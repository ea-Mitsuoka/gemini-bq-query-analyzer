# 2. サービスアカウントの作成（共通）
resource "google_service_account" "analyzer_sa" {
  account_id   = var.service_account_id
  display_name = "Gemini Query Analyzer Service Account"
  project      = var.saas_project_id

  depends_on = [terraform_data.api_completion]
}

# 3. SaaSプロジェクト側への権限付与（共通）
locals {
  saas_roles = [
    "roles/aiplatform.user",
    "roles/bigquery.jobUser",
    "roles/bigquery.dataViewer",
    "roles/workflows.invoker",
    "roles/run.developer",
    "roles/logging.logWriter"
  ]
}

resource "google_project_iam_member" "saas_permissions" {
  for_each = toset(local.saas_roles)
  project  = var.saas_project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.analyzer_sa.email}"

  depends_on = [google_service_account.analyzer_sa]
}
