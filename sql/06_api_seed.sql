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
