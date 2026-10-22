import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("steamgriddb", ROOT / "scripts/steamgriddb.py")
grid = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grid)

KEY = "abcdef0123456789abcdef0123456789"


class Response:
    def __init__(self, url, body):
        self.url, self.body = url, body

    def read(self, limit):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class Opener:
    def __init__(self):
        self.requests = []

    def __call__(self, request, timeout):
        url = request.full_url
        self.requests.append((url, request.get_header("Authorization")))
        if url.startswith(grid.API + "search/autocomplete/"):
            return Response(url, json.dumps({"success": True, "data": [{"id": 42, "name": "Mario Party"}]}).encode())
        if url.startswith(grid.API + "grids/game/42"):
            return Response(url, json.dumps({"success": True, "data": [{"url": "https://cdn2.steamgriddb.com/grid/a.png"}]}).encode())
        if url.startswith(grid.API + "heroes/game/42"):
            return Response(url, json.dumps({"success": True, "data": [{"url": "https://evil.example/hero.png"}]}).encode())
        if url.startswith(grid.API):
            return Response(url, json.dumps({"success": True, "data": []}).encode())
        if url == "https://cdn2.steamgriddb.com/grid/a.png":
            return Response(url, b"\x89PNGgrid")
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)


class SteamGridDBTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def test_no_key_means_no_requests(self):
        opener = Opener()
        report = grid.artwork([{"key": "/r/a", "name": "Mario Party"}], None, opener=opener, folder=self.folder)
        self.assertEqual((report["enabled"], report["art"], opener.requests), (False, {}, []))

    def test_key_file_in_the_library_is_validated(self):
        path = self.folder / "steamgriddb.json"
        path.write_text(grid.key_file_content(KEY))
        self.assertEqual(grid.api_key(path), KEY)
        path.write_text('{"api_key": "not a key; rm -rf"}')
        self.assertIsNone(grid.api_key(path))
        self.assertIsNone(grid.api_key(self.folder / "missing.json"))
        with self.assertRaises(grid.GridError):
            grid.key_file_content("bad key")

    def test_saves_cdn_images_only_and_sends_key_to_the_api_only(self):
        opener = Opener()
        report = grid.artwork([{"key": "/r/a", "name": "Mario Party"}], KEY, opener=opener, folder=self.folder, now=1000)
        art = report["art"]["/r/a"]
        self.assertEqual(set(art), {"grid"}, "The hero on a foreign host is skipped")
        self.assertEqual(Path(art["grid"]).read_bytes(), b"\x89PNGgrid")
        for url, authorization in opener.requests:
            self.assertEqual(authorization is not None, url.startswith(grid.API), url)
        again = Opener()
        self.assertEqual(grid.artwork([{"key": "/r/a", "name": "Mario Party"}], KEY, opener=again, folder=self.folder)["art"]["/r/a"], art)
        self.assertEqual(again.requests, [], "Saved art is reused")


if __name__ == "__main__":
    unittest.main()
