"""
Seed Supabase via REST API using the secret (service) key.

Prerequisites:
  1. Run sql/00_setup_all.sql in Supabase SQL Editor first
  2. Set SUPABASE_URL and SUPABASE_SECRET_KEY in .env

Usage:
    python data/build_setup_sql.py   # if schema not applied yet
    python data/seed_via_rest.py
"""

import json
import os
import sys
import time
from pathlib import Path

import pandas as pd
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")

SUPABASE_URL = os.getenv("SUPABASE_URL", "https://vtlfbpxcequpfkivxzgf.supabase.co").rstrip("/")
SECRET_KEY = os.getenv("SUPABASE_SECRET_KEY")
CSV_FILE = ROOT / "fact_subscriptions.csv"
BATCH_SIZE = 500


def headers():
    if not SECRET_KEY:
        print("ERROR: SUPABASE_SECRET_KEY missing in .env")
        sys.exit(1)
    return {
        "apikey": SECRET_KEY,
        "Authorization": f"Bearer {SECRET_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal",
    }


def check_view_exists():
    url = f"{SUPABASE_URL}/rest/v1/v_mrr_monthly?select=month&limit=1"
    r = requests.get(url, headers=headers(), timeout=30)
    if r.status_code == 404:
        print("ERROR: public.v_mrr_monthly not found.")
        print("  Run sql/00_setup_all.sql in Supabase Dashboard > SQL Editor first.")
        sys.exit(1)
    if r.status_code >= 400:
        print(f"ERROR checking views: {r.status_code} {r.text}")
        sys.exit(1)


def clear_staging():
    url = f"{SUPABASE_URL}/rest/v1/_bi_seed_staging?id=gt.0"
    requests.delete(url, headers=headers(), timeout=60)
    # truncate via delete all rows — table may be empty
    url = f"{SUPABASE_URL}/rest/v1/rpc/run_bi_load"
    # only after upload; for clear use delete with neq filter on text column
    requests.delete(
        f"{SUPABASE_URL}/rest/v1/_bi_seed_staging?customer_id=neq.__impossible__",
        headers=headers(),
        timeout=120,
    )


def upload_batch(rows):
    url = f"{SUPABASE_URL}/rest/v1/_bi_seed_staging"
    payload = []
    for row in rows:
        payload.append(
            {
                "customer_id": row["customer_id"],
                "month": str(row["month"]),
                "region": row["region"],
                "plan_type": row["plan_type"],
                "channel": row["channel"],
                "segment": row["segment"],
                "monthly_revenue": float(row["monthly_revenue"]),
                "churn_flag": int(row["churn_flag"]),
                "active_flag": int(row["active_flag"]),
                "usage_score": float(row["usage_score"]),
                "support_tickets": int(row["support_tickets"]),
                "failed_payments": int(row["failed_payments"]),
                "cohort_month": str(row["cohort_month"]),
            }
        )
    r = requests.post(url, headers=headers(), data=json.dumps(payload), timeout=120)
    if r.status_code >= 400:
        raise RuntimeError(f"Insert failed ({r.status_code}): {r.text}")


def run_etl():
    url = f"{SUPABASE_URL}/rest/v1/rpc/run_bi_load"
    r = requests.post(url, headers=headers(), json={}, timeout=300)
    if r.status_code >= 400:
        raise RuntimeError(f"ETL RPC failed ({r.status_code}): {r.text}")
    return r.json()


def verify():
    url = f"{SUPABASE_URL}/rest/v1/v_mrr_monthly?select=month,mrr&order=month.desc&limit=1"
    r = requests.get(url, headers=headers(), timeout=30)
    r.raise_for_status()
    data = r.json()
    print("Latest MRR row:", data)


def main():
    print("Checking API views...")
    check_view_exists()

    if not CSV_FILE.exists():
        print(f"ERROR: {CSV_FILE} not found. Run: python data/generate_data.py")
        sys.exit(1)

    df = pd.read_csv(CSV_FILE)
    print(f"Uploading {len(df)} rows in batches of {BATCH_SIZE}...")

    for start in range(0, len(df), BATCH_SIZE):
        batch = df.iloc[start : start + BATCH_SIZE]
        upload_batch(batch)
        print(f"  ✓ {min(start + BATCH_SIZE, len(df))}/{len(df)}")
        time.sleep(0.2)

    print("Running ETL...")
    result = run_etl()
    print("ETL result:", result)

    verify()
    print("\n✅ Done! Refresh the dashboard at http://localhost:3000")


if __name__ == "__main__":
    main()
