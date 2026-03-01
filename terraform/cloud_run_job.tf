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
        image = "${var.region}-docker.pkg.dev/${var.saas_project_id}/cloud-run-source-deploy/gemini-bq-query-analyzer-job:latest"

        env {
          name  = "SOURCE_CODE_HASH"
          value = null_resource.build_main_app_image.triggers.src_hash
        }

        # 共通環境変数
        env {
          name  = "SAAS_PROJECT_ID"
          value = var.saas_project_id
        }
        env {
          name  = "BQ_ANTIPATTERN_ANALYZER_URL"
          value = google_cloud_run_v2_service.antipattern_api.uri
        }

        # 以下の環境変数は Workflow 実行時の Overrides によって動的に決定されるが、
        # 定義自体は必要なのでプレースホルダーを置いておく
        env {
          name  = "CUSTOMER_PROJECT_ID"
          value = ""
        }
        env {
          name  = "GCS_BUCKET_NAME"
          value = ""
        }
        env {
          name  = "TIME_RANGE_INTERVAL"
          value = ""
        }
        env {
          name  = "WORST_QUERY_LIMIT"
          value = ""
        }
        # Slack通知はWorkflowが行うため、Job側のSLACK_WEBHOOK_URLは不要になります
      }
    }
  }
  depends_on = [time_sleep.wait_30_seconds_after_build]
}

# main-app のビルド（共通）
resource "null_resource" "build_main_app_image" {
  triggers = {
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
