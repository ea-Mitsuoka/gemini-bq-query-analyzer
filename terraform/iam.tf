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
    "roles/logging.logWriter",
    "roles/storage.objectViewer"
  ]
}

resource "google_project_iam_member" "saas_permissions" {
  for_each = toset(local.saas_roles)
  project  = var.saas_project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.analyzer_sa.email}"

  depends_on = [google_service_account.analyzer_sa]
}

# 4. 顧客プロジェクト側への権限付与（動的）
# 各テナントのプロジェクトIDとロールの組み合わせを生成
locals {
  customer_roles = [
    "roles/bigquery.metadataViewer",
    "roles/bigquery.resourceViewer",
  ]

  # テナントとロールの組み合わせをフラットなリストに変換
  tenant_role_pairs = flatten([
    for tenant_key, tenant_val in var.tenants : [
      for role in local.customer_roles : {
        project = tenant_val.customer_project_id
        role    = role
        key     = "${tenant_val.customer_project_id}-${role}"
      }
    ]
  ])
}

resource "google_project_iam_member" "customer_permissions" {
  for_each = { for pair in local.tenant_role_pairs : pair.key => pair }

  project = each.value.project
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.analyzer_sa.email}"

  depends_on = [google_service_account.analyzer_sa]
}