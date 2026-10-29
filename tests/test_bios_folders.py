import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bios_console", Path(__file__).resolve().parents[1] / "scripts/console.py")
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class FakeStorage:
    def __init__(self, root):
        self.root = root

    def target(self, name):
        return self.root / name

    def read_path(self, name):
        return self.root / name

    def mkdir(self, name):
        (self.root / name).mkdir(parents=True, exist_ok=True)


class BiosFolderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "BIOS/retroarch").mkdir(parents=True)
        self.storage = FakeStorage(self.root)

    def test_every_shown_console_gets_a_bios_folder(self):
        console.sync_bios_folders(self.storage, ["psx", "snes"])
        self.assertTrue((self.root / "BIOS/psx").is_dir() and (self.root / "BIOS/snes").is_dir())
        self.assertFalse((self.root / "BIOS/ps2").exists())

    def test_hidden_console_with_bios_files_keeps_them_in_a_dot_folder(self):
        (self.root / "BIOS/ps2").mkdir()
        (self.root / "BIOS/ps2/scph70012.bin").write_bytes(b"bios")
        console.sync_bios_folders(self.storage, ["psx"])
        self.assertFalse((self.root / "BIOS/ps2").exists())
        self.assertEqual((self.root / "BIOS/.ps2/scph70012.bin").read_bytes(), b"bios")
        console.sync_bios_folders(self.storage, ["psx", "ps2"])
        self.assertEqual((self.root / "BIOS/ps2/scph70012.bin").read_bytes(), b"bios")
        self.assertFalse((self.root / "BIOS/.ps2").exists())

    def test_hidden_console_with_an_empty_bios_folder_is_removed(self):
        (self.root / "BIOS/xbox/sub").mkdir(parents=True)
        (self.root / "BIOS/xbox/.DS_Store").write_bytes(b"")
        (self.root / "BIOS/.switch").mkdir()
        console.sync_bios_folders(self.storage, ["psx"])
        self.assertFalse((self.root / "BIOS/xbox").exists())
        self.assertFalse((self.root / "BIOS/.switch").exists())
        self.assertTrue((self.root / "BIOS/retroarch").is_dir())

    def test_files_in_a_console_folder_reach_retroarch_without_overwriting(self):
        console.sync_bios_folders(self.storage, ["psx"])
        (self.root / "BIOS/psx/scph5501.bin").write_bytes(b"mine")
        console.sync_system_bios(self.storage, "psx")
        self.assertEqual((self.root / "BIOS/retroarch/scph5501.bin").read_bytes(), b"mine")
        (self.root / "BIOS/psx/scph5501.bin").write_bytes(b"newer")
        console.sync_system_bios(self.storage, "psx")
        self.assertEqual((self.root / "BIOS/retroarch/scph5501.bin").read_bytes(), b"mine")


if __name__ == "__main__":
    unittest.main()
