"""tools/ 配下スクリプトの軽量なユニットテスト。"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load(name, relpath):
    spec = importlib.util.spec_from_file_location(name, ROOT / relpath)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_template_columns_match_required():
    """テンプレートの列と upload_tenants の必須列が一致していること（ドリフト検知）。"""
    gt = _load("generate_template", "tools/generate_template.py")
    ut = _load("upload_tenants", "tools/upload_tenants.py")
    assert set(gt.COLUMNS) == ut.REQUIRED_COLUMNS


def test_ensure_state_bucket_constants():
    esb = _load("ensure_state_bucket", "tools/ensure_state_bucket.py")
    assert esb.STATE_BUCKET_ROLE == "roles/storage.objectAdmin"
    assert esb.PUBLIC_ACCESS_PREVENTION == "enforced"
