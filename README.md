# ❄️ Snowflake Pipeline Runbook — `COMPLETE_WORKSHEET.sql`

How to set up, verify, operate and troubleshoot the Snowflake side of the pipeline:

```
RDS PostgreSQL ──export──► S3 (CSV + JSON) ──S3 event──► Snowpipe ──► RAW
                                                                     │ streams
                                         TASK (cron, every minute) ──► STAGING ──► MARTS ──► Power BI
```

Everything inside Snowflake is created by **one worksheet**, run once. After that the pipeline runs on its own.

---

## Contents

1. [What gets automated](#1-what-gets-automated)
2. [Prerequisites](#2-prerequisites)
3. [Before you start: placeholders](#3-before-you-start-placeholders)
4. [How to run the worksheet](#4-how-to-run-the-worksheet)
5. [Setup steps (sections 0–13)](#5-setup-steps)
6. [Go-live checklist](#6-go-live-checklist)
7. [Daily operations](#7-daily-operations)
8. [Monitoring reference](#8-monitoring-reference)
9. [Troubleshooting](#9-troubleshooting)
10. [Recovery procedures](#10-recovery-procedures)
11. [Common changes](#11-common-changes)
12. [Pause, resume, cleanup](#12-pause-resume-cleanup)
13. [Object reference](#13-object-reference)

---

## 1. What gets automated

| Piece | Trigger | Job | Created by |
|---|---|---|---|
| Snowpipe (6 pipes) | **S3 event** when a file arrives | Loads the file into a RAW table (~1 min) | Worksheet §6 + **AWS S3 notification** |
| `TSK_MERGE_STAGING` | **Cron every minute** (`* * * * *`, IST) | If streams have new rows → merge RAW into STAGING; otherwise SKIPPED (no cost) | Worksheet §9 |
| `TSK_BUILD_MARTS` | Right after a successful merge | Rebuilds the Power BI tables in MARTS | Worksheet §9 |
| `ALRT_PIPELINE` | **Cron every 15 minutes** | Emails you if something is wrong | Worksheet §10 |

**Outside Snowflake (not done by the worksheet):**

| Piece | Where | Notes |
|---|---|---|
| S3 event notification → Snowpipe | AWS (bucket settings) | One-time, after §6. Without it, files never load automatically |
| RDS → S3 export | AWS (Lambda + EventBridge, or your own script) | Must write files to the paths in [§3](#expected-s3-layout) with **unique names** |
| Power BI refresh | Power BI Service | Scheduled refresh on the published dataset |

---

## 2. Prerequisites

| Need | Details |
|---|---|
| Snowflake user with `ACCOUNTADMIN` | Needed for the integration, roles, monitor and alert. Day-to-day work uses `ANALYTICS_ENGINEER` |
| AWS IAM role for Snowflake | Its ARN goes in `<AWS_ROLE_ARN>`. You'll update its trust policy in §2 |
| S3 bucket | Export files under `s3://<BUCKET>/exports/` |
| Verified email | The address for alerts must be **verified** in Snowsight (*profile → Settings → Email*) |
| AWS CLI (optional) | For the S3 notification and test uploads |
| Region | Best: Snowflake account in the **same AWS region** as the bucket (no transfer cost) |

<a id="expected-s3-layout"></a>
### Expected S3 layout

```
s3://<BUCKET>/exports/csv/<source>/<table>/dt=YYYY-MM-DD/<table>_<timestamp>.csv.gz
s3://<BUCKET>/exports/json/<source>/<table>/dt=YYYY-MM-DD/<table>_<timestamp>.json.gz
s3://<BUCKET>/exports/manifests/<source>/<table>/dt=YYYY-MM-DD/<table>_<timestamp>.json   (optional)
```

| Format | Tables | File rules |
|---|---|---|
| CSV | `customers`, `agents`, `calls` | Header row, gzip optional, columns in the order of the RAW table, ISO-8601 timestamps |
| JSON Lines | `call_feedback`, `call_events` | One JSON object per line, gzip optional |

> ⚠️ **Every file needs a new, unique name** (e.g. with a timestamp). Snowpipe never reloads a file name it has already loaded, even if the content changed.

---

## 3. Before you start: placeholders

Open the worksheet and use **Find & Replace (Ctrl+H)** on all three before running anything:

| Placeholder | Example |
|---|---|
| `<AWS_ROLE_ARN>` | `arn:aws:iam::111122223333:role/snowflake-s3-read` |
| `<BUCKET>` | `nitor-rds-snowflake-exports` (name only, no `s3://`) |
| `<ALERT_EMAIL>` | `you@company.com` (verified in Snowflake) |

---

## 4. How to run the worksheet

1. Snowsight → **Projects → Workspaces** (or **Worksheets**) → **+ SQL file** → paste the whole worksheet.
2. Run **one section at a time**: highlight the section, then press **Run** (Ctrl+Enter / Cmd+Return).
3. The result pane shows only the **last** statement's result. Run each **✅ VERIFY** query on its own (cursor on it → Ctrl+Enter).
4. If a statement fails, execution stops there. Fix the cause and run again from that statement. The worksheet is **safe to re-run** (`IF NOT EXISTS` / `CREATE OR REPLACE`).
5. **Don't** "Run all" on the whole file: some steps need AWS changes or a wait in between.
6. `CREATE PROCEDURE` blocks contain `$$ ... $$`; highlight from `CREATE` through the closing `$$;`.

---

## 5. Setup steps

Tick each box as you go.

### Section 0 — Check your context
- [ ] Run the `SELECT`. Note **`account_identifier`**; your Power BI server is `<account_identifier>.snowflakecomputing.com`.

### Section 1 — Warehouses, database, schemas, roles
Creates: resource monitor `RM_ANALYTICS` (50 credits/month), `LOAD_WH`, `BI_WH`, `ANALYTICS_DB` with `RAW`, `STAGING`, `MARTS`, `OPS`, roles `ANALYTICS_ENGINEER` and `POWERBI_READER`.

- [ ] Run the section.
- [ ] **VERIFY 1:** two warehouses, four schemas, `ANALYTICS_ENGINEER` has `EXECUTE TASK` and `EXECUTE ALERT`.

### Section 2 — Storage integration (AWS assume role)
- [ ] Run the section. From `DESC INTEGRATION S3_EXPORTS_INT`, copy:
  - `STORAGE_AWS_IAM_USER_ARN`
  - `STORAGE_AWS_EXTERNAL_ID`
- [ ] **In AWS**, on the role in `<AWS_ROLE_ARN>`:
  - **Permission policy:** read-only on `exports/` (JSON in the worksheet comment, 2a).
  - **Trust policy:** principal = `STORAGE_AWS_IAM_USER_ARN`, condition `sts:ExternalId` = `STORAGE_AWS_EXTERNAL_ID` (JSON in comment 2b).
  ```bash
  aws iam update-assume-role-policy --role-name <role-name> --policy-document file://trust.json
  ```
- [ ] **VERIFY 2:** `SHOW INTEGRATIONS` shows `ENABLED = true`.

> ⚠️ **Never** run `CREATE OR REPLACE STORAGE INTEGRATION`. It generates a new external ID and breaks the AWS trust.

### Section 3 — File formats
- [ ] Run. **VERIFY 3:** `FF_CSV` and `FF_JSON` exist.

### Section 4 — Stages
- [ ] Run. **VERIFY 4** is the real test of the assume role:

| `LIST @STG_CSV` result | Meaning |
|---|---|
| File list | ✅ Working |
| Empty | ✅ Working, but no files exported yet (use §13 to test) |
| `Access Denied` | ❌ Trust policy or external ID wrong → redo the AWS part of §2 |
| `not allowed location` | ❌ Stage URL is not under `s3://<BUCKET>/exports/` |

### Section 5 — RAW + STAGING tables, streams
- [ ] Run. **VERIFY 5:** 6 RAW tables, 5 streams (`stale = false`), 5 STAGING tables.

### Section 6 — Snowpipe
- [ ] Run the six `CREATE PIPE` statements and `SHOW PIPES` together.
- [ ] In the last result, check **`distinct_channels` = 1** and copy the **`notification_channel`** (an SQS ARN).
- [ ] **In AWS, create the S3 event notification** (one rule for the whole `exports/` prefix):

  **Console:** S3 → bucket → *Properties* → *Event notifications* → *Create*
  - Prefix: `exports/`
  - Event types: *All object create events*
  - Destination: *SQS queue* → *Enter SQS queue ARN* → paste the `notification_channel`

  **CLI** (back up existing rules first; this command **replaces** all of them):
  ```bash
  aws s3api get-bucket-notification-configuration --bucket <BUCKET> > notif-backup.json
  cat > notif.json <<'EOF'
  {"QueueConfigurations":[{
     "Id":"snowpipe-exports",
     "QueueArn":"<notification_channel>",
     "Events":["s3:ObjectCreated:*"],
     "Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"exports/"}]}}
  }]}
  EOF
  aws s3api put-bucket-notification-configuration --bucket <BUCKET> --notification-configuration file://notif.json
  ```
  If `distinct_channels` > 1, create one rule per non-overlapping prefix (`exports/csv/`, `exports/json/`, `exports/manifests/`), each pointing at its pipe's channel.
- [ ] **VERIFY 6:** every pipe shows `executionState: RUNNING`.

### Section 7 — Backfill
- [ ] Run the `ALTER PIPE ... REFRESH` lines (loads files from the last 7 days).
- [ ] **Wait about 1 minute**, then run VERIFY 7 (row counts per RAW table).
- Files older than 7 days: run the pipe's `COPY INTO` once by hand (see the note in §7).

### Section 8 — Procedures
- [ ] Run both `CREATE PROCEDURE` blocks (`SP_MERGE_STAGING`, `SP_BUILD_MARTS`).
- [ ] **VERIFY 8:** run the two `CALL`s, then the counts. `AGG_DAILY_KPI` shows rows if data was loaded.

### Section 9 — Tasks (cron every minute)
- [ ] Run the section. It creates `TSK_MERGE_STAGING` (root, cron `* * * * *` Asia/Kolkata, runs only `WHEN` streams have data) and `TSK_BUILD_MARTS` (child), and resumes both.
- [ ] Wait 1–2 minutes. **VERIFY 9:** `TASK_HISTORY` shows runs:

| State | Meaning |
|---|---|
| `SKIPPED` | Ran on schedule, no new data. Normal, no cost |
| `SUCCEEDED` | Merged new data |
| `FAILED` | Read `error_message`; see [Troubleshooting](#9-troubleshooting) |

### Section 10 — Monitoring + alert
- [ ] Make sure `<ALERT_EMAIL>` is **verified** in Snowsight.
- [ ] Run the section (views, notification integration, alert).
- [ ] **VERIFY 10:** alert `started`; all pipes `RUNNING` in `VW_PIPE_STATUS`; `VW_FAILED_FILES` empty; test email received.

### Section 11 — Power BI read-only role
- [ ] Run the grants. **VERIFY 11:** `POWERBI_READER` sees MARTS tables only; selecting from RAW fails.
- [ ] When you connect Power BI, create the key-pair service user (commented block in §11):
  ```bash
  openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out pbi_key.p8 -nocrypt
  openssl rsa -in pbi_key.p8 -pubout -out pbi_key.pub
  grep -v "PUBLIC KEY" pbi_key.pub | tr -d '\n'     # paste into RSA_PUBLIC_KEY
  ```
  Keep `pbi_key.p8` in a password manager; never commit it.

### Section 13 — End-to-end test (do this before §12)
- [ ] In a terminal, run the commands in the §13 comment: they create sample CSV/JSON files and upload them with unique names.
- [ ] **Wait about 2 minutes. Don't run anything in Snowflake.**
- [ ] Run the query at the end of §13. Expected:

| call_id | status | duration_min | rating | network_drops |
|---|---|---|---|---|
| c-001 | completed | 15.00 | 5 | 0 |
| c-002 | dropped | 2.00 | 1 | 1 |

If these rows appear without you running a merge, the full automation works: **S3 event → Snowpipe → cron task → MARTS**.

Optional tests (also in the §13 comment): a newer update, an older out-of-order update, a JSON row with a missing key, and a bad CSV file.

### Section 12 — End-to-end verification
- [ ] Run each query **one at a time**. Healthy results:

| Check | Healthy |
|---|---|
| 12.1 `LIST @STG_CSV` | Lists files |
| 12.2 `VW_PIPE_STATUS` | All `RUNNING`, `pending_files` ≈ 0, recent `last_s3_event` |
| 12.3 File load status | `Loaded` only; the second query returns no rows |
| 12.4 Row counts | `STAGING.CALLS` = `MARTS.FCT_CALLS`; RAW may be ≥ STAGING (duplicates removed) |
| 12.5 Duplicate keys | No rows |
| 12.5b Rejected rows | No rows |
| 12.6 Streams pending | `FALSE` (everything merged) |
| 12.7 Task runs | `SKIPPED` / `SUCCEEDED`, no `FAILED` |
| 12.8 Lag | `lag_minutes` 0–2 for every dataset |
| 12.9 Reconciliation | All `OK` (only if manifests are exported) |
| 12.10 KPIs | Numbers look right |

### Section 14 — Pause / cleanup
- [ ] **Don't run during setup.** Commented out on purpose; see [§12 of this runbook](#12-pause-resume-cleanup).

---

## 6. Go-live checklist

- [ ] Placeholders replaced; no `<...>` left in the worksheet
- [ ] `LIST @ANALYTICS_DB.RAW.STG_CSV` works
- [ ] S3 notification on `exports/` points at the pipes' SQS ARN
- [ ] All 6 pipes `RUNNING`
- [ ] Tasks `started`; `TASK_HISTORY` shows runs every minute
- [ ] Alert `started`; test email received
- [ ] §13 test rows reached `MARTS.FCT_CALLS` automatically
- [ ] No rows in `VW_FAILED_FILES`, `VW_REJECTED_ROWS`, duplicate-key check
- [ ] `RM_ANALYTICS` attached to `LOAD_WH` and `BI_WH`
- [ ] Power BI connects as `POWERBI_READER` and cannot read RAW
- [ ] RDS export writes real files to the expected S3 paths with unique names

---

## 7. Daily operations

Nothing needs to run by hand. Use this **2-minute health check** when you want to look (or when the alert emails you):

```sql
USE ROLE ANALYTICS_ENGINEER;
USE WAREHOUSE LOAD_WH;

SELECT * FROM ANALYTICS_DB.OPS.VW_PIPE_STATUS;        -- all RUNNING
SELECT * FROM ANALYTICS_DB.OPS.VW_FAILED_FILES;       -- no rows
SELECT * FROM ANALYTICS_DB.OPS.VW_PIPELINE_LAG;       -- lag_minutes small
SELECT * FROM ANALYTICS_DB.OPS.VW_REJECTED_ROWS;      -- no rows

SELECT name, state, COUNT(*) AS runs, MAX(scheduled_time) AS last_run
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD(hour, -1, CURRENT_TIMESTAMP())))
GROUP BY 1, 2;                                         -- no FAILED
```

**Weekly:** check credit usage.
```sql
SELECT warehouse_name, ROUND(SUM(credits_used), 2) AS credits_7d
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time > DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY 1;

SELECT pipe_name, ROUND(SUM(credits_used), 3) AS snowpipe_credits_7d
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE start_time > DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY 1;
```
(`ACCOUNT_USAGE` views can lag by up to ~3 hours.)

---

## 8. Monitoring reference

All views live in `ANALYTICS_DB.OPS`.

| View | Shows | Healthy |
|---|---|---|
| `VW_PIPE_STATUS` | Each pipe's state, backlog, last S3 event, last error | `RUNNING`, `pending_files` ≈ 0 |
| `VW_FILE_LOAD_STATUS` | Every file loaded or rejected in the last 24 h | `status = 'Loaded'` |
| `VW_FAILED_FILES` | Files that didn't load (bad rows → whole file skipped) | No rows |
| `VW_PIPELINE_LAG` | Per dataset: rows waiting since the last successful merge, and how long | `lag_minutes` ≤ 2 |
| `VW_REJECTED_ROWS` | Rows skipped because their business key is missing/invalid | No rows |
| `VW_RECONCILIATION` | Manifest row count vs rows loaded per file | All `OK` |

**Alert `ALRT_PIPELINE`** (every 15 min) emails when any of these is true: a failed file in the last 15 min, a pipe not `RUNNING` or > 100 files pending, a failed task, data waiting > 10 min, or newly rejected rows. It repeats every 15 minutes while the problem lasts; suspend it during a known incident:
```sql
ALTER ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE SUSPEND;   -- resume after the fix
```

---

## 9. Troubleshooting

### Files are in S3 but not in RAW

| Check | Command | Fix |
|---|---|---|
| Pipe running? | `SELECT * FROM ANALYTICS_DB.OPS.VW_PIPE_STATUS;` | If `PAUSED`: `ALTER PIPE ... SET PIPE_EXECUTION_PAUSED = FALSE;` |
| S3 events arriving? | `last_s3_event` in the same view is old or NULL | S3 notification missing, wrong prefix, or wrong SQS ARN → redo §6 AWS step |
| File path matches? | File must be under `exports/csv/<source>/<table>/` or `exports/json/...` | Table folder name must be `customers`, `agents`, `calls`, `call_feedback`, `call_events` |
| File rejected? | `SELECT * FROM ANALYTICS_DB.OPS.VW_FAILED_FILES;` | Read `first_error_message`; see below |
| Same file name as before? | Snowpipe skips names it already loaded | Upload under a **new** name |
| Arrived before notification existed? | | `ALTER PIPE <pipe> REFRESH;` |

### Common load errors (`first_error_message`)

| Error | Cause | Fix |
|---|---|---|
| `Number of columns in file does not match` | CSV columns ≠ RAW table columns | Export columns in the RAW table order |
| `Numeric value 'abc' is not recognized` | Text in a numeric column | Fix the source data, re-export with a new file name |
| `Timestamp '...' is not recognized` | Non-ISO timestamp | Export ISO-8601 (`2026-10-26T09:15:00+00:00`) |
| `Error parsing JSON` | Broken JSON line | Fix the exporter; one object per line |
| `Access Denied` / `S3 ... 403` | Assume-role trust or permissions | Re-check §2 (trust policy, external ID, `s3:GetObject` on `exports/*`) |

### RAW has data but STAGING/MARTS don't update

| Check | Command | Fix |
|---|---|---|
| Tasks running? | `SHOW TASKS IN SCHEMA ANALYTICS_DB.OPS;` | If `suspended`: `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');` |
| Task failing? | `TASK_HISTORY` query from §7 | Read `error_message` |
| Suspended after 10 failures? | `SHOW TASKS` state `suspended` | Fix the error, then re-enable as above |
| Rows rejected? | `SELECT * FROM ANALYTICS_DB.OPS.VW_REJECTED_ROWS;` | Fix keys in the source, re-export |
| Warehouse suspended by monitor? | `SHOW RESOURCE MONITORS;` (used ≥ quota) | Raise `CREDIT_QUOTA` or wait for the monthly reset |
| Stream stale? | `SHOW STREAMS IN SCHEMA ANALYTICS_DB.RAW;` → `stale = true` | See [Recovery: stale stream](#stale-stream) |

### Other

| Symptom | Fix |
|---|---|
| No alert emails | Email must be verified; `SHOW ALERTS` state `started`; check `SELECT * FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY()) ORDER BY scheduled_time DESC;` |
| Power BI shows old data | Check `MARTS` is current (§12.10), then the Power BI refresh schedule/credentials |
| Power BI "insufficient privileges" | Grants from §11; table must be in `MARTS` |
| `Insufficient privileges` running the worksheet | Run the statement with the role shown at the top of its section (`ACCOUNTADMIN` for integrations/monitor/alert email) |

---

## 10. Recovery procedures

### A file failed to load
1. `SELECT * FROM ANALYTICS_DB.OPS.VW_FAILED_FILES;` → read `first_error_message`.
2. Inspect the file without loading it:
   ```sql
   SELECT METADATA$FILE_ROW_NUMBER, $1, $2, $3, $4, $5
   FROM @ANALYTICS_DB.RAW.STG_CSV/<path-from-file_name> LIMIT 20;
   ```
3. Fix the data at the source and upload a corrected file under a **new name** (or re-export). Snowpipe loads it; the merge removes any overlap.

### STAGING looks wrong (bad merge, logic change)
Rebuild STAGING from all of RAW. Create the procedure once from the project file `03_procedures.sql` (section 5, `SP_REBUILD_STAGING`; same table names), then:
```sql
ALTER TASK ANALYTICS_DB.OPS.TSK_MERGE_STAGING SUSPEND;
CALL ANALYTICS_DB.OPS.SP_REBUILD_STAGING();
CALL ANALYTICS_DB.OPS.SP_BUILD_MARTS();
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');
```

<a id="stale-stream"></a>
### Stale stream (task was suspended for a long time)
```sql
ALTER TASK ANALYTICS_DB.OPS.TSK_MERGE_STAGING SUSPEND;
CREATE OR REPLACE STREAM ANALYTICS_DB.RAW.CALLS_STRM ON TABLE ANALYTICS_DB.RAW.CALLS APPEND_ONLY = TRUE;
-- repeat for any other stale stream, then rebuild STAGING (above) so nothing is missed
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');
```

### MARTS look wrong
```sql
CALL ANALYTICS_DB.OPS.SP_BUILD_MARTS();   -- rebuilds every MARTS table from STAGING
```

### Integration broke (Access Denied after someone recreated it)
1. `DESC INTEGRATION S3_EXPORTS_INT;` → copy the new `STORAGE_AWS_EXTERNAL_ID`.
2. Update the AWS role trust policy (§2).
3. `LIST @ANALYTICS_DB.RAW.STG_CSV;` to confirm.
4. Load what was missed: `ALTER PIPE <pipe> REFRESH;` for each pipe.

### Task graph suspended itself
```sql
-- after fixing the error shown in TASK_HISTORY:
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');
```

---

## 11. Common changes

### Change the schedule
Re-create the root task with a new `SCHEDULE` (worksheet §9 suspends first, then re-enables):
| Need | Schedule |
|---|---|
| Every minute (default) | `USING CRON * * * * * Asia/Kolkata` |
| Every 5 minutes | `USING CRON */5 * * * * Asia/Kolkata` |
| Hourly, business hours, Mon–Fri | `USING CRON 0 9-18 * * 1-5 Asia/Kolkata` |

Format: `minute hour day-of-month month day-of-week time-zone`.

### Add a column (CSV table)
1. Exporter: add the column at the **end** of the CSV.
2. `ALTER TABLE ANALYTICS_DB.RAW.CALLS ADD COLUMN <col> <type>;` and the same on `STAGING.CALLS`.
3. Re-create the pipe with the new column in its column list and the next `$n`:
   ```sql
   ALTER PIPE ANALYTICS_DB.RAW.PIPE_CALLS SET PIPE_EXECUTION_PAUSED = TRUE;
   CREATE OR REPLACE PIPE ANALYTICS_DB.RAW.PIPE_CALLS AUTO_INGEST = TRUE AS COPY INTO ... ;   -- updated
   ```
4. Add the column to the `MERGE` in `SP_MERGE_STAGING` and, if needed, to `SP_BUILD_MARTS`.

> Re-creating a pipe resets its load history. Files staged in the last 7 days can be reloaded with `REFRESH`; the merge removes duplicates.

### Add a JSON field
Nothing to change on load (the whole object is stored as `VARIANT`). Extract the new field in `SP_MERGE_STAGING`.

### Add a new table
1. Exporter writes to `exports/csv/<source>/<new_table>/` (or `json/`).
2. Add a RAW table, a stream, a STAGING table and a pipe (copy the pattern for `customers`).
3. Add a `MERGE` to `SP_MERGE_STAGING`, its stream to the task's `WHEN` clause, and its use in `SP_BUILD_MARTS`.
4. Add it to `VW_FILE_LOAD_STATUS` and `VW_PIPELINE_LAG`.

### Raise the cost limit
```sql
USE ROLE ACCOUNTADMIN;
ALTER RESOURCE MONITOR RM_ANALYTICS SET CREDIT_QUOTA = 100;
```

---

## 12. Pause, resume, cleanup

**Pause** (stops loading and processing; S3 files keep arriving and wait):
```sql
USE ROLE ANALYTICS_ENGINEER;
ALTER TASK  ANALYTICS_DB.OPS.TSK_MERGE_STAGING SUSPEND;
ALTER ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE SUSPEND;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_CUSTOMERS     SET PIPE_EXECUTION_PAUSED = TRUE;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_AGENTS        SET PIPE_EXECUTION_PAUSED = TRUE;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_CALLS         SET PIPE_EXECUTION_PAUSED = TRUE;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_CALL_FEEDBACK SET PIPE_EXECUTION_PAUSED = TRUE;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_CALL_EVENTS   SET PIPE_EXECUTION_PAUSED = TRUE;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_MANIFESTS     SET PIPE_EXECUTION_PAUSED = TRUE;
```

**Resume:**
```sql
-- set PIPE_EXECUTION_PAUSED = FALSE on each pipe, then:
ALTER PIPE ANALYTICS_DB.RAW.PIPE_CALLS REFRESH;      -- per pipe: picks up files that arrived while paused (last 7 days)
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');
ALTER ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE RESUME;
```

**Remove everything** (irreversible): run the commented block in worksheet §14, then in AWS remove the S3 event notification rule and the Snowflake trust from the IAM role.

---

## 13. Object reference

| Object | Name |
|---|---|
| Database | `ANALYTICS_DB` |
| Schemas | `RAW` (as loaded), `STAGING` (current state), `MARTS` (Power BI), `OPS` (procedures, tasks, monitoring) |
| Warehouses | `LOAD_WH` (tasks), `BI_WH` (Power BI); XSMALL, 60 s auto-suspend |
| Resource monitor | `RM_ANALYTICS`: 50 credits/month; notify 75 %, suspend 90 %, hard stop 100 % |
| Roles | `ANALYTICS_ENGINEER` (runs the pipeline), `POWERBI_READER` (MARTS only) |
| Storage integration | `S3_EXPORTS_INT` → `<AWS_ROLE_ARN>`, allowed `s3://<BUCKET>/exports/` |
| File formats | `RAW.FF_CSV`, `RAW.FF_JSON` |
| Stages | `RAW.STG_CSV` (`exports/csv/`), `RAW.STG_JSON` (`exports/json/`), `RAW.STG_MANIFESTS` (`exports/manifests/`) |
| RAW tables | `CUSTOMERS`, `AGENTS`, `CALLS`, `CALL_FEEDBACK_JSON`, `CALL_EVENTS_JSON`, `EXPORT_MANIFESTS` |
| Streams | `CUSTOMERS_STRM`, `AGENTS_STRM`, `CALLS_STRM`, `CALL_FEEDBACK_JSON_STRM`, `CALL_EVENTS_JSON_STRM` |
| Pipes | `PIPE_CUSTOMERS`, `PIPE_AGENTS`, `PIPE_CALLS`, `PIPE_CALL_FEEDBACK`, `PIPE_CALL_EVENTS`, `PIPE_MANIFESTS` |
| STAGING tables | `CUSTOMERS`, `AGENTS`, `CALLS`, `CALL_FEEDBACK`, `CALL_EVENTS` |
| MARTS tables | `DIM_CUSTOMER`, `DIM_AGENT`, `FCT_CALLS`, `AGG_DAILY_KPI`, `AGG_AGENT_PERFORMANCE`, `AGG_HOURLY_HEATMAP` |
| Procedures | `OPS.SP_MERGE_STAGING`, `OPS.SP_BUILD_MARTS` |
| Tasks | `OPS.TSK_MERGE_STAGING` (cron every minute), `OPS.TSK_BUILD_MARTS` (after merge) |
| Alert | `OPS.ALRT_PIPELINE` (cron every 15 min) via `ANALYTICS_EMAIL_INT` |
| Monitoring views | `OPS.VW_PIPE_STATUS`, `VW_FILE_LOAD_STATUS`, `VW_FAILED_FILES`, `VW_PIPELINE_LAG`, `VW_REJECTED_ROWS`, `VW_RECONCILIATION` |
| Power BI user (optional) | `SVC_POWERBI` (key-pair, `TYPE = SERVICE`) |
