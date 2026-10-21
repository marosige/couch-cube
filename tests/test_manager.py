import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("manager", Path(__file__).resolve().parents[1] / "scripts/console.py")
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class FormatTests(unittest.TestCase):
    def setUp(self):
        self.real_physical_disks = manager.physical_disks
        self.real_protected_disks = manager.protected_disks
        self.disk = {"device": "disk42", "model": "Test SSD", "size": 256_000_000_000,
                     "identity": "unique-media-uuid", "tree": "test-device-tree", "protocol": "USB"}
        self.inventory = patch.object(manager, "physical_disks", return_value=[self.disk])
        self.protected = patch.object(manager, "protected_disks", return_value={"disk0"})
        self.inventory.start()
        self.protected.start()
        self.addCleanup(self.inventory.stop)
        self.addCleanup(self.protected.stop)

    def test_only_exact_external_device_with_fresh_token(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "run") as run:
            manager.erase_external("disk42", plan["token"], "ERASE disk42", True)
            run.assert_called_once_with([
                "/usr/sbin/diskutil", "eraseDisk", "APFS", "Mac Gaming", "GPT", "/dev/disk42"
            ])

    def test_denial_and_cancellation_never_execute(self):
        for typed, consent in [("", False), ("ERASE disk42", False), ("ERASE disk43", True)]:
            with patch.object(manager, "run") as run:
                with self.assertRaises(manager.SetupError):
                    manager.erase_external("disk42", "unused", typed, consent)
                run.assert_not_called()

    def test_changed_identity_after_review_never_executes(self):
        token = manager.format_plan("disk42")["token"]
        self.disk["identity"] = "replacement-drive"
        with patch.object(manager, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "identity changed"):
                manager.erase_external("disk42", token, "ERASE disk42", True)
            run.assert_not_called()

    def test_startup_runtime_backing_volume_refused(self):
        with patch.object(manager, "protected_disks", return_value={"disk42"}):
            with self.assertRaisesRegex(manager.SetupError, "Refusing"):
                manager.format_plan("disk42")

    def test_missing_reliable_uuid_fails_closed(self):
        self.disk["identity"] = ""
        with self.assertRaisesRegex(manager.SetupError, "Disk Utility"):
            manager.format_plan("disk42")

    def test_disconnected_or_injected_device_cannot_be_substituted(self):
        for device in ["disk0", "disk42s1", "disk42; touch /tmp/pwn", "/dev/disk42"]:
            with self.assertRaises(manager.SetupError):
                manager.format_plan(device)

    def test_authorization_failure_propagates_without_privilege_bypass(self):
        token = manager.format_plan("disk42")["token"]
        with patch.object(manager, "run", side_effect=subprocess.CalledProcessError(1, ["diskutil"])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                manager.erase_external("disk42", token, "ERASE disk42", True)
            self.assertEqual(run.call_count, 1)

    def test_physical_inventory_excludes_internal_and_virtual(self):
        import plistlib
        list_result = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps({
            "WholeDisks": ["disk0", "disk4", "disk9s1", "injection"]
        }))
        def info(device):
            return {"Internal": device == "disk0", "WholeDisk": True, "MediaName": "SSD",
                    "TotalSize": 1000, "DeviceTreePath": "usb", "DiskUUID": "UUID"}
        with patch.object(manager, "run", return_value=list_result), patch.object(manager, "disk_info", side_effect=info):
            self.assertEqual([d["device"] for d in self.real_physical_disks()], ["disk4"])

    def test_mounted_dmg_backing_disk_is_protected(self):
        import plistlib
        image_info = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps({
            "images": [{"image-path": "/Volumes/SSD/Installer/Setup.dmg"}]
        }))
        def disk_info(path):
            if str(path) == "/Volumes/SSD":
                return {"APFSPhysicalStores": [{"APFSPhysicalStore": "disk42s2"}]}
            return {"APFSPhysicalStores": [{"APFSPhysicalStore": "disk0s2"}]}
        def mount(path):
            return Path("/Volumes/SSD") if str(path).startswith("/Volumes/SSD/") else Path("/")
        with patch.object(manager, "home_disk", return_value=disk_info("/")), \
                patch.object(manager, "disk_info", side_effect=disk_info), \
                patch.object(manager, "enclosing_mount", side_effect=mount), \
                patch.object(manager, "run", return_value=image_info):
            self.assertIn("disk42", self.real_protected_disks())

    def test_failed_app_staging_cannot_erase(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "stage_current_app", side_effect=ValueError("App verification failed")), \
                patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk0"}), \
                patch.object(manager, "erase_external") as erase:
            with self.assertRaisesRegex(ValueError, "App verification"):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            erase.assert_not_called()

    def test_identity_change_during_staging_prevents_erase(self):
        plan = manager.format_plan("disk42")
        def stage(*args):
            self.disk["identity"] = "replacement-disk"
            return Path("/unused")
        with patch.object(manager, "stage_current_app", side_effect=stage), \
                patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk0"}), \
                patch.object(manager, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "identity changed"):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            run.assert_not_called()

    def test_preparation_denied_before_download(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "stage_current_app") as releases:
            with self.assertRaises(manager.SetupError):
                manager.prepare_portable("disk42", plan["token"], "", False)
            releases.assert_not_called()

    def test_download_staging_on_target_disk_is_refused(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk42"}), \
                patch.object(manager, "stage_current_app") as releases, \
                patch.object(manager, "erase_external") as erase:
            with self.assertRaisesRegex(manager.SetupError, "staging relies"):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            releases.assert_not_called()
            erase.assert_not_called()

    def test_verified_app_copied_to_exact_prepared_volume_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            mount = Path(temporary).resolve()
            choice = {"id": "new-volume", "uuid": "new-volume", "mode": "portable", "filesystem": "apfs",
                      "mount": str(mount), "root": str(mount / "Couch Cube")}
            events = []
            discovery_calls = []
            def drives():
                discovery_calls.append(True)
                return [dict(choice, free=100_000_000 - len(discovery_calls) * 1000)]
            def stage(directory):
                events.append("stage")
                app = directory / "CouchCube.app"
                app.mkdir()
                (app / "fixture").write_text("verified release")
                return app
            def erase(*args):
                events.append("erase")
                self.disk["identity"] = "new-partition-table"
            def info(path):
                return {"DeviceIdentifier": "disk42" if str(path) == str(mount) else "disk0"}
            def run(args, **kwargs):
                if args[0] == "/usr/bin/codesign":
                    events.append("verify-copy")
                else:
                    self.fail("Unexpected external command: " + str(args))
            plan = manager.format_plan("disk42")
            with patch.object(manager, "stage_current_app", side_effect=stage), \
                    patch.object(manager, "disk_info", side_effect=info), \
                    patch.object(manager, "erase_external", side_effect=erase), \
                    patch.object(manager, "drives", side_effect=drives), patch.object(manager, "run", side_effect=run):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            self.assertEqual(events, ["stage", "erase", "verify-copy"])
            self.assertEqual((mount / "CouchCube.app/fixture").read_text(), "verified release")
            self.assertFalse((mount / "Couch Cube").exists())

    def test_no_mount_after_erase_never_substitutes_another_drive(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "stage_current_app", return_value=Path("/unused")), \
                patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk0"}), \
                patch.object(manager, "erase_external") as erase, \
                patch.object(manager, "drives", return_value=[]), patch.object(manager.time, "sleep"), \
                patch.object(manager, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "not mounted"):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            erase.assert_called_once()
            run.assert_not_called()


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.choice = {"id": "uuid", "uuid": "uuid", "mode": "portable", "filesystem": "apfs",
                       "free": 100 * 1024 ** 3, "root": str(self.base / "Couch Cube")}
        self.discovery = patch.object(manager, "drives", return_value=[self.choice])
        self.discovery.start()
        self.addCleanup(self.discovery.stop)
        self.storage = manager.Storage(self.choice)

    def initialize(self):
        return manager.initialize(self.storage)

    def assessment(self):
        with patch.object(manager, "app_binary", return_value=Path("/app")), \
                patch.object(manager, "find_brew", return_value="/brew"), \
                patch.object(manager.platform, "machine", return_value="arm64"):
            return manager.assess("uuid")

    def test_new_drive_is_not_claimed_to_be_configured(self):
        self.assertEqual(self.assessment()["state"], "not prepared")

    def ssd_template(self):
        for folder in manager.SSD_FOLDERS:
            (self.storage.root / folder).mkdir(parents=True, exist_ok=True)
        (self.storage.root / manager.SSD_TEMPLATE).write_text("Couch Cube SSD template v1\n")

    def test_ssd_pack_empty_folders_can_be_initialized_on_current_drive(self):
        self.ssd_template()
        self.assertEqual(self.assessment()["state"], "not prepared")
        self.assertFalse((self.storage.root / manager.MARKER).exists())
        self.initialize()
        self.assertFalse((self.storage.root / manager.SSD_TEMPLATE).exists())
        self.assertEqual(manager.read_json(self.storage.root / manager.MARKER)["uuid"], "uuid")
        self.assertEqual(self.assessment()["state"], "valid layout")

    def test_ssd_template_with_user_files_is_preserved(self):
        self.ssd_template()
        game = self.storage.root / "ROMs/user-game.zip"
        game.write_bytes(b"keep")
        with self.assertRaisesRegex(manager.SetupError, "Preserving"):
            self.initialize()
        self.assertEqual(game.read_bytes(), b"keep")
        self.assertNotEqual(self.assessment()["state"], "not prepared")

    def test_ssd_template_rejects_symlinks_and_unexpected_folders(self):
        self.ssd_template()
        (self.storage.root / "Unknown").mkdir()
        self.assertFalse(manager.is_ssd_template(self.storage.root))
        (self.storage.root / "Unknown").rmdir()
        (self.storage.root / "ROMs/link").symlink_to(self.base)
        with self.assertRaises(manager.SetupError):
            manager.is_ssd_template(self.storage.root)

    def test_prepared_layout_passes_and_missing_directory_fails(self):
        self.initialize()
        self.assertEqual(self.assessment()["state"], "valid layout")
        (self.storage.root / "SteamLibrary").rmdir()
        self.assertIn("Missing directory: SteamLibrary", self.assessment()["issues"])

    def test_assessment_discovers_storage_only_before_and_after_read_batch(self):
        self.initialize()
        with patch.object(manager, "drives", return_value=[self.choice]) as discover:
            self.assertEqual(self.assessment()["state"], "valid layout")
        self.assertEqual(discover.call_count, 2)

    def test_assessment_rejects_volume_changed_during_read_batch(self):
        self.initialize()
        replacement = dict(self.choice, uuid="replacement")
        with patch.object(manager, "drives", side_effect=[[self.choice], [replacement]]):
            report = self.assessment()
        self.assertNotEqual(report["state"], "valid layout")
        self.assertTrue(any("identity" in issue for issue in report["issues"]))

    def test_assessment_read_batch_still_rejects_symlinks_and_path_escape(self):
        self.initialize()
        runtime = self.storage.root / "Runtime/console.py"
        runtime.unlink()
        runtime.symlink_to(self.base / "outside.py")
        self.assertTrue(any("symbolic" in issue.lower() or "symlink" in issue.lower()
                            for issue in self.assessment()["issues"]))
        with self.assertRaisesRegex(manager.SetupError, "escapes"):
            self.storage.read_path("../outside.py")

    def test_write_targets_still_revalidate_storage_each_time(self):
        self.initialize()
        with patch.object(manager, "drives", return_value=[self.choice]) as discover:
            self.storage.target("SteamLibrary")
            self.storage.target("ROMs")
        self.assertEqual(discover.call_count, 2)

    def test_bios_checks_only_enabled_consoles(self):
        manager.initialize(self.storage, ["psx", "segacd", "nes", "ps2"])
        systems = {item["id"]: item for item in manager.systems_status(self.storage)}
        self.assertIsNone(systems["dreamcast"]["bios"])
        self.assertEqual(systems["psx"]["bios"]["state"], "optional")
        self.assertEqual(systems["segacd"]["bios"]["state"], "missing")
        self.assertEqual(systems["nes"]["bios"]["state"], "not-needed")
        self.assertEqual(systems["ps2"]["bios"]["state"], "manual")
        self.assertTrue(all(item["bios"] is None for item in manager.systems_status()))

    def test_console_status_reports_actual_emulator_installation_once_per_package(self):
        self.initialize()
        def installed(name):
            if name == "Dolphin.app":
                return Path("/Applications/Dolphin.app/Contents/MacOS/Dolphin")
            raise manager.SetupError("not installed")
        with patch.object(manager, "app_binary", side_effect=installed) as detect:
            systems = {item["id"]: item for item in manager.systems_status(self.storage)}
        self.assertTrue(systems["gc"]["emulator_installed"])
        self.assertTrue(systems["wii"]["emulator_installed"])
        self.assertFalse(systems["psx"]["emulator_installed"])
        self.assertEqual(detect.call_count, 6)

    def test_bios_filename_presence_accepts_ps1_alternative_without_reading_contents(self):
        manager.initialize(self.storage, ["psx"])
        bios = self.storage.root / "BIOS/retroarch/scph5501.bin"
        bios.write_bytes(b"")
        result = manager.bios_status(self.storage, "psx")
        self.assertEqual(result["state"], "present")
        found = [item for item in result["files"] if item["present"]]
        self.assertEqual([item["filename"] for item in found], ["scph5501.bin"])
        self.assertEqual(found[0]["path"], str(bios))

    def test_bios_regional_and_optional_files_are_distinguished(self):
        self.initialize()
        (self.storage.root / "BIOS/retroarch/bios_CD_U.bin").write_bytes(b"")
        self.assertEqual(manager.bios_status(self.storage, "segacd")["state"], "partial")
        for name in ["bios_CD_E.bin", "bios_CD_J.bin"]:
            (self.storage.root / "BIOS/retroarch" / name).write_bytes(b"")
        self.assertEqual(manager.bios_status(self.storage, "segacd")["state"], "present")
        self.assertEqual(manager.bios_status(self.storage, "dreamcast")["state"], "optional")
        for name in ["dc_boot.bin", "dc_flash.bin"]:
            (self.storage.root / "BIOS/retroarch/dc" / name).write_bytes(b"")
        self.assertEqual(manager.bios_status(self.storage, "dreamcast")["state"], "present")

    def test_bios_directories_and_symlinks_do_not_count_as_files(self):
        self.initialize()
        root = self.storage.root / "BIOS/retroarch"
        (root / "scph1001.bin").mkdir()
        self.assertEqual(manager.bios_status(self.storage, "psx")["state"], "optional")
        (root / "scph5501.bin").symlink_to(self.base / "outside")
        with self.assertRaises(manager.SetupError):
            manager.bios_status(self.storage, "psx")

    def test_changed_file_detected_and_not_repaired_silently(self):
        self.initialize()
        runtime = self.storage.root / "Runtime/console.py"
        runtime.write_text("user change")
        self.assertTrue(any("Runtime/console.py" in issue for issue in self.assessment()["issues"]))
        self.assertEqual(runtime.read_text(), "user change")

    def test_corrupt_manifest_and_other_volume_reported(self):
        self.initialize()
        marker = self.storage.root / manager.MARKER
        marker.write_text('{"version":1,"uuid":"other"}')
        self.assertTrue(self.assessment()["issues"])
        marker.write_text("not json")
        self.assertTrue(self.assessment()["issues"])

    def test_partial_manifest_and_wrong_rom_directory_not_valid(self):
        self.initialize()
        marker = self.storage.root / manager.MARKER
        manifest = manager.read_json(marker)
        del manifest["managed"]["Runtime/console.py"]
        marker.write_text(manager.json_text(manifest))
        self.assertTrue(any("does not track" in issue for issue in self.assessment()["issues"]))
        settings = self.storage.root / "Frontend/ES-DE/settings/es_settings.xml"
        settings.write_text('<string name="ROMDirectory" value="/different-drive"/>')
        self.assertTrue(any("points elsewhere" in issue for issue in self.assessment()["issues"]))

    def test_low_space_and_unsupported_filesystem_explicit(self):
        self.choice["free"] = 1024
        self.choice["filesystem"] = "exfat"
        report = self.assessment()
        self.assertTrue(any("Unsupported filesystem" in issue for issue in report["issues"]))
        self.assertTrue(any("20 GiB" in note for note in report["notes"]))

    def test_missing_host_components_reported_not_installed(self):
        with patch.object(manager, "app_binary", side_effect=manager.SetupError("missing")), \
                patch.object(manager, "find_brew", side_effect=manager.SetupError("missing")):
            result = manager.assess("uuid")
        self.assertEqual(set(result["missing"]), set(manager.PACKAGES))
        self.assertTrue(any("Homebrew missing" in note for note in result["notes"]))

    def test_apps_installation_is_explicit_and_independent_of_game_library(self):
        import contextlib
        import io
        import sys
        with patch.object(sys, "argv", ["console.py", "install-apps", "--packages", "steam"]), \
                patch.object(manager, "install_packages") as install, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(manager.main(), 1)
            install.assert_not_called()
        with patch.object(sys, "argv", ["console.py", "install-apps", "--confirm", "--packages", "steam"]), \
                patch.object(manager, "install_packages") as install:
            self.assertEqual(manager.main(), 0)
            install.assert_called_once_with(["steam"])
        self.assertFalse(self.storage.root.exists())

    def test_real_dmg_verification_copy_no_overwrite(self):
        self.initialize()
        source = self.base / "Installer with spaces.dmg"
        source.write_bytes(b"fixture, hdiutil is mocked")
        with patch.object(manager, "run") as run:
            manager.copy_installer(self.storage, source)
            run.assert_called_once_with(
                ["/usr/bin/hdiutil", "verify", str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        target = self.storage.root / "Installer" / source.name
        self.assertEqual(target.read_bytes(), source.read_bytes())
        with patch.object(manager, "run"):
            with self.assertRaisesRegex(manager.SetupError, "preserving"):
                manager.copy_installer(self.storage, source)

    def test_invalid_dmg_never_copied(self):
        self.initialize()
        source = self.base / "invalid.dmg"
        source.write_bytes(b"invalid")
        with patch.object(manager, "run", side_effect=subprocess.CalledProcessError(1, ["hdiutil"])):
            with self.assertRaises(subprocess.CalledProcessError):
                manager.copy_installer(self.storage, source)
        self.assertFalse((self.storage.root / "Installer").exists())

    def test_disconnected_copy_cannot_create_mount_directory(self):
        self.initialize()
        source = self.base / "installer.dmg"
        source.write_bytes(b"fixture")
        with patch.object(manager, "run"), patch.object(manager, "drives", return_value=[]):
            with self.assertRaises(manager.SetupError):
                manager.copy_installer(self.storage, source)
        self.assertFalse((self.storage.root / "Installer").exists())

    def test_homebrew_helper_cancellation_runs_no_external_commands(self):
        helper = Path(__file__).resolve().parents[1] / "setup/Install Homebrew.command"
        result = subprocess.run(["/bin/bash", str(helper)], input="NO\n", text=True,
                                capture_output=True, env={"PATH": "/nonexistent"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cancelled. No installer executed.", result.stdout)
        self.assertNotIn("command not found", result.stderr)

    def test_bundle_copy_preserves_files_modes_and_relative_symlinks(self):
        source = self.base / "source"
        (source / "nested").mkdir(parents=True)
        executable = source / "nested/python3.13"
        executable.write_bytes(b"fixture")
        executable.chmod(0o755)
        (source / "nested/python3").symlink_to("python3.13")
        target = self.base / "target"
        target.mkdir()
        descriptor = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
        try:
            manager.copy_bundle_contents(source, descriptor)
        finally:
            os.close(descriptor)
        self.assertEqual((target / "nested/python3").read_bytes(), b"fixture")
        self.assertTrue((target / "nested/python3").is_symlink())
        self.assertTrue(os.access(target / "nested/python3", os.X_OK))

    def test_bundle_copy_uses_open_directory_not_reused_mount_path(self):
        source = self.base / "source"
        source.mkdir()
        (source / "fixture").write_text("correct disk")
        target = self.base / "target"
        target.mkdir()
        descriptor = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
        moved = self.base / "moved"
        try:
            target.rename(moved)
            target.mkdir()
            manager.copy_bundle_contents(source, descriptor)
        finally:
            os.close(descriptor)
        self.assertEqual((moved / "fixture").read_text(), "correct disk")
        self.assertFalse((target / "fixture").exists())


class DriveLibraryTests(unittest.TestCase):
    """Per-drive overview, initialize and remove use temp folders only; nothing real is erased."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        self.mount = self.base / "Volumes/Game SSD"
        self.mount.mkdir(parents=True)
        self.choice = {"id": "uuid", "uuid": "uuid", "mode": "portable", "filesystem": "apfs", "name": "Game SSD",
                       "free": 100 * 1024 ** 3, "root": str(self.mount / "Couch Cube"), "mount": str(self.mount)}
        self.second = dict(self.choice, id="uuid2", uuid="uuid2", name="Other SSD",
                           root=str(self.base / "Volumes/Other/Couch Cube"), mount=str(self.base / "Volumes/Other"))
        Path(self.second["mount"]).mkdir(parents=True)
        patches = [patch.object(manager, "drives", return_value=[self.choice, self.second]),
                   patch.object(manager.Path, "home", return_value=self.home),
                   patch.object(manager, "HOST_CONFIG", self.home / "setup.json")]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)
        self.root = Path(self.choice["root"])

    def make_library(self, choice=None):
        manager.initialize(manager.Storage(choice or self.choice), ["snes", "psx"])

    def test_overview_classifies_every_drive_without_activating_any(self):
        self.make_library()
        status = manager.storage_status()
        environments = {item["drive"]["id"]: item["environment"] for item in status["locations"]}
        self.assertEqual(environments, {"uuid": "ready", "uuid2": "absent"})
        self.assertIsNone(status["active"])
        self.assertFalse((self.home / "setup.json").exists())
        self.assertTrue(all(item["total"] for item in status["locations"]))

    def test_existing_unrecognized_folder_is_occupied_not_absent(self):
        self.root.mkdir()
        (self.root / "notes.txt").write_text("mine")
        self.assertEqual(manager.library_environment(self.choice)[0], "occupied")
        with self.assertRaises(manager.SetupError):
            manager.initialize_drive("uuid", True)
        self.assertEqual((self.root / "notes.txt").read_text(), "mine")
        self.assertFalse((self.root / manager.MARKER).exists())

    def test_foreign_manifest_is_invalid(self):
        self.make_library(self.second)
        marker = Path(self.second["root"]) / manager.MARKER
        state = json.loads(marker.read_text())
        state["uuid"] = "someone-else"
        marker.write_text(json.dumps(state))
        self.assertEqual(manager.library_environment(self.second)[0], "invalid")
        with self.assertRaises(manager.SetupError):
            manager.removal_plan("uuid2")
        self.assertTrue(marker.exists())

    def test_initialize_is_nondestructive_and_keeps_active_library(self):
        with self.assertRaises(manager.SetupError):
            manager.initialize_drive("uuid", False)
        self.assertFalse(self.root.exists())
        (self.mount / "Unrelated.txt").write_text("keep")
        manager.initialize_drive("uuid", True)
        self.assertEqual(manager.library_environment(self.choice)[0], "ready")
        self.assertEqual((self.mount / "Unrelated.txt").read_text(), "keep")
        self.assertFalse((self.home / "setup.json").exists())
        managed = (self.root / manager.MARKER).read_bytes()
        with self.assertRaises(manager.SetupError):
            manager.initialize_drive("uuid", True)
        self.assertEqual((self.root / manager.MARKER).read_bytes(), managed)

    def test_detail_reports_capacity_and_only_populated_systems(self):
        self.make_library()
        (self.root / "ROMs/snes/Game.sfc").write_bytes(b"x" * 5000)
        (self.root / "ROMs/snes/readme.txt").write_text("not a game")
        (self.root / "ROMs/psx/notes.txt").parent.mkdir(parents=True, exist_ok=True)
        (self.root / "ROMs/psx/notes.txt").write_text("not a game")
        with patch.object(manager, "steam_libraries", return_value=[]):
            detail = manager.drive_detail("uuid")
        self.assertEqual(detail["environment"], "ready")
        self.assertEqual([(item["id"], item["games"]) for item in detail["retro"]], [("snes", 1)])
        capacity = detail["capacity"]
        self.assertGreater(capacity["couch"], 5000)
        self.assertLessEqual(capacity["used"] + capacity["free"], capacity["total"])
        self.assertFalse(detail["active"])

    def test_detail_lists_steam_games_only_from_this_volume(self):
        library = self.mount / "SteamLibrary"
        (library / "steamapps").mkdir(parents=True)
        (library / "steamapps/appmanifest_70.acf").write_text('"AppState" { "appid" "70" "name" "Half-Life" "StateFlags" "4" }')
        with patch.object(manager, "steam_libraries", return_value=[library, self.home / "Elsewhere"]), \
                patch.object(manager, "same_volume", side_effect=lambda path, mount: path == library):
            detail = manager.drive_detail("uuid")
        self.assertEqual([(item["path"], [game["appid"] for game in item["games"]]) for item in detail["steam"]],
                         [(str(library), ["70"])])
        self.assertEqual(detail["environment"], "absent")
        self.assertEqual(detail["retro"], [])

    def test_removal_is_scoped_tokenized_and_refuses_active_or_steam_libraries(self):
        self.make_library()
        (self.root / "ROMs/snes/Game.sfc").write_bytes(b"rom")
        (self.mount / "Unrelated.txt").write_text("keep")
        plan = manager.removal_plan("uuid")
        self.assertEqual(plan["path"], str(self.root))
        self.assertGreater(plan["files"], 0)
        with self.assertRaises(manager.SetupError):
            manager.removal_verify("uuid", plan["token"], False)
        (self.root / "ROMs/snes/Other.sfc").write_bytes(b"new")
        with self.assertRaises(manager.SetupError):
            manager.removal_verify("uuid", plan["token"], True)
        plan = manager.removal_plan("uuid")
        self.assertEqual(manager.removal_verify("uuid", plan["token"], True), {"path": str(self.root)})
        self.assertTrue(self.root.exists(), "Verification never deletes; the app moves the folder to Trash")
        (self.home / "setup.json").write_text(json.dumps({"id": "uuid", "uuid": "uuid"}))
        with self.assertRaises(manager.SetupError):
            manager.removal_plan("uuid")
        (self.home / "setup.json").unlink()
        (self.root / "SteamLibrary/steamapps").mkdir(parents=True)
        with self.assertRaises(manager.SetupError):
            manager.removal_plan("uuid")

    def test_removal_refuses_escaping_links_and_unexpected_locations(self):
        self.make_library()
        outside = self.base / "outside.txt"
        outside.write_text("outside")
        (self.root / "ROMs/link").symlink_to(outside)
        with self.assertRaises(manager.SetupError):
            manager.removal_plan("uuid")
        (self.root / "ROMs/link").unlink()
        moved = dict(self.choice, root=str(self.mount / "Elsewhere"))
        with patch.object(manager, "drives", return_value=[moved]):
            manager.initialize(manager.Storage(moved))
            with self.assertRaises(manager.SetupError):
                manager.removal_plan("uuid")

    def test_absent_and_disconnected_drives_cannot_be_removed(self):
        with self.assertRaises(manager.SetupError):
            manager.removal_plan("uuid")
        with self.assertRaises(manager.SetupError):
            manager.removal_plan("missing")


class DriveGamesTests(unittest.TestCase):
    """Per-game storage breakdown reads temp folders only and never counts a file twice."""

    setUp = DriveLibraryTests.setUp
    make_library = DriveLibraryTests.make_library

    def scan(self, libraries=()):
        with patch.object(manager, "steam_libraries", return_value=list(libraries)), \
                patch.object(manager, "SYSTEM_APPLICATIONS", self.base / "Applications"):
            return manager.drive_games("uuid")

    def by_name(self, result):
        return {item["name"]: item for item in result["items"]}

    def test_roms_group_multipart_sets_folders_and_leftovers(self):
        self.make_library()
        psx = self.root / "ROMs/psx"
        (psx / "Game (Disc 1).bin").write_bytes(b"a" * 9000)
        (psx / "Game (Disc 1).cue").write_text('FILE "Game (Disc 1).bin" BINARY\n')
        (psx / "Game (Disc 2).bin").write_bytes(b"b" * 9000)
        (psx / "Game (Disc 2).cue").write_text('FILE "Game (Disc 2).bin" BINARY\n')
        (psx / "Game.m3u").write_text("Game (Disc 1).cue\nGame (Disc 2).cue\n../../escape.cue\n")
        (psx / "Solo.chd").write_bytes(b"c" * 5000)
        (psx / "readme.txt").write_text("notes")
        (self.root / "ROMs/snes/Pack").mkdir()
        (self.root / "ROMs/snes/Pack/a.sfc").write_bytes(b"d" * 5000)
        result = self.scan()
        items = self.by_name(result)
        self.assertEqual(set(items), {"Game", "Solo", "Other PlayStation files", "Pack"})
        self.assertEqual(items["Game"]["system"], "psx")
        self.assertGreaterEqual(items["Game"]["bytes"], 18000)
        self.assertEqual(items["Pack"]["kind"], "rom")
        self.assertEqual(result["total"], sum(item["bytes"] for item in result["items"]))
        self.assertEqual(result["coverage"][0], {"source": "rom", "name": "ROMs", "status": "scanned",
                                                 "games": 4, "note": None})

    def test_hardlinks_and_overlapping_paths_count_once(self):
        self.make_library()
        rom = self.root / "ROMs/snes/A.sfc"
        rom.write_bytes(b"x" * 40000)
        os.link(rom, self.root / "ROMs/snes/B.sfc")
        (self.root / "ROMs/snes/Link.sfc").symlink_to(self.base / "outside.sfc")
        (self.base / "outside.sfc").write_bytes(b"y" * 40000)
        items = self.by_name(self.scan())
        self.assertEqual(set(items), {"A", "B"})
        self.assertEqual(sorted(item["bytes"] > 0 for item in items.values()), [False, True],
                         "A hard-linked ROM is counted for one game only; links outside are ignored")

    def test_steam_measures_install_folder_or_marks_reported_size(self):
        library = self.mount / "SteamLibrary"
        (library / "steamapps/common/HL").mkdir(parents=True)
        (library / "steamapps/common/HL/data.bin").write_bytes(b"x" * 20000)
        (library / "steamapps/appmanifest_70.acf").write_text(
            '"AppState" { "appid" "70" "name" "Half-Life" "installdir" "HL" "sizeondisk" "1" }')
        (library / "steamapps/appmanifest_80.acf").write_text(
            '"AppState" { "appid" "80" "name" "Missing" "installdir" "Gone" "sizeondisk" "777" }')
        (library / "steamapps/appmanifest_90.acf").write_text(
            '"AppState" { "appid" "90" "name" "Escape" "installdir" ".." }')
        with patch.object(manager, "same_volume", side_effect=lambda path, mount: path == library):
            result = self.scan([library, self.home / "Elsewhere"])
        items = self.by_name(result)
        self.assertTrue(items["Half-Life"]["measured"])
        self.assertGreaterEqual(items["Half-Life"]["bytes"], 20000)
        self.assertEqual((items["Missing"]["bytes"], items["Missing"]["measured"]), (777, False))
        self.assertNotIn("Escape", items)
        self.assertTrue(any("appmanifest_90" in error for error in result["errors"]))
        self.assertEqual(items["Half-Life"]["source_name"], "Steam")

    def test_launcher_markers_epic_manifests_and_bottles(self):
        apps = self.mount / "Applications"
        (apps / "World of Warcraft").mkdir(parents=True)
        (apps / "World of Warcraft/.build.info").write_text("x")
        (apps / "The Sims 4/__Installer").mkdir(parents=True)
        (apps / "The Sims 4/__Installer/installerdata.xml").write_text("<x/>")
        (apps / "Witcher.app/Contents/Resources").mkdir(parents=True)
        (apps / "Witcher.app/Contents/Resources/goggame-1.info").write_text("{}")
        (apps / "Unknown Game").mkdir()
        epic_folder = self.mount / "Epic/Fortnite"
        epic_folder.mkdir(parents=True)
        manifests = self.home / "Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests"
        manifests.mkdir(parents=True)
        (manifests / "a.item").write_text(json.dumps({"DisplayName": "Fortnite", "InstallLocation": str(epic_folder)}))
        (manifests / "b.item").write_text("not json")
        result = self.scan()
        sources = {item["name"]: item["source"] for item in result["items"]}
        self.assertEqual(sources, {"World of Warcraft": "blizzard", "The Sims 4": "ea", "Witcher": "gog",
                                   "Fortnite": "epic"})
        self.assertTrue(any("b.item" in error for error in result["errors"]))
        bottle = self.home / "Library/Application Support/CrossOver/Bottles/Steam"
        (bottle / "drive_c").mkdir(parents=True)
        local = dict(self.choice, mode="local", root=str(self.home / "Games/Couch Cube"), mount=str(self.base))
        with patch.object(manager, "drives", return_value=[local]):
            items = self.by_name(self.scan())
        self.assertEqual(items["Steam (CrossOver bottle)"]["source"], "bottle")

    def test_other_volumes_and_unreadable_folders_are_reported_not_zeroed(self):
        self.make_library()
        locked = self.root / "ROMs/snes/Locked"
        (locked / "inner").mkdir(parents=True)
        (locked / "inner/a.sfc").write_bytes(b"x" * 5000)
        os.chmod(locked / "inner", 0)
        self.addCleanup(os.chmod, locked / "inner", 0o755)
        with patch.object(manager.os, "stat", wraps=os.stat) as fake:
            result = self.scan()
        item = self.by_name(result)["Locked"]
        if os.geteuid() != 0:
            self.assertGreater(item["unreadable"], 0)
            self.assertEqual(result["partial"], 1)
        meter = manager.StorageMeter(os.stat(self.mount).st_dev + 1)
        self.assertEqual(meter.measure([locked]), (0, 0), "Folders on another volume aren't counted")
        self.assertEqual(manager.StorageMeter(1).measure([self.base / "missing"]), (None, 1))
        self.assertTrue(fake.called)


class SteamStatusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.patch = patch.object(manager.Path, "home", return_value=self.home)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.steam = self.home / "Library/Application Support/Steam"
        self.steamapps = self.steam / "steamapps"
        self.steamapps.mkdir(parents=True)

    def manifest(self, root, appid, flags, name="Game"):
        folder = root / "steamapps"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"appmanifest_{appid}.acf").write_text(
            '"AppState" { "appid" "' + appid + '" "name" "' + name +
            '" "StateFlags" "' + flags + '" "SizeOnDisk" "123456" }')

    def test_library_counts_use_manifests_and_deduplicate_paths(self):
        external = self.home / "External SSD/SteamLibrary"
        self.manifest(self.steam, "10", "4")
        self.manifest(external, "20", "6")
        self.manifest(external, "30", "1026")
        self.manifest(external, "40", "0")
        (self.steamapps / "libraryfolders.vdf").write_text(
            '"libraryfolders" { "0" { "path" "' + str(self.steam) +
            '" "apps" { "10" "123456" } } "1" { "path" "' + str(external) +
            '" } "2" { "path" "' + str(external) + '" } }')
        with patch.object(manager, "run") as run:
            result = manager.steam_status()
        run.assert_not_called()
        self.assertEqual(result["errors"], [])
        self.assertEqual(len(result["libraries"]), 2)
        local, ssd = result["libraries"]
        self.assertEqual(len(local["games"]), 1)
        self.assertEqual(sum(game["installed"] for game in ssd["games"]), 1)
        self.assertEqual([game["state"] for game in ssd["games"]],
                         ["Update required", "Update / install in progress", "Not fully installed"])
        self.assertEqual(local["games"][0]["bytes"], 123456)

    def test_legacy_paths_and_offline_library_are_retained_without_fake_counts(self):
        offline = self.home / "Disconnected SSD"
        (self.steamapps / "libraryfolders.vdf").write_text(
            '"LibraryFolders" { "1" "' + str(offline) + '" }')
        result = manager.steam_status()
        self.assertEqual(result["errors"], [])
        self.assertFalse(result["libraries"][1]["available"])
        self.assertEqual(result["libraries"][1]["games"], [])
        self.assertFalse(offline.exists())

    def test_malformed_metadata_reports_error_instead_of_zero_games(self):
        for text in ['"libraryfolders" {', '"libraryfolders" { "1" { "path" "relative" } }']:
            (self.steamapps / "libraryfolders.vdf").write_text(text)
            result = manager.steam_status()
            self.assertTrue(result["errors"])
            self.assertEqual(result["libraries"], [])

    def test_bad_manifest_does_not_hide_other_games_or_claim_missing_flags_installed(self):
        self.manifest(self.steam, "10", "4", 'A \\"quoted\\" game')
        (self.steamapps / "appmanifest_20.acf").write_text('"AppState" { "appid" "20" "name" "Unknown" }')
        (self.steamapps / "appmanifest_30.acf").write_text('"AppState" { "appid" "31" "name" "Mismatch" }')
        result = manager.steam_status()
        self.assertEqual(len(result["errors"]), 1)
        games = result["libraries"][0]["games"]
        self.assertEqual(games[0]["name"], 'A "quoted" game')
        self.assertFalse(games[1]["installed"])
        self.assertEqual(games[1]["state"], "Unknown")
        self.assertIsNone(games[1]["bytes"])

    def test_vdf_parser_rejects_duplicates_and_truncated_objects(self):
        for text in ['"a" { "b" "1"', '"a" "1" "A" "2"', '"a" }', "unexpected"]:
            with self.assertRaises(manager.SetupError):
                manager.parse_vdf(text)
        self.assertEqual(manager.parse_vdf('// comment\n"a" { "b" "1" }'), {"a": {"b": "1"}})

    def test_steam_not_installed_is_not_an_offline_library(self):
        with patch.object(manager.Path, "home", return_value=self.home / "Empty home"):
            self.assertEqual(manager.steam_status(), {"libraries": [], "errors": []})


class AppManagementTests(unittest.TestCase):
    def test_crossover_uses_official_manual_install_and_detects_existing_app(self):
        self.assertEqual(manager.PACKAGES["crossover"], "CrossOver.app")
        self.assertEqual(manager.MANUAL_APPS["crossover"], "https://www.codeweavers.com/crossover")
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            contents = home / "Applications/CrossOver.app/Contents"
            contents.mkdir(parents=True)
            with (contents / "Info.plist").open("wb") as file:
                manager.plistlib.dump({"CFBundleShortVersionString": "1.2.3"}, file)
            with patch.object(manager, "find_brew", side_effect=manager.SetupError("missing")), \
                    patch.object(manager.Path, "home", return_value=home), \
                    patch.object(manager, "PACKAGES", {"crossover": "CrossOver.app"}):
                apps = manager.app_status()
            crossover = apps[0]
            self.assertTrue(crossover["manual"])
            self.assertTrue(crossover["installed"])
            self.assertEqual(crossover["version"], "1.2.3")
        with patch.object(manager, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "manual"):
                manager.install_packages(["crossover"])
            run.assert_not_called()

    def test_official_mac_launchers_are_known_and_battle_net_uses_official_installer(self):
        for package, name in {"gog-galaxy": "GOG Galaxy.app", "ea": "EA app.app",
                              "epic-games": "Epic Games Launcher.app", "battle-net": "Battle.net.app",
                              "curseforge": "CurseForge.app"}.items():
            self.assertEqual(manager.PACKAGES[package], name)
        self.assertEqual(manager.MANUAL_APPS["battle-net"], "https://download.battle.net/")

    def test_targeted_app_recheck_reads_only_that_package_and_its_update(self):
        calls = []

        def fake_run(args, **kwargs):
            calls.append(args)
            if "info" in args:
                return SimpleNamespace(stdout=json.dumps({"casks": [{"token": "dolphin"}]}))
            return SimpleNamespace(stdout=json.dumps({"casks": [{"name": "dolphin", "current_version": "2"}]}))

        with patch.object(manager, "find_brew", return_value="/opt/homebrew/bin/brew"), \
                patch.object(manager, "run", side_effect=fake_run), \
                patch.object(manager.Path, "is_dir", return_value=False):
            apps = manager.app_status(check_updates=True, package="dolphin")
        self.assertEqual([app["id"] for app in apps], ["dolphin"])
        self.assertEqual(apps[0]["update"], "2")
        self.assertEqual(calls[1][-1], "dolphin", "Only the re-checked cask is queried for updates")
        with self.assertRaises(manager.SetupError):
            manager.app_status(package="not-a-package")

    def test_automatic_update_check_without_brew_still_returns_app_status(self):
        with patch.object(manager, "find_brew", side_effect=manager.SetupError("missing")), \
                patch.object(manager.Path, "is_dir", return_value=False):
            apps = manager.app_status(check_updates=True)
        self.assertEqual(len(apps), len(manager.PACKAGES))
        self.assertTrue(all(not app["brew"] and app["update"] is None for app in apps))

    def test_app_management_requires_confirmation(self):
        with patch.object(manager, "run") as run:
            for package, action in [("steam", "remove"), ("unknown", "install"), ("steam", "zap")]:
                with self.assertRaises(manager.SetupError):
                    manager.manage_app(package, action)
            run.assert_not_called()

    def test_homebrew_remove_keeps_preferences_no_zap(self):
        with patch.object(manager, "app_status", return_value=[{"id": "steam", "managed": True}]), \
                patch.object(manager, "find_brew", return_value="/brew"), patch.object(manager, "run") as run:
            manager.manage_app("steam", "remove", True)
        run.assert_called_once_with(["/brew", "uninstall", "--cask", "steam"], env=manager.brew_environment())

    def test_homebrew_asks_for_the_password_in_a_dialog(self):
        environment = manager.brew_environment()
        askpass = Path(environment["SUDO_ASKPASS"])
        self.assertEqual(askpass.name, "askpass.sh")
        self.assertTrue(os.access(askpass, os.X_OK), "sudo -A needs an executable helper")
        self.assertIn("hidden answer", askpass.read_text())

    def test_unmanaged_app_not_removed_by_brew(self):
        with patch.object(manager, "app_status", return_value=[{"id": "rpcs3", "managed": False}]), \
                patch.object(manager, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "Finder"):
                manager.manage_app("rpcs3", "remove", True)
            run.assert_not_called()

    def test_cemu_and_switch_never_install_wrong_cask(self):
        with patch.object(manager, "run") as run:
            for package in ["cemu-wiiu", "switch", "rpcs3"]:
                with self.assertRaisesRegex(manager.SetupError, "manual"):
                    manager.install_packages([package])
            run.assert_not_called()

    def test_cleanup_preserves_user_library(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            config = home / "setup.json"
            config.write_text("{}")
            (home / "frontend.json").write_text('{"default": "steam"}')
            games = home / "Games/ROMs"
            games.mkdir(parents=True)
            (games / "mine.iso").write_bytes(b"keep")
            with patch.object(manager, "HOST_CONFIG", config), \
                    patch.object(manager, "FRONTEND_CONFIG", home / "frontend.json"), \
                    patch.object(manager.Path, "home", return_value=home), \
                    patch.object(manager, "login_launcher") as login:
                manager.cleanup_host(True)
            login.assert_called_once_with(True, enabled=False)
            self.assertFalse(config.exists())
            self.assertFalse((home / "frontend.json").exists())
            self.assertEqual((games / "mine.iso").read_bytes(), b"keep")

    def test_copy_app_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            mount = Path(temporary).resolve()
            destination = mount / "CouchCube.app"
            destination.mkdir()
            (destination / "keep").write_text("user app")
            choice = {"id": "drive", "uuid": "drive", "mode": "portable", "mount": str(mount),
                      "root": str(mount / manager.FOLDER)}
            with patch.object(manager, "select_drive", return_value=choice):
                with self.assertRaisesRegex(manager.SetupError, "already exists"):
                    manager.copy_app_to_storage(choice, Path("/source/CouchCube.app"))
            self.assertEqual((destination / "keep").read_text(), "user app")


class DefaultFrontendTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name).resolve() / "frontend.json"
        patcher = patch.object(manager, "FRONTEND_CONFIG", self.config)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_explicit_es_de_preference_overrides_steam_and_survives_storage_selection(self):
        with patch.object(manager, "app_binary") as binary:
            manager.set_frontend("es-de", True)
            binary.assert_called_once_with("ES-DE.app")
        with patch.object(manager, "HOST_CONFIG", self.config.parent / "setup.json"):
            manager.save_host_config({"id": "local", "uuid": "test"})
        self.assertEqual(manager.frontend_preference(), "es-de")
        with patch.object(manager.Path, "is_dir", return_value=True), patch.object(manager, "app_binary") as binary:
            self.assertEqual(manager.default_frontend(), "retro")
            binary.assert_called_once_with("ES-DE.app")

    def test_missing_explicit_default_does_not_silently_change_menu(self):
        self.config.write_text('{"default": "es-de"}')
        with patch.object(manager.Path, "is_dir", lambda path: path.name == "Steam.app"):
            with self.assertRaisesRegex(manager.SetupError, "default TV menu"):
                manager.default_frontend()

    def test_default_change_requires_consent_and_installed_app(self):
        with patch.object(manager, "app_binary", side_effect=manager.SetupError("missing")):
            for package, consent in [("steam", False), ("couch-cube", True), ("es-de", True)]:
                with self.assertRaises(manager.SetupError):
                    manager.set_frontend(package, consent)
        self.assertFalse(self.config.exists())

    def test_invalid_and_symlink_preferences_are_rejected(self):
        self.config.write_text('{"default": "unknown"}')
        with self.assertRaisesRegex(manager.SetupError, "Invalid TV menu"):
            manager.frontend_preference()
        self.config.unlink()
        target = Path(self.directory.name) / "other.json"
        target.write_text('{"default": "steam"}')
        self.config.symlink_to(target)
        with self.assertRaises(manager.SetupError):
            manager.frontend_preference()

    def test_steam_preferred_when_both_installed(self):
        with patch.object(manager.Path, "is_dir", return_value=True), \
                patch.object(manager, "app_binary") as binary:
            self.assertEqual(manager.default_frontend(), "steam")
            binary.assert_called_once_with("Steam.app")

    def test_es_de_selected_without_steam(self):
        with patch.object(manager.Path, "is_dir", lambda path: path.name == "ES-DE.app"), \
                patch.object(manager, "app_binary") as binary:
            self.assertEqual(manager.default_frontend(), "retro")
            binary.assert_called_once_with("ES-DE.app")

    def test_no_frontend_reports_error(self):
        with patch.object(manager.Path, "is_dir", return_value=False):
            with self.assertRaisesRegex(manager.SetupError, "Steam or ES-DE"):
                manager.default_frontend()

    def test_console_dispatches_to_retro_with_managed_home(self):
        storage = unittest.mock.Mock()
        storage.root = Path("/games")
        with patch.object(manager, "default_frontend", return_value="retro"), \
                patch.object(manager, "read_json", return_value={}), \
                patch.object(manager, "refresh_generated") as refresh, \
                patch.object(manager, "app_binary", return_value=Path("/Applications/ES-DE.app/Contents/MacOS/ES-DE")), \
                patch.object(manager, "run") as run:
            manager.launch(storage, "console")
            refresh.assert_called_once_with(storage, {})
            run.assert_called_once_with(["/usr/bin/open", "-a", "/Applications/ES-DE.app", "--args", "--home", "/games/Frontend"])

    def test_explicit_steam_launch_does_not_change_or_use_default(self):
        self.config.write_text('{"default": "es-de"}')
        with patch.object(manager, "default_frontend") as default, \
                patch.object(manager, "app_binary"), patch.object(manager, "run") as run:
            manager.launch(unittest.mock.Mock(), "steam")
        default.assert_not_called()
        run.assert_called_once_with(["/usr/bin/open", "steam://open/bigpicture"])
        self.assertEqual(manager.frontend_preference(), "es-de")


class AutoLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        home = patch.object(manager.Path, "home", return_value=self.home)
        home.start()
        self.addCleanup(home.stop)

    def write_agent(self, content):
        agent = manager.login_agent()
        agent.parent.mkdir(parents=True, exist_ok=True)
        agent.write_bytes(plistlib.dumps(content))
        return agent

    def test_default_off_without_creating_files(self):
        self.assertEqual(manager.login_status(), {"enabled": False, "delay": 30, "legacy": False})
        self.assertFalse(manager.login_agent().exists())

    def test_enable_saves_controller_helper_for_next_login_only(self):
        helper = self.home / "CouchCube.app/Contents/MacOS/ConsoleAutoLaunch"
        with patch.object(manager, "login_helper", return_value=helper), \
                patch.object(manager, "app_binary", return_value=Path("/steam")), \
                patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 113, stderr=b"")) as run:
            manager.login_launcher(True, delay=45)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][1], "print")
        state = plistlib.loads(manager.login_agent().read_bytes())
        self.assertEqual(state["ProgramArguments"], [str(helper), "--delay", "45"])
        self.assertTrue(state["RunAtLoad"])
        self.assertNotIn("KeepAlive", state)
        self.assertEqual(manager.login_status(), {"enabled": True, "delay": 45, "legacy": False})

    def test_disable_stops_waiting_helper_and_removes_login_entry(self):
        self.write_agent({"Label": manager.LOGIN_LABEL,
                          "ProgramArguments": ["/Applications/CouchCube.app/Contents/MacOS/ConsoleAutoLaunch",
                                               "--delay", "30"]})
        with patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            manager.login_launcher(True, enabled=False)
        self.assertEqual(run.call_args.args[0][1], "bootout")
        self.assertFalse(manager.login_agent().exists())

    def test_old_unconditional_launcher_is_recognized(self):
        self.write_agent({"Label": manager.LOGIN_LABEL,
                          "ProgramArguments": ["/usr/bin/open", "steam://open/bigpicture"]})
        self.assertTrue(manager.login_status()["legacy"])

    def test_consent_and_delay_validation_precede_changes(self):
        with patch.object(manager.subprocess, "run") as run:
            for confirm, delay in [(False, 30), (True, 4), (True, 301), (True, True)]:
                with self.assertRaises(manager.SetupError):
                    manager.login_launcher(confirm, delay=delay)
            run.assert_not_called()
        self.assertFalse(manager.login_agent().exists())

    def test_unknown_agent_preserved(self):
        agent = self.write_agent({"Label": manager.LOGIN_LABEL, "ProgramArguments": ["/unrelated"]})
        original = agent.read_bytes()
        with self.assertRaisesRegex(manager.SetupError, "Unrecognized"):
            manager.login_launcher(True, enabled=False)
        self.assertEqual(agent.read_bytes(), original)

    def test_symlink_agent_refused(self):
        target = self.home / "keep.plist"
        target.write_bytes(b"keep")
        agent = manager.login_agent()
        agent.parent.mkdir(parents=True)
        agent.symlink_to(target)
        with self.assertRaises(manager.SetupError):
            manager.login_launcher(True, enabled=False)
        self.assertEqual(target.read_bytes(), b"keep")

    def test_launchctl_error_preserves_settings(self):
        agent = self.write_agent({"Label": manager.LOGIN_LABEL,
                                 "ProgramArguments": ["/usr/bin/open", "steam://open/bigpicture"]})
        original = agent.read_bytes()
        with patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, stderr=b"denied")):
            with self.assertRaisesRegex(manager.SetupError, "denied"):
                manager.login_launcher(True, enabled=False)
        self.assertEqual(agent.read_bytes(), original)

    def test_missing_steam_prevents_installation(self):
        with patch.object(manager, "login_helper", return_value=Path("/helper")), \
                patch.object(manager, "app_binary", side_effect=manager.SetupError("Install Steam.app")), \
                patch.object(manager.subprocess, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "Steam"):
                manager.login_launcher(True)
            run.assert_not_called()
        self.assertFalse(manager.login_agent().exists())

    def test_es_de_login_saves_library_for_dynamic_frontend(self):
        with patch.object(manager, "login_helper", return_value=Path("/ConsoleAutoLaunch")), \
                patch.object(manager, "configured_storage") as storage, \
                patch.object(manager, "default_frontend", return_value="retro"), \
                patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 113, stderr=b"")):
            manager.login_launcher(True, root="/games")
        storage.assert_called_once_with("/games")
        state = plistlib.loads(manager.login_agent().read_bytes())
        self.assertEqual(state["EnvironmentVariables"], {"COUCH_CUBE_ROOT": "/games"})
        self.assertTrue(manager.login_status()["enabled"])


if __name__ == "__main__":
    unittest.main()
