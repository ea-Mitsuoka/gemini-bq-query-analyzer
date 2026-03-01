variable "saas_project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "bq_antipattern_api_url" {
  type = string
}

variable "service_account_id" {
  default = "gemini-bq-query-analyzer-sa"
}

variable "bq_dataset_id" {
  default = "audit_master"
}

variable "tenants" {
  type = map(object({
    customer_project_id = string
    worst_query_limit   = string
    time_range_interval = string
    gcs_bucket_prefix   = string
    slack_webhook_url   = string
    scheduler_cron      = string
  }))
  default = {
    "default_tenant" = { # ← ここに任意のキーが必要です
      customer_project_id = ""
      worst_query_limit   = "1"
      time_range_interval = "1 DAY"
      gcs_bucket_prefix   = "gemini-bq-query-analyzer-reports"
      slack_webhook_url   = ""
      scheduler_cron      = "0 9 * * *"
    }
  }
}
