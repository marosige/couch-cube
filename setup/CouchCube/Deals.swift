import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


struct StoreDeal: Decodable, Equatable {
    let id: String
    let title: String
    let salePrice: Double
    let normalPrice: Double?
    let savings: Int
    let store: String?
    let dealRating: Double?
    let steamRating: String?
    let steamRatingPercent: Int?
    let metacritic: Int?
    let steamAppId: String?
    let installed: Bool
    let thumb: String?
    let url: String
    var gameId: String? = nil
}

struct DealStore: Decodable, Equatable {
    let id: String
    let name: String
}

struct StoreDealsReply: Decodable {
    let page: Int
    let more: Bool
    let stores: [DealStore]
    let deals: [StoreDeal]
    let fetched: Double
    let stale: Bool
    let error: String?
    var myStores: [ShopStoreRef]? = nil
}

/// Deal end dates. Only GamerPower giveaways carry one ("end_date"); CheapShark's deal list and deal lookup
/// have no end date, so store deals never show a countdown. GamerPower doesn't say which time zone its
/// "YYYY-MM-DD HH:MM:SS" uses, so it is read as UTC.
enum DealExpiry {
    static func parseGamerPowerEnd(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return format == "yyyy-MM-dd" ? date.addingTimeInterval(86_399) : date
            }
        }
        return nil
    }

    /// Whole local calendar days from today to the end day; nil once it has ended.
    static func daysLeft(until end: Date, now: Date, calendar: Calendar = .current) -> Int? {
        guard end > now else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day
    }

    static func label(until end: Date, now: Date, calendar: Calendar = .current) -> (text: String, urgent: Bool)? {
        guard let days = daysLeft(until: end, now: now, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: end) == calendar.component(.year, from: now) ? "d MMMM" : "d MMMM yyyy"
        let text = "Offer ends " + (days == 0 ? "today" : days == 1 ? "tomorrow" : formatter.string(from: end))
        return (text, days <= 2)
    }

    /// 09:00 local on the day before the end day. If that has passed: 09:00 today when still ahead,
    /// otherwise a few minutes from now. nil when even that would be after the end.
    static func reminderDate(for end: Date, now: Date, calendar: Calendar = .current) -> (date: Date, adjusted: Bool)? {
        guard end > now else { return nil }
        let endDay = calendar.startOfDay(for: end)
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: endDay),
           let target = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore), target > now {
            return (target, false)
        }
        if let today = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now), today > now, today < end {
            return (today, true)
        }
        let minute = calendar.dateInterval(of: .minute, for: now.addingTimeInterval(5 * 60))?.start ?? now.addingTimeInterval(5 * 60)
        return minute < end ? (minute, true) : nil
    }
}

enum ReminderAccess { case notDetermined, granted, denied }

/// Reminders access goes through this so tests never write to the user's real Reminders.
protocol DealReminderStore: AnyObject {
    var access: ReminderAccess { get }
    func requestAccess(_ done: @escaping (Bool) -> Void)
    func add(title: String, notes: String, url: URL?, due: Date) throws -> String
    func exists(_ identifier: String) -> Bool
    func remove(_ identifier: String) throws
}

struct ReminderStoreError: LocalizedError {
    let errorDescription: String?
}

final class EventKitReminderStore: DealReminderStore {
    private let store = EKEventStore()

    var access: ReminderAccess {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined { return .notDetermined }
        if #available(macOS 14.0, *) { return status == .fullAccess ? .granted : .denied }
        return status == .authorized ? .granted : .denied
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { granted, _ in DispatchQueue.main.async { done(granted) } }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: finish)
        } else {
            store.requestAccess(to: .reminder, completion: finish)
        }
    }

    func add(title: String, notes: String, url: URL?, due: Date) throws -> String {
        guard let list = store.defaultCalendarForNewReminders() else {
            throw ReminderStoreError(errorDescription: "Reminders has no default list. Choose one in Reminders settings.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        reminder.notes = notes
        reminder.url = url
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        components.timeZone = TimeZone.current
        reminder.dueDateComponents = components
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func exists(_ identifier: String) -> Bool {
        store.calendarItem(withIdentifier: identifier) is EKReminder
    }

    func remove(_ identifier: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }
}

struct Giveaway: Decodable, Equatable {
    let id: String
    let title: String
    let worth: String?
    let type: String?
    let platforms: [String]
    let endDate: String?
    let users: Int?
    let thumb: String?
    let url: String
}

struct GiveawaysReply: Decodable {
    let giveaways: [Giveaway]
    let fetched: Double
    let stale: Bool
    let error: String?
    var myStores: [ShopStoreRef]? = nil
}

let cheapSharkHosts: Set<String> = ["www.cheapshark.com"]
let gamerPowerHosts: Set<String> = ["www.gamerpower.com"]
let youTubeHosts: Set<String> = ["www.youtube.com"]

/// Deals only ever open as https links on the services' own hosts (CheapShark forwards to the store itself).
func safeDealURL(_ value: String?, hosts: Set<String>? = nil) -> URL? {
    guard let value, value.count <= 2048, !value.contains(where: { $0.isWhitespace }),
          let components = URLComponents(string: value), components.scheme == "https",
          let host = components.host?.lowercased(), !host.isEmpty,
          components.user == nil, components.password == nil, components.port == nil || components.port == 443,
          hosts.map({ $0.contains(host) }) ?? true else { return nil }
    return components.url
}

func dealPrice(_ value: Double) -> String {
    value == 0 ? "Free" : String(format: "$%.2f", value)
}

func decodeDeals<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(type, from: data)
}

let appStoreHosts: Set<String> = ["apps.apple.com"]

// MARK: Cube Shop models (replies from scripts/shop.py, wishlist.py and rates.py)
