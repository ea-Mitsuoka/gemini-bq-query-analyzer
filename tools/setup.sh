#!/usr/bin/env bash
# 初回にどうしても必須となる gcloud 認証・プロジェクト設定を対話形式で実行する。
# 重い IAM/WIF/バケット作成などの初回手順は README を参照。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f base_config.ini ]; then
  echo "エラー: base_config.ini が見つかりません。先に作成してください。"
  exit 1
fi

PROJECT=$(grep -E '^\s*saas_project_id' base_config.ini | head -1 | sed 's/.*=//' | tr -d ' ')
echo "対象 SaaS プロジェクト: ${PROJECT}"
echo

ask() { read -rp "$1 [y/N] " ans; [[ "${ans:-N}" =~ ^[Yy]$ ]]; }

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

if ask "デフォルトプロジェクトを ${PROJECT} に設定しますか?"; then
  gcloud config set project "${PROJECT}"
fi

if ask "ADC のクォータプロジェクトを ${PROJECT} に合わせますか?"; then
  gcloud auth application-default set-quota-project "${PROJECT}"
fi

echo
echo "初回必須の認証設定は完了です。"
echo "サービスアカウント作成・IAM 付与・WIF 設定などの初回手順は README を参照してください。"
echo "環境確認は 'make check' で行えます。"
