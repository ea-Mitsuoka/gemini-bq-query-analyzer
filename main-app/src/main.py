import os
import logging
import requests
import datetime
from functools import lru_cache
import google.auth
import google.auth.transport.requests
import google.oauth2.id_token
from google.cloud import bigquery
from google.cloud import storage
from google.api_core.exceptions import NotFound, Forbidden
import vertexai
from vertexai.generative_models import GenerativeModel
from dotenv import load_dotenv

# --- ロギングの設定 ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


# ==========================================
# 環境変数の取得
# ==========================================

# .envファイルから環境変数を読み込む (ローカル実行時のみ有効)
load_dotenv()
SAAS_PROJECT_ID = os.getenv("SAAS_PROJECT_ID")
CUSTOMER_PROJECT_ID = os.getenv("CUSTOMER_PROJECT_ID")
BQ_ANTIPATTERN_ANALYZER_URL = os.getenv("BQ_ANTIPATTERN_ANALYZER_URL")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL")
GCS_BUCKET_NAME = os.getenv("GCS_BUCKET_NAME")
LOCATION = "us-central1"        # Vertex AIのリージョン
# 調査期間の環境変数を取得
TIME_RANGE_INTERVAL = os.getenv("TIME_RANGE_INTERVAL")
TIME_RANGE_START = os.getenv("TIME_RANGE_START")
TIME_RANGE_END = os.getenv("TIME_RANGE_END")
# 抽出するワーストクエリの件数を取得（デフォルトは1）
WORST_QUERY_LIMIT = int(os.getenv("WORST_QUERY_LIMIT", "1"))
# ファイルパスの設定
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORST_RANKING_SQL_PATH = os.path.join(BASE_DIR, "sql", "worst_ranking.sql")
STORAGE_ANALYSIS_SQL_PATH = os.path.join(BASE_DIR, "sql", "logical_vs_physical_storage_analysis.sql")
GEMINI_PROMPT_PATH = os.path.join(BASE_DIR, "prompts", "gemini_prompt.txt")

# ==========================================
# ヘルパー関数群
# ==========================================

def load_external_file(filepath):
    """外部SQLファイルを読み込む"""
    if not os.path.exists(filepath):
        raise FileNotFoundError(f"File not found: {filepath}")
    with open(filepath, "r", encoding="utf-8") as f:
        return f.read()

def get_current_user_email(client):
    """実行者のメールアドレスを取得（除外用）"""
    try:
        job = client.query("SELECT session_user() as user_email")
        result = list(job.result())
        return result[0].user_email
    except Exception as e:
        logger.warning(f"Could not detect analyzer email: {e}")
        return "unknown"

def get_active_regions(client, target_project):
    """データセットが存在するリージョンを特定"""
    regions = set()
    logger.info(f"Discovering active regions in {target_project}...")
    try:
        datasets = list(client.list_datasets(project=target_project))
        for dataset_item in datasets:
            dataset = client.get_dataset(dataset_item.reference)
            if dataset.location:
                regions.add(dataset.location.lower())
        return regions
    except Exception as e:
        logger.error(f"Error discovering regions: {e}")
        return set()

def get_time_range_expressions():
    """調査期間の条件式を組み立てる"""
    if TIME_RANGE_INTERVAL:
        start_time_expr = f"TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {TIME_RANGE_INTERVAL})"
        end_time_expr = ""
    elif TIME_RANGE_START:
        start_time_expr = f"TIMESTAMP('{TIME_RANGE_START}')"
        if TIME_RANGE_END:
            end_time_expr = f"AND creation_time <= TIMESTAMP('{TIME_RANGE_END}')"
        else:
            end_time_expr = ""
    else:
        # デフォルト設定 (1日前)
        start_time_expr = "TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)"
        end_time_expr = ""
    return start_time_expr, end_time_expr

# ==========================================
# 外部API / BigQuery 解析系関数
# ==========================================

@lru_cache(maxsize=1)
def get_oidc_token(audience):
    """OIDCトークンを取得し、キャッシュする（高速化）"""
    auth_req = google.auth.transport.requests.Request()
    try:
        # 本番環境 (Cloud Run) 用
        return google.oauth2.id_token.fetch_id_token(auth_req, audience)
    except Exception:
        # ローカルテスト環境用
        credentials, _ = google.auth.default()
        credentials.refresh(auth_req)
        return credentials.id_token

def analyze_with_bq_antipattern_analyzer(query_string):
    """構文解析APIを呼び出す。トークンはキャッシュを利用。"""
    if not BQ_ANTIPATTERN_ANALYZER_URL:
        logger.warning("BQ_ANTIPATTERN_ANALYZER_URL is not set. Skipping analyzer API call.")
        return "API URL未設定のため解析をスキップしました。"

    endpoint = f"{BQ_ANTIPATTERN_ANALYZER_URL.rstrip('/')}/analyze"

    try:
        # キャッシュされた関数からトークンを取得
        id_token = get_oidc_token(BQ_ANTIPATTERN_ANALYZER_URL)

        headers = {
            "Authorization": f"Bearer {id_token}",
            "Content-Type": "application/json"
        }
        response = requests.post(endpoint, json={"query": query_string}, headers=headers, timeout=60)
        response.raise_for_status()

        return response.json().get("recommendations", "")

    except Exception as e:
        logger.error(f"bq-antipattern-analyzer API call failed: {e}")
        return "アンチパターンの解析ツール呼び出しに失敗しました。"

def get_query_schema_info(client, referenced_tables):
    """INFORMATION_SCHEMA.JOBSの履歴(referenced_tables)から元のテーブルの完全なスキーマ情報を取得する"""
    schema_details = []
    try:
        # 履歴から取得した「参照しているテーブルのリスト」を確認
        if not referenced_tables:
            return "参照しているテーブル情報が取得できませんでした。"

        for table_ref in referenced_tables:
            try:
                # table_ref は dict または Row オブジェクトとして扱う
                if isinstance(table_ref, dict):
                    project_id = table_ref.get("project_id")
                    dataset_id = table_ref.get("dataset_id")
                    table_id = table_ref.get("table_id")
                else:
                    project_id = getattr(table_ref, "project_id", None)
                    dataset_id = getattr(table_ref, "dataset_id", None)
                    table_id = getattr(table_ref, "table_id", None)

                if not project_id or not dataset_id or not table_id:
                    continue

                table_name = f"{project_id}.{dataset_id}.{table_id}"
                table = client.get_table(table_name)
                info = [f"■ テーブル: {table_name}"]

                # パーティション情報
                if table.time_partitioning:
                    part_field = table.time_partitioning.field or "_PARTITIONTIME"
                    info.append(f"  - パーティション列: {part_field} (分割タイプ: {table.time_partitioning.type_})")
                else:
                    info.append("  - パーティション: 未設定 (フルスキャンのリスクあり)")

                # クラスタリング情報
                if table.clustering_fields:
                    info.append(f"  - クラスタリング列: {', '.join(table.clustering_fields)}")

                columns = [f"{f.name} ({f.field_type})" for f in table.schema]
                info.append(f"  - カラム一覧: {', '.join(columns)}")

                schema_details.append("\n".join(info))

            except Exception as e:
                logger.warning(f"Failed to get schema for {table_id}: {e}")
                schema_details.append(f"■ テーブル: {table_id} (権限不足等によりスキーマ取得失敗)")

        return "\n\n".join(schema_details) if schema_details else "参照しているテーブル情報が取得できませんでした。"

    except Exception as e:
        logger.warning(f"Schema extraction failed: {e}")
        return "クエリの解析に失敗したため、スキーマ情報を特定できませんでした。"

def analyze_storage_pricing(client, target_project, region, sql_template):
    """ストレージ料金モデルの判定"""
    try:
        # formatメソッドを使って外部SQLの変数を動的に置換
        formatted_sql = sql_template.format(
            target_project=target_project,
            region=region
        )
        query_job = client.query(formatted_sql, location=region)
        results = list(query_job.result())

        if not results:
            return "対象となるストレージデータがありませんでした。"

        # 表のヘッダーを作成（数値カラムは右寄せ --: を使用）
        lines = [
            "| データセット | 論理 (GB) | 物理 (GB) | 圧縮率 | 推奨アクション |",
            "|---|--:|--:|--:|---|"
        ]
        # 取得した結果を表の行として追加
        for row in results:
            lines.append(
                f"| `{row.dataset_name}` | {row.logical_gb:.2f} | {row.physical_gb:.2f} "
                f"| {row.compression_ratio:.2f} | *{row.recommendation}* |"
            )
        return "\n".join(lines)

    except Exception as e:
        logger.error(f"Storage analysis failed: {e}")
        return "ストレージ分析に失敗しました。"


# ==========================================
# マスター辞書・プロンプト生成・通知系関数
# ==========================================

def load_master_dictionary(client, saas_project_id):
    """アンチパターンマスターの読み込み"""
    logger.info("Loading anti-pattern master dictionary from BigQuery...")
    master_dict = {}
    query = f"""
        SELECT pattern_name, problem_description, best_practice
        FROM `{saas_project_id}.audit_master.antipattern_master`
    """
    try:
        query_job = client.query(query)
        for row in query_job:
            master_dict[row.pattern_name] = (
                f"■ {row.pattern_name}\n"
                f"  - 問題点: {row.problem_description}\n"
                f"  - 修正の定石: {row.best_practice}"
            )
        logger.info(f"Loaded {len(master_dict)} patterns into memory.")
        return master_dict
    except Exception as e:
        logger.error(f"Failed to load master dictionary: {e}")
        return {}

def extract_relevant_dictionary(master_dict, detected_text):
    """検出されたアンチパターンのみ抽出"""
    if not detected_text or not master_dict:
        return "特になし"

    relevant_texts = [text for key, text in master_dict.items() if key in detected_text]
    return "\n\n".join(relevant_texts) if relevant_texts else "特になし"

def build_gemini_prompt(job, schema_info_text, antipattern_raw_text, master_dict_text):
    """外部ファイルからプロンプトを読み込み、変数を注入する"""
    try:
        template = load_external_file(GEMINI_PROMPT_PATH)
        params = {
            "billed_gb": job.billed_gb if job.billed_gb is not None else 0.0,
            "duration_seconds": job.duration_seconds if job.duration_seconds is not None else 0,
            "slot_hours": job.slot_hours if job.slot_hours is not None else 0.0,
            "source_type": job.source_type,
            "difficulty": job.difficulty,
            "query": job.query,
            "schema_info_text": schema_info_text,
            "antipattern_raw_text": antipattern_raw_text,
            "master_dict_text": master_dict_text
        }
        # template.format() を使い、{} プレースホルダに辞書の中身を流し込む
        return template.format(**params)

    except Exception as e:
        logger.error(f"Failed to build prompt from external file: {e}")
        return f"Analyze this SQL: {job.query}"

def upload_report_to_gcs(bucket_name, report_content, project_id):
    """Markdown形式のレポートをGCSへアップロード"""
    if not bucket_name:
        logger.warning("GCS_BUCKET_NAME is not set. Skipping GCS upload.")
        return None
    try:
        # GCSバケットはCUSTOMER_PROJECT_IDに存在する前提
        storage_client = storage.Client(project=project_id)
        bucket = storage_client.bucket(bucket_name)
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"bq_audit_report_{project_id}_{timestamp}.md"
        blob = bucket.blob(filename)

        # マークダウンテキストとしてアップロード
        blob.upload_from_string(report_content, content_type="text/markdown")

        # Cloud Console上の該当ファイル閲覧URLを返す（CUSTOMER_PROJECT_IDを指定）
        return f"https://console.cloud.google.com/storage/browser/_details/{bucket_name}/{filename}?project={project_id}"
    except Exception as e:
        logger.error(f"Failed to upload report to GCS: {e}")
        return None

def send_to_slack(text):
    """Slackへメッセージを送信する"""
    if not SLACK_WEBHOOK_URL:
        logger.warning("SLACK_WEBHOOK_URL is not set. Skipping Slack notification.")
        return
    try:
        response = requests.post(SLACK_WEBHOOK_URL, json={"text": text}, timeout=10)
        response.raise_for_status()
    except Exception as e:
        logger.error(f"Failed to send message to Slack: {e}")


# ==========================================
# メインプロセス
# ==========================================

def main():
    if not SAAS_PROJECT_ID or not CUSTOMER_PROJECT_ID:
        logger.error("Environment variables SAAS_PROJECT_ID or CUSTOMER_PROJECT_ID are not set.")
        return

    # クライアント初期化
    bq_client = bigquery.Client(project=SAAS_PROJECT_ID)
    customer_bq_client = bigquery.Client(project=CUSTOMER_PROJECT_ID)
    vertexai.init(project=SAAS_PROJECT_ID, location=LOCATION)
    model = GenerativeModel("gemini-2.5-flash")

    # 外部SQLファイルのロード
    try:
        worst_ranking_sql_template = load_external_file(WORST_RANKING_SQL_PATH)
        storage_analysis_sql_template = load_external_file(STORAGE_ANALYSIS_SQL_PATH)
    except Exception as e:
        logger.error(f"SQL file loading error: {e}")
        return

    # 基本情報の取得
    analyzer_email = get_current_user_email(bq_client)
    # Cloud Run では K_SERVICE 環境変数がセットされるため、それを利用して判定
    if os.getenv("K_SERVICE"):
        exec_env = "Cloud Run"
    else:
        exec_env = "Local"
    logger.info(f"Execution Environment : {exec_env}")
    logger.info(f"Execution Account     : {analyzer_email} (To be excluded)")
    master_dict = load_master_dictionary(bq_client, SAAS_PROJECT_ID)
    target_regions = get_active_regions(customer_bq_client, CUSTOMER_PROJECT_ID)

    if not target_regions:
        logger.info("No active regions found.")
        return

    start_time_expr, end_time_expr = get_time_range_expressions()

    # レポート用リスト（文字列結合の最適化）
    report_lines = []
    report_lines.append("# BigQuery 監査レポート")
    report_lines.append(f"**対象プロジェクト:** `{CUSTOMER_PROJECT_ID}`")
    report_lines.append(f"**作成日時:** {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    report_lines.append("\n---")

    all_jobs = []
    storage_proposals = []

    # 1. 各リージョンからのデータ収集
    for region in target_regions:
        # ストレージ分析
        proposal = analyze_storage_pricing(bq_client, CUSTOMER_PROJECT_ID, region, storage_analysis_sql_template)
        if "対象となるストレージデータがありません" not in proposal and "失敗しました" not in proposal:
            storage_proposals.append(f"### 📍 Region: {region}\n\n{proposal}\n")
        logger.info(f"[{region}] Start extracting the worst queries...")

        # ワーストクエリ抽出
        formatted_sql = worst_ranking_sql_template.format(
            target_project=CUSTOMER_PROJECT_ID,
            region=region,
            analyzer_email=analyzer_email,
            start_time_expr=start_time_expr,
            end_time_expr=end_time_expr,
            limit=WORST_QUERY_LIMIT
        )
        try:
            # リージョンを指定してINFORMATION_SCHEMAを取得
            query_job = bq_client.query(formatted_sql, location=region)
            all_jobs.extend(list(query_job.result()))
        except Exception as e:
            logger.error(f"Error in {region}: {e}")

    # 2. プロジェクト全体でのワーストクエリに絞り込む
    job_ranks = {}
    if all_jobs:
        # --- 全体の順位を計算して保存 ---
        full_sorted_by_billed = sorted(all_jobs, key=lambda x: x.billed_gb or 0.0, reverse=True)
        full_sorted_by_duration = sorted(all_jobs, key=lambda x: x.duration_seconds or 0, reverse=True)
        for rank, j in enumerate(full_sorted_by_billed, 1):
            if j.job_id not in job_ranks:
                job_ranks[j.job_id] = {}
            job_ranks[j.job_id]['cost_rank'] = rank
        for rank, j in enumerate(full_sorted_by_duration, 1):
            job_ranks[j.job_id]['duration_rank'] = rank
        # ------------------------------

        # スキャン容量と実行時間の両方でワーストなクエリをそれぞれ抽出
        worst_by_billed = sorted(all_jobs, key=lambda x: x.billed_gb or 0.0, reverse=True)[:WORST_QUERY_LIMIT]
        worst_by_duration = sorted(all_jobs, key=lambda x: x.duration_seconds or 0, reverse=True)[:WORST_QUERY_LIMIT]

        # job_idをキーにして重複を排除しつつ結合
        final_worst_jobs = {}
        for job in worst_by_billed + worst_by_duration:
            final_worst_jobs[job.job_id] = job

        all_jobs = list(final_worst_jobs.values())
        logger.info(f"Filtered down to project-wide worst queries: {len(all_jobs)} queries.")

    # 3. ストレージ判定結果をレポートに追加
    if storage_proposals:
        report_lines.append("## 💾 ストレージ料金モデルの判定結果\n")
        report_lines.append("\n".join(storage_proposals))
        report_lines.append("---\n")
    else:
        logger.info("No valid storage data to report.")

    # 4. ジョブがなければ終了
    if not all_jobs:
        logger.info("No queries to analyze.")
        report_lines.append("対象のワーストクエリは見つかりませんでした。\n")
        final_report = "\n".join(report_lines)
        gcs_url = upload_report_to_gcs(GCS_BUCKET_NAME, final_report, CUSTOMER_PROJECT_ID)
        if gcs_url:
            send_to_slack(f"✅ *本日の BigQuery 監査レポートが完了しました。*\n詳細なレポート（Markdown）はこちらのリンクから確認できます:\n{gcs_url}")
        return

    # 5. 各ワーストクエリの解析
    report_lines.append(f"## 🚨 ワーストクエリ解析（計 {len(all_jobs)} 件）\n")

    # 6. 各クエリに対して解析とGemini生成を実行
    for i, job in enumerate(all_jobs, 1):
        logger.info(f"Analyzing Job {i}/{len(all_jobs)}: {job.job_id} ({job.region_name})")
        logger.info("Extracting schema...")

        # スキーマ情報の取得 (ドライランの代わりにジョブ履歴の referenced_tables を渡す)
        schema_info_text = get_query_schema_info(bq_client, getattr(job, "referenced_tables", []))
        # 構文解析ツールの呼び出し
        antipattern_raw_text = analyze_with_bq_antipattern_analyzer(job.query)
        # メモリ上の辞書から必要なルールだけを即座に抽出
        master_dict_text = extract_relevant_dictionary(master_dict, antipattern_raw_text)
        # Geminiへのプロンプト生成(外部ファイルの読み込みと変数注入)
        prompt = build_gemini_prompt(job, schema_info_text, antipattern_raw_text, master_dict_text)

        try:
            response = model.generate_content(prompt)
            logger.info(f"Gemini Response for Job {job.job_id}:\n{response.text}\n{'-'*50}")
            report_lines.append(f"### 🔍 ワーストクエリ {i}/{len(all_jobs)} (Job: `{job.job_id}`)\n")

            # --- ランキング情報の追記 ---
            ranks = job_ranks.get(job.job_id, {})
            cost_rank = ranks.get('cost_rank', '-')
            duration_rank = ranks.get('duration_rank', '-')
            report_lines.append(f"**【プロジェクト全体ランキング】**\n- スキャン量: ワースト **{cost_rank}位**\n- 実行時間: ワースト **{duration_rank}位**\n")
            # ---------------------------

            report_lines.append(response.text)
            report_lines.append("\n---")
        except Exception as e:
            logger.error(f"Failed to generate content from Gemini for Job {job.job_id}: {e}")

    # 7. レポートの結合と出力
    final_report = "\n".join(report_lines)
    gcs_url = upload_report_to_gcs(GCS_BUCKET_NAME, final_report, CUSTOMER_PROJECT_ID)

    if gcs_url:
        send_to_slack(f"✅ *本日の BigQuery 監査レポートが完了しました。*\n詳細なレポート（Markdown）はこちらのリンクから確認できます:\n{gcs_url}")
    else:
        send_to_slack("✅ *本日の BigQuery 監査レポートが完了しました。*\n(※GCSへの保存に失敗したか、バケットが未設定です)")

if __name__ == "__main__":
    main()