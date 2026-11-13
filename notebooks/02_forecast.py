# Databricks notebook source
# MAGIC %md
# MAGIC # 02 · Forecast, budget and budget vs actual
# MAGIC Runs after the pipeline. Uses daily TPV by segment from `gold_merchant_daily`:
# MAGIC
# MAGIC 1. **Backtest** – fit on July–September, forecast October, compare with the real October (`gold_forecast_backtest`).
# MAGIC 2. **Forecast** – fit on all history, forecast the next 92 days with an 80% range (`gold_forecast_daily`,
# MAGIC    `gold_forecast_monthly`). Revenue = forecast TPV × the segment's take rate over the last 60 days.
# MAGIC 3. **Budget** – the Q4 plan from `src/clearbook/plan.py` (`gold_budget`).
# MAGIC 4. **Budget vs actual** – for complete months, the revenue variance split into volume and rate effects; plus the latest
# MAGIC    estimate for the quarter (actual months + forecast months) against budget (`gold_budget_vs_actual`, `gold_q4_outlook`).
# MAGIC
# MAGIC Model: `src/clearbook/forecast.py` (log-linear trend + weekday + month-start effects, numpy least squares).

# COMMAND ----------

import datetime as dt
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.abspath("../src"))
from clearbook import forecast, plan

dbutils.widgets.text("schema", "workspace.clearbook")
S = dbutils.widgets.get("schema")
SEGMENTS = ["SMB", "Mid-market", "Enterprise"]

rows = spark.sql(f"""SELECT value_date, segment, sum(tpv_usd) AS tpv, sum(net_revenue_usd) AS rev
                     FROM {S}.gold_merchant_daily WHERE segment IS NOT NULL GROUP BY ALL""").collect()
actual = defaultdict(dict)      # segment -> {date: (tpv, rev)}
for r in rows:
    actual[r.segment][r.value_date] = (float(r.tpv or 0), float(r.rev or 0))
last_day = max(d for seg in actual.values() for d in seg)
first_day = min(d for seg in actual.values() for d in seg)
month = lambda d: d.replace(day=1)
print("history:", first_day, "→", last_day)

# COMMAND ----------

# 1 · Backtest: train through the end of the month before the last complete month, forecast that month
bt_month = month(last_day) if (last_day + dt.timedelta(days=1)).day == 1 else month(month(last_day) - dt.timedelta(days=1))
bt_end = (bt_month.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
backtest = []
for seg in SEGMENTS:
    hist = sorted(actual[seg].items())
    train = [(d, v[0]) for d, v in hist if d < bt_month]
    test = [(d, v[0]) for d, v in hist if bt_month <= d <= bt_end]
    m = forecast.fit([d for d, _ in train], [v for _, v in train])
    pred = forecast.predict(m, [d for d, _ in test])
    a_sum, f_sum = sum(v for _, v in test), sum(p[1] for p in pred)
    inside = sum(p[2] <= v <= p[3] for p, (_, v) in zip(pred, test)) / len(test) * 100
    backtest.append((seg, bt_month, round(forecast.mape([v for _, v in test], [p[1] for p in pred]), 2),
                     round(a_sum, 2), round(f_sum, 2), round((f_sum - a_sum) / a_sum * 100, 2), round(inside, 1),
                     round(m["monthly_growth_pct"], 2)))
spark.createDataFrame(backtest, "segment string, test_month date, daily_mape_pct double, actual_tpv_usd double, forecast_tpv_usd double, "
                                "month_error_pct double, days_inside_80pct_range_pct double, fitted_monthly_growth_pct double") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.gold_forecast_backtest")
display(spark.table(f"{S}.gold_forecast_backtest"))

# COMMAND ----------

# 2 · Forecast the next 92 days from all history
horizon = forecast.days(last_day + dt.timedelta(days=1), last_day + dt.timedelta(days=92))
daily_out = []
for seg in SEGMENTS:
    hist = sorted(actual[seg].items())
    m = forecast.fit([d for d, _ in hist], [v[0] for _, v in hist])
    recent = [v for d, v in hist if d > last_day - dt.timedelta(days=60)]
    take_rate = sum(v[1] for v in recent) / sum(v[0] for v in recent)
    for d, (tpv, rev) in hist:
        daily_out.append((d, seg, "actual", tpv, None, None, rev, take_rate * 10_000))
    for d, f, lo, hi in forecast.predict(m, horizon):
        daily_out.append((d, seg, "forecast", f, lo, hi, f * take_rate, take_rate * 10_000))
fd = spark.createDataFrame(daily_out, "date date, segment string, kind string, tpv_usd double, tpv_lower_usd double, tpv_upper_usd double, "
                                      "net_revenue_usd double, take_rate_bps double")
fd.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.gold_forecast_daily")
spark.sql(f"COMMENT ON TABLE {S}.gold_forecast_daily IS 'Daily TPV and net revenue by segment: actuals, then a 92-day forecast with an 80% range (USD).'")

spark.sql(f"""CREATE OR REPLACE TABLE {S}.gold_forecast_monthly
  COMMENT 'Monthly TPV and net revenue by segment and in total: actual and forecast parts, with the 80% range summed from the daily ranges (conservative) (USD).'
  AS SELECT date_trunc('MONTH', date) AS month, coalesce(segment, 'All') AS segment,
            round(sum(CASE WHEN kind = 'actual' THEN tpv_usd END), 2) AS actual_tpv_usd,
            round(sum(CASE WHEN kind = 'forecast' THEN tpv_usd END), 2) AS forecast_tpv_usd,
            round(sum(coalesce(tpv_lower_usd, CASE WHEN kind = 'actual' THEN tpv_usd END)), 2) AS tpv_lower_usd,
            round(sum(coalesce(tpv_upper_usd, CASE WHEN kind = 'actual' THEN tpv_usd END)), 2) AS tpv_upper_usd,
            round(sum(tpv_usd), 2) AS tpv_usd, round(sum(net_revenue_usd), 2) AS net_revenue_usd,
            CASE WHEN count_if(kind = 'forecast') = 0 THEN 'actual' WHEN count_if(kind = 'actual') = 0 THEN 'forecast' ELSE 'part forecast' END AS basis
     FROM {S}.gold_forecast_daily GROUP BY GROUPING SETS ((date_trunc('MONTH', date)), (date_trunc('MONTH', date), segment))""")

# COMMAND ----------

# 3 · Budget from Q3 actuals and the targets in plan.py
q3 = {seg: [v for d, v in actual[seg].items() if month(d) in plan.BASE_MONTHS] for seg in SEGMENTS}
q3_avg_tpv = {seg: sum(v[0] for v in q3[seg]) / len(plan.BASE_MONTHS) for seg in SEGMENTS}
q3_rate = {seg: round(sum(v[1] for v in q3[seg]) / sum(v[0] for v in q3[seg]) * 10_000, 2) for seg in SEGMENTS}
spark.createDataFrame(plan.budget(q3_avg_tpv, q3_rate),
                      "month date, segment string, budget_tpv_usd double, budget_take_rate_bps double, budget_net_revenue_usd double") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.gold_budget")
spark.sql(f"COMMENT ON TABLE {S}.gold_budget IS 'Q4 2026 budget by month and segment: Q3 average volume grown by the targets in src/clearbook/plan.py, priced at the Q3 take rate (USD).'")

# COMMAND ----------

# 4 · Budget vs actual (complete months) and the quarter outlook
bva = []
for b in spark.table(f"{S}.gold_budget").collect():
    days_in = [(d, v) for d, v in actual[b.segment].items() if month(d) == b.month]
    month_end = (b.month.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
    if not days_in or last_day < month_end:
        continue
    a_tpv, a_rev = sum(v[0] for _, v in days_in), sum(v[1] for _, v in days_in)
    v = plan.variance(a_tpv, a_rev, b.budget_tpv_usd, b.budget_net_revenue_usd)
    bva.append((b.month, b.segment, b.budget_tpv_usd, round(a_tpv, 2), round(a_tpv - b.budget_tpv_usd, 2),
                round((a_tpv / b.budget_tpv_usd - 1) * 100, 2), b.budget_net_revenue_usd, round(a_rev, 2),
                round(v["revenue_variance"], 2), round((a_rev / b.budget_net_revenue_usd - 1) * 100, 2),
                b.budget_take_rate_bps, round(a_rev / a_tpv * 10_000, 2), round(v["volume_effect"], 2), round(v["rate_effect"], 2)))
spark.createDataFrame(bva, """month date, segment string, budget_tpv_usd double, actual_tpv_usd double, tpv_variance_usd double, tpv_variance_pct double,
    budget_net_revenue_usd double, actual_net_revenue_usd double, revenue_variance_usd double, revenue_variance_pct double,
    budget_take_rate_bps double, actual_take_rate_bps double, volume_effect_usd double, rate_effect_usd double""") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{S}.gold_budget_vs_actual")
spark.sql(f"COMMENT ON TABLE {S}.gold_budget_vs_actual IS 'Budget vs actual for complete months: TPV and revenue variance, revenue variance split into volume effect (TPV gap × budget take rate) and rate effect (take-rate gap × actual TPV).'")

spark.sql(f"""CREATE OR REPLACE TABLE {S}.gold_q4_outlook
  COMMENT 'Q4 2026 latest estimate (actual months + forecast months) against budget, by segment and in total (USD).'
  AS SELECT coalesce(b.segment, 'All') AS segment,
            round(sum(b.budget_tpv_usd), 2) AS budget_tpv_usd, round(sum(f.tpv_usd), 2) AS latest_estimate_tpv_usd,
            round(sum(b.budget_net_revenue_usd), 2) AS budget_net_revenue_usd, round(sum(f.net_revenue_usd), 2) AS latest_estimate_net_revenue_usd,
            round(sum(f.net_revenue_usd) / sum(b.budget_net_revenue_usd) * 100 - 100, 2) AS revenue_vs_budget_pct,
            round(sum(f.tpv_lower_usd), 2) AS tpv_lower_usd, round(sum(f.tpv_upper_usd), 2) AS tpv_upper_usd
     FROM {S}.gold_budget b JOIN {S}.gold_forecast_monthly f ON f.month = b.month AND f.segment = b.segment
     GROUP BY GROUPING SETS ((), (b.segment))""")
display(spark.table(f"{S}.gold_budget_vs_actual"))
display(spark.table(f"{S}.gold_q4_outlook"))
