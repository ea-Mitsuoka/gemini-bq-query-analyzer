"""
Terraform backend 用の tfstate バケットを冪等に用意する（bootstrap自動化）。

base_config.ini の設定をもとに、
  1. バケットが無ければ作成し、堅牢化（versioning / UBLA / 公開アクセス防止）を適用
  2. デプロイ用サービスアカウントに、そのバケット個別の roles/storage.objectAdmin を付与
を行う。何度実行しても安全（既に存在・付与済みなら何もしない）。

backend 初期化より前（terraform init の直前）に毎回実行する想定。
このスクリプト自体は Terraform state を持たないため、再帰的な bootstrap 問題は発生しない。

使用方法:
    python tools/ensure_state_bucket.py [--dry-run]

デプロイ用SAは base_config.ini の [gcp] deployer_service_account、
または環境変数 DEPLOYER_SA で上書きできる（既定: terraform-deployer-sa@<saas>.iam.gserviceaccount.com）。
"""
import os
import sys
import configparser
from pathlib import Path

from google.cloud import storage
from google.api_core import exceptions as gcp_exceptions

BASE_DIR = Path(__file__).parent.parent
BASE_CONFIG_INI = BASE_DIR / "base_config.ini"

STATE_BUCKET_ROLE = "roles/storage.objectAdmin"
PUBLIC_ACCESS_PREVENTION = "enforced"


def load_config():
    if not BASE_CONFIG_INI.exists():
        print(f"エラー: {BASE_CONFIG_INI} が見つかりません。")
        sys.exit(1)

    config = configparser.ConfigParser()
    config.read(BASE_CONFIG_INI, encoding="utf-8")
    try:
        gcp = config["gcp"]
        saas_id = gcp["saas_project_id"]
        region = gcp["region"]
        bucket_name = gcp["tfstate_bucket_name"]
    except KeyError as e:
        print(f"エラー: base_config.ini の設定項目が不足しています: {e}")
        sys.exit(1)

    deployer_sa = (
        os.environ.get("DEPLOYER_SA")
        or config.get("gcp", "deployer_service_account", fallback="")
        or f"terraform-deployer-sa@{saas_id}.iam.gserviceaccount.com"
    )
    return saas_id, region, bucket_name, deployer_sa


def harden_bucket(bucket):
    """新規作成時の堅牢化設定を適用する。"""
    bucket.versioning_enabled = True
    bucket.iam_configuration.uniform_bucket_level_access_enabled = True
    bucket.iam_configuration.public_access_prevention = PUBLIC_ACCESS_PREVENTION
    bucket.patch()


def ensure_bucket(client, saas_id, region, bucket_name, dry_run):
    bucket = client.bucket(bucket_name)
    if bucket.exists():
        print(f"[bucket] 既に存在: gs://{bucket_name}（作成・堅牢化はスキップ）")
        return client.get_bucket(bucket_name)

    if dry_run:
        print(f"[bucket] (dry-run) 作成する: gs://{bucket_name} "
              f"(project={saas_id}, location={region}) + versioning/UBLA/PAP")
        return bucket

    try:
        bucket = client.create_bucket(bucket_name, project=saas_id, location=region)
    except gcp_exceptions.Conflict:
        # 並行実行などで先に作られた場合も成功扱い
        print(f"[bucket] 既に作成済み（競合）: gs://{bucket_name}")
        return client.get_bucket(bucket_name)

    harden_bucket(bucket)
    print(f"[bucket] 作成し堅牢化しました: gs://{bucket_name} "
          f"(versioning=ON, UBLA=ON, PAP={PUBLIC_ACCESS_PREVENTION})")
    return bucket


def ensure_iam(bucket, deployer_sa, dry_run):
    member = f"serviceAccount:{deployer_sa}"
    policy = bucket.get_iam_policy(requested_policy_version=3)

    for binding in policy.bindings:
        if binding.get("role") == STATE_BUCKET_ROLE and not binding.get("condition"):
            if member in binding.get("members", set()):
                print(f"[iam] 既に付与済み: {member} -> {STATE_BUCKET_ROLE}")
                return
            target_binding = binding
            break
    else:
        target_binding = None

    if dry_run:
        print(f"[iam] (dry-run) 付与する: {member} -> {STATE_BUCKET_ROLE} "
              f"on gs://{bucket.name}")
        return

    if target_binding is None:
        policy.bindings.append({"role": STATE_BUCKET_ROLE, "members": {member}})
    else:
        members = set(target_binding.get("members", set()))
        members.add(member)
        target_binding["members"] = members

    bucket.set_iam_policy(policy)
    print(f"[iam] 付与しました: {member} -> {STATE_BUCKET_ROLE} on gs://{bucket.name}")


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    saas_id, region, bucket_name, deployer_sa = load_config()

    print(f"対象: gs://{bucket_name} (project={saas_id}, region={region})")
    print(f"権限付与先: {deployer_sa}")
    if dry_run:
        print("=== DRY-RUN モード（変更は行いません）===")

    client = storage.Client(project=saas_id)
    bucket = ensure_bucket(client, saas_id, region, bucket_name, dry_run)
    ensure_iam(bucket, deployer_sa, dry_run)
    print("完了: backend バケットの準備ができています。")


if __name__ == "__main__":
    main()
