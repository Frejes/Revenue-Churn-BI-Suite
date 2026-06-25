"""Build sql/00_setup_all.sql for Supabase SQL Editor (one-shot schema setup)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
OUT = SQL_DIR / "00_setup_all.sql"

STAGING_SQL = """
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
"""

ORDER = [
    "-- Paste this entire file into Supabase Dashboard > SQL Editor > Run\n",
    "-- Project: vtlfbpxcequpfkivxzgf\n\n",
    "01_star_schema_ddl.sql",
    "02_mart_views.sql",
    "04_alerts_and_etl.sql",
    "__staging_override__",
    "05_api_grants.sql",
    "06_api_seed.sql",
]

parts = []
for item in ORDER:
    if item.endswith(".sql"):
        parts.append((SQL_DIR / item).read_text(encoding="utf-8"))
        parts.append("\n")
    elif item == "__staging_override__":
        parts.append(STAGING_SQL)
    else:
        parts.append(item)

OUT.write_text("".join(parts), encoding="utf-8")
print(f"Wrote {OUT} ({OUT.stat().st_size // 1024} KB)")

RESUME = SQL_DIR / "00_setup_resume.sql"
resume_parts = [
    "-- Run this if 00_setup_all.sql failed partway (tables/indexes already exist)\n",
    "-- Project: vtlfbpxcequpfkivxzgf\n\n",
    (SQL_DIR / "02_mart_views.sql").read_text(encoding="utf-8"),
    "\n",
    (SQL_DIR / "04_alerts_and_etl.sql").read_text(encoding="utf-8"),
    "\n",
    STAGING_SQL,
    (SQL_DIR / "05_api_grants.sql").read_text(encoding="utf-8"),
    "\n",
    (SQL_DIR / "06_api_seed.sql").read_text(encoding="utf-8"),
]
RESUME.write_text("".join(resume_parts), encoding="utf-8")
print(f"Wrote {RESUME} ({RESUME.stat().st_size // 1024} KB)")
