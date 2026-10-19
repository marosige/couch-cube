"""Couch Cube's own wishlist: a save file on the active Couch Cube drive (<library>/Wishlist/wishlist.json).

The file travels with the drive and needs no network to view, add or remove items. Writes are atomic (temporary
file in the same folder, fsync, rename) and serialised with an advisory lock beside the file. A copy of the last
file read is mirrored on this Mac so the wishlist stays viewable, read-only, while the drive is unplugged; when a
different drive becomes active, items only known from the mirror are merged into that drive's file. A Mac with no
Couch Cube drive set up yet keeps the same file under ~/Library/Application Support/Couch Cube; its items move onto
the drive (through the mirror merge) once one is set up.
"""

import contextlib
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
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


def _currency(value):
    return value if isinstance(value, str) and re.fullmatch(r"[A-Z]{3}", value) else None


def _art(value):
    """An https artwork link only (the image itself stays in the artwork cache, never in the file)."""
    if not isinstance(value, str) or len(value) > 500 or not value.startswith("https://") or re.search(r"\s", value):
        return None
    return value


def _time(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 else None


def price_history(record, currency="USD"):
    """CheapShark's cheapestPriceEver ({"price": "2.28", "date": 1759177295}): the lowest price it ever recorded for
    the game across the PC stores it tracks, in US dollars. A single record, not a price series, so it can say
    "all-time low" or "X% above the all-time low", never "rare", "average" or "typical"."""
    if not isinstance(record, dict):
        return None
    try:
        low = Decimal(str(record.get("price")))
    except InvalidOperation:
        return None
    stamp = record.get("date")
    if not low.is_finite() or low < 0 or isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or stamp <= 0:
        return None
    try:
        date = datetime.fromtimestamp(stamp, timezone.utc).date().isoformat()
    except (OverflowError, OSError, ValueError):
        return None
    return {"low": float(low.quantize(Decimal("0.01"), ROUND_HALF_UP)), "currency": currency, "date": date}


def price_insight(price, currency, history):
    """How a current price compares with the recorded all-time low, in the same currency and scope only.
    "record": at or below the recorded low. "above": percent above it (whole percent, at least 1; None when the
    low was free). None when there's no record, no price or the currencies differ (no conversion, ever)."""
    if not isinstance(history, dict) or price is None or currency != history.get("currency"):
        return None
    try:
        current, low = Decimal(str(price)), Decimal(str(history["low"]))
    except (InvalidOperation, KeyError):
        return None
    base = {"low": history["low"], "currency": currency, "date": history.get("date")}
    if current <= low:
        return {**base, "kind": "record", "percent": None}
    if low == 0:
        return {**base, "kind": "above", "percent": None}
    percent = ((current - low) / low * 100).quantize(Decimal(1), ROUND_HALF_UP)
    return {**base, "kind": "above", "percent": max(1, int(percent))}


def _history(raw):
    if not isinstance(raw, dict) or _money(raw.get("low")) is None or _currency(raw.get("currency")) is None:
        return None
    date = raw.get("date") if isinstance(raw.get("date"), str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw["date"]) else None
    return {"low": _money(raw["low"]), "currency": raw["currency"], "date": date}


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
            "target_price": _money(raw.get("target_price")), "thumb": _art(raw.get("thumb"))}
    # A target is kept in the currency it was entered in; files from before targets had a currency used US dollars.
    item["target_currency"] = (_currency(raw.get("target_currency")) or "USD") if item["target_price"] is not None else None
    best = raw.get("best") if isinstance(raw.get("best"), dict) else None
    if best and _money(best.get("price")) is not None:
        currency = best.get("currency") if isinstance(best.get("currency"), str) and re.fullmatch(r"[A-Z]{3}", best["currency"]) else "USD"
        savings = best.get("savings") if isinstance(best.get("savings"), int) and 0 <= best["savings"] <= 100 else 0
        item["best"] = {"price": _money(best["price"]), "normal_price": _money(best.get("normal_price")),
                        "savings": savings, "store": _text(best.get("store"), 60), "currency": currency,
                        "checked": _time(best.get("checked")), "history": _history(best.get("history"))}
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


def set_target(path, key, price, currency="USD"):
    price = _money(price) if price is not None else None
    currency = _currency(currency)
    if price is not None and currency is None:
        raise WishlistError("The target price needs a currency.")

    def change(data):
        for item in data["items"]:
            if item["key"] == key:
                item["target_price"] = price
                item["target_currency"] = currency if price is not None else None
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
            item["thumb"] = _art(game.get("thumb")) or item.get("thumb")
            item["best"] = {"price": offer["price"], "normal_price": offer.get("normal_price"),
                            "savings": offer.get("savings") or 0, "store": offer["store"], "currency": "USD",
                            "checked": now, "history": game.get("history")}
            continue
        app = apps.get(item.get("app_store_id") or "")
        if app:
            item["thumb"] = _art(app.get("thumb")) or item.get("thumb")
            previous = item.get("best") or {}
            drop = 0
            if previous.get("currency") == app["currency"] and (previous.get("normal_price") or previous.get("price") or 0) > app["price"]:
                base = previous.get("normal_price") or previous["price"]
                drop = max(0, min(100, round(100 * (base - app["price"]) / base)))
            normal = (previous.get("normal_price") or previous.get("price")) if drop else None
            item["best"] = {"price": app["price"], "normal_price": normal, "savings": drop, "store": "App Store",
                            "currency": app["currency"], "checked": now, "history": None}
    return data


def target_reached(item, rates=None, fee_percent=0):
    """True/False when the best price is at or below the target, None when it can't be told (no target, no price,
    or no exchange rate between the two currencies). The price is converted into the target's currency without
    rounding, so a price a fraction above the target never counts as reached."""
    target, best = item.get("target_price"), item.get("best") or {}
    if target is None or best.get("price") is None:
        return None
    source, wanted = best.get("currency") or "USD", item.get("target_currency") or "USD"
    try:
        price, limit, fee = Decimal(str(best["price"])), Decimal(str(target)), Decimal(str(fee_percent or 0))
    except InvalidOperation:
        return None
    if source == wanted:
        return price <= limit
    table = (rates or {}).get("rates") or {}
    if source not in table or wanted not in table:
        return None
    return price / Decimal(table[source]) * Decimal(table[wanted]) * (1 + fee / 100) <= limit


def annotate(item, rates=None):
    """Badges for display: on sale (with store and percentage) and target price reached (None: can't compare)."""
    best = item.get("best") or {}
    on_sale = bool(best and (best.get("savings") or 0) > 0)
    hit = target_reached(item, rates)
    insight = price_insight(best.get("price"), best.get("currency"), best.get("history")) if best else None
    return {**item, "on_sale": on_sale, "target_hit": hit, "insight": insight,
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


def report(data, rates=None, **extra):
    return {"items": [annotate(item, rates) for item in data["items"]], **extra}


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
