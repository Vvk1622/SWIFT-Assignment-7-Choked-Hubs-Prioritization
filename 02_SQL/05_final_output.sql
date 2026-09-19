-- ============================================================
-- SWIFT Assignment 7 - Choked Hubs Prioritization
-- File: 05_final_output.sql
-- Purpose: Create final warehouse prioritization output
-- ============================================================


-- ============================================================
-- STEP 1: Create priority score
-- ============================================================
--
-- The priority score combines current and historical
-- warehouse performance.
--
-- Current performance receives higher weight because the
-- objective is to identify warehouses requiring operational
-- attention as of 07-Oct-2023.
--
-- Score components:
--
-- 40% = Current long-stay volume
-- 25% = Current long-stay rate
-- 20% = Historical long-stay rate
-- 15% = Historical long-stay volume
--
-- Score range: approximately 0 to 100.
-- ============================================================

DROP TABLE IF EXISTS swift.final_warehouse_ranked;

CREATE TABLE swift.final_warehouse_ranked AS

WITH scored AS (

    SELECT
        f.*,


        -- ----------------------------------------------------
        -- Current volume score
        -- ----------------------------------------------------

        CASE

            WHEN MAX(open_long_stays) OVER () = 0

            THEN 0

            ELSE
                open_long_stays::numeric
                / MAX(open_long_stays) OVER ()

        END AS current_volume_score,


        -- ----------------------------------------------------
        -- Current rate score
        -- ----------------------------------------------------

        CASE

            WHEN
                open_stays >= 20
                AND MAX(open_long_stay_rate_pct) OVER () > 0

            THEN
                open_long_stay_rate_pct::numeric
                / MAX(open_long_stay_rate_pct) OVER ()

            ELSE 0

        END AS current_rate_score,


        -- ----------------------------------------------------
        -- Historical rate score
        -- ----------------------------------------------------

        CASE

            WHEN MAX(
                historical_long_stay_rate_pct
            ) OVER () = 0

            THEN 0

            ELSE
                historical_long_stay_rate_pct::numeric
                / MAX(
                    historical_long_stay_rate_pct
                ) OVER ()

        END AS historical_rate_score,


        -- ----------------------------------------------------
        -- Historical volume score
        -- ----------------------------------------------------

        CASE

            WHEN MAX(
                historical_long_stays
            ) OVER () = 0

            THEN 0

            ELSE
                historical_long_stays::numeric
                / MAX(
                    historical_long_stays
                ) OVER ()

        END AS historical_volume_score


    FROM swift.final_warehouse_prioritization f
),


-- ============================================================
-- STEP 2: Calculate weighted priority score
-- ============================================================

final_score AS (

    SELECT
        *,

        ROUND(

            (
                0.40 * current_volume_score
                +
                0.25 * current_rate_score
                +
                0.20 * historical_rate_score
                +
                0.15 * historical_volume_score
            ) * 100,

            2

        ) AS priority_score

    FROM scored
)


-- ============================================================
-- STEP 3: Create final ranked table
-- ============================================================

SELECT

    warehouse,

    completed_stays,

    historical_long_stays,

    ROUND(
        historical_long_stay_rate_pct::numeric,
        2
    ) AS historical_long_stay_rate_pct,

    open_stays,

    open_long_stays,

    ROUND(
        open_long_stay_rate_pct::numeric,
        2
    ) AS open_long_stay_rate_pct,

    ROUND(
        max_open_dwell_hours::numeric,
        2
    ) AS max_open_dwell_hours,

    category,

    priority_score,


    -- --------------------------------------------------------
    -- Priority rank
    -- --------------------------------------------------------
    --
    -- Only warehouses classified as Prioritize for Clearing
    -- receive a priority rank.
    -- --------------------------------------------------------

    CASE

        WHEN category = 'Prioritize for Clearing'

        THEN RANK() OVER (
            PARTITION BY category
            ORDER BY priority_score DESC
        )

    END AS priority_rank,


    -- --------------------------------------------------------
    -- Ignore rank
    -- --------------------------------------------------------
    --
    -- Ignore warehouses are ranked separately from lowest
    -- score upward.
    -- --------------------------------------------------------

    CASE

        WHEN category = 'Ignore'

        THEN RANK() OVER (
            PARTITION BY category
            ORDER BY priority_score ASC
        )

    END AS ignore_rank


FROM final_score;


-- ============================================================
-- STEP 4: Check final category distribution
-- ============================================================

SELECT
    category,
    COUNT(*) AS warehouse_count

FROM swift.final_warehouse_ranked

GROUP BY category

ORDER BY category;


/*
Expected structure:

| Category                | Warehouse Count |
| ----------------------- | ---------------: |
| Ignore                  |                |
| Prioritize for Clearing |                |
*/


-- ============================================================
-- STEP 5: Check top prioritized warehouses
-- ============================================================
--
-- These are the warehouses receiving the highest priority
-- score under the defined scoring framework.
-- ============================================================

SELECT

    priority_rank,
    warehouse,
    category,
    priority_score,

    completed_stays,
    historical_long_stays,
    historical_long_stay_rate_pct,

    open_stays,
    open_long_stays,
    open_long_stay_rate_pct,

    max_open_dwell_hours

FROM swift.final_warehouse_ranked

WHERE category = 'Prioritize for Clearing'

ORDER BY
    priority_rank

LIMIT 20;


/*
Top results will be used to understand the final
prioritization output.
*/


-- ============================================================
-- STEP 6: Final output for CSV
-- ============================================================
--
-- This is the exact dataset that should be exported
-- from pgAdmin as the final CSV.
-- ============================================================

SELECT

    priority_rank,

    ignore_rank,

    warehouse,

    category,

    priority_score,

    completed_stays,

    historical_long_stays,

    historical_long_stay_rate_pct,

    open_stays,

    open_long_stays,

    open_long_stay_rate_pct,

    max_open_dwell_hours

FROM swift.final_warehouse_ranked

ORDER BY

    CASE

        WHEN category = 'Prioritize for Clearing'
        THEN 1

        ELSE 2

    END,

    priority_rank NULLS LAST,

    ignore_rank NULLS LAST;


-- ============================================================
-- STEP 7: Final validation
-- ============================================================

SELECT

    COUNT(*) AS total_warehouses,

    COUNT(*) FILTER (
        WHERE category = 'Prioritize for Clearing'
    ) AS warehouses_to_prioritize,

    COUNT(*) FILTER (
        WHERE category = 'Ignore'
    ) AS warehouses_to_ignore

FROM swift.final_warehouse_ranked;


/*
Final validation output will give:

total_warehouses
warehouses_to_prioritize
warehouses_to_ignore
*/


-- ============================================================
-- END OF 05_final_output.sql
-- ============================================================