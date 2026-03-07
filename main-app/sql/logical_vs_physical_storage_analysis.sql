/* ストレージ最適化診断用SQL */
WITH StorageStats AS (
    SELECT
        table_schema AS dataset_name,
        -- 論理サイズ (GB)
        SUM(total_logical_bytes) / 1024 / 1024 / 1024 AS logical_gb,
        -- 物理サイズ (GB)
        SUM(total_physical_bytes) / 1024 / 1024 / 1024 AS physical_gb,
        -- タイムトラベルサイズ (GB)
        SUM(time_travel_physical_bytes) / 1024 / 1024 / 1024 AS time_travel_gb
    FROM
        `{target_project}`.`region-{region}`.INFORMATION_SCHEMA.TABLE_STORAGE
    GROUP BY
        1
)
SELECT
    dataset_name,
    logical_gb,
    physical_gb,
    -- 圧縮率
    logical_gb / NULLIF(physical_gb, 0) AS compression_ratio,
    -- 提案ロジック
    CASE
        WHEN logical_gb / NULLIF(physical_gb, 0) > 2.0 THEN '【推奨】物理ストレージへ変更 (コスト削減見込み大)'
        WHEN logical_gb / NULLIF(physical_gb, 0) BETWEEN 1.5 AND 2.0 THEN '検討 (コスト削減見込み中)'
        ELSE '現状維持 (論理ストレージのままが良い)'
    END AS recommendation
FROM
    StorageStats
WHERE
    logical_gb > 1 -- あまりに小さいデータセットは無視
ORDER BY
    compression_ratio DESC;