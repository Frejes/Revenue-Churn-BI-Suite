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
