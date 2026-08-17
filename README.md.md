# What Does the Indian Data Analyst Job Market Actually Want?

A SQL-only analysis of ~87,000 scraped Naukri.com job postings for Data
Analyst and Data Scientist roles — cleaned, normalized, and analyzed
entirely in PostgreSQL.

## The question

Two questions drove this project, both meant to directly inform my own
job search:

1. Which skills are actually in demand across current postings — vs.
   which ones command the highest pay? These are not the same list.
2. Does experience level, location, and remote-vs-onsite status
   actually move the needle on salary the way conventional wisdom
   suggests?

## Data

Three raw CSVs scraped from Naukri.com (Data Analyst, Data Scientist,
and a combined dataset), totaling 86,904 rows. Source data was
genuinely messy — no cleaned Kaggle dataset shortcuts here:

- No delimiter between concatenated skill tags
  (`"data cleansingData analysisAutomation..."`)
- ~59% duplicate rows (mostly repeated scrapes)
- Inconsistent city naming (`"Bangalore/ Bengaluru"` vs
  `"Bangalore/Bengaluru"` vs `"Bangalore/Bengaluru(HSR Layout)"` —
  over 900 raw location strings collapsing to ~560 real places)
- Only ~8% of postings disclose salary at all
- Multi-location postings, free-text experience ranges, mixed salary
  formats (`"10-20 Lacs PA"` vs `"Not disclosed"` vs `"Unpaid"`)

## Approach

Everything from raw CSV to final analysis was done in PostgreSQL —
no Python/pandas. See [`naukri_analysis.sql`](./naukri_analysis.sql)
for the full, commented script. Broad strokes:

1. **Staging** — loaded all 3 raw files, untouched, into one table
2. **Dedup** — `ROW_NUMBER() OVER (PARTITION BY ...)` to identify and
   drop duplicate postings (86,904 → 48,789 unique postings)
3. **Parsing** — regex extraction (`regexp_match`) to turn free-text
   experience and salary ranges into real numeric columns
4. **Normalization** — split the no-delimiter skills field
   (`regexp_split_to_table` with a lowercase→uppercase boundary
   pattern) and the comma-separated locations field into proper
   many-to-many junction tables
5. **Location cleanup** — two rounds of regex-based deduplication to
   collapse office-park suffixes, a `"Hybrid - "` prefix, and
   inconsistent slash-spacing in city names down to canonical names
6. **Indexing** — added indexes on join/filter columns, verified with
   `EXPLAIN ANALYZE` where the planner does and doesn't use them

### Schema

7 tables: `clean_jobs`, `companies`, `skills`, `locations`,
`job_skills` (many-to-many), `job_locations` (many-to-many), and
`staging_raw` (kept for reference/auditability).

## Findings

**1. The most in-demand skills aren't the highest-paying ones.**
"Data analysis," "analytical," and "business analyst/analysis"
dominate by posting volume, but the highest average salaries go to
more specialized data-engineering skills — PySpark (₹21.8L),
Azure Data Factory (₹19.2L), Spark (₹18.7L) — all outpacing the
generic analysis skills that show up far more often.

**2. Salary doesn't track posting volume by city.** Bangalore leads
by volume (14,757 postings) but isn't the top payer. Remote postings
pay a premium (₹14.0L avg) despite far fewer listings than any major
city, and mid-tier cities like Pune (₹13.7L) match Bangalore's
average (₹13.7L) with under half the posting volume.

**3. Salary growth with experience is flatter than expected.**
₹11.8L (0–2 yrs) → ₹13.7L (12+ yrs) — under 20% growth across a
decade-plus of experience. *Caveat: only ~8% of postings disclose
salary at all, and senior candidates may be less likely to have
salary listed publicly, which could understate real growth.*

## Known limitations

Documented rather than silently hidden:
- The skills-splitting regex doesn't correctly separate two
  consecutive lowercase-starting skill entries, leaving some noisy
  compound "skills" in the data
- A couple of skill entries contain a literal `#REF!` — an Excel
  error that leaked into the scraped source before export
- Word-order location variants (`"Bengaluru / Bangalore"` vs
  `"Bangalore/Bengaluru"`) weren't merged — would need manual mapping
  rather than a regex rule, and was judged not worth the effort
  relative to the analysis value

## Tools

PostgreSQL only — staging, cleaning, normalization, indexing, and
analysis all in SQL. No Python/pandas used anywhere in the pipeline.

## Files in this repo

- `naukri_analysis.sql` — full commented script: schema, cleaning,
  normalization, indexing, and all analysis queries
- `staging_schema.sql` / `staging_raw.csv` — raw data loader
- Query result CSVs — exports of the 4 key analysis queries
