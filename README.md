# SWIFT Assignment 7 – Choked Hubs Prioritization

## 1. Project Overview

This project analyses courier shipment tracking data to identify warehouses where shipments may be experiencing unusually long dwell times.

The objective is to identify warehouses that should be:

* **Prioritize for Clearing** – warehouses requiring operational attention.
* **Ignore** – warehouses whose observed performance does not meet the defined choke criteria.

The analysis uses shipment tracking history to calculate how long shipments remain at each warehouse and combines historical and current warehouse performance to identify potentially choked locations.

---

## 2. Business Problem

The logistics company wants to identify courier warehouses where shipments have entered but are not exiting within an expected period.

When shipments remain at a warehouse for unusually long periods, the warehouse may be experiencing operational congestion or other processing issues.

The analysis therefore answers the following questions:

1. How long do shipments typically remain at each warehouse?
2. What should be considered an unusually long warehouse stay?
3. Which warehouses have historically shown high long-stay behaviour?
4. Which warehouses currently have active shipments staying for unusually long periods?
5. Which warehouses should be prioritized for operational clearing?
6. How can the prioritized warehouses be ranked for action?

---

## 3. Assignment Requirements

The assignment requires:

1. Identification of potentially choked courier warehouses.
2. A mathematical definition of a choked warehouse.
3. Handling of missing or blank data.
4. Analysis using SQL.
5. Classification of warehouses into:

   * `Prioritize for Clearing`
   * `Ignore`
6. Creation of a final warehouse-level CSV output.
7. Submission of:

   * Approach document
   * SQL/SQLX code
   * Warehouse prioritization CSV

The analysis uses **7 October 2023** as the assignment's current-date cut-off.

---

# 4. Dataset

## Dataset Name

`SWIFT Assignment 7 - Analyst - CH.json`

## Format

The dataset is provided as **newline-delimited JSON (NDJSON)**.

Each line represents one shipment record.

## Main Fields

### `shipment_id`

Unique identifier of the shipment.

### `latest_status`

Latest known shipment status.

Examples include:

* Delivered
* In Transit
* Out for Delivery
* Picked Up
* Shipment Delayed

### `latest_location`

Latest known shipment location.

Some records contain blank values.

### `deduped_track_details`

Array containing the shipment's tracking history.

Each tracking event contains information such as:

* `ctime` – timestamp of the event
* `location` – warehouse/location where the shipment was recorded

### `hub_location_nam`

Additional hub-related information available for some shipment records.

This field was treated as supporting information rather than the primary warehouse identifier because the shipment tracking locations provide the actual movement history required for dwell-time analysis.

---

# 5. Technology Used

The analysis was performed using:

* **PostgreSQL 18.4**
* **pgAdmin 4**
* **VS Code**
* **Python** for loading the NDJSON file into PostgreSQL

The main analytical processing was performed in **PostgreSQL SQL**.

---

# 6. Project Structure

```text
SWIFT_Assignment_7
│
├── 01_Data
│   ├── SWIFT Assignment 7 - Analyst - CH.json
│   └── 05load_json.py
│
├── 02_SQL
│   ├── 01_setup.sql
│   ├── 02_data_exploration.sql
│   ├── 03_data_cleaning.sql
│   ├── 04_choked_hub_analysis.sql
│   └── 05_final_output.sql
│
├── 03_Documentation
│   └── SWIFT_Assignment_7_Approach.docx
│
├── 04_Output
│   └── SWIFT_Assignment_7_Warehouse_Prioritization.csv
│
└── README.md
```

The final submission can be packaged separately as:

```text
SWIFT_Assignment_7_SUBMISSION
│
├── SWIFT_Assignment_7_Approach.pdf
├── SWIFT_Assignment_7_Final.sql
└── SWIFT_Assignment_7_Warehouse_Prioritization.csv
```

# 7. Data Loading

The original dataset is an NDJSON file, meaning each line contains one JSON object.

The JSON records were loaded into PostgreSQL using a Python loading script.

The raw table is:

```text
swift.raw_shipments
```

The table structure is:

```sql
CREATE TABLE swift.raw_shipments (
    id SERIAL PRIMARY KEY,
    data JSONB NOT NULL
);
```

The JSON content is stored in PostgreSQL using the `JSONB` data type.

## 7.1 Python Loading Script

The Python loader is stored in:

```text
01_Data/05load_json.py
```

The script reads the NDJSON file line by line, converts each JSON record into a Python object, and inserts it into the PostgreSQL `swift.raw_shipments` table.

### Run the Loader

Open the VS Code **Terminal** and navigate to the data folder:

```powershell
cd "E:\data analytics\Data-Analytics-Portfolio\SWIFT_Assignment_7\01_Data"
```

Then run:

```powershell
python .\05load_json.py
```

The script prompts for the PostgreSQL password:

```text
Enter PostgreSQL password:
```

The password is entered directly in the terminal and is not stored in the script.

A successful execution produces:

```text
Starting JSON loader...
Opening JSON file...
Successfully loaded 100786 shipments.
```

## 7.2 Verify the Loaded Data

After loading, the number of records can be verified in PostgreSQL using:

```sql
SELECT
    COUNT(*) AS shipment_count
FROM swift.raw_shipments;
```

Expected result:

```text
100786
```

The Python script is used only for loading the original NDJSON dataset. The subsequent data exploration, cleaning, warehouse-stay calculation, choke analysis and final output generation are performed using PostgreSQL SQL.

## 7.3 Important Execution Note

The Python command should be executed from the `01_Data` directory because the JSON file is referenced using its local filename:

```text
SWIFT Assignment 7 - Analyst - CH.json
```

The Python loader is a development/setup utility and is **not included among the three final assignment submission files**.




# 8. Data Exploration

The first stage of the analysis was to understand the structure and quality of the data.

The following checks were performed:

* Total shipment count
* Shipment ID uniqueness
* Missing shipment IDs
* Shipment status distribution
* Missing latest locations
* Number of tracking events
* Missing tracking locations
* Number of unique tracking locations
* Tracking event chronology
* Location consistency

## Shipment Count

```text
100,786 shipments
```

## Shipment Status Distribution

| Status           |  Count |
| ---------------- | -----: |
| Delivered        | 79,008 |
| In Transit       | 18,400 |
| Out for Delivery |  2,803 |
| Picked Up        |    342 |
| Shipment Delayed |    233 |

## Latest Location

The dataset contains:

```text
2,376
```

shipments with missing or blank `latest_location`.

This was not treated as a reason to discard the shipment because the tracking history can still contain usable warehouse information.

---

# 9. Tracking Event Extraction

The `deduped_track_details` array was expanded into individual tracking events using PostgreSQL JSON functions.

The extracted tracking table is:

```text
swift.shipment_tracking
```

The main fields are:

```text
shipment_id
latest_status
event_time
location
```

The original tracking data contained:

```text
671,420
```

tracking events.

After removing tracking events with blank warehouse locations:

```text
662,521
```

usable tracking events remained.

---

# 10. Location Cleaning

Warehouse/location values were normalized before analysis.

The following cleaning was applied:

```sql
LOWER(TRIM(location))
```

This ensures that location values differing only by capitalization or surrounding spaces are treated consistently.

For example:

```text
GURUGRAM, HARYANA, IN
Gurugram, Haryana, IN
```

are normalized to the same lowercase representation where the underlying text is otherwise identical.

The cleaned tracking table is:

```text
swift.shipment_tracking_clean
```

---

# 11. Chronological Ordering

Tracking events were not always stored in chronological order in the source data.

Therefore, events were sorted by:

```text
shipment_id
event_time
```

The previous warehouse was identified using the PostgreSQL `LAG()` window function.

This allowed the analysis to determine when a shipment moved from one warehouse to another.

---

# 12. Warehouse Stay Identification

A warehouse stay represents the period during which a shipment remained at the same warehouse.

Consecutive tracking events at the same warehouse were grouped together into one stay.

For each stay:

```text
Entry Time = first timestamp at the warehouse
Exit Time  = entry time at the next warehouse
```

The warehouse-stay table is:

```text
swift.warehouse_stays
```

The dwell time was calculated as:

```text
Dwell Time (hours)
=
(Exit Time - Entry Time) / 3600
```

---

# 13. Warehouse Stay Results

The analysis generated:

```text
533,725 warehouse stays
```

These consisted of:

```text
432,950 completed stays
100,775 open stays
```

A completed stay has an identifiable exit time.

An open stay does not have a subsequent warehouse movement in the available tracking data.

---

# 14. Long-Stay Threshold

A data-driven threshold was required to identify unusually long warehouse stays.

The 95th percentile of completed warehouse-stay duration was calculated.

The result was:

```text
51.26 hours
```

Therefore:

```text
Long Stay = Dwell Time > 51.26 hours
```

This threshold is derived from the observed dataset.

It is not an externally provided service-level agreement.

---

# 15. Historical Warehouse Analysis

Historical performance was calculated using completed warehouse stays.

For each warehouse, the following metrics were calculated:

* Completed stays
* Historical long stays
* Historical long-stay rate
* Median dwell time
* 95th percentile dwell time

To reduce the effect of very small samples, only warehouses with at least:

```text
20 completed stays
```

were included in the historical benchmark calculation.

This produced:

```text
658 eligible historical warehouses
```

The 75th percentile of historical long-stay rate was:

```text
4.59%
```

Therefore:

```text
Historical Choke =
Completed Stays >= 20
AND
Historical Long-Stay Rate > 4.59%
```

where:

```text
Historical Long-Stay Rate
=
Long Stays / Completed Stays × 100
```

Using this condition:

```text
165 warehouses
```

were identified as historically choked.

---

# 16. Current Warehouse Analysis

Current warehouse performance was analysed as of:

```text
7 October 2023
23:59:59 IST
```

Only active shipment statuses were considered:

```text
In Transit
Out for Delivery
```

The latest open warehouse stay for each active shipment was identified.

The analysis produced:

```text
21,192 active/open shipment stays
```

across:

```text
2,598 warehouses
```

To avoid unstable benchmarks from very small samples, only warehouses with at least:

```text
20 open stays
```

were used for the current benchmark.

This resulted in:

```text
147 eligible current warehouses
```

The current benchmark values were:

```text
75th percentile open long stays = 10
75th percentile open long-stay rate = 16.80%
```

Therefore:

```text
Current Choke =
Open Stays >= 20
AND
Open Long Stays > 10
AND
Open Long-Stay Rate > 16.80%
```

where:

```text
Open Long-Stay Rate
=
Open Long Stays / Open Stays × 100
```

---

# 17. Mathematical Definition of a Choked Warehouse

The final definition combines historical and current performance.

```text
Choked Warehouse
=
Historical Choke
OR
Current Choke
```

Where:

```text
Historical Choke =
Completed Stays >= 20
AND
Historical Long-Stay Rate > 4.59%
```

and:

```text
Current Choke =
Open Stays >= 20
AND
Open Long Stays > 10
AND
Open Long-Stay Rate > 16.80%
```

A warehouse satisfying either condition is classified as:

```text
Prioritize for Clearing
```

All other warehouses are classified as:

```text
Ignore
```

---

# 18. Final Warehouse Classification

The analysis identified:

```text
7,328
```

warehouse/location values.

The classification was:

| Classification              |     Count |
| --------------------------- | --------: |
| Both Historical and Current |        19 |
| Current Only                |         2 |
| Historical Only             |       146 |
| Prioritize for Clearing     |   **167** |
| Ignore                      | **7,161** |
| Total                       | **7,328** |

The prioritized warehouses consist of:

```text
19 Both Historical and Current
+
2 Current Only
+
146 Historical Only
=
167 Prioritize for Clearing
```

---

# 19. Priority Score

After classification, a priority score was calculated to provide an operational ordering of warehouses already classified as `Prioritize for Clearing`.

The score uses four normalized components:

| Component                   | Weight |
| --------------------------- | -----: |
| Current long-stay volume    |    40% |
| Current long-stay rate      |    25% |
| Historical long-stay rate   |    20% |
| Historical long-stay volume |    15% |

The formula is:

```text
Priority Score =
(0.40 × Current Volume Score)
+
(0.25 × Current Rate Score)
+
(0.20 × Historical Rate Score)
+
(0.15 × Historical Volume Score)
```

The component scores are normalized against the maximum observed values and converted to a 0–100 scale.

Current performance receives the highest combined weight because the purpose of the analysis is to support operational prioritization.

The priority score does not determine whether a warehouse is choked.

Instead:

```text
Classification → determines whether attention is required

Priority Score → determines the order of attention
```

---

# 20. SQL Workflow

The SQL analysis is divided into five stages.

## `01_setup.sql`

Creates the PostgreSQL schema and raw shipment table.

Main objects:

```text
swift
swift.raw_shipments
```

---

## `02_data_exploration.sql`

Performs:

* Dataset exploration
* Shipment count validation
* Status analysis
* Missing-value analysis
* Tracking event extraction
* Tracking event validation
* Location exploration
* Chronological event analysis

Main objects created:

```text
swift.shipment_tracking
swift.shipment_tracking_clean
swift.warehouse_stays
```

---

## `03_data_cleaning.sql`

Performs:

* Location normalization
* Warehouse stay identification
* Dwell-time calculation
* Historical warehouse performance
* Open/current warehouse stay calculation
* Historical benchmark calculation
* Current benchmark calculation

Main objects created:

```text
swift.warehouse_performance
swift.open_warehouse_stays
swift.open_warehouse_metrics
```

---

## `04_choked_hub_analysis.sql`

Performs:

* Historical choke calculation
* Current choke calculation
* Final warehouse classification
* Historical/current condition comparison

Main output:

```text
swift.final_warehouse_prioritization
```

---

## `05_final_output.sql`

Performs:

* Priority score calculation
* Warehouse ranking
* Final validation
* Final output generation

Main output:

```text
swift.final_warehouse_ranked
```

---

# 21. Final Output

The final CSV is:

```text
SWIFT_Assignment_7_Warehouse_Prioritization.csv
```

The output contains:

```text
priority_rank
ignore_rank
warehouse
category
priority_score
completed_stays
historical_long_stays
historical_long_stay_rate_pct
open_stays
open_long_stays
open_long_stay_rate_pct
max_open_dwell_hours
```

The `category` column contains only:

```text
Prioritize for Clearing
Ignore
```

---

# 22. Final Deliverables

The final submission contains exactly three files:

### 1. Approach Document

```text
SWIFT_Assignment_7_Approach.pdf
```

Contains:

* Executive Summary
* Objective
* Dataset Understanding
* Data Preparation
* Warehouse Stay Calculation
* Choked Warehouse Definition
* Historical Analysis
* Current Analysis
* Classification
* Priority Score
* Results
* Key Observations
* Conclusion

### 2. SQL File

```text
SWIFT_Assignment_7_Final.sql
```

Contains the SQL workflow used to generate the analysis and final results.

### 3. CSV Output

```text
SWIFT_Assignment_7_Warehouse_Prioritization.csv
```

Contains the final warehouse classifications and priority metrics.

---

# 23. Key Results

The final analysis produced the following results:

| Metric                          |      Result |
| ------------------------------- | ----------: |
| Total shipments                 |     100,786 |
| Raw tracking events             |     671,420 |
| Usable tracking events          |     662,521 |
| Warehouse stays                 |     533,725 |
| Completed stays                 |     432,950 |
| Open stays                      |     100,775 |
| Long-stay threshold             | 51.26 hours |
| Historical benchmark warehouses |         658 |
| Historical choked warehouses    |         165 |
| Active/open stays               |      21,192 |
| Current benchmark warehouses    |         147 |
| Final warehouse/location values |       7,328 |
| Prioritize for Clearing         |         167 |
| Ignore                          |       7,161 |

---

# 24. Important Assumptions

The following assumptions were used:

1. The assignment's specified current date of **7 October 2023** was used as the analysis cut-off.

2. A warehouse stay is defined by consecutive tracking events at the same normalized warehouse.

3. Dwell time is calculated using the time difference between entering a warehouse and the next warehouse movement.

4. A completed stay with dwell time greater than **51.26 hours** is treated as a long stay.

5. The 51.26-hour threshold is derived from the 95th percentile of completed warehouse stays.

6. A minimum of 20 observations is used for warehouse-level benchmark calculations.

7. Current analysis includes only shipments with status `In Transit` or `Out for Delivery`.

8. Blank tracking locations are excluded from warehouse-level stay analysis.

9. Warehouse names are normalized using trimming and lowercase conversion.

10. `hub_location_nam` is treated as supporting information rather than the primary warehouse identifier because the tracking-event location provides the shipment's actual movement history.

11. The classification thresholds are empirical and based on the observed dataset. They are not external operational SLAs.

---

# 25. Data Quality Considerations

The dataset contains some incomplete and inconsistent information.

Examples include:

* Blank `latest_location` values.
* Blank tracking locations.
* Different capitalization of the same location.
* Tracking events that are not initially chronological.
* Shipments with limited tracking information.

These issues were handled through:

* Missing-value filtering where required.
* Location normalization.
* Chronological ordering.
* Use of tracking history instead of relying only on the latest location.
* Minimum observation thresholds for warehouse benchmarking.

---

# 26. How to Reproduce the Analysis

The analysis can be reproduced in PostgreSQL by executing the SQL files in the following order:

```text
01_setup.sql
        ↓
02_data_exploration.sql
        ↓
03_data_cleaning.sql
        ↓
04_choked_hub_analysis.sql
        ↓
05_final_output.sql
```

The NDJSON dataset must first be loaded into:

```text
swift.raw_shipments
```

After the raw data is available, the SQL workflow creates the required intermediate and final tables.

---

# 27. Conclusion

This project provides a data-driven approach for identifying courier warehouses that may be experiencing congestion.

The methodology combines shipment-level tracking history, warehouse dwell-time analysis, empirical thresholds, historical performance and current active shipment conditions.

The final analysis identified:

```text
167 warehouses
```

for:

```text
Prioritize for Clearing
```

and:

```text
7,161 warehouses
```

for:

```text
Ignore
```

The approach provides both a binary operational classification and a priority score that can be used to order warehouses requiring attention.

The methodology can also be reused with future shipment tracking data by recalculating the empirical benchmarks using the updated dataset.

---

# 28. End of Project

**Project:** SWIFT Assignment 7 – Choked Hubs Prioritization

**Database:** PostgreSQL

**Analysis Date Cut-off:** 7 October 2023

**Final Prioritized Warehouses:** 167

**Final Ignored Warehouses:** 7,161
