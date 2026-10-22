"""Links the Couch Cube wishlist with the signed-in Steam account, without signing in to anything.

- The Steam account (SteamID64) comes from Steam's loginusers.vdf, read by store_accounts.py.
- Owned games: app IDs listed in Steam's own per-account localconfig.vdf (games this account has on this Mac).
  Only the app ID keys under Software/Valve/Steam/apps are kept; every value in that file is ignored.
- The Steam wishlist is public data: Steam's Web API returns it for a profile whose game details are public.
  No key, password or cookie is sent.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import time
import urllib.parse

_spec = importlib.util.spec_from_file_location("steam_library_deals", Path(__file__).with_name("deals.py"))
deals = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(deals)

STEAM_API = "https://api.steampowered.com/IWishlistService/GetWishlist/v1/?"
STEAM_API_HOSTS = {"api.steampowered.com"}
STEAMID64_BASE = 76561197960265728
MAX_LOCALCONFIG_BYTES = 32 * 1024 * 1024
# New Steam wishlist games are looked up on CheapShark one by one (cached); later syncs pick up the rest.
LOOKUPS_PER_SYNC = 25

_LEXEME = re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]')
APPS_PATH = ("userlocalconfigstore", "software", "valve", "steam", "apps")


def valid_steam_id(value):
    return isinstance(value, str) and re.fullmatch(r"7656\d{13}", value) is not None


def account_folder(steam_id):
    return str(int(steam_id) - STEAMID64_BASE)


def app_ids_in_localconfig(text):
    """Digit keys directly under UserLocalConfigStore/Software/Valve/Steam/apps; malformed input gives what was read."""
    found, path, key, offset = [], [], None, 0
    while offset < len(text):
        match = _LEXEME.match(text, offset)
        if not match:
            break
        offset = match.end()
        lexeme = match.group()
        if lexeme.isspace() or lexeme.startswith("//"):
            continue
        if lexeme == "{":
            if key is None:
                break
            path.append(key.lower())
            if tuple(path[:-1]) == APPS_PATH and key.isdigit():
                found.append(key)
            key = None
        elif lexeme == "}":
            if not path:
                break
            path.pop()
            key = None
        elif key is None:
            key = lexeme[1:-1]
        else:
            key = None
    return list(dict.fromkeys(found))


def owned_app_ids(steam_root, steam_id):
    if not valid_steam_id(steam_id):
        return []
    path = Path(steam_root) / "userdata" / account_folder(steam_id) / "config" / "localconfig.vdf"
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_LOCALCONFIG_BYTES:
            return []
        return app_ids_in_localconfig(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []


def wishlist_app_ids(steam_id, refresh=False, now=None, opener=None):
    """App IDs on the account's public Steam wishlist, highest priority first."""
    url = STEAM_API + urllib.parse.urlencode({"steamid": steam_id})
    reply = deals.cached_fetch("steamwishlist", "steamapi", url, STEAM_API_HOSTS, refresh, now, opener)
    data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
    response = data.get("response") if isinstance(data.get("response"), dict) else {}
    items = [item for item in response.get("items") or [] if isinstance(item, dict) and str(item.get("appid", "")).isdigit()]
    items.sort(key=lambda item: (item.get("priority") if isinstance(item.get("priority"), int) and item["priority"] > 0 else 10 ** 6,
                                 -(item.get("date_added") if isinstance(item.get("date_added"), int) else 0)))
    return [str(item["appid"]) for item in items], reply.get("error")


def app_url(app_id):
    return deals.CHEAPSHARK + "games?" + urllib.parse.urlencode({"steamAppID": app_id})


def game_for_app(app_id, refresh=False, now=None, opener=None):
    """CheapShark's game for one Steam app ID: {title, game_id, thumb}, or None when CheapShark doesn't list it."""
    url = app_url(app_id)
    reply = deals.cached_fetch("steamapp", "cheapshark", url, deals.CHEAPSHARK_HOSTS, refresh, now, opener)
    for item in reply.get("data") or []:
        if not isinstance(item, dict) or str(item.get("steamAppID", "")) != app_id:
            continue
        title = item.get("external")
        if isinstance(title, str) and title.strip():
            game_id = str(item.get("gameID", ""))
            return {"title": " ".join(title.split()), "game_id": game_id if game_id.isdigit() else None,
                    "thumb": deals.https_url(item.get("thumb"))}
    return None


def read_link(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict) or not valid_steam_id(data.get("steam_id")):
        return {}
    seen = [value for value in data.get("seen") or [] if isinstance(value, str) and value.isdigit()]
    return {"steam_id": data["steam_id"], "seen": seen[:5000], "enabled": data.get("enabled") is not False,
            "synced": data.get("synced") if isinstance(data.get("synced"), (int, float)) else None}


def write_link(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def new_items(app_ids, seen, known_app_ids, lookup):
    """Wishlist entries for Steam games not seen in an earlier sync and not already on the Couch Cube wishlist.

    Returns (items, newly_seen, error). A game seen once is never added again, so removing it here sticks."""
    items, newly_seen, error, lookups = [], [], None, 0
    for app_id in app_ids:
        if app_id in seen:
            continue
        if app_id in known_app_ids:
            newly_seen.append(app_id)
            continue
        if lookups >= LOOKUPS_PER_SYNC:
            break
        lookups += 1
        try:
            game = lookup(app_id)
        except deals.DealsError as exc:
            error = str(exc)
            break
        newly_seen.append(app_id)
        if game:
            items.append({**game, "steam_app_id": app_id, "added": time.time()})
    return items, newly_seen, error
