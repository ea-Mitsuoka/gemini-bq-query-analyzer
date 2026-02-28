# ビルド完了後に30秒待つリソース
resource "time_sleep" "wait_30_seconds_after_build" {
  depends_on      = [null_resource.build_main_app_image]
  create_duration = "30s"
}

resource "google_cloud_run_v2_job" "analyzer_job" {
  name     = "gemini-bq-query-analyzer-job"
  location = var.region
  project  = var.saas_project_id

  template {
    template {
      service_account = google_service_account.analyzer_sa.email
      timeout         = "600s"

      containers {
        # ビルドした本物のイメージを指定
        image = "${var.region}-docker.pkg.dev/${var.saas_project_id}/cloud-run-source-deploy/gemini-bq-query-analyzer-job:latest"
        # 環境変数にハッシュ値を埋め込む
        # これにより、ファイルが変われば環境変数が変わり、Job の「更新」が検知されます
        env {
          name  = "SOURCE_CODE_HASH"
          value = null_resource.build_main_app_image.triggers.src_hash
        }
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
          name  = "BQ_ANTIPATTERN_ANALYZER_URL"
          value = google_cloud_run_v2_service.antipattern_api.uri
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
  # 修正: ビルド直後ではなく、待機が終わってから更新を開始させる
  depends_on = [time_sleep.wait_30_seconds_after_build]
}

# main-app のビルド
resource "null_resource" "build_main_app_image" {
  triggers = {
    # 関連ファイルの変更を検知
    src_hash = sha256(join("", [for f in fileset("${path.module}/../main-app", "**") : filesha256("${path.module}/../main-app/${f}")]))
  }

  provisioner "local-exec" {
    command = <<EOT
      gcloud builds submit ../main-app \
        --tag ${var.region}-docker.pkg.dev/${var.saas_project_id}/cloud-run-source-deploy/gemini-bq-query-analyzer-job:latest \
        --project ${var.saas_project_id}
    EOT
  }
  depends_on = [terraform_data.api_completion]
}

# # (おまけ) READMEにあった定期実行スケジューラもコード化
# resource "google_cloud_scheduler_job" "daily_analyzer_trigger" {
#   name        = "daily-analyzer-trigger"
#   description = "Trigger Gemini Query Analyzer Job daily"
#   schedule    = var.scheduler_cron
#   time_zone   = "Asia/Tokyo"
#   project     = var.saas_project_id
#   region      = var.region

#   http_target {
#     http_method = "POST"
#     uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.saas_project_id}/jobs/${google_cloud_run_v2_job.analyzer_job.name}:run"

#     oauth_token {
#       service_account_email = google_service_account.analyzer_sa.email
#     }
#   }

#   depends_on = [terraform_data.api_completion]
# }
