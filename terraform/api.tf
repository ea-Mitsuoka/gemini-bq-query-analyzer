locals {
  services = [
    "sheets.googleapis.com",
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
    "workflows.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com"
  ]
}

resource "google_project_service" "saas_services" {
  for_each = toset(local.services)
  project  = var.saas_project_id
  service  = each.value

  # APIを利用しているリソースが存在する場合は削除されてしまうため、APIの無効化を禁止する設定を追加
  disable_on_destroy = false
}

# すべてのAPI有効化が完了したことを示すエンドポイント（他リソースのdepends_on用）
resource "terraform_data" "api_completion" {
  depends_on = [google_project_service.saas_services]
}
