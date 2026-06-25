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
