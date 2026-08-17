-- Staging table: raw data, untouched, just with harmonized column names
-- so all 3 source files can load into one table. Everything from here
-- (dedup, parsing, normalizing) happens in SQL.

DROP TABLE IF EXISTS staging_raw;

CREATE TABLE staging_raw (
    raw_id           INTEGER PRIMARY KEY,
    job_title        TEXT,
    company_name     TEXT,
    experience       TEXT,   -- e.g. '4-6 Yrs'
    package          TEXT,   -- e.g. '10-20 Lacs PA' / 'Not disclosed'
    locations        TEXT,   -- comma-separated, messy formatting
    skills           TEXT,   -- concatenated with no delimiter
    job_url          TEXT,
    post_time        TEXT,   -- e.g. '3 Days Ago'
    source_category  TEXT    -- which of the 3 raw files it came from
);
