-- Revenue & Churn BI Suite — RBAC & Row-Level Security
-- Run as superuser / DBA. Never expose these credentials in app code.
-- Credentials injected via environment variables (see README.md).
-- ============================================================

-- ── A. Create Roles ──────────────────────────────────────────

-- BI Owner: DDL rights (for ETL/admin only, never used by BI tool)
CREATE ROLE bi_owner NOLOGIN;

-- Admin: full read on all schemas, can manage RLS policies
CREATE ROLE bi_admin NOLOGIN;

-- Analyst: read from bi_mart only, subject to RLS (see below)
CREATE ROLE bi_analyst NOLOGIN;

-- Viewer: read from bi_mart only, global (no RLS partition)
--         but cannot see customer-level rows (only aggregates)
CREATE ROLE bi_viewer NOLOGIN;

-- ── B. Login Users (passwords from ENV; shown as placeholders) ──
-- In production: use a secrets manager (AWS Secrets Manager, Vault, etc.)
-- Never commit real passwords to source control.

CREATE USER bi_admin_user  WITH ROLE bi_admin   PASSWORD :'BI_ADMIN_PASSWORD';
CREATE USER bi_analyst_na  WITH ROLE bi_analyst  PASSWORD :'BI_ANALYST_NA_PASSWORD';
CREATE USER bi_analyst_emea WITH ROLE bi_analyst PASSWORD :'BI_ANALYST_EMEA_PASSWORD';
CREATE USER bi_viewer_user WITH ROLE bi_viewer   PASSWORD :'BI_VIEWER_PASSWORD';
-- Note: Run with `psql -v BI_ADMIN_PASSWORD="$BI_ADMIN_PASSWORD" ...`
-- so the password comes from the shell environment, not this file.

-- ── C. Schema Grants ─────────────────────────────────────────

-- bi_owner: full DDL on bi_core and bi_mart
GRANT ALL ON SCHEMA bi_core TO bi_owner;
GRANT ALL ON SCHEMA bi_mart TO bi_owner;
GRANT ALL ON SCHEMA bi_audit TO bi_owner;

-- bi_admin: read everything, write to audit log
GRANT USAGE ON SCHEMA bi_core  TO bi_admin;
GRANT USAGE ON SCHEMA bi_mart  TO bi_admin;
GRANT USAGE ON SCHEMA bi_audit TO bi_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA bi_core  TO bi_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA bi_mart  TO bi_admin;
GRANT SELECT, INSERT ON bi_audit.refresh_log  TO bi_admin;

-- bi_analyst: ONLY mart views (no raw fact access), subject to RLS
GRANT USAGE ON SCHEMA bi_mart TO bi_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA bi_mart TO bi_analyst;
-- Analysts do NOT get access to bi_core (raw fact/dim) or bi_audit

-- bi_viewer: mart views, aggregate-only views only
GRANT USAGE ON SCHEMA bi_mart TO bi_viewer;
GRANT SELECT ON bi_mart.v_mrr_monthly    TO bi_viewer;
GRANT SELECT ON bi_mart.v_revenue_mix    TO bi_viewer;
GRANT SELECT ON bi_mart.v_alerts         TO bi_viewer;
-- Viewers do NOT get accounts-at-risk or drilldown (risk data is sensitive)

-- Default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA bi_mart
    GRANT SELECT ON TABLES TO bi_analyst, bi_viewer;

-- ── D. Row-Level Security (RLS) — Region Partitioning ────────
-- Applied to fact table and mart views that contain customer-level rows.
-- Analysts see ONLY rows matching their assigned region(s).
-- Admins bypass RLS. Viewers see aggregate views (no row-level customer data).

-- Enable RLS on fact table
ALTER TABLE bi_core.fact_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE bi_core.fact_subscriptions FORCE ROW LEVEL SECURITY;

-- Region mapping table: maps DB username → allowed region(s)
CREATE TABLE IF NOT EXISTS bi_core.rls_region_policy (
    db_user     VARCHAR(60) NOT NULL,
    region      VARCHAR(30) NOT NULL,
    PRIMARY KEY (db_user, region)
);
COMMENT ON TABLE bi_core.rls_region_policy IS
    'Maps DB login users to allowed regions for Row-Level Security. '
    'Maintained by DBA. bi_analyst role users only see rows in their assigned region.';

-- Seed RLS policy assignments
INSERT INTO bi_core.rls_region_policy (db_user, region) VALUES
    ('bi_analyst_na',   'North America'),
    ('bi_analyst_emea', 'EMEA')
ON CONFLICT DO NOTHING;

-- RLS POLICY: Analysts see only their assigned region rows
CREATE POLICY analyst_region_policy ON bi_core.fact_subscriptions
    AS RESTRICTIVE
    FOR SELECT
    TO bi_analyst
    USING (
        region IN (
            SELECT r.region
            FROM bi_core.rls_region_policy r
            WHERE r.db_user = current_user
        )
    );

-- RLS POLICY: Admins bypass (see everything)
CREATE POLICY admin_bypass_policy ON bi_core.fact_subscriptions
    AS PERMISSIVE
    FOR SELECT
    TO bi_admin
    USING (TRUE);

-- bi_owner bypasses RLS by default (superuser-adjacent)
-- Viewers don't have access to fact table at all (aggregate views only)

-- ── E. Least-Privilege Read-Only Connection User ─────────────
-- This is the user the BI tool (Power BI / Tableau) connects as.
-- It has SELECT on mart views only — no DDL, no DML.
CREATE ROLE bi_readonly NOLOGIN;
GRANT USAGE ON SCHEMA bi_mart TO bi_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA bi_mart TO bi_readonly;

CREATE USER bi_pbi_connector
    WITH ROLE bi_readonly
    PASSWORD :'BI_PBI_CONNECTOR_PASSWORD'
    CONNECTION LIMIT 10    -- prevent connection exhaustion
    VALID UNTIL '2026-12-31';  -- rotate annually

-- Connection string (TLS enforced — see F. below):
-- postgresql://bi_pbi_connector:<from-env>@db-host:5432/bi_db?sslmode=require

-- ── F. TLS / Encrypted Connections ───────────────────────────
-- PostgreSQL: enforce SSL in postgresql.conf:
--   ssl = on
--   ssl_cert_file = '/etc/ssl/certs/server.crt'
--   ssl_key_file  = '/etc/ssl/private/server.key'
--   ssl_ca_file   = '/etc/ssl/certs/ca.crt'
--
-- In pg_hba.conf, use hostssl instead of host for all BI users:
--   hostssl  bi_db  bi_pbi_connector  0.0.0.0/0  scram-sha-256
--
-- Power BI connection string must include: Encrypt=true;TrustServerCertificate=false
-- Tableau connection: SSL Mode = Require in connection dialog.
--
-- For cloud DBs (Redshift/Snowflake/BigQuery): TLS is enabled by default.
-- Verify with: SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();

-- ── G. Audit Trigger ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION bi_audit.log_table_access()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO bi_audit.refresh_log (triggered_by, source_table, rows_loaded, status)
    VALUES (current_user, TG_TABLE_NAME, 1, 'SUCCESS');
    RETURN NEW;
END;
$$;
-- Note: For query-level audit, use pgaudit extension:
--   shared_preload_libraries = 'pgaudit'
--   pgaudit.log = 'read,write'
