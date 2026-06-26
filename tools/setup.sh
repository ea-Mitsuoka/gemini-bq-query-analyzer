#!/usr/bin/env bash
# 初回にどうしても必須となる gcloud 認証・プロジェクト設定を対話形式で実行する。
# 重い IAM/WIF/バケット作成などの初回手順は README を参照。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f base_config.ini ]; then
  echo "エラー: base_config.ini が見つかりません。先に作成してください。"
  exit 1
fi

ask() { read -rp "$1 [y/N] " ans; [[ "${ans:-N}" =~ ^[Yy]$ ]]; }
ini() { grep -E "^\s*$1" base_config.ini | head -1 | sed 's/.*=//' | tr -d ' '; }

if ! command -v gcloud >/dev/null 2>&1; then
  echo "エラー: gcloud が見つかりません。Google Cloud SDK をインストールしてください。"
  exit 1
fi

if ask "gcloud にログインしますか? (gcloud auth login)"; then
  gcloud auth login
fi

if ask "アプリケーションデフォルト認証(ADC)を行いますか? (gcloud auth application-default login)"; then
  gcloud auth application-default login
fi

# SaaS プロジェクトID: base_config.ini が未設定/プレースホルダなら入力して書き込む
PROJECT=$(ini saas_project_id)
if [ -z "$PROJECT" ] || [ "$PROJECT" = "<saas_project_id>" ]; then
  DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  read -rp "SaaS プロジェクトID を入力 [${DEFAULT_PROJECT}]: " PROJECT
  PROJECT="${PROJECT:-$DEFAULT_PROJECT}"
  sed -i '' "s/^\s*saas_project_id.*/saas_project_id = ${PROJECT}/" base_config.ini
  echo "base_config.ini に saas_project_id = ${PROJECT} を設定しました。"
fi
echo "対象 SaaS プロジェクト: ${PROJECT}"

if ask "デフォルトプロジェクトを ${PROJECT} に設定しますか?"; then
  gcloud config set project "${PROJECT}"
fi

if ask "ADC のクォータプロジェクトを ${PROJECT} に合わせますか?"; then
  gcloud auth application-default set-quota-project "${PROJECT}"
fi

echo
echo "初回認証・プロジェクト設定が完了しました。"
echo "次のステップ: make bootstrap → make github-secrets → (tenants 編集) → make deploy"
echo "環境確認は 'make check' で行えます。"
