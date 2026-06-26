#!/usr/bin/env bash
# Slack Webhook URL を Secret Manager へ登録する（テナント単位）。
# 使用方法: tools/set_secret.sh <tenant_id> <webhook_url>
set -euo pipefail

cd "$(dirname "$0")/.."

TENANT="${1:?tenant_id を指定してください}"
URL="${2:?Webhook URL を指定してください}"

PROJECT=$(grep -E '^\s*saas_project_id' base_config.ini | head -1 | sed 's/.*=//' | tr -d ' ')
SECRET="slack-webhook-${TENANT}"

gcloud secrets describe "${SECRET}" --project="${PROJECT}" >/dev/null 2>&1 \
  || gcloud secrets create "${SECRET}" --project="${PROJECT}" --replication-policy="automatic"

printf '%s' "${URL}" | gcloud secrets versions add "${SECRET}" --project="${PROJECT}" --data-file=-

echo "Secret '${SECRET}' を登録しました。"
echo "tenants.json の該当テナントの slack_webhook_secret_name に '${SECRET}' を設定してください。"
