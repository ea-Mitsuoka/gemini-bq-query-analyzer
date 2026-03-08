variable "saas_project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "api_jar_bucket_name" {
  type  = string
}

# 変更すると顧客プロジェクトに影響が出るため要注意.原則としてDefaultのままにすること.
variable "service_account_id" {
  default = "gemini-bq-query-analyzer-sa"
}

variable "bq_dataset_id" {
  default = "audit_master"
}

variable "tenants" {
  type = map(object({
    customer_project_id = string
    gcs_bucket_name     = string
    worst_query_limit   = string
    time_range_interval = string
    slack_webhook_secret_name   = string
    scheduler_cron      = string
  }))
  default = {
    "default_tenant" = { # ← ここに任意のキーが必要です
      customer_project_id = ""
      gcs_bucket_name     = ""
      worst_query_limit   = "1"
      time_range_interval = "1 DAY"
      slack_webhook_secret_name   = ""
      scheduler_cron      = "0 9 * * *"
    }
  }
}
