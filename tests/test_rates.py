from decimal import Decimal
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rates", ROOT / "scripts/rates.py")
rates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rates)
spec = importlib.util.spec_from_file_location("wishlist_for_rates", ROOT / "scripts/wishlist.py")
wishlist = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wishlist)

TABLE = {"base": "EUR", "date": "2026-10-16", "rates": {"EUR": "1", "USD": "1.1253", "HUF": "363.08", "GBP": "0.84385"}}
BODY = json.dumps({"amount": 1.0, "base": "EUR", "date": "2026-10-16",
                   "rates": {"USD": 1.1253, "HUF": 363.08, "GBP": 0.84385, "XXX": "bad"}}).encode()


class Response(io.BytesIO):
    url, status, headers = rates.FRANKFURTER, 200, {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class RatesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        patcher = patch.object(rates.deals, "cache_dir", return_value=Path(self.temp.name))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.calls = 0

    def opener(self, request, timeout):
        self.calls += 1
        self.assertTrue(request.full_url.startswith("https://api.frankfurter.dev/v1/"))
        return Response(BODY)

    def test_rounding_and_fee(self):
        self.assertEqual(rates.convert(11.99, "USD", "HUF", TABLE), Decimal("3869"))
        self.assertEqual(rates.convert("11.99", "USD", "EUR", TABLE), Decimal("10.65"))
        self.assertEqual(rates.convert(11.99, "USD", "HUF", TABLE, fee_percent=1), Decimal("3907"))
        self.assertEqual(rates.convert(10, "EUR", "EUR", TABLE, fee_percent=5), Decimal("10.00"),
                         "No fee when nothing is converted")
        self.assertEqual(rates.convert(0, "USD", "HUF", TABLE), Decimal(0))
        self.assertIsNone(rates.convert(5, "USD", "ZZZ", TABLE))
        self.assertIsNone(rates.convert(5, "USD", "HUF", TABLE, fee_percent=-1))
        self.assertIsNone(rates.convert(5, "USD", "HUF", None))

    def test_cache_expiry_and_offline_fallback(self):
        first = rates.latest(now=1000, opener=self.opener)
        self.assertEqual(first["rates"]["HUF"], "363.08")
        self.assertNotIn("XXX", first["rates"])
        self.assertIn("ECB reference rate via Frankfurter, updated 2026-10-16", first["note"])
        rates.latest(now=1000 + rates.FRESH - 1, opener=self.opener)
        self.assertEqual(self.calls, 1, "Rates are reused for 12 hours")
        rates.latest(now=1000 + rates.FRESH + 1, opener=self.opener)
        self.assertEqual(self.calls, 2)

        def offline(request, timeout):
            raise urllib.error.URLError("offline")
        stale = rates.latest(refresh=True, now=1000 + 3 * rates.FRESH, opener=offline)
        self.assertTrue(stale["stale"])
        self.assertTrue(stale["note"].startswith("Offline: using rates from 2026-10-16."))

    def test_no_rates_at_all_is_an_error(self):
        def offline(request, timeout):
            raise urllib.error.URLError("offline")
        with self.assertRaises(rates.deals.DealsError):
            rates.latest(now=1000, opener=offline)

    def test_mixed_currency_sort(self):
        offers = [{"store": "Steam", "price": 14.99, "currency": "USD"},
                  {"store": "App Store", "price": 3990, "currency": "HUF"},
                  {"store": "GOG", "price": 12.99, "currency": "USD"},
                  {"store": "Odd", "price": 1, "currency": "ZZZ"}]
        ordered = [offer["store"] for offer in rates.sort_offers(offers, "HUF", TABLE)]
        self.assertEqual(ordered, ["App Store", "GOG", "Steam", "Odd"])

    def test_wishlist_file_keeps_original_prices(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "wishlist.json"
            wishlist.add(path, {"title": "Hollow Knight", "game_id": "100", "target_price": 9.5,
                                "converted": 3000, "display_price": "≈ 3 000 Ft"})
            data = wishlist.read(path)
            wishlist.apply_prices(data, {"games": {"100": {"offers": [
                {"price": 9.99, "normal_price": 14.99, "savings": 33, "store": "GOG"}]}}})
            wishlist.write(path, data)
            raw = json.loads(path.read_text())["items"][0]
        self.assertEqual(set(raw), {"title", "game_id", "steam_app_id", "app_store_id", "added", "target_price", "target_currency", "thumb", "best"})
        self.assertEqual(raw["best"]["currency"], "USD")
        self.assertEqual(raw["best"]["price"], 9.99)
        # Rates are only used to compare against a target (target_reached/annotate/report); nothing that saves uses them.
        import inspect
        for function in (wishlist.normalize_item, wishlist.apply_prices, wishlist._serialise, wishlist.write, wishlist.set_target):
            self.assertNotIn("rates", inspect.getsource(function).replace("apply_prices", ""), function.__name__)


if __name__ == "__main__":
    unittest.main()
