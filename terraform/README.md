# `terraform` による環境構築手順

## 1. 前提条件

* jarファイルの準備
* .envファイルの設定
* `gcloud auth login`
* terraform 実行者のアカウントに必要なロール(要検証)

1. PROJECT:
   1. SAAS_PROJECT
      1. IAMロール:(編集者またはオーナーが早い)
         1. Project IAM 管理者`roles/resourcemanager.projectIamAdmin`(IAMロールを付与する権限)
         2. Service Usage Admin`roles/serviceusage.serviceUsageAdmin`(APIを有効化)
         3. Cloud Build 編集者`roles/cloudbuild.builds.editor`(Cloud Build を実行する権限)
         4. Artifact Registry 管理者`roles/artifactregistry.admin`(Dockerリポジトリの作成および削除)
         5. サービス アカウント 管理者`roles/iam.serviceAccountAdmin`(サービスアカウント作成および削除)
         6. Storage 管理者`roles/storage.Admin`(tfstateファイルを格納するBackendバケット作成)
         7. BigQuery データ管理者`roles/bigquery.dataOwner`(BigQueryのデータセットとテーブルを作成および削除)
         8. BigQuery ジョブユーザー`roles/bigquery.jobUser`(BigQueryのテーブル読み取り,DDL実行)
         9. Cloud Scheduler 管理者`roles/cloudscheduler.admin`(ジョブの作成および削除)
         10. Workflows 編集者`roles/workflows.editor`(workflowの作成および削除)
         11. Cloud Run 開発者`roles/run.developer`(Cloud Runサービスやジョブの作成および削除)
         12. ログ書き込み`roles/logging.logWriter`(ログエントリ作成)
   2. CUTOMER_PROJECT
      1. IAMロール:
         1. Project IAM 管理者`roles/resourcemanager.projectIamAdmin`(IAMロールを付与する権限)
         2. Storage 管理者`roles/storage.Admin`(分析結果ファイルを格納するバケット作成および削除)

## 2. 環境構築

### 2-1. BigQuery Antipattern Recognitionツールの準備

* [Github](https://github.com/GoogleCloudPlatform/bigquery-antipattern-recognition/releases)から`bigquery-antipattern-recognition.jar`をダウンロード
* `bq-antipattern-api/`に`bigquery-antipattern-recognition.jar`を配置

### 2-2. `.env`ファイルを設定

例:

```bash
# ==========================================
# 共通設定 (SaaS 基盤側)
# ==========================================
SAAS_PROJECT_ID="saas_project-id"
REGION="us-central1"
# terraformが動的に取得するため不要↓
# BQ_ANTIPATTERN_API_URL=https://bq-antipattern-api-<saas_project_number>.<region>.run.app

# ==========================================
# マルチテナント設定 (JSON 形式)
# ==========================================
# 💡 顧客が増える場合は、この JSON 内に要素を追加してください。
# ※ シングルクォーテーションで囲むことで、内部のダブルクォーテーションを許容します。
TENANTS_JSON='{
  "tenant1": {
    "customer_project_id": "tenant1_project_id",
    "worst_query_limit": "1",
    "time_range_interval": "1 DAY",
    "gcs_bucket_prefix": "gemini-query-analyzer-reports",
    "slack_webhook_url": "https://hooks.slack.com/services/xxx/yyy/zzz",
    "scheduler_cron": "0 9 * * *"
  },
  "tenant2": {
    "customer_project_id": "tenant2_project_id",
    "worst_query_limit": "1",
    "time_range_interval": "2 DAY",
    "gcs_bucket_prefix": "gemini-query-analyzer-reports",
    "slack_webhook_url": "https://hooks.slack.com/services/xxx/yyy/zzz",
    "scheduler_cron": "0 10 * * *"
  }
}'
```

### 2-3. tfvarsファイルの作成

`tools/`で`generate_tfvars.py`を実行

### 2-4. gcloudで認証

Terraformを実行する環境（PCやCI/CD）でコマンドを実行

```bash
gcloud auth login
gcloud auth application-default login
```

### 2-2. terraform apply

```bash
cd terraform
terraform apply
```

## 🚀 この構成のメリット

* **完全自動化**: `terraform apply` を叩くだけで、ソースコードのアップロード、ビルド、イメージ作成、Cloud Runへの反映が一気通貫で行われます。
* **賢い再ビルド**: `sha256` によるトリガーを設定したため、`app.py` や JAR ファイルを書き換えたときだけビルドが走り、変更がないときはスキップされるので高速です。

## 環境破棄

* `terraform destroy`を成功させるには、事前に以下の２点を済ませておく必要がある
  * 顧客プロジェクトのバケットの中身を空にする
  * SaaSプロジェクトのmasterテーブルを削除(`bq rm -r -f -d <saas_project_id>:audit_master`)する
