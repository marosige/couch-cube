"""Display-only currency conversion for Cube Shop prices.

Rates are ECB euro reference rates from the keyless Frankfurter API (https://api.frankfurter.dev/v1, ECB data
only). They are fetched when the Shop opens, cached for 12 hours in ~/Library/Caches/Couch Cube and reused
(marked with their date) when offline. Converted prices are never written anywhere; the wishlist keeps the
original price and currency.
"""

from decimal import Decimal, ROUND_HALF_UP, InvalidOperation
import importlib.util
from pathlib import Path
import re
import time

_spec = importlib.util.spec_from_file_location("rates_deals", Path(__file__).with_name("deals.py"))
deals = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(deals)

FRANKFURTER = "https://api.frankfurter.dev/v1/latest?base=EUR"
FRANKFURTER_HOSTS = {"api.frankfurter.dev"}
FRESH = 12 * 3600
# ISO 4217 minor units for currencies whose prices are shown without (or with other than two) decimals.
MINOR_UNITS = {"HUF": 0, "JPY": 0, "KRW": 0, "ISK": 0, "IDR": 0, "CLP": 0, "VND": 0}


def code(value):
    value = (value or "").strip().upper()
    return value if re.fullmatch(r"[A-Z]{3}", value) else None


def normalize(data):
    """{"base": "EUR", "date": "YYYY-MM-DD", "rates": {code: Decimal string}} or None when unusable."""
    if not isinstance(data, dict) or data.get("base") != "EUR" or not isinstance(data.get("rates"), dict):
        return None
    date = data.get("date") if isinstance(data.get("date"), str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", data["date"]) else None
    rates = {"EUR": "1"}
    for key, value in data["rates"].items():
        number = deals.number(value)
        if code(key) and number and number > 0:
            rates[key] = str(value)
    return {"base": "EUR", "date": date, "rates": rates} if date and len(rates) > 1 else None


def latest(refresh=False, now=None, opener=None):
    """Cached rates; offline falls back to the last saved rates (stale). Raises DealsError if none exist."""
    reply = deals.cached_fetch("rates", "frankfurter", FRANKFURTER, FRANKFURTER_HOSTS, refresh, now, opener)
    rates = normalize(reply.get("data"))
    if not rates:
        raise deals.DealsError("The exchange-rate service sent data Couch Cube couldn't read.")
    note = f"ECB reference rate via Frankfurter, updated {rates['date']}; Revolut/bank rates may differ slightly."
    if reply.get("stale"):
        note = f"Offline: using rates from {rates['date']}. " + note
    return {**rates, "fetched": reply["fetched"], "stale": reply["stale"], "note": note,
            "currencies": sorted(rates["rates"])}


def convert(amount, source, target, rates, fee_percent=0):
    """Decimal conversion through EUR, plus an optional card/FX fee, rounded to the target's minor units.
    Returns None when a currency is unknown so callers show the original price instead."""
    source, target = code(source), code(target)
    table = (rates or {}).get("rates") or {}
    if source is None or target is None or source not in table or target not in table:
        return None
    try:
        value = Decimal(str(amount))
        fee = Decimal(str(fee_percent or 0))
    except InvalidOperation:
        return None
    if value < 0 or fee < 0 or fee > 20:
        return None
    if value == 0:
        return Decimal(0)
    result = value / Decimal(table[source]) * Decimal(table[target])
    if source != target:
        result *= 1 + fee / 100
    places = MINOR_UNITS.get(target, 2)
    return result.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def sort_offers(offers, target, rates, fee_percent=0):
    """Mixed-currency offers ordered by converted value; offers that can't be converted go last, unchanged."""
    def key(offer):
        value = convert(offer["price"], offer.get("currency", "USD"), target, rates, fee_percent)
        return (value is None, value if value is not None else Decimal(0), offer.get("store", "").lower())
    return sorted(offers, key=key)
