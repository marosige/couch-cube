#!/usr/bin/env python3
"""Safe storage setup and launch backend for the native macOS setup app."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parent.parent
HOST_CONFIG = Path.home() / "Library/Application Support/Mac Game Console/setup.json"
MARKER = ".mac-game-console.json"
FOLDER = "Couch Cube"
PACKAGES = {
    "steam": "Steam.app",
    "es-de": "ES-DE.app",
    "retroarch-metal": "RetroArch.app",
    "dolphin": "Dolphin.app",
    "porting-kit": "Porting Kit.app",
    "pcsx2": "PCSX2.app",
    "rpcs3": "RPCS3.app",
    "cemu-wiiu": "Cemu.app",
    "switch": "Ryujinx.app",
}
MANUAL_APPS = {
    "rpcs3": "https://rpcs3.net/download",
    "cemu-wiiu": "https://cemu.info/",
    "switch": None,
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
    "wiiu": ("Wii U", "wua|wud|wux|rpx", "cemu-wiiu"),
    "ps2": ("PlayStation 2", "iso|chd|cso|bin", "pcsx2"),
    "ps3": ("PlayStation 3", "self|bin", "rpcs3"),
    "switch": ("Nintendo Switch", "nsp|xci|nro", "switch"),
}
STANDALONE = {"dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch"}

def selected_systems(state):
    selected = state.get("systems", [key for key in SYSTEMS if key not in {"wiiu", "ps2", "ps3", "switch"}])
    if (not isinstance(selected, list) or any(not isinstance(item, str) or item not in SYSTEMS for item in selected)
            or len(set(selected)) != len(selected)):
        raise SetupError("Invalid console selection in the library manifest.")
    return selected


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
                "name": info.get("VolumeName", path.name) + " (portable console)",
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


def assess(identifier):
    choice = select_drive(identifier)
    root = Path(choice["root"])
    issues = []
    notes = []
    if choice["filesystem"] not in ["apfs", "hfs"]:
        issues.append("Unsupported filesystem for this layout: use APFS or Mac OS Extended.")
    if choice["free"] < 20 * 1024 ** 3:
        notes.append("Less than 20 GiB free. Many games need more space; no speed test was performed.")
    state = "not prepared"
    marker = root / MARKER
    try:
        reject_symlinks(root)
        if marker.exists():
            reject_symlinks(marker)
            manifest = read_json(marker)
            if manifest.get("version") != 1 or manifest.get("uuid") != choice["uuid"]:
                raise SetupError("Setup manifest version or volume identity does not match.")
            if not isinstance(manifest.get("managed"), dict) or not isinstance(manifest.get("games"), list):
                raise SetupError("Setup manifest has invalid managed-file/game entries.")
            required_files = {
                "Runtime/console.py", "Runtime/emulate.sh", "Frontend/ES-DE/custom_systems/es_systems.xml",
                "Config/retroarch-console.cfg", "Launchers/Retro.app/Contents/MacOS/launch",
                "Launchers/Retro.app/Contents/Info.plist",
                "Launchers/Steam Big Picture.app/Contents/MacOS/launch",
            }
            for relative in sorted(required_files - set(manifest["managed"])):
                issues.append("Manifest does not track required file: " + relative)
            for relative, digest in manifest["managed"].items():
                path = Storage(choice).target(relative)
                if not isinstance(digest, str) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    issues.append(f"Missing or modified managed file: {relative}")
            for folder in ["ROMs", "BIOS/retroarch", "SteamLibrary", "Saves", "Native/Assets", "Windows/Wrappers"]:
                if not Storage(choice).target(folder).is_dir():
                    issues.append("Missing directory: " + folder)
            if not Storage(choice).target("Frontend/ES-DE/settings/es_settings.xml").is_file():
                issues.append("ES-DE settings are missing. Rerun setup.")
            else:
                text = Storage(choice).target("Frontend/ES-DE/settings/es_settings.xml").read_text()
                parsed = ET.fromstring("<settings>" + re.sub(r"<\?xml[^>]*\?>", "", text) + "</settings>")
                entries = parsed.findall(".//string[@name='ROMDirectory']")
                if not entries or entries[0].get("value") != str(root / "ROMs"):
                    issues.append("ES-DE ROM directory points elsewhere. Rerun setup on this Mac.")
            state = "valid layout" if not issues else "needs attention"
            if choice["mode"] != manifest.get("mode"):
                issues.append("Manifest local/portable mode does not match storage.")
            if manifest.get("managed") == {}:
                issues.append("Incomplete setup: no managed files recorded.")
            cores = Path.home() / "Library/Application Support/RetroArch/cores"
            for system, (_, extensions, core) in SYSTEMS.items():
                folder = Storage(choice).target("ROMs/" + system)
                has_games = folder.is_dir() and any(
                    file.is_file() and file.suffix.lower().lstrip(".") in extensions.split("|")
                    for file in folder.rglob("*")
                )
                if has_games and core not in STANDALONE and not (cores / (core + "_libretro.dylib")).is_file():
                    notes.append(f"Missing host core for ROMs/{system}: {core}. Install using RetroArch Core Downloader.")
        elif root.exists() and any(root.iterdir()):
            issues.append("Existing folder has no setup manifest; it will not be overwritten.")
    except (SetupError, OSError, ValueError, KeyError, AttributeError, TypeError, ET.ParseError) as exc:
        state = "invalid setup"
        issues.append(str(exc))
    missing = []
    for package, name in PACKAGES.items():
        try:
            app_binary(name)
        except (SetupError, OSError, KeyError, ValueError):
            missing.append(package)
    try:
        find_brew()
    except SetupError:
        notes.append("Homebrew missing. Use Install Homebrew... for the official interactive installer.")
    if platform.machine() != "arm64":
        issues.append("This release supports Apple Silicon only, not Intel Macs.")
    notes.append("No SSD benchmark, BIOS authenticity or game compatibility is inferred from metadata.")
    return {"state": state if not issues else "needs attention", "issues": issues,
            "notes": notes, "missing": missing, "root": str(root)}


def physical_disks():
    result = run(["/usr/sbin/diskutil", "list", "-plist", "external", "physical"],
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    identifiers = plistlib.loads(result.stdout).get("WholeDisks", [])
    output = []
    for identifier in identifiers:
        if not re.fullmatch(r"disk\d+", identifier):
            continue
        info = disk_info(identifier)
        if info.get("Internal") is not False or info.get("WholeDisk") is not True:
            continue
        output.append({
            "device": identifier, "model": info.get("MediaName") or info.get("IORegistryEntryName") or "Unknown model",
            "size": info.get("TotalSize", info.get("Size", 0)),
            "identity": info.get("DiskUUID") or info.get("MediaUUID") or "",
            "tree": info.get("DeviceTreePath", ""), "protocol": info.get("BusProtocol", ""),
        })
    return output


def physical_stores(info):
    stores = info.get("APFSPhysicalStores", [])
    if stores:
        return {re.sub(r"s\d+.*$", "", item["APFSPhysicalStore"]) for item in stores}
    return {re.sub(r"s\d+.*$", "", info.get("ParentWholeDisk") or info.get("DeviceIdentifier", ""))}


def enclosing_mount(path):
    path = Path(path).resolve()
    while not os.path.ismount(path) and path != path.parent:
        path = path.parent
    return path


def protected_disks():
    protected = physical_stores(home_disk()) | physical_stores(disk_info("/"))
    for path in [Path(__file__), Path(sys.executable), Path.cwd()]:
        protected |= physical_stores(disk_info(enclosing_mount(path)))
    # An app running from a DMG depends on the disk carrying its backing image.
    result = run(["/usr/bin/hdiutil", "info", "-plist"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    images = plistlib.loads(result.stdout).get("images", [])
    for image in images:
        backing = image.get("image-path")
        if backing and Path(backing).is_absolute():
            protected |= physical_stores(disk_info(enclosing_mount(backing)))
    return protected


def format_plan(device):
    matches = [disk for disk in physical_disks() if disk["device"] == device]
    if len(matches) != 1:
        raise SetupError("Selected whole external physical disk is no longer available.")
    disk = dict(matches[0])
    if device in protected_disks():
        raise SetupError("Refusing a startup/app/runtime/installer-backing disk. Copy the app to a different disk and relaunch it there before erasing this disk.")
    if not disk["identity"] or not disk["tree"] or disk["size"] <= 0:
        raise SetupError("No reliable whole-disk UUID and device identity available. Automatic erase is disabled. Use Apple Disk Utility manually after verifying the physical device.")
    disk["token"] = hashlib.sha256(json_text(disk).encode()).hexdigest()
    return disk


def erase_external(device, token, confirmation, confirm):
    if not confirm or confirmation != "ERASE " + device:
        raise SetupError("No erase performed: explicit consent and exact typed ERASE <device> required.")
    plan = format_plan(device)
    if plan["token"] != token:
        raise SetupError("Disk identity changed since review. Nothing erased; refresh and review again.")
    # No shell, untrusted names, helper elevation or retry on a different device.
    # diskutil handles authorization where supported; permission failures are final.
    run(["/usr/sbin/diskutil", "eraseDisk", "APFS", "Mac Gaming", "GPT", "/dev/" + device])
    print("Erase completed.", flush=True)


def release_tools():
    spec = importlib.util.spec_from_file_location("console_releases", Path(__file__).with_name("releases.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def copy_bundle_contents(source, directory_fd):
    for entry in source.iterdir():
        mode = entry.lstat().st_mode
        if stat.S_ISLNK(mode):
            os.symlink(os.readlink(entry), entry.name, dir_fd=directory_fd)
        elif stat.S_ISDIR(mode):
            os.mkdir(entry.name, mode=0o700, dir_fd=directory_fd)
            child_fd = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
            try:
                copy_bundle_contents(entry, child_fd)
                os.fchmod(child_fd, stat.S_IMODE(mode))
            finally:
                os.close(child_fd)
        elif stat.S_ISREG(mode):
            file_fd = os.open(entry.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o600, dir_fd=directory_fd)
            with os.fdopen(file_fd, "wb") as outgoing, entry.open("rb") as incoming:
                shutil.copyfileobj(incoming, outgoing)
                os.fchmod(outgoing.fileno(), stat.S_IMODE(mode))
        else:
            raise SetupError("Unsupported file in portable app: " + str(entry))

def stage_current_app(directory):
    app = PROJECT.parent.parent
    if app.name != "CouchCube.app" or not (app / "Contents/Info.plist").is_file():
        raise SetupError("Open the built Couch Cube app to copy it to an SSD.")
    reject_symlinks(app)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    for path in app.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise SetupError("App contains an escaping symbolic link; no disk changes made.")
    target = directory / app.name
    run(["/usr/bin/ditto", str(app), str(target)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)])
    return target


def copy_app_to_storage(choice, source):
    if choice["mode"] != "portable":
        raise SetupError("Choose an external SSD for a portable app copy.")
    current = select_drive(choice["id"])
    if any(current[key] != choice[key] for key in ["uuid", "mount", "root"]):
        raise SetupError("SSD identity changed. Nothing copied.")
    destination = Path(choice["mount"]) / source.name
    reject_symlinks(destination)
    if destination.exists():
        raise SetupError("CouchCube.app already exists on this SSD. It will not be overwritten.")
    directory_fd = os.open(choice["mount"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary_name = ".couch-cube-copy-" + uuid.uuid4().hex
    try:
        os.mkdir(temporary_name, dir_fd=directory_fd)
        temporary_fd = os.open(temporary_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            os.mkdir(source.name, dir_fd=temporary_fd)
            app_fd = os.open(source.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=temporary_fd)
            try:
                copy_bundle_contents(source, app_fd)
            finally:
                os.close(app_fd)
            current = select_drive(choice["id"])
            if any(current[key] != choice[key] for key in ["uuid", "mount", "root"]):
                raise SetupError("SSD disconnected or changed during copy.")
            copied = Path(choice["mount"]) / temporary_name / source.name
            if copied.parent.stat().st_ino != os.fstat(temporary_fd).st_ino or copied.parent.stat().st_dev != os.fstat(temporary_fd).st_dev:
                raise SetupError("Copy directory identity changed.")
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied)])
            current = select_drive(choice["id"])
            if destination.exists() or any(current[key] != choice[key] for key in ["uuid", "mount", "root"]):
                raise SetupError("Destination changed before copy completed.")
            os.rename(source.name, destination.name, src_dir_fd=temporary_fd, dst_dir_fd=directory_fd)
        finally:
            os.close(temporary_fd)
        os.rmdir(temporary_name, dir_fd=directory_fd)
    finally:
        os.close(directory_fd)
    print(f"Couch Cube copied to {destination}. Open that copy on the SSD; no files were erased.", flush=True)


def prepare_portable(device, token, confirmation, confirm):
    if not confirm or confirmation != "ERASE " + device:
        raise SetupError("No preparation performed: exact typed erase consent is required.")
    reviewed = format_plan(device)
    if reviewed["token"] != token:
        raise SetupError("Disk identity changed since review. Nothing erased.")
    with tempfile.TemporaryDirectory(prefix="mcc-release-") as temporary:
        staging = Path(temporary)
        if device in physical_stores(disk_info(enclosing_mount(staging))):
            raise SetupError("Download staging relies on the selected disk. Nothing erased.")
        print("Staging and verifying this app before erasing anything. No download needed.", flush=True)
        app = stage_current_app(staging)
        # Revalidate the reviewed drive identity after staging the app.
        erase_external(device, token, confirmation, confirm)
        post_erase = format_plan(device)
        for key in ["tree", "size", "model", "protocol"]:
            if reviewed[key] != post_erase[key]:
                raise SetupError("Disk changed after erase. No app copied; inspect the disk and refresh.")

        def destination_choice():
            if format_plan(device)["token"] != post_erase["token"]:
                raise SetupError("Disk identity changed after erase. No further writes performed.")
            matches = [choice for choice in drives()
                       if choice["mode"] == "portable" and choice["filesystem"] == "apfs"
                       and physical_stores(disk_info(choice["mount"])) == {device}]
            if len(matches) > 1:
                raise SetupError("Multiple volumes appeared on the prepared disk. Refusing to choose one.")
            return matches[0] if matches else None

        choice = None
        for _ in range(10):
            choice = destination_choice()
            if choice:
                break
            time.sleep(0.5)
        if choice is None:
            raise SetupError("Erase completed, but the new APFS volume is not mounted. Refresh and inspect it; do not erase again.")
        destination = Path(choice["mount"]) / app.name
        reject_symlinks(destination)
        if destination.exists():
            raise SetupError("An app already exists at the SSD root. Preserving it.")

        def destination_unchanged():
            current = destination_choice()
            return current is not None and all(
                current[key] == choice[key] for key in ["id", "uuid", "mount", "root"])

        mount_fd = os.open(choice["mount"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if not destination_unchanged():
                raise SetupError("Destination changed before app copy.")
            copy_name = ".mcc-copy-" + uuid.uuid4().hex
            os.mkdir(copy_name, mode=0o700, dir_fd=mount_fd)
            copy_fd = os.open(copy_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=mount_fd)
            try:
                os.mkdir(app.name, mode=0o755, dir_fd=copy_fd)
                app_fd = os.open(app.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=copy_fd)
                try:
                    # Descriptor-relative writes cannot fall back to a reused
                    # /Volumes path if the SSD is disconnected mid-copy.
                    copy_bundle_contents(app, app_fd)
                finally:
                    os.close(app_fd)
                if not destination_unchanged() or destination.exists():
                    raise SetupError("Destination changed during app copy. No app installed.")
                copied = Path(choice["mount"]) / copy_name / app.name
                if copied.parent.stat().st_ino != os.fstat(copy_fd).st_ino or copied.parent.stat().st_dev != os.fstat(copy_fd).st_dev:
                    raise SetupError("Copy directory changed. No app installed.")
                run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied)])
                if not destination_unchanged() or destination.exists():
                    raise SetupError("Destination changed during copy verification. No app installed.")
                os.rename(app.name, destination.name, src_dir_fd=copy_fd, dst_dir_fd=mount_fd)
            finally:
                os.close(copy_fd)
            os.rmdir(copy_name, dir_fd=mount_fd)
        finally:
            os.close(mount_fd)
        print(f"Portable app copied to SSD root: {destination}", flush=True)
        print("Open that app from the SSD and create your game library. Host players still need setup on each Mac.", flush=True)


def copy_installer(storage, source):
    source = Path(source).expanduser().resolve(strict=True)
    if source.suffix.lower() != ".dmg" or not source.is_file():
        raise SetupError("Select an existing real .dmg file. Nothing is downloaded automatically.")
    run(["/usr/bin/hdiutil", "verify", str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    destination = storage.target("Installer/" + source.name)
    if destination.exists():
        raise SetupError("Installer copy already exists; preserving it. Choose a differently named release or remove the old copy yourself.")
    if shutil.disk_usage(storage.root).free < source.stat().st_size + 1024 ** 2:
        raise SetupError("Not enough free space for an installer copy.")
    storage.mkdir("Installer")
    temporary = None
    try:
        with source.open("rb") as incoming, tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as outgoing:
            temporary = Path(outgoing.name)
            digest = hashlib.sha256()
            while True:
                chunk = incoming.read(8 * 1024 * 1024)
                if not chunk:
                    break
                storage.check()
                digest.update(chunk)
                outgoing.write(chunk)
        storage.check()
        copied = hashlib.sha256()
        with temporary.open("rb") as file:
            for chunk in iter(lambda: file.read(8 * 1024 * 1024), b""):
                copied.update(chunk)
        if copied.digest() != digest.digest():
            raise SetupError("Installer copy checksum mismatch.")
        storage.check()
        # Hard-link creation refuses overwrite if another copy appeared concurrently.
        os.link(temporary, destination)
        print(f"Installer copied: {destination}")
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


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


def runtime_assignment(root):
    executable = Path(sys.executable).resolve()
    # Bundled runtime and library on the same volume move together. Never pin
    # those launchers to a host-specific /Volumes name or Applications folder.
    if executable.stat().st_dev == root.stat().st_dev:
        relative = os.path.relpath(executable, root)
        return 'PYTHON="$ROOT"/' + shlex.quote(relative) + "\n"
    return "PYTHON=" + shlex.quote(str(executable)) + "\n"


def app_files(name, action, root, identifier=None):
    prefix = f"Launchers/{name}.app/Contents"
    args = [action, "--root", '"$ROOT"']
    if identifier:
        args += ["--id", shlex.quote(identifier)]
    # Launchers/<name>.app/Contents/MacOS is four levels below the storage root.
    script = (
        '#!/bin/bash\nset -euo pipefail\n'
        'ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"\n'
        + runtime_assignment(root)
        + 'if [[ ! -x "$PYTHON" ]]; then\n'
        '  /usr/bin/osascript -e \'display alert "Manager app not found" '
        'message "Keep CouchCube.app on this drive. Open Game library and update the library after moving the app." as critical\'\n'
        '  exit 1\nfi\n'
        'ERROR_FILE="$(/usr/bin/mktemp)"\n'
        'trap \'rm -f "$ERROR_FILE"\' EXIT\n'
        'if ! "$PYTHON" -I -B "$ROOT/Runtime/console.py" '
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


def generated_files(storage, registrations, systems=None):
    root = storage.root
    custom = ET.Element("systemList")
    for system, (name, extensions, _) in SYSTEMS.items():
        if systems is not None and system not in systems:
            continue
        entry = ET.SubElement(custom, "system")
        fields = {
            "name": system, "fullname": name, "path": f"%ROMPATH%/{system}",
            "extension": " ".join(f".{ext} .{ext.upper()}" for ext in extensions.split("|")),
            "command": "/bin/bash " + shlex.quote(str(root / "Runtime/emulate.sh"))
            + " --system " + system + " --rom %ROM%",
            "platform": system, "theme": system,
        }
        for key, value in fields.items():
            ET.SubElement(entry, key).text = value
    files = {
        "Runtime/console.py": (Path(__file__).read_bytes(), False),
        "Runtime/emulate.sh": ((
            '#!/bin/bash\nset -euo pipefail\n'
            'ROOT="$(cd "$(dirname "$0")/.." && pwd)"\n'
            + runtime_assignment(root)
            + 'exec "$PYTHON" -I -B "$ROOT/Runtime/console.py" emulate --root "$ROOT" "$@"\n'
        ).encode(), True),
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
    if systems is not None:
        for system in SYSTEMS:
            if system not in systems and storage.target("ROMs/" + system).is_dir():
                files[f"ROMs/{system}/noload.txt"] = (b"Disabled by Couch Cube. Re-enable in Consoles.\n", False)
    files["Config/steam-shortcuts.txt"] = (
        ("Steam > Games > Add a Non-Steam Game > Browse. Add these .app bundles:\n\n"
         + "\n".join(str(root / "Launchers" / (name + ".app")) for name in
                     ["Retro", "Steam Big Picture"] + [item["name"] for item in registrations])
         + "\nKeep Steam Input enabled for native Steam games. If ES-DE sees double input, "
         "disable Steam Input for the Retro shortcut and configure the controller in ES-DE.\n").encode(), False)
    files.update(app_files("Retro", "retro", root))
    files.update(app_files("Steam Big Picture", "steam", root))
    for item in registrations:
        files.update(app_files(item["name"], "launch", root, item["id"]))
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
    parse_only = root.find("./bool[@name='ParseGamelistOnly']")
    if parse_only is None:
        parse_only = ET.SubElement(root, "bool", {"name": "ParseGamelistOnly"})
    parse_only.set("value", "false")
    # ES-DE 3.x uses sibling XML elements, not a standard XML document root.
    return b'<?xml version="1.0"?>\n' + b"\n".join(ET.tostring(child, encoding="utf-8") for child in root) + b"\n"


def refresh_generated(storage, state):
    files = generated_files(storage, state.get("games", []), selected_systems(state))
    settings = settings_content(storage)
    managed = state.get("managed", {})
    for relative, (content, _) in files.items():
        path = storage.target(relative)
        if path.exists():
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            wanted = hashlib.sha256(content).hexdigest()
            if actual != managed.get(relative) and actual != wanted:
                raise SetupError(f"Preserving modified/unmanaged file: {path}. Move it aside before rerunning.")
    disabled_markers = [key for key in managed if re.fullmatch(r"ROMs/[^/]+/noload\.txt", key) and key not in files]
    for relative in disabled_markers:
        path = storage.target(relative)
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != managed[relative]:
            raise SetupError("Preserving modified console visibility marker: " + str(path))
    for relative in disabled_markers:
        storage.check()
        path = storage.target(relative)
        if path.exists():
            path.unlink()
        del managed[relative]
    for relative, (content, executable) in files.items():
        storage.write(relative, content, executable)
        managed[relative] = hashlib.sha256(content).hexdigest()
    state["managed"] = managed
    storage.write(MARKER, json_text(state))
    storage.write("Frontend/ES-DE/settings/es_settings.xml", settings)

def select_systems(storage, systems):
    if len(set(systems)) != len(systems) or any(system not in SYSTEMS for system in systems):
        raise SetupError("Unknown or duplicate console selection.")
    state = read_json(storage.target(MARKER))
    state["systems"] = systems
    for system in systems:
        storage.mkdir("ROMs/" + system)
    refresh_generated(storage, state)
    print("Console selection saved. Existing ROMs and saves were kept.", flush=True)


def systems_status(storage=None):
    enabled = selected_systems(read_json(storage.target(MARKER))) if storage else []
    return [{"id": key, "name": name, "enabled": key in enabled,
             "package": core if core in STANDALONE else "retroarch-metal",
             "requirement": ("Own console keys/firmware; bring your own compatible macOS emulator. Not automatically downloaded."
                             if key == "switch" else
                             "Sony firmware installed in RPCS3; game compatibility varies." if key == "ps3" else
                             "Your own PS2 BIOS. Current Homebrew build may require Rosetta." if key == "ps2" else
                             "Your own games; configure controllers in Cemu." if key == "wiiu" else
                             "Dolphin; configure controllers in the emulator." if core == "dolphin" else
                             f"RetroArch core: {core}. Some systems need your own BIOS.")}
            for key, (name, _, core) in SYSTEMS.items()]


def initialize(storage, systems=None):
    storage.check()
    marker = storage.target(MARKER)
    if storage.root.exists() and not marker.exists() and any(storage.root.iterdir()):
        raise SetupError(f"Preserving existing unrecognized folder: {storage.root}. Rename it or choose another drive.")
    state = read_json(marker) if marker.exists() else {
        "version": 1, "games": [], "managed": {}, "systems": systems if systems is not None else []}
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
        "SteamLibrary", "ROMs", "BIOS/retroarch/dc",
        "Saves/RetroArch/States", "Saves/Dolphin", "Saves/Native", "Saves/Windows",
        "Native/Games", "Native/Assets", "Windows/Wrappers", "Windows/Installers",
        "Frontend", "Config", "Runtime", "Launchers",
    ]
    folders += ["ROMs/" + system for system in selected_systems(state)]
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
    if any(item in MANUAL_APPS for item in packages):
        raise SetupError("This emulator requires a manual macOS installation. Open its download page in Apps.")
    brew = find_brew()
    installed = run([brew, "list", "--cask"], stdout=subprocess.PIPE, text=True).stdout.splitlines()
    for package in packages:
        if package in installed:
            print(f"Already installed: {package}", flush=True)
            continue
        print(f"Installing host component: {package}", flush=True)
        run([brew, "install", "--cask", package])

def app_status(check_updates=False):
    brew = None
    try:
        brew = find_brew()
    except SetupError:
        pass
    managed = {}
    if brew:
        info = json.loads(run([brew, "info", "--json=v2", "--cask", "--installed"],
                              stdout=subprocess.PIPE, text=True).stdout)
        managed = {item["token"]: item for item in info.get("casks", [])}
    outdated = {}
    if check_updates:
        if not brew:
            raise SetupError("Install Homebrew to check updates for Homebrew-managed apps.")
        info = json.loads(run([brew, "outdated", "--cask", "--greedy", "--json=v2"],
                              stdout=subprocess.PIPE, text=True).stdout)
        outdated = {item["name"]: item.get("current_version", "") for item in info.get("casks", [])}
    result = []
    for key, name in PACKAGES.items():
        paths = [base / name for base in [Path("/Applications"), Path.home() / "Applications"]]
        path = next((path for path in paths if path.is_dir()), None)
        version = ""
        if path:
            with (path / "Contents/Info.plist").open("rb") as file:
                plist = plistlib.load(file)
            version = str(plist.get("CFBundleShortVersionString", plist.get("CFBundleVersion", "Unknown")))
        result.append({"id": key, "name": name.removesuffix(".app"), "installed": path is not None,
                       "path": str(path) if path else "", "version": version,
                       "brew": brew is not None,
                       "managed": key in managed, "update": outdated.get(key),
                       "manual": key in MANUAL_APPS, "url": MANUAL_APPS.get(key)})
    return result


def manage_app(package, action, confirm=False):
    if not confirm or package not in PACKAGES or action not in {"install", "update", "remove"}:
        raise SetupError("A known app, valid action and explicit confirmation are required.")
    if action == "install":
        install_packages([package])
        return
    status = next(item for item in app_status() if item["id"] == package)
    if not status["managed"]:
        raise SetupError("This app is not managed by Homebrew. Use Finder to move the app to Trash; preferences and games are kept.")
    run([find_brew(), "upgrade" if action == "update" else "uninstall", "--cask", package])
    print("App " + ("updated." if action == "update" else "removed. Games and preferences were kept."), flush=True)


def cleanup_host(confirm):
    if not confirm:
        raise SetupError("Removing Couch Cube settings requires explicit confirmation.")
    login_launcher(True, enabled=False)
    reject_symlinks(HOST_CONFIG)
    if HOST_CONFIG.is_file():
        HOST_CONFIG.unlink()
    log_path = Path.home() / "Library/Logs/Couch Cube/auto-launch.log"
    reject_symlinks(log_path)
    if log_path.is_file():
        log_path.unlink()
    print("Couch Cube login entry and local settings removed. Game folders, saves and other apps were kept.")


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


def default_frontend():
    for package in ["steam", "es-de"]:
        name = PACKAGES[package]
        if any((parent / name).is_dir() for parent in [Path("/Applications"), Path.home() / "Applications"]):
            app_binary(name)
            return "steam" if package == "steam" else "retro"
    raise SetupError("Install Steam or ES-DE from Couch Cube > Apps first.")


def launch(storage, action, identifier=None):
    storage.check()
    if action == "console":
        action = default_frontend()
    if action == "steam":
        app_binary("Steam.app")
        run(["/usr/bin/open", "steam://open/bigpicture"])
    elif action == "retro":
        state = read_json(storage.target(MARKER))
        refresh_generated(storage, state)
        binary = app_binary("ES-DE.app")
        run(["/usr/bin/open", "-a", str(binary.parent.parent.parent),
             "--args", "--home", str(storage.root / "Frontend")])
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
    enabled = selected_systems(read_json(storage.target(MARKER)))
    if system not in enabled:
        raise SetupError("This console is disabled. Enable it in Couch Cube > Consoles.")
    if core == "dolphin":
        binary = app_binary("Dolphin.app")
        args = [str(binary), "-b", "-e", str(path), "-u", str(storage.root / "Saves/Dolphin")]
    elif core in STANDALONE:
        binary = app_binary(PACKAGES[core])
        flags = {"pcsx2": ["-fullscreen", "-batch", str(path)],
                 "rpcs3": ["--no-gui", str(path)],
                 "cemu-wiiu": ["-f", "-g", str(path)],
                 "switch": ["-f", str(path)]}
        args = [str(binary)] + flags[core]
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


LOGIN_LABEL = "com.mac-game-console.steam-big-picture"


def login_agent():
    return Path.home() / "Library/LaunchAgents" / (LOGIN_LABEL + ".plist")


def login_status():
    agent = login_agent()
    reject_symlinks(agent)
    if not agent.exists():
        return {"enabled": False, "delay": 30, "legacy": False}
    with agent.open("rb") as file:
        previous = plistlib.load(file)
    if previous.get("Label") != LOGIN_LABEL:
        raise SetupError("Preserving an unrecognized existing LaunchAgent.")
    arguments = previous.get("ProgramArguments")
    if arguments == ["/usr/bin/open", "steam://open/bigpicture"]:
        return {"enabled": True, "delay": 30, "legacy": True}
    if (not isinstance(arguments, list) or len(arguments) != 3
            or not isinstance(arguments[0], str) or not Path(arguments[0]).is_absolute()
            or Path(arguments[0]).name != "ConsoleAutoLaunch" or arguments[1] != "--delay"
            or not isinstance(arguments[2], str) or not arguments[2].isdigit()
            or not 5 <= int(arguments[2]) <= 300):
        raise SetupError("Unrecognized console auto-launch settings; preserving the existing LaunchAgent.")
    return {"enabled": True, "delay": int(arguments[2]), "legacy": False}


def login_helper():
    helper = PROJECT.parent / "MacOS/ConsoleAutoLaunch"
    reject_symlinks(helper)
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise SetupError("Open the built Couch Cube app to configure automatic console mode.")
    return helper


def login_launcher(confirm, enabled=True, delay=30, root=None):
    if not confirm:
        raise SetupError("Login changes require --confirm. No change made.")
    if type(delay) is not int or not 5 <= delay <= 300:
        raise SetupError("Choose a login delay between 5 and 300 seconds.")
    login_status()
    agent = login_agent()
    log_dir = Path.home() / "Library/Logs/Couch Cube"
    reject_symlinks(log_dir)
    content = None
    if enabled:
        helper = login_helper()
        if root is None:
            app_binary("Steam.app")  # Compatibility with existing Steam-only login settings.
        else:
            configured_storage(root)
            default_frontend()
        settings = {
            "Label": LOGIN_LABEL,
            "ProgramArguments": [str(helper), "--delay", str(delay)],
            "RunAtLoad": True,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": str(log_dir / "auto-launch.log"),
            "StandardErrorPath": str(log_dir / "auto-launch.log"),
        }
        if root is not None:
            settings["EnvironmentVariables"] = {"COUCH_CUBE_ROOT": str(Path(root).absolute())}
        content = plistlib.dumps(settings)
    domain = f"gui/{os.getuid()}"
    exists = subprocess.run(["/bin/launchctl", "print", domain + "/" + LOGIN_LABEL],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if exists.returncode == 0:
        run(["/bin/launchctl", "bootout", domain + "/" + LOGIN_LABEL])
    elif exists.returncode != 113:
        raise SetupError("Cannot inspect login agent: " + exists.stderr.decode(errors="replace"))
    if not enabled:
        if agent.exists():
            agent.unlink()
        print("Automatic console mode disabled on this Mac.")
        return
    agent.parent.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=agent.parent, delete=False) as file:
            temporary = Path(file.name)
            file.write(content)
        os.chmod(temporary, 0o644)
        os.replace(temporary, agent)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    print(f"Automatic console mode saved for the next login: {delay} seconds. "
          "Keep this app at its current location and its drive connected at login.")


def shell_env(storage):
    print("BIOS_ROOT=" + shlex.quote(str(storage.root / "BIOS/retroarch")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("drives")
    sub.add_parser("disks")
    sub.add_parser("update-check")
    sub.add_parser("login-status")
    sub.add_parser("system-catalog")
    apps = sub.add_parser("apps")
    apps.add_argument("--updates", action="store_true")
    manage = sub.add_parser("manage-app")
    manage.add_argument("--package", choices=list(PACKAGES), required=True)
    manage.add_argument("--action", choices=["install", "update", "remove"], required=True)
    manage.add_argument("--confirm", action="store_true")
    cleanup = sub.add_parser("cleanup-host")
    cleanup.add_argument("--confirm", action="store_true")
    systems = sub.add_parser("systems")
    systems.add_argument("--root", required=True)
    systems.add_argument("--enabled", nargs="*", choices=list(SYSTEMS))
    systems.add_argument("--confirm", action="store_true")
    install = sub.add_parser("install-apps")
    install.add_argument("--confirm", action="store_true")
    install.add_argument("--packages", nargs="+", choices=list(PACKAGES), required=True)
    assessment = sub.add_parser("assess")
    assessment.add_argument("--drive", required=True)
    plan = sub.add_parser("format-plan")
    plan.add_argument("--device", required=True)
    erase = sub.add_parser("erase")
    erase.add_argument("--device", required=True)
    erase.add_argument("--token", required=True)
    erase.add_argument("--typed", required=True)
    erase.add_argument("--confirm", action="store_true")
    erase.add_argument("--prepare-portable", action="store_true",
                       help="Verify latest GitHub portable release before erasing; copy the app to the new SSD root.")
    installer = sub.add_parser("copy-installer")
    installer.add_argument("--drive", required=True)
    installer.add_argument("--source", required=True)
    installer.add_argument("--confirm", action="store_true")
    copy_app = sub.add_parser("copy-app")
    copy_app.add_argument("--drive", required=True)
    copy_app.add_argument("--confirm", action="store_true")
    login = sub.add_parser("login")
    login.add_argument("--confirm", action="store_true")
    login.add_argument("--disable", action="store_true")
    login.add_argument("--delay", type=int, default=30)
    login.add_argument("--root")
    setup = sub.add_parser("setup")
    setup.add_argument("--drive", required=True)
    setup.add_argument("--confirm", action="store_true")
    setup.add_argument("--no-host-config", action="store_true",
                       help="Keep selection on the drive only; do not save it in this Mac's home folder.")
    setup.add_argument("--install", nargs="*", choices=list(PACKAGES), default=[])
    for action in ["env", "index", "steam", "retro", "console", "launch", "emulate", "register"]:
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
        elif args.command == "disks":
            print(json_text(physical_disks()))
        elif args.command == "update-check":
            print(json_text(release_tools().latest()))
        elif args.command == "login-status":
            print(json_text(login_status()))
        elif args.command == "system-catalog":
            print(json_text(systems_status()))
        elif args.command == "apps":
            print(json_text(app_status(args.updates)))
        elif args.command == "manage-app":
            manage_app(args.package, args.action, args.confirm)
        elif args.command == "cleanup-host":
            cleanup_host(args.confirm)
        elif args.command == "systems":
            storage = configured_storage(args.root)
            if args.enabled is not None:
                if not args.confirm:
                    raise SetupError("Changing console selection requires explicit confirmation.")
                select_systems(storage, args.enabled)
            else:
                print(json_text(systems_status(storage)))
        elif args.command == "install-apps":
            if not args.confirm:
                raise SetupError("No apps installed. Explicit --confirm consent is required.")
            install_packages(args.packages)
        elif args.command == "assess":
            print(json_text(assess(args.drive)))
        elif args.command == "format-plan":
            print(json_text(format_plan(args.device)))
        elif args.command == "erase":
            if args.prepare_portable:
                prepare_portable(args.device, args.token, args.typed, args.confirm)
            else:
                erase_external(args.device, args.token, args.typed, args.confirm)
        elif args.command == "copy-installer":
            if not args.confirm:
                raise SetupError("Installer copying requires explicit --confirm.")
            copy_installer(Storage(select_drive(args.drive)), args.source)
        elif args.command == "copy-app":
            if not args.confirm:
                raise SetupError("Copying this app requires explicit confirmation.")
            choice = select_drive(args.drive)
            with tempfile.TemporaryDirectory(prefix="couch-cube-app-") as directory:
                app = stage_current_app(Path(directory))
                copy_app_to_storage(choice, app)
        elif args.command == "login":
            login_launcher(args.confirm, not args.disable, args.delay, args.root)
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
            if not args.no_host_config:
                save_host_config(choice)
            print("Setup complete. Continue in Couch Cube for game players, Steam and controller guidance.", flush=True)
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
