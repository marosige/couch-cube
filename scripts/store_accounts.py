"""Read-only sign-in status of game clients, taken only from local client files.

Only non-secret account names are read: Steam's loginusers.vdf lists the accounts that signed in on
this computer (AccountName, PersonaName, MostRecent, Timestamp). Every other key in that file is
ignored, and Steam's token/credential files are never opened. Windows launchers inside CrossOver or
Whisky bottles are only detected as installed; their sign-in data isn't in a stable non-secret place,
so they report "sign in inside the launcher" instead of a guessed name.
"""
import os
from pathlib import Path
import re

ALLOWED_USER_KEYS = ("accountname", "personaname", "mostrecent", "timestamp")
MAX_VDF_BYTES = 256 * 1024

MAC_STEAM_BUNDLE = "com.valvesoftware.steam"
CROSSOVER_BUNDLE = "com.codeweavers.CrossOver"
WHISKY_BUNDLE = "com.isaacmarovitz.Whisky"

# Executables relative to a bottle's drive_c; the first match per launcher wins.
WINDOWS_LAUNCHERS = [
    ("win-steam", "Steam (Windows)", ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe"]),
    ("win-epic", "Epic Games Launcher", ["Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                                         "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win32/EpicGamesLauncher.exe",
                                         "Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"]),
    ("win-gog", "GOG Galaxy", ["Program Files (x86)/GOG Galaxy/GalaxyClient.exe", "Program Files/GOG Galaxy/GalaxyClient.exe"]),
    ("win-ea", "EA app", ["Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe",
                          "Program Files (x86)/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe"]),
    ("win-battlenet", "Battle.net", ["Program Files (x86)/Battle.net/Battle.net Launcher.exe",
                                     "Program Files (x86)/Battle.net/Battle.net.exe",
                                     "Program Files/Battle.net/Battle.net Launcher.exe"]),
]

_LEXEME = re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]')


def _unquote(lexeme):
    return lexeme[1:-1].replace(r"\\", "\\").replace(r'\"', '"')


def parse_loginusers(text):
    """Accounts from Steam's loginusers.vdf, keeping only allowed non-secret keys.

    Returns [{"persona", "account", "most_recent", "steam_id"}], most recent first. Malformed input returns []."""
    lexemes, offset = [], 0
    while offset < len(text):
        match = _LEXEME.match(text, offset)
        if not match:
            return []
        offset = match.end()
        lexeme = match.group()
        if not lexeme.isspace() and not lexeme.startswith("//"):
            lexemes.append(lexeme)
    users, path, current, key = [], [], None, None
    for lexeme in lexemes:
        if lexeme == "{":
            if key is None:
                return []
            path.append(key)
            if len(path) == 2 and path[0].lower() == "users":
                # The block's own key is the account's public SteamID64 (used for its public wishlist).
                current = {"steam_id": key} if re.fullmatch(r"7656\d{13}", key) else {}
            key = None
        elif lexeme == "}":
            if not path or key is not None:
                return []
            if len(path) == 2 and current is not None:
                users.append(current)
                current = None
            path.pop()
        elif key is None:
            key = _unquote(lexeme)
        else:
            if len(path) == 2 and current is not None and key.lower() in ALLOWED_USER_KEYS:
                current[key.lower()] = _unquote(lexeme)
            key = None
    if path or key is not None:
        return []
    accounts = []
    for user in users:
        account = user.get("accountname", "").strip()
        if not account:
            continue
        try:
            stamp = int(user.get("timestamp", "0"))
        except ValueError:
            stamp = 0
        accounts.append({"persona": user.get("personaname", "").strip() or None, "account": account,
                         "most_recent": user.get("mostrecent") == "1", "timestamp": stamp, "steam_id": user.get("steam_id")})
    accounts.sort(key=lambda item: (not item["most_recent"], -item["timestamp"]))
    if accounts and not any(item["most_recent"] for item in accounts):
        accounts[0]["most_recent"] = True
    for item in accounts:
        del item["timestamp"]
    return accounts


def _safe_file(path):
    try:
        return path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_VDF_BYTES
    except OSError:
        return False


def steam_accounts(steam_root):
    """Accounts in <steam_root>/config/loginusers.vdf; only that file is read."""
    path = Path(steam_root) / "config" / "loginusers.vdf"
    if not _safe_file(path):
        return []
    try:
        return parse_loginusers(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []


def steam_row(row_id, name, installed, accounts, **extra):
    row = {"id": row_id, "name": name, "accounts": [], **extra}
    if not installed:
        row.update(state="not_installed", detail="Not installed")
    elif not accounts:
        row.update(state="not_signed_in", detail="Installed — not signed in yet")
    else:
        recent = accounts[0]
        row.update(state="signed_in", account=recent["account"], persona=recent["persona"],
                   detail="Signed in as " + (f"{recent['persona']} ({recent['account']})" if recent["persona"] else recent["account"]))
        row["accounts"] = [{"account": item["account"], "persona": item["persona"], "most_recent": item["most_recent"]}
                           for item in accounts]
    return row


def bottles(home):
    found = []
    for base, host in [(home / "Library/Application Support/CrossOver/Bottles", "CrossOver"),
                       (home / "Library/Containers/com.isaacmarovitz.Whisky/Bottles", "Whisky")]:
        try:
            if base.is_symlink() or not base.is_dir():
                continue
            for entry in sorted(base.iterdir()):
                drive = entry / "drive_c"
                if not entry.is_symlink() and entry.is_dir() and drive.is_dir() and not drive.is_symlink():
                    found.append((entry.name, host, entry))
        except OSError:
            continue
    return found


def _confined_file(root, relative):
    candidate = root / relative
    try:
        resolved = candidate.resolve(strict=True)
        return candidate if resolved.is_relative_to(root.resolve()) and resolved.is_file() else None
    except (OSError, RuntimeError):
        return None


def windows_rows(home):
    rows = []
    found = bottles(home)
    for row_id, name, paths in WINDOWS_LAUNCHERS:
        match = None
        for bottle, host, folder in found:
            drive = folder / "drive_c"
            exe = next((path for path in (_confined_file(drive, relative) for relative in paths) if path), None)
            if exe:
                match = (bottle, host, folder, exe)
                break
        extra = {"platform": "Windows", "kind": "wine"}
        if match:
            bottle, host, folder, exe = match
            extra.update(bottle=bottle, host=host, executable=str(exe), bottle_path=str(folder))
        if row_id == "win-steam":
            accounts = steam_accounts(match[3].parent) if match else []
            rows.append(steam_row(row_id, name, bool(match), accounts, **extra))
        elif match:
            rows.append({"id": row_id, "name": name, "accounts": [], "state": "installed",
                         "detail": "Installed — sign in inside the launcher", **extra})
        else:
            rows.append({"id": row_id, "name": name, "accounts": [], "state": "not_installed",
                         "detail": "Not installed", **extra})
    return rows


def status(home=None, mac_steam_installed=None):
    home = Path(home) if home else Path.home()
    if mac_steam_installed is None:
        mac_steam_installed = any(Path(base, "Steam.app").is_dir() for base in ("/Applications", home / "Applications"))
    mac_root = home / "Library/Application Support/Steam"
    mac = steam_row("mac-steam", "Steam", mac_steam_installed,
                    steam_accounts(mac_root) if mac_steam_installed else [], platform="Mac", kind="mac",
                    bundle=MAC_STEAM_BUNDLE)
    rows = [mac] + windows_rows(home)
    installed = [row for row in rows if row["state"] != "not_installed"]
    return {"clients": rows, "installed": len(installed),
            "signed_in": sum(1 for row in rows if row["state"] == "signed_in")}



def open_command(client_id, home=None, app_dirs=("/Applications",)):
    """The command that opens one client and waits until it quits, derived from a fresh scan, never from input paths."""
    home = Path(home) if home else Path.home()
    if client_id == "mac-steam":
        return ["/usr/bin/open", "-W", "-b", MAC_STEAM_BUNDLE]
    row = next((row for row in windows_rows(home) if row["id"] == client_id), None)
    if row is None:
        raise ValueError("Unknown client.")
    if row["state"] == "not_installed":
        raise ValueError(f"{row['name']} isn't installed in a CrossOver or Whisky bottle.")
    if row["host"] == "Whisky":
        return ["/usr/bin/open", "-W", "-b", WHISKY_BUNDLE]
    for base in list(app_dirs) + [str(home / "Applications")]:
        wine = Path(base, "CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        if wine.is_file():
            return [str(wine), "--bottle", row["bottle"], row["executable"]]
    raise ValueError("CrossOver isn't installed, so the launcher in its bottle can't be opened.")
