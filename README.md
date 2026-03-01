# Gemini BQ Query Analyzer

BigQueryの `INFORMATION_SCHEMA` からワーストクエリを抽出し、Geminiを使ってコスト・パフォーマンスの最適化案を自動生成・通知するツールです。

## 📁 ディレクトリ構成

```plaintext
gemini-bq-query-analyzer/ (Gitリポジトリのルート)
├── .env                  # ローカル環境変数（Git除外）
├── .gitignore
│
├── terraform/            # インフラ定義（先ほど作成したIaC）
│   ├── main.tf
│   ├── variables.tf
│   └── ...
│
├── workflows/             # 🆕 Workflowの定義ファイルを格納する専用ディレクトリ
│   └── analyzer_workflow.yaml # 🆕 実際の実行フロー（YAML）
│
├── main-app/             # 🔍 メインの監査ツール（Cloud Run Job）
│   ├── src/
│   │   └── main.py       # （現在のメインスクリプト）
│   ├── sql/
│   │   ├── antipattern-list.sql  # ★これをTerraformからも読み込みます
│   │   ├── worst_ranking.sql
│   │   └── logical_vs_physical_storage_analysis.sql
│   ├── requirements.txt  # vertexai, google-cloud-bigquery 等
│   └── Dockerfile        # PythonベースのJob用コンテナ定義
│
└── bq-antipattern-api/      # ⚙️ 構文解析API（Cloud Run Service）
    ├── app.py            # FastAPIなどのAPIコード
    ├── requirements.txt  # fastapi, uvicorn 等
    └── Dockerfile        # Java + Python 同居のService用コンテナ定義
```

* `src/` : メインのPythonプログラム（`main.py` 等）
* `sql/` : 抽出用のSQLクエリ（`query.sql`）
  * `antipattern-list.sql`:masterテーブル作成用
  * `worst_ranking.sql`: ワーストクエリ抽出用
  * `logical_vs_physical_storage_analysis.sql`: ストレージ課金モデル診断用
* `docs/`: 関連ドキュメント（マスターテーブル作成用DDLなど）
* `requirements.txt`: 依存Pythonパッケージ
* `Dockerfile`: コンテナビルド設定（Cloud Run Job用）

---

## 🛑 前提条件（初回のみ）

* 本システムを稼働させるには、SaaSプロジェクト側のBigQueryにアンチパターンの**マスター辞書テーブル**が存在している必要があります。
`docs/` 配下にあるDDLスクリプトを使用して、事前に `audit_master.antipattern_master` テーブルを作成・データ投入(`antipattern-list.sql`をBigQueryのコンソールで実行)しておいてください。
* bq-antipattern-apiを事前にデプロイしている必要があります。
  * JAR ファイルの実在: bq-antipattern-api/ 直下に bigquery-antipattern-recognition.jar が配置されている必要があります 。これが欠けていると、コンテナビルドは成功しても API 実行時に 500 Error になります 。
* 検査対象の顧客プロジェクトにGCSバケットを作成し、IAMロールを付与していただく必要があります。
* 置換変数の整合性: gemini_prompt.txt 内で使用する変数（{query} や {billed_gb} など）が、Python コード側で定義した辞書のキーと完全に一致している必要があります 。

---

## 💻 ローカルでの開発・テスト環境セットアップ

**※ コマンドはすべてプロジェクトのルートディレクトリで実行してください。**

1. **依存ライブラリのインストール**

```bash
pip install -r requirements.txt
```

1. 環境変数の設定

ルートディレクトリに .env ファイルを作成し、以下の変数を設定します（Gitにはコミットされません）。

```bash
SAAS_PROJECT_ID=your-saas-project-id
CUSTOMER_PROJECT_ID=target-customer-project-id
REGION="us-central1"
# デプロイ済みのbq-antipattern-analyzerのURL
BQ_ANTIPATTERN_ANALYZER_URL=https://bq-antipattern-api-xxxxx.a.run.app 
SLACK_WEBHOOK_URL=your-slack-webhook-url
GCS_BUCKET_NAME=for-reports-storage
# 抽出するワーストクエリの最大件数（コスト、実行時間それぞれ）
WORST_QUERY_LIMIT=2
# --- 調査期間の設定 ---
# [注意]180日より前のクエリ履歴やジョブデータは自動的に消去されるため、調査期間は180日以内に設定してください。
# パターン1: 相対指定で期間を決める場合 (優先)
+ # 例: "1 DAY", "7 DAY", "30 DAY", "12 HOUR" などを指定します。
TIME_RANGE_INTERVAL="1 MONTH"
# パターン2: 絶対時間で期間を決める場合
# TIME_RANGE_INTERVALを空にして、以下を指定します (形式: YYYY-MM-DD HH:MM:SS)
# TIME_RANGE_START="2024-01-01 00:00:00"
# TIME_RANGE_END="2024-01-31 23:59:59"

# ---
# 1. 最優先で適用される（他の設定を上書きする）
# - コードの一番最初（if TIME_RANGE_INTERVAL:）で判定されているため、この変数に値が入っている場合は、仮に .env で TIME_RANGE_START や TIME_RANGE_END が設定されていたとしても、それらはすべて無視されます。

# 2. 開始時刻（start_time_expr）の計算
# - SQLの TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ○○) という関数を使って開始時刻を作ります。
# - これは「プログラムを実行した現在時刻（CURRENT_TIMESTAMP()）から、指定された期間（TIME_RANGE_INTERVAL）を引き算する」という処理です。

# 例: "1 MONTH" と指定して実行したのが「今日の午後3時」であれば、開始時刻は「ちょうど1ヶ月前の午後3時」になります。

# 3. 終了時刻（end_time_expr）は「現在まで」になる
# - end_time_expr = "" と空文字（カラ）に設定されます。
# - これにより、後続のSQL組み立て部分で上限（終了日時）の条件が追加されなくなります。上限がないということは、開始時刻から**「最新のクエリ（現在時刻）」まですべて**が調査対象になります。
```

1. ローカル実行

```bash
python main-app/src/main.py
```

## ☁️ Cloud Run へのデプロイ手順

1. APIの有効化

```bash
gcloud services enable aiplatform.googleapis.com run.googleapis.com cloudbuild.googleapis.com
```

1. サービスアカウントの作成およびIAMロールの設定

```bash
# .envファイルから変数を読み込む
set -a
source .env
set +a

# サービスアカウントの名前とメールアドレスを定義
SA_NAME="gemini-bq-query-analyzer-sa"
SA_EMAIL="${SA_NAME}@${SAAS_PROJECT_ID}.iam.gserviceaccount.com"
echo $SA_EMAIL

gcloud iam service-accounts create $SA_NAME \
    --display-name="Gemini Query Analyzer Service Account" \
    --project=$SAAS_PROJECT_ID

# ==========================================
# A. SaaSプロジェクト側への権限付与（実行基盤）
# ==========================================

SAAS_ROLES=(
    "roles/aiplatform.user"
    "roles/run.invoker"
    "roles/bigquery.jobUser"
    "roles/bigquery.dataViewer"
    "roles/logging.logWriter"
)
# "roles/aiplatform.user"         # Gemini (Vertex AI) の実行権限
# "roles/run.invoker"             # bq-antipattern-analyzer (API) の呼び出し権限
# "roles/bigquery.jobUser"        # Saasプロジェクトでジョブ実行権限（ドライラン実行)
# "roles/bigquery.dataViewer"     # masterテーブルを閲覧する権限
# "roles/logging.logWriter"       # Cloud Runデプロイおよびツールログ書き出し
for ROLE in ${SAAS_ROLES[@]}; do
    echo $ROLE
done

for ROLE in ${SAAS_ROLES[@]}; do
    gcloud projects add-iam-policy-binding $SAAS_PROJECT_ID \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$ROLE" \
        --condition=None
done

# ==========================================
# B. 顧客プロジェクト側への権限付与（分析対象）
# ==========================================

CUSTOMER_ROLES=(
    "roles/bigquery.metadataViewer"
    "roles/bigquery.resourceViewer"
)
# "roles/bigquery.metadataViewer" # BigQuery メタデータ閲覧者（各テーブルのスキーマやパーティション構成を取得するため）
# "roles/bigquery.resourceViewer" # BigQuery リソース閲覧者（INFORMATION_SCHEMA.JOBS からプロジェクト全体のクエリ履歴を取得するため）
# "roles/storage.objectCreator"   # Cloud Storage オブジェクト作成者（レポートMarkdownをGCSバケットに保存するため）
for ROLE in ${CUSTOMER_ROLES[@]}; do
    echo $ROLE
done

for ROLE in ${CUSTOMER_ROLES[@]}; do
    gcloud projects add-iam-policy-binding $CUSTOMER_PROJECT_ID \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$ROLE" \
        --condition=None
done
```

1. 顧客プロジェクトにレポート保存用のバケット作成

```bash
# バケット作成
gcloud storage buckets create gs://[BUCKET_NAME] --project=[CUSTOMER_PROJECT_ID] --location=us-central1
# 権限付与
gcloud storage buckets add-iam-policy-binding gs://[BUCKET_NAME] \
    --member="serviceAccount:[SA_EMAIL]" --role="roles/storage.objectAdmin"
```

1. Cloud Run Jobsの作成（gcr.ioは非推奨のためソースコードから直接）

```bash
cd main-app
# .envファイルから変数を読み込む
set -a
source ../.env
set +a

gcloud run jobs deploy gemini-bq-query-analyzer-job \
    --source . \
    --region $REGION \
    --service-account=${SA_EMAIL} \
    --set-env-vars SAAS_PROJECT_ID=${SAAS_PROJECT_ID} \
    --set-env-vars CUSTOMER_PROJECT_ID=${CUSTOMER_PROJECT_ID} \
    --set-env-vars BQ_ANTIPATTERN_ANALYZER_URL=${BQ_ANTIPATTERN_ANALYZER_URL} \
    --set-env-vars SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL} \
    --set-env-vars GCS_BUCKET_NAME=${GCS_BUCKET_NAME} \
    --set-env-vars WORST_QUERY_LIMIT=${WORST_QUERY_LIMIT} \
    --set-env-vars TIME_RANGE_INTERVAL=${TIME_RANGE_INTERVAL}

    # --set-env-vars TIME_RANGE_START=${TIME_RANGE_START} \
    # --set-env-vars TIME_RANGE_END=${TIME_RANGE_END}
```

1. ジョブの単発実行（テスト）

```bash
gcloud run jobs execute gemini-bq-query-analyzer-job --region $REGION

# Cloud Schedulerをterraformで作成した場合、Workflowから環境変数を書き換える設定をする事を前提としているため gcloudコマンドやCloud Run Jobを強制実行したらエラーになる. Cloud Schedulerによる実行ならOK
gcloud scheduler jobs run gemini-bq-query-analyzer-job --location $REGION
```

1. workflowsの設定

```bash

```

1. スケジューラーの設定(コマンドは要検証)

```bash
gcloud scheduler jobs create http gemini-bq-query-analyzer-trigger \
    --location $REGION \
    --schedule ${SCHEDULER_CRON} \
    --time-zone="Asia/Tokyo" \
    --uri "https://workflowexecutions.googleapis.com/v1/projects/${SAAS_PROJECT_ID}/locations/${REGION}/workflows/${ANALYZER_WORKFLOW}/executions" \
    --message-body='{"slack_webhook_url": "https://hooks.slack.com/services/T00/B00/XXXX", "customer_id": "tenant-a"}' \
    --oauth-service-account-email "${SA_EMAIL}"
```

## 🔧 運用・メンテナンス

1. Cloud Runの環境変数を更新

顧客（分析対象）や設定を変更したい場合は、コードを再デプロイする必要はなく、環境変数を更新するだけで対応可能です。

```bash
gcloud run jobs update gemini-bq-query-analyzer-job \
    --region us-central1 \
    --update-env-vars CUSTOMER_PROJECT_ID=${CUSTOMER_PROJECT_ID}
```

### 💡 メモ: `.env` ファイルの読み込み仕様について（モノレポ化の背景）

当プロジェクトでは、インフラ（Terraform）、メインバッチ（`main-app/`）、API（`bq-antipattern-api/`）をひとつのリポジトリで管理するモノレポ構成を採用しています。

ローカル開発用の `.env` ファイルは各アプリケーションのディレクトリ内ではなく、**プロジェクトのルートディレクトリに1つだけ配置**し、全アプリケーションで共有する運用としています。

Pythonコード（`main-app/src/main.py` 等）内での環境変数の読み込みは、引数なしの `load_dotenv()` を使用しています。
これは `python-dotenv` ライブラリの仕様（親ディレクトリに向かって `.env` を自動探索する `find_dotenv()` の挙動）を利用したものです。これにより、コード内に絶対パスや相対パスをハードコードすることなく、高い可読性を維持したままルートの `.env` を安全に読み込んでいます。

`terraform destroy`をするときは、顧客プロジェクトのバケットの中身を空にして、SaaSプロジェクトのmasterテーブルを削除する
