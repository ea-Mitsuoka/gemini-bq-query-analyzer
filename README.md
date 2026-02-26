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
  * `worst_ranking.sql`: ワーストクエリ抽出用
  * `logical_vs_physical_storage_analysis.sql`: ストレージ課金モデル診断用
* `docs/`: 関連ドキュメント（マスターテーブル作成用DDLなど）
* `requirements.txt`: 依存Pythonパッケージ
* `Dockerfile`: コンテナビルド設定（Cloud Run Job用）

---

## 🛑 前提条件（初回のみ）

* 本システムを稼働させるには、SaaSプロジェクト側のBigQueryにアンチパターンの**マスター辞書テーブル**が存在している必要があります。
`docs/` 配下にあるDDLスクリプトを使用して、事前に `audit_master.antipattern_master` テーブルを作成・データ投入しておいてください。
* bq-antipattern-apiを事前にデプロイしている必要があります。
* 検査対象の顧客プロジェクトにGCSバケットを作成し、IAMロールを付与していただく必要があります。

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
BQ_ANTIPATTERN_ANALYZER_URL=https://bq-antipattern-api-xxxxx.a.run.app # デプロイ済みのbq-antipattern-analyzerのURL
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
python src/main.py
```

## ☁️ Cloud Run へのデプロイ手順

1. 必要なAPIの有効化

```bash
gcloud services enable aiplatform.googleapis.com run.googleapis.com cloudbuild.googleapis.com
```

1. IAM権限の確認

Cloud RunがGemini (Vertex AI) を呼び出せるように権限を付与します。

```bash
# .envファイルから変数を読み込む
set -a
source ../.env
set +a

# 実行するサービスアカウントのアドレスを定義
PROJECT_NUMBER=$(gcloud projects describe $(gcloud config get-value project) --format="value(projectNumber)")
SA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# ==========================================
# A. SaaSプロジェクト側への権限付与（実行基盤）
# ==========================================
# Gemini (Vertex AI) の実行権限
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/aiplatform.user"

# bq-antipattern-analyzer (API) の呼び出し権限
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/run.invoker"

# BigQueryのジョブ実行権限（ドライラン実行、および自社辞書の読み取り用）
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/bigquery.dataViewer"

# Cloud Storage のオブジェクト管理者
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectAdmin"

# Artifact Registry の書き込み
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/artifactregistry.writer"

# ログ記録者
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/logging.logWriter"

# ==========================================
# B. 顧客プロジェクト側への権限付与（分析対象）
# ==========================================

# BigQuery メタデータ閲覧者（各テーブルのスキーマやパーティション構成を取得するため）
gcloud projects add-iam-policy-binding ${CUSTOMER_PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/bigquery.metadataViewer"

# BigQuery リソース閲覧者（INFORMATION_SCHEMA.JOBS からプロジェクト全体のクエリ履歴を取得するため）
gcloud projects add-iam-policy-binding ${CUSTOMER_PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/bigquery.resourceViewer"
    # --role="roles/bigquery.resourceAdmin"

# Cloud Storage オブジェクト作成者（レポートMarkdownをGCSバケットに保存するため）
# 対象のバケットを指定する
gcloud projects add-iam-policy-binding ${CUSTOMER_PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectCreator"
    # --role="roles/storage.objectUser"
```

1. Cloud Run Jobsの作成（gcr.ioは非推奨のためソースコードから直接）

```bash
cd main-app
# .envファイルから変数を読み込む
set -a
source ../.env
set +a

export REGION="us-central1" # 任意のリージョン

gcloud run jobs deploy gemini-bq-query-analyzer-job \
    --source . \
    --region $REGION \
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
```

1. スケジューラーの設定

```bash
gcloud scheduler jobs create http daily-analyzer-trigger \
    --location $REGION \
    --schedule "0 9 * * *" \
    --uri "https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$(gcloud config get-value project)/jobs/gemini-bq-query-analyzer-job:run" \
    --http-method POST \
    --oauth-service-account-email "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
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
