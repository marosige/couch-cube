import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


struct Drive: Decodable {
    let id: String
    let uuid: String
    let mode: String
    let name: String
    let root: String
    let filesystem: String
    let free: Int64
    let mount: String
}

struct Assessment: Decodable {
    let state: String
    let issues: [String]
    let notes: [String]
    let missing: [String]
    var preferred_frontend: String? = nil
}

struct StorageStatus: Decodable {
    struct Location: Decodable {
        let drive: Drive
        let configured: Bool
        let issue: String?
        var environment: String? = nil
        var total: Int64? = nil
    }
    struct Active: Decodable { let id: String; let uuid: String }
    let locations: [Location]
    let active: Active?
    let transfer: LibraryTransferResult?
}

struct LibraryTransferPlan: Decodable {
    let source: Drive
    let destination: Drive
    let bytes: Int64
    let token: String
}

struct LibraryTransferResult: Decodable {
    let source: String
    let destination: String
    let token: String
}

struct RetiredLibrary: Decodable { let path: String }

/// One drive's library, capacity and games, read without changing the active library.
struct DriveDetail: Decodable {
    struct Capacity: Decodable { let total: Int64; let used: Int64; let free: Int64; let couch: Int64 }
    struct SteamFolder: Decodable { let path: String; let games: [SteamGame] }
    struct RetroSystem: Decodable { let id: String; let name: String; let games: Int; let path: String }
    let drive: Drive
    let environment: String
    let issue: String?
    let active: Bool
    let capacity: Capacity
    let steam: [SteamFolder]
    let retro: [RetroSystem]
    let errors: [String]
}

final class SmokeScanLog { var calls: [(String, (Int32, Data) -> Void)] = [] }

/// Per-game storage on one drive from `drive-games`; sizes are allocated bytes, nil when nothing could be read.
struct DriveGames: Decodable {
    struct Item: Decodable {
        let id: String
        let kind: String
        let source: String
        let sourceName: String
        let name: String
        let system: String?
        let systemName: String?
        let bytes: Int64?
        let measured: Bool
        let unreadable: Int
        let path: String
    }
    struct Coverage: Decodable { let source: String; let name: String; let status: String; let games: Int; let note: String? }
    struct Identity: Decodable { let id: String; let uuid: String }
    let drive: Identity
    let items: [Item]
    let coverage: [Coverage]
    let total: Int64
    let unknown: Int
    let partial: Int
    let shared: Int64
    let errors: [String]

    static func decode(_ data: Data) -> DriveGames? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(DriveGames.self, from: data)
    }
}

/// One bar segment and list row. Grouping is presentation only and always derived from the cached scan.
struct GameStorageSlice: Equatable {
    let id: String
    let title: String
    let detail: String
    let bytes: Int64?
    let games: Int
    let unknown: Int
    let partial: Bool
    /// Share of the known total in tenths of a percent; all known slices add up to exactly 1000.
    var tenths = 0

    static func launcherTitle(_ source: String, _ name: String) -> String {
        source == "bottle" ? "Windows bottles (launcher unknown)" : name + " games"
    }

    /// "Other <system> files" rows below this size are left out of the list (display only; the system total keeps them).
    static let otherFilesMinimum: Int64 = 1 << 20

    static func isNegligibleOther(_ item: DriveGames.Item) -> Bool {
        item.id.hasSuffix(":*other") && item.bytes.map { $0 < otherFilesMinimum } == true
    }

    static func slices(_ games: DriveGames, romsBySystem: Bool, pcByLauncher: Bool) -> [GameStorageSlice] {
        var order: [String] = []
        var groups: [String: [DriveGames.Item]] = [:]
        for item in games.items {
            let key: String
            if item.kind == "rom" && romsBySystem { key = "system:" + (item.system ?? "?") }
            else if isNegligibleOther(item) { continue }
            else if item.kind != "rom" && pcByLauncher { key = "launcher:" + item.source }
            else { key = "item:" + item.id }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        var slices = order.map { key -> GameStorageSlice in
            let members = groups[key]!
            let known = members.compactMap(\.bytes)
            let unknown = members.count - known.count
            let partial = members.contains { $0.unreadable > 0 }
            let first = members[0]
            if key.hasPrefix("item:") {
                let detail = first.kind == "rom" ? (first.systemName ?? "ROM") : first.sourceName + (first.measured ? "" : " · reported by Steam")
                return GameStorageSlice(id: key, title: first.name, detail: detail, bytes: first.bytes, games: 1,
                                        unknown: unknown, partial: first.unreadable > 0)
            }
            let title = first.kind == "rom" ? (first.systemName ?? "ROMs") + " ROMs" : launcherTitle(first.source, first.sourceName)
            let count = members.count == 1 ? "1 item" : "\(members.count) items"
            return GameStorageSlice(id: key, title: title, detail: count, bytes: known.isEmpty ? nil : known.reduce(0, +),
                                    games: members.count, unknown: unknown, partial: partial)
        }
        slices.sort { ($0.bytes ?? -1, $1.title) > ($1.bytes ?? -1, $0.title) }
        let total = slices.compactMap(\.bytes).reduce(0, +)
        guard total > 0 else { return slices }
        // Largest remainder keeps rounded shares adding up to 100.0%.
        var remainders: [(Int, Int64)] = []
        var assigned = 0
        for index in slices.indices {
            guard let bytes = slices[index].bytes else { continue }
            let scaled = bytes * 1000
            slices[index].tenths = Int(scaled / total)
            assigned += slices[index].tenths
            remainders.append((index, scaled % total))
        }
        for (index, _) in remainders.sorted(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }).prefix(1000 - assigned) {
            slices[index].tenths += 1
        }
        return slices
    }

    var percent: String {
        guard bytes != nil else { return "—" }
        if tenths == 0 { return (bytes ?? 0) > 0 ? "<0.1%" : "0%" }
        return String(format: "%.1f%%", Double(tenths) / 10)
    }
}

/// Segmented bar for game shares; drawn like the capacity bar, with a few calm colors and one gray "Other" segment.
final class GameStorageBar: NSView {
    static let colors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemIndigo, .systemYellow]
    static let colored = 8
    var accessibilityPrefix = "Game storage"
    var segments: [(title: String, bytes: Int64, color: NSColor)] = [] {
        didSet { needsDisplay = true; updateToolTips() }
    }

    static func segments(for slices: [GameStorageSlice]) -> [(title: String, bytes: Int64, color: NSColor)] {
        let known = slices.filter { ($0.bytes ?? 0) > 0 }
        var result = known.prefix(colored).enumerated().map { (title: $1.title, bytes: $1.bytes!, color: colors[$0]) }
        let rest = known.dropFirst(colored)
        if !rest.isEmpty {
            result.append((title: "Other (\(rest.count))", bytes: rest.compactMap(\.bytes).reduce(0, +), color: .tertiaryLabelColor))
        }
        return result
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 14) }
    override var isFlipped: Bool { true }

    private func rects() -> [NSRect] {
        let total = segments.map(\.bytes).reduce(0, +)
        guard total > 0 else { return [] }
        let gap: CGFloat = segments.count > 1 ? 1.5 : 0
        let usable = bounds.width - gap * CGFloat(segments.count - 1)
        var x: CGFloat = 0
        return segments.map { segment in
            let width = max(2, usable * CGFloat(segment.bytes) / CGFloat(total))
            defer { x += width + gap }
            return NSRect(x: x, y: 0, width: min(width, max(bounds.width - x, 0)), height: bounds.height)
        }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (rect, segment) in zip(rects(), segments) {
            addToolTip(rect, owner: segment.title + " · " + ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file) as NSString, userData: nil)
        }
    }

    override func layout() { super.layout(); updateToolTips() }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        clip.fill()
        clip.addClip()
        for (rect, segment) in zip(rects(), segments) {
            segment.color.setFill()
            rect.fill()
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        accessibilityPrefix + ": " + segments.map { $0.title + " " + ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) }.joined(separator: ", ")
    }
}

struct DriveRemovalPlan: Decodable { let path: String; let bytes: Int64; let files: Int; let token: String }

struct StorageOverviewEntry: Equatable {
    let id: String?
    let mode: String
    let title: String
    let state: String
    let active: Bool
    let path: String?
}

struct FrontendPreference: Decodable {
    let preferred: String?
}

struct CleanupItem: Decodable {
    let id: String
    let name: String
    let category: String
    let path: String
}

struct CleanupPlan: Decodable {
    let items: [CleanupItem]
    let token: String
}

struct CleanupTargets: Decodable {
    let paths: [String]
}

struct SteamLibraryReport: Decodable {
    let libraries: [SteamLibrary]
    let errors: [String]
}

struct SteamLibrary: Decodable {
    let path: String
    let available: Bool
    let games: [SteamGame]
}

struct SteamGame: Decodable {
    let appid: String
    let name: String
    let state: String
    let installed: Bool
    let bytes: Int64?
}

struct PhysicalDisk: Decodable {
    let device: String
    let model: String
    let size: Int64
}

struct ErasePlan: Decodable {
    let device: String
    let model: String
    let size: Int64
    let token: String
}

struct UpdateReport: Decodable {
    let version: String
    let available: Bool
    let url: String
}

struct AutoLaunchSettings: Decodable {
    let enabled: Bool
    let delay: Int
    let legacy: Bool
    var always: Bool? = nil
}

struct ManagedApp: Decodable {
    let id: String
    let name: String
    let installed: Bool
    let path: String
    let version: String
    let managed: Bool
    let update: String?
    let manual: Bool
    let brew: Bool
    let url: String?
}

struct ConsoleSystem: Decodable {
    let id: String
    let name: String
    var enabled: Bool
    let package: String
    let requirement: String
    let bios: BIOSStatus?
    var emulator_installed: Bool? = nil
}

struct BIOSStatus: Decodable {
    let state: String
    let summary: String
    let files: [BIOSFileStatus]
}

struct BIOSFileStatus: Decodable {
    let filename: String
    let path: String
    let present: Bool
    let note: String
}
