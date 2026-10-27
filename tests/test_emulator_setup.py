import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock

spec = importlib.util.spec_from_file_location("emulator_setup", Path(__file__).resolve().parents[1] / "scripts/emulator_setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class EmulatorSetupTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.library = Path(temp.name) / "library"
        self.home = Path(temp.name) / "home"
        for folder in setup.BIOS_FOLDERS.values():
            (self.library / folder).mkdir(parents=True)
        self.home.mkdir()

    def put(self, relative, size=10):
        path = self.library / relative
        path.write_bytes(b"x" * size)
        return path

    def test_ini_merge_keeps_other_lines_and_updates_in_place(self):
        ini = self.home / "a.ini"
        ini.write_text("[UI]\n# mine\nKeep = 1\nStartFullscreen = false\n\n[Other]\nX = 1\n")
        setup.ini_merge(ini, {"UI": {"StartFullscreen": "true", "New": "2"}, "Pad1": {"Type": "DualShock2"}})
        self.assertEqual(ini.read_text(),
                         "[UI]\n# mine\nKeep = 1\nStartFullscreen = true\nNew = 2\n\n[Other]\nX = 1\n\n[Pad1]\nType = DualShock2\n")

    def test_pcsx2_gets_bios_and_four_controllers_once(self):
        self.put("BIOS/ps2/scph70012.bin", 4_000_000)
        self.put("BIOS/ps2/readme.txt")
        state = {}
        notes = setup.prepare("pcsx2", self.library, self.home, state=state)
        data = self.home / "Library/Application Support/PCSX2"
        self.assertTrue((data / "bios/scph70012.bin").is_file())
        self.assertFalse((data / "bios/readme.txt").exists())
        ini = (data / "inis/PCSX2.ini").read_text()
        for expected in ["StartFullscreen = true", "[Pad5]", "Cross = SDL-3/A", "Cross = SDL-1/A", "MultitapPort1 = false"]:
            self.assertIn(expected, ini)
        self.assertEqual(state, {"pcsx2": 1})
        self.assertTrue(any("configured" in note for note in notes))
        (data / "inis/PCSX2.ini").write_text("[UI]\nStartFullscreen = false\n")
        self.assertEqual(setup.prepare("pcsx2", self.library, self.home, state=state), [])
        self.assertIn("false", (data / "inis/PCSX2.ini").read_text(), "Player's later changes are left alone")

    def test_existing_pcsx2_config_is_backed_up_and_bios_not_overwritten(self):
        self.put("BIOS/ps2/b.bin", 4_000_000)
        data = self.home / "Library/Application Support/PCSX2"
        (data / "bios").mkdir(parents=True)
        (data / "bios/b.bin").write_bytes(b"theirs")
        (data / "inis").mkdir()
        (data / "inis/PCSX2.ini").write_text("[UI]\nTheme = dark\n")
        setup.prepare("pcsx2", self.library, self.home, state={})
        self.assertEqual((data / "bios/b.bin").read_bytes(), b"theirs")
        self.assertEqual((data / "inis/PCSX2.ini.couchcube-backup").read_text(), "[UI]\nTheme = dark\n")
        self.assertIn("Theme = dark", (data / "inis/PCSX2.ini").read_text())

    def test_missing_ps2_bios_is_reported(self):
        notes = setup.prepare("pcsx2", self.library, self.home, state={})
        self.assertTrue(any("BIOS missing" in note for note in notes))

    def test_rpcs3_installs_firmware_only_when_needed(self):
        run = MagicMock()
        self.assertIn("missing", setup.prepare("rpcs3", self.library, self.home, "/rpcs3", run=run)[0])
        run.assert_not_called()
        pup = self.put("BIOS/ps3/PS3UPDAT.PUP")
        setup.prepare("rpcs3", self.library, self.home, "/rpcs3", run=run)
        run.assert_called_once_with(["/rpcs3", "--installfw", str(pup)], check=True, timeout=1800)
        flash = self.home / "Library/Application Support/rpcs3/dev_flash/sys"
        flash.mkdir(parents=True)
        (flash / "x").write_text("")
        run.reset_mock()
        self.assertEqual(setup.prepare("rpcs3", self.library, self.home, "/rpcs3", run=run), [])
        run.assert_not_called()

    def test_switch_keys_are_copied_without_overwriting(self):
        self.put("BIOS/switch/prod.keys")
        self.put("BIOS/switch/other.txt")
        setup.prepare("switch", self.library, self.home)
        keys = self.home / "Library/Application Support/Ryujinx/system"
        self.assertTrue((keys / "prod.keys").is_file())
        self.assertFalse((keys / "other.txt").exists())
        (keys / "prod.keys").write_bytes(b"mine")
        setup.prepare("switch", self.library, self.home)
        self.assertEqual((keys / "prod.keys").read_bytes(), b"mine")

    def test_dolphin_enables_four_ports_once(self):
        state = {}
        setup.prepare("dolphin", self.library, self.home, state=state)
        ini = (self.library / "Saves/Dolphin/Config/Dolphin.ini").read_text()
        for port in range(4):
            self.assertIn(f"SIDevice{port} = 6", ini)
        self.assertEqual(setup.prepare("dolphin", self.library, self.home, state=state), [])

    def test_bios_rows_reflect_drop_folders(self):
        self.assertFalse(setup.bios_files(self.library, "ps3")[0]["present"])
        self.put("BIOS/ps3/ps3updat.pup")
        self.assertTrue(setup.bios_files(self.library, "ps3")[0]["present"])
        self.put("BIOS/switch/prod.keys")
        self.assertEqual([row["present"] for row in setup.bios_files(self.library, "switch")], [True, False])


if __name__ == "__main__":
    unittest.main()
