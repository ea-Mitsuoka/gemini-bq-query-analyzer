locals {
  services = [
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com"
  ]
}

resource "google_project_service" "saas_apis" {
  for_each           = toset(local.services)
  project            = var.saas_project_id
  service            = each.key
  disable_on_destroy = false
}
