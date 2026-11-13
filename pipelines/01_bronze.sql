-- Clearbook · Bronze
-- Raw feeds exactly as delivered, picked up incrementally by Auto Loader (read_files inside a streaming table): each run
-- only reads files it has not seen before. Explicit schemas, with anything that does not fit kept in _rescued_data, plus
-- lineage columns (source file, ingest time).

CREATE OR REFRESH STREAMING TABLE bronze_payment_events
COMMENT 'Payment events as delivered (JSON lines): payment.succeeded / payment.failed / refund.succeeded / chargeback.created. Duplicates and bad rows are kept here on purpose; silver cleans them.'
AS SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM STREAM read_files(
  '${clearbook.landing}/events/',
  format => 'json',
  schema => 'event_id STRING, event_type STRING, event_ts STRING, payment_id STRING, merchant_id STRING, amount_minor BIGINT,
             currency STRING, card_network STRING, card_type STRING, card_country STRING, decline_reason STRING, reason STRING',
  rescuedDataColumn => '_rescued_data');

CREATE OR REFRESH STREAMING TABLE bronze_merchant_changes
COMMENT 'Merchant change feed (CDC): sign-ups, plan changes and closures, one row per change.'
AS SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM STREAM read_files(
  '${clearbook.landing}/merchants/',
  format => 'json',
  schema => 'merchant_id STRING, op STRING, change_ts STRING, merchant_name STRING, segment STRING, category STRING, country STRING,
             settlement_currency STRING, plan STRING, risk_tier STRING, status STRING',
  rescuedDataColumn => '_rescued_data');

CREATE OR REFRESH STREAMING TABLE bronze_fx_rates
COMMENT 'Daily FX rates (USD per unit of currency).'
AS SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM STREAM read_files(
  '${clearbook.landing}/fx/',
  format => 'csv', header => true,
  schema => 'rate_date DATE, currency STRING, usd_per_unit DOUBLE');

CREATE OR REFRESH STREAMING TABLE bronze_bank_payouts
COMMENT 'Bank settlement file: payouts the bank actually made to merchants. Reconciled against the ledger in stage 2.'
AS SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM STREAM read_files(
  '${clearbook.landing}/settlements/',
  format => 'csv', header => true,
  schema => 'payout_id STRING, merchant_id STRING, value_date DATE, currency STRING, amount_minor BIGINT, bank_reference STRING');
