"""Cover art for ROMs from the libretro thumbnail collection (keyless, public, no account).

Images are matched by the game's name, the way RetroArch does: the libretro sets use No-Intro/Redump
names such as "Super Mario World (USA)", so a short name also tries the common region tags. Found
images are saved in ~/Library/Caches/Couch Cube/rom-art; misses are remembered for a week so the
server isn't asked again. Only the libretro thumbnail host is contacted, over HTTPS, with a size limit.
"""
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = "thumbnails.libretro.com"
USER_AGENT = "CouchCube/0.3 (+https://github.com/marosige/couch-cube)"
IMAGE_LIMIT = 3 * 1024 ** 2
MISS_SECONDS = 7 * 24 * 3600
REGIONS = ["", " (USA)", " (Europe)", " (World)", " (USA, Europe)", " (Japan)"]
# Couch Cube system → libretro playlist (thumbnail folder). Systems without a libretro set get no art here.
PLAYLISTS = {
    "nes": "Nintendo - Nintendo Entertainment System",
    "snes": "Nintendo - Super Nintendo Entertainment System",
    "gb": "Nintendo - Game Boy",
    "gbc": "Nintendo - Game Boy Color",
    "gba": "Nintendo - Game Boy Advance",
    "n64": "Nintendo - Nintendo 64",
    "gc": "Nintendo - GameCube",
    "wii": "Nintendo - Wii",
    "psx": "Sony - PlayStation",
    "psp": "Sony - PlayStation Portable",
    "ps2": "Sony - PlayStation 2",
    "ps3": "Sony - PlayStation 3",
    "megadrive": "Sega - Mega Drive - Genesis",
    "segacd": "Sega - Mega-CD - Sega CD",
    "gamegear": "Sega - Game Gear",
    "dreamcast": "Sega - Dreamcast",
}
# libretro replaces these characters in thumbnail file names.
UNSAFE = re.compile(r'[&*/:`<>?\\|"]')
REGION_TAG = re.compile(r"\s*\((?:USA|Europe|World|Japan|En|Fr|De|Es|It|Rev [^)]*|v[\d.]+)[^)]*\)", re.I)


class ArtError(Exception):
    pass


def cache_dir():
    return Path.home() / "Library/Caches/Couch Cube/rom-art"


def thumbnail_name(name):
    return UNSAFE.sub("_", " ".join(str(name).split()))


def candidates(system, name):
    """Thumbnail URLs to try for one game, most likely first."""
    playlist = PLAYLISTS.get(system)
    if not playlist or not str(name).strip():
        return []
    base = thumbnail_name(name)
    plain = REGION_TAG.sub("", base).strip() or base
    names = [base] + ([plain + region for region in REGIONS] if plain != base else [base + region for region in REGIONS[1:]])
    urls = []
    for title in dict.fromkeys(names):
        path = "/" + "/".join(urllib.parse.quote(part) for part in (playlist, "Named_Boxarts", title + ".png"))
        urls.append("https://" + HOST + path)
    return urls


def cache_key(system, name):
    return hashlib.sha256(f"{system}\0{name}".encode()).hexdigest()[:32]


def fetch_image(url, opener=None):
    """PNG bytes from the libretro host, or None for a missing image. Raises ArtError when unreachable."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "image/png"})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=15) as response:
            final = urllib.parse.urlsplit(getattr(response, "url", None) or url)
            if final.scheme != "https" or (final.hostname or "").lower() != HOST:
                return None
            body = response.read(IMAGE_LIMIT + 1)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise ArtError(f"The cover art server returned HTTP {exc.code}.") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ArtError("Can't reach the cover art server.") from exc
    if len(body) > IMAGE_LIMIT or not body.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    return body


def cached(system, name, folder=None):
    """The saved cover for a game, if there is one."""
    path = (folder or cache_dir()) / system / (cache_key(system, name) + ".png")
    return path if path.is_file() else None


def find(system, name, now=None, opener=None, folder=None):
    """The cover for one game: from the cache, else downloaded once. None when libretro has none."""
    folder = folder or cache_dir()
    now = time.time() if now is None else now
    found = cached(system, name, folder)
    if found:
        return found
    target = folder / system / (cache_key(system, name) + ".png")
    miss = target.with_suffix(".miss")
    try:
        if now - json.loads(miss.read_text()).get("checked", 0) < MISS_SECONDS:
            return None
    except (OSError, ValueError, AttributeError):
        pass
    for url in candidates(system, name):
        body = fetch_image(url, opener)
        if body:
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(".tmp")
            temporary.write_bytes(body)
            temporary.replace(target)
            return target
    if candidates(system, name):
        miss.parent.mkdir(parents=True, exist_ok=True)
        miss.write_text(json.dumps({"checked": now}))
    return None


def covers(roms, limit=30, now=None, opener=None, folder=None):
    """{rom path: cover file} for the given library-games ROMs; at most `limit` new downloads per call."""
    result, fetched, error = {}, 0, None
    for rom in roms:
        system, name, path = rom.get("system"), rom.get("name"), rom.get("path")
        if not system or not name or not path:
            continue
        found = cached(system, name, folder or cache_dir())
        if found is None and fetched < limit and error is None:
            fetched += 1
            try:
                found = find(system, name, now, opener, folder)
            except ArtError as exc:
                error = str(exc)
        if found:
            result[path] = str(found)
    return {"covers": result, "error": error, "more": fetched >= limit}
