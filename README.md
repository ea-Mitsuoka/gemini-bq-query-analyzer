# Gemini BQ Query Analyzer

BigQueryの `INFORMATION_SCHEMA` からワーストクエリを抽出し、Geminiを使ってコスト・パフォーマンスの最適化案を自動生成・通知するツールです。

## 📁 ディレクトリ構成

```plaintext
gemini-bq-query-analyzer/ (Gitリポジトリのルート)
├── .env                          # ローカル環境変数（Git除外）
├── .gitignore
│
├── terraform/                    # インフラ定義
│   ├── main.tf
│   ├── variables.tf
│   └── ...
│
├── workflows/                    # Workflowの定義ファイルを格納する専用ディレクトリ
│   └── analyzer_workflow.yaml    # 実際の実行フロー（YAML）
│
├── main-app/                     # 🔍 メインの分析ツール（Cloud Run Job）
│   ├── src/
│   │   └── main.py               # メインスクリプト
│   ├── sql/
│   │   ├── antipattern-list.sql  # masterテーブル作成(traformからも読み込みます)
│   │   ├── worst_ranking.sql
│   │   └── logical_vs_physical_storage_analysis.sql
│   ├── requirements.txt          # vertexai, google-cloud-bigquery 等
│   └── Dockerfile                # PythonベースのJob用コンテナ定義
│
└── bq-antipattern-api/           # ⚙️ 構文解析API（Cloud Run Service）
    ├── app.py                    # FastAPIなどのAPIコード
    ├── requirements.txt          # fastapi, uvicorn 等
    └── Dockerfile                # Java + Python 同居のService用コンテナ定義
```

---

## 🛑 前提条件

* 原則として以下の5つの手順でだけで環境構築はできます。
  * JAR ファイルの準備: `bq-antipattern-api/`直下に`bigquery-antipattern-recognition.jar`を配置
  * `.env`ファイルを準備
  * `tools/`で`generate_tfvars.py`を実行
  * 分析対象の顧客プロジェクトでterraformを実行するユーザーに対して`Project IAM 管理者`と`Storage 管理者`ロールを付与
  * `terraform/`で`terraform apply`を実行
* 分析対象の顧客プロジェクトにトIAMロールを付与していただく必要があります。
* 置換変数の整合性: gemini_prompt.txt 内で使用する変数（{query} や {billed_gb} など）が、Python コード側で定義した辞書のキーと完全に一致している必要があります。

---

## 💻 ローカルでの開発・テスト環境セットアップ

**※ コマンドはすべてプロジェクトのルートディレクトリで実行してください。**

### 1. 依存ライブラリのインストール

```bash
pip install -r requirements.txt
```

### 2. 環境変数の設定

ルートディレクトリに .env ファイルを作成し、以下の変数を設定します（Gitにはコミットされません）。

```bash
SAAS_PROJECT_ID=your-saas-project-id
CUSTOMER_PROJECT_ID=target-customer-project-id
REGION="us-central1"
SLACK_WEBHOOK_URL=your-slack-webhook-url
GCS_BUCKET_NAME=for-reports-storage
# 抽出するワーストクエリの最大件数（コスト、実行時間それぞれ）
WORST_QUERY_LIMIT=1
# --- 調査期間の設定 ---
# [注意]180日より前のクエリ履歴やジョブデータは自動的に消去されるため、調査期間は180日以内に設定してください。
# パターン1: 相対指定で期間を決める場合 (優先)
+ # 例: "1 DAY", "7 DAY", "30 DAY", "12 HOUR" などを指定します。
TIME_RANGE_INTERVAL="1 DAY"
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

# 3. 終了時刻（end_time_expr）は「現在まで」になる
# - end_time_expr = "" と空文字（カラ）に設定されます。
# - これにより、後続のSQL組み立て部分で上限（終了日時）の条件が追加されなくなります。上限がないということは、開始時刻から**「最新のクエリ（現在時刻）」まですべて**が調査対象になります。
```

### 3. ローカル実行

```bash
python main-app/src/main.py
```

## ☁️ Cloud Run へのデプロイ手順

### 1. SaaSプロジェクトのAPIの有効化

```bash
gcloud services enable \
    aiplatform.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    bigquery.googleapis.com \
    cloudscheduler.googleapis.com \
    iam.googleapis.com \
    storage.googleapis.com \
    workflows.googleapis.com \
    artifactregistry.googleapis.com
```

### 2. SaaSプロジェクトにサービスアカウントの作成

```bash
# .envファイルから変数を読み込む
set -a
source .env
set +a

# サービスアカウントの名前とメールアドレスを定義
SA_NAME="gemini-bq-query-analyzer-sa"
SA_EMAIL="${SA_NAME}@${SAAS_PROJECT_ID}.iam.gserviceaccount.com"
echo $SA_EMAIL

gcloud iam service-accounts create ${SA_NAME} \
    --display-name="Gemini Query Analyzer Service Account" \
    --project=${SAAS_PROJECT_ID}
```

### 3. IAMロールの設定

```bash
# ==========================================
# SaaSプロジェクト側への権限付与（実行基盤）
# ==========================================
SAAS_ROLES=(
    "roles/aiplatform.user"
    "roles/bigquery.jobUser"
    "roles/bigquery.dataViewer"
    "roles/workflows.invoker"
    "roles/run.developer"
    "roles/logging.logWriter"
)
# "roles/aiplatform.user"         # Gemini (Vertex AI) の実行権限
# "roles/bigquery.jobUser"        # Saasプロジェクトでジョブ実行権限（ドライラン実行)
# "roles/bigquery.dataViewer"     # masterテーブルを閲覧する権限
# "roles/workflows.invoker"       # workflowsの起動
# "roles/run.developer"           # cloud run service(api)とJobの呼び出し, workflowsから環境変数セット
# "roles/logging.logWriter"       # Cloud Runなどからログ書き出し

for ROLE in ${SAAS_ROLES[@]}; do
    echo $ROLE
done

for ROLE in ${SAAS_ROLES[@]}; do
    gcloud projects add-iam-policy-binding ${SAAS_PROJECT_ID} \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$ROLE" \
        --condition=None
done

# デプロイされたURLを環境変数に格納（後続のJob作成で使用）
BQ_ANTIPATTERN_API_URL=$(
  gcloud run services describe bq-antipattern-api \
    --region="${REGION}" \
    --project="${SAAS_PROJECT_ID}" \
    --format="value(status.url)"
)

echo "API URL: ${BQ_ANTIPATTERN_API_URL}"
```

### 4. masterデータセット作成 & masterデータ投入

```bash
# データセットの作成
bq mk --location=${REGION} --project_id=${SAAS_PROJECT_ID} audit_master

# テーブル作成とデータ投入 (SQL内のプレースホルダーを置換して実行)
sed "s/<saas_project_id>/${SAAS_PROJECT_ID}/g" sql/antipattern-list.sql | \
bq query --use_legacy_sql=false --project_id=${SAAS_PROJECT_ID}
```

### 5. 顧客プロジェクトにIAMロール付与 & レポート保存用のバケット作成

```bash
# ==========================================
# 顧客プロジェクト側への権限付与（分析対象） & GCSバケット作成
# ==========================================
CUSTOMER_ROLES=(
    "roles/bigquery.metadataViewer"
    "roles/bigquery.resourceViewer"
)
# "roles/bigquery.metadataViewer" # 各テーブルのスキーマやパーティション構成を取得
# "roles/bigquery.resourceViewer" # INFORMATION_SCHEMA.JOBS からプロジェクト全体のクエリ履歴を取得
for ROLE in ${CUSTOMER_ROLES[@]}; do
    echo $ROLE
done

# 2. jq を使ってテナントのキー（pacific-legend, datatechlab）のリストを取得しループ
for TENANT_KEY in $(echo "$TENANTS_JSON" | jq -r 'keys[]'); do

    # 3. 各テナントの詳細情報を取得
    CUSTOMER_PROJECT_ID=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".customer_project_id")
    GCS_BUCKET_PREFIX=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".gcs_bucket_prefix")

    # 4-a. ランダムな4桁の英数字 suffix を生成（方法1）
    RANDOM_SUFFIX=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)

    # 4-b. バケット名の構築
    BUCKET_NAME="${GCS_BUCKET_PREFIX}-${CUSTOMER_PROJECT_ID}-${RANDOM_SUFFIX}"

    echo "----------------------------------------"
    echo "Tenant: ${TENANT_KEY}"
    echo "Project: ${CUSTOMER_PROJECT_ID}"

    # 5. IAMロールを付与
    for ROLE in ${CUSTOMER_ROLES[@]}; do
        gcloud projects add-iam-policy-binding $CUSTOMER_PROJECT_ID \
            --member="serviceAccount:${SA_EMAIL}" \
            --role="$ROLE" \
            --condition=None
    done

    # 6. バケットの作成
    echo "[1/2] Creating bucket: gs://${BUCKET_NAME}..."
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
        --project="${CUSTOMER_PROJECT_ID}" \
        --location="${REGION}"

    # 7. バケットへの権限付与 (Storage オブジェクト管理者)
    # インタラクティブな確認をスキップ
    echo "[2/2] Adding IAM policy binding for Service Account..."
    gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/storage.objectAdmin" \
        --quiet
done
```

### 6. メイン分析ジョブ (gemini-bq-query-analyzer-job) の作成

```bash
cd main-app
# .envファイルから変数を読み込む
set -a
source ../.env
set +a

gcloud run jobs deploy gemini-bq-query-analyzer-job \
    --source . \
    --region ${REGION} \
    --project ${SAAS_PROJECT_ID} \
    --service-account=${SA_EMAIL} \
    --max-retries 0 \
    --task-timeout 600s \
    --set-env-vars SAAS_PROJECT_ID=${SAAS_PROJECT_ID} \
    --set-env-vars BQ_ANTIPATTERN_API_URL=${BQ_ANTIPATTERN_API_URL} \
    --set-env-vars CUSTOMER_PROJECT_ID="" \
    --set-env-vars GCS_BUCKET_NAME="" \
    --set-env-vars TIME_RANGE_INTERVAL="" \
    --set-env-vars WORST_QUERY_LIMIT=""

    # --set-env-vars TIME_RANGE_START=${TIME_RANGE_START} \
    # --set-env-vars TIME_RANGE_END=${TIME_RANGE_END}
```

### 7. workflowsの設定

```bash
cd ../workflows

set -a
source ../.env
set +a

# YAML内の変数を環境変数で置換した一時ファイルを生成してデプロイ
# (Terraformのtemplatefile相当の処理)
cat analyzer_workflow.yaml | sed \
  -e "s/\${project_id}/${SAAS_PROJECT_ID}/g" \
  -e "s/\${region}/${REGION}/g" \
  -e "s/\${job_name}/gemini-bq-query-analyzer-job/g" > processed_workflow.yaml

gcloud workflows deploy gemini-bq-query-analyzer-workflow \
    --source processed_workflow.yaml \
    --region $REGION \
    --project $SAAS_PROJECT_ID \
    --service-account=${SA_EMAIL}
```

### 8. スケジューラーの設定(コマンドは要検証)

```bash
# jqを使用してテナントごとにループ実行
for TENANT_KEY in $(echo "$TENANTS_JSON" | jq -r 'keys[]'); do

    # テナント情報の抽出
    CUSTOMER_PROJECT_ID=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".customer_project_id")
    WORST_LIMIT=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".worst_query_limit")
    INTERVAL=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".time_range_interval")
    CRON=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".scheduler_cron")
    WEBHOOK=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".slack_webhook_url")
    BUCKET_PREFIX=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".gcs_bucket_prefix")

    # ここでは既存バケットを検索して特定します
    ACTUAL_BUCKET=$(
        gcloud storage buckets list \
            --project=${CUSTOMER_PROJECT_ID} \
            --format="value(name)" | grep "${BUCKET_PREFIX}-${CUSTOMER_PROJECT_ID}" \
    )

    # Workflowに渡す引数のJSONを構築
    ARGUMENT=$(jsonencode_args=$(jq -n \
        --arg cid "$TENANT_KEY" \
        --arg cpid "$CUSTOMER_PROJECT_ID" \
        --arg bkt "$ACTUAL_BUCKET" \
        --arg limit "$WORST_LIMIT" \
        --arg interval "$INTERVAL" \
        --arg webhook "$WEBHOOK" \
        '{customer_id: $cid, customer_project_id: $cpid, gcs_bucket_name: $bkt, worst_query_limit: $limit, time_range_interval: $interval, slack_webhook_url: $webhook}')
        echo "{\"argument\": $(echo $jsonencode_args | jq -Rs .)}")

    # Schedulerジョブの作成
    gcloud scheduler jobs create http "gemini-bq-query-analyzer-scheduler-${TENANT_KEY}" \
        --project $SAAS_PROJECT_ID \
        --location $REGION \
        --schedule "$CRON" \
        --uri "https://workflowexecutions.googleapis.com/v1/projects/${SAAS_PROJECT_ID}/locations/${REGION}/workflows/gemini-bq-query-analyzer-workflow/executions" \
        --message-body "$ARGUMENT" \
        --oauth-service-account-email ${SA_EMAIL} \
        --time-zone "Asia/Tokyo"
done
```

### 💡 メモ

* `.env` ファイルの読み込み仕様について（モノレポ化の背景）
  * 当プロジェクトでは、インフラ（Terraform）、メインバッチ（`main-app/`）、API（`bq-antipattern-api/`）をひとつのリポジトリで管理するモノレポ構成を採用しています。
  * ローカル開発用の `.env` ファイルは各アプリケーションのディレクトリ内ではなく、**プロジェクトのルートディレクトリに1つだけ配置**し、全アプリケーションで共有する運用としています。

* `terraform destroy`
  * 顧客プロジェクトのバケットの中身を空にして、SaaSプロジェクトのmasterテーブルを削除(`bq rm -r -f -d ea-agentspacepj:audit_master`)する
