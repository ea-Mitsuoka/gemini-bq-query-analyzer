resource "google_cloud_run_v2_service" "antipattern_api" {
  name     = "bq-antipattern-api"
  location = var.region
  project  = var.saas_project_id

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello:latest"
      resources {
        limits = {
          cpu    = "1000m"
          memory = "1024Mi" # Javaを動かすため 1Gi を指定
        }
      }
    }
    service_account = google_service_account.analyzer_sa.email # 共通SAを使用
  }

  # ライフサイクル管理（イメージ更新をTerraformが上書きしないようにする）
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image
    ]
  }
}