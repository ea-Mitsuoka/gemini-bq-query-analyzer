スプレッドシート（設定値）と Secret Manager（機密情報）を組み合わせたハイブリッド構成への移行工数を見積もります。

現在の `generate_tfvars.py` や `main.py`  の構造をベースに、追加実装が必要な箇所を分解して算出しました。

---

### 🛠 実装工数見積もり (トータル: 約 3〜5 営業日)

既存のコード資産を活かせるため、ゼロからの構築よりは短縮可能です。

#### 1. スプレッドシート & CSV 連携の基盤整備 (1.0 日)

* 
**シート作成**: カラム定義（`tenant_id`, `worst_query_limit`, `slack_webhook_secret_name` 等）の設定 。


* **`generate_configs.py` への刷新**: `base_config.ini` と `tenants_master.csv` を読み込み、`.env` と `terraform.tfvars` を一括生成するロジックの実装。
* **バリデーション**: `scheduler_cron` や `project_id` の形式チェック処理の追加。

#### 2. Secret Manager への移行と IAM 設定 (0.5 〜 1.0 日)

* 
**シークレット登録**: 既存の `slack_webhook_url`  を Secret Manager へ手動（または gcloud）で登録。


* 
**Terraform 修正**: `google_project_iam_member` に `roles/secretmanager.secretAccessor` ロールを追加し、`analyzer_sa` に付与 。



#### 3. アプリケーション (`main.py`) の改修 (1.0 日)

* 
**シークレット取得ロジック**: `google-cloud-secret-manager` ライブラリを `requirements.txt` に追加 。


* 
**ラッパー関数実装**: 環境変数が `https://` で始まらない場合はシークレット名と判断し、Secret Manager から値を取得する関数を `main.py` に組み込む 。



#### 4. 結合テスト・CI/CD 調整 (1.0 〜 2.0 日)

* 
**ローカルテスト**: 新しい `generate_configs.py` で正しく `tfvars` が作られ、`terraform apply` が通るか確認 。


* 
**Workflow / Scheduler 連動テスト**: Scheduler から Workflow を経由して Job に「シークレット名」が正しく渡り、Slack 通知が飛ぶかを確認 。



---

### 📈 ハイブリッド構成のアーキテクチャ図

---

### 💡 導入後の運用イメージ

| 項目 | 管理場所 | 変更時のアクション |
| --- | --- | --- |
| **新規顧客の追加** | スプレッドシート | 行を追加し、CSV保存 → `generate` → `terraform apply` 

 |
| **Webhook URL の変更** | Secret Manager | バージョンを更新（Terraform の再実行は不要） |
| **分析期間の変更** | スプレッドシート | <br>`time_range_interval` を書き換え → `generate` → `terraform apply` 

 |

### 🚀 次のステップ

まずは、既存の `main.py`  に **「Secret Manager から値を取り出す関数」** を追加するコードのプロトタイプを作成しましょうか？ これにより、環境変数に「URLの実体」ではなく「シークレット名」が入っていても動作するようになります。