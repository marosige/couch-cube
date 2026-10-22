import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("library_console", Path(__file__).resolve().parents[1] / "scripts/console.py")
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class FakeStorage:
    def __init__(self, root):
        self.root = root

    def target(self, name):
        return self.root / name

    def read_path(self, name):
        return self.root / name


class LibraryGamesTests(unittest.TestCase):
    """The Play page lists games only: ROMs of shown consoles, game apps and Windows shortcuts, no launchers."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root, self.home = base / "Couch Cube", base / "home"
        (self.root / "ROMs/snes").mkdir(parents=True)
        (self.root / "ROMs/psx").mkdir(parents=True)
        (self.root / "ROMs/n64").mkdir(parents=True)
        (self.root / "ROMs/snes/Super Mario World.sfc").write_bytes(b"rom")
        (self.root / "ROMs/snes/notes.txt").write_text("not a game")
        (self.root / "ROMs/psx/Crash (Disc 1).bin").write_bytes(b"bin")
        (self.root / "ROMs/psx/Crash.cue").write_text('FILE "Crash (Disc 1).bin" BINARY\n')
        (self.root / "ROMs/n64/Mario Kart 64.z64").write_bytes(b"rom")
        for folder in ["Native/Games/Celeste.app", "Windows/Porting Kit/Warcraft II.app",
                       "Windows/Porting Kit/Uninstall Warcraft II.app"]:
            (self.root / folder).mkdir(parents=True)
        for folder in ["Applications/CrossOver/Steam/Rocket League.app", "Applications/CrossOver/Steam/Setup Steam.app",
                       "Applications/CrossOver/Steam/Steam.app", "Applications/CrossOver/Battle.net/Battle.net.app",
                       "Applications/CrossOver/Battle.net/Warcraft III.app"]:
            (self.home / folder).mkdir(parents=True)
        (self.root / console.MARKER).write_text(json.dumps({"systems": ["snes", "psx"]}))

    def test_games_from_every_source(self):
        report = console.library_games(FakeStorage(self.root), home=self.home)
        roms = {(rom["system"], rom["name"]): Path(rom["path"]).name for rom in report["roms"]}
        self.assertEqual(roms, {("snes", "Super Mario World"): "Super Mario World.sfc", ("psx", "Crash"): "Crash.cue"},
                         "Descriptor sets launch from their .cue; hidden consoles (N64 here) are left out")
        apps = {(app["kind"], app["name"], app["group"]) for app in report["apps"]}
        self.assertEqual(apps, {("native", "Celeste", None), ("porting-kit", "Warcraft II", None),
                                ("crossover", "Rocket League", "Steam"), ("crossover", "Warcraft III", "Battle.net")},
                         "Installers, uninstallers and store launchers (Steam, Battle.net) are not games")

    def test_game_folders_start_their_largest_playable_file(self):
        (self.root / "ROMs/gc/Mario Kart Double Dash").mkdir(parents=True)
        (self.root / "ROMs/gc/Mario Kart Double Dash/game.rvz").write_bytes(b"x" * 10)
        (self.root / "ROMs/switch/Mario Party").mkdir(parents=True)
        (self.root / "ROMs/switch/Mario Party/base.nsp").write_bytes(b"x" * 100)
        (self.root / "ROMs/switch/Mario Party/update.nsp").write_bytes(b"x" * 5)
        (self.root / "ROMs/switch/Empty folder").mkdir()
        (self.root / console.MARKER).write_text(json.dumps({"systems": ["gc", "switch"]}))
        report = console.library_games(FakeStorage(self.root), home=self.home)
        roms = {(rom["system"], rom["name"]): Path(rom["path"]).name for rom in report["roms"]}
        self.assertEqual(roms, {("gc", "Mario Kart Double Dash"): "game.rvz", ("switch", "Mario Party"): "base.nsp"},
                         "A game folder is one game (updates and DLC beside it); folders without a game are skipped")
        counts = {system["id"]: system["games"] for system in console.populated_systems(self.root)}
        self.assertEqual((counts["gc"], counts["switch"]), (1, 1), "Counts games, not files")

    def test_console_detail_lists_games_with_their_saves_and_states(self):
        (self.root / "Saves/RetroArch/States").mkdir(parents=True)
        (self.root / "Saves/RetroArch/Super Mario World.srm").write_bytes(b"s")
        (self.root / "Saves/RetroArch/States/Super Mario World.state").write_bytes(b"s")
        (self.root / "Saves/RetroArch/States/Super Mario World.state1").write_bytes(b"s")
        (self.root / "Saves/RetroArch/States/Super Mario World.state1.png").write_bytes(b"s")
        (self.root / "BIOS/retroarch").mkdir(parents=True)
        detail = console.console_detail(FakeStorage(self.root), "snes")
        self.assertEqual(detail["name"], "Super Nintendo")
        self.assertEqual([(game["name"], game["saves"], game["states"]) for game in detail["games"]], [("Super Mario World", 1, 2)])
        self.assertIsNone(detail["saves_where"])
        (self.root / "ROMs/gc").mkdir()
        self.assertEqual(console.console_detail(FakeStorage(self.root), "gc")["saves_where"], "Dolphin")

    def test_symlinked_folders_are_not_followed(self):
        (self.home / "elsewhere/Fake.app").mkdir(parents=True)
        (self.home / "Applications/CrossOver/Linked").symlink_to(self.home / "elsewhere")
        names = [app["name"] for app in console.library_games(FakeStorage(self.root), home=self.home)["apps"]]
        self.assertNotIn("Fake", names)


if __name__ == "__main__":
    unittest.main()
