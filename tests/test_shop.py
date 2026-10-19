import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("shop", ROOT / "scripts/shop.py")
shop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shop)
FIX = ROOT / "tests/fixtures/shop"
DEALS_FIX = ROOT / "tests/fixtures/deals"


class Response(io.BytesIO):
    def __init__(self, body, url):
        super().__init__(body)
        self.url, self.status, self.headers = url, 200, {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Opener:
    def __init__(self):
        self.requests = []

    def __call__(self, request, timeout):
        url = request.full_url
        self.requests.append(url)
        parts = urllib.parse.urlsplit(url)
        query = urllib.parse.parse_qs(parts.query)
        if parts.path == "/api/1.0/stores":
            name = DEALS_FIX / "cheapshark-stores.json"
        elif parts.path == "/api/1.0/games" and "ids" in query:
            ids = query["ids"][0].split(",")
            assert len(ids) <= 25, "CheapShark allows at most 25 IDs per call"
            data = json.loads((FIX / "cheapshark-games-ids.json").read_text())
            return Response(json.dumps({key: value for key, value in data.items() if key in ids}).encode(), url)
        elif parts.path == "/api/1.0/games":
            name = FIX / "cheapshark-games-search.json"
        elif parts.path == "/api/1.0/deals":
            name = DEALS_FIX / "cheapshark-deals.json"
        elif parts.path == "/api/filter":
            name = DEALS_FIX / "gamerpower-giveaways.json"
        elif parts.path in ("/search", "/lookup"):
            name = FIX / "itunes-search.json"
        else:
            raise AssertionError(url)
        return Response(name.read_bytes(), url)


class ShopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        patcher = patch.object(shop.deals, "cache_dir", return_value=Path(self.temp.name))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.temp.cleanup)

    def test_platform_filter_drops_console_and_mobile(self):
        items = [{"id": "1", "platforms": ["Playstation 5", "Playstation 4"]},
                 {"id": "2", "platforms": ["Nintendo Switch", "Xbox Series X|S", "Xbox One"]},
                 {"id": "3", "platforms": ["PC", "Android", "iOS"]},
                 {"id": "4", "platforms": ["Epic Games Store"]},
                 {"id": "5", "platforms": ["VR"]}]
        kept = shop.pc_only(items)
        self.assertEqual([item["id"] for item in kept], ["3", "4"])
        self.assertEqual(kept[0]["platforms"], ["PC"])
        for banned in ["playstation 4", "playstation 5", "xbox one", "nintendo switch", "android", "ios"]:
            self.assertNotIn(banned, shop.PC_PLATFORMS)

    def test_installed_stores_and_scope(self):
        with tempfile.TemporaryDirectory() as apps, tempfile.TemporaryDirectory() as home:
            (Path(apps) / "GOG Galaxy.app").mkdir()
            clients = [{"id": "mac-steam", "state": "signed_in"}, {"id": "win-epic", "state": "not_installed"},
                       {"id": "win-battlenet", "state": "installed"}]
            mine = shop.installed_stores(clients, home, (apps,))
        self.assertEqual([store["key"] for store in mine], ["steam", "gog", "battlenet"])
        ids, labels = shop.scope_filter(mine)
        self.assertEqual(ids, ["1", "7", "31"])
        self.assertTrue(shop.in_scope({"platforms": ["PC", "Steam"]}, labels))
        self.assertFalse(shop.in_scope({"platforms": ["PC", "Epic Games Store"]}, labels))
        self.assertFalse(shop.in_scope({"platforms": ["PC"]}, labels), "Generic PC giveaways aren't tied to a store")

    def test_home_scope_mine_vs_all(self):
        opener = Opener()
        mine = [{"key": "steam", "name": "Steam"}]
        report = shop.home(mine, "mine", opener=opener, now=1000)
        self.assertEqual(report["scope"], "mine")
        deal_requests = [url for url in opener.requests if "/deals?" in url]
        self.assertTrue(deal_requests and all("storeID=1&" in url or url.endswith("storeID=1") for url in deal_requests))
        self.assertTrue(all("Steam" in item["platforms"] for item in report["free"]))
        everything = shop.home(mine, "all", opener=Opener(), now=1000)
        self.assertEqual(everything["scope"], "all")
        nothing = shop.home([], "mine", opener=Opener(), now=1000)
        self.assertEqual(nothing["scope"], "all", "No installed store falls back to all stores")
        ranked = [shop.score(deal) for deal in report["featured"]]
        self.assertEqual(ranked, sorted(ranked, reverse=True))

    def test_search_groups_sorts_and_keeps_currencies_apart(self):
        opener = Opener()
        result = shop.search("  hollow   knight ", "hu", opener=opener, now=1000)
        self.assertEqual(result["query"], "hollow knight")
        self.assertEqual([game["title"] for game in result["games"]], ["Hollow Knight", "Hollow Knight Fan Pack"],
                         "One section per game; games without offers are dropped")
        offers = result["games"][0]["offers"]
        self.assertEqual([offer["price"] for offer in offers], [9.99, 9.99, 14.99])
        self.assertEqual([offer["store"] for offer in offers], ["GOG", "Humble Store", "Steam"])
        self.assertEqual([offer["cheapest"] for offer in offers], [True, True, False])
        self.assertTrue(all(offer["currency"] == "USD" for offer in offers))
        self.assertTrue(all(offer["url"].startswith("https://www.cheapshark.com/redirect?dealID=") for offer in offers))
        self.assertEqual(offers[0]["savings"], 33)
        store = result["app_store"]
        self.assertEqual((store["country"], store["currency"]), ("HU", "HUF"))
        self.assertTrue(store["apps"] and all(app["currency"] == "HUF" for app in store["apps"]))
        self.assertEqual([app["price"] for app in store["apps"]], sorted(app["price"] for app in store["apps"]))
        self.assertTrue(all(app["url"].startswith("https://apps.apple.com/") for app in store["apps"]))
        itunes = [url for url in opener.requests if "itunes.apple.com" in url][0]
        self.assertIn("entity=macSoftware", itunes)
        self.assertIn("country=hu", itunes)
        again = Opener()
        shop.search("hollow knight", "hu", opener=again, now=1100)
        self.assertEqual(again.requests, [], "Identical searches are served from the cache")
        with self.assertRaises(shop.ShopError):
            shop.search(" a ", opener=Opener(), now=1000)

    def test_itunes_parsing_fixture(self):
        data = json.loads((FIX / "itunes-search.json").read_text())
        apps = [shop.normalize_app(item) for item in data["results"]]
        self.assertTrue(all(app is None for app, raw in zip(apps, data["results"]) if raw["kind"] != "mac-software"),
                        "iOS apps returned by entity=macSoftware are dropped")
        mac = [app for app in apps if app]
        self.assertTrue(mac)
        first = mac[0]
        self.assertTrue(first["id"].isdigit() and first["currency"] == "HUF" and first["store"] == "App Store")
        self.assertIsNone(shop.normalize_app({**data["results"][0], "trackViewUrl": "http://apps.apple.com/x"}))
        self.assertIsNone(shop.normalize_app({**data["results"][0], "genreIds": ["6002"], "primaryGenreName": "Utilities"}))
        self.assertIsNone(shop.normalize_app({**data["results"][0], "currency": "huf"}))
        self.assertEqual(shop.country_code("x1"), "US")

    def test_batch_matching_for_wishlist(self):
        opener = Opener()
        ids = [str(value) for value in range(100, 160)] + ["200", "nope"]
        prices = shop.wishlist_prices([{"game_id": value} for value in ids] + [{"app_store_id": "439924718"}],
                                      "hu", opener=opener, now=1000)
        batches = [url for url in opener.requests if "games?ids=" in url]
        self.assertEqual(len(batches), 3, "61 IDs → 3 calls of at most 25")
        self.assertEqual(sorted(prices["games"]), ["100", "200"])
        self.assertEqual(prices["games"]["100"]["offers"][0]["price"], 9.99)
        self.assertIn("439924718", prices["apps"])
        self.assertEqual(prices["errors"], [])


if __name__ == "__main__":
    unittest.main()
