-- Clearbook · Gold: revenue, unit economics, volume bridge, cohorts and chargeback monitoring (all in USD)
--
-- Definitions
--   TPV (total payment volume)  value of successful payments
--   gross revenue               fee_revenue + dispute_fee_revenue (ledger)
--   net revenue                 gross revenue − network costs (what Clearbook keeps)
--   take rate                   net revenue ÷ TPV, in basis points
--   contribution margin         net revenue − operating cost (fraud and risk operations, support, infrastructure: bps of TPV + a fixed cost per payment) − chargeback losses
--   chargeback loss             chargebacks that land after the merchant closed: Clearbook cannot recover them
-- Amounts are converted at the FX rate of the day the money moved.

CREATE OR REFRESH MATERIALIZED VIEW gold_merchant_daily
COMMENT 'One row per merchant and day (USD): payments, TPV, fees, network costs, net revenue, refunds, chargebacks, losses, with the merchant attributes in force that day. The base table for all revenue metrics.'
AS WITH settings AS (
  SELECT max(CASE WHEN setting = 'operating_cost_bps' THEN value END) AS operating_cost_bps,
         max(CASE WHEN setting = 'operating_cost_per_payment_minor_usd' THEN value END) AS operating_cost_per_payment_minor_usd
  FROM ref_pricing_settings),
ledger AS (
  SELECT value_date, merchant_id, currency,
         -sum(CASE WHEN account = 'fee_revenue' THEN amount_minor END) AS fee_minor,
         -sum(CASE WHEN account = 'dispute_fee_revenue' THEN amount_minor END) AS dispute_fee_minor,
         sum(CASE WHEN account = 'network_cost' THEN amount_minor END) AS network_cost_minor
  FROM ledger_entries WHERE account IN ('fee_revenue', 'dispute_fee_revenue', 'network_cost')
  GROUP BY ALL),
pay AS (
  SELECT payment_date AS value_date, merchant_id, currency,
         count_if(status = 'succeeded') AS payments, count_if(status = 'failed') AS declined,
         sum(CASE WHEN status = 'succeeded' THEN amount_minor END) AS tpv_minor
  FROM silver_payments GROUP BY ALL),
ev AS (
  SELECT CAST(e.event_ts AS DATE) AS value_date, e.merchant_id, e.currency,
         sum(CASE WHEN e.event_type = 'refund.succeeded' THEN e.amount_minor END) AS refunds_minor,
         count_if(e.event_type = 'refund.succeeded') AS refunds,
         sum(CASE WHEN e.event_type = 'chargeback.created' THEN e.amount_minor END) AS chargebacks_minor,
         count_if(e.event_type = 'chargeback.created') AS chargebacks
  FROM silver_payment_events e
  WHERE e.event_type IN ('refund.succeeded', 'chargeback.created')
    AND e.payment_id IN (SELECT payment_id FROM silver_payments WHERE status = 'succeeded')
  GROUP BY ALL),
k AS (
  SELECT value_date, merchant_id, currency FROM ledger UNION SELECT value_date, merchant_id, currency FROM pay
  UNION SELECT value_date, merchant_id, currency FROM ev),
first_seen AS (SELECT merchant_id, CAST(min(__START_AT) AS DATE) AS signup_date FROM dim_merchant GROUP BY merchant_id),
closed AS (SELECT merchant_id, CAST(min(__START_AT) AS DATE) AS closed_date FROM dim_merchant WHERE status = 'closed' GROUP BY merchant_id)
SELECT k.value_date, date_trunc('MONTH', k.value_date) AS month, k.merchant_id, m.merchant_name, m.segment, m.plan, m.category,
       m.country, m.risk_tier, k.currency, f.signup_date, date_trunc('MONTH', f.signup_date) AS signup_month, c.closed_date,
       coalesce(p.payments, 0) AS payments, coalesce(p.declined, 0) AS declined,
       coalesce(e.refunds, 0) AS refunds, coalesce(e.chargebacks, 0) AS chargebacks,
       round(coalesce(p.tpv_minor, 0) * fx.usd_per_unit / 100, 2) AS tpv_usd,
       round(coalesce(l.fee_minor, 0) * fx.usd_per_unit / 100, 2) AS fee_revenue_usd,
       round(coalesce(l.dispute_fee_minor, 0) * fx.usd_per_unit / 100, 2) AS dispute_fee_revenue_usd,
       round(coalesce(l.network_cost_minor, 0) * fx.usd_per_unit / 100, 2) AS network_cost_usd,
       round((coalesce(l.fee_minor, 0) + coalesce(l.dispute_fee_minor, 0) - coalesce(l.network_cost_minor, 0)) * fx.usd_per_unit / 100, 2) AS net_revenue_usd,
       round(coalesce(e.refunds_minor, 0) * fx.usd_per_unit / 100, 2) AS refunds_usd,
       round(coalesce(e.chargebacks_minor, 0) * fx.usd_per_unit / 100, 2) AS chargebacks_usd,
       round(CASE WHEN c.closed_date < k.value_date THEN coalesce(e.chargebacks_minor, 0) ELSE 0 END * fx.usd_per_unit / 100, 2) AS chargeback_loss_usd,
       round(coalesce(p.tpv_minor, 0) * fx.usd_per_unit / 100 * s.operating_cost_bps / 10000
             + coalesce(p.payments, 0) * s.operating_cost_per_payment_minor_usd / 100, 2) AS operating_cost_usd
FROM k
CROSS JOIN settings s
LEFT JOIN ledger l USING (value_date, merchant_id, currency)
LEFT JOIN pay p USING (value_date, merchant_id, currency)
LEFT JOIN ev e USING (value_date, merchant_id, currency)
LEFT JOIN first_seen f USING (merchant_id)
LEFT JOIN closed c USING (merchant_id)
LEFT JOIN silver_fx_rates fx ON fx.rate_date = k.value_date AND fx.currency = k.currency
LEFT JOIN dim_merchant m ON m.merchant_id = k.merchant_id
  AND CAST(k.value_date AS TIMESTAMP) >= m.__START_AT AND (m.__END_AT IS NULL OR CAST(k.value_date AS TIMESTAMP) < m.__END_AT);

CREATE OR REFRESH MATERIALIZED VIEW gold_monthly_kpis
COMMENT 'Monthly KPIs overall (segment = All) and by segment: TPV, revenue, take rate (bps), contribution margin, active merchants, approval, refund and chargeback rates.'
AS SELECT month, coalesce(segment, 'All') AS segment,
          count(DISTINCT CASE WHEN payments > 0 THEN merchant_id END) AS active_merchants,
          sum(payments) AS payments, round(sum(tpv_usd), 2) AS tpv_usd,
          round(sum(fee_revenue_usd + dispute_fee_revenue_usd), 2) AS gross_revenue_usd,
          round(sum(network_cost_usd), 2) AS network_cost_usd, round(sum(net_revenue_usd), 2) AS net_revenue_usd,
          round(sum(net_revenue_usd) / nullif(sum(tpv_usd), 0) * 10000, 1) AS take_rate_bps,
          round(sum(net_revenue_usd - operating_cost_usd - chargeback_loss_usd), 2) AS contribution_usd,
          round(sum(net_revenue_usd - operating_cost_usd - chargeback_loss_usd) / nullif(sum(net_revenue_usd), 0) * 100, 1) AS contribution_margin_pct,
          round(sum(tpv_usd) / nullif(sum(payments), 0), 2) AS avg_ticket_usd,
          round(sum(payments) / nullif(sum(payments + declined), 0) * 100, 2) AS approval_rate_pct,
          round(sum(refunds) / nullif(sum(payments), 0) * 100, 2) AS refund_rate_pct,
          round(sum(chargebacks) / nullif(sum(payments), 0) * 100, 3) AS chargeback_rate_pct
FROM gold_merchant_daily
GROUP BY GROUPING SETS ((month), (month, segment));

CREATE OR REFRESH MATERIALIZED VIEW gold_merchant_unit_economics
COMMENT 'Per merchant over the whole period (USD): volume, revenue, take rate, contribution margin and risk – which merchants make or lose money for Clearbook.'
AS SELECT merchant_id, max_by(merchant_name, value_date) AS merchant_name, max_by(segment, value_date) AS segment,
          max_by(plan, value_date) AS plan, max_by(category, value_date) AS category, max_by(country, value_date) AS country,
          max_by(risk_tier, value_date) AS risk_tier, min(signup_date) AS signup_date, max(closed_date) AS closed_date,
          sum(payments) AS payments, round(sum(tpv_usd), 2) AS tpv_usd, round(sum(net_revenue_usd), 2) AS net_revenue_usd,
          round(sum(net_revenue_usd) / nullif(sum(tpv_usd), 0) * 10000, 1) AS take_rate_bps,
          round(sum(operating_cost_usd), 2) AS operating_cost_usd, round(sum(chargeback_loss_usd), 2) AS chargeback_loss_usd,
          round(sum(net_revenue_usd - operating_cost_usd - chargeback_loss_usd), 2) AS contribution_usd,
          round(sum(net_revenue_usd - operating_cost_usd - chargeback_loss_usd) / nullif(sum(net_revenue_usd), 0) * 100, 1) AS contribution_margin_pct,
          round(sum(tpv_usd) / nullif(sum(payments), 0), 2) AS avg_ticket_usd,
          round(sum(refunds) / nullif(sum(payments), 0) * 100, 2) AS refund_rate_pct,
          round(sum(chargebacks) / nullif(sum(payments), 0) * 100, 3) AS chargeback_rate_pct
FROM gold_merchant_daily GROUP BY merchant_id;

-- TPV bridge (an FP&A staple): how volume moved from one month to the next, merchant by merchant.
CREATE OR REFRESH MATERIALIZED VIEW gold_tpv_bridge
COMMENT 'Month-over-month TPV bridge: start TPV + new merchants + expansion − contraction − churn = end TPV (USD).'
AS WITH mm AS (SELECT merchant_id, month, sum(tpv_usd) AS tpv FROM gold_merchant_daily GROUP BY ALL),
months AS (SELECT DISTINCT month FROM mm),
grid AS (SELECT m.month, x.merchant_id FROM months m CROSS JOIN (SELECT DISTINCT merchant_id FROM mm) x),
cur AS (
  SELECT g.month, g.merchant_id, coalesce(c.tpv, 0) AS tpv_now, coalesce(p.tpv, 0) AS tpv_prev
  FROM grid g
  LEFT JOIN mm c ON c.merchant_id = g.merchant_id AND c.month = g.month
  LEFT JOIN mm p ON p.merchant_id = g.merchant_id AND p.month = add_months(g.month, -1)
  WHERE g.month > (SELECT min(month) FROM months))
SELECT month,
       round(sum(tpv_prev), 2) AS start_tpv_usd,
       round(sum(CASE WHEN tpv_prev = 0 AND tpv_now > 0 THEN tpv_now ELSE 0 END), 2) AS new_usd,
       round(sum(CASE WHEN tpv_prev > 0 AND tpv_now > tpv_prev THEN tpv_now - tpv_prev ELSE 0 END), 2) AS expansion_usd,
       round(-sum(CASE WHEN tpv_prev > 0 AND tpv_now > 0 AND tpv_now < tpv_prev THEN tpv_prev - tpv_now ELSE 0 END), 2) AS contraction_usd,
       round(-sum(CASE WHEN tpv_prev > 0 AND tpv_now = 0 THEN tpv_prev ELSE 0 END), 2) AS churn_usd,
       round(sum(tpv_now), 2) AS end_tpv_usd,
       round(sum(CASE WHEN tpv_prev > 0 THEN tpv_now ELSE 0 END) / nullif(sum(tpv_prev), 0) * 100, 1) AS net_volume_retention_pct,
       count_if(tpv_prev = 0 AND tpv_now > 0) AS new_merchants, count_if(tpv_prev > 0 AND tpv_now = 0) AS churned_merchants
FROM cur GROUP BY month;

CREATE OR REFRESH MATERIALIZED VIEW gold_cohorts
COMMENT 'Merchant cohorts by sign-up quarter: active merchants, TPV and net revenue per month (USD).'
AS SELECT concat(year(signup_date), '-Q', quarter(signup_date)) AS signup_quarter, month,
          count(DISTINCT CASE WHEN payments > 0 THEN merchant_id END) AS active_merchants,
          round(sum(tpv_usd), 2) AS tpv_usd, round(sum(net_revenue_usd), 2) AS net_revenue_usd
FROM gold_merchant_daily GROUP BY ALL;

CREATE OR REFRESH MATERIALIZED VIEW gold_chargeback_monitoring
COMMENT 'Merchants by month with chargebacks as % of payments; over_threshold when at or above the card-network monitoring level (ref_pricing_settings) with at least 3 chargebacks.'
AS WITH t AS (SELECT max(CASE WHEN setting = 'chargeback_monitor_bps' THEN value END) / 100.0 AS threshold_pct FROM ref_pricing_settings)
SELECT d.month, d.merchant_id, max_by(d.merchant_name, d.value_date) AS merchant_name, max_by(d.segment, d.value_date) AS segment,
       max_by(d.category, d.value_date) AS category, max_by(d.risk_tier, d.value_date) AS risk_tier,
       sum(d.payments) AS payments, sum(d.chargebacks) AS chargebacks, round(sum(d.chargebacks_usd), 2) AS chargebacks_usd,
       round(sum(d.chargebacks) / nullif(sum(d.payments), 0) * 100, 2) AS chargeback_rate_pct, max(t.threshold_pct) AS threshold_pct,
       sum(d.chargebacks) >= 3 AND sum(d.chargebacks) / nullif(sum(d.payments), 0) * 100 >= max(t.threshold_pct) AS over_threshold
FROM gold_merchant_daily d CROSS JOIN t
GROUP BY d.month, d.merchant_id;
