# 顧客プロジェクトごとにGCSバケットを作成
resource "google_storage_bucket" "customer_reports" {
  for_each = var.tenants

  # バケット名は世界一意である必要があるため、プレフィックスにプロジェクトIDとランダムな接尾辞を組み合わせる（63文字制限に注意）
  name          = "${each.value.gcs_bucket_prefix}-${each.value.customer_project_id}-${random_string.suffix[each.key].result}"
  project       = each.value.customer_project_id
  location      = var.region
  force_destroy = false # 削除時に中身があっても強制削除しない（安全のため）

  uniform_bucket_level_access = true

  # 30日経過したレポートは自動削除する（コスト最適化）
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

# バケット用のランダムな接尾辞
resource "random_string" "suffix" {
  for_each = var.tenants
  length  = 4
  special = false
  upper   = false
}

# 作成したバケットに対してサービスアカウントに権限を付与
resource "google_storage_bucket_iam_member" "sa_bucket_access" {
  for_each = var.tenants

  bucket = google_storage_bucket.customer_reports[each.key].name
  role   = "roles/storage.objectAdmin" # 書き込み・読み取り両方
  member = "serviceAccount:${google_service_account.analyzer_sa.email}"
}