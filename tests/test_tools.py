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


def _config(ini_value):
    import configparser

    config = configparser.ConfigParser()
    config.read_string(f"[gcp]\nalert_notification_email = {ini_value}\n")
    return config


def test_alert_email_prefers_env_over_ini(monkeypatch):
    """CI では Secret（環境変数）が base_config.ini より優先されること。"""
    gc = _load("generate_configs", "tools/generate_configs.py")
    monkeypatch.setenv(gc.ALERT_EMAIL_ENV, "from-secret@example.com")
    assert gc.resolve_alert_email(_config("from-ini@example.com")) == "from-secret@example.com"


def test_alert_email_falls_back_to_ini(monkeypatch):
    gc = _load("generate_configs", "tools/generate_configs.py")
    monkeypatch.delenv(gc.ALERT_EMAIL_ENV, raising=False)
    assert gc.resolve_alert_email(_config("from-ini@example.com")) == "from-ini@example.com"


def test_alert_email_empty_when_neither_set(monkeypatch):
    """空文字なら通知リソースを作らない（＝アラートが消える）ため、挙動を固定しておく。"""
    gc = _load("generate_configs", "tools/generate_configs.py")
    monkeypatch.setenv(gc.ALERT_EMAIL_ENV, "   ")
    assert gc.resolve_alert_email(_config("")) == ""


def test_deploy_workflow_passes_alert_email_secret():
    """deploy.yml が Secret を generate_configs.py に渡していること（CI でアラートが消えるのを防ぐ）。"""
    gc = _load("generate_configs", "tools/generate_configs.py")
    deploy = (ROOT / ".github" / "workflows" / "deploy.yml").read_text(encoding="utf-8")
    assert f"{gc.ALERT_EMAIL_ENV}: ${{{{ secrets.{gc.ALERT_EMAIL_ENV} }}}}" in deploy


def test_check_sh_reads_gemini_settings_from_main_py():
    """check.sh が main.py の定義名を参照していること。

    モデル名を check.sh 側にも書くと二重管理になりドリフトする。定義名を変えたら
    check.sh の sed が空振りして「チェックしているのに素通り」になるため、名前を固定する。
    """
    check_sh = (ROOT / "tools" / "check.sh").read_text(encoding="utf-8")
    assert "main-app/src/main.py" in check_sh
    for name in ("GEMINI_MODEL", "LOCATION"):
        assert f"^{name}" in check_sh, f"check.sh が {name} を抽出していない"

    main_py = (ROOT / "main-app" / "src" / "main.py").read_text(encoding="utf-8")
    for name in ("GEMINI_MODEL", "LOCATION"):
        assert f"\n{name} = " in main_py, f"main.py の {name} 定義形式が変わった"


def test_run_tenant_fails_when_workflow_fails():
    """make run が Workflow の失敗を成功に見せないこと。

    gcloud workflows run は実行が FAILED でも終了コード 0 を返すため、
    state を見て明示的に落とす必要がある。
    """
    script = (ROOT / "tools" / "run_tenant.sh").read_text(encoding="utf-8")
    assert '"$STATE" != "SUCCEEDED"' in script, "Workflow の state を検査していない"
    assert "--format=json" in script, "state を取得できる形式で受け取っていない"


def test_rebuild_trigger_covers_every_dockerfile_copy():
    """Cloud Run Job の再ビルド判定が Dockerfile の COPY 対象を網羅していること。

    COPY を足したのに判定側に足し忘れると、イメージの中身が変わっても再ビルドされず、
    古いコードが動き続ける（気付きにくい）。
    """
    dockerfile = (ROOT / "main-app" / "Dockerfile").read_text(encoding="utf-8")
    sources = [
        line.split()[1].rstrip("/")
        for line in dockerfile.splitlines()
        if line.strip().startswith("COPY ")
    ]
    assert sources, "Dockerfile から COPY 対象を抽出できなかった"

    tf = (ROOT / "terraform" / "cloud_run_job.tf").read_text(encoding="utf-8")
    for src in sources:
        assert src in tf, f"再ビルド判定に {src} が含まれていない"


def test_ensure_state_bucket_constants():
    esb = _load("ensure_state_bucket", "tools/ensure_state_bucket.py")
    assert esb.STATE_BUCKET_ROLE == "roles/storage.objectAdmin"
    assert esb.PUBLIC_ACCESS_PREVENTION == "enforced"
