# 1. データセットの作成
# Terraformリソースとして管理することで、削除や場所の変更を追跡可能にします
resource "google_bigquery_dataset" "audit_master" {
  dataset_id  = var.bq_dataset_id
  project     = var.saas_project_id
  location    = var.region
  description = "Dataset for Gemini Query Analyzer Master Data"

  # APIが有効化された後に作成を開始します
  depends_on = [terraform_data.api_completion]
}

# 2. 外部SQLファイル(DDL/DML)の実行
# このリソースはSQLファイルに変更があった場合のみ再実行されます
resource "null_resource" "setup_master_data" {
  triggers = {
    # SQLファイルの内容が変わったことを検知します
    sql_hash = sha256(file("${path.module}/../main-app/sql/antipattern-list.sql"))
  }

  provisioner "local-exec" {
    # SQL内のプレースホルダーを置換して bq コマンドに渡します
    # これにより、手動で SQL を実行する際と同じ手順を Terraform が再現します
    command = <<EOT
      sed "s/<saas_project_id>/${var.saas_project_id}/g" ../main-app/sql/antipattern-list.sql | bq query --use_legacy_sql=false --project_id=${var.saas_project_id}
    EOT
  }

  # データセットが存在しないとテーブル作成に失敗するため、明示的に依存させます
  depends_on = [google_bigquery_dataset.audit_master]
}
