-- Run this if 00_setup_all.sql failed partway (tables/indexes already exist)
-- Project: vtlfbpxcequpfkivxzgf

-- Revenue & Churn BI Suite — Mart Views & KPI Transformations
-- All views live in bi_mart schema; bi_readonly can SELECT from bi_mart only
-- ============================================================

-- ── 1. MRR / ARR Summary ─────────────────────────────────────
CREATE OR REPLACE VIEW bi_mart.v_mrr_monthly AS
SELECT
    date_key                                            AS month,
    SUM(monthly_revenue)                                AS mrr,
    SUM(monthly_revenue) * 12                           AS arr,
    COUNT(DISTINCT customer_key)                        AS active_customers,
    SUM(monthly_revenue) / NULLIF(COUNT(DISTINCT customer_key), 0)  AS arpu,

    -- Churn rate = churned customers / total active at start of period
    SUM(churn_flag)::FLOAT / NULLIF(COUNT(*), 0)        AS churn_rate,
    1 - SUM(churn_flag)::FLOAT / NULLIF(COUNT(*), 0)   AS retention_rate,

    -- MoM MRR growth
    SUM(monthly_revenue) - LAG(SUM(monthly_revenue))
        OVER (ORDER BY date_key)                        AS mrr_change,

    -- LTV proxy: ARPU / churn_rate  (naive formula; replace with survival model in production)
    (SUM(monthly_revenue) / NULLIF(COUNT(DISTINCT customer_key), 0))
        / NULLIF(SUM(churn_flag)::FLOAT / NULLIF(COUNT(*), 0), 0)  AS ltv_proxy

FROM bi_core.fact_subscriptions
GROUP BY date_key
ORDER BY date_key;

COMMENT ON VIEW bi_mart.v_mrr_monthly IS
    'Monthly MRR, ARR, ARPU, churn rate, retention rate, LTV proxy. '
    'LTV proxy = ARPU / churn_rate (monthly). '
    'Filter: active_flag = 1 not applied here — fact table already excludes post-churn rows.';

-- ── 2. Revenue Drilldown ─────────────────────────────────────
CREATE OR REPLACE VIEW bi_mart.v_revenue_drilldown AS
SELECT
    f.date_key          AS month,
    f.region,
    f.segment,
    p.plan_name,
    c.channel,
    SUM(f.monthly_revenue)                              AS mrr,
    COUNT(DISTINCT f.customer_key)                      AS active_customers,
    SUM(f.churn_flag)                                   AS churned_customers,
    SUM(f.monthly_revenue) / NULLIF(COUNT(DISTINCT f.customer_key), 0) AS arpu,
    SUM(f.churn_flag)::FLOAT / NULLIF(COUNT(*), 0)     AS churn_rate,
    AVG(f.usage_score)                                  AS avg_usage_score,
    SUM(f.support_tickets)                              AS total_support_tickets,
    SUM(f.failed_payments)                              AS total_failed_payments
FROM bi_core.fact_subscriptions f
JOIN bi_core.dim_plan      p ON p.plan_key = f.plan_key
JOIN bi_core.dim_customer  c ON c.customer_key = f.customer_key
GROUP BY f.date_key, f.region, f.segment, p.plan_name, c.channel;

-- ── 3. Cohort Retention Heatmap ──────────────────────────────
CREATE OR REPLACE VIEW bi_mart.v_cohort_retention AS
WITH cohorts AS (
    SELECT
        customer_key,
        MIN(date_key) AS cohort_month
    FROM bi_core.fact_subscriptions
    GROUP BY customer_key
),
periods AS (
    SELECT
        f.customer_key,
        c.cohort_month,
        f.date_key AS activity_month,
        -- Months since cohort acquisition (0 = acquisition month)
        EXTRACT(YEAR FROM AGE(f.date_key, c.cohort_month)) * 12 +
        EXTRACT(MONTH FROM AGE(f.date_key, c.cohort_month)) AS period_num
    FROM bi_core.fact_subscriptions f
    JOIN cohorts c ON c.customer_key = f.customer_key
    WHERE f.churn_flag = 0
)
SELECT
    cohort_month,
    period_num,
    COUNT(DISTINCT customer_key)                        AS retained_customers,
    -- cohort_size joined via subquery below
    FIRST_VALUE(COUNT(DISTINCT customer_key))
        OVER (PARTITION BY cohort_month ORDER BY period_num) AS cohort_size,
    COUNT(DISTINCT customer_key)::FLOAT /
        FIRST_VALUE(COUNT(DISTINCT customer_key))
        OVER (PARTITION BY cohort_month ORDER BY period_num) AS retention_rate
FROM periods
GROUP BY cohort_month, period_num
ORDER BY cohort_month, period_num;

-- ── 4. Accounts at Risk ──────────────────────────────────────
CREATE OR REPLACE VIEW bi_mart.v_accounts_at_risk AS
SELECT
    c.customer_id,          -- anonymized hash, NOT real identity
    c.region,
    c.segment,
    p.plan_name,
    c.channel,
    f.date_key              AS last_active_month,
    f.churn_risk_score,
    f.usage_score,
    f.support_tickets,
    f.failed_payments,
    CASE
        WHEN f.churn_risk_score >= 70 THEN 'HIGH'
        WHEN f.churn_risk_score >= 40 THEN 'MEDIUM'
        ELSE 'LOW'
    END                     AS risk_tier,
    f.monthly_revenue
FROM bi_core.fact_subscriptions f
JOIN bi_core.dim_customer c ON c.customer_key = f.customer_key
JOIN bi_core.dim_plan     p ON p.plan_key     = f.plan_key
WHERE f.date_key = (SELECT MAX(date_key) FROM bi_core.fact_subscriptions)
  AND f.churn_flag = 0   -- only currently active
ORDER BY f.churn_risk_score DESC;

-- ── 5. Alert View: Churn Spike & Revenue Drop ────────────────
CREATE OR REPLACE VIEW bi_mart.v_alerts AS
WITH monthly AS (
    SELECT
        date_key,
        region,
        SUM(monthly_revenue)                                AS mrr,
        SUM(churn_flag)::FLOAT / NULLIF(COUNT(*), 0)       AS churn_rate,
        LAG(SUM(monthly_revenue))
            OVER (PARTITION BY region ORDER BY date_key)    AS prev_mrr,
        LAG(SUM(churn_flag)::FLOAT / NULLIF(COUNT(*), 0))
            OVER (PARTITION BY region ORDER BY date_key)    AS prev_churn_rate
    FROM bi_core.fact_subscriptions
    GROUP BY date_key, region
)
SELECT
    date_key,
    region,
    mrr,
    churn_rate,
    prev_mrr,
    prev_churn_rate,
    ROUND(((mrr - prev_mrr) / NULLIF(prev_mrr, 0)) * 100, 2)               AS mrr_change_pct,
    ROUND((((churn_rate - prev_churn_rate) / NULLIF(prev_churn_rate,0))*100)::numeric, 2) AS churn_change_pct,
    -- Thresholds — configurable via bi_audit.alert_thresholds table (see 04_alerts.sql)
    CASE WHEN churn_rate > 0.08 THEN TRUE ELSE FALSE END                    AS churn_spike_flag,
    CASE WHEN ((mrr - prev_mrr) / NULLIF(prev_mrr, 0)) < -0.05 THEN TRUE ELSE FALSE END
                                                                            AS revenue_drop_flag
FROM monthly
WHERE prev_mrr IS NOT NULL
ORDER BY date_key DESC, region;

CREATE OR REPLACE VIEW bi_mart.v_revenue_mix AS
SELECT
    f.date_key    AS month,
    f.segment,
    p.plan_name   AS plan_type,
    f.region,
    SUM(f.monthly_revenue)    AS mrr,
    COUNT(DISTINCT f.customer_key) AS customers
FROM bi_core.fact_subscriptions f
JOIN bi_core.dim_plan p ON p.plan_key = f.plan_key
GROUP BY f.date_key, f.segment, p.plan_name, f.region;

-- ── 7. Support & Operational Health ─────────────────────────
CREATE OR REPLACE VIEW bi_mart.v_health_signals AS
SELECT
    date_key                AS month,
    region,
    segment,
    AVG(usage_score)        AS avg_usage_score,
    SUM(support_tickets)    AS total_tickets,
    SUM(failed_payments)    AS total_failed_payments,
    AVG(churn_risk_score)   AS avg_risk_score,
    COUNT(DISTINCT CASE WHEN churn_risk_score >= 70 THEN customer_key END) AS high_risk_count
FROM bi_core.fact_subscriptions
GROUP BY date_key, region, segment;

-- ============================================================
-- Revenue & Churn BI Suite — Configurable Alerts & ETL Load
-- ============================================================

-- ── Alert Threshold Configuration Table ──────────────────────
CREATE TABLE IF NOT EXISTS bi_audit.alert_thresholds (
    threshold_id        SERIAL      PRIMARY KEY,
    metric_name         VARCHAR(60) NOT NULL UNIQUE,
    warning_threshold   NUMERIC     NOT NULL,
    critical_threshold  NUMERIC     NOT NULL,
    direction           VARCHAR(5)  NOT NULL CHECK (direction IN ('ABOVE','BELOW')),
    enabled             BOOLEAN     NOT NULL DEFAULT TRUE,
    last_updated_by     VARCHAR(60),
    last_updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Default thresholds (Admin can UPDATE these via BI admin panel)
INSERT INTO bi_audit.alert_thresholds (metric_name, warning_threshold, critical_threshold, direction) VALUES
    ('monthly_churn_rate',  0.06,  0.10, 'ABOVE'),  -- warn at 6%, critical at 10%
    ('mrr_drop_pct',       -0.05, -0.10, 'BELOW'),  -- warn at -5%, critical at -10%
    ('avg_risk_score',      50.0,  70.0, 'ABOVE'),  -- warn at 50, critical at 70
    ('failed_payment_rate', 0.08,  0.15, 'ABOVE')
ON CONFLICT (metric_name) DO NOTHING;

-- ── Alert Evaluation View ─────────────────────────────────────
CREATE OR REPLACE VIEW bi_mart.v_active_alerts AS
WITH latest_metrics AS (
    SELECT
        date_key,
        region,
        mrr,
        churn_rate,
        mrr_change_pct,
        churn_change_pct,
        churn_spike_flag,
        revenue_drop_flag
    FROM bi_mart.v_alerts
    WHERE date_key = (SELECT MAX(date_key) FROM bi_mart.v_alerts)
),
thresholds AS (
    SELECT metric_name, warning_threshold, critical_threshold, direction
    FROM bi_audit.alert_thresholds
    WHERE enabled = TRUE
)
SELECT
    m.date_key,
    m.region,
    'CHURN_SPIKE' AS alert_type,
    m.churn_rate  AS metric_value,
    CASE
        WHEN m.churn_rate >= (SELECT critical_threshold FROM thresholds WHERE metric_name='monthly_churn_rate')
             THEN 'CRITICAL'
        WHEN m.churn_rate >= (SELECT warning_threshold  FROM thresholds WHERE metric_name='monthly_churn_rate')
             THEN 'WARNING'
        ELSE 'OK'
    END AS severity
FROM latest_metrics m
WHERE m.churn_spike_flag = TRUE

UNION ALL

SELECT
    m.date_key,
    m.region,
    'REVENUE_DROP',
    m.mrr_change_pct,
    CASE
        WHEN m.mrr_change_pct <= (SELECT critical_threshold FROM thresholds WHERE metric_name='mrr_drop_pct')
             THEN 'CRITICAL'
        WHEN m.mrr_change_pct <= (SELECT warning_threshold  FROM thresholds WHERE metric_name='mrr_drop_pct')
             THEN 'WARNING'
        ELSE 'OK'
    END
FROM latest_metrics m
WHERE m.revenue_drop_flag = TRUE;

-- ── ETL Load Procedure ────────────────────────────────────────
-- Loads from staging table (populated by your data pipeline / CSV import)
-- Credentials come from environment; this script never stores passwords.

CREATE TABLE IF NOT EXISTS bi_core.stg_subscriptions (LIKE bi_core.fact_subscriptions INCLUDING DEFAULTS);

CREATE OR REPLACE PROCEDURE bi_core.load_fact_subscriptions(p_run_by VARCHAR DEFAULT 'scheduler')
LANGUAGE plpgsql AS $$
DECLARE
    v_start     TIMESTAMPTZ := clock_timestamp();
    v_rows      INT;
    v_rejected  INT := 0;
    v_err       TEXT;
BEGIN
    -- Upsert from staging
    INSERT INTO bi_core.fact_subscriptions (
        customer_key, date_key, plan_key,
        monthly_revenue, churn_flag, active_flag,
        usage_score, support_tickets, failed_payments,
        region, segment
    )
    SELECT
        customer_key, date_key, plan_key,
        monthly_revenue, churn_flag, active_flag,
        usage_score, support_tickets, failed_payments,
        region, segment
    FROM bi_core.stg_subscriptions
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Audit log
    INSERT INTO bi_audit.refresh_log
        (triggered_by, source_table, rows_loaded, rows_rejected, status, duration_ms)
    VALUES
        (p_run_by, 'fact_subscriptions', v_rows, v_rejected, 'SUCCESS',
         EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start)::INT);

    RAISE NOTICE 'Load complete: % rows in %ms', v_rows,
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start)::INT;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    INSERT INTO bi_audit.refresh_log
        (triggered_by, source_table, rows_loaded, rows_rejected, status, error_message, duration_ms)
    VALUES
        (p_run_by, 'fact_subscriptions', 0, 0, 'FAILED', v_err,
         EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start)::INT);
    RAISE;
END;
$$;

-- Schedule: Run via pg_cron (or your orchestrator) daily at 03:00 UTC
-- SELECT cron.schedule('bi-daily-refresh', '0 3 * * *',
--   $$CALL bi_core.load_fact_subscriptions('scheduler')$$);

-- ── Refresh Schedule Documentation ───────────────────────────
COMMENT ON PROCEDURE bi_core.load_fact_subscriptions IS
    'Daily ETL load. Schedule: 03:00 UTC via pg_cron. '
    'Credentials: DB user bi_etl_user; password from AWS Secrets Manager secret BI_ETL_SECRET. '
    'Retention: refresh_log rows purged after 90 days by separate cleanup job.';


-- CSV-compatible staging table + ETL (overrides 04 default stg definition)
DROP TABLE IF EXISTS bi_core.stg_subscriptions;
CREATE TABLE bi_core.stg_subscriptions (
    customer_id      VARCHAR(50),
    month            DATE,
    region           VARCHAR(30),
    plan_type        VARCHAR(30),
    channel          VARCHAR(30),
    segment          VARCHAR(20),
    monthly_revenue  NUMERIC(12,2),
    churn_flag       SMALLINT,
    active_flag      SMALLINT,
    usage_score      NUMERIC(4,3),
    support_tickets  SMALLINT,
    failed_payments  SMALLINT,
    cohort_month     DATE
);

CREATE OR REPLACE PROCEDURE bi_core.load_fact_subscriptions(p_run_by VARCHAR DEFAULT 'scheduler')
LANGUAGE plpgsql AS $$
DECLARE
    v_start     TIMESTAMPTZ := clock_timestamp();
    v_rows      INT;
    v_rejected  INT := 0;
    v_err       TEXT;
BEGIN
    INSERT INTO bi_core.dim_customer (customer_id, cohort_month, region, plan_type, channel, segment)
    SELECT DISTINCT customer_id, cohort_month, region, plan_type, channel, segment
    FROM bi_core.stg_subscriptions
    ON CONFLICT (customer_id) DO NOTHING;

    INSERT INTO bi_core.fact_subscriptions (
        customer_key, date_key, plan_key,
        monthly_revenue, churn_flag, active_flag,
        usage_score, support_tickets, failed_payments,
        region, segment
    )
    SELECT
        c.customer_key,
        s.month,
        p.plan_key,
        s.monthly_revenue,
        s.churn_flag,
        s.active_flag,
        s.usage_score,
        s.support_tickets,
        s.failed_payments,
        s.region,
        s.segment
    FROM bi_core.stg_subscriptions s
    JOIN bi_core.dim_customer c ON c.customer_id = s.customer_id
    JOIN bi_core.dim_plan p ON p.plan_name = s.plan_type
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    INSERT INTO bi_audit.refresh_log
        (triggered_by, source_table, rows_loaded, rows_rejected, status, duration_ms)
    VALUES
        (p_run_by, 'fact_subscriptions', v_rows, v_rejected, 'SUCCESS',
         EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start)::INT);
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    INSERT INTO bi_audit.refresh_log
        (triggered_by, source_table, rows_loaded, rows_rejected, status, error_message, duration_ms)
    VALUES
        (p_run_by, 'fact_subscriptions', 0, 0, 'FAILED', v_err,
         EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start)::INT);
    RAISE;
END;
$$;

INSERT INTO bi_core.dim_date (
    date_key, year, quarter, month_num, month_name,
    week_num, day_of_week, is_month_start, fiscal_year, fiscal_quarter
)
SELECT
    d::DATE,
    EXTRACT(YEAR FROM d)::SMALLINT,
    EXTRACT(QUARTER FROM d)::SMALLINT,
    EXTRACT(MONTH FROM d)::SMALLINT,
    TO_CHAR(d, 'Month'),
    EXTRACT(WEEK FROM d)::SMALLINT,
    EXTRACT(ISODOW FROM d)::SMALLINT,
    TRUE,
    EXTRACT(YEAR FROM d)::SMALLINT,
    EXTRACT(QUARTER FROM d)::SMALLINT
FROM generate_series('2023-01-01'::DATE, '2025-12-01'::DATE, '1 month'::INTERVAL) d
ON CONFLICT (date_key) DO NOTHING;
-- ============================================================
-- Revenue & Churn BI Suite — API Grants for Dashboard (PostgREST)
-- Exposes mart views via public schema wrappers for supabase-js
-- Run after 02_mart_views.sql and 04_alerts_and_etl.sql
-- ============================================================

CREATE OR REPLACE VIEW public.v_mrr_monthly AS
SELECT * FROM bi_mart.v_mrr_monthly;

CREATE OR REPLACE VIEW public.v_revenue_drilldown AS
SELECT * FROM bi_mart.v_revenue_drilldown;

CREATE OR REPLACE VIEW public.v_cohort_retention AS
SELECT * FROM bi_mart.v_cohort_retention;

CREATE OR REPLACE VIEW public.v_accounts_at_risk AS
SELECT * FROM bi_mart.v_accounts_at_risk;

CREATE OR REPLACE VIEW public.v_alerts AS
SELECT * FROM bi_mart.v_alerts;

CREATE OR REPLACE VIEW public.v_active_alerts AS
SELECT * FROM bi_mart.v_active_alerts;

CREATE OR REPLACE VIEW public.v_revenue_mix AS
SELECT * FROM bi_mart.v_revenue_mix;

CREATE OR REPLACE VIEW public.v_health_signals AS
SELECT * FROM bi_mart.v_health_signals;

CREATE OR REPLACE VIEW public.v_refresh_log AS
SELECT
    log_id,
    run_ts,
    triggered_by,
    source_table,
    rows_loaded,
    rows_rejected,
    status,
    error_message,
    duration_ms
FROM bi_audit.refresh_log;

GRANT SELECT ON public.v_mrr_monthly        TO anon, authenticated;
GRANT SELECT ON public.v_revenue_drilldown  TO anon, authenticated;
GRANT SELECT ON public.v_cohort_retention   TO anon, authenticated;
GRANT SELECT ON public.v_accounts_at_risk   TO anon, authenticated;
GRANT SELECT ON public.v_alerts             TO anon, authenticated;
GRANT SELECT ON public.v_active_alerts      TO anon, authenticated;
GRANT SELECT ON public.v_revenue_mix        TO anon, authenticated;
GRANT SELECT ON public.v_health_signals     TO anon, authenticated;
GRANT SELECT ON public.v_refresh_log        TO anon, authenticated;

-- Reload PostgREST schema cache so new views are visible immediately
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- Revenue & Churn BI Suite — REST seed helpers
-- Enables data load via Supabase API (secret key) without psql
-- ============================================================

CREATE TABLE IF NOT EXISTS public._bi_seed_staging (
    customer_id      VARCHAR(50),
    month            DATE,
    region           VARCHAR(30),
    plan_type        VARCHAR(30),
    channel          VARCHAR(30),
    segment          VARCHAR(20),
    monthly_revenue  NUMERIC(12,2),
    churn_flag       SMALLINT,
    active_flag      SMALLINT,
    usage_score      NUMERIC(4,3),
    support_tickets  SMALLINT,
    failed_payments  SMALLINT,
    cohort_month     DATE
);

CREATE OR REPLACE FUNCTION public.run_bi_load()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, bi_core, bi_audit
AS $$
DECLARE
    v_rows INT;
BEGIN
    TRUNCATE bi_core.stg_subscriptions;

    INSERT INTO bi_core.stg_subscriptions (
        customer_id, month, region, plan_type, channel, segment,
        monthly_revenue, churn_flag, active_flag, usage_score,
        support_tickets, failed_payments, cohort_month
    )
    SELECT
        customer_id, month, region, plan_type, channel, segment,
        monthly_revenue, churn_flag, active_flag, usage_score,
        support_tickets, failed_payments, cohort_month
    FROM public._bi_seed_staging;

    CALL bi_core.load_fact_subscriptions('api:seed');

    SELECT COUNT(*) INTO v_rows FROM bi_core.fact_subscriptions;

    TRUNCATE public._bi_seed_staging;

    RETURN json_build_object('fact_rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.run_bi_load() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.run_bi_load() TO service_role;

GRANT SELECT, INSERT, DELETE, TRUNCATE ON public._bi_seed_staging TO service_role;

NOTIFY pgrst, 'reload schema';
