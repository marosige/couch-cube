import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("wishlist", ROOT / "scripts/wishlist.py")
wishlist = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wishlist)


class WishlistTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        patcher = patch.object(wishlist, "mirror_path", return_value=self.base / "mirror/wishlist-mirror.json")
        patcher.start()
        self.addCleanup(patcher.stop)

    def drive(self, name):
        library = self.base / name / "Couch Cube"
        library.mkdir(parents=True)
        return library / wishlist.RELATIVE, str(library)

    def test_round_trip_schema_and_whitelist(self):
        path, _ = self.drive("A")
        wishlist.add(path, {"title": "  Hollow   Knight ", "game_id": "100", "steam_app_id": 367520, "password": "x"}, now=5)
        wishlist.add(path, {"title": "Civilization VI", "app_store_id": "1123795278"}, now=6)
        wishlist.add(path, {"title": "Hollow Knight", "game_id": "100"}, now=7)
        wishlist.set_target(path, "cs:100", 7.5)
        raw = json.loads(path.read_text())
        self.assertEqual(raw["schema"], wishlist.SCHEMA)
        self.assertEqual(len(raw["items"]), 2, "Adding the same game twice keeps one entry")
        first = raw["items"][0]
        self.assertEqual(first["title"], "Hollow Knight")
        self.assertEqual(first["steam_app_id"], "367520")
        self.assertEqual(first["target_price"], 7.5)
        self.assertEqual(first["added"], 5)
        self.assertNotIn("password", first)
        self.assertNotIn("key", first)
        data = wishlist.read(path)
        self.assertEqual([item["key"] for item in data["items"]], ["cs:100", "app:1123795278"])
        wishlist.remove(path, "app:1123795278")
        self.assertEqual([item["key"] for item in wishlist.read(path)["items"]], ["cs:100"])
        self.assertEqual(wishlist.read(self.base / "missing.json"), wishlist.empty())

    def test_atomic_write_leaves_old_file_on_failure(self):
        path, _ = self.drive("A")
        wishlist.add(path, {"title": "Keep Me", "game_id": "1"})
        before = path.read_bytes()
        with patch.object(wishlist.os, "replace", side_effect=OSError(28, "No space left on device")):
            with self.assertRaises(wishlist.WishlistError):
                wishlist.add(path, {"title": "New", "game_id": "2"})
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual([entry.name for entry in path.parent.iterdir() if entry.suffix == ".tmp"], [],
                         "The temporary file is cleaned up")

    def test_damaged_and_newer_files_are_never_overwritten(self):
        path, library = self.drive("A")
        path.parent.mkdir(parents=True)
        path.write_text("{not json")
        with self.assertRaises(wishlist.WishlistError):
            wishlist.add(path, {"title": "X", "game_id": "1"})
        self.assertEqual(path.read_text(), "{not json")
        path.write_text(json.dumps({"schema": wishlist.SCHEMA + 1, "items": []}))
        with self.assertRaises(wishlist.WishlistError):
            wishlist.read(path)

    @unittest.skipIf(os.geteuid() == 0, "root ignores permissions")
    def test_read_only_drive(self):
        path, library = self.drive("A")
        wishlist.add(path, {"title": "Hollow Knight", "game_id": "100"})
        os.chmod(path.parent, stat.S_IRUSR | stat.S_IXUSR)
        self.addCleanup(os.chmod, path.parent, stat.S_IRWXU)
        with self.assertRaises(wishlist.WishlistError):
            wishlist.add(path, {"title": "New", "game_id": "2"})
        report = wishlist.status(path, library)
        self.assertTrue(report["read_only"])
        self.assertEqual([item["title"] for item in report["items"]], ["Hollow Knight"])
        self.assertIn("read-only", report["note"])

    def test_offline_mirror_and_drive_move(self):
        path_a, library_a = self.drive("A")
        wishlist.add(path_a, {"title": "Hollow Knight", "game_id": "100"})
        wishlist.status(path_a, library_a)
        offline = wishlist.status(None, None)
        self.assertTrue(offline["offline"] and offline["read_only"])
        self.assertEqual([item["title"] for item in offline["items"]], ["Hollow Knight"])
        self.assertIn("isn't connected", offline["note"])
        path_b, library_b = self.drive("B")
        wishlist.add(path_b, {"title": "Celeste", "game_id": "200"})
        moved = wishlist.status(path_b, library_b)
        self.assertEqual(moved["merged"], 1)
        self.assertEqual(sorted(item["title"] for item in moved["items"]), ["Celeste", "Hollow Knight"])
        self.assertEqual(len(wishlist.read(path_b)["items"]), 2, "Items from the previous drive are saved on the new one")
        self.assertEqual(wishlist.status(path_b, library_b)["merged"], 0, "Merging happens once per drive switch")

    def test_prices_and_badges(self):
        data = {"schema": 1, "items": [wishlist.normalize_item({"title": "Hollow Knight", "game_id": "100", "target_price": 10}),
                                        wishlist.normalize_item({"title": "Civ", "app_store_id": "5",
                                                                 "best": {"price": 20, "currency": "HUF"}})]}
        prices = {"games": {"100": {"offers": [{"price": 9.99, "normal_price": 14.99, "savings": 33, "store": "GOG"}]}},
                  "apps": {"5": {"price": 15, "currency": "HUF"}}}
        wishlist.apply_prices(data, prices, now=50)
        game, app = [wishlist.annotate(item) for item in data["items"]]
        self.assertEqual(game["sale_text"], "On sale at GOG −33%")
        self.assertTrue(game["target_hit"])
        self.assertEqual(app["best"]["savings"], 25)
        self.assertTrue(app["on_sale"])
        self.assertFalse(app["target_hit"])

    RATES = {"base": "EUR", "date": "2026-10-16", "rates": {"EUR": "1", "USD": "1.0", "HUF": "400"}}

    def test_target_in_huf_round_trip(self):
        path, _ = self.drive("A")
        wishlist.add(path, {"title": "Hollow Knight", "game_id": "100"})
        wishlist.set_target(path, "cs:100", 4000, "HUF")
        raw = json.loads(path.read_text())["items"][0]
        self.assertEqual((raw["target_price"], raw["target_currency"]), (4000, "HUF"))
        self.assertEqual(wishlist.read(path)["items"][0]["target_currency"], "HUF")
        wishlist.set_target(path, "cs:100", None, "HUF")
        raw = json.loads(path.read_text())["items"][0]
        self.assertEqual((raw["target_price"], raw["target_currency"]), (None, None), "Clearing drops the currency too")
        with self.assertRaises(wishlist.WishlistError):
            wishlist.set_target(path, "cs:100", 5, "dollars")

    def test_old_targets_are_us_dollars(self):
        item = wishlist.normalize_item({"title": "Old", "game_id": "1", "target_price": 5})
        self.assertEqual(item["target_currency"], "USD")
        self.assertIsNone(wishlist.normalize_item({"title": "None", "game_id": "2"})["target_currency"])

    def test_converted_target_comparison(self):
        def item(price, currency, target, target_currency):
            return wishlist.normalize_item({"title": "G", "game_id": "1", "target_price": target, "target_currency": target_currency,
                                            "best": {"price": price, "currency": currency}})
        # 9.99 USD = 3996 HUF at 400 HUF/USD.
        self.assertTrue(wishlist.target_reached(item(9.99, "USD", 4000, "HUF"), self.RATES))
        self.assertTrue(wishlist.target_reached(item(9.99, "USD", 3996, "HUF"), self.RATES), "Exactly at the target counts")
        # 9.99 USD at 400.03 is 3996.2997 HUF: it would round to 3996, but the unrounded value is above a 3996 target.
        fractional = {"rates": {"EUR": "1", "USD": "1.0", "HUF": "400.03"}}
        self.assertFalse(wishlist.target_reached(item(9.99, "USD", 3996, "HUF"), fractional), "No premature rounding")
        self.assertFalse(wishlist.target_reached(item(9.99, "USD", 3000, "HUF"), self.RATES))
        self.assertFalse(wishlist.target_reached(item(9.99, "USD", 4000, "HUF"), self.RATES, fee_percent=1), "The card fee counts")
        self.assertTrue(wishlist.target_reached(item(3990, "HUF", 3990, "HUF"), None), "Same currency needs no rates")

    def test_missing_rates_make_the_target_unknown_not_missed(self):
        converted = wishlist.normalize_item({"title": "G", "game_id": "1", "target_price": 4000, "target_currency": "HUF",
                                             "best": {"price": 1, "currency": "USD"}})
        self.assertIsNone(wishlist.target_reached(converted, None))
        self.assertIsNone(wishlist.target_reached(converted, {"rates": {"EUR": "1", "USD": "1.1"}}), "HUF rate missing")
        self.assertIsNone(wishlist.annotate(converted)["target_hit"])
        self.assertTrue(wishlist.annotate(converted, self.RATES)["target_hit"])

    def test_artwork_is_a_link_not_image_data(self):
        path, _ = self.drive("A")
        wishlist.add(path, {"title": "Hollow Knight", "game_id": "100", "thumb": "https://cdn.example/hk.jpg"})
        wishlist.add(path, {"title": "Bad Art", "game_id": "101", "thumb": "data:image/png;base64,AAAA"})
        raw = json.loads(path.read_text())["items"]
        self.assertEqual(raw[0]["thumb"], "https://cdn.example/hk.jpg")
        self.assertIsNone(raw[1]["thumb"], "Only https links are kept; no image data in the file")
        data = wishlist.read(path)
        wishlist.apply_prices(data, {"games": {"101": {"thumb": "https://cdn.example/new.jpg",
                                                         "offers": [{"price": 1, "store": "Steam"}]}}})
        self.assertEqual(data["items"][1]["thumb"], "https://cdn.example/new.jpg", "Price checks fill in missing art")
        self.assertEqual(data["items"][0]["thumb"], "https://cdn.example/hk.jpg", "Art without a new link is kept")
        self.assertNotIn("≈", json.dumps(data), "No converted values are stored")


if __name__ == "__main__":
    unittest.main()


console_spec = importlib.util.spec_from_file_location("wishlist_console", ROOT / "scripts/console.py")
console = importlib.util.module_from_spec(console_spec)
console_spec.loader.exec_module(console)


class LocalWishlistTests(unittest.TestCase):
    """A Mac with no Couch Cube drive set up keeps an editable wishlist, which moves onto the drive later."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        for patcher in [patch.dict(os.environ, {"HOME": str(self.base / "home")}),
                        patch.object(console, "HOST_CONFIG", self.base / "home/setup.json")]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_no_drive_set_up_saves_on_this_mac(self):
        added = console.wishlist_change("add", item={"title": "Hollow Knight", "game_id": "100", "steam_app_id": "367520"})
        self.assertFalse(added["read_only"] or added["offline"])
        self.assertEqual(added["note"], console.LOCAL_WISHLIST_NOTE)
        local = self.base / "home/Library/Application Support/Couch Cube/Wishlist/wishlist.json"
        self.assertEqual([item["title"] for item in json.loads(local.read_text())["items"]], ["Hollow Knight"])
        status = console.wishlist_status()
        self.assertEqual([item["key"] for item in status["items"]], ["cs:100"])
        self.assertFalse(status["read_only"])
        removed = console.wishlist_change("remove", key="cs:100")
        self.assertEqual(removed["items"], [])

    def test_set_up_drive_takes_over_the_local_items(self):
        console.wishlist_change("add", item={"title": "Celeste", "game_id": "200"})
        library = self.base / "Drive/Couch Cube"
        library.mkdir(parents=True)

        class Storage:
            root = library

            def target(self, relative):
                return library / relative

        console.HOST_CONFIG.write_text("{}")
        with patch.object(console, "configured_storage", return_value=Storage()):
            status = console.wishlist_status()
        self.assertEqual(status["merged"], 1)
        self.assertNotEqual(status["note"], console.LOCAL_WISHLIST_NOTE)
        self.assertEqual([item["title"] for item in json.loads((library / "Wishlist/wishlist.json").read_text())["items"]], ["Celeste"])

    def test_disconnected_drive_stays_read_only(self):
        console.HOST_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        console.HOST_CONFIG.write_text("{}")
        with patch.object(console, "configured_storage", side_effect=console.SetupError("gone")):
            self.assertEqual(console.wishlist_location(), (None, None))
            with self.assertRaises(console.SetupError):
                console.wishlist_change("add", item={"title": "Celeste"})


class PriceInsightTests(unittest.TestCase):
    """CheapShark only knows the all-time low (USD, every store it tracks): record or percent above, never rarity."""

    RECORD = {"price": "2.28", "date": 1759177295}

    def test_history_parsing(self):
        self.assertEqual(wishlist.price_history(self.RECORD), {"low": 2.28, "currency": "USD", "date": "2025-09-29"})
        self.assertEqual(wishlist.price_history({"price": "0", "date": 1759177295})["low"], 0.0)
        for bad in (None, "2.28", {}, {"price": "abc", "date": 1}, {"price": "-1", "date": 1}, {"price": "NaN", "date": 1},
                    {"price": "2.28"}, {"price": "2.28", "date": True}, {"price": "2.28", "date": "1759177295"},
                    {"price": "2.28", "date": 0}, {"price": "2.28", "date": 10 ** 20}):
            self.assertIsNone(wishlist.price_history(bad), bad)

    def test_matching_and_below_record(self):
        history = wishlist.price_history(self.RECORD)
        for price in (2.28, "2.28", 1.99):
            insight = wishlist.price_insight(price, "USD", history)
            self.assertEqual((insight["kind"], insight["percent"], insight["low"], insight["date"]), ("record", None, 2.28, "2025-09-29"))

    def test_above_record_rounds_half_up_with_a_minimum(self):
        history = {"low": 2.00, "currency": "USD", "date": "2025-09-29"}
        self.assertEqual(wishlist.price_insight(3.01, "USD", history)["percent"], 51)  # 50.5% → 51
        self.assertEqual(wishlist.price_insight(4.00, "USD", history)["percent"], 100)
        self.assertEqual(wishlist.price_insight(2.001, "USD", history)["percent"], 1, "A hair above is never shown as 0%")
        self.assertEqual(wishlist.price_insight(0.1 + 0.2 + 1.7, "USD", history)["kind"], "record", "Decimal, no float drift")
        free = wishlist.price_insight(9.99, "USD", {"low": 0.0, "currency": "USD", "date": "2025-09-29"})
        self.assertEqual((free["kind"], free["percent"]), ("above", None))

    def test_no_claim_without_comparable_data(self):
        history = wishlist.price_history(self.RECORD)
        self.assertIsNone(wishlist.price_insight(990, "HUF", history), "Never compares across currencies")
        self.assertIsNone(wishlist.price_insight(9.99, "USD", None))
        self.assertIsNone(wishlist.price_insight(None, "USD", history))
        self.assertIsNone(wishlist.price_insight("abc", "USD", history))
        self.assertIsNone(wishlist.price_insight(9.99, None, history))

    def test_annotate_and_app_store(self):
        item = {"title": "Portal 2", "best": {"price": 1.99, "currency": "USD", "savings": 80, "store": "Steam",
                                              "history": {"low": 1.99, "currency": "USD", "date": "2025-09-29"}}}
        self.assertEqual(wishlist.annotate(item)["insight"]["kind"], "record")
        self.assertIsNone(wishlist.annotate({"title": "X", "best": {"price": 1990, "currency": "HUF", "store": "Mac App Store",
                                                                    "history": None}})["insight"])
        self.assertIsNone(wishlist.annotate({"title": "Y"})["insight"])
        for value in wishlist.annotate(item).values():
            self.assertNotIn("average", json.dumps(value).lower())
