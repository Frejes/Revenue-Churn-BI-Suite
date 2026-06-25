"""
Synthetic Data Generator for Revenue & Churn BI Suite
NO PII: All customer IDs are SHA-256 hashed. No names, emails, or real identifiers.
"""
import hashlib, random, json
import pandas as pd
import numpy as np
from datetime import date, timedelta

random.seed(42)
np.random.seed(42)

N_CUSTOMERS = 800
MONTHS = pd.date_range("2023-01-01", "2024-12-01", freq="MS")
REGIONS = ["North America", "EMEA", "APAC", "LATAM"]
PLANS = ["Starter", "Growth", "Enterprise", "Enterprise Plus"]
CHANNELS = ["Direct Sales", "Partner", "Self-Serve", "Marketplace"]
PLAN_MRR = {"Starter": (200,600), "Growth": (800,2500), "Enterprise": (3000,8000), "Enterprise Plus": (9000,25000)}
REGION_WEIGHTS = [0.40, 0.30, 0.20, 0.10]
PLAN_WEIGHTS   = [0.35, 0.30, 0.25, 0.10]

def anon_id(seed_val):
    return "CUST_" + hashlib.sha256(str(seed_val).encode()).hexdigest()[:12].upper()

customers = []
for i in range(N_CUSTOMERS):
    region  = np.random.choice(REGIONS, p=REGION_WEIGHTS)
    plan    = np.random.choice(PLANS,   p=PLAN_WEIGHTS)
    channel = random.choice(CHANNELS)
    seg     = "Enterprise" if plan in ["Enterprise","Enterprise Plus"] else ("Mid-Market" if plan=="Growth" else "SMB")
    base_mrr = random.uniform(*PLAN_MRR[plan])
    cohort_month = random.choice(MONTHS[:18])
    customers.append({
        "customer_id": anon_id(f"cust_{i}"),
        "region": region, "plan_type": plan,
        "channel": channel, "segment": seg,
        "base_mrr": round(base_mrr, 2),
        "cohort_month": cohort_month
    })

cdf = pd.DataFrame(customers)

rows = []
for _, c in cdf.iterrows():
    active = True
    mrr = c["base_mrr"]
    for m in MONTHS:
        if m < c["cohort_month"]:
            continue
        if not active:
            break
        churn_base = {"Starter":0.06,"Growth":0.04,"Enterprise":0.02,"Enterprise Plus":0.01}[c["plan_type"]]
        support_tickets = max(0, int(np.random.poisson(1.5)))
        failed_payments = 1 if random.random() < 0.08 else 0
        usage_score     = round(random.uniform(0.1, 1.0), 2)
        churn_prob = churn_base + (0.04 if support_tickets>3 else 0) + (0.06 if failed_payments else 0) + (0.03 if usage_score < 0.3 else 0)
        churn_flag = 1 if random.random() < churn_prob else 0
        mrr = max(50, mrr * random.uniform(0.97, 1.03))
        rows.append({
            "customer_id": c["customer_id"],
            "month": m.strftime("%Y-%m-%d"),
            "region": c["region"],
            "plan_type": c["plan_type"],
            "channel": c["channel"],
            "segment": c["segment"],
            "monthly_revenue": round(mrr, 2),
            "churn_flag": churn_flag,
            "active_flag": 1,
            "usage_score": usage_score,
            "support_tickets": support_tickets,
            "failed_payments": failed_payments,
            "cohort_month": c["cohort_month"].strftime("%Y-%m-%d"),
        })
        if churn_flag:
            active = False

import os

df = pd.DataFrame(rows)
output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fact_subscriptions.csv")
df.to_csv(output_path, index=False)
print(f"Generated {len(df)} rows, {df['customer_id'].nunique()} unique anonymized customers")
print(df.dtypes)
print(df.head(3).to_string())
