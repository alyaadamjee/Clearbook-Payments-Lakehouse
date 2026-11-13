# Databricks notebook source
# MAGIC %md
# MAGIC # 00 · Setup
# MAGIC Creates the schema, the landing volume, and the pricing reference tables the ledger uses. The reference tables are
# MAGIC written from `src/clearbook/pricing.py`, so the simulator (Python) and the ledger (SQL) always use the same rates.
# MAGIC Safe to rerun.

# COMMAND ----------

import os
import sys

sys.path.insert(0, os.path.abspath("../src"))
from clearbook import pricing

dbutils.widgets.text("schema", "workspace.clearbook")
S = dbutils.widgets.get("schema")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS {S} COMMENT 'Clearbook – payments revenue and reconciliation demo (simulated data)'")
spark.sql(f"CREATE VOLUME IF NOT EXISTS {S}.landing COMMENT 'Raw feeds: events/, merchants/, fx/, settlements/'")

# COMMAND ----------

spark.createDataFrame([(k, v["rate_bps"], v["fixed_minor"], k == "ic_plus", v["description"]) for k, v in pricing.PLANS.items()],
                      "plan string, rate_bps int, fixed_minor int, adds_network_cost boolean, description string") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.ref_pricing_plans")
spark.createDataFrame([(k, v) for k, v in pricing.NETWORK_COST_BPS.items()], "card_type string, network_cost_bps int") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.ref_network_costs")
spark.createDataFrame([("cross_border_bps", pricing.CROSS_BORDER_BPS), ("dispute_fee_minor", pricing.DISPUTE_FEE_MINOR),
                       ("operating_cost_bps", pricing.OPERATING_COST_BPS), ("operating_cost_per_payment_minor_usd", pricing.OPERATING_COST_PER_PAYMENT_MINOR_USD), ("chargeback_monitor_bps", int(pricing.CHARGEBACK_MONITOR_PCT * 100))],
                      "setting string, value int") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.ref_pricing_settings")
for t, c in [("ref_pricing_plans", "Merchant pricing plans (from src/clearbook/pricing.py)"),
             ("ref_network_costs", "Card network cost (interchange + scheme fees) in bps by card type"),
             ("ref_pricing_settings", "Pricing settings: cross-border surcharge (bps), dispute fee (minor units), operating cost (bps of volume + US cents per payment), chargeback monitoring threshold (bps of payments)")]:
    spark.sql(f"COMMENT ON TABLE {S}.{t} IS '{c}'")
display(spark.table(f"{S}.ref_pricing_plans"))
