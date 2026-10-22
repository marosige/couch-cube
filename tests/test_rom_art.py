import importlib.util
from pathlib import Path
import tempfile
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rom_art", ROOT / "scripts/rom_art.py")
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)

PNG = b"\x89PNG\r\n\x1a\n" + b"x" * 20


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
    def __init__(self, found):
        self.found, self.requests = found, []

    def __call__(self, request, timeout):
        self.requests.append(request.full_url)
        if request.full_url in self.found:
            return Response(request.full_url, PNG)
        raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, None)


class RomArtTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def test_names_follow_libretro_rules_and_try_regions(self):
        urls = art.candidates("snes", "Super Mario World")
        self.assertTrue(all(url.startswith("https://thumbnails.libretro.com/") for url in urls))
        self.assertEqual(urllib_unquote(urls[0]).rsplit("/", 1)[1], "Super Mario World.png")
        self.assertIn("Super Mario World (USA).png", [urllib_unquote(url).rsplit("/", 1)[1] for url in urls])
        self.assertTrue(urllib_unquote(art.candidates("gc", "Zelda: Wind Waker")[0]).endswith("Zelda_ Wind Waker.png"))
        self.assertEqual(art.candidates("switch", "Mario Party"), [], "No libretro set: no requests")

    def test_found_cover_is_saved_and_misses_are_remembered(self):
        target = art.candidates("snes", "Super Mario World")[1]
        opener = Opener({target})
        found = art.find("snes", "Super Mario World", now=1000, opener=opener, folder=self.folder)
        self.assertTrue(found and found.read_bytes() == PNG)
        self.assertEqual(art.find("snes", "Super Mario World", now=1000, opener=Opener(set()), folder=self.folder), found)
        missing = Opener(set())
        self.assertIsNone(art.find("snes", "Unknown Game", now=1000, opener=missing, folder=self.folder))
        again = Opener(set())
        self.assertIsNone(art.find("snes", "Unknown Game", now=2000, opener=again, folder=self.folder))
        self.assertEqual(again.requests, [], "A miss isn't asked again within a week")

    def test_covers_limits_new_downloads(self):
        roms = [{"system": "snes", "name": f"Game {index}", "path": f"/r/{index}.sfc"} for index in range(5)]
        report = art.covers(roms, limit=2, now=1000, opener=Opener(set()), folder=self.folder)
        self.assertEqual(report["covers"], {})
        self.assertTrue(report["more"])
        later = art.covers(roms, limit=2, now=1000, opener=Opener(set()), folder=self.folder)
        self.assertTrue(later["more"], "Remembered misses don't use the budget, so the next games get their turn")
        self.assertFalse(art.covers([{"system": "switch", "name": "X", "path": "/s"}] * 5, limit=1, now=1000,
                                    opener=Opener(set()), folder=self.folder)["more"], "No libretro set: nothing to fetch")


def urllib_unquote(value):
    import urllib.parse
    return urllib.parse.unquote(value)


if __name__ == "__main__":
    unittest.main()
