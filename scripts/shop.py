"""Cube Shop: store scope, unified price search, Mac App Store results and wishlist price checks.

Everything is read-only and keyless. CheapShark supplies PC store prices in USD (links always go through its
redirect page), GamerPower supplies giveaways and Apple's public iTunes Search API supplies Mac App Store
games priced in the user's storefront currency. Responses are cached on disk through deals.cached_fetch, which
also honours HTTP 429 Retry-After per service. Console-only platforms (PlayStation, Xbox, Switch, mobile, VR)
are never shown.
"""

import importlib.util
from pathlib import Path
import re
import urllib.parse

_spec = importlib.util.spec_from_file_location("shop_deals", Path(__file__).with_name("deals.py"))
deals = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(deals)
_spec = importlib.util.spec_from_file_location("shop_wishlist", Path(__file__).with_name("wishlist.py"))
wishlist = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wishlist)

STEAM_APPDETAILS = "https://store.steampowered.com/api/appdetails?"
STEAM_HOSTS = {"store.steampowered.com"}
# Steam's appdetails answers one game per request and is rate-limited, so each call looks up only a few new games.
PLATFORM_LOOKUPS = 12
ITUNES = "https://itunes.apple.com/"
ITUNES_HOSTS = {"itunes.apple.com"}
APP_STORE_HOSTS = {"apps.apple.com"}
GAMES_BATCH = 25
LOOKUP_BATCH = 50
SEARCH_GAMES = 12
APP_STORE_GAMES_GENRE = "6014"

# Stores Couch Cube can tell are "yours": a Mac app or a launcher in the Couch Cube Wine bottles.
STORES = [
    {"key": "steam", "name": "Steam", "cheapshark": ["1"], "platforms": ["steam"],
     "clients": ["mac-steam", "win-steam"], "apps": ["Steam.app"]},
    {"key": "epic", "name": "Epic Games", "cheapshark": ["25"], "platforms": ["epic games store"],
     "clients": ["win-epic"], "apps": ["Epic Games Launcher.app"]},
    {"key": "gog", "name": "GOG", "cheapshark": ["7"], "platforms": ["gog"],
     "clients": ["win-gog"], "apps": ["GOG Galaxy.app"]},
    {"key": "ea", "name": "EA", "cheapshark": ["8"], "platforms": ["origin", "ea app"],
     "clients": ["win-ea"], "apps": ["EA app.app"]},
    {"key": "battlenet", "name": "Battle.net", "cheapshark": ["31"], "platforms": ["battle.net", "battlenet"],
     "clients": ["win-battlenet"], "apps": ["Battle.net.app"]},
    {"key": "ubisoft", "name": "Ubisoft", "cheapshark": ["13"], "platforms": ["ubisoft", "ubisoft connect"],
     "clients": [], "apps": ["Ubisoft Connect.app"]},
]

# GamerPower platform labels (lowercased) that a Mac can use, natively or through Wine. Everything else is dropped.
PC_PLATFORMS = deals.PC_PLATFORMS


class ShopError(deals.DealsError):
    pass


def title_key(title):
    """Exact-title comparison that ignores case, trademark signs and punctuation (never fuzzy)."""
    return " ".join(re.sub(r"[^0-9a-z]+", " ", re.sub(r"[®™©]", "", title.lower())).split())


def pc_platforms(labels):
    """The Mac-usable subset of a giveaway's platform labels, in their original order."""
    return [label for label in labels if isinstance(label, str) and label.strip().lower() in PC_PLATFORMS]


def pc_only(giveaways):
    """Keep giveaways that work on at least one Mac-usable platform and show only those platforms."""
    kept = []
    for item in giveaways:
        platforms = pc_platforms(item.get("platforms") or [])
        if platforms:
            kept.append({**item, "platforms": platforms})
    return kept


def installed_stores(clients, home=None, app_dirs=("/Applications",)):
    """Stores whose Mac app or Wine launcher is installed, from store_accounts rows and /Applications."""
    home = Path(home) if home else Path.home()
    present = {row.get("id") for row in clients or [] if row.get("state") not in (None, "not_installed")}
    dirs = [Path(base) for base in app_dirs] + [home / "Applications"]
    mine = []
    for store in STORES:
        app = any((base / name).is_dir() for base in dirs for name in store["apps"])
        if app or present.intersection(store["clients"]):
            mine.append({"key": store["key"], "name": store["name"]})
    return mine


def scope_filter(mine):
    """CheapShark store IDs and GamerPower platform labels for the given installed stores."""
    keys = {store["key"] for store in mine}
    ids, labels = [], set()
    for store in STORES:
        if store["key"] in keys:
            ids += store["cheapshark"]
            labels.update(store["platforms"])
    return ids, labels


def in_scope(giveaway, labels):
    return any(label.lower() in labels for label in giveaway.get("platforms") or [])


def score(deal):
    """Simple local ranking: discount, deal rating and reviews. Nothing leaves the Mac."""
    savings = (deal.get("savings") or 0) / 100
    rating = (deal.get("deal_rating") or 0) / 10
    reviews = (deal.get("steam_rating_percent") or deal.get("metacritic") or 50) / 100
    return round(0.4 * savings + 0.4 * rating + 0.2 * reviews, 4)


def country_code(value):
    value = (value or "").strip().upper()
    return value if re.fullmatch(r"[A-Z]{2}", value) else "US"


def store_names(now=None, opener=None):
    reply = deals.cached_fetch("stores", "cheapshark", deals.CHEAPSHARK + "stores", deals.CHEAPSHARK_HOSTS,
                               now=now, opener=opener)
    return {info["id"]: info["name"] for info in map(deals.normalize_store, reply.get("data") or []) if info}


def normalize_offer(item, stores):
    if not isinstance(item, dict):
        return None
    url = deals.cheapshark_link(item.get("dealID"))
    price, retail = deals.number(item.get("price")), deals.number(item.get("retailPrice"))
    store_id = str(item.get("storeID", ""))
    if not url or price is None or price < 0 or not store_id.isdigit() or store_id not in stores:
        return None
    savings = deals.number(item.get("savings"))
    return {"store_id": store_id, "store": stores[store_id], "price": round(price, 2),
            "normal_price": round(retail, 2) if retail is not None and retail >= price else None,
            "savings": max(0, min(100, round(savings))) if savings is not None else 0,
            "currency": "USD", "url": url}


def sorted_offers(offers):
    offers = sorted(offers, key=lambda offer: (offer["price"], offer["store"].lower()))
    lowest = offers[0]["price"] if offers else None
    return [{**offer, "cheapest": offer["price"] == lowest} for offer in offers]


def games_by_ids(ids, refresh=False, now=None, opener=None, stores=None):
    """Every current store offer per CheapShark game ID, fetched in batches of 25 (the API's limit)."""
    ids = list(dict.fromkeys(str(value) for value in ids if str(value).isdigit()))
    if not ids:
        return {}, None
    stores = stores if stores is not None else store_names(now, opener)
    games, error = {}, None
    for start in range(0, len(ids), GAMES_BATCH):
        batch = ids[start:start + GAMES_BATCH]
        url = deals.CHEAPSHARK + "games?" + urllib.parse.urlencode({"ids": ",".join(batch)})
        try:
            reply = deals.cached_fetch("games", "cheapshark", url, deals.CHEAPSHARK_HOSTS, refresh, now, opener)
        except deals.DealsError as exc:
            error = str(exc)
            continue
        error = error or reply.get("error")
        data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
        for game_id in batch:
            entry = data.get(game_id)
            if not isinstance(entry, dict):
                continue
            info = entry.get("info") if isinstance(entry.get("info"), dict) else {}
            title = info.get("title")
            if not isinstance(title, str) or not title.strip():
                continue
            app_id = str(info.get("steamAppID") or "")
            offers = sorted_offers([offer for offer in (normalize_offer(item, stores) for item in entry.get("deals") or []) if offer])
            # The all-time low covers every CheapShark store in USD, so it's compared with the best USD offer only.
            history = wishlist.price_history(entry.get("cheapestPriceEver"))
            games[game_id] = {"id": game_id, "title": " ".join(title.split()),
                              "steam_app_id": app_id if app_id.isdigit() and app_id != "0" else None,
                              "thumb": deals.https_url(info.get("thumb")), "offers": offers, "history": history,
                              "insight": wishlist.price_insight(offers[0]["price"], "USD", history) if offers else None}
    return games, error


def normalize_app(item):
    """A Mac App Store game from the iTunes Search API; iOS apps and non-games are dropped."""
    if not isinstance(item, dict) or item.get("kind") != "mac-software":
        return None
    genres = [str(value) for value in item.get("genreIds") or []]
    if APP_STORE_GAMES_GENRE not in genres and item.get("primaryGenreName") != "Games":
        return None
    track, title = item.get("trackId"), item.get("trackName")
    price, currency = deals.number(item.get("price")), item.get("currency")
    url = deals.https_url(item.get("trackViewUrl"), APP_STORE_HOSTS)
    if not isinstance(track, int) or not isinstance(title, str) or not title.strip() or price is None or not url:
        return None
    if not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency):
        return None
    formatted = item.get("formattedPrice")
    return {"id": str(track), "title": " ".join(title.split()), "price": round(price, 2), "currency": currency,
            "formatted": formatted if isinstance(formatted, str) and len(formatted) < 40 else None,
            "seller": item.get("sellerName") if isinstance(item.get("sellerName"), str) else None,
            "thumb": deals.https_url(item.get("artworkUrl100")), "url": url, "store": "App Store"}


def app_store_search(term, country, refresh=False, now=None, opener=None):
    query = {"term": term, "entity": "macSoftware", "country": country_code(country).lower(), "limit": 25}
    reply = deals.cached_fetch("appstore", "itunes", ITUNES + "search?" + urllib.parse.urlencode(query),
                               ITUNES_HOSTS, refresh, now, opener)
    data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
    apps = [app for app in map(normalize_app, data.get("results") or []) if app]
    return sorted(apps, key=lambda app: app["price"]), reply.get("error")


def app_store_lookup(ids, country, refresh=False, now=None, opener=None):
    ids = list(dict.fromkeys(str(value) for value in ids if str(value).isdigit()))
    apps, error = {}, None
    for start in range(0, len(ids), LOOKUP_BATCH):
        query = {"id": ",".join(ids[start:start + LOOKUP_BATCH]), "country": country_code(country).lower()}
        try:
            reply = deals.cached_fetch("appstore", "itunes", ITUNES + "lookup?" + urllib.parse.urlencode(query),
                                       ITUNES_HOSTS, refresh, now, opener)
        except deals.DealsError as exc:
            error = str(exc)
            continue
        error = error or reply.get("error")
        data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
        for item in data.get("results") or []:
            app = normalize_app(item) or (normalize_app({**item, "primaryGenreName": "Games"})
                                         if isinstance(item, dict) else None)
            if app:
                apps[app["id"]] = app
    return apps, error


def search(query, country="US", refresh=False, now=None, opener=None):
    """One query, every source: one section per game with its store offers sorted by price (USD), plus a
    separate Mac App Store group priced in the storefront's own currency (never mixed into the USD sort)."""
    query = " ".join((query or "").split())[:60]
    if len(query) < 2:
        raise ShopError("Type at least two characters to search.")
    errors, games = [], []
    try:
        url = deals.CHEAPSHARK + "games?" + urllib.parse.urlencode({"title": query, "limit": SEARCH_GAMES})
        reply = deals.cached_fetch("search", "cheapshark", url, deals.CHEAPSHARK_HOSTS, refresh, now, opener)
        if reply.get("error"):
            errors.append(reply["error"])
        found = [item for item in reply.get("data") or [] if isinstance(item, dict)]
        ids = [str(item.get("gameID")) for item in found if str(item.get("gameID", "")).isdigit()]
        details, error = games_by_ids(ids, refresh, now, opener)
        if error:
            errors.append(error)
        games = [details[game_id] for game_id in ids if game_id in details and details[game_id]["offers"]]
    except deals.DealsError as exc:
        errors.append(str(exc))
    apps = []
    try:
        apps, error = app_store_search(query, country, refresh, now, opener)
        if error:
            errors.append(error)
    except deals.DealsError as exc:
        errors.append(str(exc))
    # A Mac App Store game with exactly the same title joins that game's store list (in its own currency).
    by_title = {}
    for app in apps:
        by_title.setdefault(title_key(app["title"]), app)
    matched = set()
    for game in games:
        app = by_title.get(title_key(game["title"]))
        game["app_store_offer"] = app
        if app:
            matched.add(app["id"])
    apps = [app for app in apps if app["id"] not in matched]
    currency = (apps or [by_title[key] for key in by_title])[0]["currency"] if by_title else None
    return {"query": query, "games": games, "currency": "USD",
            "app_store": {"country": country_code(country), "currency": currency, "apps": apps},
            "errors": list(dict.fromkeys(errors))}


def game(game_id, refresh=False, now=None, opener=None):
    """One CheapShark game with every current store offer and its all-time low, for the Cube Shop game page."""
    game_id = str(game_id or "")
    if not game_id.isdigit():
        raise ShopError("Unknown game.")
    games, error = games_by_ids([game_id], refresh, now, opener)
    found = games.get(game_id)
    if found is None and error:
        raise deals.DealsError(error)
    return {"game": found, "errors": [error] if error else []}


def wishlist_prices(items, country="US", refresh=False, now=None, opener=None):
    """Current best prices for wishlist items: CheapShark game IDs in batches of 25, App Store IDs via lookup."""
    game_ids = [item["game_id"] for item in items if item.get("game_id")]
    track_ids = [item["app_store_id"] for item in items if item.get("app_store_id")]
    games, game_error = games_by_ids(game_ids, refresh, now, opener) if game_ids else ({}, None)
    apps, app_error = app_store_lookup(track_ids, country, refresh, now, opener) if track_ids else ({}, None)
    return {"games": games, "apps": apps, "errors": [error for error in (game_error, app_error) if error]}


def resolve_title(title, refresh=False, now=None, opener=None):
    """CheapShark game ID for an exact (case-insensitive) title match only; never a fuzzy guess."""
    url = deals.CHEAPSHARK + "games?" + urllib.parse.urlencode({"title": title, "limit": 5, "exact": 1})
    reply = deals.cached_fetch("search", "cheapshark", url, deals.CHEAPSHARK_HOSTS, refresh, now, opener)
    wanted = " ".join(title.split()).lower()
    for item in reply.get("data") or []:
        if isinstance(item, dict) and " ".join(str(item.get("external", "")).split()).lower() == wanted:
            game_id = str(item.get("gameID", ""))
            if game_id.isdigit():
                return game_id
    return None


def with_insights(deals_list, refresh=False, now=None, opener=None):
    """Adds the all-time low to store deals: CheapShark's deal list has no price history, so the games are
    looked up in batches of 25 (cached) and each deal's sale price is compared with the recorded low."""
    ids = [deal["game_id"] for deal in deals_list if deal.get("game_id")]
    if not ids:
        return deals_list
    try:
        games, _ = games_by_ids(ids, refresh, now, opener)
    except deals.DealsError:
        return deals_list
    result = []
    for deal in deals_list:
        history = games.get(deal.get("game_id") or "", {}).get("history")
        insight = wishlist.price_insight(deal["sale_price"], "USD", history) if history else None
        result.append({**deal, "insight": insight} if insight else deal)
    return result


def home(mine, scope="mine", refresh=False, installed=frozenset(), now=None, opener=None):
    """Featured deals, recent price drops and free games for the chosen scope, ranked locally."""
    use_mine = scope == "mine" and bool(mine)
    ids, labels = scope_filter(mine) if use_mine else ([], set())
    store = ",".join(ids) if ids else None
    errors = []

    def section(sort):
        try:
            reply = deals.store_deals(0, sort, store, None, refresh, installed, now, opener)
            if reply.get("error"):
                errors.append(reply["error"])
            return reply["deals"]
        except deals.DealsError as exc:
            errors.append(str(exc))
            return []

    featured = sorted(section("rating"), key=score, reverse=True)[:8]
    seen = {deal["id"] for deal in featured}
    drops = [deal for deal in section("recent") if deal["savings"] >= 50 and deal["id"] not in seen][:6]
    try:
        reply = deals.giveaways(None, "game", "popularity", refresh, now, opener)
        if reply.get("error"):
            errors.append(reply["error"])
        free = [item for item in reply["giveaways"] if not labels or in_scope(item, labels)][:6]
    except deals.DealsError as exc:
        errors.append(str(exc))
        free = []
    featured, drops = with_insights(featured, refresh, now, opener), with_insights(drops, refresh, now, opener)
    return {"scope": "mine" if use_mine else "all", "my_stores": mine, "featured": featured, "drops": drops,
            "free": free, "errors": list(dict.fromkeys(errors))}


def platform_status(platforms):
    """"mac" when Steam lists a macOS build, "windows" only when it lists Windows and explicitly no macOS build,
    otherwise None (unknown: no claim is made)."""
    if not isinstance(platforms, dict):
        return None
    if platforms.get("mac") is True:
        return "mac"
    if platforms.get("windows") is True and platforms.get("mac") is False:
        return "windows"
    return None


# Steam categories that matter on a couch: several people on one Mac.
COUCH_CATEGORIES = {"Shared/Split Screen", "Shared/Split Screen PvP", "Shared/Split Screen Co-op",
                    "Local Co-op", "Local Multi-Player", "Local Multiplayer", "Remote Play Together"}
STORAGE = re.compile(r"(?:Storage|Hard Drive|Hard Disk Space|Disk Space)\s*:?\s*(?:</strong>)?\s*([\d.,]+)\s*(GB|MB|TB)", re.I)


def plain_text(html):
    """Steam's short description is HTML; keep only its text."""
    text = re.sub(r"<[^>]+>", " ", html or "")
    for entity, value in (("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")):
        text = text.replace(entity, value)
    return " ".join(text.split())


def storage_bytes(requirements):
    """Disk space from Steam's minimum requirements ("Storage: 8 GB available space"); None when not stated."""
    for block in requirements:
        text = block.get("minimum") if isinstance(block, dict) else None
        match = STORAGE.search(text) if isinstance(text, str) else None
        if match:
            amount = float(match.group(1).replace(",", "."))
            return int(amount * {"MB": 1024 ** 2, "GB": 1024 ** 3, "TB": 1024 ** 4}[match.group(2).upper()])
    return None


def steam_details(app_id, refresh=False, now=None, opener=None):
    """Store facts for a Steam game's Cube Shop page: screenshots, description, genres, developer, release date,
    disk space, controller support and couch (local multiplayer) features. Cached for a week."""
    app_id = str(app_id or "")
    if not re.fullmatch(r"\d{1,10}", app_id) or app_id == "0":
        raise ShopError("Unknown Steam game.")
    url = STEAM_APPDETAILS + urllib.parse.urlencode({"appids": app_id, "l": "english"})
    reply = deals.cached_fetch("steamdetails", "steam", url, STEAM_HOSTS, refresh, now, opener)
    data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
    game = data.get(app_id) if isinstance(data.get(app_id), dict) else {}
    details = game.get("data") if game.get("success") is True and isinstance(game.get("data"), dict) else None
    if details is None:
        return {"app_id": app_id, "found": False, "error": reply.get("error")}

    def names(key, field="description"):
        items = details.get(key) if isinstance(details.get(key), list) else []
        values = [item.get(field) if isinstance(item, dict) else item for item in items]
        return [" ".join(value.split()) for value in values if isinstance(value, str) and value.strip()]

    screenshots = []
    for shot in details.get("screenshots") or []:
        link = deals.https_url(shot.get("path_full")) if isinstance(shot, dict) else None
        if link:
            screenshots.append(link)
    platforms = details.get("platforms") if isinstance(details.get("platforms"), dict) else {}
    requirements = [details.get("mac_requirements") if platforms.get("mac") is True else None, details.get("pc_requirements")]
    release = details.get("release_date") if isinstance(details.get("release_date"), dict) else {}
    controller = details.get("controller_support")
    return {"app_id": app_id, "found": True, "description": plain_text(details.get("short_description"))[:600],
            "genres": names("genres")[:4], "developers": names("developers", None)[:2],
            "release": release.get("date") if isinstance(release.get("date"), str) else None,
            "screenshots": screenshots[:12], "storage_bytes": storage_bytes([r for r in requirements if r]),
            "controller": controller if controller in ("full", "partial") else None,
            "couch": [name for name in names("categories") if name in COUCH_CATEGORIES],
            "error": reply.get("error")}


def steam_platform_url(app_id):
    return STEAM_APPDETAILS + urllib.parse.urlencode({"appids": app_id, "filters": "platforms"})


def steam_platforms(app_ids, refresh=False, now=None, opener=None, limit=PLATFORM_LOOKUPS):
    """Platform builds per Steam app from Steam's own store data, cached for a week. Only `limit` uncached games are
    looked up per call; the rest are returned as pending so the next call continues. CheapShark and GamerPower carry
    no platform data, so games without a Steam app ID stay unknown."""
    ids = list(dict.fromkeys(str(value) for value in app_ids if re.fullmatch(r"\d{1,10}", str(value)) and str(value) != "0"))
    result, pending, error, lookups = {}, [], None, 0
    for app_id in ids:
        url = steam_platform_url(app_id)
        entry = deals.read_cache(deals.cache_path("platforms", url))
        fresh = bool(entry) and (deals.time.time() if now is None else now) - entry["fetched"] < deals.FRESH_SECONDS["platforms"]
        if fresh or (entry and (lookups >= limit or error)):
            reply = entry
        elif lookups >= limit or error:
            pending.append(app_id)
            continue
        else:
            lookups += 1
            try:
                reply = deals.cached_fetch("platforms", "steam", url, STEAM_HOSTS, refresh, now, opener)
            except deals.DealsError as exc:
                error = str(exc)
                pending.append(app_id)
                continue
            error = error or reply.get("error")
        data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
        game = data.get(app_id) if isinstance(data.get(app_id), dict) else {}
        details = game.get("data") if game.get("success") is True and isinstance(game.get("data"), dict) else {}
        platforms = details.get("platforms") if isinstance(details.get("platforms"), dict) else {}
        builds = {key: platforms[key] for key in ("mac", "windows", "linux") if isinstance(platforms.get(key), bool)}
        result[app_id] = {**builds, "status": platform_status(builds)}
    return {"platforms": result, "pending": pending, "error": error}

