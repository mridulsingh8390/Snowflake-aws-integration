/* =============================================================================
   SNOWFLAKE COMPLETE WORKSHEET
   RDS PostgreSQL -> S3 (CSV + JSON) -> Snowflake (assume role, stages, Snowpipe)
                  -> tasks every minute (CRON) -> analytics tables -> Power BI

   HOW TO USE
   ----------
   1. Open Snowsight -> Projects -> Workspaces (or Worksheets) -> + SQL file,
      paste this whole file.
   2. Find & Replace (Ctrl+H) these placeholders before running anything:

        <AWS_ROLE_ARN>        arn:aws:iam::111122223333:role/snowflake-s3-read   (your assume role)
        <BUCKET>              your S3 bucket name, e.g. nitor-rds-snowflake-exports
        <ALERT_EMAIL>         a VERIFIED email of a Snowflake user (for alerts)

   3. Run section by section (select a block -> Ctrl+Enter, or "Run all" per section).
      Every section ends with a  ✅ VERIFY  block: check it before moving on.

   EXPECTED S3 LAYOUT (what the RDS export writes)
   -----------------------------------------------
     s3://<BUCKET>/exports/csv/<source>/<table>/dt=YYYY-MM-DD/<table>_<ts>.csv.gz
     s3://<BUCKET>/exports/json/<source>/<table>/dt=YYYY-MM-DD/<table>_<ts>.json.gz
     s3://<BUCKET>/exports/manifests/<source>/<table>/dt=YYYY-MM-DD/<table>_<ts>.json   (optional)

     CSV tables : customers, agents, calls      (header row, gzip)
     JSON tables: call_feedback, call_events    (JSON Lines = one object per line, gzip)
     <source> is any short DB name, e.g. "appdb". Several sources are supported.

   FLOW
   ----
     S3 new file --(S3 event)--> Snowpipe (auto-ingest, ~1 min) --> RAW tables
     RAW --(streams)--> TASK every minute: MERGE --> STAGING
                    --> child TASK: rebuild MARTS (Power BI tables)
     Tasks only start a warehouse when the streams actually have new rows.

   SECTIONS
   --------
     0. Check your context
     1. Warehouses, database, schemas, roles
     2. Storage integration = AWS assume role  (+ AWS trust policy step)
     3. File formats (CSV + JSON)
     4. Stages (+ read files in place)
     5. RAW / STAGING tables + streams
     6. Snowpipe (auto-ingest)            (+ AWS S3 event notification step)
     7. Backfill files that already exist
     8. Procedures: MERGE to STAGING, build MARTS
     9. Tasks with CRON every minute
    10. Monitoring views + alert
    11. Power BI read-only role
    12. END-TO-END VERIFICATION
    13. Test without the Lambda (manual sample files)
    14. Pause / cleanup
   ============================================================================= */


/* =============================================================================
   0. CHECK YOUR CONTEXT
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

SELECT CURRENT_USER()                AS me,
       CURRENT_ROLE()                AS role,
       CURRENT_REGION()              AS region,       -- best: same AWS region as the bucket (e.g. AWS_AP_SOUTH_1)
       CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier;
-- Power BI server name = <account_identifier>.snowflakecomputing.com


/* =============================================================================
   1. WAREHOUSES, DATABASE, SCHEMAS, ROLES
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

-- Compute: XSMALL + 60 s auto-suspend keeps costs low
-- Cost guardrail FIRST, so warehouses are capped from the moment they exist
CREATE RESOURCE MONITOR IF NOT EXISTS RM_ANALYTICS
  WITH CREDIT_QUOTA = 50 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75  PERCENT DO NOTIFY
           ON 90  PERCENT DO SUSPEND             -- let running queries finish
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;  -- hard stop

-- Compute: XSMALL + 60 s auto-suspend keeps costs low
CREATE WAREHOUSE IF NOT EXISTS LOAD_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  RESOURCE_MONITOR = RM_ANALYTICS
  COMMENT = 'Tasks: merge + marts';
CREATE WAREHOUSE IF NOT EXISTS BI_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  RESOURCE_MONITOR = RM_ANALYTICS
  COMMENT = 'Power BI (Import mode: 60 s is enough; use 300 s only for DirectQuery to keep the cache warm)';
-- Warehouses that already existed: attach the monitor explicitly
ALTER WAREHOUSE LOAD_WH SET RESOURCE_MONITOR = RM_ANALYTICS;
ALTER WAREHOUSE BI_WH   SET RESOURCE_MONITOR = RM_ANALYTICS;

-- One database, one schema per layer
CREATE DATABASE IF NOT EXISTS ANALYTICS_DB;
CREATE SCHEMA IF NOT EXISTS ANALYTICS_DB.RAW     DATA_RETENTION_TIME_IN_DAYS = 1 COMMENT = 'Data exactly as loaded from S3';
CREATE SCHEMA IF NOT EXISTS ANALYTICS_DB.STAGING DATA_RETENTION_TIME_IN_DAYS = 1 COMMENT = 'Deduplicated current state';
CREATE SCHEMA IF NOT EXISTS ANALYTICS_DB.MARTS   DATA_RETENTION_TIME_IN_DAYS = 1 COMMENT = 'Tables for Power BI (rebuilt from STAGING)';
-- MARTS tables are rebuilt on every task run (up to every minute). Long Time Travel here would keep
-- every replaced copy for days, so keep it at 1 day (marts are transient and rebuildable).
ALTER SCHEMA ANALYTICS_DB.MARTS SET DATA_RETENTION_TIME_IN_DAYS = 1;
CREATE SCHEMA IF NOT EXISTS ANALYTICS_DB.OPS     COMMENT = 'Procedures, tasks, monitoring';

-- Roles
CREATE ROLE IF NOT EXISTS ANALYTICS_ENGINEER;
CREATE ROLE IF NOT EXISTS POWERBI_READER;
GRANT ROLE POWERBI_READER     TO ROLE ANALYTICS_ENGINEER;
GRANT ROLE ANALYTICS_ENGINEER TO ROLE SYSADMIN;
SET my_user = CURRENT_USER();
GRANT ROLE ANALYTICS_ENGINEER TO USER IDENTIFIER($my_user);

GRANT OWNERSHIP ON DATABASE ANALYTICS_DB TO ROLE ANALYTICS_ENGINEER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE ANALYTICS_DB TO ROLE ANALYTICS_ENGINEER COPY CURRENT GRANTS;
GRANT USAGE, OPERATE ON WAREHOUSE LOAD_WH TO ROLE ANALYTICS_ENGINEER;
GRANT USAGE          ON WAREHOUSE BI_WH   TO ROLE POWERBI_READER;
GRANT EXECUTE TASK, EXECUTE ALERT ON ACCOUNT TO ROLE ANALYTICS_ENGINEER;

-- ✅ VERIFY 1
SHOW WAREHOUSES LIKE '%_WH';
SHOW SCHEMAS IN DATABASE ANALYTICS_DB;          -- RAW, STAGING, MARTS, OPS (+ INFORMATION_SCHEMA, PUBLIC)
SHOW GRANTS TO ROLE ANALYTICS_ENGINEER;


/* =============================================================================
   2. STORAGE INTEGRATION = THE AWS ASSUME-ROLE CONNECTION
   -----------------------------------------------------------------------------
   Snowflake's own AWS IAM user calls sts:AssumeRole on <AWS_ROLE_ARN> with an
   external ID, gets temporary credentials, and reads S3. No access keys stored.
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

-- IF NOT EXISTS on purpose: CREATE OR REPLACE would generate a NEW external ID
-- and break the AWS trust policy.
CREATE STORAGE INTEGRATION IF NOT EXISTS S3_EXPORTS_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = '<AWS_ROLE_ARN>'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<BUCKET>/exports/')
  COMMENT = 'Assumes the AWS role (read-only on exports/)';

GRANT USAGE ON INTEGRATION S3_EXPORTS_INT TO ROLE ANALYTICS_ENGINEER;

-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this output:
DESC INTEGRATION S3_EXPORTS_INT;

/* ---------- AWS SIDE (run in AWS, not in Snowflake) ----------------------------
   2a. Permission policy on the role (read-only on the export prefix):

   {
     "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:GetObjectVersion"],
         "Resource": "arn:aws:s3:::<BUCKET>/exports/*" },
       { "Effect": "Allow",
         "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
         "Resource": "arn:aws:s3:::<BUCKET>",
         "Condition": { "StringLike": { "s3:prefix": ["exports/*"] } } }
     ]
   }

   2b. Trust policy on the role (values from DESC INTEGRATION above):

   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "AWS": "<STORAGE_AWS_IAM_USER_ARN>" },
       "Action": "sts:AssumeRole",
       "Condition": { "StringEquals": { "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>" } }
     }]
   }

   aws iam update-assume-role-policy --role-name <role-name> --policy-document file://trust.json

   (Using the Terraform project? Put both values in terraform.tfvars and run
    terraform apply instead.)
   ------------------------------------------------------------------------------ */

-- ✅ VERIFY 2  (after the AWS trust policy is updated)
--    Should return the STORAGE_AWS_ROLE_ARN = your role and ENABLED = true.
--    The real connectivity test is LIST @stage in section 4.
SHOW INTEGRATIONS LIKE 'S3_EXPORTS_INT';


/* =============================================================================
   3. FILE FORMATS
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE WAREHOUSE LOAD_WH;
USE SCHEMA ANALYTICS_DB.RAW;

-- CSV from PostgreSQL / the Lambda: header row, gzip, quoted values,
-- unquoted empty field = NULL, ISO-8601 timestamps
CREATE OR REPLACE FILE FORMAT FF_CSV
  TYPE = CSV
  COMPRESSION = AUTO
  SKIP_HEADER = 1
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('\\N', 'NULL')
  TIMESTAMP_FORMAT = 'AUTO'
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE
  ENCODING = 'UTF8';

-- JSON Lines (one object per line). Also accepts a single JSON array per file.
CREATE OR REPLACE FILE FORMAT FF_JSON
  TYPE = JSON
  COMPRESSION = AUTO
  STRIP_OUTER_ARRAY = TRUE;

-- ✅ VERIFY 3
SHOW FILE FORMATS IN SCHEMA ANALYTICS_DB.RAW;   -- FF_CSV, FF_JSON


/* =============================================================================
   4. STAGES (S3 via the assume-role integration)
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE SCHEMA ANALYTICS_DB.RAW;

CREATE STAGE IF NOT EXISTS STG_CSV
  URL = 's3://<BUCKET>/exports/csv/'
  STORAGE_INTEGRATION = S3_EXPORTS_INT
  FILE_FORMAT = FF_CSV;

CREATE STAGE IF NOT EXISTS STG_JSON
  URL = 's3://<BUCKET>/exports/json/'
  STORAGE_INTEGRATION = S3_EXPORTS_INT
  FILE_FORMAT = FF_JSON;

CREATE STAGE IF NOT EXISTS STG_MANIFESTS
  URL = 's3://<BUCKET>/exports/manifests/'
  STORAGE_INTEGRATION = S3_EXPORTS_INT
  FILE_FORMAT = FF_JSON;

-- ✅ VERIFY 4  — this is the real test of the assume role
LIST @STG_CSV;    -- Access Denied  -> trust policy / external ID wrong (section 2b)
LIST @STG_JSON;   -- empty result   -> no files exported yet (fine; see section 13)

-- Read files IN PLACE before loading (checks the file formats)
SELECT METADATA$FILENAME AS file, $1, $2, $3, $4, $5
FROM @STG_CSV (PATTERN => '.*/calls/.*') LIMIT 5;

SELECT METADATA$FILENAME AS file, $1
FROM @STG_JSON (PATTERN => '.*/call_feedback/.*') LIMIT 5;


/* =============================================================================
   5. RAW + STAGING TABLES AND STREAMS
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE SCHEMA ANALYTICS_DB.RAW;

-- ---------- RAW (transient: reloadable from S3, no Fail-safe cost) ----------
-- CSV column order must match the CSV file column order.
CREATE TRANSIENT TABLE IF NOT EXISTS CUSTOMERS (
  customer_id NUMBER, customer_name STRING, plan STRING, region STRING,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ,
  _source STRING, _file_name STRING, _file_row NUMBER, _loaded_at TIMESTAMP_LTZ);

CREATE TRANSIENT TABLE IF NOT EXISTS AGENTS (
  agent_id NUMBER, agent_name STRING, team STRING, email STRING,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ,
  _source STRING, _file_name STRING, _file_row NUMBER, _loaded_at TIMESTAMP_LTZ);

CREATE TRANSIENT TABLE IF NOT EXISTS CALLS (
  call_id STRING, customer_id NUMBER, agent_id NUMBER, channel STRING, status STRING,
  started_at TIMESTAMP_TZ, ended_at TIMESTAMP_TZ, duration_sec NUMBER, recording_url STRING,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ,
  _source STRING, _file_name STRING, _file_row NUMBER, _loaded_at TIMESTAMP_LTZ);

-- JSON: whole object in one VARIANT column (new fields never break the load)
CREATE TRANSIENT TABLE IF NOT EXISTS CALL_FEEDBACK_JSON (
  payload VARIANT, _source STRING, _file_name STRING, _loaded_at TIMESTAMP_LTZ);

CREATE TRANSIENT TABLE IF NOT EXISTS CALL_EVENTS_JSON (
  payload VARIANT, _source STRING, _file_name STRING, _loaded_at TIMESTAMP_LTZ);

CREATE TRANSIENT TABLE IF NOT EXISTS EXPORT_MANIFESTS (
  payload VARIANT, _file_name STRING, _loaded_at TIMESTAMP_LTZ);

-- ---------- Streams: "rows loaded into RAW since the last merge" ----------
CREATE STREAM IF NOT EXISTS CUSTOMERS_STRM          ON TABLE CUSTOMERS          APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS AGENTS_STRM             ON TABLE AGENTS             APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS CALLS_STRM              ON TABLE CALLS              APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS CALL_FEEDBACK_JSON_STRM ON TABLE CALL_FEEDBACK_JSON APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS CALL_EVENTS_JSON_STRM   ON TABLE CALL_EVENTS_JSON   APPEND_ONLY = TRUE;

-- ---------- STAGING: one row per key, current state ----------
USE SCHEMA ANALYTICS_DB.STAGING;

CREATE TABLE IF NOT EXISTS CUSTOMERS (
  customer_id NUMBER PRIMARY KEY, customer_name STRING, plan STRING, region STRING,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ, _merged_at TIMESTAMP_LTZ);

CREATE TABLE IF NOT EXISTS AGENTS (
  agent_id NUMBER PRIMARY KEY, agent_name STRING, team STRING, email STRING,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ, _merged_at TIMESTAMP_LTZ);

CREATE TABLE IF NOT EXISTS CALLS (
  call_id STRING PRIMARY KEY, customer_id NUMBER, agent_id NUMBER, channel STRING, status STRING,
  started_at TIMESTAMP_TZ, ended_at TIMESTAMP_TZ, duration_sec NUMBER, recording_url STRING,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ, _merged_at TIMESTAMP_LTZ);

CREATE TABLE IF NOT EXISTS CALL_FEEDBACK (
  feedback_id NUMBER PRIMARY KEY, call_id STRING, rating NUMBER, comment STRING, tags ARRAY,
  created_at TIMESTAMP_TZ, updated_at TIMESTAMP_TZ, _merged_at TIMESTAMP_LTZ);

CREATE TABLE IF NOT EXISTS CALL_EVENTS (
  event_id NUMBER PRIMARY KEY, call_id STRING, event_type STRING,
  device STRING, network STRING, latency_ms NUMBER, payload VARIANT,
  created_at TIMESTAMP_TZ, _merged_at TIMESTAMP_LTZ);

-- ✅ VERIFY 5
SHOW TABLES  IN SCHEMA ANALYTICS_DB.RAW;
SHOW STREAMS IN SCHEMA ANALYTICS_DB.RAW;        -- 5 streams, stale = false
SHOW TABLES  IN SCHEMA ANALYTICS_DB.STAGING;


/* =============================================================================
   6. SNOWPIPE (AUTO-INGEST): every new S3 file is loaded within ~1 minute
   -----------------------------------------------------------------------------
   One pipe per table. PATTERN picks that table's files from ALL sources.
   ON_ERROR = SKIP_FILE: a file with a bad row is not loaded at all (no partial
   loads) and shows up in monitoring.
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE SCHEMA ANALYTICS_DB.RAW;

CREATE PIPE IF NOT EXISTS PIPE_CUSTOMERS AUTO_INGEST = TRUE AS
COPY INTO ANALYTICS_DB.RAW.CUSTOMERS
  (customer_id, customer_name, plan, region, created_at, updated_at,
   _source, _file_name, _file_row, _loaded_at)
FROM (SELECT $1, $2, $3, $4, $5, $6,
             SPLIT_PART(METADATA$FILENAME, '/', 1), METADATA$FILENAME,
             METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
      FROM @ANALYTICS_DB.RAW.STG_CSV)
PATTERN = '.*/customers/.*[.]csv([.]gz)?'
ON_ERROR = SKIP_FILE;

CREATE PIPE IF NOT EXISTS PIPE_AGENTS AUTO_INGEST = TRUE AS
COPY INTO ANALYTICS_DB.RAW.AGENTS
  (agent_id, agent_name, team, email, created_at, updated_at,
   _source, _file_name, _file_row, _loaded_at)
FROM (SELECT $1, $2, $3, $4, $5, $6,
             SPLIT_PART(METADATA$FILENAME, '/', 1), METADATA$FILENAME,
             METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
      FROM @ANALYTICS_DB.RAW.STG_CSV)
PATTERN = '.*/agents/.*[.]csv([.]gz)?'
ON_ERROR = SKIP_FILE;

CREATE PIPE IF NOT EXISTS PIPE_CALLS AUTO_INGEST = TRUE AS
COPY INTO ANALYTICS_DB.RAW.CALLS
  (call_id, customer_id, agent_id, channel, status, started_at, ended_at,
   duration_sec, recording_url, created_at, updated_at,
   _source, _file_name, _file_row, _loaded_at)
FROM (SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
             SPLIT_PART(METADATA$FILENAME, '/', 1), METADATA$FILENAME,
             METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
      FROM @ANALYTICS_DB.RAW.STG_CSV)
PATTERN = '.*/calls/.*[.]csv([.]gz)?'
ON_ERROR = SKIP_FILE;

CREATE PIPE IF NOT EXISTS PIPE_CALL_FEEDBACK AUTO_INGEST = TRUE AS
COPY INTO ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON (payload, _source, _file_name, _loaded_at)
FROM (SELECT $1, SPLIT_PART(METADATA$FILENAME, '/', 1), METADATA$FILENAME, METADATA$START_SCAN_TIME
      FROM @ANALYTICS_DB.RAW.STG_JSON)
PATTERN = '.*/call_feedback/.*[.]json([.]gz)?'
ON_ERROR = SKIP_FILE;

CREATE PIPE IF NOT EXISTS PIPE_CALL_EVENTS AUTO_INGEST = TRUE AS
COPY INTO ANALYTICS_DB.RAW.CALL_EVENTS_JSON (payload, _source, _file_name, _loaded_at)
FROM (SELECT $1, SPLIT_PART(METADATA$FILENAME, '/', 1), METADATA$FILENAME, METADATA$START_SCAN_TIME
      FROM @ANALYTICS_DB.RAW.STG_JSON)
PATTERN = '.*/call_events/.*[.]json([.]gz)?'
ON_ERROR = SKIP_FILE;

CREATE PIPE IF NOT EXISTS PIPE_MANIFESTS AUTO_INGEST = TRUE AS
COPY INTO ANALYTICS_DB.RAW.EXPORT_MANIFESTS (payload, _file_name, _loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$START_SCAN_TIME
      FROM @ANALYTICS_DB.RAW.STG_MANIFESTS)
ON_ERROR = SKIP_FILE;

-- The SQS queue to send S3 events to = "notification_channel".
-- Auto-ingest pipes in the same Snowflake account and region normally share ONE queue.
-- Confirm it: distinct_channels must be 1. If it is > 1, create one S3 rule per
-- (non-overlapping) prefix pointing at each pipe's own channel instead of a single exports/ rule.
SHOW PIPES IN SCHEMA ANALYTICS_DB.RAW;
SELECT "name", "notification_channel",
       COUNT(DISTINCT "notification_channel") OVER () AS distinct_channels
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

/* ---------- AWS SIDE: S3 event notification -> Snowpipe SQS -------------------
   One rule for the whole exports/ prefix triggers every pipe above
   (S3 does not allow overlapping prefixes for the same event type).

   cat > notif.json <<'EOF'
   {"QueueConfigurations":[{
      "Id":"snowpipe-exports",
      "QueueArn":"<notification_channel ARN from above>",
      "Events":["s3:ObjectCreated:*"],
      "Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"exports/"}]}}
   }]}
   EOF
   aws s3api get-bucket-notification-configuration --bucket <BUCKET>   # back up existing rules first!
   aws s3api put-bucket-notification-configuration --bucket <BUCKET> \
       --notification-configuration file://notif.json                  # REPLACES all rules

   Console: S3 -> bucket -> Properties -> Event notifications -> Create:
            prefix "exports/", All object create events, Destination SQS queue ARN.
   ------------------------------------------------------------------------------ */

-- ✅ VERIFY 6  (executionState should be RUNNING)
SELECT SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CUSTOMERS')     AS customers,
       SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CALLS')         AS calls,
       SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CALL_FEEDBACK') AS feedback;


/* =============================================================================
   7. BACKFILL: load files that were in S3 BEFORE the pipes existed
   -----------------------------------------------------------------------------
   ALTER PIPE ... REFRESH queues files staged in the last 7 days.
   Older files: run the same COPY statement once by hand (see bottom note).
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;

ALTER PIPE ANALYTICS_DB.RAW.PIPE_CUSTOMERS     REFRESH;
ALTER PIPE ANALYTICS_DB.RAW.PIPE_AGENTS        REFRESH;
ALTER PIPE ANALYTICS_DB.RAW.PIPE_CALLS         REFRESH;
ALTER PIPE ANALYTICS_DB.RAW.PIPE_CALL_FEEDBACK REFRESH;
ALTER PIPE ANALYTICS_DB.RAW.PIPE_CALL_EVENTS   REFRESH;
ALTER PIPE ANALYTICS_DB.RAW.PIPE_MANIFESTS     REFRESH;

-- ✅ VERIFY 7  (wait ~1 minute, then)
SELECT 'CUSTOMERS' t, COUNT(*) n FROM ANALYTICS_DB.RAW.CUSTOMERS UNION ALL
SELECT 'AGENTS',        COUNT(*) FROM ANALYTICS_DB.RAW.AGENTS UNION ALL
SELECT 'CALLS',         COUNT(*) FROM ANALYTICS_DB.RAW.CALLS UNION ALL
SELECT 'FEEDBACK_JSON', COUNT(*) FROM ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON UNION ALL
SELECT 'EVENTS_JSON',   COUNT(*) FROM ANALYTICS_DB.RAW.CALL_EVENTS_JSON UNION ALL
SELECT 'MANIFESTS',     COUNT(*) FROM ANALYTICS_DB.RAW.EXPORT_MANIFESTS;

-- Note: files older than 7 days -> run the pipe's COPY statement directly, e.g.
--   COPY INTO ANALYTICS_DB.RAW.CALLS (...same column list...) FROM (SELECT ... FROM @ANALYTICS_DB.RAW.STG_CSV)
--   PATTERN = '.*/calls/.*[.]csv([.]gz)?' ON_ERROR = SKIP_FILE;
-- COPY and Snowpipe keep separate load histories; any overlap is removed by the MERGE in section 8.


/* =============================================================================
   8. PROCEDURES: MERGE RAW -> STAGING, BUILD MARTS
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE SCHEMA ANALYTICS_DB.OPS;

-- ---------- 8a. Merge only NEW raw rows (streams), latest version per key ----------
CREATE OR REPLACE PROCEDURE SP_MERGE_STAGING()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  -- One transaction: either every table is merged and every stream advances, or nothing changes.
  BEGIN TRANSACTION;

  MERGE INTO ANALYTICS_DB.STAGING.CUSTOMERS t
  USING (SELECT * FROM ANALYTICS_DB.RAW.CUSTOMERS_STRM
         WHERE customer_id IS NOT NULL                                   -- NULL keys -> OPS.VW_REJECTED_ROWS
         QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id
                                    ORDER BY updated_at DESC NULLS LAST, _loaded_at DESC, _file_row DESC) = 1) s
  ON t.customer_id = s.customer_id
  WHEN MATCHED AND s.updated_at >= t.updated_at THEN UPDATE SET
    customer_name = s.customer_name, plan = s.plan, region = s.region,
    created_at = s.created_at, updated_at = s.updated_at, _merged_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (customer_id, customer_name, plan, region, created_at, updated_at, _merged_at)
    VALUES (s.customer_id, s.customer_name, s.plan, s.region, s.created_at, s.updated_at, CURRENT_TIMESTAMP());

  MERGE INTO ANALYTICS_DB.STAGING.AGENTS t
  USING (SELECT * FROM ANALYTICS_DB.RAW.AGENTS_STRM
         WHERE agent_id IS NOT NULL                                   -- NULL keys -> OPS.VW_REJECTED_ROWS
         QUALIFY ROW_NUMBER() OVER (PARTITION BY agent_id
                                    ORDER BY updated_at DESC NULLS LAST, _loaded_at DESC, _file_row DESC) = 1) s
  ON t.agent_id = s.agent_id
  WHEN MATCHED AND s.updated_at >= t.updated_at THEN UPDATE SET
    agent_name = s.agent_name, team = s.team, email = s.email,
    created_at = s.created_at, updated_at = s.updated_at, _merged_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (agent_id, agent_name, team, email, created_at, updated_at, _merged_at)
    VALUES (s.agent_id, s.agent_name, s.team, s.email, s.created_at, s.updated_at, CURRENT_TIMESTAMP());

  MERGE INTO ANALYTICS_DB.STAGING.CALLS t
  USING (SELECT * FROM ANALYTICS_DB.RAW.CALLS_STRM
         WHERE call_id IS NOT NULL                                   -- NULL keys -> OPS.VW_REJECTED_ROWS
         QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id
                                    ORDER BY updated_at DESC NULLS LAST, _loaded_at DESC, _file_row DESC) = 1) s
  ON t.call_id = s.call_id
  WHEN MATCHED AND s.updated_at >= t.updated_at THEN UPDATE SET
    customer_id = s.customer_id, agent_id = s.agent_id, channel = s.channel, status = s.status,
    started_at = s.started_at, ended_at = s.ended_at, duration_sec = s.duration_sec,
    recording_url = s.recording_url, created_at = s.created_at, updated_at = s.updated_at,
    _merged_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (call_id, customer_id, agent_id, channel, status, started_at, ended_at,
                                duration_sec, recording_url, created_at, updated_at, _merged_at)
    VALUES (s.call_id, s.customer_id, s.agent_id, s.channel, s.status, s.started_at, s.ended_at,
            s.duration_sec, s.recording_url, s.created_at, s.updated_at, CURRENT_TIMESTAMP());

  -- JSON -> columns
  MERGE INTO ANALYTICS_DB.STAGING.CALL_FEEDBACK t
  -- TRY_ casts: one malformed value becomes NULL instead of failing the whole transaction
  -- (which would block every table on every run). Rows without a valid key are skipped
  -- here and listed in OPS.VW_REJECTED_ROWS.
  USING (SELECT TRY_TO_NUMBER(payload:feedback_id::STRING)         AS feedback_id,
                payload:call_id::STRING                            AS call_id,
                TRY_TO_NUMBER(payload:rating::STRING)              AS rating,
                payload:comment::STRING                            AS comment,
                IFF(IS_ARRAY(payload:tags), payload:tags::ARRAY, ARRAY_CONSTRUCT()) AS tags,
                TRY_TO_TIMESTAMP_TZ(payload:created_at::STRING)    AS created_at,
                TRY_TO_TIMESTAMP_TZ(payload:updated_at::STRING)    AS updated_at,
                _loaded_at
         FROM ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON_STRM
         WHERE TRY_TO_NUMBER(payload:feedback_id::STRING) IS NOT NULL
         QUALIFY ROW_NUMBER() OVER (PARTITION BY feedback_id
                                    ORDER BY updated_at DESC NULLS LAST, _loaded_at DESC) = 1) s
  ON t.feedback_id = s.feedback_id
  WHEN MATCHED AND (s.updated_at >= t.updated_at OR t.updated_at IS NULL) THEN UPDATE SET
    call_id = s.call_id, rating = s.rating, comment = s.comment, tags = s.tags,
    created_at = s.created_at, updated_at = s.updated_at, _merged_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (feedback_id, call_id, rating, comment, tags, created_at, updated_at, _merged_at)
    VALUES (s.feedback_id, s.call_id, s.rating, s.comment, s.tags, s.created_at, s.updated_at, CURRENT_TIMESTAMP());

  -- Events are immutable: re-sent event_id is ignored.
  -- event_id must be unique across sources. With several source DBs whose IDs can
  -- collide, add _source to the key (staging column + PARTITION BY + ON clause).
  MERGE INTO ANALYTICS_DB.STAGING.CALL_EVENTS t
  USING (SELECT TRY_TO_NUMBER(payload:event_id::STRING)              AS event_id,
                payload:call_id::STRING                              AS call_id,
                payload:event_type::STRING                           AS event_type,
                payload:payload:device::STRING                       AS device,
                payload:payload:network::STRING                      AS network,
                TRY_TO_NUMBER(payload:payload:latency_ms::STRING)    AS latency_ms,
                payload:payload                                      AS payload,
                TRY_TO_TIMESTAMP_TZ(payload:created_at::STRING)      AS created_at
         FROM ANALYTICS_DB.RAW.CALL_EVENTS_JSON_STRM
         WHERE TRY_TO_NUMBER(payload:event_id::STRING) IS NOT NULL
         QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY _loaded_at DESC) = 1) s
  ON t.event_id = s.event_id
  WHEN NOT MATCHED THEN INSERT (event_id, call_id, event_type, device, network, latency_ms, payload, created_at, _merged_at)
    VALUES (s.event_id, s.call_id, s.event_type, s.device, s.network, s.latency_ms, s.payload, s.created_at, CURRENT_TIMESTAMP());

  COMMIT;
  RETURN 'SP_MERGE_STAGING done';
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;   -- streams keep their rows, next run retries them
    RAISE;      -- re-throw so the task run shows FAILED
END;
$$;

-- ---------- 8b. Build the Power BI tables ----------
CREATE OR REPLACE PROCEDURE SP_BUILD_MARTS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  CREATE OR REPLACE TRANSIENT TABLE ANALYTICS_DB.MARTS.DIM_CUSTOMER COPY GRANTS AS
  SELECT customer_id, customer_name, plan, region FROM ANALYTICS_DB.STAGING.CUSTOMERS;

  CREATE OR REPLACE TRANSIENT TABLE ANALYTICS_DB.MARTS.DIM_AGENT COPY GRANTS AS
  SELECT agent_id, agent_name, team FROM ANALYTICS_DB.STAGING.AGENTS;

  CREATE OR REPLACE TRANSIENT TABLE ANALYTICS_DB.MARTS.FCT_CALLS COPY GRANTS AS
  WITH ev AS (
    SELECT call_id,
           COUNT_IF(event_type = 'network_drop') AS network_drops,
           COUNT_IF(event_type = 'reconnect')    AS reconnects,
           ROUND(AVG(latency_ms), 0)             AS avg_latency_ms
    FROM ANALYTICS_DB.STAGING.CALL_EVENTS GROUP BY call_id),
  fb AS (
    SELECT call_id, AVG(rating) AS rating, MAX(comment) AS feedback_comment
    FROM ANALYTICS_DB.STAGING.CALL_FEEDBACK GROUP BY call_id)
  SELECT c.call_id, c.customer_id, c.agent_id,
         TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.started_at))       AS call_date,
         HOUR(CONVERT_TIMEZONE('Asia/Kolkata', c.started_at))          AS call_hour,
         DAYNAME(CONVERT_TIMEZONE('Asia/Kolkata', c.started_at))       AS call_weekday,
         CONVERT_TIMEZONE('Asia/Kolkata', c.started_at)::TIMESTAMP_NTZ AS started_at_ist,
         c.channel, c.status, c.duration_sec,
         ROUND(c.duration_sec / 60, 2)                                 AS duration_min,
         IFF(c.recording_url IS NOT NULL, 1, 0)                        AS has_recording,
         COALESCE(ev.network_drops, 0) AS network_drops,
         COALESCE(ev.reconnects, 0)    AS reconnects,
         ev.avg_latency_ms,
         fb.rating, fb.feedback_comment
  FROM ANALYTICS_DB.STAGING.CALLS c
  LEFT JOIN ev ON ev.call_id = c.call_id
  LEFT JOIN fb ON fb.call_id = c.call_id;

  CREATE OR REPLACE TRANSIENT TABLE ANALYTICS_DB.MARTS.AGG_DAILY_KPI COPY GRANTS AS
  SELECT call_date,
         COUNT(*)                                                      AS total_calls,
         COUNT_IF(status = 'completed')                                AS completed_calls,
         COUNT_IF(status = 'dropped')                                  AS dropped_calls,
         ROUND(SUM(duration_min), 1)                                   AS total_minutes,
         ROUND(AVG(IFF(status = 'completed', duration_min, NULL)), 2)  AS avg_duration_min,
         ROUND(AVG(rating), 2)                                         AS avg_rating
  FROM ANALYTICS_DB.MARTS.FCT_CALLS GROUP BY call_date;

  CREATE OR REPLACE TRANSIENT TABLE ANALYTICS_DB.MARTS.AGG_AGENT_PERFORMANCE COPY GRANTS AS
  SELECT f.agent_id, a.agent_name, a.team,
         COUNT(*)                                                       AS total_calls,
         ROUND(COUNT_IF(f.status = 'dropped') / NULLIF(COUNT(*), 0), 4) AS drop_rate,
         ROUND(AVG(f.rating), 2)                                        AS avg_rating
  FROM ANALYTICS_DB.MARTS.FCT_CALLS f
  LEFT JOIN ANALYTICS_DB.MARTS.DIM_AGENT a ON a.agent_id = f.agent_id
  GROUP BY 1, 2, 3;

  CREATE OR REPLACE TRANSIENT TABLE ANALYTICS_DB.MARTS.AGG_HOURLY_HEATMAP COPY GRANTS AS
  SELECT call_weekday, call_hour, COUNT(*) AS total_calls
  FROM ANALYTICS_DB.MARTS.FCT_CALLS GROUP BY 1, 2;

  RETURN 'SP_BUILD_MARTS done';
END;
$$;

-- ✅ VERIFY 8  (run both once by hand)
CALL ANALYTICS_DB.OPS.SP_MERGE_STAGING();
CALL ANALYTICS_DB.OPS.SP_BUILD_MARTS();
SELECT COUNT(*) AS staging_calls FROM ANALYTICS_DB.STAGING.CALLS;
SELECT * FROM ANALYTICS_DB.MARTS.AGG_DAILY_KPI ORDER BY call_date DESC LIMIT 7;


/* =============================================================================
   9. TASKS WITH CRON EVERY MINUTE
   -----------------------------------------------------------------------------
   TSK_MERGE_STAGING  (root)  CRON '* * * * *'  -> runs every minute
        WHEN any stream has data  -> if nothing new, the run is skipped and
                                     NO warehouse starts (no compute cost)
        │
        ▼
   TSK_BUILD_MARTS    (child) AFTER TSK_MERGE_STAGING

   CRON format: minute hour day-of-month month day-of-week time-zone
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE SCHEMA ANALYTICS_DB.OPS;

ALTER TASK IF EXISTS TSK_MERGE_STAGING SUSPEND;   -- a graph must be suspended to change it

CREATE OR REPLACE TASK TSK_MERGE_STAGING
  WAREHOUSE = LOAD_WH
  SCHEDULE = 'USING CRON * * * * * Asia/Kolkata'          -- every minute
  USER_TASK_TIMEOUT_MS = 600000                           -- 10 min safety timeout
  SUSPEND_TASK_AFTER_NUM_FAILURES = 10
  COMMENT = 'Every minute: merge new RAW rows into STAGING'
WHEN SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.CUSTOMERS_STRM')
  OR SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.AGENTS_STRM')
  OR SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.CALLS_STRM')
  OR SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON_STRM')
  OR SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.CALL_EVENTS_JSON_STRM')
AS
  CALL ANALYTICS_DB.OPS.SP_MERGE_STAGING();

CREATE OR REPLACE TASK TSK_BUILD_MARTS
  WAREHOUSE = LOAD_WH
  COMMENT = 'Rebuild Power BI tables after each merge'
  AFTER TSK_MERGE_STAGING
AS
  CALL ANALYTICS_DB.OPS.SP_BUILD_MARTS();

-- Resume the root AND all children in one go
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');

-- ✅ VERIFY 9
SHOW TASKS IN SCHEMA ANALYTICS_DB.OPS;     -- state = started; schedule on the root
-- Wait 1-2 minutes, then:
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD(minute, -15, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;
-- state = SKIPPED   -> ran on schedule, no new data (normal, free)
-- state = SUCCEEDED -> merged new data
-- state = FAILED    -> read error_message

/* Other CRON examples
   'USING CRON */5 * * * * Asia/Kolkata'      every 5 minutes
   'USING CRON 0 * * * * Asia/Kolkata'        every hour
   'USING CRON 0 9-18 * * 1-5 Asia/Kolkata'   hourly, 9 AM-6 PM, Mon-Fri
   'USING CRON 30 7 * * * Asia/Kolkata'       daily 7:30 AM */


/* =============================================================================
   10. MONITORING VIEWS + EMAIL ALERT
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE SCHEMA ANALYTICS_DB.OPS;

-- Live per-file load status (last 24 h)
CREATE OR REPLACE VIEW VW_FILE_LOAD_STATUS AS
SELECT 'CUSTOMERS' AS tbl, file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ANALYTICS_DB.RAW.CUSTOMERS', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())))
UNION ALL
SELECT 'AGENTS', file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ANALYTICS_DB.RAW.AGENTS', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())))
UNION ALL
SELECT 'CALLS', file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ANALYTICS_DB.RAW.CALLS', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())))
UNION ALL
SELECT 'CALL_FEEDBACK_JSON', file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())))
UNION ALL
SELECT 'CALL_EVENTS_JSON', file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ANALYTICS_DB.RAW.CALL_EVENTS_JSON', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())))
UNION ALL
SELECT 'EXPORT_MANIFESTS', file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ANALYTICS_DB.RAW.EXPORT_MANIFESTS', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())));
-- Quick self-test of the function before relying on the view:
--   SELECT * FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.COPY_HISTORY(
--     TABLE_NAME => 'ANALYTICS_DB.RAW.CALLS', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())));
--   If your account rejects the 3-part name, run it with USE SCHEMA ANALYTICS_DB.RAW and TABLE_NAME => 'CALLS'.

-- Manifest row count vs rows actually loaded (only if your export writes manifests)
CREATE OR REPLACE VIEW VW_RECONCILIATION AS
WITH m AS (
  SELECT payload:table::STRING AS table_name, payload:file::STRING AS file_key,
         payload:row_count::NUMBER AS expected_rows, _loaded_at
  FROM ANALYTICS_DB.RAW.EXPORT_MANIFESTS),
l AS (
  SELECT _file_name, COUNT(*) AS loaded_rows FROM ANALYTICS_DB.RAW.CUSTOMERS GROUP BY 1
  UNION ALL SELECT _file_name, COUNT(*) FROM ANALYTICS_DB.RAW.AGENTS GROUP BY 1
  UNION ALL SELECT _file_name, COUNT(*) FROM ANALYTICS_DB.RAW.CALLS GROUP BY 1
  UNION ALL SELECT _file_name, COUNT(*) FROM ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON GROUP BY 1
  UNION ALL SELECT _file_name, COUNT(*) FROM ANALYTICS_DB.RAW.CALL_EVENTS_JSON GROUP BY 1)
SELECT m.table_name, m.file_key, m.expected_rows, COALESCE(l.loaded_rows, 0) AS loaded_rows,
       IFF(m.expected_rows = COALESCE(l.loaded_rows, 0), 'OK', 'MISMATCH') AS status, m._loaded_at
FROM m LEFT JOIN l ON ENDSWITH(m.file_key, '/' || l._file_name);

-- Files that did not load (bad rows -> whole file skipped)
CREATE OR REPLACE VIEW VW_FAILED_FILES AS
SELECT tbl AS table_name, file_name, status, row_count, error_count, first_error_message, last_load_time
FROM ANALYTICS_DB.OPS.VW_FILE_LOAD_STATUS
WHERE status <> 'Loaded' OR COALESCE(error_count, 0) > 0;

-- Snowpipe health for every pipe (executionState should be RUNNING)
CREATE OR REPLACE VIEW VW_PIPE_STATUS AS
SELECT pipe_name,
       details:executionState::STRING               AS status,
       details:pendingFileCount::NUMBER             AS pending_files,
       details:lastReceivedMessageTimestamp::STRING AS last_s3_event,
       details:error::STRING                        AS last_error
FROM (
  SELECT 'PIPE_CUSTOMERS'     AS pipe_name, PARSE_JSON(SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CUSTOMERS'))     AS details UNION ALL
  SELECT 'PIPE_AGENTS',                     PARSE_JSON(SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_AGENTS'))                UNION ALL
  SELECT 'PIPE_CALLS',                      PARSE_JSON(SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CALLS'))                 UNION ALL
  SELECT 'PIPE_CALL_FEEDBACK',              PARSE_JSON(SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CALL_FEEDBACK'))         UNION ALL
  SELECT 'PIPE_CALL_EVENTS',                PARSE_JSON(SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_CALL_EVENTS'))           UNION ALL
  SELECT 'PIPE_MANIFESTS',                  PARSE_JSON(SYSTEM$PIPE_STATUS('ANALYTICS_DB.RAW.PIPE_MANIFESTS'))
);

-- Is STAGING keeping up with RAW? Per dataset: rows loaded AFTER the last successful merge
-- and the age of the OLDEST of them. 0 = nothing waiting.
CREATE OR REPLACE VIEW VW_PIPELINE_LAG AS
WITH last_merge AS (
  SELECT COALESCE(MAX(query_start_time), '1970-01-01'::TIMESTAMP_LTZ) AS t
  FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
         TASK_NAME => 'TSK_MERGE_STAGING',
         SCHEDULED_TIME_RANGE_START => DATEADD(day, -7, CURRENT_TIMESTAMP())))
  WHERE state = 'SUCCEEDED'
),
pending AS (
  SELECT 'CUSTOMERS' AS dataset, _loaded_at FROM ANALYTICS_DB.RAW.CUSTOMERS          WHERE _loaded_at > (SELECT t FROM last_merge)
  UNION ALL SELECT 'AGENTS',        _loaded_at FROM ANALYTICS_DB.RAW.AGENTS             WHERE _loaded_at > (SELECT t FROM last_merge)
  UNION ALL SELECT 'CALLS',         _loaded_at FROM ANALYTICS_DB.RAW.CALLS              WHERE _loaded_at > (SELECT t FROM last_merge)
  UNION ALL SELECT 'CALL_FEEDBACK', _loaded_at FROM ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON WHERE _loaded_at > (SELECT t FROM last_merge)
  UNION ALL SELECT 'CALL_EVENTS',   _loaded_at FROM ANALYTICS_DB.RAW.CALL_EVENTS_JSON   WHERE _loaded_at > (SELECT t FROM last_merge)
),
datasets AS (
  SELECT column1 AS dataset FROM VALUES ('CUSTOMERS'), ('AGENTS'), ('CALLS'), ('CALL_FEEDBACK'), ('CALL_EVENTS')
)
SELECT d.dataset,
       COUNT(p._loaded_at)                                                     AS pending_rows,
       COALESCE(DATEDIFF(minute, MIN(p._loaded_at), CURRENT_TIMESTAMP()), 0)  AS lag_minutes,
       (SELECT t FROM last_merge)                                              AS last_successful_merge
FROM datasets d
LEFT JOIN pending p ON p.dataset = d.dataset
GROUP BY d.dataset;
-- Note: a manual CALL SP_MERGE_STAGING() isn't a task run, so lag may show rows until the
-- next scheduled run. Exact pending rows (does not consume the stream):
--   SELECT COUNT(*), MIN(_loaded_at) FROM ANALYTICS_DB.RAW.CALLS_STRM;

-- Rows that the merge skips because their business key is missing/invalid (quarantine list).
-- They stay in RAW: fix the source, re-export, and the next merge picks them up.
CREATE OR REPLACE VIEW VW_REJECTED_ROWS AS
SELECT 'CUSTOMERS' AS dataset, _file_name, _file_row AS row_in_file, 'customer_id is NULL' AS reason, _loaded_at
FROM ANALYTICS_DB.RAW.CUSTOMERS WHERE customer_id IS NULL
UNION ALL
SELECT 'AGENTS', _file_name, _file_row, 'agent_id is NULL', _loaded_at
FROM ANALYTICS_DB.RAW.AGENTS WHERE agent_id IS NULL
UNION ALL
SELECT 'CALLS', _file_name, _file_row, 'call_id is NULL', _loaded_at
FROM ANALYTICS_DB.RAW.CALLS WHERE call_id IS NULL
UNION ALL
SELECT 'CALL_FEEDBACK', _file_name, NULL, 'feedback_id missing or not a number', _loaded_at
FROM ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON WHERE TRY_TO_NUMBER(payload:feedback_id::STRING) IS NULL
UNION ALL
SELECT 'CALL_FEEDBACK', _file_name, NULL, 'updated_at missing or not a timestamp', _loaded_at
FROM ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON
WHERE TRY_TO_NUMBER(payload:feedback_id::STRING) IS NOT NULL
  AND TRY_TO_TIMESTAMP_TZ(payload:updated_at::STRING) IS NULL
UNION ALL
SELECT 'CALL_EVENTS', _file_name, NULL, 'event_id missing or not a number', _loaded_at
FROM ANALYTICS_DB.RAW.CALL_EVENTS_JSON WHERE TRY_TO_NUMBER(payload:event_id::STRING) IS NULL;

-- Email alert every 15 minutes if anything is wrong
USE ROLE ACCOUNTADMIN;
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS ANALYTICS_EMAIL_INT
  TYPE = EMAIL ENABLED = TRUE ALLOWED_RECIPIENTS = ('<ALERT_EMAIL>');
GRANT USAGE ON INTEGRATION ANALYTICS_EMAIL_INT TO ROLE ANALYTICS_ENGINEER;

USE ROLE ANALYTICS_ENGINEER;
CREATE OR REPLACE ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE
  WAREHOUSE = LOAD_WH
  SCHEDULE = 'USING CRON */15 * * * * Asia/Kolkata'
  IF (EXISTS (
        SELECT 1 FROM ANALYTICS_DB.OPS.VW_FAILED_FILES
        WHERE last_load_time > DATEADD(minute, -15, CURRENT_TIMESTAMP())
        UNION ALL
        SELECT 1 FROM ANALYTICS_DB.OPS.VW_PIPE_STATUS
        WHERE COALESCE(status, 'UNKNOWN') <> 'RUNNING' OR COALESCE(pending_files, 0) > 100
        UNION ALL
        SELECT 1 FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                 SCHEDULED_TIME_RANGE_START => DATEADD(minute, -15, CURRENT_TIMESTAMP())))
        WHERE state = 'FAILED'
        UNION ALL
        SELECT 1 FROM ANALYTICS_DB.OPS.VW_PIPELINE_LAG WHERE lag_minutes > 10
        UNION ALL
        SELECT 1 FROM ANALYTICS_DB.OPS.VW_REJECTED_ROWS
        WHERE _loaded_at > DATEADD(minute, -15, CURRENT_TIMESTAMP())))
  THEN CALL SYSTEM$SEND_EMAIL('ANALYTICS_EMAIL_INT', '<ALERT_EMAIL>',
         'Snowflake pipeline needs attention',
         'A file failed to load, a pipe is not RUNNING / backlogged, a task failed, data waited > 10 min '
         || 'to be merged, or rows were rejected for missing keys. Check ANALYTICS_DB.OPS.VW_FAILED_FILES, '
         || 'VW_PIPE_STATUS, VW_PIPELINE_LAG, VW_REJECTED_ROWS and TASK_HISTORY.');
-- Note: the alert re-sends every 15 minutes while a problem persists. Suspend it during a known
-- incident (ALTER ALERT ... SUSPEND) and resume after the fix.
ALTER ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE RESUME;

-- (Cost guardrail RM_ANALYTICS is created in section 1.)

-- ✅ VERIFY 10
SHOW ALERTS IN SCHEMA ANALYTICS_DB.OPS;     -- state = started
SELECT * FROM ANALYTICS_DB.OPS.VW_PIPE_STATUS;    -- every pipe RUNNING
SELECT * FROM ANALYTICS_DB.OPS.VW_FAILED_FILES;   -- expected: no rows
CALL SYSTEM$SEND_EMAIL('ANALYTICS_EMAIL_INT', '<ALERT_EMAIL>', 'Snowflake test', 'Email integration works');


/* =============================================================================
   11. POWER BI READ-ONLY ROLE
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
GRANT USAGE  ON DATABASE ANALYTICS_DB                       TO ROLE POWERBI_READER;
GRANT USAGE  ON SCHEMA   ANALYTICS_DB.MARTS                 TO ROLE POWERBI_READER;
GRANT SELECT ON ALL TABLES    IN SCHEMA ANALYTICS_DB.MARTS  TO ROLE POWERBI_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA ANALYTICS_DB.MARTS  TO ROLE POWERBI_READER;

/* Service user for Power BI (key-pair, no password). Generate the key first:
     openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out pbi_key.p8 -nocrypt
     openssl rsa -in pbi_key.p8 -pubout -out pbi_key.pub
   then paste the public key body (without BEGIN/END lines) below and run:

USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS SVC_POWERBI TYPE = SERVICE
  DEFAULT_ROLE = POWERBI_READER DEFAULT_WAREHOUSE = BI_WH
  RSA_PUBLIC_KEY = '<PUBLIC_KEY_BODY>';
USE ROLE SECURITYADMIN;
GRANT ROLE POWERBI_READER TO USER SVC_POWERBI;
*/

-- ✅ VERIFY 11  — what Power BI will see (RAW must NOT be readable)
SHOW GRANTS TO ROLE POWERBI_READER;   -- only USAGE on ANALYTICS_DB + MARTS, SELECT on MARTS, USAGE on BI_WH
USE ROLE POWERBI_READER;
USE WAREHOUSE BI_WH;
SHOW TABLES IN SCHEMA ANALYTICS_DB.MARTS;
SELECT COUNT(*) FROM ANALYTICS_DB.MARTS.FCT_CALLS;
-- SELECT COUNT(*) FROM ANALYTICS_DB.RAW.CALLS;   -- expected: insufficient privileges


/* =============================================================================
   12. END-TO-END VERIFICATION  (run any time; every row should look healthy)
   ============================================================================= */
USE ROLE ANALYTICS_ENGINEER;
USE WAREHOUSE LOAD_WH;

-- 12.1 Assume role works?
LIST @ANALYTICS_DB.RAW.STG_CSV;

-- 12.2 Snowpipe running and receiving S3 events?
--      status = RUNNING, last_s3_event is recent, pending_files ~ 0
SELECT * FROM ANALYTICS_DB.OPS.VW_PIPE_STATUS;

-- 12.3 Every file loaded? (status should be 'Loaded')
SELECT tbl, status, COUNT(*) AS files, SUM(row_count) AS rows_loaded, MAX(last_load_time) AS latest
FROM ANALYTICS_DB.OPS.VW_FILE_LOAD_STATUS GROUP BY 1, 2 ORDER BY 1;

SELECT * FROM ANALYTICS_DB.OPS.VW_FILE_LOAD_STATUS WHERE status <> 'Loaded';   -- expected: no rows

-- 12.4 Row counts per layer
SELECT 'RAW.CALLS'           AS layer, COUNT(*) AS n FROM ANALYTICS_DB.RAW.CALLS UNION ALL
SELECT 'STAGING.CALLS',                COUNT(*)      FROM ANALYTICS_DB.STAGING.CALLS UNION ALL
SELECT 'MARTS.FCT_CALLS',              COUNT(*)      FROM ANALYTICS_DB.MARTS.FCT_CALLS UNION ALL
SELECT 'STAGING.CALL_FEEDBACK',        COUNT(*)      FROM ANALYTICS_DB.STAGING.CALL_FEEDBACK UNION ALL
SELECT 'STAGING.CALL_EVENTS',          COUNT(*)      FROM ANALYTICS_DB.STAGING.CALL_EVENTS;
-- RAW can be >= STAGING (re-exports/duplicates); STAGING.CALLS must = MARTS.FCT_CALLS

-- 12.5 No duplicate keys in STAGING (expected: no rows)
SELECT 'CUSTOMERS' AS tbl, customer_id::STRING AS key_value, COUNT(*) AS n FROM ANALYTICS_DB.STAGING.CUSTOMERS GROUP BY 1, 2 HAVING COUNT(*) > 1
UNION ALL SELECT 'AGENTS',        agent_id::STRING,    COUNT(*) FROM ANALYTICS_DB.STAGING.AGENTS        GROUP BY 1, 2 HAVING COUNT(*) > 1
UNION ALL SELECT 'CALLS',         call_id,             COUNT(*) FROM ANALYTICS_DB.STAGING.CALLS         GROUP BY 1, 2 HAVING COUNT(*) > 1
UNION ALL SELECT 'CALL_FEEDBACK', feedback_id::STRING, COUNT(*) FROM ANALYTICS_DB.STAGING.CALL_FEEDBACK GROUP BY 1, 2 HAVING COUNT(*) > 1
UNION ALL SELECT 'CALL_EVENTS',   event_id::STRING,    COUNT(*) FROM ANALYTICS_DB.STAGING.CALL_EVENTS   GROUP BY 1, 2 HAVING COUNT(*) > 1;

-- 12.5b Rows rejected for missing/invalid keys (expected: no rows)
SELECT * FROM ANALYTICS_DB.OPS.VW_REJECTED_ROWS;

-- 12.6 Streams consumed? (FALSE = everything merged)
SELECT SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.CALLS_STRM')              AS calls_pending,
       SYSTEM$STREAM_HAS_DATA('ANALYTICS_DB.RAW.CALL_FEEDBACK_JSON_STRM') AS feedback_pending;

-- 12.7 Tasks running every minute? (SKIPPED / SUCCEEDED, no FAILED)
SELECT name, state, COUNT(*) AS runs, MAX(scheduled_time) AS last_run
FROM TABLE(ANALYTICS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD(hour, -1, CURRENT_TIMESTAMP())))
GROUP BY 1, 2 ORDER BY 1, 2;

-- 12.8 Freshness: how far behind is STAGING?
SELECT * FROM ANALYTICS_DB.OPS.VW_PIPELINE_LAG;                    -- lag_minutes ~ 0-2 for every dataset

-- 12.9 Reconciliation (if manifests are exported): all OK
SELECT status, COUNT(*) FROM ANALYTICS_DB.OPS.VW_RECONCILIATION GROUP BY 1;

-- 12.10 The numbers Power BI will show
SELECT * FROM ANALYTICS_DB.MARTS.AGG_DAILY_KPI ORDER BY call_date DESC LIMIT 7;
SELECT * FROM ANALYTICS_DB.MARTS.AGG_AGENT_PERFORMANCE ORDER BY total_calls DESC LIMIT 10;


/* =============================================================================
   13. TEST WITHOUT THE LAMBDA: upload sample files by hand
-----------------------------------------------------------------------------
Run in a terminal with the AWS CLI (lines below have no indentation on purpose,
so the CSV/JSON content is copied exactly). Each upload uses a NEW file name
(timestamp): Snowpipe never reloads a file name it has already loaded.

TS=$(date -u +%Y%m%dT%H%M%SZ); DT=$(date -u +%F); B=<BUCKET>

cat > customers.csv <<'EOF'
customer_id,customer_name,plan,region,created_at,updated_at
1,"Customer 1","pro","North","2026-10-26T09:00:00+00:00","2026-10-26T09:00:00+00:00"
2,"Customer 2","basic","South","2026-10-26T09:00:00+00:00","2026-10-26T09:00:00+00:00"
EOF

cat > agents.csv <<'EOF'
agent_id,agent_name,team,email,created_at,updated_at
10,"Agent A","Support","a@example.com","2026-10-26T09:00:00+00:00","2026-10-26T09:00:00+00:00"
EOF

cat > calls.csv <<'EOF'
call_id,customer_id,agent_id,channel,status,started_at,ended_at,duration_sec,recording_url,created_at,updated_at
"c-001",1,10,"video","completed","2026-10-26T09:10:00+00:00","2026-10-26T09:25:00+00:00",900,"s3://rec/c-001.mp4","2026-10-26T09:25:00+00:00","2026-10-26T09:25:00+00:00"
"c-002",2,10,"audio","dropped","2026-10-26T09:30:00+00:00","2026-10-26T09:32:00+00:00",120,,"2026-10-26T09:32:00+00:00","2026-10-26T09:32:00+00:00"
EOF

cat > call_feedback.json <<'EOF'
{"feedback_id":1,"call_id":"c-001","rating":5,"comment":"Great help","tags":["resolved"],"created_at":"2026-10-26T09:30:00+00:00","updated_at":"2026-10-26T09:30:00+00:00"}
{"feedback_id":2,"call_id":"c-002","rating":1,"comment":"Call dropped","tags":["dropped"],"created_at":"2026-10-26T09:40:00+00:00","updated_at":"2026-10-26T09:40:00+00:00"}
EOF

cat > call_events.json <<'EOF'
{"event_id":100,"call_id":"c-002","event_type":"network_drop","payload":{"device":"web","network":"4g","latency_ms":350},"created_at":"2026-10-26T09:31:00+00:00"}
EOF

gzip -f customers.csv agents.csv calls.csv call_feedback.json call_events.json
aws s3 cp customers.csv.gz     s3://$B/exports/csv/appdb/customers/dt=$DT/customers_$TS.csv.gz
aws s3 cp agents.csv.gz        s3://$B/exports/csv/appdb/agents/dt=$DT/agents_$TS.csv.gz
aws s3 cp calls.csv.gz         s3://$B/exports/csv/appdb/calls/dt=$DT/calls_$TS.csv.gz
aws s3 cp call_feedback.json.gz s3://$B/exports/json/appdb/call_feedback/dt=$DT/call_feedback_$TS.json.gz
aws s3 cp call_events.json.gz  s3://$B/exports/json/appdb/call_events/dt=$DT/call_events_$TS.json.gz

Then wait ~2 minutes (Snowpipe ~1 min + task every minute) and run section 12.

TEST AN UPDATE: change customer 2's plan to "enterprise" and a later updated_at,
upload as a NEW file name, wait 2 minutes:
  SELECT customer_id, plan FROM ANALYTICS_DB.STAGING.CUSTOMERS WHERE customer_id = 2;   -> enterprise

TEST AN OLDER (OUT-OF-ORDER) UPDATE: upload, as yet another NEW file name, customer 2 with
plan "basic" and an updated_at EARLIER than the enterprise row. Wait 2 minutes:
  SELECT customer_id, plan FROM ANALYTICS_DB.STAGING.CUSTOMERS WHERE customer_id = 2;   -> still enterprise

TEST A MISSING JSON KEY: upload call_feedback with a line that has no "feedback_id":
  {"call_id":"c-001","rating":3,"comment":"no key","updated_at":"2026-10-26T10:00:00+00:00"}
  SELECT * FROM ANALYTICS_DB.OPS.VW_REJECTED_ROWS;        -> 1 row, CALL_FEEDBACK
  (the other feedback rows in the same file are still merged)

TEST A BAD FILE: upload a calls CSV where duration_sec = "abc".
  SELECT * FROM ANALYTICS_DB.OPS.VW_FILE_LOAD_STATUS WHERE status <> 'Loaded';  -> 1 row, file skipped
------------------------------------------------------------------------------ */

-- Expected after the sample upload:
SELECT * FROM ANALYTICS_DB.MARTS.FCT_CALLS WHERE call_id IN ('c-001', 'c-002');
--   c-001  completed  15.00 min  rating 5  network_drops 0
--   c-002  dropped     2.00 min  rating 1  network_drops 1


/* =============================================================================
   14. PAUSE / RESUME / CLEANUP
   ============================================================================= */
/*
-- Pause everything
USE ROLE ANALYTICS_ENGINEER;
ALTER TASK  ANALYTICS_DB.OPS.TSK_MERGE_STAGING SUSPEND;
ALTER ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE SUSPEND;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_CALLS SET PIPE_EXECUTION_PAUSED = TRUE;   -- repeat per pipe

-- Resume
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_DB.OPS.TSK_MERGE_STAGING');
ALTER ALERT ANALYTICS_DB.OPS.ALRT_PIPELINE RESUME;
ALTER PIPE  ANALYTICS_DB.RAW.PIPE_CALLS SET PIPE_EXECUTION_PAUSED = FALSE;

-- Remove everything
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS ANALYTICS_DB;            -- tables, stages, pipes, streams, tasks, alert
DROP WAREHOUSE IF EXISTS LOAD_WH;
DROP WAREHOUSE IF EXISTS BI_WH;
DROP INTEGRATION IF EXISTS S3_EXPORTS_INT;
DROP INTEGRATION IF EXISTS ANALYTICS_EMAIL_INT;
DROP RESOURCE MONITOR IF EXISTS RM_ANALYTICS;
DROP USER IF EXISTS SVC_POWERBI;
DROP ROLE IF EXISTS POWERBI_READER;
DROP ROLE IF EXISTS ANALYTICS_ENGINEER;
-- AWS: remove the S3 event notification rule and the IAM role trust.
*/
