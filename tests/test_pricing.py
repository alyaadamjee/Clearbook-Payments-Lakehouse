from clearbook import pricing


def test_standard_fee_is_2_9_pct_plus_30c():
    assert pricing.fee_minor(10_000, "standard", "credit", False) == 290 + 30


def test_ic_plus_adds_network_cost():
    cost = pricing.network_cost_minor(10_000, "credit", True)   # 1.8% + 1.0% cross-border
    assert cost == 280
    assert pricing.fee_minor(10_000, "ic_plus", "credit", True) == cost + 40 + 10


def test_fee_is_integer_minor_units():
    assert isinstance(pricing.fee_minor(1234, "volume", "debit", False), int)


def test_halves_round_up_like_sql():
    # exact halves always round up, as SQL does; Python round() would round 2.5 down to 2 (banker's rounding)
    assert pricing.bps_of(1500, 290) == 44
    assert pricing.bps_of(5, 1000) == 1      # 0.5 → 1
    assert pricing.bps_of(25, 1000) == 3     # 2.5 → 3 (banker's rounding would give 2)
