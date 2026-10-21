import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("steam_library", ROOT / "scripts/steam_library.py")
sl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sl)

LOCALCONFIG = '''"UserLocalConfigStore"
{
\t"friends" { "123" { "name" "x" } }
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"apps"
\t\t\t\t{
\t\t\t\t\t"620" { "LastPlayed" "1700000000" "cloud" { "1" "2" } }
\t\t\t\t\t"440" { "Playtime" "5" }
\t\t\t\t}
\t\t\t\t"ConnectCache" { "abc" "secret-token" }
\t\t\t}
\t\t}
\t}
}
'''


class FakeResponse:
    def __init__(self, url, data):
        self.url, self.body, self.status, self.headers = url, json.dumps(data).encode(), 200, {}

    def read(self, limit):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class SteamLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        sl.deals.cache_dir = lambda: Path(self.temp.name) / "cache"

    def test_owned_games_are_app_id_keys_only(self):
        self.assertEqual(sl.app_ids_in_localconfig(LOCALCONFIG), ["620", "440"])
        self.assertEqual(sl.app_ids_in_localconfig("garbage {"), [])

    def test_owned_games_read_from_the_account_folder(self):
        steam_id = "76561198000000002"
        config = Path(self.temp.name) / "userdata" / str(int(steam_id) - sl.STEAMID64_BASE) / "config"
        config.mkdir(parents=True)
        (config / "localconfig.vdf").write_text(LOCALCONFIG)
        self.assertEqual(sl.owned_app_ids(self.temp.name, steam_id), ["620", "440"])
        self.assertEqual(sl.owned_app_ids(self.temp.name, "../../etc"), [])

    def test_public_wishlist_sorted_by_priority(self):
        def opener(request, timeout):
            self.assertTrue(request.full_url.startswith(sl.STEAM_API))
            self.assertNotIn("key=", request.full_url)
            return FakeResponse(request.full_url, {"response": {"items": [
                {"appid": 10, "priority": 2}, {"appid": 20, "priority": 1}, {"appid": 30, "priority": 0}, {"appid": "x"}]}})
        ids, error = sl.wishlist_app_ids("76561198000000002", opener=opener)
        self.assertEqual((ids, error), (["20", "10", "30"], None))

    def test_game_for_app_needs_matching_app_id(self):
        def opener(request, timeout):
            return FakeResponse(request.full_url, [{"gameID": "7", "steamAppID": "99", "external": "Other", "thumb": None},
                                                   {"gameID": "8", "steamAppID": "620", "external": "Portal  2",
                                                    "thumb": "https://cdn.cloudflare.steamstatic.com/a.jpg"}])
        self.assertEqual(sl.game_for_app("620", opener=opener)["title"], "Portal 2")
        self.assertEqual(sl.game_for_app("620", opener=opener)["game_id"], "8")

    def test_new_items_skip_seen_and_known(self):
        lookups = []

        def lookup(app_id):
            lookups.append(app_id)
            return None if app_id == "4" else {"title": "Game " + app_id, "game_id": app_id, "thumb": None}
        items, seen, error = sl.new_items(["1", "2", "3", "4"], {"1"}, {"2"}, lookup)
        self.assertEqual([item["steam_app_id"] for item in items], ["3"])
        self.assertEqual(seen, ["2", "3", "4"])
        self.assertEqual(lookups, ["3", "4"])
        self.assertIsNone(error)

    def test_link_file_round_trip(self):
        path = Path(self.temp.name) / "link.json"
        sl.write_link(path, {"steam_id": "76561198000000002", "seen": ["1", "x"], "synced": 5})
        self.assertEqual(sl.read_link(path), {"steam_id": "76561198000000002", "seen": ["1"], "synced": 5})
        path.write_text('{"steam_id": "nope"}')
        self.assertEqual(sl.read_link(path), {})


if __name__ == "__main__":
    unittest.main()
