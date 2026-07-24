# Architecture Decision Records (ADR)

アーキテクチャ上の重要な決定を記録する。新規追加時は連番でファイルを作成する。

| No.                                              | タイトル                                                                       | ステータス |
| :----------------------------------------------- | :----------------------------------------------------------------------------- | :--------- |
| [0001](0001-notification-channels.md)            | 通知チャネルの使い分け（失敗＝Monitoring/Email、成功＝Workflow/Slack Webhook） | Accepted   |
| [0002](0002-failure-detection-workflow-layer.md) | 失敗検知は Workflow 層で行い、復旧不能エラーは exit 1 にする                   | Accepted   |
| [0003](0003-signed-url-delivery.md)              | レポートは顧客 GCS に保存し、期限付き V4 署名付きURLで配信する                 | Accepted   |
| [0004](0004-terraform-state-backend.md)          | Terraform の state backend は本ツール同梱の bootstrap で自動構築する           | Accepted   |
