locals {
  services = [
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
    "workflows.googleapis.com"
  ]
}

resource "google_project_service" "saas_services" {
  for_each = toset(local.services)
  project  = var.saas_project_id
  service  = each.value

  disable_on_destroy = false
}

# すべてのAPI有効化が完了したことを示すエンドポイント（他リソースのdepends_on用）
resource "terraform_data" "api_completion" {
  depends_on = [google_project_service.saas_services]
}