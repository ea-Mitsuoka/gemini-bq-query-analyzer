resource "google_workflows_workflow" "analyzer_workflow" {
  name            = "gemini-bq-query-analyzer-workflow"
  region          = var.region
  description     = "Orchestrates BQ Analysis Job and Slack Notification"
  service_account = google_service_account.analyzer_sa.id

  # 外部のYAMLファイルを読み込む
  source_contents = templatefile("${path.module}/../workflows/analyzer_workflow.yaml", {
    project_id   = var.saas_project_id
    region       = var.region
    job_name     = google_cloud_run_v2_job.analyzer_job.name
    # その他、Workflow内で使いたい変数を注入可能
  })

  # 明示的依存：APIの有効化とIAM付与が終わってから作成する
  depends_on = [
    terraform_data.api_completion,
    google_project_iam_member.saas_permissions
  ]
}