#!/usr/bin/env bash
# 環境が整っているかを確認する。NG があっても最後まで実行し、最後に終了コードへ反映する。
set -uo pipefail

cd "$(dirname "$0")/.."

FAIL=0
ok()   { echo "  [OK]  $1"; }
ng()   { echo "  [NG]  $1"; FAIL=1; }
info() { echo "  [--]  $1"; }

echo "== コマンド =="
command -v gcloud    >/dev/null 2>&1 && ok "gcloud"    || ng "gcloud 未インストール"
command -v terraform >/dev/null 2>&1 && ok "terraform" || ng "terraform 未インストール"
command -v uv        >/dev/null 2>&1 && ok "uv"        || info "uv 未インストール（make install で使用）"
command -v jq        >/dev/null 2>&1 && ok "jq"        || info "jq 未インストール（手動構築手順で使用）"
command -v curl      >/dev/null 2>&1 && ok "curl"      || info "curl 未インストール（Gemini 到達性チェックで使用）"

echo "== 設定ファイル =="
if [ -f base_config.ini ]; then
  ok "base_config.ini が存在"
  PROJECT=$(grep -E '^\s*saas_project_id' base_config.ini | head -1 | sed 's/.*=//' | tr -d ' ')
  TFSTATE_BUCKET=$(grep -E '^\s*tfstate_bucket_name' base_config.ini | head -1 | sed 's/.*=//' | tr -d ' ')
else
  ng "base_config.ini が存在しない"
  PROJECT=""; TFSTATE_BUCKET=""
fi

echo "== 認証 =="
if command -v gcloud >/dev/null 2>&1; then
  ACTIVE=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)
  [ -n "$ACTIVE" ] && ok "gcloud 認証済み: ${ACTIVE}" || ng "gcloud 未認証（make setup を実行）"

  CUR_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [ -n "$PROJECT" ] && [ "$CUR_PROJECT" = "$PROJECT" ]; then
    ok "デフォルトプロジェクト一致: ${CUR_PROJECT}"
  else
    ng "デフォルトプロジェクト不一致（現在: ${CUR_PROJECT:-未設定} / 期待: ${PROJECT:-不明}）"
  fi

  ADC="${HOME}/.config/gcloud/application_default_credentials.json"
  [ -f "$ADC" ] && ok "ADC 認証情報が存在" || ng "ADC 未設定（make setup を実行）"
fi

echo "== GCP リソース =="
if command -v gcloud >/dev/null 2>&1 && [ -n "$PROJECT" ]; then
  REQUIRED_APIS="aiplatform.googleapis.com run.googleapis.com bigquery.googleapis.com \
cloudscheduler.googleapis.com workflows.googleapis.com artifactregistry.googleapis.com \
secretmanager.googleapis.com storage.googleapis.com cloudbuild.googleapis.com"
  ENABLED=$(gcloud services list --enabled --project="$PROJECT" --format="value(config.name)" 2>/dev/null || true)
  for api in $REQUIRED_APIS; do
    echo "$ENABLED" | grep -q "^${api}$" && ok "API 有効: ${api}" || ng "API 無効: ${api}"
  done

  if [ -n "$TFSTATE_BUCKET" ]; then
    if gcloud storage buckets describe "gs://${TFSTATE_BUCKET}" --format="value(name)" >/dev/null 2>&1; then
      ok "tfstate バケット存在: ${TFSTATE_BUCKET}"
      if gcloud storage ls "gs://${TFSTATE_BUCKET}/config/tenants.json" >/dev/null 2>&1; then
        ok "tenants.json が GCS に存在"
      else
        ng "tenants.json が未アップロード（make template -> 編集 -> upload_tenants.py）"
      fi
    else
      ng "tfstate バケットが存在しない: ${TFSTATE_BUCKET}（make ensure-bucket で作成）"
    fi
  fi
fi

echo "== Gemini 到達性 =="
# モデルは「カタログに存在する」だけでは呼べず、提供エンドポイント（リージョン/global）が
# モデルごとに異なる。組み合わせが不正でも本番では例外が握り潰されがちなので、
# デプロイ前にここで 1 回だけ実際に叩いて確認する。
# 名前を二重管理するとドリフトするため、値は main.py から読む。
MAIN_PY="main-app/src/main.py"
GEMINI_MODEL=$(sed -n 's/^GEMINI_MODEL[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$MAIN_PY" | head -1)
GEMINI_LOCATION=$(sed -n 's/^LOCATION[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$MAIN_PY" | head -1)

if [ -z "$GEMINI_MODEL" ] || [ -z "$GEMINI_LOCATION" ]; then
  ng "${MAIN_PY} から GEMINI_MODEL / LOCATION を読み取れない（定義名が変わった可能性）"
elif ! command -v curl >/dev/null 2>&1 || ! command -v gcloud >/dev/null 2>&1 || [ -z "$PROJECT" ]; then
  info "Gemini 到達性チェックはスキップ（curl / gcloud / プロジェクト設定が必要）"
else
  if [ "$GEMINI_LOCATION" = "global" ]; then
    AI_HOST="aiplatform.googleapis.com"
  else
    AI_HOST="${GEMINI_LOCATION}-aiplatform.googleapis.com"
  fi
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
  if [ -z "$TOKEN" ]; then
    info "Gemini 到達性チェックはスキップ（アクセストークンを取得できない）"
  else
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST \
      "https://${AI_HOST}/v1/projects/${PROJECT}/locations/${GEMINI_LOCATION}/publishers/google/models/${GEMINI_MODEL}:generateContent" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "x-goog-user-project: ${PROJECT}" \
      -H "Content-Type: application/json" \
      -d '{"contents":[{"role":"user","parts":[{"text":"ping"}]}],"generationConfig":{"maxOutputTokens":1}}' 2>/dev/null || true)
    if [ "$CODE" = "200" ]; then
      ok "Gemini 呼び出し可: ${GEMINI_MODEL} @ ${GEMINI_LOCATION}"
    else
      ng "Gemini 呼び出し不可: ${GEMINI_MODEL} @ ${GEMINI_LOCATION} (HTTP ${CODE:-応答なし})"
      ng "  モデルの提供エンドポイントを確認してください（3.x 系は global のみの場合あり）"
    fi
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "全チェック OK。"
else
  echo "未充足の項目があります（上記 [NG] を参照）。"
fi
exit "$FAIL"
