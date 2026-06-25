(function () {
  'use strict';

  const VIEWS = [
    'v_mrr_monthly',
    'v_revenue_mix',
    'v_revenue_drilldown',
    'v_cohort_retention',
    'v_accounts_at_risk',
    'v_alerts',
    'v_refresh_log',
    'v_health_signals',
  ];

  window.dashboardData = {
    source: 'loading',
    error: null,
    mrrMonthly: [],
    revenueMix: [],
    revenueDrilldown: [],
    cohortRetention: [],
    accountsAtRisk: [],
    alerts: [],
    refreshLog: [],
    healthSignals: [],
  };

  function getEffectiveConfig() {
    const cfg = {
      url: window.SUPABASE_CONFIG?.url,
      anonKey: window.SUPABASE_CONFIG?.anonKey,
    };
    const saved = localStorage.getItem('supabase_anon_key');
    if (saved && (!cfg.anonKey || cfg.anonKey.includes('YOUR_'))) {
      cfg.anonKey = saved;
    }
    return cfg;
  }

  function isConfigReady() {
    const cfg = getEffectiveConfig();
    return Boolean(
      cfg.url &&
        cfg.anonKey &&
        !cfg.anonKey.includes('YOUR_') &&
        cfg.anonKey.length > 20
    );
  }

  function showSetupPanel() {
    const panel = document.getElementById('setup-panel');
    if (panel) {
      panel.style.display = 'block';
    }
    const saved = localStorage.getItem('supabase_anon_key');
    const input = document.getElementById('setup-anon-key');
    if (input && saved) {
      input.value = saved;
    }
  }

  function hideSetupPanel() {
    const panel = document.getElementById('setup-panel');
    if (panel) {
      panel.style.display = 'none';
    }
  }

  window.initSupabaseSetup = function initSupabaseSetup() {
    const btn = document.getElementById('setup-save-btn');
    const input = document.getElementById('setup-anon-key');
    if (!btn || !input) {
      return;
    }
    btn.addEventListener('click', async () => {
      const key = input.value.trim();
      if (!key || key.length < 20) {
        alert('Paste your full Publishable key from Supabase API Keys.');
        return;
      }
      localStorage.setItem('supabase_anon_key', key);
      hideSetupPanel();
      document.getElementById('data-error').style.display = 'none';
      if (window.bootstrapDashboard) {
        await window.bootstrapDashboard();
      }
    });
  };

  async function fetchView(supabase, view, options) {
    let query = supabase.from(view).select('*');
    if (options?.order) {
      for (const [column, ascending] of options.order) {
        query = query.order(column, { ascending });
      }
    }
    if (options?.limit) {
      query = query.limit(options.limit);
    }
    const { data, error } = await query;
    if (error) {
      if (error.code === 'PGRST205' || error.message?.includes('schema cache')) {
        throw new Error(
          `${view} not found. Run sql/00_setup_all.sql in Supabase SQL Editor, then: python data/seed_via_rest.py`
        );
      }
      throw new Error(`${view}: ${error.message}`);
    }
    return data || [];
  }

  function fmtMonth(value) {
    const date = new Date(String(value).slice(0, 10) + 'T00:00:00');
    if (Number.isNaN(date.getTime())) {
      return String(value);
    }
    const month = date.toLocaleDateString('en-US', { month: 'short' });
    const year = String(date.getFullYear()).slice(-2);
    return `${month} ${year}`;
  }

  function pct(value, digits) {
    if (value == null || Number.isNaN(Number(value))) {
      return '—';
    }
    return `${(Number(value) * 100).toFixed(digits ?? 1)}%`;
  }

  function money(value) {
    const n = Number(value);
    if (Number.isNaN(n)) {
      return '—';
    }
    if (n >= 1e6) {
      return `$${(n / 1e6).toFixed(2)}M`;
    }
    if (n >= 1e3) {
      return `$${Math.round(n / 1e3)}K`;
    }
    return `$${Math.round(n)}`;
  }

  function latestMonth(rows, field) {
    if (!rows.length) {
      return null;
    }
    return rows.reduce((max, row) => {
      const value = String(row[field]);
      return !max || value > max ? value : max;
    }, null);
  }

  function setStatus(state, message) {
    const badge = document.getElementById('conn-status');
    if (!badge) {
      return;
    }
    badge.textContent = message;
    badge.className = `conn-badge conn-${state}`;
  }

  window.loadDashboardData = async function loadDashboardData() {
    setStatus('loading', 'Connecting…');

    if (!isConfigReady()) {
      window.dashboardData.source = 'error';
      window.dashboardData.error =
        'Paste your Supabase Publishable key below to connect.';
      setStatus('error', 'Not configured');
      showSetupPanel();
      throw new Error(window.dashboardData.error);
    }

    hideSetupPanel();

    if (!window.supabase?.createClient) {
      window.dashboardData.source = 'error';
      window.dashboardData.error = 'Supabase client failed to load';
      setStatus('error', 'Client error');
      throw new Error(window.dashboardData.error);
    }

    const cfg = getEffectiveConfig();
    const supabase = window.supabase.createClient(cfg.url, cfg.anonKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    try {
      const [
        mrrMonthly,
        revenueMix,
        revenueDrilldown,
        cohortRetention,
        accountsAtRisk,
        alerts,
        refreshLog,
        healthSignals,
      ] = await Promise.all([
        fetchView(supabase, 'v_mrr_monthly', {
          order: [['month', true]],
        }),
        fetchView(supabase, 'v_revenue_mix', {
          order: [['month', true]],
        }),
        fetchView(supabase, 'v_revenue_drilldown', {
          order: [['month', true]],
        }),
        fetchView(supabase, 'v_cohort_retention', {
          order: [
            ['cohort_month', true],
            ['period_num', true],
          ],
        }),
        fetchView(supabase, 'v_accounts_at_risk', {
          order: [['churn_risk_score', false]],
        }),
        fetchView(supabase, 'v_alerts', {
          order: [['date_key', false]],
        }),
        fetchView(supabase, 'v_refresh_log', {
          order: [['run_ts', false]],
          limit: 10,
        }),
        fetchView(supabase, 'v_health_signals', {
          order: [['month', true]],
        }),
      ]);

      window.dashboardData = {
        source: 'supabase',
        error: null,
        mrrMonthly,
        revenueMix,
        revenueDrilldown,
        cohortRetention,
        accountsAtRisk,
        alerts,
        refreshLog,
        healthSignals,
      };

      setStatus('ok', 'Live · Supabase');
      return window.dashboardData;
    } catch (err) {
      window.dashboardData.source = 'error';
      window.dashboardData.error = err.message;
      setStatus('error', 'Connection failed');
      throw err;
    }
  };

  window.dashboardFmt = { fmtMonth, pct, money, latestMonth };
})();
