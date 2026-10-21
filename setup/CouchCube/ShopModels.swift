import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


struct ShopStoreRef: Decodable, Equatable {
    let key: String
    let name: String
}

/// One store's current price for a game (CheapShark prices are USD; App Store offers use their storefront currency).
struct ShopOffer: Decodable, Equatable {
    let storeId: String?
    let store: String
    let price: Double
    let normalPrice: Double?
    let savings: Int?
    let currency: String
    let url: String
}

struct AppStoreGame: Decodable, Equatable {
    let id: String
    let title: String
    let price: Double
    let currency: String
    let formatted: String?
    let seller: String?
    let thumb: String?
    let url: String

    var offer: ShopOffer {
        ShopOffer(storeId: nil, store: "Mac App Store", price: price, normalPrice: nil, savings: nil, currency: currency, url: url)
    }
}

/// How today's best PC store price compares with CheapShark's recorded all-time low (USD, every store it tracks).
/// Only the minimum is known, so "record" or "percent above" is all it can say; never rarity or an average.
struct PriceInsight: Decodable, Equatable {
    let kind: String
    let percent: Int?
    let low: Double
    let currency: String
    let date: String?

    var text: String {
        if kind == "record" { return "All-time low" }
        return percent.map { "\($0)% above all-time low" } ?? "Was free before"
    }

    var detail: String {
        let low = self.low == 0 ? "free" : String(format: "%.2f %@", self.low, currency)
        var dateText = ""
        if let date, let day = ISO8601DateFormatter.dayOnly.date(from: date) {
            dateText = " on " + DateFormatter.localizedString(from: day, dateStyle: .medium, timeStyle: .none)
        }
        return "Lowest price CheapShark has recorded across the PC stores it tracks: \(low)\(dateText). "
            + "Only the record low is known, not how often a game sells at a price."
    }
}

extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}

struct ShopGame: Decodable, Equatable {
    let id: String
    let title: String
    let steamAppId: String?
    let thumb: String?
    let offers: [ShopOffer]
    let appStoreOffer: AppStoreGame?
    var insight: PriceInsight? = nil
}

struct AppStoreGroup: Decodable, Equatable {
    let country: String
    let currency: String?
    let apps: [AppStoreGame]
}

struct ShopSearchReply: Decodable {
    let query: String
    let games: [ShopGame]
    let appStore: AppStoreGroup
    let errors: [String]
}

/// Steam's own platform flags for one game ("mac", "windows" = Windows only, nil = unknown).
struct SteamPlatforms: Decodable, Equatable {
    let mac: Bool?
    let windows: Bool?
    let status: String?
}

struct PlatformsReply: Decodable {
    let platforms: [String: SteamPlatforms]
    let pending: [String]
    let error: String?
}

/// What Cube Shop can say about running a game on this Mac. Only verified facts: no badge when unknown.
enum GameCompatibility: Equatable {
    case mac
    case windowsOnly
}

/// Steam-style "Sort by" orders shared by every Cube Shop list. Raw values are saved per list.
enum ShopSort: String, CaseIterable {
    case relevance, name, priceAsc = "price", priceDesc = "price-desc", discount, rating, added, endsSoon = "ends"

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .name: return "Name A\u{2013}Z"
        case .priceAsc: return "Lowest Price"
        case .priceDesc: return "Highest Price"
        case .discount: return "Biggest Discount"
        case .rating: return "Best Rating"
        case .added: return "Date Added"
        case .endsSoon: return "Ends Soon"
        }
    }
}

/// What a row can be sorted by; nil fields always sort last.
struct ShopSortFields {
    var title: String
    var price: Double? = nil
    var currency: String? = nil
    var discount: Double? = nil
    var rating: Double? = nil
    var added: Double? = nil
    var ends: Double? = nil
}

/// A stable sort: ties keep their original order, and missing values go last in either direction.
/// Prices compare converted (`convert` returns the amount in the Shop currency) or, without a Shop currency,
/// grouped by currency so dollars and forints never mix.
func shopSorted<T>(_ items: [T], by sort: ShopSort, convert: (Double, String) -> Double? = { _, _ in nil },
                   fields: (T) -> ShopSortFields) -> [T] {
    guard sort != .relevance else { return items }
    let keyed = items.enumerated().map { (index: $0.offset, item: $0.element, fields: fields($0.element)) }
    func order<V: Comparable>(_ a: V?, _ b: V?, descending: Bool) -> Bool? {
        switch (a, b) {
        case let (a?, b?): return a == b ? nil : (descending ? a > b : a < b)
        case (_?, nil): return true
        case (nil, _?): return false
        default: return nil
        }
    }
    func priceKey(_ f: ShopSortFields) -> (group: String, amount: Double)? {
        guard let price = f.price else { return nil }
        let code = f.currency ?? "USD"
        if let converted = convert(price, code) { return ("", converted) }
        return (code, price)
    }
    return keyed.sorted { a, b in
        let result: Bool?
        switch sort {
        case .relevance: result = nil
        case .name:
            let c = a.fields.title.localizedStandardCompare(b.fields.title)
            result = c == .orderedSame ? nil : c == .orderedAscending
        case .priceAsc, .priceDesc:
            let x = priceKey(a.fields), y = priceKey(b.fields)
            if let x, let y, x.group != y.group { result = x.group < y.group }
            else { result = order(x?.amount, y?.amount, descending: sort == .priceDesc) }
        case .discount: result = order(a.fields.discount, b.fields.discount, descending: true)
        case .rating: result = order(a.fields.rating, b.fields.rating, descending: true)
        case .added: result = order(a.fields.added, b.fields.added, descending: true)
        case .endsSoon: result = order(a.fields.ends, b.fields.ends, descending: false)
        }
        return result ?? (a.index < b.index)
    }.map(\.item)
}

struct WishlistBest: Decodable, Equatable {
    let price: Double
    let normalPrice: Double?
    let savings: Int
    let store: String?
    let currency: String
    let checked: Double?
}

/// A wishlist entry as stored on the Couch Cube drive: original prices and their currency only.
struct WishlistItem: Decodable, Equatable {
    let key: String
    let title: String
    let gameId: String?
    let steamAppId: String?
    let appStoreId: String?
    let added: Double?
    let targetPrice: Double?
    /// The currency the target was entered in (files from before this was saved used US dollars).
    let targetCurrency: String?
    /// An https artwork link; the image itself lives in the artwork cache, never in the wishlist file.
    let thumb: String?
    let best: WishlistBest?
    let onSale: Bool
    /// The backend's comparison without exchange rates (nil when the currencies differ); the app compares itself.
    let targetHit: Bool?
    let saleText: String?
    var insight: PriceInsight? = nil
}

struct WishlistReply: Decodable, Equatable {
    let items: [WishlistItem]
    let library: String?
    let readOnly: Bool
    let offline: Bool
    let note: String?
}

struct ShopHomeReply: Decodable {
    let scope: String
    let myStores: [ShopStoreRef]
    let featured: [StoreDeal]
    let drops: [StoreDeal]
    let free: [Giveaway]
    let errors: [String]
    let wishlist: WishlistReply?
}

/// ECB euro reference rates (Frankfurter) as decimal strings, so no binary rounding creeps in.
struct ExchangeRates: Decodable, Equatable {
    let base: String
    let date: String
    let rates: [String: String]
    let fetched: Double?
    let stale: Bool?
}

/// Display-only currency conversion. Prices are converted through EUR with Decimal math, an optional card/FX fee is
/// added, and the result is rounded to the target currency's minor units (HUF, JPY... have none).
enum ShopMoney {
    static let currencies = ["USD", "EUR", "HUF", "GBP", "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "HKD", "IDR", "ILS",
                             "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "ZAR"]
    static let zeroDecimal: Set<String> = ["HUF", "JPY", "KRW", "ISK", "IDR", "CLP", "VND"]
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func minorUnits(_ code: String) -> Int { zeroDecimal.contains(code) ? 0 : 2 }

    static func decimal(_ value: Double) -> Decimal { Decimal(string: String(value), locale: posix) ?? Decimal(value) }

    static func rounded(_ value: Decimal, places: Int) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, places, .plain)
        return output
    }

    static func convert(_ amount: Decimal, from source: String, to target: String, rates: ExchangeRates?, feePercent: Decimal = 0,
                        round: Bool = true) -> Decimal? {
        guard let table = rates?.rates,
              let from = table[source].flatMap({ Decimal(string: $0, locale: posix) }), from > 0,
              let to = table[target].flatMap({ Decimal(string: $0, locale: posix) }), to > 0,
              amount >= 0, feePercent >= 0, feePercent <= 20 else { return nil }
        if amount == 0 { return 0 }
        var result = amount / from * to
        if source != target { result *= 1 + feePercent / 100 }
        return round ? rounded(result, places: minorUnits(target)) : result
    }

    static func format(_ amount: Decimal, _ code: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code
        formatter.minimumFractionDigits = minorUnits(code)
        formatter.maximumFractionDigits = minorUnits(code)
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(code)"
    }

    /// "11.99 USD": the unconverted original, shown in tooltips and accessibility labels.
    static func plain(_ amount: Decimal, _ code: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = posix
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = minorUnits(code)
        formatter.maximumFractionDigits = minorUnits(code)
        return (formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)") + " " + code
    }
}

/// Reads a typed target price: spaces and currency signs are ignored; in currencies without decimals (HUF...) "." and ","
/// group thousands, otherwise "," is a decimal comma. nil for empty or invalid input.
func parseTargetPrice(_ raw: String, _ code: String) -> Double? {
    var text = raw.filter { $0.isNumber || $0 == "." || $0 == "," }
    if ShopMoney.minorUnits(code) == 0 {
        text = text.filter(\.isNumber)
    } else {
        text = text.replacingOccurrences(of: ",", with: ".")
    }
    guard let value = Double(text), value >= 0, value < 100_000_000 else { return nil }
    return value
}

/// A price ready for display: converted ("≈ 4 120 Ft") when a Shop currency is set, with the original kept for tooltips.
struct ShopPrice {
    let text: String
    let original: String
    let converted: Bool
    /// Comparable value in the display currency (nil when it couldn't be converted).
    let value: Decimal?
    var spoken: String { converted ? "\(text) (\(original))" : text }
}

/// Remote deal artwork: https only, no cookies, bounded size, cached in memory and in Couch Cube's cache folder.
let dealImageSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForRequest = 15
    configuration.httpAdditionalHeaders = ["User-Agent": "CouchCube/0.3 (+https://github.com/marosige/couch-cube)"]
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Couch Cube/deal-images")
    configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20, directory: folder)
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: configuration)
}()
let dealImageCache = NSCache<NSURL, NSImage>()
