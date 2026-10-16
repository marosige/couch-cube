import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("cleanup_console", Path(__file__).resolve().parents[1] / "scripts/console.py")
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        for target, replacement in [
            ("app_status", []), ("drives", []), ("steam_libraries", [])
        ]:
            mock = patch.object(console, target, return_value=replacement)
            mock.start()
            self.addCleanup(mock.stop)
        home = patch.object(console.Path, "home", return_value=self.home)
        home.start()
        self.addCleanup(home.stop)
        applications = patch.object(console, "SYSTEM_APPLICATIONS", self.home / "SystemApplications")
        applications.start()
        self.addCleanup(applications.stop)

    def folder(self, relative):
        path = self.home / relative
        path.mkdir(parents=True)
        return path

    def test_scan_is_read_only_and_includes_data_without_installed_apps(self):
        data = self.folder("Library/Application Support/CrossOver")
        save = data / "save.dat"
        save.write_bytes(b"keep until confirmed")
        unrelated = self.folder("Documents/Work")
        plan = console.cleanup_plan()
        self.assertEqual([item["path"] for item in plan["items"]], [str(data)])
        self.assertEqual(save.read_bytes(), b"keep until confirmed")
        self.assertTrue(unrelated.exists())
        self.assertEqual(plan, console.cleanup_plan())

    def test_scan_lists_external_steamapps_not_whole_library(self):
        library = self.folder("ExternalLibrary")
        games = self.folder("ExternalLibrary/steamapps")
        with patch.object(console, "steam_libraries", return_value=[library]):
            paths = [item["path"] for item in console.cleanup_plan()["items"]]
        self.assertEqual(paths, [str(games)])

    def test_symlink_is_rejected_without_touching_destination(self):
        destination = self.folder("Work")
        parent = self.folder("Library/Application Support")
        (parent / "Steam").symlink_to(destination, target_is_directory=True)
        with self.assertRaisesRegex(console.SetupError, "symlink"):
            console.cleanup_plan()
        self.assertTrue(destination.exists())

    def test_confirmation_selection_and_fresh_plan_are_required(self):
        self.folder("ES-DE")
        plan = console.cleanup_plan()
        identifier = plan["items"][0]["id"]
        for ids, token, confirm in [
            ([identifier], plan["token"], False),
            ([], plan["token"], True),
            ([identifier, identifier], plan["token"], True),
            (["unknown"], plan["token"], True),
            ([identifier], "stale", True),
        ]:
            with self.subTest(ids=ids, token=token, confirm=confirm):
                with patch.object(console, "run") as run:
                    with self.assertRaises(console.SetupError):
                        console.prepare_cleanup(ids, token, confirm)
                    run.assert_not_called()

    def test_new_target_invalidates_review(self):
        self.folder("ES-DE")
        plan = console.cleanup_plan()
        self.folder("Library/Application Support/Steam")
        with self.assertRaisesRegex(console.SetupError, "changed"):
            console.prepare_cleanup([plan["items"][0]["id"]], plan["token"], True)

    def test_unselected_data_is_kept_and_selected_data_only_returned_for_trash(self):
        selected = self.folder("ES-DE")
        kept = self.folder("Library/Application Support/Steam")
        plan = console.cleanup_plan()
        identifier = next(item["id"] for item in plan["items"] if item["path"] == str(selected))
        result = console.prepare_cleanup([identifier], plan["token"], True)
        self.assertEqual(result, {"paths": [str(selected)]})
        self.assertTrue(selected.exists())
        self.assertTrue(kept.exists())

    def test_managed_app_uses_brew_without_zap_or_shared_dependency_cleanup(self):
        app = self.folder("Applications/Steam.app")
        contents = self.folder("Applications/Steam.app/Contents")
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.valvesoftware.steam"}, file)
        status = [{"id": "steam", "name": "Steam", "managed": True,
                   "installed": True, "path": str(app)}]
        with patch.object(console, "app_status", return_value=status), \
                patch.object(console, "find_brew", return_value="/test/brew"), \
                patch.object(console, "run") as run:
            plan = console.cleanup_plan()
            item = next(item for item in plan["items"] if item["path"] == str(app))
            self.assertEqual(item["package"], "steam")
            result = console.prepare_cleanup([item["id"]], plan["token"], True)
            self.assertEqual(result, {"paths": []})
            self.assertEqual(run.call_args.args[0], ["/test/brew", "uninstall", "--cask", "steam"])
            self.assertEqual(run.call_count, 1)

    def test_uninstall_failure_stops_cleanup(self):
        plan = {"token": "review", "items": [
            {"id": "app", "path": str(self.home / "Steam.app"), "name": "Steam", "package": "steam"},
            {"id": "data", "path": str(self.home / "data"), "name": "Games", "package": None},
        ]}
        with patch.object(console, "cleanup_plan", return_value=plan), \
                patch.object(console, "find_brew", return_value="/test/brew"), \
                patch.object(console, "run", side_effect=subprocess.CalledProcessError(1, "brew")):
            with self.assertRaises(subprocess.CalledProcessError):
                console.prepare_cleanup(["app", "data"], "review", True)

    def test_overlapping_selections_return_parent_only(self):
        parent = self.folder("Library/Application Support/Steam")
        child = self.folder("Library/Application Support/Steam/steamapps")
        with patch.object(console, "steam_libraries", return_value=[parent]):
            plan = console.cleanup_plan()
            self.assertEqual([item["path"] for item in plan["items"]], [str(parent)])
            self.assertEqual(console.prepare_cleanup(
                [item["id"] for item in plan["items"]], plan["token"], True),
                {"paths": [str(parent)]})
        self.assertTrue(child.exists())

    def test_residual_caches_and_preferences_are_listed_without_app(self):
        cache = self.folder("Library/Caches/com.valvesoftware.steam")
        preferences = self.folder("Library/Preferences") / "com.valvesoftware.steam.plist"
        preferences.write_bytes(plistlib.dumps({"example": True}))
        self.assertEqual({item["path"] for item in console.cleanup_plan()["items"]},
                         {str(cache), str(preferences)})

    def test_selected_library_requires_valid_storage_identity(self):
        root = self.folder("External/Couch Cube")
        (root / console.MARKER).write_text("{}")
        with patch.object(console, "drives", return_value=[{"root": str(root)}]), \
                patch.object(console, "configured_storage", side_effect=console.SetupError("Drive identity changed")):
            with self.assertRaisesRegex(console.SetupError, "identity changed"):
                console.cleanup_plan()
        self.assertTrue(root.exists())

    def test_login_agent_is_disabled_before_settings_removal(self):
        config = self.home / "Library/Application Support/Mac Game Console/setup.json"
        self.folder(str(config.parent.relative_to(self.home)))
        with patch.object(console, "HOST_CONFIG", config), \
                patch.object(console, "login_launcher") as login:
            plan = console.cleanup_plan()
            console.prepare_cleanup([item["id"] for item in plan["items"]], plan["token"], True)
        login.assert_called_once_with(True, enabled=False)


if __name__ == "__main__":
    unittest.main()
