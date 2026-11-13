# Databricks notebook source
# MAGIC %md
# MAGIC # 01 · Simulate the feeds
# MAGIC Stands in for the outside world: writes payment events, merchant changes, FX rates and the bank's settlement file for
# MAGIC each day from `start_date` to `end_date` into the landing volume (see `src/clearbook/simulator.py`). Blank dates = today.
# MAGIC The pipeline then picks up only the new files.

# COMMAND ----------

import datetime as dt
import os
import sys

sys.path.insert(0, os.path.abspath("../src"))
from clearbook import simulator

dbutils.widgets.text("schema", "workspace.clearbook")
dbutils.widgets.text("start_date", "")
dbutils.widgets.text("end_date", "")
S = dbutils.widgets.get("schema")
today = dt.datetime.utcnow().date()
start = dt.date.fromisoformat(dbutils.widgets.get("start_date") or today.isoformat())
end = dt.date.fromisoformat(dbutils.widgets.get("end_date") or start.isoformat())
landing = "/Volumes/" + S.replace(".", "/") + "/landing"

summary = simulator.write(landing, start, end)
print(f"{start} → {end}:", summary)
dbutils.notebook.exit(str(summary))
