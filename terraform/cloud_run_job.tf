locals {
  main_app_dir = "${path.module}/../main-app"

  # main-app/Dockerfile の COPY 対象と対で維持すること（tests/test_tools.py が検査する）。
  # バイトコードはイメージに入れる意味がなく、実行環境で再生成されるため除外する。
  main_app_build_files = [
    for f in concat(
      ["Dockerfile", "requirements.txt"],
      [for f in fileset(local.main_app_dir, "src/**") : f],
      [for f in fileset(local.main_app_dir, "sql/**") : f],
      [for f in fileset(local.main_app_dir, "prompts/**") : f],
    ) : f if !can(regex("(^|/)__pycache__/", f)) && !endswith(f, ".pyc")
  ]
}

# ビルド完了後に30秒待つリソース
resource "time_sleep" "wait_30_seconds_after_build" {
  depends_on      = [null_resource.build_main_app_image]
  create_duration = "30s"
}

resource "google_cloud_run_v2_job" "analyzer_job" {
  name     = "gemini-bq-query-analyzer-job"
  location = var.region
  project  = var.saas_project_id

  # 誤削除の防止。make unlock（allow_destroy=true）でのみ削除可能にする。
  deletion_protection = !var.allow_destroy

  template {
    template {
      service_account = data.google_service_account.analyzer_sa.email
      timeout         = "600s"

      # 既定の 3 回だと、設定不備のような復旧不能エラーでも全リトライを消化してから
      # 失敗が確定し、通知が十数分遅れる（実測）。一時障害の救済は残しつつ短縮する。
      max_retries = 1

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
          name  = "BQ_ANTIPATTERN_API_URL"
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
        # Slack通知はWorkflowが行うため、Job側のslack_webhook_secret_nameは不要になります
      }
    }
  }
  depends_on = [time_sleep.wait_30_seconds_after_build]
}

# main-app のビルド（共通）
resource "null_resource" "build_main_app_image" {
  # 再ビルドは「イメージの中身が変わったとき」だけで良いので、Dockerfile が COPY する
  # ファイル群（＋Dockerfile 自身）だけをハッシュ対象にする。
  # main-app/** を丸ごと対象にすると、ローカルにしか無い docs/ の下書きや .venv、
  # テストが残す __pycache__ でもハッシュが変わり、CI とローカルで一致しない（実測）。
  triggers = {
    src_hash = sha256(join("", [
      for f in local.main_app_build_files : filesha256("${local.main_app_dir}/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<EOT
      gcloud builds submit ../main-app \
        --tag ${var.region}-docker.pkg.dev/${var.saas_project_id}/cloud-run-source-deploy/gemini-bq-query-analyzer-job:latest \
        --project ${var.saas_project_id}
    EOT
  }

  # 1. APIが有効であること + 2. リポジトリが存在すること の両方を条件にする
  depends_on = [
    terraform_data.api_completion,
    google_artifact_registry_repository.cloud_run_source_deploy
  ]
}
