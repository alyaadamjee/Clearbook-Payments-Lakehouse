"""Daily volume forecast: a small, explainable regression rather than a black box.

    log(volume) = level + growth × day + weekday effect + month-start effect + noise

Fitted by least squares (numpy only). The growth term gives the trend, weekday dummies capture weekend shopping, and the
month-start dummy (days 1–3) captures subscription renewals. The 80% range comes from the spread of the residuals.
Forecasts are made per segment and added up.
"""
import datetime as dt
import math

import numpy as np

Z80 = 1.2816  # two-sided 80% interval


def _features(dates, origin):
    rows = []
    for d in dates:
        t = (d - origin).days
        dow = [1.0 if d.weekday() == k else 0.0 for k in range(1, 7)]  # Monday is the baseline
        rows.append([1.0, t, *dow, 1.0 if d.day <= 3 else 0.0])
    return np.array(rows)


def fit(dates, values):
    """Fit on daily values (> 0). Returns a model dict."""
    pairs = [(d, v) for d, v in zip(dates, values) if v and v > 0]
    if len(pairs) < 21:
        raise ValueError("need at least 21 days of history")
    ds, vs = zip(*pairs)
    origin = min(ds)
    X, y = _features(ds, origin), np.log(np.array(vs, dtype=float))
    coef, *_ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ coef
    sigma = float(np.std(resid, ddof=X.shape[1]))
    return {"coef": coef, "sigma": sigma, "origin": origin, "n": len(vs),
            "daily_growth": float(coef[1]), "monthly_growth_pct": (math.exp(coef[1] * 30) - 1) * 100}


def predict(model, dates):
    """Point forecast and 80% range per date: list of (date, forecast, lower, upper)."""
    X = _features(dates, model["origin"])
    mu = X @ model["coef"]
    s = model["sigma"]
    # mean of a lognormal = exp(mu + s²/2); interval from the log-scale quantiles
    return [(d, math.exp(m + s * s / 2), math.exp(m - Z80 * s), math.exp(m + Z80 * s)) for d, m in zip(dates, mu)]


def mape(actual, forecast):
    """Mean absolute percentage error over pairs with actual > 0, in %."""
    pairs = [(a, f) for a, f in zip(actual, forecast) if a]
    return 100 * sum(abs(a - f) / a for a, f in pairs) / len(pairs)


def days(start, end):
    return [start + dt.timedelta(days=k) for k in range((end - start).days + 1)]
