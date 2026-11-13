-- Clearbook · Bank reconciliation
-- What the ledger says each merchant should be paid (the day's net movement on merchant_payable, due T+2 business days)
-- against what the bank's settlement file says was paid. Every expected payout and every bank row ends up with a status:
--   matched            one bank payment, right amount, on the due date
--   paid_late          right amount, after the due date
--   amount_mismatch    bank amount differs from the ledger
--   duplicate_payout   the bank paid it more than once
--   missing_payout     due on or before the latest bank file, but not paid
--   unexpected_payout  the bank paid something the ledger does not expect
--   not_yet_due        due after the latest bank file – nothing to check yet

CREATE OR REFRESH MATERIALIZED VIEW silver_bank_payouts
COMMENT 'Bank payouts as delivered, with the date of the settlement file each one arrived in (paid_date). Duplicates kept on purpose.'
AS SELECT payout_id, merchant_id, value_date, currency, amount_minor, bank_reference,
          CAST(regexp_extract(_source_file, 'settlements/([0-9-]+)\\.csv', 1) AS DATE) AS paid_date, _source_file
FROM bronze_bank_payouts;

CREATE OR REFRESH MATERIALIZED VIEW expected_payouts
COMMENT 'Payout the ledger expects per merchant, value date and currency: net credit to merchant_payable that day, due T+2 business days.'
AS SELECT l.merchant_id, l.value_date, l.currency, -sum(l.amount_minor) AS expected_minor, min(due.cal_date) AS due_date
FROM ledger_entries l
JOIN ref_calendar c ON c.cal_date = l.value_date
JOIN ref_calendar due ON due.is_business_day AND due.bd_index = c.bd_index + 2
WHERE l.account = 'merchant_payable'
GROUP BY l.merchant_id, l.value_date, l.currency
HAVING sum(l.amount_minor) <> 0;

CREATE OR REFRESH MATERIALIZED VIEW recon_payouts
COMMENT 'Bank reconciliation: one row per merchant, value date and currency, with the expected and paid amounts, dates and a status.'
AS WITH bank AS (
  SELECT merchant_id, value_date, currency, count(*) AS bank_rows, sum(amount_minor) AS paid_minor,
         max(amount_minor) AS bank_amount_minor, min(paid_date) AS paid_date, concat_ws(', ', collect_list(bank_reference)) AS bank_references
  FROM silver_bank_payouts GROUP BY merchant_id, value_date, currency),
latest AS (SELECT max(paid_date) AS latest_file_date FROM silver_bank_payouts)
SELECT coalesce(e.merchant_id, b.merchant_id) AS merchant_id, coalesce(e.value_date, b.value_date) AS value_date,
       coalesce(e.currency, b.currency) AS currency, e.expected_minor, b.paid_minor, b.bank_rows, e.due_date, b.paid_date,
       b.bank_references, coalesce(b.paid_minor, 0) - coalesce(e.expected_minor, 0) AS difference_minor,
       datediff(b.paid_date, e.due_date) AS days_late, latest.latest_file_date,
       CASE
         WHEN e.merchant_id IS NULL THEN 'unexpected_payout'
         WHEN b.merchant_id IS NULL AND e.due_date > latest.latest_file_date THEN 'not_yet_due'
         WHEN b.merchant_id IS NULL THEN 'missing_payout'
         WHEN b.bank_rows > 1 THEN 'duplicate_payout'
         WHEN b.bank_amount_minor <> e.expected_minor THEN 'amount_mismatch'
         WHEN b.paid_date > e.due_date THEN 'paid_late'
         ELSE 'matched' END AS status
FROM expected_payouts e
FULL OUTER JOIN bank b ON b.merchant_id = e.merchant_id AND b.value_date = e.value_date AND b.currency = e.currency
CROSS JOIN latest;

CREATE OR REFRESH MATERIALIZED VIEW recon_breaks
COMMENT 'Open reconciliation breaks (everything except matched and not_yet_due), with merchant details and the amount at stake in USD.'
AS SELECT r.*, m.merchant_name, m.segment, datediff(r.latest_file_date, r.due_date) AS age_days,
          round(abs(r.difference_minor) * fx.usd_per_unit / 100, 2) AS difference_usd
FROM recon_payouts r
LEFT JOIN dim_merchant m ON m.merchant_id = r.merchant_id AND m.__END_AT IS NULL
LEFT JOIN silver_fx_rates fx ON fx.rate_date = r.value_date AND fx.currency = r.currency
WHERE r.status NOT IN ('matched', 'not_yet_due');
