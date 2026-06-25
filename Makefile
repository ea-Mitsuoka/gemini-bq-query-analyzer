# Gemini BQ Query Analyzer - 運用タスク
#
# 主なターゲット:
#   make ensure-bucket   backend(tfstate)バケットを冪等に用意し権限を付与
#   make generate        base_config.ini と GCS の tenants.json から設定ファイルを生成
#   make init            上記2つを実行してから terraform init
#   make plan / apply    init 後に terraform plan / apply

PYTHON      ?= python
TF_DIR      := terraform

.PHONY: ensure-bucket generate init plan apply

# backend バケットの作成・堅牢化・権限付与（state を持たない冪等処理）
ensure-bucket:
	$(PYTHON) tools/ensure_state_bucket.py

# 変更を加えず、何が起きるかだけ確認
ensure-bucket-dry-run:
	$(PYTHON) tools/ensure_state_bucket.py --dry-run

# backend.tf / terraform.tfvars / env.txt を生成（GCS の tenants.json が必要）
generate:
	$(PYTHON) tools/generate_configs.py

# バケット準備 -> 設定生成 -> terraform init
init: ensure-bucket generate
	cd $(TF_DIR) && terraform init

plan: init
	cd $(TF_DIR) && terraform plan

apply: init
	cd $(TF_DIR) && terraform apply
