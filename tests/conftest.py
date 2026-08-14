"""テスト共通のフィクスチャ。

main-app は Vertex AI 等の重い依存を持つが、CI で検証したいのはロジックであり
SDK そのものではない。実依存を入れると CI が重くなるため、import 時にだけ必要な
モジュールはスタブに差し替えて main.py をロードする。
"""

import importlib.util
import sys
import types
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent

# main.py の import 文を満たすためだけのスタブ（テストでは実体を使わない）
_STUB_MODULES = {
    "vertexai": ["init"],
    "vertexai.generative_models": ["GenerativeModel"],
    "dotenv": ["load_dotenv"],
    "google.cloud.bigquery": ["Client"],
}


def _make_stub(name, attrs):
    module = types.ModuleType(name)
    for attr in attrs:
        setattr(module, attr, lambda *args, **kwargs: None)
    return module


@pytest.fixture(scope="session")
def main_app():
    """main-app/src/main.py をスタブ付きでロードして返す。

    __pycache__ を作らせない。main-app 配下のファイル一覧は Cloud Run Job の
    再ビルド判定（src_hash）に使われるため、テストが副産物を残すと
    無関係な再ビルドを誘発する。
    """
    sys.dont_write_bytecode = True
    saved = {name: sys.modules.get(name) for name in _STUB_MODULES}
    for name, attrs in _STUB_MODULES.items():
        if name in sys.modules:
            continue
        stub = _make_stub(name, attrs)
        sys.modules[name] = stub
        # `from google.cloud import bigquery` 形式のために親モジュールへも生やす
        parent_name, _, child = name.rpartition(".")
        parent = sys.modules.get(parent_name) if parent_name else None
        if parent is not None and not hasattr(parent, child):
            setattr(parent, child, stub)

    try:
        spec = importlib.util.spec_from_file_location(
            "analyzer_main", ROOT / "main-app" / "src" / "main.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module
    finally:
        for name, original in saved.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original
