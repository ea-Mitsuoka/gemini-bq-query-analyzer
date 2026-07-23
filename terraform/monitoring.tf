# 失敗通知（社内運用向け）
# Workflow が失敗時に出す構造化ログ「ANALYZER_FAILURE ...」を Cloud Logging で検知し、
# Email 通知チャネル（Slackチャンネルの Integration メール等）へ送る。
# alert_notification_email が空の場合は何も作らない（＝通知を使わない構成も可）。

locals {
  enable_alerting = var.alert_notification_email != ""
}

resource "google_monitoring_notification_channel" "failure_email" {
  count        = local.enable_alerting ? 1 : 0
  project      = var.saas_project_id
  display_name = "gemini-bq-query-analyzer failure notifications"
  type         = "email"
  labels = {
    email_address = var.alert_notification_email
  }

  depends_on = [terraform_data.api_completion]
}

resource "google_monitoring_alert_policy" "analyzer_failure" {
  count        = local.enable_alerting ? 1 : 0
  project      = var.saas_project_id
  display_name = "gemini-bq-query-analyzer: pipeline failure"
  combiner     = "OR"

  # Workflow が出す ANALYZER_FAILURE ログにマッチ（tenant_id / error を含む）
  conditions {
    display_name = "Workflow ANALYZER_FAILURE log"
    condition_matched_log {
      filter = <<-EOT
        resource.type="workflows.googleapis.com/Workflow"
        "ANALYZER_FAILURE"
      EOT
    }
  }

  notification_channels = [google_monitoring_notification_channel.failure_email[0].id]

  # ログベース条件では通知レート制限が必須
  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
  }

  depends_on = [terraform_data.api_completion]
}
