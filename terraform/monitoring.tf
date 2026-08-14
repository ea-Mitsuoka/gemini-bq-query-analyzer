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

  # 通知の重要度。未設定だと件名が "[ALERT - No severity]" になり分類できない。
  severity = "ERROR"

  # Workflow が出す ANALYZER_FAILURE ログにマッチ（tenant_id / error を含む）
  conditions {
    display_name = "Workflow ANALYZER_FAILURE log"
    condition_matched_log {
      filter = <<-EOT
        resource.type="workflows.googleapis.com/Workflow"
        "ANALYZER_FAILURE"
      EOT

      # 通知本文にテナントを出すため、ログ本文から抽出してラベル化する。
      # これが無いと通知には Workflow のリソースラベルしか出ず、
      # マルチテナントで「どの顧客が失敗したか」が分からない。
      # 抽出式の文字列リテラルは \S 等のエスケープを解釈しないため、
      # バックスラッシュを使わない文字クラスで「次の空白まで」を表現する。
      label_extractors = {
        "tenant"   = "REGEXP_EXTRACT(textPayload, \"tenant=([^ ]+)\")"
        "customer" = "REGEXP_EXTRACT(textPayload, \"customer=([^ ]+)\")"
      }
    }
  }

  # 通知メールに表示される本文。$${...} は Terraform ではなく
  # Cloud Monitoring 側で展開される変数なので $ を重ねてエスケープする。
  documentation {
    subject   = "分析パイプライン失敗: テナント $${log.extracted_label.tenant}"
    mime_type = "text/markdown"
    content   = <<-EOT
      テナント **$${log.extracted_label.tenant}**（顧客プロジェクト: `$${log.extracted_label.customer}`）の分析パイプラインが失敗しました。

      調査手順:

      1. Cloud Logging で `ANALYZER_FAILURE` を検索し、`error=` の内容を確認する
      1. Cloud Run Job のログで復旧不能エラー（設定不備 / バケットアクセス不可 / SQL 読込失敗 / Gemini 全件失敗）を特定する
      1. `make check` で Gemini モデルの到達性を確認する
      1. 修正後に `make run TENANT=$${log.extracted_label.tenant}` で再実行する
    EOT
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
