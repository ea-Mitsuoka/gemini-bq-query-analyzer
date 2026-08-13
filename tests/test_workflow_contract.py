"""Workflow YAML と Terraform / main-app の間の契約（ドリフト）を検証する。

文字列で結合されている箇所は、片方だけ直すと本番で初めて壊れる。
過去に実際に起きた事故（YAML パースエラー、failedCount の KeyError）も含めて
静的に検知できるようにする。
"""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_PATH = ROOT / "workflows" / "analyzer_workflow.yaml"
WORKFLOWS_TF = ROOT / "terraform" / "workflows.tf"
MONITORING_TF = ROOT / "terraform" / "monitoring.tf"


@pytest.fixture(scope="module")
def workflow_text():
    return WORKFLOW_PATH.read_text(encoding="utf-8")


def test_workflow_yaml_is_parsable(workflow_text):
    """`: ` を含む式のクオート漏れ等で YAML が壊れていないこと（過去に2度発生）。"""
    assert yaml.safe_load(workflow_text)["main"]["steps"]


def test_workflow_template_vars_are_provided_by_terraform(workflow_text):
    """YAML 内の ${var} が templatefile() の引数に全て存在すること。

    `$${...}` は Workflows の式（エスケープ済み）なので対象外。
    """
    used = set(re.findall(r"(?<!\$)\$\{(\w+)\}", workflow_text))

    tf = WORKFLOWS_TF.read_text(encoding="utf-8")
    block = tf.split("templatefile(", 1)[1].split("})", 1)[0]
    provided = set(re.findall(r"^\s*(\w+)\s*=", block, re.MULTILINE))

    assert used, "テンプレート変数が1つも検出できていない（正規表現の破損を疑う）"
    assert used <= provided, f"terraform 側で未提供の変数: {sorted(used - provided)}"


def test_failure_marker_matches_monitoring_filter(workflow_text):
    """Monitoring のログフィルタが探す文字列を Workflow が実際に出力していること。"""
    tf = MONITORING_TF.read_text(encoding="utf-8")
    heredoc = tf.split("<<-EOT", 1)[1].split("EOT", 1)[0]
    # フィルタ内の裸の引用符行（例: "ANALYZER_FAILURE"）がフリーテキスト検索語
    markers = [
        line.strip().strip('"')
        for line in heredoc.splitlines()
        if line.strip().startswith('"') and line.strip().endswith('"')
    ]

    assert markers, "monitoring.tf のフィルタから検索語を抽出できなかった"
    for marker in markers:
        assert marker in workflow_text, f"Workflow が '{marker}' を出力していない"


def test_workflow_uses_map_get_for_failed_count(workflow_text):
    """failedCount は成功時にキーごと存在しないため、直接参照すると KeyError になる。"""
    assert 'map.get(execution_status, "failedCount")' in workflow_text
    assert "execution_status.failedCount" not in workflow_text


def test_workflow_reads_summary_path_written_by_main_app(workflow_text, main_app):
    """Workflow が取得する summary.json のパスが main-app の保存先と一致すること。"""
    encoded = main_app.SUMMARY_BLOB_PATH.replace("/", "%2F")
    assert encoded in workflow_text


def test_workflow_wraps_pipeline_in_try_except(workflow_text):
    """失敗検知は Workflow 層で行う（ADR-0002）。try/except と再送出があること。"""
    steps = yaml.safe_load(workflow_text)["main"]["steps"]
    pipeline = next(s["run_pipeline"] for s in steps if "run_pipeline" in s)
    assert "try" in pipeline and "except" in pipeline

    except_steps = pipeline["except"]["steps"]
    assert any("raise" in list(step.values())[0] for step in except_steps), (
        "except 節で再送出していないと Workflow が成功扱いになる"
    )
