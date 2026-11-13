-- Clearbook · Silver
-- Clean, typed, de-duplicated data:
--   silver_payment_events     events with data quality expectations (bad rows dropped and counted in the pipeline's
--                             event log) and duplicates removed (first copy kept)
--   quarantine_payment_events the rows the expectations dropped, with the reasons – nothing disappears silently
--   dim_merchant              merchant history as a slowly changing dimension (SCD type 2) built with AUTO CDC
--   silver_fx_rates           one rate per currency and day
--   silver_payments           one row per payment: amount, refunds, chargebacks, plan in force on the day, USD amount
--   orphan_events             refunds / chargebacks for payments that do not exist

CREATE OR REFRESH MATERIALIZED VIEW silver_payment_events (
  CONSTRAINT known_event_type EXPECT (event_type IN ('payment.succeeded', 'payment.failed', 'refund.succeeded', 'chargeback.created')) ON VIOLATION DROP ROW,
  CONSTRAINT positive_amount EXPECT (amount_minor > 0) ON VIOLATION DROP ROW,
  CONSTRAINT known_currency EXPECT (currency IN ('USD', 'GBP', 'EUR')) ON VIOLATION DROP ROW,
  CONSTRAINT has_ids EXPECT (event_id IS NOT NULL AND payment_id IS NOT NULL AND merchant_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valid_timestamp EXPECT (event_ts IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Payment events, cleaned: expectations drop bad rows (see quarantine_payment_events), duplicate sends removed (first copy by ingest time).'
AS SELECT event_id, event_type, try_to_timestamp(event_ts) AS event_ts, payment_id, merchant_id, amount_minor, currency,
          card_network, card_type, card_country, decline_reason, reason AS chargeback_reason,
          _source_file, _ingested_at,
          CAST(regexp_extract(_source_file, '/events/([0-9-]+)/', 1) AS DATE) AS arrival_date
FROM bronze_payment_events
QUALIFY row_number() OVER (PARTITION BY event_id ORDER BY _ingested_at, _source_file) = 1;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_payment_events
COMMENT 'Events the silver expectations dropped, with every rule each one broke.'
AS SELECT * FROM (
  SELECT filter(array(
           CASE WHEN NOT event_type IN ('payment.succeeded', 'payment.failed', 'refund.succeeded', 'chargeback.created') OR event_type IS NULL THEN 'known_event_type' END,
           CASE WHEN NOT amount_minor > 0 OR amount_minor IS NULL THEN 'positive_amount' END,
           CASE WHEN NOT currency IN ('USD', 'GBP', 'EUR') OR currency IS NULL THEN 'known_currency' END,
           CASE WHEN event_id IS NULL OR payment_id IS NULL OR merchant_id IS NULL THEN 'has_ids' END,
           CASE WHEN try_to_timestamp(event_ts) IS NULL THEN 'valid_timestamp' END), x -> x IS NOT NULL) AS rules_broken,
         b.*
  FROM bronze_payment_events b)
WHERE size(rules_broken) > 0;

-- Merchant history (SCD type 2): every plan change or closure closes the old row (__END_AT) and opens a new one, so a
-- payment can be priced with the plan that was in force when it happened.
CREATE TEMPORARY VIEW merchant_changes AS
SELECT * EXCEPT (change_ts, _rescued_data, _source_file, _ingested_at), CAST(change_ts AS TIMESTAMP) AS change_ts
FROM STREAM(bronze_merchant_changes);

CREATE OR REFRESH STREAMING TABLE dim_merchant
COMMENT 'Merchant history, SCD type 2: one row per version, valid from __START_AT to __END_AT (null = current).';

CREATE FLOW dim_merchant_cdc AS AUTO CDC INTO dim_merchant
FROM STREAM(merchant_changes)
KEYS (merchant_id)
SEQUENCE BY change_ts
COLUMNS * EXCEPT (op)
STORED AS SCD TYPE 2;

CREATE OR REFRESH MATERIALIZED VIEW silver_fx_rates
COMMENT 'One FX rate per currency and day (USD per unit).'
AS SELECT rate_date, currency, max(usd_per_unit) AS usd_per_unit
FROM bronze_fx_rates GROUP BY rate_date, currency;

CREATE OR REFRESH MATERIALIZED VIEW silver_payments
COMMENT 'One row per payment: status, amount, refunds and chargebacks so far, card details, the merchant plan in force when it was taken, and the USD value at that day''s rate.'
AS WITH p AS (
  SELECT payment_id,
         max_by(merchant_id, event_type IN ('payment.succeeded', 'payment.failed')) AS merchant_id,
         min(CASE WHEN event_type IN ('payment.succeeded', 'payment.failed') THEN event_ts END) AS created_ts,
         max(CASE WHEN event_type = 'payment.succeeded' THEN 'succeeded' WHEN event_type = 'payment.failed' THEN 'failed' END) AS status,
         max(CASE WHEN event_type IN ('payment.succeeded', 'payment.failed') THEN amount_minor END) AS amount_minor,
         max(CASE WHEN event_type = 'payment.failed' THEN decline_reason END) AS decline_reason,
         coalesce(sum(CASE WHEN event_type = 'refund.succeeded' THEN amount_minor END), 0) AS refunded_minor,
         coalesce(sum(CASE WHEN event_type = 'chargeback.created' THEN amount_minor END), 0) AS chargeback_minor,
         max(CASE WHEN event_type = 'chargeback.created' THEN chargeback_reason END) AS chargeback_reason,
         max(currency) AS currency, max(card_network) AS card_network, max(card_type) AS card_type, max(card_country) AS card_country
  FROM silver_payment_events
  GROUP BY payment_id
  HAVING count_if(event_type IN ('payment.succeeded', 'payment.failed')) > 0)
SELECT p.*, CAST(p.created_ts AS DATE) AS payment_date,
       m.merchant_name, m.segment, m.category, m.country AS merchant_country, m.plan, m.risk_tier,
       p.card_country <> m.country AS cross_border,
       fx.usd_per_unit, round(p.amount_minor * fx.usd_per_unit / 100, 2) AS amount_usd
FROM p
LEFT JOIN dim_merchant m
  ON m.merchant_id = p.merchant_id AND p.created_ts >= m.__START_AT AND (m.__END_AT IS NULL OR p.created_ts < m.__END_AT)
LEFT JOIN silver_fx_rates fx ON fx.rate_date = CAST(p.created_ts AS DATE) AND fx.currency = p.currency;

CREATE OR REFRESH MATERIALIZED VIEW orphan_events
COMMENT 'Refunds and chargebacks whose payment id has no payment event – cannot be matched to a sale.'
AS SELECT e.* FROM silver_payment_events e
LEFT ANTI JOIN (SELECT DISTINCT payment_id FROM silver_payment_events WHERE event_type IN ('payment.succeeded', 'payment.failed')) p
  USING (payment_id)
WHERE e.event_type IN ('refund.succeeded', 'chargeback.created');
