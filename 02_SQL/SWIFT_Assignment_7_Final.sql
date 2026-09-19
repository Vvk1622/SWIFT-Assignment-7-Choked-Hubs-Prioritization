-- ============================================================
-- SWIFT Assignment 7 - Choked Hubs Prioritization
-- Final SQL Submission
-- ============================================================
--
-- Purpose:
-- Identify courier warehouses that should be prioritized
-- for clearing based on historical and current warehouse
-- dwell-time performance.
--
-- Database: PostgreSQL
-- Analysis Cutoff Date: 07-Oct-2023
--
-- Final output categories:
--   1. Prioritize for Clearing
--   2. Ignore
--
-- ============================================================


-- ============================================================
-- 1. CREATE SCHEMA AND RAW TABLE
-- ============================================================

CREATE SCHEMA IF NOT EXISTS swift;

DROP TABLE IF EXISTS swift.raw_shipments;

CREATE TABLE swift.raw_shipments (
    id SERIAL PRIMARY KEY,
    data JSONB NOT NULL
);


-- ============================================================
-- NOTE:
-- The NDJSON dataset is loaded into swift.raw_shipments
-- before running the analytical sections below.
--
-- The original dataset contains 100,786 shipment records.
-- ============================================================


-- ============================================================
-- 2. FLATTEN NESTED TRACKING EVENTS
-- ============================================================

DROP TABLE IF EXISTS swift.shipment_tracking;

CREATE TABLE swift.shipment_tracking AS
SELECT
    r.data->>'shipment_id' AS shipment_id,
    r.data->>'latest_status' AS latest_status,

    (track_event->>'ctime')::timestamptz AS event_time,

    NULLIF(
        TRIM(track_event->>'location'),
        ''
    ) AS location

FROM swift.raw_shipments r

CROSS JOIN LATERAL jsonb_array_elements(
    r.data->'deduped_track_details'
) AS track_event

WHERE NULLIF(
    TRIM(track_event->>'location'),
    ''
) IS NOT NULL;


-- ============================================================
-- 3. CLEAN AND NORMALIZE WAREHOUSE LOCATIONS
-- ============================================================

DROP TABLE IF EXISTS swift.shipment_tracking_clean;

CREATE TABLE swift.shipment_tracking_clean AS
SELECT
    shipment_id,
    latest_status,
    event_time,
    LOWER(TRIM(location)) AS warehouse

FROM swift.shipment_tracking

WHERE NULLIF(
    TRIM(location),
    ''
) IS NOT NULL;


-- ============================================================
-- 4. IDENTIFY CONTINUOUS WAREHOUSE STAYS
-- ============================================================
--
-- A warehouse stay represents the period during which a
-- shipment remains at the same warehouse.
--
-- Events are ordered chronologically because the source
-- tracking array is not guaranteed to be chronological.
--


DROP TABLE IF EXISTS swift.warehouse_stays;

CREATE TABLE swift.warehouse_stays AS

WITH ordered_events AS (

    SELECT
        shipment_id,
        latest_status,
        event_time,
        warehouse,

        LAG(warehouse) OVER (
            PARTITION BY shipment_id
            ORDER BY event_time
        ) AS previous_warehouse

    FROM swift.shipment_tracking_clean
),

stay_groups AS (

    SELECT
        *,
        
        SUM(
            CASE
                WHEN previous_warehouse IS NULL
                  OR previous_warehouse <> warehouse
                THEN 1
                ELSE 0
            END
        ) OVER (
            PARTITION BY shipment_id
            ORDER BY event_time
        ) AS stay_id

    FROM ordered_events
),

stay_start AS (

    SELECT
        shipment_id,
        latest_status,
        warehouse,
        stay_id,
        MIN(event_time) AS entry_time

    FROM stay_groups

    GROUP BY
        shipment_id,
        latest_status,
        warehouse,
        stay_id
),

stay_with_exit AS (

    SELECT
        *,
        
        LEAD(entry_time) OVER (
            PARTITION BY shipment_id
            ORDER BY entry_time
        ) AS exit_time

    FROM stay_start
)

SELECT
    shipment_id,
    latest_status,
    warehouse,
    entry_time,
    exit_time,

    CASE
        WHEN exit_time IS NOT NULL
        THEN EXTRACT(
            EPOCH FROM (exit_time - entry_time)
        ) / 3600
        ELSE NULL
    END AS dwell_hours

FROM stay_with_exit;


-- ============================================================
-- 5. ESTABLISH DATA-DRIVEN LONG-STAY THRESHOLD
-- ============================================================
--
-- The 95th percentile of completed warehouse-stay duration
-- is used as the empirical long-stay threshold.
--
-- Observed threshold:
-- 51.26277777777778 hours
-- approximately 51.26 hours.
--
-- A stay above this value is considered unusually long
-- relative to observed completed stays.
-- ============================================================


DROP TABLE IF EXISTS swift.warehouse_threshold;

CREATE TABLE swift.warehouse_threshold AS

SELECT
    PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY dwell_hours
        ) AS long_stay_threshold_hours

FROM swift.warehouse_stays

WHERE exit_time IS NOT NULL
  AND dwell_hours >= 0;


-- ============================================================
-- 6. HISTORICAL WAREHOUSE PERFORMANCE
-- ============================================================

DROP TABLE IF EXISTS swift.warehouse_performance;

CREATE TABLE swift.warehouse_performance AS

SELECT
    ws.warehouse,

    COUNT(*) AS completed_stays,

    COUNT(*) FILTER (
        WHERE ws.dwell_hours >
              51.26277777777778
    ) AS historical_long_stays,

    (
        COUNT(*) FILTER (
            WHERE ws.dwell_hours >
                  51.26277777777778
        )::numeric
        / COUNT(*)
    ) * 100 AS historical_long_stay_rate_pct,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY ws.dwell_hours
        ) AS median_dwell_hours,

    PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY ws.dwell_hours
        ) AS p95_dwell_hours

FROM swift.warehouse_stays ws

WHERE ws.exit_time IS NOT NULL
  AND ws.dwell_hours >= 0

GROUP BY ws.warehouse;


-- ============================================================
-- 7. CURRENT / OPEN WAREHOUSE STAYS
-- ============================================================
--
-- Current analysis cutoff:
-- 07-Oct-2023 23:59:59 IST
--
-- Only active shipment statuses are considered:
--   In Transit
--   Out for Delivery
--
-- ============================================================


DROP TABLE IF EXISTS swift.open_warehouse_stays;

CREATE TABLE swift.open_warehouse_stays AS

WITH last_stay AS (

    SELECT
        shipment_id,
        latest_status,
        warehouse,
        entry_time,
        exit_time,

        ROW_NUMBER() OVER (
            PARTITION BY shipment_id
            ORDER BY entry_time DESC
        ) AS rn

    FROM swift.warehouse_stays
)

SELECT
    shipment_id,
    latest_status,
    warehouse,
    entry_time,

    ROUND(
        EXTRACT(
            EPOCH FROM (
                TIMESTAMPTZ
                '2023-10-07 23:59:59+05:30'
                - entry_time
            )
        ) / 3600,
        2
    ) AS open_dwell_hours

FROM last_stay

WHERE rn = 1

  AND exit_time IS NULL

  AND LOWER(TRIM(latest_status)) IN (
      'in transit',
      'out for delivery'
  )

  AND entry_time <=
      TIMESTAMPTZ
      '2023-10-07 23:59:59+05:30';


-- ============================================================
-- 8. CURRENT WAREHOUSE PERFORMANCE
-- ============================================================

DROP TABLE IF EXISTS swift.open_warehouse_metrics;

CREATE TABLE swift.open_warehouse_metrics AS

SELECT
    warehouse,

    COUNT(*) AS open_stays,

    COUNT(*) FILTER (
        WHERE open_dwell_hours >
              51.26277777777778
    ) AS open_long_stays,

    (
        COUNT(*) FILTER (
            WHERE open_dwell_hours >
                  51.26277777777778
        )::numeric
        / COUNT(*)
    ) * 100 AS open_long_stay_rate_pct,

    MAX(open_dwell_hours)
        AS max_open_dwell_hours,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY open_dwell_hours
        ) AS median_open_dwell_hours

FROM swift.open_warehouse_stays

WHERE open_dwell_hours >= 0

GROUP BY warehouse;


-- ============================================================
-- 9. HISTORICAL CHOKE BENCHMARK
-- ============================================================
--
-- Minimum observation requirement:
-- 20 completed stays.
--
-- Historical long-stay-rate benchmark:
-- 75th percentile = 4.59%
--
-- A warehouse is historically choked when:
--
-- completed_stays >= 20
-- AND historical_long_stay_rate > 4.59%
-- ============================================================


DROP TABLE IF EXISTS swift.historical_benchmark;

CREATE TABLE swift.historical_benchmark AS

SELECT
    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY historical_long_stay_rate_pct
        ) AS historical_rate_p75

FROM swift.warehouse_performance

WHERE completed_stays >= 20;


-- ============================================================
-- 10. CURRENT CHOKE BENCHMARK
-- ============================================================
--
-- Minimum observation requirement:
-- 20 open stays.
--
-- Current benchmarks:
--   P75 open long stays = 10
--   P75 open long-stay rate = 16.80%
--
-- A warehouse is currently choked when:
--
-- open_stays >= 20
-- AND open_long_stays > 10
-- AND open_long_stay_rate > 16.80%
-- ============================================================


DROP TABLE IF EXISTS swift.current_benchmark;

CREATE TABLE swift.current_benchmark AS

SELECT
    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY open_stays
        ) AS open_stays_p75,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY open_long_stays
        ) AS open_long_stays_p75,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY open_long_stay_rate_pct
        ) AS open_long_stay_rate_p75

FROM swift.open_warehouse_metrics

WHERE open_stays >= 20;


-- ============================================================
-- 11. COMBINE HISTORICAL AND CURRENT PERFORMANCE
-- ============================================================

DROP TABLE IF EXISTS swift.final_warehouse_prioritization;

CREATE TABLE swift.final_warehouse_prioritization AS

SELECT

    COALESCE(h.warehouse, c.warehouse)
        AS warehouse,

    COALESCE(
        h.completed_stays,
        0
    ) AS completed_stays,

    COALESCE(
        h.historical_long_stays,
        0
    ) AS historical_long_stays,

    COALESCE(
        h.historical_long_stay_rate_pct,
        0
    ) AS historical_long_stay_rate_pct,

    COALESCE(
        c.open_stays,
        0
    ) AS open_stays,

    COALESCE(
        c.open_long_stays,
        0
    ) AS open_long_stays,

    COALESCE(
        c.open_long_stay_rate_pct,
        0
    ) AS open_long_stay_rate_pct,

    COALESCE(
        c.max_open_dwell_hours,
        0
    ) AS max_open_dwell_hours,

    CASE

        WHEN
            COALESCE(h.completed_stays, 0) >= 20
            AND COALESCE(
                h.historical_long_stay_rate_pct,
                0
            ) > 4.59

        OR

            COALESCE(c.open_stays, 0) >= 20
            AND COALESCE(c.open_long_stays, 0) > 10
            AND COALESCE(
                c.open_long_stay_rate_pct,
                0
            ) > 16.80

        THEN 'Prioritize for Clearing'

        ELSE 'Ignore'

    END AS category,

    CASE

        WHEN
            COALESCE(h.completed_stays, 0) >= 20
            AND COALESCE(
                h.historical_long_stay_rate_pct,
                0
            ) > 4.59

        AND

            COALESCE(c.open_stays, 0) >= 20
            AND COALESCE(c.open_long_stays, 0) > 10
            AND COALESCE(
                c.open_long_stay_rate_pct,
                0
            ) > 16.80

        THEN 'Both historical and current'

        WHEN
            COALESCE(h.completed_stays, 0) >= 20
            AND COALESCE(
                h.historical_long_stay_rate_pct,
                0
            ) > 4.59

        THEN 'Historical only'

        WHEN
            COALESCE(c.open_stays, 0) >= 20
            AND COALESCE(c.open_long_stays, 0) > 10
            AND COALESCE(
                c.open_long_stay_rate_pct,
                0
            ) > 16.80

        THEN 'Current only'

        ELSE 'No choke signal'

    END AS choke_reason

FROM swift.warehouse_performance h

FULL OUTER JOIN swift.open_warehouse_metrics c

    ON h.warehouse = c.warehouse;


-- ============================================================
-- 12. PRIORITY SCORE
-- ============================================================
--
-- Priority score is used only to order warehouses that have
-- already been classified as "Prioritize for Clearing".
--
-- Score components:
--
-- 40% Current long-stay volume
-- 25% Current long-stay rate
-- 20% Historical long-stay rate
-- 15% Historical long-stay volume
--
-- Each component is normalized against the maximum observed
-- value so the final score ranges approximately from 0 to 100.
-- ============================================================


DROP TABLE IF EXISTS swift.final_warehouse_ranked;

CREATE TABLE swift.final_warehouse_ranked AS

WITH scored AS (

    SELECT
        f.*,

        CASE
            WHEN MAX(open_long_stays)
                 OVER () = 0
            THEN 0

            ELSE
                open_long_stays::numeric
                / MAX(open_long_stays)
                  OVER ()

        END AS current_volume_score,


        CASE
            WHEN
                open_stays >= 20
                AND MAX(open_long_stay_rate_pct)
                    OVER () > 0

            THEN
                open_long_stay_rate_pct::numeric
                / MAX(open_long_stay_rate_pct)
                  OVER ()

            ELSE 0

        END AS current_rate_score,


        CASE
            WHEN
                MAX(historical_long_stay_rate_pct)
                OVER () = 0

            THEN 0

            ELSE
                historical_long_stay_rate_pct::numeric
                / MAX(historical_long_stay_rate_pct)
                  OVER ()

        END AS historical_rate_score,


        CASE
            WHEN
                MAX(historical_long_stays)
                OVER () = 0

            THEN 0

            ELSE
                historical_long_stays::numeric
                / MAX(historical_long_stays)
                  OVER ()

        END AS historical_volume_score

    FROM swift.final_warehouse_prioritization f
),

final_score AS (

    SELECT
        *,

        ROUND(
            (
                0.40 * current_volume_score
                + 0.25 * current_rate_score
                + 0.20 * historical_rate_score
                + 0.15 * historical_volume_score
            ) * 100,
            2
        ) AS priority_score

    FROM scored
)

SELECT

    warehouse,

    completed_stays,

    historical_long_stays,

    historical_long_stay_rate_pct,

    open_stays,

    open_long_stays,

    open_long_stay_rate_pct,

    max_open_dwell_hours,

    category,

    choke_reason,

    priority_score,

    CASE
        WHEN category =
             'Prioritize for Clearing'

        THEN RANK() OVER (
            PARTITION BY category
            ORDER BY priority_score DESC
        )

    END AS priority_rank,

    CASE
        WHEN category = 'Ignore'

        THEN RANK() OVER (
            PARTITION BY category
            ORDER BY priority_score ASC
        )

    END AS ignore_rank

FROM final_score;


-- ============================================================
-- 13. FINAL RESULT
-- ============================================================

SELECT

    priority_rank,

    ignore_rank,

    warehouse,

    category,

    priority_score,

    completed_stays,

    historical_long_stays,

    ROUND(
        historical_long_stay_rate_pct,
        2
    ) AS historical_long_stay_rate_pct,

    open_stays,

    open_long_stays,

    ROUND(
        open_long_stay_rate_pct,
        2
    ) AS open_long_stay_rate_pct,

    max_open_dwell_hours

FROM swift.final_warehouse_ranked

ORDER BY

    CASE
        WHEN category =
             'Prioritize for Clearing'
        THEN 1
        ELSE 2
    END,

    priority_rank NULLS LAST,

    warehouse;


-- ============================================================
-- 14. VALIDATION SUMMARY
-- ============================================================

SELECT
    COUNT(*) AS total_warehouses,

    COUNT(*) FILTER (
        WHERE category =
              'Prioritize for Clearing'
    ) AS warehouses_to_prioritize,

    COUNT(*) FILTER (
        WHERE category = 'Ignore'
    ) AS warehouses_to_ignore

FROM swift.final_warehouse_ranked;


-- ============================================================
-- 15. CHOKE REASON SUMMARY
-- ============================================================

SELECT
    choke_reason,
    COUNT(*) AS warehouse_count

FROM swift.final_warehouse_prioritization

GROUP BY choke_reason

ORDER BY warehouse_count DESC;


-- ============================================================
-- END OF FINAL SQL SUBMISSION
-- ============================================================