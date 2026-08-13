#!/usr/bin/env bash
# GitHub Actions の Secrets（WIF_PROVIDER / SERVICE_ACCOUNT）を gh CLI で設定する。
# bootstrap で作成した Workload Identity Provider と デプロイ用 SA を参照する。
#
# 前提: gh CLI が対象リポジトリに対して認証済みであること。
set -euo pipefail

cd "$(dirname "$0")/.."

ini() { grep -E "^\s*$1" base_config.ini | head -1 | sed 's/.*=//' | tr -d ' '; }
PROJECT=$(ini saas_project_id)

if ! command -v gh >/dev/null 2>&1; then
  echo "エラー: gh CLI が必要です。https://cli.github.com/ を導入し gh auth login を実行してください。"
  exit 1
fi

WIF_PROVIDER=$(gcloud iam workload-identity-pools providers describe github-provider \
  --project="${PROJECT}" --location=global --workload-identity-pool=github-actions-pool \
  --format="value(name)")
SERVICE_ACCOUNT="terraform-deployer-sa@${PROJECT}.iam.gserviceaccount.com"

if [ -z "$WIF_PROVIDER" ]; then
  echo "エラー: WIF Provider が見つかりません。先に make bootstrap を実行してください。"
  exit 1
fi

echo "WIF_PROVIDER  = ${WIF_PROVIDER}"
echo "SERVICE_ACCOUNT = ${SERVICE_ACCOUNT}"

gh secret set WIF_PROVIDER --body "${WIF_PROVIDER}"
gh secret set SERVICE_ACCOUNT --body "${SERVICE_ACCOUNT}"

# 失敗通知の宛先。公開リポジトリに置けないため terraform/alert.auto.tfvars（Git管理外）から拾う。
# 未設定のまま Actions からデプロイすると Monitoring のアラートが削除されるので警告する。
ALERT_TFVARS="terraform/alert.auto.tfvars"
if [ -f "$ALERT_TFVARS" ]; then
  ALERT_EMAIL=$(sed -n 's/^[[:space:]]*alert_notification_email[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$ALERT_TFVARS" | head -1)
else
  ALERT_EMAIL=""
fi

if [ -n "$ALERT_EMAIL" ]; then
  echo "ALERT_NOTIFICATION_EMAIL = ${ALERT_EMAIL}"
  gh secret set ALERT_NOTIFICATION_EMAIL --body "${ALERT_EMAIL}"
else
  echo "警告: ${ALERT_TFVARS} に alert_notification_email が見つかりません。"
  echo "      ALERT_NOTIFICATION_EMAIL を設定しないまま Actions からデプロイすると、"
  echo "      失敗通知（Monitoring アラート）が削除されます。"
fi

echo "GitHub Actions Secrets を設定しました。"
