"""
Upload local synthetic data to Supabase PostgreSQL instance.

Reads fact_subscriptions.csv, connects to Supabase via psycopg2,
loads data into stg_subscriptions, then calls the ETL procedure
to populate dimension and fact tables.

Usage:
    1. Copy .env.example to .env and fill in your Supabase DB password
    2. Run: python upload_to_supabase.py
"""

import os
import sys
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

# ── Configuration ─────────────────────────────────────────────
load_dotenv()

SUPABASE_PROJECT_ID = "vtlfbpxcequpfkivxzgf"
SUPABASE_DB_HOST = os.getenv(
    "SUPABASE_POOLER_HOST", "aws-1-ap-southeast-2.pooler.supabase.com"
)
SUPABASE_DB_PORT = int(os.getenv("SUPABASE_DB_PORT", "5432"))
SUPABASE_DB_NAME = "postgres"
SUPABASE_DB_USER = os.getenv(
    "SUPABASE_DB_USER", f"postgres.{SUPABASE_PROJECT_ID}"
)
SUPABASE_DB_PASSWORD = os.getenv("SUPABASE_DB_PASSWORD")

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(ROOT_DIR, "sql")
CSV_FILE = os.path.join(ROOT_DIR, "fact_subscriptions.csv")

# ── SQL Scripts ───────────────────────────────────────────────
SQL_FILES = [
    os.path.join(SQL_DIR, "01_star_schema_ddl.sql"),
    os.path.join(SQL_DIR, "02_mart_views.sql"),
    # 03_rbac_security.sql is skipped — requires superuser and env-var passwords
    os.path.join(SQL_DIR, "04_alerts_and_etl.sql"),
    os.path.join(SQL_DIR, "05_api_grants.sql"),
    os.path.join(SQL_DIR, "06_api_seed.sql"),
]

# Staging table DDL (matches CSV columns, not fact table structure)
STG_TABLE_DDL = """
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
"""

# Corrected ETL procedure that maps staging → dim + fact tables
LOAD_PROCEDURE = """
CREATE OR REPLACE PROCEDURE bi_core.load_fact_subscriptions(p_run_by VARCHAR DEFAULT 'scheduler')
LANGUAGE plpgsql AS $$
DECLARE
    v_start     TIMESTAMPTZ := clock_timestamp();
    v_rows      INT;
    v_rejected  INT := 0;
    v_err       TEXT;
BEGIN
    -- Insert new customers into dim_customer
    INSERT INTO bi_core.dim_customer (customer_id, cohort_month, region, plan_type, channel, segment)
    SELECT DISTINCT customer_id, cohort_month, region, plan_type, channel, segment
    FROM bi_core.stg_subscriptions
    ON CONFLICT (customer_id) DO NOTHING;

    -- Upsert into fact_subscriptions
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
"""

# Seed dim_date with monthly entries for the data range
DIM_DATE_SEED = """
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


def get_connection():
    """Create and return a psycopg2 connection to Supabase."""
    if not SUPABASE_DB_PASSWORD:
        print("ERROR: SUPABASE_DB_PASSWORD not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Replace the placeholder with your Supabase DB password")
        print("  3. Find it at: Supabase Dashboard > Project Settings > Database")
        sys.exit(1)

    print(f"Connecting to Supabase at {SUPABASE_DB_HOST}:{SUPABASE_DB_PORT}...")
    conn = psycopg2.connect(
        host=SUPABASE_DB_HOST,
        port=SUPABASE_DB_PORT,
        dbname=SUPABASE_DB_NAME,
        user=SUPABASE_DB_USER,
        password=SUPABASE_DB_PASSWORD,
        sslmode="require",
        connect_timeout=20,
    )
    conn.autocommit = False
    print("Connected successfully!\n")
    return conn


def run_sql_file(conn, filepath):
    """Execute an entire SQL file against the connection."""
    filename = os.path.basename(filepath)
    print(f"  Running {filename}...")
    with open(filepath, "r", encoding="utf-8") as f:
        sql = f.read()
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    print(f"  ✓ {filename} completed.")


def setup_schema(conn):
    """Run DDL scripts, seed dim_date, create staging table & ETL procedure."""
    print("=" * 60)
    print("STEP 1: Setting up database schema")
    print("=" * 60)

    for sql_file in SQL_FILES:
        run_sql_file(conn, sql_file)

    # Seed dim_date
    print("  Seeding dim_date...")
    with conn.cursor() as cur:
        cur.execute(DIM_DATE_SEED)
    conn.commit()
    print("  ✓ dim_date seeded.")

    # Create staging table (CSV-compatible schema)
    print("  Creating staging table (stg_subscriptions)...")
    with conn.cursor() as cur:
        cur.execute(STG_TABLE_DDL)
    conn.commit()
    print("  ✓ Staging table ready.")

    # Create corrected ETL procedure
    print("  Creating ETL load procedure...")
    with conn.cursor() as cur:
        cur.execute(LOAD_PROCEDURE)
    conn.commit()
    print("  ✓ ETL procedure created.\n")


def upload_csv(conn):
    """Read CSV and bulk-insert into stg_subscriptions."""
    print("=" * 60)
    print("STEP 2: Uploading CSV data to staging table")
    print("=" * 60)

    if not os.path.exists(CSV_FILE):
        print(f"ERROR: CSV file not found at {CSV_FILE}")
        print("Run 'python generate_data.py' first to create it.")
        sys.exit(1)

    df = pd.read_csv(CSV_FILE)
    print(f"  Read {len(df)} rows from fact_subscriptions.csv")
    print(f"  Columns: {list(df.columns)}")

    # Truncate staging table before insert
    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE bi_core.stg_subscriptions;")
    conn.commit()

    # Bulk insert using execute_values (much faster than row-by-row)
    columns = [
        "customer_id", "month", "region", "plan_type", "channel", "segment",
        "monthly_revenue", "churn_flag", "active_flag", "usage_score",
        "support_tickets", "failed_payments", "cohort_month"
    ]

    values = [tuple(row) for row in df[columns].values]

    insert_sql = """
        INSERT INTO bi_core.stg_subscriptions
            (customer_id, month, region, plan_type, channel, segment,
             monthly_revenue, churn_flag, active_flag, usage_score,
             support_tickets, failed_payments, cohort_month)
        VALUES %s
    """

    print(f"  Inserting {len(values)} rows into stg_subscriptions...")
    with conn.cursor() as cur:
        execute_values(cur, insert_sql, values, page_size=1000)
    conn.commit()
    print(f"  ✓ {len(values)} rows inserted into staging.\n")


def run_etl(conn):
    """Call the ETL load procedure to process staging → fact + dimensions."""
    print("=" * 60)
    print("STEP 3: Running ETL load procedure")
    print("=" * 60)

    with conn.cursor() as cur:
        cur.execute("CALL bi_core.load_fact_subscriptions('manual:upload_script');")
    conn.commit()
    print("  ✓ ETL procedure completed.\n")


def verify(conn):
    """Run verification queries and print results."""
    print("=" * 60)
    print("STEP 4: Verification")
    print("=" * 60)

    queries = {
        "dim_customer":        "SELECT COUNT(*) FROM bi_core.dim_customer;",
        "dim_plan":            "SELECT COUNT(*) FROM bi_core.dim_plan;",
        "dim_date":            "SELECT COUNT(*) FROM bi_core.dim_date;",
        "fact_subscriptions":  "SELECT COUNT(*) FROM bi_core.fact_subscriptions;",
        "stg_subscriptions":   "SELECT COUNT(*) FROM bi_core.stg_subscriptions;",
        "refresh_log":         "SELECT COUNT(*) FROM bi_audit.refresh_log;",
    }

    with conn.cursor() as cur:
        for name, sql in queries.items():
            cur.execute(sql)
            count = cur.fetchone()[0]
            print(f"  {name:.<30} {count:>8} rows")

    # Show latest audit log entry
    with conn.cursor() as cur:
        cur.execute("""
            SELECT triggered_by, source_table, rows_loaded, status, duration_ms
            FROM bi_audit.refresh_log
            ORDER BY run_ts DESC LIMIT 1;
        """)
        row = cur.fetchone()
        if row:
            print(f"\n  Latest ETL run:")
            print(f"    Triggered by : {row[0]}")
            print(f"    Source table  : {row[1]}")
            print(f"    Rows loaded   : {row[2]}")
            print(f"    Status        : {row[3]}")
            print(f"    Duration (ms) : {row[4]}")

    print()


def main():
    print()
    print("+----------------------------------------------------------+")
    print("|   Revenue & Churn BI Suite -- Supabase Upload Script      |")
    print("+----------------------------------------------------------+")
    print(f"|   Target: {SUPABASE_DB_HOST:<48} |")
    print("+----------------------------------------------------------+")
    print()

    conn = get_connection()

    try:
        setup_schema(conn)
        upload_csv(conn)
        run_etl(conn)
        verify(conn)
        print("✅ All done! Your Supabase database is now fully loaded.")
        print("   You can query data via the Supabase Dashboard SQL Editor")
        print("   or connect Power BI / Tableau to the bi_mart views.\n")
    except Exception as e:
        conn.rollback()
        print(f"\n❌ ERROR: {e}")
        raise
    finally:
        conn.close()
        print("Connection closed.")


if __name__ == "__main__":
    main()
