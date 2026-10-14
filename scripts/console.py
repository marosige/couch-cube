#!/usr/bin/env python3
"""Safe storage setup and launch backend for the native macOS setup app."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parent.parent
HOST_CONFIG = Path.home() / "Library/Application Support/Mac Game Console/setup.json"
MARKER = ".mac-game-console.json"
FOLDER = "Mac Game Console"
PACKAGES = {
    "steam": "Steam.app",
    "es-de": "ES-DE.app",
    "retroarch-metal": "RetroArch.app",
    "dolphin": "Dolphin.app",
    "porting-kit": "Porting Kit.app",
}
# Folder names match ES-DE's macOS system definitions.
SYSTEMS = {
    "nes": ("Nintendo Entertainment System", "nes|zip|7z", "nestopia"),
    "snes": ("Super Nintendo", "sfc|smc|zip|7z", "snes9x"),
    "gb": ("Game Boy", "gb|zip|7z", "gambatte"),
    "gbc": ("Game Boy Color", "gbc|zip|7z", "gambatte"),
    "gba": ("Game Boy Advance", "gba|zip|7z", "mgba"),
    "n64": ("Nintendo 64", "n64|z64|v64|zip|7z", "mupen64plus_next"),
    "gc": ("GameCube", "iso|gcz|rvz", "dolphin"),
    "wii": ("Wii", "iso|wbfs|rvz", "dolphin"),
    "psx": ("PlayStation", "cue|chd|m3u|pbp", "pcsx_rearmed"),
    "psp": ("PlayStation Portable", "iso|cso|pbp", "ppsspp"),
    "megadrive": ("Mega Drive / Genesis", "md|bin|zip|7z", "genesis_plus_gx"),
    "segacd": ("Sega CD", "cue|chd|m3u", "genesis_plus_gx"),
    "dreamcast": ("Dreamcast", "gdi|cdi|chd|m3u", "flycast"),
}


class SetupError(Exception):
    pass


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def disk_info(path):
    result = run(["/usr/sbin/diskutil", "info", "-plist", str(path)],
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    info = plistlib.loads(result.stdout)
    if info.get("Error"):
        raise SetupError(info.get("ErrorMessage", "Cannot read disk information"))
    return info


def home_disk():
    # diskutil accepts mountpoints, not arbitrary folders.
    path = Path.home().resolve()
    while not os.path.ismount(path) and path != path.parent:
        path = path.parent
    info = disk_info(path)
    if not info.get("WritableVolume"):
        # Modern macOS has a read-only system snapshot and writable Data volume.
        info = disk_info("/System/Volumes/Data")
    return info


def external_candidate(info, path, physical_disks):
    stores = [entry.get("APFSPhysicalStore") for entry in info.get("APFSPhysicalStores", [])]
    parents = stores + [info.get("ParentWholeDisk"), info.get("DeviceIdentifier")]
    physical = any(re.sub(r"s\d+.*$", "", p or "") in physical_disks for p in parents)
    return (
        info.get("Internal") is False and physical
        and info.get("WritableVolume") is True and not info.get("Locked", False)
        and info.get("VolumeUUID") and info.get("MountPoint") == str(path)
        and path.parent == Path("/Volumes") and not path.is_symlink()
        and os.path.ismount(path) and os.access(path, os.W_OK)
    )


def drives():
    if platform.system() != "Darwin":
        raise SetupError("This setup requires macOS.")
    result = run(["/usr/sbin/diskutil", "list", "-plist", "external", "physical"],
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    physical = set(plistlib.loads(result.stdout).get("WholeDisks", []))
    choices = []
    info = home_disk()
    if info.get("Internal") is True and info.get("WritableVolume") and os.access(Path.home(), os.W_OK):
        choices.append({
            "id": "internal", "mode": "local", "name": "Mac internal SSD (local console)",
            "mount": info["MountPoint"], "uuid": info["VolumeUUID"],
            "root": str(Path.home() / "Games" / FOLDER), "filesystem": info.get("FilesystemType", ""),
            "free": shutil.disk_usage(Path.home()).free,
        })
    for path in sorted(Path("/Volumes").iterdir()):
        if path.is_symlink() or not os.path.ismount(path):
            continue
        try:
            info = disk_info(path)
        except (subprocess.CalledProcessError, SetupError) as exc:
            print(f"Cannot inspect {path}: {exc}", file=sys.stderr)
            continue
        if external_candidate(info, path, physical):
            choices.append({
                "id": info["VolumeUUID"], "mode": "portable",
                "name": info.get("VolumeName", path.name) + " (portable data)",
                "mount": str(path), "uuid": info["VolumeUUID"],
                "root": str(path / FOLDER), "filesystem": info.get("FilesystemType", ""),
                "free": shutil.disk_usage(path).free,
            })
    return choices


def select_drive(identifier):
    matches = [item for item in drives() if item["id"] == identifier]
    if len(matches) != 1:
        raise SetupError("Selected drive is disconnected, locked or not writable. Refresh and select again.")
    return matches[0]


def reject_symlinks(path):
    for part in [path] + list(path.parents):
        if part.is_symlink():
            raise SetupError(f"Refusing a symlink in a managed path: {part}")


class Storage:
    def __init__(self, choice):
        self.choice = choice
        self.root = Path(choice["root"])

    def check(self):
        current = select_drive(self.choice["id"])
        if current["uuid"] != self.choice["uuid"] or current["root"] != str(self.root):
            raise SetupError("Drive identity or mountpoint changed. Run setup again.")
        if any(ord(char) < 32 for char in str(self.root)):
            raise SetupError("The storage path contains unsupported control characters. Rename the volume and refresh.")
        reject_symlinks(self.root)
        return current

    def target(self, relative):
        self.check()
        path = self.root / relative
        if not path.is_relative_to(self.root) or ".." in path.parts:
            raise SetupError("Managed path escapes the game folder.")
        reject_symlinks(path)
        return path

    def mkdir(self, relative):
        self.target(relative).mkdir(parents=True, exist_ok=True)

    def write(self, relative, content, executable=False):
        path = self.target(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, str):
            content = content.encode()
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temp:
            temp.write(content)
            temp_name = temp.name
        try:
            self.check()
            os.chmod(temp_name, 0o755 if executable else 0o644)
            os.replace(temp_name, path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)


def json_text(value):
    return json.dumps(value, indent=2, ensure_ascii=True) + "\n"


def read_json(path):
    with path.open() as file:
        return json.load(file)


def app_binary(name):
    for parent in [Path("/Applications"), Path.home() / "Applications"]:
        app = parent / name
        if app.is_dir():
            with (app / "Contents/Info.plist").open("rb") as file:
                executable = plistlib.load(file)["CFBundleExecutable"]
            binary = app / "Contents/MacOS" / executable
            if binary.is_file() and os.access(binary, os.X_OK):
                return binary
    raise SetupError(f"Install {name} in /Applications or ~/Applications first.")


def app_files(name, action, identifier=None):
    prefix = f"Launchers/{name}.app/Contents"
    args = [action, "--root", '"$ROOT"']
    if identifier:
        args += ["--id", shlex.quote(identifier)]
    # Launchers/<name>.app/Contents/MacOS is four levels below the storage root.
    script = (
        '#!/bin/bash\nset -euo pipefail\n'
        'ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"\n'
        'ERROR_FILE="$(/usr/bin/mktemp)"\n'
        'trap \'rm -f "$ERROR_FILE"\' EXIT\n'
        'if ! /usr/bin/python3 "$ROOT/Runtime/console.py" '
        + " ".join(args) + ' >"$ERROR_FILE" 2>&1; then\n'
        '  cat "$ERROR_FILE" >&2\n'
        '  /usr/bin/osascript - "$ERROR_FILE" <<\'APPLESCRIPT\'\n'
        'on run arguments\n'
        '  set details to read POSIX file (item 1 of arguments)\n'
        '  display alert "Game launcher failed" message details as critical\n'
        'end run\n'
        'APPLESCRIPT\n'
        '  exit 1\nfi\n'
    )
    plist = plistlib.dumps({
        "CFBundleName": name, "CFBundleDisplayName": name,
        "CFBundleIdentifier": "org.macgameconsole." + hashlib.sha256(name.encode()).hexdigest()[:16],
        "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "LSUIElement": True,
    })
    return {
        f"{prefix}/Info.plist": (plist, False),
        f"{prefix}/MacOS/launch": (script.encode(), True),
    }


def generated_files(storage, registrations):
    root = storage.root
    custom = ET.Element("systemList")
    for system, (name, extensions, _) in SYSTEMS.items():
        entry = ET.SubElement(custom, "system")
        fields = {
            "name": system, "fullname": name, "path": f"%ROMPATH%/{system}",
            "extension": " ".join(f".{ext} .{ext.upper()}" for ext in extensions.split("|")),
            "command": "/usr/bin/python3 " + shlex.quote(str(root / "Runtime/console.py"))
            + " emulate --root " + shlex.quote(str(root)) + " --system " + system + " --rom %ROM%",
            "platform": system, "theme": system,
        }
        for key, value in fields.items():
            ET.SubElement(entry, key).text = value
    files = {
        "Runtime/console.py": (Path(__file__).read_bytes(), False),
        "Frontend/ES-DE/custom_systems/es_systems.xml": (ET.tostring(custom, encoding="utf-8", xml_declaration=True), False),
        "Config/retroarch-console.cfg": (
            "".join(f'{key} = {json.dumps(str(root / value), ensure_ascii=False)}\n' for key, value in {
                "system_directory": "BIOS/retroarch",
                "savefile_directory": "Saves/RetroArch",
                "savestate_directory": "Saves/RetroArch/States",
            }.items()).encode() + b'video_fullscreen = "true"\n'
            b'savefiles_in_content_dir = "false"\n'
            b'savestates_in_content_dir = "false"\n', False),
    }
    files["Config/steam-shortcuts.txt"] = (
        ("Steam > Games > Add a Non-Steam Game > Browse. Add these .app bundles:\n\n"
         + "\n".join(str(root / "Launchers" / (name + ".app")) for name in
                     ["Retro", "Steam Big Picture"] + [item["name"] for item in registrations])
         + "\nKeep Steam Input enabled for native Steam games. If ES-DE sees double input, "
         "disable Steam Input for the Retro shortcut and configure the controller in ES-DE.\n").encode(), False)
    files.update(app_files("Retro", "retro"))
    files.update(app_files("Steam Big Picture", "steam"))
    for item in registrations:
        files.update(app_files(item["name"], "launch", item["id"]))
    return files


def settings_content(storage):
    path = storage.target("Frontend/ES-DE/settings/es_settings.xml")
    if path.exists():
        text = re.sub(r"<\?xml[^>]*\?>", "", path.read_text())
        wrapper = ET.fromstring("<settings>" + text + "</settings>")
        root = wrapper.find("settings")
        if root is None:
            root = wrapper
    else:
        root = ET.Element("settings")
    matches = root.findall("./string[@name='ROMDirectory']")
    setting = matches[0] if matches else ET.SubElement(root, "string", {"name": "ROMDirectory"})
    setting.set("value", str(storage.root / "ROMs"))
    # ES-DE 3.x uses sibling XML elements, not a standard XML document root.
    return b'<?xml version="1.0"?>\n' + b"\n".join(ET.tostring(child, encoding="utf-8") for child in root) + b"\n"


def refresh_generated(storage, state):
    files = generated_files(storage, state.get("games", []))
    settings = settings_content(storage)
    managed = state.get("managed", {})
    for relative, (content, _) in files.items():
        path = storage.target(relative)
        if path.exists():
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            wanted = hashlib.sha256(content).hexdigest()
            if actual != managed.get(relative) and actual != wanted:
                raise SetupError(f"Preserving modified/unmanaged file: {path}. Move it aside before rerunning.")
    for relative, (content, executable) in files.items():
        storage.write(relative, content, executable)
        managed[relative] = hashlib.sha256(content).hexdigest()
    state["managed"] = managed
    storage.write(MARKER, json_text(state))
    storage.write("Frontend/ES-DE/settings/es_settings.xml", settings)


def initialize(storage):
    storage.check()
    marker = storage.target(MARKER)
    if storage.root.exists() and not marker.exists() and any(storage.root.iterdir()):
        raise SetupError(f"Preserving existing unrecognized folder: {storage.root}. Rename it or choose another drive.")
    state = read_json(marker) if marker.exists() else {"version": 1, "games": [], "managed": {}}
    if state.get("version") != 1:
        raise SetupError("Unsupported setup version; preserving existing data.")
    if state.get("uuid", storage.choice["uuid"]) != storage.choice["uuid"]:
        raise SetupError("This folder belongs to a different volume. Preserving it.")
    state.update({"uuid": storage.choice["uuid"], "mode": storage.choice["mode"], "id": storage.choice["id"]})
    storage.mkdir(".")
    # Mark ownership before generating files so interrupted first setups are recoverable.
    if not marker.exists():
        storage.write(MARKER, json_text(state))
    folders = [
        "SteamLibrary", "ROMs", "BIOS/retroarch/dc", "BIOS/PCSX2",
        "Saves/RetroArch/States", "Saves/Dolphin", "Saves/Native", "Saves/Windows",
        "Native/Games", "Native/Assets", "Windows/Wrappers", "Windows/Installers",
        "Frontend", "Config", "Runtime", "Launchers",
    ]
    folders += ["ROMs/" + system for system in SYSTEMS] + ["ROMs/ps2"]
    for folder in folders:
        storage.mkdir(folder)
    refresh_generated(storage, state)
    return state


def find_brew():
    for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", shutil.which("brew")]:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SetupError("Homebrew is missing. Install from https://brew.sh yourself, then rerun setup. No installer was downloaded.")


def install_packages(packages):
    if not packages:
        return
    if any(item not in PACKAGES for item in packages):
        raise SetupError("Unknown package selection.")
    brew = find_brew()
    installed = run([brew, "list", "--cask"], stdout=subprocess.PIPE, text=True).stdout.splitlines()
    for package in packages:
        if package in installed:
            print(f"Already installed: {package}", flush=True)
            continue
        print(f"Installing host component: {package}", flush=True)
        run([brew, "install", "--cask", package])


def save_host_config(choice):
    reject_symlinks(HOST_CONFIG)
    HOST_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=HOST_CONFIG.parent, mode="w", delete=False) as file:
        file.write(json_text({"id": choice["id"], "uuid": choice["uuid"]}))
        temporary = file.name
    os.replace(temporary, HOST_CONFIG)


def configured_storage(root=None):
    if root is not None:
        path = Path(root).absolute()
        reject_symlinks(path)
        state = read_json(path / MARKER)
        choice = select_drive(state["id"])
        if choice["root"] != str(path) or choice["uuid"] != state["uuid"]:
            raise SetupError("Drive moved or is disconnected. Run setup on this Mac to reconnect it.")
    else:
        config = read_json(HOST_CONFIG)
        choice = select_drive(config["id"])
        if choice["uuid"] != config["uuid"]:
            raise SetupError("Configured drive identity changed.")
    storage = Storage(choice)
    storage.check()
    if not storage.target(MARKER).is_file():
        raise SetupError("Setup is incomplete. Run setup again.")
    return storage


def portable_app(storage, relative):
    path = storage.target(relative)
    if not path.is_dir() or path.suffix != ".app":
        raise SetupError(f"Application missing: {path}. Supply a macOS .app, not a Windows .exe.")
    return path


def register(storage, name, kind, relative):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 _-]{0,63}", name) or name.casefold() in ["retro", "steam big picture"]:
        raise SetupError("Use a unique game name (1-64 letters/numbers/spaces/_/-).")
    path = Path(relative)
    allowed = "Native/Games" if kind == "native" else "Windows/Wrappers"
    if path.is_absolute() or ".." in path.parts or not path.is_relative_to(Path(allowed)):
        raise SetupError(f"The app must be inside {allowed} on the selected drive.")
    portable_app(storage, relative)
    state = read_json(storage.target(MARKER))
    identifier = hashlib.sha256(name.encode()).hexdigest()[:16]
    if any(item["name"].casefold() == name.casefold() and item["name"] != name
           for item in state["games"]):
        raise SetupError("A game name already differs only by case. Use a distinct name.")
    if any(item["name"] == name and (item["path"] != relative or item["kind"] != kind)
           for item in state["games"]):
        raise SetupError("That name already refers to a different game; choose a unique name.")
    if not any(item["id"] == identifier for item in state["games"]):
        state["games"].append({"id": identifier, "name": name, "kind": kind, "path": relative})
    refresh_generated(storage, state)
    print(f"Created {storage.root / 'Launchers' / (name + '.app')}", flush=True)


def launch(storage, action, identifier=None):
    storage.check()
    if action == "steam":
        app_binary("Steam.app")
        run(["/usr/bin/open", "steam://open/bigpicture"])
    elif action == "retro":
        state = read_json(storage.target(MARKER))
        refresh_generated(storage, state)
        binary = app_binary("ES-DE.app")
        run([str(binary), "--home", str(storage.root / "Frontend")])
    elif action == "launch":
        games = read_json(storage.target(MARKER))["games"]
        matches = [game for game in games if game["id"] == identifier]
        if len(matches) != 1:
            raise SetupError("No registered game matches this shortcut.")
        app = portable_app(storage, matches[0]["path"])
        run(["/usr/bin/open", "-W", str(app)])


def emulate(storage, system, rom):
    if system not in SYSTEMS:
        raise SetupError("Unknown emulation system.")
    path = Path(rom).absolute()
    reject_symlinks(path)
    if not path.is_relative_to(storage.root / "ROMs" / system) or not path.is_file():
        raise SetupError("ROM must be a file in the selected system's ROM folder.")
    core = SYSTEMS[system][2]
    if core == "dolphin":
        binary = app_binary("Dolphin.app")
        args = [str(binary), "-b", "-e", str(path), "-u", str(storage.root / "Saves/Dolphin")]
    else:
        binary = app_binary("RetroArch.app")
        core_path = Path.home() / "Library/Application Support/RetroArch/cores" / (core + "_libretro.dylib")
        if not core_path.is_file():
            raise SetupError(f"Missing core: {core_path.name}. Install it in RetroArch > Online Updater > Core Downloader.")
        args = [str(binary), "-L", str(core_path), "--appendconfig",
                str(storage.root / "Config/retroarch-console.cfg"), str(path)]
    run(args)


def vdf_value(text, key):
    match = re.search(r'"' + re.escape(key) + r'"\s+"((?:\\.|[^"\\])*)"', text, re.IGNORECASE)
    if not match:
        raise SetupError(f"Steam manifest is missing {key}.")
    return match.group(1).replace(r"\\", "\\").replace(r'\"', '"')


def index_games(storage):
    libraries = {Path.home() / "Library/Application Support/Steam", storage.root / "SteamLibrary"}
    vdf = Path.home() / "Library/Application Support/Steam/steamapps/libraryfolders.vdf"
    if vdf.exists():
        for value in re.findall(r'"path"\s+"((?:\\.|[^"\\])*)"', vdf.read_text()):
            libraries.add(Path(value.replace(r"\\", "\\").replace(r'\"', '"')))
    steam = {}
    for library in sorted(libraries):
        for manifest in sorted((library / "steamapps").glob("appmanifest_*.acf")):
            text = manifest.read_text()
            appid = vdf_value(text, "appid")
            if not appid.isdigit():
                raise SetupError(f"Invalid Steam app ID in {manifest}")
            steam[appid] = {"appid": appid, "name": vdf_value(text, "name"),
                            "manifest": str(manifest), "url": "steam://rungameid/" + appid}
    emulated = []
    for system, (_, extensions, _) in SYSTEMS.items():
        for rom in sorted((storage.root / "ROMs" / system).rglob("*")):
            if rom.is_file() and rom.suffix.lower().lstrip(".") in extensions.split("|"):
                emulated.append({"system": system, "name": rom.stem, "path": str(rom)})
    data = {"steam": list(steam.values()), "emulated": emulated,
            "registered": read_json(storage.target(MARKER))["games"]}
    storage.write("Config/library.json", json_text(data))
    print(f"Wrote {storage.root / 'Config/library.json'}")


def login_launcher(confirm):
    if not confirm:
        raise SetupError("Login installation requires --confirm. No change made.")
    storage = configured_storage()
    if storage.choice["mode"] != "local":
        raise SetupError("Use Steam's own login setting for portable mode; a disconnected drive must not trigger writes.")
    label = "com.mac-game-console.steam-big-picture"
    agent = Path.home() / "Library/LaunchAgents" / (label + ".plist")
    log_dir = HOST_CONFIG.parent / "Logs"
    reject_symlinks(agent)
    reject_symlinks(log_dir)
    if agent.exists():
        with agent.open("rb") as file:
            previous = plistlib.load(file)
        if previous.get("Label") != label:
            raise SetupError("Preserving an unrecognized existing LaunchAgent.")
    agent.parent.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    content = plistlib.dumps({
        "Label": label,
        "ProgramArguments": ["/usr/bin/open", "steam://open/bigpicture"],
        "RunAtLoad": True,
        "StandardOutPath": str(log_dir / "steam.log"),
        "StandardErrorPath": str(log_dir / "steam-errors.log"),
    })
    domain = f"gui/{os.getuid()}"
    exists = subprocess.run(["/bin/launchctl", "print", domain + "/" + label],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if exists.returncode == 0:
        run(["/bin/launchctl", "bootout", domain + "/" + label])
    elif exists.returncode != 113:
        raise SetupError("Cannot inspect login agent: " + exists.stderr.decode(errors="replace"))
    agent.write_bytes(content)
    run(["/bin/launchctl", "bootstrap", domain, str(agent)])
    print(f"Installed login launcher: {agent}")


def shell_env(storage):
    root = storage.root
    for key, value in {
        "ROMS_ROOT": root / "ROMs", "BIOS_ROOT": root / "BIOS/retroarch",
        "LIBRARY_INDEX_JSON": root / "Config/library.json",
        "STEAM_APPS_VDF": Path.home() / "Library/Application Support/Steam/steamapps/libraryfolders.vdf",
        "STEAM_COMMON_DEFAULT": root / "SteamLibrary/steamapps/common",
        "EMULATIONSTATION_APP": "/Applications/ES-DE.app",
        "OPENEMU_APP": "/Applications/OpenEmu.app", "RETROARCH_APP": "/Applications/RetroArch.app",
    }.items():
        print(key + "=" + shlex.quote(str(value)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("drives")
    login = sub.add_parser("login")
    login.add_argument("--confirm", action="store_true")
    setup = sub.add_parser("setup")
    setup.add_argument("--drive", required=True)
    setup.add_argument("--confirm", action="store_true")
    setup.add_argument("--install", nargs="*", choices=list(PACKAGES), default=[])
    for action in ["env", "index", "steam", "retro", "launch", "emulate", "register"]:
        command = sub.add_parser(action)
        command.add_argument("--root")
        if action == "launch":
            command.add_argument("--id", required=True)
        if action == "emulate":
            command.add_argument("--system", required=True)
            command.add_argument("--rom", required=True)
        if action == "register":
            command.add_argument("--name", required=True)
            command.add_argument("--kind", choices=["native", "windows"], required=True)
            command.add_argument("--app", required=True)
    args = parser.parse_args()
    try:
        if args.command == "drives":
            print(json_text(drives()))
        elif args.command == "login":
            login_launcher(args.confirm)
        elif args.command == "setup":
            if not args.confirm:
                raise SetupError("No changes made. Setup requires explicit --confirm consent.")
            choice = select_drive(args.drive)
            if choice["filesystem"] not in ["apfs", "hfs"]:
                raise SetupError("Use an existing APFS or Mac OS Extended volume for apps/Wine/Steam. No formatting performed.")
            if args.install:
                find_brew()  # Fail before storage writes if host installations cannot run.
            print(f"Setting up {choice['mode']} data: {choice['root']}", flush=True)
            storage = Storage(choice)
            initialize(storage)
            install_packages(args.install)
            storage.check()
            save_host_config(choice)
            print("Setup complete. See README for Steam Storage, controller and Windows-wrapper steps.", flush=True)
        else:
            storage = configured_storage(args.root)
            if args.command == "env":
                shell_env(storage)
            elif args.command == "index":
                index_games(storage)
            elif args.command == "register":
                register(storage, args.name, args.kind, args.app)
            elif args.command == "emulate":
                emulate(storage, args.system, args.rom)
            else:
                launch(storage, args.command, getattr(args, "id", None))
    except (SetupError, OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
