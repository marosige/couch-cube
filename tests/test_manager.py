import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
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

    def test_failed_download_cannot_erase(self):
        plan = manager.format_plan("disk42")
        releases = SimpleNamespace(stage=lambda *args: (_ for _ in ()).throw(ValueError("No release available")))
        with patch.object(manager, "release_tools", return_value=releases), \
                patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk0"}), \
                patch.object(manager, "erase_external") as erase:
            with self.assertRaisesRegex(ValueError, "No release"):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            erase.assert_not_called()

    def test_identity_change_during_download_prevents_erase(self):
        plan = manager.format_plan("disk42")
        def stage(*args):
            self.disk["identity"] = "replacement-disk"
            return Path("/unused")
        with patch.object(manager, "release_tools", return_value=SimpleNamespace(stage=stage)), \
                patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk0"}), \
                patch.object(manager, "run") as run:
            with self.assertRaisesRegex(manager.SetupError, "identity changed"):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            run.assert_not_called()

    def test_preparation_denied_before_download(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "release_tools") as releases:
            with self.assertRaises(manager.SetupError):
                manager.prepare_portable("disk42", plan["token"], "", False)
            releases.assert_not_called()

    def test_download_staging_on_target_disk_is_refused(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "disk_info", return_value={"DeviceIdentifier": "disk42"}), \
                patch.object(manager, "release_tools") as releases, \
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
            def stage(directory, run):
                events.append("download")
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
            with patch.object(manager, "release_tools", return_value=SimpleNamespace(stage=stage)), \
                    patch.object(manager, "disk_info", side_effect=info), \
                    patch.object(manager, "erase_external", side_effect=erase), \
                    patch.object(manager, "drives", side_effect=drives), patch.object(manager, "run", side_effect=run):
                manager.prepare_portable("disk42", plan["token"], "ERASE disk42", True)
            self.assertEqual(events, ["download", "erase", "verify-copy"])
            self.assertEqual((mount / "CouchCube.app/fixture").read_text(), "verified release")
            self.assertFalse((mount / "Couch Cube").exists())

    def test_no_mount_after_erase_never_substitutes_another_drive(self):
        plan = manager.format_plan("disk42")
        with patch.object(manager, "release_tools", return_value=SimpleNamespace(stage=lambda *args: Path("/unused"))), \
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

    def test_prepared_layout_passes_and_missing_directory_fails(self):
        self.initialize()
        self.assertEqual(self.assessment()["state"], "valid layout")
        (self.storage.root / "SteamLibrary").rmdir()
        self.assertIn("Missing directory: SteamLibrary", self.assessment()["issues"])

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


if __name__ == "__main__":
    unittest.main()
