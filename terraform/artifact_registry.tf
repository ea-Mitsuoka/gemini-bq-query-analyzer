resource "google_artifact_registry_repository" "cloud_run_source_deploy" {
  provider      = google
  project       = var.saas_project_id
  location      = var.region
  repository_id = "cloud-run-source-deploy"
  description   = "Repository for Cloud Run source deployments"
  format        = "DOCKER"

  depends_on = [terraform_data.api_completion] # APIが有効になった後に作成
}