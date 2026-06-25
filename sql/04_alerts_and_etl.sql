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
