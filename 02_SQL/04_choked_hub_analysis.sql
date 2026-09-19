-- ============================================================
-- SWIFT Assignment 7
-- Choked Hub Analysis
-- ============================================================


-- ============================================================
-- Step 1: Calculate exact historical warehouse performance
-- ============================================================
--
-- Historical long stay threshold:
-- 95th percentile of completed warehouse dwell time
-- = 51.26277777777778 hours
--
-- A completed stay above this threshold is treated
-- as a long stay.
-- ============================================================

DROP TABLE IF EXISTS swift.historical_warehouse_performance_exact;

CREATE TABLE swift.historical_warehouse_performance_exact AS

SELECT
    warehouse,

    COUNT(*) AS completed_stays,

    COUNT(*) FILTER (
        WHERE dwell_hours > 51.26277777777778
    ) AS historical_long_stays,

    (
        COUNT(*) FILTER (
            WHERE dwell_hours > 51.26277777777778
        )::numeric
        / COUNT(*)
    ) * 100 AS historical_long_stay_rate_pct,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY dwell_hours
        ) AS historical_median_dwell_hours,

    PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY dwell_hours
        ) AS historical_p95_dwell_hours

FROM swift.warehouse_stays

WHERE exit_time IS NOT NULL
  AND dwell_hours >= 0

GROUP BY warehouse;


-- ============================================================
-- Step 2: Historical warehouse benchmark
-- ============================================================
--
-- Only warehouses with at least 20 completed stays
-- are considered.
--
-- The 75th percentile of historical long-stay rate
-- is used as the historical choke benchmark.
-- ============================================================

SELECT
    COUNT(*) AS warehouse_count,

    COUNT(*) FILTER (
        WHERE completed_stays >= 20
    ) AS warehouses_with_min_sample,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY historical_long_stay_rate_pct
        ) FILTER (
            WHERE completed_stays >= 20
        ) AS exact_historical_rate_threshold

FROM swift.historical_warehouse_performance_exact;

-- Expected output:
-- 6261    658    4.5925


-- ============================================================
-- Step 3: Identify historically choked warehouses
-- ============================================================
--
-- Historical Choke definition:
--
-- Completed Stays >= 20
-- AND
-- Historical Long-Stay Rate > 4.5925%
-- ============================================================

DROP TABLE IF EXISTS swift.historical_choked_warehouses;

CREATE TABLE swift.historical_choked_warehouses AS

SELECT
    warehouse,
    completed_stays,
    historical_long_stays,
    historical_long_stay_rate_pct,
    historical_median_dwell_hours,
    historical_p95_dwell_hours,

    CASE
        WHEN completed_stays >= 20
             AND historical_long_stay_rate_pct > 4.5925
        THEN 'Historical Choke'
        ELSE 'Not Historical Choke'
    END AS historical_status

FROM swift.historical_warehouse_performance_exact;


-- Validation

SELECT
    historical_status,
    COUNT(*) AS warehouse_count

FROM swift.historical_choked_warehouses

GROUP BY historical_status

ORDER BY historical_status;

-- Output:
-- "Historical Choke"       165
-- "Not Historical Choke"   6096


-- ============================================================
-- Step 4: Calculate exact current/open warehouse performance
-- ============================================================
--
-- Active shipments are analysed as of:
-- 07-Oct-2023
--
-- Active statuses:
--     In Transit
--     Out for Delivery
--
-- Current long stay threshold:
-- 51.26277777777778 hours
-- ============================================================

DROP TABLE IF EXISTS swift.current_warehouse_performance_exact;

CREATE TABLE swift.current_warehouse_performance_exact AS

SELECT
    warehouse,

    COUNT(*) AS open_stays,

    COUNT(*) FILTER (
        WHERE open_dwell_hours > 51.26277777777778
    ) AS open_long_stays,

    (
        COUNT(*) FILTER (
            WHERE open_dwell_hours > 51.26277777777778
        )::numeric
        / COUNT(*)
    ) * 100 AS open_long_stay_rate_pct,

    MAX(open_dwell_hours) AS max_open_dwell_hours,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY open_dwell_hours
        ) AS median_open_dwell_hours

FROM swift.open_warehouse_stays

WHERE open_dwell_hours >= 0

GROUP BY warehouse;


-- ============================================================
-- Step 5: Current warehouse benchmarks
-- ============================================================
--
-- Minimum active stays = 20
--
-- 75th percentile benchmarks:
-- Open long stays = 10
-- Open long-stay rate = 16.80%
-- ============================================================

SELECT
    COUNT(*) AS warehouse_count,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY open_stays
        ) AS median_open_stays,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY open_stays
        ) AS p75_open_stays,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY open_long_stays
        ) AS median_open_long_stays,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY open_long_stays
        ) AS p75_open_long_stays,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY open_long_stay_rate_pct
        ) AS median_open_long_stay_rate_pct,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY open_long_stay_rate_pct
        ) AS p75_open_long_stay_rate_pct

FROM swift.current_warehouse_performance_exact

WHERE open_stays >= 20;

-- Output:
-- 147    39.00    91.00    3.00    10.00    5.00    16.80


-- ============================================================
-- Step 6: Identify currently choked warehouses
-- ============================================================
--
-- Current Choke definition:
--
-- Open Stays >= 20
-- AND
-- Open Long Stays > 10
-- AND
-- Open Long-Stay Rate > 16.80%
-- ============================================================

DROP TABLE IF EXISTS swift.current_choked_warehouses;

CREATE TABLE swift.current_choked_warehouses AS

SELECT
    warehouse,
    open_stays,
    open_long_stays,
    open_long_stay_rate_pct,
    max_open_dwell_hours,
    median_open_dwell_hours,

    CASE
        WHEN open_stays >= 20
             AND open_long_stays > 10
             AND open_long_stay_rate_pct > 16.80
        THEN 'Current Choke'
        ELSE 'Not Current Choke'
    END AS current_status

FROM swift.current_warehouse_performance_exact;


-- Validation

SELECT
    current_status,
    COUNT(*) AS warehouse_count

FROM swift.current_choked_warehouses

GROUP BY current_status

ORDER BY current_status;


-- ============================================================
-- Step 7: Combine historical and current choke results
-- ============================================================
--
-- Final Choked Warehouse definition:
--
-- Historical Choke OR Current Choke
--
-- If either condition is satisfied:
--     Prioritize for Clearing
--
-- Otherwise:
--     Ignore
-- ============================================================

DROP TABLE IF EXISTS swift.final_warehouse_prioritization;

CREATE TABLE swift.final_warehouse_prioritization AS

WITH combined AS (

    SELECT

        COALESCE(
            h.warehouse,
            c.warehouse
        ) AS warehouse,

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
            h.historical_median_dwell_hours,
            0
        ) AS historical_median_dwell_hours,

        COALESCE(
            h.historical_p95_dwell_hours,
            0
        ) AS historical_p95_dwell_hours,

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

        COALESCE(
            c.median_open_dwell_hours,
            0
        ) AS median_open_dwell_hours

    FROM swift.historical_warehouse_performance_exact h

    FULL OUTER JOIN
        swift.current_warehouse_performance_exact c

    ON h.warehouse = c.warehouse
)

SELECT

    *,

    CASE

        WHEN
            (
                completed_stays >= 20
                AND historical_long_stay_rate_pct > 4.5925
            )

            OR

            (
                open_stays >= 20
                AND open_long_stays > 10
                AND open_long_stay_rate_pct > 16.80
            )

        THEN 'Prioritize for Clearing'

        ELSE 'Ignore'

    END AS category

FROM combined;


-- ============================================================
-- Step 8: Final category summary
-- ============================================================

SELECT
    category,
    COUNT(*) AS warehouse_count

FROM swift.final_warehouse_prioritization

GROUP BY category

ORDER BY category;


-- ============================================================
-- Step 9: Identify reason for prioritization
-- ============================================================
--
-- This shows whether a warehouse is:
--     Historical Only
--     Current Only
--     Both
--     Ignore
-- ============================================================

SELECT

    CASE

        WHEN
            completed_stays >= 20
            AND historical_long_stay_rate_pct > 4.5925
            AND open_stays >= 20
            AND open_long_stays > 10
            AND open_long_stay_rate_pct > 16.80
        THEN 'Both Historical and Current'

        WHEN
            completed_stays >= 20
            AND historical_long_stay_rate_pct > 4.5925
        THEN 'Historical Only'

        WHEN
            open_stays >= 20
            AND open_long_stays > 10
            AND open_long_stay_rate_pct > 16.80
        THEN 'Current Only'

        ELSE 'Ignore'

    END AS choke_reason,

    COUNT(*) AS warehouse_count

FROM swift.final_warehouse_prioritization

GROUP BY

    CASE

        WHEN
            completed_stays >= 20
            AND historical_long_stay_rate_pct > 4.5925
            AND open_stays >= 20
            AND open_long_stays > 10
            AND open_long_stay_rate_pct > 16.80
        THEN 'Both Historical and Current'

        WHEN
            completed_stays >= 20
            AND historical_long_stay_rate_pct > 4.5925
        THEN 'Historical Only'

        WHEN
            open_stays >= 20
            AND open_long_stays > 10
            AND open_long_stay_rate_pct > 16.80
        THEN 'Current Only'

        ELSE 'Ignore'

    END

ORDER BY choke_reason;


-- ============================================================
-- END OF 04_choked_hub_analysis.sql
-- ============================================================