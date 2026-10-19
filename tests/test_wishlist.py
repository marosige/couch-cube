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


if __name__ == "__main__":
    unittest.main()
