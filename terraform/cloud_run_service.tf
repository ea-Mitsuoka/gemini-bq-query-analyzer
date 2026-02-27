
# ローカルソースをアーカイブしてCloud Buildでビルドするリソースの例
resource "null_resource" "build_api_image" {
  # ソースコードやJARファイルが変更されたら再実行
  triggers = {
    src_hash = sha256(file("${path.module}/../bq-antipattern-api/app.py"))
    jar_hash = filesha256("${path.module}/../bq-antipattern-api/bigquery-antipattern-recognition.jar")
  }

  provisioner "local-exec" {
    command = <<EOT
      gcloud builds submit ../bq-antipattern-api \
        --tag gcr.io/${var.saas_project_id}/bq-antipattern-api:latest \
        --project ${var.saas_project_id}
    EOT
  }
  # APIが有効になってからビルドを開始する
  depends_on = [terraform_data.api_completion]
}

# Cloud Buildを利用してローカルソースからイメージをビルド・デプロイする構成
resource "google_cloud_run_v2_service" "antipattern_api" {
  name     = "bq-antipattern-api"
  location = var.region
  project  = var.saas_project_id

  template {
    containers {
      # ビルドされたイメージ名を指定（プロジェクト内のArtifact Registry等を参照）
      # ここではビルド後に生成されるパスを動的に指定するか、
      # 簡略化のためCloud Buildの結果を受け取る構成にします
      image = "gcr.io/${var.saas_project_id}/bq-antipattern-api:latest"

      resources {
        limits = {
          cpu    = "1000m"
          memory = "1024Mi"
        }
      }
    }
    service_account = google_service_account.analyzer_sa.email
  }
  # ビルドが終わってからサービスを作成・更新する
  depends_on = [null_resource.build_api_image]
}
