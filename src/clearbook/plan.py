"""The Q4 2026 budget (the plan the actuals are judged against).

Built the way a finance team would at the end of Q3: start from each segment's average monthly volume in Q3 (Jul–Sep),
grow it by a monthly target, and price it at the segment's Q3 take rate. Kept in code so it is versioned and reviewable.
"""
import datetime as dt

BUDGET_MONTHS = [dt.date(2026, 10, 1), dt.date(2026, 11, 1), dt.date(2026, 12, 1)]
BASE_MONTHS = [dt.date(2026, 7, 1), dt.date(2026, 8, 1), dt.date(2026, 9, 1)]
MONTHLY_GROWTH_TARGET = {"SMB": 0.03, "Mid-market": 0.04, "Enterprise": 0.06}  # stretch targets per segment
SEASONAL_UPLIFT = {11: 1.08, 12: 1.12}  # Black Friday / holiday season on top of growth


def budget(q3_avg_tpv, q3_take_rate_bps):
    """q3_avg_tpv / q3_take_rate_bps: {segment: value}. Returns rows (month, segment, tpv, take_rate_bps, net_revenue)."""
    rows = []
    for seg, base in q3_avg_tpv.items():
        g = MONTHLY_GROWTH_TARGET[seg]
        for k, m in enumerate(BUDGET_MONTHS, start=2):  # Q3 average sits at mid-August: Oct is 2 months on
            tpv = base * (1 + g) ** k * SEASONAL_UPLIFT.get(m.month, 1.0)
            rows.append((m, seg, round(tpv, 2), q3_take_rate_bps[seg], round(tpv * q3_take_rate_bps[seg] / 10_000, 2)))
    return rows


def variance(actual_tpv, actual_rev, budget_tpv, budget_rev):
    """Split the revenue variance into volume and rate effects (price/volume analysis).

    volume effect = (actual TPV − budget TPV) × budget take rate
    rate effect   = (actual take rate − budget take rate) × actual TPV
    The two add up to the total revenue variance exactly.
    """
    budget_rate = budget_rev / budget_tpv if budget_tpv else 0.0
    actual_rate = actual_rev / actual_tpv if actual_tpv else 0.0
    volume = (actual_tpv - budget_tpv) * budget_rate
    rate = (actual_rate - budget_rate) * actual_tpv
    return {"revenue_variance": actual_rev - budget_rev, "volume_effect": volume, "rate_effect": rate}
