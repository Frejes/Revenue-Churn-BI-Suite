-- ============================================================
-- Revenue & Churn BI Suite — Star Schema DDL
-- Database: PostgreSQL 15+ (compatible with Redshift/Snowflake with minor tweaks)
-- Security: All tables owned by bi_owner role; bi_readonly granted SELECT only
-- PII Note: customer_id is a SHA-256 hash prefix — no real PII stored anywhere
-- ============================================================

-- ── Schemas ──────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS bi_core;       -- fact & dimension tables
CREATE SCHEMA IF NOT EXISTS bi_mart;       -- pre-aggregated mart views
CREATE SCHEMA IF NOT EXISTS bi_audit;      -- audit & refresh log tables

-- ── Roles ────────────────────────────────────────────────────
-- Run as superuser / DBA once during setup
-- See 03_rbac_security.sql for full RBAC implementation

-- ============================================================
-- DIMENSION TABLES
-- ============================================================

-- dim_date: Calendar dimension for time intelligence
CREATE TABLE IF NOT EXISTS bi_core.dim_date (
    date_key        DATE         PRIMARY KEY,
    year            SMALLINT     NOT NULL,
    quarter         SMALLINT     NOT NULL,  -- 1–4
    month_num       SMALLINT     NOT NULL,  -- 1–12
    month_name      VARCHAR(12)  NOT NULL,
    week_num        SMALLINT     NOT NULL,
    day_of_week     SMALLINT     NOT NULL,
    is_month_start  BOOLEAN      NOT NULL DEFAULT FALSE,
    fiscal_year     SMALLINT     NOT NULL,  -- Assumes Jan fiscal year start; adjust as needed
    fiscal_quarter  SMALLINT     NOT NULL
);
COMMENT ON TABLE bi_core.dim_date IS 'Calendar dimension. Populate via generate_dim_date() procedure.';

-- dim_customer: One row per anonymized customer (NO PII)
CREATE TABLE IF NOT EXISTS bi_core.dim_customer (
    customer_key    SERIAL       PRIMARY KEY,
    customer_id     CHAR(17)     NOT NULL UNIQUE,  -- "CUST_" + 12-char SHA-256 prefix
    cohort_month    DATE         NOT NULL,
    region          VARCHAR(30)  NOT NULL,
    plan_type       VARCHAR(30)  NOT NULL,
    channel         VARCHAR(30)  NOT NULL,
    segment         VARCHAR(20)  NOT NULL,          -- SMB | Mid-Market | Enterprise
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_dim_customer_region   ON bi_core.dim_customer(region);
CREATE INDEX IF NOT EXISTS idx_dim_customer_segment  ON bi_core.dim_customer(segment);
COMMENT ON TABLE bi_core.dim_customer IS
    'Anonymized customer dimension. customer_id is a SHA-256 hash — no PII. '
    'Cohort month is the first active month.';

-- dim_plan: Plan reference
CREATE TABLE IF NOT EXISTS bi_core.dim_plan (
    plan_key        SERIAL      PRIMARY KEY,
    plan_name       VARCHAR(30) NOT NULL UNIQUE,
    tier_rank       SMALLINT    NOT NULL,   -- 1=Starter … 4=Enterprise Plus
    base_price_usd  NUMERIC(10,2)
);
INSERT INTO bi_core.dim_plan (plan_name, tier_rank, base_price_usd) VALUES
    ('Starter',          1,   299.00),
    ('Growth',           2,  1299.00),
    ('Enterprise',       3,  4999.00),
    ('Enterprise Plus',  4, 14999.00)
ON CONFLICT DO NOTHING;

-- dim_region: Region reference (used for Row-Level Security partitioning)
CREATE TABLE IF NOT EXISTS bi_core.dim_region (
    region_key   SERIAL      PRIMARY KEY,
    region_name  VARCHAR(30) NOT NULL UNIQUE,
    geo_cluster  VARCHAR(10) NOT NULL   -- AMER | EMEA | APAC | LATAM
);
INSERT INTO bi_core.dim_region (region_name, geo_cluster) VALUES
    ('North America', 'AMER'),
    ('EMEA',          'EMEA'),
    ('APAC',          'APAC'),
    ('LATAM',         'LATAM')
ON CONFLICT DO NOTHING;

-- ============================================================
-- FACT TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS bi_core.fact_subscriptions (
    sub_key             BIGSERIAL    PRIMARY KEY,
    customer_key        INT          NOT NULL REFERENCES bi_core.dim_customer(customer_key),
    date_key            DATE         NOT NULL REFERENCES bi_core.dim_date(date_key),
    plan_key            INT          NOT NULL REFERENCES bi_core.dim_plan(plan_key),

    -- Measures (no PII)
    monthly_revenue     NUMERIC(12,2) NOT NULL,
    churn_flag          SMALLINT     NOT NULL CHECK (churn_flag IN (0,1)),
    active_flag         SMALLINT     NOT NULL CHECK (active_flag IN (0,1)),
    usage_score         NUMERIC(4,3) NOT NULL CHECK (usage_score BETWEEN 0 AND 1),
    support_tickets     SMALLINT     NOT NULL DEFAULT 0,
    failed_payments     SMALLINT     NOT NULL DEFAULT 0,

    -- Derived churn-risk proxy (computed at load time)
    churn_risk_score    NUMERIC(5,2) GENERATED ALWAYS AS (
                            LEAST(100,
                                failed_payments * 30.0 +
                                LEAST(support_tickets, 5) * 10.0 +
                                (1.0 - usage_score) * 40.0
                            )
                        ) STORED,

    -- Partition column for RLS (mirrors dim_customer.region)
    region              VARCHAR(30)  NOT NULL,
    segment             VARCHAR(20)  NOT NULL,

    loaded_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Partitioned by month (optional; use if DB supports it)
-- For PostgreSQL: CREATE TABLE ... PARTITION BY RANGE (date_key);
-- Retained as non-partitioned for portability; add partitioning per environment.

CREATE INDEX IF NOT EXISTS idx_fact_date        ON bi_core.fact_subscriptions(date_key);
CREATE INDEX IF NOT EXISTS idx_fact_customer    ON bi_core.fact_subscriptions(customer_key);
CREATE INDEX IF NOT EXISTS idx_fact_region      ON bi_core.fact_subscriptions(region);
CREATE INDEX IF NOT EXISTS idx_fact_segment     ON bi_core.fact_subscriptions(segment);
CREATE INDEX IF NOT EXISTS idx_fact_churn       ON bi_core.fact_subscriptions(churn_flag);

COMMENT ON TABLE bi_core.fact_subscriptions IS
    'Monthly grain subscription fact. churn_risk_score is a computed proxy. '
    'region/segment are denormalized for RLS filter performance.';

-- ============================================================
-- AUDIT / REFRESH LOG TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS bi_audit.refresh_log (
    log_id          BIGSERIAL    PRIMARY KEY,
    run_ts          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    triggered_by    VARCHAR(50)  NOT NULL,  -- 'scheduler' | 'manual:<username>'
    source_table    VARCHAR(80)  NOT NULL,
    rows_loaded     INT,
    rows_rejected   INT          DEFAULT 0,
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('SUCCESS','FAILED','PARTIAL')),
    error_message   TEXT,
    duration_ms     INT
);
COMMENT ON TABLE bi_audit.refresh_log IS
    'Tracks every ETL/refresh run. Retained for 90 days per data governance policy.';
