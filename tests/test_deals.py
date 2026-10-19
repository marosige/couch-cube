import email.message
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("deals", ROOT / "scripts/deals.py")
deals = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deals)
FIXTURES = ROOT / "tests/fixtures/deals"


class FakeResponse(io.BytesIO):
    def __init__(self, body, url, status=200, headers=None):
        super().__init__(body)
        self.url, self.status, self.headers = url, status, headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    """Serves fixture files by endpoint and records every request, so caching is observable."""

    def __init__(self, routes=None, final_url=None, error=None):
        self.routes = routes or {
            "/api/1.0/stores": ("cheapshark-stores.json", {}),
            "/api/1.0/deals": ("cheapshark-deals.json", {"X-Total-Page-Count": "3"}),
            "/api/giveaways": ("gamerpower-giveaways.json", {}),
            "/api/filter": ("gamerpower-giveaways.json", {}),
        }
        self.final_url, self.error, self.requests = final_url, error, []

    def __call__(self, request, timeout):
        self.requests.append(request)
        if self.error:
            raise self.error
        url = request.full_url
        path = url.split("?")[0].split("gamerpower.com")[-1].split("cheapshark.com")[-1]
        name, headers = self.routes[path]
        body = (FIXTURES / name).read_bytes() if name else b""
        return FakeResponse(body, self.final_url or url, 201 if name is None else 200, headers)


class DealsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        cache = patch.object(deals, "cache_dir", return_value=Path(temporary.name))
        cache.start()
        self.addCleanup(cache.stop)

    def test_store_deals_parse_and_reject_unsafe_entries(self):
        opener = FakeOpener()
        result = deals.store_deals(opener=opener, now=1000)
        titles = [deal["title"] for deal in result["deals"]]
        self.assertEqual(titles, ["The Witcher 3: Wild Hunt Remastered", "Portal 2", "Portal 2"])
        witcher = result["deals"][0]
        self.assertEqual((witcher["sale_price"], witcher["normal_price"], witcher["savings"]), (24.99, 49.99, 50))
        self.assertEqual(witcher["store"], "GOG")
        self.assertEqual(witcher["deal_rating"], 10.0)
        self.assertEqual(witcher["url"], "https://www.cheapshark.com/redirect?dealID=OR%2BVz0QIAULaNU5tjUdvoTs3iqGm6lodrS%2BXzXvxPXg%3D")
        self.assertIsNone(result["deals"][1]["thumb"], "Insecure artwork URLs are dropped")
        knockoff = result["deals"][2]
        self.assertIsNone(knockoff["metacritic"])
        self.assertIsNone(knockoff["steam_rating"])
        self.assertEqual([store["name"] for store in result["stores"]], ["GOG", "Humble Store", "Steam"],
                         "Inactive stores are not offered as filters")
        self.assertTrue(result["more"])
        self.assertEqual(result["pages"], 3)
        self.assertNotIn("Mac", json.dumps(result), "No platform compatibility is claimed")

    def test_installed_requires_exact_steam_app_id(self):
        result = deals.store_deals(installed=frozenset({"620"}), opener=FakeOpener(), now=1000)
        flags = [(deal["title"], deal["steam_app_id"], deal["installed"]) for deal in result["deals"]]
        self.assertEqual(flags, [("The Witcher 3: Wild Hunt Remastered", "292030", False),
                                 ("Portal 2", "620", True), ("Portal 2", None, False)],
                         "A same-named deal without the Steam app ID is never marked installed")

    def test_query_parameters_and_validation(self):
        opener = FakeOpener()
        deals.store_deals(page=2, sort="price", store="7", search="  the   witcher " + "x" * 80, opener=opener, now=1000)
        url = opener.requests[-1].full_url
        self.assertIn("pageNumber=2", url)
        self.assertIn("sortBy=Price", url)
        self.assertIn("desc=0", url)
        self.assertIn("storeID=7", url)
        self.assertIn("title=the+witcher+xxx", url)
        self.assertEqual(opener.requests[-1].get_header("User-agent"), deals.USER_AGENT)
        for bad in [{"sort": "metacritic; drop"}, {"store": "7&evil=1"}]:
            with self.assertRaises(deals.DealsError):
                deals.store_deals(opener=opener, now=1000, **bad)
        with self.assertRaises(deals.DealsError):
            deals.giveaways(platform="../etc", opener=opener, now=1000)
        with self.assertRaises(deals.DealsError):
            deals.giveaways(kind="everything", opener=opener, now=1000)

    def test_cache_reuse_refresh_floor_and_expiry(self):
        opener = FakeOpener()
        first = deals.store_deals(opener=opener, now=1000)
        count = len(opener.requests)
        again = deals.store_deals(opener=opener, now=1100)
        self.assertEqual(len(opener.requests), count, "Fresh cache is reused")
        self.assertTrue(again["cached"])
        deals.store_deals(refresh=True, opener=opener, now=1030)
        self.assertEqual(len(opener.requests), count, "Repeated refresh clicks are coalesced")
        deals.store_deals(refresh=True, opener=opener, now=1200)
        self.assertEqual(len(opener.requests), count + 1, "A deliberate refresh after the floor fetches deals only")
        deals.store_deals(opener=opener, now=1200 + deals.FRESH_SECONDS["deals"] + 1)
        self.assertEqual(len(opener.requests), count + 2)
        self.assertEqual(first["deals"], again["deals"])

    def test_offline_keeps_last_results_marked_stale(self):
        deals.store_deals(opener=FakeOpener(), now=1000)
        offline = FakeOpener(error=urllib.error.URLError("offline"))
        stale = deals.store_deals(refresh=True, opener=offline, now=5000)
        self.assertTrue(stale["stale"])
        self.assertIn("internet", stale["error"])
        self.assertEqual(len(stale["deals"]), 3)
        with self.assertRaises(deals.DealsError):
            deals.giveaways(opener=offline, now=5000)

    def test_rate_limit_is_respected_without_retrying(self):
        headers = email.message.Message()
        headers["Retry-After"] = "600"
        limited = FakeOpener(error=urllib.error.HTTPError("https://www.cheapshark.com/api/1.0/stores", 429, "Too Many", headers, None))
        with self.assertRaises(deals.DealsError) as raised:
            deals.store_deals(opener=limited, now=1000)
        self.assertIn("10 min", str(raised.exception))
        working = FakeOpener()
        with self.assertRaises(deals.DealsError):
            deals.store_deals(opener=working, now=1300)
        self.assertEqual(working.requests, [], "No requests while CheapShark's block is active")
        deals.store_deals(opener=working, now=1601)
        self.assertTrue(working.requests)

    def test_redirect_to_unexpected_host_is_rejected(self):
        with self.assertRaises(deals.DealsError):
            deals.store_deals(opener=FakeOpener(final_url="https://evil.example/api"), now=1000)

    def test_giveaways_parse_attribution_links_and_filters(self):
        opener = FakeOpener()
        result = deals.giveaways(platform="steam", kind="game", sort="value", opener=opener, now=1000)
        self.assertEqual([item["id"] for item in result["giveaways"]], ["3100", "3819", "4002"],
                         "Off-site links, expired and console-only giveaways are dropped")
        first, second, mixed = result["giveaways"]
        self.assertEqual(mixed["platforms"], ["PC"], "Mobile, VR and console platforms are never shown")
        self.assertEqual(first["worth"], "$5.99")
        self.assertEqual(first["platforms"], ["PC", "Itch.io", "DRM-Free"])
        self.assertEqual(first["url"], "https://www.gamerpower.com/open/the-black-within-itch-io-giveaway")
        self.assertIsNone(second["worth"])
        self.assertIsNone(second["end_date"])
        url = opener.requests[-1].full_url
        self.assertTrue(url.startswith("https://www.gamerpower.com/api/filter?"))
        for part in ["platform=steam", "type=game", "sort-by=value"]:
            self.assertIn(part, url)

    def test_giveaways_never_request_console_platforms(self):
        opener = FakeOpener()
        deals.giveaways(opener=opener, now=1000)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(opener.requests[-1].full_url).query)
        requested = query["platform"][0].split(".")
        self.assertIn("steam", requested)
        for banned in ["ps4", "ps5", "xbox-one", "xbox-series-xs", "switch", "android", "ios", "vr"]:
            self.assertNotIn(banned, requested)
            with self.assertRaises(deals.DealsError):
                deals.giveaways(platform=banned, opener=opener, now=1000)
        self.assertNotIn("4001", [item["id"] for item in deals.giveaways(opener=opener, now=1000)["giveaways"]])

    def test_no_active_giveaways_is_empty_not_error(self):
        opener = FakeOpener(routes={"/api/filter": (None, {})})
        self.assertEqual(deals.giveaways(opener=opener, now=1000)["giveaways"], [])

    def test_url_validation(self):
        self.assertEqual(deals.https_url("https://www.gamerpower.com/x", deals.GAMERPOWER_HOSTS), "https://www.gamerpower.com/x")
        for bad in ["http://www.gamerpower.com/x", "https://www.gamerpower.com.evil.example/x",
                    "https://user@www.gamerpower.com/x", "https://www.gamerpower.com:8443/x",
                    "javascript:alert(1)", "file:///etc/passwd", "https://www.gamerpower.com/a b", None, 42]:
            self.assertIsNone(deals.https_url(bad, deals.GAMERPOWER_HOSTS), bad)
        self.assertIsNone(deals.cheapshark_link("javascript:alert(1)"))
        self.assertEqual(deals.cheapshark_link("abc+DEF/123="), "https://www.cheapshark.com/redirect?dealID=abc%2BDEF%2F123%3D")


if __name__ == "__main__":
    unittest.main()
