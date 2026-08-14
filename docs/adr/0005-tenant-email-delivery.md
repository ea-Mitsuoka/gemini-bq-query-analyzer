# ADR-0005: テナントへのメール配信手段（Workspace SMTP リレー vs SendGrid）

- ステータス: Proposed（未決定・実装保留）
- 日付: 2026-08-14
- 関連: [ADR-0001](0001-notification-channels.md), [ADR-0002](0002-failure-detection-workflow-layer.md), [ADR-0003](0003-signed-url-delivery.md)

## コンテキスト

現在テナントへの完了通知は **Slack Incoming Webhook の opt-in のみ**で、Webhook を持たないテナントには何も届かない（レポートが GCS に置かれるだけ）。[ADR-0001](0001-notification-channels.md) では「一般にはメール＋署名付きURLを基本とし、Slack は希望者のみ」と決めたが、**送信基盤が無いため未実装**である。

前提:

- 送信元は **Cloud Workflows**。HTTP POST はできるが **SMTP は話せない**（[ADR-0001](0001-notification-channels.md)）。
- 送るのはレポート本文ではなく**署名付きURL**（[ADR-0003](0003-signed-url-delivery.md)）。機微情報をメール本文に載せない方針は維持する。
- 宛先は**別組織**（テナント）。当社ドメインから外部宛に送ることになる。
- **送信量は極めて少ない**。週次配信でテナント数ぶん（100 テナントでも週 100 通）。どちらの案も容量面では余裕がある。

## 比較

| 観点               | Google Workspace SMTP リレー                                                                                    | SendGrid                                                                                                            |
| :----------------- | :-------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------ |
| **契約・コスト**   | 既存の Workspace 契約に含まれ、追加費用なし                                                                     | 新規 SaaS の契約が必要。無料枠を超えると月額が発生（この送信量なら小さい）                                          |
| **アーキテクチャ** | Workflows から SMTP を話せないため、**HTTP を受けて SMTP で送る中継コンポーネント（Cloud Run 等）が新規に必要** | Workflows から `http.post` 1 発。**新規コンポーネント不要**                                                         |
| **到達性・DNS**    | 既存ドメインの SPF/DKIM/DMARC と送信レピュテーションをそのまま使える。DNS 変更は基本的に不要                    | SPF への追加と DKIM の CNAME 登録が必要（**DNS 権限を持つ部署の作業**）。専用サブドメインでレピュテーションを別管理 |
| **バウンス検知**   | エンベロープ送信者へバウンスメールが返るだけ。**検知するには受信箱と、それを読む仕組みが別途必要**              | Webhook / API でバウンス・スパム報告を機械的に取得できる                                                            |
| **運用・監視**     | 中継コンポーネントの死活・エラーを自分で監視する対象が増える                                                    | 送信結果はレスポンスで即座に判る。ダッシュボードで配信状況を追える                                                  |
| **制限**           | Workspace 側の送信上限とリレーの許可設定（外部宛の可否、認証方式）に従う。**上限値は変動するため要確認**        | プラン上限に従う。この用途では実質問題にならない                                                                    |
| **懸念**           | GCP からの外向き SMTP はポート 25 が塞がれており、**利用可能なポートと経路の確認が必要**                        | 認証情報（APIキー）が 1 つ増える。Secret Manager で管理する                                                         |

## 当社ドメインの実態（2026-08-15 時点の公開 DNS）

```
SPF   : v=spf1 include:_spf.google.com include:…hubspotemail.net ~all
DMARC : v=DMARC1; p=quarantine; rua=mailto:eag-admin@e-agency.co.jp,…
MX    : SMTP.GOOGLE.COM
```

ここから決まること:

- **DMARC が `p=quarantine`（強制あり）**。DKIM/SPF が当社ドメインと整合しない送信は受信側で隔離される。したがって **「DNS を変更せずに SendGrid を使う」（Single Sender Verification 等）は現実的でない**。
- SPF に既に `_spf.google.com` があるため、**Workspace 経由の送信は DNS 変更なしで整合する**。
- SPF に `hubspotemail.net` が入っており、第三者送信サービスを SPF に追加した前例が社内にある。
- DMARC 集約レポートの宛先が `eag-admin@e-agency.co.jp`。**メール周りの相談先はここ**。

**重要**: SMTP リレーの有効化は Google 管理コンソールの設定であり、**特権管理者権限が必要**。開発者アカウント単独では設定できない。つまり **情シスと DNS の両方を回避できる選択肢は存在しない**。

## 推奨

**Google Workspace SMTP リレーを推奨する。** 当初は SendGrid を推していたが、上記の実態を踏まえて反転させた。判断が変わった理由は「情シスへの依頼を避けられるか」ではなく（どちらも避けられない）、**依頼の大きさ**である。

|                | Workspace リレー          | SendGrid                            |
| :------------- | :------------------------ | :---------------------------------- |
| 情シスへの依頼 | 管理コンソールの設定 1 件 | ベンダー契約の承認                  |
| DNS 変更       | **不要**                  | DKIM の CNAME 3 件 + SPF 追加が必要 |
| 新規ベンダー   | 不要                      | 契約・調達が必要                    |

SendGrid の技術的な優位（構成要素が増えない・バウンスを機械検知できる）は依然として事実だが、**契約と DNS という 2 つの組織的関門を越えられなければ実装に到達しない**。到達可能性を優先する。

### 採用する場合に必ずセットで設計すること

Workspace リレーの弱点は**バウンスが無音になること**である。本システムは「成功したように見えて中身が無い」状態を一貫して潰してきた（[ADR-0002](0002-failure-detection-workflow-layer.md)、Gemini 全件失敗時の exit 1、`make run` の終了コード修正）。**宛先不達に気付けない配信はその再来**になるため、次を同時に用意する。

- 中継コンポーネント（Cloud Run）は **SMTP の応答コードを見て、失敗を Workflow の失敗として伝播させる**（握り潰さない）
- エンベロープ送信者を**監視対象の受信箱**にし、バウンスが溜まったら気付ける導線を作る
- 送信量が少ない（週次×テナント数）ため、**送信ログを Cloud Logging に残して件数を突き合わせる**運用でも当面は成立する

## 情シスへの依頼内容（Workspace リレー採用時）

1. **SMTP リレーサービスの有効化**（管理コンソール → Apps → Google Workspace → Gmail → ルーティング → SMTP リレーサービス）
1. 許可する送信元の指定 — 中継用 Cloud Run の**固定外向き IP**（Cloud NAT）または SMTP 認証アカウント
1. **外部宛送信の許可**（宛先はテナント＝社外）
1. 送信元アドレス（例: `noreply@e-agency.co.jp`）の用意と、**バウンス受信箱の所在**

## 決定に必要な情報

1. 上記の依頼が通るか（相談先: `eag-admin@e-agency.co.jp`）
1. 中継 Cloud Run から `smtp-relay.gmail.com` への到達性 — **GCP は外向きポート 25 を遮断している**ため、使用ポート（587/465）と経路（Cloud NAT の要否）の確認が必要
1. バウンス受信箱を誰が監視するか

## 実装の見通し（決定後）

どちらを選んでも、Workflow 側とテナント設定の扱いは共通にする。

- APIキー（または中継エンドポイントの認証情報）は **Secret Manager** に置く。Slack Webhook と同じ流儀。
- `tenants.json` に `notification_email` を追加し、**空なら送らない** opt-in とする（`slack_webhook_secret_name` と同じ扱い）。
- **送信失敗は握り潰さない。** Workflow の失敗として扱い、`ANALYZER_FAILURE` 経由で当社に通知する（[ADR-0002](0002-failure-detection-workflow-layer.md)）。
- 本文には要点サマリと**期限付き署名付きURL**のみを載せる（[ADR-0003](0003-signed-url-delivery.md)）。

Workspace リレーを選ぶ場合は、これに加えて **HTTP を受けて SMTP で送る中継 Cloud Run サービス**を新設する。Workflow から見た形は SendGrid の場合と同じ（Secret Manager の認証情報で `http.post`）にしておき、将来 SendGrid へ移行しても Workflow 側を変えずに済むようにする。

## 却下した案

- **DNS を変更せずに SendGrid を使う**（Single Sender Verification）: DMARC が `p=quarantine` のため受信側で隔離される。到達性が担保できない。
- **開発者個人の Gmail アカウントから送る**: 送信者が個人に紐づき、退職・異動で壊れる。送信上限も低く、顧客向けの体裁として不適切。
