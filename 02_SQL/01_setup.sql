-- ============================================================
-- SWIFT Assignment 7 - Choked Hubs Prioritization
-- File: 01_setup.sql
-- Purpose: Create the database schema and raw data table
-- ============================================================


-- ============================================================
-- STEP 1: Create the SWIFT schema
-- ============================================================
--
-- The schema keeps all assignment-related tables organized
-- separately from other database objects.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS swift;


-- ============================================================
-- STEP 2: Create the raw shipment table
-- ============================================================
--
-- The original dataset is a newline-delimited JSON file.
--
-- Each row in this table stores one complete shipment record
-- as JSONB.
-- ============================================================

DROP TABLE IF EXISTS swift.raw_shipments;

CREATE TABLE swift.raw_shipments (
    id SERIAL PRIMARY KEY,
    data JSONB NOT NULL
);


-- ============================================================
-- STEP 3: Validate the raw data load
-- ============================================================
--
-- This confirms that all shipment records were successfully
-- loaded into PostgreSQL.
-- ============================================================

SELECT
    COUNT(*) AS shipment_count

FROM swift.raw_shipments;


/*
Output:

| shipment_count |
|---------------:|
|        100,786 |
*/


-- ============================================================
-- SETUP SUMMARY
-- ============================================================
--
-- Schema created:
--     swift
--
-- Raw table created:
--     swift.raw_shipments
--
-- Total shipment records loaded:
--     100,786
--
-- Data type:
--     JSONB
--
-- ============================================================
-- END OF 01_setup.sql
-- ============================================================