# gcloud による手動構築（別紙）

Terraform / CI を使わず `gcloud` のみで構築する詳細手順です。
通常は [README](../README.md) の `make` ベースの手順を利用してください。

______________________________________________________________________

### gcloudによる手動構築

#### 1. SaaSプロジェクトのAPIの有効化

```bash
gcloud services enable \
    aiplatform.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    bigquery.googleapis.com \
    cloudscheduler.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    sts.googleapis.com \
    storage.googleapis.com \
    workflows.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com
```

#### 2. 環境設定ファイルを配置

```bash
cd Downloads/deployment-configs
cp env.txt ~/gemini-bq-query-analyzer/
```

#### 3. SaaSプロジェクトにサービスアカウントの作成

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

#### 4. SaaSプロジェクトにIAMロールの設定

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

#### 5. bq-antipattern-apiのデプロイ

[注意]Cloud Run Serviceのデプロイ手順は`bq-antipattern-api/README.md`をご確認ください。

#### 6. bq-antipattern-apiのURLを取得

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

#### 7. masterデータセット作成 & masterデータ投入

```bash
# データセットの作成
bq mk --location=${REGION} --project_id=${SAAS_PROJECT_ID} audit_master

# テーブル作成とデータ投入 (SQL内のプレースホルダーを置換して実行)
sed "s/<saas_project_id>/${SAAS_PROJECT_ID}/g" main-app/sql/antipattern-list.sql | \
bq query --use_legacy_sql=false --project_id=${SAAS_PROJECT_ID}
```

#### 8. 顧客プロジェクトにIAMロール付与 & レポート保存用のバケット作成

```bash
# ==========================================
# 顧客プロジェクト側への権限付付与（分析対象） & GCSバケットへ権限付与
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

#### 9. メイン分析ジョブ (gemini-bq-query-analyzer-job) の作成

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

#### 10. Workflowsの設定

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

#### 11. Cloud Schedulerの設定

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
