# ADR-0004: Terraform の state backend は本ツール同梱の bootstrap で自動構築する

- ステータス: Accepted
- 日付: 2026-07-24
- 関連: [design-decisions.md](../design-decisions.md)

## コンテキスト

Terraform の GCS backend には「**bootstrap 問題**」がある。state を GCS に置くには state 用バケットが要るが、そのバケット自体を Terraform で作ると「state を置く先が state に依存する」鶏卵になる。

運用上の要望:

- **`make` コマンドで完結**させたい。make と make の間で手動 `gcloud` を打ちたくない。
- ツールを作るたびに backend バケット作成・権限付与という定型作業（bootstrap）が発生するのを、少なくとも本ツール内では自動化したい。

比較検討した選択肢: (A) 各ツールに bootstrap を同梱、(B) tfstate 専用プロジェクト＋共有バケット、(C) HCP Terraform（旧 Terraform Cloud）、(D) Terragrunt で backend を DRY 化。

## 決定

- **本ツールに bootstrap を同梱し、backend バケットの作成と権限付与を `make` で自動化する**（選択肢 A）。
  - `make init` 相当で backend バケットの存在確認・作成・必要な IAM 付与まで行い、手動 `gcloud` を挟まない。
  - state 用バケットはツール固有のリソースとして本リポジトリの範囲で完結させる。
- HCP Terraform / Terragrunt / 専用 state プロジェクトは**現時点では採用しない**（下記トレードオフ参照）。将来ツール数が増えて bootstrap の重複が負担になったら再評価する。

## 根拠

- 「make で完結・手動 gcloud を挟まない」という第一要件を、追加の外部依存なしに満たせるのが bootstrap 同梱。
- 個人〜小規模の運用では、ツールごとに state バケットが分かれている方が**影響範囲が独立**し、あるツールの操作が他へ波及しない。
- HCP Terraform は無料枠（リソース数上限）があるが外部 SaaS 依存・アカウント運用が増える。現状はローカル＋GCS backend で十分。
- Terragrunt は backend 定義の DRY 化に有効だが、単一ツール内では重複が小さく、学習・運用コストに見合わない。

## 影響 / トレードオフ

- ツールを新設するたびに同種の bootstrap を持ち回る**重複**が残る（ツール数が増えると効いてくる）。
- backend バケットのライフサイクル（削除保護・バージョニング）は各ツールで面倒を見る必要がある。
- 将来、複数ツール横断で state を統合管理したくなった場合は、専用 state プロジェクト（B）や Terragrunt（D）への移行を別途検討する。

## 検討した代替案

- **(B) tfstate 専用プロジェクト＋共有バケット**: 横断管理はしやすいが、全ツールが単一バケットに集中し影響範囲が広がる。小規模では過剰。→ 現時点では不採用（将来候補）。
- **(C) HCP Terraform**: リモート実行・state ロック・無料枠が魅力だが外部 SaaS 依存とアカウント運用が増える。→ 現時点では不採用。
- **(D) Terragrunt**: backend の DRY 化に有効だが単一ツールでは効果が薄く、学習コストが上回る。→ 現時点では不採用（ツール多数化で再評価）。
