-- ============================================================
-- Naukri Data Analyst / Data Scientist Job Postings — Analysis
-- Raw data: 3 scraped CSVs from Naukri.com (~87k rows total)
-- Built entirely in PostgreSQL — staging load, cleaning, and
-- analysis all done in SQL.
-- ============================================================


-- ============================================================
-- SECTION 1: STAGING — raw data loaded as-is (see staging_schema.sql
-- and staging_raw.csv for the load step; nothing cleaned yet)
-- ============================================================

-- staging_raw columns: raw_id, job_title, company_name, experience,
-- package, locations, skills, job_url, post_time, source_category


-- ============================================================
-- SECTION 2: DEDUP + PARSING → clean_jobs
-- ============================================================

CREATE TABLE clean_jobs (
    job_id            SERIAL PRIMARY KEY,
    job_title         TEXT,
    company_name      TEXT,
    exp_min_years     NUMERIC,
    exp_max_years     NUMERIC,
    salary_min_lpa    NUMERIC,
    salary_max_lpa    NUMERIC,
    salary_disclosed  BOOLEAN,
    locations_raw     TEXT,
    skills_raw        TEXT,
    job_url           TEXT,
    source_category   TEXT
);

-- Dedup on (job_title, company_name, locations, job_url) using
-- ROW_NUMBER() + PARTITION BY, keeping the first-scraped copy (rn=1).
-- Also parses experience ('4-6 Yrs') and package ('10-20 Lacs PA' /
-- 'Not disclosed') into numeric columns in the same pass.
INSERT INTO clean_jobs (job_title, company_name, exp_min_years, exp_max_years,
                         salary_min_lpa, salary_max_lpa, salary_disclosed,
                         locations_raw, skills_raw, job_url, source_category)
SELECT job_title, company_name,
       (regexp_match(experience, '([\d.]+)-([\d.]+)'))[1]::numeric,
       (regexp_match(experience, '([\d.]+)-([\d.]+)'))[2]::numeric,
       CASE WHEN package ~ '[\d.]+-[\d.]+\s*Lacs'
            THEN (regexp_match(package, '([\d.]+)-([\d.]+)\s*Lacs'))[1]::numeric
            ELSE NULL END,
       CASE WHEN package ~ '[\d.]+-[\d.]+\s*Lacs'
            THEN (regexp_match(package, '([\d.]+)-([\d.]+)\s*Lacs'))[2]::numeric
            ELSE NULL END,
       CASE WHEN package ~ '[\d.]+-[\d.]+\s*Lacs' THEN TRUE ELSE FALSE END,
       locations, skills, job_url, source_category
FROM (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY job_title, company_name, locations, job_url ORDER BY raw_id) AS rn
  FROM staging_raw
  WHERE job_title IS NOT NULL
) sub
WHERE rn = 1;
-- Result: 48,789 unique postings


-- ============================================================
-- SECTION 3: SKILLS — split no-delimiter skills text, normalize casing
-- ============================================================

CREATE TABLE skills (
    skill_id   SERIAL PRIMARY KEY,
    skill_name TEXT UNIQUE
);

-- Split pattern: lowercase letter immediately followed by uppercase
-- letter marks a boundary between two concatenated skill words
-- (e.g. "data cleansingData analysis" -> "data cleansing" | "Data analysis").
-- Known limitation: doesn't split cases where two consecutive skills
-- both start lowercase — documented, not fully fixable without a
-- maintained skills taxonomy.
INSERT INTO skills (skill_name)
SELECT DISTINCT trim(lower(skill))
FROM (
    SELECT regexp_split_to_table(skills_raw, '(?<=[a-z])(?=[A-Z])') AS skill
    FROM clean_jobs
    WHERE skills_raw IS NOT NULL
) sub
WHERE trim(skill) <> '';
-- Result: 22,658 unique skills

CREATE TABLE job_skills (
    job_id   INTEGER REFERENCES clean_jobs(job_id),
    skill_id INTEGER REFERENCES skills(skill_id),
    PRIMARY KEY (job_id, skill_id)
);

INSERT INTO job_skills (job_id, skill_id)
SELECT DISTINCT cj.job_id, s.skill_id
FROM clean_jobs cj,
     LATERAL regexp_split_to_table(cj.skills_raw, '(?<=[a-z])(?=[A-Z])') AS skill
JOIN skills s ON s.skill_name = trim(lower(skill))
WHERE cj.skills_raw IS NOT NULL AND trim(skill) <> '';
-- Result: 314,021 job-skill links


-- ============================================================
-- SECTION 4: LOCATIONS — split comma-separated list, then normalize
-- messy variants (office park names, "Hybrid -" prefix, slash spacing)
-- ============================================================

CREATE TABLE locations (
    location_id   SERIAL PRIMARY KEY,
    location_name TEXT UNIQUE
);

INSERT INTO locations (location_name)
SELECT DISTINCT trim(loc)
FROM (
    SELECT regexp_split_to_table(locations_raw, ',') AS loc
    FROM clean_jobs
    WHERE locations_raw IS NOT NULL
) sub
WHERE trim(loc) <> '';
-- Initial result: 938 locations (many messy near-duplicates)

CREATE TABLE job_locations (
    job_id      INTEGER REFERENCES clean_jobs(job_id),
    location_id INTEGER REFERENCES locations(location_id),
    PRIMARY KEY (job_id, location_id)
);

INSERT INTO job_locations (job_id, location_id)
SELECT DISTINCT cj.job_id, l.location_id
FROM clean_jobs cj,
     LATERAL regexp_split_to_table(cj.locations_raw, ',') AS loc
JOIN locations l ON l.location_name = trim(loc)
WHERE cj.locations_raw IS NOT NULL AND trim(loc) <> '';
-- Initial result: 76,329 job-location links

-- --- Cleanup round 1: strip "Hybrid - " prefix and "(office park name)" ---
CREATE TABLE location_cleanup AS
SELECT location_id AS old_id,
       trim(regexp_replace(regexp_replace(location_name, '^Hybrid - ', ''), '\(.*\)', '')) AS cleaned_name
FROM locations;

CREATE TABLE location_canonical AS
SELECT cleaned_name, MIN(old_id) AS canonical_id
FROM location_cleanup
GROUP BY cleaned_name;

CREATE TABLE job_locations_clean AS
SELECT DISTINCT jl.job_id, lc.canonical_id AS location_id
FROM job_locations jl
JOIN location_cleanup c ON jl.location_id = c.old_id
JOIN location_canonical lc ON lc.cleaned_name = c.cleaned_name;

DROP TABLE job_locations;
ALTER TABLE job_locations_clean RENAME TO job_locations;
ALTER TABLE job_locations ADD PRIMARY KEY (job_id, location_id);

ALTER TABLE locations DROP CONSTRAINT locations_location_name_key;

UPDATE locations l
SET location_name = lc.cleaned_name
FROM location_canonical lc
WHERE l.location_id = lc.canonical_id;

DELETE FROM locations
WHERE location_id NOT IN (SELECT canonical_id FROM location_canonical);

ALTER TABLE locations ADD CONSTRAINT locations_location_name_key UNIQUE (location_name);
-- Result after round 1: 584 locations

-- --- Cleanup round 2: normalize slash spacing ("City/ City" -> "City/City") ---
-- Note the 'g' flag on regexp_replace -- without it, only the FIRST
-- slash in a multi-city string gets fixed, not all of them.
CREATE TABLE location_cleanup2 AS
SELECT location_id AS old_id,
       regexp_replace(location_name, '\s*/\s*', '/', 'g') AS cleaned_name
FROM locations;

CREATE TABLE location_canonical2 AS
SELECT cleaned_name, MIN(old_id) AS canonical_id
FROM location_cleanup2
GROUP BY cleaned_name;

CREATE TABLE job_locations_clean2 AS
SELECT DISTINCT jl.job_id, lc.canonical_id AS location_id
FROM job_locations jl
JOIN location_cleanup2 c ON jl.location_id = c.old_id
JOIN location_canonical2 lc ON lc.cleaned_name = c.cleaned_name;

DROP TABLE job_locations;
ALTER TABLE job_locations_clean2 RENAME TO job_locations;
ALTER TABLE job_locations ADD PRIMARY KEY (job_id, location_id);

ALTER TABLE locations DROP CONSTRAINT locations_location_name_key;

UPDATE locations l
SET location_name = lc.cleaned_name
FROM location_canonical2 lc
WHERE l.location_id = lc.canonical_id;

DELETE FROM locations
WHERE location_id NOT IN (SELECT canonical_id FROM location_canonical2);

ALTER TABLE locations ADD CONSTRAINT locations_location_name_key UNIQUE (location_name);
-- Result after round 2: 562 locations, 76,261 job-location links

-- Known limitation: word-order variants like "Bengaluru / Bangalore" vs
-- "Bangalore/Bengaluru" are NOT merged -- would need explicit manual
-- mapping rather than a regex rule. Documented, not fixed.

-- Helper tables (location_cleanup, location_canonical, location_cleanup2,
-- location_canonical2) were dropped after cleanup was verified:
-- DROP TABLE location_cleanup, location_canonical, location_cleanup2, location_canonical2;


-- ============================================================
-- SECTION 5: COMPANIES
-- ============================================================

CREATE TABLE companies (
    company_id   SERIAL PRIMARY KEY,
    company_name TEXT UNIQUE
);

INSERT INTO companies (company_name)
SELECT DISTINCT trim(company_name)
FROM clean_jobs
WHERE company_name IS NOT NULL AND trim(company_name) <> '';
-- Result: 8,058 companies

ALTER TABLE clean_jobs ADD COLUMN company_id INTEGER REFERENCES companies(company_id);

UPDATE clean_jobs cj
SET company_id = c.company_id
FROM companies c
WHERE trim(cj.company_name) = c.company_name;
-- Result: all 48,789 rows matched


-- ============================================================
-- SECTION 6: INDEXES
-- ============================================================

CREATE INDEX idx_job_skills_skill ON job_skills(skill_id);
CREATE INDEX idx_job_skills_job ON job_skills(job_id);
CREATE INDEX idx_job_locations_location ON job_locations(location_id);
CREATE INDEX idx_job_locations_job ON job_locations(job_id);
CREATE INDEX idx_clean_jobs_company ON clean_jobs(company_id);
CREATE INDEX idx_clean_jobs_salary ON clean_jobs(salary_min_lpa, salary_max_lpa) WHERE salary_disclosed;


-- ============================================================
-- SECTION 7: ANALYSIS
-- ============================================================

-- Q1: Which skills appear most often across postings? (demand)
SELECT s.skill_name, COUNT(*)
FROM job_skills js
JOIN skills s ON s.skill_id = js.skill_id
GROUP BY s.skill_name
ORDER BY COUNT(*) DESC
LIMIT 15;

-- Q2: Which skills command the highest average salary? (pay)
-- Filters to skills with >=20 disclosed-salary postings to avoid
-- single outlier postings skewing the average.
SELECT s.skill_name,
       COUNT(*) AS postings,
       ROUND(AVG((cj.salary_min_lpa + cj.salary_max_lpa) / 2), 1) AS avg_salary_lpa
FROM job_skills js
JOIN skills s ON s.skill_id = js.skill_id
JOIN clean_jobs cj ON cj.job_id = js.job_id
WHERE cj.salary_disclosed = TRUE
GROUP BY s.skill_name
HAVING COUNT(*) >= 20
ORDER BY avg_salary_lpa DESC
LIMIT 15;
-- Finding: specialized data-engineering skills (PySpark, Spark, Azure
-- Data Factory) out-earn generic analysis skills despite lower demand.

-- Q3: Top cities by posting volume and average salary
-- CASE WHEN inside AVG() keeps COUNT(*) at the true total per city,
-- while AVG() only considers rows with a disclosed salary (AVG
-- ignores NULLs automatically).
SELECT l.location_name,
       COUNT(*) AS postings,
       ROUND(AVG(CASE WHEN cj.salary_disclosed THEN (cj.salary_min_lpa + cj.salary_max_lpa) / 2 END), 1) AS avg_salary_lpa
FROM job_locations jl
JOIN locations l ON l.location_id = jl.location_id
JOIN clean_jobs cj ON cj.job_id = jl.job_id
GROUP BY l.location_name
ORDER BY postings DESC
LIMIT 15;
-- Finding: pay doesn't track posting volume. Remote work and mid-tier
-- cities (Pune) match or beat Bangalore's average despite far fewer postings.

-- Q4: Experience level vs average salary
SELECT CASE
         WHEN (exp_min_years + exp_max_years)/2 < 2 THEN '0-2 yrs'
         WHEN (exp_min_years + exp_max_years)/2 < 5 THEN '2-5 yrs'
         WHEN (exp_min_years + exp_max_years)/2 < 8 THEN '5-8 yrs'
         WHEN (exp_min_years + exp_max_years)/2 < 12 THEN '8-12 yrs'
         ELSE '12+ yrs'
       END AS experience_band,
       COUNT(*) AS postings,
       ROUND(AVG((salary_min_lpa + salary_max_lpa)/2), 1) AS avg_salary_lpa
FROM clean_jobs
WHERE salary_disclosed = TRUE
  AND exp_min_years IS NOT NULL
GROUP BY experience_band
ORDER BY MIN((exp_min_years + exp_max_years)/2);
-- Finding: salary growth with experience is surprisingly flat (₹11.8L
-- at 0-2 yrs to ₹13.7L at 12+ yrs, <20% growth). Caveat: senior
-- candidates may be less likely to have salary disclosed in postings,
-- which could understate true growth.
