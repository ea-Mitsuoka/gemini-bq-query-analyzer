"""main-app（分析ジョブ本体）のユニットテスト。

過去に実際に起きた不具合の再発防止を主眼にしている:
- objectAdmin で buckets.get 権限がなく疎通確認が 403 になった件
- 署名付きURLを鍵レス（signBlob）で生成する契約
- Workflow が読む summary.json のキー
"""

import json
import re
from pathlib import Path

import pytest
from google.api_core.exceptions import Forbidden, NotFound


class _FakeBlob:
    def __init__(self):
        self.uploaded = None
        self.content_type = None
        self.signed_url_kwargs = None

    def upload_from_string(self, data, content_type=None):
        self.uploaded = data
        self.content_type = content_type

    def generate_signed_url(self, **kwargs):
        self.signed_url_kwargs = kwargs
        return "https://signed.example/report.md"


class _FakeBucket:
    def __init__(self):
        self.blobs = {}

    def blob(self, path):
        self.blobs.setdefault(path, _FakeBlob())
        return self.blobs[path]


class _FakeStorageClient:
    """storage.Client の差し替え。list_blobs の挙動を注入できる。"""

    last_instance = None

    def __init__(self, project=None):
        self.project = project
        self.buckets = {}
        self.get_bucket_called = False
        _FakeStorageClient.last_instance = self

    def bucket(self, name):
        self.buckets.setdefault(name, _FakeBucket())
        return self.buckets[name]

    def get_bucket(self, name):
        # 呼ばれてはいけない（objectAdmin に buckets.get が含まれないため）
        self.get_bucket_called = True
        raise Forbidden("storage.buckets.get denied")

    def list_blobs(self, bucket_name, max_results=None):
        return iter([])


# ==========================================
# check_bucket_exists（403 事故の再発防止）
# ==========================================


def test_check_bucket_exists_does_not_call_get_bucket(main_app):
    """objectAdmin では buckets.get が使えないため get_bucket に依存してはいけない。"""
    client = _FakeStorageClient()
    assert main_app.check_bucket_exists(client, "some-bucket") is True
    assert client.get_bucket_called is False


def test_check_bucket_exists_false_when_bucket_name_empty(main_app):
    assert main_app.check_bucket_exists(_FakeStorageClient(), "") is False


@pytest.mark.parametrize("error", [NotFound("missing"), Forbidden("denied"), RuntimeError("boom")])
def test_check_bucket_exists_false_on_error(main_app, error):
    client = _FakeStorageClient()

    def raise_error(bucket_name, max_results=None):
        raise error

    client.list_blobs = raise_error
    assert main_app.check_bucket_exists(client, "some-bucket") is False


# ==========================================
# 調査期間の条件式
# ==========================================


def test_time_range_uses_interval_when_set(main_app, monkeypatch):
    monkeypatch.setattr(main_app, "TIME_RANGE_INTERVAL", "3 DAY")
    start, end = main_app.get_time_range_expressions()
    assert "INTERVAL 3 DAY" in start
    assert end == ""


def test_time_range_uses_explicit_start_and_end(main_app, monkeypatch):
    monkeypatch.setattr(main_app, "TIME_RANGE_INTERVAL", "")
    monkeypatch.setattr(main_app, "TIME_RANGE_START", "2026-01-01")
    monkeypatch.setattr(main_app, "TIME_RANGE_END", "2026-01-31")
    start, end = main_app.get_time_range_expressions()
    assert "TIMESTAMP('2026-01-01')" == start
    assert "TIMESTAMP('2026-01-31')" in end


def test_time_range_falls_back_to_one_day(main_app, monkeypatch):
    monkeypatch.setattr(main_app, "TIME_RANGE_INTERVAL", "")
    monkeypatch.setattr(main_app, "TIME_RANGE_START", None)
    start, end = main_app.get_time_range_expressions()
    assert "INTERVAL 1 DAY" in start
    assert end == ""


# ==========================================
# アンチパターン辞書の抽出
# ==========================================


def test_extract_relevant_dictionary_returns_only_detected(main_app):
    master = {"SELECT *": "全列取得の説明", "CROSS JOIN": "直積の説明"}
    result = main_app.extract_relevant_dictionary(master, "検出: SELECT * が使われています")
    assert "全列取得の説明" in result
    assert "直積の説明" not in result


@pytest.mark.parametrize(
    "master,detected",
    [({}, "SELECT *"), ({"SELECT *": "説明"}, ""), ({"SELECT *": "説明"}, "該当なし")],
)
def test_extract_relevant_dictionary_returns_placeholder(main_app, master, detected):
    assert main_app.extract_relevant_dictionary(master, detected) == "特になし"


# ==========================================
# 署名付きURL（鍵レス署名の契約）
# ==========================================


class _FakeCredentials:
    service_account_email = "analyzer-sa@example.iam.gserviceaccount.com"
    token = "ya29.fake-token"

    def refresh(self, request):
        pass


def test_generate_report_signed_url_signs_keylessly(main_app, monkeypatch):
    """鍵ファイルではなく signBlob（SAメール＋アクセストークン）で V4 署名すること。"""
    monkeypatch.setattr(main_app.google.auth, "default", lambda: (_FakeCredentials(), None))
    blob = _FakeBlob()

    url = main_app.generate_report_signed_url(blob)

    assert url == "https://signed.example/report.md"
    kwargs = blob.signed_url_kwargs
    assert kwargs["version"] == "v4"
    assert kwargs["method"] == "GET"
    assert kwargs["service_account_email"] == _FakeCredentials.service_account_email
    assert kwargs["access_token"] == _FakeCredentials.token
    assert kwargs["expiration"].days == main_app.REPORT_URL_EXPIRY_DAYS


def test_generate_report_signed_url_returns_none_on_failure(main_app, monkeypatch):
    """署名に失敗してもレポート自体は保存済みなので、例外にせず None を返す。"""

    def boom():
        raise RuntimeError("signBlob denied")

    monkeypatch.setattr(main_app.google.auth, "default", boom)
    assert main_app.generate_report_signed_url(_FakeBlob()) is None


# ==========================================
# GCS への保存
# ==========================================


def test_upload_report_to_gcs_returns_pair_of_none_without_bucket(main_app):
    assert main_app.upload_report_to_gcs("", "body", "customer-project") == (None, None)


def test_save_summary_writes_workflow_contract_keys(main_app, monkeypatch):
    """Workflow が参照するキー（text_summary / report_url）を固定パスに書くこと。"""
    monkeypatch.setattr(main_app.storage, "Client", _FakeStorageClient)

    main_app.save_summary_for_workflow(
        "report-bucket", "解析が完了しました。", "customer-project", report_url="https://signed/x"
    )

    bucket = _FakeStorageClient.last_instance.buckets["report-bucket"]
    blob = bucket.blobs[main_app.SUMMARY_BLOB_PATH]
    payload = json.loads(blob.uploaded)
    assert payload["text_summary"] == "解析が完了しました。"
    assert payload["report_url"] == "https://signed/x"
    assert payload["customer_project_id"] == "customer-project"
    assert blob.content_type == "application/json"


def test_summary_contains_every_key_the_workflow_reads(main_app, monkeypatch):
    """Workflow の `report_json.body.<key>` 参照が summary.json のキーに揃っていること。"""
    monkeypatch.setattr(main_app.storage, "Client", _FakeStorageClient)
    main_app.save_summary_for_workflow("report-bucket", "要点", "customer-project", "https://u")

    blob = _FakeStorageClient.last_instance.buckets["report-bucket"].blobs[
        main_app.SUMMARY_BLOB_PATH
    ]
    written = set(json.loads(blob.uploaded))

    workflow = (
        Path(__file__).resolve().parent.parent / "workflows" / "analyzer_workflow.yaml"
    ).read_text(encoding="utf-8")
    referenced = set(re.findall(r"report_json\.body\.(\w+)", workflow))

    assert referenced, "Workflow が summary.json を参照していない（正規表現の破損を疑う）"
    assert referenced <= written, f"main-app が書いていないキー: {sorted(referenced - written)}"


def test_save_summary_skips_when_bucket_missing(main_app, monkeypatch):
    called = []
    monkeypatch.setattr(main_app.storage, "Client", lambda *a, **k: called.append(1))
    main_app.save_summary_for_workflow("", "summary", "customer-project")
    assert called == []
