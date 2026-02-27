variable "saas_project_id" {
  type = string
}
variable "customer_project_id" {
  type = string
}
variable "region" {
  type    = string
  default = "us-central1"
}
variable "bq_antipattern_analyzer_url" {
  type = string
}
variable "slack_webhook_url" {
  type = string
}
variable "gcs_bucket_name" {
  type = string
}
variable "time_range_interval" {
  type    = string
  default = "1 DAY"
}
variable "worst_query_limit" {
  type    = string
  default = "2"
}
variable "scheduler_cron" {
  default = "0 9 * * *"
}
variable "service_account_id" {
  default = "gemini-bq-query-analyzer-sa"
}
variable "bq_dataset_id" {
  default = "audit_master"
}