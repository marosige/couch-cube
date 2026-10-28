import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("console", Path(__file__).resolve().parents[1] / "scripts/console.py")
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.choice = {
            "id": "TEST-UUID", "uuid": "TEST-UUID", "mode": "portable",
            "root": str(self.base / 'Drive with spaces & "quotes"' / console.FOLDER),
            "mount": str(self.base), "filesystem": "apfs",
        }
        self.discovery = patch.object(console, "drives", return_value=[self.choice])
        self.discovery.start()
        self.addCleanup(self.discovery.stop)
        self.storage = console.Storage(self.choice)

    def initialize(self):
        return console.initialize(self.storage, systems=list(console.SYSTEMS))

    def test_setup_preserves_roms_and_repeated_runs(self):
        self.initialize()
        rom = self.storage.root / "ROMs/snes/My game.sfc"
        rom.write_bytes(b"user data")
        settings = self.storage.root / "Frontend/ES-DE/settings/es_settings.xml"
        settings.write_text('<string name="Theme" value="my-theme"/>\n<string name="ROMDirectory" value="old"/>')
        self.initialize()
        self.assertEqual(rom.read_bytes(), b"user data")
        values = ET.fromstring("<settings>" + settings.read_text().split("?>", 1)[1] + "</settings>")
        self.assertEqual(values.find("./string[@name='Theme']").get("value"), "my-theme")
        self.assertEqual(values.find("./string[@name='ROMDirectory']").get("value"), str(self.storage.root / "ROMs"))
        self.assertTrue((self.storage.root / "Native/Assets").is_dir())
        self.assertTrue((self.storage.root / "Windows/Wrappers").is_dir())

    def test_unrecognized_folder_not_overwritten(self):
        self.storage.root.mkdir(parents=True)
        game = self.storage.root / "existing-game"
        game.write_text("keep")
        with self.assertRaises(console.SetupError):
            self.initialize()
        self.assertEqual(game.read_text(), "keep")
        self.assertFalse((self.storage.root / console.MARKER).exists())

    def test_setup_creates_only_supported_system_folders(self):
        self.initialize()
        folders = {path.name for path in (self.storage.root / "ROMs").iterdir()}
        self.assertEqual(folders, set(console.SYSTEMS))
        self.assertFalse((self.storage.root / "BIOS/PCSX2").exists())

    def test_bios_environment_contains_only_checker_input(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            console.shell_env(self.storage)
        import shlex
        self.assertEqual(shlex.split(output.getvalue()),
                         ["BIOS_ROOT=" + str(self.storage.root / "BIOS/retroarch")])

    def test_new_library_starts_with_no_consoles_or_unwanted_folders(self):
        state = console.initialize(self.storage)
        self.assertEqual(state["systems"], [])
        self.assertEqual(list((self.storage.root / "ROMs").iterdir()), [])

    def test_console_selection_includes_switch_and_preserves_disabled_games(self):
        self.initialize()
        rom = self.storage.root / "ROMs/snes/mine.sfc"
        rom.write_bytes(b"own game")
        console.select_systems(self.storage, ["gc", "wii", "wiiu", "ps2", "ps3", "switch"])
        state = console.read_json(self.storage.root / console.MARKER)
        self.assertIn("switch", state["systems"])
        self.assertTrue((rom.parent / "noload.txt").exists())
        config = ET.parse(self.storage.root / "Frontend/ES-DE/custom_systems/es_systems.xml")
        self.assertEqual({item.findtext("name") for item in config.findall("system")}, set(state["systems"]))
        console.select_systems(self.storage, state["systems"] + ["snes"])
        self.assertFalse((rom.parent / "noload.txt").exists())
        self.assertEqual(rom.read_bytes(), b"own game")

    def test_console_selection_preserves_customized_files_and_manifest(self):
        self.initialize()
        marker = (self.storage.root / console.MARKER).read_bytes()
        custom = self.storage.root / "Frontend/ES-DE/custom_systems/es_systems.xml"
        custom.write_text("user customized")
        with self.assertRaisesRegex(console.SetupError, "Preserving"):
            console.select_systems(self.storage, ["gc"])
        self.assertEqual(custom.read_text(), "user customized")
        self.assertEqual((self.storage.root / console.MARKER).read_bytes(), marker)

    def test_console_toggle_writes_only_changed_files(self):
        self.initialize()
        enabled = [system for system in console.SYSTEMS if system != "snes"]
        with patch.object(self.storage, "write", wraps=self.storage.write) as write, \
                patch.object(console, "drives", return_value=[self.choice]) as discovery:
            console.select_systems(self.storage, enabled)
        written = {call.args[0] for call in write.call_args_list}
        self.assertEqual(written, {
            "ROMs/snes/noload.txt",
            "Frontend/ES-DE/custom_systems/es_systems.xml",
            console.MARKER,
        })
        self.assertLessEqual(discovery.call_count, 15)
        with patch.object(self.storage, "write", wraps=self.storage.write) as write:
            console.select_systems(self.storage, list(console.SYSTEMS))
        self.assertEqual({call.args[0] for call in write.call_args_list}, {
            "Frontend/ES-DE/custom_systems/es_systems.xml", console.MARKER,
        })
        self.assertFalse((self.storage.root / "ROMs/snes/noload.txt").exists())

    def test_ps2_launch_does_not_require_retroarch(self):
        self.initialize()
        rom = self.storage.root / "ROMs/ps2/mine.iso"
        rom.write_bytes(b"own dump")
        with patch.object(console, "app_binary", return_value=Path("/pcsx2")) as binary, \
                patch.object(console, "prepare_emulator") as prepare, \
                patch.object(console, "run") as run:
            console.emulate(self.storage, "ps2", str(rom))
        prepare.assert_called_once_with(self.storage, "pcsx2", Path("/pcsx2"))
        self.assertEqual(binary.call_count, 2)
        run.assert_called_once_with(["/pcsx2", "-fullscreen", "-batch", str(rom)])

    def test_disabled_console_refuses_launch(self):
        self.initialize()
        rom = self.storage.root / "ROMs/gc/mine.iso"
        rom.write_bytes(b"own dump")
        console.select_systems(self.storage, [])
        with patch.object(console, "run") as run:
            with self.assertRaisesRegex(console.SetupError, "disabled"):
                console.emulate(self.storage, "gc", str(rom))
            run.assert_not_called()

    def test_modified_generated_file_preserved(self):
        self.initialize()
        custom = self.storage.root / "Frontend/ES-DE/custom_systems/es_systems.xml"
        custom.write_text("user customized")
        with self.assertRaises(console.SetupError):
            self.initialize()
        self.assertEqual(custom.read_text(), "user customized")

    def test_disconnection_does_not_recreate_mount(self):
        with patch.object(console, "drives", return_value=[]):
            with self.assertRaises(console.SetupError):
                self.initialize()
        self.assertFalse(self.storage.root.exists())

    def test_disconnect_during_setup_stops_writes(self):
        self.initialize()
        with patch.object(console, "drives", return_value=[]):
            with self.assertRaises(console.SetupError):
                self.storage.write("ROMs/unwanted", "no")
        self.assertFalse((self.storage.root / "ROMs/unwanted").exists())

    def test_partial_first_setup_can_be_retried(self):
        original = self.storage.write
        def interrupted(relative, content, executable=False):
            if relative == "Frontend/ES-DE/custom_systems/es_systems.xml":
                raise console.SetupError("Drive disconnected")
            return original(relative, content, executable)
        with patch.object(self.storage, "write", side_effect=interrupted):
            with self.assertRaises(console.SetupError):
                self.initialize()
        self.assertTrue((self.storage.root / console.MARKER).exists())
        self.initialize()
        self.assertTrue((self.storage.root / "Launchers/Retro.app/Contents/MacOS/launch").exists())

    def test_remount_regenerates_absolute_config_and_keeps_data(self):
        self.initialize()
        rom = self.storage.root / "ROMs/nes/test.nes"
        rom.write_bytes(b"preserve")
        new_root = self.base / "Renamed Drive" / console.FOLDER
        new_root.parent.mkdir()
        self.storage.root.rename(new_root)
        self.choice["root"] = str(new_root)
        new_storage = console.Storage(self.choice)
        console.initialize(new_storage)
        self.assertEqual((new_root / "ROMs/nes/test.nes").read_bytes(), b"preserve")
        config = ET.parse(new_root / "Frontend/ES-DE/custom_systems/es_systems.xml")
        self.assertIn(str(new_root), config.find("./system/command").text)

    def test_symlink_and_traversal_rejected(self):
        self.initialize()
        outside = self.base / "outside"
        outside.mkdir()
        (self.storage.root / "linked").symlink_to(outside, target_is_directory=True)
        for path in ["linked/file", "../escape"]:
            with self.assertRaises(console.SetupError):
                self.storage.write(path, "no")
        self.assertEqual(list(outside.iterdir()), [])

    def test_wrong_volume_identity(self):
        self.initialize()
        changed = dict(self.choice, uuid="OTHER-VOLUME")
        with patch.object(console, "drives", return_value=[changed]):
            with self.assertRaises(console.SetupError):
                self.storage.mkdir("wrong")

    def test_generated_esde_config_quotes_paths_and_rom_placeholder(self):
        self.initialize()
        config = ET.parse(self.storage.root / "Frontend/ES-DE/custom_systems/es_systems.xml")
        entries = config.findall("system")
        self.assertEqual(len(entries), len(console.SYSTEMS))
        for entry in entries:
            command = entry.findtext("command")
            self.assertTrue(command.endswith("--rom %ROM%"))
            import shlex
            tokens = shlex.split(command)
            self.assertEqual(tokens[0], "/bin/bash")
            self.assertEqual(tokens[1], str(self.storage.root / "Runtime/emulate.sh"))
            self.assertNotIn("/usr/bin/python3", tokens)
        self.assertEqual(config.find("./system[name='psx']/path").text, "%ROMPATH%/psx")

    def test_non_ascii_volume_name_preserved_in_retroarch_config(self):
        self.choice["root"] = str(self.base / "J\u00e1t\u00e9k SSD" / console.FOLDER)
        storage = console.Storage(self.choice)
        console.initialize(storage)
        cfg = (storage.root / "Config/retroarch-console.cfg").read_text()
        self.assertIn("J\u00e1t\u00e9k SSD", cfg)
        self.assertNotIn(r"\u00", cfg)

    def test_launcher_resolves_own_storage_root(self):
        self.initialize()
        executable = self.storage.root / "Launchers/Retro.app/Contents/MacOS/launch"
        metadata = plistlib.loads((executable.parent.parent / "Info.plist").read_bytes())
        self.assertEqual(metadata["CFBundleExecutable"], "launch")
        subprocess.run(["bash", "-n", str(executable)], check=True)
        evidence = self.base / "args.json"
        # Stub only our temporary runtime; never start an actual emulator or Steam.
        (self.storage.root / "Runtime/console.py").write_text(
            "import json, pathlib, sys\npathlib.Path(" + repr(str(evidence))
            + ").write_text(json.dumps(sys.argv[1:]))\n"
        )
        subprocess.run(["bash", str(executable)], check=True)
        self.assertEqual(json.loads(evidence.read_text()), ["retro", "--root", str(self.storage.root)])

    def test_portable_launcher_runs_after_volume_and_host_path_change(self):
        app = self.storage.root.parent / "CouchCube.app"
        python = app / "Contents/Resources/python/bin/python3"
        python.parent.mkdir(parents=True)
        # This temporary stand-in has no dependency on the old mount location.
        python.write_text('#!/bin/bash\nexec /usr/bin/python3 "$@"\n')
        python.chmod(0o755)
        with patch.object(console.sys, "executable", str(python)):
            self.initialize()
        launcher = self.storage.root / "Launchers/Retro.app/Contents/MacOS/launch"
        script = launcher.read_text()
        self.assertNotIn(str(self.storage.root.parent), script)
        self.assertIn('PYTHON="$ROOT"/', script)
        evidence = self.base / "portable-args.json"
        (self.storage.root / "Runtime/console.py").write_text(
            "import json, pathlib, sys\npathlib.Path(" + repr(str(evidence))
            + ").write_text(json.dumps(sys.argv[1:]))\n"
        )
        moved = self.base / "Different mount & host"
        self.storage.root.parent.rename(moved)
        new_root = moved / console.FOLDER
        subprocess.run(["bash", str(new_root / "Launchers/Retro.app/Contents/MacOS/launch")], check=True)
        self.assertEqual(json.loads(evidence.read_text()), ["retro", "--root", str(new_root)])
        rom = new_root / "ROMs/nes/Test game.nes"
        rom.write_bytes(b"fixture")
        subprocess.run(["bash", str(new_root / "Runtime/emulate.sh"), "--system", "nes", "--rom", str(rom)], check=True)
        self.assertEqual(json.loads(evidence.read_text()),
                         ["emulate", "--root", str(new_root), "--system", "nes", "--rom", str(rom)])

    def test_library_creation_can_avoid_host_config(self):
        with patch.object(sys, "argv", ["console.py", "setup", "--drive", self.choice["id"],
                                      "--confirm", "--no-host-config"]), \
                patch.object(console, "save_host_config") as save:
            self.assertEqual(console.main(), 0)
            save.assert_not_called()
        self.assertTrue((self.storage.root / console.MARKER).exists())

    def test_register_and_launch_windows_wrapper_without_shell_interpolation(self):
        self.initialize()
        relative = "Windows/Wrappers/My Game.app"
        (self.storage.root / relative).mkdir()
        console.register(self.storage, "My Game", "windows", relative)
        console.register(self.storage, "My Game", "windows", relative)
        games = console.read_json(self.storage.root / console.MARKER)["games"]
        self.assertEqual(len(games), 1)
        with patch.object(console, "run") as run:
            console.launch(self.storage, "launch", games[0]["id"])
            run.assert_called_once_with(["/usr/bin/open", "-W", str(self.storage.root / relative)])
        with self.assertRaises(console.SetupError):
            console.register(self.storage, "Bad", "windows", "/Applications/Steam.app")
        with self.assertRaises(console.SetupError):
            console.register(self.storage, "$(touch malicious)", "windows", relative)
        with self.assertRaises(console.SetupError):
            console.register(self.storage, "retro", "windows", relative)
        with self.assertRaises(console.SetupError):
            console.register(self.storage, "my game", "windows", relative)

    def test_missing_core_actionable_error_no_launch(self):
        self.initialize()
        rom = self.storage.root / "ROMs/nes/test.nes"
        rom.write_bytes(b"test")
        with patch.object(console, "app_binary", return_value=Path("/Applications/RetroArch.app/Contents/MacOS/RetroArch")), \
                patch.object(Path, "home", return_value=self.base / "empty-home"):
            with self.assertRaisesRegex(console.SetupError, "Core Downloader"):
                console.emulate(self.storage, "nes", str(rom))

    def test_dolphin_userdata_and_rom_argument(self):
        self.initialize()
        rom = self.storage.root / "ROMs/gc/My Game.rvz"
        rom.write_bytes(b"test")
        with patch.object(console, "app_binary", return_value=Path("/dolphin")), patch.object(console, "run") as run:
            console.emulate(self.storage, "gc", str(rom))
            run.assert_called_once_with(["/dolphin", "-b", "-e", str(rom), "-u", str(self.storage.root / "Saves/Dolphin")])

    def test_index_reads_manifests_not_install_directory_names(self):
        self.initialize()
        steamapps = self.storage.root / "SteamLibrary/steamapps"
        steamapps.mkdir()
        (steamapps / "appmanifest_123.acf").write_text('"AppState" { "appid" "123" "name" "A \\"quoted\\" game" }')
        (self.storage.root / "ROMs/psx/Game.chd").write_bytes(b"user supplied")
        with patch.object(Path, "home", return_value=self.base / "host"):
            console.index_games(self.storage)
        result = console.read_json(self.storage.root / "Config/library.json")
        self.assertEqual(result["steam"][0]["appid"], "123")
        self.assertEqual(result["steam"][0]["name"], 'A "quoted" game')
        self.assertEqual(result["emulated"][0]["system"], "psx")

    def test_no_consent_no_writes_or_installations(self):
        with patch.object(sys, "argv", ["console.py", "setup", "--drive", self.choice["id"]]), \
                patch.object(console, "install_packages") as install, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(console.main(), 1)
            install.assert_not_called()
        self.assertFalse(self.storage.root.exists())

    def test_package_failure_reported_not_success(self):
        with patch.object(console, "find_brew", return_value="/brew"), \
                patch.object(console, "run", side_effect=[
                    subprocess.CompletedProcess([], 0, stdout="steam\n"),
                    subprocess.CalledProcessError(1, ["/brew", "install"]),
                ]):
            with self.assertRaises(subprocess.CalledProcessError):
                console.install_packages(["steam", "es-de"])

    def test_filesystem_refusal_happens_before_writes(self):
        self.choice["filesystem"] = "exfat"
        with patch.object(sys, "argv", ["console.py", "setup", "--drive", self.choice["id"], "--confirm"]), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(console.main(), 1)
        self.assertFalse(self.storage.root.exists())

    def test_bios_checker_distinguishes_alternatives_optional_and_regional_files(self):
        project = self.base / "bios-test"
        (project / "scripts").mkdir(parents=True)
        (project / "config").mkdir()
        import shutil
        for script in ["check-bios.sh", "utils.sh"]:
            shutil.copy(console.PROJECT / "scripts" / script, project / "scripts" / script)
        shutil.copy(console.PROJECT / "config/bios-map.csv", project / "config/bios-map.csv")
        (project / "config/paths.env").write_text('BIOS_ROOT="$HOME/BIOS"\n')
        env = dict(os.environ, HOME=str(project))
        result = subprocess.run(["bash", str(project / "scripts/check-bios.sh")], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout.count("[OPTIONAL ALTERNATIVE]"), 5)
        self.assertEqual(result.stdout.count("[OPTIONAL]"), 2)
        self.assertEqual(result.stdout.count("[REGION NOT FOUND]"), 3)
        self.assertIn("Total missing required BIOS groups: 1", result.stdout)
        bios = project / "BIOS"
        (bios / "dc").mkdir(parents=True)
        for name in ["scph1001.bin", "dc/dc_boot.bin", "dc/dc_flash.bin", "bios_CD_U.bin"]:
            (bios / name).write_bytes(b"fixture")
        result = subprocess.run(["bash", str(project / "scripts/check-bios.sh")], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)


class CatalogTests(unittest.TestCase):
    def test_catalog_needs_no_library_or_app_installation(self):
        with patch.object(console, "read_json") as read, patch.object(console, "app_binary") as app:
            catalog = console.systems_status()
        read.assert_not_called()
        app.assert_not_called()
        self.assertEqual({system["id"] for system in catalog}, set(console.SYSTEMS))
        self.assertFalse(any(system["enabled"] for system in catalog))
        self.assertEqual(next(system["package"] for system in catalog if system["id"] == "switch"), "switch")


class DriveTests(unittest.TestCase):
    def test_external_apfs_physical_required_and_readonly_excluded(self):
        path = Path("/Volumes/Games SSD")
        info = {"Internal": False, "WritableVolume": True, "VolumeUUID": "A",
                "MountPoint": str(path), "APFSPhysicalStores": [{"APFSPhysicalStore": "disk4s2"}]}
        with patch("os.path.ismount", return_value=True), patch("os.access", return_value=True), \
                patch.object(Path, "is_symlink", return_value=False):
            self.assertTrue(console.external_candidate(info, path, {"disk4"}))
            self.assertFalse(console.external_candidate(info, path, {"disk5"}))
            self.assertFalse(console.external_candidate(dict(info, WritableVolume=False), path, {"disk4"}))
            self.assertFalse(console.external_candidate(dict(info, Internal=True), path, {"disk4"}))
            self.assertFalse(console.external_candidate(dict(info, Locked=True), path, {"disk4"}))

    def test_internal_choice_and_duplicate_mountpoint_lookup(self):
        choice = {"id": "internal", "mode": "local", "uuid": "LOCAL", "root": "/Users/test/Games/Couch Cube"}
        with patch.object(console, "drives", return_value=[choice]):
            self.assertEqual(console.select_drive("internal")["mode"], "local")
        with patch.object(console, "drives", return_value=[choice, choice]):
            with self.assertRaises(console.SetupError):
                console.select_drive("internal")

    def test_remounted_external_resolved_by_uuid(self):
        choice = {"id": "VOL-1", "uuid": "VOL-1", "root": "/Volumes/Renamed SSD/Couch Cube"}
        with patch.object(console, "drives", return_value=[choice]):
            self.assertEqual(console.select_drive("VOL-1")["root"], choice["root"])


if __name__ == "__main__":
    unittest.main()


class WindowsAndChatAppTests(unittest.TestCase):
    def test_sikarugir_installs_from_its_tap_and_discord_is_a_plain_cask(self):
        self.assertEqual(console.PACKAGES["sikarugir"], "Sikarugir Creator.app")
        self.assertEqual(console.PACKAGES["discord"], "Discord.app")
        self.assertNotIn("porting-kit", console.PACKAGES)
        with patch.object(console, "find_brew", return_value="/brew"), \
                patch.object(console, "brew_environment", return_value=None), \
                patch.object(console, "run", side_effect=[
                    subprocess.CompletedProcess([], 0, stdout=""), None, None]) as run:
            console.install_packages(["sikarugir", "discord"])
        self.assertEqual([call.args[0] for call in run.call_args_list[1:]],
                         [["/brew", "install", "--cask", "sikarugir-app/sikarugir/sikarugir"],
                          ["/brew", "install", "--cask", "discord"]])
