# Gemini BQ Query Analyzer

BigQueryの `INFORMATION_SCHEMA` からワーストクエリを抽出し、Geminiを使ってコスト・パフォーマンスの最適化案を自動生成・通知するツールです。

## 🏗️ アーキテクチャ図

```mermaid
flowchart LR
    %% ─── Terraform (top) ────────────────────────────────────────────────────
    TF["🏗 Terraform\n全リソース IaC 管理\ntfvars で Client 差分を管理"]

    %% ─── SaaS Project ───────────────────────────────────────────────────────
    subgraph SAAS["☁️ SaaS Project"]
        direction LR
        SCH["① 🕐 Cloud Scheduler\n定期トリガー"]
        WF["② 🔀 Cloud Workflows\nClient ごとの環境変数を\n上書きして Job 起動"]
        JOB["③ 🚀 Cloud Run Job\nMain Process"]
        OSS["⑤ 🔍 Cloud Run Service\nBQ Antipattern Recognition\nFastAPI Wrapper"]
        VAI["⑥ 🤖 Vertex AI / Gemini\nクエリ最適化\nアドバイス生成"]
    end

    %% ─── Customer / Client Project ──────────────────────────────────────────
    subgraph CLIENT["🏢 Customer / Client Project"]
        direction TB
        BQ["④ 🗄 BigQuery\nINFORMATION_SCHEMA\n.JOBS_BY_PROJECT"]
        GCS["⑦ 🪣 Cloud Storage\nMarkdown レポート格納"]
        SLACK["⑧ 💬 Slack\nGCS パスとサマリーを通知"]
    end

    %% ─── Flows ───────────────────────────────────────────────────────────────
    SCH -->|"① Cron で起動"| WF
    WF  -->|"② 環境変数上書きで起動"| JOB
    JOB -->|"③ ジョブ履歴を取得"| BQ
    BQ  -->|"④ 履歴・スキャン量を返却"| JOB
    JOB -->|"⑤ HTTP POST\nクエリ文字列"| OSS
    OSS -->|"⑤ アンチパターン\n検出結果を返却"| JOB
    JOB -->|"⑥ OSS結果＋クエリを\nプロンプト送信"| VAI
    VAI -->|"⑥ 最適化アドバイス\nを返却"| JOB
    JOB -->|"⑦ Markdown\nをアップロード"| GCS
    JOB -->|"⑧ GCS パス＆\nサマリーを通知"| SLACK

    TF -.->|manages| SAAS
    TF -.->|grants IAM to SA| CLIENT

    %% ─── Styles ─────────────────────────────────────────────────────────────
    classDef scheduler fill:#1e3a5f,stroke:#3b82f6,color:#bfdbfe
    classDef workflows  fill:#0c2a4a,stroke:#0ea5e9,color:#bae6fd
    classDef crjob      fill:#0c2040,stroke:#22d3ee,color:#a5f3fc
    classDef crservice  fill:#0d2e2e,stroke:#2dd4bf,color:#99f6e4
    classDef vertexai   fill:#1e1040,stroke:#a78bfa,color:#ddd6fe
    classDef bigquery   fill:#0f2d1f,stroke:#34d399,color:#a7f3d0
    classDef gcs        fill:#0f2d1f,stroke:#34d399,color:#a7f3d0
    classDef slack      fill:#2d1515,stroke:#f87171,color:#fecaca
    classDef terraform  fill:#1e1040,stroke:#7c3aed,color:#c4b5fd

    class SCH scheduler
    class WF workflows
    class JOB crjob
    class OSS crservice
    class VAI vertexai
    class BQ bigquery
    class GCS gcs
    class SLACK slack
    class TF terraform
```

## 📁 ディレクトリ構成

```plaintext
gemini-bq-query-analyzer/ (Gitリポジトリのルート)
├── env.txt                       # ローカル環境変数（Git除外）
├── .gitignore
│
├── .github/
│   ├── workflows/
│      └── deploy.yaml            # CI/CD
│
├── terraform/                    # インフラ定義
│   ├── main.tf
│   ├── variables.tf
│   ├── terraform.tfvars          # terraform環境変数（Git除外）
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

* tfstateファイルを格納するGCSバケットを作成しておく必要があります。
* 置換変数の整合性: gemini_prompt.txt 内で使用する変数（{query} や {billed_gb} など）が、Python コード側で定義した辞書のキーと完全に一致している必要があります。
* Spread Sheet APIを有効化`gcloud services enable sheets.googleapis.com --project=<saas_project_id>`

\# ---削除予定---
* terraform-deployer-saに`Cloud Build 編集者`と`Storage 管理者`と`Service Usage ユーザー`を付与しておく
\# ---削除予定---

---

## ☁️ 環境構築: 共通

### 1. GCSバケットを作成(初回のみ)

\# tfstateファイル格納用

```bash
# 環境変数設定
export $(grep -v '^\[.*\]' base_config.ini | sed 's/ *= */=/g' | xargs)

# 1. ランダムな4桁のサフィックスを生成
RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)

# 2. 新しいバケット名を決定（例: ea-agentspacepj-tfstate-a1b2）
NEW_TFSTATE_BUCKET="tfstate-for-gemini-bq-analyzer-${saas_project_id}-${RANDOM_SUFFIX}"
echo "✨ 新しいtfstateバケット: ${NEW_TFSTATE_BUCKET}"

# 3. バケットを作成
gcloud storage buckets create "gs://${NEW_TFSTATE_BUCKET}" \
    --project=${saas_project_id} \
    --location=${region}
```

\# BigQuery Antipattern Recognitionツール格納用

```bash
# 1. ランダムな4桁のサフィックスを生成
RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)

# 2. 新しいバケット名を決定（例: ea-agentspacepj-tfstate-a1b2）
NEW_API_JAR_BUCKET="api-jar-for-gemini-bq-analyzer-${saas_project_id}-${RANDOM_SUFFIX}"
echo "✨ 新しいtfstateバケット: ${NEW_API_JAR_BUCKET}"

# 3. バケットを作成
gcloud storage buckets create "gs://${NEW_API_JAR_BUCKET}" \
    --project=${saas_project_id} \
    --location=${region}
```

### 2. `base_config.ini`ファイルを設定

```bash
# tfstateバケット名
echo $NEW_TFSTATE_BUCKET
sed -i '' "s/<tfstate_bucket_name>/${NEW_TFSTATE_BUCKET}/g" base_config.ini

# api-jarバケット名
echo $NEW_API_JAR_BUCKET
sed -i '' "s/<api_jar_bucket_name>/${NEW_API_JAR_BUCKET}/g" base_config.ini

# 3. 置換結果の確認
cat base_config.ini
```

### 3. Terraform実行用のサービスアカウント作成

```bash
gcloud iam service-accounts create terraform-deployer-sa \
    --display-name="Terraform SaaS Infrastructure Manager" \
    --project=${saas_project_id}
```

### 4.Terraform実行用のサービスアカウントにIAMロール付与

\# Terraform実行用サービスアカウントに必要なIAMロール [⚠️]ログ書き込みが不要な可能性あり要検証

| 行番号 | 表示名 | ロール識別子 | 利用目的 |
| :--- | :--- | :--- | :--- |
| 1 | Artifact Registry 管理者 | roles/artifactregistry.admin | Dockerリポジトリの作成および削除 |
| 2 | BigQuery データ管理者 | roles/bigquery.dataOwner | BigQueryのデータセットとテーブルを作成および削除 |
| 3 | BigQuery ジョブユーザー | roles/bigquery.jobUser | BigQueryのテーブル読み取り,DDL実行 |
| 4 | Cloud Build 編集者 | roles/cloudbuild.builds.editor | Cloud Build を実行する権限 |
| 5 | Cloud Run 開発者 | roles/run.developer | Cloud Runサービスやジョブの作成および削除 |
| 6 | Project IAM 管理者 | roles/resourcemanager.projectIamAdmin | IAMロールを付与する権限 |
| 7 | Service Usage Admin | roles/serviceusage.serviceUsageAdmin | APIを有効化 |
| 8 | サービス アカウント ユーザー | roles/iam.serviceAccountUser | Cloud Buildの実行,Workflowsへの紐付け |
| 9 | サービス アカウント 管理者 | roles/iam.serviceAccountAdmin | サービスアカウント作成および削除 |
| 10 | Storage 管理者 | roles/storage.Admin | tfstateファイルを格納するBackendバケットに書き込み |
| 11 | Cloud Scheduler 管理者 | roles/cloudscheduler.admin | ジョブの作成および削除 |
| 12 | ログ書き込み | roles/logging.logWriter | ログエントリ作成 |
| 13 | Workflows 編集者 | roles/workflows.editor | workflowの作成および削除 |
| 14 | 閲覧者 | roles/viewer | Secret ManagerのSlack Webhook URLの確認, ビルドログの確認など |

```bash
ROLES=(
    "roles/artifactregistry.admin"
    "roles/bigquery.dataOwner"
    "roles/bigquery.jobUser"
    "roles/cloudbuild.builds.editor"
    "roles/run.developer"
    "roles/resourcemanager.projectIamAdmin"
    "roles/serviceusage.serviceUsageAdmin"
    "roles/iam.serviceAccountUser"
    "roles/iam.serviceAccountAdmin"
    "roles/storage.Admin"
    "roles/cloudscheduler.admin"
    "roles/logging.logWriter"
    "roles/workflows.editor"
    "roles/viewer"
)

SA_EMAIL="terraform-deployer-sa@${saas_project_id}.iam.gserviceaccount.com"

# ループによる権限付与の実行
echo "Starting IAM policy binding for ${SA_EMAIL} in project ${saas_project_id}..."

for ROLE in "${ROLES[@]}"; do
    echo "Adding role: ${ROLE}"
    gcloud projects add-iam-policy-binding "${saas_project_id}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="${ROLE}" \
        --no-user-output-enabled
done

echo "IAM policy binding completed."
```

### 5. 顧客情報のスプレッドシート`Gemini-BQ-Query-Analyzer-Tenant-Master`を準備

下記の項目を設定する

* tenant_id
* customer_project_id
* gcs_bucket_name([注意⚠️]予め顧客に作成してもらい、バケット名を聞く)
* worst_query_limit
* time_range_interval
* slack_webhook_secret_name(Secret Managerに登録したSlack Webhook URL)
* scheduler_cron

### Github ActionsのSercretを登録

Setteings > Secrets and variables > Actions > New repositry secret

* GOOGLE_CREDENTIALS: 作成したTerraform実行用サービスアカウントのJSONキー
* SPREADSHEET_ID: 顧客情報スプレッドシートのID

## ☁️ 環境構築: Terraform編

### 1. BigQuery Antipattern Recognitionツールをダウンロード

Cloud Run ServiceとしてデプロイしてAPI化するために下記を実施

* [Github](https://github.com/GoogleCloudPlatform/bigquery-antipattern-recognition/releases)から`bigquery-antipattern-recognition.jar`をダウンロード
* ローカルで実行することも考慮して`bq-antipattern-api/`に`bigquery-antipattern-recognition.jar`を配置

## 2. BigQuery Antipattern RecognitionツールをGCSへ格納

```bash
gcloud storage cp bq-antipattern-api/bigquery-antipattern-recognition.jar gs://${NEW_API_JAR_BUCKET}/
```

### 3. Github Actionsの手動実行

Github Actionsには、terraform実行用のサービスアカウントのJSONと顧客情報スプレッドシートのIDを保存しておく

* GitHub リポジトリの Actions タブに移動
* 左側のメニューから Manual Deploy from Spreadsheet（または設定したワークフロー名）を選択
* Run workflow ボタンをクリックして実行
  * `terraform apply`まで実行される

### 4. 生成ファイルの確認とダウンロード

Manual Deploy from Spreadsheet > Summary > deployment-configs > ↓

出力例:
\# env.txt

```bash
# ==========================================
# 共通設定 (SaaS 基盤側)
# ==========================================
SAAS_PROJECT_ID="saas_project-id"
REGION="us-central1"

# ==========================================
# マルチテナント設定 (JSON 形式)
# ==========================================
TENANTS_JSON='{
  "tenant1": {
    "customer_project_id": "tenant1_project_id",
    "gcs_bucket_name": "gemini-query-analyzer-reports",
    "worst_query_limit": "1",
    "time_range_interval": "1 DAY",
    "slack_webhook_secret_name": "",
    "scheduler_cron": "0 9 * * *"
  },
  "tenant2": {
    "customer_project_id": "tenant2_project_id",
    "gcs_bucket_name": "gemini-query-analyzer-reports",
    "worst_query_limit": "1",
    "time_range_interval": "2 DAY",
    "slack_webhook_secret_name": "",
    "scheduler_cron": "0 10 * * *"
  }
}'
```

\# terraform.tfvars

```bash
# Generated by generate_tfvars.py - DO NOT EDIT MANUALLY
# ==========================================
# 共通設定 (SaaS 基盤側)
# ==========================================
saas_project_id = "ea-agentspacepj"
region          = "us-central1"

# ==========================================
# マルチテナント設定 (マップ 形式)
# ==========================================
tenants = {
  "pacific-legend" = {
    customer_project_id       = "pacific-legend-634"
    gcs_bucket_name           = "gemini-query-analyzer-reports"
    worst_query_limit         = "1"
    time_range_interval       = "2 DAY"
    slack_webhook_secret_name = ""
    scheduler_cron            = "0 9 * * *"
  }
  "datatechlab" = {
    customer_project_id       = "ea-datatechlab"
    gcs_bucket_name           = "gemini-query-analyzer-reports"
    worst_query_limit         = "1"
    time_range_interval       = "2 DAY"
    slack_webhook_secret_name = ""
    scheduler_cron            = "0 10 * * *"
  }
}
```

\# backend.tf

```bash
# Generated from base_config.ini - DO NOT EDIT
terraform {
  backend "gcs" {
    bucket = "<NEW_TFSTATE_BUCKET>"
     prefix = "terraform/state"
  }
}
```

## 🗑️ 環境破棄

### 1. `backend.tf`と`terraform.tfvars`の配置

* 一旦、Github ActionsでRun workflowを実行して生成した環境ファイルをダウンロード
* `terraform/terrform.tfvars`に配置

```bash
cd Downloads/deployment-configs
cp terraform/{backend.tf,terraform.tfvars} ~/gemini-bq-query-analyzer/terraform/
```

### 2. SaaSプロジェクトのmasterテーブルを削除

```bash
bq rm -r -f -d ${saas_project_id}:audit_master
```

### 3. `terraform destroy`

先に`terraform state list`や`terraform plan`で内容を確認して注意して実施する

```bash
cd terraform
terraform destroy
```

---

## ☁️ 環境構築: gcloud編

### 1. SaaSプロジェクトのAPIの有効化

```bash
gcloud services enable \
    sheets.googleapis.com \
    aiplatform.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    bigquery.googleapis.com \
    cloudscheduler.googleapis.com \
    iam.googleapis.com \
    storage.googleapis.com \
    workflows.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com
```

### 2. 環境設定ファイルを配置

```bash
cd Downloads/deployment-configs
cp env.txt ~/gemini-bq-query-analyzer/
```

### 3. SaaSプロジェクトにサービスアカウントの作成

```bash
# .envファイルから変数を読み込む
set -a
source env.txt
set +a

# サービスアカウントの名前とメールアドレスを定義
SA_NAME="gemini-bq-query-analyzer-sa"
SA_EMAIL="${SA_NAME}@${SAAS_PROJECT_ID}.iam.gserviceaccount.com"
echo $SA_EMAIL

gcloud iam service-accounts create ${SA_NAME} \
    --display-name="Gemini Query Analyzer Service Account" \
    --project=${SAAS_PROJECT_ID}
```

### 4. SaaSプロジェクトにIAMロールの設定

```bash
# ==========================================
# SaaSプロジェクト側への権限付与（実行基盤）
# ==========================================
SAAS_ROLES=(
    "roles/aiplatform.user"
    "roles/bigquery.jobUser"
    "roles/bigquery.dataViewer"
    "roles/workflows.invoker"
    "roles/secretmanager.secretAccessor"
    "roles/run.developer"
    "roles/logging.logWriter"
)
# "roles/aiplatform.user"              # Gemini (Vertex AI) の実行権限
# "roles/bigquery.jobUser"             # Saasプロジェクトでジョブ実行権限（ドライラン実行)
# "roles/bigquery.dataViewer"          # masterテーブルを閲覧する権限
# "roles/workflows.invoker"            # workflowsの起動
# "roles/secretmanager.secretAccessor" # Secret ManagerからSlack Webhook URLの取得
# "roles/run.developer"                # cloud run service(api)とJobの呼び出し, workflowsから環境変数セット
# "roles/logging.logWriter"            # Cloud Runなどからログ書き出し

for ROLE in ${SAAS_ROLES[@]}; do
    echo $ROLE
done

for ROLE in ${SAAS_ROLES[@]}; do
    gcloud projects add-iam-policy-binding ${SAAS_PROJECT_ID} \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$ROLE" \
        --condition=None
done
```

### 5. bq-antipattern-apiのデプロイ

[注意]Cloud Run Serviceのデプロイ手順は`bq-antipattern-api/README.md`をご確認ください。

### 6. bq-antipattern-apiのURLを取得

```bash
# デプロイされたURLを環境変数に格納（後続のJob作成で使用）
BQ_ANTIPATTERN_API_URL=$(
  gcloud run services describe bq-antipattern-api \
    --region="${REGION}" \
    --project="${SAAS_PROJECT_ID}" \
    --format="value(status.url)"
)

echo "API URL: ${BQ_ANTIPATTERN_API_URL}"
```

### 7. masterデータセット作成 & masterデータ投入

```bash
# データセットの作成
bq mk --location=${REGION} --project_id=${SAAS_PROJECT_ID} audit_master

# テーブル作成とデータ投入 (SQL内のプレースホルダーを置換して実行)
sed "s/<saas_project_id>/${SAAS_PROJECT_ID}/g" main-app/sql/antipattern-list.sql | \
bq query --use_legacy_sql=false --project_id=${SAAS_PROJECT_ID}
```

### 8. 顧客プロジェクトにIAMロール付与 & レポート保存用のバケット作成

```bash
# ==========================================
# 顧客プロジェクト側への権限付与（分析対象） & GCSバケットへ権限付与
# ==========================================
CUSTOMER_ROLES=(
    "roles/bigquery.metadataViewer"
    "roles/bigquery.resourceViewer"
)
# "roles/bigquery.metadataViewer" # 各テーブルのスキーマやパーティション構成を取得
# "roles/bigquery.resourceViewer" # INFORMATION_SCHEMA.JOBS からプロジェクト全体のクエリ履歴を取得

# 2. jq を使ってテナントのキー（pacific-legend, datatechlab）のリストを取得しループ
for TENANT_KEY in $(echo "$TENANTS_JSON" | jq -r 'keys[]'); do

    # 3. 各テナントの詳細情報を取得
    CUSTOMER_PROJECT_ID=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".customer_project_id")
    GCS_BUCKET_NAME=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".gcs_bucket_name")

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

    # 6. バケットへの権限付与 (Storage オブジェクト管理者)
    echo "[2/2] Adding IAM policy binding for Service Account..."
    gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET_NAME}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/storage.objectAdmin" \
        --quiet
done
```

### 9. メイン分析ジョブ (gemini-bq-query-analyzer-job) の作成

```bash
cd main-app

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
    --set-env-vars WORST_QUERY_LIMIT="" \
    --set-env-vars TIME_RANGE_INTERVAL=""

    # --set-env-vars TIME_RANGE_START=${TIME_RANGE_START} \
    # --set-env-vars TIME_RANGE_END=${TIME_RANGE_END}
```

### 10. Workflowsの設定

```bash
cd ../workflows

# YAML内の変数を環境変数で置換した一時ファイルを生成してデプロイ
cat analyzer_workflow.yaml | sed \
  -e 's/\$\${/${/g' \
  -e "s/\${project_id}/${SAAS_PROJECT_ID}/g" \
  -e "s/\${region}/${REGION}/g" \
  -e "s/\${job_name}/gemini-bq-query-analyzer-job/g" > processed_workflow.yaml

gcloud workflows deploy gemini-bq-query-analyzer-workflow \
    --source processed_workflow.yaml \
    --location $REGION \
    --project $SAAS_PROJECT_ID \
    --service-account=${SA_EMAIL}
```

### 11. Cloud Schedulerの設定

```bash
# jqを使用してテナントごとにループ実行
for TENANT_KEY in $(echo "$TENANTS_JSON" | jq -r 'keys[]'); do

    # テナント情報の抽出
    CUSTOMER_PROJECT_ID=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".customer_project_id")
    BUCKET_NAME=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".gcs_bucket_name")
    WORST_LIMIT=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".worst_query_limit")
    INTERVAL=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".time_range_interval")
    WEBHOOK=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".slack_webhook_secret_name")
    CRON=$(echo "$TENANTS_JSON" | jq -r ".\"$TENANT_KEY\".scheduler_cron")

    # Workflowに渡す引数のJSONを構築
    ARGUMENT=$(jsonencode_args=$(jq -n \
        --arg tid "$TENANT_KEY" \
        --arg cpid "$CUSTOMER_PROJECT_ID" \
        --arg bkt "$BUCKET_NAME" \
        --arg limit "$WORST_LIMIT" \
        --arg interval "$INTERVAL" \
        --arg webhook "$WEBHOOK" \
        '{tenant_id: $tid, customer_project_id: $cpid, gcs_bucket_name: $bkt, worst_query_limit: $limit, time_range_interval: $interval, slack_webhook_secret_name: $webhook}')
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

---

### 💡 メモ

* `env.txt` ファイルの読み込み仕様について
  * 当プロジェクトでは、インフラ（Terraform）、メインバッチ（`main-app/`）、API（`bq-antipattern-api/`）をひとつのリポジトリで管理するモノレポ構成を採用しており`env.txt`ファイルは両方から参照します。
