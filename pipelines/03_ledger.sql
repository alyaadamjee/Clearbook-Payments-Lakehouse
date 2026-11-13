-- Clearbook · Ledger (double-entry)
-- Every money movement becomes ledger lines that add up to zero: debits positive, credits negative, in minor units of the
-- payment's currency. Accounts:
--   settlement_cash      asset      money due from / paid back through the card networks
--   network_cost         expense    interchange + scheme fees Clearbook pays the networks
--   merchant_payable     liability  what Clearbook owes each merchant (paid out by the bank, T+2 business days)
--   fee_revenue          revenue    Clearbook's processing fees
--   dispute_fee_revenue  revenue    fees charged to merchants for chargebacks
--   suspense             asset      refunds / chargebacks for unknown payments, parked until investigated
--
-- Journals per event:
--   payment.succeeded   Dr settlement_cash (amount − network cost), Dr network_cost, Cr merchant_payable (amount − fee), Cr fee_revenue
--   refund.succeeded    Dr merchant_payable, Cr settlement_cash          (fees are not returned)
--   chargeback.created  Dr merchant_payable (amount + dispute fee), Cr settlement_cash, Cr dispute_fee_revenue
--   unknown payment     Dr suspense, Cr settlement_cash                  (merchant balance untouched)
-- Fees use the same integer half-up arithmetic as src/clearbook/pricing.py, from the ref_* tables setup writes.

CREATE OR REFRESH MATERIALIZED VIEW ref_calendar
COMMENT 'Calendar with a running business-day number (Mon–Fri), used to find the T+2 payout date.'
AS SELECT d AS cal_date, dayofweek(d) NOT IN (1, 7) AS is_business_day,
          sum(CASE WHEN dayofweek(d) NOT IN (1, 7) THEN 1 ELSE 0 END) OVER (ORDER BY d) AS bd_index
FROM (SELECT explode(sequence(DATE'2025-01-01', DATE'2027-12-31')) AS d);

CREATE OR REFRESH MATERIALIZED VIEW ledger_entries
COMMENT 'Double-entry ledger: one row per journal line. amount_minor > 0 = debit, < 0 = credit; every journal (journal_id = event_id) sums to zero.'
AS WITH settings AS (
  SELECT max(CASE WHEN setting = 'cross_border_bps' THEN value END) AS cross_border_bps,
         max(CASE WHEN setting = 'dispute_fee_minor' THEN value END) AS dispute_fee_minor
  FROM ref_pricing_settings),
ev AS (
  SELECT e.event_id, e.event_type, e.event_ts, CAST(e.event_ts AS DATE) AS value_date, e.payment_id, e.merchant_id,
         e.amount_minor, e.currency, p.plan, p.card_type, p.cross_border, p.payment_id IS NOT NULL AS known_payment
  FROM silver_payment_events e
  LEFT JOIN silver_payments p ON p.payment_id = e.payment_id AND p.status = 'succeeded'
  WHERE e.event_type <> 'payment.failed'),
priced AS (
  SELECT ev.*, s.dispute_fee_minor,
         CAST(floor((ev.amount_minor * (nc.network_cost_bps + CASE WHEN ev.cross_border THEN s.cross_border_bps ELSE 0 END) + 5000) / 10000) AS BIGINT) AS network_cost_minor,
         CAST(floor((ev.amount_minor * pp.rate_bps + 5000) / 10000) AS BIGINT) + pp.fixed_minor AS base_fee_minor,
         pp.adds_network_cost
  FROM ev CROSS JOIN settings s
  LEFT JOIN ref_network_costs nc ON nc.card_type = ev.card_type
  LEFT JOIN ref_pricing_plans pp ON pp.plan = ev.plan),
lines AS (
  SELECT p.*, explode(CASE
    WHEN event_type = 'payment.succeeded' THEN array(
      named_struct('account', 'settlement_cash', 'amount', amount_minor - network_cost_minor),
      named_struct('account', 'network_cost', 'amount', network_cost_minor),
      named_struct('account', 'merchant_payable', 'amount', -(amount_minor - (base_fee_minor + CASE WHEN adds_network_cost THEN network_cost_minor ELSE 0 END))),
      named_struct('account', 'fee_revenue', 'amount', -(base_fee_minor + CASE WHEN adds_network_cost THEN network_cost_minor ELSE 0 END)))
    WHEN NOT known_payment THEN array(
      named_struct('account', 'suspense', 'amount', amount_minor),
      named_struct('account', 'settlement_cash', 'amount', -amount_minor))
    WHEN event_type = 'refund.succeeded' THEN array(
      named_struct('account', 'merchant_payable', 'amount', amount_minor),
      named_struct('account', 'settlement_cash', 'amount', -amount_minor))
    WHEN event_type = 'chargeback.created' THEN array(
      named_struct('account', 'merchant_payable', 'amount', amount_minor + CAST(dispute_fee_minor AS BIGINT)),
      named_struct('account', 'settlement_cash', 'amount', -amount_minor),
      named_struct('account', 'dispute_fee_revenue', 'amount', -CAST(dispute_fee_minor AS BIGINT)))
  END) AS line
  FROM priced p)
SELECT event_id AS journal_id, event_type, event_ts, value_date, payment_id, merchant_id, currency, line.account,
       CASE line.account WHEN 'settlement_cash' THEN 'asset' WHEN 'suspense' THEN 'asset' WHEN 'network_cost' THEN 'expense'
                         WHEN 'merchant_payable' THEN 'liability' ELSE 'revenue' END AS account_type,
       line.amount AS amount_minor
FROM lines;

-- The ledger must balance: if any journal does not sum to zero, the pipeline update FAILS rather than publishing a broken ledger.
CREATE OR REFRESH MATERIALIZED VIEW ledger_journal_check (
  CONSTRAINT journal_balances EXPECT (unbalanced_journals = 0) ON VIOLATION FAIL UPDATE
)
COMMENT 'Ledger integrity: number of journals that do not sum to zero (must be 0) and the overall total per currency.'
AS SELECT currency, count(*) AS journals, sum(journal_lines) AS lines,
          count_if(journal_total <> 0) AS unbalanced_journals, sum(journal_total) AS ledger_total
FROM (SELECT journal_id, currency, count(*) AS journal_lines, sum(amount_minor) AS journal_total FROM ledger_entries GROUP BY journal_id, currency)
GROUP BY currency;

CREATE OR REFRESH MATERIALIZED VIEW ledger_trial_balance
COMMENT 'Trial balance by account and currency: debits, credits and net (minor units). Net over all accounts is zero.'
AS SELECT currency, account, account_type,
          sum(CASE WHEN amount_minor > 0 THEN amount_minor ELSE 0 END) AS debits_minor,
          -sum(CASE WHEN amount_minor < 0 THEN amount_minor ELSE 0 END) AS credits_minor,
          sum(amount_minor) AS net_minor
FROM ledger_entries GROUP BY ALL;
