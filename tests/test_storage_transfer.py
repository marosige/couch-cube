import importlib.util
import plistlib
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("console", Path(__file__).resolve().parents[1] / "scripts/console.py")
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class StorageTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.choice("internal", "local", "Mac")
        self.destination = self.choice("external", "portable", "SSD")
        self.choices = [self.source, self.destination]
        for choice in self.choices:
            Path(choice["mount"]).mkdir()
        for patcher in [
            patch.object(console, "drives", side_effect=lambda: self.choices),
            patch.object(console, "HOST_CONFIG", self.base / "host/setup.json"),
            patch.object(console, "login_agent", return_value=self.base / "agent.plist"),
            patch.object(console, "run", side_effect=self.copy),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.storage = console.Storage(self.source)
        console.initialize(self.storage, systems=["snes"])
        self.rom = self.storage.root / "ROMs/snes/game.sfc"
        self.rom.write_bytes(b"my game")
        (self.storage.root / "Saves/RetroArch/game.srm").write_bytes(b"my save")
        console.save_host_config(self.source)

    def choice(self, identifier, mode, folder):
        mount = self.base / folder
        return {"id": identifier, "uuid": identifier, "mode": mode, "name": folder,
                "root": str(mount / console.FOLDER), "mount": str(mount),
                "filesystem": "apfs", "free": 100 * 1024 ** 3}

    def copy(self, args, **kwargs):
        self.assertEqual(args[:3], ["/usr/bin/ditto", "--rsrc", "--extattr"])
        source, destination = map(Path, args[-2:])
        if source.is_symlink():
            destination.symlink_to(source.readlink())
        elif source.is_dir():
            shutil.copytree(source, destination, symlinks=True)
        else:
            shutil.copy2(source, destination)

    def transfer(self):
        plan = console.transfer_plan(self.source["id"], self.destination["id"])
        return console.transfer_library(self.source["id"], self.destination["id"], plan["token"], True)

    def test_status_reports_active_and_unconfigured_locations(self):
        status = console.storage_status()
        self.assertEqual(status["active"]["id"], "internal")
        self.assertEqual([item["configured"] for item in status["locations"]], [True, False])
        console.HOST_CONFIG.unlink()
        self.assertIsNone(console.storage_status()["active"])

    def test_setup_activates_existing_library_and_preserves_content(self):
        console.save_host_config(self.destination)
        with patch.object(sys, "argv", ["console.py", "setup", "--drive", "internal", "--confirm"]):
            self.assertEqual(console.main(), 0)
        self.assertEqual(console.read_json(console.HOST_CONFIG)["id"], "internal")
        self.assertEqual(self.rom.read_bytes(), b"my game")

    def test_copy_verifies_activates_and_preserves_original(self):
        result = self.transfer()
        root = Path(result["destination"])
        self.assertEqual(self.rom.read_bytes(), b"my game")
        self.assertEqual((root / "ROMs/snes/game.sfc").read_bytes(), b"my game")
        self.assertEqual((root / "Saves/RetroArch/game.srm").read_bytes(), b"my save")
        self.assertEqual(console.read_json(console.HOST_CONFIG)["id"], "external")
        state = console.read_json(root / console.MARKER)
        self.assertEqual((state["id"], state["uuid"], state["mode"]), ("external", "external", "portable"))
        self.assertEqual(state["systems"], ["snes"])
        settings = (root / "Frontend/ES-DE/settings/es_settings.xml").read_text()
        self.assertIn(str(root / "ROMs"), settings)
        self.assertNotIn(str(self.storage.root / "ROMs"), settings)
        self.assertEqual(console.storage_status()["transfer"]["token"], result["token"])
        self.assertEqual(console.retire_transferred_library("external", result["token"])["path"], self.source["root"])
        self.assertTrue(self.rom.exists(), "Retirement only returns a verified path; it never deletes files")

    @unittest.skipUnless(sys.platform == "darwin", "Checks the native macOS copy implementation")
    def test_native_ditto_preserves_extended_attributes_and_internal_links(self):
        subprocess.run(["/usr/bin/xattr", "-w", "com.couchcube.transfer-test", "metadata", str(self.rom)], check=True)
        (self.rom.parent / "linked.sfc").symlink_to("game.sfc")
        with patch.object(console, "run", side_effect=lambda args, **kwargs: subprocess.run(args, check=True, **kwargs)):
            result = self.transfer()
        copied = Path(result["destination"]) / "ROMs/snes/game.sfc"
        attribute = subprocess.check_output(["/usr/bin/xattr", "-p", "com.couchcube.transfer-test", str(copied)])
        self.assertEqual(attribute.strip(), b"metadata")
        self.assertEqual((copied.parent / "linked.sfc").readlink(), Path("game.sfc"))

    def test_transfer_from_ssd_back_to_mac(self):
        self.transfer()
        # A different clean Mac location represents a destination without an existing library.
        old_source = self.source
        self.source = self.destination
        self.destination = self.choice("another-mac", "local", "Other Mac")
        Path(self.destination["mount"]).mkdir()
        self.choices = [self.source, self.destination, old_source]
        result = self.transfer()
        self.assertEqual(console.read_json(console.HOST_CONFIG)["id"], "another-mac")
        self.assertEqual((Path(result["destination"]) / "ROMs/snes/game.sfc").read_bytes(), b"my game")

    def test_steam_files_are_not_copied_and_prevent_retirement(self):
        steam = self.storage.root / "SteamLibrary/steamapps"
        steam.mkdir()
        (steam / "game.dat").write_bytes(b"steam owns this")
        result = self.transfer()
        self.assertFalse((Path(result["destination"]) / "SteamLibrary/steamapps").exists())
        with self.assertRaisesRegex(console.SetupError, "Steam"):
            console.retire_transferred_library("external", result["token"])
        self.assertTrue((steam / "game.dat").exists())

    def test_never_merge_existing_destination(self):
        root = Path(self.destination["root"])
        root.mkdir()
        (root / "existing").write_text("keep")
        with self.assertRaisesRegex(console.SetupError, "already exists"):
            console.transfer_plan("internal", "external")
        self.assertEqual((root / "existing").read_text(), "keep")

    def test_stale_plan_and_missing_consent_do_not_copy(self):
        plan = console.transfer_plan("internal", "external")
        self.rom.write_bytes(b"changed")
        with self.assertRaisesRegex(console.SetupError, "changed"):
            console.transfer_library("internal", "external", plan["token"], True)
        with self.assertRaisesRegex(console.SetupError, "confirmation"):
            console.transfer_library("internal", "external", plan["token"], False)
        self.assertFalse(Path(self.destination["root"]).exists())
        self.assertEqual(console.read_json(console.HOST_CONFIG)["id"], "internal")

    def test_insufficient_space_and_unsupported_filesystem(self):
        self.destination["free"] = 0
        with self.assertRaisesRegex(console.SetupError, "free space"):
            console.transfer_plan("internal", "external")
        self.destination["free"] = 100 * 1024 ** 3
        self.destination["filesystem"] = "exfat"
        with self.assertRaisesRegex(console.SetupError, "APFS"):
            console.transfer_plan("internal", "external")

    def test_internal_relative_symlinks_survive_but_external_links_are_rejected(self):
        link = self.rom.parent / "linked.sfc"
        link.symlink_to("game.sfc")
        result = self.transfer()
        self.assertEqual((Path(result["destination"]) / "ROMs/snes/linked.sfc").readlink(), Path("game.sfc"))
        outside = self.rom.parent / "outside"
        outside.symlink_to(self.base)
        with self.assertRaisesRegex(console.SetupError, "outside"):
            console.transfer_snapshot(self.storage.root)

    def test_copy_failure_keeps_source_and_active_config(self):
        plan = console.transfer_plan("internal", "external")
        with patch.object(console, "run", side_effect=OSError("disconnected")):
            with self.assertRaisesRegex(console.SetupError, "Source files were kept"):
                console.transfer_library("internal", "external", plan["token"], True)
        self.assertEqual(self.rom.read_bytes(), b"my game")
        self.assertEqual(console.read_json(console.HOST_CONFIG)["id"], "internal")

    def test_copy_corruption_never_activates_destination(self):
        plan = console.transfer_plan("internal", "external")
        def corrupt(args, **kwargs):
            self.copy(args, **kwargs)
            destination = Path(args[-1])
            if destination.name == "ROMs":
                (destination / "snes/game.sfc").write_bytes(b"bad copy")
        with patch.object(console, "run", side_effect=corrupt):
            with self.assertRaisesRegex(console.SetupError, "verification failed"):
                console.transfer_library("internal", "external", plan["token"], True)
        self.assertEqual(self.rom.read_bytes(), b"my game")
        self.assertEqual(console.read_json(console.HOST_CONFIG)["id"], "internal")

    def test_retirement_requires_updating_old_console_mode_path(self):
        result = self.transfer()
        console.login_agent().write_bytes(plistlib.dumps({
            "EnvironmentVariables": {"COUCH_CUBE_ROOT": self.source["root"]}
        }))
        with self.assertRaisesRegex(console.SetupError, "Console Mode"):
            console.retire_transferred_library("external", result["token"])
        self.assertTrue(self.rom.exists())

    def test_replaced_destination_identity_is_not_accepted(self):
        result = self.transfer()
        self.destination["uuid"] = "another-volume"
        with self.assertRaisesRegex(console.SetupError, "identity changed"):
            console.retire_transferred_library("external", result["token"])

    def test_retirement_refuses_source_changes_or_destination_data_loss(self):
        result = self.transfer()
        self.rom.write_bytes(b"new save or game")
        with self.assertRaisesRegex(console.SetupError, "Source changed"):
            console.retire_transferred_library("external", result["token"])
        self.rom.write_bytes(b"my game")
        (Path(result["destination"]) / "ROMs/snes/game.sfc").unlink()
        with self.assertRaisesRegex(console.SetupError, "Destination content"):
            console.retire_transferred_library("external", result["token"])

    def test_retirement_requires_matching_receipt_active_drive_and_identity(self):
        result = self.transfer()
        with self.assertRaisesRegex(console.SetupError, "receipt"):
            console.retire_transferred_library("external", "wrong")
        console.save_host_config(self.source)
        with self.assertRaisesRegex(console.SetupError, "Activate"):
            console.retire_transferred_library("external", result["token"])
        self.source["uuid"] = "replaced-volume"
        with self.assertRaisesRegex(console.SetupError, "identity"):
            console.retire_transferred_library("external", result["token"])


if __name__ == "__main__":
    unittest.main()
