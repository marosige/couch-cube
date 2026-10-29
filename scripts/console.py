#!/usr/bin/env python3
"""Safe storage setup and launch backend for the native macOS setup app."""

import argparse
import contextlib
import csv
import hashlib
import importlib.util
import io
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
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile

PROJECT = Path(__file__).resolve().parent.parent
BIOS_MAP = PROJECT / ("Config" if Path(__file__).parent.name == "Runtime" else "config") / "bios-map.csv"
APP_SUPPORT = Path.home() / "Library/Application Support/Couch Cube"
# Settings folder used before the app was renamed; migrate_app_support() moves its files over.
LEGACY_APP_SUPPORT = Path.home() / "Library/Application Support/Mac Game Console"
HOST_CONFIG = APP_SUPPORT / "setup.json"
FRONTEND_CONFIG = APP_SUPPORT / "frontend.json"
BUNDLE_ID = "me.marosi.couchcube"
LEGACY_BUNDLE_ID = "org.macgameconsole.setup"
SYSTEM_APPLICATIONS = Path("/Applications")
MARKER = ".mac-game-console.json"
FOLDER = "Couch Cube"
SSD_TEMPLATE = ".couch-cube-ssd-template"
SSD_FOLDERS = [
    "SteamLibrary", "ROMs", "BIOS/retroarch/dc", "Saves", "Native/Games",
    "Native/Assets", "Windows/Wrappers", "Windows/Installers", "Windows/Porting Kit",
]
PACKAGES = {
    "steam": "Steam.app",
    "gog-galaxy": "GOG Galaxy.app",
    "ea": "EA app.app",
    "epic-games": "Epic Games Launcher.app",
    "battle-net": "Battle.net.app",
    "curseforge": "CurseForge.app",
    "discord": "Discord.app",
    "es-de": "ES-DE.app",
    "retroarch-metal": "RetroArch.app",
    "dolphin": "Dolphin.app",
    "sikarugir": "Sikarugir Creator.app",
    "crossover": "CrossOver.app",
    "pcsx2": "PCSX2.app",
    "rpcs3": "RPCS3.app",
    "cemu-wiiu": "Cemu.app",
    "switch": "Ryujinx.app",
    "azahar": "Azahar.app",
    "xemu": "xemu.app",
}
# Casks that live in a third-party tap are installed by their full name, which makes Homebrew add the tap itself.
CASK_NAMES = {"sikarugir": "sikarugir-app/sikarugir/sikarugir"}
MANUAL_APPS = {
    # Notarized DMG (Developer ID: FX GAMES FZ LLC); no Homebrew cask, so the official release page is opened.
    "crossover": "https://www.codeweavers.com/crossover",
    "battle-net": "https://download.battle.net/",
    "rpcs3": "https://rpcs3.net/download",
    "cemu-wiiu": "https://cemu.info/",
    "switch": None,
    "azahar": "https://azahar-emu.org/",
}
# Folder names match ES-DE's macOS system definitions.
SYSTEMS = {
    "nes": ("Nintendo Entertainment System", "nes|zip|7z", "nestopia"),
    "snes": ("Super Nintendo", "sfc|smc|zip|7z", "snes9x"),
    "gb": ("Game Boy", "gb|zip|7z", "gambatte"),
    "gbc": ("Game Boy Color", "gbc|zip|7z", "gambatte"),
    "gba": ("Game Boy Advance", "gba|zip|7z", "mgba"),
    "n64": ("Nintendo 64", "n64|z64|v64|zip|7z", "mupen64plus_next"),
    "gc": ("GameCube", "iso|gcm|ciso|gcz|rvz|wia", "dolphin"),
    "wii": ("Wii", "iso|wbfs|ciso|gcz|rvz|wia|wad", "dolphin"),
    "psx": ("PlayStation", "cue|chd|m3u|pbp", "pcsx_rearmed"),
    "psp": ("PlayStation Portable", "iso|cso|pbp", "ppsspp"),
    "megadrive": ("Mega Drive / Genesis", "md|bin|zip|7z", "genesis_plus_gx"),
    "segacd": ("Sega CD", "cue|chd|m3u", "genesis_plus_gx"),
    "gamegear": ("Game Gear", "gg|zip|7z", "genesis_plus_gx"),
    "dreamcast": ("Dreamcast", "gdi|cdi|chd|m3u", "flycast"),
    "wiiu": ("Wii U", "wua|wud|wux|rpx", "cemu-wiiu"),
    "ps2": ("PlayStation 2", "iso|chd|cso|bin", "pcsx2"),
    "ps3": ("PlayStation 3", "self|bin", "rpcs3"),
    "switch": ("Nintendo Switch", "nsp|xci|nca|nro|nso", "switch"),
    "nds": ("Nintendo DS", "nds|zip|7z", "melonds"),
    "n3ds": ("Nintendo 3DS", "3ds|3dsx|cci|cxi", "azahar"),
    "mastersystem": ("Sega Master System", "sms|zip|7z", "genesis_plus_gx"),
    "sega32x": ("Sega 32X", "32x|zip|7z", "picodrive"),
    "saturn": ("Sega Saturn", "cue|chd|m3u|iso|ccd", "mednafen_saturn"),
    "pcengine": ("PC Engine / TurboGrafx-16", "pce|sgx|cue|chd|m3u|zip|7z", "mednafen_pce"),
    "neogeo": ("Neo Geo", "zip|7z", "fbneo"),
    "arcade": ("Arcade", "zip|7z", "mame2003_plus"),
    "xbox": ("Xbox", "iso|xiso", "xemu"),
}
STANDALONE = {"dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch", "azahar", "xemu"}
# Systems that need a separate emulator app (or own BIOS) stay off until the player turns them on.
DEFAULT_OFF = {"wiiu", "ps2", "ps3", "switch", "n3ds", "xbox"}

def selected_systems(state):
    selected = state.get("systems", [key for key in SYSTEMS if key not in DEFAULT_OFF])
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


def is_ssd_template(root):
    marker = root / SSD_TEMPLATE
    reject_symlinks(root)
    if not marker.is_file():
        return False
    reject_symlinks(marker)
    if marker.read_text() != "Couch Cube SSD template v1\n":
        return False
    allowed = {Path(".")}
    for folder in SSD_FOLDERS:
        path = Path(folder)
        allowed.update([path, *path.parents])
    for path in root.rglob("*"):
        reject_symlinks(path)
        if path == marker:
            continue
        if not path.is_dir() or path.relative_to(root) not in allowed:
            return False
    return True


def assess(identifier):
    choice = select_drive(identifier)
    storage = Storage(choice)
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
                path = storage.read_path(relative)
                if not isinstance(digest, str) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    issues.append(f"Missing or modified managed file: {relative}")
            for folder in ["ROMs", "BIOS/retroarch", "SteamLibrary", "Saves", "Native/Assets", "Windows/Wrappers"]:
                if not storage.read_path(folder).is_dir():
                    issues.append("Missing directory: " + folder)
            if not storage.read_path("Frontend/ES-DE/settings/es_settings.xml").is_file():
                issues.append("ES-DE settings are missing. Rerun setup.")
            else:
                text = storage.read_path("Frontend/ES-DE/settings/es_settings.xml").read_text()
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
                folder = storage.read_path("ROMs/" + system)
                has_games = folder.is_dir() and any(
                    file.is_file() and file.suffix.lower().lstrip(".") in extensions.split("|")
                    for file in folder.rglob("*")
                )
                if has_games and core not in STANDALONE and not (cores / (core + "_libretro.dylib")).is_file():
                    notes.append(f"Missing host core for ROMs/{system}: {core}. Install using RetroArch Core Downloader.")
        elif root.exists() and any(root.iterdir()) and not is_ssd_template(root):
            issues.append("Existing folder has no setup manifest; it will not be overwritten.")
        storage.check()
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
            "notes": notes, "missing": missing, "root": str(root),
            "preferred_frontend": frontend_preference()}


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


def migrate_app_support(legacy=None, current=None):
    """Move settings from the pre-rename folder; files already in the new folder win."""
    legacy = LEGACY_APP_SUPPORT if legacy is None else legacy
    current = APP_SUPPORT if current is None else current
    if legacy.is_symlink() or current.is_symlink() or not legacy.is_dir():
        return
    current.mkdir(parents=True, exist_ok=True)
    for item in legacy.iterdir():
        if not (current / item.name).exists() and not (current / item.name).is_symlink():
            os.rename(item, current / item.name)
    try:
        legacy.rmdir()
    except OSError:
        pass  # Something could not move because the new folder already had it; keep the rest.


def release_tools():
    spec = importlib.util.spec_from_file_location("console_releases", Path(__file__).with_name("releases.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def deal_tools():
    spec = importlib.util.spec_from_file_location("console_deals", Path(__file__).with_name("deals.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def windows_tools():
    spec = importlib.util.spec_from_file_location("console_windows_downloads", Path(__file__).with_name("windows_downloads.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def store_accounts_tools():
    spec = importlib.util.spec_from_file_location("console_store_accounts", Path(__file__).with_name("store_accounts.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def open_store_client(client_id):
    """Opens one game client so the user can sign in there, and returns once it quits."""
    try:
        command = store_accounts_tools().open_command(client_id)
    except ValueError as exc:
        raise SetupError(str(exc)) from exc
    subprocess.run(command, check=False, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def windows_downloads_status(root=None):
    """Read-only: which official Windows launcher installers are already in the library's Downloads folder."""
    tools = windows_tools()
    try:
        storage = configured_storage(root)
    except (SetupError, OSError, KeyError, ValueError):
        return {"library": None, "folder": None, "items": tools.status(None)}
    folder = storage.read_path(tools.FOLDER)
    return {"library": str(storage.root), "folder": str(folder), "items": tools.status(folder)}


def windows_download(package, confirm=False, root=None):
    """Downloads one installer into <library>/Downloads. It is never opened or run."""
    if not confirm:
        raise SetupError("Downloading an installer requires --confirm.")
    tools = windows_tools()
    storage = configured_storage(root)
    folder = storage.target(tools.FOLDER)
    try:
        return tools.download(package, folder, progress=lambda line: print(line, flush=True), check=storage.check)
    except tools.DownloadError as exc:
        raise SetupError(str(exc)) from None


def installed_steam_app_ids():
    """Steam app IDs with a fully installed local manifest; an unreadable library simply contributes nothing."""
    return frozenset(game["appid"] for library in steam_status()["libraries"] for game in library["games"]
                     if game.get("installed"))


def shop_tools():
    spec = importlib.util.spec_from_file_location("console_shop", Path(__file__).with_name("shop.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def wishlist_tools():
    spec = importlib.util.spec_from_file_location("console_wishlist", Path(__file__).with_name("wishlist.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def my_stores(shop=None):
    """Stores whose Mac app or Couch Cube Wine launcher is installed (local checks only)."""
    shop = shop or shop_tools()
    try:
        clients = store_accounts_tools().status()["clients"]
    except (OSError, ValueError, KeyError):
        clients = []
    return shop.installed_stores(clients)


def deals_report(source, page=0, sort=None, store=None, search=None, platform=None, kind=None, refresh=False,
                 mine=False):
    shop = shop_tools()
    tools = shop.deals
    # Always detected, so the Shop knows My Stores is available even while All Stores is shown.
    installed = my_stores(shop)
    stores = installed if mine else []
    ids, labels = shop.scope_filter(stores)
    scope = {"scope": "mine" if mine and stores else "all", "my_stores": installed}
    if source == "cheapshark":
        report = tools.store_deals(page, sort or "rating", store or (",".join(ids) if mine and ids else None),
                                   search, refresh, installed_steam_app_ids())
        return {**report, "deals": shop.with_insights(report["deals"], refresh), **scope}
    report = tools.giveaways(platform, kind, sort or "date", refresh)
    if mine and labels:
        report["giveaways"] = [item for item in report["giveaways"] if shop.in_scope(item, labels)]
    return {**report, **scope}


def shop_home(scope="mine", refresh=False):
    shop = shop_tools()
    report = shop.home(my_stores(shop), scope, refresh, installed_steam_app_ids())
    return {**report, "wishlist": wishlist_status()}


def shop_search(query, country="US", refresh=False):
    shop = shop_tools()
    try:
        return shop.search(query, country, refresh)
    except shop.deals.DealsError as exc:
        raise SetupError(str(exc)) from None


def shop_game(game_id, refresh=False):
    shop = shop_tools()
    try:
        return shop.game(game_id, refresh)
    except (shop.ShopError, shop.deals.DealsError) as exc:
        raise SetupError(str(exc)) from None


def rates_tools():
    spec = importlib.util.spec_from_file_location("console_rates", Path(__file__).with_name("rates.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def exchange_rates(refresh=False):
    tools = rates_tools()
    try:
        return tools.latest(refresh)
    except tools.deals.DealsError as exc:
        raise SetupError(str(exc)) from None


def wishlist_location():
    """(path, library) on the active Couch Cube drive, on this Mac when no drive was ever set up here,
    or (None, None) when the set-up drive isn't connected (the mirror is then shown read-only)."""
    tools = wishlist_tools()
    if not HOST_CONFIG.exists():
        library = tools.local_library()
        try:
            (library / tools.RELATIVE).parent.mkdir(parents=True, exist_ok=True)
        except OSError:
            return None, None
        return library / tools.RELATIVE, str(library)
    try:
        storage = configured_storage()
        return storage.target(tools.RELATIVE), str(storage.root)
    except (SetupError, OSError, KeyError, ValueError):
        return None, None


LOCAL_WISHLIST_NOTE = "Saved on this Mac. It moves to your Couch Cube drive when you set one up."


def local_wishlist_note(tools, reply, library):
    if library is not None and library == str(tools.local_library()) and not reply.get("note"):
        reply["note"] = LOCAL_WISHLIST_NOTE
    return reply


def wishlist_status():
    tools = wishlist_tools()
    path, library = wishlist_location()
    try:
        return local_wishlist_note(tools, tools.status(path, library), library)
    except tools.WishlistError as exc:
        return {**tools.report(tools.empty()), "library": library, "read_only": True, "offline": path is None,
                "merged": 0, "note": str(exc)}


def wishlist_change(action, item=None, key=None, price=None, currency="USD"):
    tools = wishlist_tools()
    path, library = wishlist_location()
    if path is None:
        raise SetupError("Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
    try:
        if action == "add":
            data = tools.add(path, item)
        elif action == "remove":
            data = tools.remove(path, key)
        else:
            data = tools.set_target(path, key, price, currency)
    except tools.WishlistError as exc:
        raise SetupError(str(exc)) from None
    tools.mirror(library, data)
    return local_wishlist_note(tools, tools.report(data, library=library, read_only=False, offline=False, merged=0, note=None), library)


def wishlist_check(country="US", refresh=False):
    """Look up current prices for every wishlist item (only when the Shop opens or on refresh)."""
    tools, shop = wishlist_tools(), shop_tools()
    current = wishlist_status()
    items = current["items"]
    resolved = {}
    for item in [item for item in items if not item.get("game_id") and not item.get("app_store_id")][:10]:
        try:
            game_id = shop.resolve_title(item["title"], refresh)
        except shop.deals.DealsError:
            continue
        if game_id:
            resolved[item["key"]] = game_id
    lookup = [{**item, "game_id": item.get("game_id") or resolved.get(item["key"])} for item in items]
    prices = shop.wishlist_prices(lookup, country, refresh)

    def change(data):
        for item in data["items"]:
            if item["key"] in resolved:
                item["game_id"] = resolved[item["key"]]
        tools.apply_prices(data, prices)
        for item in data["items"]:
            item["key"] = tools.item_key(item)
    path, library = wishlist_location()
    if path is not None and not current.get("read_only"):
        try:
            data = tools.update(path, change)
            tools.mirror(library, data)
            return {**tools.report(data, library=library, read_only=False, offline=False, merged=current.get("merged", 0),
                                   note=current.get("note")), "errors": prices["errors"]}
        except tools.WishlistError as exc:
            current = {**current, "note": str(exc), "read_only": True}
    data = {"schema": tools.SCHEMA, "items": [tools.normalize_item(item) for item in items]}
    change(data)
    return {**tools.report(data, **{key: current.get(key) for key in ("library", "read_only", "offline", "merged", "note")}),
            "errors": prices["errors"]}


STEAM_LINK = APP_SUPPORT / "steam-link.json"


def steam_library_tools():
    spec = importlib.util.spec_from_file_location("console_steam_library", Path(__file__).with_name("steam_library.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def steam_account():
    """The Mac Steam client's most recent account (from loginusers.vdf), or None."""
    tools = store_accounts_tools()
    accounts = tools.steam_accounts(Path.home() / "Library/Application Support/Steam")
    return next((item for item in accounts if item.get("steam_id")), None)


def steam_link_status(change=None):
    """Steam account, owned games and whether the Couch Cube wishlist takes in the Steam wishlist."""
    tools = steam_library_tools()
    account = steam_account()
    link = tools.read_link(STEAM_LINK)
    if change == "on":
        if not account:
            raise SetupError("Sign in to Steam on this Mac first, then try again.")
        if link.get("steam_id") != account["steam_id"]:
            link = {"steam_id": account["steam_id"], "seen": [], "synced": None}
        link["enabled"] = True
        tools.write_link(STEAM_LINK, link)
    elif change == "off" and link:
        # Turning it off keeps what was already imported, so games removed here never come back.
        link["enabled"] = False
        tools.write_link(STEAM_LINK, link)
    linked = bool(account and link.get("steam_id") == account["steam_id"] and link.get("enabled", True))
    owned = sorted(set(tools.owned_app_ids(Path.home() / "Library/Application Support/Steam", account["steam_id"]))
                   | installed_steam_app_ids()) if account else sorted(installed_steam_app_ids())
    return {"account": account and {"persona": account["persona"], "account": account["account"]},
            "linked": linked, "synced": link.get("synced") if linked else None, "owned": owned}


def steam_wishlist_sync(refresh=False):
    """Adds new games from the public Steam wishlist to the Couch Cube wishlist (one way; removals here stick)."""
    tools, wish = steam_library_tools(), wishlist_tools()
    status = steam_link_status()
    if not status["linked"]:
        return {**status, "imported": 0, "error": None}
    link = tools.read_link(STEAM_LINK)
    try:
        app_ids, error = tools.wishlist_app_ids(link["steam_id"], refresh)
    except tools.deals.DealsError as exc:
        return {**status, "imported": 0, "error": str(exc)}
    path, library = wishlist_location()
    if path is None:
        return {**status, "imported": 0, "error": "Connect your Couch Cube drive to update the wishlist."}
    try:
        known = {item.get("steam_app_id") for item in wish.read(path)["items"]}
    except wish.WishlistError as exc:
        return {**status, "imported": 0, "error": str(exc)}
    items, seen, lookup_error = tools.new_items(app_ids, set(link["seen"]), known,
                                                lambda app_id: tools.game_for_app(app_id, refresh))
    added = 0
    if items:
        def change(data):
            nonlocal added
            keys = {entry["key"] for entry in data["items"]}
            for raw in items:
                item = wish.normalize_item(raw)
                if item and item["key"] not in keys:
                    keys.add(item["key"])
                    data["items"].append(item)
                    added += 1
        try:
            wish.mirror(library, wish.update(path, change))
        except wish.WishlistError as exc:
            return {**status, "imported": 0, "error": str(exc)}
    tools.write_link(STEAM_LINK, {"steam_id": link["steam_id"], "seen": link["seen"] + seen, "synced": time.time(),
                                  "enabled": True})
    if not app_ids and not error:
        error = "No games found on your Steam wishlist. If it isn't empty, set Game details to Public in Steam's privacy settings."
    return {**steam_link_status(), "imported": added, "error": error or lookup_error}


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
        return self.read_path(relative)

    def read_path(self, relative):
        # Read-only batches validate volume identity before and after the batch.
        # Writes must continue to use target(), which revalidates every operation.
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
        "CFBundleIdentifier": BUNDLE_ID + ".launcher." + hashlib.sha256(name.encode()).hexdigest()[:16],
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
        "Config/bios-map.csv": (BIOS_MAP.read_bytes(), False),
        "Runtime/emulator_setup.py": (Path(__file__).with_name("emulator_setup.py").read_bytes(), False),
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
    quit_helper = PROJECT.parent / "MacOS/ControllerQuit"
    if quit_helper.is_file():
        files["Runtime/ControllerQuit"] = (quit_helper.read_bytes(), True)
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
    path = storage.read_path("Frontend/ES-DE/settings/es_settings.xml")
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
    for child in root:
        if child.tail is not None and not child.tail.strip():
            child.tail = None
    # ES-DE 3.x uses sibling XML elements, not a standard XML document root.
    return b'<?xml version="1.0"?>\n' + b"\n".join(ET.tostring(child, encoding="utf-8") for child in root) + b"\n"


def refresh_generated(storage, state):
    storage.check()
    files = generated_files(storage, state.get("games", []), selected_systems(state))
    settings = settings_content(storage)
    managed = state.get("managed", {})
    for relative, (content, _) in files.items():
        path = storage.read_path(relative)
        if path.exists():
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            wanted = hashlib.sha256(content).hexdigest()
            if actual != managed.get(relative) and actual != wanted:
                raise SetupError(f"Preserving modified/unmanaged file: {path}. Move it aside before rerunning.")
    disabled_markers = [key for key in managed if re.fullmatch(r"ROMs/[^/]+/noload\.txt", key) and key not in files]
    for relative in disabled_markers:
        path = storage.read_path(relative)
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != managed[relative]:
            raise SetupError("Preserving modified console visibility marker: " + str(path))
    storage.check()
    for relative in disabled_markers:
        storage.check()
        path = storage.target(relative)
        if path.exists():
            path.unlink()
        del managed[relative]
    for relative, (content, executable) in files.items():
        path = storage.read_path(relative)
        if not path.is_file() or path.read_bytes() != content or bool(path.stat().st_mode & 0o111) != executable:
            storage.write(relative, content, executable)
        managed[relative] = hashlib.sha256(content).hexdigest()
    state["managed"] = managed
    storage.write(MARKER, json_text(state))
    settings_path = storage.read_path("Frontend/ES-DE/settings/es_settings.xml")
    if not settings_path.is_file() or settings_path.read_bytes() != settings:
        storage.write("Frontend/ES-DE/settings/es_settings.xml", settings)
    storage.check()

LEGACY_NOLOAD = b"Disabled by Couch Cube. Re-enable in Consoles.\n"
JUNK_FILES = {".DS_Store", "noload.txt"}


def _real_files(folder):
    """Real files in a console folder; Finder's .DS_Store and the old noload.txt marker do not count."""
    found = []
    for directory, _, names in os.walk(folder, followlinks=False):
        found += [Path(directory) / name for name in names if name not in JUNK_FILES]
    return found


def _remove_empty_tree(folder):
    """Removes a folder that holds no real files, bottom-up with rmdir only: a user's file can never be deleted this way."""
    for directory, _, names in os.walk(folder, topdown=False, followlinks=False):
        for name in names:
            if name in JUNK_FILES:
                os.unlink(Path(directory) / name)
        os.rmdir(directory)


def sync_console_folders(storage, base, enabled):
    """One folder per shown console under ROMs/ or BIOS/. A console you hide keeps its files: the folder gets a leading
    dot (hidden in Finder, and ES-DE skips it) and returns when the console is shown again. A hidden console's folder
    with no files in it is removed. Needs no marker files."""
    enabled = set(enabled)
    for system in SYSTEMS:
        visible = storage.read_path(f"{base}/{system}")
        hidden = storage.read_path(f"{base}/.{system}")
        for folder in (visible, hidden):
            marker = folder / "noload.txt"
            if folder.is_dir() and marker.is_file() and not marker.is_symlink() and marker.read_bytes() == LEGACY_NOLOAD:
                storage.target(str(marker.relative_to(storage.root))).unlink()
        if system in enabled:
            if hidden.is_dir() and not visible.exists():
                os.rename(storage.target(f"{base}/.{system}"), storage.target(f"{base}/{system}"))
            elif not visible.exists():
                storage.mkdir(f"{base}/{system}")
            continue
        if visible.is_dir() and not visible.is_symlink():
            if not _real_files(visible):
                _remove_empty_tree(storage.target(f"{base}/{system}"))
            elif not hidden.exists():
                os.rename(storage.target(f"{base}/{system}"), storage.target(f"{base}/.{system}"))
        if hidden.is_dir() and not hidden.is_symlink() and not _real_files(hidden):
            _remove_empty_tree(storage.target(f"{base}/.{system}"))


def sync_system_bios(storage, system):
    """BIOS files dropped into a console's own folder reach RetroArch's system directory (never overwriting)."""
    folder = storage.read_path("BIOS/" + system)
    if not folder.is_dir():
        return
    with BIOS_MAP.open(newline="") as file:
        entries = [entry for entry in csv.DictReader(file) if entry["system"] == system]
    for entry in entries:
        target = storage.read_path("BIOS/retroarch/" + entry["filename"])
        if target.exists():
            continue
        for candidate in [folder / entry["filename"], folder / Path(entry["filename"]).name]:
            if candidate.is_file() and not candidate.is_symlink():
                storage.target("BIOS/retroarch/" + entry["filename"]).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(candidate, storage.target("BIOS/retroarch/" + entry["filename"]))
                break


def select_systems(storage, systems):
    if len(set(systems)) != len(systems) or any(system not in SYSTEMS for system in systems):
        raise SetupError("Unknown or duplicate console selection.")
    state = read_json(storage.target(MARKER))
    state["systems"] = systems
    sync_console_folders(storage, "ROMs", systems)
    sync_console_folders(storage, "BIOS", systems)
    refresh_generated(storage, state)
    print("Console selection saved. Existing ROMs and saves were kept.", flush=True)


def bios_status(storage, system):
    root = storage.read_path("BIOS/retroarch")
    with BIOS_MAP.open(newline="") as file:
        entries = [entry for entry in csv.DictReader(file) if entry["system"] == system]
    files = [{"filename": entry["filename"], "path": str(root / entry["filename"]),
              "present": storage.read_path("BIOS/retroarch/" + entry["filename"]).is_file()
              or storage.read_path("BIOS/" + system + "/" + entry["filename"]).is_file(),
              "note": entry["notes"]} for entry in entries]
    if files:
        present = sum(item["present"] for item in files)
        if system == "psx":
            state = "present" if present else "optional"
            message = "BIOS filename found" if present else "BIOS recommended · HLE fallback available"
        elif system == "dreamcast":
            state = "present" if present == len(files) else "optional"
            message = "BIOS filenames found" if present == len(files) else "Optional BIOS files missing · HLE available"
        elif system in {"nds", "pcengine"}:
            state = "present" if present == len(files) else "optional"
            message = "BIOS filenames found" if present == len(files) else "Optional BIOS files missing · most games run without"
        elif system == "saturn":
            state = "present" if present else "missing"
            message = "Saturn BIOS found" if present else "Saturn BIOS missing · one regional file is enough"
        else:
            state = "present" if present == len(files) else "partial" if present else "missing"
            message = f"{present}/{len(files)} regional BIOS files found" if present else "Regional BIOS files missing"
        return {"state": state, "summary": message, "files": files}
    if system in {"ps2", "ps3", "switch", "xbox"}:
        rows = emulator_setup_tools().bios_files(storage.root, system)
        if rows and all(row["present"] for row in rows):
            return {"state": "present", "summary": "Your files are in the library; installed on first launch", "files": rows}
        return {"state": "manual", "summary": "Put your PS2 BIOS in BIOS/ps2" if system == "ps2" else
                "Put PS3UPDAT.PUP in BIOS/ps3" if system == "ps3" else
                "Put prod.keys and the firmware .zip in BIOS/switch" if system == "switch" else
                "Put the Xbox BIOS files in BIOS/xbox", "files": []}
    return {"state": "not-needed", "summary": "No BIOS file required for the configured emulator",
            "files": []}


SAVE_SUFFIXES = {".srm", ".sav", ".mcr", ".mcd", ".dsv", ".eep", ".fla", ".rtc", ".sra", ".vmu", ".bin"}


def console_detail(storage, system):
    """One console's overview for its Details page: its games (with size), and the RetroArch saves and save
    states that belong to each game (matched by the game's file name, as RetroArch names them). Read-only."""
    if system not in SYSTEMS:
        raise SetupError("Unknown console.")
    name, extensions, core = SYSTEMS[system]
    folder = storage.root / "ROMs" / system
    games = []
    if folder.is_dir() and not folder.is_symlink():
        try:
            found = playable_roms(folder, extensions.split("|"))
        except OSError:
            found = []
        for game, launch in found:
            try:
                size = launch.stat().st_size
            except OSError:
                size = None
            games.append({"name": game, "file": launch.name, "path": str(launch), "bytes": size, "saves": 0, "states": 0})
    # Saves and states: RetroArch keeps them under Saves/RetroArch (states in States/), named after the game file.
    # Standalone emulators (Dolphin, PCSX2, RPCS3, Cemu, Ryujinx) keep their own.
    standalone = core in STANDALONE or core == "dolphin"
    if not standalone and games:
        stems = {Path(game["file"]).stem.lower(): game for game in games}
        base = storage.root / "Saves/RetroArch"
        if base.is_dir() and not base.is_symlink():
            try:
                for path in base.rglob("*"):
                    if path.is_symlink() or not path.is_file():
                        continue
                    lower = path.name.lower()
                    is_state = ".state" in lower and not lower.endswith(".png")
                    stem = lower.split(".state")[0] if is_state else Path(lower).stem
                    game = stems.get(stem)
                    if game is None:
                        continue
                    if is_state:
                        game["states"] += 1
                    elif path.suffix.lower() in SAVE_SUFFIXES:
                        game["saves"] += 1
            except OSError:
                pass
    return {"id": system, "name": name, "folder": str(folder), "games": games,
            "saves_where": None if not standalone else ("Dolphin" if core == "dolphin" else PACKAGES[core].removesuffix(".app")),
            "bios": bios_status(storage, system)}


def systems_status(storage=None):
    enabled = selected_systems(read_json(storage.target(MARKER))) if storage else []
    installed = {}
    for package in ({core if core in STANDALONE else "retroarch-metal" for _, _, core in SYSTEMS.values()} if storage else []):
        try:
            app_binary(PACKAGES[package])
            installed[package] = True
        except (SetupError, OSError, KeyError, ValueError):
            installed[package] = False
    result = [{"id": key, "name": name, "enabled": key in enabled,
             "emulator_installed": installed.get(core if core in STANDALONE else "retroarch-metal"),
             "bios": bios_status(storage, key) if storage and key in enabled else None,
             "package": core if core in STANDALONE else "retroarch-metal",
             "requirement": ("Own console keys/firmware; bring your own compatible macOS emulator. Not automatically downloaded."
                             if key == "switch" else
                             "Sony firmware installed in RPCS3; game compatibility varies." if key == "ps3" else
                             "Your own PS2 BIOS. Current Homebrew build may require Rosetta." if key == "ps2" else
                             "Your own games; configure controllers in Cemu." if key == "wiiu" else
                             "Dolphin; configure controllers in the emulator." if core == "dolphin" else
                             "Azahar (3DS). Install it from its website, then Couch Cube starts it." if core == "azahar" else
                             "xemu. Needs your own Xbox BIOS files and XISO game images." if core == "xemu" else
                             f"RetroArch core: {core}. Some systems need your own BIOS.")}
            for key, (name, _, core) in SYSTEMS.items()]
    if storage:
        storage.check()
    return result


def initialize(storage, systems=None):
    storage.check()
    marker = storage.target(MARKER)
    template = not marker.exists() and is_ssd_template(storage.root)
    if storage.root.exists() and not marker.exists() and any(storage.root.iterdir()) and not template:
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
        "Saves/RetroArch/States", "Saves/Dolphin", "Saves/Native",
        "Saves/Windows",
        "Native/Games", "Native/Assets", "Windows/Wrappers", "Windows/Installers", "Windows/Porting Kit",
        "Frontend", "Config", "Runtime", "Launchers",
    ]
    for folder in folders:
        storage.mkdir(folder)
    sync_console_folders(storage, "ROMs", selected_systems(state))
    sync_console_folders(storage, "BIOS", selected_systems(state))
    refresh_generated(storage, state)
    if template:
        storage.target(SSD_TEMPLATE).unlink()
    return state


def find_brew():
    for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", shutil.which("brew")]:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SetupError("Homebrew is missing. Install from https://brew.sh yourself, then rerun setup. No installer was downloaded.")


def brew_environment():
    """Homebrew asks for the Mac password through a dialog (SUDO_ASKPASS) instead of a terminal it doesn't have."""
    askpass = Path(__file__).with_name("askpass.sh")
    return {**os.environ, "SUDO_ASKPASS": str(askpass)} if askpass.is_file() else None


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
        run([brew, "install", "--cask", CASK_NAMES.get(package, package)], env=brew_environment())

def app_status(check_updates=False, package=None):
    """Installed/managed/update state for every known app, or only `package` (a targeted post-install re-check)."""
    if package is not None and package not in PACKAGES:
        raise SetupError("Unknown package selection.")
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
        if brew:
            info = json.loads(run([brew, "outdated", "--cask", "--greedy", "--json=v2"] + ([package] if package and package in managed else []),
                                  stdout=subprocess.PIPE, text=True).stdout)
            outdated = {item["name"]: item.get("current_version", "") for item in info.get("casks", [])}
    result = []
    for key, name in PACKAGES.items():
        if package is not None and key != package:
            continue
        paths = [base / name for base in [SYSTEM_APPLICATIONS, Path.home() / "Applications"]]
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
    run([find_brew(), "upgrade" if action == "update" else "uninstall", "--cask", package], env=brew_environment())
    print("App " + ("updated." if action == "update" else "removed. Games and preferences were kept."), flush=True)


def cleanup_host(confirm):
    if not confirm:
        raise SetupError("Removing Couch Cube settings requires explicit confirmation.")
    login_launcher(True, enabled=False)
    reject_symlinks(HOST_CONFIG)
    if HOST_CONFIG.is_file():
        HOST_CONFIG.unlink()
    reject_symlinks(FRONTEND_CONFIG)
    if FRONTEND_CONFIG.is_file():
        FRONTEND_CONFIG.unlink()
    log_path = Path.home() / "Library/Logs/Couch Cube/auto-launch.log"
    reject_symlinks(log_path)
    if log_path.is_file():
        log_path.unlink()
    print("Couch Cube login entry and local settings removed. Game folders, saves and other apps were kept.")


def cleanup_plan():
    items = []

    def add(path, name, category, package=None):
        path = Path(path)
        reject_symlinks(path)
        if not path.exists() or any(item["path"] == str(path) for item in items):
            return
        protected = {Path("/"), Path.home(), Path("/Applications"), Path.home() / "Library",
                     Path.home() / "Games", Path("/Volumes")}
        if path in protected or path.parent == path:
            raise SetupError(f"Unsafe cleanup target: {path}")
        info = path.stat()
        items.append({"id": hashlib.sha256(str(path).encode()).hexdigest(),
                      "name": name, "category": category, "path": str(path),
                      "package": package, "identity": f"{info.st_dev}:{info.st_ino}"})

    apps = app_status()
    for app in apps:
        for base in [SYSTEM_APPLICATIONS, Path.home() / "Applications"]:
            path = base / PACKAGES[app["id"]]
            add(path, app["name"], "App",
                app["id"] if app["managed"] and str(path) == app["path"] else None)
    home = Path.home()
    # Only named gaming directories are candidates; never offer a whole Library or volume.
    data_folders = [
        ("Library/Application Support/Steam", "Steam games, account data and settings"),
        ("Library/Application Support/RetroArch", "RetroArch cores, saves and settings"),
        ("Library/Application Support/Dolphin", "Dolphin saves and settings"),
        ("Library/Application Support/PCSX2", "PCSX2 BIOS, saves and settings"),
        ("Library/Application Support/rpcs3", "RPCS3 firmware, games and saves"),
        ("Library/Application Support/Cemu", "Cemu games, saves and settings"),
        ("Library/Application Support/Ryujinx", "Ryujinx firmware, games and saves"),
        ("Library/Application Support/CrossOver", "CrossOver bottles and Windows games"),
        ("Library/Application Support/Porting Kit", "Porting Kit wrappers and settings"),
        ("Library/Application Support/Sikarugir", "Sikarugir engines and Windows games"),
        ("Library/Application Support/discord", "Discord settings and cache"),
        ("Library/Application Support/Battle.net", "Battle.net data and settings"),
        ("Library/Application Support/Blizzard", "Blizzard data and settings"),
        ("Library/Application Support/CurseForge", "CurseForge profiles and addons"),
        ("Library/Application Support/Epic", "Epic data and settings"),
        ("Library/Application Support/GOG.com", "GOG data and settings"),
        ("Library/Application Support/EA app", "EA data and settings"),
        ("Library/Application Support/Origin", "Origin data and settings"),
        ("Library/Application Support/Blizzard Entertainment", "Blizzard settings"),
        ("Library/Application Support/OpenEmu", "OpenEmu games, BIOS and saves"),
        ("Library/Application Support/com.isaacmarovitz.Whisky", "Whisky bottles and Windows games"),
        ("Library/Containers/com.isaacmarovitz.Whisky", "Whisky sandbox and Windows games"),
        ("Documents/PCSX2", "PCSX2 BIOS, saves and settings"),
        ("Documents/Dolphin Emulator", "Dolphin saves and settings"),
        (".config/retroarch", "RetroArch configuration"),
        ("ES-DE", "ES-DE settings and downloaded artwork"),
        (".emulationstation", "Legacy EmulationStation settings"),
        ("Library/Application Support/Couch Cube", "Couch Cube settings"),
        ("Library/Application Support/Mac Game Console", "Older Couch Cube settings"),
        ("Library/Logs/Couch Cube", "Couch Cube logs"),
    ]
    for relative, name in data_folders:
        add(home / relative, name, "Games and data")
    for name in ["World of Warcraft", "Warcraft III", "StarCraft", "StarCraft II",
                 "Diablo III", "Hearthstone", "Heroes of the Storm"]:
        for base in [SYSTEM_APPLICATIONS, home / "Applications", home / "Games"]:
            add(base / name, name + " games and addons", "Games and data")
    bundle_ids = {
        BUNDLE_ID: "Couch Cube",
        LEGACY_BUNDLE_ID: "Older Couch Cube",
        "com.valvesoftware.steam": "Steam",
        "org.libretro.RetroArch": "RetroArch",
        "org.dolphin-emu.dolphin": "Dolphin",
        "net.pcsx2.pcsx2": "PCSX2",
        "net.rpcs3.rpcs3": "RPCS3",
        "info.cemu.Cemu": "Cemu",
        "org.ryujinx.Ryujinx": "Ryujinx",
        "com.codeweavers.CrossOver": "CrossOver",
        "com.blizzard.BattleNet": "Battle.net",
    }
    for app in apps:
        if not app["installed"]:
            continue
        with (Path(app["path"]) / "Contents/Info.plist").open("rb") as file:
            bundle_id = plistlib.load(file).get("CFBundleIdentifier")
        if not isinstance(bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
            raise SetupError(f"Invalid bundle identifier for {app['name']}.")
        bundle_ids[bundle_id] = app["name"]
    for bundle_id, name in bundle_ids.items():
        for folder in ["Caches", "Logs", "HTTPStorages", "WebKit", "Saved Application State"]:
            suffix = ".savedState" if folder == "Saved Application State" else ""
            add(home / "Library" / folder / (bundle_id + suffix), name + " " + folder, "Supporting files")
        add(home / "Library/Preferences" / (bundle_id + ".plist"), name + " preferences", "Supporting files")
    for path in steam_libraries():
        if path != (home / "Library/Application Support/Steam").resolve():
            add(path / "steamapps", "Steam library games and downloads", "Games and data")
    for choice in drives():
        root = Path(choice["root"])
        if (root / MARKER).is_file():
            storage = configured_storage(str(root))
            add(storage.root, "Couch Cube library - ROMs, BIOS, games and saves", "Games and data")
    agent = home / "Library/LaunchAgents" / (LOGIN_LABEL + ".plist")
    add(agent, "Couch Cube automatic console mode", "Supporting files")
    items = [item for item in items if not any(
        Path(item["path"]).is_relative_to(Path(parent["path"]))
        for parent in items if parent["path"] != item["path"])]
    token = hashlib.sha256(json_text(items).encode()).hexdigest()
    return {"items": items, "token": token}


def prepare_cleanup(identifiers, token, confirm):
    if not confirm or not identifiers or len(set(identifiers)) != len(identifiers):
        raise SetupError("Select cleanup items and explicitly confirm removal.")
    plan = cleanup_plan()
    if token != plan["token"]:
        raise SetupError("Cleanup items changed. Review the list again before removing anything.")
    known = {item["id"]: item for item in plan["items"]}
    if not set(identifiers).issubset(known):
        raise SetupError("Unknown cleanup item. Review the list again.")
    selected = [known[key] for key in identifiers]
    if any(item["path"].endswith("/" + LOGIN_LABEL + ".plist") or
           item["path"] == str(HOST_CONFIG.parent) for item in selected):
        # Keep stdout reserved for the JSON response.
        import contextlib
        with contextlib.redirect_stdout(sys.stderr):
            login_launcher(True, enabled=False)
    remaining = []
    for item in selected:
        if item["package"]:
            print("Uninstalling " + item["name"], file=sys.stderr, flush=True)
            run([find_brew(), "uninstall", "--cask", item["package"]], stdout=sys.stderr)
        else:
            remaining.append(item["path"])
    # Selecting a library and a subdirectory should recycle the library only.
    paths = [path for path in remaining if not any(
        Path(path).is_relative_to(Path(parent)) for parent in remaining if parent != path)]
    for path in paths:
        reject_symlinks(Path(path))
        if Path(path).exists():
            info = Path(path).stat()
            item = next(item for item in selected if item["path"] == path)
            if f"{info.st_dev}:{info.st_ino}" != item["identity"]:
                raise SetupError(f"Cleanup target changed: {path}. Scan again.")
    paths = [path for path in paths if Path(path).exists()]
    return {"paths": paths}


def save_host_config(choice):
    reject_symlinks(HOST_CONFIG)
    HOST_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=HOST_CONFIG.parent, mode="w", delete=False) as file:
        file.write(json_text({"id": choice["id"], "uuid": choice["uuid"]}))
        temporary = file.name
    os.replace(temporary, HOST_CONFIG)


def storage_status():
    reject_symlinks(HOST_CONFIG)
    active = read_json(HOST_CONFIG) if HOST_CONFIG.is_file() else None
    if active is not None and (not isinstance(active, dict)
                               or not all(isinstance(active.get(key), str) for key in ["id", "uuid"])):
        raise SetupError("Saved storage selection is invalid. Open Activity to review the saved setup.json file.")
    locations = []
    for choice in drives():
        root = Path(choice["root"])
        reject_symlinks(root)
        marker = root / MARKER
        reject_symlinks(marker)
        configured = False
        issue = None
        if marker.exists():
            try:
                state = read_json(marker)
                configured = (state.get("version") == 1 and state.get("uuid") == choice["uuid"]
                              and state.get("id") == choice["id"] and state.get("mode") == choice["mode"])
                if not configured:
                    issue = "Library belongs to another volume or needs setup."
            except (OSError, ValueError, AttributeError) as exc:
                issue = f"Couldn't read library: {exc}"
        environment, environment_issue = library_environment(choice)
        try:
            total = shutil.disk_usage(choice["mount"]).total
        except OSError:
            total = None
        locations.append({"drive": choice, "configured": configured, "issue": issue or environment_issue,
                          "environment": environment, "total": total})
    transfer = None
    for location in locations:
        if active and location["configured"] and location["drive"]["id"] == active.get("id"):
            storage = Storage(location["drive"])
            receipt_path = storage.read_path("Config/storage-transfer.json")
            if receipt_path.is_file():
                receipt = read_json(receipt_path)
                if any(item["drive"]["root"] == receipt["source"]["root"] and item["configured"]
                       and item["drive"]["uuid"] == receipt["source"]["uuid"] for item in locations):
                    transfer = {"source": receipt["source"]["root"], "destination": receipt["destination"]["root"],
                                "token": hashlib.sha256(json_text(receipt).encode()).hexdigest()}
    return {"locations": locations, "active": active, "transfer": transfer}


def transfer_snapshot(root):
    """Hash the library without following links or including Steam's managed library."""
    reject_symlinks(root)
    result = {}
    for directory, folders, files in os.walk(root, followlinks=False):
        parent = Path(directory)
        if parent == root:
            folders[:] = [name for name in folders if name != "SteamLibrary"]
            files = [name for name in files if name != "SteamLibrary"]
        for name in sorted(folders + files):
            path = parent / name
            relative = str(path.relative_to(root))
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                link = os.readlink(path)
                if Path(link).is_absolute() or not (path.parent / link).resolve().is_relative_to(root.resolve()):
                    raise SetupError(f"Library link points outside its folder: {path}. Move it manually.")
                result[relative] = {"link": link}
            elif stat.S_ISDIR(info.st_mode):
                result[relative] = {"directory": True}
            elif stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256()
                with path.open("rb") as file:
                    for chunk in iter(lambda: file.read(1024 * 1024), b""):
                        digest.update(chunk)
                result[relative] = {"size": info.st_size, "sha256": digest.hexdigest(),
                                    "mode": stat.S_IMODE(info.st_mode)}
            else:
                raise SetupError(f"Unsupported special file in library: {path}")
    return result


def transfer_plan(source_id, destination_id, include_snapshot=False):
    source = Storage(select_drive(source_id))
    destination = Storage(select_drive(destination_id))
    source.check()
    destination.check()
    if source.choice["uuid"] == destination.choice["uuid"] or source.root == destination.root:
        raise SetupError("Choose a different storage volume for the transfer.")
    state = read_json(source.target(MARKER))
    if (state.get("version") != 1 or state.get("uuid") != source.choice["uuid"]
            or state.get("id") != source_id or state.get("mode") != source.choice["mode"]):
        raise SetupError("Source library identity does not match. Run setup on it first.")
    selected_systems(state)
    if destination.choice["filesystem"] not in ["apfs", "hfs"]:
        raise SetupError("The destination must use APFS or Mac OS Extended. No formatting performed.")
    if destination.root.exists():
        raise SetupError("The destination Couch Cube folder already exists. Use it as a separate library, "
                         "or move it aside in Finder before transferring. Libraries are never merged or overwritten.")
    snapshot = transfer_snapshot(source.root)
    size = sum(item.get("size", 0) for item in snapshot.values())
    if destination.choice["free"] < size + 1024 ** 3:
        raise SetupError("Not enough free space at the destination (1 GiB reserve required).")
    source.check()
    destination.check()
    identity = {"source": source.choice, "destination": destination.choice, "files": snapshot}
    # Free space changes between planning and copying are expected.
    for key in ["source", "destination"]:
        identity[key] = {k: v for k, v in identity[key].items() if k != "free"}
    token = hashlib.sha256(json_text(identity).encode()).hexdigest()
    plan = {"source": source.choice, "destination": destination.choice, "bytes": size, "token": token}
    if include_snapshot:
        plan["_snapshot"] = snapshot
    return plan


def transfer_library(source_id, destination_id, token, confirm):
    if not confirm:
        raise SetupError("Library transfer requires explicit confirmation.")
    plan = transfer_plan(source_id, destination_id, include_snapshot=True)
    if token != plan["token"]:
        raise SetupError("The library or drive changed. Review the transfer again; no files copied.")
    source, destination = Storage(plan["source"]), Storage(plan["destination"])
    snapshot = plan["_snapshot"]
    stage = destination.root.parent / (".couch-cube-transfer-" + uuid.uuid4().hex)
    destination.check()
    stage.mkdir(mode=0o700)
    try:
        for path in source.root.iterdir():
            if path.name == "SteamLibrary":
                continue
            source.check()
            destination.check()
            print(f"Copying {path.name}...", file=sys.stderr, flush=True)
            run(["/usr/bin/ditto", "--rsrc", "--extattr", str(path), str(stage / path.name)])
        if transfer_snapshot(stage) != snapshot or transfer_snapshot(source.root) != snapshot:
            raise SetupError("Content changed during copying or verification failed. Source remains unchanged.")
        source.check()
        destination.check()
        if destination.root.exists():
            raise SetupError("Destination appeared during copying; it will not be overwritten.")
        # An exclusive directory reservation prevents replacing any existing library.
        destination.root.mkdir()
        for path in stage.iterdir():
            destination.check()
            path.rename(destination.root / path.name)
        stage.rmdir()
        state = read_json(destination.target(MARKER))
        state.update({"id": destination_id, "uuid": destination.choice["uuid"], "mode": destination.choice["mode"]})
        destination.write(MARKER, json_text(state))
        initialize(destination)
        source.check()
        destination.check()
        receipt = {"source": source.choice, "destination": destination.choice,
                   "source_snapshot": snapshot}
        receipt_token = hashlib.sha256(json_text(receipt).encode()).hexdigest()
        destination.write("Config/storage-transfer.json", json_text(receipt))
        save_host_config(destination.choice)
        return {"source": str(source.root), "destination": str(destination.root), "token": receipt_token}
    except (OSError, SetupError, subprocess.CalledProcessError) as exc:
        raise SetupError(f"Transfer did not finish: {exc}. Source files were kept. "
                         f"Inspect {stage} and {destination.root} before retrying.") from exc


def retire_transferred_library(destination_id, token):
    destination = Storage(select_drive(destination_id))
    destination.check()
    receipt = read_json(destination.target("Config/storage-transfer.json"))
    if hashlib.sha256(json_text(receipt).encode()).hexdigest() != token:
        raise SetupError("Transfer receipt changed. Old library will not be removed.")
    source = Storage(receipt["source"])
    source.check()
    active = configured_storage()
    if active.root != destination.root or source.root == destination.root:
        raise SetupError("Activate the verified destination before retiring the source.")
    if receipt["destination"]["uuid"] != destination.choice["uuid"]:
        raise SetupError("Destination drive identity changed.")
    if transfer_snapshot(source.root) != receipt["source_snapshot"]:
        raise SetupError("Source changed since transfer; preserving it.")
    copied = transfer_snapshot(destination.root)
    state = read_json(destination.target(MARKER))
    for relative, digest in state["managed"].items():
        path = destination.read_path(relative)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SetupError(f"Destination generated files need repair: {relative}. Preserving old library.")
    regenerated = set(state["managed"]) | {MARKER, "Frontend/ES-DE/settings/es_settings.xml",
                                          "Config/storage-transfer.json"}
    for relative, expected in receipt["source_snapshot"].items():
        if relative not in regenerated and copied.get(relative) != expected:
            raise SetupError(f"Destination content changed or is missing: {relative}. Preserving old library.")
    steam = source.read_path("SteamLibrary")
    if steam.exists() and any(steam.iterdir()):
        raise SetupError("Old library still contains Steam files. Move these using Steam before retiring this folder.")
    agent = login_agent()
    reject_symlinks(agent)
    if agent.exists():
        settings = plistlib.loads(agent.read_bytes())
        if settings.get("EnvironmentVariables", {}).get("COUCH_CUBE_ROOT") == str(source.root):
            raise SetupError("Automatic console mode still uses this library. Save it again in Console Mode first.")
    destination.check()
    source.check()
    return {"path": str(source.root)}


def library_environment(choice):
    """Classify a drive's Couch Cube folder without writing; unknown content is never called absent."""
    root = Path(choice["root"])
    try:
        reject_symlinks(root)
        marker = root / MARKER
        reject_symlinks(marker)
        if marker.exists():
            state = read_json(marker)
            if (isinstance(state, dict) and state.get("version") == 1 and state.get("uuid") == choice["uuid"]
                    and state.get("id") == choice["id"] and state.get("mode") == choice["mode"]):
                return "ready", None
            return "invalid", "Library belongs to another volume or needs setup."
        if not root.exists():
            return "absent", None
        if not root.is_dir():
            return "invalid", "A file is in the way of the Couch Cube folder. It will not be overwritten."
        if not any(root.iterdir()) or is_ssd_template(root):
            return "absent", None
        return "occupied", "A Couch Cube folder without setup information exists here. It will not be overwritten."
    except (SetupError, OSError, ValueError, AttributeError) as exc:
        return "invalid", f"Couldn't read library: {exc}"


def allocated_bytes(root):
    """Disk space used below root without following links."""
    total = 0
    if not root.is_dir() or root.is_symlink():
        return 0
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in folders + files:
            try:
                total += os.lstat(Path(directory) / name).st_blocks * 512
            except OSError:
                continue
    return total + os.lstat(root).st_blocks * 512


def populated_systems(root):
    systems = []
    for system, (name, extensions, _) in SYSTEMS.items():
        folder = root / "ROMs" / system
        if folder.is_symlink() or not folder.is_dir():
            continue
        # Games, not files: a game folder with its updates, DLC or extra discs counts once.
        try:
            count = len(playable_roms(folder, extensions.split("|")))
        except OSError:
            continue
        if count:
            systems.append({"id": system, "name": name, "games": count, "path": str(folder)})
    return systems


def same_volume(path, mount):
    try:
        return path.exists() and os.stat(path).st_dev == os.stat(mount).st_dev
    except OSError:
        return False


def drive_detail(identifier):
    """Read one drive's library, capacity and games without changing the active library."""
    choice = select_drive(identifier)
    root = Path(choice["root"])
    environment, issue = library_environment(choice)
    usage = shutil.disk_usage(choice["mount"])
    errors = []
    couch = allocated_bytes(root) if environment != "absent" or root.is_dir() else 0
    steam = []
    try:
        for path in steam_libraries():
            if same_volume(path, choice["mount"]):
                games = steam_library_games(path, errors)
                if games:
                    steam.append({"path": str(path), "games": games})
    except (SetupError, OSError, UnicodeError) as exc:
        errors.append(str(exc))
    retro = populated_systems(root) if environment == "ready" else []
    active = None
    if HOST_CONFIG.is_file() and not HOST_CONFIG.is_symlink():
        try:
            active = read_json(HOST_CONFIG)
        except (OSError, ValueError):
            active = None
    select_drive(identifier)
    return {"drive": choice, "environment": environment, "issue": issue,
            "active": isinstance(active, dict) and active.get("id") == choice["id"] and active.get("uuid") == choice["uuid"],
            "capacity": {"total": usage.total, "used": usage.used, "free": usage.free, "couch": couch},
            "steam": steam, "retro": retro, "errors": errors}


DISC_SUFFIX = re.compile(r"\s*[\(\[](?:disc|disk|cd)\s*\d+[^\)\]]*[\)\]]", re.I)
LAUNCHER_NAMES = {"steam": "Steam", "gog": "GOG", "blizzard": "Battle.net", "ea": "EA app",
                  "epic": "Epic Games", "bottle": "Windows bottles"}


class StorageMeter:
    """Allocated-size measurement that stays on one volume, never follows links and counts each inode once."""

    def __init__(self, device):
        self.device = device
        self.seen = set()
        self.shared = 0

    def _entry(self, path):
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or info.st_dev != self.device:
            return 0, False
        key = (info.st_dev, info.st_ino)
        size = info.st_blocks * 512
        if key in self.seen:
            self.shared += size
            return 0, stat.S_ISDIR(info.st_mode)
        self.seen.add(key)
        return size, stat.S_ISDIR(info.st_mode)

    def measure(self, paths):
        """Return (bytes or None, unreadable count); None means nothing could be read at all."""
        total, unreadable, readable = 0, 0, False
        for path in paths:
            try:
                size, is_dir = self._entry(path)
            except OSError:
                unreadable += 1
                continue
            readable = True
            total += size
            if not is_dir:
                continue
            failures = []
            for directory, folders, files in os.walk(path, followlinks=False, onerror=failures.append):
                for name in folders + files:
                    try:
                        size, _ = self._entry(os.path.join(directory, name))
                        total += size
                    except OSError:
                        unreadable += 1
                folders[:] = [name for name in folders
                              if not os.path.islink(os.path.join(directory, name))]
            unreadable += len(failures)
        return (total if readable else None), unreadable


def rom_references(descriptor, folder):
    """Files a .m3u/.cue/.gdi names, limited to existing regular files inside its system folder."""
    try:
        text = descriptor.read_text(errors="replace")
    except OSError:
        return []
    suffix = descriptor.suffix.lower()
    names = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if suffix == ".cue":
            match = re.match(r'FILE\s+"([^"]+)"|FILE\s+(\S+)', line, re.I)
            if match:
                names.append(match.group(1) or match.group(2))
        elif suffix == ".gdi":
            quoted = re.findall(r'"([^"]+)"', line)
            parts = line.split()
            if quoted:
                names.append(quoted[0])
            elif len(parts) >= 5:
                names.append(parts[4])
        else:
            names.append(line)
    base = folder.resolve()
    found = []
    for name in names:
        if os.path.isabs(name):
            continue
        target = descriptor.parent / name
        try:
            resolved = target.resolve()
        except OSError:
            continue
        if (target.is_symlink() or not target.is_file() or resolved == base
                or base not in resolved.parents):
            continue
        found.append(target)
    return found


def rom_games(folder, allowed):
    """Group one system folder into games: folders, descriptor sets, multi-disc names and leftovers."""
    files, folders = [], []
    for entry in sorted(folder.iterdir()):
        if entry.name.startswith(".") or entry.is_symlink():
            continue
        (folders if entry.is_dir() else files if entry.is_file() else []).append(entry)
    claimed = {}
    for file in files:
        # A descriptor only groups files when the system plays it; otherwise its files stay games of their own.
        if file.suffix.lower() in {".m3u", ".cue", ".gdi"} and file.suffix.lower().lstrip(".") in allowed:
            claimed[file] = rom_references(file, folder)
    referenced = {target.resolve() for targets in claimed.values() for target in targets}
    groups = {}
    used = set()
    for file in files:
        if file.resolve() in referenced or file.suffix.lower().lstrip(".") not in allowed:
            continue
        stack, members = [file], []
        while stack:
            current = stack.pop()
            if current.resolve() in used:
                continue
            used.add(current.resolve())
            members.append(current)
            stack.extend(claimed.get(current, []))
        name = DISC_SUFFIX.sub("", file.stem).strip() or file.stem
        groups.setdefault(name, []).extend(members)
    games = [(name, members) for name, members in groups.items()]
    games += [(entry.name, [entry]) for entry in folders]
    leftovers = [file for file in files if file.resolve() not in used and file.resolve() not in referenced]
    for targets in claimed.values():
        leftovers += [target for target in targets if target.resolve() not in used]
    return games, list(dict.fromkeys(leftovers))


def rom_launch_file(members, allowed):
    """The file to start for one game from rom_games: the file itself, or for a game folder (e.g. a Switch game
    with its updates and DLC, or a GameCube folder) the largest playable file inside it. None when there is none."""
    first = members[0]
    if first.is_file():
        return first
    if first.is_symlink() or not first.is_dir():
        return None
    best, best_size = None, -1
    for path in sorted(first.rglob("*")):
        if path.name.startswith(".") or path.is_symlink() or not path.is_file() or path.suffix.lower().lstrip(".") not in allowed:
            continue
        size = path.stat().st_size
        if size > best_size:
            best, best_size = path, size
    return best


def playable_roms(folder, allowed):
    """(name, file to start) for every game in one system folder, loose files and game folders alike."""
    games, _ = rom_games(folder, allowed)
    found = []
    for name, members in games:
        launch = rom_launch_file(members, allowed) if members else None
        if launch is not None:
            found.append((name, launch))
    return found


def launcher_roots(choice):
    mount = Path(choice["mount"])
    if choice["mode"] == "local":
        home = Path.home()
        return [SYSTEM_APPLICATIONS, home / "Applications", home / "Games"]
    return [mount / "Applications", mount / "Games", mount]


def marker_games(choice, device, errors):
    """Battle.net, EA and GOG installs identified by the files their installers leave in each game folder."""
    found = {}
    for base in launcher_roots(choice):
        try:
            if base.is_symlink() or not base.is_dir() or os.stat(base).st_dev != device:
                continue
            entries = sorted(base.iterdir())
        except OSError as exc:
            errors.append(f"{base}: {exc}")
            continue
        for entry in entries:
            try:
                if entry.is_symlink() or not entry.is_dir() or os.lstat(entry).st_dev != device:
                    continue
                source = None
                if (entry / ".build.info").is_file():
                    source = "blizzard"
                elif (entry / "__Installer" / "installerdata.xml").is_file():
                    source = "ea"
                elif any(entry.glob("goggame-*.info")) or any((entry / "Contents" / "Resources").glob("goggame-*.info")):
                    source = "gog"
                if source:
                    name = entry.name[:-4] if entry.suffix == ".app" else entry.name
                    found.setdefault(str(entry.resolve()), (source, name, entry))
            except OSError as exc:
                errors.append(f"{entry}: {exc}")
    return list(found.values())


def epic_games(device, errors):
    manifests = Path.home() / "Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests"
    games = []
    if manifests.is_symlink() or not manifests.is_dir():
        return games, False
    for manifest in sorted(manifests.glob("*.item")):
        try:
            data = read_json(manifest)
            location, name = data.get("InstallLocation"), data.get("DisplayName")
            if not isinstance(location, str) or not isinstance(name, str) or not os.path.isabs(location):
                raise SetupError("Missing install location or name.")
            path = Path(location)
            if path.is_symlink() or not path.exists() or os.lstat(path).st_dev != device:
                continue
            games.append((name, path))
        except (SetupError, OSError, ValueError, AttributeError) as exc:
            errors.append(f"{manifest}: {exc}")
    return games, True


def bottle_folders(choice, device):
    if choice["mode"] != "local":
        return []
    home = Path.home()
    bottles = []
    for base, app in [(home / "Library/Application Support/CrossOver/Bottles", "CrossOver"),
                      (home / "Library/Containers/com.isaacmarovitz.Whisky/Bottles", "Whisky")]:
        try:
            if base.is_symlink() or not base.is_dir():
                continue
            for entry in sorted(base.iterdir()):
                if not entry.is_symlink() and entry.is_dir() and os.lstat(entry).st_dev == device:
                    bottles.append((f"{entry.name} ({app} bottle)", entry))
        except OSError:
            continue
    return bottles


def drive_games(identifier):
    """Read-only per-game storage on one drive. Specific games are measured before shared containers,
    so a game inside a bottle is counted once, and an inode is never counted twice."""
    choice = select_drive(identifier)
    mount = Path(choice["mount"])
    device = os.stat(mount).st_dev
    meter = StorageMeter(device)
    items, errors, coverage = [], [], []

    def add(source, name, paths, system=None, system_name=None, kind="pc", estimated=None, item_id=None):
        size, unreadable = meter.measure(paths)
        if estimated is not None and (size is None or size == 0):
            size, measured = estimated, False
        else:
            measured = True
        items.append({"id": item_id or f"{source}:{paths[0]}", "kind": kind, "source": source,
                      "source_name": "ROMs" if kind == "rom" else LAUNCHER_NAMES[source],
                      "name": name, "system": system, "system_name": system_name,
                      "bytes": size, "measured": measured, "unreadable": unreadable, "path": str(paths[0])})

    def cover(source, name, status, count=0, note=None):
        coverage.append({"source": source, "name": name, "status": status, "games": count, "note": note})

    environment, _ = library_environment(choice)
    root = Path(choice["root"])
    if environment == "ready":
        before = len(items)
        for system, (system_name, extensions, _) in SYSTEMS.items():
            folder = root / "ROMs" / system
            if folder.is_symlink() or not folder.is_dir():
                continue
            try:
                games, leftovers = rom_games(folder, extensions.split("|"))
            except OSError as exc:
                errors.append(f"{folder}: {exc}")
                continue
            for name, members in games:
                add("rom", name, members, system, system_name, "rom", item_id=f"rom:{system}:{name}")
            if leftovers:
                add("rom", f"Other {system_name} files", leftovers, system, system_name, "rom",
                    item_id=f"rom:{system}:*other")
        cover("rom", "ROMs", "scanned" if len(items) > before else "none", len(items) - before)
    else:
        cover("rom", "ROMs", "none", note="No Couch Cube library on this drive.")

    before = len(items)
    try:
        for library in steam_libraries():
            if not same_volume(library, mount):
                continue
            for manifest in sorted((library / "steamapps").glob("appmanifest_*.acf")):
                try:
                    data = parse_vdf(manifest.read_text()).get("appstate")
                    appid, name, folder = (data or {}).get("appid"), (data or {}).get("name"), (data or {}).get("installdir")
                    if (not isinstance(appid, str) or not appid.isdigit() or not isinstance(name, str)
                            or not isinstance(folder, str) or not folder or "/" in folder or folder in {".", ".."}):
                        raise SetupError("Invalid Steam game manifest.")
                    size = (data or {}).get("sizeondisk")
                    reported = int(size) if isinstance(size, str) and size.isdigit() else None
                    paths = [path for path in [library / "steamapps/common" / folder,
                                               library / "steamapps/workshop/content" / appid]
                             if path.exists() and not path.is_symlink()]
                    if paths:
                        add("steam", name, paths, item_id=f"steam:{appid}")
                    else:
                        items.append({"id": f"steam:{appid}", "kind": "pc", "source": "steam", "source_name": "Steam",
                                      "name": name, "system": None, "system_name": None, "bytes": reported,
                                      "measured": False, "unreadable": 0, "path": str(library)})
                except (SetupError, OSError, UnicodeError) as exc:
                    errors.append(f"{manifest}: {exc}")
        cover("steam", "Steam", "scanned" if len(items) > before else "none", len(items) - before)
    except (SetupError, OSError, UnicodeError) as exc:
        errors.append(str(exc))
        cover("steam", "Steam", "error", note=str(exc))

    found = marker_games(choice, device, errors)
    for source in ["blizzard", "ea", "gog"]:
        matches = [(name, path) for kind, name, path in found if kind == source]
        for name, path in matches:
            add(source, name, [path])
        cover(source, LAUNCHER_NAMES[source], "scanned" if matches else "none", len(matches),
              "Found by installer files in Applications and Games folders.")

    epic, readable = epic_games(device, errors)
    for name, path in epic:
        add("epic", name, [path])
    cover("epic", "Epic Games", "scanned" if epic else "none", len(epic),
          None if readable else "Epic Games Launcher has no install list on this Mac.")

    bottles = bottle_folders(choice, device)
    for name, path in bottles:
        add("bottle", name, [path])
    cover("bottle", "Windows bottles", "scanned" if bottles else "none", len(bottles),
          "Whole CrossOver and Whisky bottles; games inside them aren't split by launcher.")
    cover("other", "Other launchers", "unsupported",
          note="Amazon, Ubisoft and custom game folders aren't detected.")
    known = [item["bytes"] for item in items if item["bytes"] is not None]
    return {"drive": {"id": choice["id"], "uuid": choice["uuid"]}, "items": items, "coverage": coverage,
            "total": sum(known), "unknown": sum(1 for item in items if item["bytes"] is None),
            "partial": sum(1 for item in items if item["unreadable"]),
            "shared": meter.shared, "errors": errors}


def initialize_drive(identifier, confirm):
    """Create a new library only where nothing would be overwritten; the active library is unchanged."""
    if not confirm:
        raise SetupError("No changes made. Initializing requires explicit confirmation.")
    choice = select_drive(identifier)
    if choice["filesystem"] not in ["apfs", "hfs"]:
        raise SetupError("Use an APFS or Mac OS Extended volume. No formatting performed.")
    environment, issue = library_environment(choice)
    if environment != "absent":
        raise SetupError(issue or "A Couch Cube library already exists here. Nothing was changed.")
    initialize(Storage(choice))
    return {"path": choice["root"]}


def removal_plan(identifier):
    """Describe exactly what Remove would move to Trash; ambiguous ownership fails closed."""
    choice = select_drive(identifier)
    storage = Storage(choice)
    storage.check()
    root = storage.root
    if library_environment(choice)[0] != "ready":
        raise SetupError("This folder's Couch Cube ownership can't be verified. Nothing will be removed.")
    expected = Path.home() / "Games" / FOLDER if choice["mode"] == "local" else Path(choice["mount"]) / FOLDER
    if root != expected or root in [Path("/"), Path.home(), Path(choice["mount"])]:
        raise SetupError("Unexpected library location. Nothing will be removed.")
    if HOST_CONFIG.is_file():
        reject_symlinks(HOST_CONFIG)
        active = read_json(HOST_CONFIG)
        if isinstance(active, dict) and active.get("uuid") == choice["uuid"] and active.get("id") == choice["id"]:
            raise SetupError("This is your active library. Activate or move to another library first.")
    for running in [Path(__file__).resolve(), Path(sys.executable).resolve()]:
        if running.is_relative_to(root.resolve()):
            raise SetupError("Couch Cube is running from this library. Quit it and open the copy on this Mac first.")
    agent = login_agent()
    reject_symlinks(agent)
    if agent.exists():
        settings = plistlib.loads(agent.read_bytes())
        if settings.get("EnvironmentVariables", {}).get("COUCH_CUBE_ROOT") == str(root):
            raise SetupError("Automatic console mode still uses this library. Save it again in Console Mode first.")
    steam = storage.read_path("SteamLibrary")
    if steam.exists() and (not steam.is_dir() or any(steam.iterdir())):
        raise SetupError("This library still contains Steam games. Uninstall or move them in Steam first.")
    snapshot = transfer_snapshot(root)
    identity = {"drive": {k: v for k, v in choice.items() if k != "free"}, "files": snapshot}
    token = hashlib.sha256(json_text(identity).encode()).hexdigest()
    storage.check()
    return {"path": str(root), "bytes": sum(item.get("size", 0) for item in snapshot.values()),
            "files": sum(1 for item in snapshot.values() if "size" in item), "token": token}


def removal_verify(identifier, token, confirm):
    if not confirm:
        raise SetupError("No changes made. Removing a library requires explicit confirmation.")
    plan = removal_plan(identifier)
    if plan["token"] != token:
        raise SetupError("The library changed since you reviewed it. Nothing was removed.")
    return {"path": plan["path"]}


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


def frontend_preference():
    reject_symlinks(FRONTEND_CONFIG)
    if not FRONTEND_CONFIG.exists():
        return None
    value = read_json(FRONTEND_CONFIG)
    if not isinstance(value, dict) or value.get("default") not in {"steam", "es-de", "cube-tv"}:
        raise SetupError("Invalid TV menu preference. Choose Steam, ES-DE or Cube TV in Console Mode.")
    return value["default"]


def set_frontend(package, confirm=False):
    if not confirm or package not in {"steam", "es-de", "cube-tv"}:
        raise SetupError("Choose an installed TV menu and explicitly confirm the change.")
    if package != "cube-tv":  # Cube TV is part of Couch Cube itself.
        app_binary(PACKAGES[package])
    reject_symlinks(FRONTEND_CONFIG)
    FRONTEND_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=FRONTEND_CONFIG.parent, mode="w", delete=False) as file:
        file.write(json_text({"default": package}))
        temporary = file.name
    os.replace(temporary, FRONTEND_CONFIG)
    print("Default TV menu saved for this Mac. Play and automatic console mode use this choice.")


def default_frontend():
    preferred = frontend_preference()
    if preferred in (None, "cube-tv"):  # Cube TV is the default TV menu.
        return "cube-tv"
    for package in [preferred]:
        name = PACKAGES[package]
        if any((parent / name).is_dir() for parent in [Path("/Applications"), Path.home() / "Applications"]):
            app_binary(name)
            return "steam" if package == "steam" else "retro"
    if preferred:
        raise SetupError(f"Your default TV menu ({PACKAGES[preferred]}) is missing. Install it or choose another in Console Mode.")
    raise SetupError("Install Steam or ES-DE from Couch Cube > Apps first.")


def couch_cube_app():
    """The Couch Cube.app this script runs from (its TV mode opens inside the app)."""
    for parent in Path(__file__).resolve().parents:
        if parent.suffix == ".app":
            return parent
    raise SetupError("Cube TV opens inside the Couch Cube app; start it from the installed app.")


def launch(storage, action, identifier=None):
    storage.check()
    if action == "console":
        action = default_frontend()
    if action == "steam":
        app_binary("Steam.app")
        run(["/usr/bin/open", "steam://open/bigpicture"])
    elif action == "cube-tv":
        run(["/usr/bin/open", "-a", str(couch_cube_app()), "--args", "--cube-tv"])
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


LAUNCHER_SKIP = re.compile(r"^(uninstall|install|setup|readme|update)\b", re.I)
# Store apps and launchers are tools, not games: Play lists only what they install (they stay in App Store).
STORE_LAUNCHERS = re.compile(r"^(steam|battle\.?net( launcher)?|blizzard battle\.net|ea( app| desktop)?|origin|"
                             r"epic games( launcher)?|gog galaxy|galaxy|ubisoft connect|uplay|rockstar games launcher|"
                             r"amazon games|itch|curseforge|xbox|ea app)$", re.I)


def app_bundles(folder, depth=1, launchers=False):
    """`.app` bundles in a folder (and its subfolders up to `depth`), never following symlinks.
    `launchers=True` keeps store apps such as a Steam wrapper: in Sikarugir the wrapper IS how Windows Steam starts."""
    found = []
    if folder.is_symlink() or not folder.is_dir():
        return found
    for entry in sorted(folder.iterdir()):
        if entry.name.startswith(".") or entry.is_symlink():
            continue
        if entry.suffix == ".app" and entry.is_dir():
            if not LAUNCHER_SKIP.match(entry.stem) and (launchers or not STORE_LAUNCHERS.match(entry.stem.strip())):
                found.append(entry)
        elif entry.is_dir() and depth > 0:
            found += app_bundles(entry, depth - 1, launchers)
    return found


def rom_art_tools():
    spec = importlib.util.spec_from_file_location("console_rom_art", Path(__file__).with_name("rom_art.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def emulator_setup_tools():
    spec = importlib.util.spec_from_file_location("console_emulator_setup", Path(__file__).with_name("emulator_setup.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare_emulator(storage, core, binary):
    """Copy the player's own BIOS/firmware/keys into the emulator and apply console defaults once.
    A failure here must not block the game from starting, so it is reported and skipped."""
    try:
        tools = emulator_setup_tools()
        marker = storage.read_path(tools.MARKER)
        state = read_json(marker) if marker.is_file() else {}
        before = dict(state)
        for note in tools.prepare(core, storage.root, Path.home(), binary, state):
            print(note, file=sys.stderr, flush=True)
        if state != before:
            storage.write(tools.MARKER, json_text(state))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"Emulator setup skipped: {exc}", file=sys.stderr, flush=True)


def steamgriddb_tools():
    spec = importlib.util.spec_from_file_location("console_steamgriddb", Path(__file__).with_name("steamgriddb.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def game_art(storage):
    """SteamGridDB grid, hero, logo and icon for the Play library's ROMs and game apps (needs the user's key)."""
    library = library_games(storage)
    games = [{"key": rom["path"], "name": rom["name"]} for rom in library["roms"]]
    games += [{"key": app["path"], "name": app["name"]} for app in library["apps"]]
    tools = steamgriddb_tools()
    return tools.artwork(games, tools.api_key(storage.read_path(tools.KEY_FILE)))


def game_art_key(storage, key=None, clear=False):
    """Saves or removes the SteamGridDB key in the library, so it goes with the drive to other Macs."""
    tools = steamgriddb_tools()
    if clear:
        path = storage.target(tools.KEY_FILE)
        if path.exists():
            path.unlink()
    elif key is not None:
        try:
            storage.write(tools.KEY_FILE, tools.key_file_content(key))
        except tools.GridError as exc:
            raise SetupError(str(exc)) from None
    return {"saved": tools.api_key(storage.read_path(tools.KEY_FILE)) is not None}


def library_games(storage, home=None):
    """Everything playable for the Play page's game grid, read-only and fast (nothing is measured):
    ROMs of enabled consoles, native Mac games and Windows wrappers in the library, Porting Kit ports
    and CrossOver's program shortcuts. Steam games come from steam-status."""
    home = Path.home() if home is None else home
    enabled = set(selected_systems(read_json(storage.target(MARKER))))
    art = rom_art_tools()
    roms = []
    for system, (system_name, extensions, _) in SYSTEMS.items():
        folder = storage.root / "ROMs" / system
        if system not in enabled or folder.is_symlink() or not folder.is_dir():
            continue
        try:
            found = playable_roms(folder, extensions.split("|"))
        except OSError:
            continue  # An unreadable folder hides only its own games.
        for name, launch in found:
            cover = art.cached(system, name)
            roms.append({"system": system, "system_name": system_name, "name": name, "path": str(launch),
                         "cover": str(cover) if cover else None})
    apps = []
    sikarugir_folder = home / "Applications/Sikarugir"
    for kind, folder, depth in [("native", storage.root / "Native/Games", 1),
                                ("windows", storage.root / "Windows/Wrappers", 1),
                                ("porting-kit", storage.root / "Windows/Porting Kit", 1),
                                ("windows", sikarugir_folder, 1),
                                ("crossover", home / "Applications/CrossOver", 2)]:
        for app in app_bundles(folder, depth, launchers=folder == sikarugir_folder):
            apps.append({"kind": kind, "name": app.stem, "path": str(app),
                         "group": app.parent.name if kind == "crossover" and app.parent != folder else None})
    return {"roms": roms, "apps": apps}


CORE_URL = "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/{core}_libretro.dylib.zip"
CORE_HOST = "buildbot.libretro.com"
MAX_CORE_BYTES = 200 << 20


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def install_core(core, destination):
    """Download one RetroArch core from libretro's own build server (https only, that host only, size-limited)."""
    if core not in {entry[2] for entry in SYSTEMS.values()} or not re.fullmatch(r"[a-z0-9_]+", core):
        raise SetupError("Unknown RetroArch core.")
    member = core + "_libretro.dylib"
    url = CORE_URL.format(core=core)
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname != CORE_HOST:
        raise SetupError("Core downloads are limited to libretro's build server.")
    print(f"Downloading RetroArch core: {core}", file=sys.stderr, flush=True)
    try:
        opener = urllib.request.build_opener(_NoRedirects)
        with opener.open(urllib.request.Request(url, headers={"User-Agent": "CouchCube"}), timeout=60) as reply:
            data = reply.read(MAX_CORE_BYTES + 1)
        if len(data) > MAX_CORE_BYTES:
            raise SetupError("The core download is unexpectedly large; nothing was saved.")
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            info = archive.getinfo(member)
            if info.file_size > MAX_CORE_BYTES:
                raise SetupError("The core file is unexpectedly large; nothing was saved.")
            payload = archive.read(info)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as exc:
        raise SetupError(f"Couldn't download core {member} ({exc}). Install it in RetroArch > Online Updater > Core Downloader.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
        temp.write(payload)
    os.chmod(temp.name, 0o755)
    os.replace(temp.name, destination)


@contextlib.contextmanager
def controller_quit(storage, binary):
    """While a game runs, holding Select + Start on any controller for two seconds quits the emulator (many
    standalone emulators have no controller hotkey for it). Skipped quietly when the helper isn't in the library."""
    helper = storage.root / "Runtime/ControllerQuit"
    watcher = None
    if helper.is_file() and not helper.is_symlink() and os.access(helper, os.X_OK):
        try:
            watcher = subprocess.Popen([str(helper), "--binary", str(binary)])
        except OSError:
            watcher = None
    try:
        yield
    finally:
        if watcher is not None:
            watcher.terminate()


def emulate(storage, system, rom):
    if system not in SYSTEMS:
        raise SetupError("Unknown emulation system.")
    path = Path(rom).absolute()
    reject_symlinks(path)
    core = SYSTEMS[system][2]
    enabled = selected_systems(read_json(storage.target(MARKER)))
    if system not in enabled:
        raise SetupError("This console is disabled. Enable it in Couch Cube > Consoles.")
    if not path.is_relative_to(storage.root / "ROMs" / system) or not path.is_file():
        raise SetupError("ROM must be a file in the selected system's ROM folder.")
    if core in STANDALONE:
        prepare_emulator(storage, core, app_binary(PACKAGES[core]))
    if core == "dolphin":
        binary = app_binary("Dolphin.app")
        args = [str(binary), "-b", "-e", str(path), "-u", str(storage.root / "Saves/Dolphin")]
    elif core in STANDALONE:
        binary = app_binary(PACKAGES[core])
        flags = {"pcsx2": ["-fullscreen", "-batch", str(path)],
                 "rpcs3": ["--no-gui", str(path)],
                 "cemu-wiiu": ["-f", "-g", str(path)],
                 "switch": ["-f", str(path)],
                 "azahar": ["-f", str(path)],
                 "xemu": ["-full-screen", "-dvd_path", str(path)]}
        args = [str(binary)] + flags[core]
    else:
        binary = app_binary("RetroArch.app")
        sync_system_bios(storage, system)
        core_path = Path.home() / "Library/Application Support/RetroArch/cores" / (core + "_libretro.dylib")
        if not core_path.is_file():
            install_core(core, core_path)
        args = [str(binary), "-L", str(core_path), "--appendconfig",
                str(storage.root / "Config/retroarch-console.cfg"), str(path)]
    with controller_quit(storage, args[0]):
        run(args)


def vdf_value(text, key):
    match = re.search(r'"' + re.escape(key) + r'"\s+"((?:\\.|[^"\\])*)"', text, re.IGNORECASE)
    if not match:
        raise SetupError(f"Steam manifest is missing {key}.")
    return match.group(1).replace(r"\\", "\\").replace(r'\"', '"')


def parse_vdf(text):
    tokens = []
    offset = 0
    pattern = re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]')
    while offset < len(text):
        match = pattern.match(text, offset)
        if not match:
            raise SetupError("Unsupported or malformed Steam metadata.")
        token = match.group()
        offset = match.end()
        if token.isspace() or token.startswith("//"):
            continue
        tokens.append(token)
    position = 0

    def object_value(nested=False, depth=0):
        nonlocal position
        if depth > 32:
            raise SetupError("Steam metadata nesting is too deep.")
        result = {}
        while position < len(tokens):
            key = tokens[position]
            position += 1
            if key == "}" and nested:
                return result
            if not key.startswith('"') or position >= len(tokens):
                raise SetupError("Malformed Steam metadata key.")
            key = key[1:-1].replace(r"\\", "\\").replace(r'\"', '"').lower()
            value = tokens[position]
            position += 1
            if value == "{":
                value = object_value(True, depth + 1)
            elif value.startswith('"'):
                value = value[1:-1].replace(r"\\", "\\").replace(r'\"', '"')
            else:
                raise SetupError("Malformed Steam metadata value.")
            if key in result:
                raise SetupError("Duplicate Steam metadata key: " + key)
            result[key] = value
        if nested:
            raise SetupError("Unclosed Steam metadata object.")
        return result

    return object_value()


def steam_libraries(extra=None):
    home = Path.home() / "Library/Application Support/Steam"
    paths = [home]
    metadata = home / "steamapps/libraryfolders.vdf"
    if metadata.is_file():
        folders = parse_vdf(metadata.read_text()).get("libraryfolders")
        if not isinstance(folders, dict):
            raise SetupError("Steam libraryfolders metadata is invalid.")
        for key, entry in folders.items():
            if not key.isdigit():
                continue
            path = entry.get("path") if isinstance(entry, dict) else entry
            if not isinstance(path, str) or not Path(path).is_absolute():
                raise SetupError("Steam library path is invalid.")
            paths.append(Path(path))
    if extra is not None:
        paths.append(extra)
    return list(dict.fromkeys(path.resolve() for path in paths))


def steam_library_games(path, errors):
    """Read one Steam library's app manifests; unreadable entries are reported, not guessed."""
    games = []
    try:
        manifests = sorted((path / "steamapps").glob("appmanifest_*.acf"))
        for manifest in manifests:
            try:
                data = parse_vdf(manifest.read_text()).get("appstate")
                if not isinstance(data, dict):
                    raise SetupError("Missing AppState object.")
                appid, name = data.get("appid"), data.get("name")
                if not isinstance(appid, str) or not appid.isdigit() or not isinstance(name, str):
                    raise SetupError("Invalid Steam game identity.")
                if manifest.name != f"appmanifest_{appid}.acf":
                    raise SetupError("Steam app ID does not match its manifest filename.")
                flags, size = data.get("stateflags"), data.get("sizeondisk")
                flags = int(flags) if isinstance(flags, str) and flags.isdigit() else None
                size = int(size) if isinstance(size, str) and size.isdigit() else None
                state = "Unknown"
                if flags is not None:
                    state = "Update required" if flags & 2 else "Installed" if flags & 4 else "Not fully installed"
                    if flags & (256 | 512 | 1024 | 131072 | 262144 | 524288 | 1048576 | 2097152 | 4194304 | 8388608):
                        state = "Update / install in progress"
                games.append({"appid": appid, "name": name, "state": state,
                              "installed": flags is not None and bool(flags & 4), "bytes": size})
            except (SetupError, OSError, UnicodeError) as exc:
                errors.append(f"{manifest}: {exc}")
    except OSError as exc:
        errors.append(f"{path}: {exc}")
    return games


def steam_status():
    libraries = []
    errors = []
    try:
        paths = steam_libraries()
    except (SetupError, OSError, UnicodeError) as exc:
        return {"libraries": [], "errors": [str(exc)]}
    for path in paths:
        if path == (Path.home() / "Library/Application Support/Steam").resolve() and not path.exists():
            continue
        available = path.is_dir()
        games = steam_library_games(path, errors) if available else []
        libraries.append({"path": str(path), "available": available, "games": games})
    return {"libraries": libraries, "errors": errors}


def index_games(storage):
    libraries = steam_libraries(storage.root / "SteamLibrary")
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
        return {"enabled": False, "delay": 30, "legacy": False, "always": False}
    with agent.open("rb") as file:
        previous = plistlib.load(file)
    if previous.get("Label") != LOGIN_LABEL:
        raise SetupError("Preserving an unrecognized existing LaunchAgent.")
    arguments = previous.get("ProgramArguments")
    if arguments == ["/usr/bin/open", "steam://open/bigpicture"]:
        return {"enabled": True, "delay": 30, "legacy": True, "always": True}
    # "--always" opens the TV menu after every login; without it only when a controller is on and no
    # keyboard or mouse is connected.
    always = isinstance(arguments, list) and len(arguments) == 4 and arguments[3] == "--always"
    if always:
        arguments = arguments[:3]
    if (not isinstance(arguments, list) or len(arguments) != 3
            or not isinstance(arguments[0], str) or not Path(arguments[0]).is_absolute()
            or Path(arguments[0]).name != "ConsoleAutoLaunch" or arguments[1] != "--delay"
            or not isinstance(arguments[2], str) or not arguments[2].isdigit()
            or not 5 <= int(arguments[2]) <= 300):
        raise SetupError("Unrecognized console auto-launch settings; preserving the existing LaunchAgent.")
    return {"enabled": True, "delay": int(arguments[2]), "legacy": False, "always": always}


def login_helper():
    helper = PROJECT.parent / "MacOS/ConsoleAutoLaunch"
    reject_symlinks(helper)
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise SetupError("Open the built Couch Cube app to configure automatic console mode.")
    return helper


def login_launcher(confirm, enabled=True, delay=30, root=None, always=False):
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
            "ProgramArguments": [str(helper), "--delay", str(delay)] + (["--always"] if always else []),
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
    sub.add_parser("storage-status")
    transfer = sub.add_parser("transfer-plan")
    transfer.add_argument("--source", required=True)
    transfer.add_argument("--destination", required=True)
    copy_library = sub.add_parser("transfer-library")
    copy_library.add_argument("--source", required=True)
    copy_library.add_argument("--destination", required=True)
    copy_library.add_argument("--token", required=True)
    copy_library.add_argument("--confirm", action="store_true")
    retire = sub.add_parser("retire-library")
    retire.add_argument("--destination", required=True)
    retire.add_argument("--token", required=True)
    detail = sub.add_parser("drive-detail")
    detail.add_argument("--drive", required=True)
    games = sub.add_parser("drive-games")
    games.add_argument("--drive", required=True)
    create = sub.add_parser("initialize-drive")
    create.add_argument("--drive", required=True)
    create.add_argument("--confirm", action="store_true")
    removal = sub.add_parser("removal-plan")
    removal.add_argument("--drive", required=True)
    remove = sub.add_parser("removal-verify")
    remove.add_argument("--drive", required=True)
    remove.add_argument("--token", required=True)
    remove.add_argument("--confirm", action="store_true")
    sub.add_parser("disks")
    sub.add_parser("update-check")
    sub.add_parser("login-status")
    sub.add_parser("steam-status")
    sub.add_parser("system-catalog")
    deals = sub.add_parser("deals")
    deals.add_argument("--source", choices=["cheapshark", "gamerpower"], required=True)
    deals.add_argument("--page", type=int, default=0)
    deals.add_argument("--sort")
    deals.add_argument("--store")
    deals.add_argument("--search")
    deals.add_argument("--platform")
    deals.add_argument("--type", dest="kind")
    deals.add_argument("--refresh", action="store_true")
    deals.add_argument("--mine", action="store_true")
    shop_home_parser = sub.add_parser("shop-home")
    shop_home_parser.add_argument("--scope", choices=["mine", "all"], default="mine")
    shop_home_parser.add_argument("--refresh", action="store_true")
    shop_search_parser = sub.add_parser("shop-search")
    shop_search_parser.add_argument("--query", required=True)
    shop_search_parser.add_argument("--country", default="US")
    shop_search_parser.add_argument("--refresh", action="store_true")
    steam_details_parser = sub.add_parser("shop-steam")
    steam_details_parser.add_argument("--app", required=True)
    steam_details_parser.add_argument("--refresh", action="store_true")
    shop_game_parser = sub.add_parser("shop-game")
    shop_game_parser.add_argument("--id", required=True)
    shop_game_parser.add_argument("--refresh", action="store_true")
    platforms_parser = sub.add_parser("shop-platforms")
    platforms_parser.add_argument("--steam", default="", help="comma-separated Steam app IDs")
    platforms_parser.add_argument("--refresh", action="store_true")
    rates_parser = sub.add_parser("rates")
    rates_parser.add_argument("--refresh", action="store_true")
    steam_link = sub.add_parser("steam-link")
    steam_link.add_argument("--set", choices=["on", "off"])
    steam_sync = sub.add_parser("steam-wishlist-sync")
    steam_sync.add_argument("--refresh", action="store_true")
    wish = sub.add_parser("wishlist")
    wish_action = wish.add_mutually_exclusive_group()
    wish_action.add_argument("--add", metavar="JSON")
    wish_action.add_argument("--remove", metavar="KEY")
    wish_action.add_argument("--target", metavar="KEY")
    wish_action.add_argument("--check", action="store_true")
    wish.add_argument("--price", type=float)
    wish.add_argument("--currency", default="USD", help="currency of --price (ISO 4217 code)")
    wish.add_argument("--country", default="US")
    wish.add_argument("--refresh", action="store_true")
    sub.add_parser("windows-downloads").add_argument("--root")
    sub.add_parser("store-accounts")
    store_open = sub.add_parser("store-account-open")
    store_open.add_argument("--id", required=True)
    windows = sub.add_parser("windows-download")
    windows.add_argument("--package", required=True)
    windows.add_argument("--confirm", action="store_true")
    windows.add_argument("--root")
    frontend = sub.add_parser("frontend")
    frontend.add_argument("--default", choices=["steam", "es-de", "cube-tv"])
    frontend.add_argument("--confirm", action="store_true")
    apps = sub.add_parser("apps")
    apps.add_argument("--updates", action="store_true")
    apps.add_argument("--package", choices=list(PACKAGES))
    manage = sub.add_parser("manage-app")
    manage.add_argument("--package", choices=list(PACKAGES), required=True)
    manage.add_argument("--action", choices=["install", "update", "remove"], required=True)
    manage.add_argument("--confirm", action="store_true")
    cleanup = sub.add_parser("cleanup-host")
    cleanup.add_argument("--confirm", action="store_true")
    sub.add_parser("cleanup-plan")
    full_cleanup = sub.add_parser("cleanup-prepare")
    full_cleanup.add_argument("--items", nargs="+", required=True)
    full_cleanup.add_argument("--token", required=True)
    full_cleanup.add_argument("--confirm", action="store_true")
    detail = sub.add_parser("console-detail")
    detail.add_argument("--root", required=True)
    detail.add_argument("--system", required=True)
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
    login.add_argument("--always", action="store_true", help="Open the TV menu after every login, not only with a controller")
    setup = sub.add_parser("setup")
    setup.add_argument("--drive", required=True)
    setup.add_argument("--confirm", action="store_true")
    setup.add_argument("--no-host-config", action="store_true",
                       help="Keep selection on the drive only; do not save it in this Mac's home folder.")
    setup.add_argument("--install", nargs="*", choices=list(PACKAGES), default=[])
    for action in ["env", "index", "steam", "retro", "console", "launch", "emulate", "register", "library-games",
                   "porting-kit-folder", "rom-art", "game-art", "game-art-key"]:
        command = sub.add_parser(action)
        command.add_argument("--root")
        if action == "launch":
            command.add_argument("--id", required=True)
        if action == "game-art-key":
            command.add_argument("--set", metavar="KEY")
            command.add_argument("--clear", action="store_true")
        if action == "emulate":
            command.add_argument("--system", required=True)
            command.add_argument("--rom", required=True)
        if action == "register":
            command.add_argument("--name", required=True)
            command.add_argument("--kind", choices=["native", "windows"], required=True)
            command.add_argument("--app", required=True)
    args = parser.parse_args()
    try:
        migrate_app_support()
        if args.command == "drives":
            print(json_text(drives()))
        elif args.command == "storage-status":
            print(json_text(storage_status()))
        elif args.command == "transfer-plan":
            print(json_text(transfer_plan(args.source, args.destination)))
        elif args.command == "transfer-library":
            print(json_text(transfer_library(args.source, args.destination, args.token, args.confirm)))
        elif args.command == "retire-library":
            print(json_text(retire_transferred_library(args.destination, args.token)))
        elif args.command == "drive-detail":
            print(json_text(drive_detail(args.drive)))
        elif args.command == "drive-games":
            print(json_text(drive_games(args.drive)))
        elif args.command == "initialize-drive":
            print(json_text(initialize_drive(args.drive, args.confirm)))
        elif args.command == "removal-plan":
            print(json_text(removal_plan(args.drive)))
        elif args.command == "removal-verify":
            print(json_text(removal_verify(args.drive, args.token, args.confirm)))
        elif args.command == "disks":
            print(json_text(physical_disks()))
        elif args.command == "update-check":
            print(json_text(release_tools().latest()))
        elif args.command == "login-status":
            print(json_text(login_status()))
        elif args.command == "steam-status":
            print(json_text(steam_status()))
        elif args.command == "system-catalog":
            print(json_text(systems_status()))
        elif args.command == "store-accounts":
            print(json_text(store_accounts_tools().status()))
        elif args.command == "store-account-open":
            open_store_client(args.id)
        elif args.command == "windows-downloads":
            print(json_text(windows_downloads_status(args.root)))
        elif args.command == "windows-download":
            print("RESULT " + json.dumps(windows_download(args.package, args.confirm, args.root)), flush=True)
        elif args.command == "deals":
            print(json_text(deals_report(args.source, args.page, args.sort, args.store, args.search,
                                         args.platform, args.kind, args.refresh, args.mine)))
        elif args.command == "rates":
            print(json_text(exchange_rates(args.refresh)))
        elif args.command == "shop-home":
            print(json_text(shop_home(args.scope, args.refresh)))
        elif args.command == "shop-platforms":
            ids = [value for value in args.steam.split(",") if value][:100]
            print(json_text(shop_tools().steam_platforms(ids, args.refresh)))
        elif args.command == "shop-search":
            print(json_text(shop_search(args.query, args.country, args.refresh)))
        elif args.command == "shop-steam":
            shop = shop_tools()
            try:
                print(json_text(shop.steam_details(args.app, args.refresh)))
            except (shop.ShopError, shop.deals.DealsError) as exc:
                raise SetupError(str(exc)) from None
        elif args.command == "shop-game":
            print(json_text(shop_game(args.id, args.refresh)))
        elif args.command == "steam-link":
            print(json_text(steam_link_status(args.set)))
        elif args.command == "steam-wishlist-sync":
            print(json_text(steam_wishlist_sync(args.refresh)))
        elif args.command == "wishlist":
            if args.add:
                try:
                    item = json.loads(args.add)
                except ValueError:
                    raise SetupError("The wishlist item isn't valid JSON.") from None
                print(json_text(wishlist_change("add", item=item)))
            elif args.remove:
                print(json_text(wishlist_change("remove", key=args.remove)))
            elif args.target:
                print(json_text(wishlist_change("target", key=args.target, price=args.price, currency=args.currency.upper())))
            elif args.check:
                print(json_text(wishlist_check(args.country, args.refresh)))
            else:
                print(json_text(wishlist_status()))
        elif args.command == "frontend":
            if args.default:
                set_frontend(args.default, args.confirm)
            else:
                print(json_text({"preferred": frontend_preference()}))
        elif args.command == "apps":
            print(json_text(app_status(args.updates, args.package)))
        elif args.command == "manage-app":
            manage_app(args.package, args.action, args.confirm)
        elif args.command == "cleanup-host":
            cleanup_host(args.confirm)
        elif args.command == "cleanup-plan":
            print(json_text(cleanup_plan()))
        elif args.command == "cleanup-prepare":
            print(json_text(prepare_cleanup(args.items, args.token, args.confirm)))
        elif args.command == "console-detail":
            print(json_text(console_detail(configured_storage(args.root), args.system)))
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
            login_launcher(args.confirm, not args.disable, args.delay, args.root, args.always)
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
            elif args.command == "library-games":
                print(json_text(library_games(storage)))
            elif args.command == "game-art":
                print(json_text(game_art(storage)))
            elif args.command == "game-art-key":
                print(json_text(game_art_key(storage, args.set, args.clear)))
            elif args.command == "rom-art":
                print(json_text(rom_art_tools().covers(library_games(storage)["roms"])))
            elif args.command == "porting-kit-folder":
                storage.mkdir("Windows/Porting Kit")
                print(json_text({"path": str(storage.root / "Windows/Porting Kit")}))
            else:
                launch(storage, args.command, getattr(args, "id", None))
    except (SetupError, OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
