#!/usr/bin/env bash
# 指定テナントの分析を Workflow 経由でオンデマンド実行する（Scheduler とは分離）。
# tenants.json（GCS）から対象テナントの設定を取り出して Workflow に渡す。
#
# 使用方法: tools/run_tenant.sh <tenant_id>
set -euo pipefail

cd "$(dirname "$0")/.."

TENANT="${1:?tenant_id を指定してください（例: make run TENANT=pacific-legend-634）}"

if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が必要です。インストールしてください。"
  exit 1
fi

ini() { grep -E "^\s*$1" base_config.ini | head -1 | sed 's/.*=//' | tr -d ' '; }
PROJECT=$(ini saas_project_id)
REGION=$(ini region)
TFSTATE_BUCKET=$(ini tfstate_bucket_name)

# GCS の tenants.json から対象テナント設定を取得（真実の源泉）
TENANTS_JSON=$(gcloud storage cat "gs://${TFSTATE_BUCKET}/config/tenants.json")
if ! echo "$TENANTS_JSON" | jq -e --arg t "$TENANT" 'has($t)' >/dev/null; then
  echo "エラー: tenants.json にテナント '${TENANT}' が見つかりません。"
  exit 1
fi

# Scheduler が送るのと同じ形の引数を組み立てる
ARG=$(echo "$TENANTS_JSON" | jq -c --arg t "$TENANT" '.[$t] | {
  tenant_id: $t,
  customer_project_id: .customer_project_id,
  gcs_bucket_name: .gcs_bucket_name,
  worst_query_limit: .worst_query_limit,
  time_range_interval: .time_range_interval,
  slack_webhook_secret_name: .slack_webhook_secret_name
}')

echo "オンデマンド実行: tenant=${TENANT}（完了まで待機します）"
# gcloud workflows run は実行が FAILED でも終了コード 0 を返すため、
# 返却 JSON の state を必ず確認する（失敗を成功に見せない）。
if ! OUT=$(gcloud workflows run gemini-bq-query-analyzer-workflow \
  --project "$PROJECT" --location "$REGION" \
  --data "$ARG" --format=json); then
  echo "エラー: Workflow の実行に失敗しました。" >&2
  exit 1
fi

STATE=$(echo "$OUT" | jq -r '.state // "UNKNOWN"')
if [ "$STATE" != "SUCCEEDED" ]; then
  echo >&2
  echo "エラー: Workflow が失敗しました (state=${STATE})。" >&2
  echo "$OUT" | jq -r '.error.payload // "詳細なし"' >&2
  echo >&2
  echo "詳細は Cloud Logging で ANALYZER_FAILURE を検索してください。" >&2
  exit 1
fi

# Workflow の返り値（要点＋署名付きURL）を実行者に表示する
RESULT=$(echo "$OUT" | jq -r '.result // empty')
echo
echo "===== 分析結果 ====="
echo "$RESULT" | jq -r '"サマリ: " + (.text_summary // "N/A") + "\nレポート(署名付きURL、7日間有効):\n" + (.report_url // "N/A")' 2>/dev/null \
  || echo "$RESULT"
