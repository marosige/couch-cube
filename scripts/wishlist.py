"""Couch Cube's own wishlist: a save file on the active Couch Cube drive (<library>/Wishlist/wishlist.json).

The file travels with the drive and needs no network to view, add or remove items. Writes are atomic (temporary
file in the same folder, fsync, rename) and serialised with an advisory lock beside the file. A copy of the last
file read is mirrored on this Mac so the wishlist stays viewable, read-only, while the drive is unplugged; when a
different drive becomes active, items only known from the mirror are merged into that drive's file. A Mac with no
Couch Cube drive set up yet keeps the same file under ~/Library/Application Support/Couch Cube; its items move onto
the drive (through the mirror merge) once one is set up.
"""

import contextlib
import errno
import fcntl
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

SCHEMA = 1
RELATIVE = "Wishlist/wishlist.json"
MAX_ITEMS = 500
FILE_LIMIT = 2 * 1024 ** 2


class WishlistError(ValueError):
    pass


class ReadOnly(WishlistError):
    pass


def mirror_path():
    return Path.home() / "Library/Application Support/Couch Cube/wishlist-mirror.json"


def local_library():
    """Where the wishlist lives on a Mac that has no Couch Cube drive set up yet; it moves onto the drive later."""
    return Path.home() / "Library/Application Support/Couch Cube"


def empty():
    return {"schema": SCHEMA, "items": []}


def _text(value, limit=200):
    return " ".join(value.split())[:limit] if isinstance(value, str) and value.strip() else None


def _digits(value):
    value = str(value) if isinstance(value, (int, str)) else ""
    return value if re.fullmatch(r"\d{1,12}", value) and value != "0" else None


def _money(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return None
    return round(float(value), 2)


def _time(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 else None


def item_key(item):
    if item.get("game_id"):
        return "cs:" + item["game_id"]
    if item.get("app_store_id"):
        return "app:" + item["app_store_id"]
    return "title:" + item["title"].lower()


def normalize_item(raw):
    """Whitelisted fields only; anything else in the file is ignored."""
    if not isinstance(raw, dict):
        return None
    title = _text(raw.get("title"))
    if not title:
        return None
    item = {"title": title, "game_id": _digits(raw.get("game_id")), "steam_app_id": _digits(raw.get("steam_app_id")),
            "app_store_id": _digits(raw.get("app_store_id")), "added": _time(raw.get("added")) or time.time(),
            "target_price": _money(raw.get("target_price"))}
    best = raw.get("best") if isinstance(raw.get("best"), dict) else None
    if best and _money(best.get("price")) is not None:
        currency = best.get("currency") if isinstance(best.get("currency"), str) and re.fullmatch(r"[A-Z]{3}", best["currency"]) else "USD"
        savings = best.get("savings") if isinstance(best.get("savings"), int) and 0 <= best["savings"] <= 100 else 0
        item["best"] = {"price": _money(best["price"]), "normal_price": _money(best.get("normal_price")),
                        "savings": savings, "store": _text(best.get("store"), 60), "currency": currency,
                        "checked": _time(best.get("checked"))}
    item["key"] = item_key(item)
    return item


def normalize(data):
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        raise WishlistError("The wishlist file isn't in a format Couch Cube understands.")
    if not isinstance(data.get("schema"), int) or data["schema"] > SCHEMA:
        raise WishlistError("The wishlist was saved by a newer Couch Cube. Update Couch Cube to change it.")
    items, seen = [], set()
    for raw in data["items"][:MAX_ITEMS]:
        item = normalize_item(raw)
        if item and item["key"] not in seen:
            seen.add(item["key"])
            items.append(item)
    return {"schema": SCHEMA, "items": items}


def read(path):
    """The wishlist at path; a missing file is an empty wishlist, a damaged one is an error (never overwritten)."""
    path = Path(path)
    try:
        if path.is_symlink():
            raise WishlistError("The wishlist file is a link; Couch Cube won't follow it.")
        with open(path, "rb") as handle:
            body = handle.read(FILE_LIMIT + 1)
    except FileNotFoundError:
        return empty()
    except OSError as exc:
        raise WishlistError(f"Couldn't read the wishlist ({exc.strerror or exc}).") from exc
    if len(body) > FILE_LIMIT:
        raise WishlistError("The wishlist file is unexpectedly large.")
    try:
        return normalize(json.loads(body))
    except (ValueError, UnicodeError) as exc:
        raise WishlistError("The wishlist file is damaged. It was left untouched.") from exc


def _serialise(data):
    return {"schema": SCHEMA, "items": [{key: value for key, value in item.items() if key != "key"}
                                        for item in data["items"]]}


def write(path, data):
    """Atomic replace: temp file in the same folder, fsync, rename, fsync the folder."""
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".wishlist-", suffix=".tmp", delete=False)
    except OSError as exc:
        if exc.errno in (errno.EROFS, errno.EACCES, errno.EPERM):
            raise ReadOnly("The Couch Cube drive is read-only, so the wishlist can't be changed.") from exc
        raise WishlistError(f"Couldn't save the wishlist ({exc.strerror or exc}).") from exc
    try:
        with handle:
            json.dump(_serialise(data), handle, indent=1, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(handle.name, path)
        with contextlib.suppress(OSError):
            folder = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(folder)
            finally:
                os.close(folder)
    except OSError as exc:
        with contextlib.suppress(OSError):
            os.unlink(handle.name)
        raise WishlistError(f"Couldn't save the wishlist ({exc.strerror or exc}).") from exc


@contextlib.contextmanager
def locked(path):
    """Advisory lock so two Couch Cube processes never interleave a read-modify-write."""
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path.parent / ".wishlist.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    except OSError as exc:
        if exc.errno in (errno.EROFS, errno.EACCES, errno.EPERM):
            raise ReadOnly("The Couch Cube drive is read-only, so the wishlist can't be changed.") from exc
        raise WishlistError(f"Couldn't open the wishlist ({exc.strerror or exc}).") from exc
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def update(path, change):
    with locked(path):
        data = read(path)
        change(data)
        data["items"] = data["items"][:MAX_ITEMS]
        write(path, data)
        return data


def merge(primary, extra):
    """Union by item key; primary's entries win, extra only adds what primary lacks. Returns (data, added)."""
    keys = {item["key"] for item in primary["items"]}
    added = [item for item in extra["items"] if item["key"] not in keys]
    return {"schema": SCHEMA, "items": primary["items"] + added}, len(added)


def add(path, raw, now=None):
    item = normalize_item({**(raw or {}), "added": now or time.time()})
    if not item:
        raise WishlistError("That game can't be added to the wishlist.")

    def change(data):
        if all(existing["key"] != item["key"] for existing in data["items"]):
            data["items"].append(item)
    return update(path, change)


def remove(path, key):
    return update(path, lambda data: data.__setitem__("items", [item for item in data["items"] if item["key"] != key]))


def set_target(path, key, price):
    price = _money(price) if price is not None else None

    def change(data):
        for item in data["items"]:
            if item["key"] == key:
                item["target_price"] = price
    return update(path, change)


def apply_prices(data, prices, now=None):
    """Record the best current offer per item from shop.wishlist_prices. Items without data keep their last price."""
    now = now or time.time()
    games, apps = prices.get("games") or {}, prices.get("apps") or {}
    for item in data["items"]:
        game = games.get(item.get("game_id") or "")
        if game and game.get("offers"):
            offer = game["offers"][0]
            item["steam_app_id"] = item.get("steam_app_id") or game.get("steam_app_id")
            item["best"] = {"price": offer["price"], "normal_price": offer.get("normal_price"),
                            "savings": offer.get("savings") or 0, "store": offer["store"], "currency": "USD",
                            "checked": now}
            continue
        app = apps.get(item.get("app_store_id") or "")
        if app:
            previous = item.get("best") or {}
            drop = 0
            if previous.get("currency") == app["currency"] and (previous.get("normal_price") or previous.get("price") or 0) > app["price"]:
                base = previous.get("normal_price") or previous["price"]
                drop = max(0, min(100, round(100 * (base - app["price"]) / base)))
            normal = (previous.get("normal_price") or previous.get("price")) if drop else None
            item["best"] = {"price": app["price"], "normal_price": normal, "savings": drop, "store": "App Store",
                            "currency": app["currency"], "checked": now}
    return data


def annotate(item):
    """Badges for display: on sale (with store and percentage) and target price reached."""
    best = item.get("best") or {}
    on_sale = bool(best and (best.get("savings") or 0) > 0)
    target = item.get("target_price")
    hit = target is not None and best.get("price") is not None and best.get("currency", "USD") == "USD" and best["price"] <= target
    return {**item, "on_sale": on_sale, "target_hit": hit,
            "sale_text": f"On sale at {best['store']} −{best['savings']}%" if on_sale and best.get("store") else None}


def mirror(library, data):
    entry = {"library": library, "saved": time.time(), "data": _serialise(data)}
    path = mirror_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, suffix=".tmp") as handle:
            json.dump(entry, handle)
        os.replace(handle.name, path)
    except OSError:
        pass


def read_mirror():
    try:
        entry = json.loads(mirror_path().read_text())
        return entry.get("library"), normalize(entry.get("data")), entry.get("saved")
    except (OSError, ValueError, UnicodeError, AttributeError, WishlistError):
        return None, None, None


def report(data, **extra):
    return {"items": [annotate(item) for item in data["items"]], **extra}


def status(path, library):
    """Read the drive's wishlist (merging items carried over from another drive) or fall back to the mirror."""
    if path is None:
        _, cached, saved = read_mirror()
        return report(cached or empty(), library=None, read_only=True, offline=True, saved=saved, merged=0,
                      note="The Couch Cube drive isn't connected. Showing the last saved wishlist (read-only).")
    data = read(path)
    merged, read_only, note = 0, False, None
    old_library, cached, _ = read_mirror()
    if cached and old_library and old_library != library:
        combined, merged = merge(data, cached)
        if merged:
            try:
                data = update(path, lambda current: current.__setitem__("items", merge(current, cached)[0]["items"]))
                note = f"Added {merged} wishlist item{'s' if merged != 1 else ''} from your previous Couch Cube drive."
            except ReadOnly as exc:
                data, read_only, note = combined, True, str(exc)
                merged = 0
    if not read_only:
        read_only = not os.access(Path(path).parent if Path(path).parent.exists() else Path(library), os.W_OK)
        note = note or ("The Couch Cube drive is read-only, so the wishlist can't be changed." if read_only else None)
    if not (cached and old_library != library and read_only):
        # A read-only drive that couldn't take carried-over items keeps the old mirror, so nothing is lost.
        mirror(library, data)
    return report(data, library=library, read_only=read_only, offline=False, saved=None, merged=merged, note=note)
