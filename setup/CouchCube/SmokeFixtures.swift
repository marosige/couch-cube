import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


let smokeStoreDealsJSON = """
{"source":"cheapshark","page":0,"pages":2,"more":true,"stores":[{"id":"1","name":"Steam"},{"id":"7","name":"GOG"}],
 "deals":[{"id":"abc","title":"Portal 2","sale_price":1.99,"normal_price":9.99,"savings":80,"store_id":"1","store":"Steam",
  "deal_rating":9.4,"steam_rating":"Overwhelmingly Positive","steam_rating_percent":98,"metacritic":95,"steam_app_id":"620",
  "installed":true,"thumb":"https://shared.akamai.steamstatic.com/portal2.jpg","url":"https://www.cheapshark.com/redirect?dealID=abc"},
  {"id":"lng","title":"The Elder Scrolls V: Skyrim Special Edition – Anniversary Edition Upgrade Bundle","sale_price":4.99,
  "normal_price":39.99,"savings":88,"store_id":"7","store":"GOG","deal_rating":7.2,"steam_rating":"Very Positive","steam_rating_percent":85,
  "metacritic":null,"steam_app_id":null,"installed":false,"thumb":null,"url":"https://www.cheapshark.com/redirect?dealID=lng"},
  {"id":"mc","title":"Critics Pick","sale_price":12.49,"normal_price":12.49,"savings":0,"store_id":"1","store":"Steam",
  "deal_rating":null,"steam_rating":null,"steam_rating_percent":null,"metacritic":71,"steam_app_id":null,
  "installed":false,"thumb":null,"url":"https://www.cheapshark.com/redirect?dealID=mc"},
  {"id":"def","title":"Unsafe Link","sale_price":0,"normal_price":4.99,"savings":100,"store_id":"7","store":"GOG",
  "deal_rating":null,"steam_rating":null,"steam_rating_percent":null,"metacritic":null,"steam_app_id":null,
  "installed":false,"thumb":null,"url":"https://evil.example/redirect?dealID=def"}],
 "fetched":1700000000,"cached":true,"stale":false,"error":null}
"""
let smokeGiveawaysJSON = """
{"source":"gamerpower","giveaways":[{"id":"1","title":"Free Adventure","worth":"$19.99","type":"Game","platforms":["PC","Epic Games Store"],
 "end_date":"2030-01-01","users":10,"description":"","thumb":null,"url":"https://www.gamerpower.com/open/free-adventure","info_url":null}],
 "fetched":1700000000,"cached":true,"stale":false,"error":null}
"""
let smokeShopHomeJSON = """
{"scope":"mine","my_stores":[{"key":"steam","name":"Steam"}],
 "featured":[{"id":"abc","title":"Portal 2","sale_price":1.99,"normal_price":9.99,"savings":80,"store_id":"1","store":"Steam",
  "deal_rating":9.4,"steam_rating":"Overwhelmingly Positive","steam_rating_percent":98,"metacritic":95,"steam_app_id":"620","game_id":"612",
  "installed":true,"thumb":null,"url":"https://www.cheapshark.com/redirect?dealID=abc"}],
 "drops":[{"id":"ghi","title":"Drop Game","sale_price":4.99,"normal_price":19.99,"savings":75,"store_id":"1","store":"Steam",
  "deal_rating":8.1,"steam_rating":null,"steam_rating_percent":null,"metacritic":null,"steam_app_id":"700","game_id":"700",
  "installed":false,"thumb":"https://cdn.example.com/drop.jpg","url":"https://www.cheapshark.com/redirect?dealID=ghi"}],
 "free":[{"id":"1","title":"Free Adventure","worth":"$19.99","type":"Game","platforms":["PC","Epic Games Store"],
  "end_date":"2030-01-01","users":10,"thumb":null,"url":"https://www.gamerpower.com/open/free-adventure"}],
 "errors":[]}
"""
let smokeShopSearchJSON = """
{"query":"hollow knight","currency":"USD","errors":[],
 "games":[{"id":"100","title":"Hollow Knight","steam_app_id":"367520","thumb":null,
   "offers":[{"store_id":"7","store":"GOG","price":9.99,"normal_price":14.99,"savings":33,"currency":"USD","url":"https://www.cheapshark.com/redirect?dealID=g1","cheapest":true},
             {"store_id":"1","store":"Steam","price":14.99,"normal_price":14.99,"savings":0,"currency":"USD","url":"https://www.cheapshark.com/redirect?dealID=s1","cheapest":false}],
   "app_store_offer":{"id":"555","title":"Hollow Knight","price":3990,"currency":"HUF","formatted":"3 990 Ft","seller":"Team Cherry","thumb":null,
     "url":"https://apps.apple.com/hu/app/hollow-knight/id555","store":"App Store"},
   "insight":{"kind":"above","percent":25,"low":7.99,"currency":"USD","date":"2025-09-29"}},
  {"id":"200","title":"Hollow Knight: Silksong — Collector's Soundtrack Edition","steam_app_id":null,"thumb":null,
   "offers":[{"store_id":"1","store":"Steam","price":19.99,"normal_price":24.99,"savings":20,"currency":"USD","url":"https://www.cheapshark.com/redirect?dealID=ss","cheapest":true}],
   "app_store_offer":null,"insight":{"kind":"record","percent":null,"low":19.99,"currency":"USD","date":"2025-09-29"}}],
 "app_store":{"country":"HU","currency":"HUF","apps":[{"id":"777","title":"Hollow Pocket","price":1990,"currency":"HUF","formatted":"1 990 Ft",
   "seller":"Smoke Studio","thumb":null,"url":"https://apps.apple.com/hu/app/hollow-pocket/id777","store":"App Store"}]}}
"""
let smokeRatesJSON = """
{"base":"EUR","date":"2026-10-16","rates":{"EUR":"1","USD":"1.1253","HUF":"363.08","GBP":"0.84385"},"fetched":1700000000,"stale":false,
 "note":"ECB reference rate via Frankfurter, updated 2026-10-16; Revolut/bank rates may differ slightly."}
"""
let smokeSteamDetailsJSON = """
{"app_id":"620","found":true,"description":"The Perpetual Testing Initiative has been expanded to allow you to design co-op puzzles.",
 "genres":["Action","Adventure"],"platforms":["Mac","Windows","Linux"],"deck":"Verified","developers":["Valve"],"release":"18 Apr, 2011",
 "screenshots":["https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/620/ss_1.jpg",
                "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/620/ss_2.jpg"],
 "storage_bytes":8589934592,"controller":"full","couch":["Shared/Split Screen Co-op"],"error":null}
"""
