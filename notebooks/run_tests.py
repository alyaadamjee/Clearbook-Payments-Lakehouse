# Databricks notebook source
# MAGIC %md
# MAGIC # Unit tests
# MAGIC Runs the pytest suite in `tests/` (pure Python). The same tests run on every push through GitHub Actions.

# COMMAND ----------

# MAGIC %pip install pytest==8.3.3 -q

# COMMAND ----------

import os
import subprocess
import sys

p = subprocess.run([sys.executable, "-m", "pytest", os.path.abspath("../tests"), "-q", "-p", "no:cacheprovider", "-rf"],
                   capture_output=True, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), cwd="/tmp")
print(p.stdout[-20000:], p.stderr[-5000:])
if p.returncode != 0:
    raise Exception(f"tests failed (exit code {p.returncode})\n" + (p.stdout + p.stderr)[-3000:])
dbutils.notebook.exit(p.stdout.strip().splitlines()[-1] if p.stdout.strip() else "ok")
