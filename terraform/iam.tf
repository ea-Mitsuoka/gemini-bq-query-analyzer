# 既にGCP上に存在するサービスアカウントを読み込む
data "google_service_account" "analyzer_sa" {
  account_id = var.service_account_id
  project    = var.saas_project_id
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
  member   = "serviceAccount:${data.google_service_account.analyzer_sa.email}"
}

# レポートの V4 署名付きURLを鍵レスで生成するため、SA が自身に対して
# signBlob できるようにする（roles/iam.serviceAccountTokenCreator）。
resource "google_service_account_iam_member" "analyzer_sa_token_creator" {
  service_account_id = data.google_service_account.analyzer_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${data.google_service_account.analyzer_sa.email}"
}
