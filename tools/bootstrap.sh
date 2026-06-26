#!/usr/bin/env bash
# SaaS 基盤の初回ブートストラップ（Terraform 管理外の前提）を冪等に作成する。
#   - 必要な GCP API の有効化
#   - サービスアカウント2種（ワークロード用 / Terraform デプロイ用）の作成
#   - デプロイ用 SA への SaaS 側 IAM ロール付与
#   - api-jar バケットの作成・堅牢化 + JAR の配置
#   - Workload Identity Federation（Pool / Provider / バインディング）
#
# 何度実行しても安全（既存リソースはスキップ）。実行後 `make github-secrets` を推奨。
#
# 使用方法:
#   make bootstrap                 # GITHUB_REPO は git remote から自動判定
#   make bootstrap GITHUB_REPO=owner/name
set -euo pipefail

cd "$(dirname "$0")/.."

ini() { grep -E "^\s*$1" base_config.ini | head -1 | sed 's/.*=//' | tr -d ' '; }

PROJECT=$(ini saas_project_id)
REGION=$(ini region)
API_JAR_BUCKET=$(ini api_jar_bucket_name)

if [ -z "$PROJECT" ] || [ "$PROJECT" = "<saas_project_id>" ]; then
  echo "エラー: base_config.ini の saas_project_id が未設定です。先に make setup を実行してください。"
  exit 1
fi

# GITHUB_REPO（owner/name）。未指定なら git remote から判定。
GITHUB_REPO="${GITHUB_REPO:-$(git remote get-url origin 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
if [ -z "$GITHUB_REPO" ]; then
  echo "エラー: GITHUB_REPO を判定できません。make bootstrap GITHUB_REPO=owner/name で指定してください。"
  exit 1
fi

SA_WORKLOAD="gemini-bq-query-analyzer-sa@${PROJECT}.iam.gserviceaccount.com"
SA_DEPLOYER="terraform-deployer-sa@${PROJECT}.iam.gserviceaccount.com"
JAR_NAME="bigquery-antipattern-recognition.jar"
JAR_REPO="GoogleCloudPlatform/bigquery-antipattern-recognition"

echo "== プロジェクト: ${PROJECT} / リージョン: ${REGION} / GITHUB_REPO: ${GITHUB_REPO} =="

echo "== [1/6] API を有効化 =="
gcloud services enable \
  aiplatform.googleapis.com run.googleapis.com cloudbuild.googleapis.com \
  bigquery.googleapis.com cloudscheduler.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com storage.googleapis.com \
  workflows.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="${PROJECT}"

echo "== [2/6] サービスアカウント作成 =="
gcloud iam service-accounts describe "${SA_WORKLOAD}" --project="${PROJECT}" >/dev/null 2>&1 \
  || gcloud iam service-accounts create gemini-bq-query-analyzer-sa \
       --display-name="Gemini Query Analyzer Service Account" --project="${PROJECT}"
gcloud iam service-accounts describe "${SA_DEPLOYER}" --project="${PROJECT}" >/dev/null 2>&1 \
  || gcloud iam service-accounts create terraform-deployer-sa \
       --display-name="Terraform SaaS Infrastructure Manager" --project="${PROJECT}"

echo "== [3/6] デプロイ用 SA / Cloud Build 実行 SA に IAM を付与 =="
DEPLOYER_ROLES=(
  roles/artifactregistry.admin roles/bigquery.dataOwner roles/bigquery.jobUser
  roles/cloudbuild.builds.editor roles/run.developer roles/resourcemanager.projectIamAdmin
  roles/serviceusage.serviceUsageAdmin roles/iam.serviceAccountUser roles/iam.serviceAccountAdmin
  roles/storage.admin roles/cloudscheduler.admin roles/workflows.editor roles/viewer
)
for ROLE in "${DEPLOYER_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${SA_DEPLOYER}" --role="${ROLE}" \
    --condition=None --no-user-output-enabled
done

# Cloud Build のビルド実行 SA（Compute Engine デフォルト SA）にソース読み取り等を付与。
# 近年の Cloud Build は新規プロジェクトでこの SA を使うため、未付与だと
# `gcloud builds submit` が storage.objects.get 403 で失敗する。
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for ROLE in roles/cloudbuild.builds.builder roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${COMPUTE_SA}" --role="${ROLE}" \
    --condition=None --no-user-output-enabled
done

echo "== [4/6] api-jar バケットを作成・堅牢化 =="
if [ -z "$API_JAR_BUCKET" ] || [ "$API_JAR_BUCKET" = "<api_jar_bucket_name>" ]; then
  API_JAR_BUCKET="gemini-bq-analyzer-api-jar-${PROJECT}"
  sed -i '' "s/^\s*api_jar_bucket_name.*/api_jar_bucket_name = ${API_JAR_BUCKET}/" base_config.ini
  echo "  api_jar_bucket_name を ${API_JAR_BUCKET} に設定しました（base_config.ini）"
fi
gcloud storage buckets describe "gs://${API_JAR_BUCKET}" >/dev/null 2>&1 \
  || gcloud storage buckets create "gs://${API_JAR_BUCKET}" --project="${PROJECT}" --location="${REGION}"
gcloud storage buckets update "gs://${API_JAR_BUCKET}" --uniform-bucket-level-access --public-access-prevention >/dev/null

echo "== [5/6] JAR を配置 =="
if gcloud storage ls "gs://${API_JAR_BUCKET}/${JAR_NAME}" >/dev/null 2>&1; then
  echo "  既に存在: gs://${API_JAR_BUCKET}/${JAR_NAME}"
else
  if [ ! -f "bq-antipattern-api/${JAR_NAME}" ]; then
    echo "  JAR をダウンロード（${JAR_REPO} の最新リリース）..."
    gh release download --repo "${JAR_REPO}" --pattern "*.jar" --dir bq-antipattern-api/ \
      || { echo "エラー: JAR を取得できません。${JAR_REPO} の releases から ${JAR_NAME} を bq-antipattern-api/ に配置して再実行してください。"; exit 1; }
  fi
  gcloud storage cp "bq-antipattern-api/${JAR_NAME}" "gs://${API_JAR_BUCKET}/"
fi

echo "== [6/6] Workload Identity Federation =="
gcloud iam workload-identity-pools describe github-actions-pool \
  --project="${PROJECT}" --location=global >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools create github-actions-pool \
       --project="${PROJECT}" --location=global --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers describe github-provider \
  --project="${PROJECT}" --location=global --workload-identity-pool=github-actions-pool >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools providers create-oidc github-provider \
       --project="${PROJECT}" --location=global --workload-identity-pool=github-actions-pool \
       --display-name="GitHub Provider" \
       --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor" \
       --attribute-condition="assertion.repository == '${GITHUB_REPO}'" \
       --issuer-uri="https://token.actions.githubusercontent.com"

WIF_POOL=$(gcloud iam workload-identity-pools describe github-actions-pool \
  --project="${PROJECT}" --location=global --format="value(name)")
gcloud iam service-accounts add-iam-policy-binding "${SA_DEPLOYER}" \
  --project="${PROJECT}" --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WIF_POOL}/attribute.repository/${GITHUB_REPO}" \
  --no-user-output-enabled

echo
echo "ブートストラップ完了。次に 'make github-secrets' で GitHub Actions Secrets を設定してください。"
echo "（ワークロード SA の SaaS IAM は terraform apply = make deploy で付与されます）"
