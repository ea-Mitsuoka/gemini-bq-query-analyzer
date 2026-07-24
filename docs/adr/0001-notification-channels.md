# ADR-0001: 通知チャネルの使い分け（失敗＝Monitoring/Email、成功＝Workflow/Slack Webhook）

- ステータス: Accepted
- 日付: 2026-07-24
- 関連: [design-decisions.md](../design-decisions.md)

## コンテキスト

本システムには性質の異なる 2 種類の通知がある。

1. **失敗通知（社内運用向け）**: 分析パイプラインが失敗したことを当社（ホスト）に伝える。送信元は **Cloud Monitoring**。
1. **成功通知（テナント向け）**: 分析完了と成果物（レポートの署名付きURL）をテナントに伝える。送信元は **Cloud Workflows**。

論点は「Slack へ届ける手段」として **Incoming Webhook** と **チャンネルの Email インテグレーション（email-to-channel）** のどちらが適切か。加えて、テナントは通常**別組織・別ワークスペース**であるクロス組織性を考慮する必要がある。

重要な観察: **送信元が何を送れるか**で最適な手段が変わる。

- Cloud Monitoring は **Email しか送れない**（Webhook 送信は不可）。
- Cloud Workflows は **HTTP POST できる**（Webhook 送信が可能。ネイティブなメール送信は不可）。

## 決定

- **失敗通知（当社）** = Workflow が失敗時に構造化ログ `ANALYZER_FAILURE tenant=... error=...` を出力し、**Cloud Monitoring ログベースアラート → Email 通知チャネル → Slack チャンネルの Integration メールアドレス**で当社ワークスペースへ届ける。
  - 送信元（Monitoring）が Email のみのため Email を採用。
  - Cloud Monitoring の「Slack 通知チャネル」（OAuth で Slack アプリをインストールする方式）は**使わない**。Email チャネルなら Slack アプリ承認（情シス）が不要で、宛先はただのメールアドレスで済む。
- **成功通知（テナント）** = Workflow が **Slack Incoming Webhook** に `http.post` する（テナント毎の **opt-in**）。
  - Workflow は POST できるため、追加のメール送信基盤が不要で、リッチな整形・即時性・明確な成否が得られる。
  - Webhook URL は Secret Manager に保管（`slack_webhook_secret_name`）。空のテナントは通知しない。
- **クロス組織のテナント配信の原則**: 全テナントに Slack を強制しない。一般には **メール（テナント自身のアドレス）＋署名付きURL** を基本とし、Slack を希望するテナントのみ Webhook で opt-in とする。
  - テナント向けメール配信を本採用する場合は、Workflow から送るためのメール送信基盤（例: SendGrid）の導入が別途必要（未実装・将来検討）。

## 根拠

- 「Webhook と Email のどちらが優れるか」は一概ではなく、**送信元の能力に合わせる**のが正しい。今の使い分け（Monitoring→Email／Workflow→Webhook）は適材適所。
- Slack 宛に限れば、POST 可能な送信元では Incoming Webhook の方が Email インテグレーションより優れる（インフラ不要・リッチ・即時）。
- Email インテグレーションは「送信元が Email しか送れない」場合の適切な手段であり、失敗通知（Monitoring）がまさにそれ。

## 影響 / トレードオフ

- Webhook URL は実質ベアラーシークレット。漏洩時はテナント側で**再発行**できる旨を運用手順に含める。
- テナント毎に Slack アプリ承認と URL 共有の手間が発生する（Slack を選ぶテナントのみ）。
- テナント向けメール配信を将来採用する場合、メール送信基盤という新規依存が増える。

## 検討した代替案

- **Slack Bot token（`chat.postMessage`）**: 多チャンネル/DM/対話が可能だが設定が重い。単方向の完了通知には過剰。→ 不採用。
- **テナント成功通知を Email インテグレーションで送る**: Workflow がネイティブにメール送信できず、送信基盤を新設する必要があり Webhook より不利。→ 不採用。
- **Cloud Monitoring の Slack 通知チャネル**: OAuth で Slack アプリのインストール（情シス承認）が必要。Email チャネルで代替できるため不採用。
