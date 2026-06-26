"""Makefile のターゲットと README の Make コマンド表が一致するか検証する。

`## ` 付きで定義された Makefile ターゲットと、README の
「開発・運用コマンド（Make）」セクションの表に列挙された `make <target>` を突き合わせ、
過不足があれば非ゼロ終了する（make lint から呼ばれる）。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SECTION_HEADING = "## 🛠 開発・運用コマンド（Make）"


def makefile_targets() -> set[str]:
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    return set(re.findall(r"^([a-zA-Z][a-zA-Z0-9_-]*):.*?##", text, re.M))


def documented_targets() -> set[str]:
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    if SECTION_HEADING not in text:
        print(f"エラー: README に '{SECTION_HEADING}' セクションが見つかりません。")
        sys.exit(1)
    section = text.split(SECTION_HEADING, 1)[1].split("\n###", 1)[0]
    return set(re.findall(r"`make ([a-zA-Z][a-zA-Z0-9_-]*)`", section))


def main() -> None:
    targets = makefile_targets()
    documented = documented_targets()

    missing = targets - documented  # Makefile にあるが README 未記載
    extra = documented - targets  # README にあるが Makefile 未定義

    if missing or extra:
        if missing:
            print("README に未記載の Makefile ターゲット:", ", ".join(sorted(missing)))
        if extra:
            print("Makefile に存在しない README 記載ターゲット:", ", ".join(sorted(extra)))
        print("README の Make コマンド表を Makefile に合わせて更新してください。")
        sys.exit(1)

    print(f"make-docs OK: {len(targets)} ターゲットが README と一致しています。")


if __name__ == "__main__":
    main()
