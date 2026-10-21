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
        elif parts.path == "/api/appdetails":
            app = query["appids"][0]
            data = json.loads((FIX / "steam-appdetails.json").read_text())
            return Response(json.dumps({app: data.get(app, {"success": False})}).encode(), url)
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

    def test_all_time_low_from_games_lookup(self):
        games, _ = shop.games_by_ids(["100", "200"], opener=Opener(), now=1000)
        self.assertEqual(games["100"]["history"], {"low": 4.99, "currency": "USD", "date": "1970-01-01"})
        self.assertEqual((games["100"]["insight"]["kind"], games["100"]["insight"]["percent"]), ("above", 100),
                         "Best offer 9.99 vs record 4.99")
        self.assertIsNone(games["200"]["history"])
        self.assertIsNone(games["200"]["insight"], "No record, no claim")

    def test_steam_store_facts_for_the_game_page(self):
        facts = shop.steam_details("620", opener=Opener(), now=1000)
        missing = shop.steam_details("999", opener=Opener(), now=1000)
        self.assertTrue(facts["found"])
        self.assertEqual(facts["description"], 'The "Perpetual Testing Initiative" has been expanded to allow you to design co-op puzzles .')
        self.assertEqual(facts["genres"], ["Action", "Adventure"])
        self.assertEqual(facts["developers"], ["Valve"])
        self.assertEqual(facts["release"], "18 Apr, 2011")
        self.assertEqual(facts["storage_bytes"], 8 * 1024 ** 3, "The Mac requirement wins for Mac games")
        self.assertEqual(facts["controller"], "full")
        self.assertEqual(facts["couch"], ["Shared/Split Screen", "Shared/Split Screen Co-op"])
        self.assertEqual(len(facts["screenshots"]), 2, "Only https screenshots")
        self.assertFalse(missing["found"])
        with self.assertRaises(shop.ShopError):
            shop.steam_details("abc", opener=Opener(), now=1000)

    def test_deals_get_their_all_time_low(self):
        deals_list = [{"id": "a", "game_id": "100", "sale_price": 4.99}, {"id": "b", "game_id": "200", "sale_price": 1.0},
                      {"id": "c", "game_id": None, "sale_price": 2.0}]
        enriched = shop.with_insights(deals_list, opener=Opener(), now=1000)
        self.assertEqual(enriched[0]["insight"]["kind"], "record", "4.99 equals Hollow Knight's recorded low")
        self.assertNotIn("insight", enriched[1], "No history, no claim")
        self.assertNotIn("insight", enriched[2])

    def test_single_game_for_the_game_page(self):
        report = shop.game("100", opener=Opener(), now=1000)
        self.assertEqual(report["game"]["title"], "Hollow Knight")
        self.assertEqual([offer["price"] for offer in report["game"]["offers"]], [9.99, 9.99, 14.99])
        self.assertEqual(report["game"]["history"]["low"], 4.99)
        self.assertEqual(report["errors"], [])
        self.assertIsNone(shop.game("12345", opener=Opener(), now=1000)["game"], "Unknown IDs are not invented")
        with self.assertRaises(shop.ShopError):
            shop.game("../1", opener=Opener(), now=1000)



class SteamPlatformTests(unittest.TestCase):
    """Mac / Windows-only badges come only from Steam's own platform flags; anything else stays unknown."""

    GAMES = {"620": {"windows": True, "mac": True, "linux": True},   # both builds
             "1091500": {"windows": True, "mac": False, "linux": False},  # Windows only
             "300": {"windows": False, "mac": True, "linux": False}}  # Mac only

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        patcher = patch.object(shop.deals, "cache_dir", return_value=Path(self.temp.name))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.temp.cleanup)
        self.requests = []

    def opener(self, request, timeout):
        url = request.full_url
        self.requests.append(url)
        parts = urllib.parse.urlsplit(url)
        assert parts.netloc == "store.steampowered.com" and parts.path == "/api/appdetails", url
        query = urllib.parse.parse_qs(parts.query)
        app_id = query["appids"][0]
        assert "," not in app_id and query["filters"] == ["platforms"], "One game per request, platforms only"
        if app_id in self.GAMES:
            body = {app_id: {"success": True, "data": {"platforms": self.GAMES[app_id]}}}
        elif app_id == "404":
            body = {app_id: {"success": False}}
        else:
            body = {app_id: {"success": True, "data": {}}}
        return Response(json.dumps(body).encode(), url)

    def test_statuses(self):
        report = shop.steam_platforms(["620", "1091500", "300", "404", "777", "abc", "0", "620"], opener=self.opener, now=100)
        statuses = {key: value["status"] for key, value in report["platforms"].items()}
        self.assertEqual(statuses, {"620": "mac", "1091500": "windows", "300": "mac", "404": None, "777": None})
        self.assertEqual(report["platforms"]["620"]["windows"], True, "Both builds: Mac, with the Windows build noted")
        self.assertEqual(len(self.requests), 5, "Invalid and repeated IDs aren't looked up")

    def test_no_false_windows_only(self):
        self.assertIsNone(shop.platform_status({"windows": True}), "A missing mac flag isn't evidence of Windows only")
        self.assertIsNone(shop.platform_status({}))
        self.assertIsNone(shop.platform_status(None))
        self.assertIsNone(shop.platform_status({"windows": False, "mac": False}))
        self.assertEqual(shop.platform_status({"windows": True, "mac": False}), "windows")
        self.assertEqual(shop.platform_status({"windows": True, "mac": True}), "mac")

    def test_cached_for_a_week_and_capped(self):
        ids = [str(value) for value in range(1, 31)]
        first = shop.steam_platforms(ids, opener=self.opener, now=100, limit=12)
        self.assertEqual(len(self.requests), 12, "Only a few new games are looked up per call")
        self.assertEqual(len(first["pending"]), 18)
        shop.steam_platforms(ids[:12], opener=self.opener, now=100 + 6 * 24 * 3600)
        self.assertEqual(len(self.requests), 12, "Looked-up games come from the week-long cache")
        second = shop.steam_platforms(ids, opener=self.opener, now=200, limit=12)
        self.assertEqual(len(self.requests), 24)
        self.assertEqual(len(second["platforms"]), 24)


if __name__ == "__main__":
    unittest.main()
