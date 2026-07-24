# ADR-0002: 失敗検知は Workflow 層で行い、復旧不能エラーは exit 1 にする

- ステータス: Accepted
- 日付: 2026-07-24
- 関連: [design-decisions.md](../design-decisions.md), [ADR-0001](0001-notification-channels.md)

## コンテキスト

分析パイプラインは **Cloud Workflows** が **Cloud Run Job**（実処理）を起動する二層構成になっている。

課題は「どこで失敗を検知するか」。Cloud Run Job の終了コードだけを見ると、次のようなサイレント失敗を取りこぼす。

- Job 自体は正常終了（exit 0）だが、後続の Workflow ステップ（結果保存・通知など）で失敗する。
- Job のコードが例外を握りつぶして exit 0 で終わってしまう（設定不備・バケットアクセス不可・SQL 読込失敗など、本来は失敗すべきケース）。

「成功したように見えて実は失敗している」状態は、テナントに古い/欠損したレポートを出す、あるいは何も出さないまま気付かれない、という最悪の結果につながる。

## 決定

失敗検知を **2 段構え**にする。

1. **Workflow 層を一次検知点にする。**
   - パイプライン全体を `try/except` で囲み、失敗時は構造化ログ `ANALYZER_FAILURE tenant=... error=...` を `severity=ERROR` で出力してから `reraise` する。
   - Job の実行結果も Workflow 側で確認する（`map.get(execution_status, "failedCount")` で失敗数を見る。キー欠如で KeyError にならないよう直接参照は避ける）。
2. **Cloud Run Job も復旧不能エラーでは exit 1 にする。**
   - 設定不備 / レポートバケットにアクセス不可 / SQL 読込失敗 は `sys.exit(1)` にして、サイレントな exit 0 をやめる。
   - 「対象リージョンなし」など正常な空結果は summary を書いて exit 0 に留める（失敗ではない）。

この構造化ログ `ANALYZER_FAILURE` を Cloud Monitoring のログベースアラートが拾い、通知につなぐ（通知チャネルは [ADR-0001](0001-notification-channels.md)）。

## 根拠

- Workflow 層はパイプライン全体の成否を見渡せる唯一の場所であり、Job 単体では見えない後続ステップの失敗まで捕捉できる。
- 終了コードは自動監視（Cloud Run の失敗メトリクス等）が拾える機械可読なシグナルであり、exit 1 を正しく返すことは監視の前提。二層で冗長に検知することで片方の穴を他方が埋める。
- 構造化ログを検知の「契機」にすることで、Monitoring 側はログフィルタ 1 本で拾え、通知手段（[ADR-0001](0001-notification-channels.md)）と疎結合になる。

## 影響 / トレードオフ

- Workflow に `try/except` とログ出力の定型が増える（可読性コスト。ただし1箇所）。
- exit コードの意味付け（何を復旧不能とみなすか）をコード側で維持する必要がある。空結果を失敗と誤判定しないよう線引きが要る。
- ログ文言 `ANALYZER_FAILURE` は Monitoring のフィルタと結合しているため、変更時は両方を揃える必要がある（文字列結合）。

## 検討した代替案

- **Cloud Run Job の終了コードだけで検知**: Job 正常終了後の Workflow ステップ失敗を取りこぼす。→ 不採用（Workflow 層検知と併用する形で残置）。
- **Workflow の成否だけで検知（Job は常に exit 0）**: Job 内の復旧不能エラーが Workflow まで伝播しないケースで検知が遅れる/曖昧になる。→ 不採用。
- **例外を握りつぶして warning ログのみ**: サイレント失敗そのもので、本 ADR が排除したい状態。→ 不採用。
