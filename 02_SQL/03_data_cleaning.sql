-- ============================================================
-- SWIFT Assignment 7
-- Data Cleaning and Preparation
-- ============================================================


-- ============================================================
-- STEP 1: Flatten JSON tracking events
-- ============================================================
--
-- The original dataset contains tracking events inside the
-- deduped_track_details JSON array.
--
-- Each tracking event is converted into one row.
--
-- Blank tracking locations are excluded.
-- ============================================================

DROP TABLE IF EXISTS swift.shipment_tracking;

CREATE TABLE swift.shipment_tracking AS

SELECT
    r.data->>'shipment_id' AS shipment_id,
    r.data->>'latest_status' AS latest_status,

    (track_event->>'ctime')::timestamptz
        AS event_time,

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
-- STEP 2: Normalize tracking locations
-- ============================================================
--
-- Location values may have differences in capitalization
-- and extra spaces.
--
-- We standardize them using LOWER + TRIM.
--
-- We do NOT merge different operational locations into
-- city-level names because different facilities may exist
-- within the same city.
-- ============================================================

DROP TABLE IF EXISTS swift.shipment_tracking_clean;

CREATE TABLE swift.shipment_tracking_clean AS

SELECT
    shipment_id,
    latest_status,
    event_time,

    LOWER(
        TRIM(location)
    ) AS warehouse

FROM swift.shipment_tracking

WHERE NULLIF(
    TRIM(location),
    ''
) IS NOT NULL;


-- ============================================================
-- STEP 3: Create warehouse stay episodes
-- ============================================================
--
-- Tracking events are first ordered chronologically
-- for every shipment.
--
-- A new warehouse stay starts whenever the shipment moves
-- to a different warehouse.
--
-- Dwell time is calculated as:
--
-- Exit Time - Entry Time
--
-- If there is no next warehouse event, the stay remains open.
-- ============================================================

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
            EPOCH FROM (
                exit_time - entry_time
            )
        ) / 3600

        ELSE NULL
    END AS dwell_hours

FROM stay_with_exit;


-- ============================================================
-- STEP 4: Historical warehouse performance
-- ============================================================
--
-- The network-level 95th percentile of completed warehouse
-- dwell time is used as the long-stay threshold.
--
-- Exact threshold:
-- 51.26277777777778 hours
--
-- A completed stay above this threshold is treated as
-- an unusually long warehouse stay.
-- ============================================================

DROP TABLE IF EXISTS swift.warehouse_performance;

CREATE TABLE swift.warehouse_performance AS

SELECT
    warehouse,

    COUNT(*) AS completed_stays,

    COUNT(*) FILTER (
        WHERE dwell_hours > 51.26277777777778
    ) AS long_stays,

    (
        COUNT(*) FILTER (
            WHERE dwell_hours > 51.26277777777778
        )::numeric
        / COUNT(*)
    ) * 100 AS long_stay_rate_pct,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY dwell_hours
        ) AS median_dwell_hours,

    PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY dwell_hours
        ) AS p95_dwell_hours

FROM swift.warehouse_stays

WHERE exit_time IS NOT NULL
  AND dwell_hours >= 0

GROUP BY warehouse;


-- ============================================================
-- STEP 5: Identify active/open warehouse stays
-- ============================================================
--
-- Assignment analysis date:
-- 07-Oct-2023
--
-- Only operationally active shipments are considered:
--     In Transit
--     Out for Delivery
--
-- The latest warehouse stay for each shipment is selected.
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

  AND LOWER(
      TRIM(latest_status)
  ) IN (
      'in transit',
      'out for delivery'
  )

  AND entry_time <=
      TIMESTAMPTZ
      '2023-10-07 23:59:59+05:30';


-- ============================================================
-- STEP 6: Current warehouse performance
-- ============================================================
--
-- Current performance is calculated using active/open stays.
--
-- Long current stay:
-- open_dwell_hours > 51.26277777777778
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

    MAX(
        open_dwell_hours
    ) AS max_open_dwell_hours,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY open_dwell_hours
        ) AS median_open_dwell_hours

FROM swift.open_warehouse_stays

WHERE open_dwell_hours >= 0

GROUP BY warehouse;


-- ============================================================
-- STEP 7: Current warehouse benchmarks
-- ============================================================
--
-- Minimum 20 active stays are required to avoid
-- small-sample effects.
--
-- Calculated benchmarks:
--
-- P75 open stays              = 91
-- P75 open long stays         = 10
-- P75 open long-stay rate     = 16.80%
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

FROM swift.open_warehouse_metrics

WHERE open_stays >= 20;


-- ============================================================
-- STEP 8: Cleaning validation
-- ============================================================


-- Validation 1: Flattened tracking table

SELECT
    COUNT(*) AS tracking_events,
    COUNT(DISTINCT shipment_id) AS shipments,
    COUNT(DISTINCT location) AS distinct_locations

FROM swift.shipment_tracking;

-- Output:
-- 662521    100775    10357


-- Validation 2: Cleaned tracking table

SELECT
    COUNT(*) AS cleaned_tracking_events,
    COUNT(DISTINCT shipment_id) AS shipments,
    COUNT(DISTINCT warehouse) AS distinct_warehouses

FROM swift.shipment_tracking_clean;

-- Output:
-- 662521    100775    9699


-- Validation 3: Warehouse stay episodes

SELECT
    COUNT(*) AS total_stays,

    COUNT(*) FILTER (
        WHERE exit_time IS NOT NULL
    ) AS completed_stays,

    COUNT(*) FILTER (
        WHERE exit_time IS NULL
    ) AS open_stays

FROM swift.warehouse_stays;

-- Output:
-- 533725    432950    100775


-- Validation 4: Historical warehouse count

SELECT
    COUNT(*) AS warehouse_count

FROM swift.warehouse_performance;

-- Output:
-- 6261


-- Validation 5: Active/open stays

SELECT
    COUNT(*) AS open_active_stays,
    COUNT(DISTINCT shipment_id) AS active_shipments,
    COUNT(DISTINCT warehouse) AS active_warehouses

FROM swift.open_warehouse_stays;

-- Output:
-- 21192    21192    2598


-- Validation 6: Current warehouse count

SELECT
    COUNT(*) AS warehouse_count

FROM swift.open_warehouse_metrics;

-- Output:
-- 2598


-- Validation 7: Current benchmarks

-- Output:
-- 147    39.00    91.00    3.00    10.00    5.00    16.80


-- ============================================================
-- END OF 03_data_cleaning.sql
-- ============================================================