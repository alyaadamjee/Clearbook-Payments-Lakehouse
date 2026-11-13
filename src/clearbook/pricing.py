"""Clearbook pricing: what merchants pay (fees) and what Clearbook pays the card networks (network costs).

All money is handled in minor units (cents / pence) as integers, the way payment systems store it, so nothing is lost to
floating-point rounding. Rates are in basis points (1 bp = 0.01%).
"""

# Merchant pricing plans: fee = amount * rate_bps / 10_000 + fixed_minor, except ic_plus where the rate is added on top of
# the actual network cost ("interchange plus").
PLANS = {
    "standard": {"rate_bps": 290, "fixed_minor": 30, "description": "2.9% + 30¢ – small businesses"},
    "volume": {"rate_bps": 250, "fixed_minor": 25, "description": "2.5% + 25¢ – mid-market"},
    "ic_plus": {"rate_bps": 40, "fixed_minor": 10, "description": "network cost + 0.4% + 10¢ – enterprise"},
}

# Network cost (interchange + scheme fees) in bps by card type, plus a surcharge when the card is from another country.
NETWORK_COST_BPS = {"debit": 60, "credit": 180, "amex": 250}
CROSS_BORDER_BPS = 100
DISPUTE_FEE_MINOR = 1500  # charged to the merchant per chargeback
# Clearbook's own variable cost to run a payment (fraud and risk operations, support, infrastructure): a share of volume plus
# a fixed amount per successful payment, in US cents. Used for contribution margin.
OPERATING_COST_BPS = 30
OPERATING_COST_PER_PAYMENT_MINOR_USD = 10
CHARGEBACK_MONITOR_PCT = 1.0   # card network monitoring threshold: chargebacks as % of payments in a month


def bps_of(amount_minor, bps):
    """amount × bps / 10,000 in whole minor units, halves rounded up – integer arithmetic, so Python and SQL agree exactly
    (SQL: floor((amount * bps + 5000) / 10000))."""
    return (amount_minor * bps + 5_000) // 10_000


def network_cost_minor(amount_minor, card_type, cross_border):
    bps = NETWORK_COST_BPS[card_type] + (CROSS_BORDER_BPS if cross_border else 0)
    return bps_of(amount_minor, bps)


def fee_minor(amount_minor, plan, card_type, cross_border):
    """Fee Clearbook charges the merchant for one captured payment."""
    p = PLANS[plan]
    fee = bps_of(amount_minor, p["rate_bps"]) + p["fixed_minor"]
    if plan == "ic_plus":
        fee += network_cost_minor(amount_minor, card_type, cross_border)
    return fee
