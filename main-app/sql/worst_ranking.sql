WITH base_data AS (
    SELECT
        user_email,
        job_id,
        creation_time,
        query,
        project_id,

        -- 1. コスト評価 (Scan)
        total_bytes_billed / 1024 / 1024 / 1024 AS billed_gb,

        -- 2. 時間評価 (Duration & Load)
        TIMESTAMP_DIFF(end_time, start_time, SECOND) AS duration_seconds,
        total_slot_ms / 1000 / 3600 AS slot_hours,

        -- 3. 実行者判定
        CASE
            WHEN EXISTS(SELECT 1 FROM UNNEST(labels) WHERE key = 'data_source_id' AND value = 'scheduled_query') THEN 'Scheduled_Query'
            WHEN REGEXP_CONTAINS(user_email, r'\.gserviceaccount\.com$') THEN 'Service_Account_App'
            ELSE 'Human_User'
        END AS source_type,

        -- 4. 改善難易度判定
        CASE
            WHEN EXISTS(SELECT 1 FROM UNNEST(labels) WHERE key = 'data_source_id' AND value = 'scheduled_query') THEN 'Low'
            WHEN REGEXP_CONTAINS(user_email, r'\.gserviceaccount\.com$') THEN 'High'
            ELSE 'Medium'
        END AS difficulty,

        -- どのリージョンの結果か
        '{region}' AS region_name

    FROM
        `{target_project}`.`region-{region}`.INFORMATION_SCHEMA.JOBS_BY_PROJECT

    WHERE
        -- 調査期間
        creation_time >= {start_time_expr}
        {end_time_expr}

        AND job_type = 'QUERY'
        AND statement_type = 'SELECT'
        AND error_result IS NULL

        -- スキャン量が0バイトのクエリ（テーブル未参照など）を除外
        AND total_bytes_billed > 0

        -- 除外ロジック:
        -- 1. SaaS側の監査システム自身が実行したクエリを除外
        AND user_email != '{analyzer_email}'
        -- 2. メタデータ取得クエリはチューニングの余地がないため、誰が実行したかにかかわらず一律除外
        --    ※ (?i) を付けて大文字・小文字 (information_schema等) のブレを吸収する
        AND NOT REGEXP_CONTAINS(query, r'(?i)INFORMATION_SCHEMA')
)

SELECT *
FROM base_data
WHERE query IS NOT NULL

-- スキャン量ワースト{limit}、または実行時間ワースト{limit} の「どちらか」に該当する行だけを残す
QUALIFY
    ROW_NUMBER() OVER(ORDER BY billed_gb DESC) <= {limit}
    OR
    ROW_NUMBER() OVER(ORDER BY duration_seconds DESC) <= {limit};
    -- ROW_NUMBER() OVER(ORDER BY billed_gb DESC) <= 10
    -- OR
    -- ROW_NUMBER() OVER(ORDER BY duration_seconds DESC) <= 10;