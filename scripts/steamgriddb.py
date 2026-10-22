"""Game artwork from SteamGridDB, only when the user has added their own free API key.

The key is the user's (from steamgriddb.com › Preferences › API). It isn't a secret worth guarding (it
only fetches public artwork), so it lives in the game library at Config/steamgriddb.json and travels with
a portable SSD to every Mac. It is sent only to SteamGridDB's API host as a Bearer token and never printed.
Per game it saves four images to ~/Library/Caches/Couch Cube/game-art:
a wide grid (the Play tile), a hero (a big banner), a logo and an icon. Images come only from SteamGridDB's
CDN hosts, over HTTPS, with a size limit. Misses are remembered for a week.
"""
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://www.steamgriddb.com/api/v2/"
API_HOST = "www.steamgriddb.com"
CDN_HOSTS = {"cdn2.steamgriddb.com", "cdn.steamgriddb.com"}
KEY_FILE = "Config/steamgriddb.json"
KEY_PATTERN = re.compile(r"[A-Za-z0-9]{16,64}")
USER_AGENT = "CouchCube/0.3 (+https://github.com/marosige/couch-cube)"
JSON_LIMIT = 1024 ** 2
IMAGE_LIMIT = 6 * 1024 ** 2
MISS_SECONDS = 7 * 24 * 3600
KINDS = {"grid": "grids/game/{id}?dimensions=460x215,920x430",
         "hero": "heroes/game/{id}",
         "logo": "logos/game/{id}",
         "icon": "icons/game/{id}"}


class GridError(Exception):
    pass


def cache_dir():
    return Path.home() / "Library/Caches/Couch Cube/game-art"


def valid_key(value):
    return isinstance(value, str) and KEY_PATTERN.fullmatch(value.strip()) is not None


def api_key(path):
    """The key saved in the library (path to Config/steamgriddb.json), or None when none was added."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    key = data.get("api_key") if isinstance(data, dict) else None
    return key.strip() if valid_key(key) else None


def key_file_content(key):
    if not valid_key(key):
        raise GridError("That doesn't look like a SteamGridDB API key.")
    return json.dumps({"api_key": key.strip()}, indent=2) + "\n"


def _read(url, hosts, limit, headers, opener):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **headers})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=20) as response:
            final = urllib.parse.urlsplit(getattr(response, "url", None) or url)
            if final.scheme != "https" or (final.hostname or "").lower() not in hosts:
                raise GridError("SteamGridDB redirected to an unexpected site.")
            body = response.read(limit + 1)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        if exc.code in (401, 403):
            raise GridError("SteamGridDB didn't accept the API key. Check it in App Settings.") from exc
        raise GridError(f"SteamGridDB returned HTTP {exc.code}.") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise GridError("Can't reach SteamGridDB.") from exc
    if len(body) > limit:
        raise GridError("SteamGridDB sent an unexpectedly large response.")
    return body


def api(path, key, opener=None):
    body = _read(API + path, {API_HOST}, JSON_LIMIT, {"Authorization": "Bearer " + key, "Accept": "application/json"}, opener)
    if body is None:
        return None
    try:
        data = json.loads(body)
    except ValueError as exc:
        raise GridError("SteamGridDB sent data Couch Cube couldn't read.") from exc
    return data.get("data") if isinstance(data, dict) and data.get("success") is True else None


def game_id(name, key, steam_app_id=None, opener=None):
    if steam_app_id and str(steam_app_id).isdigit():
        data = api(f"games/steam/{steam_app_id}", key, opener)
        if isinstance(data, dict) and str(data.get("id", "")).isdigit():
            return str(data["id"])
    data = api("search/autocomplete/" + urllib.parse.quote(str(name)[:100], safe=""), key, opener)
    if isinstance(data, list) and data and isinstance(data[0], dict) and str(data[0].get("id", "")).isdigit():
        return str(data[0]["id"])
    return None


def item_key(name, steam_app_id=None):
    return hashlib.sha256(f"{steam_app_id or ''}\0{name}".encode()).hexdigest()[:32]


def cached(name, steam_app_id=None, folder=None):
    """{kind: file} already saved for a game."""
    base = (folder or cache_dir()) / item_key(name, steam_app_id)
    found = {}
    for kind in KINDS:
        for extension in ("png", "jpg", "webp"):
            path = base / f"{kind}.{extension}"
            if path.is_file():
                found[kind] = str(path)
                break
    return found


def fetch(name, key, steam_app_id=None, now=None, opener=None, folder=None):
    """Downloads grid, hero, logo and icon for one game (whatever SteamGridDB has); {kind: file}."""
    folder = folder or cache_dir()
    now = time.time() if now is None else now
    base = folder / item_key(name, steam_app_id)
    found = cached(name, steam_app_id, folder)
    if found:
        return found
    miss = base / "miss.json"
    try:
        if now - json.loads(miss.read_text()).get("checked", 0) < MISS_SECONDS:
            return {}
    except (OSError, ValueError, AttributeError):
        pass
    identifier = game_id(name, key, steam_app_id, opener)
    if identifier:
        for kind, path in KINDS.items():
            images = api(path.format(id=identifier), key, opener)
            url = images[0].get("url") if isinstance(images, list) and images and isinstance(images[0], dict) else None
            parts = urllib.parse.urlsplit(url) if isinstance(url, str) else None
            extension = Path(parts.path).suffix.lower().lstrip(".") if parts else ""
            if not parts or extension not in ("png", "jpg", "jpeg", "webp"):
                continue
            body = _read(url, CDN_HOSTS, IMAGE_LIMIT, {"Accept": "image/*"}, opener)
            if body:
                base.mkdir(parents=True, exist_ok=True)
                target = base / f"{kind}.{'jpg' if extension == 'jpeg' else extension}"
                temporary = target.with_suffix(".tmp")
                temporary.write_bytes(body)
                temporary.replace(target)
                found[kind] = str(target)
    if not found:
        base.mkdir(parents=True, exist_ok=True)
        miss.write_text(json.dumps({"checked": now}))
    return found


def artwork(games, key, limit=10, now=None, opener=None, folder=None):
    """{game key: {kind: file}} for library games ({key, name, steam_app_id?}); at most `limit` new lookups."""
    result, looked, error = {}, 0, None
    for game in games:
        name, steam = game.get("name"), game.get("steam_app_id")
        if not name:
            continue
        found = cached(name, steam, folder)
        if not found and key and looked < limit and error is None:
            looked += 1
            try:
                found = fetch(name, key, steam, now, opener, folder)
            except GridError as exc:
                error = str(exc)
        if found:
            result[game["key"]] = found
    return {"enabled": bool(key), "art": result, "error": error, "more": bool(key) and looked >= limit}
