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
    TF -.->|manages| CLIENT

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
├── .env                          # ローカル環境変数（Git除外）
├── .gitignore
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

* Terraform実行アカウントに顧客プロジェクトで`Project IAM 管理者`と`ストレージ 管理者`のIAMロールが必要です。
* 置換変数の整合性: gemini_prompt.txt 内で使用する変数（{query} や {billed_gb} など）が、Python コード側で定義した辞書のキーと完全に一致している必要があります。

---

## ☁️ 環境構築手順 Terraform編

### 1. BigQuery Antipattern Recognitionツールの準備

* [Github](https://github.com/GoogleCloudPlatform/bigquery-antipattern-recognition/releases)から`bigquery-antipattern-recognition.jar`をダウンロード
* `bq-antipattern-api/`に`bigquery-antipattern-recognition.jar`を配置

### 2. `.env`ファイルを設定

例:

```bash
# ==========================================
# 共通設定 (SaaS 基盤側)
# ==========================================
SAAS_PROJECT_ID="saas_project-id"
REGION="us-central1"
# terraformが動的に取得するため不要↓
# BQ_ANTIPATTERN_API_URL=https://bq-antipattern-api-<saas_project_number>.<region>.run.app

# ==========================================
# マルチテナント設定 (JSON 形式)
# ==========================================
# 💡 顧客が増える場合は、この JSON 内に要素を追加してください。
# ※ シングルクォーテーションで囲むことで、内部のダブルクォーテーションを許容します。
TENANTS_JSON='{
  "tenant1": {
    "customer_project_id": "tenant1_project_id",
    "worst_query_limit": "1",
    "time_range_interval": "1 DAY",
    "gcs_bucket_prefix": "gemini-query-analyzer-reports",
    "slack_webhook_url": "https://hooks.slack.com/services/xxx/yyy/zzz",
    "scheduler_cron": "0 9 * * *"
  },
  "tenant2": {
    "customer_project_id": "tenant2_project_id",
    "worst_query_limit": "1",
    "time_range_interval": "2 DAY",
    "gcs_bucket_prefix": "gemini-query-analyzer-reports",
    "slack_webhook_url": "https://hooks.slack.com/services/xxx/yyy/zzz",
    "scheduler_cron": "0 10 * * *"
  }
}'
```

### 3. tfvarsファイルの作成

`tools/`で`generate_tfvars.py`を実行

### 4. gcloudで認証

Terraformを実行する環境（PCやCI/CD）でコマンドを実行

```bash
gcloud auth login
gcloud auth application-default login
```

### 5. terraform apply

```bash
cd terraform
terraform apply
```

## 🗑️ 環境破棄

* `terraform destroy`を成功させるには、事前に以下の２点を済ませておく必要がある
  * 顧客プロジェクトのバケットの中身を空にする
  * SaaSプロジェクトのmasterテーブルを削除(`bq rm -r -f -d <saas_project_id>:audit_master`)する

## ☁️ 環境構築手順 gcloudコマンド&shell編

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

### 3. SaaSプロジェクトにIAMロールの設定

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
```

### 4. bq-antipattern-apiのデプロイ

[注意]Cloud Run Serviceのデプロイ手順は`bq-antipattern-api/README.md`をご確認ください。

### 5. bq-antipattern-apiのURLを取得

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

### 6. masterデータセット作成 & masterデータ投入

```bash
# データセットの作成
bq mk --location=${REGION} --project_id=${SAAS_PROJECT_ID} audit_master

# テーブル作成とデータ投入 (SQL内のプレースホルダーを置換して実行)
sed "s/<saas_project_id>/${SAAS_PROJECT_ID}/g" main-app/sql/antipattern-list.sql | \
bq query --use_legacy_sql=false --project_id=${SAAS_PROJECT_ID}
```

### 7. 顧客プロジェクトにIAMロール付与 & レポート保存用のバケット作成

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
    RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
    # RANDOM_SUFFIX=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)

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

### 8. メイン分析ジョブ (gemini-bq-query-analyzer-job) の作成

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
    --set-env-vars TIME_RANGE_INTERVAL="" \
    --set-env-vars WORST_QUERY_LIMIT=""

    # --set-env-vars TIME_RANGE_START=${TIME_RANGE_START} \
    # --set-env-vars TIME_RANGE_END=${TIME_RANGE_END}
```

### 9. Workflowsの設定

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

### 10. Cloud Schedulerの設定

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
