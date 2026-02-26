# 2. サービスアカウントの作成
resource "google_service_account" "analyzer_sa" {
  account_id   = "gemini-analyzer-sa"
  display_name = "Gemini Query Analyzer Service Account"
  project      = var.saas_project_id
}

# 3. SaaSプロジェクト側への権限付与
locals {
  saas_roles = [
    "roles/aiplatform.user",
    "roles/run.invoker",
    "roles/bigquery.jobUser",
    "roles/bigquery.dataViewer",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter"
  ]
}

resource "google_project_iam_member" "saas_permissions" {
  for_each = toset(local.saas_roles)
  project  = var.saas_project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.analyzer_sa.email}"
}

# 4. 顧客プロジェクト側への権限付与
locals {
  customer_roles = [
    "roles/bigquery.metadataViewer",
    "roles/bigquery.resourceViewer",
    "roles/storage.objectCreator"
  ]
}

resource "google_project_iam_member" "customer_permissions" {
  for_each = toset(local.customer_roles)
  project  = var.customer_project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.analyzer_sa.email}"
}
