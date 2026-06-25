# Gemini BQ Query Analyzer - 運用タスク
#
# よく使う流れ:
#   make install     # ローカル環境構築（uv）
#   make setup       # 初回必須の gcloud 認証等（対話）
#   make check       # 環境が整っているか確認
#   make template    # テナント設定テンプレート生成 -> 編集 -> upload_tenants.py
#   make deploy      # backend準備 -> 設定生成 -> terraform init & apply（確認なし）
#
# 削除フロー:
#   make unlock      # 削除保護を解除（allow_destroy=true を apply）
#   make destroy     # terraform destroy
#   make lock        # 削除保護を再有効化

VENV    := .venv
PYTHON  := $(shell [ -x $(VENV)/bin/python ] && echo $(VENV)/bin/python || echo python3)
TF_DIR  := terraform
TF      := terraform
PROTECT_TFVARS := $(TF_DIR)/allow_destroy.auto.tfvars

# lint / 対象 Python パス
PY_SRC  := tools main-app/src bq-antipattern-api/app.py tests

.DEFAULT_GOAL := help

.PHONY: help install setup check template generate ensure-bucket ensure-bucket-dry-run \
        init lint test plan deploy unlock lock destroy clean

help:  ## このヘルプを表示
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

install:  ## uv でローカル環境を構築（.venv 作成 + 依存インストール）
	uv venv $(VENV)
	uv pip install --python $(VENV)/bin/python -r requirements.txt -r requirements-dev.txt

setup:  ## 初回必須の gcloud 認証・プロジェクト設定を対話形式で実行
	bash tools/setup.sh

check:  ## 環境が整っているか確認（gcloud/terraform/認証/API/バケット 等）
	bash tools/check.sh

template:  ## 空のテナント設定スプレッドシート(CSV/Excel)を生成
	$(PYTHON) tools/generate_template.py

generate:  ## base_config.ini と GCS の tenants.json から設定ファイル(tfvars等)を生成
	$(PYTHON) tools/generate_configs.py

ensure-bucket:  ## backend(tfstate)バケットを冪等に作成・堅牢化し権限付与
	$(PYTHON) tools/ensure_state_bucket.py

ensure-bucket-dry-run:  ## ensure-bucket の変更内容を確認のみ
	$(PYTHON) tools/ensure_state_bucket.py --dry-run

init: ensure-bucket generate  ## バケット準備 -> 設定生成 -> terraform init
	cd $(TF_DIR) && $(TF) init

lint:  ## Python(ruff) と Terraform(fmt) の lint
	$(PYTHON) -m ruff check $(PY_SRC)
	cd $(TF_DIR) && $(TF) fmt -check -recursive

test:  ## pytest 実行
	$(PYTHON) -m pytest

plan: init  ## terraform plan
	cd $(TF_DIR) && $(TF) plan

deploy: init  ## terraform apply（確認なし・多段でも一発）
	cd $(TF_DIR) && $(TF) apply -auto-approve

unlock:  ## 削除保護を解除（allow_destroy=true を書き込み apply）。実行後 make destroy 可能
	@echo 'allow_destroy = true' > $(PROTECT_TFVARS)
	@echo "allow_destroy=true を設定しました。保護解除を反映するため apply します..."
	$(MAKE) deploy
	@echo "削除保護を解除しました。'make destroy' が実行可能です。"

lock:  ## 削除保護を再有効化（allow_destroy=false を書き込み apply）
	@echo 'allow_destroy = false' > $(PROTECT_TFVARS)
	$(MAKE) deploy
	@echo "削除保護を再有効化しました。"

destroy:  ## terraform destroy（事前に make unlock が必要。保護中はゲートで拒否）
	@grep -q 'allow_destroy[[:space:]]*=[[:space:]]*true' $(PROTECT_TFVARS) 2>/dev/null \
		|| { echo "削除保護が有効です。先に 'make unlock' を実行してください。"; exit 1; }
	cd $(TF_DIR) && $(TF) destroy -auto-approve

clean:  ## 自動生成された設定ファイルを削除（tfstate / .venv は保持）
	rm -f env.txt tenants.json tenants_template.csv processed_workflow.yaml
	rm -f $(TF_DIR)/backend.tf $(TF_DIR)/terraform.tfvars
	@echo "生成ファイルを削除しました（tfstate / .venv / 削除保護設定は保持）。"
