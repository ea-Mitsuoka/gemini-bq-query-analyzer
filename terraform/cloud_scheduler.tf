resource "google_cloud_scheduler_job" "tenant_schedulers" {
  for_each = var.tenants

  name     = "gemini-bq-query-analyzer-scheduler-${each.key}"
  schedule = each.value.scheduler_cron
  project  = var.saas_project_id
  region   = var.region

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.saas_project_id}/locations/${var.region}/workflows/${google_workflows_workflow.analyzer_workflow.name}/executions"

    body = base64encode(jsonencode({
      argument = jsonencode({
        customer_id         = each.key
        customer_project_id = each.value.customer_project_id
        worst_query_limit   = each.value.worst_query_limit
        time_range_interval = each.value.time_range_interval
        gcs_bucket_name     = google_storage_bucket.customer_reports[each.key].name
        slack_webhook_url   = each.value.slack_webhook_url
      })
    }))

    oauth_token {
      service_account_email = google_service_account.analyzer_sa.email
    }
  }
}