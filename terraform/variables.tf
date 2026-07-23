variable "saas_project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "api_jar_bucket_name" {
  type = string
}

# 失敗通知の宛先メール（Slackチャンネルの Integration メール等）。空なら通知アラートを作らない。
variable "alert_notification_email" {
  type    = string
  default = ""
}

# 変更すると顧客プロジェクトに影響が出るため要注意.原則としてDefaultのままにすること.
variable "service_account_id" {
  default = "gemini-bq-query-analyzer-sa"
}

variable "bq_dataset_id" {
  default = "audit_master"
}

# 削除保護フラグ。false の間は make destroy がゲートで拒否される。
# また BigQuery データセットは allow_destroy=true のときのみ中身ごと破棄を許可する。
# 破棄したい場合は true に変更して apply（make unlock）した上で destroy（make destroy）する。
variable "allow_destroy" {
  type    = bool
  default = false
}

variable "tenants" {
  type = map(object({
    customer_project_id       = string
    gcs_bucket_name           = string
    worst_query_limit         = string
    time_range_interval       = string
    slack_webhook_secret_name = string
    scheduler_cron            = string
  }))
  default = {
    "default_tenant" = { # ← ここに任意のキーが必要です
      customer_project_id       = ""
      gcs_bucket_name           = ""
      worst_query_limit         = "1"
      time_range_interval       = "1 DAY"
      slack_webhook_secret_name = ""
      scheduler_cron            = "0 9 * * *"
    }
  }
}
