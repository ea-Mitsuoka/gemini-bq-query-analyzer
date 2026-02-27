-- 1. テーブルの作成 (CREATE TABLE)
CREATE OR REPLACE TABLE `<saas_project_id>.audit_master.antipattern_master` (
    pattern_name STRING NOT NULL OPTIONS(description="ツールが出力するアンチパターン名（Key）"),
    problem_description STRING NOT NULL OPTIONS(description="BigQueryのアーキテクチャ的に何が悪いのか（Why）"),
    best_practice STRING NOT NULL OPTIONS(description="Geminiに提案させるべき正しい修正案・定石（How）")
);
-- 2. マスターデータの投入 (INSERT)
INSERT INTO `<saas_project_id>.audit_master.antipattern_master` (pattern_name, problem_description, best_practice)
VALUES
    ('SimpleSelectStar',
     '必要なカラムだけを指定しないと、列指向DBであるBigQueryでは無駄なスキャン量（課金）が跳ね上がります。',
     'SELECT * を避け、必要なカラム名を明示的に指定するように修正してください。'),

    ('OrderByWithoutLimit',
     '全データを1つのノードに集めてソートしようとするため、メモリ不足（Resources exceeded）によるクエリ失敗の最大要因になります。',
     'ORDER BY を使用する場合は、必ず LIMIT 句を併用してソート対象を絞り込むように修正してください。'),

    ('CTEsEvalMultipleTimes',
     'BigQueryはWITH句をキャッシュしないため、複数回呼び出すとその都度再計算されコストと時間が倍増します。',
     '複数回参照されるCTEはWITH句ではなく、事前に一時テーブル（CREATE TEMP TABLE）に結果を退避してJOINするように修正してください。'),

    ('SemiJoinWithoutAgg',
     'WHERE句の IN (SELECT ...) などのサブクエリ結果が巨大な場合、著しくパフォーマンスが低下します。',
     'EXISTS句を使用するか、事前にGROUP BYで集計した結果をJOINするように修正してください。'),

    ('DynamicPredicate',
     '実行時まで条件が確定しない動的述語（サブクエリ等）によるフィルタは、パーティションプルーニング（読み込みスキップ）が効かずフルスキャンになりがちです。',
     '静的な値でフィルタリングするか、パーティションキーを直接指定するように修正してください。'),

    ('StringComparison',
     'LIKE や = で済む単純な比較に REGEXP_CONTAINS などの正規表現関数を使うと、CPU計算コスト（スロット）を無駄に消費します。',
     '完全一致の場合は = を、部分一致の場合は LIKE を使用するように修正してください。'),

    ('LatestRecordWithAnalyticFun',
     'ROW_NUMBER() で番号を振って外側で WHERE row_num = 1 とするのは計算コストが高いです。',
     'QUALIFY 句を使用するか、ARRAY_AGG(... ORDER BY ... LIMIT 1)[OFFSET(0)] を使用して最新行を取得するように修正してください。'),

    ('WhereOrder',
     'WHERE句の中で、計算負荷の高い関数（正規表現など）を先に評価しようとすると、無駄なCPU時間（スロット）を消費する原因になります。',
     '計算負荷の低い単純な絞り込み条件（= や IN など）をWHERE句の先頭に書き、負荷の高い関数を後に配置するように条件の順序を修正してください。');