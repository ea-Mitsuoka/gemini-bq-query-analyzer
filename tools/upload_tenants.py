"""
ローカルにダウンロードしたスプレッドシートを tenants.json に変換し GCS へアップロードする。

使用方法:
    python tools/upload_tenants.py <スプレッドシートファイルパス>

対応形式: CSV (.csv), Excel (.xlsx)

必要な列名（順不同）:
    tenant_id, customer_project_id, gcs_bucket_name,
    worst_query_limit, time_range_interval,
    slack_webhook_secret_name, scheduler_cron
"""
import configparser
import csv
import json
import sys
from pathlib import Path

from google.cloud import storage

BASE_DIR = Path(__file__).parent.parent
BASE_CONFIG_INI = BASE_DIR / "base_config.ini"
TENANTS_JSON_LOCAL = BASE_DIR / "tenants.json"
GCS_TENANTS_PATH = "config/tenants.json"

REQUIRED_COLUMNS = {
    "tenant_id",
    "customer_project_id",
    "gcs_bucket_name",
    "worst_query_limit",
    "time_range_interval",
    "slack_webhook_secret_name",
    "scheduler_cron",
}


def read_csv(filepath):
    with open(filepath, encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def read_xlsx(filepath):
    try:
        import openpyxl
    except ImportError:
        print("エラー: Excel形式を読み込むには openpyxl が必要です。")
        print("  pip install openpyxl")
        sys.exit(1)

    wb = openpyxl.load_workbook(filepath, read_only=True, data_only=True)
    ws = wb.active
    rows = list(ws.values)
    if not rows:
        return []

    headers = [str(h).strip() if h is not None else "" for h in rows[0]]
    result = []
    for row in rows[1:]:
        if all(cell is None for cell in row):
            continue
        result.append({
            headers[i]: (str(row[i]).strip() if row[i] is not None else "")
            for i in range(len(headers))
        })
    return result


def validate_columns(rows):
    if not rows:
        print("エラー: データ行が見つかりませんでした。")
        sys.exit(1)

    actual = set(rows[0].keys())
    missing = REQUIRED_COLUMNS - actual
    if missing:
        print(f"エラー: 必要な列が不足しています: {', '.join(sorted(missing))}")
        print(f"  検出された列: {', '.join(sorted(actual))}")
        sys.exit(1)


def rows_to_tenants(rows):
    tenants = {}
    for row in rows:
        tenant_id = row.get("tenant_id", "").strip()
        if not tenant_id:
            continue
        tenants[tenant_id] = {
            "customer_project_id":       row.get("customer_project_id", "").strip(),
            "gcs_bucket_name":           row.get("gcs_bucket_name", "").strip(),
            "worst_query_limit":         row.get("worst_query_limit", "1").strip(),
            "time_range_interval":       row.get("time_range_interval", "1 DAY").strip(),
            "slack_webhook_secret_name": row.get("slack_webhook_secret_name", "").strip(),
            "scheduler_cron":            row.get("scheduler_cron", "0 9 * * *").strip(),
        }
    return tenants


def main():
    if len(sys.argv) < 2:
        print("使用方法: python tools/upload_tenants.py <ファイルパス>")
        print("対応形式: .csv, .xlsx")
        sys.exit(1)

    filepath = Path(sys.argv[1])
    if not filepath.exists():
        print(f"エラー: ファイルが見つかりません: {filepath}")
        sys.exit(1)

    # base_config.ini からバケット名を取得
    config = configparser.ConfigParser()
    config.read(BASE_CONFIG_INI, encoding="utf-8")
    try:
        tfstate_bucket = config["gcp"]["tfstate_bucket_name"]
    except KeyError as e:
        print(f"エラー: base_config.ini の設定項目が不足しています: {e}")
        sys.exit(1)

    # ファイル読み込み
    suffix = filepath.suffix.lower()
    if suffix == ".csv":
        rows = read_csv(filepath)
    elif suffix in (".xlsx", ".xls"):
        rows = read_xlsx(filepath)
    else:
        print(f"エラー: 未対応のファイル形式です: {suffix}")
        sys.exit(1)

    validate_columns(rows)
    tenants = rows_to_tenants(rows)

    if not tenants:
        print("エラー: tenant_id が設定されている行が見つかりませんでした。")
        sys.exit(1)

    print(f"{len(tenants)} テナントを読み込みました: {list(tenants.keys())}")

    tenants_json = json.dumps(tenants, ensure_ascii=False, indent=2)

    # ローカルに保存（内容確認用）
    TENANTS_JSON_LOCAL.write_text(tenants_json, encoding="utf-8")
    print(f"ローカル保存: {TENANTS_JSON_LOCAL}")

    # GCS へアップロード
    blob = storage.Client().bucket(tfstate_bucket).blob(GCS_TENANTS_PATH)
    blob.upload_from_string(tenants_json, content_type="application/json")
    print(f"GCSアップロード完了: gs://{tfstate_bucket}/{GCS_TENANTS_PATH}")


if __name__ == "__main__":
    main()
