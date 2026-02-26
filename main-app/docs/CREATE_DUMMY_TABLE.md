残念ながら、Googleが公開している `bigquery-public-data` には、`INFORMATION_SCHEMA` （メタデータ）のサンプルデータはありません。これは、プロジェクト固有の機密情報（誰がいつ何をクエリしたか）そのものだからです。

しかし、**「本物と全く同じスキーマ（構造）を持つダミーテーブル」** をご自身の環境に作り、そこに「テストしたいパターンのデータ」を流し込むことで、完璧なテスト環境を作ることができます。

以下の手順で、**「ワーストクエリ」や「スケジュールクエリ」が混在するダミーデータ** を作成してください。

### 手順1: ダミーテーブルの枠を作る

まず、本物の `INFORMATION_SCHEMA` から構造だけをコピーして、空のテーブルを作ります。これで型定義（ARRAYやSTRUCTなど）が完全に一致します。

```sql
-- 自分のプロジェクトのデータセットを指定してください
CREATE OR REPLACE TABLE `your_project.your_dataset.mock_jobs`
AS
SELECT *
FROM `region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT` -- リージョンに合わせて変更
WHERE FALSE; -- データはコピーせず、枠だけ作る

```

### 手順2: テストデータを流し込む (INSERT)

分析ロジック（コスト判定、実行者判定、AIへのプロンプト）をテストするために必要な **「典型的な4つのパターン」** を用意しました。これをそのまま実行してください。

```sql
INSERT INTO `your_project.your_dataset.mock_jobs` (
  job_id,
  creation_time,
  start_time,
  end_time,
  user_email,
  job_type,
  statement_type,
  query,
  total_bytes_billed,
  total_slot_ms,
  state,
  error_result,
  labels
)
VALUES
  -- 1. 【Human / High Cost】人間が実行した「SELECT *」の激重クエリ
  (
    'job_human_worst_001',
    CURRENT_TIMESTAMP(),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 MINUTE),
    CURRENT_TIMESTAMP(),
    'engineer-tanaka@your-company.com', -- 人間のメアド
    'QUERY',
    'SELECT',
    'SELECT * FROM `bigquery-public-data.github_repos.contents` WHERE content LIKE "%password%"', -- AIに怒られるSQL
    5497558138880, -- 5 TB (約$30) の課金
    360000000,     -- 100時間分のスロット消費 (重い)
    'DONE',
    NULL,
    [] -- ラベルなし
  ),

  -- 2. 【Scheduled Query / Low Cost】定期実行クエリ (コンソールで修正可能)
  (
    'job_scheduled_001',
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 61 MINUTE),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 MINUTE),
    'bigquery-admin@your-project.iam.gserviceaccount.com',
    'QUERY',
    'SELECT',
    'SELECT date, count(*) FROM `daily_logs` GROUP BY 1', -- まともなSQL
    1073741824,    -- 1 GB
    1000,          -- 軽い
    'DONE',
    NULL,
    [STRUCT('data_source_id', 'scheduled_query')] -- ★スケジュールクエリ判定用ラベル
  ),

  -- 3. 【App (Service Account) / Medium Cost】アプリからの自動実行 (コード修正が必要)
  (
    'job_app_run_001',
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 121 MINUTE),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 120 MINUTE),
    'backend-service@your-project.iam.gserviceaccount.com', -- SAのメアド
    'QUERY',
    'SELECT',
    'SELECT id, name FROM users CROSS JOIN logs', -- CROSS JOINのアンチパターン
    107374182400,  -- 100 GB
    7200000,       -- 2時間分のスロット消費
    'DONE',
    NULL,
    [STRUCT('source', 'cloud_run_app')] -- アプリ判定用ラベル
  ),

  -- 4. 【Error Job】失敗したクエリ
  (
    'job_error_001',
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 HOUR),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 181 MINUTE),
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 180 MINUTE),
    'new-member@your-company.com',
    'QUERY',
    'SELECT',
    'SELECT * FROM non_existent_table',
    0, -- 失敗したので課金ゼロ
    0,
    'DONE',
    STRUCT('NotFound' as reason, 'Not found: Table ...' as message, 'global' as location, 'debugInfo' as debugInfo),
    []
  );

```

### 手順3: テスト用スクリプトの修正

これで、`your_project.your_dataset.mock_jobs` というテーブルに、テストしたい全パターンのデータが入りました。

先ほど作成したPythonスクリプト（`test_analyzer.py`）やSQLの **`FROM` 句を書き換えるだけ** でテスト可能です。

**修正前:**

```sql
FROM `region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`

```

**修正後 (テスト用):**

```sql
FROM `your-project.your_dataset.mock_jobs` -- ここをダミーテーブルに向ける

```

### このデータの使い道

* **Geminiのテスト:** `job_human_worst_001` のSQL（`SELECT * ... LIKE ...`）が渡されたとき、Geminiが「フルスキャンが発生しています。LIKE検索は避け、検索インデックスを検討してください」と返してくるか確認できます。
* **ロジックのテスト:** `job_scheduled_001` が正しく「Scheduled_Query (難易度: Low)」に分類されるか確認できます。
