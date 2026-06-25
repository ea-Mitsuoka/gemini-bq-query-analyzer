"""
tenants.json の元になる、空のテナント設定スプレッドシートを生成する。

生成したファイルを編集してから upload_tenants.py に渡すことで、
tenants.json への変換と GCS へのアップロードが行える。

使用方法:
    python tools/generate_template.py [出力パス]

出力形式は拡張子で自動判定する（未指定時は tenants_template.csv）:
    .csv  -> CSV テンプレート
    .xlsx -> Excel テンプレート（openpyxl が必要）

例:
    python tools/generate_template.py                       # ./tenants_template.csv
    python tools/generate_template.py ~/Downloads/t.xlsx    # Excel で出力
"""
import sys
import csv
from pathlib import Path

BASE_DIR = Path(__file__).parent.parent
DEFAULT_OUTPUT = BASE_DIR / "tenants_template.csv"

# 列の並び。upload_tenants.py の REQUIRED_COLUMNS と一致させること。
COLUMNS = [
    "tenant_id",
    "customer_project_id",
    "gcs_bucket_name",
    "worst_query_limit",
    "time_range_interval",
    "slack_webhook_secret_name",
    "scheduler_cron",
]

# 各列の説明（標準出力での案内用）。upload_tenants.py のデフォルト値も併記。
COLUMN_HELP = {
    "tenant_id":                 "テナント識別子（必須・キーになる）",
    "customer_project_id":       "顧客のGCPプロジェクトID",
    "gcs_bucket_name":           "レポート格納用バケット名（顧客側で事前作成）",
    "worst_query_limit":         "分析対象とするワーストクエリ数（空欄時の既定: 1）",
    "time_range_interval":       "分析対象期間（空欄時の既定: 1 DAY）",
    "slack_webhook_secret_name": "Secret Manager のSecret名（空欄でSlack通知無効）",
    "scheduler_cron":            "実行スケジュール（空欄時の既定: 0 9 * * *）",
}


def write_csv(filepath):
    with open(filepath, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(COLUMNS)


def write_xlsx(filepath):
    try:
        import openpyxl
    except ImportError:
        print("エラー: Excel形式を出力するには openpyxl が必要です。")
        print("  pip install openpyxl")
        sys.exit(1)

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "tenants"
    ws.append(COLUMNS)
    wb.save(filepath)


def main():
    filepath = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT

    if filepath.exists():
        print(f"エラー: 既にファイルが存在します（上書きしません）: {filepath}")
        sys.exit(1)

    suffix = filepath.suffix.lower()
    if suffix == ".csv":
        write_csv(filepath)
    elif suffix in (".xlsx", ".xls"):
        write_xlsx(filepath)
    else:
        print(f"エラー: 未対応のファイル形式です: {suffix}（.csv または .xlsx を指定）")
        sys.exit(1)

    print(f"テンプレートを生成しました: {filepath}")
    print("各列の意味:")
    for col in COLUMNS:
        print(f"  - {col}: {COLUMN_HELP[col]}")
    print("\n編集後、次のコマンドで tenants.json へ変換しGCSへアップロードできます:")
    print(f"  python tools/upload_tenants.py {filepath}")


if __name__ == "__main__":
    main()
