# Revenue & Churn BI Suite
### Enterprise Executive Dashboard — Security-First Design

> **Version:** 1.0.0 | **Data grain:** Monthly subscription | **DB:** PostgreSQL 15+ compatible

---

## Table of Contents
1. [Overview](#overview)
2. [Dashboard Pages](#dashboard-pages)
3. [Metric Definitions & Formulas](#metric-definitions--formulas)
4. [Data Dictionary](#data-dictionary)
5. [SQL Star Schema](#sql-star-schema)
6. [Security Design](#security-design)
7. [How to Run](#how-to-run)
8. [Limitations & Next Steps](#limitations--next-steps)

---

## Overview

This suite provides an enterprise-grade Revenue & Churn analytics platform with:
- **4 dashboard pages**: Overview KPIs, Drilldowns, Accounts at Risk, Alerts & Monitoring
- **Star-schema SQL data model** with fact + 4 dimension tables and 7 mart views
- **Security-first architecture**: RBAC, Row-Level Security, no PII, encrypted connections
- **Synthetic anonymized dataset**: 800 customers × 24 months = 8,297 rows (no real data)

**Tech stack:**
- Database: PostgreSQL 15 (SQL compatible with Redshift, Snowflake, BigQuery with minor changes)
- BI layer: Power BI Desktop (`.pbix`) / Tableau (`.twbx`) — connected via read-only mart views
- ETL: Python (data generation) + SQL procedures (load + audit)
- Security: PostgreSQL RLS policies + pgaudit extension

---

## Dashboard Pages

### Page 1 — Overview
Executive summary of all key metrics for the latest period.

| Visual | Source View | Description |
|--------|-------------|-------------|
| KPI tiles (8) | `v_mrr_monthly` | MRR, ARR, Active Customers, Churn Rate, Retention, ARPU, LTV proxy, High-Risk count |
| MRR Trend line | `v_mrr_monthly` | 24-month MRR with MoM growth overlay |
| Revenue by Plan donut | `v_revenue_mix` | Plan-level revenue contribution |
| Monthly Churn Rate bar | `v_mrr_monthly` | Color-coded by severity (green/amber/red) |
| Revenue by Region bar | `v_revenue_drilldown` | Horizontal bar, all-time |
| Cohort Retention Heatmap | `v_cohort_retention` | % retained by month since acquisition |

### Page 2 — Drilldowns
Interactive slicers for ad-hoc analysis.

| Slicer | Field | Values |
|--------|-------|--------|
| Region | `region` | North America, EMEA, APAC, LATAM |
| Plan | `plan_type` | Starter, Growth, Enterprise, Enterprise Plus |
| Segment | `segment` | SMB, Mid-Market, Enterprise |
| Channel | `channel` | Direct Sales, Partner, Self-Serve, Marketplace |

Visuals: Stacked MRR by Region/Segment, Churn Rate by Region, Top Revenue Impact table.

### Page 3 — Accounts at Risk
Risk-ranked table of active accounts with churn-risk proxy scores.

| Column | Source | Description |
|--------|--------|-------------|
| Anon ID | `dim_customer.customer_id` | SHA-256 hash prefix — no PII |
| Risk Score | `fact_subscriptions.churn_risk_score` | 0–100 composite score |
| Risk Tier | `v_accounts_at_risk.risk_tier` | HIGH ≥70 / MEDIUM 40–69 / LOW <40 |
| Driver Breakdown | chart | Usage (40%), Failed Payments (30%), Support (30%) |

**RLS enforcement:** Analyst users see only their assigned region's accounts.

### Page 4 — Alerts & Monitoring
Configurable threshold-based alerts + ETL refresh audit trail.

| Alert | Default threshold | Configurable? |
|-------|-------------------|---------------|
| Churn Spike | > 8% monthly churn rate | ✓ via `alert_thresholds` table |
| Revenue Drop | > −5% MoM MRR | ✓ via `alert_thresholds` table |
| High Avg Risk | > 50 avg risk score | ✓ via `alert_thresholds` table |
| Failed Payment Rate | > 8% | ✓ via `alert_thresholds` table |

Refresh log shows: run timestamp, triggered by, rows loaded, status, duration.

---

## Metric Definitions & Formulas

| Metric | Formula | Notes |
|--------|---------|-------|
| **MRR** | `SUM(monthly_revenue)` for active accounts in month | Monthly Recurring Revenue |
| **ARR** | `MRR × 12` | Annualized Run Rate — not actual annual bookings |
| **Churn Rate** | `COUNT(churned) / COUNT(total active)` | Monthly rate, not annualized |
| **Retention Rate** | `1 − Churn Rate` | Complement of monthly churn |
| **ARPU** | `MRR / Active Customers` | Average Revenue Per User (monthly) |
| **LTV Proxy** | `ARPU / Monthly Churn Rate` | Naive LTV; assumes constant churn. Replace with survival model in prod. |
| **Churn Risk Score** | `MIN(100, failed_payments×30 + MIN(tickets,5)×10 + (1−usage_score)×40)` | 0–100; higher = riskier |
| **Cohort Retention** | `Retained(M) / Cohort_Size(M0)` | % of original cohort still active at period N |
| **MoM MRR Growth** | `(MRR_t − MRR_{t-1}) / MRR_{t-1}` | Month-over-month percentage change |

---

## Data Dictionary

### `bi_core.fact_subscriptions`

| Column | Type | Description | PII? |
|--------|------|-------------|------|
| `sub_key` | BIGSERIAL | Surrogate primary key | No |
| `customer_key` | INT | FK to `dim_customer` | No |
| `date_key` | DATE | Month start date (e.g. 2024-01-01) | No |
| `plan_key` | INT | FK to `dim_plan` | No |
| `monthly_revenue` | NUMERIC(12,2) | MRR for this account-month in USD | No |
| `churn_flag` | SMALLINT | 1 = churned this month, 0 = active | No |
| `active_flag` | SMALLINT | 1 = active (post-churn rows excluded) | No |
| `usage_score` | NUMERIC(4,3) | Product usage intensity 0.0–1.0 | No |
| `support_tickets` | SMALLINT | Support tickets opened this month | No |
| `failed_payments` | SMALLINT | Count of failed payment attempts | No |
| `churn_risk_score` | NUMERIC(5,2) | Computed composite risk 0–100 (STORED) | No |
| `region` | VARCHAR(30) | Denormalized for RLS filter performance | No |
| `segment` | VARCHAR(20) | SMB / Mid-Market / Enterprise | No |
| `loaded_at` | TIMESTAMPTZ | ETL load timestamp | No |

### `bi_core.dim_customer`

| Column | Type | Description | PII? |
|--------|------|-------------|------|
| `customer_key` | SERIAL | Surrogate key | No |
| `customer_id` | CHAR(17) | "CUST_" + 12-char SHA-256 prefix. **No real identifier.** | No |
| `cohort_month` | DATE | First active month | No |
| `region` | VARCHAR(30) | Geographic region | No |
| `plan_type` | VARCHAR(30) | Subscription plan name | No |
| `channel` | VARCHAR(30) | Acquisition channel | No |
| `segment` | VARCHAR(20) | Business size segment | No |

### `bi_core.dim_plan`

| Column | Type | Description |
|--------|------|-------------|
| `plan_key` | SERIAL | Surrogate key |
| `plan_name` | VARCHAR(30) | Plan name |
| `tier_rank` | SMALLINT | 1=Starter, 2=Growth, 3=Enterprise, 4=Enterprise Plus |
| `base_price_usd` | NUMERIC(10,2) | List price (not actual billed amount) |

### `bi_core.dim_region` / `bi_core.dim_date`
Standard region and calendar dimension tables. See `01_star_schema_ddl.sql`.

### `bi_audit.refresh_log`

| Column | Description |
|--------|-------------|
| `triggered_by` | 'scheduler' or 'manual:<username>' |
| `source_table` | Table or view refreshed |
| `rows_loaded` | Row count successfully loaded |
| `status` | SUCCESS / FAILED / PARTIAL |
| `duration_ms` | Execution time in milliseconds |

### `bi_audit.alert_thresholds`

| Column | Description |
|--------|-------------|
| `metric_name` | Metric identifier (e.g. 'monthly_churn_rate') |
| `warning_threshold` | Value that triggers a WARNING alert |
| `critical_threshold` | Value that triggers a CRITICAL alert |
| `direction` | ABOVE (alert if metric exceeds threshold) or BELOW |

---

## SQL Star Schema

```
                    ┌──────────────┐
                    │  dim_date    │
                    │  (date_key)  │
                    └──────┬───────┘
                           │
┌─────────────┐    ┌───────┴──────────┐    ┌──────────────┐
│ dim_customer├────┤fact_subscriptions├────┤  dim_plan    │
│ (cust_key)  │    │                  │    │  (plan_key)  │
└─────────────┘    │  - monthly_rev   │    └──────────────┘
                   │  - churn_flag    │
                   │  - usage_score   │
                   │  - risk_score    │
                   └──────────────────┘
                          │
              ┌───────────┴──────────────┐
              │       bi_mart views       │
              │  v_mrr_monthly            │
              │  v_revenue_drilldown      │
              │  v_cohort_retention       │
              │  v_accounts_at_risk       │
              │  v_alerts                 │
              │  v_active_alerts          │
              │  v_health_signals         │
              └───────────────────────────┘
```

**Files:**
- `sql/01_star_schema_ddl.sql` — DDL for all tables + indexes
- `sql/02_mart_views.sql` — All BI mart views
- `sql/03_rbac_security.sql` — Roles, grants, RLS policies
- `sql/04_alerts_and_etl.sql` — Alert thresholds + ETL procedure + audit log

---

## Security Design

### A. No PII

All `customer_id` values are `"CUST_" + SHA-256(seed)[:12].upper()`. No names, emails,
phone numbers, IP addresses, or any real identifiers exist anywhere in the data model.
The anonymization is one-way — there is no mapping table from hash to real identity.

**Verification:** `SELECT customer_id FROM bi_core.dim_customer LIMIT 5;`
Returns values like `CUST_E87A5244CE37` — no real identity.

### B. Role-Based Access Control (RBAC)

| Role | DB Object | Access | Use case |
|------|-----------|--------|----------|
| `bi_owner` | `bi_core`, `bi_mart`, `bi_audit` | DDL + DML | ETL pipeline only |
| `bi_admin` | All schemas | SELECT + audit INSERT | BI admin, DBA |
| `bi_analyst` | `bi_mart` views only | SELECT (RLS-filtered) | Regional analysts |
| `bi_viewer` | Aggregate `bi_mart` views | SELECT (no customer rows) | Executives |
| `bi_readonly` | `bi_mart` views | SELECT | Power BI connector user |

**BI tool connects as:** `bi_pbi_connector` (member of `bi_readonly`) — read-only, mart views only, no access to raw fact/dim tables.

### C. Row-Level Security (RLS)

RLS is enforced on `bi_core.fact_subscriptions` via PostgreSQL's native RLS mechanism:

```sql
-- Policy: Analysts see only their assigned region
CREATE POLICY analyst_region_policy ON bi_core.fact_subscriptions
    AS RESTRICTIVE FOR SELECT TO bi_analyst
    USING (region IN (
        SELECT r.region FROM bi_core.rls_region_policy r
        WHERE r.db_user = current_user
    ));
```

The `rls_region_policy` table maps each analyst login to their allowed region(s).
Admins have a `PERMISSIVE` bypass policy. Viewers never touch the fact table.

**FORCE ROW LEVEL SECURITY** is set on the table — even the table owner is subject to policies.

### D. Secure Credentials

**No passwords are hardcoded anywhere.** All credentials are injected via environment variables:

```bash
# .env (never commit to source control; use .gitignore)
export BI_ADMIN_PASSWORD="..."
export BI_ANALYST_NA_PASSWORD="..."
export BI_ANALYST_EMEA_PASSWORD="..."
export BI_VIEWER_PASSWORD="..."
export BI_PBI_CONNECTOR_PASSWORD="..."

# Run SQL with env vars:
psql -v BI_ADMIN_PASSWORD="$BI_ADMIN_PASSWORD" \
     -v BI_PBI_CONNECTOR_PASSWORD="$BI_PBI_CONNECTOR_PASSWORD" \
     -f sql/03_rbac_security.sql
```

In production, use a secrets manager:
- **AWS:** Secrets Manager + IAM role for the BI server
- **GCP:** Secret Manager + Workload Identity
- **Azure:** Key Vault + Managed Identity

### E. Least Privilege (Read-Only BI Connection)

`bi_pbi_connector` is the user the BI tool connects as. Its privileges:
- `CONNECT` on `bi_db` database only
- `USAGE` on `bi_mart` schema only
- `SELECT` on all tables/views in `bi_mart` only
- No `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `DROP`, or schema-level DDL
- Connection limit: 10 (prevents connection exhaustion)
- Password expires annually (`VALID UNTIL '2026-12-31'`)

### F. Encrypted Data Connections

**PostgreSQL configuration** (`postgresql.conf`):
```conf
ssl = on
ssl_cert_file = '/etc/ssl/certs/server.crt'
ssl_key_file  = '/etc/ssl/private/server.key'
```

**`pg_hba.conf`** — only TLS connections accepted for BI users:
```
hostssl  bi_db  bi_pbi_connector  0.0.0.0/0  scram-sha-256
```

**Power BI connection string** must include:
```
Server=db-host;Database=bi_db;User Id=bi_pbi_connector;Password=...;
Encrypt=true;TrustServerCertificate=false;
```

**Tableau:** Set SSL Mode = "Require" in the connection dialog.

For cloud databases (Redshift, Snowflake, BigQuery): TLS is enforced by default.
Verify with: `SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();`

### G. Safe Sharing

- Dashboard published to a **private Power BI workspace** (e.g. `Revenue-BI-Secure`)
- **No public links** generated — sharing only via workspace member assignment
- Members assigned per role: Admin → `BI Admin` workspace role; Analyst → `BI Contributor` (filtered by RLS); Viewer → `BI Viewer`
- Row-level security is re-enforced at the Power BI dataset level using **Power BI RLS rules** that mirror the SQL RLS policies (belt-and-suspenders approach)

### H. Audit Trail

**ETL audit log** (`bi_audit.refresh_log`):
- Every ETL run records: timestamp, triggered_by, rows_loaded, status, duration_ms
- Failed runs record error_message
- Retained 90 days (cleanup job purges `run_ts < NOW() - INTERVAL '90 days'`)

**Query-level audit** via `pgaudit` extension:
```conf
shared_preload_libraries = 'pgaudit'
pgaudit.log = 'read,write'
pgaudit.log_catalog = off
```

**Refresh schedule:** Daily at **03:00 UTC** via `pg_cron`:
```sql
SELECT cron.schedule('bi-daily-refresh', '0 3 * * *',
    $$CALL bi_core.load_fact_subscriptions('scheduler')$$);
```

---
## Live Demo - https://revenue-churn-bi-suite.vercel.app/

## How to Run

### Prerequisites
- PostgreSQL 15+ (or Redshift/Snowflake with syntax adjustments)
- Python 3.9+ with pandas, numpy
- Power BI Desktop (or Tableau Desktop)
- pg_cron extension (optional, for scheduling)

### Step 1 — Generate synthetic data
```bash
cd bi-suite
pip install pandas numpy --break-system-packages
python3 data/generate_data.py
# Output: data/fact_subscriptions.csv (8,297 rows, no PII)
```

### Step 2 — Set up the database
```bash
# Set env vars (never hardcode)
export BI_ADMIN_PASSWORD="your-secure-password"
export BI_PBI_CONNECTOR_PASSWORD="another-secure-password"
# ... (see Security Design §D for full list)

# Create DB
createdb bi_db

# Run DDL
psql -d bi_db -f sql/01_star_schema_ddl.sql
psql -d bi_db -f sql/02_mart_views.sql
psql -d bi_db -v BI_ADMIN_PASSWORD="$BI_ADMIN_PASSWORD" \
              -v BI_PBI_CONNECTOR_PASSWORD="$BI_PBI_CONNECTOR_PASSWORD" \
              -f sql/03_rbac_security.sql
psql -d bi_db -f sql/04_alerts_and_etl.sql
```

### Step 3 — Load data
```bash
# Copy CSV to staging and run load procedure
psql -d bi_db -c "\COPY bi_core.stg_subscriptions FROM 'data/fact_subscriptions.csv' CSV HEADER"
psql -d bi_db -c "CALL bi_core.load_fact_subscriptions('manual:setup');"
```

### Step 4 — Connect Power BI
1. Open Power BI Desktop → Get Data → PostgreSQL
2. Server: `your-db-host`, Database: `bi_db`
3. User: `bi_pbi_connector` (from env var — do not type password in .pbix file)
4. Enable SSL: Advanced options → `sslmode=require`
5. Import views: `bi_mart.v_mrr_monthly`, `v_revenue_drilldown`, `v_cohort_retention`, `v_accounts_at_risk`, `v_alerts`, `v_active_alerts`
6. Set up Power BI RLS rules to mirror SQL RLS (belt-and-suspenders)
7. Publish to private workspace — do NOT enable public access

### Step 5 — Schedule refreshes
```sql
-- Requires pg_cron extension
SELECT cron.schedule('bi-daily-refresh', '0 3 * * *',
    $$CALL bi_core.load_fact_subscriptions('scheduler')$$);
-- Verify: SELECT * FROM cron.job;
```

### Checking the audit trail
```sql
SELECT * FROM bi_audit.refresh_log ORDER BY run_ts DESC LIMIT 10;
SELECT * FROM bi_mart.v_active_alerts;
```

---

### Alternative: Deploy to Supabase (Cloud PostgreSQL)

Instead of running a local PostgreSQL instance, you can deploy the entire BI suite to
[Supabase](https://supabase.com), which provides a managed PostgreSQL 15 database.

#### Prerequisites
- A Supabase project (free tier works)
- Python 3.9+ with the project's virtual environment activated

#### Quick Start (automated)
```bash
# 1. Activate the virtual environment
# Windows:
.\venv\Scripts\activate
# macOS/Linux:
source venv/bin/activate

# 2. Install dependencies (if not already installed)
pip install psycopg2-binary python-dotenv

# 3. Create your .env file from the template
cp .env.example .env
# Edit .env and set SUPABASE_DB_PASSWORD to your Supabase database password
# (found in Supabase Dashboard > Project Settings > Database)

# 4. Run the upload script — this does everything automatically:
#    - Creates schemas, tables, indexes
#    - Creates mart views
#    - Seeds dimension tables (dim_date, dim_plan, dim_region)
#    - Uploads fact_subscriptions.csv to staging
#    - Runs the ETL procedure to load fact + dimension tables
#    - Prints verification counts
python upload_to_supabase.py
```

#### Connect Power BI / Tableau to Supabase
Use these connection settings:
- **Host:** `db.vtlfbpxcequpfkivxzgf.supabase.co`
- **Port:** `5432` (direct) or `6543` (connection pooling)
- **Database:** `postgres`
- **User:** `postgres`
- **Password:** (your Supabase DB password)
- **SSL Mode:** `require`

Import the same `bi_mart` views listed in Step 4 above.


---

## Limitations & Next Steps

### Current Limitations

| Area | Limitation | Impact |
|------|------------|--------|
| LTV formula | Naive `ARPU / churn_rate` | Overestimates LTV for high-churn cohorts |
| Churn risk score | Rule-based proxy (3 signals) | Not a trained ML model; limited predictive accuracy |
| Cohort retention | Acquisition cohort only | No expansion/contraction revenue cohorts |
| RLS | PostgreSQL native only | Redshift/Snowflake require different RLS syntax |
| Alert delivery | View-based (pull) | No push notifications (email/Slack/PagerDuty) |
| Data freshness | Daily ETL | No real-time or near-real-time streaming |
| Multi-currency | USD only | No FX conversion for multi-currency customers |

### Recommended Next Steps

**Analytics improvements:**
1. **Survival model for LTV** — fit a Kaplan-Meier or Cox proportional hazards model on cohort data
2. **ML churn prediction** — train a gradient boosted classifier (XGBoost) on usage signals; replace rule-based risk score
3. **Expansion MRR tracking** — add upsell/cross-sell MRR as separate fact columns
4. **NPS/CSAT integration** — join with CRM satisfaction scores as additional churn signal

**Engineering improvements:**
5. **Streaming ETL** — replace daily batch with Kafka + dbt for hourly refresh
6. **Alert push delivery** — integrate `v_active_alerts` with PagerDuty API or Slack webhook
7. **Data lineage** — add dbt model documentation for end-to-end lineage tracking
8. **Partition pruning** — enable table partitioning by month for query performance at scale
9. **Column-level encryption** — encrypt monthly_revenue at rest using pgcrypto for additional compliance

**Compliance & governance:**
10. **Data retention policy** — implement automated purge of `refresh_log` rows > 90 days
11. **SOC 2 controls mapping** — map each security control to the relevant SOC 2 trust criteria
12. **GDPR right-to-erasure** — document that synthetic IDs are deletion-safe (no real subjects)
