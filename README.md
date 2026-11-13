# Clearbook – payments revenue, reconciliation and forecasting on Databricks

![tests](https://github.com/<you>/<repo>/actions/workflows/tests.yml/badge.svg)

Clearbook is a fictional payments processor. About 300 merchants (online shops, restaurants, SaaS companies, travel) take
card payments through it in USD, GBP and EUR. Clearbook charges each merchant a fee per payment, pays the card networks
their costs, and pays merchants out through the bank two business days later.

This repository is the data platform behind it. It combines three things:
- **Data engineering:** streaming ingestion, a Lakeflow declarative pipeline, data quality expectations, merchant history
  (SCD type 2) and a double-entry ledger.
- **FP&A:** take rate, unit economics, a volume bridge, a forecast, and budget vs actual split into volume and rate effects.
- **Business intelligence:** an AI/BI dashboard and a Genie space for questions in plain English.

> **All data is simulated** by `src/clearbook/simulator.py`. Merchants, card payments, amounts and bank files are fake.
> Problems are planted on purpose (duplicate events, bad amounts, unknown payments, missing or short bank payouts) so every
> check has something to catch.

![Clearbook dashboard](docs/dashboard_executive.png)

## Architecture

```
 landing volume (simulated feeds)          Lakeflow declarative pipeline (serverless)                       jobs / BI
 ┌──────────────────────────┐   Auto Loader  ┌─────────┐   ┌────────────────────────────┐   ┌─────────────────────────┐
 │ events/   payment events │ ─────────────► │ bronze  │ ─►│ silver                     │ ─►│ ledger (double-entry)   │
 │ merchants/ change feed   │  (only new     │ as      │   │ expectations + quarantine  │   │ reconciliation vs bank  │
 │ fx/       daily rates    │   files)       │ delivered│  │ dedupe, SCD2 dim_merchant  │   │ gold revenue & metrics  │
 │ settlements/ bank file   │                └─────────┘   │ silver_payments            │   └───────────┬─────────────┘
 └──────────────────────────┘                              └────────────────────────────┘               │
                                                              02_forecast (Python job) ─► forecast, budget, BvA
                                                              AI/BI dashboard · Genie space ◄────────────┘
```

| Layer | Objects | What it shows |
|---|---|---|
| **Bronze** (`pipelines/01_bronze.sql`) | `bronze_payment_events`, `bronze_merchant_changes`, `bronze_fx_rates`, `bronze_bank_payouts` | Incremental ingestion with Auto Loader (`read_files` in streaming tables): each run reads only new files. Explicit schemas, rescued data column, lineage columns. |
| **Silver** (`pipelines/02_silver.sql`) | `silver_payment_events`, `quarantine_payment_events`, `dim_merchant`, `silver_fx_rates`, `silver_payments`, `orphan_events` | **Expectations** drop bad rows, which are kept with the rules they broke, and duplicate sends are removed. **AUTO CDC** builds merchant history as **SCD type 2**, so each payment is priced on the plan in force that day. |
| **Ledger** (`03_ledger.sql`) | `ledger_entries`, `ledger_journal_check`, `ledger_trial_balance` | **Double-entry bookkeeping** in integer minor units: every journal sums to zero. An `EXPECT … ON VIOLATION FAIL UPDATE` stops the pipeline rather than publish an unbalanced ledger. Refunds for unknown payments go to a suspense account. |
| **Reconciliation** (`04_reconciliation.sql`) | `expected_payouts`, `silver_bank_payouts`, `recon_payouts`, `recon_breaks` | Ledger vs bank: the payout each merchant is owed (T+2 business days) matched to the bank file, with every difference classified. |
| **Gold** (`05_gold_revenue.sql`) | `gold_merchant_daily`, `gold_monthly_kpis`, `gold_merchant_unit_economics`, `gold_tpv_bridge`, `gold_cohorts`, `gold_chargeback_monitoring` | TPV, net revenue, take rate, contribution margin, volume bridge (new / expansion / contraction / churn), cohorts and chargeback monitoring, all in USD at the day's FX rate. |
| **Forecast and plan** (`notebooks/02_forecast.py`) | `gold_forecast_*`, `gold_budget`, `gold_budget_vs_actual`, `gold_q4_outlook` | A backtested forecast with an 80% range, the Q4 budget, and budget vs actual split into **volume and rate effects**. |
| **BI** | `dashboard/`, `genie/` | AI/BI dashboard (Executive, Merchants, Risk & reconciliation, Data quality) and a Genie space with business definitions. |

**Money handling:** amounts are integer minor units (cents and pence) until converted to USD for reporting. Fees use
integer half-up rounding, identical in Python (`pricing.bps_of`) and SQL, so the ledger and the simulator agree to the cent.

**Pricing** (`src/clearbook/pricing.py`, written to `ref_*` tables by setup, so Python and SQL share one source):

- standard: 2.9% + 30¢
- volume: 2.5% + 25¢
- interchange-plus: network cost + 0.4% + 10¢
- network costs: 0.6% debit, 1.8% credit, 2.5% Amex, +1.0% cross-border
- operating cost: 0.30% of TPV + 10¢ per payment

## Results (simulated Jul 1 – Oct 31 2026)

**Pipeline**
- **Events:** 774,231 events loaded. 3,192 duplicate sends removed, 8 rows quarantined (4 bad amounts, 4 unknown
  currencies), and 4 refunds for unknown payments parked in suspense. Silver holds 771,031 events, which ties exactly.
- **Payments:** 747,027 payments worth $168M, 6% declined. 300 merchants with 331 versions in the merchant history.

**Ledger:** 726,000 journals and 2.86M lines in three currencies, with **0 unbalanced journals**.

**Bank reconciliation** (31,930 bank payouts):

| Status | Payouts | |
|---|---|---|
| matched | 31,265 | exact to the cent |
| missing_payout | 312 | due, never paid |
| paid_late | 308 | right amount, after the due date |
| amount_mismatch | 161 | all exactly 25¢ short (the bank charge planted in the file) |
| duplicate_payout | 98 | paid twice |
| unexpected_payout | 0 | |

**October 2026**

| Segment | TPV | Net revenue | Take rate | Contribution margin |
|---|---|---|---|---|
| All | $42.3M | $470k | 111 bps | 68.7% |
| SMB | $12.0M | $196k | 163 bps | 78.9% |
| Mid-market | $17.6M | $214k | 121 bps | 71.5% |
| Enterprise | $12.7M | $61k | 48 bps | 25.6% |

Enterprise brings 30% of volume but 13% of revenue: on interchange-plus pricing Clearbook keeps a thin margin. 299 of 300
merchants are profitable. The exception is a high-risk travel merchant whose chargebacks (2.05% of payments) cost more than
it earned Clearbook.

**Volume bridge:**
- TPV grew from $37.2M (July) to $42.3M (October).
- September: churn took out $484k of volume when 6 merchants closed.
- October: net volume retention of 107%.

**Forecast backtest** (trained Jul–Sep, forecast October):
- **Total:** +0.7% vs the actual October.
- **By segment:** SMB +2.4%, Mid-market −5.6%, Enterprise +7.8%. Part of the segment error is merchants upgrading from
  SMB to mid-market during the month.
- **Weak spot:** the 80% range held 45–71% of days, so it is too narrow, mainly for Enterprise, where 11 merchants make
  daily volume noisy. A wider, per-segment interval is the next improvement.

**Budget vs actual (October):**
- **Total:** revenue $470k vs $455k budget, **+3.2%**.
- **Mid-market +$20.0k:** a volume effect of +$17.3k (TPV 9% over plan) and a rate effect of +$2.7k.
- **Enterprise −$1.9k:** volume −$3.4k, partly offset by rate +$1.5k.
- **SMB −$3.6k:** partly volume that moved to mid-market with upgrades.

**Q4 outlook:**
- **Latest estimate** (October actual + November–December forecast): $1.45M vs $1.52M budget, **−4.1%**.
- **Why:** the budget assumes a holiday uplift (+8% November, +12% December) that a trend model trained on July–October
  cannot see. That's the conversation to have with the business: is the uplift still expected?

![Merchants page](docs/dashboard_merchants.png)

![Risk and reconciliation page](docs/dashboard_risk.png)

**Genie example:** asked *"How did October revenue compare with budget, by segment?"*, it wrote the SQL against
`gold_budget_vs_actual` and answered: *"Mid-market exceeded its budget by $20,014 (+10.3%), while Enterprise and SMB fell
short by $1,911 (−3.1%) and $3,589 (−1.8%)."*

## Run it

You need a Databricks workspace with Unity Catalog and serverless compute (the free
[Databricks Free Edition](https://www.databricks.com/learn/free-edition) works), plus the Databricks CLI and jq.

```sh
databricks auth login --host https://<your-workspace>.cloud.databricks.com
databricks bundle deploy                 # pipeline, jobs and dashboard (dev target: names prefixed, schedules paused)
databricks bundle run cb_tests           # unit tests
databricks bundle run cb_backfill        # setup → simulate Jul 1–Oct 31 → pipeline → forecast (≈10 min)
scripts/deploy_genie.sh workspace.clearbook <warehouse_id>   # optional: the Genie space
```

- **Daily job:** `cb_daily` simulates the current day, runs the pipeline (new files only) and refreshes the forecast.
  `databricks bundle deploy -t prod` deploys it with the schedule on.
- **Regenerate everything from scratch:** delete the `landing/` folders, run `cb_backfill`, then
  `databricks bundle run clearbook_pipeline --full-refresh-all`. Auto Loader skips files it has already read.
- **Tests:** `pytest tests` (needs numpy) covers pricing, the simulator, the forecast model and the budget maths. They run
  on every push through GitHub Actions.

## Repository layout

```
databricks.yml, resources/   bundle: pipeline, jobs (backfill, daily, tests), dashboard
pipelines/                   01_bronze … 05_gold_revenue (Lakeflow SQL)
src/clearbook/               pricing.py, simulator.py, forecast.py, plan.py
notebooks/                   00_setup, 01_simulate, 02_forecast, run_tests
dashboard/                   dashboard.jq → clearbook.lvdash.json (scripts/build_dashboard.sh)
genie/                       space.json (scripts/deploy_genie.sh)
tests/                       pytest
```
