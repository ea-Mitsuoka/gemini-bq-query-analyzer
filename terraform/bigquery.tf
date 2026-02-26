# データセットの作成
resource "google_bigquery_dataset" "audit_master" {
  dataset_id  = "audit_master"
  project     = var.saas_project_id
  location    = var.region
  description = "Dataset for Gemini Query Analyzer Master Data"

  depends_on = [google_project_service.saas_apis]
}

# SQLファイルを読み込んで初期テーブル作成とデータ投入を実行
resource "google_bigquery_job" "init_master_data" {
  # 実行ID（変更すると再実行されます）
  job_id   = "init_antipattern_master_v1" 
  project  = var.saas_project_id
  location = var.region

  query {
    # 既存のSQLファイルを読み込んで実行
    query          = file("${path.module}/../sql/antipattern-list.sql")
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_dataset.audit_master]
}
