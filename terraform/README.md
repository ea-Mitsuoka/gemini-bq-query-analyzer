# `terraform apply` 成功させるための条件

このコードで全自動デプロイを完結させるための前提条件（チェックリスト）は以下の通りです：

1. **JARファイルが配置されていること**: `bq-antipattern-api/` 直下に `bigquery-antipattern-recognition.jar` が実在すること 。

2. **gcloudが認証済みであること**: Terraformを実行する環境（PCやCI/CD）で `gcloud auth login` が済んでおり、`saas_project_id` に対して Cloud Build を実行する権限があること。

3. **APIが有効であること**: `api.tf` で `cloudbuild.googleapis.com` が有効化されていること 。

4. **Artifact Registry / GCR の有効化**: プロジェクトで `containerregistry.googleapis.com` (GCR) または `artifactregistry.googleapis.com` が有効であること。

## 🚀 この構成のメリット

* **完全自動化**: `terraform apply` を叩くだけで、ソースコードのアップロード、ビルド、イメージ作成、Cloud Runへの反映が一気通貫で行われます。
* **賢い再ビルド**: `sha256` によるトリガーを設定したため、`app.py` や JAR ファイルを書き換えたときだけビルドが走り、変更がないときはスキップされるので高速です。
* **URLの自動連携**: `cloud_run_job.tf` 側で `value = google_cloud_run_v2_service.antipattern_api.uri` と記述していれば、ビルドされたAPIのURLが自動的にメインアプリに渡されます 。
