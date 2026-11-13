import datetime as dt
import math
import random

from clearbook import forecast, plan

D0 = dt.date(2026, 7, 1)


def synthetic(n_days, growth=0.004, weekend=1.4, noise=0.05, seed=1):
    rng = random.Random(seed)
    ds = forecast.days(D0, D0 + dt.timedelta(days=n_days - 1))
    vs = [1000 * math.exp(growth * k) * (weekend if d.weekday() >= 5 else 1) * math.exp(rng.gauss(0, noise)) for k, d in enumerate(ds)]
    return ds, vs


def test_recovers_growth_and_weekend():
    ds, vs = synthetic(120)
    m = forecast.fit(ds, vs)
    assert abs(m["daily_growth"] - 0.004) < 0.0005
    sat = forecast.predict(m, [dt.date(2026, 11, 7)])[0][1]   # Saturday
    mon = forecast.predict(m, [dt.date(2026, 11, 9)])[0][1]   # Monday
    assert 1.3 < sat / mon * math.exp(0.004 * 2) < 1.5


def test_interval_contains_most_future_days():
    ds, vs = synthetic(150, seed=3)
    m = forecast.fit(ds[:120], vs[:120])
    preds = forecast.predict(m, ds[120:])
    inside = sum(lo <= v <= hi for (_, _, lo, hi), v in zip(preds, vs[120:]))
    assert inside / 30 > 0.6                                   # ~80% expected


def test_backtest_error_is_small_on_clean_data():
    ds, vs = synthetic(122, noise=0.03)
    m = forecast.fit(ds[:91], vs[:91])
    assert forecast.mape(vs[91:], [p[1] for p in forecast.predict(m, ds[91:])]) < 6


def test_needs_history():
    try:
        forecast.fit([D0], [1.0])
        assert False
    except ValueError:
        pass


def test_variance_effects_add_up():
    v = plan.variance(actual_tpv=110.0, actual_rev=1.2, budget_tpv=100.0, budget_rev=1.0)
    assert abs(v["volume_effect"] + v["rate_effect"] - v["revenue_variance"]) < 1e-12
    assert abs(v["volume_effect"] - 0.1) < 1e-12


def test_budget_rows():
    rows = plan.budget({"SMB": 100.0}, {"SMB": 150.0})
    assert [r[0].month for r in rows] == [10, 11, 12]
    assert rows[1][2] > rows[0][2]                             # growth + November uplift
    assert rows[0][4] == round(rows[0][2] * 150 / 10000, 2)
