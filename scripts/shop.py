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
            offers = [offer for offer in (normalize_offer(item, stores) for item in entry.get("deals") or []) if offer]
            games[game_id] = {"id": game_id, "title": " ".join(title.split()),
                              "steam_app_id": app_id if app_id.isdigit() and app_id != "0" else None,
                              "thumb": deals.https_url(info.get("thumb")), "offers": sorted_offers(offers)}
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
    return {"scope": "mine" if use_mine else "all", "my_stores": mine, "featured": featured, "drops": drops,
            "free": free, "errors": list(dict.fromkeys(errors))}
