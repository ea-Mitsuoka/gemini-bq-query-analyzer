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

echo "GitHub Actions Secrets を設定しました。"
