import os
import json
import configparser
from googleapiclient.discovery import build
from google.oauth2 import service_account

# 設定パスの定義
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE_CONFIG_INI = os.path.join(BASE_DIR, "base_config.ini")
ENV_PATH = os.path.join(BASE_DIR, ".env")
# terraformディレクトリが存在しない場合に備えて作成
TFVARS_DIR = os.path.join(BASE_DIR, "terraform")
TFVARS_PATH = os.path.join(TFVARS_DIR, "terraform.tfvars")

def main():
    # 1. base_config.ini (SaaS基盤共通設定) の読み込み
    if not os.path.exists(BASE_CONFIG_INI):
        print(f"エラー: {BASE_CONFIG_INI} が見つかりません。")
        return

    config = configparser.ConfigParser()
    config.read(BASE_CONFIG_INI, encoding='utf-8')

    try:
        saas_id = config['gcp']['saas_project_id']
        region = config['gcp']['region']
    except KeyError as e:
        print(f"エラー: base_config.ini の設定項目が不足しています: {e}")
        return

    # 2. 環境変数から認証情報とスプレッドシートIDを取得
    creds_json = os.getenv("GOOGLE_CREDENTIALS")
    spreadsheet_id = os.getenv("SPREADSHEET_ID")

    if not creds_json or not spreadsheet_id:
        print("エラー: 環境変数 (GOOGLE_CREDENTIALS または SPREADSHEET_ID) が未設定です。")
        return

    # スプレッドシートAPIの認証
    creds_info = json.loads(creds_json)
    creds = service_account.Credentials.from_service_account_info(
        creds_info,
        scopes=["https://www.googleapis.com/auth/spreadsheets.readonly"]
    )
    service = build("sheets", "v4", credentials=creds)

    # A2からG列までを取得 (ヘッダーを除外)
    # カラム順: tenant_id, customer_project_id, gcs_bucket_name, worst_query_limit, 
    #          time_range_interval, slack_webhook_secret_name, scheduler_cron
    range_name = "Sheet1!A2:G"
    try:
        result = service.spreadsheets().values().get(
            spreadsheetId=spreadsheet_id, range=range_name
        ).execute()
        rows = result.get("values", [])
    except Exception as e:
        print(f"エラー: スプレッドシートの取得に失敗しました: {e}")
        return

    tenants = {}
    for row in rows:
        # 必要なカラムが揃っていない行はスキップ
        if len(row) < 7:
            continue

        t_id = row[0]
        tenants[t_id] = {
            "customer_project_id":       row[1],
            "gcs_bucket_name":           row[2], # 顧客側で作成済みのバケット名
            "worst_query_limit":         row[3],
            "time_range_interval":       row[4],
            "slack_webhook_secret_name": row[5],
            "scheduler_cron":            row[6]
        }

    # 3. .env の書き出し (ローカルデプロイやログ確認用)
    with open(ENV_PATH, "w", encoding='utf-8') as f:
        f.write(f'SAAS_PROJECT_ID="{saas_id}"\n')
        f.write(f'REGION="{region}"\n')
        # JSON形式でテナント情報を1行にまとめる
        f.write(f"TENANTS_JSON='{json.dumps(tenants, ensure_ascii=False)}'\n")

    # 4. terraform.tfvars の書き出し
    if not os.path.exists(TFVARS_DIR):
        os.makedirs(TFVARS_DIR)

    with open(TFVARS_PATH, "w", encoding='utf-8') as f:
        f.write("# Generated from base_config.ini and Spreadsheet - DO NOT EDIT\n\n")
        f.write(f'saas_project_id = "{saas_id}"\n')
        f.write(f'region          = "{region}"\n\n')

        f.write("tenants = {\n")
        for tid, cfg in tenants.items():
            f.write(f'  "{tid}" = {{\n')
            # 各項目の書き出し
            for k, v in cfg.items():
                f.write(f'    {k:<25} = "{v}"\n')
            f.write("  }\n")
        f.write("}\n")

    print(f"完了: SaaSプロジェクト '{saas_id}' 用のコンフィグを生成しました。")
    print(f"処理テナント数: {len(tenants)}")

if __name__ == "__main__":
    main()