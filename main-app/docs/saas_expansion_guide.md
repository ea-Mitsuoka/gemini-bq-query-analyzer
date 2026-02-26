# SaaS展開に向けたアーキテクチャ拡張ガイド（マルチテナント対応）

本ドキュメントでは、Gemini Query Analyzerを単一顧客向けから**複数顧客向けのSaaSサービス**としてスケールさせるための設計変更、およびスプレッドシートを用いた顧客プロビジョニングの自動化手順について記載します。

## 1. アーキテクチャの変更方針

現在の構成（1顧客＝1デプロイ）から、以下のような**スプレッドシート駆動のマルチテナント構成**へ移行します。

1. **設定の中央管理**: Google スプレッドシートを「顧客マスタ」とし、各顧客のプロジェクトIDやSlack通知先、スケジュール設定を行ごとに管理する。
2. **IaCの動的生成**: Pythonスクリプトでスプレッドシートを読み込み、Terraformの変数ファイル（`terraform.tfvars`）を自動生成する。
3. **並列プロビジョニング**: Terraformの `for_each` 構文を利用し、1回の `terraform apply` で全顧客分のCloud Run JobとCloud Schedulerを一括デプロイ（差分更新）する。

---

## 2. スプレッドシート連携の事前準備 (GCP設定)

Pythonスクリプトからスプレッドシートのデータを自動取得するために、GCP側でAPIの有効化と認証キーの発行を行います。作業はSaaS基盤側プロジェクト（`SAAS_PROJECT_ID`）で実施します。

### 2-1. 必要なAPIの有効化

GCPコンソール、または以下のgcloudコマンドでAPIを有効にします。

```bash
gcloud services enable sheets.googleapis.com drive.googleapis.com

```

### 2-2. スプレッドシート読み取り用サービスアカウントの作成と鍵発行

1. GCPコンソールの **[IAMと管理] > [サービスアカウント]** に移動します。
2. **[サービスアカウントを作成]** をクリックし、任意の名前（例: `sheets-reader-sa`）を付けて作成します（ロールの付与は不要です）。
3. 作成したサービスアカウントの行をクリックし、**[キー]** タブを開きます。
4. **[鍵を追加] > [新しい鍵を作成]** を選択し、**JSON** 形式でダウンロードします。
5. ダウンロードしたJSONファイルは `credentials.json` にリネームし、自動生成スクリプトと同じディレクトリ（例: `scripts/`）に配置します。
> ⚠️ **注意**: このJSONファイルは非常に強い権限を持つため、**必ず `.gitignore` に追加**し、絶対にGitリポジトリにコミットしないでください。



### 2-3. スプレッドシートの共有設定

1. 顧客管理用のGoogle スプレッドシートを新規作成します。
2. 画面右上の **[共有]** ボタンをクリックします。
3. 共有先に、先ほど作成した**サービスアカウントのメールアドレス**（例: `sheets-reader-sa@your-project.iam.gserviceaccount.com`）を入力し、「閲覧者」権限を付与して保存します。
これにより、Pythonスクリプトがこのシートにアクセスできるようになります。

---

## 3. 自動生成スクリプトの実装 (`scripts/generate_tfvars.py`)

スプレッドシートからデータを取得し、Terraform用の変数ファイルを生成するPythonスクリプトです。
実行には `gspread` と `oauth2client` のインストールが必要です（`pip install gspread oauth2client`）。

```python
import gspread
from oauth2client.service_account import ServiceAccountCredentials
import os

# 1. スプレッドシートの認証設定
SCOPE = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
CREDS_PATH = os.path.join(os.path.dirname(__file__), 'credentials.json')
CREDS = ServiceAccountCredentials.from_json_keyfile_name(CREDS_PATH, SCOPE)
client = gspread.authorize(CREDS)

# 2. シートの読み込み（スプレッドシート名とシート名を指定）
SPREADSHEET_NAME = 'Gemini_Analyzer_Customers'
sheet = client.open(SPREADSHEET_NAME).sheet1
records = sheet.get_all_records()

# 3. tfvarsの文字列を構築
tfvars_content = "customers = {\n"

for row in records:
    # enable_terraform_deploy が TRUE の顧客だけを抽出
    if str(row.get('enable_terraform_deploy', '')).upper() in ['TRUE', '1']:
        customer_name = row['対象の顧客名']
        
        tfvars_content += f'  "{customer_name}" = {{\n'
        tfvars_content += f'    customer_project_id = "{row["customer_project_id"]}"\n'
        tfvars_content += f'    slack_webhook_url   = "{row["slack_webhook_url"]}"\n'
        tfvars_content += f'    gcs_bucket_name     = "{row["gcs_bucket_name"]}"\n'
        tfvars_content += f'    worst_query_limit   = "{row["worst_query_limit"]}"\n'
        tfvars_content += f'    time_interval       = "{row["time_interval"]}"\n'
        tfvars_content += f'    schedule_cron       = "{row["schedule_cron"]}"\n'
        tfvars_content += f'    schedule_timezone   = "{row["schedule_timezone"]}"\n'
        tfvars_content += '  }\n'

tfvars_content += "}\n"

# 4. terraform/terraform.tfvars に書き出し
output_path = os.path.join(os.path.dirname(__file__), '../terraform/terraform.tfvars')
with open(output_path, 'w', encoding='utf-8') as f:
    f.write(tfvars_content)

print("✅ terraform.tfvars has been generated successfully!")

```

---

## 4. Terraform側の変更点

単一の変数から、複数の顧客設定をまとめて受け取る構造（`map`）に変更します。

### 4-1. `variables.tf`

```hcl
variable "saas_project_id" { type = string }
variable "region" { type = string, default = "us-central1" }
variable "bq_antipattern_analyzer_url" { type = string }

# 顧客のリストを受け取る変数
variable "customers" {
  description = "スプレッドシートから自動生成される顧客設定マップ"
  type = map(object({
    customer_project_id = string
    slack_webhook_url   = string
    gcs_bucket_name     = string
    worst_query_limit   = string
    time_interval       = string
    schedule_cron       = string
    schedule_timezone   = string
  }))
}

```

### 4-2. `cloud_run.tf` (一部抜粋)

`for_each` を使用して、顧客の数だけリソースをループ生成します。

```hcl
resource "google_cloud_run_v2_job" "analyzer_job" {
  for_each = var.customers

  # リソース名に顧客名を付与して一意にする
  name     = "gemini-analyzer-job-${each.key}"
  location = var.region
  project  = var.saas_project_id

  template {
    template {
      service_account = google_service_account.analyzer_sa.email
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"
        
        env { name = "SAAS_PROJECT_ID", value = var.saas_project_id }
        env { name = "BQ_ANTIPATTERN_ANALYZER_URL", value = var.bq_antipattern_analyzer_url }
        # 顧客固有の設定を注入
        env { name = "CUSTOMER_PROJECT_ID", value = each.value.customer_project_id }
        env { name = "SLACK_WEBHOOK_URL", value = each.value.slack_webhook_url }
        env { name = "GCS_BUCKET_NAME", value = each.value.gcs_bucket_name }
        env { name = "WORST_QUERY_LIMIT", value = each.value.worst_query_limit }
        env { name = "TIME_RANGE_INTERVAL", value = each.value.time_interval }
      }
    }
  }
}

```

---

## 5. SaaS展開における運用上の注意点

マルチテナント化を進める上で、以下の点に注意して運用・設計を行ってください。

1. **顧客側プロジェクトへのIAM権限付与フローの確立**
SaaS側のサービスアカウント（`gemini-analyzer-sa`）が、各顧客のプロジェクトのBigQuery情報を読み取る必要があります。新規顧客追加時は、顧客側のシステム管理者に「SaaS側SAに対して指定のIAMロールを付与してもらう作業」を必ず案内するオンボーディングプロセスが必要です。
2. **GCPクォータ（上限）の管理**
Cloud Run JobやCloud Schedulerには、リージョンあたりの作成上限（クォータ）が存在します。顧客数が数十〜数百規模になる場合は、GCPコンソールから事前に上限緩和申請を行うか、複数のSaaSプロジェクトへ分散させる設計を検討してください。
3. **Terraform Stateファイルの遠隔管理（必須）**
顧客インフラの一括管理を安全に行うため、Terraformの `.tfstate` ファイルはローカルに置かず、必ず **GCS（Google Cloud Storage）バックエンド** に保存するように `main.tf` を構成してください。
4. **APIレートリミットへの配慮**
全顧客のCloud Schedulerが「毎日朝9:00」など全く同じ時間に発火すると、Gemini APIやSaaS側のBigQuery（マスター辞書読み込み）へのリクエストがスパイクし、レートリミット（429エラー）に引っかかる恐れがあります。顧客ごとにスケジュールを数分ずつずらす等の工夫を推奨します。