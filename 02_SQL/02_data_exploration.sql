-- ============================================================
-- SWIFT Assignment 7 - Choked Hubs Prioritization
-- File: 02_data_exploration.sql
-- Purpose: Explore and understand the raw shipment data
-- ============================================================


-- ============================================================
-- QUERY 1: Check total number of shipments
-- ============================================================

SELECT
    COUNT(*) AS total_shipments

FROM swift.raw_shipments;

-- Output:
-- 100786


-- ============================================================
-- QUERY 2: Inspect one raw shipment record
-- ============================================================
--
-- This helps understand the JSON structure and available
-- fields before performing any transformation.
-- ============================================================

SELECT
    data

FROM swift.raw_shipments

LIMIT 1;


-- ============================================================
-- QUERY 3: Check shipment statuses
-- ============================================================
--
-- This shows the current/latest status distribution
-- in the dataset.
-- ============================================================

SELECT
    data->>'latest_status' AS latest_status,
    COUNT(*) AS shipment_count

FROM swift.raw_shipments

GROUP BY
    data->>'latest_status'

ORDER BY
    shipment_count DESC;


/*
Output:

| Status           | Shipments |
| ---------------- | ---------:|
| Delivered        |    79,008 |
| In Transit       |    18,400 |
| Out for Delivery |     2,803 |
| Picked Up        |       342 |
| Shipment Delayed |       233 |
| Total            |   100,786 |
*/


-- ============================================================
-- QUERY 4: Check missing latest locations
-- ============================================================
--
-- Missing location values are part of the data-quality
-- assessment.
-- ============================================================

SELECT
    COUNT(*) AS total_shipments,

    COUNT(*) FILTER (
        WHERE NULLIF(
            TRIM(data->>'latest_location'),
            ''
        ) IS NULL
    ) AS missing_latest_location,

    COUNT(*) FILTER (
        WHERE NULLIF(
            TRIM(data->>'latest_location'),
            ''
        ) IS NOT NULL
    ) AS available_latest_location

FROM swift.raw_shipments;

-- Output:
-- 100786    2376    98410

-- About 2.36% of shipments have a blank latest_location.
-- Therefore, latest_location is not used as the primary
-- warehouse field in the analysis.
-- Tracking-history locations are used instead.


-- ============================================================
-- QUERY 5: Check shipment ID quality
-- ============================================================
--
-- Shipment IDs should be present and unique because they
-- identify individual shipments.
-- ============================================================

SELECT
    COUNT(*) AS total_shipments,

    COUNT(*) FILTER (
        WHERE NULLIF(
            TRIM(data->>'shipment_id'),
            ''
        ) IS NULL
    ) AS missing_shipment_id,

    COUNT(
        DISTINCT data->>'shipment_id'
    ) AS unique_shipment_ids

FROM swift.raw_shipments;


/*
Output:

| Metric               | Result   |
| -------------------- | -------: |
| Total shipments      | 100,786  |
| Missing shipment IDs | 0        |
| Unique shipment IDs  | 100,786  |

Conclusion:
Every shipment has an ID and all shipment IDs are unique.
*/


-- ============================================================
-- QUERY 6: Inspect tracking-history structure
-- ============================================================
--
-- deduped_track_details contains the shipment's tracking
-- journey as an array of events.
-- ============================================================

SELECT
    r.data->>'shipment_id' AS shipment_id,
    track_event->>'ctime' AS event_time,
    track_event->>'location' AS location

FROM swift.raw_shipments r

CROSS JOIN LATERAL jsonb_array_elements(
    r.data->'deduped_track_details'
) AS track_event

LIMIT 20;


-- ============================================================
-- QUERY 7: Count all tracking events
-- ============================================================
--
-- This includes events with blank locations.
-- ============================================================

SELECT
    COUNT(*) AS total_tracking_events

FROM swift.raw_shipments r

CROSS JOIN LATERAL jsonb_array_elements(
    r.data->'deduped_track_details'
) AS track_event;

-- Output:
-- 671420


-- ============================================================
-- QUERY 8: Check missing tracking locations
-- ============================================================
--
-- This identifies data-quality issues inside the tracking
-- history itself.
-- ============================================================

SELECT
    COUNT(*) AS total_tracking_events,

    COUNT(*) FILTER (
        WHERE NULLIF(
            TRIM(track_event->>'location'),
            ''
        ) IS NULL
    ) AS missing_location_events,

    COUNT(*) FILTER (
        WHERE NULLIF(
            TRIM(track_event->>'location'),
            ''
        ) IS NOT NULL
    ) AS valid_location_events

FROM swift.raw_shipments r

CROSS JOIN LATERAL jsonb_array_elements(
    r.data->'deduped_track_details'
) AS track_event;


/*
Output:

| Tracking events       | Count   |
| --------------------- | ------: |
| Total tracking events | 671,420 |
| Missing location      |   8,899 |
| Valid location        | 662,521 |
*/


-- ============================================================
-- QUERY 9: Create flattened shipment tracking table
-- ============================================================
--
-- The nested JSON tracking history is converted into a
-- relational table.
--
-- Blank tracking locations are excluded because they cannot
-- be used to identify a warehouse.
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
-- QUERY 10: Verify flattened tracking table
-- ============================================================

SELECT
    COUNT(*) AS tracking_events,

    COUNT(DISTINCT shipment_id) AS shipments,

    COUNT(DISTINCT location) AS distinct_locations

FROM swift.shipment_tracking;

-- Output:
-- 662521    100775    10357


-- ============================================================
-- QUERY 11: Inspect most frequently occurring locations
-- ============================================================
--
-- This helps understand the warehouse/location values before
-- normalization.
-- ============================================================

SELECT
    location,
    COUNT(*) AS event_count

FROM swift.shipment_tracking

GROUP BY location

ORDER BY event_count DESC

LIMIT 50;


/*
Sample output:

| Location                       | Event Count |
| ------------------------------ | ----------: |
| DELH                           |      14,985 |
| BOMH                           |      13,929 |
| DEL/LH1, Gurgaon, HARYANA      |      12,096 |
*/


-- ============================================================
-- QUERY 12: Normalize warehouse names
-- ============================================================
--
-- Location values may differ only in capitalization or
-- surrounding spaces.
--
-- LOWER + TRIM is used for basic normalization.
--
-- Different operational facilities are NOT automatically
-- merged into city-level names.
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
-- QUERY 13: Verify chronological ordering
-- ============================================================
--
-- Tracking events are ordered by event time for each shipment.
--
-- This is necessary before calculating warehouse dwell time.
-- ============================================================

SELECT
    shipment_id,
    event_time,
    warehouse,

    LAG(event_time) OVER (
        PARTITION BY shipment_id
        ORDER BY event_time
    ) AS previous_event_time

FROM swift.shipment_tracking_clean

ORDER BY
    shipment_id,
    event_time

LIMIT 30;


-- ============================================================
-- QUERY 14: Identify warehouse changes
-- ============================================================
--
-- A new stay starts whenever the shipment moves from one
-- warehouse to another.
-- ============================================================

SELECT
    shipment_id,
    event_time,
    warehouse,

    LAG(warehouse) OVER (
        PARTITION BY shipment_id
        ORDER BY event_time
    ) AS previous_warehouse,

    CASE

        WHEN
            LAG(warehouse) OVER (
                PARTITION BY shipment_id
                ORDER BY event_time
            ) IS NULL

            OR

            LAG(warehouse) OVER (
                PARTITION BY shipment_id
                ORDER BY event_time
            ) <> warehouse

        THEN 1

        ELSE 0

    END AS new_stay

FROM swift.shipment_tracking_clean

ORDER BY
    shipment_id,
    event_time

LIMIT 30;

-- A value of 1 indicates the beginning of a new warehouse
-- stay episode.


-- ============================================================
-- QUERY 15: Create warehouse stay episodes
-- ============================================================
--
-- A warehouse stay represents the period during which a
-- shipment remains at the same warehouse.
--
-- Dwell time:
--
-- Exit Time - Entry Time
--
-- If there is no later warehouse event, exit_time is NULL
-- and the stay is treated as open/current.
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
-- QUERY 16: Verify warehouse stay episodes
-- ============================================================

SELECT
    COUNT(*) AS total_stays,

    COUNT(*) FILTER (
        WHERE exit_time IS NOT NULL
    ) AS completed_stays,

    COUNT(*) FILTER (
        WHERE exit_time IS NULL
    ) AS open_stays,

    ROUND(
        MIN(dwell_hours)::numeric,
        2
    ) AS minimum_dwell_hours,

    ROUND(
        MAX(dwell_hours)::numeric,
        2
    ) AS maximum_completed_dwell_hours

FROM swift.warehouse_stays

WHERE dwell_hours IS NULL
   OR dwell_hours >= 0;


/*
Output:

| Metric                  | Result      |
| ----------------------- | ----------: |
| Total warehouse stays   | 533,725     |
| Completed stays         | 432,950     |
| Open stays              | 100,775     |
| Minimum completed dwell | 0.00 hrs    |
| Maximum completed dwell | 413.42 hrs  |
*/


-- Completed stay:
-- Shipment entered a warehouse and later moved to another
-- location.

-- Open stay:
-- Shipment's latest usable tracking event is still at the
-- warehouse, so there is no exit event.

-- Completed stays are used to establish the historical
-- warehouse-performance benchmark.


-- ============================================================
-- QUERY 17: Calculate network dwell-time benchmarks
-- ============================================================
--
-- These benchmarks describe the distribution of completed
-- warehouse stays across the network.
-- ============================================================

SELECT
    COUNT(*) AS completed_stays,

    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY dwell_hours
        )::numeric,
        2
    ) AS p25_dwell_hours,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY dwell_hours
        )::numeric,
        2
    ) AS median_dwell_hours,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY dwell_hours
        )::numeric,
        2
    ) AS p75_dwell_hours,

    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP (
            ORDER BY dwell_hours
        )::numeric,
        2
    ) AS p90_dwell_hours,

    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY dwell_hours
        )::numeric,
        2
    ) AS p95_dwell_hours,

    ROUND(
        PERCENTILE_CONT(0.99)
        WITHIN GROUP (
            ORDER BY dwell_hours
        )::numeric,
        2
    ) AS p99_dwell_hours

FROM swift.warehouse_stays

WHERE exit_time IS NOT NULL
  AND dwell_hours >= 0;


/*
Output:

Completed stays : 432,950
P25              : 4.00 hours
Median           : 9.42 hours
P75              : 23.37 hours
P90              : 37.90 hours
P95              : 51.26 hours
P99              : 77.77 hours

Interpretation:

The 95th percentile is used later as the empirical
long-stay threshold.

Exact P95:
51.26277777777778 hours
*/


-- ============================================================
-- QUERY 18: Check tracking coverage per shipment
-- ============================================================
--
-- This checks whether shipments have usable tracking
-- histories and identifies shipments with very limited
-- tracking information.
-- ============================================================

SELECT
    COUNT(*) AS total_shipments,

    COUNT(*) FILTER (
        WHERE tracking_event_count > 0
    ) AS shipments_with_tracking,

    COUNT(*) FILTER (
        WHERE tracking_event_count = 1
    ) AS shipments_with_one_event,

    COUNT(*) FILTER (
        WHERE tracking_event_count > 1
    ) AS shipments_with_multiple_events

FROM (

    SELECT
        r.data->>'shipment_id' AS shipment_id,

        COUNT(track_event) AS tracking_event_count

    FROM swift.raw_shipments r

    LEFT JOIN LATERAL jsonb_array_elements(
        r.data->'deduped_track_details'
    ) AS track_event
        ON TRUE

    GROUP BY
        r.data->>'shipment_id'

) AS shipment_tracking_counts;


/*
Output:

| Metric                   | Count   |
| ------------------------ | ------: |
| Total shipments          | 100,786 |
| Shipments with tracking  | 100,786 |
| Only 1 tracking event    |     503 |
| Multiple tracking events | 100,283 |
*/


-- ============================================================
-- EXPLORATION SUMMARY
-- ============================================================
--
-- Total shipments              = 100,786
-- Tracking events               = 671,420
-- Valid-location events        = 662,521
-- Missing-location events      = 8,899
-- Shipments with usable
-- location events              = 100,775
-- Completed warehouse stays    = 432,950
-- Open warehouse stays         = 100,775
-- P95 completed dwell          = 51.26 hours
--
-- Data-quality observations:
--
-- 1. Shipment IDs are complete and unique.
-- 2. Some latest_location values are missing.
-- 3. Some tracking events have blank locations.
-- 4. 11 shipments do not appear in the usable-location
--    tracking table despite having tracking records,
--    because their tracking locations are blank.
-- 5. 503 shipments have only one tracking event.
--
-- These limitations are considered during the cleaning
-- and warehouse-choke analysis stages.
-- ============================================================


-- ============================================================
-- END OF 02_data_exploration.sql
-- ============================================================