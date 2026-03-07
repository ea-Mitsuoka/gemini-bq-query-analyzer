# ローカルソースをアーカイブしてCloud Buildでビルドするリソースの例
resource "null_resource" "build_api_image" {
  # ソースコードやJARファイルが変更されたら再実行
  triggers = {
    src_hash = sha256(file("${path.module}/../bq-antipattern-api/app.py"))
    docker_hash = sha256(file("${path.module}/../bq-antipattern-api/Dockerfile"))
  }

  provisioner "local-exec" {
    command = <<EOT
      # 1. GCSからローカルのディレクトリにJARファイルをダウンロード
      gcloud storage cp gs://bigquery-antipattern-recognition-for-bq-analyzer-api-9klp/bigquery-antipattern-recognition.jar ../bq-antipattern-api/

      # 2. ダウンロードしたJARを含めてCloud Buildでビルド
      gcloud builds submit ../bq-antipattern-api \
        --tag ${var.region}-docker.pkg.dev/${var.saas_project_id}/cloud-run-source-deploy/bq-antipattern-api:latest \
        --project ${var.saas_project_id}
    EOT
  }

  # 1. APIが有効であること + 2. リポジトリが存在すること の両方を条件にする
  depends_on = [
    terraform_data.api_completion,
    google_artifact_registry_repository.cloud_run_source_deploy
  ]
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
      image = "${var.region}-docker.pkg.dev/${var.saas_project_id}/cloud-run-source-deploy/bq-antipattern-api:latest"
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
