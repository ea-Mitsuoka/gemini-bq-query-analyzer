resource "google_cloud_run_v2_job" "analyzer_job" {
  name     = "gemini-analyzer-job"
  location = var.region
  project  = var.saas_project_id

  template {
    template {
      service_account = google_service_account.analyzer_sa.email
      timeout         = "600s"

      containers {
        # 初回構築用のプレースホルダー画像。実際のアプリデプロイはソースコードから行います。
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"

        resources {
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }

        # 環境変数の注入
        env {
          name  = "SAAS_PROJECT_ID"
          value = var.saas_project_id
        }
        env {
          name  = "CUSTOMER_PROJECT_ID"
          value = var.customer_project_id
        }
        env {
          name  = google_cloud_run_v2_service.antipattern_api.uri
          value = var.bq_antipattern_analyzer_url
        }
        env {
          name  = "SLACK_WEBHOOK_URL"
          value = var.slack_webhook_url
        }
        env {
          name  = "GCS_BUCKET_NAME"
          value = var.gcs_bucket_name
        }
        env {
          name  = "TIME_RANGE_INTERVAL"
          value = var.time_range_interval
        }
        env {
          name  = "WORST_QUERY_LIMIT"
          value = var.worst_query_limit
        }
      }
    }
  }

  lifecycle {
    # アプリのデプロイによってコンテナイメージが書き換わっても、Terraformで上書きして元に戻さないようにする
    ignore_changes = [
      template[0].template[0].containers[0].image
    ]
  }

  depends_on = [google_project_service.saas_apis]
}

# (おまけ) READMEにあった定期実行スケジューラもコード化
resource "google_cloud_scheduler_job" "daily_analyzer_trigger" {
  name        = "daily-analyzer-trigger"
  description = "Trigger Gemini Query Analyzer Job daily"
  schedule    = var.scheduler_cron
  time_zone   = "Asia/Tokyo"
  project     = var.saas_project_id
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.saas_project_id}/jobs/${google_cloud_run_v2_job.analyzer_job.name}:run"

    oauth_token {
      service_account_email = google_service_account.analyzer_sa.email
    }
  }

  depends_on = [google_project_service.saas_apis]
}
