# ADR-0005: テナントへのメール配信手段の選定

- ステータス: Proposed（未決定・実装保留）
- 日付: 2026-08-14
- 関連: [ADR-0001](0001-notification-channels.md), [ADR-0003](0003-signed-url-delivery.md)

## コンテキスト

現在テナントへの完了通知は **Slack Incoming Webhook の opt-in のみ**で、Webhook を持たないテナントには何も届かない（レポートは GCS に置かれるだけ）。[ADR-0001](0001-notification-channels.md) では「一般にはメール＋署名付きURLを基本とし、Slack は希望者のみ」と決めたが、**メール送信基盤が無いため未実装**のままである。

制約:

- 送信元は **Cloud Workflows**。HTTP POST はできるが、ネイティブなメール送信機能は無い（[ADR-0001](0001-notification-channels.md)）。
- テナントは別組織であり、当社ドメインからの送信になる。到達率のため SPF / DKIM / DMARC の整備が要る。
- レポート本文ではなく**署名付きURL**を送る（[ADR-0003](0003-signed-url-delivery.md)）。機微情報をメール本文に載せない方針は維持する。

## 決定すべきこと

1. **送信サービスの選定**（下表）
1. **送信元ドメインとアドレス**（例: `noreply@…`）と、DNS レコードを誰が設定するか
1. **バウンス/苦情の扱い**（宛先不達をどう検知するか。無視すると「送ったつもり」のサイレント失敗になる）

## 選択肢

| 案 | 長所 | 短所 |
| :-- | :-- | :-- |
| **SendGrid**（Google Cloud Marketplace 経由も可） | 実績が多く HTTP API が単純。Workflows から `http.post` 1 発で送れる | 外部 SaaS の契約・課金・APIキー管理が増える |
| **Mailgun / Amazon SES** | 単価が安い場合がある | SES は別クラウドの認証情報を GCP 側に持つことになる |
| **Google Workspace の SMTP リレー** | 既存契約の範囲で完結しうる | Workflows から SMTP は直接話せず、中継する Cloud Run/Functions が必要。送信制限あり |
| **送らない（現状維持）** | 追加コストゼロ | Slack を使わないテナントには何も届かない |

## 実装の見通し（サービス選定後）

- APIキーは Secret Manager に置き、Workflow から参照する（Slack Webhook と同じ流儀）。
- `tenants.json` に `notification_email` を追加し、**空なら送らない** opt-in とする（`slack_webhook_secret_name` と同じ扱い）。
- 送信失敗は握り潰さず、Workflow の失敗として扱う（[ADR-0002](0002-failure-detection-workflow-layer.md) の方針を踏襲）。

## 保留の理由

送信サービスの契約・課金・DNS 設定は当社側の意思決定と権限を要するため、選定前に実装しない。**選定が済めば実装自体は小さい**（Workflow に 1 ステップ追加＋テナント設定に 1 項目追加）。
