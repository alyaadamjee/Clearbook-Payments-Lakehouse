"""Simulated feeds for Clearbook, a fictional payments processor. All data is fake.

Clearbook takes card payments for ~300 merchants. Per day the simulator writes, under <landing>/:
  events/<date>/events-<n>.json    payment events (JSON lines): payment.succeeded / payment.failed / refund / chargeback
  merchants/<date>.json            merchant changes (CDC feed): sign-ups, plan changes, closures
  fx/<date>.csv                    daily FX rates to USD
  settlements/<date>.csv           the bank's payout file: what was actually paid to each merchant that day

Deterministic: the same date range always gives the same files. Generation always starts at FEED_START (refunds and
chargebacks land days after their payment, and payouts are T+2), but only days inside the requested range are written.

Problems are planted on purpose so the pipeline's checks and the reconciliation have something to find
(see PLANTED below).
"""
import csv
import datetime as dt
import json
import math
import os
import random
from collections import defaultdict

from clearbook import pricing

FEED_START = dt.date(2026, 7, 1)
CURRENCIES = {"US": "USD", "CA": "USD", "GB": "GBP", "IE": "EUR", "DE": "EUR", "FR": "EUR", "NL": "EUR"}
MERCHANT_COUNTRIES = [("US", 55), ("GB", 15), ("DE", 10), ("FR", 7), ("NL", 5), ("IE", 4), ("CA", 4)]
CATEGORIES = {  # category: (ticket min, ticket max in major units, share of weekend volume uplift)
    "Retail": (15, 180, 1.3), "Restaurants": (12, 90, 1.6), "Software & SaaS": (9, 400, 0.6),
    "Travel": (80, 1500, 1.1), "Health & Beauty": (10, 120, 1.2), "Marketplace": (8, 250, 1.2),
}
SEGMENTS = {  # segment: (share of merchants, payments per day range, plan)
    "SMB": (0.76, (1, 15), "standard"), "Mid-market": (0.20, (15, 60), "volume"), "Enterprise": (0.04, (100, 300), "ic_plus"),
}
WORDS_A = ["Amber", "Birch", "Copper", "Driftwood", "Ember", "Fable", "Garnet", "Harbor", "Indigo", "Juniper", "Kiln", "Linden",
           "Maple", "Nimbus", "Opal", "Pebble", "Quill", "Russet", "Saffron", "Thistle", "Umber", "Velvet", "Willow", "Yarrow"]
WORDS_B = ["Goods", "Kitchen", "Studio", "Travel", "Supply", "Labs", "Market", "Co", "Outfitters", "Bakery", "Apothecary", "Works"]
FAIL_RATE = 0.06
REFUND_RATE = 0.035
CHARGEBACK_RATE = {"normal": 0.003, "risky": 0.016}

PLANTED = {
    "duplicate_events": "0.4% of events are sent twice (same event_id)",
    "late_events": "0.5% of events arrive one or two days after they happened",
    "bad_amount": "a handful of events with amount 0 or negative",
    "bad_currency": "a handful of events with currency 'XXX'",
    "orphan_refund": "a few refunds for payment ids that do not exist",
    "missing_payout": "~1% of merchant payouts missing from the bank file",
    "payout_amount_diff": "~0.5% of payouts short by a bank charge",
    "duplicate_payout": "~0.3% of payouts appear twice",
    "late_payout": "~1% of payouts arrive one day late",
}


def _rng(*parts):
    return random.Random("|".join(str(p) for p in parts))


def daterange(a, b):
    d = a
    while d <= b:
        yield d
        d += dt.timedelta(days=1)


def add_business_days(d, n):
    while n:
        d += dt.timedelta(days=1)
        if d.weekday() < 5:
            n -= 1
    return d


# ---- merchants ---------------------------------------------------------------------------------------------------

def merchants():
    """300 merchants with their history: signup, plan changes, closures. Returns (list of dicts, list of change events)."""
    rng = _rng("merchants")
    out, changes = [], []
    for i in range(1, 301):
        seg = rng.choices(list(SEGMENTS), [s[0] for s in SEGMENTS.values()])[0]
        country = rng.choices([c for c, _ in MERCHANT_COUNTRIES], [w for _, w in MERCHANT_COUNTRIES])[0]
        cat = rng.choice(list(CATEGORIES))
        signup = dt.date(2025, 1, 1) + dt.timedelta(days=rng.randint(0, 640))  # up to early Oct 2026
        lo, hi = SEGMENTS[seg][1]
        m = {"merchant_id": f"M{i:05d}", "merchant_name": f"{rng.choice(WORDS_A)} {rng.choice(WORDS_B)}", "segment": seg,
             "category": cat, "country": country, "settlement_currency": CURRENCIES[country], "plan": SEGMENTS[seg][2],
             "risk_tier": "risky" if rng.random() < 0.06 else "normal", "signup_date": signup,
             "base_daily": rng.uniform(lo, hi), "growth": rng.uniform(-0.004, 0.012), "closed_on": None}
        changes.append({"merchant_id": m["merchant_id"], "op": "UPSERT", "change_ts": f"{signup}T00:00:00",
                        **{k: m[k] for k in ("merchant_name", "segment", "category", "country", "settlement_currency", "plan",
                                             "risk_tier")}, "status": "active"})
        # some SMBs grow into mid-market during the period: plan change (tests history-aware pricing)
        if seg == "SMB" and rng.random() < 0.08:
            when = FEED_START + dt.timedelta(days=rng.randint(20, 110))
            if when > signup:
                m["upgrade_on"] = when
                changes.append({**changes[-1], "op": "UPSERT", "change_ts": f"{when}T00:00:00", "segment": "Mid-market", "plan": "volume"})
        if rng.random() < 0.05:  # churned merchants
            m["closed_on"] = FEED_START + dt.timedelta(days=rng.randint(10, 115))
            if m["closed_on"] > signup:
                changes.append({**changes[-1], "op": "UPSERT", "change_ts": f"{m['closed_on']}T17:00:00", "status": "closed"})
            else:
                m["closed_on"] = None
        out.append(m)
    return out, changes


def plan_on(m, d):
    return "volume" if m.get("upgrade_on") and d >= m["upgrade_on"] else m["plan"]


# ---- FX ----------------------------------------------------------------------------------------------------------

def fx_rates(end):
    """Daily USD per unit rate for GBP and EUR (random walk). {date: {"GBP": x, "EUR": y, "USD": 1.0}}"""
    rng = _rng("fx")
    gbp, eur, out = 1.27, 1.08, {}
    for d in daterange(FEED_START - dt.timedelta(days=5), end):
        gbp *= math.exp(rng.gauss(0, 0.004))
        eur *= math.exp(rng.gauss(0, 0.0035))
        out[d] = {"USD": 1.0, "GBP": round(gbp, 6), "EUR": round(eur, 6)}
    return out


# ---- payments ----------------------------------------------------------------------------------------------------

def simulate(end):
    """Run the whole simulation from FEED_START to end. Returns dict of per-day outputs."""
    ms, changes = merchants()
    fx = fx_rates(end)
    events = defaultdict(list)          # arrival date -> events
    ledger_truth = defaultdict(lambda: defaultdict(int))  # (merchant, value date) -> net payout minor
    payment_ids = []
    seq = 0
    for d in daterange(FEED_START, end):
        for m in ms:
            if m["signup_date"] > d or (m["closed_on"] and d > m["closed_on"]):
                continue
            rng = _rng("pay", m["merchant_id"], d)
            months = (d - FEED_START).days / 30
            lo, hi, weekend_uplift = CATEGORIES[m["category"]]
            mean = m["base_daily"] * (1 + m["growth"]) ** (months * 30 / 7) * (weekend_uplift if d.weekday() >= 5 else 1.0)
            if m["category"] == "Software & SaaS" and d.day <= 3:
                mean *= 3  # monthly subscription renewals
            n = max(0, int(rng.gauss(mean, math.sqrt(mean))))
            cur = m["settlement_currency"]
            for _ in range(n):
                seq += 1
                pid = f"pay_{d:%Y%m%d}_{seq:07d}"
                ts = dt.datetime.combine(d, dt.time()) + dt.timedelta(seconds=rng.randint(0, 86399))
                amount = int(round(rng.uniform(lo, hi) * 100 * (1 if cur == "USD" else 0.85)))
                card_type = rng.choices(["debit", "credit", "amex"], [45, 47, 8])[0]
                card_country = m["country"] if rng.random() < 0.88 else rng.choice(["US", "GB", "DE", "FR", "BR", "JP", "AU"])
                cross = card_country != m["country"]
                base = {"payment_id": pid, "merchant_id": m["merchant_id"], "currency": cur, "card_network":
                        "amex" if card_type == "amex" else rng.choice(["visa", "visa", "mastercard"]), "card_type": card_type,
                        "card_country": card_country}
                if rng.random() < FAIL_RATE:
                    events[d].append({**base, "event_id": f"evt_{seq:08d}_f", "event_type": "payment.failed",
                                      "event_ts": ts.isoformat(), "amount_minor": amount,
                                      "decline_reason": rng.choice(["insufficient_funds", "do_not_honor", "expired_card", "fraud_suspected"])})
                    continue
                events[d].append({**base, "event_id": f"evt_{seq:08d}_s", "event_type": "payment.succeeded", "event_ts": ts.isoformat(),
                                  "amount_minor": amount})
                payment_ids.append(pid)
                fee = pricing.fee_minor(amount, plan_on(m, d), card_type, cross)
                ledger_truth[(m["merchant_id"], d)][cur] += amount - fee
                if rng.random() < REFUND_RATE:
                    rd = d + dt.timedelta(days=rng.randint(1, 20))
                    ramt = amount if rng.random() < 0.7 else int(amount * rng.uniform(0.2, 0.8))
                    events[rd].append({**base, "event_id": f"evt_{seq:08d}_r", "event_type": "refund.succeeded",
                                       "event_ts": f"{rd}T{rng.randint(8, 20):02d}:{rng.randint(0, 59):02d}:00", "amount_minor": ramt})
                    ledger_truth[(m["merchant_id"], rd)][cur] -= ramt
                elif rng.random() < CHARGEBACK_RATE[m["risk_tier"]]:
                    cd = d + dt.timedelta(days=rng.randint(15, 60))
                    events[cd].append({**base, "event_id": f"evt_{seq:08d}_c", "event_type": "chargeback.created",
                                       "event_ts": f"{cd}T{rng.randint(8, 20):02d}:00:00", "amount_minor": amount,
                                       "reason": rng.choice(["fraudulent", "product_not_received", "duplicate", "not_as_described"])})
                    ledger_truth[(m["merchant_id"], cd)][cur] -= amount + pricing.DISPUTE_FEE_MINOR

    # ---- planted event problems (arrival can differ from event time) ----
    arrivals = defaultdict(list)
    prng = _rng("planted-events")
    for d, evs in events.items():
        for e in evs:
            r = prng.random()
            if r < 0.005:
                arrivals[d + dt.timedelta(days=prng.choice([1, 2]))].append(e)   # late event
            else:
                arrivals[d].append(e)
            if prng.random() < 0.004:
                arrivals[d].append(dict(e))                                      # duplicate send
    days = [d for d in sorted(arrivals) if d <= end]  # plant problems only on days that are written
    for k in range(12):
        d = days[prng.randrange(len(days))]
        e = dict(prng.choice(arrivals[d]))
        kind = k % 3
        if kind == 0:
            e.update(event_id=e["event_id"] + "_bad_amt", amount_minor=prng.choice([0, -e["amount_minor"]]))
        elif kind == 1:
            e.update(event_id=e["event_id"] + "_bad_cur", currency="XXX")
        else:
            e.update(event_id=f"evt_orphan_{k:03d}", event_type="refund.succeeded", payment_id=f"pay_unknown_{k:03d}")
        arrivals[d].append(e)

    # ---- bank settlement file: payouts T+2 business days, with planted breaks ----
    payouts = defaultdict(list)
    brng = _rng("planted-payouts")
    for (mid, value_date), by_cur in sorted(ledger_truth.items()):
        for cur, net in by_cur.items():
            if net == 0:
                continue
            pay_date = add_business_days(value_date, 2)
            row = {"payout_id": f"po_{mid}_{value_date:%Y%m%d}", "merchant_id": mid, "value_date": value_date.isoformat(),
                   "currency": cur, "amount_minor": net, "bank_reference": f"CLB{brng.randint(10**9, 10**10 - 1)}"}
            r = brng.random()
            if r < 0.01:
                continue                                                         # missing payout
            if r < 0.015:
                row["amount_minor"] = net - 25                                   # bank charge deducted
            if brng.random() < 0.01:
                pay_date = add_business_days(pay_date, 1)                        # late payout
            payouts[pay_date].append(row)
            if brng.random() < 0.003:
                payouts[pay_date].append(dict(row, bank_reference=f"CLB{brng.randint(10**9, 10**10 - 1)}"))  # paid twice
    return {"merchants": ms, "changes": changes, "fx": fx, "events": arrivals, "payouts": payouts, "payment_ids": payment_ids}


def write(landing, start, end, sim=None):
    """Write the files for each day in [start, end]. Returns a summary dict."""
    sim = sim or simulate(end)
    summary = defaultdict(int)
    by_day_changes = defaultdict(list)
    for c in sim["changes"]:
        cd = dt.date.fromisoformat(c["change_ts"][:10])
        by_day_changes[max(cd, FEED_START)].append(c)  # history before the feed starts arrives as the first file
    for d in daterange(start, end):
        evs = sim["events"].get(d, [])
        if evs:
            folder = f"{landing}/events/{d}"
            os.makedirs(folder, exist_ok=True)
            chunk = math.ceil(len(evs) / 4)
            for n in range(4):
                part = evs[n * chunk:(n + 1) * chunk]
                if part:
                    with open(f"{folder}/events-{n + 1}.json", "w") as f:
                        f.writelines(json.dumps(e) + "\n" for e in part)
            summary["events"] += len(evs)
        if by_day_changes.get(d):
            os.makedirs(f"{landing}/merchants", exist_ok=True)
            with open(f"{landing}/merchants/{d}.json", "w") as f:
                f.writelines(json.dumps(c) + "\n" for c in by_day_changes[d])
            summary["merchant_changes"] += len(by_day_changes[d])
        os.makedirs(f"{landing}/fx", exist_ok=True)
        with open(f"{landing}/fx/{d}.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["rate_date", "currency", "usd_per_unit"])
            for cur, r in sim["fx"][d].items():
                w.writerow([d.isoformat(), cur, r])
        if sim["payouts"].get(d):
            os.makedirs(f"{landing}/settlements", exist_ok=True)
            with open(f"{landing}/settlements/{d}.csv", "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=["payout_id", "merchant_id", "value_date", "currency", "amount_minor", "bank_reference"])
                w.writeheader()
                w.writerows(sim["payouts"][d])
            summary["payouts"] += len(sim["payouts"][d])
    return dict(summary)
