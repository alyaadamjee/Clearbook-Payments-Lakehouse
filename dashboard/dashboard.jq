# Clearbook dashboard (Databricks AI/BI). Build: scripts/build_dashboard.sh -> dashboard/clearbook.lvdash.json
# Table names are unqualified; the bundle sets catalog and schema (resources/dashboard.yml).
# Every query starts with a version comment: bump it to make a published dashboard re-run its queries.

def lines($s): [$s | split("\n")[] | . + "\n"];
def q_lines($s): ["-- clearbook dashboard, queries v1\n"] + lines($s);
def fld($n; $e): {name: $n, expression: $e};
def q($ds; $fields): [{name: "main_query", query: {datasetName: $ds, fields: $fields, disaggregated: false}}];
def raw($ds; $cols): [{name: "main_query", query: {datasetName: $ds, fields: [$cols[] | fld(.f; "`\(.f)`")], disaggregated: true}}];
def titled($t; $d): {showTitle: true, title: {value: $t, fields: []}, showDescription: true, description: $d};
def title($t): {showTitle: true, title: {value: $t, fields: []}};
def usd: {type: "number-currency", currencyCode: "USD", abbreviation: "compact", decimalPlaces: {type: "max", places: 1}};
def usd2: {type: "number-currency", currencyCode: "USD", abbreviation: "none", decimalPlaces: {type: "max", places: 0}};
def num1: {type: "number-plain", abbreviation: "none", decimalPlaces: {type: "max", places: 1}};
def int: {type: "number-plain", abbreviation: "compact", decimalPlaces: {type: "max", places: 0}};
def seg_colors: {type: "categorical", mappings: [{value: "SMB", color: "#4c9f8a"}, {value: "Mid-market", color: "#2f5d8c"}, {value: "Enterprise", color: "#d08a3c"}]};
def basis_colors: {type: "categorical", mappings: [{value: "actual", color: "#2f5d8c"}, {value: "forecast", color: "#9db8d6"}]};
def bridge_colors: {type: "categorical", mappings: [{value: "New merchants", color: "#4c9f8a"}, {value: "Expansion", color: "#8cc6a4"},
  {value: "Contraction", color: "#e0a458"}, {value: "Churn", color: "#c8553d"}]};
def recon_colors: {type: "categorical", mappings: [{value: "matched", color: "#4c9f8a"}, {value: "not_yet_due", color: "#b8c1cc"},
  {value: "paid_late", color: "#e0a458"}, {value: "amount_mismatch", color: "#d08a3c"}, {value: "duplicate_payout", color: "#9b5de5"},
  {value: "missing_payout", color: "#c8553d"}, {value: "unexpected_payout", color: "#6c757d"}]};
def text($name; $s; $pos): {widget: {name: $name, multilineTextboxSpec: {lines: lines($s)}}, position: $pos};
def kpi($name; $t; $d; $ds; $field; $fmt; $x): {widget: {name: $name, queries: q($ds; [fld("v"; "SUM(`\($field)`)")]),
  spec: {version: 2, widgetType: "counter", frame: titled($t; $d), encodings: {value: {fieldName: "v", format: $fmt}}}},
  position: {x: $x, y: 2, width: 2, height: 3}};
def table($name; $t; $d; $ds; $cols; $pos): {widget: {name: $name, queries: raw($ds; $cols),
  spec: {version: 2, widgetType: "table", frame: titled($t; $d),
         encodings: {columns: [$cols[] | {fieldName: .f, displayName: .t} + (if .fmt then {format: .fmt} else {} end)]}}}, position: $pos};
def bar($name; $t; $d; $ds; $x; $xt; $y; $yt; $agg; $color; $ct; $scale; $fmt; $pos): {widget: {name: $name,
  queries: q($ds; [fld($x; "`\($x)`"), fld($color; "`\($color)`"), fld("\($agg)(\($y))"; "\($agg)(`\($y)`)")]),
  spec: {version: 3, widgetType: "bar", frame: titled($t; $d), mark: {layout: "stack"},
         encodings: {x: {fieldName: $x, displayName: $xt, scale: {type: (if $x == "month" then "temporal" else "categorical" end)}, axis: {hideTitle: true}},
                     y: {fieldName: "\($agg)(\($y))", displayName: $yt, scale: {type: "quantitative"}, format: $fmt, axis: {hideTitle: true}},
                     color: {fieldName: $color, displayName: $ct, scale: $scale}}}}, position: $pos};
def line($name; $t; $d; $ds; $y; $yt; $fmt; $pos): {widget: {name: $name,
  queries: q($ds; [fld("month"; "`month`"), fld("segment"; "`segment`"), fld("avg(\($y))"; "AVG(`\($y)`)")]),
  spec: {version: 3, widgetType: "line", frame: titled($t; $d),
         encodings: {x: {fieldName: "month", displayName: "Month", scale: {type: "temporal"}, axis: {hideTitle: true}},
                     y: {fieldName: "avg(\($y))", displayName: $yt, scale: {type: "quantitative"}, format: $fmt, axis: {hideTitle: true}},
                     color: {fieldName: "segment", displayName: "Segment", scale: seg_colors}}}}, position: $pos};

{
  datasets: [
    {name: "kpi_latest", displayName: "Latest month KPIs", queryLines: q_lines(
"SELECT * FROM gold_monthly_kpis WHERE segment = 'All' AND month = (SELECT max(month) FROM gold_monthly_kpis)")},
    {name: "monthly_segment", displayName: "Monthly KPIs by segment", queryLines: q_lines(
"SELECT month, segment, tpv_usd, net_revenue_usd, take_rate_bps, contribution_usd, contribution_margin_pct, approval_rate_pct,
  refund_rate_pct, chargeback_rate_pct, active_merchants
FROM gold_monthly_kpis WHERE segment <> 'All'")},
    {name: "forecast_all", displayName: "TPV actual and forecast", queryLines: q_lines(
"SELECT month, CASE WHEN basis = 'actual' THEN 'actual' ELSE 'forecast' END AS basis, tpv_usd, tpv_lower_usd, tpv_upper_usd, net_revenue_usd
FROM gold_forecast_monthly WHERE segment = 'All'")},
    {name: "bva", displayName: "Budget vs actual", queryLines: q_lines(
"SELECT month, segment, budget_net_revenue_usd, actual_net_revenue_usd, revenue_variance_usd, revenue_variance_pct, volume_effect_usd,
  rate_effect_usd, budget_tpv_usd, actual_tpv_usd, tpv_variance_pct, budget_take_rate_bps, actual_take_rate_bps
FROM gold_budget_vs_actual")},
    {name: "outlook", displayName: "Q4 outlook", queryLines: q_lines(
"SELECT segment, budget_net_revenue_usd, latest_estimate_net_revenue_usd, revenue_vs_budget_pct, budget_tpv_usd, latest_estimate_tpv_usd,
  tpv_lower_usd, tpv_upper_usd, CASE segment WHEN 'All' THEN 0 WHEN 'SMB' THEN 1 WHEN 'Mid-market' THEN 2 ELSE 3 END AS sort_order
FROM gold_q4_outlook ORDER BY sort_order")},
    {name: "backtest", displayName: "Forecast backtest", queryLines: q_lines(
"SELECT segment, test_month, actual_tpv_usd, forecast_tpv_usd, month_error_pct, daily_mape_pct, days_inside_80pct_range_pct FROM gold_forecast_backtest")},
    {name: "bridge", displayName: "TPV bridge", queryLines: q_lines(
"SELECT month, component, amount_usd FROM (
  SELECT month, stack(4, 'New merchants', new_usd, 'Expansion', expansion_usd, 'Contraction', contraction_usd, 'Churn', churn_usd) AS (component, amount_usd)
  FROM gold_tpv_bridge)")},
    {name: "bridge_table", displayName: "TPV bridge table", queryLines: q_lines(
"SELECT month, start_tpv_usd, new_usd, expansion_usd, contraction_usd, churn_usd, end_tpv_usd, net_volume_retention_pct FROM gold_tpv_bridge ORDER BY month")},
    {name: "unit_econ", displayName: "Merchant unit economics", queryLines: q_lines(
"SELECT merchant_name, merchant_id, segment, plan, category, country, risk_tier, tpv_usd, net_revenue_usd, take_rate_bps, contribution_usd,
  contribution_margin_pct, chargeback_rate_pct FROM gold_merchant_unit_economics ORDER BY contribution_usd")},
    {name: "cohorts", displayName: "Cohorts", queryLines: q_lines(
"SELECT signup_quarter, month, active_merchants, tpv_usd, net_revenue_usd FROM gold_cohorts")},
    {name: "cb_flagged", displayName: "Merchants over the chargeback threshold", queryLines: q_lines(
"SELECT month, merchant_name, segment, category, risk_tier, payments, chargebacks, chargeback_rate_pct, chargebacks_usd
FROM gold_chargeback_monitoring WHERE over_threshold ORDER BY month DESC, chargeback_rate_pct DESC")},
    {name: "recon_status", displayName: "Reconciliation status", queryLines: q_lines(
"SELECT status, count(*) AS payouts FROM recon_payouts GROUP BY status")},
    {name: "breaks", displayName: "Open breaks", queryLines: q_lines(
"SELECT status, merchant_name, merchant_id, value_date, due_date, paid_date, currency, expected_minor / 100 AS expected, paid_minor / 100 AS paid,
  difference_minor / 100 AS difference, difference_usd, age_days, bank_references
FROM recon_breaks ORDER BY age_days DESC, difference_usd DESC")},
    {name: "ledger_check", displayName: "Ledger check", queryLines: q_lines(
"SELECT currency, journals, lines, unbalanced_journals, ledger_total FROM ledger_journal_check")},
    {name: "trial_balance", displayName: "Trial balance", queryLines: q_lines(
"SELECT currency, account, account_type, debits_minor / 100 AS debits, credits_minor / 100 AS credits, net_minor / 100 AS net
FROM ledger_trial_balance ORDER BY currency, account")},
    {name: "dq", displayName: "Data quality", queryLines: q_lines(
"SELECT 'Duplicate events removed' AS item, (SELECT count(*) - count(DISTINCT event_id) FROM bronze_payment_events) AS events
UNION ALL SELECT concat('Quarantined: ', array_join(rules_broken, ', ')), count(*) FROM quarantine_payment_events GROUP BY rules_broken
UNION ALL SELECT 'Refunds / chargebacks for unknown payments (to suspense)', count(*) FROM orphan_events")}
  ],
  pages: [
    {name: "executive", displayName: "Executive", pageType: "PAGE_TYPE_CANVAS", layoutVersion: "GRID_V1", layout: [
      text("header"; "# Clearbook\n**Payments revenue, forecast and reconciliation · simulated data (Jul–Oct 2026, 300 merchants)** · KPIs are for the latest month · TPV = total payment volume, take rate = net revenue ÷ TPV"; {x: 0, y: 0, width: 12, height: 2}),
      kpi("k_tpv"; "TPV"; "Successful payments, latest month"; "kpi_latest"; "tpv_usd"; usd; 0),
      kpi("k_rev"; "Net revenue"; "Fees + dispute fees − network costs"; "kpi_latest"; "net_revenue_usd"; usd; 2),
      kpi("k_take"; "Take rate (bps)"; "Net revenue ÷ TPV"; "kpi_latest"; "take_rate_bps"; num1; 4),
      kpi("k_cm"; "Contribution margin %"; "After operating cost and chargeback losses"; "kpi_latest"; "contribution_margin_pct"; num1; 6),
      kpi("k_merchants"; "Active merchants"; "At least one payment"; "kpi_latest"; "active_merchants"; int; 8),
      kpi("k_approval"; "Approval rate %"; "Successful ÷ attempted payments"; "kpi_latest"; "approval_rate_pct"; num1; 10),
      bar("tpv_forecast"; "TPV: actual and forecast"; "Forecast = trend + weekday + month-start model, next 3 months (range in the table below)"; "forecast_all";
          "month"; "Month"; "tpv_usd"; "TPV"; "SUM"; "basis"; "Basis"; basis_colors; usd; {x: 0, y: 5, width: 6, height: 7}),
      bar("rev_segment"; "Net revenue by segment"; "Enterprise brings volume, SMB brings margin"; "monthly_segment";
          "month"; "Month"; "net_revenue_usd"; "Net revenue"; "SUM"; "segment"; "Segment"; seg_colors; usd; {x: 6, y: 5, width: 6, height: 7}),
      line("take_rate"; "Take rate by segment (bps)"; "Interchange-plus pricing keeps enterprise take rate low"; "monthly_segment"; "take_rate_bps"; "Take rate (bps)"; num1; {x: 0, y: 12, width: 6, height: 6}),
      line("margin"; "Contribution margin by segment (%)"; "Net revenue − operating cost (0.30% of TPV + 10¢ per payment) − chargeback losses"; "monthly_segment"; "contribution_margin_pct"; "Margin %"; num1; {x: 6, y: 12, width: 6, height: 6}),
      table("bva_table"; "Budget vs actual – complete months"; "Revenue variance split: volume effect = TPV gap × budget take rate; rate effect = take-rate gap × actual TPV"; "bva";
            [{f: "month", t: "Month"}, {f: "segment", t: "Segment"}, {f: "budget_net_revenue_usd", t: "Budget revenue", fmt: usd2},
             {f: "actual_net_revenue_usd", t: "Actual revenue", fmt: usd2}, {f: "revenue_variance_usd", t: "Variance", fmt: usd2},
             {f: "revenue_variance_pct", t: "Variance %"}, {f: "volume_effect_usd", t: "Volume effect", fmt: usd2}, {f: "rate_effect_usd", t: "Rate effect", fmt: usd2},
             {f: "tpv_variance_pct", t: "TPV vs budget %"}, {f: "budget_take_rate_bps", t: "Budget take rate"}, {f: "actual_take_rate_bps", t: "Actual take rate"}];
            {x: 0, y: 18, width: 12, height: 5}),
      table("outlook_table"; "Q4 2026 outlook vs budget"; "Latest estimate = October actual + November–December forecast. The budget assumes a holiday uplift (+8% Nov, +12% Dec) the trend model does not include"; "outlook";
            [{f: "segment", t: "Segment"}, {f: "budget_net_revenue_usd", t: "Budget revenue", fmt: usd2}, {f: "latest_estimate_net_revenue_usd", t: "Latest estimate", fmt: usd2},
             {f: "revenue_vs_budget_pct", t: "vs budget %"}, {f: "budget_tpv_usd", t: "Budget TPV", fmt: usd2}, {f: "latest_estimate_tpv_usd", t: "Estimate TPV", fmt: usd2},
             {f: "tpv_lower_usd", t: "TPV low (80%)", fmt: usd2}, {f: "tpv_upper_usd", t: "TPV high (80%)", fmt: usd2}];
            {x: 0, y: 23, width: 7, height: 5}),
      table("backtest_table"; "Forecast backtest"; "Trained on Jul–Sep, forecast October, compared with the actual October"; "backtest";
            [{f: "segment", t: "Segment"}, {f: "actual_tpv_usd", t: "Actual TPV", fmt: usd2}, {f: "forecast_tpv_usd", t: "Forecast TPV", fmt: usd2},
             {f: "month_error_pct", t: "Month error %"}, {f: "daily_mape_pct", t: "Daily error %"}, {f: "days_inside_80pct_range_pct", t: "Days in 80% range %"}];
            {x: 7, y: 23, width: 5, height: 5})
    ]},
    {name: "merchants", displayName: "Merchants", pageType: "PAGE_TYPE_CANVAS", layoutVersion: "GRID_V1", layout: [
      bar("bridge_chart"; "TPV bridge: what moved volume month to month"; "New merchants and expansion add, contraction and churn subtract"; "bridge";
          "month"; "Month"; "amount_usd"; "TPV change"; "SUM"; "component"; "Component"; bridge_colors; usd; {x: 0, y: 0, width: 6, height: 7}),
      table("bridge_tbl"; "TPV bridge"; "Start + new + expansion + contraction + churn = end; net volume retention = existing merchants this month ÷ last month"; "bridge_table";
            [{f: "month", t: "Month"}, {f: "start_tpv_usd", t: "Start", fmt: usd}, {f: "new_usd", t: "New", fmt: usd}, {f: "expansion_usd", t: "Expansion", fmt: usd},
             {f: "contraction_usd", t: "Contraction", fmt: usd}, {f: "churn_usd", t: "Churn", fmt: usd}, {f: "end_tpv_usd", t: "End", fmt: usd},
             {f: "net_volume_retention_pct", t: "Net volume retention %"}];
            {x: 6, y: 0, width: 6, height: 7}),
      bar("cohort_chart"; "TPV by sign-up cohort"; "Merchants grouped by the quarter they joined"; "cohorts";
          "month"; "Month"; "tpv_usd"; "TPV"; "SUM"; "signup_quarter"; "Signed up"; {type: "categorical"}; usd; {x: 0, y: 7, width: 6, height: 7}),
      bar("active_seg"; "Active merchants by segment"; "Merchants with at least one payment in the month"; "monthly_segment";
          "month"; "Month"; "active_merchants"; "Merchants"; "SUM"; "segment"; "Segment"; seg_colors; int; {x: 6, y: 7, width: 6, height: 7}),
      table("unit_tbl"; "Merchant unit economics – least profitable first"; "Whole period. Contribution = net revenue − operating cost − chargeback losses"; "unit_econ";
            [{f: "merchant_name", t: "Merchant"}, {f: "segment", t: "Segment"}, {f: "plan", t: "Plan"}, {f: "category", t: "Category"}, {f: "risk_tier", t: "Risk"},
             {f: "tpv_usd", t: "TPV", fmt: usd2}, {f: "net_revenue_usd", t: "Net revenue", fmt: usd2}, {f: "take_rate_bps", t: "Take rate (bps)"},
             {f: "contribution_usd", t: "Contribution", fmt: usd2}, {f: "contribution_margin_pct", t: "Margin %"}, {f: "chargeback_rate_pct", t: "Chargeback %"}];
            {x: 0, y: 14, width: 12, height: 9})
    ]},
    {name: "risk", displayName: "Risk & reconciliation", pageType: "PAGE_TYPE_CANVAS", layoutVersion: "GRID_V1", layout: [
      line("cb_rate"; "Chargeback rate by segment (%)"; "Chargebacks land 15–60 days after the payment, so July is understated"; "monthly_segment"; "chargeback_rate_pct"; "Chargeback %"; num1; {x: 0, y: 0, width: 6, height: 7}),
      {widget: {name: "recon_chart", queries: q("recon_status"; [fld("status"; "`status`"), fld("sum(payouts)"; "SUM(`payouts`)")]),
         spec: {version: 3, widgetType: "bar", frame: titled("Bank reconciliation"; "Every expected payout matched to the bank file (T+2 business days)"),
                encodings: {x: {fieldName: "sum(payouts)", displayName: "Payouts", scale: {type: "quantitative"}, axis: {hideTitle: true}},
                            y: {fieldName: "status", displayName: "Status", scale: {type: "categorical", sort: {by: "x"}}, axis: {hideTitle: true}},
                            color: {fieldName: "status", displayName: "Status", scale: recon_colors}}}},
       position: {x: 6, y: 0, width: 6, height: 7}},
      table("breaks_tbl"; "Open reconciliation breaks"; "Oldest first. Amounts in the payout currency; difference also in USD"; "breaks";
            [{f: "status", t: "Status"}, {f: "merchant_name", t: "Merchant"}, {f: "value_date", t: "Value date"}, {f: "due_date", t: "Due"}, {f: "paid_date", t: "Paid"},
             {f: "currency", t: "Ccy"}, {f: "expected", t: "Expected"}, {f: "paid", t: "Paid amount"}, {f: "difference", t: "Difference"},
             {f: "difference_usd", t: "Difference USD", fmt: usd2}, {f: "age_days", t: "Age (days)"}];
            {x: 0, y: 7, width: 12, height: 8}),
      table("cb_tbl"; "Merchants over the 1% chargeback threshold"; "At least 3 chargebacks and ≥ 1% of payments in the month"; "cb_flagged";
            [{f: "month", t: "Month"}, {f: "merchant_name", t: "Merchant"}, {f: "segment", t: "Segment"}, {f: "category", t: "Category"}, {f: "risk_tier", t: "Risk"},
             {f: "payments", t: "Payments"}, {f: "chargebacks", t: "Chargebacks"}, {f: "chargeback_rate_pct", t: "Rate %"}, {f: "chargebacks_usd", t: "Amount", fmt: usd2}];
            {x: 0, y: 15, width: 7, height: 8}),
      table("ledger_tbl"; "Ledger integrity"; "Every journal must sum to zero – the pipeline fails otherwise"; "ledger_check";
            [{f: "currency", t: "Ccy"}, {f: "journals", t: "Journals"}, {f: "lines", t: "Lines"}, {f: "unbalanced_journals", t: "Unbalanced"}, {f: "ledger_total", t: "Total"}];
            {x: 7, y: 15, width: 5, height: 4}),
      table("tb_tbl"; "Trial balance"; "Debits − credits by account (major units)"; "trial_balance";
            [{f: "currency", t: "Ccy"}, {f: "account", t: "Account"}, {f: "debits", t: "Debits"}, {f: "credits", t: "Credits"}, {f: "net", t: "Net"}];
            {x: 7, y: 19, width: 5, height: 4})
    ]},
    {name: "data_quality", displayName: "Data quality", pageType: "PAGE_TYPE_CANVAS", layoutVersion: "GRID_V1", layout: [
      text("dq_text"; "### Pipeline checks\nBronze keeps every event as delivered. Silver drops duplicates and rows that fail the expectations (they are kept in `quarantine_payment_events` with the rules they broke), and refunds or chargebacks for unknown payments are parked in the ledger's suspense account instead of touching merchant balances."; {x: 0, y: 0, width: 12, height: 2}),
      table("dq_tbl"; "What the pipeline caught"; "Over all loaded data"; "dq"; [{f: "item", t: "Check"}, {f: "events", t: "Events"}]; {x: 0, y: 2, width: 12, height: 5})
    ]},
    {name: "filters", displayName: "Global Filters", pageType: "PAGE_TYPE_GLOBAL_FILTERS", layoutVersion: "GRID_V1", layout: [
      {widget: {name: "f_segment",
         queries: (["monthly_segment", "bva", "unit_econ", "cb_flagged"] | map({name: "f_segment_\(.)", query: {datasetName: ., fields: [fld("segment"; "`segment`"), fld("segment_associativity"; "COUNT_IF(`associative_filter_predicate_group`)")], disaggregated: false}})),
         spec: {version: 2, widgetType: "filter-multi-select", frame: title("Segment"),
                encodings: {fields: (["monthly_segment", "bva", "unit_econ", "cb_flagged"] | map({fieldName: "segment", queryName: "f_segment_\(.)"}))}}},
       position: {x: 0, y: 0, width: 2, height: 2}}
    ]}
  ]
}
