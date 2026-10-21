"""Read-only game deals from CheapShark (store prices) and GamerPower (free giveaways).

Both APIs are public and keyless. CheapShark asks for a descriptive User-Agent, links to deals through its
redirect page, and temporarily blocks clients that request too often (HTTP 429 with Retry-After).
GamerPower asks for attribution with a link back to GamerPower.com and at most 10 requests per second.
Responses are cached on disk so browsing, re-opening the page and quick refreshes do not hit the APIs again.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "CouchCube/0.3 (+https://github.com/marosige/couch-cube)"
CHEAPSHARK = "https://www.cheapshark.com/api/1.0/"
GAMERPOWER = "https://www.gamerpower.com/api/"
CHEAPSHARK_HOSTS = {"www.cheapshark.com"}
GAMERPOWER_HOSTS = {"www.gamerpower.com"}
RESPONSE_LIMIT = 4 * 1024 ** 2
PAGE_SIZE = 60
# Fresh enough to reuse without asking: CheapShark refreshes prices about hourly and caches for 5–10 minutes.
FRESH_SECONDS = {"deals": 10 * 60, "stores": 24 * 3600, "giveaways": 30 * 60, "search": 30 * 60, "games": 10 * 60,
                 "appstore": 6 * 3600, "rates": 12 * 3600, "platforms": 7 * 24 * 3600,
                 "steamdetails": 7 * 24 * 3600, "steamwishlist": 30 * 60, "steamapp": 7 * 24 * 3600}
# A manual refresh inside this window reuses the cache, so repeated clicks never become repeated requests.
REFRESH_FLOOR = 60
SORTS = {"rating": "Deal Rating", "savings": "Savings", "price": "Price", "price-desc": "Price", "recent": "Recent",
         "reviews": "Reviews", "title": "Title"}
# Only platforms a Mac can use natively or through Wine; console and mobile giveaways are never requested or shown.
GIVEAWAY_PLATFORMS = ["pc", "steam", "epic-games-store", "gog", "itchio", "ubisoft", "origin", "battlenet", "drm-free"]
PC_PLATFORMS = {"pc", "steam", "epic games store", "gog", "itch.io", "drm-free", "ubisoft", "ubisoft connect",
                "origin", "ea app", "battle.net", "battlenet"}
GIVEAWAY_TYPES = ["game", "loot", "beta"]
GIVEAWAY_SORTS = ["date", "value", "popularity"]


class DealsError(ValueError):
    pass


def cache_dir():
    return Path.home() / "Library/Caches/Couch Cube/deals"


def https_url(value, hosts=None):
    """Return value only when it is an https URL (on an expected host, when given); otherwise None."""
    if not isinstance(value, str) or len(value) > 2048 or any(ch.isspace() for ch in value):
        return None
    try:
        url = urllib.parse.urlsplit(value)
    except ValueError:
        return None
    host = (url.hostname or "").lower()
    if url.scheme != "https" or not host or url.username or url.password or url.port not in (None, 443):
        return None
    if hosts is not None and host not in hosts:
        return None
    return value


def cheapshark_link(deal_id):
    """CheapShark requires sending users to deals through its redirect page."""
    if not isinstance(deal_id, str) or not re.fullmatch(r"[A-Za-z0-9%+/=_-]{8,200}", deal_id):
        return None
    # The API returns the ID already percent-encoded; normalise so it is encoded exactly once.
    encoded = urllib.parse.quote(urllib.parse.unquote(deal_id), safe="")
    return f"https://www.cheapshark.com/redirect?dealID={encoded}"


def number(value):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if result == result and result not in (float("inf"), float("-inf")) else None


def whole(value):
    result = number(value)
    return int(result) if result is not None else None


def fetch(url, hosts, opener=None):
    """GET JSON from an allowed host; returns (status, headers, data). Raises DealsError with a readable reason."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=20) as response:
            final = urllib.parse.urlsplit(response.url if hasattr(response, "url") else url)
            if final.scheme != "https" or (final.hostname or "").lower() not in hosts:
                raise DealsError("The deals service redirected to an unexpected site.")
            body = response.read(RESPONSE_LIMIT + 1)
            if len(body) > RESPONSE_LIMIT:
                raise DealsError("The deals service sent an unexpectedly large response.")
            status = getattr(response, "status", 200)
            headers = dict(getattr(response, "headers", {}) or {})
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            retry = whole((exc.headers or {}).get("Retry-After")) or 300
            raise DealsError(f"rate-limited:{max(retry, 30)}") from exc
        raise DealsError(f"The deals service returned HTTP {exc.code}.") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        raise DealsError(f"Can't reach the deals service ({reason}). Check your internet connection.") from exc
    if status == 201 or not body.strip():
        return status, headers, None
    try:
        return status, headers, json.loads(body)
    except (ValueError, UnicodeError) as exc:
        raise DealsError("The deals service sent data Couch Cube couldn't read.") from exc


def cache_path(kind, url):
    return cache_dir() / f"{kind}-{hashlib.sha256(url.encode()).hexdigest()[:24]}.json"


def read_cache(path):
    try:
        entry = json.loads(path.read_text())
        return entry if isinstance(entry, dict) and isinstance(entry.get("fetched"), (int, float)) else None
    except (OSError, ValueError, UnicodeError):
        return None


def write_cache(path, entry):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, suffix=".tmp") as handle:
            json.dump(entry, handle)
        os.replace(handle.name, path)
    except OSError:
        pass


def blocked_until(service):
    entry = read_cache(cache_dir() / f"blocked-{service}.json")
    return entry.get("until", 0) if entry else 0


def cached_fetch(kind, service, url, hosts, refresh=False, now=None, opener=None):
    """Serve fresh cache, otherwise fetch; on failure fall back to the last saved response (marked stale)."""
    now = time.time() if now is None else now
    path = cache_path(kind, url)
    entry = read_cache(path)
    age = now - entry["fetched"] if entry else None
    if entry and (age < REFRESH_FLOOR or (not refresh and age < FRESH_SECONDS[kind])):
        return {**entry, "cached": True, "stale": False, "error": None}
    until = blocked_until(service)
    try:
        if until > now:
            raise DealsError(f"rate-limited:{int(until - now)}")
        status, headers, data = fetch(url, hosts, opener)
    except DealsError as exc:
        message = str(exc)
        if message.startswith("rate-limited:"):
            seconds = int(message.split(":", 1)[1])
            if until <= now:
                write_cache(cache_dir() / f"blocked-{service}.json", {"fetched": now, "until": now + seconds})
            minutes = max(1, (seconds + 59) // 60)
            message = f"The deals service asked Couch Cube to wait. Try again in about {minutes} min."
        if entry:
            return {**entry, "cached": True, "stale": True, "error": message}
        raise DealsError(message) from exc
    pages = whole({key.lower(): value for key, value in headers.items()}.get("x-total-page-count"))
    entry = {"fetched": now, "data": data, "pages": pages}
    write_cache(path, entry)
    return {**entry, "cached": False, "stale": False, "error": None}


def normalize_store(item):
    store_id = str(item.get("storeID", "")) if isinstance(item, dict) else ""
    name = item.get("storeName") if isinstance(item, dict) else None
    if not store_id.isdigit() or not isinstance(name, str) or not name.strip():
        return None
    return {"id": store_id, "name": name.strip(), "active": item.get("isActive") in (1, "1", True)}


def normalize_deal(item, stores, installed):
    if not isinstance(item, dict):
        return None
    title = item.get("title")
    url = cheapshark_link(item.get("dealID"))
    sale, normal = number(item.get("salePrice")), number(item.get("normalPrice"))
    if not isinstance(title, str) or not title.strip() or not url or sale is None or sale < 0:
        return None
    store_id = str(item.get("storeID", ""))
    app_id = str(item.get("steamAppID") or "")
    app_id = app_id if app_id.isdigit() and app_id != "0" else None
    savings = number(item.get("savings"))
    rating = number(item.get("dealRating"))
    steam_percent = whole(item.get("steamRatingPercent"))
    metacritic = whole(item.get("metacriticScore"))
    return {
        "id": urllib.parse.unquote(item["dealID"]),
        "game_id": str(item.get("gameID")) if str(item.get("gameID", "")).isdigit() else None,
        "title": " ".join(title.split()),
        "sale_price": round(sale, 2),
        "normal_price": round(normal, 2) if normal is not None and normal >= sale else None,
        "savings": max(0, min(100, round(savings))) if savings is not None else 0,
        "store_id": store_id if store_id.isdigit() else None,
        "store": stores.get(store_id),
        "deal_rating": round(rating, 1) if rating is not None and 0 <= rating <= 10 else None,
        "steam_rating": item.get("steamRatingText") if isinstance(item.get("steamRatingText"), str) and steam_percent else None,
        "steam_rating_percent": steam_percent if steam_percent and 0 < steam_percent <= 100 else None,
        "metacritic": metacritic if metacritic and 0 < metacritic <= 100 else None,
        "steam_app_id": app_id,
        # Only an exact Steam app ID match against local Steam manifests counts; names are never compared.
        "installed": bool(app_id and app_id in installed),
        "thumb": https_url(item.get("thumb")),
        "url": url,
    }


def store_deals(page=0, sort="rating", store=None, search=None, refresh=False, installed=frozenset(),
                now=None, opener=None):
    if sort not in SORTS:
        raise DealsError("Unknown sort order.")
    if store is not None and not re.fullmatch(r"\d{1,3}(,\d{1,3}){0,15}", str(store)):
        raise DealsError("Unknown store.")
    page = max(0, min(int(page), 50))
    stores_reply = cached_fetch("stores", "cheapshark", CHEAPSHARK + "stores", CHEAPSHARK_HOSTS,
                                now=now, opener=opener)
    known = [store_info for store_info in map(normalize_store, stores_reply.get("data") or []) if store_info]
    stores = {store_info["id"]: store_info["name"] for store_info in known}
    query = {"pageNumber": page, "pageSize": PAGE_SIZE, "sortBy": SORTS[sort], "onSale": 1}
    if sort in ("price", "price-desc"):
        query["desc"] = int(sort == "price-desc")
    if store is not None:
        query["storeID"] = store
    search = " ".join((search or "").split())[:60]
    if search:
        query["title"] = search
    reply = cached_fetch("deals", "cheapshark", CHEAPSHARK + "deals?" + urllib.parse.urlencode(query),
                         CHEAPSHARK_HOSTS, refresh, now, opener)
    raw = reply.get("data")
    deals = [deal for deal in (normalize_deal(item, stores, installed) for item in (raw if isinstance(raw, list) else []))
             if deal]
    total_pages = reply.get("pages")
    return {
        "source": "cheapshark", "page": page, "pages": total_pages,
        "more": bool(deals) and (page + 1 < total_pages if total_pages else len(raw or []) >= PAGE_SIZE),
        "stores": [{"id": store_info["id"], "name": store_info["name"]}
                   for store_info in sorted(known, key=lambda entry: entry["name"].lower()) if store_info["active"]],
        "deals": deals, "fetched": reply["fetched"], "cached": reply["cached"], "stale": reply["stale"],
        "error": reply["error"],
    }


def normalize_giveaway(item):
    if not isinstance(item, dict):
        return None
    title, gid = item.get("title"), item.get("id")
    url = https_url(item.get("open_giveaway_url") or item.get("open_giveaway"), GAMERPOWER_HOSTS)
    if not isinstance(title, str) or not title.strip() or not isinstance(gid, int) or not url:
        return None
    if str(item.get("status", "Active")).lower() != "active":
        return None
    worth = item.get("worth")
    worth = worth if isinstance(worth, str) and re.fullmatch(r"\$\d{1,5}(\.\d{2})?", worth) else None
    platforms = [part.strip() for part in str(item.get("platforms") or "").split(",")
                 if part.strip().lower() in PC_PLATFORMS]
    if not platforms:
        return None
    end = item.get("end_date")
    end = end if isinstance(end, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?", end) else None
    users = item.get("users")
    return {
        "id": str(gid), "title": " ".join(title.split()), "worth": worth,
        "type": item.get("type") if item.get("type") in ("Game", "DLC", "Early Access", "Other", "Beta") else None,
        "platforms": platforms, "end_date": end,
        "users": users if isinstance(users, int) and users >= 0 else None,
        "description": " ".join(str(item.get("description") or "").split())[:400],
        "thumb": https_url(item.get("thumbnail")), "url": url,
        "info_url": https_url(item.get("gamerpower_url"), GAMERPOWER_HOSTS),
    }


def giveaways(platform=None, kind=None, sort="date", refresh=False, now=None, opener=None):
    if platform is not None and platform not in GIVEAWAY_PLATFORMS:
        raise DealsError("Unknown giveaway platform.")
    if kind is not None and kind not in GIVEAWAY_TYPES:
        raise DealsError("Unknown giveaway type.")
    if sort not in GIVEAWAY_SORTS:
        raise DealsError("Unknown sort order.")
    # The filter endpoint takes a dot-separated platform union; results are filtered again client-side because
    # multi-platform giveaways also list console and mobile platforms.
    query = {"platform": platform or ".".join(GIVEAWAY_PLATFORMS), "sort-by": sort}
    if kind:
        query["type"] = kind
    reply = cached_fetch("giveaways", "gamerpower", GAMERPOWER + "filter?" + urllib.parse.urlencode(query),
                         GAMERPOWER_HOSTS, refresh, now, opener)
    raw = reply.get("data")
    items = [entry for entry in (normalize_giveaway(item) for item in (raw if isinstance(raw, list) else [])) if entry]
    return {"source": "gamerpower", "giveaways": items, "fetched": reply["fetched"], "cached": reply["cached"],
            "stale": reply["stale"], "error": reply["error"]}
