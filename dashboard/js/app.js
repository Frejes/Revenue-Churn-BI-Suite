let months = [];
let mrrData = [];
let churnData = [];
let alertData = [];
let riskAccounts = [];
let currentRole = 'Admin';
let charts = {};

const { fmtMonth, pct, money, latestMonth } = window.dashboardFmt;

function fmt(n) {
  return money(n);
}

function num(n, digits) {
  if (n == null || Number.isNaN(Number(n))) {
    return '—';
  }
  return Number(n).toLocaleString(undefined, {
    maximumFractionDigits: digits ?? 0,
  });
}

function getData() {
  return window.dashboardData;
}

function hydrateFromSupabase() {
  const d = getData();
  months = d.mrrMonthly.map((row) => fmtMonth(row.month));
  mrrData = d.mrrMonthly.map((row) => Number(row.mrr));
  churnData = d.mrrMonthly.map((row) => Number(row.churn_rate) * 100);

  alertData = d.alerts
    .filter((row) => row.churn_spike_flag || row.revenue_drop_flag)
    .slice(0, 12)
    .map((row) => {
      if (row.churn_spike_flag) {
        return {
          region: row.region,
          month: fmtMonth(row.date_key),
          type: 'CHURN_SPIKE',
          value: Number((Number(row.churn_rate) * 100).toFixed(2)),
          label: 'Churn rate',
          unit: '%',
        };
      }
      return {
        region: row.region,
        month: fmtMonth(row.date_key),
        type: 'REVENUE_DROP',
        value: Number(row.mrr_change_pct),
        label: 'MRR change',
        unit: '%',
      };
    });

  riskAccounts = d.accountsAtRisk.slice(0, 15).map((row) => ({
    id: row.customer_id,
    region: row.region,
    plan: row.plan_name,
    risk: Math.round(Number(row.churn_risk_score)),
    tier: row.risk_tier,
    fp: Number(row.failed_payments),
    tickets: Number(row.support_tickets),
    usage: Number(row.usage_score),
    mrr: Number(row.monthly_revenue),
  }));
}

function updateOverviewKpis() {
  const d = getData();
  const rows = d.mrrMonthly;
  if (!rows.length) {
    return;
  }

  const latest = rows[rows.length - 1];
  const prev = rows.length > 1 ? rows[rows.length - 2] : null;
  const highRisk = d.accountsAtRisk.filter(
    (row) => Number(row.churn_risk_score) >= 70
  ).length;

  const mrrDelta = prev
    ? ((Number(latest.mrr) - Number(prev.mrr)) / Number(prev.mrr)) * 100
    : null;
  const custDelta = prev
    ? ((Number(latest.active_customers) - Number(prev.active_customers)) /
        Number(prev.active_customers)) *
      100
    : null;
  const retDelta = prev
    ? (Number(latest.retention_rate) - Number(prev.retention_rate)) * 100
    : null;

  document.getElementById('kpi-mrr').textContent = money(latest.mrr);
  document.querySelector('#page-overview .kpi:nth-child(1) .kpi-label').textContent =
    `MRR (${fmtMonth(latest.month)})`;
  document.querySelector('#page-overview .kpi:nth-child(1) .kpi-delta').innerHTML =
    mrrDelta == null
      ? ''
      : `${mrrDelta < 0 ? '↓' : '↑'} ${mrrDelta < 0 ? '−' : '+'}${Math.abs(mrrDelta).toFixed(1)}% vs prior month`;
  document.querySelector('#page-overview .kpi:nth-child(1) .kpi-delta').className =
    `kpi-delta ${mrrDelta < 0 ? 'delta-dn' : 'delta-up'}`;

  document.querySelector('#page-overview .kpi:nth-child(2) .kpi-val').textContent =
    money(latest.arr);
  document.querySelector('#page-overview .kpi:nth-child(3) .kpi-val').textContent =
    num(latest.active_customers);
  document.querySelector('#page-overview .kpi:nth-child(3) .kpi-delta').innerHTML =
    custDelta == null
      ? ''
      : `${custDelta < 0 ? '↓' : '↑'} ${custDelta < 0 ? '−' : '+'}${Math.abs(custDelta).toFixed(1)}% vs prior month`;
  document.querySelector('#page-overview .kpi:nth-child(3) .kpi-delta').className =
    `kpi-delta ${custDelta < 0 ? 'delta-dn' : 'delta-up'}`;

  document.querySelector('#page-overview .kpi:nth-child(4) .kpi-val').textContent =
    pct(latest.churn_rate, 1);
  document.querySelector('#page-overview .kpi:nth-child(4) .kpi-sub').textContent =
    `${fmtMonth(latest.month)} monthly`;

  document.querySelector('#page-overview .kpi:nth-child(5) .kpi-val').textContent =
    pct(latest.retention_rate, 1);
  document.querySelector('#page-overview .kpi:nth-child(5) .kpi-delta').innerHTML =
    retDelta == null
      ? ''
      : `${retDelta >= 0 ? '↑' : '↓'} ${retDelta >= 0 ? '+' : '−'}${Math.abs(retDelta).toFixed(1)}pp vs prior month`;
  document.querySelector('#page-overview .kpi:nth-child(5) .kpi-delta').className =
    `kpi-delta ${retDelta >= 0 ? 'delta-up' : 'delta-dn'}`;

  document.querySelector('#page-overview .kpi:nth-child(6) .kpi-val').textContent =
    money(latest.arpu);
  document.querySelector('#page-overview .kpi:nth-child(7) .kpi-val').textContent =
    money(latest.ltv_proxy);
  document.querySelector('#page-overview .kpi:nth-child(8) .kpi-val').textContent =
    String(highRisk);
}

function updateRiskKpis() {
  const d = getData();
  const high = d.accountsAtRisk.filter((r) => r.risk_tier === 'HIGH').length;
  const med = d.accountsAtRisk.filter((r) => r.risk_tier === 'MEDIUM').length;
  const low = d.accountsAtRisk.filter((r) => r.risk_tier === 'LOW').length;

  document.querySelector('#page-risk .kpi:nth-child(1) .kpi-val').textContent =
    String(high);
  document.querySelector('#page-risk .kpi:nth-child(2) .kpi-val').textContent =
    String(med);
  document.querySelector('#page-risk .kpi:nth-child(3) .kpi-val').textContent =
    String(low);
}

function planMixLatest() {
  const d = getData();
  const month = latestMonth(d.revenueMix, 'month');
  const rows = d.revenueMix.filter((row) => String(row.month) === String(month));
  const totals = rows.reduce((acc, row) => {
    acc[row.plan_type] = (acc[row.plan_type] || 0) + Number(row.mrr);
    return acc;
  }, {});
  const totalMrr = Object.values(totals).reduce((sum, value) => sum + value, 0);
  const palette = {
    'Enterprise Plus': '#3C3489',
    Enterprise: '#534AB7',
    Growth: '#7F77DD',
    Starter: '#AFA9EC',
  };
  const labels = Object.keys(totals).sort((a, b) => totals[b] - totals[a]);
  const data = labels.map((label) =>
    totalMrr ? Math.round((totals[label] / totalMrr) * 100) : 0
  );
  const colors = labels.map((label) => palette[label] || '#534AB7');
  const legend = document.querySelector('#page-overview .donut-legend');
  if (legend) {
    legend.innerHTML = labels
      .map(
        (label, index) =>
          `<div class="legend-row"><span class="legend-swatch" style="background:${colors[index]}"></span>${label} — ${data[index]}%</div>`
      )
      .join('');
  }
  return { labels, data, colors };
}

function regionMixLatest() {
  const d = getData();
  const month = latestMonth(d.revenueMix, 'month');
  const rows = d.revenueMix.filter((row) => String(row.month) === String(month));
  const totals = rows.reduce((acc, row) => {
    acc[row.region] = (acc[row.region] || 0) + Number(row.mrr);
    return acc;
  }, {});
  const labels = Object.keys(totals).sort((a, b) => totals[b] - totals[a]);
  const data = labels.map((label) => totals[label]);
  const short = {
    'North America': 'N. America',
    EMEA: 'EMEA',
    APAC: 'APAC',
    LATAM: 'LATAM',
  };
  return {
    labels: labels.map((label) => short[label] || label),
    data,
    colors: ['#534AB7', '#1D9E75', '#378ADD', '#D85A30'],
  };
}

function drilldownSegmentStack() {
  const d = getData();
  const month = latestMonth(d.revenueDrilldown, 'month');
  const rows = d.revenueDrilldown.filter(
    (row) => String(row.month) === String(month)
  );
  const regions = [...new Set(rows.map((row) => row.region))].sort();
  const segments = ['SMB', 'Mid-Market', 'Enterprise'];
  const colors = {
    SMB: '#AFA9EC',
    'Mid-Market': '#534AB7',
    Enterprise: '#3C3489',
  };
  const datasets = segments.map((segment) => ({
    label: segment,
    data: regions.map((region) =>
      rows
        .filter((row) => row.region === region && row.segment === segment)
        .reduce((sum, row) => sum + Number(row.mrr), 0)
    ),
    backgroundColor: colors[segment],
  }));
  return { labels: regions, datasets };
}

function drilldownChurnByRegion() {
  const d = getData();
  const month = latestMonth(d.revenueDrilldown, 'month');
  const rows = d.revenueDrilldown.filter(
    (row) => String(row.month) === String(month)
  );
  const byRegion = rows.reduce((acc, row) => {
    if (!acc[row.region]) {
      acc[row.region] = { churn: 0, count: 0 };
    }
    acc[row.region].churn += Number(row.churn_rate);
    acc[row.region].count += 1;
    return acc;
  }, {});
  const labels = Object.keys(byRegion);
  const data = labels.map((region) =>
    Number(
      ((byRegion[region].churn / byRegion[region].count) * 100).toFixed(2)
    )
  );
  return {
    labels,
    data,
    colors: data.map((value) =>
      value >= 6 ? '#E24B4A' : value >= 5 ? '#EF9F27' : '#639922'
    ),
  };
}

function riskDriverBreakdown() {
  const high = getData().accountsAtRisk.filter((row) => row.risk_tier === 'HIGH');
  const lowUsage = high.filter((row) => Number(row.usage_score) < 0.3).length;
  const failedPay = high.filter((row) => Number(row.failed_payments) > 0).length;
  const tickets = high.filter((row) => Number(row.support_tickets) >= 4).length;
  const total = Math.max(high.length, 1);
  return [
    Math.round((lowUsage / total) * 100),
    Math.round((failedPay / total) * 100),
    Math.round((tickets / total) * 100),
  ];
}

function riskBySegment() {
  const high = getData().accountsAtRisk.filter((row) => row.risk_tier === 'HIGH');
  const totals = high.reduce((acc, row) => {
    acc[row.segment] = (acc[row.segment] || 0) + 1;
    return acc;
  }, {});
  const labels = Object.keys(totals);
  const data = labels.map((label) => totals[label]);
  const total = data.reduce((sum, value) => sum + value, 0) || 1;
  const legend = document.querySelector('#page-risk .donut-legend');
  if (legend) {
    const colors = { SMB: '#E24B4A', 'Mid-Market': '#EF9F27', Enterprise: '#639922' };
    legend.innerHTML = labels
      .map((label) => {
        const share = Math.round((totals[label] / total) * 100);
        return `<div class="legend-row"><span class="legend-swatch" style="background:${colors[label] || '#534AB7'}"></span>${label} — ${share}%</div>`;
      })
      .join('');
  }
  return {
    labels,
    data,
    colors: ['#E24B4A', '#EF9F27', '#639922'],
  };
}

function riskByRegion() {
  const d = getData();
  const regions = [...new Set(d.accountsAtRisk.map((row) => row.region))].sort();
  const high = regions.map(
    (region) =>
      d.accountsAtRisk.filter(
        (row) => row.region === region && row.risk_tier === 'HIGH'
      ).length
  );
  const med = regions.map(
    (region) =>
      d.accountsAtRisk.filter(
        (row) => row.region === region && row.risk_tier === 'MEDIUM'
      ).length
  );
  return { labels: regions, high, med };
}

function buildImpactTable() {
  const d = getData();
  const grouped = d.revenueDrilldown.reduce((acc, row) => {
    const key = `${row.plan_name}|${row.channel}`;
    if (!acc[key]) {
      acc[key] = {
        plan: row.plan_name,
        channel: row.channel,
        mrr: 0,
        customers: 0,
        churn: 0,
        churnCount: 0,
        usage: 0,
        usageCount: 0,
      };
    }
    acc[key].mrr += Number(row.mrr);
    acc[key].customers += Number(row.active_customers);
    acc[key].churn += Number(row.churn_rate);
    acc[key].churnCount += 1;
    acc[key].usage += Number(row.avg_usage_score);
    acc[key].usageCount += 1;
    return acc;
  }, {});

  const rows = Object.values(grouped)
    .sort((a, b) => b.mrr - a.mrr)
    .slice(0, 8);

  document.getElementById('impact-table').innerHTML = rows
    .map((row) => {
      const churn = ((row.churn / row.churnCount) * 100).toFixed(1);
      const usage = (row.usage / row.usageCount).toFixed(2);
      const arpu = row.customers ? row.mrr / row.customers : 0;
      return `<tr>
        <td>${row.plan}</td><td>${row.channel}</td><td>${money(row.mrr)}</td>
        <td>${num(row.customers)}</td><td>${churn}%</td><td>${money(arpu)}</td><td>${usage}</td>
      </tr>`;
    })
    .join('');
}

function buildAuditLog() {
  const container = document.getElementById('audit-log-card');
  if (!container) {
    return;
  }
  const rows = getData().refreshLog;
  if (!rows.length) {
    container.innerHTML =
      '<div class="audit-row"><span>No refresh log entries yet</span></div>';
    return;
  }
  container.innerHTML =
    rows
      .map((row) => {
        const dot =
          row.status === 'SUCCESS'
            ? 'dot-ok'
            : row.status === 'FAILED'
              ? 'dot-fail'
              : 'dot-warn';
        const detail =
          row.status === 'SUCCESS'
            ? `${num(row.rows_loaded)} rows`
            : row.error_message || row.status;
        const color =
          row.status === 'SUCCESS'
            ? 'var(--color-text-success)'
            : row.status === 'FAILED'
              ? 'var(--color-text-danger)'
              : 'var(--color-text-warning)';
        const ts = new Date(row.run_ts).toISOString().replace('T', ' ').slice(0, 16);
        return `<div class="audit-row"><span><span class="status-dot ${dot}"></span>${row.source_table}</span><span style="color:var(--color-text-secondary)">${ts} UTC</span><span style="color:${color};font-size:12px">${detail}</span></div>`;
      })
      .join('') +
    '<div style="margin-top:10px;font-size:11px;color:var(--color-text-tertiary)">ℹ Logs retained 90 days · Schedule: 03:00 UTC daily via pg_cron</div>';
}

function makeChart(id, cfg) {
  const el = document.getElementById(id);
  if (!el) {
    return;
  }
  if (charts[id]) {
    charts[id].destroy();
  }
  charts[id] = new Chart(el, cfg);
}

function initCharts() {
  const plan = planMixLatest();
  const region = regionMixLatest();
  const drillRev = drilldownSegmentStack();
  const drillChurn = drilldownChurnByRegion();
  const drivers = riskDriverBreakdown();
  const riskSeg = riskBySegment();
  const riskReg = riskByRegion();

  makeChart('mrrChart', {
    type: 'line',
    data: {
      labels: months,
      datasets: [
        {
          label: 'MRR',
          data: mrrData,
          borderColor: '#534AB7',
          backgroundColor: 'rgba(83,74,183,0.08)',
          fill: true,
          tension: 0.4,
          pointRadius: 0,
          borderWidth: 2,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { label: (v) => fmt(v.raw) } },
      },
      scales: {
        x: { ticks: { font: { size: 10 }, maxTicksLimit: 8, autoSkip: true } },
        y: { ticks: { callback: (v) => fmt(v), font: { size: 10 } } },
      },
    },
  });

  makeChart('planChart', {
    type: 'doughnut',
    data: {
      labels: plan.labels,
      datasets: [{ data: plan.data, backgroundColor: plan.colors, borderWidth: 0 }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      cutout: '65%',
    },
  });

  makeChart('churnChart', {
    type: 'bar',
    data: {
      labels: months,
      datasets: [
        {
          label: 'Churn rate %',
          data: churnData,
          backgroundColor: churnData.map((v) =>
            v >= 6 ? '#E24B4A' : v >= 5 ? '#EF9F27' : '#639922'
          ),
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { ticks: { font: { size: 9 }, maxTicksLimit: 8, autoSkip: true } },
        y: { ticks: { callback: (v) => `${v}%`, font: { size: 10 } }, max: 10 },
      },
    },
  });

  makeChart('regionChart', {
    type: 'bar',
    data: {
      labels: region.labels,
      datasets: [
        {
          label: 'Total MRR',
          data: region.data,
          backgroundColor: region.colors,
        },
      ],
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { ticks: { callback: (v) => fmt(v), font: { size: 10 } } },
        y: { ticks: { font: { size: 11 } } },
      },
    },
  });

  makeChart('drillRevChart', {
    type: 'bar',
    data: { labels: drillRev.labels, datasets: drillRev.datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { stacked: true, ticks: { font: { size: 10 } } },
        y: {
          stacked: true,
          ticks: { callback: (v) => fmt(v), font: { size: 10 } },
        },
      },
    },
  });

  makeChart('drillChurnChart', {
    type: 'bar',
    data: {
      labels: drillChurn.labels,
      datasets: [
        {
          label: 'Churn rate',
          data: drillChurn.data,
          backgroundColor: drillChurn.colors,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        y: { ticks: { callback: (v) => `${v}%`, font: { size: 10 } }, max: 8 },
      },
    },
  });

  makeChart('driverChart', {
    type: 'bar',
    data: {
      labels: ['Low usage score', 'Failed payments', 'High support tickets'],
      datasets: [
        {
          label: 'Contribution',
          data: drivers,
          backgroundColor: ['#E24B4A', '#EF9F27', '#534AB7'],
        },
      ],
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { max: 100, ticks: { callback: (v) => `${v}%`, font: { size: 10 } } },
        y: { ticks: { font: { size: 10 } } },
      },
    },
  });

  makeChart('riskSegChart', {
    type: 'doughnut',
    data: {
      labels: riskSeg.labels,
      datasets: [
        {
          data: riskSeg.data,
          backgroundColor: riskSeg.colors,
          borderWidth: 0,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      cutout: '55%',
    },
  });

  makeChart('riskRegChart', {
    type: 'bar',
    data: {
      labels: riskReg.labels,
      datasets: [
        { label: 'High-risk', data: riskReg.high, backgroundColor: '#E24B4A' },
        { label: 'Med-risk', data: riskReg.med, backgroundColor: '#EF9F27' },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: { x: { stacked: true }, y: { stacked: true } },
    },
  });

  buildHeatmap();
  buildRiskTable();
  buildImpactTable();
  buildAuditLog();
  updateOverviewKpis();
  updateRiskKpis();
  evalAlerts();
}

function buildHeatmap() {
  const d = getData();
  const periods = [
    'M0',
    'M1',
    'M2',
    'M3',
    'M4',
    'M5',
    'M6',
    'M7',
    'M8',
    'M9',
    'M10',
    'M11',
  ];
  const byCohort = d.cohortRetention.reduce((acc, row) => {
    const key = String(row.cohort_month);
    if (!acc[key]) {
      acc[key] = {};
    }
    acc[key][Number(row.period_num)] = Math.round(
      Number(row.retention_rate) * 100
    );
    return acc;
  }, {});

  const cohorts = Object.keys(byCohort)
    .sort()
    .filter((_, index, arr) => index % 2 === 0 || arr.length <= 6)
    .slice(-6);

  function color(v) {
    if (v == null) {
      return 'var(--color-background-tertiary)';
    }
    if (v >= 90) {
      return '#EAF3DE';
    }
    if (v >= 80) {
      return '#C0DD97';
    }
    if (v >= 70) {
      return '#97C459';
    }
    if (v >= 60) {
      return '#639922';
    }
    return '#3B6D11';
  }

  function textColor(v) {
    return v != null && v >= 80 ? '#27500A' : '#EAF3DE';
  }

  let html = '<div class="hm-header">';
  periods.forEach((p) => {
    html += `<div class="hm-hdr">${p}</div>`;
  });
  html += '</div>';

  cohorts.forEach((cohort) => {
    html += `<div class="hm-row"><div class="hm-label">${fmtMonth(cohort)}</div>`;
    periods.forEach((_, index) => {
      const value = byCohort[cohort][index] ?? null;
      html += `<div class="hm-cell" style="background:${color(value)};color:${textColor(value)}">${value != null ? value : '—'}</div>`;
    });
    html += '</div>';
  });

  document.getElementById('heatmap-container').innerHTML = html;
}

function buildRiskTable() {
  const role = currentRole;
  const tbody = document.getElementById('risk-table-body');
  tbody.innerHTML = riskAccounts
    .filter((r) => (role === 'Analyst' ? r.region === 'EMEA' : true))
    .map((r) => {
      const barColor =
        r.tier === 'HIGH'
          ? '#E24B4A'
          : r.tier === 'MEDIUM'
            ? '#EF9F27'
            : '#639922';
      const tierClass =
        r.tier === 'HIGH'
          ? 'tier-high'
          : r.tier === 'MEDIUM'
            ? 'tier-med'
            : 'tier-low';
      return `<tr>
      <td style="font-family:var(--font-mono);font-size:11px">${r.id}</td>
      <td>${r.region}</td><td>${r.plan}</td>
      <td><div style="display:flex;align-items:center;gap:6px"><div class="risk-bar-wrap"><div class="risk-bar" style="width:${r.risk}%;background:${barColor}"></div></div>${r.risk}</div></td>
      <td><span class="${tierClass}">${r.tier}</span></td>
      <td>${r.fp}</td><td>${r.tickets}</td><td>${r.usage.toFixed(2)}</td>
      <td>$${r.mrr.toLocaleString()}</td>
    </tr>`;
    })
    .join('');
}

function evalAlerts() {
  const ct = parseFloat(document.getElementById('t-churn').value);
  const rt = parseFloat(document.getElementById('t-rev').value);
  let html = '';
  if (!alertData.length) {
    html =
      '<div class="alert-card alert-ok"><div class="alert-title">No active alert conditions</div><div class="alert-sub">All regions within configured thresholds.</div></div>';
  }
  alertData.forEach((a) => {
    const isTriggered =
      (a.type === 'CHURN_SPIKE' && a.value >= ct) ||
      (a.type === 'REVENUE_DROP' && Math.abs(a.value) >= rt);
    const isCritical =
      (a.type === 'CHURN_SPIKE' && a.value >= ct * 1.3) ||
      (a.type === 'REVENUE_DROP' && Math.abs(a.value) >= rt * 1.5);
    const cls = isTriggered
      ? isCritical
        ? 'alert-critical'
        : 'alert-warning'
      : 'alert-ok';
    const sev = isTriggered ? (isCritical ? 'CRITICAL' : 'WARNING') : 'RESOLVED';
    html += `<div class="alert-card ${cls}">
      <div class="alert-title">${a.type.replace('_', ' ')} — ${a.region} <span style="font-weight:400;font-size:12px;opacity:.7">${a.month}</span></div>
      <div class="alert-sub">${a.label}: ${a.value}${a.unit} · Status: <strong>${sev}</strong> · Threshold: ${a.type === 'CHURN_SPIKE' ? `${ct}%` : `-${rt}%`}</div>
    </div>`;
  });
  document.getElementById('alert-list').innerHTML = html;
}

function setRole(r) {
  currentRole = r;
  document.querySelectorAll('.role-badge').forEach((b) => b.classList.remove('active'));
  document.getElementById(`r-${r}`).classList.add('active');
  document.getElementById('current-role-label').textContent = r;
  const previews = {
    Admin:
      'You are viewing as Admin. Full read access across all regions, segments, and customer rows. You can view audit logs and manage alert thresholds.',
    Analyst:
      'You are viewing as Analyst (EMEA). Row-level security is active — you can only see EMEA region data. Customer-level rows are visible within your partition. Audit logs and alert threshold editing are restricted.',
    Viewer:
      'You are viewing as Viewer. You have access to aggregate views (MRR, ARR, alerts) only. No customer-level rows, no accounts-at-risk data, no audit logs. Suitable for executive dashboards.',
  };
  document.getElementById('role-preview').innerHTML = previews[r];
  buildRiskTable();
  const kpiMrr = document.getElementById('kpi-mrr');
  if (r === 'Analyst') {
    const emeaRows = getData().revenueMix.filter(
      (row) =>
        row.region === 'EMEA' &&
        String(row.month) === String(latestMonth(getData().revenueMix, 'month'))
    );
    const emeaMrr = emeaRows.reduce((sum, row) => sum + Number(row.mrr), 0);
    kpiMrr.textContent = money(emeaMrr);
    kpiMrr.title = 'EMEA region only (RLS preview)';
  } else {
    const latest = getData().mrrMonthly.at(-1);
    kpiMrr.textContent = money(latest?.mrr);
    kpiMrr.title = '';
  }
}

function showPage(id, btn) {
  document.querySelectorAll('.page').forEach((p) => p.classList.remove('active'));
  document.querySelectorAll('.nav-btn').forEach((b) => b.classList.remove('active'));
  document.getElementById(`page-${id}`).classList.add('active');
  btn.classList.add('active');
}

function updateDrilldown() {
  const d = getData();
  const region = document.getElementById('f-region').value;
  const plan = document.getElementById('f-plan').value;
  const segment = document.getElementById('f-segment').value;
  const channel = document.getElementById('f-channel').value;

  let rows = d.revenueDrilldown;
  if (region !== 'All') {
    rows = rows.filter((row) => row.region === region);
  }
  if (plan !== 'All') {
    rows = rows.filter((row) => row.plan_name === plan);
  }
  if (segment !== 'All') {
    rows = rows.filter((row) => row.segment === segment);
  }
  if (channel !== 'All') {
    rows = rows.filter((row) => row.channel === channel);
  }

  const mrr = rows.reduce((sum, row) => sum + Number(row.mrr), 0);
  const customers = rows.reduce(
    (sum, row) => sum + Number(row.active_customers),
    0
  );
  const churn =
    rows.reduce((sum, row) => sum + Number(row.churn_rate), 0) /
    Math.max(rows.length, 1);
  const usage =
    rows.reduce((sum, row) => sum + Number(row.avg_usage_score), 0) /
    Math.max(rows.length, 1);

  document.getElementById('d-mrr').textContent = money(mrr);
  document.getElementById('d-cust').textContent = num(customers);
  document.getElementById('d-churn').textContent = `${(churn * 100).toFixed(1)}%`;
  document.getElementById('d-usage').textContent = usage.toFixed(2);
}

function showError(message) {
  const banner = document.getElementById('data-error');
  if (banner) {
    banner.textContent = message;
    banner.style.display = 'block';
  }
}

async function bootstrap() {
  window.initSupabaseSetup?.();
  try {
    await window.loadDashboardData();
    hydrateFromSupabase();
    initCharts();
    updateDrilldown();
  } catch (err) {
    if (!err.message.includes('Paste your Supabase Publishable key')) {
      showError(
        `${err.message} If views are missing, run data/upload_to_supabase.py to load the database.`
      );
    }
  }
}

window.bootstrapDashboard = bootstrap;

window.setRole = setRole;
window.showPage = showPage;
window.updateDrilldown = updateDrilldown;
window.evalAlerts = evalAlerts;

bootstrap();
