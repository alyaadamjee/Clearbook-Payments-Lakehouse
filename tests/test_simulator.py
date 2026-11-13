import datetime as dt
import json

import pytest

from clearbook import simulator as s

END = s.FEED_START + dt.timedelta(days=13)


@pytest.fixture(scope="module")
def sim():
    return s.simulate(END)


def test_deterministic():
    a, b = s.simulate(s.FEED_START + dt.timedelta(days=2)), s.simulate(s.FEED_START + dt.timedelta(days=2))
    assert a["events"][s.FEED_START] == b["events"][s.FEED_START]


def test_merchant_ids_unique_and_history_starts_with_signup():
    ms, changes = s.merchants()
    assert len({m["merchant_id"] for m in ms}) == 300
    first = {}
    for c in changes:
        first.setdefault(c["merchant_id"], c)
    assert all(c["status"] == "active" for c in first.values())


def test_events_have_required_fields(sim):
    e = sim["events"][s.FEED_START][0]
    for k in ("event_id", "event_type", "payment_id", "merchant_id", "amount_minor", "currency", "event_ts"):
        assert k in e


def test_refunds_never_exceed_the_payment(sim):
    paid = {}
    for evs in sim["events"].values():
        for e in evs:
            if e["event_type"] == "payment.succeeded":
                paid[e["payment_id"]] = e["amount_minor"]
    for evs in sim["events"].values():
        for e in evs:
            if e["event_type"] == "refund.succeeded" and e["payment_id"] in paid and e["amount_minor"] > 0:
                assert e["amount_minor"] <= paid[e["payment_id"]]


def test_planted_problems_exist(sim):
    all_events = [e for evs in sim["events"].values() for e in evs]
    ids = [e["event_id"] for e in all_events]
    assert len(ids) > len(set(ids))                                       # duplicates
    assert any(e["currency"] == "XXX" for e in all_events)
    assert any(e["amount_minor"] <= 0 for e in all_events)
    assert any(e["payment_id"].startswith("pay_unknown") for e in all_events)
    assert sum(e["currency"] == "XXX" for e in all_events) == 4                    # all planted ones inside the range


def test_payouts_are_t_plus_2_business_days(sim):
    for pay_date, rows in sim["payouts"].items():
        for r in rows:
            vd = dt.date.fromisoformat(r["value_date"])
            assert pay_date >= s.add_business_days(vd, 2)


def test_write(tmp_path, sim):
    out = s.write(str(tmp_path), s.FEED_START, s.FEED_START + dt.timedelta(days=3), sim)
    assert out["events"] > 0 and out["merchant_changes"] > 0
    line = (tmp_path / "events" / str(s.FEED_START) / "events-1.json").read_text().splitlines()[0]
    assert json.loads(line)["event_id"]
