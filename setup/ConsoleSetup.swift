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
        "Game storage: " + segments.map { $0.title + " " + ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) }.joined(separator: ", ")
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

enum ConsoleArtwork {
    static let groups: [(title: String, systems: [String])] = [
        ("Nintendo home consoles", ["nes", "snes", "n64", "gc", "wii", "wiiu", "switch"]),
        ("Nintendo handhelds", ["gb", "gbc", "gba"]),
        ("PlayStation", ["psx", "ps2", "psp", "ps3"]),
        ("SEGA", ["megadrive", "segacd", "dreamcast"])
    ]

    // Body colors follow each system's best-known retail edition. Very dark plastics are
    // lifted slightly in Dark Mode so the silhouette stays visible.
    static func color(for id: String) -> NSColor {
        let colors: (UInt32, UInt32)
        switch id {
        case "nes": colors = (0xC9C6BF, 0xD3D0C9)
        case "snes": colors = (0xC5C3CE, 0xCFCDD8)
        case "n64": colors = (0x2E3035, 0x62666F)
        case "gc": colors = (0x4E43A8, 0x7A6EDB)
        case "wii": colors = (0xEDEFF2, 0xF4F5F7)
        case "wiiu": colors = (0x27292E, 0x5E626B)
        case "switch": colors = (0x34363B, 0x5E6168)
        case "gb": colors = (0xC4C2B8, 0xCDCBC1)
        case "gbc": colors = (0xF2C318, 0xF5CB2E)
        case "gba": colors = (0x4B3BA8, 0x7666D6)
        case "psx": colors = (0xBEBFC3, 0xCACCD0)
        case "ps2", "psp", "ps3": colors = (0x23252B, 0x5A5E68)
        case "megadrive", "segacd": colors = (0x232428, 0x5B5E66)
        case "dreamcast": colors = (0xEEEDE8, 0xF3F2EE)
        default: return .secondaryLabelColor
        }
        return InterfacePalette.adaptive("Console-\(id)", light: colors.0, dark: colors.1)
    }

    static func accent(_ name: String) -> NSColor {
        switch name {
        case "red": return InterfacePalette.adaptive("Console-red", light: 0xD92B32, dark: 0xF0464C)
        case "purple": return InterfacePalette.adaptive("Console-purple", light: 0x6D4CB3, dark: 0x8E72D6)
        case "darkGray": return InterfacePalette.adaptive("Console-darkGray", light: 0x45464B, dark: 0x6B6D73)
        case "joyBlue": return InterfacePalette.adaptive("Console-joyBlue", light: 0x00A7DF, dark: 0x1CBDF0)
        case "joyRed": return InterfacePalette.adaptive("Console-joyRed", light: 0xF2434D, dark: 0xFF5A62)
        case "blue": return InterfacePalette.adaptive("Console-blue", light: 0x2766D0, dark: 0x4C8CF0)
        case "orange": return InterfacePalette.adaptive("Console-orange", light: 0xEE6A1F, dark: 0xFF7F33)
        default: return .secondaryLabelColor
        }
    }

    static func image(for id: String) -> NSImage {
        // Original hardware-inspired drawings, without manufacturer logos.
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat = 2) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                             xRadius: radius, yRadius: radius).stroke()
            }
            func line(_ points: [NSPoint]) {
                let path = NSBezierPath()
                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.line(to: point) }
                }
                path.stroke()
            }
            func stroke(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat) {
                line([NSPoint(x: x, y: y), NSPoint(x: endX, y: endY)])
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 2) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
            }
            func disc(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).stroke()
            }
            func pad(_ x: CGFloat, _ y: CGFloat) {
                stroke(x - 2, y, x + 2, y)
                stroke(x, y - 2, x, y + 2)
            }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.white.setStroke()
            color(for: id).setFill()
            var silhouettes: [NSBezierPath] = []
            func solid(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
                let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                                        xRadius: radius, yRadius: radius)
                path.fill()
                silhouettes.append(path)
            }
            func paint(_ color: String, _ rect: NSRect, clippedTo x: CGFloat, _ y: CGFloat,
                       _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                             xRadius: radius, yRadius: radius).addClip()
                accent(color).setFill()
                rect.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            switch id {
            case "nes":
                solid(3, 7, 26, 18, 2)
                paint("darkGray", NSRect(x: 3, y: 18, width: 26, height: 7), clippedTo: 3, 7, 26, 18, 2)
                paint("red", NSRect(x: 24, y: 20, width: 3, height: 3), clippedTo: 3, 7, 26, 18, 2)
            case "snes":
                solid(3, 9, 26, 16, 5); solid(9, 7, 14, 9, 2)
                paint("purple", NSRect(x: 7, y: 18, width: 7, height: 5), clippedTo: 3, 9, 26, 16, 5)
                paint("purple", NSRect(x: 18, y: 18, width: 7, height: 5), clippedTo: 3, 9, 26, 16, 5)
            case "n64":
                let body = NSBezierPath()
                body.move(to: NSPoint(x: 3, y: 24))
                for point in [(5, 13), (10, 10), (22, 10), (27, 13), (29, 24)] {
                    body.line(to: NSPoint(x: point.0, y: point.1))
                }
                body.close()
                body.fill()
                silhouettes.append(body)
            case "gc": solid(10, 3, 12, 9, 3); solid(6, 10, 20, 18, 3)
            case "wii":
                let body = NSBezierPath()
                body.move(to: NSPoint(x: 8, y: 27))
                for point in [(10, 5), (23, 3), (23, 27)] {
                    body.line(to: NSPoint(x: point.0, y: point.1))
                }
                body.close()
                body.fill()
                silhouettes.append(body)
                solid(6, 28, 20, 2, 1)
            case "wiiu": solid(6, 4, 22, 9, 3); solid(2, 16, 28, 13, 4)
            case "switch":
                solid(2, 7, 28, 18, 5)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 7, width: 28, height: 18),
                             xRadius: 5, yRadius: 5).addClip()
                accent("joyBlue").setFill()
                NSRect(x: 2, y: 7, width: 6, height: 18).fill()
                accent("joyRed").setFill()
                NSRect(x: 24, y: 7, width: 6, height: 18).fill()
                NSGraphicsContext.restoreGraphicsState()
            case "gb", "gbc": solid(7, 2, 18, 28, id == "gb" ? 2 : 5)
            case "gba": solid(1, 7, 30, 18, 7)
            case "psx": solid(2, 7, 28, 19, 3)
            case "ps2":
                solid(8, 3, 15, 26, 1); solid(5, 28, 22, 2, 1)
                paint("blue", NSRect(x: 19, y: 22, width: 3, height: 5), clippedTo: 8, 3, 15, 26, 1)
            case "psp": solid(1, 8, 30, 16, 7)
            case "ps3": solid(6, 3, 20, 26, 7)
            case "megadrive": solid(2, 8, 28, 18, 6)
            case "segacd": solid(2, 4, 28, 14, 4); solid(2, 20, 28, 9, 2)
            case "dreamcast":
                solid(3, 5, 26, 23, 4)
                accent("orange").setFill()
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 12.5, width: 5, height: 5)).fill()
            default: solid(4, 6, 24, 20, 4)
            }
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.white.setFill()
            let previousLineWidth = NSBezierPath.defaultLineWidth
            NSBezierPath.defaultLineWidth = 1.6
            defer { NSBezierPath.defaultLineWidth = previousLineWidth }
            switch id {
            case "nes":
                box(3, 7, 26, 18)
                stroke(3, 18, 29, 18)
                box(15, 10, 10, 5, 0)
                stroke(7, 22, 11, 22)
                dot(25, 21)
            case "snes":
                box(3, 9, 26, 16, 5)
                box(9, 7, 14, 9)
                stroke(12, 11, 20, 11)
                box(8, 19, 5, 3, 1)
                box(19, 19, 5, 3, 1)
            case "n64":
                line([NSPoint(x: 3, y: 24), NSPoint(x: 5, y: 13), NSPoint(x: 10, y: 10),
                      NSPoint(x: 22, y: 10), NSPoint(x: 27, y: 13), NSPoint(x: 29, y: 24),
                      NSPoint(x: 3, y: 24)])
                stroke(11, 13, 21, 13)
                for x in [7, 12, 18, 23] { dot(CGFloat(x), 20) }
            case "gc":
                box(6, 10, 20, 18, 3)
                solid(12, 5, 8, 4, 1)
                disc(10, 12, 12)
                dot(10, 25)
                dot(20, 25)
            case "wii":
                line([NSPoint(x: 8, y: 27), NSPoint(x: 10, y: 5), NSPoint(x: 23, y: 3),
                      NSPoint(x: 23, y: 27), NSPoint(x: 8, y: 27)])
                stroke(19, 8, 19, 22)
                dot(12, 8)
                stroke(6, 29, 26, 29)
            case "wiiu":
                box(6, 4, 22, 9, 3)
                stroke(14, 8, 25, 8)
                box(2, 16, 28, 13, 4)
                box(9, 19, 14, 7, 1)
                pad(5, 22)
                dot(26, 21)
            case "switch":
                box(2, 7, 28, 18, 5)
                box(9, 9, 14, 14, 1)
                stroke(8, 8, 8, 24)
                stroke(24, 8, 24, 24)
                dot(4, 11, 2.5)
                dot(26, 18, 2.5)
            case "gb", "gbc":
                box(7, 2, 18, 28, id == "gb" ? 2 : 5)
                box(10, 5, 12, id == "gb" ? 10 : 11, 1)
                pad(12, 22)
                dot(19, 21)
                dot(22, 19)
                if id == "gb" { stroke(16, 27, 20, 27) }
                else { stroke(17, 26, 21, 25); stroke(17, 28, 21, 27) }
            case "gba":
                box(1, 7, 30, 18, 7)
                box(10, 10, 12, 12, 1)
                pad(5, 16)
                dot(25, 16)
                dot(28, 13)
            case "psx":
                box(2, 7, 28, 19, 3)
                disc(9, 9, 14)
                dot(5, 11, 3)
                dot(25, 11, 3)
                box(7, 23, 6, 2, 0)
                box(19, 23, 6, 2, 0)
            case "ps2":
                box(8, 3, 15, 26, 1)
                stroke(18, 3, 18, 29)
                for y in [8, 12, 16, 20] { stroke(10, CGFloat(y), 16, CGFloat(y)) }
                stroke(21, 7, 21, 20)
                stroke(5, 29, 27, 29)
            case "psp":
                box(1, 8, 30, 16, 7)
                box(10, 10, 12, 12, 1)
                pad(5, 16)
                for point in [(26, 12), (24, 15), (28, 15), (26, 18)] {
                    dot(CGFloat(point.0), CGFloat(point.1), 1.5)
                }
                dot(5, 20, 1.5)
            case "ps3":
                box(6, 3, 20, 26, 7)
                stroke(20, 5, 20, 27)
                stroke(23, 10, 23, 21)
                stroke(10, 25, 16, 25)
            case "megadrive":
                box(2, 8, 28, 18, 6)
                disc(9, 10, 14)
                stroke(12, 13, 20, 13)
                box(5, 22, 7, 3, 1)
                box(20, 22, 7, 3, 1)
            case "segacd":
                box(2, 4, 28, 14, 4)
                disc(11, 6, 10)
                box(2, 20, 28, 9, 2)
                box(13, 22, 14, 5, 1)
                dot(6, 24)
            case "dreamcast":
                box(3, 5, 26, 23, 4)
                disc(8, 7, 16)
                stroke(11, 9, 21, 9)
                for x in [7, 12, 18, 23] { dot(CGFloat(x), 25) }
            default:
                box(4, 6, 24, 20, 4)
                pad(11, 16)
                dot(22, 15)
            }
            // A faint rim keeps white and black hardware readable on matching backgrounds.
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            for path in silhouettes {
                path.lineWidth = 0.9
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct PairedController {
    let name: String
    let address: String
    let connected: Bool
}

struct ControllerEntry: Codable {
    let id: String
    var name: String
    var connected: Bool
    var transport: String
    /// false = macOS reports a Bluetooth connection but no HID gamepad/joystick input device for it.
    var inputDetected: Bool? = nil
    /// Artwork model proven by HID vendor/product IDs; takes priority over name guesses.
    var model: String? = nil
    /// The controller's own Bluetooth address, read from the device itself over USB. Never stored or guessed.
    var hardwareAddress: String? = nil

    enum CodingKeys: String, CodingKey { case id, name, connected, transport, inputDetected, model }
    var connectionLabel: String {
        transport == "Wired" ? "USB" : transport
    }
}

struct ControllerCustomization: Codable {
    var name: String
    var color: String
    var artwork: String? = nil
}

enum ControllerArtwork {
    static let kinds = ["Automatic", "Xbox", "PS4 · DualShock 4", "PS5 · DualSense", "PlayStation", "Switch Pro Controller", "Joy-Con (L)", "Joy-Con (R)", "Joy-Con", "Nintendo", "Steam Controller", "8BitDo SN30 Pro", "8BitDo Micro", "8BitDo Pro 2", "8BitDo Ultimate", "8BitDo", "Generic"]

    static func kind(for entry: ControllerEntry, artwork: String?) -> String {
        kind(name: entry.name, preference: artwork.flatMap { $0 == "Automatic" ? nil : $0 } ?? entry.model)
    }

    static func kind(name: String, preference: String?) -> String {
        if let preference = preference, kinds.dropFirst().contains(preference) { return preference }
        let name = name.lowercased()
        let model = name.filter { $0.isLetter || $0.isNumber }
        if model.contains("sn30pro") { return "8BitDo SN30 Pro" }
        if name.contains("8bit") {
            if model.contains("micro") { return "8BitDo Micro" }
            if model.contains("pro2") { return "8BitDo Pro 2" }
            if model.contains("ultimate") { return "8BitDo Ultimate" }
            return "8BitDo"
        }
        if name.contains("xbox") { return "Xbox" }
        if model.contains("dualsense") || model.contains("ps5") { return "PS5 · DualSense" }
        if model.contains("dualshock4") || model.contains("ps4") { return "PS4 · DualShock 4" }
        if name.contains("dualshock") || name.contains("playstation") { return "PlayStation" }
        if model.contains("joyconl") { return "Joy-Con (L)" }
        if model.contains("joyconr") { return "Joy-Con (R)" }
        if model.contains("joycon") { return "Joy-Con" }
        if name.contains("pro controller") || model.contains("switchpro") { return "Switch Pro Controller" }
        if model.contains("steamcontroller") { return "Steam Controller" }
        if name.contains("nintendo") { return "Nintendo" }
        return "Generic"
    }

    /// Template line art (menus); `filledImage` adds the body color as a silhouette fill.
    static func image(_ kind: String) -> NSImage { draw(kind, fill: nil, line: .black, context: .black, rim: nil, boost: 0) }

    /// Body paths are closed silhouettes: the fill never leaves the outline. Details are strokes on top.
    /// Drawn in passes: rims and fills (flat or camo, clipped to each body), then the optional offset
    /// highlight ("double wall"), then the outline/detail ink, so lines are never covered by a fill.
    /// `context` inks strokes that sit outside the body (shoulder buttons, the faded partner Joy-Con) against the background.
    static func draw(_ kind: String, fill: NSColor?, camo: ControllerCamo? = nil, line: NSColor, context: NSColor,
                             rim: NSColor?, highlight: NSColor? = nil, boost: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 80, height: 52), flipped: true) { _ in
            // Device pixels per artwork unit at the size this representation is rendered.
            let scale = max(abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1), 0.01)
            var ink = line, ctx = context, drawFill = true, drawLines = false
            func render() {
                ink.setStroke()
                func shape(_ path: NSBezierPath, alpha: CGFloat = 1) {
                    let width = path.lineWidth
                    if drawFill {
                        guard alpha == 1 else { return }
                        if let rim = rim {
                            rim.setStroke()
                            path.lineWidth = width + 2.2
                            path.stroke()
                            path.lineWidth = width
                        }
                        if let camo = camo, ControllerCamo.patterned(atScale: scale) {
                            NSGraphicsContext.saveGraphicsState()
                            path.addClip()
                            camo.draw()
                            NSGraphicsContext.restoreGraphicsState()
                        } else if let fill = fill {
                            fill.setFill()
                            path.fill()
                        }
                        return
                    }
                    guard drawLines else { return }
                    (alpha == 1 ? ink : ctx.withAlphaComponent(alpha)).setStroke()
                    path.lineWidth = width + boost
                    path.stroke()
                    path.lineWidth = width
                }

                func stroke(_ points: [(CGFloat, CGFloat)]) {
                    let path = NSBezierPath()
                    path.lineWidth = 2 + boost
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    if let first = points.first {
                        path.move(to: NSPoint(x: first.0, y: first.1))
                        for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
                    }
                    if drawLines { path.stroke() }
                }
                func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                    let path = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    path.lineWidth = 1.8 + boost
                    if drawLines { path.stroke() }
                }
                func outside(_ points: [(CGFloat, CGFloat)]) {
                    guard drawLines else { return }
                    ctx.setStroke()
                    stroke(points)
                    ink.setStroke()
                }
                if ["8BitDo", "8BitDo SN30 Pro", "8BitDo Micro"].contains(kind) {
                    let micro = kind == "8BitDo Micro"
                    let body = NSBezierPath(roundedRect: NSRect(x: micro ? 10 : 5, y: micro ? 12 : 8,
                                                               width: micro ? 60 : 70, height: micro ? 28 : 36),
                                            xRadius: micro ? 8 : 17, yRadius: micro ? 8 : 17)
                    body.lineWidth = 2.3
                    shape(body)
                    stroke([(15, 23), (27, 23)])
                    stroke([(21, 17), (21, 29)])
                    if !micro {
                        circle(31, 35, 4)
                        circle(49, 35, 4)
                    }
                    if kind == "8BitDo SN30 Pro" {
                        outside([(12, 6), (26, 6)])
                        outside([(54, 6), (68, 6)])
                    }
                    stroke([(36, 22), (38, 22)])
                    stroke([(42, 22), (44, 22)])
                    for p in [(59.0, 17.0), (54, 22), (64, 22), (59, 27)] { circle(p.0, p.1, 1.8) }
                } else if kind == "Nintendo" {
                    // SNES-style "dog bone" pad as the default Nintendo outline.
                    let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 12, width: 72, height: 28), xRadius: 14, yRadius: 14)
                    body.lineWidth = 2.2
                    shape(body)
                    stroke([(12, 26), (24, 26)])
                    stroke([(18, 20), (18, 32)])
                    for p in [(62.0, 20.0), (56, 26), (68, 26), (62, 32)] { circle(p.0, p.1, 2.2) }
                    stroke([(32, 29), (36, 25)])
                    stroke([(42, 29), (46, 25)])
                    outside([(12, 8), (24, 8)])
                    outside([(56, 8), (68, 8)])
                } else if kind.hasPrefix("Joy-Con") {
                    /// One Joy-Con in an 18×46 box; the flat rail faces the partner, never joined to a grip.
                    func joyCon(left: Bool, x: CGFloat, scale: CGFloat, alpha: CGFloat) {
                        NSGraphicsContext.saveGraphicsState()
                        let transform = NSAffineTransform()
                        transform.translateX(by: x, yBy: 26 - 23 * scale)
                        transform.scale(by: scale)
                        transform.concat()
                        (alpha == 1 ? ink : ctx.withAlphaComponent(alpha)).setStroke()
                        func mx(_ value: CGFloat) -> CGFloat { left ? value : 18 - value }
                        let shell = NSBezierPath()
                        shell.move(to: NSPoint(x: mx(18), y: 0))
                        shell.line(to: NSPoint(x: mx(9), y: 0))
                        shell.curve(to: NSPoint(x: mx(0), y: 9), controlPoint1: NSPoint(x: mx(4), y: 0), controlPoint2: NSPoint(x: mx(0), y: 4))
                        shell.line(to: NSPoint(x: mx(0), y: 37))
                        shell.curve(to: NSPoint(x: mx(9), y: 46), controlPoint1: NSPoint(x: mx(0), y: 42), controlPoint2: NSPoint(x: mx(4), y: 46))
                        shell.line(to: NSPoint(x: mx(18), y: 46))
                        shell.close()
                        shell.lineWidth = 2
                        // The faded partner is ctx only, never colored: its shell color isn't known.
                        shape(shell, alpha: alpha)
                        (alpha == 1 ? ink : ctx.withAlphaComponent(alpha)).setStroke()
                        circle(mx(9), left ? 13 : 29, 4)
                        for (dx, dy) in [(0.0, -4.0), (-4, 0), (4, 0), (0, 4)] { circle(mx(9) + CGFloat(dx), (left ? 29 : 13) + CGFloat(dy), 1.4) }
                        stroke([(mx(12), 4), (mx(15), 4)])
                        if !left { stroke([(mx(13.5), 2.5), (mx(13.5), 5.5)]) }
                        circle(mx(9), 40, 1.4)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    switch kind {
                    case "Joy-Con (L)":
                        joyCon(left: true, x: 23, scale: 1, alpha: 1)
                        joyCon(left: false, x: 47, scale: 0.55, alpha: 0.5)
                    case "Joy-Con (R)":
                        joyCon(left: true, x: 23, scale: 0.55, alpha: 0.5)
                        joyCon(left: false, x: 39, scale: 1, alpha: 1)
                    default:
                        joyCon(left: true, x: 20, scale: 1, alpha: 1)
                        joyCon(left: false, x: 42, scale: 1, alpha: 1)
                    }
                } else if kind == "Steam Controller" {
                    // Current (2026) Steam Controller: D-pad/ABXY on top, two sticks, two square trackpads below.
                    let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 72, height: 40), xRadius: 14, yRadius: 14)
                    body.lineWidth = 2.3
                    shape(body)
                    stroke([(11, 15), (19, 15)])
                    stroke([(15, 11), (15, 19)])
                    for p in [(65.0, 11.0), (61, 15), (69, 15), (65, 19)] { circle(p.0, p.1, 1.5) }
                    circle(28, 18, 4.5)
                    circle(52, 18, 4.5)
                    for x in [11.0, 52.0] {
                        let pad = NSBezierPath(roundedRect: NSRect(x: x, y: 26, width: 17, height: 15), xRadius: 3, yRadius: 3)
                        pad.lineWidth = 1.6 + boost
                        if drawLines { pad.stroke() }
                    }
                    circle(40, 14, 1.6)
                } else {
                    let body = NSBezierPath()
                    body.lineWidth = 2.3
                    body.lineJoinStyle = .round
                    let dualSense = kind == "PS5 · DualSense"
                    body.move(to: NSPoint(x: dualSense ? 19 : 23, y: dualSense ? 5 : 8))
                    body.curve(to: NSPoint(x: 8, y: 42), controlPoint1: NSPoint(x: 8, y: 5), controlPoint2: NSPoint(x: 3, y: 30))
                    body.curve(to: NSPoint(x: 27, y: 37), controlPoint1: NSPoint(x: 12, y: 53), controlPoint2: NSPoint(x: 20, y: 43))
                    body.line(to: NSPoint(x: 53, y: 37))
                    body.curve(to: NSPoint(x: 72, y: 42), controlPoint1: NSPoint(x: 60, y: 43), controlPoint2: NSPoint(x: 68, y: 53))
                    body.curve(to: NSPoint(x: dualSense ? 61 : 57, y: dualSense ? 5 : 8), controlPoint1: NSPoint(x: 77, y: 30), controlPoint2: NSPoint(x: 72, y: 5))
                    body.close()
                    shape(body)
                    ink.setStroke()
                    let playStation = ["PlayStation", "PS4 · DualShock 4", "PS5 · DualSense"].contains(kind)
                    let symmetric = playStation || kind == "8BitDo Pro 2"
                    let padX: CGFloat = symmetric ? 22 : 31
                    let padY: CGFloat = symmetric ? 22 : 32
                    stroke([(padX - 5, padY), (padX + 5, padY)])
                    stroke([(padX, padY - 5), (padX, padY + 5)])
                    circle(symmetric ? 31 : 21, symmetric ? 33 : 20, 5)
                    circle(49, 33, 5)
                    for p in [(59.0, 16.0), (54, 21), (64, 21), (59, 26)] { circle(p.0, p.1, 1.8) }
                    if playStation {
                        if kind != "PlayStation" {
                            let touchpad = NSBezierPath(roundedRect: NSRect(x: dualSense ? 28 : 30, y: dualSense ? 8 : 12,
                                                                           width: dualSense ? 24 : 20, height: dualSense ? 13 : 10), xRadius: 3, yRadius: 3)
                            touchpad.lineWidth = 1.5 + boost
                            if drawLines { touchpad.stroke() }
                        }
                        if dualSense {
                            stroke([(16, 31), (22, 40)])
                            stroke([(64, 31), (58, 40)])
                        }
                    } else if kind == "Xbox" { circle(40, 16, 3) }
                    else if kind == "Switch Pro Controller" {
                        stroke([(33, 17), (37, 17)])
                        stroke([(43, 17), (47, 17)])
                        stroke([(45, 15), (45, 19)])
                    } else if kind == "8BitDo Ultimate" {
                        stroke([(34, 17), (36, 17)])
                        stroke([(44, 17), (46, 17)])
                        circle(40, 25, 2)
                        outside([(14, 7), (25, 7)])
                        outside([(55, 7), (66, 7)])
                    } else if kind == "8BitDo Pro 2" {
                        stroke([(36, 20), (38, 20)])
                        stroke([(42, 20), (44, 20)])
                        outside([(14, 6), (25, 6)])
                        outside([(55, 6), (66, 6)])
                    }
                }
            }
            render()
            drawFill = false
            drawLines = true
            if let highlight = highlight {
                // Offset by whole device pixels (1 px small, 2 px large) so the second wall stays crisp.
                let pixels = min(2, max(1, (scale * 0.5).rounded()))
                let offset = pixels / scale
                NSGraphicsContext.saveGraphicsState()
                let shift = NSAffineTransform()
                shift.translateX(by: offset, yBy: offset)
                shift.concat()
                ink = highlight
                ctx = .clear
                render()
                NSGraphicsContext.restoreGraphicsState()
                ink = line
                ctx = context
            }
            render()
            return true
        }
        image.isTemplate = fill == nil
        return image
    }

    private static var filledCache: [String: NSImage] = [:]

    /// Outline style for filled art. `.outline`: black lines on every body, light lines only on black bodies.
    /// `.doubleWall`: the same black lines on every body plus a subtle white copy offset by a device pixel or two.
    static var outlineStyle: ControllerOutlineStyle = .outline

    /// Filled art for `color` as seen in `appearance`, in `style`. Camo palette colors get a seeded camo fill.
    /// A faint rim is added when neither fill nor ink would separate the silhouette from the window background.
    static func filledImage(_ kind: String, color: NSColor, appearance: NSAppearance, highContrast: Bool,
                            style: ControllerOutlineStyle = outlineStyle) -> NSImage {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var resolved = NSColor.black
        var background = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .gray
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? (dark ? NSColor(white: 0.12, alpha: 1) : .white)
        }
        let ink = ControllerInk.choose(fill: resolved, background: background, dark: dark, highContrast: highContrast, style: style)
        let camo = ControllerCamo.matching(resolved)
        let key = [kind, ControllerInk.hex(resolved), ControllerInk.hex(background), "\(highContrast)", "\(style)",
                   camo?.name ?? "flat", "80x52"].joined(separator: "|")
        if let cached = filledCache[key] { return cached }
        let highlight: NSColor? = style == .doubleWall ? NSColor.white.withAlphaComponent(highContrast ? 1 : 0.7) : nil
        let image = draw(kind, fill: ink.fill, camo: camo, line: ink.line, context: ink.context, rim: ink.rim,
                         highlight: highlight, boost: highContrast ? 0.4 : 0)
        image.accessibilityDescription = kind
        filledCache[key] = image
        return image
    }

    /// Artwork choices grouped by company, matching the color menu's section headers.
    static let sections: [(String, [String])] = [
        ("Microsoft", ["Xbox"]),
        ("Sony", ["PS5 · DualSense", "PS4 · DualShock 4", "PlayStation"]),
        ("Nintendo", ["Switch Pro Controller", "Joy-Con (L)", "Joy-Con (R)", "Joy-Con", "Nintendo"]),
        ("Valve", ["Steam Controller"]),
        ("8BitDo", ["8BitDo SN30 Pro", "8BitDo Micro", "8BitDo Pro 2", "8BitDo Ultimate", "8BitDo"]),
        ("Other", ["Generic"])
    ]

    static func menu(selecting selected: String?) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.autoenablesItems = false
        let automatic = NSMenuItem(title: "Automatic", action: nil, keyEquivalent: "")
        automatic.representedObject = "Automatic"
        popup.menu?.addItem(automatic)
        for (section, kinds) in sections {
            popup.menu?.addItem(.separator())
            let header = NSMenuItem(title: section, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: section, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor])
            popup.menu?.addItem(header)
            for kind in kinds {
                let item = NSMenuItem(title: kind, action: nil, keyEquivalent: "")
                item.representedObject = kind
                item.indentationLevel = 1
                let icon = image(kind)
                icon.size = NSSize(width: 25, height: 16)
                item.image = icon
                popup.menu?.addItem(item)
            }
        }
        let wanted = selected.flatMap { kinds.contains($0) ? $0 : nil } ?? "Automatic"
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == wanted }) { popup.select(item) }
        return popup
    }

    static func selectedKind(in popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? "Automatic"
    }
}

/// Picks outline/detail ink for a filled controller body (WCAG relative luminance and contrast ratio).
enum ControllerOutlineStyle: String, CaseIterable {
    case outline, doubleWall
}

/// Discreet procedural camo for camo palette colors: original seeded blobs in a few close tones of the
/// edition's color, so it is identical on every render and at every size. Below `patterned(atScale:)`
/// the art falls back to the flat palette color, which is the camo's average tone.
struct ControllerCamo {
    let name: String
    let base: NSColor
    let tones: [NSColor]
    let seed: UInt64

    static func rgb(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let all: [ControllerCamo] = [
        ControllerCamo(name: "Gray Camouflage", base: rgb(0x7D8070), tones: [rgb(0x8D9081), rgb(0x6C6F61), rgb(0x5C5F53)], seed: 0x6A7C),
        ControllerCamo(name: "Mineral Camo", base: rgb(0x5E6B4A), tones: [rgb(0x707C5C), rgb(0x4F5B3E), rgb(0x6B6F62)], seed: 0x3F51)
    ]

    /// Exact palette match only; dimmed or composited variants stay flat.
    static func matching(_ color: NSColor) -> ControllerCamo? {
        guard let c = color.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { return nil }
        return all.first { camo in
            let b = camo.base.usingColorSpace(.sRGB)!
            return abs(b.redComponent - c.redComponent) < 0.004 && abs(b.greenComponent - c.greenComponent) < 0.004
                && abs(b.blueComponent - c.blueComponent) < 0.004
        }
    }

    /// Blobs are ~6–12 artwork units; under 0.75 device px per unit they would read as noise.
    static func patterned(atScale scale: CGFloat) -> Bool { scale >= 0.75 }

    /// Fills the current clip: base color, then smooth irregular blobs in each tone over the 80×52 art box.
    func draw() {
        base.setFill()
        NSRect(x: -10, y: -10, width: 100, height: 72).fill()
        var state = seed
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
        for tone in tones {
            tone.setFill()
            for _ in 0..<7 {
                let cx = -4 + next() * 88, cy = -4 + next() * 60
                let radius = 4 + next() * 4.5, stretch = 0.7 + next() * 0.8
                let count = 7
                var points: [NSPoint] = []
                for i in 0..<count {
                    let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
                    let r = radius * (0.65 + next() * 0.55)
                    points.append(NSPoint(x: cx + cos(angle) * r * stretch, y: cy + sin(angle) * r))
                }
                let path = NSBezierPath()
                func mid(_ a: NSPoint, _ b: NSPoint) -> NSPoint { NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
                path.move(to: mid(points[count - 1], points[0]))
                for i in 0..<count {
                    let p = points[i], q = points[(i + 1) % count]
                    path.curve(to: mid(p, q), controlPoint1: p, controlPoint2: p)
                }
                path.close()
                path.fill()
            }
        }
    }
}

enum ControllerInk {
    static let darkInk = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    static let lightInk = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)

    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Translucent colors (dimmed/disconnected states) become the opaque color they show over the window,
    /// so the fill is never see-through (also honoring Reduce Transparency).
    static func composite(_ color: NSColor, over background: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? .gray, b = background.usingColorSpace(.sRGB) ?? .white
        let a = c.alphaComponent
        return NSColor(srgbRed: c.redComponent * a + b.redComponent * (1 - a), green: c.greenComponent * a + b.greenComponent * (1 - a),
                       blue: c.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    /// Black and near-black neutral bodies only: very dark and essentially unsaturated.
    /// Dark but colored bodies (purple, cobalt, red…) are not black and keep black outlines.
    static func isNearBlack(_ color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        let high = max(c.redComponent, c.greenComponent, c.blueComponent)
        let low = min(c.redComponent, c.greenComponent, c.blueComponent)
        let saturation = high > 0 ? (high - low) / high : 0
        return luminance(c) < 0.03 && saturation < 0.35
    }

    /// Black outlines on every body color; only black/near-black bodies get light outlines.
    /// A rim is added only when neither the body nor its outline separates from the background by 3:1.
    /// In `.doubleWall` every body, black included, keeps black lines; the offset white wall carries the contrast.
    static func choose(fill: NSColor, background: NSColor, dark: Bool, highContrast: Bool, style: ControllerOutlineStyle = .outline)
        -> (fill: NSColor, line: NSColor, context: NSColor, rim: NSColor?) {
        let solid = composite(fill, over: background)
        let darkLine = highContrast ? NSColor.black : darkInk, lightLine = highContrast ? NSColor.white : lightInk
        let line = style == .outline && isNearBlack(solid) ? lightLine : darkLine
        let edge = max(contrast(solid, background), contrast(line, background))
        let rim: NSColor? = edge >= 3 ? nil : (dark ? NSColor.white.withAlphaComponent(highContrast ? 0.8 : 0.45)
                                                    : NSColor.black.withAlphaComponent(highContrast ? 0.7 : 0.35))
        let context = contrast(darkLine, background) >= contrast(lightLine, background) ? darkLine : lightLine
        return (solid, line, context, rim)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        return String(format: "%02X%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }
}

/// Controller art that fills itself with `contentTintColor` and re-renders on appearance or accessibility changes.
/// Without a tint it shows the plain template line art.
final class ControllerArtView: NSImageView {
    var kind: String { didSet { if kind != oldValue { render() } } }
    /// Nil follows `ControllerArtwork.outlineStyle`; the comparison sheet pins a style per view.
    var style: ControllerOutlineStyle? { didSet { render() } }
    private var observer: NSObjectProtocol?

    init(kind: String) {
        self.kind = kind
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.render()
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observer.map(NSWorkspace.shared.notificationCenter.removeObserver) }

    override var contentTintColor: NSColor? { didSet { render() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private func render() {
        image = contentTintColor.map {
            ControllerArtwork.filledImage(kind, color: $0, appearance: effectiveAppearance,
                                          highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                                          style: style ?? ControllerArtwork.outlineStyle)
        } ?? ControllerArtwork.image(kind)
    }
}

enum InterfacePalette {
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
}

enum ControllerPalette {
    struct Shade {
        let name: String
        let rgb: UInt32
        let brands: [String]
    }

    static let brands = ["PlayStation", "Xbox", "8BitDo", "Nintendo"]
    private static let all = brands

    static let sections: [(String, [Shade])] = [
        ("Black & White", [
            Shade(name: "Black", rgb: 0x1E1F24, brands: all),
            Shade(name: "White", rgb: 0xEFF0F2, brands: all)
        ]),
        ("Gray & Silver", [
            Shade(name: "Classic Gray", rgb: 0xA9A8A6, brands: ["8BitDo", "Nintendo"]),
            Shade(name: "Sterling Silver", rgb: 0xB6BBC2, brands: ["PlayStation"])
        ]),
        ("Camo", [
            Shade(name: "Gray Camouflage", rgb: 0x7D8070, brands: ["PlayStation"]),
            Shade(name: "Mineral Camo", rgb: 0x5E6B4A, brands: ["Xbox"])
        ]),
        ("Red & Orange", [
            Shade(name: "Cosmic Red", rgb: 0xB0102E, brands: ["PlayStation"]),
            Shade(name: "Volcanic Red", rgb: 0xD1261C, brands: ["PlayStation"]),
            Shade(name: "Pulse Red", rgb: 0xD7262E, brands: ["Xbox"]),
            Shade(name: "Neon Red", rgb: 0xFF3C28, brands: ["Nintendo"]),
            Shade(name: "Neon Orange", rgb: 0xFAA005, brands: ["Nintendo"])
        ]),
        ("Pink", [
            Shade(name: "Nova Pink", rgb: 0xF25F9C, brands: ["PlayStation"]),
            Shade(name: "Deep Pink", rgb: 0xE0347E, brands: ["Xbox"]),
            Shade(name: "Micro Pink", rgb: 0xF27BAE, brands: ["8BitDo"]),
            Shade(name: "Neon Pink", rgb: 0xFF3278, brands: ["Nintendo"])
        ]),
        ("Purple & Indigo", [
            Shade(name: "Galactic Purple", rgb: 0x5A3DA6, brands: ["PlayStation"]),
            Shade(name: "Chroma Indigo", rgb: 0x4B3FB0, brands: ["PlayStation"]),
            Shade(name: "Astral Purple", rgb: 0x7650C8, brands: ["Xbox"]),
            Shade(name: "Atomic Purple", rgb: 0x8E52C9, brands: ["8BitDo"]),
            Shade(name: "SN Purple", rgb: 0x6A5BAF, brands: ["8BitDo", "Nintendo"]),
            Shade(name: "GameCube Indigo", rgb: 0x524A9C, brands: ["Nintendo"]),
            Shade(name: "Neon Purple", rgb: 0xB400E6, brands: ["Nintendo"])
        ]),
        ("Blue & Teal", [
            Shade(name: "Starlight Blue", rgb: 0x4AA2DE, brands: ["PlayStation"]),
            Shade(name: "Cobalt Blue", rgb: 0x1E4FB0, brands: ["PlayStation"]),
            Shade(name: "Chroma Teal", rgb: 0x16A3A0, brands: ["PlayStation"]),
            Shade(name: "Shock Blue", rgb: 0x1E7FD8, brands: ["Xbox"]),
            Shade(name: "Micro Blue", rgb: 0x3D8EE0, brands: ["8BitDo"]),
            Shade(name: "Neon Blue", rgb: 0x0AB9E6, brands: ["Nintendo"])
        ]),
        ("Green & Yellow", [
            Shade(name: "Micro Green", rgb: 0x8FD42A, brands: ["8BitDo"]),
            Shade(name: "Velocity Green", rgb: 0x14A05A, brands: ["Xbox"]),
            Shade(name: "Electric Volt", rgb: 0xD4E82E, brands: ["Xbox"]),
            Shade(name: "Neon Green", rgb: 0x1EDC00, brands: ["Nintendo"]),
            Shade(name: "Neon Yellow", rgb: 0xE6FF00, brands: ["Nintendo"])
        ])
    ]

    private static func rgbColor(_ rgb: UInt32) -> NSColor {
        let red = CGFloat((rgb >> 16) & 255) / 255
        let green = CGFloat((rgb >> 8) & 255) / 255
        let blue = CGFloat(rgb & 255) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static let colors: [(String, NSColor)] = sections.flatMap { $0.1 }.map { (shade: Shade) -> (String, NSColor) in
        (shade.name, rgbColor(shade.rgb))
    }

    private static let legacyNames = [
        "Blue": "Starlight Blue", "Indigo": "Chroma Indigo", "Purple": "Galactic Purple",
        "Pink": "Nova Pink", "Green": "Velocity Green", "Red": "Pulse Red",
        "Orange": "Neon Orange", "Yellow": "Electric Volt", "Gray": "Sterling Silver",
        "Midnight Black": "Black", "Carbon Black": "Black", "Ultimate Black": "Black",
        "Glacier White": "White", "Robot White": "White", "Ultimate White": "White"
    ]

    /// Returns a palette name, or "" (Automatic) for empty/unknown values.
    static func canonicalName(_ name: String, for entry: ControllerEntry) -> String {
        if name.isEmpty || colors.contains(where: { $0.0 == name }) { return name }
        if legacyInferredName(for: entry) == "Micro Green" && name == "Green" { return "Micro Green" }
        return legacyNames[name] ?? ""
    }

    /// Before Automatic existed, Customize always stored the inferred default, so a saved value equal to it
    /// is treated as Automatic once. Anything else the user picked stays explicit.
    static func migratedName(_ name: String, for entry: ControllerEntry) -> String {
        let canonical = canonicalName(name, for: entry)
        return canonical == legacyInferredName(for: entry) ? "" : canonical
    }

    private static func tag(_ brand: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let width = ceil((brand as NSString).size(withAttributes: [.font: font]).width) + 10
        return NSImage(size: NSSize(width: width, height: 14), flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.quaternaryLabelColor.setFill()
            pill.fill()
            (brand as NSString).draw(at: NSPoint(x: 5, y: 1.5), withAttributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
    }

    /// `selected` "" selects Automatic, whose title shows the color it currently resolves to.
    static func menu(selecting selected: String, automatic: String? = nil) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.autoenablesItems = false
        if let automatic = automatic {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.representedObject = ""
            popup.menu?.addItem(item)
            setAutomatic(automatic, in: popup)
        }
        for (section, shades) in sections {
            if popup.numberOfItems > 0 { popup.menu?.addItem(.separator()) }
            let header = NSMenuItem(title: section, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: section, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor])
            popup.menu?.addItem(header)
            for shade in shades {
                let item = NSMenuItem(title: shade.name, action: nil, keyEquivalent: "")
                item.representedObject = shade.name
                item.image = swatch(color(named: shade.name))
                item.indentationLevel = 1
                let title = NSMutableAttributedString(string: shade.name + "  ",
                                                      attributes: [.font: NSFont.menuFont(ofSize: 0)])
                for brand in shade.brands.count == brands.count ? ["All brands"] : shade.brands {
                    let attachment = NSTextAttachment()
                    attachment.image = tag(brand)
                    attachment.bounds = NSRect(x: 0, y: -2, width: attachment.image!.size.width, height: 14)
                    title.append(NSAttributedString(attachment: attachment))
                    title.append(NSAttributedString(string: " "))
                }
                item.attributedTitle = title
                item.toolTip = "Fits " + shade.brands.joined(separator: ", ")
                popup.menu?.addItem(item)
            }
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            popup.select(item)
        }
        return popup
    }

    static func setAutomatic(_ name: String, in popup: NSPopUpButton) {
        guard let item = popup.itemArray.first(where: { $0.representedObject as? String == "" }) else { return }
        item.title = "Automatic (\(name))"
        item.image = swatch(color(named: name))
        item.toolTip = "Standard color for this controller model. Couch Cube can't read a controller's shell color."
        if popup.selectedItem === item { popup.synchronizeTitleAndSelectedItem() }
    }

    static func selectedName(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    /// The model's standard launch/marketing controller color. Couch Cube can't read a controller's shell color
    /// (no public macOS API, and the open DualSense/DualShock drivers expose no such field), so this is a default, not a detection.
    static func defaultName(forKind kind: String) -> String {
        switch kind {
        case "PS5 · DualSense": return "White"
        case "PS4 · DualShock 4", "PlayStation", "Xbox", "Switch Pro Controller", "Steam Controller", "8BitDo Ultimate", "Generic":
            return "Black"
        case "Joy-Con (L)": return "Neon Blue"
        case "Joy-Con (R)": return "Neon Red"
        case "8BitDo Micro": return "Micro Green"
        default: return "Classic Gray" // Joy-Con pair (gray launch set), SNES-style Nintendo, other 8BitDo
        }
    }

    static func defaultName(for entry: ControllerEntry, artwork: String? = nil) -> String {
        defaultName(forKind: ControllerArtwork.kind(for: entry, artwork: artwork))
    }

    /// Defaults Couch Cube used to fill in before Automatic existed; such saved values were never the user's own pick.
    static func legacyInferredName(for entry: ControllerEntry) -> String {
        switch ControllerArtwork.kind(name: entry.name, preference: entry.model) {
        case "8BitDo Micro": return "Micro Green"
        case "PS5 · DualSense": return "Chroma Indigo"
        case "Xbox", "PlayStation", "PS4 · DualShock 4": return "Black"
        case let kind where kind.hasPrefix("8BitDo"): return "Classic Gray"
        default: return "Shock Blue"
        }
    }

    /// An empty saved color means Automatic.
    static func resolvedName(_ saved: String?, for entry: ControllerEntry, artwork: String? = nil) -> String {
        if let saved = saved, !saved.isEmpty, colors.contains(where: { $0.0 == saved }) { return saved }
        return defaultName(for: entry, artwork: artwork)
    }

    static func color(named name: String) -> NSColor {
        colors.first { $0.0 == name }?.1 ?? colors[0].1
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let square = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 14, height: 14),
                                      xRadius: 3, yRadius: 3)
            color.setFill()
            square.fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            square.lineWidth = 0.5
            square.stroke()
            return true
        }
    }
}

/// Live preview in the customize sheet: the controller's art filled with the chosen color.
/// Purely visual; nothing is saved until the sheet's Save button is pressed.
final class ControllerCustomizationPreview: NSObject {
    let imageView = ControllerArtView(kind: "Generic")
    private(set) var iconFrame: ControllerIconFrame!
    let colorPopup: NSPopUpButton
    let artworkPopup: NSPopUpButton
    private let controllerName: String
    private let automaticModel: String?

    init(controllerName: String, automaticModel: String? = nil, colorPopup: NSPopUpButton, artworkPopup: NSPopUpButton) {
        self.controllerName = controllerName
        self.automaticModel = automaticModel
        self.colorPopup = colorPopup
        self.artworkPopup = artworkPopup
        super.init()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        iconFrame = ControllerIconFrame(imageView: imageView, size: NSSize(width: 88, height: 60), inset: 4)
        imageView.setAccessibilityLabel("Icon preview")
        for popup in [colorPopup, artworkPopup] {
            popup.target = self
            popup.action = #selector(update)
        }
        update()
    }

    var kind: String {
        let choice = ControllerArtwork.selectedKind(in: artworkPopup)
        return ControllerArtwork.kind(name: controllerName, preference: choice == "Automatic" ? automaticModel : choice)
    }

    /// The saved value: "" for Automatic.
    var savedColor: String { ControllerPalette.selectedName(in: colorPopup) ?? "" }

    var colorName: String {
        let saved = savedColor
        return saved.isEmpty ? ControllerPalette.defaultName(forKind: kind) : saved
    }

    @objc func update() {
        ControllerPalette.setAutomatic(ControllerPalette.defaultName(forKind: kind), in: colorPopup)
        let color = ControllerPalette.color(named: colorName)
        imageView.kind = kind
        imageView.contentTintColor = color
        imageView.setAccessibilityValue("\(kind), \(colorName)\(savedColor.isEmpty ? " (Automatic)" : "")")
    }
}

/// A fixed-size, transparent frame for controller line art: no background, just the icon.
/// It keeps row geometry fixed; the input pulse animates the inner image only.
final class ControllerIconFrame: NSView {
    let imageView: NSImageView

    init(imageView: NSImageView, size: NSSize, inset: CGFloat = 3) {
        self.imageView = imageView
        super.init(frame: NSRect(origin: .zero, size: size))
        identifier = NSUserInterfaceItemIdentifier("controller-icon-frame")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

func controllerAddress(_ value: String) -> String? {
    let address = value.lowercased().filter { $0.isHexDigit }
    return address.count == 12 ? address : nil
}

func hidControllerEntry(_ device: IOHIDDevice) -> ControllerEntry {
    func property(_ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString).map { String(describing: $0) } ?? ""
    }
    let transport = property(kIOHIDTransportKey)
    let serial = property(kIOHIDSerialNumberKey)
    var registryID: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
    let address = transport.hasPrefix("Bluetooth") ? controllerAddress(serial) : nil
    let location = property(kIOHIDLocationIDKey)
    let identity = !serial.isEmpty ? "serial:\(serial)" : !location.isEmpty && location != "0" ?
        "location:\(location)" : "session:\(registryID)"
    let id = address.map { "bt:\($0)" } ??
        "hid:\(property(kIOHIDVendorIDKey)):\(property(kIOHIDProductIDKey)):\(transport):\(identity)"
    let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
    var name = property(kIOHIDProductKey)
    if vendor == 0x057E, let side = joyConSide(product: product), !name.lowercased().contains("joy-con") { name = side }
    let hardwareAddress = transport == "USB" ? cachedSonyUSBBluetoothAddress(device, registryID: registryID,
                                                                             vendor: vendor, product: product) : nil
    return ControllerEntry(id: id, name: name.isEmpty ? "Game controller" : name,
        connected: true, transport: transport == "USB" ? "Wired" :
            transport.hasPrefix("Bluetooth") ? "Bluetooth" : "Wireless / Other",
        model: controllerModel(vendor: vendor, product: product, name: name), hardwareAddress: hardwareAddress)
}

/// Feature report that carries the pad's own Bluetooth address over USB (the same reports SDL/Steam read).
func sonyAddressReportID(vendor: Int?, product: Int?) -> UInt8? {
    guard vendor == 0x054C else { return nil }
    switch product {
    case 0x05C4, 0x09CC: return 0x12 // DualShock 4
    case 0x0CE6, 0x0DF2: return 0x09 // DualSense, DualSense Edge
    default: return nil
    }
}

/// macOS returns numbered feature reports with the report ID first, then the address in little-endian order.
func controllerAddressFromSonyReport(_ report: [UInt8], reportID: UInt8) -> String? {
    guard report.count >= 7, report[0] == reportID else { return nil }
    let bytes = report[1...6].reversed()
    guard bytes.contains(where: { $0 != 0 }), bytes.contains(where: { $0 != 0xFF }) else { return nil }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private let sonyAddressLock = NSLock()
private var sonyAddressCache: [UInt64: String] = [:]
private var sonyAddressAttempts: Set<UInt64> = []

/// Read once per plugged-in device; failures (no permission, unsupported firmware) simply leave no address.
func cachedSonyUSBBluetoothAddress(_ device: IOHIDDevice, registryID: UInt64, vendor: Int?, product: Int?) -> String? {
    guard let reportID = sonyAddressReportID(vendor: vendor, product: product) else { return nil }
    sonyAddressLock.lock()
    if sonyAddressAttempts.contains(registryID) {
        defer { sonyAddressLock.unlock() }
        return sonyAddressCache[registryID]
    }
    sonyAddressAttempts.insert(registryID)
    sonyAddressLock.unlock()
    guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    var buffer = [UInt8](repeating: 0, count: 64)
    buffer[0] = reportID
    var length = CFIndex(buffer.count)
    guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &length) == kIOReturnSuccess,
          let address = controllerAddressFromSonyReport(Array(buffer.prefix(max(0, length))), reportID: reportID)
    else { return nil }
    sonyAddressLock.lock()
    sonyAddressCache[registryID] = address
    sonyAddressLock.unlock()
    return address
}

func controllerInputDescription(page: UInt32, usage: UInt32, value: Int,
                                minimum: Int, maximum: Int) -> String? {
    if page == 9 {
        return value == 0 ? nil : "Button \(usage) pressed"
    }
    guard page == 1 else { return nil }
    if usage == 0x39 {
        return value >= minimum && value <= maximum ? "D-pad · Direction \(value - minimum + 1)" : nil
    }
    let axes: [UInt32: String] = [0x30: "X", 0x31: "Y", 0x32: "Z", 0x33: "RX", 0x34: "RY", 0x35: "RZ"]
    guard let axis = axes[usage], maximum > minimum else { return nil }
    let normalized = (Double(value) - Double(minimum)) / (Double(maximum) - Double(minimum))
    guard abs(normalized - 0.5) > 0.2 else { return nil }
    return "Stick / trigger \(axis) · \(Int(normalized * 100))%"
}

func connectedHIDControllers() -> [ControllerEntry] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matches = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
    }
    IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    var result: [String: ControllerEntry] = [:]
    for device in devices {
        let entry = hidControllerEntry(device)
        result[entry.id] = entry
    }
    return result.values.sorted { $0.id < $1.id }
}

/// Nintendo identifies its pads by vendor 0x057E. Third-party "Pro Controller" clones with another vendor ID
/// keep generic art instead of being presented as a genuine Switch Pro Controller.
func controllerModel(vendor: Int?, product: Int?, name: String) -> String? {
    if vendor == 0x057E {
        switch product {
        case 0x2009: return "Switch Pro Controller"
        case 0x2006: return "Joy-Con (L)"
        case 0x2007: return "Joy-Con (R)"
        case 0x200E: return "Joy-Con"
        default: return "Nintendo"
        }
    }
    if vendor != nil, name.trimmingCharacters(in: .whitespaces).lowercased() == "pro controller" { return "Generic" }
    return nil
}

func joyConSide(product: Int?) -> String? {
    switch product {
    case 0x2006: return "Joy-Con (L)"
    case 0x2007: return "Joy-Con (R)"
    case 0x200E: return "Joy-Con Charging Grip"
    default: return nil
    }
}

/// Bluetooth link state and game-input detection are separate: a link alone never claims working input.
func controllerConnectionStatus(connected: Bool, inputDetected: Bool?, connecting: Bool) -> String {
    guard connected else { return connecting ? "Connecting…" : "Not connected" }
    return inputDetected == false ? "Bluetooth only" : "Connected"
}

func isBluetoothController(deviceClass: UInt32, name: String) -> Bool {
    let peripheral = (deviceClass >> 8) & 0x1f == 5
    let subtype = (deviceClass >> 2) & 0x0f
    if peripheral && (subtype == 1 || subtype == 2) { return true }
    let name = name.lowercased()
    return ["dualsense", "dualshock", "xbox wireless", "xbox elite", "pro controller", "joy-con", "nintendo switch",
            "8bitdo", "gamesir", "wireless controller", "stadia controller", "nimbus", "stratus"].contains { name.contains($0) }
}

func controllerBatteryText(level: Float, state: GCDeviceBattery.State) -> String? {
    guard state != .unknown, level.isFinite, (0...1).contains(level) else { return nil }
    let percent = state == .full ? 100 : Int((level * 100).rounded())
    return state == .charging ? "Charging · \(percent)%" : "\(percent)% battery"
}

enum ControllerBatterySeverity: Equatable { case normal, low, critical, charging }

func controllerBatterySeverity(level: Float, state: GCDeviceBattery.State) -> ControllerBatterySeverity? {
    guard state != .unknown, level.isFinite, (0...1).contains(level) else { return nil }
    if state == .charging { return .charging }
    if state == .full { return .normal }
    if level <= 0.10 { return .critical }
    if level <= 0.30 { return .low }
    return .normal
}

/// Orange that stays readable on light rows (systemYellow is too pale there) and bright on dark rows.
let controllerBatteryWarningColor = NSColor(name: "controllerBatteryWarning") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        : NSColor(srgbRed: 0.76, green: 0.33, blue: 0.0, alpha: 1)
}

func controllerBatteryColor(_ severity: ControllerBatterySeverity) -> NSColor {
    switch severity {
    case .charging: return .systemGreen
    case .critical: return .systemRed
    case .low: return controllerBatteryWarningColor
    case .normal: return .secondaryLabelColor
    }
}

func controllerBatterySymbol(level: Float, state: GCDeviceBattery.State) -> String {
    if state == .charging { return "battery.100.bolt" }
    let value = state == .full ? 1 : level
    return value > 0.87 ? "battery.100" : value > 0.62 ? "battery.75" :
        value > 0.37 ? "battery.50" : value > 0.12 ? "battery.25" : "battery.0"
}

/// A USB serial only proves identity when it is literally the Bluetooth address of a paired controller.
func controllerSerialAddress(_ serial: String) -> String? {
    guard serial.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" }) else { return nil }
    return controllerAddress(serial)
}

/// Joy-Cons are always separate controllers: never auto-linked or offered as "Same Controller As".
func isJoyCon(_ entry: ControllerEntry) -> Bool {
    entry.model?.hasPrefix("Joy-Con") == true ||
        ControllerArtwork.kind(name: entry.name, preference: nil).hasPrefix("Joy-Con")
}

func verifiedBluetoothAlias(for id: String, knownBluetoothIDs: Set<String>) -> String? {
    let parts = id.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
    guard parts.count == 5, parts[0] == "hid", !parts[3].hasPrefix("Bluetooth"),
          parts[4].hasPrefix("serial:"),
          let address = controllerSerialAddress(String(parts[4].dropFirst("serial:".count))) else { return nil }
    let candidate = "bt:" + address
    return knownBluetoothIDs.contains(candidate) ? candidate : nil
}

/// The one profile a USB connection belongs to, only when the device itself proves it. Joy-Cons are never linked.
func controllerProfileAlias(for entry: ControllerEntry, knownBluetoothIDs: Set<String>) -> String? {
    guard entry.id.hasPrefix("hid:"), !isJoyCon(entry) else { return nil }
    if let address = entry.hardwareAddress.flatMap(controllerAddress) { return "bt:" + address }
    return verifiedBluetoothAlias(for: entry.id, knownBluetoothIDs: knownBluetoothIDs)
}

func dashedControllerAddress(_ address: String) -> String {
    stride(from: 0, to: address.count, by: 2).map {
        let start = address.index(address.startIndex, offsetBy: $0)
        return String(address[start..<address.index(start, offsetBy: 2)])
    }.joined(separator: "-")
}

/// Moves `id` so it lands at `index` within the visible ordering `visible`, keeping hidden controllers in place.
func reorderedControllerIDs(_ all: [String], moving id: String, to index: Int, among visible: [String]) -> [String] {
    guard let current = all.firstIndex(of: id) else { return all }
    var result = all
    result.remove(at: current)
    let others = visible.filter { $0 != id }
    if index < others.count, let target = result.firstIndex(of: others[max(0, index)]) {
        result.insert(id, at: target)
    } else if let last = others.last, let target = result.firstIndex(of: last) {
        result.insert(id, at: target + 1)
    } else {
        result.append(id)
    }
    return result
}

enum ControllerGlyph {
    static let bluetooth: NSImage = {
        let image = NSImage(size: NSSize(width: 10, height: 14), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1.6, y: 10.2))
            path.line(to: NSPoint(x: 8.2, y: 4.2))
            path.line(to: NSPoint(x: 5, y: 1.2))
            path.line(to: NSPoint(x: 5, y: 12.8))
            path.line(to: NSPoint(x: 8.2, y: 9.8))
            path.line(to: NSPoint(x: 1.6, y: 3.8))
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bluetooth"
        return image
    }()
}

final class ControllerDragHandle: NSImageView {
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?

    convenience init() {
        self.init(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder")!)
        contentTintColor = .tertiaryLabelColor
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                onDrop?(next.locationInWindow)
                return
            }
            onDrag?(next.locationInWindow)
        }
    }
}

/// One actionable item behind a numbered sidebar dot. Guided setup shows one page's tasks at a time; otherwise all show.
struct SidebarTask: Equatable {
    let page: Int
    let color: NSColor
    let title: String
    let setup: Bool
}

struct SidebarSeverity: Equatable {
    let color: NSColor
    let titles: [String]
    var count: Int { titles.count }
}

/// A page's tasks split by severity, most severe first, so red and yellow each get their own count.
struct SidebarBadge: Equatable {
    let groups: [SidebarSeverity]
    var count: Int { groups.reduce(0) { $0 + $1.count } }
    var color: NSColor { groups.first?.color ?? .systemYellow }
    var titles: [String] { groups.flatMap(\.titles) }
}

func sidebarSeverityRank(_ color: NSColor) -> Int {
    color == .systemRed ? 0 : color == .systemYellow ? 1 : 2
}

let guidedSetupOrder = [6, 1, 10, 7, 8, 11]
/// With guidance on, only the first page (in setup order) that has any task is marked, setup or maintenance alike.
/// Guided markers wait for checks to settle and never jump: while checks run, the shown step is kept as it was
/// (nothing is shown before the first step is known); once settled, the pinned step stays until it has no tasks.
func guidedSidebarStep(_ tasks: [SidebarTask], pinned: Int?, settled: Bool,
                       previous: [Int: SidebarBadge]) -> (badges: [Int: SidebarBadge], pinned: Int?) {
    guard settled else {
        guard let pinned = pinned else { return ([:], nil) }
        return (previous.filter { $0.key == pinned }, pinned)
    }
    let badges = sidebarBadges(tasks, guided: true, pinned: pinned)
    return (badges, badges.keys.first)
}

func sidebarSeverityName(_ color: NSColor) -> String {
    color == .systemRed ? "needs attention" : color == .systemYellow ? "recommended" : "info"
}

/// With guidance on, only one page is marked, setup or maintenance alike: the pinned page while it still has tasks,
/// otherwise the first page in setup order that has any.
func sidebarBadges(_ tasks: [SidebarTask], guided: Bool, pinned: Int? = nil) -> [Int: SidebarBadge] {
    let guidedPage = guided ? ([pinned].compactMap { $0 } + guidedSetupOrder + tasks.map(\.page)).first { page in tasks.contains { $0.page == page } } : nil
    let visible = tasks.filter { !guided || $0.page == guidedPage }
    return Dictionary(grouping: visible, by: \.page).mapValues { tasks in
        var colors: [NSColor] = []
        for task in tasks where !colors.contains(task.color) { colors.append(task.color) }
        let groups = colors.enumerated().sorted {
            (sidebarSeverityRank($0.element), $0.offset) < (sidebarSeverityRank($1.element), $1.offset)
        }.map { _, color in
            SidebarSeverity(color: color, titles: tasks.filter { $0.color == color }.map(\.title))
        }
        return SidebarBadge(groups: groups)
    }
}

final class SidebarCountDot: NSView {
    init(count: Int, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: count > 99 ? "99+" : "\(count)")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.identifier = NSUserInterfaceItemIdentifier("sidebar-count")
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        self.color = color
    }

    required init?(coder: NSCoder) { nil }

    var color: NSColor = .systemYellow { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = color.usingColorSpace(.sRGB) ?? color
            layer?.backgroundColor = fill.withAlphaComponent(0.28).cgColor
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let number = dark ? fill.blended(withFraction: 0.25, of: .white) : fill.blended(withFraction: 0.45, of: .black)
            (subviews.first as? NSTextField)?.textColor = number ?? fill
        }
    }
}

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

/// A control inside a ClickableRowView. Like the row, it takes the first click in an inactive window,
/// so clicking a heart in a background window toggles it instead of being swallowed while the row would open.
final class RowControlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A whole list row that acts as one link: hover highlight, pointing-hand cursor, pressed state,
/// Return/Space when focused and a VoiceOver link. Dragging away cancels; nested buttons keep their own action.

/// Cube Shop's My Stores / All Stores choice: a quiet pop-up that answers to the segmented-control calls the Shop already makes.
final class ScopePopUp: NSPopUpButton {
    convenience init(labels: [String]) {
        self.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        labels.forEach { addItem(withTitle: $0) }
    }
    var selectedSegment: Int {
        get { indexOfSelectedItem }
        set { selectItem(at: newValue) }
    }
    func setEnabled(_ enabled: Bool, forSegment segment: Int) { item(at: segment)?.isEnabled = enabled }
    func isEnabled(forSegment segment: Int) -> Bool { item(at: segment)?.isEnabled ?? false }
    func setToolTip(_ toolTip: String?, forSegment segment: Int) { item(at: segment)?.toolTip = toolTip }
}

final class ClickableRowView: NSView {
    var onActivate: (() -> Void)?
    private(set) var hovering = false
    private(set) var pressed = false
    private var downPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func activate() { onActivate?() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { activate(); return true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return current }
            view = current.superview
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateLook() }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; updateLook() }

    /// True when the event lands on a control inside the row (a heart, a reminder badge...), even a disabled one.
    /// Disabled buttons pass their mouse events up the responder chain, which must never open the row's link.
    private func landsOnControl(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        var view = super.hitTest(superview.convert(event.locationInWindow, from: nil))
        while let current = view, current !== self {
            if current is NSButton { return true }
            view = current.superview
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        guard !landsOnControl(event) else { downPoint = nil; return }
        downPoint = convert(event.locationInWindow, from: nil)
        pressed = true
        updateLook()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) > 4 {
            downPoint = nil
            pressed = false
            updateLook()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let click = downPoint != nil && inside && !landsOnControl(event)
        downPoint = nil
        pressed = false
        updateLook()
        if click { activate() }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { activate() } else { super.keyDown(with: event) }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = pressed ? NSColor.labelColor.withAlphaComponent(0.12)
                : hovering ? NSColor.labelColor.withAlphaComponent(0.06) : .clear
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// A multi-line label that wraps to its current width (flow layout for inline badges).
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

final class RemoteImageView: NSImageView {
    private(set) var source: URL?
    private var task: URLSessionDataTask?
    /// Fills the frame and crops the overflow, so differently shaped store art lines up row to row.
    var aspectFill = false

    override var wantsUpdateLayer: Bool { aspectFill ? false : super.wantsUpdateLayer }

    override func draw(_ dirtyRect: NSRect) {
        guard aspectFill, let image else { super.draw(dirtyRect); return }
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    func load(_ url: URL?, enabled: Bool = true) {
        task?.cancel()
        source = url
        guard let url, enabled else { return }
        if let cached = dealImageCache.object(forKey: url as NSURL) { image = cached; return }
        task = dealImageSession.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, data.count <= 2 << 20, (response as? HTTPURLResponse)?.statusCode == 200,
                  response?.url.flatMap({ safeDealURL($0.absoluteString) }) != nil,
                  let picture = NSImage(data: data), picture.isValid else { return }
            dealImageCache.setObject(picture, forKey: url as NSURL)
            DispatchQueue.main.async {
                // A reused or re-rendered row may now show a different deal.
                guard let self, self.source == url else { return }
                self.image = picture
            }
        }
        task?.resume()
    }
}

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

/// An official Windows launcher installer that Couch Cube can download (never run) into the library's Downloads folder.
struct StoreAccountName: Decodable, Equatable {
    let account: String
    let persona: String?
    let most_recent: Bool
}

/// One game client's sign-in status, read by the backend from local client files only (no web, no secrets).
struct StoreAccountRow: Decodable, Equatable {
    let id: String
    let name: String
    let state: String
    let detail: String
    let platform: String
    let kind: String
    let host: String?
    let bottle: String?
    let accounts: [StoreAccountName]
}

struct StoreAccountsReport: Decodable, Equatable {
    let clients: [StoreAccountRow]
    let installed: Int
    let signed_in: Int
}

/// Checks run only when asked (page open, Check Again, a launched client quitting); a stale reply never wins.
struct StoreAccountsModel {
    enum Phase: Equatable { case idle, checking, loaded, failed }
    private(set) var phase = Phase.idle
    private(set) var report: StoreAccountsReport?
    private(set) var lastChecked: Date?
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation += 1
        phase = .checking
        return generation
    }

    /// Returns false when the reply belongs to an older check. A failed check keeps the last good report.
    @discardableResult
    mutating func finish(_ check: Int, report newReport: StoreAccountsReport?, at date: Date) -> Bool {
        guard check == generation, phase == .checking else { return false }
        if let newReport {
            report = newReport
            lastChecked = date
            phase = .loaded
        } else {
            phase = .failed
        }
        return true
    }

    var summary: String {
        guard let report else { return phase == .failed ? "Couldn't check game clients" : "Checking game clients\u{2026}" }
        if report.installed == 0 { return "No game clients installed" }
        return "\(report.signed_in) of \(report.installed) signed in"
    }
}

/// The guided walkthrough visits installed clients one at a time; any step can be skipped.
struct StoreAccountsWalkthrough: Equatable {
    let ids: [String]
    private(set) var index = 0
    private(set) var skipped: [String] = []

    init(report: StoreAccountsReport) {
        ids = report.clients.filter { $0.state != "not_installed" }.map(\.id)
    }

    var current: String? { ids.indices.contains(index) ? ids[index] : nil }
    var finished: Bool { current == nil }

    mutating func next() { if !finished { index += 1 } }
    mutating func skip() {
        if let current { skipped.append(current) }
        next()
    }
}

struct WindowsDownloadItem: Decodable, Equatable {
    let id: String
    let name: String
    let vendor: String
    let kind: String
    let downloaded: Bool
    let file: String?
    let size: Int64?
    let sha256: String?
}

struct WindowsDownloadsReply: Decodable {
    let library: String?
    let folder: String?
    let items: [WindowsDownloadItem]
}

struct WindowsDownloadJob {
    var done: Int64 = 0
    var total: Int64 = 0
    var failure: String?
    var running = true
    var canceled = false
    var cancel: (() -> Void)?
}

/// Real byte progress reported by the backend as "PROGRESS <done> <total>" (total 0 when the server didn't say).
func windowsDownloadProgress(_ line: String) -> (done: Int64, total: Int64)? {
    let parts = line.split(separator: " ")
    guard parts.count == 3, parts[0] == "PROGRESS", let done = Int64(parts[1]), let total = Int64(parts[2]),
          done >= 0, total >= 0 else { return nil }
    return (done, total)
}

func windowsDownloadStatus(_ item: WindowsDownloadItem, job: WindowsDownloadJob?) -> (title: String, color: NSColor, pulsing: Bool) {
    if let job, job.running {
        if job.total > 0 { return ("Downloading \u{00B7} \(min(99, job.done * 100 / job.total))%", .systemBlue, true) }
        if job.done > 0 { return ("Downloading \u{00B7} " + ByteCountFormatter.string(fromByteCount: job.done, countStyle: .file), .systemBlue, true) }
        return ("Downloading\u{2026}", .systemBlue, true)
    }
    if job?.failure != nil { return ("Couldn't download", .systemRed, false) }
    return item.downloaded ? ("Downloaded", .systemGreen, false) : ("Not downloaded", .systemGray, false)
}

/// Last backend "ERROR: ..." line, for an inline message.
func backendErrorMessage(_ errors: String, fallback: String) -> String {
    let line = errors.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
    let message = line.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
    return message.isEmpty ? fallback : String(message.prefix(300))
}

struct AppOperation: Equatable {
    let action: String
    var phase: String?
    var failure: String?
    var running: Bool
}

/// The latest real Homebrew phase in a chunk of output. Homebrew hides download percentages when its output isn't a terminal,
/// so App Store rows show phases with an indeterminate spinner rather than invented percentages.
func appOperationPhase(_ output: String, action: String) -> String? {
    var phase: String?
    for line in output.split(whereSeparator: \.isNewline) {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("==> Downloading") || text.hasPrefix("==> Fetching") { phase = "Downloading" }
        else if text.hasPrefix("==> Uninstalling") || text.hasPrefix("==> Removing") || text.hasPrefix("==> Backing App") || text.hasPrefix("==> Purging") {
            phase = action == "remove" ? "Removing" : "Installing"
        } else if text.hasPrefix("==> Installing") || text.hasPrefix("==> Upgrading") || text.hasPrefix("==> Moving") {
            phase = action == "update" ? "Updating" : "Installing"
        }
    }
    return phase
}

/// Row status for an App Store app. Green means a verified installed, up-to-date app.
func appRowStatus(_ app: ManagedApp, operation: AppOperation?, unknown: Bool, checking: Bool) -> (title: String, color: NSColor, pulsing: Bool) {
    if let operation, operation.running {
        let verb = operation.action == "remove" ? "Removing" : operation.action == "update" ? "Updating" : "Installing"
        let phase = operation.phase.map { $0 == verb ? "" : " · \($0)" } ?? ""
        return (verb + phase + "\u{2026}", .systemBlue, true)
    }
    if let failure = operation?.failure { return (failure, .systemRed, false) }
    if unknown { return (checking ? "Checking..." : "Not checked", checking ? .systemBlue : .systemGray, checking) }
    let hasUpdate = app.installed && app.managed && app.update?.isEmpty == false
    return app.installed ? (hasUpdate ? ("Installed · Update available", .systemYellow, false) : ("Installed", .systemGreen, false))
        : ("Not installed", .systemRed, false)
}

final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

let settingsSectionBackground = NSColor.controlBackgroundColor
let settingsWindowBackground = NSColor.windowBackgroundColor

final class ControllerLEDHousing: NSBox {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .custom
        titlePosition = .noTitle
        borderWidth = 0
        cornerRadius = 10
        contentViewMargins = .zero
        fillColor = .quaternaryLabelColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

typealias SetupActionButton = NSButton

class TileActionButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { setHovered(false) }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea = hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        if let window = window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        } else {
            setHovered(false)
        }
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered && isEnabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        outline.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
    }
}

final class StorageChoiceButton: TileActionButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

/// A whole-row link to a drive's detail page; buttons inside (like the Finder path) keep their own clicks.
final class StorageOverviewRow: NSView {
    var driveID: String?
    var onOpen: ((String) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let id = driveID, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(id)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let id = driveID else { return false }
        onOpen?(id)
        return true
    }
    override func resetCursorRects() {
        if driveID != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

final class HomeHeaderImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSMenuItemValidation, CBCentralManagerDelegate,
    IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    private var window: NSWindow!
    private var mainWindow: NSWindow!
    private let detail = NSView()
    private let mainDetail = NSView()
    private let sidebar = NSTableView()
    private var selectingPage = false
    private let sidebarPages = [-1, 0, 8, 13, -1, 6, 1, 7, 10, 11]
    private let sidebarTitles = ["Couch Cube", "Play", "Controllers", "Cube Shop", "Settings", "Game library", "App Store", "Retro consoles", "Console Mode", "App Settings"]
    private let sidebarSymbols = ["", "play.rectangle.fill", "gamecontroller.fill", "bag.fill", "", "books.vertical.fill", "storefront", "tv", "power", "app"]
    private let screenTitle = NSTextField(labelWithString: "Play")
    // Deals: lazy, cached, read-only views of CheapShark store deals and GamerPower giveaways.
    lazy var dealsRead: ([String], @escaping (Int32, Data, String) -> Void) -> Void = { [weak self] arguments, completed in
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            // Smoke tests never touch the network: serve fixed, already-normalized replies.
            let data = Data((arguments.contains("gamerpower") ? smokeGiveawaysJSON : smokeStoreDealsJSON).utf8)
            // RunLoop (not the main queue) so replies also arrive while a smoke check spins a nested run loop.
            RunLoop.main.perform { completed(0, data, "") }
            return
        }
        self?.runBackendInBackground(["deals"] + arguments, completed: completed)
    }
    private let dealsModeKey = "dealsMode", dealsSortKey = "dealsSort", giveawaySortKey = "giveawaySort"
    private let dealsMode = NSSegmentedControl(labels: ["Store Deals", "Free Games"], trackingMode: .selectOne, target: nil, action: nil)
    private let dealsSearch = NSSearchField()
    private let dealsStorePopup = NSPopUpButton()
    private let dealsSortPopup = NSPopUpButton()
    private let giveawayPlatformPopup = NSPopUpButton()
    private let giveawayTypePopup = NSPopUpButton()
    private let giveawaySortPopup = NSPopUpButton()
    private let dealsFilters = NSStackView()
    private let dealsStatus = NSTextField(wrappingLabelWithString: "")
    private let dealsList = NSStackView()
    /// Reminders access is created only on first use; smoke tests swap in a mock so nothing is written.
    lazy var reminderStore: DealReminderStore = EventKitReminderStore()
    var dealsNow: () -> Date = { Date() }
    /// Asks before removing a reminder; smoke tests answer it directly.
    lazy var confirmReminderRemoval: (String) -> Bool = { title in
        let alert = NSAlert()
        alert.messageText = "Remove the reminder for \u{201C}\(title)\u{201D}?"
        alert.informativeText = "It will be deleted from Reminders."
        alert.addButton(withTitle: "Remove Reminder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Reminder identifiers by giveaway, so a deal never gets a duplicate reminder.
    private(set) var dealReminders: [String: String] = UserDefaults.standard.dictionary(forKey: "dealReminders") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(dealReminders, forKey: "dealReminders") }
    }
    private let dealsReminderNote = NSTextField(wrappingLabelWithString: "")
    private let dealsReminderSettings = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    private let dealsReminderBar = NSStackView()
    private let dealsMore = NSButton(title: "Load More Deals", target: nil, action: nil)
    private let dealsRetry = NSButton(title: "Try Again", target: nil, action: nil)
    private let dealsRefreshButton = NSButton(title: "", target: nil, action: nil)
    private let dealsProgress = NSProgressIndicator()
    private var dealsStores: [DealStore] = []
    private(set) var storeDeals: [StoreDeal] = []
    private(set) var giveaways: [Giveaway] = []
    private var storeDealsPage = 0, storeDealsHasMore = false
    private var dealsGeneration = 0
    private var dealsLoadingKey: String?
    private var dealsLoadedKey: [Int: String] = [:]
    private var dealsOpened = false
    private var dealsOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var dealsFetched: [Int: Double] = [:]
    // Cube Shop: Home, Deals, Free Games, Search and the drive-saved Wishlist, with optional display-currency conversion.
    private let shopTabKey = "shopTab", shopScopeKey = "shopScope", shopCurrencyKey = "shopCurrency", shopFeeKey = "shopFeePercent"
    let shopTab = NSSegmentedControl(labels: ["Home", "Deals", "Free Games", "Search", "Wishlist"], trackingMode: .selectOne, target: nil, action: nil)
    /// The visible navigation; Search isn't a tab but the results of the search field above it.
    let shopNav = NSSegmentedControl(labels: ["Home", "Deals", "Free Games", "Wishlist"], trackingMode: .selectOne, target: nil, action: nil)
    private static let shopNavTabs = [0, 1, 2, 4]
    private var shopReturnTab = 0
    let shopScope = ScopePopUp(labels: ["My Stores", "All Stores"])
    private let shopScopeHint = NSTextField(wrappingLabelWithString: "")
    private let shopScopeBar = NSStackView()
    private let shopCurrencyNote = NSTextField(wrappingLabelWithString: "")
    private let dealsPane = NSStackView(), homePane = NSStackView(), searchPane = NSStackView(), wishlistPane = NSStackView()
    private let homeStatus = NSTextField(wrappingLabelWithString: ""), homeList = NSStackView()
    private let shopSearchField = NSSearchField()
    private var shopScrollOffsets: [Int: CGFloat] = [:], shopShownTab: Int?
    private let searchStatus = NSTextField(wrappingLabelWithString: ""), searchList = NSStackView()
    private let wishlistStatus = NSTextField(wrappingLabelWithString: ""), wishlistList = NSStackView()
    private let searchSortPopup = NSPopUpButton(), wishlistSortPopup = NSPopUpButton()
    private let searchSortKey = "shopSort.search", wishlistSortKey = "shopSort.wishlist"
    private var shopPageView: NSView?
    private(set) var shopHome: ShopHomeReply?
    private var homeLoadingKey: String?, homeLoadedScope: String?, homeError: String?
    private(set) var searchReply: ShopSearchReply?
    /// Steam platform status per app ID, looked up a few at a time after lists render.
    private(set) var steamPlatformStatus: [String: String] = [:]
    private var platformsRequested: Set<String> = []
    private var platformLookupScheduled = false
    private var platformLookupRounds = 0
    private var searchLoadingQuery: String?, searchLoadedQuery: String?, searchError: String?
    private var searchTimer: Timer?
    private(set) var wishlist: WishlistReply?
    private var wishlistLoading = false, wishlistCheckedAt: Date?
    private var wishlistPayloads: [String: (title: String, payload: [String: String])] = [:]
    /// The currency a store row's price is in, for a target set before the game is on the wishlist (with Original prices).
    private var shopTargetCurrencies: [String: String] = [:]
    private(set) var exchangeRates: ExchangeRates?
    private var ratesLoading = false, ratesFailed = false, ratesLoadedAt: Date?
    private var myStores: [ShopStoreRef]?
    private var shopLoading: Set<String> = []
    private let shopCurrencyPopup = NSPopUpButton()
    private let shopFeeField = NSTextField()
    private let shopRatesNote = NSTextField(wrappingLabelWithString: "")
    /// Shop, wishlist and exchange-rate commands; smoke tests serve fixtures and an in-memory wishlist instead.
    lazy var shopRead: ([String], @escaping (Int32, Data, String) -> Void) -> Void = { [weak self] arguments, completed in
        guard let self else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            self.smokeShopCalls.append(arguments)
            let reply = self.smokeShopReply(arguments)
            RunLoop.main.perform { completed(reply.0, Data(reply.1.utf8), "") }
            return
        }
        self.runBackendInBackground(arguments, completed: completed)
    }
    var smokeShopCalls: [[String]] = []
    var smokeWishlist: [[String: Any]] = []
    var smokeWishlistOffline = false
    /// Asks for a wishlist target price in the given currency: .none = cancelled, .some(nil) = clear the target.
    lazy var askTargetPrice: (String, Double?, String) -> Double?? = { title, current, code in
        let alert = NSAlert()
        alert.messageText = "Target price for \u{201C}\(title)\u{201D}"
        alert.informativeText = "Cube Shop marks the game when its best price is at or below this, converted at today's ECB rate. Leave it empty to clear the target."
        let places = ShopMoney.minorUnits(code)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = places == 0 ? "e.g. 4000" : "e.g. 9.99"
        field.setAccessibilityLabel("Target price in \(code)")
        if let current { field.stringValue = String(format: "%.\(places)f", current) }
        let unit = NSTextField(labelWithString: code)
        unit.textColor = .secondaryLabelColor
        let box = NSStackView(views: [field, unit])
        box.spacing = 6
        box.frame = NSRect(x: 0, y: 0, width: 170, height: 24)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .none }
        return .some(parseTargetPrice(field.stringValue, code))
    }
    private let backToolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Back"))
    private let forwardToolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Forward"))
    private var pageHistory: [(page: Int, systemID: String?)] = []
    private var historyIndex = -1
    private var replayingHistory = false
    private var inspectorSystemID: String?
    private var preferredFrontend: String?
    private let defaultMenuPicker = NSPopUpButton()
    private let tvMenuStatus = NSTextField(wrappingLabelWithString: "")
    private let updateAllButton = NSButton()
    private let homeMenuLabel = NSTextField(wrappingLabelWithString: "Checking your console...")
    private let homeProgress = NSProgressIndicator()
    private let homeControllerStatus = NSStackView()
    private var homeControllerRowViews: [String: NSView] = [:]
    private var homeControllerRowIDs: [String] = []
    private var homeControllerRenderedSignature: String?
    private var homeControllerRenderCount = 0
    private var homeControllerInputLabels: [String: NSTextField] = [:]
    private var homeControllerImages: [String: [NSImageView]] = [:]
    private var homeSessionControllers: [String] = []
    private var homeObservedConnections = Set<String>()
    private let homePlayBackground = NSView()
    private var homeTiles: NSStackView!
    private var sidebarAttention: [Int: NSColor] = [:]
    private var sidebarTasks: [SidebarTask] = []
    private var sidebarTaskCounts: [Int: SidebarBadge] = [:]
    private let guidedSetupKey = "guidedSetup"
    private lazy var guidedSetup: Bool = ProcessInfo.processInfo.arguments.contains("--smoke-test") ? true :
        (UserDefaults.standard.object(forKey: guidedSetupKey) as? Bool ?? true)
    private let guidedSetupToggle = NSSwitch()
    private var couchCubeUpdateAvailable = false
    private var controllerInputUnavailable = false
    private let inspectorRows = NSStackView()
    private let inspectorTitle = NSTextField(labelWithString: "")
    private var inspectorParent = 1
    private let activeControllerRows = NSStackView()
    private let controllerStatus = NSTextField(wrappingLabelWithString: "")
    private var controllerAccessButton: NSButton!
    private var bluetoothManager: CBCentralManager?
    private var controllerTimer: Timer?
    private var controllerQueryRunning = false
    private var pairedControllers: [PairedController] = []
    private var controllerEntries: [ControllerEntry] = []
    private var controllerCustomizations: [String: ControllerCustomization] = [:]
    private var controllerInputManager: IOHIDManager?
    private let controllerTestStatus = NSTextField(wrappingLabelWithString: "Press a button or move a stick to identify and test a controller.")
    private var controllerInputLabels: [String: NSTextField] = [:]
    private var controllerLastInput: [String: (message: String, date: Date)] = [:]
    private let controllerSortMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private var controllerConnectedFirst = false
    private var controllerAliases: [String: String] = [:]
    private var controllerBatteries: [String: (level: Float, state: GCDeviceBattery.State)] = [:]
    private var controllerImages: [String: [NSImageView]] = [:]
    private var controllerRowViews: [String: NSView] = [:]
    private var controllerRowIDs: [String] = []
    private let controllerDropIndicator = NSBox()
    private var controllerBusy = Set<String>()
    private var discoveredControllers: [PairedController] = []
    private let discoveredControllerRows = NSStackView()
    private let homeDiscoveredControllerRows = NSStackView()
    private var discoveredControllersSignature: String?
    private var discoveredRenderCount = 0
    private var bluetoothInquiry: IOBluetoothDeviceInquiry?
    private var bluetoothInquiryRestart: DispatchWorkItem?
    private var bluetoothPairing: IOBluetoothDevicePair?
    private var controllerErrors: [String] = []
    private var bluetoothSettingsOpens = 0
    private var smokePairRequests: [String] = []
    private var controllerBanner: NSBox!
    private var controllerSmokeBanner = false
    private let controllerDefaultsKey = "controllerPreferences"
    private struct ControllerPreferences: Codable {
        var entries: [ControllerEntry]
        var customizations: [String: ControllerCustomization]
        var connectedFirst: Bool
        var recentControllerIDs: [String]? = nil
        var aliases: [String: String]? = nil
        /// 2 = empty color means Automatic; older saves stored the inferred default instead.
        var colorVersion: Int? = nil
    }
    private let volumeMenu = NSPopUpButton()
    private let driveRows = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    private let libraryTitle = NSTextField(labelWithString: "Choose your game drive")
    private let libraryDescription = NSTextField(wrappingLabelWithString: "Connect an SSD, or use this Mac's internal storage.")
    private let libraryAction = SetupActionButton()
    private var playAction: NSButton!
    private let steamStorageAdvice = NSTextField(wrappingLabelWithString: "")
    private let retroAdvice = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSTabView()
    private let modeLabel = NSTextField(labelWithString: "PORTABLE MANAGER")
    private let log = NSTextView()
    private var actions: [NSControl] = []
    private var volumes: [Drive] = []
    private var availableVolumes: [Drive] = []
    private var task: Process?
    private let backend: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts/console.py")
    private var refreshPending = false
    private var disks: [PhysicalDisk] = []
    private var logWindow: NSWindow?
    private var report: Assessment?
    private var libraryControls: [NSControl] = []
    private var appStates: [ManagedApp] = []
    private var appsChecking = false
    /// Startup preload of App Store data; runs in the background as soon as no other command is running.
    private var appsPreloadPending = false
    private var lastAppsData: Data?
    private var appsLoadGeneration = 0
    private var consoleLoadGeneration = 0
    /// Read-only backend reads for App Store and Retro consoles; smoke tests replace it to control completion order.
    lazy var backendRead: (_ arguments: [String], _ done: @escaping (Int32, Data) -> Void) -> Void = { arguments, done in
        self.execute(arguments, capture: true, completed: done)
    }
    private var appsHaveResults = true
    private(set) var windowsDownloads: [WindowsDownloadItem] = []
    private(set) var windowsDownloadJobs: [String: WindowsDownloadJob] = [:]
    private var windowsLibrary: String?
    private var windowsDownloadsGeneration = 0
    lazy var windowsDownloadsRead: (@escaping (Int32, Data) -> Void) -> Void = { [weak self] done in
        self?.runBackendInBackground(["windows-downloads"]) { code, data, _ in done(code, data) }
    }
    /// Starts one download and returns its cancel action. Lines arrive in order on the main thread.
    lazy var windowsDownloadRun: (String, @escaping (String) -> Void, @escaping (Int32, String) -> Void) -> (() -> Void) = { [weak self] id, line, done in
        guard let self else { return {} }
        let process = self.runBackendStreaming(["windows-download", "--package", id, "--confirm"], line: line, completed: done)
        return { if process.isRunning { process.terminate() } }
    }
    private(set) var appOperations: [String: AppOperation] = [:]
    private(set) var storeAccounts = StoreAccountsModel()
    private(set) var storeWalkthrough: StoreAccountsWalkthrough?
    private var storeClientsOpen: Set<String> = []
    private(set) var storeAccountsError: String?
    private let storeAccountsSummary = NSTextField(labelWithString: "")
    private let storeAccountsChecked = NSTextField(labelWithString: "")
    private let storeAccountsRows = NSStackView()
    private let storeWalkthroughPanel = NSStackView()
    /// Read-only local status; smoke tests replace it so no real client files are read.
    lazy var storeAccountsRead: (@escaping (Int32, Data) -> Void) -> Void = { [weak self] done in
        self?.runBackendInBackground(["store-accounts"]) { code, data, _ in done(code, data) }
    }
    /// Opens one client and calls back once it quits; smoke tests replace it so nothing launches.
    lazy var storeClientOpen: (String, @escaping (Int32) -> Void) -> Void = { [weak self] id, done in
        self?.runBackendInBackground(["store-account-open", "--id", id]) { code, _, _ in done(code) }
    }
    private var appVerifyTokens: [String: Int] = [:]
    private var appOperationOutput: ((String) -> Void)?
    lazy var appOperationRun: ([String], @escaping (Int32) -> Void) -> Void = { arguments, done in
        self.execute(arguments) { code, _ in done(code) }
    }
    lazy var appVerifyRead: ([String], @escaping (Int32, Data) -> Void) -> Void = { arguments, done in
        self.backendRead(arguments, done)
    }
    private var appRefreshPending = false
    private let appMenuRows = NSStackView()
    private let appPCRows = NSStackView()
    private let appWindowsRows = NSStackView()
    private let appRetroRows = NSStackView()
    private let consoleRows = NSStackView()
    private var consoleSystems: [ConsoleSystem] = [] { didSet { updateLibrarySummary() } }
    private var consolesChecking = false
    private var consolesLoaded = false
    private var consoleRefreshPending = false
    private var systemSwitches: [NSSwitch] = []
    private var systemStatusLines: [NSStackView] = []
    /// Console selection last confirmed on disk; failed saves fall back to it.
    private var consolePersistedEnabled: Set<String>?
    private var consoleSaveTimer: Timer?
    private var consoleSaveInFlight = false
    private var consoleSaveDirty = false
    private var consoleEditGeneration = 0
    private var consoleSaveDelay: TimeInterval = 0.4
    /// Show/hide-all switches for the page, each company card and each Nintendo subsection.
    private var consoleBulkToggles: [(toggle: NSSwitch, count: NSTextField, ids: Set<String>, scope: String)] = []
    lazy var consoleRoot: () -> String? = { self.selected?.root }
    /// Injected in smoke tests; the default runs the backend off the main thread without the global busy state.
    lazy var consoleSaver: (_ root: String, _ enabled: [String], _ done: @escaping (Int32, String) -> Void) -> Void = { root, enabled, done in
        self.runBackendInBackground(["systems", "--root", root, "--confirm", "--enabled"] + enabled) { code, _, errors in done(code, errors) }
    }
    lazy var consoleRefresher: (_ root: String, _ done: @escaping (Int32, Data) -> Void) -> Void = { root, done in
        self.runBackendInBackground(["systems", "--root", root]) { code, data, _ in done(code, data) }
    }
    private let appsStatus = NSTextField(wrappingLabelWithString: "")
    private let consoleStatus = NSTextField(wrappingLabelWithString: "Create your game folders in Settings → Game library first.")
    private let setupFolderStatus = NSTextField(wrappingLabelWithString: "Choose where to keep your games.")
    private let gameLibraryOverviewRows = NSStackView()
    private var storageOverviewRendered: [ObjectIdentifier: [StorageOverviewEntry]] = [:]
    private let driveDetailRows = NSStackView()
    private var driveDetailID: String?
    private var driveDetailParent = 6
    private var driveDetailCache: [String: DriveDetail] = [:]
    private var driveDetailErrors: [String: String] = [:]
    private var driveDetailGeneration = 0
    private var driveDetailLoading = false
    private var driveDetailPending = false
    private var driveGamesCache: [String: (games: DriveGames, scanned: Date)] = [:]
    private var driveGamesErrors: [String: String] = [:]
    private var driveGamesScanning: String?
    private var driveGamesGeneration = 0
    private var driveGamesShowAll = false
    private var driveGamesProcess: Process?
    private let romsBySystemKey = "DriveStorageGroupRomsBySystem"
    private let pcByLauncherKey = "DriveStorageGroupPCByLauncher"
    /// Independent of the shared backend task, so a long size scan never blocks other actions; smoke tests replace it.
    lazy var driveGamesRead: (_ id: String, _ done: @escaping (Int32, Data) -> Void) -> Void = { id, done in
        self.runDriveGamesScan(id, done)
    }
    private var storageStatus: StorageStatus?
    private var transferLibraryButton: NSButton!
    private var retireLibraryButton: NSButton!
    private var lastLibraryTransfer: (result: LibraryTransferResult, destinationID: String)?
    private let setupAppStatus = NSTextField(wrappingLabelWithString: "Steam or ES-DE provides your TV menu.")
    private let setupConnectionStatus = NSTextField(wrappingLabelWithString: "Connect a controller and add your games.")
    private var lastError = ""
    private var smokeFinishing = false
    private var smokeAppsLoaded = false
    private var smokeSystemsLoaded = false
    private var smokeSteamLoaded = false
    private var smokeOverviewRefreshed = false
    private let updateStatus = NSTextField(wrappingLabelWithString: "Checking for updates...")
    private let updateButton = NSButton()
    private var updateTask: Process?
    private var updateURL: URL?
    private var didRouteInitialLibrary = false
    private var preferredMode: String?
    private let navigationBar = NSStackView()
    private let sidebarPanel = NSView()
    private let splitController = NSSplitViewController()
    private let storageHeading = NSTextField(labelWithString: "Choose your game storage")
    private let storageAdvice = NSTextField(wrappingLabelWithString: "")
    private let storageNext = SetupActionButton()
    private let portablePreparation = NSStackView()
    private let selectedStorage = NSTextField(wrappingLabelWithString: "")
    private let selectedStorageIcon = NSImageView()
    private let selectedStorageMode = NSTextField(labelWithString: "")
    private let libraryHealth = NSStackView()
    private let librarySummary = NSTextField(wrappingLabelWithString: "Checking your games…")
    private let finishAdvice = NSTextField(wrappingLabelWithString: "")
    private var advanceAfterLibraryCheck = false
    private let preparationResult = NSTextField(wrappingLabelWithString: "")
    private var helperButton: NSButton!
    private let helperAdvice = NSTextField(wrappingLabelWithString:
        "Homebrew is needed only to install missing apps from here. Finish its Terminal installer, return here, then click the app's Install button. macOS may ask for administrator approval.")
    private let autoLaunchToggle = NSSwitch()
    private let autoLaunchDelay = NSTextField(string: "30")
    private let autoLaunchStatus = NSTextField(wrappingLabelWithString: "Open Console Mode to check automatic startup.")
    private var autoLaunchLoaded = false
    private enum OverviewCheck: CaseIterable { case storage, menu, consoles, automatic, steam, apps }
    private var overviewChecks = Set<OverviewCheck>()
    /// The guided step currently shown; it stays until its tasks are done so arriving checks never make markers jump.
    private var guidedPinnedPage: Int?
    private var overviewCheckFailures = Set<OverviewCheck>()
    private var steamReport: SteamLibraryReport?
    private let steamGuideRows = NSStackView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Couch Cube"
        window.minSize = NSSize(width: 960, height: 720)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let chrome = NSToolbar(identifier: "WindowChrome")
        chrome.allowsUserCustomization = false
        chrome.displayMode = .iconOnly
        chrome.delegate = self
        window.toolbar = chrome
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.backgroundColor = settingsWindowBackground
        window.delegate = self
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Couch Cube", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Couch Cube", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[").target = self
        viewMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Activity", action: #selector(showActivity), keyEquivalent: "").target = self
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Couch Cube Help", action: #selector(instructions), keyEquivalent: "").target = self
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)
        NSApp.mainMenu = menu
        mainWindow = window
        let sidebarBackground = sidebarPanel
        let sidebarController = NSViewController()
        sidebarController.view = sidebarBackground
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 210
        sidebarItem.canCollapse = false
        sidebarItem.allowsFullHeightLayout = true
        let detailController = NSViewController()
        detailController.view = mainDetail
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 716
        splitController.splitView.isVertical = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(detailItem)
        mainWindow.contentViewController = splitController
        sidebarBackground.addSubview(navigationBar)
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            navigationBar.topAnchor.constraint(equalTo: (mainWindow.contentLayoutGuide as! NSLayoutGuide).topAnchor),
            navigationBar.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -24)
        ])
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--smoke-test"),
           let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
            let appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
            mainWindow.appearance = appearance
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        mainDetail.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: mainDetail.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: mainDetail.trailingAnchor),
            detail.topAnchor.constraint(equalTo: mainDetail.safeAreaLayoutGuide.topAnchor),
            detail.bottomAnchor.constraint(equalTo: mainDetail.bottomAnchor)
        ])
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: detail.topAnchor),
            stack.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -16)
        ])
        for (item, symbol, label, action) in [
            (backToolbarItem, "chevron.left", "Back", #selector(goBack)),
            (forwardToolbarItem, "chevron.right", "Forward", #selector(goForward))
        ] {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isNavigational = true
            item.isBordered = true
            item.autovalidates = false
        }
        screenTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        modeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        volumeMenu.target = self
        volumeMenu.action = #selector(selectionChanged)
        volumeMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        driveRows.orientation = .vertical
        driveRows.alignment = .leading
        driveRows.spacing = 12
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        actions.append(volumeMenu)
        tabs.tabViewType = .noTabsNoBorder

        libraryTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        libraryDescription.textColor = .secondaryLabelColor
        libraryAction.title = "Update game library..."
        libraryAction.target = self
        libraryAction.action = #selector(setup)
        libraryAction.bezelStyle = .rounded
        actions.append(libraryAction)
        libraryControls.append(libraryAction)
        let openGames = headerIconButton("folder", label: "Open game folders", action: #selector(openFolder))
        let addGame = headerIconButton("plus", label: "Add a game…", action: #selector(registerGame))
        let play = TileActionButton(title: "", target: self, action: #selector(showPlayOverview))
        playAction = play
        libraryControls += [openGames, addGame, play]
        homeMenuLabel.textColor = .secondaryLabelColor
        homeProgress.style = .spinning
        homeProgress.controlSize = .small
        homeProgress.isDisplayedWhenStopped = false
        homeProgress.setAccessibilityLabel("Checking console status")
        homeControllerStatus.orientation = .vertical
        homeControllerStatus.alignment = .leading
        homeControllerStatus.spacing = 8
        let playCard = NSBox()
        playCard.boxType = .custom
        playCard.titlePosition = .noTitle
        playCard.contentViewMargins = .zero
        let playTitle = text("Play", size: 22)
        playTitle.font = .systemFont(ofSize: 22, weight: .bold)
        playTitle.textColor = .white
        playTitle.shadow = NSShadow()
        playTitle.shadow?.shadowColor = .black
        playTitle.shadow?.shadowBlurRadius = 6
        play.title = ""
        play.isBordered = false
        play.toolTip = "Play"
        play.setAccessibilityLabel("Play")
        homePlayBackground.wantsLayer = true
        homePlayBackground.layer?.contentsGravity = .resizeAspectFill
        homePlayBackground.layer?.masksToBounds = true
        homePlayBackground.layer?.cornerRadius = 16
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        shade.layer?.cornerRadius = 16
        for view in [homePlayBackground, shade, playTitle, play] {
            view.translatesAutoresizingMaskIntoConstraints = false
            playCard.contentView!.addSubview(view)
        }
        pin(homePlayBackground, to: playCard.contentView!)
        pin(shade, to: playCard.contentView!)
        pin(play, to: playCard.contentView!)
        NSLayoutConstraint.activate([
            playTitle.topAnchor.constraint(equalTo: playCard.contentView!.topAnchor, constant: 16),
            playTitle.leadingAnchor.constraint(equalTo: playCard.contentView!.leadingAnchor, constant: 16),
            playCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        let openControllersButton = headerIconButton("list.bullet", label: "Open Controllers", action: #selector(showControllers))
        let controllerHeader = cardHeader("Controllers", buttons: [openControllersButton])
        controllerHeader.identifier = NSUserInterfaceItemIdentifier("home-controller-header")
        homeControllerStatus.spacing = 10
        homeDiscoveredControllerRows.orientation = .vertical
        homeDiscoveredControllerRows.alignment = .leading
        homeDiscoveredControllerRows.spacing = 10
        homeDiscoveredControllerRows.isHidden = true
        // The card is as tall as the Play tile; this filler takes the spare height so a newly shown
        // discovery row sits right under the list instead of being stretched to the card's bottom first.
        homeControllerStatus.setContentHuggingPriority(.required, for: .vertical)
        homeDiscoveredControllerRows.setContentHuggingPriority(.required, for: .vertical)
        let controllerCardFiller = NSView()
        controllerCardFiller.identifier = NSUserInterfaceItemIdentifier("home-controller-filler")
        controllerCardFiller.setContentHuggingPriority(.init(1), for: .vertical)
        controllerCardFiller.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let controllerCard = card("", subtitle: nil, views: [controllerHeader, homeControllerStatus, homeDiscoveredControllerRows, controllerCardFiller])
        controllerCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        for section in [playCard, controllerCard] {
            section.fillColor = .quaternaryLabelColor
            section.cornerRadius = 16
            section.borderWidth = 0
            if let contents = section.contentView?.subviews.first as? NSStackView {
                let first = contents.arrangedSubviews.first
                let title = first as? NSTextField ?? (first as? NSStackView)?.arrangedSubviews.first as? NSTextField
                title?.font = .systemFont(ofSize: 22, weight: .bold)
            }
        }
        playCard.fillColor = .systemBlue.withAlphaComponent(0.12)
        let homeCards = row([playCard, controllerCard])
        homeTiles = homeCards
        homeCards.distribution = .fillEqually
        homeCards.spacing = 20
        playCard.widthAnchor.constraint(equalTo: controllerCard.widthAnchor).isActive = true
        playCard.heightAnchor.constraint(equalTo: controllerCard.heightAnchor).isActive = true
        let brandHeader = NSView()
        brandHeader.wantsLayer = true
        brandHeader.layer?.cornerRadius = 16
        brandHeader.layer?.masksToBounds = true
        let portableHeader = Bundle.main.object(forInfoDictionaryKey: "MCCDistribution") as? String == "portable"
        let headerName = portableHeader ? "HomeHeaderPortable.png" : "HomeHeader.png"
        let brandImage = HomeHeaderImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(headerName))!)
        brandImage.imageScaling = .scaleAxesIndependently
        brandImage.translatesAutoresizingMaskIntoConstraints = false
        brandHeader.addSubview(brandImage)
        pin(brandImage, to: brandHeader)
        NSLayoutConstraint.activate([
            brandHeader.heightAnchor.constraint(equalTo: brandHeader.widthAnchor, multiplier: 500.0 / 1680.0)
        ])
        addPage("Play", content: column([
            brandHeader,
            homeCards
        ]))

        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        helperButton = button("Install Homebrew...", #selector(homebrew))
        helperAdvice.textColor = .secondaryLabelColor
        let apps = column([
            row([appsStatus, updateAllButton]),
            appCategoryCard("TV menus", rows: appMenuRows),
            appCategoryCard("PC games", rows: appPCRows),
            appCategoryCard("Windows games", rows: appWindowsRows),
            appCategoryCard("Retro games", rows: appRetroRows),
            helperAdvice,
            helperButton
        ])
        updateAllButton.title = "Update all"
        updateAllButton.target = self
        updateAllButton.action = #selector(updateAllApps)
        updateAllButton.bezelStyle = .rounded
        updateAllButton.setContentHuggingPriority(.required, for: .horizontal)
        updateAllButton.toolTip = "Update outdated Homebrew-managed apps. Other apps use their own updaters."
        updateAllButton.isEnabled = false
        updateAllButton.isHidden = true
        actions.append(updateAllButton)
        addPage("App Store", content: apps)
        autoLaunchDelay.widthAnchor.constraint(equalToConstant: 64).isActive = true
        autoLaunchToggle.controlSize = .small
        autoLaunchToggle.setAccessibilityLabel("Automatic console mode on this Mac")
        autoLaunchDelay.setAccessibilityLabel("Seconds to wait after login, from 5 to 300")
        autoLaunchStatus.textColor = .secondaryLabelColor
        actions += [autoLaunchToggle, autoLaunchDelay]
        defaultMenuPicker.target = self
        defaultMenuPicker.action = #selector(defaultMenuChanged(_:))
        defaultMenuPicker.setAccessibilityLabel("Default TV menu")
        actions.append(defaultMenuPicker)
        transferLibraryButton = button("Move library...", #selector(moveLibrary))
        retireLibraryButton = button("Move old library to Trash...", #selector(retireOldLibrary))
        retireLibraryButton.isHidden = true
        // Library storage is part of Game library; the index stays so page numbers remain stable.
        addPage("Library storage", content: column([]))
        updateButton.title = "View release..."
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.isEnabled = false
        updateButton.bezelStyle = .rounded
        addPage("Library storage", content: column([]))
        storageHeading.font = .systemFont(ofSize: 24, weight: .bold)
        storageAdvice.textColor = .secondaryLabelColor
        storageNext.title = "Use this storage..."
        storageNext.target = self
        storageNext.action = #selector(continueStorage)
        storageNext.bezelStyle = .rounded
        actions.append(storageNext)
        portablePreparation.orientation = .vertical
        portablePreparation.alignment = .leading
        let prepare = card("Prepare a new SSD", subtitle:
            "Erase and format an external SSD, then copy Couch Cube onto it. You'll review the disk before anything is erased.",
            views: [button("Prepare an SSD...", #selector(prepareDisk))])
        portablePreparation.addArrangedSubview(prepare)
        prepare.widthAnchor.constraint(equalTo: portablePreparation.widthAnchor).isActive = true
        addPage("Storage", content: column([
            storageAdvice,
            preparationResult,
            portablePreparation,
            card("Library storage", subtitle: "Choose a drive. Existing files are kept.", views: [
                driveRows,
                summary,
                button("Refresh connected drives", #selector(refresh)),
                primary(storageNext),
                button("Copy this app to SSD...", #selector(copyAppToSSD))
            ]),
            button("Change storage type", #selector(backToChoices))
        ]))
        preparationResult.isHidden = true
        addPage("Finish", content: column([
            pageHeading("Set up Steam", "These steps happen in Steam, not automatically in Couch Cube."),
            finishAdvice,
            card("Steam libraries", subtitle: "See where your Steam games are installed. Change storage in Steam.", views: [
                steamGuideRows,
                row([button("Open Steam Storage", #selector(openSteamStorage)),
                     button("Refresh Steam status", #selector(refreshSteamStatus))])
            ]),
            card("1. Sign in & choose game storage", subtitle: nil, views: [
                steamStorageAdvice,
                row([button("Open Steam desktop", #selector(openSteamDesktop)),
                     button("Show SteamLibrary folder", #selector(showSteamFolder))])
            ]),
            card("2. Connect a controller & install a game", subtitle:
                "Pair it in macOS Bluetooth settings or connect it with USB. Steam → Settings → Controller lets you check the buttons. Retro players may need their own controller setup.",
                views: [text("Install a game from your Steam library, then choose Play on Home. Existing Steam games stay where they are.", size: 12, secondary: true),
                        button("Controllers", #selector(showControllers))]),
            card("Optional: retro & Windows games in Big Picture", subtitle: nil, views: [
                retroAdvice, row([button("Open Steam desktop", #selector(openSteamDesktop)),
                                 button("Open game folders", #selector(openFolder))])
            ])
        ]))
        librarySummary.font = .systemFont(ofSize: 12)
        librarySummary.textColor = .secondaryLabelColor
        librarySummary.identifier = NSUserInterfaceItemIdentifier("library-summary")
        let yourGames = cardHeader("Your games", buttons: [addGame, openGames])
        yourGames.identifier = NSUserInterfaceItemIdentifier("library-header")
        (yourGames.arrangedSubviews.first as? NSTextField)?.font = .systemFont(ofSize: 17, weight: .semibold)
        let storageHeader = cardHeader("Where your games live", buttons: [libraryStorageMenu()])
        (storageHeader.arrangedSubviews.first as? NSTextField)?.font = .systemFont(ofSize: 17, weight: .semibold)
        gameLibraryOverviewRows.orientation = .vertical
        gameLibraryOverviewRows.alignment = .leading
        gameLibraryOverviewRows.spacing = 0
        addPage("Game library", content: column([
            card("", subtitle: nil, views: [
                storageHeader,
                text("ROMs, BIOS, saves and portable games can live on this Mac and on external SSDs. Choose a drive to see its storage, Steam games and retro games.", size: 12, secondary: true),
                setupFolderStatus, gameLibraryOverviewRows, libraryHealth, libraryTitle, libraryDescription, libraryAction,
                row([button("Refresh connected drives", #selector(refresh)), button("Add or prepare an SSD...", #selector(choosePortable))])
            ]),
            card("", subtitle: nil, views: [yourGames, librarySummary]),
            card("Move your library", subtitle: "Copy to another drive, verify the contents and activate it. The old copy stays until you choose to remove it. Steam libraries are moved in Steam.", views: [
                transferLibraryButton, retireLibraryButton
            ])
        ]))
        consoleRows.orientation = .vertical
        consoleRows.alignment = .leading
        consoleRows.spacing = 16
        addPage("Consoles", content: column([
            consoleStatus,
            consoleRows
        ]))
        for rows in [activeControllerRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        controllerAccessButton = controllerButton("Allow Bluetooth Access", #selector(controllerBluetoothAccess))
        controllerAccessButton.bezelStyle = .rounded
        controllerSortMenu.addItem(withTitle: "")
        controllerSortMenu.item(at: 0)?.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
        for (tag, title) in ["Your Order", "Connected First"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(controllerSortChanged(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            controllerSortMenu.menu?.addItem(item)
        }
        controllerSortMenu.bezelStyle = .inline
        controllerSortMenu.isBordered = false
        (controllerSortMenu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        controllerSortMenu.setAccessibilityLabel("Sort controllers")
        controllerSortMenu.widthAnchor.constraint(equalToConstant: 28).isActive = true
        updateControllerSortMenu()
        discoveredControllerRows.orientation = .vertical
        discoveredControllerRows.alignment = .leading
        discoveredControllerRows.spacing = 0
        discoveredControllerRows.isHidden = true
        loadControllerPreferences()
        controllerStatus.font = .systemFont(ofSize: 12)
        let bannerIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Attention")!)
        bannerIcon.contentTintColor = .systemYellow
        bannerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        bannerIcon.setContentHuggingPriority(.required, for: .horizontal)
        controllerStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controllerBanner = card("", subtitle: nil, views: [row([bannerIcon, controllerStatus, controllerAccessButton])], inset: 12)
        controllerBanner.fillColor = NSColor.systemYellow.withAlphaComponent(0.12)
        controllerBanner.borderColor = NSColor.systemYellow.withAlphaComponent(0.35)
        controllerBanner.isHidden = true
        let bluetoothSettings = headerIconButton("", label: "Bluetooth Settings", action: #selector(openBluetooth))
        bluetoothSettings.image = ControllerGlyph.bluetooth
        bluetoothSettings.imageScaling = .scaleNone
        let gameControllerSettings = headerIconButton("gearshape", label: "Game Controller Settings", action: #selector(openGameControllerSettings))
        let pairingHint = text("To add a wireless controller, put it in pairing mode. It appears here with a Connect button. Xbox and other Bluetooth LE controllers may only appear in Bluetooth Settings.", size: 11, secondary: true)
        addPage("Controllers", content: column([
            controllerBanner,
            card("", subtitle: nil, views: [
                cardHeader("Controllers", buttons: [controllerSortMenu, bluetoothSettings, gameControllerSettings]),
                activeControllerRows, discoveredControllerRows, pairingHint
            ])
        ]))
        inspectorTitle.font = .systemFont(ofSize: 22, weight: .bold)
        inspectorRows.orientation = .vertical
        inspectorRows.alignment = .leading
        inspectorRows.spacing = 12
        addPage("Details", content: column([
            card("Details", subtitle: nil, views: [inspectorRows])
        ]))
        addPage("Console Mode", content: column([
            card("Default TV menu", subtitle: "The menu Play and automatic console mode open.", views: [
                settingsRow("TV menu", subtitle: "Install menus in App Store.", symbol: "tv.fill",
                            color: .systemBlue, trailing: defaultMenuPicker),
                tvMenuStatus
            ]),
            card("Automatic console mode", subtitle: nil, views: [
                settingsRow("Start after login", subtitle: "Open the TV menu when a controller is connected.",
                            symbol: "power", color: .systemGreen, trailing: autoLaunchToggle),
                row([text("Wait after login:"), autoLaunchDelay, text("seconds")]),
                text("Runs once after login. A connected keyboard or mouse skips console mode for that login. With no controller, it waits until one connects. Keep Couch Cube and its game drive available. Turn off Steam's own login startup.", size: 12, secondary: true),
                autoLaunchStatus,
                button("Save automatic console mode", #selector(saveAutoLaunch))
            ]),
            card("Start straight into your console", subtitle: "macOS controls accounts, automatic login and screen locking.", views: [
                text("1. Optional: in Users & Groups, create a Standard user named Couch Cube with its own password. Keep your private administrator account. A passwordless account is not needed.", size: 13),
                text("2. Put Couch Cube in /Applications, then sign in to the gaming account. Open Couch Cube there, choose game storage, sign in to Steam or your other launchers, and save automatic console mode. Settings and saves belong to that account; an existing private-account library is not moved or shared automatically.", size: 13),
                text("3. In Users & Groups, choose the gaming account under Automatically log in as. Enter its password in macOS, not Couch Cube. Organization policies or an Apple Account login password may prevent automatic login.", size: 13),
                row([button("Open Users & Groups", #selector(openUsersAndGroups)),
                     button("Apple login guide", #selector(openAutomaticLoginGuide))])
            ]),
            card("Privacy and screen lock", subtitle: nil, views: [
                text("Automatic login is unavailable while FileVault is on. Turning FileVault off reduces startup protection for the entire Mac, including your private account. A separate gaming account is useful separation, not a security boundary against someone with physical access. Keep FileVault on if private data protection is more important than unattended startup.", size: 13),
                text("Waking from sleep can still require a password. Review Require password after screen saver begins or display is turned off in Lock Screen. Reducing this protection lets anyone nearby use the gaming account. macOS may restrict this setting, including when iPhone Mirroring uses automatic authentication.", size: 13),
                row([button("Open FileVault Settings", #selector(openFileVaultSettings)),
                     button("Open Lock Screen Settings", #selector(openLockScreenSettings))]),
                text("Couch Cube does not create accounts, store login passwords, change FileVault or enable macOS automatic login. The setup above is optional and performed in System Settings.", size: 12, secondary: true)
            ])
        ]))
        guidedSetupToggle.state = guidedSetup ? .on : .off
        guidedSetupToggle.controlSize = .small
        guidedSetupToggle.target = self
        guidedSetupToggle.action = #selector(guidedSetupChanged)
        guidedSetupToggle.setAccessibilityLabel("Guided setup")
        addPage("App Settings", content: column([
            card("App Settings", subtitle: nil, views: [
                settingsRow("App updates", subtitle: "Check for a new version of Couch Cube.",
                            symbol: "arrow.down.circle", color: .systemGreen,
                            trailing: row([button("Check...", #selector(checkUpdates)), updateButton]),
                            detail: updateStatus),
                separator(),
                settingsRow("Guided setup", subtitle: "Show one sidebar step at a time. Turn off to see every task.",
                            symbol: "checklist", color: .systemBlue, trailing: guidedSetupToggle),
                separator(),
                settingsRow("App location", subtitle: "Find this copy of Couch Cube.", symbol: "app",
                            color: .systemGray, trailing: button("Show in Finder", #selector(revealApp))),
                separator(),
                settingsRow("Installer copy", subtitle: "Keep a download on your game drive.", symbol: "square.and.arrow.down",
                            color: .systemOrange, trailing: button("Copy installer...", #selector(copyDMG))),
                separator(),
                settingsRow("Remove Couch Cube", subtitle: "Your games, saves and other apps are kept.", symbol: "trash",
                            color: .systemGray, trailing: button("Uninstall...", #selector(uninstallCouchCube))),
                separator(),
                settingsRow("Clean up gaming setup", subtitle: "Review apps, games, saves and related files to remove.", symbol: "trash",
                            color: .systemRed, trailing: button("Review...", #selector(reviewGamingCleanup)))
            ]),
            shopSettingsCard(),
            storeAccountsCard()
        ]))
        driveDetailRows.orientation = .vertical
        driveDetailRows.alignment = .leading
        driveDetailRows.spacing = 16
        addPage("Drive", content: column([driveDetailRows]))
        addPage("Cube Shop", content: column([cubeShopPage()]))
        navigationBar.orientation = .vertical
        navigationBar.alignment = .leading
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        let navigationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Navigation"))
        navigationColumn.resizingMask = .autoresizingMask
        sidebar.addTableColumn(navigationColumn)
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 32
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Couch Cube navigation")
        sidebarScroll.documentView = sidebar
        navigationBar.addArrangedSubview(sidebarScroll)
        sidebarScroll.widthAnchor.constraint(equalTo: navigationBar.widthAnchor).isActive = true
        sidebarScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        stack.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        log.isEditable = false
        log.isSelectable = true
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textColor = .textColor
        log.backgroundColor = .textBackgroundColor
        log.autoresizingMask = [.width]
        log.isVerticallyResizable = true
        log.isHorizontallyResizable = false
        log.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        log.textContainer?.widthTracksTextView = true
        for view in stack.arrangedSubviews where view !== tabs {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        selectPage(0)
        mainWindow.center()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(disksChanged), name: name, object: nil)
        }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(controllerConnectionChanged), name: name, object: nil)
        }
        refresh()
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            updateStatus.stringValue = "Startup network check skipped for read-only verification."
        } else {
            checkUpdates()
        }
    }

    @objc private func checkUpdates() {
        guard updateTask == nil else { return }
        updateStatus.stringValue = "Checking GitHub for the latest portable release..."
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path, "update-check"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        updateTask = process
        do {
            try process.run()
        } catch {
            updateTask = nil
            updateStatus.stringValue = "Couldn't check for updates: \(error.localizedDescription)"
            return
        }
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                self.updateTask = nil
                guard process.terminationStatus == 0 else {
                    self.updateStatus.stringValue = self.friendlyBackendError(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                do {
                    let report = try JSONDecoder().decode(UpdateReport.self, from: data)
                    self.updateStatus.stringValue = report.available
                        ? "Couch Cube \(report.version) is available. Download it and replace the app after quitting."
                        : "You're up to date. Latest published release: \(report.version)."
                    self.updateURL = URL(string: report.url)
                    self.updateButton.title = "Download..."
                    self.updateButton.isHidden = !report.available
                    self.updateButton.isEnabled = report.available && self.updateURL != nil
                    self.couchCubeUpdateAvailable = report.available
                    self.renderGeneral()
                    if report.available {
                        self.status.stringValue = "App update available. Open Settings to view the release."
                    }
                } catch {
                    self.updateStatus.stringValue = "Couldn't read GitHub update information: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func openUpdate() {
        if let url = updateURL { NSWorkspace.shared.open(url) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if controllerPageVisible { refreshControllers() }
    }

    private func pageHeading(_ title: String, _ subtitle: String) -> NSStackView {
        column([text(subtitle, size: 13, secondary: true)])
    }

    private func primary(_ button: NSButton) -> NSButton {
        button.bezelStyle = .rounded
        button.isBordered = true
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    private func choice(_ title: String, _ description: String, symbol: String, action: Selector) -> NSView {
        let choose = StorageChoiceButton(title: "", target: self, action: action)
        choose.isBordered = false
        choose.setButtonType(.momentaryChange)
        choose.focusRingType = .exterior
        actions.append(choose)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let heading = text(title)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = column([heading, text(description, size: 12, secondary: true)])
        labels.spacing = 4
        let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let content = row([icon, labels, arrow])
        content.distribution = .fill
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        choose.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: choose.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: choose.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: choose.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: choose.bottomAnchor, constant: -12),
            choose.heightAnchor.constraint(greaterThanOrEqualToConstant: 68)
        ])
        choose.setAccessibilityLabel(title + ". " + description.replacingOccurrences(of: "\n", with: " "))
        return choose
    }

    /// Shared with Library Settings so both pages name and draw storage modes the same way.
    private static let storageModes: [(mode: String, title: String, symbol: String)] = [
        ("local", "This Mac", "macmini"), ("portable", "External SSD", "externaldrive")
    ]

    private func storageMode(_ mode: String) -> (mode: String, title: String, symbol: String) {
        Self.storageModes.first { $0.mode == mode } ?? Self.storageModes[1]
    }

    private func storageModeIcon(_ view: NSImageView, mode: String) {
        view.image = NSImage(systemSymbolName: storageMode(mode).symbol, accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        view.contentTintColor = .secondaryLabelColor
    }

    private func selectedStorageView() -> NSView {
        selectedStorageIcon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        selectedStorageIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        selectedStorageIcon.setContentHuggingPriority(.required, for: .horizontal)
        selectedStorageIcon.identifier = NSUserInterfaceItemIdentifier("library-storage-icon")
        selectedStorageMode.font = .systemFont(ofSize: 13, weight: .medium)
        selectedStorageMode.identifier = NSUserInterfaceItemIdentifier("library-storage-mode")
        selectedStorage.font = .systemFont(ofSize: 12)
        selectedStorage.textColor = .secondaryLabelColor
        selectedStorage.lineBreakMode = .byTruncatingMiddle
        selectedStorage.maximumNumberOfLines = 2
        selectedStorage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = column([selectedStorageMode, selectedStorage])
        labels.spacing = 4
        labels.setHuggingPriority(.init(1), for: .horizontal)
        let line = row([selectedStorageIcon, labels])
        line.spacing = 12
        line.distribution = .fill
        storageModeIcon(selectedStorageIcon, mode: "local")
        return line
    }

    /// Game library shows the same mode, icon and "· Active" marker as the Library Settings tiles.
    private func updateSelectedStorageMarker() {
        guard let mode = selected?.mode ?? preferredMode else {
            selectedStorageIcon.isHidden = true
            selectedStorageMode.stringValue = "No storage selected"
            return
        }
        selectedStorageIcon.isHidden = false
        storageModeIcon(selectedStorageIcon, mode: mode)
        let marker: String
        if let drive = selected {
            let active = storageStatus.flatMap { storage in storage.locations.first {
                $0.drive.id == storage.active?.id && $0.drive.uuid == storage.active?.uuid && $0.configured
            } }
            marker = active?.drive.id == drive.id && active?.drive.uuid == drive.uuid ? " · Active" : ""
        } else {
            marker = " · Disconnected"
        }
        selectedStorageMode.stringValue = storageMode(mode).title + marker
        selectedStorageIcon.setAccessibilityLabel(selectedStorageMode.stringValue)
    }

    @objc private func chooseLocal() { chooseMode("local") }
    @objc private func choosePortable() { chooseMode("portable") }

    private func renderStorageLocations() {
        updateSelectedStorageMarker()
        renderStorageOverview()
        if driveDetailID != nil {
            renderDriveDetail()
            if currentPage == 12 && detailDrive != nil { loadDriveDetail() }
        }
        guard let storage = storageStatus else {
            setupFolderStatus.stringValue = "Reading available storage..."
            transferLibraryButton.isEnabled = false
            return
        }
        let active = storage.locations.first {
            $0.drive.id == storage.active?.id && $0.drive.uuid == storage.active?.uuid && $0.configured
        }
        if let transfer = storage.transfer, let active = active {
            lastLibraryTransfer = (transfer, active.drive.id)
        }
        if let active = active {
            setupFolderStatus.stringValue = "Active · \(active.drive.mode == "local" ? "This Mac" : active.drive.name)\n\(active.drive.root)"
        } else if storage.active != nil {
            setupFolderStatus.stringValue = "Your active library is disconnected or needs setup. Reconnect its drive, or choose another location."
        } else if storage.locations.contains(where: \.configured) {
            setupFolderStatus.stringValue = "Choose an existing library to activate it, or set up another location. No files are moved when switching."
        } else {
            setupFolderStatus.stringValue = "Where should your game files live? Choose this Mac or an external SSD to set up your first library."
        }
        setupFolderStatus.isHidden = active != nil
        transferLibraryButton.isEnabled = task == nil && active != nil &&
            storage.locations.contains { $0.drive.id != active?.drive.id }
        transferLibraryButton.toolTip = active == nil ? "Set up or activate a library first." : "Transfer the active Couch Cube library to another drive."
        retireLibraryButton.isHidden = lastLibraryTransfer == nil
        retireLibraryButton.isEnabled = task == nil && lastLibraryTransfer != nil
    }

    private var currentPage: Int {
        tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? -1
    }

    private func driveTitle(_ drive: Drive) -> String {
        drive.mode == "local" ? "This Mac" : drive.name.replacingOccurrences(of: " (portable console)", with: "")
    }

    /// One shared model for Game library and Library storage: This Mac, every connected drive, and honest placeholders.
    func storageOverviewEntries() -> [StorageOverviewEntry] {
        guard let storage = storageStatus else {
            return [StorageOverviewEntry(id: nil, mode: "local", title: "This Mac", state: "checking", active: false, path: nil),
                    StorageOverviewEntry(id: nil, mode: "portable", title: "External SSD", state: "checking", active: false, path: nil)]
        }
        var entries: [StorageOverviewEntry] = []
        var activeFound = false
        for mode in ["local", "portable"] {
            for location in storage.locations where location.drive.mode == mode {
                let drive = location.drive
                let state = location.environment ?? (location.configured ? "ready" : "absent")
                let active = storage.active.map { $0.id == drive.id && $0.uuid == drive.uuid } ?? false
                activeFound = activeFound || active
                entries.append(StorageOverviewEntry(id: drive.id, mode: mode, title: driveTitle(drive), state: state,
                                                    active: active && state == "ready", path: drive.root))
            }
        }
        if storage.active != nil && !activeFound {
            entries.append(StorageOverviewEntry(id: nil, mode: "portable", title: "Active library", state: "disconnected", active: true, path: nil))
        }
        if !entries.contains(where: { $0.mode == "portable" && $0.id != nil }) {
            entries.append(StorageOverviewEntry(id: nil, mode: "portable", title: "External SSD", state: "connect", active: false, path: nil))
        }
        return entries
    }

    private func storageStateLabel(_ entry: StorageOverviewEntry) -> (text: String, symbol: String?, color: NSColor) {
        switch entry.state {
        case "ready": return ("Ready" + (entry.active ? " · Active" : ""), "checkmark.circle.fill", .systemGreen)
        case "absent": return ("Not set up", "plus.circle.fill", .systemGray)
        case "occupied": return ("Not set up · A Couch Cube folder is already there", "exclamationmark.circle.fill", .systemOrange)
        case "invalid": return ("Needs attention", "exclamationmark.triangle.fill", .systemOrange)
        case "disconnected": return ("Disconnected · Reconnect its drive", "bolt.horizontal.circle.fill", .systemGray)
        case "connect": return ("Connect one", nil, .systemGray)
        default: return ("Checking...", nil, .systemGray)
        }
    }

    /// Drive icon with its readiness drawn on it, as in Library Settings.
    private func storageIconView(_ entry: StorageOverviewEntry) -> NSView {
        let icon = NSImageView()
        storageModeIcon(icon, mode: entry.mode)
        icon.identifier = NSUserInterfaceItemIdentifier("storage-overview-icon")
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 44), container.heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor), icon.topAnchor.constraint(equalTo: container.topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 36)
        ])
        let state = storageStateLabel(entry)
        if let symbol = state.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.text) {
            let badge = NSImageView(image: image)
            badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, state.color]))
            badge.identifier = NSUserInterfaceItemIdentifier("storage-overview-badge")
            badge.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                badge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                badge.widthAnchor.constraint(equalToConstant: 17), badge.heightAnchor.constraint(equalToConstant: 17)
            ])
        }
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.image)
        container.setAccessibilityLabel(entry.title + ", " + state.text)
        return container
    }

    func storageOverviewRow(_ entry: StorageOverviewEntry, navigable: Bool = true) -> StorageOverviewRow {
        let view = StorageOverviewRow()
        view.identifier = NSUserInterfaceItemIdentifier("storage-overview-row")
        let state = storageStateLabel(entry)
        let title = text(entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        let status = text(state.text, size: 11, secondary: true)
        status.identifier = NSUserInterfaceItemIdentifier("storage-overview-status")
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        var lines: [NSView] = [title, status]
        if let path = entry.path, !["absent", "checking", "connect", "disconnected"].contains(entry.state) {
            let link = pill((path as NSString).abbreviatingWithTildeInPath, symbol: "folder", action: #selector(openBIOSFolder(_:)),
                            value: path, help: "Open " + path + " in Finder")
            link.identifier = NSUserInterfaceItemIdentifier(path)
            link.lineBreakMode = .byTruncatingMiddle
            link.setContentCompressionResistancePriority(.init(490), for: .horizontal)
            lines.append(link)
        }
        let labels = column(lines)
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var parts: [NSView] = [storageIconView(entry), labels, spacer]
        if navigable, let id = entry.id {
            view.driveID = id
            view.onOpen = { [weak self] id in self?.showDriveDetail(id) }
            let chevron = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Manage \(entry.title)")!,
                                   target: self, action: #selector(openDriveDetail(_:)))
            chevron.isBordered = false
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.identifier = NSUserInterfaceItemIdentifier(id)
            chevron.toolTip = "Manage \(entry.title)"
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.widthAnchor.constraint(equalToConstant: 18).isActive = true
            parts.append(chevron)
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel("\(entry.title), \(state.text). Manage drive")
            view.toolTip = "Manage \(entry.title)"
        }
        if entry.state == "connect" {
            view.alphaValue = 0.45
            view.toolTip = "Connect an external SSD to keep games on it"
        }
        let content = row(parts)
        content.distribution = .fill
        content.spacing = 12
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        return view
    }

    /// Re-renders rows only when something visible changed, so silent refreshes don't flicker.
    private func renderStorageOverview() {
        let entries = storageOverviewEntries()
        for rows in [gameLibraryOverviewRows] {
            guard storageOverviewRendered[ObjectIdentifier(rows)] != entries else { continue }
            storageOverviewRendered[ObjectIdentifier(rows)] = entries
            clearRows(rows)
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    let line = separator()
                    rows.addArrangedSubview(line)
                    line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                }
                let view = storageOverviewRow(entry)
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
    }

    @objc private func openDriveDetail(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showDriveDetail(id)
    }

    func showDriveDetail(_ id: String) {
        let page = currentPage
        if page != 12 { driveDetailParent = 6 }
        if driveDetailID != id { driveDetailLoading = false }
        driveDetailID = id
        renderDriveDetail()
        selectPage(12)
        loadDriveDetail()
        if storageStatus?.locations.contains(where: { $0.drive.id == id }) ?? true {
            loadDriveGames(id)
            renderDriveDetail()
        }
    }

    /// Reads one drive in the background; older or other-drive results never overwrite the current page.
    func loadDriveDetail() {
        guard let id = driveDetailID else { return }
        guard task == nil else { driveDetailPending = true; return }
        driveDetailPending = false
        driveDetailGeneration += 1
        let generation = driveDetailGeneration
        driveDetailLoading = true
        if driveDetailCache[id] == nil { renderDriveDetail() }
        backendRead(["drive-detail", "--drive", id]) { code, data in
            guard generation == self.driveDetailGeneration else { return }
            self.driveDetailLoading = false
            if code == 0, let detail = try? JSONDecoder().decode(DriveDetail.self, from: data) {
                self.driveDetailCache[id] = detail
                self.driveDetailErrors[id] = nil
            } else {
                self.driveDetailErrors[id] = self.lastError.isEmpty ? "Couldn't read this drive." : self.lastError
            }
            if self.driveDetailID == id { self.renderDriveDetail() }
        }
    }

    /// Starts (or reuses) the per-game size scan for one drive. Results for another drive or an older scan are dropped.
    func loadDriveGames(_ id: String, force: Bool = false) {
        if !force, driveGamesScanning == id { return }
        if !force, let cached = driveGamesCache[id], Date().timeIntervalSince(cached.scanned) < 300 { return }
        driveGamesGeneration += 1
        let generation = driveGamesGeneration
        driveGamesScanning = id
        driveGamesErrors[id] = nil
        driveGamesRead(id) { code, data in
            guard generation == self.driveGamesGeneration else { return }
            self.driveGamesScanning = nil
            if code == 0, let games = DriveGames.decode(data), games.drive.id == id {
                self.driveGamesCache[id] = (games, Date())
            } else {
                self.driveGamesErrors[id] = "Couldn't measure games on this drive."
            }
            if self.driveDetailID == id { self.renderDriveDetail() }
        }
    }

    /// Cancels a running scan, e.g. when its drive is unplugged; nothing is written either way.
    private func cancelDriveGames(_ id: String) {
        driveGamesCache[id] = nil
        guard driveGamesScanning == id else { return }
        driveGamesGeneration += 1
        driveGamesScanning = nil
        driveGamesProcess?.terminate()
        driveGamesProcess = nil
    }

    private func runDriveGamesScan(_ id: String, _ done: @escaping (Int32, Data) -> Void) {
        driveGamesProcess?.terminate()
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path, "drive-games", "--drive", id]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        driveGamesProcess = process
        do { try process.run() } catch { driveGamesProcess = nil; done(1, Data()); return }
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                if self.driveGamesProcess === process { self.driveGamesProcess = nil }
                done(process.terminationStatus, data)
            }
        }
    }

    @objc private func toggleDriveStorageGrouping(_ sender: NSButton) {
        let key = sender.identifier?.rawValue == "drive-group-roms" ? romsBySystemKey : pcByLauncherKey
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        renderDriveDetail()
    }

    @objc private func toggleDriveStorageShowAll() {
        driveGamesShowAll.toggle()
        renderDriveDetail()
    }

    @objc private func rescanDriveGames() {
        guard let id = driveDetailID, detailDrive != nil else { return }
        loadDriveGames(id, force: true)
        renderDriveDetail()
    }

    /// Bottom-of-page breakdown: each game's share of the games found on this drive, not of the drive's capacity.
    private func driveGamesSection(_ id: String) -> NSView {
        let rescan = button("Rescan", #selector(rescanDriveGames))
        rescan.identifier = NSUserInterfaceItemIdentifier("drive-games-rescan")
        rescan.isEnabled = driveGamesScanning != id
        let scanning = driveGamesScanning == id
        guard let games = driveGamesCache[id]?.games else {
            let message = driveGamesErrors[id].map { $0 + " Nothing was changed." } ?? "Measuring games on this drive..."
            let status: NSView = driveGamesErrors[id] == nil
                ? statusIndicator(message, color: .systemBlue, pulsing: true) : text(message, size: 12, secondary: true)
            return detailSection("Game storage", trailing: [rescan], views: [status])
        }
        let romsBySystem = UserDefaults.standard.bool(forKey: romsBySystemKey)
        let pcByLauncher = UserDefaults.standard.bool(forKey: pcByLauncherKey)
        let slices = GameStorageSlice.slices(games, romsBySystem: romsBySystem, pcByLauncher: pcByLauncher)
        var views: [NSView] = []
        let checked = games.coverage.filter { $0.status != "unsupported" }.map { $0.games > 0 ? "\($0.name) (\($0.games))" : $0.name }
        let unsupported = games.coverage.filter { $0.status == "unsupported" }.compactMap(\.note)
        if games.items.isEmpty {
            views.append(text("No games found on this drive.", size: 13))
        } else {
            let total = ByteCountFormatter.string(fromByteCount: games.total, countStyle: .file)
            let denominator = text("Share of \(total) of games found on this drive (not of the drive's size).", size: 12, secondary: true)
            denominator.identifier = NSUserInterfaceItemIdentifier("drive-games-total")
            let bar = GameStorageBar()
            bar.identifier = NSUserInterfaceItemIdentifier("drive-games-bar")
            bar.segments = GameStorageBar.segments(for: slices)
            let roms = NSButton(checkboxWithTitle: "Group ROMs by system", target: self, action: #selector(toggleDriveStorageGrouping(_:)))
            roms.identifier = NSUserInterfaceItemIdentifier("drive-group-roms")
            roms.state = romsBySystem ? .on : .off
            let pc = NSButton(checkboxWithTitle: "Group PC games by launcher", target: self, action: #selector(toggleDriveStorageGrouping(_:)))
            pc.identifier = NSUserInterfaceItemIdentifier("drive-group-pc")
            pc.state = pcByLauncher ? .on : .off
            let toggles = row([roms, pc, NSView()])
            toggles.distribution = .fill
            views += [bar, denominator, toggles]
            let colors = Dictionary(uniqueKeysWithValues: slices.filter { ($0.bytes ?? 0) > 0 }.prefix(GameStorageBar.colored)
                .enumerated().map { ($1.id, GameStorageBar.colors[$0]) })
            let limit = 12
            for slice in driveGamesShowAll ? slices : Array(slices.prefix(limit)) {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = (colors[slice.id] ?? .tertiaryLabelColor).cgColor
                dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
                func single(_ value: String, _ size: CGFloat, secondary: Bool = false) -> NSTextField {
                    let field = NSTextField(labelWithString: value)
                    field.font = .systemFont(ofSize: size)
                    field.textColor = secondary ? .secondaryLabelColor : .labelColor
                    field.lineBreakMode = .byTruncatingTail
                    return field
                }
                let name = single(slice.title, 13)
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                var notes = [slice.detail]
                if slice.unknown > 0 { notes.append(slice.unknown == 1 ? "1 size unknown" : "\(slice.unknown) sizes unknown") }
                if slice.partial { notes.append("some files unreadable") }
                let detail = single(notes.joined(separator: " · "), 11, secondary: true)
                detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
                let size = single(slice.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown", 13)
                size.alignment = .right
                let percent = single(slice.percent, 12, secondary: true)
                percent.alignment = .right
                percent.widthAnchor.constraint(equalToConstant: 48).isActive = true
                let line = row([dot, name, detail, NSView(), size, percent])
                line.distribution = .fill
                line.identifier = NSUserInterfaceItemIdentifier("drive-games-row")
                line.setAccessibilityElement(true)
                line.setAccessibilityLabel("\(slice.title), \(size.stringValue), \(slice.percent)")
                views.append(line)
            }
            if slices.count > limit {
                let more = button(driveGamesShowAll ? "Show fewer" : "Show all \(slices.count)", #selector(toggleDriveStorageShowAll))
                more.identifier = NSUserInterfaceItemIdentifier("drive-games-more")
                views.append(row([more, NSView()]))
            }
        }
        var status: [String] = []
        if scanning { status.append("Rescanning...") }
        if !scanning, driveGamesErrors[id] != nil { status.append("The last rescan failed; showing earlier results.") }
        if games.unknown > 0 { status.append("\(games.unknown) with unknown size, left out of the bar.") }
        if games.partial > 0 { status.append("\(games.partial) only partly readable, so they may be larger.") }
        if games.items.contains(where: { !$0.measured && $0.bytes != nil }) { status.append("Missing Steam folders use Steam's reported size.") }
        if games.shared > 0 { status.append("Shared files are counted once.") }
        status.append("Checked: " + checked.joined(separator: ", ") + ".")
        status += unsupported
        let note = text(status.joined(separator: " "), size: 11, secondary: true)
        note.identifier = NSUserInterfaceItemIdentifier("drive-games-status")
        views.append(note)
        return detailSection("Game storage", subtitle: "Which games take the most space here. Nothing is deleted from this view.", trailing: [rescan], views: views)
    }

    private func detailSection(_ title: String, subtitle: String? = nil, trailing: [NSView] = [], views: [NSView]) -> NSView {
        let heading = text(title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let header = row([heading, NSView()] + trailing)
        header.distribution = .fill
        var content: [NSView] = [header]
        if let subtitle = subtitle { content.append(text(subtitle, size: 12, secondary: true)) }
        return card("", subtitle: nil, views: content + views)
    }

    func renderDriveDetail() {
        clearRows(driveDetailRows)
        guard let id = driveDetailID else { return }
        func add(_ view: NSView) {
            driveDetailRows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: driveDetailRows.widthAnchor).isActive = true
        }
        let location = storageStatus?.locations.first { $0.drive.id == id }
        let detail = driveDetailCache[id]
        let drive = location?.drive ?? detail?.drive
        let title = drive.map(driveTitle) ?? "Drive"
        if currentPage == 12 { screenTitle.stringValue = title }
        if storageStatus != nil && location == nil {
            cancelDriveGames(id)
            add(detailSection(title, subtitle: "Disconnected. Reconnect this drive to see its library, storage and games. Nothing on it was changed.", views: []))
            return
        }
        guard let entry = storageOverviewEntries().first(where: { $0.id == id }) ?? drive.map({
            StorageOverviewEntry(id: $0.id, mode: $0.mode, title: driveTitle($0), state: "checking", active: false, path: $0.root)
        }) else {
            add(detailSection("Drive", subtitle: "Checking connected drives...", views: []))
            return
        }
        var library: [NSView] = [storageOverviewRow(entry, navigable: false)]
        var actions: [NSView] = []
        switch entry.state {
        case "ready":
            if !entry.active {
                actions.append(button("Use this library...", #selector(activateDetailDrive)))
            } else {
                actions.append(button("Move library...", #selector(moveLibrary)))
            }
            let remove = button("Remove...", #selector(removeDetailLibrary))
            remove.identifier = NSUserInterfaceItemIdentifier("drive-remove")
            actions.append(remove)
        case "absent":
            library.append(text("No Couch Cube library here yet. Initialize adds a Couch Cube folder with empty game, BIOS and save folders. Nothing existing is changed and your active library stays the same.", size: 12, secondary: true))
            let initialize = button("Initialize...", #selector(initializeDetailDrive))
            initialize.identifier = NSUserInterfaceItemIdentifier("drive-initialize")
            initialize.isEnabled = drive.map { ["apfs", "hfs"].contains($0.filesystem) } ?? false
            if !initialize.isEnabled { initialize.toolTip = "This drive must use APFS or Mac OS Extended. Couch Cube never formats it here." }
            actions.append(initialize)
        case "occupied", "invalid":
            let issue = location?.issue ?? detail?.issue
            library.append(text((issue ?? "This folder isn't a Couch Cube library Couch Cube can verify.") +
                                " Nothing will be overwritten. Rename or move it in Finder, then refresh.", size: 12, secondary: true))
        default:
            break
        }
        if !actions.isEmpty {
            let line = row(actions + [NSView()])
            line.distribution = .fill
            library.append(line)
        }
        add(detailSection("Couch Cube library", views: library))
        let loadingDetail = driveDetailLoading && detail == nil
        if let capacity = detail?.capacity {
            func amount(_ label: String, _ bytes: Int64, _ identifier: String) -> NSView {
                let value = text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), size: 13)
                value.identifier = NSUserInterfaceItemIdentifier(identifier)
                value.alignment = .right
                let line = row([text(label, size: 13), NSView(), value])
                line.distribution = .fill
                return line
            }
            let bar = NSLevelIndicator()
            bar.levelIndicatorStyle = .continuousCapacity
            bar.minValue = 0
            bar.maxValue = Double(max(capacity.total, 1))
            bar.doubleValue = Double(capacity.used)
            bar.warningValue = bar.maxValue * 0.85
            bar.criticalValue = bar.maxValue * 0.95
            bar.setAccessibilityLabel("Used space")
            add(detailSection("Storage", views: [
                bar,
                amount("Drive size", capacity.total, "drive-total"),
                amount("Used (all files)", capacity.used, "drive-used"),
                amount("Couch Cube files", capacity.couch, "drive-couch"),
                amount("Free space", capacity.free, "drive-free")
            ]))
        } else if loadingDetail {
            add(detailSection("Storage", views: [statusIndicator("Reading this drive...", color: .systemBlue, pulsing: true)]))
        }
        if let detail = detail, !detail.steam.isEmpty {
            var views: [NSView] = []
            for folder in detail.steam {
                let count = folder.games.filter(\.installed).count
                let heading = text(count == 1 ? "1 game" : "\(count) games", size: 11, secondary: true)
                heading.font = .systemFont(ofSize: 11, weight: .semibold)
                let link = pill((folder.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", action: #selector(openBIOSFolder(_:)),
                                value: folder.path, help: "Open " + folder.path + " in Finder")
                link.lineBreakMode = .byTruncatingMiddle
                link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let line = row([heading, link, NSView()])
                line.distribution = .fill
                views.append(line)
                views.append(contentsOf: folder.games.map(steamGameRow))
            }
            add(detailSection("Steam", trailing: [button("Open Steam Storage", #selector(openSteamStorage))], views: views))
        }
        if let detail = detail, !detail.retro.isEmpty {
            let views: [NSView] = detail.retro.map { system in
                let name = text(system.name, size: 13)
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let line = row([name, text(system.games == 1 ? "1 game" : "\(system.games) games", size: 11, secondary: true), NSView(),
                                pill("Open folder", symbol: "folder", action: #selector(openBIOSFolder(_:)),
                                     value: system.path, help: "Open " + system.path + " in Finder")])
                line.distribution = .fill
                line.identifier = NSUserInterfaceItemIdentifier("drive-retro-" + system.id)
                return line
            }
            add(detailSection("Retro games", views: views))
        }
        if location != nil || storageStatus == nil {
            add(driveGamesSection(id))
        }
        let errors = (detail?.errors ?? []) + (driveDetailErrors[id].map { [$0] } ?? [])
        if !errors.isEmpty {
            add(text(errors.prefix(3).joined(separator: "\n"), size: 11, secondary: true))
        }
    }

    private var detailDrive: Drive? {
        driveDetailID.flatMap { id in storageStatus?.locations.first { $0.drive.id == id }?.drive }
    }

    @objc private func activateDetailDrive() {
        guard task == nil, let drive = detailDrive else { return }
        chooseMode(drive.mode)
        populateVolumes(previous: drive.id)
        selectionChanged()
    }

    @objc private func initializeDetailDrive() {
        guard task == nil, let drive = detailDrive else { return }
        let confirm = NSAlert()
        confirm.messageText = "Initialize a library on \(driveTitle(drive))?"
        confirm.informativeText = "Creates \(drive.root) with empty game, BIOS and save folders.\n\nNothing is formatted, overwritten or moved. If that folder already exists, nothing is changed. Your active library stays the same."
        confirm.addButton(withTitle: "Initialize")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        execute(["initialize-drive", "--drive", drive.id, "--confirm"]) { code, _ in
            if code != 0 {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't initialize this drive. Nothing was changed." : self.lastError)
            }
            self.refresh()
        }
    }

    /// Moves only this drive's verified Couch Cube folder to the Trash after a scoped plan and two confirmations.
    @objc private func removeDetailLibrary() {
        guard task == nil, let drive = detailDrive else { return }
        if Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: drive.root).standardizedFileURL.path + "/") {
            storageOperationFailed("Couch Cube is running from this library. Quit it and open a copy from another location first. Nothing was removed.")
            return
        }
        backendRead(["removal-plan", "--drive", drive.id]) { code, data in
            guard code == 0, let plan = try? JSONDecoder().decode(DriveRemovalPlan.self, from: data) else {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't verify this library. Nothing was removed." : self.lastError)
                return
            }
            let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
            let review = NSAlert()
            review.alertStyle = .warning
            review.messageText = "Remove the Couch Cube library on \(self.driveTitle(drive))?"
            review.informativeText = "\(plan.path)\n\(size) · \(plan.files) files\n\nEverything in this folder is removed: ROMs, BIOS files, saves, launchers and settings stored there. The rest of the drive is not erased or formatted, and Steam games are not touched.\n\nBack up first: copy the library to another drive, or open it in Finder and copy what you want to keep."
            review.addButton(withTitle: "Continue...")
            review.addButton(withTitle: "Cancel")
            review.addButton(withTitle: "Show in Finder")
            review.addButton(withTitle: "Copy to another drive...")
            switch review.runModal() {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn:
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plan.path)])
                return
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                self.transferLibrary(from: drive)
                return
            default: return
            }
            let confirm = NSAlert()
            confirm.alertStyle = .critical
            confirm.messageText = "Move this library to the Trash?"
            confirm.informativeText = "\(plan.path)\n\nIt stays in the Trash until you empty it. Anything you didn't back up is lost when the Trash is emptied."
            confirm.showsSuppressionButton = true
            confirm.suppressionButton?.title = "I backed up what I want to keep"
            confirm.addButton(withTitle: "Move to Trash")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            guard confirm.suppressionButton?.state == .on else {
                self.storageOperationFailed("Confirm that you backed up what you want to keep. Nothing was removed.")
                return
            }
            self.execute(["removal-verify", "--drive", drive.id, "--token", plan.token, "--confirm"], capture: true) { code, data in
                guard code == 0, let target = try? JSONDecoder().decode(RetiredLibrary.self, from: data), target.path == plan.path else {
                    self.storageOperationFailed(self.lastError.isEmpty ? "The library changed or couldn't be verified. Nothing was removed." : self.lastError)
                    self.refresh()
                    return
                }
                self.cleanupInProgress = true
                self.busy(true)
                NSWorkspace.shared.recycle([URL(fileURLWithPath: target.path)]) { _, error in
                    DispatchQueue.main.async {
                        self.cleanupInProgress = false
                        self.busy(false)
                        if let error = error {
                            self.storageOperationFailed("Couldn't move the library to Trash: \(error.localizedDescription). Nothing else was changed.")
                        } else {
                            self.append("Moved \(target.path) to the Trash.\n")
                        }
                        self.driveDetailCache[drive.id] = nil
                        self.refresh()
                    }
                }
            }
        }
    }

    private func storageOperationFailed(_ message: String) {
        status.stringValue = message
        append(message + "\n")
        let alert = NSAlert()
        alert.messageText = "Library storage"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func moveLibrary() {
        guard task == nil, let storage = storageStatus,
              let source = storage.locations.first(where: { $0.drive.id == storage.active?.id && $0.configured })?.drive else {
            storageOperationFailed("Set up or activate a connected library before moving it.")
            return
        }
        transferLibrary(from: source)
    }

    private func transferLibrary(from source: Drive) {
        guard task == nil, let storage = storageStatus else { return }
        let destinations = storage.locations.map(\.drive).filter { $0.id != source.id }
        guard !destinations.isEmpty else {
            storageOperationFailed("Connect another writable APFS or Mac OS Extended drive first.")
            return
        }
        let choose = NSAlert()
        choose.messageText = "Move your library"
        choose.informativeText = "From: \(source.root)\n\nChoose a destination. Its Couch Cube folder must not already exist; libraries are never merged. Steam files are not copied. Quit games and emulators before continuing."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 28))
        picker.addItems(withTitles: destinations.map { "\($0.mode == "local" ? "This Mac" : $0.name) · \($0.root)" })
        choose.accessoryView = picker
        choose.addButton(withTitle: "Review transfer")
        choose.addButton(withTitle: "Cancel")
        guard choose.runModal() == .alertFirstButtonReturn,
              destinations.indices.contains(picker.indexOfSelectedItem) else { return }
        let destination = destinations[picker.indexOfSelectedItem]
        execute(["transfer-plan", "--source", source.id, "--destination", destination.id], capture: true) { code, data in
            guard code == 0 else {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't review the library transfer. Open Activity for details." : self.lastError)
                return
            }
            do {
                let plan = try JSONDecoder().decode(LibraryTransferPlan.self, from: data)
                let confirm = NSAlert()
                confirm.messageText = "Copy, verify and activate this library?"
                confirm.informativeText = "From: \(plan.source.root)\nTo: \(plan.destination.root)\nSize: \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))\n\nCopies Couch Cube content except SteamLibrary, checks file contents, and activates the new location. The old library stays untouched until you separately move it to Trash. App installations and emulator data outside this folder are not moved. Keep both drives connected. Save automatic console mode again after moving."
                confirm.addButton(withTitle: "Copy and activate")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
                self.execute(["transfer-library", "--source", source.id, "--destination", destination.id,
                              "--token", plan.token, "--confirm"], capture: true) { code, data in
                    guard code == 0 else {
                        self.storageOperationFailed(self.lastError.isEmpty ? "Library transfer failed. Source files were kept. Open Activity for details." : self.lastError)
                        self.refresh()
                        return
                    }
                    do {
                        let result = try JSONDecoder().decode(LibraryTransferResult.self, from: data)
                        self.lastLibraryTransfer = (result, destination.id)
                        self.preferredMode = destination.mode
                        self.volumeMenu.select(nil)
                        self.refresh()
                        let done = NSAlert()
                        done.messageText = "Library copied and activated"
                        done.informativeText = "\(result.destination)\n\nThe old copy is still at \(result.source). Use Move old library to Trash when ready. Steam files or an old automatic console mode link must be handled first."
                        done.runModal()
                    } catch {
                        self.storageOperationFailed("Couldn't read the transfer result: \(error.localizedDescription). Inspect both libraries before retrying.")
                    }
                }
            } catch {
                self.storageOperationFailed("Couldn't read the transfer plan: \(error.localizedDescription)")
            }
        }
    }

    @objc private func retireOldLibrary() {
        guard task == nil, let transfer = lastLibraryTransfer else { return }
        let confirm = NSAlert()
        confirm.messageText = "Move the old library to Trash?"
        confirm.informativeText = "\(transfer.result.source)\n\nThe new library remains active at \(transfer.result.destination). The old copy is removed only if it still matches the transfer and the copied content is present. Steam files must be moved separately first."
        confirm.addButton(withTitle: "Move to Trash")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        execute(["retire-library", "--destination", transfer.destinationID, "--token", transfer.result.token], capture: true) { code, data in
            guard code == 0 else {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't verify the old library. It was kept." : self.lastError)
                return
            }
            do {
                let target = try JSONDecoder().decode(RetiredLibrary.self, from: data)
                guard target.path == transfer.result.source else {
                    self.storageOperationFailed("The old library path changed. Nothing was removed.")
                    return
                }
                self.cleanupInProgress = true
                self.busy(true)
                NSWorkspace.shared.recycle([URL(fileURLWithPath: target.path)]) { _, error in
                    DispatchQueue.main.async {
                        self.cleanupInProgress = false
                        self.busy(false)
                        if let error = error {
                            self.storageOperationFailed("Couldn't move old library to Trash: \(error.localizedDescription)")
                        } else {
                            self.lastLibraryTransfer = nil
                            self.refresh()
                        }
                    }
                }
            } catch {
                self.storageOperationFailed("Couldn't read the old library path: \(error.localizedDescription)")
            }
        }
    }

    private func chooseMode(_ mode: String) {
        guard task == nil else { status.stringValue = "Wait for the current operation before changing storage."; return }
        preferredMode = mode
        didRouteInitialLibrary = true
        preparationResult.isHidden = true
        populateVolumes(previous: nil)
        selectPage(4)
        selectionChanged()
    }

    private func populateVolumes(previous: String?) {
        volumes = availableVolumes.filter { preferredMode == nil || $0.mode == preferredMode }
        volumeMenu.removeAllItems()
        volumeMenu.addItems(withTitles: volumes.map { $0.name })
        if let previous = previous {
            if let index = volumes.firstIndex(where: { $0.id == previous }) {
                volumeMenu.selectItem(at: index)
            } else {
                volumeMenu.select(nil)
            }
        } else if let activeID = storageStatus?.active?.id,
                  let index = volumes.firstIndex(where: { $0.id == activeID }) {
            volumeMenu.selectItem(at: index)
        } else if let index = volumes.firstIndex(where: {
            $0.mode == "portable" && Bundle.main.bundleURL.path.hasPrefix($0.mount + "/")
        }) {
            volumeMenu.selectItem(at: index)
        }
        let portable = preferredMode == "portable"
        storageHeading.stringValue = portable ? "External SSD" : "Mac storage"
        storageAdvice.stringValue = portable
            ? "Create your game folders on this SSD. Steam storage is configured in Game library's Steam setup guide. Preparing a new SSD is optional and erases it."
            : "Create Couch Cube's folders on this Mac. Steam can keep using its current library. No apps are installed and no Steam games are moved in this step."
        portablePreparation.isHidden = !portable
        renderDrives()
    }

    private func renderDrives() {
        clearRows(driveRows)
        for (index, drive) in volumes.enumerated() {
            let choose = button(index == volumeMenu.indexOfSelectedItem ? "Selected" : "Choose", #selector(selectStorage(_:)))
            choose.tag = index
            choose.state = index == volumeMenu.indexOfSelectedItem ? .on : .off
            let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
            let location = storageStatus?.locations.first { $0.drive.id == drive.id }
            let active = storageStatus?.active?.id == drive.id && storageStatus?.active?.uuid == drive.uuid
            let state = active ? "Active library" : location?.configured == true ? "Library available" : "Not set up"
            let line = settingsRow((drive.mode == "local" ? "Macintosh HD" : drive.name) + (active ? " · Active" : ""),
                                   subtitle: "\(location?.issue ?? state) · \(free) available · \(drive.filesystem.uppercased())\n\(drive.root)",
                                   symbol: drive.mode == "local" ? "internaldrive.fill" : "externaldrive.fill",
                                   color: .systemGray, trailing: choose)
            driveRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: driveRows.widthAnchor).isActive = true
        }
    }

    @objc private func selectStorage(_ sender: NSButton) {
        guard task == nil, volumes.indices.contains(sender.tag) else {
            status.stringValue = "Wait for the current operation before changing storage."
            return
        }
        volumeMenu.selectItem(at: sender.tag)
        renderDrives()
        selectionChanged()
    }

    @objc private func backToChoices() {
        selectPage(6)
    }

    @objc private func continueStorage() {
        guard let report = report, report.issues.isEmpty, selected != nil else { return }
        // Refresh absolute frontend paths when an SSD moves between Macs.
        setup()
    }

    @objc private func showPlayers() { selectPage(1); loadApps() }
    @objc private func showPlayOverview() {
        guard task == nil else { return }
        guard report?.state == "valid layout", report?.issues.isEmpty == true, selected != nil else {
            backToChoices()
            return
        }
        guard effectiveFrontend != nil else { showPlayers(); return }
        playSteam()
    }
    @objc private func showLibraryOverview() { selectPage(6); loadPageData(6) }
    @objc private func showConsoles() { selectPage(7); loadSystems() }

    @objc private func showFinishing() { selectPage(5); loadPageData(5) }

    private func updateSteamGuide() {
        let missing = report?.missing ?? []
        finishAdvice.stringValue = report?.issues.isEmpty != true
            ? "Your library still needs attention. Go back to storage before continuing."
            : missing.contains("steam")
            ? "Using ES-DE only? Skip Steam setup. Configure your selected emulators in App Store and add your ROMs in Game library."
            : "Steam is installed. The steps below happen in Steam; they are not changed by Couch Cube."
        if let drive = selected {
            let path = (drive.root as NSString).appendingPathComponent("SteamLibrary")
            steamStorageAdvice.stringValue = drive.mode == "local"
                ? "Sign in to Steam and use its existing Macintosh HD library. Open Steam Storage to choose the default install location. Couch Cube's folders are for retro games and launchers; existing Steam installs stay where they are."
                : "In Steam Storage → Add Drive, choose another location and select:\n\(path)\n\nCheck the path to identify your SSD. In its ••• menu, rename the Steam library Console Port if offered and choose Make Default. This is a Steam display name, not a disk rename. Use Steam's Move action for existing games.\n\nSteamCMD's force_install_dir does not configure the desktop client's default library. Couch Cube does not edit Steam's library database. Labels vary by Steam version."
            steamStorageAdvice.font = .systemFont(ofSize: 13)
            retroAdvice.stringValue = "In Steam desktop → Games → Add a Non-Steam Game to My Library → Browse, add:\n\(drive.root)/Launchers/Retro.app\n\nES-DE needs the emulators for the consoles you enabled, plus your own games and any BIOS/cores. Add registered game .app shortcuts from Launchers in the same way. Steam shortcuts are not added automatically."
        }
    }

    @objc private func openWebsite() {
        if !NSWorkspace.shared.open(URL(string: "https://marosige.github.io/couch-cube/")!) {
            status.stringValue = "Couldn't open the website: https://marosige.github.io/couch-cube/"
            append(status.stringValue + "\n")
        }
    }

    @objc private func openSteamStorage() {
        guard NSWorkspace.shared.open(URL(string: "steam://open/settings/storage")!) else {
            status.stringValue = "Couldn't open Steam Storage. Open Steam → Settings → Storage manually."
            append(status.stringValue + "\n")
            return
        }
    }

    @objc private func refreshSteamStatus() {
        guard task == nil else {
            status.stringValue = "Wait for the current operation before refreshing Steam status."
            return
        }
        loadSteamStatus()
    }

    private func steamStorageKind(_ library: SteamLibrary) -> String {
        guard library.available,
              let values = try? URL(fileURLWithPath: library.path).resourceValues(forKeys: [.volumeIsInternalKey]),
              let internalVolume = values.volumeIsInternal else { return "Storage type unknown" }
        return internalVolume ? "Local" : "External"
    }

    private var steamOverviewSummary: String {
        guard let report = steamReport else { return "Not checked" }
        if !report.errors.isEmpty { return "Couldn't read some games · Open Game library" }
        let online = report.libraries.filter { $0.available }
        let local = online.filter { steamStorageKind($0) == "Local" }.reduce(0) { $0 + $1.games.filter { $0.installed }.count }
        let external = online.filter { steamStorageKind($0) == "External" }.reduce(0) { $0 + $1.games.filter { $0.installed }.count }
        let unknown = online.filter { steamStorageKind($0) == "Storage type unknown" }.reduce(0) { $0 + $1.games.filter { $0.installed }.count }
        let offline = report.libraries.filter { !$0.available }.count
        return "\(local) local · \(external) external Steam games" +
            (unknown > 0 ? " · \(unknown) other" : "") + (offline > 0 ? " · \(offline) offline libraries" : "")
    }

    private func libraryStorageMenu() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.addItem(withTitle: "")
        popup.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        for (title, symbol, action) in [("Check Library", "checkmark.circle", #selector(checkStorage))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            popup.menu?.addItem(item)
        }
        popup.bezelStyle = .inline
        popup.isBordered = false
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popup.toolTip = "Storage options"
        popup.setAccessibilityLabel("Storage options")
        popup.identifier = NSUserInterfaceItemIdentifier("library-storage-menu")
        popup.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return popup
    }

    private func updateLibrarySummary() {
        var parts: [String] = []
        if let report = steamReport {
            let count = report.libraries.filter(\.available).reduce(0) { $0 + $1.games.filter(\.installed).count }
            parts.append(count == 1 ? "1 Steam game" : "\(count) Steam games")
        }
        let retro = consoleSystems.filter { $0.enabled && $0.emulator_installed != false }.count
        if !consoleSystems.isEmpty {
            parts.append(retro == 1 ? "1 retro console ready" : "\(retro) retro consoles ready")
        }
        librarySummary.stringValue = parts.isEmpty ? "Add a game with +, or install one in Steam." : parts.joined(separator: " · ")
    }

    private func steamGameRow(_ game: SteamGame) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let name = text(game.name, size: 13)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let size = game.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let detail = text(game.installed ? (size ?? "Installed") : game.state + (size.map { " · " + $0 } ?? ""), size: 11, secondary: true)
        let labels = column([name, detail])
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, labels]
        if game.appid.allSatisfy(\.isNumber) {
            let manage = NSButton(title: "Manage", target: self, action: #selector(manageSteamGame(_:)))
            manage.bezelStyle = .rounded
            manage.controlSize = .small
            manage.identifier = NSUserInterfaceItemIdentifier(game.appid)
            manage.toolTip = "Open \(game.name) in Steam to manage, move or uninstall it"
            manage.setAccessibilityLabel("Manage \(game.name) in Steam")
            manage.setContentHuggingPriority(.required, for: .horizontal)
            views.append(manage)
        }
        if game.installed {
            let play = NSButton(title: "Play", target: self, action: #selector(playSteamGame(_:)))
            play.bezelStyle = .rounded
            play.controlSize = .small
            play.identifier = NSUserInterfaceItemIdentifier(game.appid)
            play.setAccessibilityLabel("Play \(game.name)")
            play.setContentHuggingPriority(.required, for: .horizontal)
            views.append(play)
        }
        let line = row(views)
        line.distribution = .fill
        line.spacing = 10
        line.identifier = NSUserInterfaceItemIdentifier("steam-game")
        return line
    }

    /// Steam's documented game details link; moving or uninstalling happens in Steam.
    @objc private func manageSteamGame(_ sender: NSButton) {
        guard let appid = sender.identifier?.rawValue, appid.allSatisfy(\.isNumber),
              let url = URL(string: "steam://nav/games/details/" + appid) else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't open Steam"
            alert.informativeText = "Install or open Steam, then try again."
            alert.runModal()
        }
    }

    @objc private func playSteamGame(_ sender: NSButton) {
        guard let appid = sender.identifier?.rawValue, appid.allSatisfy(\.isNumber),
              let url = URL(string: "steam://rungameid/" + appid) else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't start this game"
            alert.informativeText = "Open Steam, then try again."
            alert.runModal()
        }
    }

    private func renderSteamLibraries() {
        updateLibrarySummary()
        for rows in [steamGuideRows] {
            clearRows(rows)
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 8
            func add(_ view: NSView) {
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            if overviewChecks.contains(.steam) {
                let checking = row([statusIndicator("Checking Steam libraries...", color: .systemBlue, pulsing: true), NSView()])
                checking.distribution = .fill
                add(checking)
            }
            guard let report = steamReport else {
                add(text(overviewCheckFailures.contains(.steam) ? "Couldn't read Steam libraries. Open Activity for details." : "Steam libraries have not been checked yet.", size: 12, secondary: true))
                continue
            }
            for library in report.libraries {
                let count = library.games.filter { $0.installed }.count
                let label = selected.map { URL(fileURLWithPath: $0.root).appendingPathComponent("SteamLibrary").standardizedFileURL.path == URL(fileURLWithPath: library.path).standardizedFileURL.path } == true ? "Console Port · " : ""
                add(text(label + (library.available ? "\(steamStorageKind(library)) · \(count) games installed" : "Disconnected · Connect this drive"), size: 12))
                add(text(library.path, size: 11, secondary: true))
            }
            if !report.libraries.contains(where: { !$0.games.isEmpty }) && report.errors.isEmpty {
                add(text("No Steam games found yet. Open Steam to install your first game.", size: 12, secondary: true))
            }
            if !report.errors.isEmpty {
                add(text("Some games couldn't be checked. Open Steam, then refresh. Activity has technical details.", size: 11, secondary: true))
            }
            if overviewCheckFailures.contains(.steam) && report.errors.isEmpty {
                add(text("Refresh failed. Last results shown; see Activity.", size: 11, secondary: true))
            }
        }
    }

    private func loadSteamStatus() {
        guard task == nil else { return }
        overviewChecks.insert(.steam)
        overviewCheckFailures.remove(.steam)
        renderSteamLibraries()
        renderGeneral()
        execute(["steam-status"], capture: true) { code, data in
            self.overviewChecks.remove(.steam)
            defer { self.renderSteamLibraries(); self.renderGeneral() }
            guard code == 0 else {
                self.overviewCheckFailures.insert(.steam)
                self.append("Couldn't read Steam libraries. " + self.lastError + "\n")
                return
            }
            do {
                let report = try JSONDecoder().decode(SteamLibraryReport.self, from: data)
                self.steamReport = report
                if !report.errors.isEmpty {
                    self.overviewCheckFailures.insert(.steam)
                    self.append(report.errors.joined(separator: "\n") + "\n")
                }
            } catch {
                self.overviewCheckFailures.insert(.steam)
                self.append("Couldn't decode Steam libraries: \(error.localizedDescription)\n")
            }
        }
    }

    @objc private func openBluetooth() {
        bluetoothSettingsOpens += 1
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) {
            controllerStatus.stringValue = "Couldn't open Bluetooth settings. Open System Settings → Bluetooth manually."
        }
    }

    private func openConsoleSettingsURL(_ address: String, name: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(name)"
            alert.informativeText = "Open \(name) manually in System Settings."
            alert.runModal()
            return
        }
    }

    @objc private func openUsersAndGroups() {
        openConsoleSettingsURL("x-apple.systempreferences:com.apple.Users-Groups-Settings.extension", name: "Users & Groups")
    }

    @objc private func openFileVaultSettings() {
        openConsoleSettingsURL("x-apple.systempreferences:com.apple.preference.security?FileVault", name: "Privacy & Security → FileVault")
    }

    @objc private func openLockScreenSettings() {
        openConsoleSettingsURL("x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension", name: "Lock Screen")
    }

    @objc private func openAutomaticLoginGuide() {
        openConsoleSettingsURL("https://support.apple.com/en-us/102316", name: "Apple's automatic login guide")
    }

    @objc private func openGameControllerSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!) {
            controllerStatus.stringValue = "Couldn't open Game Controllers settings. Open System Settings → Game Controllers manually."
        }
    }

    private func controllerButton(_ title: String, _ action: Selector) -> NSButton {
        let control = button(title, action)
        actions.removeAll { $0 === control }
        return control
    }

    @objc private func showControllers() { selectPage(8) }

    @objc private func controllerBluetoothAccess() {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!) {
                controllerStatus.stringValue = "Open System Settings → Privacy & Security → Bluetooth to review access."
            }
        } else if bluetoothManager == nil {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refreshControllers()
        if central.state == .poweredOn { startControllerDiscovery() } else { stopControllerDiscovery() }
    }

    @objc private func controllerConnectionChanged() {
        DispatchQueue.main.async {
            self.renderGeneral()
            if self.controllerPageVisible { self.refreshControllers() }
        }
    }

    private let controllerColors = ControllerPalette.colors

    private func loadControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              let data = UserDefaults.standard.data(forKey: controllerDefaultsKey) else { return }
        do {
            let preferences = try JSONDecoder().decode(ControllerPreferences.self, from: data)
            restoreControllerPreferences(preferences)
        } catch {
            append("Couldn't read controller names: \(error.localizedDescription)\n")
            controllerStatus.stringValue = "Couldn't read saved controller names. Activity has details."
        }
    }

    private func restoreControllerPreferences(_ preferences: ControllerPreferences) {
        controllerAliases = (preferences.aliases ?? [:]).filter { !$0.key.contains("session:") && $0.key != $0.value }
        controllerEntries = preferences.entries.filter { !$0.id.contains("session:") && controllerAliases[$0.id] == nil }.map {
            var entry = $0
            entry.connected = false
            return entry
        }
        controllerCustomizations = preferences.customizations
        let legacyColors = (preferences.colorVersion ?? 1) < 2
        for entry in controllerEntries {
            if let color = controllerCustomizations[entry.id]?.color {
                controllerCustomizations[entry.id]?.color = legacyColors ?
                    ControllerPalette.migratedName(color, for: entry) : ControllerPalette.canonicalName(color, for: entry)
            }
        }
        controllerConnectedFirst = preferences.connectedFirst
        updateControllerSortMenu()
        let knownIDs = Set(controllerEntries.map(\.id))
        var recent: [String] = []
        for id in preferences.recentControllerIDs ?? controllerEntries.suffix(4).map(\.id) {
            let id = canonicalControllerID(id)
            if knownIDs.contains(id) && !recent.contains(id) { recent.append(id) }
        }
        homeSessionControllers = Array(recent.suffix(4))
        homeObservedConnections = []
    }

    private func currentControllerPreferences() -> ControllerPreferences {
        ControllerPreferences(entries: controllerEntries.filter { !$0.id.contains("session:") },
            customizations: controllerCustomizations, connectedFirst: controllerConnectedFirst,
            recentControllerIDs: homeSessionControllers.filter { !$0.contains("session:") },
            aliases: controllerAliases.filter { !$0.key.contains("session:") }, colorVersion: 2)
    }

    private func saveControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        do {
            let data = try JSONEncoder().encode(currentControllerPreferences())
            if data != UserDefaults.standard.data(forKey: controllerDefaultsKey) {
                UserDefaults.standard.set(data, forKey: controllerDefaultsKey)
            }
        } catch {
            controllerStatus.stringValue = "Couldn't save controller names. Activity has details."
            append("Couldn't save controller names: \(error.localizedDescription)\n")
        }
    }

    private func canonicalControllerID(_ id: String) -> String { controllerAliases[id] ?? id }

    private func updateControllerSortMenu() {
        guard controllerSortMenu.numberOfItems > 2 else { return }
        controllerSortMenu.item(at: 1)?.state = controllerConnectedFirst ? .off : .on
        controllerSortMenu.item(at: 2)?.state = controllerConnectedFirst ? .on : .off
        controllerSortMenu.toolTip = controllerConnectedFirst ? "Sorted: connected first, then your order" : "Sorted: your order"
    }

    @objc private func controllerSortChanged(_ sender: NSMenuItem) {
        controllerConnectedFirst = sender.tag == 1
        updateControllerSortMenu()
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    /// Your order is the stored list order. Connected first is a stable partition of that same order.
    private let homeControllerLimit = 4

    /// Home mirrors the Controllers list exactly: same entries, saved order and sort mode, limited to the first slots.
    private func homeControllerList() -> [ControllerEntry] { orderedControllers(controllerEntries) }

    private func orderedControllers(_ entries: [ControllerEntry]) -> [ControllerEntry] {
        guard controllerConnectedFirst else { return entries }
        return entries.filter(\.connected) + entries.filter { !$0.connected }
    }

    private var controllerPageVisible: Bool {
        tabs.selectedTabViewItem === tabs.tabViewItems[0] ||
            tabs.selectedTabViewItem === tabs.tabViewItems[8]
    }

    private func controllerDisplayName(_ entry: ControllerEntry) -> String {
        let custom = controllerCustomizations[entry.id]?.name ?? ""
        return custom.isEmpty ? entry.name : custom
    }

    private func controllerID(from sender: Any) -> String? {
        if let item = sender as? NSMenuItem {
            return (item.representedObject as? String) ?? (item.representedObject as? [String])?.first
        }
        return (sender as? NSView)?.identifier?.rawValue
    }

    private let controllerStatusResistance = NSLayoutConstraint.Priority(490)

    /// Width of the longest status, so in-place Connected ↔ Not connected changes never reuse a narrower width.
    private func controllerStatusWidth(_ font: NSFont) -> CGFloat {
        ["Not connected", "Connecting…", "Connected"].map { text -> CGFloat in
            let label = NSTextField(labelWithString: text)
            label.font = font
            return ceil(label.intrinsicContentSize.width)
        }.max() ?? 0
    }

    private func controllerStatusText(_ entry: ControllerEntry, active: Bool) -> String {
        controllerConnectionStatus(connected: entry.connected, inputDetected: entry.inputDetected,
                                   connecting: controllerBusy.contains(entry.id))
    }

    private func controllerIcon(_ image: NSImage?, color: NSColor, label: String, size: CGFloat = 11) -> NSImageView? {
        guard let image = image else { return nil }
        let view = NSImageView(image: image)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        view.toolTip = label
        view.setAccessibilityLabel(label)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func controllerDetailSeparator() -> NSTextField {
        let dot = NSTextField(labelWithString: "·")
        dot.font = .systemFont(ofSize: 11)
        dot.textColor = .tertiaryLabelColor
        return dot
    }

    private func controllerConnectionViews(_ entry: ControllerEntry) -> [NSView] {
        guard entry.connected else { return [] }
        var views: [NSView] = []
        let transport: NSImage? = entry.transport == "Bluetooth" ? ControllerGlyph.bluetooth :
            entry.transport == "Wired" ? (NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil) ??
                                          NSImage(systemSymbolName: "powerplug", accessibilityDescription: nil)) :
            entry.transport.isEmpty ? nil : NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
        if let icon = controllerIcon(transport, color: .secondaryLabelColor, label: entry.connectionLabel) {
            icon.identifier = NSUserInterfaceItemIdentifier("controller-transport")
            if transport === ControllerGlyph.bluetooth {
                icon.widthAnchor.constraint(equalToConstant: 8).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 11).isActive = true
            }
            views += [controllerDetailSeparator(), icon]
        }
        if let battery = controllerBatteries[entry.id],
           let severity = controllerBatterySeverity(level: battery.level, state: battery.state) {
            let color = controllerBatteryColor(severity)
            let description = controllerBatteryText(level: battery.level, state: battery.state) ?? ""
            let percent = battery.state == .full ? 100 : Int((battery.level * 100).rounded())
            if let icon = controllerIcon(NSImage(systemSymbolName: controllerBatterySymbol(level: battery.level, state: battery.state),
                                                 accessibilityDescription: nil), color: color, label: description, size: 12) {
                icon.identifier = NSUserInterfaceItemIdentifier("controller-battery")
                let value = NSTextField(labelWithString: "\(percent)%")
                value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                value.textColor = severity == .normal ? .secondaryLabelColor : color
                value.identifier = NSUserInterfaceItemIdentifier("controller-battery-text")
                value.toolTip = description
                let battery = row([icon, value])
                battery.spacing = 3
                battery.setAccessibilityElement(true)
                battery.setAccessibilityLabel(description)
                views += [controllerDetailSeparator(), battery]
            }
        }
        return views
    }

    private func controllerMenuButton(_ entry: ControllerEntry, list: Int, position: Int, count: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.addItem(withTitle: "")
        popup.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        popup.menu?.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: Selector, enabled: Bool = true,
                 object: Any? = nil, to menu: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = list
            item.representedObject = object ?? entry.id
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            (menu ?? popup.menu)?.addItem(item)
        }
        add("Customize…", "pencil", #selector(customizeController(_:)))
        add("Move Up", "arrow.up", #selector(moveControllerUp(_:)), enabled: position > 0)
        add("Move Down", "arrow.down", #selector(moveControllerDown(_:)), enabled: position < count - 1)
        let bluetooth = entry.id.hasPrefix("bt:")
        if bluetooth {
            popup.menu?.addItem(.separator())
            if entry.connected && entry.transport == "Bluetooth" {
                add("Disconnect", "xmark.circle", #selector(disconnectController(_:)))
            } else if !entry.connected {
                add("Connect", "link", #selector(connectController(_:)), enabled: !controllerBusy.contains(entry.id))
            }
        }
        let candidates = controllerLinkCandidates(for: entry)
        let linked = controllerAliases.values.contains(entry.id)
        if !candidates.isEmpty || linked {
            popup.menu?.addItem(.separator())
        }
        if !candidates.isEmpty {
            let parent = NSMenuItem(title: "Same Controller As", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: nil)
            let submenu = NSMenu()
            for candidate in candidates {
                add("\(controllerDisplayName(candidate)) · \(candidate.id.hasPrefix("bt:") ? "Bluetooth" : candidate.connectionLabel)",
                    "gamecontroller", #selector(linkControllers(_:)), object: [entry.id, candidate.id], to: submenu)
            }
            parent.submenu = submenu
            popup.menu?.addItem(parent)
        }
        if linked {
            add("Separate USB Connection", "personalhotspot.slash", #selector(unlinkController(_:)))
        }
        popup.menu?.addItem(.separator())
        if bluetooth {
            add("Forget Device…", "trash", #selector(forgetController(_:)), enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        } else {
            add("Remove from List", "trash", #selector(removeControllerFromList(_:)), enabled: !entry.connected)
        }
        popup.bezelStyle = .inline
        popup.isBordered = false
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popup.toolTip = "More options for \(controllerDisplayName(entry))"
        popup.setAccessibilityLabel(popup.toolTip)
        popup.identifier = NSUserInterfaceItemIdentifier("controller-menu:" + entry.id)
        popup.widthAnchor.constraint(equalToConstant: 26).isActive = true
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    /// One Bluetooth identity and one USB identity can be joined. Same-model controllers are never merged automatically.
    private func controllerLinkCandidates(for entry: ControllerEntry) -> [ControllerEntry] {
        guard !entry.id.contains("session:"), entry.id.hasPrefix("bt:") || entry.id.hasPrefix("hid:"),
              !isJoyCon(entry) else { return [] }
        return controllerEntries.filter {
            $0.id != entry.id && !$0.id.contains("session:") && !isJoyCon($0) &&
                (entry.id.hasPrefix("bt:") ? $0.id.hasPrefix("hid:") : $0.id.hasPrefix("bt:")) &&
                !($0.id.hasPrefix("bt:") && controllerAliases.values.contains($0.id)) &&
                !(entry.id.hasPrefix("bt:") && controllerAliases.values.contains(entry.id))
        }
    }

    private func controllerRow(_ entry: ControllerEntry, compact: Bool, list: NSStackView,
                               position: Int, count: Int) -> NSView {
        let customization = controllerCustomizations[entry.id]
        let title = controllerDisplayName(entry)
        let handle = ControllerDragHandle()
        handle.toolTip = "Drag to reorder"
        handle.setAccessibilityLabel("Reorder \(title)")
        handle.onDrag = { [weak self, weak list] point in
            guard let self = self, let list = list else { return }
            self.dragController(entry.id, in: list, to: point)
        }
        handle.onDrop = { [weak self, weak list] point in
            guard let self = self, let list = list else { return }
            self.dropController(entry.id, in: list, at: point)
        }
        let kind = ControllerArtwork.kind(for: entry, artwork: customization?.artwork)
        let image = ControllerArtView(kind: kind)
        let plate = ControllerIconFrame(imageView: image, size: NSSize(width: 52, height: 38), inset: 2)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: compact ? 12 : 13)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = title == entry.name ? title : "\(title) · \(entry.name)"
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSTextField(labelWithString: controllerStatusText(entry, active: false))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let detail = NSStackView(views: [status] + controllerConnectionViews(entry))
        detail.orientation = .horizontal
        detail.spacing = 4
        detail.alignment = .centerY
        let labels = NSStackView(views: [label, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Short statuses beat stack hugging (250) but stay below window resizing (500); long names truncate first.
        detail.setContentCompressionResistancePriority(controllerStatusResistance, for: .horizontal)
        status.setContentCompressionResistancePriority(controllerStatusResistance, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        status.identifier = NSUserInterfaceItemIdentifier("controller-status")
        let reserved = status.widthAnchor.constraint(greaterThanOrEqualToConstant: controllerStatusWidth(status.font!))
        reserved.priority = controllerStatusResistance
        reserved.isActive = true
        let listID = list === homeControllerStatus ? 0 : 1
        let more = controllerMenuButton(entry, list: listID, position: position, count: count)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = row([handle, plate, labels, spacer, more])
        line.spacing = 10
        line.identifier = NSUserInterfaceItemIdentifier("controller-row:" + entry.id)
        if listID == 0 {
            homeControllerInputLabels[entry.id] = status
            homeControllerImages[entry.id] = [image]
            homeControllerRowViews[entry.id] = line
        } else {
            controllerInputLabels[entry.id] = status
            controllerImages[entry.id] = [image]
            controllerRowViews[entry.id] = line
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        }
        return line
    }

    private func renderHomeControllers() {
        let connected = controllerEntries.filter(\.connected)
        for entry in connected where !homeObservedConnections.contains(entry.id) {
            homeSessionControllers.removeAll { $0 == entry.id }
            homeSessionControllers.append(entry.id)
        }
        homeObservedConnections = Set(connected.map(\.id))
        let knownIDs = Set(controllerEntries.map(\.id))
        homeSessionControllers = homeSessionControllers.map(canonicalControllerID).reduce(into: [String]()) { result, id in
            if !result.contains(id) && knownIDs.contains(id) { result.append(id) }
        }
        while homeSessionControllers.count > 4 {
            let index = homeSessionControllers.firstIndex { id in
                !connected.contains { $0.id == id }
            } ?? 0
            homeSessionControllers.remove(at: index)
        }
        let all = homeControllerList()
        let recent = Array(all.prefix(homeControllerLimit))
        // Rebuilding recreates every row and makes neighbours re-layout, so unchanged content is updated in place.
        let signature = homeControllerSignature(recent, total: all.count)
        if signature == homeControllerRenderedSignature, homeControllerRowIDs == recent.map(\.id) {
            for entry in recent { updateHomeControllerActivity(entry.id) }
            saveControllerPreferences()
            return
        }
        homeControllerRenderedSignature = signature
        homeControllerRenderCount += 1
        clearRows(homeControllerStatus)
        homeControllerInputLabels = [:]
        homeControllerImages = [:]
        homeControllerRowViews = [:]
        homeControllerRowIDs = recent.map(\.id)
        if recent.isEmpty {
            homeControllerStatus.addArrangedSubview(text("Connect via USB or Bluetooth", size: 13, secondary: true))
        }
        for (position, entry) in recent.enumerated() {
            let line = controllerRow(entry, compact: true, list: homeControllerStatus, position: position, count: recent.count)
            homeControllerStatus.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: homeControllerStatus.widthAnchor).isActive = true
            updateHomeControllerActivity(entry.id)
        }
        if all.count > recent.count {
            let more = all.count - recent.count
            let note = text("\(more) more in Controllers", size: 11, secondary: true)
            note.identifier = NSUserInterfaceItemIdentifier("home-controller-more")
            homeControllerStatus.addArrangedSubview(note)
        }
        if controllerInputUnavailable {
            homeControllerStatus.addArrangedSubview(text("Input activity unavailable. Check Input Monitoring in macOS Privacy & Security.", size: 12, secondary: true))
        }
        saveControllerPreferences()
    }

    private func homeControllerSignature(_ entries: [ControllerEntry], total: Int) -> String {
        var parts = ["\(total)", "\(controllerInputUnavailable)"]
        for entry in entries {
            let customization = controllerCustomizations[entry.id]
            let battery = controllerBatteries[entry.id].map { "\(Int(($0.level * 100).rounded())):\($0.state.rawValue)" } ?? "-"
            parts.append([entry.id, entry.name, controllerDisplayName(entry), "\(entry.connected)", entry.transport,
                          "\(controllerBusy.contains(entry.id))", customization?.color ?? "",
                          customization?.artwork ?? "", battery].joined(separator: "\u{1f}"))
        }
        return parts.joined(separator: "\u{1e}")
    }

    private func updateHomeControllerActivity(_ id: String) {
        let entry = controllerEntries.first { $0.id == id }
        let connected = entry?.connected == true
        let active = connected && (controllerLastInput[id].map { Date().timeIntervalSince($0.date) < 1.5 } ?? false)
        for label in [homeControllerInputLabels[id], controllerInputLabels[id]].compactMap({ $0 }) {
            if let entry = entry, label.stringValue != controllerStatusText(entry, active: active) {
                label.stringValue = controllerStatusText(entry, active: active)
                label.invalidateIntrinsicContentSize()
            }
        }
        let customization = controllerCustomizations[id]
        let colorName = entry.map { ControllerPalette.resolvedName(customization?.color, for: $0, artwork: customization?.artwork) } ?? "Black"
        let color = connected ? ControllerPalette.color(named: colorName) : .systemGray
        for image in (homeControllerImages[id] ?? []) + (controllerImages[id] ?? []) {
            image.contentTintColor = color
            image.alphaValue = connected ? 1 : 0.55
            image.wantsLayer = true
            image.setAccessibilityValue(active ? "Receiving input" : nil)
            if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if image.layer?.animation(forKey: "controllerActivity") == nil {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 1
                    pulse.toValue = 0.35
                    pulse.duration = 0.35
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    image.layer?.add(pulse, forKey: "controllerActivity")
                }
            } else { image.layer?.removeAnimation(forKey: "controllerActivity") }
        }
    }

    @objc private func customizeController(_ sender: Any) {
        guard let id = controllerID(from: sender),
              let entry = controllerEntries.first(where: { $0.id == id }) else { return }
        let previous = controllerCustomizations[id]
        let alert = NSAlert()
        alert.messageText = "Customize controller"
        alert.informativeText = "Choose a name and icon color in Couch Cube. Leave the name empty to use \(entry.name)."
        let name = NSTextField(string: previous?.name ?? "")
        name.placeholderString = entry.name
        let color = ControllerPalette.menu(selecting: previous?.color ?? "",
                                           automatic: ControllerPalette.defaultName(for: entry, artwork: previous?.artwork))
        let artwork = ControllerArtwork.menu(selecting: previous?.artwork)
        let preview = ControllerCustomizationPreview(controllerName: entry.name, automaticModel: entry.model, colorPopup: color, artworkPopup: artwork)
        let pickers = NSStackView(views: [color, artwork])
        pickers.orientation = .vertical
        pickers.alignment = .leading
        pickers.spacing = 8
        let previewRow = NSStackView(views: [preview.iconFrame, pickers])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 12
        let contents = column([name, previewRow])
        contents.frame = NSRect(x: 0, y: 0, width: 340, height: 108)
        name.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = contents
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response = withExtendedLifetime(preview) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return }
        controllerCustomizations[id] = ControllerCustomization(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                                               color: preview.savedColor,
                                                               artwork: ControllerArtwork.selectedKind(in: artwork))
        renderControllerList()
        renderHomeControllers()
    }

    private func controllerRowIDs(for list: Int) -> [String] { list == 0 ? homeControllerRowIDs : controllerRowIDs }

    /// Moves a controller inside the visible list. With Connected first on, it stays inside its own group.
    private func moveController(_ id: String, toVisibleIndex index: Int, list: Int) {
        let visible = controllerRowIDs(for: list)
        guard let current = visible.firstIndex(of: id) else { return }
        var target = max(0, min(index, visible.count))
        if controllerConnectedFirst {
            let connectedIDs = Set(controllerEntries.filter(\.connected).map(\.id))
            let split = visible.filter { connectedIDs.contains($0) }.count
            target = connectedIDs.contains(id) ? min(target, split) : max(target, split)
        }
        if target > current { target -= 1 }
        guard target != current else { return }
        let ids = reorderedControllerIDs(controllerEntries.map(\.id), moving: id, to: target, among: visible)
        let byID = Dictionary(controllerEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        controllerEntries = ids.compactMap { byID[$0] }
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    @objc private func moveControllerUp(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender),
              let index = controllerRowIDs(for: sender.tag).firstIndex(of: id) else { return }
        moveController(id, toVisibleIndex: index - 1, list: sender.tag)
    }

    @objc private func moveControllerDown(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender),
              let index = controllerRowIDs(for: sender.tag).firstIndex(of: id) else { return }
        moveController(id, toVisibleIndex: index + 2, list: sender.tag)
    }

    private func controllerDropIndex(in list: NSStackView, at point: NSPoint) -> Int {
        let local = list.convert(point, from: nil)
        let ids = list === homeControllerStatus ? homeControllerRowIDs : controllerRowIDs
        let views = list === homeControllerStatus ? homeControllerRowViews : controllerRowViews
        return ids.compactMap { views[$0] }.filter {
            list.isFlipped ? local.y > $0.frame.midY : local.y < $0.frame.midY
        }.count
    }

    private func dragController(_ id: String, in list: NSStackView, to point: NSPoint) {
        let ids = list === homeControllerStatus ? homeControllerRowIDs : controllerRowIDs
        let views = (list === homeControllerStatus ? homeControllerRowViews : controllerRowViews)
        let rows = ids.compactMap { views[$0] }
        guard let last = rows.last, let first = rows.first else { return }
        views[id]?.alphaValue = 0.4
        let index = controllerDropIndex(in: list, at: point)
        let y: CGFloat
        if index < rows.count {
            y = list.isFlipped ? rows[index].frame.minY - 1 : rows[index].frame.maxY - 1
        } else {
            y = list.isFlipped ? last.frame.maxY - 1 : last.frame.minY - 1
        }
        controllerDropIndicator.boxType = .custom
        controllerDropIndicator.borderWidth = 0
        controllerDropIndicator.fillColor = .controlAccentColor
        controllerDropIndicator.cornerRadius = 1
        if controllerDropIndicator.superview !== list { list.addSubview(controllerDropIndicator) }
        controllerDropIndicator.frame = NSRect(x: first.frame.minX, y: y, width: first.frame.width, height: 2)
    }

    private func dropController(_ id: String, in list: NSStackView, at point: NSPoint) {
        controllerDropIndicator.removeFromSuperview()
        let listID = list === homeControllerStatus ? 0 : 1
        (listID == 0 ? homeControllerRowViews : controllerRowViews)[id]?.alphaValue = 1
        moveController(id, toVisibleIndex: controllerDropIndex(in: list, at: point), list: listID)
    }

    private func renderControllerList() {
        clearRows(activeControllerRows)
        controllerInputLabels = [:]
        controllerImages = [:]
        controllerRowViews = [:]
        let ordered = orderedControllers(controllerEntries)
        controllerRowIDs = ordered.map(\.id)
        let split = ordered.filter(\.connected).count
        for (position, entry) in ordered.enumerated() {
            if !activeControllerRows.arrangedSubviews.isEmpty {
                let line = separator()
                activeControllerRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            }
            if controllerConnectedFirst && position == split && split > 0 {
                addSectionHeading("Not connected", to: activeControllerRows)
            }
            let line = controllerRow(entry, compact: false, list: activeControllerRows, position: position, count: ordered.count)
            activeControllerRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            updateHomeControllerActivity(entry.id)
        }
        if ordered.isEmpty {
            activeControllerRows.addArrangedSubview(text("No controllers yet. Plug one in with USB, or put a Bluetooth controller in pairing mode.", size: 12, secondary: true))
        }
        renderDiscoveredControllers()
    }

    /// Home and Controllers list the same discovered devices with the same real Connect action.
    private func renderDiscoveredControllers() {
        // Refreshes and name callbacks repeat often; rebuilding identical rows would move the Connect button under the pointer.
        let signature = discoveredControllers.map { [$0.address, $0.name, "\(controllerBusy.contains("pair:" + $0.address))"]
            .joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        guard signature != discoveredControllersSignature else { return }
        discoveredControllersSignature = signature
        discoveredRenderCount += 1
        clearRows(discoveredControllerRows)
        clearRows(homeDiscoveredControllerRows)
        for device in discoveredControllers {
            discoveredControllerRows.addArrangedSubview(separator())
            let line = discoveredControllerRow(device, compact: false)
            discoveredControllerRows.addArrangedSubview(line)
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            for view in discoveredControllerRows.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: discoveredControllerRows.widthAnchor).isActive = true
            }
            let home = discoveredControllerRow(device, compact: true)
            homeDiscoveredControllerRows.addArrangedSubview(home)
            home.widthAnchor.constraint(equalTo: homeDiscoveredControllerRows.widthAnchor).isActive = true
        }
        discoveredControllerRows.isHidden = discoveredControllers.isEmpty
        homeDiscoveredControllerRows.isHidden = discoveredControllers.isEmpty
    }

    private func discoveredControllerRow(_ device: PairedController, compact: Bool) -> NSView {
        let image = ControllerArtView(kind: ControllerArtwork.kind(name: device.name, preference: nil))
        image.contentTintColor = .tertiaryLabelColor
        let plate = ControllerIconFrame(imageView: image, size: NSSize(width: 52, height: 38), inset: 2)
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: compact ? 12 : 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pairing = controllerBusy.contains("pair:" + device.address)
        let status = NSTextField(labelWithString: pairing ? "Pairing…" : "Ready to pair")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let connect = NSButton(title: "Connect", target: self, action: #selector(pairDiscoveredController(_:)))
        connect.bezelStyle = .rounded
        connect.controlSize = compact ? .small : .regular
        connect.identifier = NSUserInterfaceItemIdentifier(device.address)
        connect.isEnabled = !pairing
        connect.setAccessibilityLabel("Connect \(device.name)")
        connect.widthAnchor.constraint(equalToConstant: compact ? 68 : 76).isActive = true
        connect.setContentCompressionResistancePriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = row([spacer, plate, labels, filler, connect])
        line.spacing = 10
        line.identifier = NSUserInterfaceItemIdentifier(compact ? "home-discovered-controller" : "discovered-controller")
        return line
    }

    private func mergeControllerList(_ connected: [ControllerEntry], paired: [PairedController]) {
        let joyConIDs = Set((controllerEntries + connected).filter(isJoyCon).map(\.id) +
            paired.filter { ControllerArtwork.kind(name: $0.name, preference: nil).hasPrefix("Joy-Con") }
                .compactMap { controllerAddress($0.address).map { "bt:" + $0 } })
        controllerAliases = controllerAliases.filter { !joyConIDs.contains($0.key) && !joyConIDs.contains($0.value) }
        var knownBluetooth = Set(controllerEntries.map(\.id).filter { $0.hasPrefix("bt:") })
        for device in paired { if let address = controllerAddress(device.address) { knownBluetooth.insert("bt:" + address) } }
        var current: [String: ControllerEntry] = [:]
        for var entry in connected {
            if controllerAliases[entry.id] == nil,
               let alias = controllerProfileAlias(for: entry, knownBluetoothIDs: knownBluetooth) {
                adoptControllerProfile(entry.id, into: alias)
            }
            let id = canonicalControllerID(entry.id)
            if let existing = current[id], existing.transport == "Wired" { continue }
            entry = ControllerEntry(id: id, name: entry.name, connected: true, transport: entry.transport, model: entry.model)
            current[id] = entry
        }
        for device in paired {
            guard let address = controllerAddress(device.address) else { continue }
            let id = "bt:\(address)"
            if current[id] == nil {
                current[id] = ControllerEntry(id: id, name: device.name, connected: device.connected, transport: "Bluetooth",
                                              inputDetected: device.connected ? false : nil)
            } else if current[id]?.transport == "Bluetooth", current[id]?.name.lowercased().contains("joy-con") != true {
                current[id]?.name = device.name
            }
        }
        controllerEntries.removeAll { controllerAliases[$0.id] != nil }
        for index in controllerEntries.indices {
            if let updated = current.removeValue(forKey: controllerEntries[index].id) {
                controllerEntries[index] = updated
            } else {
                controllerEntries[index].connected = false
            }
        }
        controllerEntries += current.values.sorted { $0.id < $1.id }
        controllerEntries.removeAll { !$0.connected && $0.id.contains("session:") && !homeSessionControllers.contains($0.id) }
        controllerBusy = controllerBusy.filter { id in !controllerEntries.contains { $0.id == id && $0.connected } }
        discoveredControllers.removeAll { device in
            controllerAddress(device.address).map { knownBluetooth.contains("bt:" + $0) } ?? true
        }
        updateControllerBatteries()
        renderControllerList()
        renderHomeControllers()
    }

    /// GameController exposes battery per controller but not its HID or Bluetooth identity, so only unambiguous names are matched.
    private func updateControllerBatteries() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        var batteries: [String: (level: Float, state: GCDeviceBattery.State)] = [:]
        let gameControllers = GCController.controllers()
        let connected = controllerEntries.filter(\.connected)
        for entry in connected {
            let matches = gameControllers.filter { $0.vendorName == entry.name }
            guard matches.count == 1, connected.filter({ $0.name == entry.name }).count == 1,
                  let battery = matches[0].battery else { continue }
            batteries[entry.id] = (battery.batteryLevel, battery.batteryState)
        }
        controllerBatteries = batteries
    }

    @objc private func linkControllers(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let bluetooth = pair.first { $0.hasPrefix("bt:") }
        let usb = pair.first { $0.hasPrefix("hid:") }
        guard let canonical = bluetooth, let alias = usb,
              let canonicalEntry = controllerEntries.first(where: { $0.id == canonical }),
              let aliasEntry = controllerEntries.first(where: { $0.id == alias }) else { return }
        let alert = NSAlert()
        alert.messageText = "Use one profile for both connections?"
        alert.informativeText = "\(controllerDisplayName(canonicalEntry)) over Bluetooth and \(controllerDisplayName(aliasEntry)) over USB will share one name, color and place in the list. Only do this for the same physical controller."
        alert.addButton(withTitle: "Use One Profile")
        alert.addButton(withTitle: "Cancel")
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test") || alert.runModal() == .alertFirstButtonReturn else { return }
        linkController(alias, to: canonical)
    }

    /// Automatic, device-proven link: the USB profile moves onto the Bluetooth-address profile, keeping its list place.
    private func adoptControllerProfile(_ alias: String, into canonical: String) {
        guard alias != canonical else { return }
        for (key, value) in controllerAliases where value == alias { controllerAliases[key] = canonical }
        controllerAliases[alias] = canonical
        if let custom = controllerCustomizations.removeValue(forKey: alias), controllerCustomizations[canonical] == nil {
            controllerCustomizations[canonical] = custom
        }
        if !controllerEntries.contains(where: { $0.id == canonical }),
           let index = controllerEntries.firstIndex(where: { $0.id == alias }) {
            let old = controllerEntries[index]
            controllerEntries[index] = ControllerEntry(id: canonical, name: old.name, connected: old.connected,
                                                       transport: old.transport, model: old.model)
        }
        homeSessionControllers = homeSessionControllers.map { $0 == alias ? canonical : $0 }
    }

    private func linkController(_ alias: String, to canonical: String) {
        guard !controllerEntries.contains(where: { ($0.id == alias || $0.id == canonical) && isJoyCon($0) }) else { return }
        for (key, value) in controllerAliases where value == alias { controllerAliases[key] = canonical }
        controllerAliases[alias] = canonical
        if controllerCustomizations[canonical] == nil, let custom = controllerCustomizations[alias] {
            controllerCustomizations[canonical] = custom
        }
        controllerCustomizations[alias] = nil
        if let aliasEntry = controllerEntries.first(where: { $0.id == alias }), aliasEntry.connected,
           let index = controllerEntries.firstIndex(where: { $0.id == canonical }) {
            controllerEntries[index].connected = true
            controllerEntries[index].transport = aliasEntry.transport
        }
        controllerEntries.removeAll { $0.id == alias }
        homeSessionControllers = homeSessionControllers.map(canonicalControllerID)
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    @objc private func unlinkController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender) else { return }
        controllerAliases = controllerAliases.filter { $0.value != id }
        saveControllerPreferences()
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            renderControllerList()
            renderHomeControllers()
        } else {
            refreshControllers()
        }
    }

    @objc private func removeControllerFromList(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender),
              controllerEntries.first(where: { $0.id == id })?.connected == false else { return }
        controllerEntries.removeAll { $0.id == id }
        controllerCustomizations[id] = nil
        controllerAliases = controllerAliases.filter { $0.key != id && $0.value != id }
        homeSessionControllers.removeAll { $0 == id }
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    private func bluetoothDevice(for id: String) -> IOBluetoothDevice? {
        guard id.hasPrefix("bt:"), let address = controllerAddress(String(id.dropFirst(3))) else { return nil }
        return IOBluetoothDevice(addressString: dashedControllerAddress(address))
    }

    /// Connect/pair problems stay in the app. Bluetooth Settings only opens from its own explicit header button.
    private func showControllerError(_ title: String, _ message: String) {
        append("\(title): \(message)\n")
        controllerErrors.append(title)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func bluetoothErrorText(_ code: IOReturn) -> String {
        String(format: "macOS Bluetooth error 0x%08X.", UInt32(bitPattern: code))
    }

    @objc private func connectController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender) else { return }
        guard CBManager.authorization == .allowedAlways else {
            showControllerError("Bluetooth access needed", "Allow Bluetooth access for Couch Cube, then try again.")
            return
        }
        guard let device = bluetoothDevice(for: id) else {
            showControllerError("Couldn't find this controller", "macOS has no Bluetooth device with this address.")
            return
        }
        let result = device.openConnection(self)
        guard result == kIOReturnSuccess else {
            showControllerError("Couldn't connect", "\(bluetoothErrorText(result)) Turn the controller on, or press its home button, then try again.")
            return
        }
        controllerBusy.insert(id)
        renderControllerList()
        renderHomeControllers()
    }

    @objc(connectionComplete:status:) func bluetoothConnectionComplete(_ device: IOBluetoothDevice?, status: IOReturn) {
        DispatchQueue.main.async {
            if let address = device?.addressString.flatMap(controllerAddress) { self.controllerBusy.remove("bt:" + address) }
            if status != kIOReturnSuccess && device?.isConnected() != true {
                self.showControllerError("Couldn't connect",
                    "\(self.bluetoothErrorText(status)) Most controllers connect when you press their home button. If it still fails, forget it and pair again.")
            }
            self.refreshControllers()
        }
    }

    @objc private func disconnectController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender), let device = bluetoothDevice(for: id) else { return }
        let result = device.closeConnection()
        if result != kIOReturnSuccess {
            showControllerError("Couldn't disconnect", "\(bluetoothErrorText(result)) Turn the controller off, or disconnect it in Bluetooth Settings.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshControllers() }
    }

    @objc private func forgetController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender), let entry = controllerEntries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(controllerDisplayName(entry))?"
        alert.informativeText = "This Mac removes the pairing. Couch Cube keeps its name, color and icon, so they come back when you pair it again."
        alert.addButton(withTitle: "Forget Device")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Forget and Delete Profile")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.last?.hasDestructiveAction = true
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertThirdButtonReturn else { return }
        let deleteProfile = response == .alertThirdButtonReturn
        guard let device = bluetoothDevice(for: id) else {
            showControllerError("Couldn't forget this controller", "macOS has no Bluetooth device with this address.")
            return
        }
        // macOS has no public unpair API. This uses IOBluetooth's remove method when available and verifies the result.
        let remove = Selector(("remove"))
        if device.responds(to: remove) { _ = device.perform(remove) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if device.isPaired() {
                self.showControllerError("Forget it in Bluetooth Settings",
                    "This version of macOS didn't let Couch Cube remove the pairing. In Bluetooth Settings, choose ⓘ next to \(entry.name), then Forget This Device.")
                return
            }
            self.forgetControllerPairing(id, deleteProfile: deleteProfile)
            self.refreshControllers()
        }
    }

    /// Forgetting removes the Mac's pairing and the list row only. Name, color, icon and links stay keyed by the
    /// controller's Bluetooth address, so pairing it again restores them, unless the profile is explicitly deleted.
    private func forgetControllerPairing(_ id: String, deleteProfile: Bool) {
        controllerEntries.removeAll { $0.id == id }
        homeSessionControllers.removeAll { $0 == id }
        if deleteProfile {
            controllerCustomizations[id] = nil
            controllerAliases = controllerAliases.filter { $0.value != id }
        }
        saveControllerPreferences()
    }

    private func startControllerDiscovery() {
        guard bluetoothInquiry == nil, !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              CBManager.authorization == .allowedAlways, bluetoothManager?.state == .poweredOn,
              controllerPageVisible else { return }
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else { return }
        inquiry.inquiryLength = 8
        inquiry.updateNewDeviceNames = true
        let result = inquiry.start()
        guard result == kIOReturnSuccess else {
            append("Bluetooth controller search failed: \(bluetoothErrorText(result))\n")
            return
        }
        bluetoothInquiry = inquiry
    }

    private func stopControllerDiscovery() {
        bluetoothInquiry?.stop()
        bluetoothInquiry = nil
        bluetoothInquiryRestart?.cancel()
        bluetoothInquiryRestart = nil
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        addDiscoveredController(device)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        addDiscoveredController(device)
    }

    private func addDiscoveredController(_ device: IOBluetoothDevice?) {
        guard let device = device, !device.isPaired(), let name = device.name,
              isBluetoothController(deviceClass: device.classOfDevice, name: name),
              let raw = device.addressString, controllerAddress(raw) != nil else { return }
        let found = PairedController(name: name, address: raw, connected: false)
        if let index = discoveredControllers.firstIndex(where: { controllerAddress($0.address) == controllerAddress(raw) }) {
            discoveredControllers[index] = found
        } else {
            discoveredControllers.append(found)
        }
        renderDiscoveredControllers()
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        bluetoothInquiry = nil
        guard !aborted else { return }
        if error != kIOReturnSuccess { append("Bluetooth controller search ended: \(bluetoothErrorText(error))\n") }
        let restart = DispatchWorkItem { [weak self] in
            self?.bluetoothInquiryRestart = nil
            self?.startControllerDiscovery()
        }
        bluetoothInquiryRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: restart)
    }

    @objc private func pairDiscoveredController(_ sender: NSButton) {
        guard let address = sender.identifier?.rawValue, bluetoothPairing == nil,
              !controllerBusy.contains(where: { $0.hasPrefix("pair:") }) else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            smokePairRequests.append(address)
            return
        }
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        let scanning = bluetoothInquiry != nil
        stopControllerDiscovery()
        controllerBusy.insert("pair:" + address)
        renderDiscoveredControllers()
        // Paging a controller while the discovery scan is still winding down can fail; give the radio a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + (scanning ? 0.8 : 0)) { [weak self] in
            self?.startPairing(device, address: address)
        }
    }

    private func startPairing(_ device: IOBluetoothDevice, address: String) {
        guard let pairing = IOBluetoothDevicePair(device: device) else {
            controllerBusy.remove("pair:" + address)
            renderDiscoveredControllers()
            showControllerError("Couldn't pair", "macOS couldn't start pairing with this controller.")
            startControllerDiscovery()
            return
        }
        pairing.delegate = self
        let result = pairing.start()
        guard result == kIOReturnSuccess else {
            controllerBusy.remove("pair:" + address)
            renderDiscoveredControllers()
            showControllerError("Couldn't pair", "\(bluetoothErrorText(result)) Put the controller back in pairing mode and try again.")
            startControllerDiscovery()
            return
        }
        bluetoothPairing = pairing
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        let alert = NSAlert()
        alert.messageText = "Confirm pairing code"
        alert.informativeText = "Does the controller show \(String(format: "%06u", numericValue))? Most controllers don't have a screen; choose Pair to continue."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        bluetoothPairing?.replyUserConfirmation(alert.runModal() == .alertFirstButtonReturn)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        bluetoothPairing?.stop()
        bluetoothPairing = nil
        controllerBusy = controllerBusy.filter { !$0.hasPrefix("pair:") }
        renderDiscoveredControllers()
        showControllerError("PIN code needed", "This controller asks for a PIN code, which Couch Cube can't enter. Use the Bluetooth Settings button on the Controllers page if you want to pair it there.")
        startControllerDiscovery()
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let device = bluetoothPairing?.device()
        bluetoothPairing = nil
        controllerBusy = controllerBusy.filter { !$0.hasPrefix("pair:") }
        if error != kIOReturnSuccess && device?.isPaired() != true {
            showControllerError("Couldn't pair", "\(bluetoothErrorText(error)) Put the controller back in pairing mode and try again.")
            renderDiscoveredControllers()
        } else if let device = device {
            discoveredControllers.removeAll { controllerAddress($0.address) == device.addressString.flatMap(controllerAddress) }
            if !device.isConnected() { _ = device.openConnection(self) }
            if !device.isConnected(), let address = device.addressString.flatMap(controllerAddress) { controllerBusy.insert("bt:" + address) }
        }
        refreshControllers()
        startControllerDiscovery()
    }

    private func startControllerTest() {
        guard controllerInputManager == nil, !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context = context else { return }
            let owner = Unmanaged<SetupController>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard let message = controllerInputDescription(page: IOHIDElementGetUsagePage(element),
                    usage: IOHIDElementGetUsage(element), value: IOHIDValueGetIntegerValue(value),
                    minimum: IOHIDElementGetLogicalMin(element), maximum: IOHIDElementGetLogicalMax(element)) else { return }
            owner.receiveControllerInput(hidControllerEntry(device), message: message)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            controllerTestStatus.stringValue = "Couldn't start the controller test. Check macOS Privacy & Security → Input Monitoring if access was denied, then reopen this page."
            controllerInputUnavailable = true
            renderHomeControllers()
            append("Controller input access failed: \(result)\n")
            return
        }
        controllerInputManager = manager
        controllerInputUnavailable = false
        controllerTestStatus.stringValue = "Press a button or move a stick to identify and test a controller."
    }

    private func stopControllerTest() {
        guard let manager = controllerInputManager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        controllerInputManager = nil
        controllerLastInput = [:]
    }

    private func receiveControllerInput(_ raw: ControllerEntry, message: String) {
        guard controllerPageVisible else { return }
        let entry = ControllerEntry(id: canonicalControllerID(raw.id), name: raw.name, connected: true, transport: raw.transport)
        let now = Date()
        if let last = controllerLastInput[entry.id], last.message == message && now.timeIntervalSince(last.date) < 0.1 { return }
        if !controllerEntries.contains(where: { $0.id == entry.id }) {
            controllerEntries.append(entry)
            renderControllerList()
            renderHomeControllers()
        } else if let index = controllerEntries.firstIndex(where: { $0.id == entry.id }),
                  !controllerEntries[index].connected {
            controllerEntries[index].connected = true
            controllerEntries[index].transport = entry.transport
            renderControllerList()
            renderHomeControllers()
        }
        controllerLastInput[entry.id] = (message, now)
        if tabs.selectedTabViewItem === tabs.tabViewItems[8] {
            let name = controllerCustomizations[entry.id]?.name ?? ""
            controllerTestStatus.stringValue = "\(name.isEmpty ? entry.name : name) · \(message)"
        }
        updateHomeControllerActivity(entry.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let last = self.controllerLastInput[entry.id],
                  last.date == now else { return }
            self.updateHomeControllerActivity(entry.id)
        }
    }

    private func updateControllerBanner() {
        var visible = true
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            visible = controllerSmokeBanner
            controllerAccessButton.title = "Allow Bluetooth Access"
            controllerStatus.stringValue = "Allow Bluetooth access to see and connect paired controllers. USB controllers work without it."
        } else {
            switch CBManager.authorization {
            case .notDetermined:
                controllerAccessButton.title = "Allow Bluetooth Access"
                controllerAccessButton.isHidden = false
                controllerStatus.stringValue = "Allow Bluetooth access to see and connect paired controllers. USB controllers work without it."
            case .denied, .restricted:
                controllerAccessButton.title = "Open Privacy Settings"
                controllerAccessButton.isHidden = false
                controllerStatus.stringValue = "Bluetooth access is off for Couch Cube. Turn it on in Privacy & Security → Bluetooth."
            case .allowedAlways:
                controllerAccessButton.isHidden = true
                if bluetoothManager?.state == .poweredOff {
                    controllerAccessButton.title = "Bluetooth Settings"
                    controllerAccessButton.isHidden = false
                    controllerStatus.stringValue = "Bluetooth is off. Turn it on to use wireless controllers."
                } else {
                    visible = false
                }
            @unknown default:
                visible = false
            }
        }
        if controllerInputUnavailable {
            visible = true
            controllerStatus.stringValue += (controllerStatus.stringValue.isEmpty ? "" : " ") +
                "Input activity unavailable. Check Input Monitoring in Privacy & Security."
        }
        controllerBanner.isHidden = !visible
        renderGeneral()
    }

    @objc private func refreshControllers() {
        guard controllerPageVisible, !controllerQueryRunning else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            controllerEntries = [
                ControllerEntry(id: "preview:1", name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"),
                ControllerEntry(id: "preview:2", name: "Xbox Wireless Controller", connected: false, transport: "Bluetooth"),
                ControllerEntry(id: "preview:3", name: "8BitDo Controller", connected: true, transport: "Wired")
            ]
            controllerCustomizations["preview:1"] = ControllerCustomization(name: "Purple PS5", color: "Galactic Purple")
            controllerBatteries = ["preview:1": (0.25, .discharging), "preview:3": (0.6, .charging)]
            discoveredControllers = [PairedController(name: "Pro Controller", address: "98-b6-e9-00-00-01", connected: false)]
            updateControllerBanner()
            renderControllerList()
            renderHomeControllers()
            return
        }
        if CBManager.authorization == .allowedAlways && bluetoothManager == nil {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        updateControllerBanner()
        controllerQueryRunning = true
        let readBluetooth = CBManager.authorization == .allowedAlways
        DispatchQueue.global(qos: .userInitiated).async {
            let connected = connectedHIDControllers()
            let devices = readBluetooth ?
                (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> PairedController? in
                    let name = device.name ?? "Game controller"
                    guard isBluetoothController(deviceClass: device.classOfDevice, name: name) else { return nil }
                    return PairedController(name: name, address: device.addressString ?? "Address unavailable", connected: device.isConnected())
                } : []
            DispatchQueue.main.async {
                self.controllerQueryRunning = false
                guard self.controllerPageVisible else { return }
                self.pairedControllers = CBManager.authorization == .allowedAlways ? devices : []
                self.mergeControllerList(connected, paired: self.pairedControllers)
                self.startControllerDiscovery()
            }
        }
    }

    @objc private func openSteamDesktop() {
        guard report?.missing.contains("steam") == false else {
            status.stringValue = "Install Steam in App Store, then return to the Steam setup guide."
            showPlayers()
            return
        }
        if !NSWorkspace.shared.open(URL(string: "steam://open/main")!) {
            status.stringValue = "Couldn't open Steam. Check its installation in App Store."
        }
    }

    @objc private func showSteamFolder() {
        guard let drive = selected else { return }
        let folder = URL(fileURLWithPath: drive.root).appendingPathComponent("SteamLibrary")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            status.stringValue = "Create your game folders in Game library before connecting Steam storage."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func updateSetupSummary() {
        defer { renderGeneral() }
        clearRows(libraryHealth)
        guard let report = report, let drive = selected else {
            libraryHealth.addArrangedSubview(statusIndicator(selected == nil ? "No storage selected" : "Checking library", color: .systemYellow))
            playAction.isEnabled = false
            return
        }
        let foldersReady = report.state == "valid layout" && report.issues.isEmpty
        libraryHealth.addArrangedSubview(statusIndicator(foldersReady ? "Ready" : report.issues.isEmpty ? "Setup required" : "Needs attention",
                                                        color: foldersReady ? .systemGreen : report.issues.isEmpty ? .systemYellow : .systemRed))
        let steamInstalled = !report.missing.contains("steam")
        let retroInstalled = !report.missing.contains("es-de")
        let menu = effectiveFrontend
        playAction.toolTip = menu == "steam" ? "Open Steam Big Picture" : menu == "es-de" ? "Open ES-DE" : "Install your TV menu to play"
        renderStorageLocations()
        setupAppStatus.stringValue = steamInstalled ? "Steam is installed. Optional emulators are managed in App Store." :
            retroInstalled ? "ES-DE is installed and is your console menu." : "Install Steam or ES-DE in App Store to get your TV menu."
        setupConnectionStatus.stringValue = drive.mode == "local"
            ? "Local Steam games stay in Steam's existing library. No storage change needed."
            : "For Steam games on the SSD, add its SteamLibrary in Steam → Settings → Storage."
        playAction.isEnabled = task == nil && foldersReady && menu != nil
    }

    private var effectiveFrontend: String? {
        guard report != nil || !appStates.isEmpty else { return nil }
        func installed(_ id: String) -> Bool {
            if let report = report { return !report.missing.contains(id) }
            return appStates.contains { $0.id == id && $0.installed }
        }
        if let preferred = preferredFrontend ?? report?.preferred_frontend {
            return installed(preferred) ? preferred : nil
        }
        return installed("steam") ? "steam" : installed("es-de") ? "es-de" : nil
    }

    private func renderGeneral() {
        let ready = report?.state == "valid layout" && report?.issues.isEmpty == true
        let frontend = effectiveFrontend
        homeMenuLabel.stringValue = frontend == "steam" ? "Steam Big Picture" :
            frontend == "es-de" ? "ES-DE" : report == nil ? "Checking your console..." : "Choose a TV menu in Console Mode."
        let checking = !overviewChecks.isEmpty && report == nil
        if checking { homeProgress.startAnimation(nil) }
        else { homeProgress.stopAnimation(nil) }
        homeProgress.isHidden = !checking
        if report == nil && !overviewCheckFailures.isEmpty { homeMenuLabel.stringValue = "Couldn't check your console." }
        playAction.isEnabled = task == nil && ready && frontend != nil
        renderHomeControllers()
        let frontendID = frontend == "es-de" ? "es-de.png" : "steam.jpg"
        homePlayBackground.layer?.contentsGravity = frontend == "es-de" ? .resizeAspect : .resizeAspectFill
        homePlayBackground.layer?.backgroundColor = NSColor(srgbRed: 0.025, green: 0.30, blue: 0.40, alpha: 1).cgColor
        if let image = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("TVMenus/\(frontendID)")) {
            homePlayBackground.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        playAction.setAccessibilityLabel("Play · \(homeMenuLabel.stringValue)")
        var tasks: [SidebarTask] = []
        if let report = report, !ready {
            if report.issues.isEmpty {
                tasks.append(SidebarTask(page: 6, color: .systemYellow, title: "Prepare your game library", setup: true))
            } else {
                tasks += report.issues.map { SidebarTask(page: 6, color: .systemRed, title: $0, setup: false) }
            }
        }
        if let report = report {
            if report.missing.contains("steam") && report.missing.contains("es-de") {
                tasks.append(SidebarTask(page: 1, color: .systemRed, title: "Get a TV menu: Steam or ES-DE", setup: true))
            } else if frontend == nil {
                tasks.append(SidebarTask(page: 10, color: .systemYellow, title: "Choose your TV menu", setup: true))
            }
            if installedAppCount(computerGameApps.union(emulatorApps)) == 0 &&
                !(report.missing.contains("steam") && report.missing.contains("es-de")) {
                tasks.append(SidebarTask(page: 1, color: .systemYellow, title: "Get a game app or emulator", setup: true))
            }
        }
        for (check, page, title) in [(OverviewCheck.storage, 6, "Library storage couldn't be checked"),
                                     (.menu, 1, "Apps couldn't be checked"), (.consoles, 7, "Retro consoles couldn't be checked"),
                                     (.automatic, 10, "Console mode couldn't be checked"), (.steam, 6, "Steam couldn't be checked")]
            where overviewCheckFailures.contains(check) {
            tasks.append(SidebarTask(page: page, color: .systemYellow, title: title, setup: false))
        }
        for system in consoleSystems where system.enabled {
            if system.emulator_installed == false {
                tasks.append(SidebarTask(page: 1, color: .systemRed, title: "Get the emulator for \(system.name)", setup: false))
            }
            if ["missing", "partial"].contains(system.bios?.state ?? "") {
                tasks.append(SidebarTask(page: 7, color: .systemRed, title: "Add BIOS files for \(system.name)", setup: false))
            } else if ["optional", "manual"].contains(system.bios?.state ?? "") {
                tasks.append(SidebarTask(page: 7, color: .systemYellow, title: "Check BIOS files for \(system.name)", setup: false))
            }
        }
        for app in appStates where app.installed && app.update?.isEmpty == false {
            tasks.append(SidebarTask(page: 1, color: .systemYellow, title: "Update \(app.name)", setup: false))
        }
        if couchCubeUpdateAvailable {
            tasks.append(SidebarTask(page: 11, color: .systemYellow, title: "Update Couch Cube", setup: false))
        }
        if controllerBluetoothNeedsAttention {
            tasks.append(SidebarTask(page: 8, color: .systemYellow, title: "Allow Bluetooth access", setup: true))
        }
        sidebarTasks = tasks
        let badges: [Int: SidebarBadge]
        if guidedSetup {
            let step = guidedSidebarStep(tasks, pinned: guidedPinnedPage, settled: overviewChecks.isEmpty, previous: sidebarTaskCounts)
            guidedPinnedPage = step.pinned
            badges = step.badges
        } else {
            guidedPinnedPage = nil
            badges = sidebarBadges(tasks, guided: false)
        }
        let attention = badges.mapValues(\.color)
        if sidebarTaskCounts != badges {
            let changed = IndexSet(sidebarPages.indices.filter {
                sidebarPages[$0] >= 0 && sidebarTaskCounts[sidebarPages[$0]] != badges[sidebarPages[$0]]
            })
            sidebarTaskCounts = badges
            sidebarAttention = attention
            if sidebar.numberOfRows == sidebarPages.count {
                for row in changed {
                    if let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                        applySidebarMarkers(to: cell, row: row)
                    } else {
                        sidebar.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                    }
                }
            } else {
                sidebar.reloadData()
            }
        }
    }

    private var controllerBluetoothNeedsAttention: Bool {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return controllerSmokeBanner }
        return CBManager.authorization != .allowedAlways || bluetoothManager?.state == .poweredOff
    }

    @objc private func guidedSetupChanged() {
        guidedSetup = guidedSetupToggle.state == .on
        guidedPinnedPage = nil
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            UserDefaults.standard.set(guidedSetup, forKey: guidedSetupKey)
        }
        renderGeneral()
    }

    private let computerGameApps: Set<String> = ["steam", "steamac", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge"]
    private let emulatorApps: Set<String> = ["retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]

    private func installedAppCount(_ ids: Set<String>) -> Int {
        if let report = report { return ids.subtracting(report.missing).count }
        return appStates.filter { ids.contains($0.id) && $0.installed }.count
    }

    private var overviewAppSummary: String {
        guard report != nil || !appStates.isEmpty else { return "Not checked" }
        let computer = installedAppCount(computerGameApps)
        let emulators = installedAppCount(emulatorApps)
        return "\(computer) PC game app\(computer == 1 ? "" : "s") · \(emulators) emulator\(emulators == 1 ? "" : "s") installed"
    }

    private func controllerOverviewStatus(count: Int) -> NSStackView {
        let dots = (0..<4).map { index -> NSImageView in
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            dot.contentTintColor = index < count ? .systemGreen : .systemGray
            dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            return dot
        }
        let leds = row(dots)
        leds.spacing = 5
        leds.translatesAutoresizingMaskIntoConstraints = false
        let housing = ControllerLEDHousing()
        housing.contentView!.addSubview(leds)
        NSLayoutConstraint.activate([
            leds.leadingAnchor.constraint(equalTo: housing.leadingAnchor, constant: 8),
            leds.trailingAnchor.constraint(equalTo: housing.trailingAnchor, constant: -8),
            leds.centerYAnchor.constraint(equalTo: housing.centerYAnchor),
            housing.heightAnchor.constraint(equalToConstant: 20)
        ])
        let label = NSTextField(labelWithString: count == 0 ? "Not Connected" : "\(count) Connected")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let result = row([housing, label])
        result.spacing = 7
        result.setAccessibilityLabel(label.stringValue)
        return result
    }

    @objc private func refreshGeneral() {
        guard task == nil else { return }
        refresh()
    }

    private func loadGeneralDetails() {
        guard task == nil else { return }
        appsPreloadPending = true
        guard report?.state == "valid layout", let drive = selected else {
            consoleSystems = []
            consolesLoaded = false
            overviewChecks.remove(.consoles)
            renderGeneral()
            loadAutoLaunch()
            return
        }
        let root = drive.root
        execute(["systems", "--root", root], capture: true) { code, data in
            self.overviewChecks.remove(.consoles)
            if self.selected?.root != root {
                // Storage changed meanwhile; its own refresh brings the right consoles.
            } else if code == 0 {
                do {
                    self.acceptSystems(try JSONDecoder().decode([ConsoleSystem].self, from: data))
                } catch {
                    self.overviewCheckFailures.insert(.consoles)
                    self.status.stringValue = "Couldn't read console status: \(error.localizedDescription)"
                    self.append(self.status.stringValue + "\n")
                }
            } else {
                self.overviewCheckFailures.insert(.consoles)
                self.status.stringValue = "Couldn't read console status. Open Details for the error."
            }
            self.renderGeneral()
            self.loadAutoLaunch()
        }
    }

    private func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func pin(_ view: NSView, to host: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func statusIndicator(_ title: String, color: NSColor, pulsing: Bool = false) -> NSView {
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.contentTintColor = color
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        if pulsing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            dot.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "checking")
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let result = row([dot, label])
        result.setHuggingPriority(.required, for: .horizontal)
        result.spacing = 5
        result.setAccessibilityLabel(title)
        return result
    }

    private func addSectionHeading(_ title: String, to rows: NSStackView) {
        let heading = text(title, size: 12, secondary: true)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let container = NSView()
        heading.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: rows.arrangedSubviews.isEmpty ? 4 : 18),
            heading.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        rows.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private func hero(_ title: String, subtitle: String) -> NSStackView {
        let image = NSImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Console.icns"))!)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 88).isActive = true
        image.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let images = row([NSView(), image, NSView()])
        images.arrangedSubviews[0].widthAnchor.constraint(equalTo: images.arrangedSubviews[2].widthAnchor).isActive = true
        let heading = text(title, size: 28)
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.alignment = .center
        let caption = text(subtitle, size: 14, secondary: true)
        caption.alignment = .center
        let result = column([images, heading, caption])
        result.spacing = 16
        return result
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.distribution = .fill
        for view in views {
            if view is NSButton && !(view is StorageChoiceButton) {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            } else {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func card(_ title: String, subtitle: String?, views: [NSView], inset: CGFloat = 16) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.cornerRadius = 12
        box.fillColor = .quaternaryLabelColor
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        let heading = text(title, size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        var contents: [NSView] = title.isEmpty ? [] : [heading]
        if let subtitle = subtitle { contents.append(text(subtitle, size: 12, secondary: true)) }
        contents += views
        let stack = column(contents)
        for view in contents where !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -inset)
        ])
        return box
    }

    private func storeAccountsCard() -> NSBox {
        storeAccountsSummary.font = .systemFont(ofSize: 13, weight: .semibold)
        storeAccountsSummary.setAccessibilityIdentifier("storeAccountsSummary")
        storeAccountsChecked.font = .systemFont(ofSize: 11)
        storeAccountsChecked.lineBreakMode = .byWordWrapping
        storeAccountsChecked.maximumNumberOfLines = 0
        storeAccountsChecked.preferredMaxLayoutWidth = 360
        storeAccountsChecked.textColor = .secondaryLabelColor
        storeAccountsRows.orientation = .vertical
        storeAccountsRows.alignment = .leading
        storeAccountsRows.spacing = 0
        storeWalkthroughPanel.orientation = .vertical
        storeWalkthroughPanel.alignment = .leading
        storeWalkthroughPanel.spacing = 8
        storeWalkthroughPanel.isHidden = true
        let note = text("Shows who is signed in to the game clients on this Mac, read from their own local files. Passwords and sign-in tokens are never read. Each client has its own sign-in: signing in to Steam on the Mac doesn't sign you in to the Windows launchers in CrossOver or Whisky, and the other way round. Deals open in your web browser, which keeps its own logins.",
                        size: 11, secondary: true)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 520
        let header = row([column([storeAccountsSummary, storeAccountsChecked]),
                          button("Set Up Accounts...", #selector(startStoreWalkthrough)),
                          button("Check Again", #selector(checkStoreAccounts))])
        (header.arrangedSubviews[0] as? NSStackView)?.spacing = 2
        header.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        renderStoreAccounts()
        return card("Store Accounts", subtitle: nil, views: [header, note, storeWalkthroughPanel, storeAccountsRows])
    }

    @objc private func checkStoreAccounts() { loadStoreAccounts() }

    func loadStoreAccounts() {
        let check = storeAccounts.begin()
        renderStoreAccounts()
        storeAccountsRead { [weak self] code, data in
            guard let self else { return }
            let report = code == 0 ? try? JSONDecoder().decode(StoreAccountsReport.self, from: data) : nil
            guard self.storeAccounts.finish(check, report: report, at: Date()) else { return }
            if report == nil { self.append("Couldn't check game client sign-ins.\n") }
            self.renderStoreAccounts()
        }
    }

    private func storeAccountRow(_ client: StoreAccountRow) -> NSView {
        let checking = storeAccounts.phase == .checking
        let waiting = storeClientsOpen.contains(client.id)
        let color: NSColor = client.state == "signed_in" ? .systemGreen : client.state == "not_installed" ? .systemGray : .systemOrange
        var detail = client.detail
        if client.kind == "wine", let host = client.host, let bottle = client.bottle { detail += " · \(host) bottle \u{201C}\(bottle)\u{201D}" }
        if client.accounts.count > 1 { detail += " · \(client.accounts.count - 1) more account\(client.accounts.count == 2 ? "" : "s") on this Mac" }
        if waiting { detail = "Waiting for \(client.name) to quit\u{2026}" } else if checking { detail = "Checking\u{2026}" }
        let open: NSButton
        if client.state == "not_installed" {
            open = button("App Store", #selector(showAppStoreForClient(_:)))
        } else {
            open = button("Open", #selector(openStoreClient(_:)))
            open.isEnabled = !waiting
            open.setAccessibilityLabel("Open \(client.name) to sign in")
        }
        open.identifier = NSUserInterfaceItemIdentifier(client.id)
        let again = button("Check Again", #selector(checkStoreAccounts))
        again.isEnabled = !checking
        again.setAccessibilityLabel("Check \(client.name) sign-in again")
        let status = text(detail, size: 11, secondary: true)
        status.setAccessibilityIdentifier("storeAccountStatus")
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        dot.contentTintColor = color
        let line = row([dot, status])
        line.spacing = 5
        let title = client.platform == "Mac" ? client.name + " (Mac client)" : client.name
        let result = settingsRow(title, subtitle: detail, symbol: client.kind == "mac" ? "desktopcomputer" : "pc",
                                 color: client.kind == "mac" ? .systemBlue : .systemIndigo,
                                 trailing: row([open, again]), detail: line)
        result.identifier = NSUserInterfaceItemIdentifier("store-row-" + client.id)
        result.setAccessibilityElement(false)
        status.setAccessibilityLabel("\(title): \(detail)")
        return result
    }

    func renderStoreAccounts() {
        storeAccountsSummary.stringValue = storeAccounts.summary
        storeAccountsChecked.textColor = storeAccountsError == nil ? .secondaryLabelColor : .systemRed
        if let error = storeAccountsError {
            storeAccountsChecked.stringValue = error
        } else if let date = storeAccounts.lastChecked {
            storeAccountsChecked.stringValue = "Last checked " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        } else {
            storeAccountsChecked.stringValue = storeAccounts.phase == .checking ? "Reading local client files\u{2026}" : ""
        }
        storeAccountsRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, client) in (storeAccounts.report?.clients ?? []).enumerated() {
            if index > 0 { storeAccountsRows.addArrangedSubview(separator()) }
            let view = storeAccountRow(client)
            storeAccountsRows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: storeAccountsRows.widthAnchor).isActive = true
        }
        renderStoreWalkthrough()
    }

    private func renderStoreWalkthrough() {
        storeWalkthroughPanel.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let walkthrough = storeWalkthrough, let report = storeAccounts.report else {
            storeWalkthroughPanel.isHidden = true
            return
        }
        storeWalkthroughPanel.isHidden = false
        let heading: NSTextField
        var buttons: [NSView] = []
        if let id = walkthrough.current, let client = report.clients.first(where: { $0.id == id }) {
            let step = (walkthrough.ids.firstIndex(of: id) ?? 0) + 1
            heading = text("Step \(step) of \(walkthrough.ids.count): \(client.name) \u{2014} \(client.detail)", size: 12)
            let open = button("Open \(client.name)", #selector(openStoreClient(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(id)
            open.isEnabled = !storeClientsOpen.contains(id)
            buttons = [open, button("Skip", #selector(skipStoreWalkthrough)), button("Next", #selector(nextStoreWalkthrough))]
            let hint = text(client.state == "signed_in" ? "Already signed in. Choose Next to continue."
                            : "Open it, sign in there, then quit it; the status updates when it closes.", size: 11, secondary: true)
            storeWalkthroughPanel.addArrangedSubview(heading)
            storeWalkthroughPanel.addArrangedSubview(hint)
        } else {
            var summary = walkthrough.ids.isEmpty ? "No game clients are installed yet. Get them in the App Store."
                : "Done \u{2014} \(storeAccounts.summary)."
            let names = walkthrough.skipped.compactMap { id in report.clients.first { $0.id == id }?.name }
            if !names.isEmpty { summary += " Skipped: " + names.joined(separator: ", ") + "." }
            heading = text(summary, size: 12)
            storeWalkthroughPanel.addArrangedSubview(heading)
            buttons = [button("Done", #selector(endStoreWalkthrough))]
        }
        heading.setAccessibilityIdentifier("storeWalkthroughStep")
        heading.lineBreakMode = .byWordWrapping
        heading.maximumNumberOfLines = 0
        storeWalkthroughPanel.addArrangedSubview(row(buttons))
    }

    @objc private func startStoreWalkthrough() {
        guard let report = storeAccounts.report else { loadStoreAccounts(); return }
        storeWalkthrough = StoreAccountsWalkthrough(report: report)
        renderStoreWalkthrough()
    }

    @objc private func nextStoreWalkthrough() { storeWalkthrough?.next(); renderStoreWalkthrough() }
    @objc private func skipStoreWalkthrough() { storeWalkthrough?.skip(); renderStoreWalkthrough() }
    @objc private func endStoreWalkthrough() { storeWalkthrough = nil; renderStoreWalkthrough() }

    @objc private func showAppStoreForClient(_ sender: NSButton) { selectPage(1) }

    @objc private func openStoreClient(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, !storeClientsOpen.contains(id),
              let client = storeAccounts.report?.clients.first(where: { $0.id == id }), client.state != "not_installed" else { return }
        storeClientsOpen.insert(id)
        renderStoreAccounts()
        storeClientOpen(id) { [weak self] code in
            guard let self else { return }
            self.storeClientsOpen.remove(id)
            if code != 0 {
                self.storeAccountsError = "Couldn't open \(client.name). " + (client.kind == "wine"
                    ? "Open \(client.host ?? "CrossOver or Whisky") and start it from its bottle, then choose Check Again."
                    : "Open it from Applications, then choose Check Again.")
            } else {
                self.storeAccountsError = nil
            }
            self.loadStoreAccounts()
        }
    }

    private func settingsRow(_ title: String, subtitle: String, symbol: String, color: NSColor,
                             trailing: NSView, artwork: NSImage? = nil, detail: NSView? = nil,
                             neutralArtworkBackground: Bool = false, bareArtwork: Bool = false) -> NSView {
        let icon = NSImageView(image: artwork ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = artwork?.isTemplate == false ? nil :
            bareArtwork ? .secondaryLabelColor : neutralArtworkBackground ? color : .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = bareArtwork ? NSColor.clear.cgColor :
            neutralArtworkBackground ? NSColor.quaternaryLabelColor.cgColor : color.cgColor
        tile.layer?.cornerRadius = 5
        tile.widthAnchor.constraint(equalToConstant: 26).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 26).isActive = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        if artwork != nil {
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            icon.imageScaling = .scaleProportionallyUpOrDown
        }
        let labels = column([text(title, size: 13), detail ?? text(subtitle, size: 11, secondary: true)])
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let result = row([tile, labels, trailing])
        result.distribution = .fill
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        if let controls = trailing as? NSStackView {
            controls.setHuggingPriority(.required, for: .horizontal)
            for control in controls.arrangedSubviews {
                control.setContentHuggingPriority(.required, for: .horizontal)
            }
        }
        labels.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(greaterThanOrEqualTo: result.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: result.bottomAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: result.trailingAnchor)
        ])
        result.spacing = 12
        return result
    }

    private func addPage(_ title: String, content: NSStackView) {
        let page = NSTabViewItem(identifier: title)
        page.label = title
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let container = TopAlignedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        let isHome = tabs.tabViewItems.isEmpty
        if !isHome {
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
        }
        let width = content.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -16)
        // Below windowSizeStayPut so the capped page width never shrinks the window.
        width.priority = isHome ? .required : NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        width.isActive = true
        page.view = scroll
        tabs.addTabViewItem(page)
    }

    private func selectPage(_ index: Int) {
        // Library storage (2, 3) now lives in Game library.
        if index == 2 || index == 3 { selectPage(6); return }
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        if !replayingHistory && (historyIndex < 0 || pageHistory[historyIndex].page != index ||
            (index == 9 && pageHistory[historyIndex].systemID != inspectorSystemID) ||
            (index == 12 && pageHistory[historyIndex].systemID != driveDetailID)) {
            pageHistory = Array(pageHistory.prefix(historyIndex + 1))
            pageHistory.append((index, index == 9 ? inspectorSystemID : index == 12 ? driveDetailID : nil))
            historyIndex = pageHistory.count - 1
        }
        backToolbarItem.isEnabled = historyIndex > 0
        forwardToolbarItem.isEnabled = historyIndex + 1 < pageHistory.count
        selectingPage = true
        defer { selectingPage = false }
        if index == 5 { updateSteamGuide() }
        tabs.selectTabViewItem(at: index)
        navigationBar.isHidden = false
        mainWindow.title = "Couch Cube"
        screenTitle.stringValue = index == 0 ? "Play" : index == 9 ? inspectorTitle.stringValue :
            index == 12 ? (detailDrive.map(driveTitle) ?? driveDetailCache[driveDetailID ?? ""].map { driveTitle($0.drive) } ?? "Drive") : index == 4 ? "Library storage" :
            index == 5 ? "Steam setup guide" :
            sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube"
        storageNext.isHidden = index != 4
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playAction.keyEquivalent = index == 0 ? "\r" : ""
        let sidebarPage = (index == 3 || index == 4) ? 6 : index == 5 ? 6 : index == 9 ? inspectorParent : index == 12 ? driveDetailParent : index
        if let selected = sidebarPages.firstIndex(of: sidebarPage), sidebar.selectedRow != selected {
            sidebar.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        controllerTimer?.invalidate()
        controllerTimer = nil
        if index != 8 && index != 0 { stopControllerTest() }
        if index != 8 && index != 0 { stopControllerDiscovery() }
        if index == 8 || index == 0 {
            refreshControllers()
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                startControllerTest()
                controllerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshControllers() }
            }
        }
        if index == 0 { renderGeneral() }
        if index == 6 { renderStorageLocations() }
        if index == 13 { openCubeShop() }
        if index == 11, shopCurrency != nil { loadRates(refresh: false) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .sidebarTrackingSeparator, backToolbarItem.itemIdentifier,
         forwardToolbarItem.itemIdentifier, NSToolbarItem.Identifier("PageTitle"), .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == backToolbarItem.itemIdentifier { return backToolbarItem }
        if itemIdentifier == forwardToolbarItem.itemIdentifier { return forwardToolbarItem }
        if itemIdentifier == NSToolbarItem.Identifier("PageTitle") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Page"
            item.view = screenTitle
            item.isBordered = false
            item.visibilityPriority = .high
            return item
        }
        return nil
    }

    @objc private func goBack() { navigateHistory(-1) }
    @objc private func goForward() { navigateHistory(1) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBack) { return historyIndex > 0 }
        if menuItem.action == #selector(goForward) { return historyIndex + 1 < pageHistory.count }
        return true
    }

    private func navigateHistory(_ offset: Int) {
        let next = historyIndex + offset
        guard pageHistory.indices.contains(next) else { return }
        historyIndex = next
        replayingHistory = true
        defer { replayingHistory = false }
        let destination = pageHistory[next]
        if destination.page == 9, let id = destination.systemID,
           let index = consoleSystems.firstIndex(where: { $0.id == id }) {
            let sender = NSButton()
            sender.tag = index
            showConsoleDetails(sender)
        } else if destination.page == 12, let id = destination.systemID {
            showDriveDetail(id)
            return
        } else {
            selectPage(destination.page)
        }
        loadPageData(destination.page)
    }

    private func loadPageData(_ page: Int) {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        if page == 10 { loadAutoLaunch() }
        if page == 11 { loadStoreAccounts() }
        if page == 1 { loadApps() }
        if page == 7 { loadSystems() }
        if page == 5 || page == 6 { loadSteamStatus() }
        if page == 0 { refreshGeneral() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTitles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: sidebarTitles[row])
        if sidebarPages[row] < 0 {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let view = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3)
            ])
            return view
        }
        label.font = .systemFont(ofSize: 13)
        let cell = NSTableCellView()
        cell.textField = label
        let image = NSImageView(image: NSImage(systemSymbolName: sidebarSymbols[row], accessibilityDescription: nil)!)
        image.contentTintColor = .secondaryLabelColor
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        image.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let markers = self.row([])
        markers.spacing = 3
        markers.identifier = NSUserInterfaceItemIdentifier("sidebar-markers")
        markers.setContentHuggingPriority(.required, for: .horizontal)
        // Fixed center-Y anchors: icon and title sit identically whether zero, one or two markers are shown.
        for view in [image, label, markers] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        }
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: markers.leadingAnchor, constant: -6),
            markers.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            markers.heightAnchor.constraint(equalToConstant: 16)
        ])
        cell.imageView = image
        applySidebarMarkers(to: cell, row: row)
        return cell
    }

    /// Refreshes only the markers of an existing sidebar cell, so badge updates never rebuild or re-lay out the title.
    private func applySidebarMarkers(to cell: NSTableCellView, row: Int) {
        guard let markers = cell.subviews.first(where: { $0.identifier?.rawValue == "sidebar-markers" }) as? NSStackView else { return }
        markers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var accessibility = sidebarTitles[row]
        if let badge = sidebarTaskCounts[sidebarPages[row]] {
            let tooltip = badge.groups.map { group in
                (["\(group.count) \(sidebarSeverityName(group.color)):"] + group.titles.map { "• " + $0 }).joined(separator: "\n")
            }.joined(separator: "\n")
            for group in badge.groups {
                let dot = SidebarCountDot(count: group.count, color: group.color)
                let summary = "\(group.count) \(sidebarSeverityName(group.color))"
                dot.toolTip = tooltip
                dot.setAccessibilityElement(true)
                dot.setAccessibilityRole(.staticText)
                dot.setAccessibilityLabel(summary + ": " + group.titles.joined(separator: ", "))
                dot.setContentHuggingPriority(.required, for: .horizontal)
                markers.addArrangedSubview(dot)
            }
            accessibility += ", " + badge.groups.map { "\($0.count) \(sidebarSeverityName($0.color))" }.joined(separator: ", ")
        }
        cell.setAccessibilityLabel(accessibility)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { sidebarPages[row] >= 0 }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { sidebarPages[row] < 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { sidebarPages[row] < 0 ? 28 : 32 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NSTableRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingPage, sidebarPages.indices.contains(sidebar.selectedRow) else { return }
        let page = sidebarPages[sidebar.selectedRow]
        guard page >= 0 else { return }
        guard tabs.selectedTabViewItem !== tabs.tabViewItems[page] else { return }
        selectPage(page)
        loadPageData(page)
    }

    @objc private func openSettings() {
        selectPage(6)
        loadPageData(6)
    }

    @objc private func loadApps() { fetchApps(updates: true) }

    /// Launch preload: App Store data loads in the background once no other command is running.
    private func runPendingAppsPreload() {
        if appsPreloadPending && task == nil && !smokeFinishing { fetchApps(updates: true) }
    }

    private func fetchApps(updates: Bool, completed: ((Bool) -> Void)? = nil) {
        guard task == nil else {
            if completed == nil { appRefreshPending = true }
            appsStatus.stringValue = "An operation is running. App information will refresh when it finishes."
            completed?(false)
            return
        }
        appRefreshPending = false
        appsPreloadPending = false
        loadWindowsDownloads()
        let silent = appsHaveResults
        appsChecking = !silent
        if appStates.isEmpty {
            appsHaveResults = false
            let catalog = [
                ("steam", "Steam"), ("steamac", "FX Steam Launcher"), ("gog-galaxy", "GOG Galaxy"), ("ea", "EA app"),
                ("epic-games", "Epic Games Launcher"), ("battle-net", "Battle.net"),
                ("curseforge", "CurseForge"), ("es-de", "ES-DE"),
                ("retroarch-metal", "RetroArch"), ("dolphin", "Dolphin"),
                ("pcsx2", "PCSX2"), ("rpcs3", "RPCS3"), ("cemu-wiiu", "Cemu"),
                ("switch", "Ryujinx"), ("porting-kit", "Porting Kit"), ("crossover", "CrossOver")
            ]
            appStates = catalog.map {
                ManagedApp(id: $0.0, name: $0.1, installed: false, path: "", version: "",
                           managed: false, update: nil, manual: false, brew: false, url: nil)
            }
        }
        if !silent { renderApps() }
        appsStatus.stringValue = ""
        appsLoadGeneration += 1
        let generation = appsLoadGeneration
        backendRead(updates ? ["apps", "--updates"] : ["apps"]) { code, data in
            guard generation == self.appsLoadGeneration else { return }
            self.appsChecking = false
            if self.overviewChecks.remove(.apps) != nil { self.renderGeneral() }
            guard code == 0 else {
                self.renderApps()
                self.appsStatus.stringValue = "Couldn't read apps. Open Activity for the error."
                self.activityNeeded()
                completed?(false)
                return
            }
            do {
                let decoded = try JSONDecoder().decode([ManagedApp].self, from: data)
                // Unchanged results keep the rendered rows (scroll position, hover, focus) untouched.
                let unchanged = silent && data == self.lastAppsData
                self.lastAppsData = data
                self.appStates = decoded
                // A fresh full check supersedes earlier inline failures.
                let failures = self.appOperations.filter { !$0.value.running }.count
                self.appOperations = self.appOperations.filter { $0.value.running }
                self.appsHaveResults = true
                self.helperButton.isHidden = self.appStates.first?.brew == true
                self.helperAdvice.isHidden = self.helperButton.isHidden
                if let report = self.report {
                    self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                             missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                             preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                    self.updateSetupSummary()
                }
                if !unchanged || failures > 0 { self.renderApps() }
                self.renderTVMenus()
                self.renderGeneral()
                if self.collapsedAppCategories.isEmpty {
                    precondition(self.appMenuRows.arrangedSubviews.count == 4)
                    precondition(self.appPCRows.arrangedSubviews.count == 14)
                    precondition(self.appWindowsRows.arrangedSubviews.count == 4 + 2 * self.windowsDownloads.count)
                    precondition(self.appRetroRows.arrangedSubviews.count == 12)
                }
                precondition(Set([self.appMenuRows, self.appPCRows, self.appWindowsRows, self.appRetroRows]
                    .compactMap { $0.superview?.superview }.map { ObjectIdentifier($0) }).count == 4,
                    "Each Apps category must have its own card")
                self.appsStatus.stringValue = ""
                self.backendRead(["frontend"]) { code, data in
                    guard code == 0 else {
                        self.tvMenuStatus.stringValue = "Couldn't read the default menu. Open Activity for details."
                        completed?(false)
                        return
                    }
                    do {
                        self.preferredFrontend = try JSONDecoder().decode(FrontendPreference.self, from: data).preferred
                        self.renderTVMenus()
                        self.updateSetupSummary()
                        completed?(true)
                    } catch {
                        self.tvMenuStatus.stringValue = "Couldn't read TV menu preference: \(error.localizedDescription)"
                        self.append(self.tvMenuStatus.stringValue + "\n")
                        completed?(false)
                    }
                }
            } catch {
                self.renderApps()
                self.appsStatus.stringValue = "Couldn't read app information: \(error.localizedDescription)"
                self.append(self.appsStatus.stringValue + "\n")
                completed?(false)
            }
        }
    }

    private func clearRows(_ stack: NSStackView) {
        actions.removeAll { $0.isDescendant(of: stack) }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private let collapsedAppCategoriesKey = "collapsedAppCategories"
    private lazy var collapsedAppCategories: Set<String> = ProcessInfo.processInfo.arguments.contains("--smoke-test") ? [] :
        Set(UserDefaults.standard.stringArray(forKey: collapsedAppCategoriesKey) ?? [])
    private var appCategoryToggles: [String: NSButton] = [:]

    private func appCategoryTitle(for rows: NSStackView) -> String {
        rows === appMenuRows ? "TV menus" : rows === appPCRows ? "PC games" :
            rows === appWindowsRows ? "Windows games" : "Retro games"
    }

    private func appCategoryCard(_ title: String, rows: NSStackView) -> NSBox {
        let toggle = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!,
                              target: self, action: #selector(toggleAppCategory(_:)))
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        toggle.identifier = NSUserInterfaceItemIdentifier(title)
        appCategoryToggles[title] = toggle
        updateAppCategoryToggle(title)
        return card("", subtitle: nil, views: [cardHeader(title, buttons: [toggle]), rows])
    }

    private func updateAppCategoryToggle(_ title: String) {
        guard let toggle = appCategoryToggles[title] else { return }
        let collapsed = collapsedAppCategories.contains(title)
        toggle.image = NSImage(systemSymbolName: collapsed ? "chevron.up" : "chevron.down",
                               accessibilityDescription: nil)
        toggle.toolTip = collapsed ? "Show all \(title)" : "Show installed \(title) only"
        toggle.setAccessibilityLabel(toggle.toolTip)
    }

    @objc private func toggleAppCategory(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue else { return }
        if collapsedAppCategories.contains(title) { collapsedAppCategories.remove(title) }
        else { collapsedAppCategories.insert(title) }
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            UserDefaults.standard.set(collapsedAppCategories.sorted(), forKey: collapsedAppCategoriesKey)
        }
        updateAppCategoryToggle(title)
        renderApps()
    }

    private func dealsPage() -> NSView {
        dealsMode.target = self
        dealsMode.action = #selector(dealsModeChanged)
        dealsMode.selectedSegment = UserDefaults.standard.integer(forKey: dealsModeKey) == 1 ? 1 : 0
        dealsMode.setAccessibilityLabel("Deal type")
        dealsSearch.placeholderString = "Search store deals"
        dealsSearch.sendsWholeSearchString = true
        dealsSearch.target = self
        dealsSearch.action = #selector(dealsFiltersChanged)
        dealsSearch.setAccessibilityLabel("Search store deals")
        func popup(_ button: NSPopUpButton, _ items: [(String, String)], label: String, selected: String?) {
            button.removeAllItems()
            for (title, value) in items {
                button.addItem(withTitle: title)
                button.lastItem?.representedObject = value
            }
            if let selected, let index = items.firstIndex(where: { $0.1 == selected }) { button.selectItem(at: index) }
            button.target = self
            button.action = #selector(dealsFiltersChanged)
            button.controlSize = .small
            button.setAccessibilityLabel(label)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        popup(dealsStorePopup, [("Any Store", "")], label: "Store", selected: nil)
        // CheapShark sorts Deals across pages, so these stay server-side; the labels match the other lists' Sort by.
        popup(dealsSortPopup, [("Best Deals", "rating"), ("Biggest Discount", "savings"), ("Lowest Price", "price"), ("Highest Price", "price-desc"),
                               ("Newest", "recent"), ("Best Reviews", "reviews"), ("Name A\u{2013}Z", "title")],
              label: "Sort deals", selected: UserDefaults.standard.string(forKey: dealsSortKey))
        // PC stores and launchers only: console and phone giveaways are never requested or shown.
        popup(giveawayPlatformPopup, [("All PC Stores", ""), ("PC", "pc"), ("Steam", "steam"), ("Epic Games Store", "epic-games-store"),
                                      ("GOG", "gog"), ("itch.io", "itchio"), ("Ubisoft", "ubisoft"), ("EA", "origin"),
                                      ("Battle.net", "battlenet"), ("DRM-Free", "drm-free")],
              label: "Platform", selected: nil)
        popup(giveawayTypePopup, [("All Types", ""), ("Full Games", "game"), ("In-Game Loot", "loot"), ("Beta Access", "beta")],
              label: "Giveaway type", selected: nil)
        // GamerPower sorts by date, value and popularity; Ends Soon and Name sort the fetched list here.
        popup(giveawaySortPopup, [("Newest", "date"), ("Ends Soon", "ends"), ("Highest Value", "value"), ("Most Popular", "popularity"),
                                  ("Name A\u{2013}Z", "name")],
              label: "Sort giveaways", selected: UserDefaults.standard.string(forKey: giveawaySortKey))
        dealsFilters.orientation = .horizontal
        dealsFilters.spacing = 8
        dealsFilters.alignment = .centerY
        dealsRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        dealsRefreshButton.bezelStyle = .inline
        dealsRefreshButton.isBordered = false
        dealsRefreshButton.contentTintColor = .secondaryLabelColor
        dealsRefreshButton.target = self
        dealsRefreshButton.action = #selector(refreshShop)
        dealsRefreshButton.toolTip = "Refresh"
        dealsRefreshButton.setAccessibilityLabel("Refresh")
        dealsProgress.style = .spinning
        dealsProgress.controlSize = .small
        dealsProgress.isDisplayedWhenStopped = false
        dealsStatus.font = .systemFont(ofSize: 11)
        dealsStatus.textColor = .secondaryLabelColor
        dealsRetry.target = self
        dealsRetry.action = #selector(retryDeals)
        dealsRetry.controlSize = .small
        dealsRetry.isHidden = true
        dealsStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dealsStatus.lineBreakMode = .byTruncatingTail
        dealsList.orientation = .vertical
        dealsList.alignment = .leading
        dealsList.spacing = 0
        dealsMore.target = self
        dealsMore.action = #selector(loadMoreDeals)
        dealsMore.isHidden = true
        dealsReminderNote.font = .systemFont(ofSize: 11)
        dealsReminderNote.setAccessibilityIdentifier("dealsReminderNote")
        dealsReminderNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dealsReminderSettings.controlSize = .small
        dealsReminderSettings.target = self
        dealsReminderSettings.action = #selector(openReminderPrivacy)
        dealsReminderBar.orientation = .horizontal
        dealsReminderBar.alignment = .firstBaseline
        dealsReminderBar.spacing = 8
        dealsReminderBar.setViews([dealsReminderNote, dealsReminderSettings], in: .leading)
        dealsReminderBar.isHidden = true
        configureShopPane(dealsPane, [dealsFilters, dealsList, dealsMore], full: [dealsFilters, dealsList])
        dealsList.setAccessibilityIdentifier("dealsList")
        layoutDealsFilters()
        renderDeals()
        return dealsPane
    }

    private func dealsAttribution() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let result = NSMutableAttributedString()
        func plain(_ value: String) { result.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        func link(_ value: String, _ url: String) { result.append(NSAttributedString(string: value, attributes: [.font: font, .link: URL(string: url)!])) }
        plain("Deals by ")
        link("CheapShark", "https://www.cheapshark.com")
        plain(" \u{00B7} Free games by ")
        link("GamerPower", "https://www.gamerpower.com")
        plain(" \u{00B7} App Store via ")
        link("iTunes Search", "https://performance-partners.apple.com/search-api")
        plain(" \u{00B7} Rates by ")
        link("Frankfurter", "https://frankfurter.dev")
        plain(". PC stores only; not a promise a game runs on a Mac.")
        return result
    }

    private func layoutDealsFilters() {
        dealsFilters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Status on the left, the list's own filters and Sort by on the right; titles are found with the search field above.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let views: [NSView] = [dealsStatus, dealsRetry, spacer] + (dealsMode.selectedSegment == 0
            ? [dealsStorePopup, dealsSortPopup]
            : [giveawayPlatformPopup, giveawayTypePopup, giveawaySortPopup])
        views.forEach { dealsFilters.addArrangedSubview($0) }
    }

    private func dealsArguments(page: Int = 0) -> [String] {
        func value(_ button: NSPopUpButton) -> String { (button.selectedItem?.representedObject as? String) ?? "" }
        var arguments: [String]
        if dealsMode.selectedSegment == 0 {
            arguments = ["--source", "cheapshark", "--page", String(page), "--sort", value(dealsSortPopup).isEmpty ? "rating" : value(dealsSortPopup)]
            if !value(dealsStorePopup).isEmpty { arguments += ["--store", value(dealsStorePopup)] }
            let search = dealsSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty { arguments += ["--search", String(search.prefix(100))] }
        } else {
            let sort = value(giveawaySortPopup)
            arguments = ["--source", "gamerpower", "--sort", ["value", "popularity"].contains(sort) ? sort : "date"]
            if !value(giveawayPlatformPopup).isEmpty { arguments += ["--platform", value(giveawayPlatformPopup)] }
            if !value(giveawayTypePopup).isEmpty { arguments += ["--type", value(giveawayTypePopup)] }
        }
        if shopScopeMine { arguments.append("--mine") }
        return arguments
    }

    /// Loads deals only when the Deals page is shown. Identical in-flight requests are coalesced; visible results stay while refreshing.
    private func openDeals() {
        dealsOpened = true
        let key = dealsArguments().joined(separator: "\u{1F}")
        if dealsLoadedKey[dealsMode.selectedSegment] == key { renderDeals(); return }
        loadDeals(page: 0, refresh: false)
    }

    private func loadDeals(page: Int, refresh: Bool) {
        guard dealsOpened else { return }
        let mode = dealsMode.selectedSegment
        let base = dealsArguments(page: page)
        let key = base.joined(separator: "\u{1F}") + (refresh ? "\u{1F}refresh" : "")
        if dealsLoadingKey == key { return }
        dealsLoadingKey = key
        dealsGeneration += 1
        let generation = dealsGeneration
        let filtersKey = dealsArguments().joined(separator: "\u{1F}")
        setShopLoading("deals", true)
        dealsRetry.isHidden = true
        dealsMore.isEnabled = false
        if (mode == 0 ? storeDeals.isEmpty : giveaways.isEmpty) { dealsStatus.stringValue = "Loading\u{2026}" }
        dealsRead(base + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self else { return }
            // Ignore replies for filters or modes the user has already left.
            guard generation == self.dealsGeneration else { return }
            self.dealsLoadingKey = nil
            self.setShopLoading("deals", false)
            self.dealsMore.isEnabled = true
            guard code == 0 else {
                let message = String(decoding: data, as: UTF8.self) + errors
                self.dealsFailed(self.dealsErrorText(message))
                return
            }
            if mode == 0, let reply = decodeDeals(StoreDealsReply.self, data) {
                self.dealsStores = reply.stores
                self.updateDealStores()
                self.storeDeals = page == 0 ? reply.deals : self.storeDeals + reply.deals.filter { deal in !self.storeDeals.contains { $0.id == deal.id } }
                self.storeDealsPage = reply.page
                self.storeDealsHasMore = reply.more
                self.dealsLoadedKey[0] = filtersKey
                if let stores = reply.myStores { self.myStores = stores; self.updateScopeHint() }
                self.renderDeals(reply.stale ? self.dealsErrorText(reply.error ?? "") : nil, fetched: reply.fetched)
            } else if mode == 1, let reply = decodeDeals(GiveawaysReply.self, data) {
                self.giveaways = reply.giveaways
                self.dealsLoadedKey[1] = filtersKey
                if let stores = reply.myStores { self.myStores = stores; self.updateScopeHint() }
                self.renderDeals(reply.stale ? self.dealsErrorText(reply.error ?? "") : nil, fetched: reply.fetched)
            } else {
                self.dealsFailed("The deals service returned data Couch Cube couldn't read.")
            }
        }
    }

    func dealsErrorText(_ raw: String) -> String {
        let message = raw.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "rate-limited:") {
            let seconds = Int(message[range.upperBound...].prefix { $0.isNumber }) ?? 60
            return "The deals service asked Couch Cube to slow down. Try again in about \(max(1, (seconds + 59) / 60)) min."
        }
        return message.isEmpty ? "Couldn't load deals. Check your internet connection." : String(message.prefix(300))
    }

    private func dealsFailed(_ message: String) {
        let empty = dealsMode.selectedSegment == 0 ? storeDeals.isEmpty : giveaways.isEmpty
        dealsStatus.stringValue = empty ? message : "\(message) Showing the last loaded deals."
        dealsRetry.isHidden = false
        dealsMore.isHidden = dealsMode.selectedSegment != 0 || !storeDealsHasMore
    }

    private func updateDealStores() {
        let selected = dealsStorePopup.selectedItem?.representedObject as? String ?? ""
        dealsStorePopup.removeAllItems()
        dealsStorePopup.addItem(withTitle: "Any Store")
        dealsStorePopup.lastItem?.representedObject = ""
        for store in dealsStores {
            dealsStorePopup.addItem(withTitle: store.name)
            dealsStorePopup.lastItem?.representedObject = store.id
        }
        if let index = dealsStorePopup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            dealsStorePopup.selectItem(at: index)
        }
    }

    private func renderDeals(_ warning: String? = nil, fetched: Double? = nil) {
        schedulePlatformLookup()
        dealsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let store = dealsMode.selectedSegment == 0
        let count = store ? storeDeals.count : giveaways.count
        if let fetched { dealsFetched[dealsMode.selectedSegment] = fetched }
        let fetched = fetched ?? dealsFetched[dealsMode.selectedSegment]
        if store {
            for deal in storeDeals { addDealRow(storeDealRow(deal)) }
        } else {
            for giveaway in sortedGiveaways() { addDealRow(giveawayRow(giveaway)) }
        }
        dealsMore.isHidden = !store || !storeDealsHasMore || storeDeals.isEmpty
        if let warning {
            dealsStatus.stringValue = "\(warning) Showing saved deals."
            dealsRetry.isHidden = false
        } else if dealsLoadingKey == nil || count > 0 {
            dealsRetry.isHidden = true
            if count == 0 {
                dealsStatus.stringValue = dealsLoadedKey[dealsMode.selectedSegment] == nil ? "" :
                    store ? "No deals match these filters." : "No active giveaways match these filters."
            } else {
                var line = store ? "\(count) deals" : "\(count) active giveaways"
                if let fetched, fetched > 0 {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .short
                    line += " \u{00B7} updated \(formatter.localizedString(for: Date(timeIntervalSince1970: fetched), relativeTo: Date()))"
                }
                dealsStatus.stringValue = line
            }
        }
    }

    private func addDealRow(_ view: NSView) { addShopRow(view, to: dealsList) }

    private func addShopRow(_ view: NSView, to list: NSStackView, separated: Bool = true) {
        if separated, let last = list.arrangedSubviews.last, last.accessibilityIdentifier() != "shopSection" {
            let line = separator()
            list.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    static let shopArtworkSize = NSSize(width: 80, height: 40)
    static let shopHeadingSize: CGFloat = 19
    /// Extra room above each Home section after the first (on top of the heading's own 14 pt), so sections read as blocks.
    static let shopSectionGap: CGFloat = 14
    static let shopHeartWidth: CGFloat = 22, shopPriceWidth: CGFloat = 96, shopPercentWidth: CGFloat = 78, shopOfferWidth: CGFloat = 180, shopMarkerWidth: CGFloat = 80, shopChildIndent: CGFloat = 40

    /// Game art in one shared frame: wide store art is cropped to fill it; square app icons are fitted.
    private func dealArtwork(_ source: String?, width: CGFloat = SetupController.shopArtworkSize.width,
                             height: CGFloat = SetupController.shopArtworkSize.height, fill: Bool = true) -> RemoteImageView {
        let image = RemoteImageView()
        image.aspectFill = fill
        image.setAccessibilityIdentifier("shopArtwork")
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 4
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        image.widthAnchor.constraint(equalToConstant: width).isActive = true
        image.heightAnchor.constraint(equalToConstant: height).isActive = true
        image.setAccessibilityElement(false)
        image.load(safeDealURL(source), enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        return image
    }

    private func dealRow(artwork: NSView, title: String, detail: NSAttributedString, detailTip: String, trailing: [NSView],
                         accessibility: String, compact: Bool = false, indent: CGFloat = 0, actions: [NSView] = [],
                         open: @escaping () -> Void) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.isHidden = title.isEmpty
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Rating badges wrap to a second line instead of truncating; full wording lives in the tooltip.
        let info = WrappingLabel(labelWithAttributedString: detail)
        info.lineBreakMode = .byWordWrapping
        info.maximumNumberOfLines = 0
        info.cell?.wraps = true
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        info.setAccessibilityIdentifier("dealBadges")
        // Rows without a detail line (store rows under a game) center their title instead of leaving a blank line.
        info.isHidden = detail.length == 0
        let texts = NSStackView(views: [name, info])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        if !actions.isEmpty {
            // Title and platform on top, then a clear gap, then the row's own controls (target, wishlist, reminder).
            let bar = NSStackView(views: actions)
            bar.orientation = .horizontal
            bar.alignment = .centerY
            bar.spacing = 8
            bar.setAccessibilityIdentifier("shopRowActions")
            for view in actions { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
            if let above = [info, name].first(where: { !$0.isHidden }) { texts.setCustomSpacing(compact ? 4 : 10, after: above) }
            texts.addArrangedSubview(bar)
        }
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text column takes the slack, so the price columns always end at the row's edge.
        texts.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        info.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let line = row([artwork, texts] + trailing)
        line.distribution = .fill
        line.spacing = 12
        line.alignment = .centerY
        for view in trailing {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let rowView = ClickableRowView()
        rowView.toolTip = detailTip.isEmpty ? title : "\(title)\n\(detailTip)"
        rowView.setAccessibilityLabel(accessibility)
        rowView.setAccessibilityIdentifier("dealRow")
        rowView.onActivate = open
        line.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 6 + indent),
            line.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: rowView.topAnchor, constant: compact ? 5 : 8),
            line.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: compact ? -5 : -8),
            rowView.heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 36 : 59)
        ])
        return rowView
    }

    /// Compact inline badges: a mini symbol plus a short colored value, kept together with no-break spaces.
    /// Bundled launcher icon for a store name (CheapShark names), nil when Couch Cube has none.
    static func storeIconID(_ store: String) -> String? {
        let name = store.lowercased()
        if name.hasPrefix("steam") { return "steam" }
        if name.hasPrefix("epic") { return "epic-games" }
        if name.hasPrefix("gog") { return "gog-galaxy" }
        if name == "origin" || name.hasPrefix("ea ") || name == "ea" { return "ea" }
        if name.hasPrefix("battle.net") || name.hasPrefix("blizzard") { return "battle-net" }
        return nil
    }

    static let storeIconCache = NSCache<NSString, NSImage>()

    /// A small store logo: the bundled launcher icon, the Apple logo for the Mac App Store, otherwise a cart symbol.
    static func storeIcon(_ store: String, size: CGFloat) -> (image: NSImage, template: Bool) {
        if let id = storeIconID(store) {
            if let cached = storeIconCache.object(forKey: id as NSString) { return (cached, false) }
            if let image = Bundle.main.resourceURL.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("AppIcons/\(id).png")) }) {
                storeIconCache.setObject(image, forKey: id as NSString)
                return (image, false)
            }
        }
        let symbol = store.lowercased().contains("app store") ? "apple.logo" : "cart"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .medium)) ?? NSImage()
        return (image, true)
    }

    /// The store under the price, by its full name: gray with its logo, or on a sale a green tag with the discount
    /// ("Steam −75%"). A game row covering several stores shows just the best discount.
    private func storeTag(_ store: String?, savings: Int? = nil) -> NSView {
        let text = [store, savings.map { "\u{2212}\($0)%" }].compactMap { $0 }.joined(separator: " ")
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = savings != nil ? .systemGreen : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .right
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        let icon: NSView
        if savings != nil {
            let image = NSImageView(image: NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? NSImage())
            image.contentTintColor = .systemGreen
            image.setAccessibilityIdentifier("shopSaleTag")
            icon = image
        } else {
            icon = storeIconView(store ?? "", size: 12)
        }
        let tag = NSStackView(views: [icon, label])
        tag.orientation = .horizontal
        tag.alignment = .centerY
        tag.spacing = 3
        let spoken = [store, savings.map { "\($0)% off" }].compactMap { $0 }.joined(separator: ", ")
        tag.toolTip = spoken
        tag.setAccessibilityIdentifier("shopStoreTag")
        tag.setAccessibilityElement(true)
        tag.setAccessibilityRole(.staticText)
        tag.setAccessibilityLabel(spoken)
        return tag
    }

    /// The all-time-low note: a small third line under the price, green only at the record.
    private func insightLabel(_ insight: PriceInsight?) -> NSView? {
        guard let insight else { return nil }
        let label = NSTextField(labelWithString: insight.text)
        label.font = .systemFont(ofSize: 10, weight: insight.kind == "record" ? .semibold : .regular)
        label.textColor = insight.kind == "record" ? .systemGreen : .tertiaryLabelColor
        label.toolTip = insight.detail
        label.setAccessibilityLabel(insight.text + ". " + insight.detail)
        label.setAccessibilityIdentifier("shopPriceInsight")
        return label
    }

    private func storeIconView(_ store: String, size: CGFloat = 16) -> NSView {
        let icon = Self.storeIcon(store, size: size)
        let view = NSImageView(image: icon.image)
        view.imageScaling = .scaleProportionallyUpOrDown
        if icon.template { view.contentTintColor = .secondaryLabelColor }
        view.setAccessibilityIdentifier("shopStoreIcon")
        view.setAccessibilityLabel(store)
        view.toolTip = store
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }

    /// Badge symbols are SF Symbol names; "store:<name>" puts that store's small logo in front of the text instead.
    private func dealBadges(_ parts: [(symbol: String?, text: String, color: NSColor)]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  \u{00B7}  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if let symbol = part.symbol, symbol.hasPrefix("store:") {
                let icon = Self.storeIcon(String(symbol.dropFirst(6)), size: 12)
                let attachment = NSTextAttachment()
                attachment.image = icon.template ? icon.image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [part.color]))) ?? icon.image
                    : icon.image
                attachment.bounds = icon.template ? NSRect(x: 0, y: -1, width: attachment.image!.size.width, height: attachment.image!.size.height)
                    : NSRect(x: 0, y: -2, width: 12, height: 12)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: font]))
            } else if let symbol = part.symbol,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [part.color]))) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: part.text.replacingOccurrences(of: " ", with: "\u{00A0}"),
                                             attributes: [.font: font, .foregroundColor: part.color]))
        }
        return result
    }

    static func ratingColor(_ value: Double, good: Double, fair: Double) -> NSColor {
        value >= good ? .systemGreen : value >= fair ? .systemOrange : .systemRed
    }

    private func dealBadge(_ title: String, color: NSColor) -> NSTextField {
        let badge = NSTextField(labelWithString: title)
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = color
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        badge.layer?.cornerRadius = 4
        badge.alignment = .center
        let padded = badge.widthAnchor.constraint(greaterThanOrEqualToConstant: badge.intrinsicContentSize.width + 10)
        padded.priority = .defaultHigh
        padded.isActive = true
        badge.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.heightAnchor.constraint(equalToConstant: 17).isActive = true
        return badge
    }

    /// Ratings a store deal can carry. Each kind has its own fixed column, so Steam always sits under Steam,
    /// Metacritic under Metacritic and the deal rating under the deal rating; a missing one leaves its slot empty.
    struct ShopRatings {
        var steamPercent: Int? = nil
        var steamText: String? = nil
        var metacritic: Int? = nil
        var deal: Double? = nil
        static let none = ShopRatings()
    }

    static let shopRatingWidths: (steam: CGFloat, metacritic: CGFloat, deal: CGFloat) = (50, 40, 40)

    private func ratingCell(_ symbol: String, _ value: String?, color: NSColor, width: CGFloat, id: String, tip: String?) -> NSView {
        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 3
        cell.setAccessibilityIdentifier(id)
        cell.widthAnchor.constraint(equalToConstant: width).isActive = true
        cell.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.setHuggingPriority(.required, for: .horizontal)
        if let value {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))!)
            icon.contentTintColor = color
            let label = NSTextField(labelWithString: value)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = color
            label.setAccessibilityIdentifier("shopRatingValue")
            cell.setViews([NSView(), icon, label], in: .trailing)
            cell.toolTip = tip
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel(tip)
        }
        return cell
    }

    /// The right end of every shop row, in fixed-width columns that line up from row to row:
    /// [Steam | Metacritic | Deal rating]  heart  [Lowest]  price (usual price beneath)  discount.
    /// Rating columns appear when `ratings` is given and the marker column when `marker` is non-nil, even if empty,
    /// so every row of a list reserves the same slots. Missing values leave their cell blank.
    private func priceCluster(heart: NSView?, price: ShopPrice?, priceText: String? = nil, was: String? = nil,
                              savings: Int? = nil, highlight: Bool = false, marker: String?? = nil, ratings: ShopRatings? = nil,
                              ratingOverlay: NSView? = nil, store: String? = nil, footer: NSView? = nil) -> NSView {
        func column(_ views: [NSView], width: CGFloat, id: String) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .trailing
            stack.spacing = 1
            stack.setAccessibilityIdentifier(id)
            stack.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.setHuggingPriority(.required, for: .horizontal)
            return stack
        }
        var columns: [NSView] = []
        if let ratings {
            let widths = Self.shopRatingWidths
            var cells: [NSView] = []
            cells.append(ratingCell("hand.thumbsup.fill", ratings.steamPercent.map { "\($0)%" },
                                      color: ratings.steamPercent.map { Self.ratingColor(Double($0), good: 80, fair: 50) } ?? .clear,
                                      width: widths.steam, id: "shopRatingSteam",
                                      tip: ratings.steamPercent.map { p in "Steam reviews: " + (ratings.steamText.map { "\($0) (\(p)%)" } ?? "\(p)%") }))
            cells.append(ratingCell("m.square.fill", ratings.metacritic.map { "\($0)" },
                                      color: ratings.metacritic.map { Self.ratingColor(Double($0), good: 75, fair: 50) } ?? .clear,
                                      width: widths.metacritic, id: "shopRatingMetacritic",
                                      tip: ratings.metacritic.map { "Metacritic score: \($0)" }))
            cells.append(ratingCell("tag.fill", ratings.deal.map { String(format: "%.1f", $0) },
                                      color: ratings.deal.map { Self.ratingColor($0, good: 8, fair: 5) } ?? .clear,
                                      width: widths.deal, id: "shopRatingDeal",
                                      tip: ratings.deal.map { String(format: "CheapShark deal rating: %.1f of 10", $0) }))
            if let ratingOverlay {
                // A row without ratings (a free game on Home) uses the empty rating area for its own control.
                let stack = NSStackView(views: cells)
                stack.spacing = 6
                let area = NSView()
                for view in [stack, ratingOverlay] {
                    view.translatesAutoresizingMaskIntoConstraints = false
                    area.addSubview(view)
                }
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: area.leadingAnchor), stack.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: area.topAnchor), stack.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                    ratingOverlay.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                    ratingOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor),
                    ratingOverlay.centerYAnchor.constraint(equalTo: area.centerYAnchor),
                    area.heightAnchor.constraint(greaterThanOrEqualTo: ratingOverlay.heightAnchor)
                ])
                columns.append(area)
            } else {
                columns += cells
            }
        }
        if let heart {
            let heartColumn = column([heart], width: Self.shopHeartWidth, id: "shopHeartColumn")
            heartColumn.alignment = .centerX
            columns.append(heartColumn)
        }
        // Search rows add a "Lowest" column beside the price; nil-in-optional keeps the column empty for alignment.
        if let marker {
            let badge = marker.map { dealBadge($0, color: .systemGreen) }
            badge?.setAccessibilityIdentifier("shopLowest")
            columns.append(column(badge.map { [$0] } ?? [], width: Self.shopMarkerWidth, id: "shopMarkerColumn"))
        }
        // Two right-aligned lines: the price, with the usual price struck through beside it on a sale; beneath it the
        // store in gray, or a green tag with the store and the discount on a sale. A real end date or the all-time-low
        // note goes on a small third line.
        var top: [NSView] = []
        if let shown = price ?? priceText.map({ ShopPrice(text: $0, original: $0, converted: false, value: nil) }) {
            top.append(priceLabel(shown, highlight: highlight))
        }
        if let was {
            let label = NSTextField(labelWithAttributedString: NSAttributedString(string: was, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
            label.setAccessibilityIdentifier("shopWasPrice")
            top.append(label)
        }
        for case let label as NSTextField in top {
            label.lineBreakMode = .byTruncatingHead
            label.alignment = .right
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let topLine = NSStackView(views: top)
        topLine.orientation = .horizontal
        topLine.alignment = .firstBaseline
        topLine.spacing = 6
        topLine.setAccessibilityIdentifier("shopPriceLine")
        let sale = savings.flatMap { $0 > 0 ? $0 : nil }
        let storeLine: NSView? = store != nil || sale != nil ? storeTag(store, savings: sale) : nil
        func slot(_ view: NSView?, height: CGFloat?) -> NSView {
            // A full-width line with its content pinned to the right edge.
            let line = NSStackView()
            line.orientation = .horizontal
            if let view { line.addView(view, in: .trailing) }
            if let height { line.heightAnchor.constraint(equalToConstant: height).isActive = true }
            return line
        }
        var lines = [slot(topLine, height: 17), slot(storeLine, height: 15)]
        if let footer { lines.append(slot(footer, height: nil)) }
        let block = column(lines, width: Self.shopOfferWidth, id: "shopPriceColumn")
        for line in lines { line.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
        block.spacing = 2
        columns.append(block)
        let cluster = NSStackView(views: columns)
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 6
        cluster.setAccessibilityIdentifier("shopPriceCluster")
        cluster.setHuggingPriority(.required, for: .horizontal)
        return cluster
    }

    private func storeDealRow(_ deal: StoreDeal) -> NSView {
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips = [deal.store ?? "Store"]
        let compat = compatibilityBadge(compatibility(steamAppId: deal.steamAppId))
        if let compat { badges.append(compat.badge); tips.append(compat.tip) }
        if let percent = deal.steamRatingPercent {
            tips.append("Steam reviews: " + (deal.steamRating.map { "\($0) (\(percent)%)" } ?? "\(percent)%"))
        }
        if let metacritic = deal.metacritic { tips.append("Metacritic score: \(metacritic)") }
        if let rating = deal.dealRating { tips.append(String(format: "CheapShark deal rating: %.1f of 10", rating)) }
        if deal.installed { badges.append(("checkmark.circle.fill", "Installed", .systemGreen)) }
        let ratings = ShopRatings(steamPercent: deal.steamRatingPercent, steamText: deal.steamRating,
                                  metacritic: deal.metacritic, deal: deal.dealRating)
        let salePrice = shopPrice(deal.salePrice, "USD")
        let heart = wishlistHeart(key: deal.gameId.map { "cs:" + $0 } ?? "title:" + deal.title.lowercased(), title: deal.title,
                                  payload: ["title": deal.title, "game_id": deal.gameId ?? "", "steam_app_id": deal.steamAppId ?? "", "thumb": deal.thumb ?? ""])
        let trailing = [priceCluster(heart: nil, price: salePrice,
                                     was: deal.normalPrice.flatMap { $0 > deal.salePrice ? shopPrice($0, "USD").text : nil },
                                     savings: deal.savings, ratings: ratings, store: deal.store)]
        if salePrice.converted { tips.append("Price: \(salePrice.spoken)") }
        var spoken = "\(deal.title), \(salePrice.spoken)"
        if let normal = deal.normalPrice, normal > deal.salePrice { spoken += ", was \(shopPrice(normal, "USD").spoken), \(deal.savings)% off" }
        spoken += (deal.installed ? ", installed" : "") + ". " + tips.dropFirst().joined(separator: ". ")
        return dealRow(artwork: dealArtwork(deal.thumb), title: deal.title,
                       detail: dealBadges(badges), detailTip: tips.joined(separator: "\n"), trailing: trailing,
                       accessibility: "Open \(deal.title) deal at \(deal.store ?? "store"), " + spoken,
                       actions: [shopTargetButton(key: heart.identifier!.rawValue, title: deal.title, currency: "USD"), heart]) { [weak self] in
            self?.openShopLink(deal.url, hosts: cheapSharkHosts)
        }
    }

    /// `ratingColumns` reserves the (empty) rating columns when the row shares a list with store deals, as on Home.
    private func giveawayRow(_ giveaway: Giveaway, ratingColumns: Bool = false) -> NSView {
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        if let type = giveaway.type { badges.append((nil, type, .secondaryLabelColor)); tips.append(type) }
        if !giveaway.platforms.isEmpty { tips.append("Platforms: " + giveaway.platforms.joined(separator: ", ")) }
        // The store giving it away goes under the price, like every other row; plain "PC" says nothing about the store.
        let giver = giveaway.platforms.first { !["pc", "drm-free"].contains($0.lowercased()) }
        var trailing: [NSView] = []
        var reminder: NSButton?
        if let end = DealExpiry.parseGamerPowerEnd(giveaway.endDate), end > dealsNow() {
            tips.append("Ends " + DateFormatter.localizedString(from: end, dateStyle: .medium, timeStyle: .short))
            let key = "giveaway:" + giveaway.id
            if let id = dealReminders[key], reminderStore.access == .granted, !reminderStore.exists(id) {
                dealReminders[key] = nil
            }
            let remind = RowControlButton(title: "", target: self, action: #selector(dealReminderClicked(_:)))
            remind.identifier = NSUserInterfaceItemIdentifier(giveaway.id)
            configureReminderButton(remind, giveaway: giveaway, end: end)
            reminder = remind
        }
        // GamerPower lists the usual value in US dollars ("$19.99").
        let worthPrice = giveaway.worth.flatMap { Double($0.replacingOccurrences(of: "$", with: "")) }.map { shopPrice($0, "USD") }
        let heart = wishlistHeart(key: "title:" + giveaway.title.lowercased(), title: giveaway.title, payload: ["title": giveaway.title, "thumb": giveaway.thumb ?? ""])
        trailing.append(priceCluster(heart: nil, price: nil, priceText: "Free", was: worthPrice?.text ?? giveaway.worth, highlight: true,
                                     ratings: ratingColumns ? ShopRatings.none : nil, store: giver, footer: reminder))
        if let worthPrice, worthPrice.converted { tips.append("Usually \(worthPrice.spoken)") }
        return dealRow(artwork: dealArtwork(giveaway.thumb), title: giveaway.title,
                       detail: dealBadges(badges), detailTip: tips.joined(separator: "\n"), trailing: trailing,
                       accessibility: "Open \(giveaway.title) giveaway, free" + ((worthPrice?.spoken ?? giveaway.worth).map { ", usually \($0)" } ?? "")
                        + (tips.isEmpty ? "" : ". " + tips.joined(separator: ". ")),
                       actions: [heart]) { [weak self] in
            self?.openShopLink(giveaway.url, hosts: gamerPowerHosts)
        }
    }

    private func configureReminderButton(_ button: NSButton, giveaway: Giveaway, end: Date) {
        button.bezelStyle = .inline
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("dealReminder")
        let set = dealReminders["giveaway:" + giveaway.id] != nil
        let expiry = DealExpiry.label(until: end, now: dealsNow())
        // The real end date stays visible either way; the icon says whether a reminder is set.
        let title = expiry?.text ?? "Offer ended"
        let color: NSColor = set ? .systemGreen : expiry?.urgent == true ? .systemOrange : .secondaryLabelColor
        button.image = NSImage(systemSymbolName: set ? "checkmark.circle.fill" : "bell", accessibilityDescription: nil)
        button.contentTintColor = color
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
        button.toolTip = set ? "A reminder is set for the day before this giveaway ends. Click to remove it."
            : "Remind me at 9:00 the day before this giveaway ends."
        button.setAccessibilityLabel(set ? "Reminder set for the day before this deal ends. Activate to remove it."
            : "Remind me the day before this deal ends" + (expiry.map { ", \($0.text.lowercased())" } ?? ""))
    }

    private func showReminderNote(_ text: String, error: Bool = false, privacy: Bool = false) {
        dealsReminderNote.stringValue = text
        dealsReminderNote.textColor = error ? .systemRed : .secondaryLabelColor
        dealsReminderSettings.isHidden = !privacy
        dealsReminderBar.isHidden = false
    }

    @objc private func openReminderPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { dealsOpener(url) }
    }

    @objc private func dealReminderClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let giveaway = (giveaways + (shopHome?.free ?? [])).first(where: { $0.id == id }) else { return }
        guard let end = DealExpiry.parseGamerPowerEnd(giveaway.endDate) else { return }
        let key = "giveaway:" + giveaway.id
        let store = reminderStore
        if let id = dealReminders[key] {
            if store.access == .granted, !store.exists(id) {
                dealReminders[key] = nil
                configureReminderButton(sender, giveaway: giveaway, end: end)
                showReminderNote("That reminder was deleted in Reminders. Click again to add a new one.")
                return
            }
            guard confirmReminderRemoval(giveaway.title) else { return }
            do { try store.remove(id) } catch {
                showReminderNote("Couldn't remove the reminder: \(error.localizedDescription)", error: true)
                return
            }
            dealReminders[key] = nil
            configureReminderButton(sender, giveaway: giveaway, end: end)
            showReminderNote("Reminder removed.")
            return
        }
        let denied = { [weak self] in
            self?.showReminderNote("Couch Cube isn't allowed to add reminders. Turn it on in Privacy & Security \u{203A} Reminders.",
                                   error: true, privacy: true)
        }
        switch store.access {
        case .denied: denied()
        case .granted: addDealReminder(giveaway, end: end, button: sender)
        case .notDetermined:
            store.requestAccess { [weak self] granted in
                guard let self else { return }
                if granted { self.addDealReminder(giveaway, end: end, button: sender) } else { denied() }
            }
        }
    }

    private func addDealReminder(_ giveaway: Giveaway, end: Date, button: NSButton) {
        let key = "giveaway:" + giveaway.id
        guard dealReminders[key] == nil else { return }
        guard let due = DealExpiry.reminderDate(for: end, now: dealsNow()) else {
            showReminderNote("This giveaway ends too soon for a reminder.")
            return
        }
        let store = giveaway.platforms.first { $0 != "PC" } ?? giveaway.platforms.first ?? "GamerPower"
        let endText = DateFormatter.localizedString(from: end, dateStyle: .full, timeStyle: .short)
        var notes = "Free" + (giveaway.worth.map { " (usually \($0))" } ?? "") + " on \(giveaway.platforms.joined(separator: ", ")).\n"
        notes += "Ends: \(endText). GamerPower lists end times without a time zone; read as UTC.\n"
        notes += giveaway.url
        do {
            let id = try reminderStore.add(title: "\(giveaway.title) deal ends \u{2014} \(store)", notes: notes,
                                           url: safeDealURL(giveaway.url, hosts: gamerPowerHosts), due: due.date)
            dealReminders[key] = id
        } catch {
            showReminderNote("Couldn't add the reminder: \(error.localizedDescription)", error: true)
            return
        }
        configureReminderButton(button, giveaway: giveaway, end: end)
        let when = DateFormatter.localizedString(from: due.date, dateStyle: .medium, timeStyle: .short)
        showReminderNote(due.adjusted
            ? "9:00 the day before has already passed, so the reminder is set for \(when) in your default Reminders list."
            : "Reminder set for \(when) in your default Reminders list.")
    }

    /// Shop links open in the default browser, and only as https links on the expected service's own hosts.
    private func openShopLink(_ value: String?, hosts: Set<String>) {
        guard let link = safeDealURL(value, hosts: hosts) else {
            showReminderNote("This link isn't from CheapShark, GamerPower or the Mac App Store, so Couch Cube didn't open it.", error: true)
            return
        }
        dealsOpener(link)
    }

    @objc private func dealsModeChanged() {
        UserDefaults.standard.set(dealsMode.selectedSegment, forKey: dealsModeKey)
        dealsGeneration += 1
        dealsLoadingKey = nil
        setShopLoading("deals", false)
        layoutDealsFilters()
        renderDeals()
        openDeals()
    }

    @objc private func dealsFiltersChanged() {
        if let sort = dealsSortPopup.selectedItem?.representedObject as? String { UserDefaults.standard.set(sort, forKey: dealsSortKey) }
        if let sort = giveawaySortPopup.selectedItem?.representedObject as? String { UserDefaults.standard.set(sort, forKey: giveawaySortKey) }
        if dealsLoadedKey[dealsMode.selectedSegment] == dealsArguments().joined(separator: "\u{1F}") { renderDeals(); return }
        if dealsMode.selectedSegment == 0 { storeDealsPage = 0 }
        loadDeals(page: 0, refresh: false)
    }

    @objc private func refreshDeals() { loadDeals(page: 0, refresh: true) }

    // MARK: Cube Shop

    private func configureShopPane(_ pane: NSStackView, _ views: [NSView], full: [NSView]) {
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 12
        pane.setViews(views, in: .leading)
        for view in full { view.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true }
    }

    private func shopList(_ list: NSStackView, id: String) {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.setAccessibilityIdentifier(id)
    }

    private func shopStatusLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func cubeShopPage() -> NSView {
        let deals = dealsPage()
        // Cube Shop always opens on Home; the other tabs keep their own state and scroll position once visited.
        shopTab.selectedSegment = 0
        shopTab.target = self
        shopTab.action = #selector(shopTabChanged)
        shopNav.selectedSegment = 0
        shopNav.target = self
        shopNav.action = #selector(shopNavChanged)
        shopNav.setAccessibilityLabel("Cube Shop section")
        shopNav.setAccessibilityIdentifier("shopNav")
        shopNav.segmentDistribution = .fit
        shopNav.segmentStyle = .automatic
        shopScope.target = self
        shopScope.action = #selector(shopScopeChanged)
        shopScope.controlSize = .small
        shopScope.isBordered = false
        shopScope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shopScope.setContentHuggingPriority(.required, for: .horizontal)
        shopScope.setAccessibilityIdentifier("shopScope")
        shopScope.selectedSegment = shopScopeMine ? 0 : 1
        shopScope.setAccessibilityLabel("Show deals for")
        shopScope.setToolTip("Only the stores whose app or launcher is installed on this Mac", forSegment: 0)
        shopScope.setToolTip("Every PC store", forSegment: 1)
        shopStatusLabel(shopScopeHint)
        shopScopeHint.setAccessibilityIdentifier("shopScopeHint")
        shopScopeBar.orientation = .horizontal
        shopScopeBar.alignment = .centerY
        shopScopeBar.spacing = 10
        shopScopeBar.setViews([shopScope], in: .leading)
        shopStatusLabel(shopCurrencyNote)
        shopCurrencyNote.setAccessibilityIdentifier("shopCurrencyNote")
        // Store header: one calm search field for every store on top, then the sections, with the store scope and refresh tucked at the right.
        shopSearchField.setAccessibilityIdentifier("shopSearchField")
        let nav = row([shopNav, NSView(), shopScopeBar, dealsProgress, dealsRefreshButton])
        nav.alignment = .centerY
        nav.spacing = 8
        let header = column([shopSearchField, nav])
        header.spacing = 12
        for view in [shopSearchField, nav] { view.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        shopScopeHint.isHidden = true
        shopStatusLabel(homeStatus)
        shopList(homeList, id: "shopHomeList")
        shopSearchField.controlSize = .large
        shopSearchField.font = .systemFont(ofSize: 15)
        configureShopPane(homePane, [homeStatus, homeList], full: [homeStatus, homeList])
        shopSearchField.placeholderString = "Search games in every store"
        shopSearchField.sendsWholeSearchString = true
        shopSearchField.target = self
        shopSearchField.action = #selector(shopSearchSubmitted)
        shopSearchField.setAccessibilityLabel("Search every store")
        NotificationCenter.default.addObserver(self, selector: #selector(shopSearchTyped(_:)), name: NSControl.textDidChangeNotification, object: shopSearchField)
        shopStatusLabel(searchStatus)
        shopList(searchList, id: "shopSearchList")
        let searchHeader = sortHeader(searchStatus, searchSortPopup, [.relevance, .name, .priceAsc, .priceDesc, .discount],
                                      key: searchSortKey, label: "Sort search results")
        configureShopPane(searchPane, [searchHeader, searchList], full: [searchHeader, searchList])
        shopStatusLabel(wishlistStatus)
        wishlistStatus.setAccessibilityIdentifier("wishlistStatus")
        shopList(wishlistList, id: "wishlistList")
        let wishlistHeader = sortHeader(wishlistStatus, wishlistSortPopup, [.relevance, .added, .name, .priceAsc, .priceDesc, .discount],
                                        key: wishlistSortKey, label: "Sort wishlist")
        wishlistSortPopup.item(at: 0)?.title = "On Sale First"
        configureShopPane(wishlistPane, [wishlistHeader, wishlistList], full: [wishlistHeader, wishlistList])
        let attribution = NSTextField(labelWithAttributedString: dealsAttribution())
        attribution.isSelectable = true
        attribution.allowsEditingTextAttributes = true
        attribution.lineBreakMode = .byWordWrapping
        attribution.maximumNumberOfLines = 0
        attribution.setAccessibilityIdentifier("dealsAttribution")
        // Store-style page: one header row, the content, and the small print (scope, rates, sources) at the bottom.
        let page = column([header, dealsReminderBar, homePane, deals, searchPane, wishlistPane, shopScopeHint, shopCurrencyNote, attribution])
        page.spacing = 12
        page.setCustomSpacing(20, after: header)
        for view in [header, shopScopeHint, shopCurrencyNote, homePane, deals, searchPane, wishlistPane, attribution] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        shopPageView = page
        updateScopeHint()
        updateCurrencyNotes()
        showShopTab()
        return page
    }

    private func showShopTab() {
        let tab = shopTab.selectedSegment
        homePane.isHidden = tab != 0
        dealsPane.isHidden = tab != 1 && tab != 2
        searchPane.isHidden = tab != 3
        wishlistPane.isHidden = tab != 4
        shopScopeBar.isHidden = tab > 2
        shopNav.selectedSegment = Self.shopNavTabs.firstIndex(of: tab) ?? -1
        // The field shows a query only while its results are on screen.
        if tab != 3 { shopSearchField.stringValue = "" }
    }

    @objc private func shopNavChanged() {
        guard Self.shopNavTabs.indices.contains(shopNav.selectedSegment) else { return }
        selectShopTab(Self.shopNavTabs[shopNav.selectedSegment])
    }

    private func openCubeShop() {
        dealsOpened = true
        shopTab.selectedSegment = 0
        loadRates(refresh: false)
        if wishlistCheckedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { checkWishlist(refresh: false) }
        shopTabChanged()
    }

    func selectShopTab(_ tab: Int) {
        if tab != 3 { shopReturnTab = tab }
        shopTab.selectedSegment = tab
        shopTabChanged()
    }

    @objc private func shopTabChanged() {
        let tab = shopTab.selectedSegment
        if tab != 3 { shopReturnTab = tab }
        let scroll = shopPageView?.enclosingScrollView
        if let shown = shopShownTab, shown != tab, let scroll { shopScrollOffsets[shown] = scroll.contentView.bounds.origin.y }
        defer {
            // Each tab keeps its own scroll position.
            if shopShownTab != tab, let scroll, let page = shopPageView {
                page.layoutSubtreeIfNeeded()
                let limit = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(shopScrollOffsets[tab] ?? 0, limit)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            shopShownTab = tab
        }
        showShopTab()
        dealsReminderBar.isHidden = true
        guard dealsOpened else { return }
        switch tab {
        case 0: loadHome(refresh: false)
        case 1, 2:
            dealsMode.selectedSegment = tab - 1
            dealsModeChanged()
        case 3: renderSearch()
        default: renderWishlist()
        }
    }

    @objc private func refreshShop() {
        if shopCurrency != nil { loadRates(refresh: true) }
        switch shopTab.selectedSegment {
        case 0: loadHome(refresh: true)
        case 1, 2: loadDeals(page: 0, refresh: true)
        case 3: runSearch(refresh: true)
        default: checkWishlist(refresh: true)
        }
    }

    private func setShopLoading(_ name: String, _ on: Bool) {
        if on { shopLoading.insert(name) } else { shopLoading.remove(name) }
        if shopLoading.isEmpty { dealsProgress.stopAnimation(nil) } else { dealsProgress.startAnimation(nil) }
    }

    /// Re-renders every Shop list after a currency, rate or wishlist change (rows are cheap; data stays as loaded).
    private func rerenderShop() {
        guard dealsOpened else { return }
        renderDeals()
        renderHome()
        renderSearch()
        renderWishlist()
    }

    // MARK: My Stores / All Stores

    private var shopScopeMine: Bool { UserDefaults.standard.string(forKey: shopScopeKey) != "all" }

    @objc private func shopScopeChanged() {
        UserDefaults.standard.set(shopScope.selectedSegment == 0 ? "mine" : "all", forKey: shopScopeKey)
        updateScopeHint()
        switch shopTab.selectedSegment {
        case 0: loadHome(refresh: false)
        case 1, 2: dealsFiltersChanged()
        default: break
        }
    }

    private func updateScopeHint() {
        // The scope control explains itself in its tooltip; the small print only speaks up when nothing is installed.
        defer {
            shopScope.toolTip = shopScopeHint.stringValue
            shopScopeHint.isHidden = !(myStores?.isEmpty ?? false)
        }
        if let stores = myStores, stores.isEmpty {
            // Nothing installed: show every store, and say why My Stores is unavailable.
            shopScope.setEnabled(false, forSegment: 0)
            shopScope.selectedSegment = 1
            shopScopeHint.stringValue = "No store apps found on this Mac, so every PC store is shown."
            return
        }
        shopScope.setEnabled(true, forSegment: 0)
        shopScope.selectedSegment = shopScopeMine ? 0 : 1
        if !shopScopeMine {
            shopScopeHint.stringValue = "Showing every PC store."
        } else if let stores = myStores {
            shopScopeHint.stringValue = "Showing " + ListFormatter.localizedString(byJoining: stores.map(\.name)) + ", installed on this Mac."
        } else {
            shopScopeHint.stringValue = "Showing the stores installed on this Mac."
        }
    }

    // MARK: Currency

    /// The display currency, or nil for original prices (the default, whatever the Mac's locale).
    var shopCurrency: String? {
        let saved = UserDefaults.standard.string(forKey: shopCurrencyKey)
        guard let saved, ShopMoney.currencies.contains(saved) else { return nil }
        return saved
    }

    private var shopFeePercent: Decimal {
        let value = UserDefaults.standard.double(forKey: shopFeeKey)
        return value > 0 && value <= 20 ? ShopMoney.decimal(value) : 0
    }

    func shopPrice(_ amount: Double, _ currency: String) -> ShopPrice {
        let value = ShopMoney.decimal(amount)
        let original = currency == "USD" && shopCurrency == nil ? dealPrice(amount) : ShopMoney.format(value, currency)
        if amount == 0 { return ShopPrice(text: "Free", original: "Free", converted: false, value: 0) }
        guard let target = shopCurrency else { return ShopPrice(text: original, original: original, converted: false, value: value) }
        if target == currency { return ShopPrice(text: ShopMoney.format(value, currency), original: original, converted: false, value: value) }
        guard let converted = ShopMoney.convert(value, from: currency, to: target, rates: exchangeRates, feePercent: shopFeePercent) else {
            return ShopPrice(text: original, original: original, converted: false, value: nil)
        }
        return ShopPrice(text: "\u{2248} " + ShopMoney.format(converted, target), original: ShopMoney.plain(value, currency),
                         converted: true, value: converted)
    }

    private func priceLabel(_ price: ShopPrice, highlight: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: price.text)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = highlight ? .systemGreen : .labelColor
        label.alignment = .right
        if price.converted {
            label.toolTip = "\(price.text) (\(price.original))"
            label.setAccessibilityLabel(price.spoken)
        }
        return label
    }

    private func loadRates(refresh: Bool) {
        guard shopCurrency != nil, !ratesLoading else { updateCurrencyNotes(); return }
        if !refresh, exchangeRates != nil, let loaded = ratesLoadedAt, Date().timeIntervalSince(loaded) < 3600 { updateCurrencyNotes(); return }
        ratesLoading = true
        updateCurrencyNotes()
        shopRead(["rates"] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, _ in
            guard let self else { return }
            self.ratesLoading = false
            if code == 0, let rates = decodeDeals(ExchangeRates.self, data) {
                let changed = rates != self.exchangeRates
                self.exchangeRates = rates
                self.ratesFailed = false
                self.ratesLoadedAt = Date()
                self.updateCurrencyNotes()
                if changed { self.rerenderShop() }
            } else {
                self.ratesFailed = true
                self.updateCurrencyNotes()
            }
        }
    }

    private func updateCurrencyNotes() {
        let source = "ECB reference rate via Frankfurter"
        let caveat = "Revolut/bank rates may differ slightly."
        guard let target = shopCurrency else {
            shopCurrencyNote.isHidden = true
            shopRatesNote.stringValue = "Prices are shown in the currency each store uses."
            return
        }
        shopCurrencyNote.isHidden = false
        let fee = shopFeePercent > 0 ? " incl. \(shopFeePercent)% card/FX fee" : ""
        if let rates = exchangeRates {
            let date = rates.stale == true ? "rates from \(rates.date)" : "updated \(rates.date)"
            shopRatesNote.stringValue = "\(source), \(date); \(caveat) Prices are converted for display only."
            shopCurrencyNote.stringValue = "Prices \u{2248} \(target)\(fee) \u{00B7} \(source), \(date)"
        } else if ratesLoading {
            shopRatesNote.stringValue = "\(source), loading\u{2026} \(caveat)"
            shopCurrencyNote.stringValue = "Loading exchange rates\u{2026}"
        } else if ratesFailed {
            shopRatesNote.stringValue = "\(source) couldn't be reached and no saved rates exist yet, so prices stay in their original currency. \(caveat)"
            shopCurrencyNote.stringValue = "Exchange rates aren't available, so prices are shown in their original currency."
        } else {
            shopRatesNote.stringValue = "\(source), loaded when you open Cube Shop. \(caveat)"
            shopCurrencyNote.stringValue = ""
        }
    }

    private func shopSettingsCard() -> NSView {
        shopCurrencyPopup.removeAllItems()
        shopCurrencyPopup.addItem(withTitle: "Original prices")
        shopCurrencyPopup.lastItem?.representedObject = "original"
        shopCurrencyPopup.menu?.addItem(.separator())
        for code in ShopMoney.currencies {
            let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
            shopCurrencyPopup.addItem(withTitle: "\(code) \u{2014} \(name)")
            shopCurrencyPopup.lastItem?.representedObject = code
            if code == "GBP" { shopCurrencyPopup.menu?.addItem(.separator()) }
        }
        let selected = shopCurrency ?? "original"
        if let item = shopCurrencyPopup.itemArray.first(where: { $0.representedObject as? String == selected }) { shopCurrencyPopup.select(item) }
        shopCurrencyPopup.target = self
        shopCurrencyPopup.action = #selector(shopCurrencyChanged)
        shopCurrencyPopup.controlSize = .small
        shopCurrencyPopup.setAccessibilityLabel("Shop currency")
        shopFeeField.stringValue = shopFeePercent == 0 ? "0" : "\(shopFeePercent)"
        shopFeeField.alignment = .right
        shopFeeField.controlSize = .small
        shopFeeField.font = .systemFont(ofSize: 11)
        shopFeeField.target = self
        shopFeeField.action = #selector(shopFeeChanged)
        shopFeeField.setAccessibilityLabel("Card or FX fee percent")
        shopFeeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        shopStatusLabel(shopRatesNote)
        shopRatesNote.setAccessibilityIdentifier("shopRatesNote")
        updateCurrencyNotes()
        return card("Cube Shop", subtitle: nil, views: [
            settingsRow("Shop currency", subtitle: "Show Cube Shop prices converted to this currency. Original prices (the default) keeps each store's own currency.", symbol: "dollarsign.circle",
                        color: .systemGreen, trailing: shopCurrencyPopup, detail: nil),
            separator(),
            settingsRow("Add card/FX fee", subtitle: "Added to converted prices, e.g. a weekend exchange markup.", symbol: "percent",
                        color: .systemOrange, trailing: row([shopFeeField, text("%", size: 12)]), detail: nil),
            shopRatesNote
        ])
    }

    @objc private func shopCurrencyChanged() {
        UserDefaults.standard.set(shopCurrencyPopup.selectedItem?.representedObject as? String ?? "original", forKey: shopCurrencyKey)
        updateCurrencyNotes()
        loadRates(refresh: false)
        rerenderShop()
    }

    @objc private func shopFeeChanged() {
        let text = shopFeeField.stringValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let value = Double(text.isEmpty ? "0" : text), value >= 0, value <= 20 {
            UserDefaults.standard.set(value, forKey: shopFeeKey)
        }
        shopFeeField.stringValue = shopFeePercent == 0 ? "0" : "\(shopFeePercent)"
        updateCurrencyNotes()
        rerenderShop()
    }

    // MARK: Home

    private func loadHome(refresh: Bool) {
        let scope = shopScopeMine ? "mine" : "all"
        let key = scope + (refresh ? "\u{1F}refresh" : "")
        if homeLoadingKey == key { return }
        if !refresh, homeLoadedScope == scope, shopHome != nil { renderHome(); return }
        homeLoadingKey = key
        setShopLoading("home", true)
        if shopHome == nil { homeStatus.stringValue = "Loading\u{2026}" }
        shopRead(["shop-home", "--scope", scope] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self, self.homeLoadingKey == key else { return }
            self.homeLoadingKey = nil
            self.setShopLoading("home", false)
            guard code == 0, let reply = decodeDeals(ShopHomeReply.self, data) else {
                self.homeError = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
                self.renderHome()
                return
            }
            self.shopHome = reply
            self.homeLoadedScope = scope
            self.homeError = reply.errors.first.map(self.dealsErrorText)
            self.myStores = reply.myStores
            self.updateScopeHint()
            if self.wishlist == nil, let wishlist = reply.wishlist { self.wishlist = wishlist }
            self.renderHome()
        }
    }

    private func sectionHeader(_ title: String, trailing: [NSView] = [], size: CGFloat = 13) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: size, weight: size > 13 ? .bold : .semibold)
        label.setAccessibilityIdentifier("shopSectionTitle")
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = row([label, NSView()] + trailing)
        line.edgeInsets = NSEdgeInsets(top: 14, left: 6, bottom: 4, right: 6)
        line.setAccessibilityIdentifier("shopSection")
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.group)
        line.setAccessibilityLabel(title)
        return line
    }

    private func renderHome() {
        schedulePlatformLookup()
        homeList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let home = shopHome else {
            homeStatus.stringValue = homeError ?? (homeLoadingKey == nil ? "" : "Loading\u{2026}")
            return
        }
        func section(_ title: String, _ rows: [NSView], more tab: Int, _ label: String) {
            guard !rows.isEmpty else { return }
            let more = NSButton(title: label + " \u{203A}", target: self, action: #selector(shopSeeAll(_:)))
            more.tag = tab
            more.bezelStyle = .inline
            more.isBordered = false
            more.contentTintColor = .controlAccentColor
            more.setAccessibilityIdentifier("shopSeeAll")
            more.setAccessibilityLabel("\(label): \(title)")
            if let previous = homeList.arrangedSubviews.last { homeList.setCustomSpacing(Self.shopSectionGap, after: previous) }
            addShopRow(sectionHeader(title, trailing: [more], size: Self.shopHeadingSize), to: homeList, separated: false)
            rows.forEach { addShopRow($0, to: homeList) }
        }
        let hits = (wishlist?.items ?? []).filter { $0.onSale || targetReached($0) == true }
        // A few picks per section; "See all" leads to the full list.
        section("Wishlist deals", hits.prefix(3).map { wishlistRow($0, ratingColumns: true) }, more: 4, "See all")
        section("Featured deals", home.featured.prefix(4).map(storeDealRow), more: 1, "See all")
        section("Price drops", home.drops.prefix(3).map(storeDealRow), more: 1, "See all")
        section("Free now", home.free.prefix(3).map { giveawayRow($0, ratingColumns: true) }, more: 2, "See all")
        if homeList.arrangedSubviews.isEmpty {
            homeStatus.stringValue = homeError ?? "Nothing to recommend right now. Try All Stores or Refresh."
        } else {
            homeStatus.stringValue = homeError.map { "\($0) Some sections may be missing." } ?? ""
            homeStatus.toolTip = "Picked on this Mac from discounts, ratings, recency and your wishlist. Nothing about you is sent anywhere."
        }
    }

    // MARK: Search

    private var shopCountry: String { Locale.current.region?.identifier ?? "US" }

    @objc private func shopSeeAll(_ sender: NSButton) { selectShopTab(sender.tag) }

    /// The one search field sits above every section; searching shows the results in place of the section, and clearing it goes back.
    @objc private func shopSearchTyped(_ note: Notification? = nil) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.shopSearchSubmitted() }
    }

    @objc private func shopSearchSubmitted() {
        searchTimer?.invalidate()
        searchTimer = nil
        let searching = shopSearchQuery.count >= 2
        if searching, shopTab.selectedSegment != 3 { selectShopTab(3) }
        runSearch(refresh: false)
        if !searching, shopTab.selectedSegment == 3 { selectShopTab(shopReturnTab) }
    }

    private var shopSearchQuery: String {
        String(shopSearchField.stringValue.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
    }

    private func runSearch(refresh: Bool) {
        let query = shopSearchQuery
        guard query.count >= 2 else {
            guard searchReply != nil || searchLoadingQuery != nil || searchError != nil else { return }
            searchReply = nil
            searchLoadedQuery = nil
            searchLoadingQuery = nil
            searchError = nil
            setShopLoading("search", false)
            renderSearch()
            return
        }
        // Identical searches are combined; results are cached by the backend.
        if searchLoadingQuery == query { return }
        // Already showing it. Don't rebuild: ending editing re-sends the field's action, and rebuilding the rows
        // mid-click would swallow a wishlist heart click.
        if !refresh, searchLoadedQuery == query { return }
        searchLoadingQuery = query
        setShopLoading("search", true)
        searchStatus.stringValue = "Searching every store for \u{201C}\(query)\u{201D}\u{2026}"
        shopRead(["shop-search", "--query", query, "--country", shopCountry] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self, self.searchLoadingQuery == query else { return }
            self.searchLoadingQuery = nil
            self.setShopLoading("search", false)
            guard code == 0, let reply = decodeDeals(ShopSearchReply.self, data) else {
                self.searchError = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
                self.renderSearch()
                return
            }
            self.searchReply = reply
            self.searchLoadedQuery = query
            self.searchError = reply.errors.first.map(self.dealsErrorText)
            self.renderSearch()
        }
    }

    /// Offers in price order. With a Shop currency every store is compared by its converted price; with original
    /// prices only same-currency offers are compared and other currencies follow, grouped and labelled.
    func sortedShopOffers(_ offers: [ShopOffer]) -> [(offer: ShopOffer, price: ShopPrice, cheapest: Bool)] {
        let priced = offers.map { (offer: $0, price: shopPrice($0.price, $0.currency)) }
        let converting = shopCurrency != nil && exchangeRates != nil
        func group(_ item: (offer: ShopOffer, price: ShopPrice)) -> String {
            converting ? (item.price.value == nil ? "~" + item.offer.currency : "") : (item.offer.currency == "USD" ? "" : item.offer.currency)
        }
        let ordered = priced.sorted { a, b in
            let (ga, gb) = (group(a), group(b))
            if ga != gb { return ga < gb }
            let (va, vb) = (a.price.value ?? ShopMoney.decimal(a.offer.price), b.price.value ?? ShopMoney.decimal(b.offer.price))
            return va != vb ? va < vb : a.offer.store.localizedCaseInsensitiveCompare(b.offer.store) == .orderedAscending
        }
        guard let first = ordered.first else { return [] }
        let lowest = first.price.value ?? ShopMoney.decimal(first.offer.price)
        return ordered.map { item in
            (item.offer, item.price, group(item) == group(first) && (item.price.value ?? ShopMoney.decimal(item.offer.price)) == lowest)
        }
    }

    private func symbolArtwork(_ symbol: String, size: CGFloat = 24, width: CGFloat? = nil) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        image.setAccessibilityIdentifier("shopArtwork")
        image.widthAnchor.constraint(equalToConstant: width ?? size).isActive = true
        image.heightAnchor.constraint(equalToConstant: size).isActive = true
        image.setAccessibilityElement(false)
        return image
    }

    private func offerRow(_ game: String, _ offer: ShopOffer, _ price: ShopPrice, cheapest: Bool, mixed: Bool = false, steamAppId: String? = nil) -> NSView {
        let appStore = offer.storeId == nil
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        if let savings = offer.savings, savings > 0 { tips.append("\(savings)% off") }
        let was = offer.normalPrice.flatMap { $0 > offer.price ? shopPrice($0, offer.currency) : nil }
        if let was { tips.append("Usually \(was.spoken)") }
        // The price shows its own currency; the store row stays one line.
        tips.append("Price in \(offer.currency)")
        if price.converted { tips.append("Price: \(price.spoken)") }
        let compat = compatibilityBadge(appStore ? .mac : offer.storeId == "1" ? compatibility(steamAppId: steamAppId) : nil)
        if let compat { badges.append(compat.badge); tips.append(compat.tip) }
        // The store itself (logo and short name) sits under the price; the left side keeps only Lowest and the platform.
        let lowest = cheapest ? dealBadge(lowestMarker(offer, mixed: mixed), color: .systemGreen) : nil
        lowest?.setAccessibilityIdentifier("shopLowest")
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 0).isActive = true
        let view = dealRow(artwork: spacer, title: "", detail: dealBadges(badges),
                           detailTip: tips.joined(separator: "\n"),
                           trailing: [priceCluster(heart: nil, price: price, was: was?.text, savings: offer.savings, highlight: cheapest,
                                                   store: offer.store)],
                           accessibility: "Open \(game) at \(offer.store), \(price.spoken)" + (cheapest ? ", cheapest" : "") + (compat.map { ". " + $0.tip } ?? ""),
                           compact: true, indent: Self.shopChildIndent, actions: lowest.map { [$0] } ?? []) { [weak self] in
            self?.openShopLink(offer.url, hosts: appStore ? appStoreHosts : cheapSharkHosts)
        }
        view.setAccessibilityIdentifier("shopOffer")
        return view
    }

    /// One game in search results: a parent row (art, title, stores, heart and the lowest price) with every
    /// store indented beneath it, cheapest first. Separators only fall between games, so each group reads as one.
    private func addSearchGroup(_ game: ShopGame, to list: NSStackView, first: Bool) {
        let offers = sortedShopOffers(game.offers + (game.appStoreOffer.map { [$0.offer] } ?? []))
        let mixed = Set(offers.map(\.offer.currency)).count > 1 && !(shopCurrency != nil && exchangeRates != nil)
        if offers.count == 1 {
            // Sold in one store only: an ordinary game row, not a group with a lone child.
            addShopRow(singleOfferRow(game, offers[0].offer, offers[0].price), to: list, separated: !first)
            return
        }
        addShopRow(searchGameRow(game, offers: offers, mixed: mixed), to: list, separated: !first)
        for item in offers {
            let view = offerRow(game.title, item.offer, item.price, cheapest: item.cheapest, mixed: mixed, steamAppId: game.steamAppId)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func lowestMarker(_ offer: ShopOffer, mixed: Bool) -> String {
        mixed ? "Lowest\u{00A0}\(offer.currency)" : "Lowest"
    }

    private func searchGameRow(_ game: ShopGame, offers: [(offer: ShopOffer, price: ShopPrice, cheapest: Bool)], mixed: Bool) -> NSView {
        let heart = wishlistHeart(key: "cs:" + game.id, title: game.title,
                                  payload: ["title": game.title, "game_id": game.id, "steam_app_id": game.steamAppId ?? "", "thumb": game.thumb ?? ""])
        let best = offers.first { $0.cheapest } ?? offers.first
        // The stores are listed right below, so the game row only says how many.
        var badges: [(symbol: String?, text: String, color: NSColor)] = [(nil, "\(offers.count) stores", .secondaryLabelColor)]
        let compat = compatibilityBadge(compatibility(steamAppId: game.steamAppId, appStore: game.appStoreOffer != nil))
        if let compat { badges.append(compat.badge) }
        let was = best.flatMap { item in item.offer.normalPrice.flatMap { $0 > item.offer.price ? shopPrice($0, item.offer.currency).text : nil } }
        let spoken = best.map { ", lowest price \($0.price.spoken) at \($0.offer.store)" + (($0.offer.savings ?? 0) > 0 ? ", \($0.offer.savings!)% off" : "") } ?? ""
        let view = dealRow(artwork: dealArtwork(game.thumb), title: game.title, detail: dealBadges(badges),
                           detailTip: ([best.map { "Lowest price: \($0.price.spoken) at \($0.offer.store)" }, compat?.tip].compactMap { $0 }).joined(separator: "\n"),
                           trailing: [priceCluster(heart: nil, price: best?.price, was: was, savings: best?.offer.savings, highlight: best != nil,
                                                   footer: best?.offer.storeId != nil ? insightLabel(game.insight) : nil)],
                           accessibility: "Open \(game.title)\(spoken)" + (compat.map { ". " + $0.tip } ?? ""),
                           actions: [shopTargetButton(key: heart.identifier!.rawValue, title: game.title, currency: best?.offer.currency ?? "USD"), heart]) { [weak self] in
            guard let best else { return }
            self?.openShopLink(best.offer.url, hosts: best.offer.storeId == nil ? appStoreHosts : cheapSharkHosts)
        }
        view.setAccessibilityIdentifier("shopGameRow")
        return view
    }

    private func singleOfferRow(_ game: ShopGame, _ offer: ShopOffer, _ price: ShopPrice) -> NSView {
        let appStore = offer.storeId == nil
        let heart = wishlistHeart(key: "cs:" + game.id, title: game.title,
                                  payload: ["title": game.title, "game_id": game.id, "steam_app_id": game.steamAppId ?? "", "thumb": game.thumb ?? ""])
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        let compat = compatibilityBadge(compatibility(steamAppId: game.steamAppId, appStore: appStore))
        if let compat { badges.append(compat.badge) }
        let was = offer.normalPrice.flatMap { $0 > offer.price ? shopPrice($0, offer.currency) : nil }
        var spoken = "\(game.title) at \(offer.store), \(price.spoken)"
        if let compat { spoken += ". " + compat.tip }
        if let was, let savings = offer.savings, savings > 0 { spoken += ", was \(was.spoken), \(savings)% off" }
        let view = dealRow(artwork: dealArtwork(game.thumb), title: game.title, detail: dealBadges(badges),
                           detailTip: "Only at \(offer.store)" + (price.converted ? "\nPrice: \(price.spoken)" : "") + (compat.map { "\n" + $0.tip } ?? ""),
                           trailing: [priceCluster(heart: nil, price: price, was: was?.text, savings: offer.savings, store: offer.store,
                                                   footer: appStore ? nil : insightLabel(game.insight))],
                           accessibility: "Open \(spoken)",
                           actions: [shopTargetButton(key: heart.identifier!.rawValue, title: game.title, currency: offer.currency), heart]) { [weak self] in
            self?.openShopLink(offer.url, hosts: appStore ? appStoreHosts : cheapSharkHosts)
        }
        view.setAccessibilityIdentifier("shopSingleOffer")
        return view
    }

    private func appStoreRow(_ app: AppStoreGame) -> NSView {
        let price = shopPrice(app.price, app.currency)
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        let compat = compatibilityBadge(.mac)!
        badges.append(compat.badge)
        let heart = wishlistHeart(key: "app:" + app.id, title: app.title, payload: ["title": app.title, "app_store_id": app.id, "thumb": app.thumb ?? ""])
        let view = dealRow(artwork: dealArtwork(app.thumb, fill: false), title: app.title, detail: dealBadges(badges),
                           detailTip: (app.seller.map { "By \($0)\n" } ?? "") + (price.converted ? "Price: \(price.spoken)" : "Mac App Store price in \(app.currency)"),
                           trailing: [priceCluster(heart: nil, price: price, store: "Mac App Store")],
                           accessibility: "Open \(app.title) in the Mac App Store, \(price.spoken). \(compat.tip)",
                           actions: [shopTargetButton(key: heart.identifier!.rawValue, title: app.title, currency: app.currency), heart]) { [weak self] in
            self?.openShopLink(app.url, hosts: appStoreHosts)
        }
        view.setAccessibilityIdentifier("shopAppStoreRow")
        return view
    }

    /// Home's search section: the best few results in the shared row style, with a link to the full comparison.
    /// A status line with a compact "Sort by" popup at its trailing edge; the choice is remembered per list.
    private func sortHeader(_ status: NSTextField, _ popup: NSPopUpButton, _ options: [ShopSort], key: String, label: String) -> NSStackView {
        popup.removeAllItems()
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.rawValue
        }
        let saved = UserDefaults.standard.string(forKey: key)
        popup.selectItem(at: options.firstIndex { $0.rawValue == saved } ?? 0)
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(shopSortChanged(_:))
        popup.setAccessibilityLabel(label)
        popup.setAccessibilityIdentifier("shopSortPopup")
        popup.toolTip = "Sort by"
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [status, popup])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        return header
    }

    private func selectedSort(_ popup: NSPopUpButton) -> ShopSort {
        (popup.selectedItem?.representedObject as? String).flatMap(ShopSort.init(rawValue:)) ?? .relevance
    }

    @objc private func shopSortChanged(_ sender: NSPopUpButton) {
        let sort = selectedSort(sender).rawValue
        if sender === searchSortPopup { UserDefaults.standard.set(sort, forKey: searchSortKey); renderSearch() }
        if sender === wishlistSortPopup { UserDefaults.standard.set(sort, forKey: wishlistSortKey); renderWishlist() }
    }

    /// Converts into the Shop currency for sorting (unrounded); nil with Original prices, so prices group by currency.
    func sortConvert(_ price: Double, _ currency: String) -> Double? {
        guard let target = shopCurrency else { return nil }
        if currency == target { return price }
        return ShopMoney.convert(ShopMoney.decimal(price), from: currency, to: target, rates: exchangeRates,
                                 feePercent: shopFeePercent, round: false).map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    /// A search game sorts by its cheapest store (converted when a Shop currency is set) and its biggest discount.
    func searchSortFields(_ game: ShopGame) -> ShopSortFields {
        let offers = game.offers + (game.appStoreOffer.map { [$0.offer] } ?? [])
        let cheapest = offers.min { a, b in
            let x = sortConvert(a.price, a.currency), y = sortConvert(b.price, b.currency)
            if let x, let y { return x < y }
            if x != nil || y != nil { return x != nil }
            return a.currency == b.currency ? a.price < b.price : a.currency == (offers.first?.currency ?? "USD")
        }
        return ShopSortFields(title: game.title, price: cheapest?.price, currency: cheapest?.currency,
                              discount: offers.compactMap(\.savings).max().map(Double.init))
    }

    func wishlistSortFields(_ item: WishlistItem) -> ShopSortFields {
        ShopSortFields(title: item.title, price: item.best?.price, currency: item.best?.currency,
                       discount: item.best.map { Double($0.savings) }, added: item.added)
    }

    func sortedGiveaways() -> [Giveaway] {
        let sort: ShopSort = (giveawaySortPopup.selectedItem?.representedObject as? String).flatMap {
            ["ends": ShopSort.endsSoon, "name": .name][$0] } ?? .relevance
        return shopSorted(giveaways, by: sort) { giveaway in
            ShopSortFields(title: giveaway.title, ends: DealExpiry.parseGamerPowerEnd(giveaway.endDate)?.timeIntervalSince1970)
        }
    }

    private func renderSearch() {
        schedulePlatformLookup()
        searchList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let reply = searchReply else {
            searchStatus.stringValue = searchError ?? (searchLoadingQuery != nil ? searchStatus.stringValue :
                "Search every PC store and the Mac App Store at once.")
            return
        }
        let sort = selectedSort(searchSortPopup)
        let games = shopSorted(reply.games, by: sort, convert: sortConvert, fields: searchSortFields)
        for (index, game) in games.enumerated() { addSearchGroup(game, to: searchList, first: index == 0) }
        if !reply.appStore.apps.isEmpty {
            let currency = reply.appStore.currency ?? reply.appStore.apps[0].currency
            let heading = sectionHeader("Mac App Store", size: 15)
            heading.toolTip = "Mac App Store prices for your region, in \(currency)"
            addShopRow(heading, to: searchList, separated: false)
            let apps = shopSorted(reply.appStore.apps, by: sort, convert: sortConvert) {
                ShopSortFields(title: $0.title, price: $0.price, currency: $0.currency)
            }
            for app in apps { addShopRow(appStoreRow(app), to: searchList) }
        }
        let found = reply.games.count + reply.appStore.apps.count
        var line = found == 0 ? "No PC store or Mac App Store games match \u{201C}\(reply.query)\u{201D}." :
            "\(found) result\(found == 1 ? "" : "s") for \u{201C}\(reply.query)\u{201D}."
        if let searchError { line += " \(searchError)" }
        searchStatus.stringValue = line
    }

    // MARK: Wishlist

    private func wishlistItem(key: String, title: String) -> WishlistItem? {
        wishlist?.items.first { $0.key == key || $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    // MARK: Mac / Windows compatibility

    /// Mac App Store games are Mac apps; otherwise only Steam's platform flags count. PC stores alone prove nothing.
    func compatibility(steamAppId: String?, appStore: Bool = false) -> GameCompatibility? {
        if appStore { return .mac }
        switch steamAppId.flatMap({ steamPlatformStatus[$0] }) {
        case "mac": return .mac
        case "windows": return .windowsOnly
        default: return nil
        }
    }

    /// Installed apps that run Windows games (nil until the app list has been read).
    private var compatibilityLayers: [String]? {
        guard lastAppsData != nil else { return nil }
        return ["crossover", "porting-kit", "steamac"].compactMap { id in appStates.first { $0.id == id && $0.installed }?.name }
    }

    /// A compact badge (logo + short label) and the full explanation for tooltips and VoiceOver.
    /// System yellow is too pale for small text on a light background, so light mode uses a deeper amber.
    static let windowsYellow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : NSColor(srgbRed: 0.72, green: 0.53, blue: 0, alpha: 1)
    }

    func compatibilityBadge(_ value: GameCompatibility?) -> (badge: (symbol: String?, text: String, color: NSColor), tip: String)? {
        switch value {
        case .mac?:
            return (("apple.logo", "Mac", .systemGreen), "Mac: has a macOS version")
        case .windowsOnly?:
            let layers = compatibilityLayers
            let base = "Windows only: no macOS version on Steam. It needs a Windows compatibility app to run on a Mac, and may not work in every one"
            // Same compact badge as Mac; the compatibility-app note lives in the tooltip and VoiceOver only.
            let badge: (symbol: String?, text: String, color: NSColor) = ("square.grid.2x2.fill", "Windows", Self.windowsYellow)
            if let layers, !layers.isEmpty {
                return (badge, base + ". Installed here: \(layers.joined(separator: ", ")).")
            }
            return (badge, base + (layers == nil ? " (for example CrossOver)." : ". None is installed on this Mac yet (for example CrossOver)."))
        case nil:
            return nil
        }
    }

    private func schedulePlatformLookup() {
        guard !platformLookupScheduled else { return }
        platformLookupScheduled = true
        // A run-loop timer (not the main queue) so it also fires while a modal or nested run loop is spinning.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.platformLookupScheduled = false
            self?.lookUpPlatforms()
        }
    }

    private func lookUpPlatforms() {
        var ids = storeDeals.compactMap(\.steamAppId) + (shopHome.map { ($0.featured + $0.drops).compactMap(\.steamAppId) } ?? [])
        ids += (searchReply?.games ?? []).compactMap(\.steamAppId) + (wishlist?.items ?? []).compactMap(\.steamAppId)
        var seen = Set<String>()
        let wanted = ids.filter { !platformsRequested.contains($0) && seen.insert($0).inserted }.prefix(40)
        guard !wanted.isEmpty, platformLookupRounds < 20 else { return }
        platformLookupRounds += 1
        platformsRequested.formUnion(wanted)
        shopRead(["shop-platforms", "--steam", wanted.joined(separator: ",")]) { [weak self] code, data, _ in
            guard let self, code == 0, let reply = decodeDeals(PlatformsReply.self, data) else { return }
            var changed = false
            for (id, platforms) in reply.platforms {
                let status = platforms.status ?? "unknown"
                if self.steamPlatformStatus[id] != status { self.steamPlatformStatus[id] = status; changed = changed || status != "unknown" }
            }
            // Not looked up yet (Steam asks for a slow pace): try again on the next render, a little later.
            self.platformsRequested.subtract(reply.pending)
            if changed { self.rerenderShop() }
            if !reply.pending.isEmpty && reply.error == nil {
                Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.schedulePlatformLookup() }
            }
        }
    }

    private var wishlistEditable: Bool { wishlist.map { !$0.readOnly && !$0.offline } ?? false }

    private func wishlistHeart(key: String, title: String, payload: [String: String]) -> NSButton {
        let heart = RowControlButton(title: "", target: self, action: #selector(wishlistHeartClicked(_:)))
        heart.identifier = NSUserInterfaceItemIdentifier(key)
        heart.bezelStyle = .inline
        heart.isBordered = false
        heart.imagePosition = .imageOnly
        heart.setAccessibilityIdentifier("wishlistHeart")
        heart.widthAnchor.constraint(equalToConstant: 22).isActive = true
        wishlistPayloads[key] = (title, payload.filter { !$0.value.isEmpty })
        configureHeart(heart)
        return heart
    }

    private func configureHeart(_ heart: NSButton) {
        guard let key = heart.identifier?.rawValue, let entry = wishlistPayloads[key] else { return }
        let saved = wishlistItem(key: key, title: entry.title) != nil
        heart.image = NSImage(systemSymbolName: saved ? "heart.fill" : "heart", accessibilityDescription: nil)
        heart.contentTintColor = !wishlistEditable ? .tertiaryLabelColor : saved ? .systemPink : .secondaryLabelColor
        // Stays clickable while the wishlist is read-only: the click explains why instead of doing nothing.
        heart.isEnabled = true
        heart.toolTip = !wishlistEditable ? (wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            : saved ? "Remove from wishlist" : "Add to wishlist"
        heart.setAccessibilityLabel(saved ? "Remove \(entry.title) from wishlist" : "Add \(entry.title) to wishlist")
    }

    private func refreshHearts() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        guard let page = shopPageView else { return }
        for button in views(page).compactMap({ $0 as? NSButton }) {
            if button.accessibilityIdentifier() == "wishlistHeart" { configureHeart(button) }
            if button.accessibilityIdentifier() == "shopTarget" { configureShopTarget(button) }
        }
    }

    /// "Set Target…" on a store row: works whether or not the game is on the wishlist yet (setting one adds it).
    private func shopTargetButton(key: String, title: String, currency: String) -> NSButton {
        let button = RowControlButton(title: "", target: self, action: #selector(shopTargetClicked(_:)))
        // Not the wishlist key itself, which identifies the heart.
        button.identifier = NSUserInterfaceItemIdentifier("target:" + key)
        button.controlSize = .small
        button.bezelStyle = .inline
        button.setAccessibilityIdentifier("shopTarget")
        shopTargetCurrencies[key] = currency
        configureShopTarget(button)
        return button
    }

    private func shopTargetCode(key: String, title: String) -> String {
        wishlistItem(key: key, title: title).map(targetCurrency(for:)) ?? shopCurrency ?? shopTargetCurrencies[key] ?? "USD"
    }

    private func configureShopTarget(_ button: NSButton) {
        guard let key = button.identifier?.rawValue.replacingOccurrences(of: "target:", with: ""), let entry = wishlistPayloads[key] else { return }
        let item = wishlistItem(key: key, title: entry.title)
        let code = shopTargetCode(key: key, title: entry.title)
        button.title = item?.targetPrice.map { "Target " + ShopMoney.format(ShopMoney.decimal($0), item?.targetCurrency ?? code) } ?? "Set Target\u{2026}"
        button.isEnabled = true
        button.toolTip = !wishlistEditable ? (wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            : item == nil ? "Set a target price in \(code). This also adds the game to your wishlist." : "Change the target price (\(code))"
        button.setAccessibilityLabel("Set a target price in \(code) for \(entry.title)")
    }

    @objc private func shopTargetClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue.replacingOccurrences(of: "target:", with: ""), let entry = wishlistPayloads[key] else { return }
        guard wishlistEditable else {
            showReminderNote(wishlist == nil ? "The wishlist is still loading. Try again in a moment."
                             : wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            return
        }
        if let item = wishlistItem(key: key, title: entry.title) { promptTarget(item); return }
        let code = shopTargetCode(key: key, title: entry.title)
        guard let choice = askTargetPrice(entry.title, nil, code), let price = choice,
              let json = try? JSONSerialization.data(withJSONObject: entry.payload, options: [.sortedKeys]) else { return }
        shopRead(["wishlist", "--add", String(decoding: json, as: UTF8.self)]) { [weak self] code_, data, errors in
            guard let self else { return }
            guard code_ == 0, let reply = decodeDeals(WishlistReply.self, data) else {
                self.showReminderNote(self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors), error: true)
                return
            }
            self.applyWishlist(reply)
            // The backend may file it under another key (e.g. by title), so look the new item up again.
            guard let item = self.wishlistItem(key: key, title: entry.title) else { return }
            self.changeWishlist(["--target", item.key, "--price", String(format: "%.\(ShopMoney.minorUnits(code))f", price), "--currency", code])
        }
    }

    @objc private func wishlistHeartClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let entry = wishlistPayloads[key] else { return }
        guard wishlistEditable else {
            showReminderNote(wishlist == nil ? "The wishlist is still loading. Try again in a moment."
                             : wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            return
        }
        if let item = wishlistItem(key: key, title: entry.title) {
            changeWishlist(["--remove", item.key])
        } else if let json = try? JSONSerialization.data(withJSONObject: entry.payload, options: [.sortedKeys]) {
            changeWishlist(["--add", String(decoding: json, as: UTF8.self)])
        }
    }

    private func changeWishlist(_ arguments: [String]) {
        shopRead(["wishlist"] + arguments) { [weak self] code, data, errors in
            guard let self else { return }
            guard code == 0, let reply = decodeDeals(WishlistReply.self, data) else {
                self.showReminderNote(self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors), error: true)
                return
            }
            self.applyWishlist(reply)
        }
    }

    private func checkWishlist(refresh: Bool) {
        guard !wishlistLoading else { return }
        wishlistLoading = true
        setShopLoading("wishlist", true)
        renderWishlist()
        shopRead(["wishlist", "--check", "--country", shopCountry] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self else { return }
            self.wishlistLoading = false
            self.setShopLoading("wishlist", false)
            self.wishlistCheckedAt = Date()
            guard code == 0, let reply = decodeDeals(WishlistReply.self, data) else {
                self.wishlistStatus.stringValue = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
                return
            }
            self.applyWishlist(reply)
        }
    }

    private func applyWishlist(_ reply: WishlistReply) {
        wishlist = reply
        refreshHearts()
        switch shopTab.selectedSegment {
        case 0: renderHome()
        case 4: renderWishlist()
        default: break
        }
    }

    private func wishlistRow(_ item: WishlistItem, ratingColumns: Bool = false, targetButton: Bool = true) -> NSView {
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        // The sale (green tag, store, discount) shows under the price like every other row; the sentence stays in the tooltip.
        if let sale = item.saleText { tips.append(sale) }
        var trailing: [NSView] = []
        var bestPrice: ShopPrice?
        if let best = item.best {
            let price = shopPrice(best.price, best.currency)
            bestPrice = price
            tips.append("Best price: \(price.spoken)" + (best.store.map { " at \($0)" } ?? ""))
            if let checked = best.checked {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                tips.append("Checked " + formatter.localizedString(for: Date(timeIntervalSince1970: checked), relativeTo: Date()))
            }
        }
        if let target = item.targetPrice {
            // The target stays in the currency it was entered in; the best price is converted to it for the comparison.
            let code = item.targetCurrency ?? "USD"
            let amount = ShopMoney.format(ShopMoney.decimal(target), code)
            switch targetReached(item) {
            case true?:
                badges.append(("target", "Target reached: " + amount, .systemOrange))
                tips.append("Target price \(amount) reached")
            case false?:
                badges.append((nil, "Target " + amount, .secondaryLabelColor))
                tips.append("Target price: \(amount)")
            case nil:
                badges.append((nil, "Target " + amount, .secondaryLabelColor))
                tips.append(item.best == nil ? "Target price: \(amount). No current price yet."
                            : "Target price: \(amount). Can't compare with \(item.best!.currency) prices until exchange rates load.")
            }
        }
        if badges.isEmpty { badges.append((nil, item.best == nil ? "No price checked yet" : "Not on sale", .secondaryLabelColor)) }
        if let compat = compatibilityBadge(compatibility(steamAppId: item.steamAppId, appStore: item.appStoreId != nil)) {
            badges.append(compat.badge)
            tips.append(compat.tip)
        }
        let targetCode = targetCurrency(for: item)
        let target = RowControlButton(title: item.targetPrice == nil ? "Set Target\u{2026}" : "Target\u{2026}", target: self, action: #selector(wishlistTargetClicked(_:)))
        target.toolTip = "Set a target price in \(targetCode)"
        target.identifier = NSUserInterfaceItemIdentifier(item.key)
        target.controlSize = .small
        target.bezelStyle = .inline
        target.isEnabled = wishlistEditable
        target.setAccessibilityIdentifier("wishlistTarget")
        target.setAccessibilityLabel("Set a target price in \(targetCode) for \(item.title)")
        let remove = RowControlButton(title: "", target: self, action: #selector(wishlistRemoveClicked(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(item.key)
        remove.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
        remove.contentTintColor = .systemPink
        remove.bezelStyle = .inline
        remove.isBordered = false
        remove.isEnabled = wishlistEditable
        remove.toolTip = "Remove from wishlist"
        remove.setAccessibilityIdentifier("wishlistRemove")
        remove.setAccessibilityLabel("Remove \(item.title) from wishlist")
        remove.widthAnchor.constraint(equalToConstant: Self.shopHeartWidth).isActive = true
        let was = item.best.flatMap { best in best.normalPrice.flatMap { $0 > best.price ? shopPrice($0, best.currency).text : nil } }
        trailing += [priceCluster(heart: nil, price: bestPrice, priceText: bestPrice == nil ? "\u{2014}" : nil, was: was,
                                  savings: item.onSale ? item.best?.savings : nil, highlight: item.onSale,
                                  ratings: ratingColumns ? ShopRatings.none : nil, store: item.best?.store, footer: insightLabel(item.insight))]
        let art: NSView = safeDealURL(item.thumb ?? "") == nil
            ? symbolArtwork(item.appStoreId != nil ? "apple.logo" : "gamecontroller", size: 28, width: Self.shopArtworkSize.width)
            : dealArtwork(item.thumb, fill: item.appStoreId == nil)
        let view = dealRow(artwork: art, title: item.title,
                           detail: dealBadges(badges), detailTip: tips.joined(separator: "\n"), trailing: trailing,
                           accessibility: "Search every store for \(item.title). " + tips.joined(separator: ". "),
                           actions: (targetButton ? [target] : []) + [remove]) { [weak self] in
            self?.searchFor(item.title)
        }
        view.setAccessibilityIdentifier("wishlistRow")
        return view
    }

    /// Matches LOCAL_WISHLIST_NOTE in scripts/console.py: no drive is set up yet, so the wishlist lives on this Mac.
    static let localWishlistNote = "Saved on this Mac. It moves to your Couch Cube drive when you set one up."

    private func searchFor(_ title: String) {
        shopSearchField.stringValue = title
        selectShopTab(3)
        shopSearchSubmitted()
    }

    private func renderWishlist() {
        schedulePlatformLookup()
        wishlistList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let wishlist else {
            wishlistStatus.stringValue = wishlistLoading ? "Loading your wishlist\u{2026}" : ""
            return
        }
        func hit(_ item: WishlistItem) -> Bool { item.onSale || targetReached(item) == true }
        let byDefault = wishlist.items.sorted { a, b in
            hit(a) != hit(b) ? hit(a) : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        let items = shopSorted(byDefault, by: selectedSort(wishlistSortPopup), convert: sortConvert, fields: wishlistSortFields)
        items.forEach { addShopRow(wishlistRow($0), to: wishlistList) }
        var lines: [String] = []
        if let note = wishlist.note, note != Self.localWishlistNote { lines.append(note) }
        if items.isEmpty {
            lines.append("Your wishlist is empty. Click \u{2661} on any deal, free game or search result to add it.")
        } else {
            let hits = items.filter(hit).count
            lines.append("\(items.count) game\(items.count == 1 ? "" : "s")" + (hits > 0 ? " \u{00B7} \(hits) on sale" : ""))
        }
        // Where it's saved goes in the tooltip; the status line stays short.
        wishlistStatus.toolTip = (wishlist.note == Self.localWishlistNote ? "Saved on this Mac; it moves to your Couch Cube drive when you set one up."
            : "Saved on your Couch Cube drive (Couch Cube/Wishlist/wishlist.json); it works offline and moves with the drive.")
            + " Prices are checked when you open Cube Shop or refresh."
        wishlistStatus.stringValue = lines.joined(separator: " ")
    }

    /// Targets are entered in the Shop currency (e.g. HUF); with Original prices, in the currency already used or the game's own.
    private func targetCurrency(for item: WishlistItem) -> String {
        shopCurrency ?? item.targetCurrency ?? item.best?.currency ?? "USD"
    }

    /// Whether the best price is at or below the target: the price is converted into the target's currency (with the card
    /// fee, unrounded, so a fraction above never counts). nil when there is no price yet or no exchange rate to compare with.
    func targetReached(_ item: WishlistItem) -> Bool? {
        guard let target = item.targetPrice, let best = item.best else { return nil }
        let code = item.targetCurrency ?? "USD"
        let price = ShopMoney.decimal(best.price)
        let converted = best.currency == code ? price
            : ShopMoney.convert(price, from: best.currency, to: code, rates: exchangeRates, feePercent: shopFeePercent, round: false)
        return converted.map { $0 <= ShopMoney.decimal(target) }
    }

    @objc private func wishlistTargetClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let item = wishlist?.items.first(where: { $0.key == key }), wishlistEditable else { return }
        promptTarget(item)
    }

    private func promptTarget(_ item: WishlistItem) {
        let key = item.key
        let code = targetCurrency(for: item)
        guard let choice = askTargetPrice(item.title, item.targetCurrency == code ? item.targetPrice : nil, code) else { return }
        let places = ShopMoney.minorUnits(code)
        changeWishlist(["--target", key] + (choice.map { ["--price", String(format: "%.\(places)f", $0), "--currency", code] } ?? []))
    }

    @objc private func wishlistRemoveClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, wishlistEditable else { return }
        changeWishlist(["--remove", key])
    }

    /// In-memory stand-ins for the shop backend used by smoke tests (no network, no drive writes).
    private func smokeShopReply(_ arguments: [String]) -> (Int32, String) {
        func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        func report() -> [String: Any] {
            ["items": smokeWishlist, "library": smokeWishlistOffline ? NSNull() : "/Volumes/Smoke/Couch Cube" as Any,
             "read_only": smokeWishlistOffline, "offline": smokeWishlistOffline, "merged": 0,
             "note": smokeWishlistOffline ? "The Couch Cube drive isn't connected. Showing the last saved wishlist (read-only)." as Any : NSNull()]
        }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        switch arguments.first {
        case "rates": return (0, smokeRatesJSON)
        case "shop-search": return (0, smokeShopSearchJSON)
        case "shop-platforms":
            // Portal 2 and Hollow Knight have Mac builds; Drop Game is Windows only; anything else is unknown.
            let known: [String: [String: Any]] = ["620": ["mac": true, "windows": true, "status": "mac"],
                                                  "367520": ["mac": true, "windows": true, "status": "mac"],
                                                  "700": ["mac": false, "windows": true, "status": "windows"]]
            let ids = (value("--steam") ?? "").split(separator: ",").map(String.init)
            return (0, json(["platforms": Dictionary(uniqueKeysWithValues: ids.map { ($0, known[$0] ?? ["status": NSNull()]) }),
                             "pending": [String](), "error": NSNull()]))
        case "shop-home":
            var home = try! JSONSerialization.jsonObject(with: Data(smokeShopHomeJSON.utf8)) as! [String: Any]
            home["wishlist"] = report()
            if value("--scope") == "all" { home["scope"] = "all" }
            return (0, json(home))
        case "wishlist":
            if arguments.contains("--check") || arguments.count == 1 { return (0, json(report())) }
            guard !smokeWishlistOffline else { return (1, "ERROR: Connect your Couch Cube drive to change the wishlist.") }
            if let raw = value("--add"), let item = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] {
                let key = item["game_id"].map { "cs:" + $0 } ?? item["app_store_id"].map { "app:" + $0 } ?? "title:" + (item["title"] ?? "").lowercased()
                smokeWishlist.append(["key": key, "title": item["title"] ?? "", "game_id": item["game_id"] ?? NSNull(),
                                      "steam_app_id": item["steam_app_id"] ?? NSNull(), "app_store_id": item["app_store_id"] ?? NSNull(),
                                      "added": 1_700_000_000, "target_price": NSNull(), "target_currency": NSNull(),
                                      "thumb": item["thumb"] ?? NSNull(), "best": NSNull(), "on_sale": false,
                                      "target_hit": false, "sale_text": NSNull()])
            } else if let key = value("--remove") {
                smokeWishlist.removeAll { $0["key"] as? String == key }
            } else if let key = value("--target"), let index = smokeWishlist.firstIndex(where: { $0["key"] as? String == key }) {
                let price = value("--price").flatMap(Double.init)
                smokeWishlist[index]["target_price"] = price ?? NSNull()
                smokeWishlist[index]["target_currency"] = price == nil ? NSNull() : (value("--currency") ?? "USD")
            }
            return (0, json(report()))
        default: return (1, "ERROR: unknown command")
        }
    }

    @objc private func retryDeals() { loadDeals(page: 0, refresh: false) }

    @objc private func loadMoreDeals() {
        guard dealsMode.selectedSegment == 0, storeDealsHasMore else { return }
        loadDeals(page: storeDealsPage + 1, refresh: false)
    }

    private func headerIconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let control = NSButton(title: "", target: self, action: action)
        control.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        control.bezelStyle = .inline
        control.isBordered = false
        control.contentTintColor = .secondaryLabelColor
        control.toolTip = label
        control.setAccessibilityLabel(label)
        control.widthAnchor.constraint(equalToConstant: 24).isActive = true
        control.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return control
    }

    private func cardHeader(_ title: String, buttons: [NSView]) -> NSStackView {
        let heading = text(title, size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([heading, NSView()] + buttons)
        header.distribution = .fill
        header.spacing = 10
        for view in buttons { view.setContentHuggingPriority(.required, for: .horizontal) }
        return header
    }

    private func renderApps() {
        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] { clearRows(rows) }
        var hiddenApps: [ObjectIdentifier: Int] = [:]
        let order = ["steam", "steamac", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch", "porting-kit", "crossover"]
        appStates.sort { (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100) }
        for (index, app) in appStates.enumerated() {
            for placement in appPlacements(app) {
                if !appPlacementVisible(app, placement) {
                    hiddenApps[ObjectIdentifier(placement.rows), default: 0] += 1
                    continue
                }
                addAppRow(app, index: index, to: placement.rows, title: placement.title, purpose: placement.purpose)
            }
        }
        for item in windowsDownloads {
            if !item.downloaded && windowsDownloadJobs[item.id] == nil && collapsedAppCategories.contains("Windows games") {
                hiddenApps[ObjectIdentifier(appWindowsRows), default: 0] += 1
                continue
            }
            addRow(makeWindowsDownloadRow(item), to: appWindowsRows)
        }
        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] {
            guard let hidden = hiddenApps[ObjectIdentifier(rows)] else { continue }
            let note = text("\(hidden) more app\(hidden == 1 ? "" : "s") to get · Expand to show",
                            size: 11, secondary: true)
            note.identifier = NSUserInterfaceItemIdentifier("app-hidden-note")
            rows.addArrangedSubview(note)
        }
        updateAllButton.isEnabled = task == nil && appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
        updateAllButton.isHidden = !appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
        if highlightedAppID != nil { DispatchQueue.main.async { self.highlightAppRow() } }
    }

    /// Every place an app is listed. One app can appear in several categories (Steam is both a TV menu and a PC game app);
    /// all its rows are built from the same app state and operation, so they always show the same status.
    private func appPlacements(_ app: ManagedApp) -> [(rows: NSStackView, title: String?, purpose: String?)] {
        if app.id == "steam" { return [(appMenuRows, "Steam Big Picture", "Steam TV menu"), (appPCRows, nil, nil)] }
        let rows = app.id == "es-de" ? appMenuRows :
            computerGameApps.contains(app.id) ? appPCRows :
            ["porting-kit", "crossover"].contains(app.id) ? appWindowsRows : appRetroRows
        return [(rows, nil, nil)]
    }

    private func appPlacementVisible(_ app: ManagedApp, _ placement: (rows: NSStackView, title: String?, purpose: String?)) -> Bool {
        app.installed || !collapsedAppCategories.contains(appCategoryTitle(for: placement.rows))
    }

    private let appPurposes = [
            "steam": "Steam games for Mac",
            "steamac": "SteamOS in a VM · Windows Steam games · Apple silicon, macOS 15+",
            "gog-galaxy": "GOG games for Mac",
            "ea": "EA games for Mac",
            "epic-games": "Epic Games for Mac",
            "battle-net": "Blizzard games · World of Warcraft",
            "curseforge": "World of Warcraft addons",
            "es-de": "Retro game TV menu",
            "retroarch-metal": "NES · SNES · Nintendo 64 · Game Boy · Game Boy Color · Game Boy Advance · PlayStation · PSP · Mega Drive · Sega CD · Dreamcast",
            "dolphin": "GameCube · Wii",
            "pcsx2": "PlayStation 2",
            "rpcs3": "PlayStation 3",
            "cemu-wiiu": "Wii U",
            "switch": "Nintendo Switch",
            "porting-kit": "Compatible Windows games on Mac",
            "crossover": "Compatible Windows games on Mac · Paid license or trial"
    ]

    private func appPillButton(_ title: String, app: ManagedApp, index: Int,
                               action: Selector, destructive: Bool = false) -> NSButton {
        let control: NSButton
        if destructive {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.addItem(withTitle: "")
            popup.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
            let update = NSMenuItem(title: "Update", action: #selector(updateAppFromMenu(_:)), keyEquivalent: "")
            update.target = self
            update.tag = index
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            popup.menu?.addItem(update)
            popup.menu?.autoenablesItems = false
            update.isEnabled = app.managed && app.update?.isEmpty == false
            let remove = NSMenuItem(title: "Remove…", action: #selector(removeAppFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            popup.menu?.addItem(remove)
            popup.bezelStyle = .inline
            popup.isBordered = false
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            control = popup
        } else {
            control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded
            control.controlSize = .regular
        }
        control.setButtonType(.momentaryChange)
        control.tag = index
        control.toolTip = destructive ? "More options for \(app.name)" : "\(title) \(app.name)"
        control.setAccessibilityLabel(control.toolTip)
        control.widthAnchor.constraint(equalToConstant: destructive ? 26 : title == "Get" ? 64 : 76).isActive = true
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        actions.append(control)
        return control
    }

    @objc private func removeAppFromMenu(_ sender: NSMenuItem) {
        let control = NSButton()
        control.tag = sender.tag
        appAction(control)
    }

    @objc private func updateAppFromMenu(_ sender: NSMenuItem) {
        let control = NSButton()
        control.tag = sender.tag
        updateApp(control)
    }

    private func addAppRow(_ app: ManagedApp, index: Int, to rows: NSStackView, title: String? = nil,
                           purpose: String? = nil) {
        addRow(makeAppRow(app, index: index, title: title, purpose: purpose), to: rows)
    }

    private func addRow(_ line: NSView, to rows: NSStackView) {
        rows.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        let separator = self.separator()
        rows.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    /// Replaces only this app's row(s) in place, so the list keeps its scroll position and other rows don't flicker.
    private func refreshAppRow(_ id: String) {
        guard let index = appStates.firstIndex(where: { $0.id == id }) else { return }
        let app = appStates[index]
        let placements = appPlacements(app).filter { appPlacementVisible(app, $0) }
        let existing = [appMenuRows, appPCRows, appWindowsRows, appRetroRows].flatMap { rows in
            rows.arrangedSubviews.filter { $0.identifier?.rawValue == "app-row-" + id }.map { (rows, $0) }
        }
        // A row appeared or disappeared (for example in a collapsed category): rebuild the list instead.
        guard existing.count == placements.count,
              zip(existing, placements).allSatisfy({ $0.0 === $1.rows }) else { return renderApps() }
        for ((rows, old), placement) in zip(existing, placements) {
            guard let position = rows.arrangedSubviews.firstIndex(of: old) else { continue }
            let line = makeAppRow(app, index: index, title: placement.title, purpose: placement.purpose)
            actions.removeAll { $0.isDescendant(of: old) }
            rows.insertArrangedSubview(line, at: position)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            rows.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
    }

    private func loadWindowsDownloads(verifying id: String? = nil) {
        windowsDownloadsGeneration += 1
        let generation = windowsDownloadsGeneration
        windowsDownloadsRead { [weak self] code, data in
            guard let self, generation == self.windowsDownloadsGeneration else { return }
            let reply = code == 0 ? try? JSONDecoder().decode(WindowsDownloadsReply.self, from: data) : nil
            if let id, self.windowsDownloadJobs[id]?.running == true {
                if reply?.items.first(where: { $0.id == id })?.downloaded == true {
                    self.windowsDownloadJobs[id] = nil
                } else {
                    self.windowsDownloadJobs[id]?.running = false
                    self.windowsDownloadJobs[id]?.failure = "The download finished, but Couch Cube couldn't find the installer in Downloads."
                }
            }
            guard let reply else {
                if let id { self.refreshWindowsDownloadRow(id) }
                return
            }
            let changedList = reply.items.map(\.id) != self.windowsDownloads.map(\.id)
            let changed = reply.items.filter { item in self.windowsDownloads.first { $0.id == item.id } != item }.map(\.id)
            let libraryChanged = reply.library != self.windowsLibrary
            self.windowsDownloads = reply.items
            self.windowsLibrary = reply.library
            if changedList || libraryChanged { self.renderApps() }
            else { Set(changed + (id.map { [$0] } ?? [])).forEach { self.refreshWindowsDownloadRow($0) } }
        }
    }

    private func refreshWindowsDownloadRow(_ id: String) {
        guard let item = windowsDownloads.first(where: { $0.id == id }),
              let old = appWindowsRows.arrangedSubviews.first(where: { $0.identifier?.rawValue == "win-row-" + id }),
              let position = appWindowsRows.arrangedSubviews.firstIndex(of: old) else { return renderApps() }
        let line = makeWindowsDownloadRow(item)
        actions.removeAll { $0.isDescendant(of: old) }
        appWindowsRows.insertArrangedSubview(line, at: position)
        line.widthAnchor.constraint(equalTo: appWindowsRows.widthAnchor).isActive = true
        appWindowsRows.removeArrangedSubview(old)
        old.removeFromSuperview()
    }

    private func makeWindowsDownloadRow(_ item: WindowsDownloadItem) -> NSView {
        let index = windowsDownloads.firstIndex(of: item) ?? 0
        let job = windowsDownloadJobs[item.id]
        let controls = row([])
        if job?.running == true {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.minValue = 0
            progress.maxValue = 1
            // Determinate only from the real byte count; spins when the server didn't send a size.
            progress.isIndeterminate = (job?.total ?? 0) == 0
            if progress.isIndeterminate { progress.startAnimation(nil) }
            else { progress.doubleValue = Double(job!.done) / Double(job!.total) }
            let cancel = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel download")!,
                                  target: self, action: #selector(cancelWindowsDownload(_:)))
            cancel.isBordered = false
            cancel.contentTintColor = .secondaryLabelColor
            cancel.tag = index
            cancel.toolTip = "Cancel downloading \(item.name)"
            cancel.setAccessibilityLabel(cancel.toolTip)
            let slot = row([progress, cancel])
            slot.spacing = 6
            slot.identifier = NSUserInterfaceItemIdentifier("win-progress")
            slot.widthAnchor.constraint(equalToConstant: 64).isActive = true
            slot.heightAnchor.constraint(equalToConstant: 26).isActive = true
            progress.setAccessibilityLabel(windowsDownloadStatus(item, job: job).title + " " + item.name)
            controls.addArrangedSubview(slot)
        } else if item.downloaded {
            let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)!,
                                target: self, action: #selector(windowsDownloadHelp(_:)))
            help.isBordered = false
            help.contentTintColor = .secondaryLabelColor
            help.tag = index
            help.toolTip = "How to run this installer"
            help.setAccessibilityLabel("How to run \(item.name)")
            let show = button("Show in Finder", #selector(showWindowsDownload(_:)))
            show.tag = index
            show.setAccessibilityLabel("Show \(item.name) installer in Finder")
            controls.addArrangedSubview(help)
            controls.addArrangedSubview(show)
        } else {
            let get = NSButton(title: job?.failure == nil ? "Get" : "Retry", target: self, action: #selector(getWindowsDownload(_:)))
            get.bezelStyle = .rounded
            get.tag = index
            get.isEnabled = windowsLibrary != nil
            get.toolTip = windowsLibrary == nil ? "Set up a game library first. The installer is saved in its Downloads folder." :
                "Download the official \(item.kind == "msi" ? ".msi" : ".exe") installer from \(item.vendor)"
            get.setAccessibilityLabel("\(get.title) \(item.name) installer")
            get.widthAnchor.constraint(equalToConstant: 64).isActive = true
            controls.addArrangedSubview(get)
        }
        let state = windowsDownloadStatus(item, job: job)
        let statusLine = row([statusIndicator(state.title, color: state.color, pulsing: state.pulsing), NSView()])
        statusLine.identifier = NSUserInterfaceItemIdentifier("app-status")
        statusLine.distribution = .fill
        let detail: NSTextField
        if let failure = job?.failure, job?.running != true {
            detail = text(failure, size: 11, secondary: true)
            detail.textColor = .systemRed
        } else if item.downloaded, let file = item.file {
            let size = item.size.map { " \u{00B7} " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            detail = text((file as NSString).lastPathComponent + size +
                          " \u{00B7} Not run or installed. Open it with Porting Kit or CrossOver.", size: 11, secondary: true)
            detail.toolTip = file + (item.sha256.map { "\nSHA-256 \($0)" } ?? "")
        } else {
            detail = text("Official Windows installer from \(item.vendor) \u{00B7} Saved to Downloads in your game library",
                          size: 11, secondary: true)
        }
        detail.identifier = NSUserInterfaceItemIdentifier("win-detail")
        let info = column([statusLine, detail])
        info.spacing = 4
        let line = settingsRow(item.name, subtitle: "", symbol: "arrow.down.app", color: .systemGray, trailing: controls, detail: info)
        let macID = String(item.id.dropFirst(4))
        if let image = Bundle.main.resourceURL.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("AppIcons/\(macID).png")) }),
           let stack = line as? NSStackView, let first = stack.arrangedSubviews.first {
            let icon = NSImageView(image: image)
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
            stack.insertArrangedSubview(icon, at: 0)
        }
        line.identifier = NSUserInterfaceItemIdentifier("win-row-" + item.id)
        return line
    }

    @objc private func getWindowsDownload(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag), windowsLibrary != nil else { return }
        let item = windowsDownloads[sender.tag]
        guard windowsDownloadJobs[item.id]?.running != true else { return }
        windowsDownloadJobs[item.id] = WindowsDownloadJob()
        refreshWindowsDownloadRow(item.id)
        let cancel = windowsDownloadRun(item.id, { [weak self] line in
            guard let self, let progress = windowsDownloadProgress(line), self.windowsDownloadJobs[item.id]?.running == true else { return }
            self.windowsDownloadJobs[item.id]?.done = progress.done
            self.windowsDownloadJobs[item.id]?.total = progress.total
            self.refreshWindowsDownloadRow(item.id)
        }, { [weak self] code, errors in
            guard let self, let job = self.windowsDownloadJobs[item.id], job.running else { return }
            if job.canceled {
                self.windowsDownloadJobs[item.id] = nil
                self.loadWindowsDownloads(verifying: nil)
                self.refreshWindowsDownloadRow(item.id)
            } else if code == 0 {
                self.loadWindowsDownloads(verifying: item.id)
            } else {
                self.windowsDownloadJobs[item.id]?.running = false
                self.windowsDownloadJobs[item.id]?.cancel = nil
                self.windowsDownloadJobs[item.id]?.failure = backendErrorMessage(errors, fallback: "The download failed. Nothing was saved.")
                self.refreshWindowsDownloadRow(item.id)
            }
        })
        if windowsDownloadJobs[item.id]?.running == true { windowsDownloadJobs[item.id]?.cancel = cancel }
    }

    @objc private func cancelWindowsDownload(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag) else { return }
        cancelWindowsDownload(id: windowsDownloads[sender.tag].id)
    }

    private func cancelWindowsDownload(id: String) {
        guard windowsDownloadJobs[id]?.running == true else { return }
        windowsDownloadJobs[id]?.canceled = true
        windowsDownloadJobs[id]?.cancel?()
    }

    @objc private func showWindowsDownload(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag), let file = windowsDownloads[sender.tag].file else { return }
        let url = URL(fileURLWithPath: file)
        // Only reveal files the backend reported inside the library's Downloads folder.
        guard let library = windowsLibrary, url.standardizedFileURL.deletingLastPathComponent().path ==
                URL(fileURLWithPath: library).appendingPathComponent("Downloads").standardizedFileURL.path,
              FileManager.default.fileExists(atPath: url.path) else {
            loadWindowsDownloads()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func windowsDownloadHelp(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag) else { return }
        let item = windowsDownloads[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Running \(item.name)"
        alert.informativeText = "Couch Cube only downloaded the official installer. It doesn't run Windows programs.\n\n" +
            "To install the launcher, open the installer with a Windows compatibility app such as Porting Kit or CrossOver " +
            "(listed above under Windows games). Whether a launcher or game works depends on that app and its settings."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Porting Kit & CrossOver")
        let show = { (response: NSApplication.ModalResponse) in
            guard response == .alertSecondButtonReturn else { return }
            self.highlightedAppID = "porting-kit"
            self.highlightAppRow()
        }
        if window.isVisible && window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: show) }
        else { show(alert.runModal()) }
    }

    private func makeAppRow(_ app: ManagedApp, index: Int, title: String? = nil, purpose: String? = nil) -> NSView {
        let controls = row([])
        let operation = appOperations[app.id]
        if operation?.running == true {
            // A spinner takes the action button's place at the same size; Homebrew doesn't report real percentages here.
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            progress.translatesAutoresizingMaskIntoConstraints = false
            let slot = NSView()
            slot.addSubview(progress)
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: app.installed ? 26 : 64),
                slot.heightAnchor.constraint(equalToConstant: 26),
                progress.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                progress.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
            ])
            slot.identifier = NSUserInterfaceItemIdentifier("app-progress")
            slot.setAccessibilityElement(true)
            slot.setAccessibilityRole(.progressIndicator)
            slot.setAccessibilityLabel(appRowStatus(app, operation: operation, unknown: false, checking: false).title + " " + app.name)
            controls.addArrangedSubview(slot)
        } else {
            if app.id == "crossover" && app.installed {
                let open = button("Open", #selector(openCrossOver(_:)))
                open.tag = index
                controls.addArrangedSubview(open)
            }
            if app.installed {
                controls.addArrangedSubview(appPillButton("Remove", app: app, index: index,
                                                          action: #selector(appAction(_:)), destructive: true))
            } else {
                controls.addArrangedSubview(appPillButton(operation?.failure == nil ? "Get" : "Retry", app: app, index: index,
                                                          action: #selector(appAction(_:))))
            }
        }
        let unknown = !appsHaveResults && app.path.isEmpty && app.version.isEmpty && operation == nil
        let state = appRowStatus(app, operation: operation, unknown: unknown, checking: appsChecking)
        let statusLine = row([statusIndicator(state.title, color: state.color, pulsing: state.pulsing), NSView()])
        statusLine.identifier = NSUserInterfaceItemIdentifier("app-status")
        controls.isHidden = unknown
        controls.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = !appsChecking && task == nil }
        statusLine.toolTip = app.installed ? "Version \(app.version)" + (app.update.map { " · Update \($0) available" } ?? "") : nil
        statusLine.distribution = .fill
        let info = column([statusLine,
                           text(purpose ?? appPurposes[app.id] ?? app.name, size: 11, secondary: true)])
        info.spacing = 4
        let line = settingsRow(title ?? app.name, subtitle: "", symbol: "app.fill",
                               color: .systemBlue, trailing: controls, detail: info)
        let bundledIcon = Bundle.main.resourceURL?.appendingPathComponent("AppIcons/\(app.id).png")
        let appIcon = app.installed ? NSWorkspace.shared.icon(forFile: app.path) :
            bundledIcon.flatMap { NSImage(contentsOf: $0) }
        if let appIcon = appIcon, let stack = line as? NSStackView, let first = stack.arrangedSubviews.first {
            let icon = NSImageView(image: appIcon)
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
            stack.insertArrangedSubview(icon, at: 0)
        }
        line.identifier = NSUserInterfaceItemIdentifier("app-row-" + app.id)
        return line
    }

    private func renderTVMenus() {
        defaultMenuPicker.removeAllItems()
        defaultMenuPicker.autoenablesItems = false
        var selectedIndex: Int?
        for id in ["steam", "es-de"] {
            let installed = appStates.first { $0.id == id }?.installed ??
                report.map { !$0.missing.contains(id) } ?? false
            defaultMenuPicker.addItem(withTitle: (id == "steam" ? "Steam Big Picture" : "ES-DE") +
                (installed ? "" : " — Not installed"))
            let item = defaultMenuPicker.lastItem!
            item.representedObject = id
            item.isEnabled = installed
            if effectiveFrontend == id { selectedIndex = defaultMenuPicker.numberOfItems - 1 }
        }
        if let index = selectedIndex { defaultMenuPicker.selectItem(at: index) }
        else {
            defaultMenuPicker.insertItem(withTitle: "Choose a menu", at: 0)
            defaultMenuPicker.item(at: 0)?.isEnabled = false
            defaultMenuPicker.selectItem(at: 0)
        }
        defaultMenuPicker.isEnabled = task == nil && !appsChecking &&
            defaultMenuPicker.itemArray.contains { $0.representedObject != nil && $0.isEnabled }
        tvMenuStatus.stringValue = selectedIndex == nil ? "Install Steam or ES-DE in App Store to get started." : ""
        tvMenuStatus.isHidden = tvMenuStatus.stringValue.isEmpty
    }

    @objc private func defaultMenuChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let index = appStates.firstIndex(where: { $0.id == id && $0.installed }) else {
            renderTVMenus()
            return
        }
        let control = NSButton()
        control.tag = index
        setDefaultMenu(control)
    }

    @objc private func showTVMenus() { selectPage(10); loadPageData(10) }

    @objc private func setDefaultMenu(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        execute(["frontend", "--default", app.id, "--confirm"]) { code, _ in
            if code == 0 {
                self.preferredFrontend = app.id
                self.renderTVMenus()
                self.updateSetupSummary()
            } else {
                self.renderTVMenus()
                self.tvMenuStatus.isHidden = false
                self.tvMenuStatus.stringValue = "Couldn't save the default menu. Open Activity for details."
            }
        }
    }

    @objc private func updateAllApps() {
        let updates = appStates.filter { $0.installed && $0.managed && $0.update?.isEmpty == false }
        guard task == nil, !updates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Update \(updates.count) apps?"
        alert.informativeText = "Quit these apps first: " + updates.map { $0.name }.joined(separator: ", ") +
            ". Homebrew will update only these managed apps. Self-updating and manually installed apps use their own updaters."
        alert.addButton(withTitle: "Update all")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateNextApp(updates)
    }

    private func updateNextApp(_ remaining: [ManagedApp]) {
        guard let app = remaining.first else { return }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            let message = "Quit \(app.name), then try Update all again."
            append(message + "\n")
            fetchApps(updates: false) { success in
                if success { self.appsStatus.stringValue = message }
            }
            return
        }
        runAppOperation(app, action: "update") { verified in
            if verified { self.updateNextApp(Array(remaining.dropFirst())) }
            else { self.appsStatus.stringValue = "Update stopped at \(app.name). Try again, or choose View > Activity for details." }
        }
    }

    @objc private func closeInspector() {
        selectPage(inspectorParent)
    }

    @objc private func showConsoleDetails(_ sender: NSButton) {
        guard consoleSystems.indices.contains(sender.tag) else { return }
        let system = consoleSystems[sender.tag]
        inspectorSystemID = system.id
        inspectorParent = 7
        inspectorTitle.stringValue = system.name
        clearRows(inspectorRows)
        let emulator = emulatorStatus(system)
        let store = NSButton(title: "Show in App Store", target: self, action: #selector(showEmulatorInAppStore(_:)))
        store.image = NSImage(systemSymbolName: "storefront", accessibilityDescription: nil)
        store.imagePosition = .imageLeading
        store.bezelStyle = .rounded
        store.controlSize = .small
        store.identifier = NSUserInterfaceItemIdentifier(system.package)
        store.toolTip = "Show \(emulatorName(system)) in App Store"
        let emulatorRow = row([statusIndicator(emulator.title, color: emulator.color), NSView(), store])
        emulatorRow.distribution = .fill
        inspectorRows.addArrangedSubview(emulatorRow)
        if let bios = system.bios, bios.state != "not-needed" {
            let status = biosStatusView(bios, searchQuery: system.name + " BIOS")
            inspectorRows.addArrangedSubview(status)
            status.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
        }
        selectPage(9)
    }

    private func appStoreLink(for system: ConsoleSystem) -> NSButton {
        let name = emulatorName(system)
        let control = NSButton(image: NSImage(systemSymbolName: "storefront",
                                              accessibilityDescription: "Show \(name) in App Store")!,
                               target: self, action: #selector(showEmulatorInAppStore(_:)))
        control.isBordered = false
        control.contentTintColor = .secondaryLabelColor
        control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        control.identifier = NSUserInterfaceItemIdentifier(system.package)
        control.toolTip = "Show \(name) in App Store"
        control.setAccessibilityLabel(control.toolTip)
        return control
    }

    @objc private func showEmulatorInAppStore(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showAppInStore(id)
    }

    private var highlightedAppID: String?

    private func showAppInStore(_ id: String) {
        highlightedAppID = id
        let category = id == "steam" || id == "es-de" ? "TV menus" : computerGameApps.contains(id) ? "PC games" :
            ["porting-kit", "crossover"].contains(id) ? "Windows games" : "Retro games"
        if appStates.first(where: { $0.id == id })?.installed != true && collapsedAppCategories.contains(category),
           let toggle = appCategoryToggles[category] {
            toggleAppCategory(toggle)
        }
        showPlayers()
        highlightAppRow()
    }

    private func highlightAppRow() {
        guard let id = highlightedAppID else { return }
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "app-row-" + id { return view }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        guard let line = [appMenuRows, appPCRows, appWindowsRows, appRetroRows].lazy.compactMap({ find($0) }).first else { return }
        if !appsChecking { highlightedAppID = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        line.scrollToVisible(line.bounds.insetBy(dx: 0, dy: -120))
        line.wantsLayer = true
        line.layer?.cornerRadius = 8
        let color = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        line.layer?.backgroundColor = color
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = color
        fade.toValue = NSColor.clear.cgColor
        fade.beginTime = CACurrentMediaTime() + 1.6
        fade.duration = 0.8
        fade.fillMode = .backwards
        line.layer?.add(fade, forKey: "highlight")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak line] in
            line?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func openCrossOver(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag), appStates[sender.tag].id == "crossover",
              appStates[sender.tag].installed else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appStates[sender.tag].path),
                                          configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.appsStatus.stringValue = "Couldn't open CrossOver: \(error.localizedDescription)"
                    self.append(self.appsStatus.stringValue + "\n")
                }
            }
        }
    }

    @objc private func appAction(_ sender: NSButton) {
        guard task == nil, appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        if app.installed && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) {
            appsStatus.stringValue = "Quit \(app.name) first, then choose Remove."
            return
        }
        if !app.installed && app.manual {
            if let url = app.url, let link = URL(string: url) {
                NSWorkspace.shared.open(link)
                appsStatus.stringValue = "Finish the official installer, then reopen App Store to check the installation."
            } else {
                let alert = NSAlert()
                alert.messageText = "Switch emulator: manual setup"
                alert.informativeText = "No verified automatic Switch emulator download is bundled. If you have a compatible Ryujinx-based macOS build, install it as Ryujinx.app in Applications. Configure your own legally obtained keys, firmware and game dumps there, then reopen App Store. Availability and game compatibility are not guaranteed."
                alert.runModal()
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = app.installed ? "Remove \(app.name)?" : "Install \(app.name)?"
        alert.informativeText = app.installed
            ? "Quit \(app.name) first. The app will be removed. Game libraries, saves and preferences are kept. To remove another app, select it separately."
            : "Homebrew will install this app on this Mac. It won't install games or sign in to accounts."
        alert.addButton(withTitle: app.installed ? "Remove app" : "Install app")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if app.installed && !app.managed {
            NSWorkspace.shared.recycle([URL(fileURLWithPath: app.path)]) { _, error in
                DispatchQueue.main.async {
                    if let error = error { self.appsStatus.stringValue = "Couldn't remove app: \(error.localizedDescription)" }
                    else { self.loadApps() }
                }
            }
            return
        }
        manage(app, action: app.installed ? "remove" : "install")
    }

    @objc private func updateApp(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            appsStatus.stringValue = "Quit \(app.name) before updating."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update \(app.name)?"
        alert.informativeText = "Quit the app first. Homebrew will download and install the update."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { manage(app, action: "update") }
    }

    private func manage(_ app: ManagedApp, action: String) {
        if action == "install", appStates.first?.brew != true {
            fetchApps(updates: false) { success in
                guard success else { return }
                if self.appStates.first?.brew == true { self.manage(app, action: action) }
                else { self.homebrew() }
            }
            return
        }
        runAppOperation(app, action: action)
    }

    /// Runs one Homebrew app operation, then re-checks only that app before showing it as done (green).
    private func runAppOperation(_ app: ManagedApp, action: String, completed: ((Bool) -> Void)? = nil) {
        guard task == nil, appOperations[app.id]?.running != true else {
            appsStatus.stringValue = "Wait for the current operation to finish."
            completed?(false)
            return
        }
        appsStatus.stringValue = ""
        // Results of app checks started before this change must not overwrite it.
        appsLoadGeneration += 1
        appsChecking = false
        appOperations[app.id] = AppOperation(action: action, phase: nil, failure: nil, running: true)
        refreshAppRow(app.id)
        appOperationOutput = { [weak self] output in
            guard let self, let phase = appOperationPhase(output, action: action),
                  self.appOperations[app.id]?.running == true, self.appOperations[app.id]?.phase != phase else { return }
            self.appOperations[app.id]?.phase = phase
            self.refreshAppRow(app.id)
        }
        appOperationRun(["manage-app", "--package", app.id, "--action", action, "--confirm"]) { code in
            self.appOperationOutput = nil
            self.verifyApp(app.id, action: action, succeeded: code == 0, completed: completed)
        }
    }

    private func verifyApp(_ id: String, action: String, succeeded: Bool, completed: ((Bool) -> Void)?) {
        appVerifyTokens[id, default: 0] += 1
        let token = appVerifyTokens[id]!
        appOperations[id]?.phase = "Checking"
        refreshAppRow(id)
        appVerifyRead(["apps", "--updates", "--package", id]) { code, data in
            guard self.appVerifyTokens[id] == token else { return }
            let verified = code == 0 ? (try? JSONDecoder().decode([ManagedApp].self, from: data))?.first { $0.id == id } : nil
            if let verified, let index = self.appStates.firstIndex(where: { $0.id == id }) { self.appStates[index] = verified }
            let reached = verified.map { action == "remove" ? !$0.installed : $0.installed && $0.update?.isEmpty != false } ?? false
            let name = verified?.name ?? self.appStates.first { $0.id == id }?.name ?? id
            if succeeded && reached {
                self.appOperations[id] = nil
            } else {
                let verb = action == "remove" ? "remove" : action == "update" ? "update" : "install"
                self.appOperations[id] = AppOperation(action: action, phase: nil,
                    failure: verified == nil ? "Couldn't confirm the \(verb)" : "Couldn't \(verb)", running: false)
                self.appsStatus.stringValue = verified == nil
                    ? "Couldn't check \(name) after the \(verb). Reopen App Store to check again."
                    : "Couldn't \(verb) \(name). Try again, or choose View > Activity for details."
            }
            // Any full app check still in flight predates this verified state.
            self.appsLoadGeneration += 1
            self.appsChecking = false
            self.lastAppsData = nil
            if let report = self.report {
                self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                         missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                         preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                self.updateSetupSummary()
            }
            self.refreshAppRow(id)
            let updates = self.appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
            self.updateAllButton.isHidden = !updates
            self.updateAllButton.isEnabled = updates && self.task == nil
            self.renderTVMenus()
            self.renderGeneral()
            completed?(succeeded && reached)
        }
    }

    private func loadSystems() {
        if consoleSystems.isEmpty {
            consolesLoaded = false
            let catalog = [
                ("nes", "Nintendo Entertainment System"), ("snes", "Super Nintendo"),
                ("n64", "Nintendo 64"), ("gc", "GameCube"), ("wii", "Wii"),
                ("wiiu", "Wii U"), ("switch", "Nintendo Switch"),
                ("gb", "Game Boy"), ("gbc", "Game Boy Color"), ("gba", "Game Boy Advance"),
                ("psx", "PlayStation"), ("ps2", "PlayStation 2"),
                ("psp", "PlayStation Portable"), ("ps3", "PlayStation 3"),
                ("megadrive", "Mega Drive / Genesis"), ("segacd", "Sega CD"), ("dreamcast", "Dreamcast")
            ]
            consoleSystems = catalog.map {
                let package = ["gc": "dolphin", "wii": "dolphin", "wiiu": "cemu-wiiu",
                               "switch": "switch", "ps2": "pcsx2", "ps3": "rpcs3"][$0.0] ?? "retroarch-metal"
                return ConsoleSystem(id: $0.0, name: $0.1, enabled: false, package: package,
                                     requirement: "", bios: nil)
            }
        }
        consolesChecking = selected != nil && report?.state == "valid layout"
        // Refreshing already loaded consoles is silent: the rows stay as they are until real changes arrive.
        if !consolesLoaded { renderSystems() }
        if task != nil && consolesChecking {
            consoleRefreshPending = true
            return
        }
        guard task == nil, let root = consoleRoot(), report?.state == "valid layout" else {
            consolesChecking = false
            renderSystems()
            consoleStatus.stringValue = "Create game folders in Settings → Game library first. Wait for any current operation to finish."
            return
        }
        consoleRefreshPending = false
        consoleStatus.stringValue = ""
        consoleLoadGeneration += 1
        let generation = consoleLoadGeneration
        backendRead(["systems", "--root", root]) { code, data in
            guard generation == self.consoleLoadGeneration else { return }
            self.consolesChecking = false
            guard self.consoleRoot() == root else { return }
            guard code == 0 else {
                if !self.consolesLoaded { self.renderSystems() }
                self.consoleStatus.stringValue = "Couldn't read console selection. Choose View > Activity for details."
                self.append("Couldn't read console selection.\n")
                self.activityNeeded()
                return
            }
            do {
                self.acceptSystems(try JSONDecoder().decode([ConsoleSystem].self, from: data))
                self.renderGeneral()
                self.consoleStatus.stringValue = ""
            } catch {
                self.renderSystems()
                self.consoleStatus.stringValue = "Couldn't read consoles: \(error.localizedDescription)"
                self.append(self.consoleStatus.stringValue + "\n")
            }
        }
    }

    private func renderSystems() {
        clearRows(consoleRows)
        systemSwitches = []
        systemStatusLines = []
        consoleBulkToggles = []
        let present = Set(consoleSystems.map(\.id))
        func ids(_ groups: [String]) -> Set<String> {
            Set(ConsoleArtwork.groups.filter { groups.contains($0.title) }.flatMap(\.systems)).intersection(present)
        }
        let allRow = consoleBulkRow("All consoles", scope: "all consoles", ids: present, size: 13)
        consoleRows.addArrangedSubview(allRow)
        allRow.widthAnchor.constraint(equalTo: consoleRows.widthAnchor).isActive = true
        let order = ConsoleArtwork.groups.flatMap { $0.systems }
        consoleSystems.sort {
            (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100)
        }
        var manufacturerRows: [String: NSStackView] = [:]
        for manufacturer in ["Nintendo", "PlayStation", "SEGA"] {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
            manufacturerRows[manufacturer] = rows
            let groups = ConsoleArtwork.groups.map(\.title).filter { $0 == manufacturer || ($0.hasPrefix(manufacturer) && manufacturer == "Nintendo") }
            let heading = consoleBulkRow(manufacturer, scope: manufacturer + " consoles", ids: ids(groups), size: 13)
            let box = card("", subtitle: nil, views: [heading, rows])
            consoleRows.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: consoleRows.widthAnchor).isActive = true
        }
        var previousGroup = ""
        for (index, system) in consoleSystems.enumerated() {
            let group = ConsoleArtwork.groups.first { $0.systems.contains(system.id) }?.title ?? "Other systems"
            let manufacturer = group.hasPrefix("Nintendo") ? "Nintendo" : group
            guard let rows = manufacturerRows[manufacturer] else { continue }
            if group != previousGroup {
                if manufacturer == "Nintendo" {
                    let title = group == "Nintendo home consoles" ? "Home consoles" : "Handhelds"
                    let heading = consoleBulkRow(title, scope: "Nintendo " + title.lowercased(), ids: ids([group]), size: 12)
                    let container = NSView()
                    heading.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(heading)
                    NSLayoutConstraint.activate([
                        heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                        heading.topAnchor.constraint(equalTo: container.topAnchor, constant: rows.arrangedSubviews.isEmpty ? 4 : 18),
                        heading.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
                    ])
                    rows.addArrangedSubview(container)
                    container.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                }
                previousGroup = group
            } else {
                let separator = NSBox()
                separator.boxType = .separator
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = system.enabled ? .on : .off
            toggle.isEnabled = consolesLoaded
            toggle.target = self
            toggle.action = #selector(toggleSystem(_:))
            toggle.setAccessibilityLabel(system.name)
            systemSwitches.append(toggle)
            let info = button("", #selector(showConsoleDetails(_:)))
            info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Details for \(system.name)")
            info.isBordered = false
            info.tag = index
            info.toolTip = "Details"
            info.setAccessibilityLabel("Details for \(system.name)")
            let controls = row([appStoreLink(for: system), info, toggle])
            let statusLine = row([])
            statusLine.distribution = .fill
            fillSystemStatus(statusLine, system)
            systemStatusLines.append(statusLine)
            let line = settingsRow(system.name,
                subtitle: "",
                symbol: "gamecontroller.fill", color: .secondaryLabelColor, trailing: controls,
                artwork: ConsoleArtwork.image(for: system.id), detail: statusLine, bareArtwork: true)
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        }
        updateConsoleBulkToggles()
    }

    /// A heading with a trailing switch for every console beneath it; "3 of 7" marks a mixed group.
    private func consoleBulkRow(_ title: String, scope: String, ids: Set<String>, size: CGFloat) -> NSStackView {
        let heading = text(title, size: size, secondary: size < 13)
        heading.font = .systemFont(ofSize: size, weight: .semibold)
        let count = text("", size: 11, secondary: true)
        count.identifier = NSUserInterfaceItemIdentifier("console-bulk-count")
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleConsoleGroup(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier("console-bulk")
        consoleBulkToggles.append((toggle, count, ids, scope))
        let line = row([heading, NSView(), count, toggle])
        line.distribution = .fill
        return line
    }

    /// On only when every console beneath is shown; a mixed group shows Off plus a count, so a click shows all.
    private func updateConsoleBulkToggles() {
        let enabled = Set(consoleSystems.filter(\.enabled).map(\.id))
        for bulk in consoleBulkToggles {
            let shown = bulk.ids.intersection(enabled).count, total = bulk.ids.count
            let mixed = shown > 0 && shown < total
            bulk.toggle.state = total > 0 && shown == total ? .on : .off
            bulk.toggle.isEnabled = consolesLoaded && total > 0
            bulk.count.stringValue = mixed ? "\(shown) of \(total)" : ""
            bulk.count.isHidden = !mixed
            let state = shown == total ? "all \(total) shown" : shown == 0 ? "all hidden" : "\(shown) of \(total) shown"
            let action = shown == total ? "Hide" : "Show"
            bulk.toggle.setAccessibilityLabel("Show all \(bulk.scope), \(state)")
            bulk.toggle.toolTip = "\(action) all \(bulk.scope) (\(state))"
        }
    }

    /// Same fast path as single switches: rows update in place and one debounced save covers the whole batch.
    /// Showing consoles never installs emulators or asks to.
    @objc private func toggleConsoleGroup(_ sender: NSSwitch) {
        guard consolesLoaded, let bulk = consoleBulkToggles.first(where: { $0.toggle === sender }),
              systemSwitches.count == consoleSystems.count else {
            updateConsoleBulkToggles()
            consoleStatus.stringValue = "Wait until your consoles are loaded."
            return
        }
        if esdeRunning {
            updateConsoleBulkToggles()
            consoleStatus.stringValue = "Quit ES-DE first. It must not overwrite updated frontend settings."
            return
        }
        let show = sender.state == .on
        if consolePersistedEnabled == nil { consolePersistedEnabled = Set(consoleSystems.filter(\.enabled).map(\.id)) }
        var changed = false
        for index in consoleSystems.indices where bulk.ids.contains(consoleSystems[index].id) && consoleSystems[index].enabled != show {
            consoleSystems[index].enabled = show
            systemSwitches[index].state = show ? .on : .off
            fillSystemStatus(systemStatusLines[index], consoleSystems[index])
            changed = true
        }
        updateConsoleBulkToggles()
        guard changed else { return }
        consoleEditGeneration += 1
        scheduleConsoleSave()
    }

    private func fillSystemStatus(_ statusLine: NSStackView, _ system: ConsoleSystem) {
        statusLine.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let emulator = emulatorStatus(system)
        let initialCheck = consolesChecking && !consolesLoaded
        var indicators: [NSView] = [statusIndicator(initialCheck ? emulatorName(system) : emulator.title,
            color: initialCheck ? .systemBlue : emulator.color, pulsing: initialCheck)]
        if system.enabled, let bios = system.bios, bios.state != "not-needed" {
            indicators.append(initialCheck
                ? statusIndicator("BIOS", color: .systemBlue, pulsing: true)
                : biosIndicator(bios))
        }
        indicators.append(NSView())
        indicators.forEach(statusLine.addArrangedSubview)
        statusLine.toolTip = emulator.help
    }

    /// Takes a fresh status read, keeping unsaved toggles, and updates rows in place when the list is already shown.
    private func acceptSystems(_ fresh: [ConsoleSystem]) {
        var systems = fresh
        consolePersistedEnabled = Set(systems.filter(\.enabled).map(\.id))
        if consoleSaveInFlight || consoleSaveTimer != nil || consoleSaveDirty {
            let intent = Dictionary(uniqueKeysWithValues: consoleSystems.map { ($0.id, $0.enabled) })
            systems = systems.map { system in
                var system = system
                system.enabled = intent[system.id] ?? system.enabled
                return system
            }
        }
        let wasLoaded = consolesLoaded
        consolesLoaded = true
        if !(wasLoaded && applySystemsInPlace(systems)) {
            consoleSystems = systems
            renderSystems()
        }
    }

    /// Updates switches and status lines without rebuilding the list, so scroll position and focus stay put.
    @discardableResult
    private func applySystemsInPlace(_ systems: [ConsoleSystem]) -> Bool {
        guard systemSwitches.count == consoleSystems.count, systemStatusLines.count == consoleSystems.count,
              Set(systems.map(\.id)) == Set(consoleSystems.map(\.id)), systems.count == consoleSystems.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: systems.map { ($0.id, $0) })
        consoleSystems = consoleSystems.map { byID[$0.id]! }
        for (index, system) in consoleSystems.enumerated() {
            systemSwitches[index].state = system.enabled ? .on : .off
            systemSwitches[index].isEnabled = consolesLoaded
            fillSystemStatus(systemStatusLines[index], system)
        }
        updateConsoleBulkToggles()
        return true
    }

    static let appUpdatedMessage = "Couch Cube was updated while it was open. Please quit and reopen Couch Cube."

    /// A rebuilt or replaced app can leave this running copy without its backend files; say so instead of showing Python's error.
    func friendlyBackendError(_ text: String) -> String {
        let runtime = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3").path
        let missing = !FileManager.default.fileExists(atPath: backend.path) || !FileManager.default.fileExists(atPath: runtime)
        let pythonCannotOpen = text.contains("can't open file") && text.contains("/Contents/Resources/scripts/")
        return missing || pythonCannotOpen ? Self.appUpdatedMessage : text
    }

    /// A background backend run that reports stdout line by line and can be canceled with terminate().
    private func runBackendStreaming(_ arguments: [String], line: @escaping (String) -> Void,
                                     completed: @escaping (Int32, String) -> Void) -> Process {
        precondition(!ProcessInfo.processInfo.arguments.contains("--smoke-test"), "Smoke tests must never download")
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completed(1, self.friendlyBackendError("ERROR: Cannot start bundled runtime: \(error.localizedDescription)")) }
                return
            }
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    DispatchQueue.main.async { line(text) }
                }
            }
            process.waitUntilExit()
            group.wait()
            let code = process.terminationStatus
            let text = String(decoding: errorData, as: UTF8.self)
            DispatchQueue.main.async { completed(code, code == 0 ? text : self.friendlyBackendError(text)) }
        }
        return process
    }

    private func runBackendInBackground(_ arguments: [String], completed: @escaping (Int32, Data, String) -> Void) {
        precondition(!arguments.contains("--confirm") || !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
                     "Read-only smoke tests must never run mutations")
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completed(1, Data(), self.friendlyBackendError("Cannot start bundled runtime: \(error.localizedDescription)")) }
                return
            }
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.wait()
            let code = process.terminationStatus
            let text = String(decoding: errorData, as: UTF8.self)
            DispatchQueue.main.async { completed(code, data, code == 0 ? text : self.friendlyBackendError(text)) }
        }
    }

    private func emulatorName(_ system: ConsoleSystem) -> String {
        ["retroarch-metal": "RetroArch", "cemu-wiiu": "Cemu", "switch": "Ryujinx",
         "pcsx2": "PCSX2", "rpcs3": "RPCS3", "dolphin": "Dolphin"][system.package] ?? system.package
    }

    private func emulatorStatus(_ system: ConsoleSystem) -> (title: String, color: NSColor, help: String) {
        let name = emulatorName(system)
        guard system.enabled else { return (name, .systemGray, "Hidden from your game menu.") }
        let app = appsHaveResults ? appStates.first { $0.id == system.package } : nil
        let installed = system.emulator_installed ?? app?.installed ??
            report.map { !$0.missing.contains(system.package) }
        guard let installed = installed else { return (name, .systemGray, "Emulator not checked yet.") }
        guard installed else { return (name, .systemRed, "\(name) · Not installed. Install it in App Store.") }
        if app?.managed == true, app?.update?.isEmpty == false {
            return ("\(name) · Update available", .systemYellow, "\(name) · Update available in App Store.")
        }
        return (name, .systemGreen, "\(name) · Installed.")
    }

    private func consoleReadiness(_ system: ConsoleSystem) -> (color: NSColor, help: String) {
        guard system.enabled else { return (.systemGray, "Hidden from your game menu. Switch on to check setup.") }
        let installed = system.emulator_installed ??
            report.map { !$0.missing.contains(system.package) } ??
            appStates.first(where: { $0.id == system.package })?.installed
        guard let installed = installed else { return (.systemGray, "Emulator not checked yet. Reopen Consoles to refresh.") }
        guard installed else { return (.systemRed, "Install \(emulatorName(system)) in App Store, then return here.") }
        guard let bios = system.bios else { return (.systemGray, "Emulator installed. Reopen Consoles to check BIOS requirements.") }
        switch bios.state {
        case "present", "not-needed": return (.systemGreen, "Emulator ready. Add your own games in Game library.")
        case "optional": return (.systemYellow, "BIOS recommended. A fallback is available; open help for optional filenames.")
        case "missing", "partial": return (.systemRed, "Required BIOS files are missing. Open help to copy filenames and see where they go.")
        default: return (.systemGray, bios.summary + ". Open the emulator to check its setup.")
        }
    }

    private func biosIndicator(_ bios: BIOSStatus) -> NSView {
        let color: NSColor = bios.state == "present" || bios.state == "not-needed" ? .systemGreen :
            bios.state == "missing" || bios.state == "partial" ? .systemRed : bios.state == "manual" ? .systemGray : .systemYellow
        let title = bios.state == "optional" ? "BIOS recommended · Fallback available" :
            bios.state == "manual" ? "BIOS · Check in emulator" : "BIOS"
        let view = statusIndicator(title, color: color)
        view.toolTip = bios.summary
        return view
    }

    private func biosStatusView(_ bios: BIOSStatus, searchQuery: String? = nil) -> NSView {
        let indicator = row([biosIndicator(bios), NSView()])
        indicator.distribution = .fill
        let missing = bios.files.filter { !$0.present }
        guard !missing.isEmpty && bios.state != "present" else { return indicator }
        var sections: [NSView] = [indicator]
        var folders: [String] = []
        for file in missing {
            let folder = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
            if !folders.contains(folder) { folders.append(folder) }
        }
        for folder in folders {
            var shown = folder
            if let root = selected?.root, folder.hasPrefix(root) {
                shown = URL(fileURLWithPath: root).lastPathComponent + folder.dropFirst(root.count)
            }
            let place = row([text("Put in", size: 11, secondary: true),
                             pill(shown, symbol: "folder", action: #selector(openBIOSFolder(_:)),
                                  value: folder, help: "Open " + folder), NSView()])
            place.distribution = .fill
            let names = missing.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == folder }
                .map { URL(fileURLWithPath: $0.filename).lastPathComponent }
            let fileRows = NSStackView()
            fileRows.orientation = .vertical
            fileRows.alignment = .leading
            fileRows.spacing = 4
            for start in stride(from: 0, to: names.count, by: 3) {
                fileRows.addArrangedSubview(row(names[start..<min(start + 3, names.count)].map {
                    pill($0, symbol: "doc.on.doc", action: #selector(copyBIOSNames(_:)), value: $0,
                         help: "Copy filename " + $0)
                }))
            }
            let files = row([text("Files", size: 11, secondary: true), fileRows, NSView()])
            files.distribution = .fill
            files.alignment = .top
            sections.append(column([place, files]))
        }
        if let query = searchQuery {
            let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
            glass.contentTintColor = .secondaryLabelColor
            glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            let phrase = text("Search online for \u{201C}\(query)\u{201D}", size: 11, secondary: true)
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyBIOSNames(_:)))
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            copy.font = .systemFont(ofSize: 11)
            copy.identifier = NSUserInterfaceItemIdentifier(query)
            copy.toolTip = "Copy search phrase: " + query
            copy.setAccessibilityLabel(copy.toolTip)
            let search = row([glass, phrase, copy, NSView()])
            search.spacing = 6
            search.distribution = .fill
            sections.append(search)
        }
        let result = column(sections)
        result.spacing = 8
        return result
    }

    /// Small inline link used for BIOS and library folders; the identifier carries the value.
    private func pill(_ title: String, symbol: String, action: Selector, value: String, help: String) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        control.imagePosition = .imageLeading
        control.bezelStyle = .inline
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.identifier = NSUserInterfaceItemIdentifier(value)
        control.toolTip = help
        control.setAccessibilityLabel(help)
        return control
    }

    @objc private func openBIOSFolder(_ sender: NSButton) {
        guard var url = sender.identifier.map({ URL(fileURLWithPath: $0.rawValue) }) else { return }
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyBIOSNames(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(value, forType: .string) else {
            append("Couldn't copy \(value). Try again.\n")
            return
        }
        let title = sender.title, image = sender.image
        sender.title = "Copied"
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = title
            sender?.image = image
        }
    }

    private var pendingEmulatorInstall: ManagedApp?
    private var pendingAppStoreID: String?

    private var esdeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.lastPathComponent == "ES-DE.app" }
    }

    /// Applies the switch immediately; saving is debounced, serialized and off the main thread so toggles never wait.
    @objc private func toggleSystem(_ sender: NSSwitch) {
        guard consolesLoaded, let index = systemSwitches.firstIndex(of: sender), index < consoleSystems.count else {
            consoleStatus.stringValue = "Wait until your consoles are loaded."
            return
        }
        if esdeRunning {
            sender.state = consoleSystems[index].enabled ? .on : .off
            consoleStatus.stringValue = "Quit ES-DE first. It must not overwrite updated frontend settings."
            return
        }
        if consolePersistedEnabled == nil { consolePersistedEnabled = Set(consoleSystems.filter(\.enabled).map(\.id)) }
        consoleSystems[index].enabled = sender.state == .on
        consoleEditGeneration += 1
        fillSystemStatus(systemStatusLines[index], consoleSystems[index])
        updateConsoleBulkToggles()
        if sender.state == .on {
            let system = consoleSystems[index]
            let app = appStates.first { $0.id == system.package }
            if (system.emulator_installed ?? app?.installed) == false {
                let name = emulatorName(system)
                let alert = NSAlert()
                alert.messageText = "Install \(name)?"
                alert.informativeText = "\(system.name) needs \(name) to play games."
                alert.addButton(withTitle: "Install \(name)")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() == .alertFirstButtonReturn {
                    if appsHaveResults, let app = app, !app.manual { pendingEmulatorInstall = app }
                    else { pendingAppStoreID = system.package }
                }
            }
        }
        scheduleConsoleSave()
    }

    private func scheduleConsoleSave() {
        consoleStatus.stringValue = ""
        consoleSaveTimer?.invalidate()
        consoleSaveTimer = Timer.scheduledTimer(withTimeInterval: consoleSaveDelay, repeats: false) { [weak self] _ in
            self?.consoleSaveTimer = nil
            self?.saveSystems()
        }
    }

    @objc private func saveSystems() {
        consoleSaveTimer?.invalidate()
        consoleSaveTimer = nil
        if consoleSaveInFlight {
            consoleSaveDirty = true
            return
        }
        // Wait for other changes to the library (setup, cleanup, installs); the save restarts when they finish.
        if (task != nil && !ProcessInfo.processInfo.arguments.contains("--smoke-test")) || cleanupInProgress {
            consoleSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.consoleSaveTimer = nil
                self?.saveSystems()
            }
            return
        }
        guard let root = consoleRoot(), !consoleSystems.isEmpty else {
            revertConsoleSelection("Load your console selection first. Create game folders in Settings → Game library if needed.")
            return
        }
        if esdeRunning {
            revertConsoleSelection("Quit ES-DE first. It must not overwrite updated frontend settings.")
            return
        }
        let enabled = consoleSystems.filter(\.enabled).map(\.id)
        consoleSaveInFlight = true
        consoleSaveDirty = false
        consoleSaver(root, enabled) { code, errors in
            self.consoleSaveInFlight = false
            guard code == 0 else {
                if !errors.isEmpty { self.append(errors) }
                self.revertConsoleSelection("Couldn't save console selection. Your last saved choices are shown. Open Activity for details.")
                self.activityNeeded()
                return
            }
            self.consolePersistedEnabled = Set(enabled)
            if self.consoleSaveDirty || self.consoleSaveTimer != nil {
                if self.consoleSaveTimer == nil { self.saveSystems() }
                return
            }
            if let app = self.pendingEmulatorInstall {
                self.pendingEmulatorInstall = nil
                self.manage(app, action: "install")
            } else if let id = self.pendingAppStoreID {
                self.pendingAppStoreID = nil
                self.showAppInStore(id)
            }
            self.refreshConsoleStatusInPlace(root: root)
        }
    }

    private func revertConsoleSelection(_ message: String) {
        consoleSaveTimer?.invalidate()
        consoleSaveTimer = nil
        consoleSaveDirty = false
        consoleEditGeneration += 1
        pendingEmulatorInstall = nil
        pendingAppStoreID = nil
        if let persisted = consolePersistedEnabled {
            applySystemsInPlace(consoleSystems.map { system in
                var system = system
                system.enabled = persisted.contains(system.id)
                return system
            })
        }
        consoleStatus.stringValue = message
        append(message + "\n")
    }

    /// Reads BIOS/emulator status after a save and merges it into the rows; ignored if newer toggles happened meanwhile.
    private func refreshConsoleStatusInPlace(root: String) {
        let generation = consoleEditGeneration
        consoleRefresher(root) { code, data in
            guard generation == self.consoleEditGeneration, !self.consoleSaveInFlight, self.consoleSaveTimer == nil else { return }
            guard code == 0, let systems = try? JSONDecoder().decode([ConsoleSystem].self, from: data) else {
                self.consoleStatus.stringValue = "Saved. Couldn't refresh console status; reopen Retro consoles to check again."
                return
            }
            self.consolePersistedEnabled = Set(systems.filter(\.enabled).map(\.id))
            if !self.applySystemsInPlace(systems) {
                self.consoleSystems = systems
                self.renderSystems()
            }
            self.renderGeneral()
        }
    }

    private var cleanupInProgress = false
    private var cleanupReviewChoices: [NSButton] = []

    @objc private func selectCleanupItems(_ sender: NSButton) {
        cleanupReviewChoices.forEach { $0.state = sender.tag == 1 ? .on : .off }
    }

    @objc private func reviewGamingCleanup() {
        guard task == nil, !cleanupInProgress else {
            status.stringValue = "Wait for the current operation to finish."
            return
        }
        execute(["cleanup-plan"], capture: true) { code, data in
            guard code == 0 else { self.activityNeeded("Couldn't scan for cleanup items."); return }
            do {
                let plan = try JSONDecoder().decode(CleanupPlan.self, from: data)
                self.presentGamingCleanup(plan)
            } catch {
                self.status.stringValue = "Couldn't read cleanup items: \(error.localizedDescription)"
                self.append(self.status.stringValue + "\n")
                self.activityNeeded(self.status.stringValue)
            }
        }
    }

    private func presentGamingCleanup(_ plan: CleanupPlan) {
        let alert = NSAlert()
        alert.messageText = "Clean up gaming setup"
        alert.informativeText = "Select what to remove, including anything installed before Couch Cube. Back up first and quit all games and launchers.\n\nGame data includes saves, BIOS, addons and Windows bottles. Removing Couch Cube settings also disables automatic console mode.\n\nOnly detected locations are listed. Custom folders, other accounts and disconnected drives are not scanned. Homebrew, shared dependencies and Rosetta are kept. Trash is not emptied."
        alert.addButton(withTitle: "Continue...")
        alert.addButton(withTitle: "Cancel")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        var choices: [NSButton] = []
        for item in plan.items {
            let checkbox = NSButton(checkboxWithTitle: "\(item.name) (\(item.category))", target: nil, action: nil)
            checkbox.state = .off
            choices.append(checkbox)
            list.addArrangedSubview(checkbox)
            let path = NSTextField(wrappingLabelWithString: item.path)
            path.font = .systemFont(ofSize: 11)
            path.textColor = .secondaryLabelColor
            path.isSelectable = true
            path.widthAnchor.constraint(equalToConstant: 550).isActive = true
            list.addArrangedSubview(path)
        }
        let removeSelf = NSButton(checkboxWithTitle: "Also move this copy of Couch Cube to Trash", target: nil, action: nil)
        list.addArrangedSubview(removeSelf)
        cleanupReviewChoices = choices
        defer { cleanupReviewChoices = [] }
        let selectAll = NSButton(title: "Select all detected items", target: self, action: #selector(selectCleanupItems(_:)))
        selectAll.tag = 1
        let deselectAll = NSButton(title: "Deselect all", target: self, action: #selector(selectCleanupItems(_:)))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 360))
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            list.widthAnchor.constraint(equalToConstant: 560)
        ])
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = column([row([selectAll, deselectAll]), scroll])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = zip(plan.items, choices).filter { $0.1.state == .on }.map { $0.0 }
        guard !selected.isEmpty else {
            status.stringValue = "No cleanup items selected. Use Uninstall to remove only Couch Cube."
            return
        }
        let gamingApps = Set(["Steam.app", "FX Steam Launcher.app", "GOG Galaxy.app", "EA app.app", "Epic Games Launcher.app",
                              "Battle.net.app", "CurseForge.app", "ES-DE.app", "RetroArch.app",
                              "Dolphin.app", "Porting Kit.app", "CrossOver.app", "PCSX2.app",
                              "RPCS3.app", "Cemu.app", "Ryujinx.app"])
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL else { return false }
            return gamingApps.contains(url.lastPathComponent) ||
                selected.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
        }
        guard running.isEmpty else {
            let warning = NSAlert()
            warning.messageText = "Quit gaming apps first"
            warning.informativeText = running.map { $0.localizedName ?? "Gaming app" }.joined(separator: ", ")
            warning.runModal()
            return
        }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Remove \(selected.count) selected items?"
        confirmation.informativeText = "Homebrew-managed apps will be uninstalled. Other selected files move to Trash where supported; macOS may report that an external disk cannot use Trash. Recovery of uninstalled apps or unsynced saves is not guaranteed.\n\nType REMOVE to confirm."
        let summary = NSTextView(frame: NSRect(x: 0, y: 0, width: 550, height: 180))
        summary.isEditable = false
        summary.font = .systemFont(ofSize: 12)
        summary.isVerticallyResizable = true
        summary.maxSize = NSSize(width: 550, height: CGFloat.greatestFiniteMagnitude)
        summary.textContainer?.widthTracksTextView = true
        summary.string = selected.map { "\($0.name)\n\($0.path)" }.joined(separator: "\n\n") +
            (removeSelf.state == .on ? "\n\nCouch Cube\n\(Bundle.main.bundleURL.path)" : "")
        let summaryScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 550, height: 180))
        summaryScroll.hasVerticalScroller = true
        summaryScroll.documentView = summary
        summaryScroll.widthAnchor.constraint(equalToConstant: 550).isActive = true
        summaryScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let typed = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        typed.setAccessibilityLabel("Type REMOVE to confirm cleanup")
        confirmation.accessoryView = column([summaryScroll, typed])
        confirmation.addButton(withTitle: "Remove selected items")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn, typed.stringValue == "REMOVE" else { return }
        var arguments = ["cleanup-prepare", "--confirm", "--token", plan.token, "--items"]
        arguments += selected.map(\.id)
        execute(arguments, capture: true) { code, data in
            guard code == 0 else {
                self.status.stringValue = "Cleanup stopped. Some apps may already be uninstalled. Review Activity and scan again."
                self.activityNeeded(self.status.stringValue)
                return
            }
            do {
                let targets = try JSONDecoder().decode(CleanupTargets.self, from: data)
                var urls = targets.paths.map { URL(fileURLWithPath: $0) }
                if removeSelf.state == .on { urls.append(Bundle.main.bundleURL) }
                if urls.isEmpty {
                    self.status.stringValue = "Selected apps removed. Shared dependencies and unselected data were kept."
                    self.appsHaveResults = false
                    self.consolesLoaded = false
                    self.refresh()
                    return
                }
                self.cleanupInProgress = true
                self.busy(true)
                NSWorkspace.shared.recycle(urls) { moved, error in
                    DispatchQueue.main.async {
                        self.cleanupInProgress = false
                        self.busy(false)
                        if let error = error {
                            let remaining = urls.filter { moved[$0] == nil }.map(\.path).joined(separator: "\n")
                            self.status.stringValue = "Cleanup incomplete: \(error.localizedDescription)"
                            self.append(self.status.stringValue + "\nNot moved:\n" + remaining + "\n")
                            self.activityNeeded(self.status.stringValue)
                        } else if removeSelf.state == .on {
                            NSApp.terminate(nil)
                        } else {
                            if let identifier = Bundle.main.bundleIdentifier,
                               targets.paths.contains(where: { $0.hasSuffix("/\(identifier).plist") }) {
                                UserDefaults.standard.removePersistentDomain(forName: identifier)
                            }
                            self.status.stringValue = "Selected items removed. Trash was not emptied. Unselected and undetected items were kept."
                            self.appsHaveResults = false
                            self.consolesLoaded = false
                            self.refresh()
                        }
                    }
                }
            } catch {
                self.status.stringValue = "Cleanup stopped after app removal: \(error.localizedDescription)"
                self.append(self.status.stringValue + "\n")
                self.activityNeeded(self.status.stringValue)
            }
        }
    }

    @objc private func uninstallCouchCube() {
        guard task == nil else { status.stringValue = "Wait for the current operation to finish."; return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Couch Cube?"
        alert.informativeText = "Moves this copy of Couch Cube to Trash and removes its saved Mac selection, login entry and login log. Games, ROMs, BIOS, saves, other installed apps and game-library folders are kept. You can remove other apps individually in App Store."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["cleanup-host", "--confirm"]) { code, _ in
            guard code == 0 else { return }
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                DispatchQueue.main.async {
                    if let error = error { self.status.stringValue = "Settings removed, but couldn't move app to Trash: \(error.localizedDescription)" }
                    else { NSApp.terminate(nil) }
                }
            }
        }
    }

    private func loadAutoLaunch() {
        guard task == nil else { return }
        overviewChecks.insert(.automatic)
        overviewCheckFailures.remove(.automatic)
        defer { renderGeneral() }
        execute(["login-status"], capture: true) { code, data in
            self.overviewChecks.remove(.automatic)
            defer {
                self.renderGeneral()
                if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    if self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!) == 10 { self.loadApps() }
                    else { self.loadSteamStatus() }
                }
            }
            guard code == 0 else {
                self.overviewCheckFailures.insert(.automatic)
                self.autoLaunchStatus.stringValue = "Cannot read login settings. Open Details for the error."
                self.activityNeeded()
                return
            }
            do {
                let settings = try JSONDecoder().decode(AutoLaunchSettings.self, from: data)
                self.autoLaunchToggle.state = settings.enabled ? .on : .off
                self.autoLaunchDelay.stringValue = String(settings.delay)
                self.autoLaunchLoaded = true
                self.autoLaunchStatus.stringValue = settings.legacy
                    ? "An older always-on Steam login launcher is installed. Save to replace it with controller-aware console mode."
                    : settings.enabled ? "Enabled for the next login on this Mac." : "Off. Nothing starts automatically."
                self.renderGeneral()
            } catch {
                self.overviewCheckFailures.insert(.automatic)
                self.autoLaunchStatus.stringValue = "Cannot read login settings: \(error.localizedDescription)"
                self.append(self.autoLaunchStatus.stringValue + "\n")
                self.activityNeeded()
            }
        }
    }

    @objc private func saveAutoLaunch() {
        guard autoLaunchLoaded else {
            autoLaunchStatus.stringValue = "Login settings haven't loaded. Reopen Console Mode to try again."
            return
        }
        let enabled = autoLaunchToggle.state == .on
        guard !enabled || (selected != nil && report?.state == "valid layout" && report?.issues.isEmpty == true) else {
            autoLaunchStatus.stringValue = "Choose Settings → Game library before enabling automatic console mode."
            return
        }
        guard let delay = Int(autoLaunchDelay.stringValue), (5...300).contains(delay) else {
            autoLaunchStatus.stringValue = "Enter a whole number between 5 and 300 seconds."
            return
        }
        let alert = NSAlert()
        alert.messageText = enabled ? "Enable automatic console mode on this Mac?" : "Turn off automatic console mode?"
        alert.informativeText = enabled
            ? "Starting at your next macOS login, wait \(delay) seconds. If no keyboard or mouse is connected, wait for a controller and open your default TV menu.\n\nNo passwords or automatic macOS login are configured. Keep Couch Cube at:\n\(Bundle.main.bundleURL.path)\n\nIf you move or replace the app or game library, save this setting again. macOS may manage this under Login Items."
            : "Stops this app's waiting login helper and removes its login entry. Steam and your game library are unchanged."
        alert.addButton(withTitle: enabled ? "Enable" : "Turn off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var arguments = ["login", "--confirm", "--delay", String(delay)]
        if enabled, let drive = selected { arguments += ["--root", drive.root] }
        if !enabled { arguments.append("--disable") }
        execute(arguments) { code, _ in
            if code == 0 { self.loadAutoLaunch() }
            else {
                self.autoLaunchStatus.stringValue = "Couldn't save console mode. Open Details for the error."
                self.activityNeeded()
            }
        }
    }

    /// Only an explicit debug flag lets Activity open by itself; release builds open it solely from View > Activity.
    static let activityAutoOpens = ProcessInfo.processInfo.environment["COUCH_CUBE_DEBUG_ACTIVITY"] == "1"
    private(set) var lastProblemNotice: String?

    /// Called where something failed or an operation started. Problems are shown in the app; the log stays closed.
    private func activityNeeded(_ problem: String? = nil) {
        if SetupController.activityAutoOpens { showActivity(); return }
        guard let problem = problem?.trimmingCharacters(in: .whitespacesAndNewlines), !problem.isEmpty else { return }
        lastProblemNotice = problem
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"), let window = mainWindow ?? self.window,
              window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Something went wrong"
        alert.informativeText = String(problem.prefix(600))
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Activity")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { self.showActivity() }
        }
    }

    @objc private func showActivity() {
        if logWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Activity"
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            log.frame = NSRect(origin: .zero, size: scroll.contentSize)
            log.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            log.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scroll.documentView = log
            status.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView!.addSubview(status)
            panel.contentView!.addSubview(scroll)
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
                status.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
                status.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 12),
                scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
                scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
            ])
            panel.center()
            logWindow = panel
        }
        logWindow!.makeKeyAndOrderFront(nil)
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = SetupActionButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.required, for: .horizontal)
        if title.hasPrefix("Open Steam"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "steam://open/main")!) {
            let image = NSWorkspace.shared.icon(forFile: app.path)
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageLeading
        }
        actions.append(button)
        return button
    }

    private var selected: Drive? {
        let index = volumeMenu.indexOfSelectedItem
        return volumes.indices.contains(index) ? volumes[index] : nil
    }

    private func append(_ text: String) {
        appOperationOutput?(text)
        log.textStorage?.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]))
        log.scrollToEndOfDocument(nil)
    }

    private func busy(_ value: Bool) {
        actions.forEach { $0.isEnabled = !value }
        if !value && selected == nil {
            libraryControls.forEach { $0.isEnabled = false }
        }
        storageNext.isEnabled = !value && selected != nil && report?.issues.isEmpty == true
        if !value {
            renderTVMenus()
            [volumeMenu, storageNext].forEach { $0.needsDisplay = true }
            updateAllButton.isEnabled = appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
            updateAllButton.isHidden = !appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
            updateSetupSummary()
        }
    }

    private func execute(_ arguments: [String], capture: Bool = false,
                         completed: @escaping (Int32, Data) -> Void) {
        precondition(capture || !ProcessInfo.processInfo.arguments.contains("--smoke-test"), "Read-only smoke tests must never run mutations")
        guard task == nil, !cleanupInProgress else {
            status.stringValue = "An operation is already running. Activity shows its progress."
            return
        }
        lastError = ""
        if ["transfer-library", "retire-library", "initialize-drive", "removal-verify", "erase", "prepare-portable",
            "copy-app", "copy-installer", "cleanup-prepare", "cleanup-host", "setup"].contains(arguments.first ?? "") {
            // The library is about to change: stop installer downloads so no partial file is copied or left behind.
            for (id, job) in windowsDownloadJobs where job.running { cancelWindowsDownload(id: id) }
        }
        let readOnly = capture && ["drives", "storage-status", "assess", "apps", "systems", "system-catalog", "login-status", "frontend", "steam-status", "drive-detail", "removal-plan"].contains(arguments.first ?? "")
        if !readOnly { busy(true) }
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        task = process
        switch arguments.first {
        case "drives", "storage-status", "assess": break
        case "setup": status.stringValue = "Getting your library ready. Keep the drive connected."
        case "install-apps": status.stringValue = "Installing your game players. This may take a few minutes."
        case "manage-app": status.stringValue = "Updating apps. Open Activity for live Homebrew output."
        case "erase": status.stringValue = "Preparing your SSD. Keep it connected until this finishes."
        default: if !readOnly { status.stringValue = "Working on it..." }
        }
        do {
            try process.run()
        } catch {
            task = nil
            if !readOnly { busy(false) }
            lastError = friendlyBackendError("Cannot start bundled runtime: \(error.localizedDescription)")
            append(lastError + "\n")
            status.stringValue = lastError
            activityNeeded(lastError)
            completed(1, Data())
            return
        }
        // Drain both pipes off the UI thread, including large Homebrew output.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async {
                        self.lastError += text
                        self.append(text)
                    }
            }
            group.leave()
        }
        DispatchQueue.global().async {
            var collected = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                if capture { collected.append(data) }
                else {
                    let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async { self.append(text) }
                }
            }
            process.waitUntilExit()
            group.wait()
            let result = collected
            DispatchQueue.main.async {
                self.task = nil
                if !readOnly { self.busy(false) }
                if process.terminationStatus != 0 {
                    let friendly = self.friendlyBackendError(self.lastError)
                    if friendly != self.lastError { self.lastError = friendly; self.append(friendly + "\n"); self.status.stringValue = friendly }
                }
                if process.terminationStatus != 0 && !capture { self.activityNeeded(self.lastError.isEmpty ? "The operation didn't finish." : self.lastError) }
                completed(process.terminationStatus, result)
                if self.consoleRefreshPending && self.task == nil && !self.smokeFinishing {
                    self.consoleRefreshPending = false
                    if self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!) == 7 {
                        self.loadSystems()
                    }
                }
                self.runPendingAppsPreload()
                if self.appRefreshPending && self.task == nil && !self.smokeFinishing {
                    self.appRefreshPending = false
                    if [1, 6].contains(self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!)) {
                        self.loadApps()
                    }
                }
                if self.refreshPending && self.task == nil && !self.smokeFinishing {
                    self.refreshPending = false
                    self.refresh()
                }
                if self.driveDetailPending && self.task == nil && !self.smokeFinishing {
                    self.driveDetailPending = false
                    if self.currentPage == 12 { self.loadDriveDetail() }
                }
            }
        }
    }

    @objc private func refresh() {
        if task != nil { refreshPending = true; return }
        let previous = selected?.id
        let previousRoot = selected?.root
        overviewChecks = Set(OverviewCheck.allCases)
        overviewCheckFailures = []
        renderGeneral()
        execute(["storage-status"], capture: true) { code, data in
            self.availableVolumes = []
            self.storageStatus = nil
            if code == 0 {
                do {
                    self.storageStatus = try JSONDecoder().decode(StorageStatus.self, from: data)
                    self.availableVolumes = self.storageStatus!.locations.map(\.drive)
                    self.lastLibraryTransfer = nil
                    self.status.stringValue = self.availableVolumes.isEmpty
                        ? "No writable supported storage found. Unlock/mount your drive and refresh."
                        : "Ready. Nothing has been changed."
                } catch {
                    self.status.stringValue = "Invalid drive information: \(error.localizedDescription)"
                    self.append(self.status.stringValue + "\n")
                    self.overviewCheckFailures.formUnion(OverviewCheck.allCases)
                }
            } else {
                self.overviewCheckFailures.formUnion(OverviewCheck.allCases)
                self.status.stringValue = "Drive discovery failed. Open Activity for details."
                self.activityNeeded(self.status.stringValue)
            }
            self.populateVolumes(previous: previous)
            self.renderStorageLocations()
            let preserve = previous == self.selected?.id && previousRoot == self.selected?.root
            let cachedReport = self.report
            let cachedSystems = self.consoleSystems.map { $0.id }
            self.updateSelection(preservingStatus: preserve)
            if preserve && ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                precondition(self.report?.state == cachedReport?.state,
                             "Refreshing unchanged storage must retain its last assessment")
                precondition(self.consoleSystems.map { $0.id } == cachedSystems,
                             "Refreshing unchanged storage must retain console visibility")
            }
            if self.selected == nil {
                self.overviewChecks = []
                self.renderGeneral()
                self.loadAutoLaunch()
                self.finishSmokeTest(success: false)
            }
        }
    }

    /// Game library and Library storage share one drive overview; each drive opens a read-only detail page.
    private func smokeTestDriveOverview() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        func overviewRows(_ stack: NSStackView) -> [StorageOverviewRow] { stack.arrangedSubviews.compactMap { $0 as? StorageOverviewRow } }
        let saved = (storageStatus, driveDetailCache, driveDetailID, backendRead, driveDetailParent, driveDetailErrors, currentPage, driveDetailLoading)
        let savedGames = (driveGamesRead, driveGamesCache, driveGamesShowAll,
                          UserDefaults.standard.object(forKey: romsBySystemKey), UserDefaults.standard.object(forKey: pcByLauncherKey))
        let scans = SmokeScanLog()
        driveGamesRead = { id, done in scans.calls.append((id, done)) }
        UserDefaults.standard.removeObject(forKey: romsBySystemKey)
        UserDefaults.standard.removeObject(forKey: pcByLauncherKey)
        defer {
            (driveGamesRead, driveGamesCache, driveGamesShowAll) = (savedGames.0, savedGames.1, savedGames.2)
            UserDefaults.standard.set(savedGames.3, forKey: romsBySystemKey)
            UserDefaults.standard.set(savedGames.4, forKey: pcByLauncherKey)
            driveGamesScanning = nil
            driveGamesGeneration += 1
            (storageStatus, driveDetailCache, driveDetailID, backendRead, driveDetailParent, driveDetailErrors) = (saved.0, saved.1, saved.2, saved.3, saved.4, saved.5)
            driveDetailLoading = saved.7
            driveDetailGeneration += 1
            renderStorageLocations()
            selectPage(saved.6)
        }
        let local = Drive(id: "local", uuid: "u0", mode: "local", name: "Macintosh HD", root: "/Users/test/Games/Couch Cube",
                          filesystem: "apfs", free: 100, mount: "/")
        func ssd(_ number: Int) -> Drive {
            Drive(id: "ssd\(number)", uuid: "u\(number)", mode: "portable", name: "Game SSD \(number) (portable console)",
                  root: "/Volumes/G\(number)/Couch Cube", filesystem: "apfs", free: 100, mount: "/Volumes/G\(number)")
        }
        for entry in [StorageOverviewEntry(id: "local", mode: "local", title: "This Mac", state: "ready", active: true,
                                           path: "/Users/test/Games/Couch Cube"),
                      StorageOverviewEntry(id: nil, mode: "portable", title: "External SSD", state: "connect", active: false, path: nil)] {
            let probe = storageOverviewRow(entry)
            probe.frame = NSRect(x: 0, y: 0, width: 600, height: 80)
            probe.layoutSubtreeIfNeeded()
            for field in views(probe).compactMap({ $0 as? NSControl }) where field is NSTextField || field.identifier?.rawValue == entry.path {
                precondition(field.frame.width + 0.5 >= field.intrinsicContentSize.width,
                             "Drive titles, status and paths must not truncate when the row has room: \(field.stringValue)")
            }
        }
        storageStatus = nil
        precondition(storageOverviewEntries().map(\.state) == ["checking", "checking"], "Unchecked drives are never shown as ready or missing")
        storageStatus = StorageStatus(locations: [.init(drive: local, configured: true, issue: nil, environment: "ready")],
                                      active: .init(id: "local", uuid: "u0"), transfer: nil)
        renderStorageOverview()
        for stack in [gameLibraryOverviewRows] {
            let rows = overviewRows(stack)
            precondition(rows.count == 2 && rows[0].driveID == "local" && labels(rows[0]).contains("This Mac") &&
                         labels(rows[0]).contains("Ready · Active"), "This Mac is always listed with its readiness")
            precondition(rows[1].driveID == nil && rows[1].alphaValue < 1 && labels(rows[1]).contains("External SSD") &&
                         labels(rows[1]).contains("Connect one"), "Without a drive, External SSD is a disabled Connect one row")
        }
        precondition(gameLibraryOverviewRows.isDescendant(of: tabs.tabViewItems[6].view!), "Game library shows the drive overview")
        storageStatus = StorageStatus(locations: [
            .init(drive: local, configured: true, issue: nil, environment: "ready"),
            .init(drive: ssd(1), configured: false, issue: nil, environment: "absent"),
            .init(drive: ssd(2), configured: false, issue: "A Couch Cube folder is already there.", environment: "occupied"),
            .init(drive: ssd(3), configured: true, issue: nil, environment: "ready")
        ], active: .init(id: "local", uuid: "u0"), transfer: nil)
        renderStorageOverview()
        let rows = overviewRows(gameLibraryOverviewRows)
        precondition(rows.map(\.driveID) == ["local", "ssd1", "ssd2", "ssd3"], "Every connected drive gets its own row")
        precondition(labels(rows[1]).contains("Game SSD 1") && labels(rows[1]).contains("Not set up") &&
                     labels(rows[2]).contains { $0.hasPrefix("Not set up ·") } && labels(rows[3]).contains("Ready"))
        precondition(rows.allSatisfy { row in views(row).contains { $0.identifier?.rawValue == "storage-overview-badge" } },
                     "Readiness is drawn on each drive icon")
        precondition(!views(rows[1]).contains { ($0 as? NSButton)?.action == #selector(openBIOSFolder(_:)) },
                     "A path that doesn't exist yet isn't offered in Finder")
        let unchanged = rows[0]
        renderStorageOverview()
        precondition(overviewRows(gameLibraryOverviewRows)[0] === unchanged, "Silent refreshes keep rows in place")
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        selectPage(6)
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        let finder = views(rows[0]).compactMap { $0 as? NSButton }.first { $0.action == #selector(openBIOSFolder(_:)) }!
        precondition(finder.identifier?.rawValue == local.root, "The library path opens in Finder like BIOS folders")
        let finderPoint = rows[0].superview!.convert(NSPoint(x: finder.bounds.midX, y: finder.bounds.midY), from: finder)
        precondition(rows[0].hitTest(finderPoint).map { $0 === finder || $0.isDescendant(of: finder) } == true,
                     "The Finder link keeps its own click instead of opening the drive")
        let title = views(rows[0]).compactMap { $0 as? NSTextField }.first { $0.stringValue == "This Mac" }!
        precondition(rows[0].hitTest(rows[0].superview!.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), from: title)) === rows[0],
                     "The rest of the row opens the drive")
        var reads: [([String], (Int32, Data) -> Void)] = []
        backendRead = { arguments, done in reads.append((arguments, done)) }
        func detailJSON(_ drive: Drive, steam: String, retro: String) -> Data {
            Data("""
            {"drive":{"id":"\(drive.id)","uuid":"\(drive.uuid)","mode":"\(drive.mode)","name":"\(drive.name)","root":"\(drive.root)","filesystem":"apfs","free":100,"mount":"\(drive.mount)"},
             "environment":"ready","issue":null,"active":false,
             "capacity":{"total":1000000000000,"used":600000000000,"free":400000000000,"couch":5000000000},
             "steam":\(steam),"retro":\(retro),"errors":[]}
            """.utf8)
        }
        rows[1].onOpen?("ssd1")
        precondition(currentPage == 12 && driveDetailID == "ssd1" && driveDetailParent == 6 &&
                     sidebar.selectedRow == sidebarPages.firstIndex(of: 6) && screenTitle.stringValue == "Game SSD 1",
                     "A drive row opens its detail page under Game library")
        precondition(reads.last?.0 == ["drive-detail", "--drive", "ssd1"])
        precondition(views(driveDetailRows).contains { ($0 as? NSButton)?.identifier?.rawValue == "drive-initialize" && ($0 as? NSButton)?.isEnabled == true },
                     "A drive without a library offers Initialize")
        precondition(!views(driveDetailRows).contains { $0.identifier?.rawValue == "drive-remove" })
        precondition(labels(driveDetailRows).contains("Reading this drive..."))
        showDriveDetail("ssd3")
        precondition(reads.count == 2 && reads[1].0 == ["drive-detail", "--drive", "ssd3"])
        reads[0].1(0, detailJSON(ssd(1), steam: "[]", retro: "[]"))
        precondition(driveDetailCache["ssd1"] == nil && driveDetailID == "ssd3" && labels(driveDetailRows).contains("Reading this drive..."),
                     "A stale result for another drive never replaces the current page")
        reads[1].1(0, detailJSON(ssd(3), steam: """
            [{"path":"/Volumes/G3/SteamLibrary","games":[{"appid":"620","name":"Portal 2","state":"Installed","installed":true,"bytes":1000}]}]
            """, retro: """
            [{"id":"snes","name":"Super Nintendo","games":3,"path":"/Volumes/G3/Couch Cube/ROMs/snes"}]
            """))
        let detailLabels = labels(driveDetailRows)
        for heading in ["Couch Cube library", "Storage", "Drive size", "Used (all files)", "Couch Cube files", "Free space", "Steam", "Retro games", "Super Nintendo"] {
            precondition(detailLabels.contains(heading), "Drive detail shows \(heading)")
        }
        precondition(!detailLabels.contains("Reading this drive..."))
        let buttons = views(driveDetailRows).compactMap { $0 as? NSButton }
        precondition(buttons.contains { $0.identifier?.rawValue == "620" && $0.title == "Play" } &&
                     buttons.contains { $0.identifier?.rawValue == "620" && $0.title == "Manage" && $0.action == #selector(manageSteamGame(_:)) },
                     "Steam games on the drive keep Play and get a Steam manage link")
        precondition(buttons.contains { $0.identifier?.rawValue == "drive-remove" } && buttons.contains { $0.title == "Use this library..." },
                     "A ready library that isn't active can be activated or removed")
        precondition(views(driveDetailRows).contains { $0.identifier?.rawValue == "drive-retro-snes" } &&
                     !views(driveDetailRows).contains { $0.identifier?.rawValue.hasPrefix("drive-retro-") == true && $0.identifier?.rawValue != "drive-retro-snes" })
        smokeTestDriveGames(scans, labels: labels, views: views)
        reads.removeAll()
        showDriveDetail("ssd1")
        precondition(reads.count == 1)
        reads[0].1(0, detailJSON(ssd(1), steam: "[]", retro: "[]"))
        precondition(!labels(driveDetailRows).contains("Steam") && !labels(driveDetailRows).contains("Retro games"),
                     "Systems and stores without games on this drive are left out")
        storageStatus = StorageStatus(locations: [.init(drive: local, configured: true, issue: nil, environment: "ready")],
                                      active: .init(id: "local", uuid: "u0"), transfer: nil)
        reads.removeAll()
        renderStorageLocations()
        precondition(labels(driveDetailRows).contains { $0.hasPrefix("Disconnected.") } && reads.isEmpty,
                     "Unplugging the drive shows it as disconnected without reading it")
        precondition(driveGamesCache["ssd1"] == nil && driveGamesScanning == nil,
                     "Unplugging drops the drive's game sizes so a reconnect measures it again")
    }

    /// Game storage breakdown: one scan per drive, stale scans dropped, grouping is presentation-only.
    private func smokeTestDriveGames(_ log: SmokeScanLog, labels: (NSView) -> [String], views: (NSView) -> [NSView]) {
        precondition(log.calls.map(\.0) == ["ssd1", "ssd3"], "Opening a drive measures its games once, separately from the detail read")
        func item(_ id: String, _ kind: String, _ source: String, _ sourceName: String, _ name: String, _ system: String?,
                  _ bytes: Int64?, measured: Bool = true, unreadable: Int = 0) -> String {
            let systemNames = ["psx": "PlayStation", "snes": "Super Nintendo"]
            let systemJSON = system.map { "\"\($0)\"" } ?? "null"
            let systemName = system.flatMap { systemNames[$0] }.map { "\"\($0)\"" } ?? "null"
            return """
            {"id":"\(id)","kind":"\(kind)","source":"\(source)","source_name":"\(sourceName)","name":"\(name)","system":\(systemJSON),
             "system_name":\(systemName),"bytes":\(bytes.map(String.init) ?? "null"),"measured":\(measured),"unreadable":\(unreadable),"path":"/Volumes/G3/x"}
            """
        }
        var items = [item("rom:psx:A", "rom", "rom", "ROMs", "Alpha", "psx", 300_000_000),
                     item("rom:psx:B", "rom", "rom", "ROMs", "Beta", "psx", 100_000_000, unreadable: 2),
                     item("rom:snes:C", "rom", "rom", "ROMs", "Gamma", "snes", 50_000_000),
                     item("steam:1", "pc", "steam", "Steam", "Portal 2", nil, 500_000_000),
                     item("steam:2", "pc", "steam", "Steam", "Reported", nil, 40_000_000, measured: false),
                     item("gog:1", "pc", "gog", "GOG", "Witcher", nil, 9_000_000),
                     item("bottle:1", "pc", "bottle", "Windows bottles", "Steam (CrossOver bottle)", nil, 1_000),
                     item("epic:1", "pc", "epic", "Epic Games", "Unknown size", nil, nil)]
        items += (0..<6).map { item("rom:snes:t\($0)", "rom", "rom", "ROMs", "Tiny \($0)", "snes", 1_000) }
        // Leftover files: a few kilobytes are hidden from the list, a real amount stays listed.
        items += [item("rom:snes:*other", "rom", "rom", "ROMs", "Other Super Nintendo files", "snes", 900_000),
                  item("rom:psx:*other", "rom", "rom", "ROMs", "Other PlayStation files", "psx", 2_000_000)]
        func games(_ drive: String, _ items: [String]) -> Data {
            Data("""
            {"drive":{"id":"\(drive)","uuid":"u3"},"items":[\(items.joined(separator: ","))],
             "coverage":[{"source":"rom","name":"ROMs","status":"scanned","games":9,"note":null},
                         {"source":"other","name":"Other launchers","status":"unsupported","games":0,"note":"Amazon isn't detected."}],
             "total":999007000,"unknown":1,"partial":1,"shared":4096,"errors":[]}
            """.utf8)
        }
        log.calls[0].1(0, games("ssd1", []))
        precondition(driveGamesCache["ssd1"] == nil && labels(driveDetailRows).contains("Measuring games on this drive..."),
                     "A scan for a drive that is no longer shown never lands")
        log.calls[1].1(0, games("ssd3", items))
        let decoded = driveGamesCache["ssd3"]!.games
        let individual = GameStorageSlice.slices(decoded, romsBySystem: false, pcByLauncher: false)
        precondition(!individual.contains { $0.title == "Other Super Nintendo files" } && individual.contains { $0.title == "Other PlayStation files" },
                     "Only negligible Other files rows are hidden")
        precondition(individual.count == 15 && individual.first?.title == "Portal 2" && individual.last?.bytes == nil,
                     "Individual view lists every game largest first, unknown sizes last")
        precondition(individual.map(\.tenths).reduce(0, +) == 1000, "Rounded shares add up to exactly 100%")
        precondition(individual.first { $0.title == "Tiny 0" }?.percent == "<0.1%", "Tiny games keep a visible share instead of 0%")
        precondition(individual.first { $0.title == "Unknown size" }?.percent == "—")
        let bySystem = GameStorageSlice.slices(decoded, romsBySystem: true, pcByLauncher: false)
        let psx = bySystem.first { $0.id == "system:psx" }!
        precondition(psx.title == "PlayStation ROMs" && psx.bytes == 402_000_000 && psx.games == 3 && psx.partial, "ROMs sum by system")
        precondition(bySystem.contains { $0.title == "Portal 2" } && !bySystem.contains { $0.title == "Alpha" },
                     "Grouping ROMs keeps PC games individual")
        let byLauncher = GameStorageSlice.slices(decoded, romsBySystem: false, pcByLauncher: true)
        let steam = byLauncher.first { $0.id == "launcher:steam" }!
        precondition(steam.title == "Steam games" && steam.bytes == 540_000_000 && steam.games == 2 &&
                     byLauncher.contains { $0.title == "GOG games" } && byLauncher.contains { $0.title == "Windows bottles (launcher unknown)" } &&
                     byLauncher.contains { $0.title == "Alpha" }, "PC games sum by launcher; bottles stay unattributed; ROMs stay individual")
        let epic = byLauncher.first { $0.id == "launcher:epic" }!
        precondition(epic.bytes == nil && epic.unknown == 1, "A launcher with only unknown sizes isn't shown as zero")
        let both = GameStorageSlice.slices(decoded, romsBySystem: true, pcByLauncher: true)
        // Split into typed values: one combined expression is too slow for older Swift type checkers (CI).
        let bothIDs: Set<String> = Set(both.map { $0.id })
        let expectedIDs: Set<String> = ["system:psx", "system:snes", "launcher:steam", "launcher:gog", "launcher:bottle", "launcher:epic"]
        let bothBytes: Int64 = both.compactMap { $0.bytes }.reduce(0, +)
        let individualBytes: Int64 = individual.compactMap { $0.bytes }.reduce(0, +)
        let bothTenths: Int = both.map { $0.tenths }.reduce(0, +)
        precondition(bothIDs == expectedIDs, "Both groupings: \(bothIDs)")
        precondition(bothBytes == individualBytes + 900_000, "Both groupings together keep the same total")
        precondition(bothTenths == 1000, "Both groupings' shares add up to 100%")
        func rows() -> [NSView] { views(driveDetailRows).filter { $0.identifier?.rawValue == "drive-games-row" } }
        func checkbox(_ id: String) -> NSButton { views(driveDetailRows).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }! }
        let page = labels(driveDetailRows)
        precondition(page.contains("Game storage") && page.contains { $0.hasPrefix("Share of ") && $0.contains("games found on this drive") },
                     "The breakdown names its denominator")
        precondition(views(driveDetailRows).last { $0.identifier?.rawValue == "drive-games-bar" } != nil && rows().count == 12 &&
                     checkbox("drive-games-more").title == "Show all 15", "The list starts with the biggest games and can show every one")
        precondition(page.contains { $0.contains("unknown size") && $0.contains("Amazon isn't detected.") }, "Coverage and unknowns are stated")
        let bar = views(driveDetailRows).compactMap { $0 as? GameStorageBar }.first!
        precondition(bar.segments.count == GameStorageBar.colored + 1 && bar.segments.last!.title.hasPrefix("Other ("),
                     "Only the largest games get colors; the rest share one gray segment")
        views(driveDetailRows).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drive-games-more" }!.performClick(nil)
        precondition(rows().count == 15 && checkbox("drive-games-more").title == "Show fewer", "Tiny games stay reachable")
        precondition(!labels(driveDetailRows).contains("Other Super Nintendo files") && labels(driveDetailRows).contains("Other PlayStation files"),
                     "Kilobytes of leftover files aren't listed")
        checkbox("drive-group-roms").performClick(nil)
        precondition(UserDefaults.standard.bool(forKey: romsBySystemKey) && labels(driveDetailRows).contains("PlayStation ROMs") &&
                     labels(driveDetailRows).contains("Portal 2") && log.calls.count == 2, "Grouping by system re-renders without rescanning")
        checkbox("drive-group-pc").performClick(nil)
        precondition(checkbox("drive-group-roms").state == .on && labels(driveDetailRows).contains("Steam games") &&
                     labels(driveDetailRows).contains("PlayStation ROMs") && rows().count == 6 && log.calls.count == 2,
                     "Launcher grouping keeps the ROM grouping")
        checkbox("drive-group-roms").performClick(nil)
        checkbox("drive-group-pc").performClick(nil)
        precondition(labels(driveDetailRows).contains("Alpha") && labels(driveDetailRows).contains("Portal 2"))
        showDriveDetail("ssd3")
        precondition(log.calls.count == 2, "Reopening a recently measured drive reuses its results")
        views(driveDetailRows).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drive-games-rescan" }!.performClick(nil)
        precondition(log.calls.count == 3 && log.calls[2].0 == "ssd3" && labels(driveDetailRows).contains { $0.hasPrefix("Rescanning...") },
                     "Rescan measures again while showing the previous results")
        log.calls[2].1(1, Data())
        precondition(driveGamesCache["ssd3"] != nil && labels(driveDetailRows).contains("Alpha"),
                     "A failed rescan keeps the last good results")
        driveGamesShowAll = false
    }

    private func finishSmokeTest(success: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test"), !smokeFinishing else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let requestedPage = arguments.firstIndex(of: "--page").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        if requestedPage != nil || arguments.contains("--smoke-flow") {
            if ["0", "5", "6"].contains(requestedPage ?? "") || arguments.contains("--smoke-flow"), !smokeSteamLoaded {
                smokeSteamLoaded = true
                execute(["steam-status"], capture: true) { code, data in
                    do {
                        self.steamReport = try JSONDecoder().decode(SteamLibraryReport.self, from: data)
                        self.renderSteamLibraries()
                        self.renderGeneral()
                        precondition(!self.steamGuideRows.arrangedSubviews.isEmpty)
                        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
                        self.smokeTestDriveOverview()
                        self.smokeTestAppOperations()
                        self.smokeTestWindowsDownloads()
                        self.smokeTestStoreAccounts()
                        self.smokeTestActivityStaysClosed()
                        precondition(!self.librarySummary.stringValue.isEmpty)
                        let page = self.tabs.tabViewItems[6].view!
                        precondition(views(page).contains { $0.identifier?.rawValue == "library-storage-menu" })
                        let menu = views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "library-storage-menu" }!
                        precondition(menu.itemArray.dropFirst().map(\.title) == ["Check Library"], "Storage is changed on this page, not elsewhere")
                        // Sidebar task model: guided setup shows one page's tasks at a time; off shows all.
                        let tasks = [SidebarTask(page: 1, color: .systemYellow, title: "Get an app", setup: true),
                                     SidebarTask(page: 8, color: .systemYellow, title: "Allow Bluetooth", setup: true),
                                     SidebarTask(page: 7, color: .systemRed, title: "BIOS", setup: false),
                                     SidebarTask(page: 7, color: .systemYellow, title: "BIOS 2", setup: false),
                                     SidebarTask(page: 1, color: .systemYellow, title: "Update", setup: false)]
                        let guided = sidebarBadges(tasks, guided: true)
                        precondition(guided.keys.sorted() == [1] && guided[1]?.count == 2 && guided[1]?.color == .systemYellow,
                                     "Guided setup marks only the current step, including its maintenance tasks")
                        let free = sidebarBadges(tasks, guided: false)
                        precondition(free.keys.sorted() == [1, 7, 8] && free[8]?.count == 1 && free[1]?.count == 2 &&
                                     free[7]?.count == 2 && free[7]?.color == .systemRed, "Guided setup off shows every task")
                        let later = sidebarBadges(tasks.filter { $0.page != 1 }, guided: true)
                        precondition(later.keys.sorted() == [7] && later[7]?.color == .systemRed,
                                     "Maintenance-only pages are guided in order too")
                        let last = sidebarBadges(tasks.filter { $0.page == 8 }, guided: true)
                        precondition(last.keys.sorted() == [8], "The next step appears once earlier ones are done")
                        precondition(sidebarBadges([SidebarTask(page: 99, color: .systemRed, title: "x", setup: false)], guided: true)[99]?.count == 1,
                                     "Pages outside the guided order still surface when nothing earlier is open")
                        precondition(free[7]?.groups.map(\.color) == [.systemRed, .systemYellow] &&
                                     free[7]?.groups.map(\.count) == [1, 1] && free[1]?.groups.count == 1,
                                     "Mixed severities get separate red and yellow counts")
                        let mixed = sidebarBadges([SidebarTask(page: 6, color: .systemYellow, title: "a", setup: true),
                                                   SidebarTask(page: 6, color: .systemRed, title: "b", setup: false),
                                                   SidebarTask(page: 6, color: .systemYellow, title: "c", setup: false),
                                                   SidebarTask(page: 7, color: .systemRed, title: "d", setup: false)], guided: true)
                        precondition(mixed.keys.sorted() == [6] && mixed[6]?.groups.map(\.count) == [1, 2] &&
                                     mixed[6]?.groups[1].titles == ["a", "c"], "Guided step keeps both severity counts; later pages stay hidden")
                        // Guided step stays put while checks arrive in any order.
                        let storageTask = SidebarTask(page: 6, color: .systemYellow, title: "Prepare", setup: true)
                        let appTask = SidebarTask(page: 1, color: .systemRed, title: "Get a TV menu", setup: true)
                        let biosTask = SidebarTask(page: 7, color: .systemRed, title: "BIOS", setup: false)
                        var step = guidedSidebarStep([biosTask], pinned: nil, settled: false, previous: [:])
                        precondition(step.badges.isEmpty && step.pinned == nil, "Nothing is guided before checks settle")
                        step = guidedSidebarStep([biosTask, appTask], pinned: step.pinned, settled: false, previous: step.badges)
                        precondition(step.badges.isEmpty, "Partial results never pick a step")
                        step = guidedSidebarStep([biosTask, appTask], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == 1 && step.badges.keys.sorted() == [1], "Settled checks pick the first step")
                        step = guidedSidebarStep([], pinned: step.pinned, settled: false, previous: step.badges)
                        precondition(step.pinned == 1 && step.badges[1]?.titles == ["Get a TV menu"],
                                     "A refresh that hasn't loaded yet must not hide or move the step")
                        step = guidedSidebarStep([storageTask, biosTask, appTask], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == 1 && step.badges.keys.sorted() == [1],
                                     "A newly found earlier task must not displace the current step")
                        step = guidedSidebarStep([biosTask, storageTask], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == 6 && step.badges.keys.sorted() == [6], "Once done, the next step in order appears")
                        step = guidedSidebarStep([], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == nil && step.badges.isEmpty, "No stale markers once everything is done")
                        for (page, badge) in self.sidebarTaskCounts {
                            precondition(self.sidebarAttention[page] == badge.color && badge.count == badge.titles.count)
                        }
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load Steam smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
            if requestedPage == "1" || requestedPage == "2" || arguments.contains("--smoke-flow"), !smokeAppsLoaded {
                smokeAppsLoaded = true
                execute(["apps"], capture: true) { code, data in
                    do {
                        self.appStates = try JSONDecoder().decode([ManagedApp].self, from: data)
                        self.renderApps()
                        self.renderTVMenus()
                        self.appsStatus.stringValue = "Installed versions. Updates are checked only when requested."
                        precondition(Set(self.appStates.map { $0.id }) == Set(["steam", "steamac", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "porting-kit", "crossover", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]))
                        for app in self.appStates {
                            let iconURL = Bundle.main.resourceURL!.appendingPathComponent("AppIcons/\(app.id).png")
                            precondition(NSImage(contentsOf: iconURL) != nil, "Missing app icon: \(app.id)")
                        }
                        let porting = self.appStates.firstIndex { $0.id == "porting-kit" }!
                        precondition(self.appStates[porting + 1].id == "crossover")
                        let steamIndex = self.appStates.firstIndex { $0.id == "steam" }!
                        precondition(self.appStates[steamIndex + 1].id == "steamac", "FX Steam Launcher sits right below Steam")
                        let battle = self.appStates.firstIndex { $0.id == "battle-net" }!
                        precondition(self.appStates[battle + 1].id == "curseforge")
                        func buttons(in view: NSView) -> [NSButton] {
                            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
                        }
                        for installed in [false, true] {
                            for update in [false, true] {
                                let preview = ManagedApp(id: "pcsx2", name: "PCSX2", installed: installed,
                                    path: "/Applications/PCSX2.app", version: "1.0", managed: true,
                                    update: update ? "2.0" : nil, manual: false, brew: true, url: nil)
                                let rows = NSStackView()
                                self.addAppRow(preview, index: 0, to: rows)
                                let controls = buttons(in: rows)
                                func appLabels(_ view: NSView) -> [String] {
                                    (view as? NSTextField).map { [$0.stringValue] } ??
                                        view.subviews.flatMap { appLabels($0) }
                                }
                                precondition(appLabels(rows).contains(installed ?
                                    (update ? "Installed · Update available" : "Installed") : "Not installed"))
                                precondition(controls.count == 1)
                                if installed {
                                    precondition(controls.allSatisfy { $0.toolTip != nil })
                                    precondition(controls.last is NSPopUpButton)
                                    let menu = (controls.last as! NSPopUpButton).menu!
                                    precondition(menu.items.last?.title == "Remove…")
                                    precondition(menu.items.last?.action == #selector(self.removeAppFromMenu(_:)))
                                    precondition(menu.items.last?.tag == 0)
                                    precondition(controls.last?.toolTip == "More options for PCSX2")
                                    let updateItem = menu.items.first { $0.title == "Update" }
                                    precondition(updateItem?.action == #selector(self.updateAppFromMenu(_:)))
                                    precondition(updateItem?.isEnabled == update)
                                } else {
                                    precondition(controls.first?.bezelStyle == .rounded && controls.first?.title == "Get")
                                }
                                if !installed {
                                    precondition(controls.last?.action == #selector(self.appAction(_:)))
                                }
                                self.clearRows(rows)
                            }
                        }
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load app smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
            if requestedPage == "7" || arguments.contains("--smoke-flow"), !smokeSystemsLoaded {
                smokeSystemsLoaded = true
                execute(["system-catalog"], capture: true) { code, data in
                    do {
                        self.consoleSystems = try JSONDecoder().decode([ConsoleSystem].self, from: data)
                        self.renderSystems()
                        precondition(self.consoleSystems.contains { $0.id == "switch" })
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load console smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
        }
        if arguments.contains("--smoke-flow") && !smokeOverviewRefreshed {
            smokeOverviewRefreshed = true
            selectPage(0)
            refreshGeneral()
            precondition(task != nil && !overviewChecks.isEmpty,
                         "Home must refresh asynchronously with pending indicators")
            return
        }
        smokeFinishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let stack = self.detail.subviews.compactMap { $0 as? NSStackView }.first!
                let discoveryOK = success && !self.volumes.isEmpty && self.window.isVisible
                    && self.selected != nil
                    && self.tabs.numberOfTabViewItems == 14 && self.logWindow == nil
                precondition(self.sidebarPages.count == self.sidebarTitles.count &&
                             self.sidebarPages.count == self.sidebarSymbols.count)
                precondition(!self.sidebarPages.contains(3) && !self.sidebarPages.contains(4),
                             "Storage belongs under Settings, not in the sidebar")
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--minimum-size") { self.window.setContentSize(self.window.minSize) }
                precondition(self.window.frame.width >= 960, "Settings pages must preserve the minimum window width")
                if args.contains("--minimum-size") {
                    precondition(self.window.frame.width <= 980,
                                 "Header artwork must not expand the compact window: \(self.window.frame)")
                }
                if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
                   let page = Int(args[index + 1]), (0..<self.tabs.numberOfTabViewItems).contains(page) {
                    if page == 4 {
                        self.preferredMode = args.contains("--portable") ? "portable" : "local"
                        self.populateVolumes(previous: nil)
                        if self.selected == nil { self.selectionChanged() }
                    }
                    self.selectPage(page)
                }
                if args.contains("--smoke-flow") {
                    precondition(isBluetoothController(deviceClass: 0x0508, name: "HID device"))
                    precondition(isBluetoothController(deviceClass: 0, name: "DualSense Wireless Controller"))
                    precondition(!isBluetoothController(deviceClass: 0x0580, name: "Mouse"))
                    precondition(!isBluetoothController(deviceClass: 0x0540, name: "Keyboard"))
                    precondition(controllerBatteryText(level: -1, state: .discharging) == nil)
                    precondition(controllerBatteryText(level: 0, state: .unknown) == nil)
                    precondition(controllerBatteryText(level: 0.75, state: .discharging) == "75% battery")
                    for count in 0...4 {
                        let status = self.controllerOverviewStatus(count: count)
                        precondition(status.arrangedSubviews.count == 2)
                        let housing = status.arrangedSubviews[0] as! ControllerLEDHousing
                        let leds = housing.contentView!.subviews[0] as! NSStackView
                        precondition(leds.arrangedSubviews.count == 4)
                        for index in 0..<4 {
                            let dot = leds.arrangedSubviews[index] as! NSImageView
                            precondition(dot.contentTintColor == (index < count ? NSColor.systemGreen : NSColor.systemGray))
                        }
                        precondition((status.arrangedSubviews[1] as! NSTextField).stringValue ==
                                     (count == 0 ? "Not Connected" : "\(count) Connected"))
                    }
                    let assessment = self.report
                    self.busy(true)
                    precondition(stack.arrangedSubviews.count == 1 && stack.arrangedSubviews.first === self.tabs,
                                 "The main content must not include a status footer")
                    precondition(self.sidebar.isEnabled, "Navigation must stay available during operations")
                    self.busy(false)
                    for page in 0..<self.tabs.numberOfTabViewItems {
                        self.selectPage(page)
                        precondition(!self.navigationBar.isHidden && self.window === self.mainWindow)
                        precondition(self.sidebar.selectedRow == self.sidebarPages.firstIndex(of:
                            (page == 2 || page == 3 || page == 4) ? 6 : page == 5 ? 6 : page == 9 ? self.inspectorParent : page == 12 ? self.driveDetailParent : page))
                        if page == 13 { self.assertSmokeDeals() }
                        self.assertSmokePageScrolls()
                        if page == 7 {
                            for toggle in self.systemSwitches {
                                precondition(toggle.controlSize == .small)
                                let controls = toggle.superview!
                                let frame = toggle.convert(toggle.bounds, to: controls)
                                precondition(abs(frame.maxX - controls.bounds.maxX) < 4, "Console switches must align to the right edge")
                            }
                            if !self.esdeRunning {
                                self.smokeTestRapidConsoleToggles()
                                self.smokeTestConsoleBulkToggles()
                            }
                            if !self.esdeRunning { self.smokeTestSilentRefresh() }
                        }
                        if page == 6 {
                            let saved = self.storageStatus
                            let sample = self.availableVolumes[0]
                            self.storageStatus = StorageStatus(locations: [
                                StorageStatus.Location(drive: sample, configured: true, issue: nil)
                            ], active: StorageStatus.Active(id: sample.id, uuid: sample.uuid), transfer: nil)
                            self.renderStorageLocations()
                            precondition(self.gameLibraryOverviewRows.arrangedSubviews.contains { ($0 as? StorageOverviewRow)?.driveID == sample.id },
                                         "Game library lists drives with the shared overview rows")
                            precondition(self.setupFolderStatus.stringValue.hasPrefix("Active · "))
                            let library = self.tabs.tabViewItems[6].view!
                            precondition([self.setupFolderStatus, self.gameLibraryOverviewRows, self.transferLibraryButton, self.retireLibraryButton]
                                            .allSatisfy { $0.isDescendant(of: library) },
                                         "Game library includes the former Library storage controls")
                            func texts(_ view: NSView) -> [String] {
                                ((view as? NSButton).map { [$0.title] } ?? (view as? NSTextField).map { [$0.stringValue] } ?? []) +
                                    view.subviews.flatMap { texts($0) }
                            }
                            let pageTexts: [String] = texts(library)
                            let refreshCount: Int = pageTexts.filter { $0 == "Refresh connected drives" }.count
                            let headingCount: Int = pageTexts.filter { $0 == "Where your games live" }.count
                            let storageDiagnostics: String = "refresh=\(refreshCount) heading=\(headingCount) texts=\(pageTexts.filter { !$0.isEmpty })"
                            precondition(refreshCount == 1, "The merged page has one drive refresh button: " + storageDiagnostics)
                            precondition(headingCount == 1, "The merged page has one storage heading: " + storageDiagnostics)
                            precondition(pageTexts.contains("Add or prepare an SSD..."), "The merged page offers SSD setup: " + storageDiagnostics)
                            precondition(pageTexts.contains("Move library..."), "The merged page offers moving the library: " + storageDiagnostics)
                            precondition(texts(self.tabs.tabViewItems[2].view!).isEmpty)
                            self.storageStatus = StorageStatus(locations: [], active: nil, transfer: nil)
                            self.renderStorageLocations()
                            precondition(self.setupFolderStatus.stringValue.contains("first library"))
                            precondition(!self.transferLibraryButton.isEnabled)
                            self.storageStatus = saved
                            self.renderStorageLocations()
                        }
                        if page == 8 {
                            func controllerLabels(_ view: NSView) -> [String] {
                                (view as? NSTextField).map { [$0.stringValue] } ??
                                    view.subviews.flatMap { controllerLabels($0) }
                            }
                            let labels = controllerLabels(self.activeControllerRows)
                            precondition(labels.contains("Purple PS5") && !labels.contains("DualSense Wireless Controller"))
                            precondition(labels.contains("Not connected"))
                            precondition(self.controllerColors.contains { $0.0 == "Chroma Indigo" })
                            precondition(self.controllerColors.contains { $0.0 == "Micro Green" })
                            precondition(Set(self.controllerColors.map { $0.0 }).count == self.controllerColors.count)
                            let picker = ControllerPalette.menu(selecting: "Gray Camouflage")
                            precondition(ControllerPalette.selectedName(in: picker) == "Gray Camouflage" &&
                                         picker.itemArray.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title) ==
                                            ControllerPalette.sections.map { $0.0 })
                            precondition(ControllerPalette.sections.flatMap { $0.1 }.allSatisfy {
                                !$0.brands.isEmpty && Set($0.brands).isSubset(of: ControllerPalette.brands) })
                            let micro = ControllerEntry(id: "micro", name: "8BitDo Micro", connected: true, transport: "Bluetooth")
                            precondition(ControllerPalette.canonicalName("Green", for: micro) == "Micro Green" &&
                                         ControllerPalette.canonicalName("Indigo", for: micro) == "Chroma Indigo" &&
                                         ControllerPalette.canonicalName("Carbon Black", for: micro) == "Black")
                            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                                NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
                                    for (_, color) in self.controllerColors {
                                        precondition(ControllerPalette.swatch(color).tiffRepresentation != nil)
                                    }
                                }
                            }
                            let savedBefore = self.controllerCustomizations
                            let previewArt = ControllerArtwork.menu(selecting: nil)
                            precondition(Set(ControllerArtwork.sections.flatMap(\.1)) == Set(ControllerArtwork.kinds.dropFirst()) &&
                                         ControllerArtwork.sections.flatMap(\.1).count == ControllerArtwork.kinds.count - 1,
                                         "Every artwork choice appears in exactly one company section")
                            let headers = previewArt.itemArray.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title)
                            precondition(headers == ControllerArtwork.sections.map(\.0) &&
                                         previewArt.itemArray.filter { !$0.isEnabled }.allSatisfy { $0.representedObject == nil },
                                         "Company headers are disabled, unselectable labels")
                            precondition(ControllerArtwork.selectedKind(in: previewArt) == "Automatic" &&
                                         ControllerArtwork.selectedKind(in: ControllerArtwork.menu(selecting: "Nintendo")) == "Nintendo" &&
                                         ControllerArtwork.selectedKind(in: ControllerArtwork.menu(selecting: "8BitDo Micro")) == "8BitDo Micro" &&
                                         ControllerArtwork.selectedKind(in: ControllerArtwork.menu(selecting: "Removed kind")) == "Automatic",
                                         "Saved artwork choices reselect the item, never a same-named header")
                            let previewColor = ControllerPalette.menu(selecting: "", automatic: "Black")
                            let preview = ControllerCustomizationPreview(controllerName: "Pro Controller", colorPopup: previewColor,
                                                                         artworkPopup: previewArt)
                            precondition(preview.kind == "Switch Pro Controller" && preview.colorName == "Black" &&
                                         preview.savedColor == "" && previewColor.titleOfSelectedItem == "Automatic (Black)" &&
                                         preview.imageView.image != nil && preview.iconFrame.imageView === preview.imageView &&
                                         preview.imageView.contentTintColor == ControllerPalette.color(named: "Black"),
                                         "Automatic is the default choice and shows the model color it resolves to")
                            func pick(_ popup: NSPopUpButton, _ value: String) {
                                popup.select(popup.itemArray.first { $0.representedObject as? String == value })
                                _ = popup.sendAction(popup.action, to: popup.target)
                            }
                            pick(previewArt, "Joy-Con (R)")
                            precondition(preview.colorName == "Neon Red" && previewColor.titleOfSelectedItem == "Automatic (Neon Red)",
                                         "Automatic follows the chosen artwork's model color")
                            pick(previewColor, "Shock Blue")
                            precondition(preview.kind == "Joy-Con (R)" && preview.savedColor == "Shock Blue" &&
                                         preview.imageView.contentTintColor == ControllerPalette.color(named: "Shock Blue"),
                                         "A manual color always wins over Automatic")
                            pick(previewArt, "PS5 · DualSense")
                            precondition(preview.colorName == "Shock Blue", "Changing artwork keeps a manual color")
                            pick(previewColor, "")
                            precondition(preview.colorName == "White" && preview.savedColor == "", "PS5 Automatic is DualSense white")
                            precondition(preview.iconFrame.subviews == [preview.imageView] && preview.iconFrame.layer?.backgroundColor == nil &&
                                         preview.iconFrame.frame.size == NSSize(width: 88, height: 60),
                                         "Controller art has no background: just the icon in a fixed-size frame")
                            precondition(self.controllerCustomizations.keys == savedBefore.keys &&
                                         self.controllerCustomizations.values.map(\.color) == savedBefore.values.map(\.color),
                                         "Previewing must not change saved customizations")
                            precondition(ControllerPalette.defaultName(for: ControllerEntry(
                                id: "micro", name: "8BitDo Micro", connected: true, transport: "Bluetooth")) == "Micro Green")
                            precondition(ControllerPalette.defaultName(for: self.controllerEntries[0]) == "White")
                            for (kind, expected) in [("PS5 · DualSense", "White"), ("PS4 · DualShock 4", "Black"), ("Xbox", "Black"),
                                                     ("Switch Pro Controller", "Black"), ("Joy-Con (L)", "Neon Blue"),
                                                     ("Joy-Con (R)", "Neon Red"), ("Nintendo", "Classic Gray"), ("Steam Controller", "Black")] {
                                precondition(ControllerPalette.defaultName(forKind: kind) == expected, "Marketing color for \(kind)")
                            }
                            let ps5 = ControllerEntry(id: "hid:ps5", name: "DualSense Wireless Controller", connected: true, transport: "USB")
                            precondition(ControllerPalette.migratedName("Chroma Indigo", for: ps5) == "" &&
                                         ControllerPalette.migratedName("Galactic Purple", for: ps5) == "Galactic Purple" &&
                                         ControllerPalette.canonicalName("Chroma Indigo", for: ps5) == "Chroma Indigo" &&
                                         ControllerPalette.canonicalName("Removed color", for: ps5) == "" &&
                                         ControllerPalette.resolvedName("", for: ps5) == "White" &&
                                         ControllerPalette.resolvedName("Galactic Purple", for: ps5) == "Galactic Purple" &&
                                         ControllerPalette.resolvedName("", for: ps5, artwork: "Xbox") == "Black",
                                         "Old inferred defaults become Automatic; explicit picks stay")
                            do {
                                let backup = (self.controllerEntries, self.controllerCustomizations, self.controllerAliases,
                                              self.homeSessionControllers, self.controllerConnectedFirst)
                                let legacy = ControllerPreferences(entries: [ps5], customizations: [
                                    ps5.id: ControllerCustomization(name: "", color: "Chroma Indigo", artwork: nil)],
                                    connectedFirst: false)
                                self.restoreControllerPreferences(try! JSONDecoder().decode(ControllerPreferences.self,
                                                                                            from: JSONEncoder().encode(legacy)))
                                precondition(self.controllerCustomizations[ps5.id]?.color == "", "Legacy inferred color migrates to Automatic")
                                self.controllerCustomizations[ps5.id]?.color = "Chroma Indigo"
                                let current = self.currentControllerPreferences()
                                precondition(current.colorVersion == 2)
                                self.restoreControllerPreferences(try! JSONDecoder().decode(ControllerPreferences.self,
                                                                                            from: JSONEncoder().encode(current)))
                                precondition(self.controllerCustomizations[ps5.id]?.color == "Chroma Indigo",
                                             "A color picked after Automatic exists is never migrated away")
                                (self.controllerEntries, self.controllerCustomizations, self.controllerAliases,
                                 self.homeSessionControllers, self.controllerConnectedFirst) = backup
                            }
                            func identified(_ view: NSView, _ id: String) -> [NSView] {
                                (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap { identified($0, id) }
                            }
                            precondition(labels.filter { $0 == "Connected" }.count == 2 && labels.contains("25%") && labels.contains("60%"))
                            let controllerLines = self.controllerRowIDs.compactMap { self.controllerRowViews[$0] as? NSStackView }
                            precondition(controllerLines.count == self.controllerEntries.count)
                            for (entry, line) in zip(self.controllerEntries, controllerLines) {
                                precondition(line.arrangedSubviews.first is ControllerDragHandle, "Controllers need a drag handle")
                                precondition(line.arrangedSubviews.last is NSPopUpButton, "Controllers need a … menu")
                                let plate = line.arrangedSubviews[1] as! ControllerIconFrame
                                let icon = plate.imageView
                                precondition(plate.frame.size == NSSize(width: 52, height: 38) || plate.frame.isEmpty)
                                let saved = self.controllerCustomizations[entry.id]
                                let expected = entry.connected ? ControllerPalette.color(named: ControllerPalette.resolvedName(
                                    saved?.color, for: entry, artwork: saved?.artwork)) : NSColor.systemGray
                                precondition(icon.contentTintColor == expected, "Connected controllers use their color, others stay gray")
                            }
                            precondition(identified(self.activeControllerRows, "controller-transport").count == 2,
                                         "Only connected controllers show a transport icon")
                            precondition(identified(self.activeControllerRows, "controller-battery").compactMap {
                                ($0 as? NSImageView)?.contentTintColor } == [controllerBatteryWarningColor, .systemGreen])
                            for (level, state, expected) in [
                                (Float(0.10), GCDeviceBattery.State.discharging, ControllerBatterySeverity?.some(.critical)),
                                (0.05, .discharging, .critical), (0.11, .discharging, .low), (0.30, .discharging, .low),
                                (0.31, .discharging, .normal), (0.05, .charging, .charging), (0.05, .full, .normal),
                                (0.50, .unknown, nil), (Float.nan, .discharging, nil), (1.2, .discharging, nil)
                            ] {
                                precondition(controllerBatterySeverity(level: level, state: state) == expected, "Battery \(level) \(state.rawValue)")
                            }
                            precondition(controllerBatteryColor(.critical) == .systemRed && controllerBatteryColor(.low) == controllerBatteryWarningColor &&
                                         controllerBatteryColor(.normal) == .secondaryLabelColor && controllerBatteryColor(.charging) == .systemGreen)
                            func menuTitles(_ popup: NSPopUpButton) -> [String: Bool] {
                                Dictionary(popup.itemArray.dropFirst().filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) },
                                           uniquingKeysWith: { first, _ in first })
                            }
                            let firstMenu = menuTitles(controllerLines[0].arrangedSubviews.last as! NSPopUpButton)
                            precondition(firstMenu["Customize…"] == true && firstMenu["Move Up"] == false && firstMenu["Move Down"] == true &&
                                         firstMenu["Remove from List"] == false && firstMenu["Forget Device…"] == nil)
                            let pairedMenu = menuTitles(self.controllerMenuButton(ControllerEntry(id: "bt:aabbccddeeff",
                                name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"), list: 1, position: 0, count: 1))
                            precondition(pairedMenu["Disconnect"] != nil && pairedMenu["Connect"] == nil && pairedMenu["Forget Device…"] != nil)
                            let offlineMenu = menuTitles(self.controllerMenuButton(ControllerEntry(id: "bt:aabbccddeeff",
                                name: "DualSense Wireless Controller", connected: false, transport: "Bluetooth"), list: 1, position: 0, count: 1))
                            precondition(offlineMenu["Connect"] == true && offlineMenu["Disconnect"] == nil)
                            precondition(self.discoveredControllerRows.arrangedSubviews.contains {
                                $0.identifier?.rawValue == "discovered-controller" } && !self.discoveredControllerRows.isHidden)
                            precondition(identified(self.discoveredControllerRows, "98-b6-e9-00-00-01").compactMap { $0 as? NSButton }.first?.title == "Connect")
                            precondition(self.controllerBanner.isHidden)
                            self.controllerSmokeBanner = true
                            self.updateControllerBanner()
                            precondition(!self.controllerBanner.isHidden && self.controllerAccessButton.title == "Allow Bluetooth Access")
                            precondition(self.sidebarTasks.filter { $0.page == 8 }.count == 1, "Bluetooth access must be a Controllers task")
                            self.controllerSmokeBanner = false
                            self.updateControllerBanner()
                            precondition(self.controllerBanner.isHidden && !self.sidebarTasks.contains { $0.page == 8 })
                            precondition(reorderedControllerIDs(["a", "b", "c", "d"], moving: "d", to: 0, among: ["b", "d"]) == ["a", "d", "b", "c"])
                            precondition(reorderedControllerIDs(["a", "b", "c", "d"], moving: "a", to: 2, among: ["a", "b", "c"]) == ["b", "c", "a", "d"])
                            let originalOrder = self.controllerEntries.map { $0.id }
                            self.controllerConnectedFirst = true
                            self.renderControllerList()
                            precondition(self.controllerRowIDs == ["preview:1", "preview:3", "preview:2"])
                            precondition(controllerLabels(self.activeControllerRows).contains("Not connected"))
                            self.moveController("preview:3", toVisibleIndex: 0, list: 1)
                            precondition(self.controllerEntries.map(\.id) == ["preview:3", "preview:1", "preview:2"])
                            self.moveController("preview:2", toVisibleIndex: 0, list: 1)
                            precondition(self.controllerRowIDs == ["preview:3", "preview:1", "preview:2"],
                                         "Connected first keeps disconnected controllers in their own group")
                            self.controllerConnectedFirst = false
                            self.renderControllerList()
                            precondition(self.controllerRowIDs == ["preview:3", "preview:1", "preview:2"])
                            self.moveController("preview:2", toVisibleIndex: 0, list: 1)
                            precondition(self.controllerEntries.map(\.id) == ["preview:2", "preview:3", "preview:1"])
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            let lastRow = self.controllerRowViews["preview:1"]!
                            let firstRow = self.controllerRowViews["preview:2"]!
                            let topPoint = firstRow.convert(NSPoint(x: 4, y: firstRow.bounds.midY), to: nil)
                            let abovePoint = NSPoint(x: topPoint.x, y: firstRow.convert(firstRow.bounds, to: nil).maxY - 2)
                            _ = lastRow
                            self.dragController("preview:1", in: self.activeControllerRows, to: abovePoint)
                            precondition(self.controllerDropIndicator.superview === self.activeControllerRows)
                            self.dropController("preview:1", in: self.activeControllerRows, at: abovePoint)
                            precondition(self.controllerDropIndicator.superview == nil)
                            precondition(self.controllerEntries.map(\.id) == ["preview:1", "preview:2", "preview:3"],
                                         "Dragging to the top must move the controller first: \(self.controllerEntries.map(\.id))")
                            let byID = Dictionary(uniqueKeysWithValues: self.controllerEntries.map { ($0.id, $0) })
                            self.controllerEntries = originalOrder.compactMap { byID[$0] }
                            self.renderControllerList()
                            let entry = self.controllerEntries[0]
                            let savedName = self.controllerCustomizations[entry.id]
                            self.controllerCustomizations[entry.id]?.name = String(repeating: "Very Long Controller Name ", count: 6)
                            self.renderControllerList()
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            func layoutSnapshot() -> [NSRect] {
                                var frames: [NSRect] = [self.window.frame, self.activeControllerRows.frame]
                                frames += self.activeControllerRows.arrangedSubviews.map { $0.frame }
                                if let row = self.controllerRowViews[entry.id] {
                                    frames.append(row.frame)
                                    frames += row.subviews.map { $0.frame }
                                }
                                return frames
                            }
                            let idleLayout = layoutSnapshot()
                            precondition(self.controllerRowViews[entry.id]!.frame.maxX <= self.activeControllerRows.bounds.maxX + 0.5,
                                         "Long names must truncate inside the row")
                            self.receiveControllerInput(entry, message: "Button 1 pressed")
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            precondition(self.controllerInputLabels[entry.id]?.stringValue == "Connected",
                                         "Input must not add inline status text")
                            precondition(self.controllerImages[entry.id]?.allSatisfy { $0.accessibilityValue() as? String == "Receiving input" &&
                                (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || $0.layer?.animation(forKey: "controllerActivity") != nil) } == true,
                                         "Input only flashes the controller icon")
                            precondition(!self.controllerRowViews[entry.id]!.subviews.contains { $0.identifier?.rawValue == "controller-activity" },
                                         "No extra activity indicator")
                            precondition(layoutSnapshot() == idleLayout, "Input activity must never change row, card or window layout")
                            self.controllerLastInput[entry.id] = ("Button 1 pressed", Date(timeIntervalSinceNow: -2))
                            self.updateHomeControllerActivity(entry.id)
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            precondition(self.controllerImages[entry.id]?.allSatisfy { $0.layer?.animation(forKey: "controllerActivity") == nil &&
                                $0.accessibilityValue() == nil } == true)
                            precondition(layoutSnapshot() == idleLayout, "Returning to idle must not shift layout")
                            self.controllerCustomizations[entry.id] = savedName
                            self.renderControllerList()
                            self.receiveControllerInput(entry, message: "Button 1 pressed")
                            precondition(self.controllerTestStatus.stringValue == "Purple PS5 · Button 1 pressed")
                            precondition(self.controllerInputLabels[entry.id]?.stringValue == "Connected")
                            precondition(self.controllerInputLabels[self.controllerEntries[2].id]?.stringValue == "Connected")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 1, minimum: 0, maximum: 1) == "Button 1 pressed")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 0, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 7, usage: 1, value: 1, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 128, minimum: 0, maximum: 255) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 255, minimum: 0, maximum: 255) == "Stick / trigger X · 100%")
                            precondition(controllerAddress("AA-BB-CC-DD-EE-FF") == "aabbccddeeff")
                            precondition(controllerAddress("not an address") == nil)
                            let bluetoothID = "bt:aabbccddeeff"
                            let usbSerial = "hid:1356:3302:USB:serial:aa-bb-cc-dd-ee-ff"
                            precondition(verifiedBluetoothAlias(for: usbSerial, knownBluetoothIDs: [bluetoothID]) == bluetoothID)
                            precondition(verifiedBluetoothAlias(for: "hid:1356:3302:USB:serial:AA:BB:CC:DD:EE:FF", knownBluetoothIDs: [bluetoothID]) == bluetoothID)
                            for unverified in ["hid:1356:3302:USB:location:12345", "hid:1356:3302:USB:serial:XYZ123",
                                               "hid:1356:3302:USB:serial:aabbccddee00", "hid:1356:3302:Bluetooth:serial:aa-bb-cc-dd-ee-ff",
                                               "hid:1356:3302:USB:serial:aabbccddeeff-2"] {
                                precondition(verifiedBluetoothAlias(for: unverified, knownBluetoothIDs: [bluetoothID]) == nil, unverified)
                            }
                            let savedPreviewEntries = self.controllerEntries
                            let savedCustomizations = self.controllerCustomizations
                            self.controllerEntries = [ControllerEntry(id: bluetoothID, name: "DualSense Wireless Controller", connected: false, transport: "Bluetooth")]
                            self.controllerCustomizations[bluetoothID] = ControllerCustomization(name: "Mine", color: "Galactic Purple")
                            let pairedDualSense = PairedController(name: "DualSense Wireless Controller", address: "aa-bb-cc-dd-ee-ff", connected: false)
                            self.mergeControllerList([ControllerEntry(id: usbSerial, name: "DualSense Wireless Controller", connected: true, transport: "Wired")],
                                                     paired: [pairedDualSense])
                            precondition(self.controllerEntries.count == 1 && self.controllerEntries[0].id == bluetoothID &&
                                         self.controllerEntries[0].connected && self.controllerEntries[0].transport == "Wired" &&
                                         self.controllerAliases[usbSerial] == bluetoothID, "A verified USB serial must reuse the Bluetooth profile")
                            let twins = (1...2).map { ControllerEntry(id: "hid:1356:3302:USB:location:\($0)", name: "DualSense Wireless Controller",
                                                                      connected: true, transport: "Wired") }
                            self.mergeControllerList(twins, paired: [pairedDualSense])
                            precondition(self.controllerEntries.count == 3 && self.controllerAliases.count == 1,
                                         "Same-model controllers must never merge by name or model")
                            let candidates = self.controllerLinkCandidates(for: twins[0])
                            precondition(candidates.isEmpty, "A Bluetooth profile that already has a verified USB link is not offered again")
                            self.controllerAliases = [:]
                            precondition(self.controllerLinkCandidates(for: twins[0]).map(\.id) == [bluetoothID])
                            self.linkController(twins[0].id, to: bluetoothID)
                            precondition(!self.controllerEntries.contains { $0.id == twins[0].id } &&
                                         self.controllerEntries.first { $0.id == bluetoothID }?.transport == "Wired")
                            let linkedPreferences = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(self.currentControllerPreferences()))
                            self.restoreControllerPreferences(linkedPreferences)
                            precondition(self.controllerAliases == [twins[0].id: bluetoothID] &&
                                         self.controllerCustomizations[bluetoothID]?.name == "Mine" &&
                                         !self.controllerEntries.contains { $0.id == twins[0].id }, "Aliases must survive a restart")
                            let separate = NSMenuItem()
                            separate.representedObject = bluetoothID
                            self.unlinkController(separate)
                            precondition(self.controllerAliases.isEmpty)
                            // Profiles follow the controller's own Bluetooth address across Forget, re-pair and USB.
                            precondition(controllerAddressFromSonyReport([0x09, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x08], reportID: 0x09) == "aabbccddeeff")
                            precondition(controllerAddressFromSonyReport([0x12, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa], reportID: 0x12) == "aabbccddeeff")
                            for bad in [[0x12, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa], [0x09, 0, 0, 0, 0, 0, 0], [0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0x09, 1, 2]] as [[UInt8]] {
                                precondition(controllerAddressFromSonyReport(bad, reportID: 0x09) == nil, "Unproven Sony address reports are rejected")
                            }
                            precondition(sonyAddressReportID(vendor: 0x054C, product: 0x0CE6) == 0x09 &&
                                         sonyAddressReportID(vendor: 0x054C, product: 0x09CC) == 0x12 &&
                                         sonyAddressReportID(vendor: 0x045E, product: 0x0B13) == nil &&
                                         sonyAddressReportID(vendor: 0x057E, product: 0x2009) == nil)
                            self.controllerAliases = [:]
                            self.controllerEntries = [ControllerEntry(id: bluetoothID, name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"),
                                                      ControllerEntry(id: "bt:112233445566", name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth")]
                            self.controllerCustomizations[bluetoothID] = ControllerCustomization(name: "Mine", color: "Galactic Purple", artwork: "PlayStation")
                            self.controllerCustomizations["bt:112233445566"] = ControllerCustomization(name: "Guest", color: "Cosmic Red")
                            self.forgetControllerPairing(bluetoothID, deleteProfile: false)
                            precondition(!self.controllerEntries.contains { $0.id == bluetoothID } &&
                                         self.controllerCustomizations[bluetoothID]?.name == "Mine", "Forget keeps the profile")
                            let afterForget = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(self.currentControllerPreferences()))
                            self.restoreControllerPreferences(afterForget)
                            self.mergeControllerList([], paired: [PairedController(name: "DualSense Wireless Controller", address: "AA:BB:CC:DD:EE:FF", connected: true),
                                                                  PairedController(name: "DualSense Wireless Controller", address: "11-22-33-44-55-66", connected: true)])
                            let repaired = self.controllerEntries.first { $0.id == bluetoothID }
                            precondition(repaired != nil && self.controllerDisplayName(repaired!) == "Mine" &&
                                         self.controllerCustomizations[bluetoothID]?.color == "Galactic Purple" &&
                                         self.controllerCustomizations[bluetoothID]?.artwork == "PlayStation" &&
                                         self.controllerCustomizations["bt:112233445566"]?.name == "Guest",
                                         "Re-pairing restores name, color and icon without touching an identical controller")
                            // USB first: the profile set over USB moves onto the Bluetooth address the pad reports, in place.
                            let usbFirst = "hid:1356:3302:USB:location:77"
                            self.controllerEntries = [ControllerEntry(id: "bt:112233445566", name: "DualSense Wireless Controller", connected: false, transport: "Bluetooth"),
                                                      ControllerEntry(id: usbFirst, name: "DualSense Wireless Controller", connected: true, transport: "Wired")]
                            self.controllerCustomizations = [usbFirst: ControllerCustomization(name: "Desk", color: "Starlight Blue"),
                                                             "bt:112233445566": ControllerCustomization(name: "Guest", color: "Cosmic Red")]
                            self.mergeControllerList([ControllerEntry(id: usbFirst, name: "DualSense Wireless Controller", connected: true, transport: "Wired",
                                                                      hardwareAddress: "a0b1c2d3e4f5")], paired: [])
                            precondition(self.controllerEntries.map(\.id) == ["bt:112233445566", "bt:a0b1c2d3e4f5"] &&
                                         self.controllerAliases[usbFirst] == "bt:a0b1c2d3e4f5" &&
                                         self.controllerCustomizations["bt:a0b1c2d3e4f5"]?.name == "Desk" &&
                                         self.controllerCustomizations[usbFirst] == nil, "A USB-reported address adopts the profile in place")
                            self.mergeControllerList([], paired: [PairedController(name: "DualSense Wireless Controller", address: "a0-b1-c2-d3-e4-f5", connected: true)])
                            precondition(self.controllerEntries.count == 2 && self.controllerEntries[1].transport == "Bluetooth" &&
                                         self.controllerDisplayName(self.controllerEntries[1]) == "Desk", "Bluetooth later uses the same profile")
                            // Joy-Cons never adopt anything, even with an address-looking serial.
                            let joyUSB = ControllerEntry(id: "hid:1406:8198:USB:serial:aa-bb-cc-dd-ee-ff", name: "Joy-Con (L)", connected: true,
                                                         transport: "Wired", model: "Joy-Con (L)", hardwareAddress: "aabbccddeeff")
                            precondition(controllerProfileAlias(for: joyUSB, knownBluetoothIDs: [bluetoothID]) == nil)
                            self.controllerAliases = [:]
                            self.forgetControllerPairing("bt:112233445566", deleteProfile: true)
                            precondition(self.controllerCustomizations["bt:112233445566"] == nil, "Forget and Delete Profile removes it")
                            self.controllerAliases = [:]
                            self.controllerEntries = savedPreviewEntries
                            self.controllerCustomizations = savedCustomizations
                            self.controllerCustomizations[bluetoothID] = nil
                            self.controllerConnectedFirst = true
                            let preferences = self.currentControllerPreferences()
                            let restored = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(preferences))
                            precondition(restored.customizations[entry.id]?.name == "Purple PS5")
                            precondition(restored.customizations[entry.id]?.color == "Galactic Purple")
                            precondition(restored.connectedFirst && restored.entries.map(\.id) == originalOrder)
                            self.controllerConnectedFirst = false
                            self.updateControllerSortMenu()
                            self.mergeControllerList([], paired: [])
                            precondition(self.controllerEntries.allSatisfy { !$0.connected })
                            precondition(self.controllerEntries.map { $0.id } == originalOrder)
                            self.refreshControllers()
                        }
                    }
                    for (index, page) in self.sidebarPages.enumerated() where page < 0 {
                        precondition(!self.tableView(self.sidebar, shouldSelectRow: index), "Sidebar section headings must not navigate")
                    }
                    precondition(self.systemSwitches.count == 17 && self.activeControllerRows.arrangedSubviews.count == 5)
                    precondition(self.consoleRows.arrangedSubviews.count == 4,
                                 "The all-consoles row, then one card each for Nintendo, PlayStation and SEGA")
                    precondition(self.consoleBulkToggles.map(\.scope) == ["all consoles", "Nintendo consoles", "PlayStation consoles",
                                 "SEGA consoles", "Nintendo home consoles", "Nintendo handhelds"],
                                 "Show/hide-all switches for the page, each section and each subsection")
                    let readyBIOS = BIOSStatus(state: "present", summary: "", files: [])
                    for (enabled, installed, bios, expected) in [
                        (false, false, readyBIOS, NSColor.systemGray),
                        (true, false, readyBIOS, NSColor.systemRed),
                        (true, true, readyBIOS, NSColor.systemGreen),
                        (true, true, BIOSStatus(state: "optional", summary: "", files: []), NSColor.systemYellow),
                        (true, true, BIOSStatus(state: "missing", summary: "", files: []), NSColor.systemRed),
                        (true, true, BIOSStatus(state: "manual", summary: "", files: []), NSColor.systemGray)
                    ] {
                        let preview = ConsoleSystem(id: "psx", name: "PlayStation", enabled: enabled,
                            package: "retroarch-metal", requirement: "", bios: bios, emulator_installed: installed)
                        precondition(self.consoleReadiness(preview).color == expected)
                        let emulatorColor = self.emulatorStatus(preview).color
                        if !enabled {
                            precondition(emulatorColor == .systemGray)
                        } else if !installed {
                            precondition(emulatorColor == .systemRed)
                        } else {
                            precondition(emulatorColor == .systemGreen || emulatorColor == .systemYellow,
                                         "Missing BIOS must not mark an installed emulator red")
                        }
                        precondition(self.emulatorName(preview) == "RetroArch")
                    }
                    precondition(self.controllerInputManager == nil, "Input monitoring must stop when leaving Controllers")
                    let previousTestText = self.controllerTestStatus.stringValue
                    self.receiveControllerInput(self.controllerEntries[0], message: "Ignored outside Controllers")
                    precondition(self.controllerTestStatus.stringValue == previousTestText)
                    self.selectPage(0)
                    let homeEntry = self.controllerEntries[0]
                    precondition(self.homeControllerRowIDs == Array(self.orderedControllers(self.controllerEntries).map(\.id).prefix(4)) &&
                                 self.homeControllerInputLabels.count == 3,
                                 "Home must show the same controllers, in the same order, as Controllers")
                    do {
                        // Regression: input on a connected controller must not move a disconnected neighbour's name.
                        let saved = self.controllerEntries
                        self.controllerEntries = Array(saved.prefix(2))
                        self.controllerEntries[0].connected = true
                        self.controllerEntries[1].connected = false
                        self.renderHomeControllers()
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        let ids = self.homeControllerRowIDs
                        precondition(ids.count == 2, "Jitter scenario needs two Home rows")
                        let rows = ids.map { self.homeControllerRowViews[$0]! }
                        func fields(_ view: NSView) -> [NSTextField] {
                            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
                        }
                        func nameFrames() -> [NSRect] {
                            rows.flatMap(fields).map { $0.convert($0.bounds, to: nil) }
                        }
                        let frames = nameFrames()
                        let renders = self.homeControllerRenderCount
                        for i in 0..<6 {
                            self.receiveControllerInput(self.controllerEntries[0], message: "Button \(i) pressed")
                            self.renderHomeControllers()
                            self.renderGeneral()
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            precondition(ids.map { self.homeControllerRowViews[$0]! }.elementsEqual(rows, by: ===),
                                         "Controller input must not rebuild Home controller rows")
                            precondition(nameFrames() == frames, "Controller input must not move Home controller names")
                        }
                        self.updateHomeControllerActivity(ids[0])
                        precondition(nameFrames() == frames, "Ending input activity must not move Home controller names")
                        precondition(self.homeControllerRenderCount == renders,
                                     "Controller input and unchanged refreshes must not rebuild Home controllers")
                        self.controllerEntries = saved
                        self.renderHomeControllers()
                    }
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    func homeLayout() -> [NSRect] {
                        [self.window.frame, self.homeControllerStatus.frame] + self.homeControllerStatus.arrangedSubviews.map(\.frame) +
                            (self.homeControllerRowViews[homeEntry.id]?.subviews.map(\.frame) ?? [])
                    }
                    let homeIdle = homeLayout()
                    self.receiveControllerInput(homeEntry, message: "Button 1 pressed")
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.homeControllerInputLabels[homeEntry.id]?.stringValue == "Connected")
                    precondition(self.homeControllerImages[homeEntry.id]?.contains { $0.accessibilityValue() as? String == "Receiving input" } == true,
                                 "Home flashes the same controller icon")
                    precondition(homeLayout() == homeIdle, "Home input must not change the tile layout")
                    precondition(self.homeControllerInputLabels[self.controllerEntries[2].id]?.stringValue == "Connected",
                                 "Only the controller sending input should light up")
                    precondition(self.controllerTestStatus.stringValue == previousTestText,
                                 "Home input must not display detailed button information")
                    self.controllerLastInput[homeEntry.id] = ("Button 1 pressed", Date(timeIntervalSinceNow: -2))
                    self.updateHomeControllerActivity(homeEntry.id)
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.homeControllerImages[homeEntry.id]?.allSatisfy { $0.layer?.animation(forKey: "controllerActivity") == nil } == true &&
                                 homeLayout() == homeIdle, "Home activity must clear after input stops without moving layout")
                    self.mergeControllerList([], paired: [])
                    precondition(self.homeControllerInputLabels.count == 3 &&
                                 self.homeControllerInputLabels.values.allSatisfy { $0.stringValue == "Not connected" },
                                 "Listed controllers must remain gray after disconnecting")
                    func assertHomeStatusesFit(_ message: String) {
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        for label in self.homeControllerInputLabels.values {
                            precondition(label.frame.width + 0.5 >= max(label.intrinsicContentSize.width, self.controllerStatusWidth(label.font!)), message + ": \(label.stringValue) is truncated")
                        }
                    }
                    assertHomeStatusesFit("Not connected must fit in the Home tile")
                    let longName = homeEntry.id
                    let savedCustomization = self.controllerCustomizations[longName]
                    self.controllerCustomizations[longName] = ControllerCustomization(
                        name: "Living Room Wireless Controller With A Very Long Custom Name", color: "Shock Blue")
                    for _ in 0..<3 {
                        self.renderHomeControllers()
                        assertHomeStatusesFit("A long name must truncate before the status")
                        self.mergeControllerList([], paired: [])
                        for id in self.homeControllerRowIDs { self.updateHomeControllerActivity(id) }
                        assertHomeStatusesFit("Repeated refreshes must keep the status readable")
                    }
                    let nameLabel = (self.homeControllerRowViews[longName]?.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.first as? NSTextField)
                    precondition(nameLabel.map { $0.convert($0.bounds, to: self.homeControllerStatus).maxX <= self.homeControllerStatus.bounds.width + 0.5 } ?? true, "Long names stay inside the tile")
                    self.controllerCustomizations[longName] = savedCustomization
                    self.renderHomeControllers()
                    let disconnected = self.controllerEntries
                    for _ in 0..<3 {
                        self.controllerEntries = disconnected.map { var entry = $0; entry.connected = true; entry.transport = "Bluetooth"; return entry }
                        self.renderHomeControllers()
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        self.controllerEntries = disconnected
                        for id in self.homeControllerRowIDs { self.updateHomeControllerActivity(id) }
                        assertHomeStatusesFit("Connected → Not connected in place must not keep the old narrow width")
                    }
                    self.renderHomeControllers()
                    precondition(!self.homeControllerStatus.arrangedSubviews.contains {
                        ($0 as? NSTextField)?.stringValue == "Connect via USB or Bluetooth"
                    }, "Remembered disconnected controllers must not show the empty-state hint")
                    let savedEntries = self.controllerEntries
                    self.controllerEntries = []
                    self.renderHomeControllers()
                    precondition(self.homeControllerStatus.arrangedSubviews.contains {
                        ($0 as? NSTextField)?.stringValue == "Connect via USB or Bluetooth"
                    })
                    self.controllerEntries = savedEntries
                    self.renderHomeControllers()
                    let newer = (1...4).map {
                        ControllerEntry(id: "new:\($0)", name: "Xbox \($0)", connected: true, transport: "Bluetooth")
                    }
                    self.mergeControllerList(newer, paired: [])
                    precondition(Set(self.homeSessionControllers) == Set(newer.map(\.id)),
                                 "New connections must evict disconnected slots, never exceed four")
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.homeControllerInputLabels.count == 4)
                    for image in self.homeControllerImages.values.flatMap({ $0 }) {
                        let frame = image.convert(image.bounds, to: self.homeControllerStatus)
                        precondition(self.homeControllerStatus.bounds.contains(frame),
                                     "All four controller icons must fit in the Home tile")
                    }
                    self.mergeControllerList(newer, paired: [])
                    precondition(self.homeSessionControllers.count == 4)
                    func homeMatchesControllers(_ message: String) {
                        self.renderControllerList()
                        precondition(self.homeControllerRowIDs == Array(self.controllerRowIDs.prefix(4)), message)
                        let more = self.homeControllerStatus.arrangedSubviews.compactMap { $0 as? NSTextField }
                            .first { $0.identifier?.rawValue == "home-controller-more" }
                        precondition(self.controllerRowIDs.count > 4 ? more?.stringValue == "\(self.controllerRowIDs.count - 4) more in Controllers" : more == nil,
                                     "Home must say how many listed controllers do not fit")
                    }
                    homeMatchesControllers("Your Order must decide Home slots")
                    precondition(self.homeControllerRowIDs == savedEntries.map(\.id) + ["new:1"])
                    self.controllerConnectedFirst = true
                    self.renderHomeControllers()
                    homeMatchesControllers("Connected First must apply to Home")
                    precondition(self.homeControllerRowIDs == newer.map(\.id))
                    self.controllerConnectedFirst = false
                    self.renderControllerList()
                    self.moveController("new:3", toVisibleIndex: 0, list: 1)
                    homeMatchesControllers("Reordering in Controllers must update Home immediately")
                    precondition(self.homeControllerRowIDs.first == "new:3")
                    let hiddenID = savedEntries[1].id
                    let removeItem = NSMenuItem()
                    removeItem.representedObject = hiddenID
                    self.removeControllerFromList(removeItem)
                    homeMatchesControllers("Removed controllers must leave Home too")
                    precondition(!self.homeControllerRowIDs.contains(hiddenID))
                    let saved = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(self.currentControllerPreferences()))
                    let homeBeforeRestart = self.homeControllerRowIDs
                    self.restoreControllerPreferences(saved)
                    self.mergeControllerList(newer, paired: [])
                    homeMatchesControllers("Order and removals must survive restart on Home")
                    precondition(self.homeControllerRowIDs == homeBeforeRestart && !self.controllerEntries.contains { $0.id == hiddenID })
                    let remembered = ControllerPreferences(entries: self.controllerEntries,
                        customizations: self.controllerCustomizations,
                        connectedFirst: self.controllerConnectedFirst,
                        recentControllerIDs: self.homeSessionControllers)
                    let decoded = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(remembered))
                    self.restoreControllerPreferences(decoded)
                    self.renderHomeControllers()
                    precondition(Set(self.homeSessionControllers) == Set(newer.map(\.id)))
                    precondition(self.controllerEntries.allSatisfy { !$0.connected },
                                 "Restoring remembered controllers must never imply a live connection")
                    precondition(self.homeControllerInputLabels.count == 4 &&
                                 self.homeControllerInputLabels.values.allSatisfy { $0.stringValue == "Not connected" })
                    let legacy = ControllerPreferences(entries: newer, customizations: [:], connectedFirst: false)
                    let legacyDecoded = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(legacy))
                    self.restoreControllerPreferences(legacyDecoded)
                    precondition(self.homeSessionControllers == newer.map(\.id),
                                 "Existing saved controllers must migrate without a recent-ID field")
                    self.mergeControllerList(newer, paired: [])
                    for kind in ControllerArtwork.kinds.dropFirst() {
                        precondition(ControllerArtwork.image(kind).tiffRepresentation != nil)
                    }
                    let lightBG = NSColor.white, darkBG = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                    func ink(_ name: String, dark: Bool) -> (fill: NSColor, line: NSColor, context: NSColor, rim: NSColor?) {
                        ControllerInk.choose(fill: ControllerPalette.color(named: name), background: dark ? darkBG : lightBG,
                                             dark: dark, highContrast: false)
                    }
                    precondition(abs(ControllerInk.contrast(.black, .white) - 21) < 0.01 && abs(ControllerInk.contrast(.white, .white) - 1) < 0.01)
                    precondition(ink("Black", dark: true).line == ControllerInk.lightInk && ink("Black", dark: false).line == ControllerInk.lightInk,
                                 "Black bodies get light outlines in both appearances")
                    precondition(ink("Black", dark: true).rim == nil && ink("Black", dark: false).context == ControllerInk.darkInk)
                    precondition(ink("White", dark: false).line == ControllerInk.darkInk && ink("White", dark: false).rim == nil,
                                 "White bodies keep a dark outline that separates them from light windows")
                    for name in ["Neon Red", "Neon Yellow", "Micro Green", "Classic Gray", "Neon Blue"] {
                        precondition(ink(name, dark: false).line == ControllerInk.darkInk, "\(name) keeps black lines")
                    }
                    for name in ["Cobalt Blue", "Galactic Purple", "Chroma Indigo", "Cosmic Red", "Mineral Camo", "Gray Camouflage"] {
                        for dark in [false, true] {
                            precondition(ink(name, dark: dark).line == ControllerInk.darkInk, "\(name) is colored, not black: black lines")
                        }
                    }
                    precondition(ControllerInk.isNearBlack(NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1))
                                 && !ControllerInk.isNearBlack(NSColor(srgbRed: 0.18, green: 0.05, blue: 0.40, alpha: 1)),
                                 "Only neutral near-black counts as black")
                    for (name, _) in ControllerPalette.colors {
                        for dark in [false, true] {
                            let choice = ink(name, dark: dark), bg = dark ? darkBG : lightBG
                            precondition(choice.line == (name == "Black" ? ControllerInk.lightInk : ControllerInk.darkInk),
                                         "\(name): only Black gets a light outline")
                            if name == "Black" { precondition(ControllerInk.contrast(choice.line, choice.fill) >= 3, "Black details stay readable") }
                            precondition(ControllerInk.contrast(choice.context, bg) >= 3)
                            precondition(choice.rim != nil || max(ControllerInk.contrast(choice.fill, bg), ControllerInk.contrast(choice.line, bg)) >= 3,
                                         "\(name) silhouette must not vanish")
                        }
                    }
                    for (name, _) in ControllerPalette.colors {
                        let wall = ControllerInk.choose(fill: ControllerPalette.color(named: name), background: darkBG, dark: true,
                                                        highContrast: false, style: .doubleWall)
                        precondition(wall.line == ControllerInk.darkInk, "Double wall keeps black lines on \(name), black included")
                    }
                    func pixels(_ image: NSImage, scale: CGFloat) -> Data {
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(80 * scale), pixelsHigh: Int(52 * scale),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        rep.size = NSSize(width: 80, height: 52)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 52))
                        NSGraphicsContext.restoreGraphicsState()
                        return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) } ?? Data()
                    }
                    let aqua = NSAppearance(named: .aqua)!
                    let outlineArt = ControllerArtwork.filledImage("Xbox", color: ControllerPalette.color(named: "Black"), appearance: aqua,
                                                                   highContrast: false, style: .outline)
                    let wallArt = ControllerArtwork.filledImage("Xbox", color: ControllerPalette.color(named: "Black"), appearance: aqua,
                                                                highContrast: false, style: .doubleWall)
                    precondition(outlineArt !== wallArt && pixels(outlineArt, scale: 2) != pixels(wallArt, scale: 2),
                                 "Both outline styles render and are cached separately")
                    precondition(ControllerArtwork.outlineStyle == .outline, "Outline (A) is the default style")
                    for camoName in ["Gray Camouflage", "Mineral Camo"] {
                        let color = ControllerPalette.color(named: camoName)
                        precondition(ControllerCamo.matching(color)?.name == camoName, "\(camoName) gets its camo pattern")
                        precondition(ControllerCamo.matching(color.withAlphaComponent(0.55)) == nil, "Dimmed camo stays flat")
                        let camo = ControllerArtwork.filledImage("PS5 · DualSense", color: color, appearance: aqua, highContrast: false)
                        let flat = ControllerArtwork.draw("PS5 · DualSense", fill: color, line: ControllerInk.darkInk,
                                                          context: ControllerInk.darkInk, rim: nil, boost: 0)
                        precondition(pixels(camo, scale: 2) == pixels(camo, scale: 2), "Camo is deterministic")
                        precondition(pixels(camo, scale: 2) != pixels(flat, scale: 2), "Camo is patterned at preview scale")
                        precondition(pixels(camo, scale: 0.5) == pixels(flat, scale: 0.5), "Tiny camo falls back to the flat color")
                    }
                    precondition(ControllerCamo.matching(ControllerPalette.color(named: "Classic Gray")) == nil)
                    let translucent = ControllerInk.composite(NSColor.black.withAlphaComponent(0.5), over: .white).usingColorSpace(.sRGB)!
                    precondition(translucent.alphaComponent == 1 && abs(translucent.redComponent - 0.5) < 0.01, "Fills are opaque")
                    let highContrast = ControllerInk.choose(fill: ControllerPalette.color(named: "Black"), background: darkBG, dark: true, highContrast: true)
                    precondition(highContrast.line == .white && highContrast.context == .white)
                    for kind in ControllerArtwork.kinds.dropFirst() {
                        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
                            let red = ControllerArtwork.filledImage(kind, color: ControllerPalette.color(named: "Neon Red"), appearance: appearance, highContrast: false)
                            let black = ControllerArtwork.filledImage(kind, color: ControllerPalette.color(named: "Black"), appearance: appearance, highContrast: false)
                            precondition(!red.isTemplate && red.tiffRepresentation != nil && red.tiffRepresentation != black.tiffRepresentation)
                            precondition(ControllerArtwork.filledImage(kind, color: ControllerPalette.color(named: "Neon Red"), appearance: appearance,
                                                                       highContrast: false) === red, "Rendered art is cached")
                        }
                    }
                    let artView = ControllerArtView(kind: "Xbox")
                    precondition(artView.image?.isTemplate == true)
                    artView.contentTintColor = ControllerPalette.color(named: "White")
                    let filled = artView.image
                    precondition(filled?.isTemplate == false)
                    artView.appearance = NSAppearance(named: .darkAqua)
                    precondition(artView.image !== filled || NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                                 "Appearance changes re-render the fill")
                    artView.kind = "Steam Controller"
                    precondition(artView.image?.accessibilityDescription == "Steam Controller")
                    for (name, expected) in [
                        ("DualShock 4 Wireless Controller", "PS4 · DualShock 4"),
                        ("PS4 Controller", "PS4 · DualShock 4"),
                        ("DualSense Wireless Controller", "PS5 · DualSense"),
                        ("DualSense Edge", "PS5 · DualSense"),
                        ("PS5 Controller", "PS5 · DualSense"),
                        ("PlayStation Controller", "PlayStation"),
                        ("Joy-Con (L)", "Joy-Con (L)"),
                        ("Joy-Con (R)", "Joy-Con (R)"),
                        ("Joy-Con", "Joy-Con"),
                        ("Nintendo Wireless Gamepad", "Nintendo"),
                        ("Pro Controller", "Switch Pro Controller"),
                        ("Nintendo Switch Pro Controller", "Switch Pro Controller"),
                        ("Steam Controller", "Steam Controller"),
                        ("8BitDo Ultimate 2C", "8BitDo Ultimate"),
                        ("Unidentified gamepad", "Generic")
                    ] {
                        precondition(ControllerArtwork.kind(name: name, preference: nil) == expected)
                        precondition(ControllerArtwork.kind(name: name, preference: "PlayStation") == "PlayStation",
                                     "Existing manual artwork choices must remain valid")
                    }
                    let psKinds = ["PlayStation", "PS4 · DualShock 4", "PS5 · DualSense"]
                    for (index, kind) in psKinds.enumerated() {
                        for other in psKinds.dropFirst(index + 1) {
                            precondition(ControllerArtwork.image(kind).tiffRepresentation != ControllerArtwork.image(other).tiffRepresentation,
                                         "PlayStation models must have distinct drawings")
                        }
                    }
                    precondition(ControllerArtwork.kind(name: "8BitDo Pro 2", preference: nil) == "8BitDo Pro 2")
                    precondition(ControllerArtwork.kind(name: "8BitDo SN30 Pro", preference: nil) == "8BitDo SN30 Pro")
                    precondition(ControllerArtwork.kind(name: "SN30Pro", preference: nil) == "8BitDo SN30 Pro")
                    precondition(ControllerArtwork.kind(name: "8BitDo Micro gamepad", preference: nil) == "8BitDo Micro")
                    precondition(ControllerArtwork.kind(name: "8BitDo Ultimate", preference: nil) == "8BitDo Ultimate")
                    precondition(ControllerArtwork.kind(name: "DualSense", preference: "Xbox") == "Xbox")
                    precondition(controllerModel(vendor: 0x057E, product: 0x2009, name: "Pro Controller") == "Switch Pro Controller" &&
                                 controllerModel(vendor: 0x057E, product: 0x2006, name: "Joy-Con (L)") == "Joy-Con (L)" &&
                                 controllerModel(vendor: 0x057E, product: 0x2007, name: "Joy-Con (R)") == "Joy-Con (R)" &&
                                 controllerModel(vendor: 0x057E, product: 0x1234, name: "Wireless Gamepad") == "Nintendo" &&
                                 controllerModel(vendor: 0x2DC8, product: 0x6001, name: "Pro Controller") == "Generic" &&
                                 controllerModel(vendor: 0x2DC8, product: 0x6001, name: "8BitDo Pro 2") == nil &&
                                 controllerModel(vendor: nil, product: nil, name: "Pro Controller") == nil,
                                 "Only Nintendo's vendor ID proves a genuine Switch controller")
                    precondition(joyConSide(product: 0x2006) == "Joy-Con (L)" && joyConSide(product: 0x2007) == "Joy-Con (R)" &&
                                 joyConSide(product: 0x2009) == nil, "Joy-Con L and R stay distinct from the Pro Controller")
                    precondition(ControllerArtwork.kind(name: "Pro Controller", preference: "Generic") == "Generic" &&
                                 isBluetoothController(deviceClass: 0, name: "Pro Controller") &&
                                 isBluetoothController(deviceClass: 0, name: "Joy-Con (R)") &&
                                 isBluetoothController(deviceClass: 0x002508, name: "Anything"),
                                 "Pro Controller and Joy-Con must be discoverable for pairing")
                    precondition(controllerConnectionStatus(connected: true, inputDetected: false, connecting: false) == "Bluetooth only" &&
                                 controllerConnectionStatus(connected: true, inputDetected: true, connecting: false) == "Connected" &&
                                 controllerConnectionStatus(connected: true, inputDetected: nil, connecting: false) == "Connected" &&
                                 controllerConnectionStatus(connected: false, inputDetected: nil, connecting: true) == "Connecting…",
                                 "A Bluetooth link alone must not claim working game input, nor read as a failure")
                    let proAddress = "e4-17-d8-e1-5a-ce"
                    self.mergeControllerList([], paired: [PairedController(name: "Pro Controller", address: proAddress, connected: true)])
                    let linkOnly = self.controllerEntries.first { $0.id == "bt:e417d8e15ace" }
                    precondition(linkOnly?.connected == true && linkOnly?.inputDetected == false &&
                                 self.controllerStatusText(linkOnly!, active: false) == "Bluetooth only",
                                 "Connected Bluetooth controller absent from HID input must show Bluetooth only")
                    self.mergeControllerList([ControllerEntry(id: "bt:e417d8e15ace", name: "Pro Controller", connected: true,
                                                              transport: "Bluetooth", model: "Switch Pro Controller")],
                                             paired: [PairedController(name: "Pro Controller", address: proAddress, connected: true)])
                    let withInput = self.controllerEntries.first { $0.id == "bt:e417d8e15ace" }
                    precondition(withInput?.inputDetected == nil && withInput?.model == "Switch Pro Controller" &&
                                 self.controllerStatusText(withInput!, active: false) == "Connected",
                                 "HID input upgrades a Bluetooth-only link to Connected")
                    func connectButtons(_ view: NSView) -> [NSButton] {
                        ((view as? NSButton).map { $0.title == "Connect" ? [$0] : [] } ?? []) + view.subviews.flatMap(connectButtons)
                    }
                    let discoverAddress = "98-b6-e9-00-00-02"
                    self.discoveredControllers = [PairedController(name: "Pro Controller", address: discoverAddress, connected: false)]
                    self.renderDiscoveredControllers()
                    let fullConnect = connectButtons(self.discoveredControllerRows)
                    let homePairConnect = connectButtons(self.homeDiscoveredControllerRows)
                    precondition(fullConnect.count == 1 && homePairConnect.count == 1, "Both Home and Controllers offer Connect")
                    self.smokePairRequests = []
                    self.controllerErrors = []
                    self.bluetoothSettingsOpens = 0
                    fullConnect[0].performClick(nil)
                    homePairConnect[0].performClick(nil)
                    precondition(self.smokePairRequests == [discoverAddress, discoverAddress],
                                 "Connect on Home and Controllers must pair in-app")
                    self.devicePairingPINCodeRequest(nil)
                    self.devicePairingFinished(nil, error: kIOReturnError)
                    precondition(self.controllerErrors == ["PIN code needed", "Couldn't pair"] && self.bluetoothSettingsOpens == 0,
                                 "Pair/connect problems must stay in-app and never open Bluetooth Settings")
                    self.discoveredControllers = []
                    self.renderDiscoveredControllers()
                    // A newly found controller appears once, directly under Home's list, and stays put until macOS pairs it.
                    let previousTab = self.tabs.selectedTabViewItem
                    self.tabs.selectTabViewItem(at: 0)
                    let newAddress = "98-b6-e9-00-00-03"
                    self.discoveredControllers = [PairedController(name: "Wireless Controller", address: newAddress, connected: false)]
                    self.renderDiscoveredControllers()
                    self.window.contentView?.layoutSubtreeIfNeeded()
                    let rendersAfterFind = self.discoveredRenderCount
                    func windowFrame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
                    let firstRow = self.homeDiscoveredControllerRows.arrangedSubviews.first.map(windowFrame)
                    let listFrame = windowFrame(self.homeControllerStatus)
                    precondition(firstRow != nil && abs(listFrame.minY - firstRow!.maxY) <= 17,
                                 "A discovered controller must sit right under Home's list, not at the card's bottom")
                    precondition(!self.controllerEntries.contains { $0.id == "bt:98b6e9000003" },
                                 "A discovered controller is not in the paired list before macOS pairs it")
                    for _ in 0..<3 { self.renderDiscoveredControllers(); self.renderControllerList() }
                    self.discoveredControllers.insert(PairedController(name: "Other pad", address: "98-b6-e9-00-00-04", connected: false), at: 0)
                    self.discoveredControllers.removeFirst()
                    self.renderDiscoveredControllers()
                    self.window.contentView?.layoutSubtreeIfNeeded()
                    precondition(self.discoveredRenderCount == rendersAfterFind &&
                                 self.homeDiscoveredControllerRows.arrangedSubviews.first.map(windowFrame) == firstRow,
                                 "Refreshes must not rebuild or move an unchanged Connect row under the pointer")
                    self.mergeControllerList([], paired: [PairedController(name: "Wireless Controller", address: newAddress, connected: true)])
                    precondition(self.discoveredControllers.isEmpty && self.homeDiscoveredControllerRows.isHidden &&
                                 self.controllerEntries.last?.id == "bt:98b6e9000003",
                                 "Only macOS's paired state moves it into the list")
                    self.controllerEntries.removeAll { $0.id == "bt:98b6e9000003" }
                    if let previousTab = previousTab { self.tabs.selectTabViewItem(previousTab) }
                    let joyEntries = [
                        ControllerEntry(id: "bt:aa0000000001", name: "Joy-Con (L)", connected: true, transport: "Bluetooth", model: "Joy-Con (L)"),
                        ControllerEntry(id: "bt:aa0000000002", name: "Joy-Con (R)", connected: true, transport: "Bluetooth", model: "Joy-Con (R)"),
                        ControllerEntry(id: "hid:1406:8201:USB:serial:aa0000000001", name: "Joy-Con (L)", connected: true, transport: "Wired"),
                        ControllerEntry(id: "hid:1118:2835:USB:serial:abc", name: "Xbox Controller", connected: true, transport: "Wired")
                    ]
                    self.controllerEntries = joyEntries
                    self.controllerAliases = ["hid:1406:8201:USB:serial:aa0000000001": "bt:aa0000000001"]
                    self.mergeControllerList(joyEntries, paired: [])
                    precondition(self.controllerAliases.isEmpty, "Joy-Cons must never be auto-linked or keep stale links")
                    precondition(Set(self.controllerEntries.map(\.id)).isSuperset(of: joyEntries.prefix(3).map(\.id)),
                                 "Joy-Con L, R and their USB entry stay separate controllers")
                    for entry in self.controllerEntries where isJoyCon(entry) {
                        precondition(self.controllerLinkCandidates(for: entry).isEmpty, "Joy-Cons are never offered Same Controller As")
                    }
                    if let xbox = self.controllerEntries.first(where: { $0.name == "Xbox Controller" }) {
                        precondition(!self.controllerLinkCandidates(for: xbox).contains(where: isJoyCon),
                                     "Other controllers can't link to a Joy-Con")
                    }
                    self.linkController("hid:1406:8201:USB:serial:aa0000000001", to: "bt:aa0000000001")
                    precondition(self.controllerAliases.isEmpty, "Manual linking refuses Joy-Cons")
                    precondition(ControllerArtwork.kind(name: "Joy-Con (L)", preference: "Joy-Con (L)") == "Joy-Con (L)" &&
                                 ControllerArtwork.kind(name: "Nintendo Controller", preference: nil) == "Nintendo" &&
                                 ControllerArtwork.kind(name: "Steam Controller", preference: nil) == "Steam Controller")
                    let artKinds = ["Joy-Con (L)", "Joy-Con (R)", "Joy-Con", "Nintendo", "Switch Pro Controller", "Steam Controller", "Generic"]
                    let artData = artKinds.map { ControllerArtwork.image($0).tiffRepresentation! }
                    precondition(Set(artData).count == artKinds.count, "Joy-Con L/R/pair, SNES, Switch Pro and Steam art are distinct")
                    self.controllerAliases = [:]
                    self.controllerEntries = savedEntries
                    self.homeSessionControllers = []
                    self.homeObservedConnections = []
                    self.renderHomeControllers()
                    self.selectPage(7)
                    let biosPreview = BIOSStatus(state: "missing", summary: "Missing BIOS",
                        files: [
                            BIOSFileStatus(filename: "dc/dc_boot.bin", path: "/BIOS/dc/dc_boot.bin", present: false, note: ""),
                            BIOSFileStatus(filename: "dc/dc_flash.bin", path: "/BIOS/dc/dc_flash.bin", present: false, note: "")
                        ])
                    func biosCopyButtons(_ view: NSView) -> [NSButton] {
                        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { biosCopyButtons($0) }
                    }
                    let biosButtons = biosCopyButtons(self.biosStatusView(biosPreview, searchQuery: "Dreamcast BIOS"))
                    precondition(biosButtons.first?.action == #selector(self.openBIOSFolder(_:)) &&
                                 biosButtons.first?.identifier?.rawValue == "/BIOS/dc",
                                 "BIOS details must show the destination folder")
                    let copies = biosButtons.filter { $0.action == #selector(self.copyBIOSNames(_:)) }
                    precondition(copies.map { $0.title } == ["dc_boot.bin", "dc_flash.bin", "Copy"])
                    precondition(copies.map { $0.identifier!.rawValue } ==
                                 ["dc_boot.bin", "dc_flash.bin", "Dreamcast BIOS"])
                    precondition(!biosButtons.contains { $0.title.contains("Google") || $0.title == "Copy all" })
                    precondition(biosCopyButtons(self.biosStatusView(BIOSStatus(state: "present",
                        summary: "BIOS found", files: biosPreview.files))).isEmpty)
                    let orderedSystems = ConsoleArtwork.groups.flatMap { $0.systems }
                    precondition(self.consoleSystems.map { $0.id } == orderedSystems,
                                 "Systems must stay grouped and ordered by original release")
                    let artwork = orderedSystems.compactMap { ConsoleArtwork.image(for: $0).tiffRepresentation }
                    precondition(artwork.count == 17 && Set(artwork).count == 17,
                                 "Every system must have distinct, renderable original artwork")
                    precondition(orderedSystems.allSatisfy { !ConsoleArtwork.image(for: $0).isTemplate },
                                 "Console artwork must preserve its hardware colors")
                    let switchBitmap = NSBitmapImageRep(data: ConsoleArtwork.image(for: "switch").tiffRepresentation!)!
                    let leftJoyCon = switchBitmap.colorAt(x: switchBitmap.pixelsWide * 4 / 32,
                        y: switchBitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    let rightJoyCon = switchBitmap.colorAt(x: switchBitmap.pixelsWide * 27 / 32,
                        y: switchBitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    precondition(leftJoyCon.alphaComponent > 0.9 && leftJoyCon.blueComponent > leftJoyCon.redComponent &&
                                 rightJoyCon.alphaComponent > 0.9 && rightJoyCon.redComponent > rightJoyCon.blueComponent,
                                 "Switch Joy-Cons must retain separate blue and red colors")
                    let inspectorTrigger = NSButton()
                    inspectorTrigger.tag = 0
                    self.showConsoleDetails(inspectorTrigger)
                    precondition(self.inspectorTitle.stringValue == self.consoleSystems[0].name)
                    self.closeInspector()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[7])
                    self.selectPage(0)
                    func labels(in view: NSView) -> [String] {
                        if let label = view as? NSTextField { return [label.stringValue] }
                        return view.subviews.flatMap { labels(in: $0) }
                    }
                    func indicatorColors(in view: NSView) -> [NSColor] {
                        if let image = view as? NSImageView, let color = image.contentTintColor {
                            precondition(image.layer?.animation(forKey: "checking") == nil,
                                         "Cached status must not pulse during a refresh")
                            return [color]
                        }
                        return view.subviews.flatMap { indicatorColors(in: $0) }
                    }
                    let hadAppResults = self.appsHaveResults
                    self.appsHaveResults = true
                    self.appsChecking = false
                    self.renderApps()
                    let appColors = indicatorColors(in: self.appMenuRows)
                    self.appsChecking = true
                    self.renderApps()
                    precondition(indicatorColors(in: self.appMenuRows) == appColors,
                                 "App status colors must stay unchanged during background refresh")
                    self.appsChecking = false
                    self.appsHaveResults = hadAppResults
                    self.renderApps()
                    let savedAppsForConsoleStatus = self.appStates
                    let savedSystemsForStatus = self.consoleSystems
                    let hadConsoleResults = self.consolesLoaded
                    self.appsHaveResults = true
                    self.consolesLoaded = true
                    self.consoleSystems = [ConsoleSystem(id: "ps2", name: "PlayStation 2", enabled: true,
                        package: "pcsx2", requirement: "", bios: nil, emulator_installed: true)]
                    for hasUpdate in [false, true] {
                        self.appStates = [ManagedApp(id: "pcsx2", name: "PCSX2", installed: true,
                            path: "", version: "1.0", managed: true, update: hasUpdate ? "2.0" : nil,
                            manual: false, brew: true, url: nil)]
                        let expectedTitle = hasUpdate ? "PCSX2 · Update available" : "PCSX2"
                        for refreshing in [false, true] {
                            self.consolesChecking = refreshing
                            self.renderSystems()
                            precondition(labels(in: self.consoleRows).contains(expectedTitle),
                                         "Console rows must explain updates, including during refresh")
                        }
                        let trigger = NSButton()
                        trigger.tag = 0
                        self.showConsoleDetails(trigger)
                        precondition(labels(in: self.inspectorRows).contains(expectedTitle),
                                     "Console details must explain emulator updates")
                        precondition(!labels(in: self.inspectorRows).contains { $0.contains("Emulator ready") || $0.contains("core:") },
                                     "Console details must stay short")
                        func actions(_ view: NSView) -> [Selector] {
                            ((view as? NSButton)?.action).map { [$0] } ?? view.subviews.flatMap { actions($0) }
                        }
                        precondition(actions(self.inspectorRows) == [#selector(self.showEmulatorInAppStore(_:))],
                                     "Console details must offer only the App Store link without BIOS")
                        precondition(actions(self.consoleRows).contains(#selector(self.showEmulatorInAppStore(_:))) &&
                                     !actions(self.tabs.tabViewItems[7].view!).contains(#selector(self.showPlayers)),
                                     "Console rows link to App Store; the page has no bottom App Store button")
                        self.closeInspector()
                        self.appsChecking = false
                        self.renderApps()
                        self.highlightedAppID = "pcsx2"
                        self.highlightAppRow()
                        precondition(self.highlightedAppID == nil, "App Store highlight must finish after results load")
                        func row(_ view: NSView, _ id: String) -> NSView? {
                            view.identifier?.rawValue == id ? view : view.subviews.lazy.compactMap { row($0, id) }.first
                        }
                        precondition(row(self.appRetroRows, "app-row-pcsx2")?.layer?.backgroundColor != nil,
                                     "Opening an emulator in App Store must highlight its row")
                    }
                    self.appStates = savedAppsForConsoleStatus
                    self.consoleSystems = savedSystemsForStatus
                    self.appsHaveResults = hadAppResults
                    self.consolesLoaded = true
                    self.consolesChecking = false
                    self.renderSystems()
                    let consoleColors = indicatorColors(in: self.consoleRows)
                    self.consolesChecking = true
                    self.renderSystems()
                    precondition(indicatorColors(in: self.consoleRows) == consoleColors,
                                 "Emulator and BIOS status colors must stay unchanged during refresh")
                    self.consolesChecking = false
                    self.consolesLoaded = hadConsoleResults
                    self.renderSystems()
                    self.overviewChecks = Set(OverviewCheck.allCases)
                    self.renderGeneral()
                    precondition(self.homeProgress.isHidden, "Known Home status must stay stable during refresh")
                    self.overviewChecks = []
                    self.overviewCheckFailures = [.storage]
                    self.guidedSetup = false
                    self.renderGeneral()
                    precondition(self.sidebarAttention[6] != nil, "Storage errors must mark the sidebar")
                    self.guidedSetup = true
                    self.renderGeneral()
                    precondition(self.sidebarAttention[6] != nil && self.sidebarAttention.count == 1,
                                 "Guided setup shows storage first and nothing else")
                    let savedCounts = self.sidebarTaskCounts
                    self.sidebarTaskCounts = sidebarBadges([SidebarTask(page: 7, color: .systemYellow, title: "y1", setup: false),
                                                            SidebarTask(page: 7, color: .systemRed, title: "r1", setup: false),
                                                            SidebarTask(page: 7, color: .systemYellow, title: "y2", setup: false)], guided: false)
                    if let cell = self.tableView(self.sidebar, viewFor: nil, row: self.sidebarPages.firstIndex(of: 7)!) {
                        func dots(_ view: NSView) -> [SidebarCountDot] {
                            (view as? SidebarCountDot).map { [$0] } ?? view.subviews.flatMap(dots)
                        }
                        let found = dots(cell)
                        precondition(found.map(\.color) == [.systemRed, .systemYellow] &&
                                     found.compactMap { ($0.subviews.first as? NSTextField)?.stringValue } == ["1", "2"] &&
                                     found[0].accessibilityLabel() == "1 needs attention: r1" && found[0].toolTip?.contains("2 recommended") == true,
                                     "Sidebar shows separate red and yellow markers with their own counts")
                    } else { preconditionFailure("Sidebar row must render") }
                    self.updateSelectedStorageMarker()
                    if let drive = self.selected {
                        let expected = drive.mode == "local" ? "This Mac" : "External SSD"
                        precondition(self.selectedStorageMode.stringValue.hasPrefix(expected) && !self.selectedStorageIcon.isHidden &&
                                     self.selectedStorageIcon.image != nil && self.selectedStorageIcon.accessibilityLabel() == self.selectedStorageMode.stringValue &&
                                     self.storageMode(drive.mode).symbol == (drive.mode == "local" ? "macmini" : "externaldrive"),
                                     "Game library storage uses the Library Settings mode name and icon")
                    } else {
                        precondition(self.selectedStorageMode.stringValue == "No storage selected" ||
                                     self.selectedStorageMode.stringValue.hasSuffix("· Disconnected"))
                    }
                    let controllersRow = self.sidebarPages.firstIndex(of: 8)!
                    func controllersCellLayout(_ tasks: [SidebarTask]) -> [NSRect] {
                        self.sidebarTaskCounts = sidebarBadges(tasks, guided: false)
                        let cell = self.tableView(self.sidebar, viewFor: nil, row: controllersRow)!
                        cell.frame = NSRect(x: 0, y: 0, width: 180, height: self.tableView(self.sidebar, heightOfRow: controllersRow))
                        cell.layoutSubtreeIfNeeded()
                        let title = (cell as! NSTableCellView).textField!
                        let icon = (cell as! NSTableCellView).imageView!
                        precondition(abs(title.frame.midY - cell.bounds.midY) < 1, "Sidebar titles stay vertically centered")
                        // Width may shrink for truncation; position and height must not change.
                        return [title.frame, icon.frame].map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) }
                    }
                    let task = { (color: NSColor, n: Int) in (0..<n).map { SidebarTask(page: 8, color: color, title: "t\($0)", setup: false) } }
                    let noBadge = controllersCellLayout([])
                    for tasks in [task(.systemYellow, 1), task(.systemRed, 1) + task(.systemYellow, 2),
                                  task(.systemRed, 12) + task(.systemYellow, 140), [], task(.systemYellow, 3)] {
                        precondition(controllersCellLayout(tasks) == noBadge, "Sidebar badges must never move the Controllers title or icon")
                    }
                    self.sidebarTaskCounts = savedCounts
                    self.renderGeneral()
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    let liveCells = self.sidebarPages.indices.map { self.sidebar.view(atColumn: 0, row: $0, makeIfNecessary: false) }
                    let liveFrames = liveCells.map { ($0 as? NSTableCellView)?.textField.map { $0.convert($0.bounds, to: nil) } }
                    for guided in [false, true, false] {
                        self.guidedSetup = guided
                        self.overviewCheckFailures = guided ? [] : [.storage]
                        self.renderGeneral()
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        let now = self.sidebarPages.indices.map { self.sidebar.view(atColumn: 0, row: $0, makeIfNecessary: false) }
                        precondition(zip(now, liveCells).allSatisfy { $0 === $1 }, "Badge refresh updates sidebar cells in place")
                        precondition(now.map { ($0 as? NSTableCellView)?.textField.map { $0.convert($0.bounds, to: nil) }.map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) } } ==
                                     liveFrames.map { $0.map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) } },
                                     "Badge refresh must not move any sidebar title")
                    }
                    self.guidedSetup = true
                    self.overviewCheckFailures = [.storage]
                    self.renderGeneral()
                    // Battery warning orange must stay readable on light and dark rows.
                    func luminance(_ color: NSColor) -> CGFloat {
                        let c = color.usingColorSpace(.sRGB)!
                        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
                    }
                    for name in [NSAppearance.Name.aqua, .darkAqua] {
                        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                            let fg = luminance(controllerBatteryWarningColor), bg = luminance(settingsSectionBackground)
                            let ratio = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
                            precondition(ratio >= 4.5, "Battery warning contrast \(ratio) in \(name.rawValue)")
                        }
                    }
                    self.overviewCheckFailures = []
                    self.renderGeneral()
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.playAction.action == #selector(self.showPlayOverview))
                    precondition(self.playAction.isDescendant(of: self.tabs.tabViewItems[0].view!))
                    let tiles = self.homeTiles.arrangedSubviews
                    precondition(tiles.count == 2 &&
                                 abs(tiles[0].frame.width - tiles[1].frame.width) <= 1 &&
                                 tiles[0].frame.width >= 280,
                                 "Discover tiles must have equal usable widths: \(self.homeTiles.frame), \(tiles.map(\.frame)), scroll \(self.tabs.tabViewItems[0].view!.frame)")
                    precondition(NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("HomeHeader.png")) != nil)
                    precondition(NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("HomeHeaderPortable.png")) != nil)
                    for name in ["HomeHeader.png", "HomeHeaderPortable.png"] {
                        let image = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(name))
                        precondition(image?.size == NSSize(width: 1680, height: 500))
                    }
                    func homeHeaderButtons(_ view: NSView) -> [NSButton] {
                        (view.identifier?.rawValue == "home-controller-header" ? (view as! NSStackView).arrangedSubviews.compactMap { $0 as? NSButton } : []) +
                            view.subviews.flatMap { homeHeaderButtons($0) }
                    }
                    let controllerHeaderButtons = homeHeaderButtons(self.homeTiles)
                    precondition(controllerHeaderButtons.map { $0.action } == [#selector(self.showControllers)],
                                 "Home lists discovered controllers itself, so it has no separate add button")
                    precondition(!self.homeDiscoveredControllerRows.isHidden, "Discovered controllers must appear on Home")
                    let homeConnect = self.homeDiscoveredControllerRows.arrangedSubviews.flatMap { ($0 as! NSStackView).arrangedSubviews }
                        .compactMap { $0 as? NSButton }
                    precondition(homeConnect.map(\.title) == ["Connect"] &&
                                 homeConnect.first?.identifier?.rawValue == "98-b6-e9-00-00-01" &&
                                 homeConnect.first?.action == #selector(self.pairDiscoveredController(_:)),
                                 "Home must offer the same real Connect action as Controllers")
                    precondition(!self.homeTiles.arrangedSubviews[1].subviews.flatMap { $0.subviews }.contains { $0 is TileActionButton },
                                 "The controller tile must not be one big button")
                    for (id, line) in self.homeControllerRowViews {
                        let stack = line as! NSStackView
                        precondition(stack.arrangedSubviews.first is ControllerDragHandle && stack.arrangedSubviews.last is NSPopUpButton, id)
                    }
                    let hoverEvent = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber,
                        context: nil, subtype: 0, data1: 0, data2: 0)!
                    for control in [self.playAction].compactMap({ $0 as? TileActionButton }) {
                        let enabled = control.isEnabled
                        control.isEnabled = true
                        control.mouseEntered(with: hoverEvent)
                        precondition(control.isHovered)
                        control.mouseExited(with: hoverEvent)
                        precondition(!control.isHovered)
                        control.isEnabled = false
                        control.mouseEntered(with: hoverEvent)
                        precondition(!control.isHovered, "Disabled tiles must not advertise an available action")
                        control.isEnabled = enabled
                    }
                    precondition(!labels(in: self.homeControllerStatus).contains { $0.contains("controller") && $0.contains("connected") })
                    controllerHeaderButtons[0].performClick(nil)
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8])
                    self.selectPage(0)
                    precondition(self.sidebarPages == [-1, 0, 8, 13, -1, 6, 1, 7, 10, 11] && !self.sidebarPages.contains(2))
                    precondition(self.sidebarTitles[0] == "Couch Cube" && self.sidebarTitles[1] == "Play" && self.sidebarSymbols[1] == "play.rectangle.fill")
                    precondition(self.sidebarTitles[self.sidebarPages.firstIndex(of: 1)!] == "App Store")
                    for page in [0, 8, 13, 6, 1, 7, 10, 11] {
                        let sidebarRow = self.sidebarPages.firstIndex(of: page)!
                        let cell = self.tableView(self.sidebar, viewFor: self.sidebar.tableColumns[0], row: sidebarRow)!
                        func colorTiles(in view: NSView) -> [NSBox] {
                            view.subviews.flatMap { child in
                                if let box = child as? NSBox, box.boxType == .custom { return [box] }
                                return colorTiles(in: child)
                            }
                        }
                        precondition(colorTiles(in: cell).isEmpty, "Sidebar symbols must not have colored tiles")
                        precondition((cell as? NSTableCellView)?.imageView?.contentTintColor == .secondaryLabelColor)
                    }
                    precondition(!self.sidebarPages.contains(5), "Steam guide is part of Game library, not a sidebar destination")
                    precondition(!self.homeControllerStatus.arrangedSubviews.isEmpty)
                    let homeReport = self.report
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.renderGeneral()
                    precondition(!labels(in: self.tabs.tabViewItems[0].view!).contains("Needs attention"),
                                 "Home must not show an attention section")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                        missing: Array(self.computerGameApps.union(self.emulatorApps).union(["es-de"])))
                    self.guidedSetup = false
                    self.renderGeneral()
                    precondition(self.sidebarAttention[1] == .systemRed, "Missing apps must mark Apps in red")
                    self.guidedSetup = true
                    self.report = homeReport
                    self.renderGeneral()
                    let countReport = self.report
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                                             missing: Array(self.computerGameApps.union(self.emulatorApps)))
                    precondition(self.overviewAppSummary == "0 PC game apps · 0 emulators installed")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                                             missing: Array(self.computerGameApps.union(self.emulatorApps).subtracting(["steam", "dolphin"])))
                    precondition(self.overviewAppSummary == "1 PC game app · 1 emulator installed")
                    self.report = countReport
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    self.selectPage(2)
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[6], "Library storage opens the merged Game library")
                    self.goBack()
                    precondition(self.screenTitle.stringValue == "Play")
                    self.goForward()
                    precondition(self.screenTitle.stringValue == "Game library")
                    self.showTVMenus()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[10])
                    precondition(self.screenTitle.stringValue == "Console Mode")
                    self.renderTVMenus()
                    precondition(self.defaultMenuPicker.numberOfItems >= 2)
                    for item in self.defaultMenuPicker.itemArray {
                        if let id = item.representedObject as? String {
                            precondition(item.isEnabled == (self.appStates.first { $0.id == id }?.installed == true))
                        }
                    }
                    precondition(self.defaultMenuPicker.isDescendant(of: self.tabs.tabViewItems[10].view!))
                    precondition(self.updateButton.isDescendant(of: self.tabs.tabViewItems[11].view!))
                    self.selectPage(11)
                    precondition(self.screenTitle.stringValue == "App Settings")
                    self.report = nil
                    self.continueStorage()
                    precondition(self.task == nil, "No storage assessment must never start setup")
                    self.report = Assessment(state: "needs attention", issues: ["Fixture: unsupported storage"], notes: [], missing: [])
                    self.continueStorage()
                    precondition(self.task == nil, "Storage issues must never start setup")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: ["steam", "es-de"])
                    self.updateSetupSummary()
                    precondition(!self.playAction.isEnabled)
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: ["steam"])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled && self.homeMenuLabel.stringValue == "ES-DE")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled)
                    self.preferredFrontend = "es-de"
                    self.updateSetupSummary()
                    precondition(self.homeMenuLabel.stringValue == "ES-DE")
                    precondition(self.homePlayBackground.layer?.contentsGravity == .resizeAspect,
                                 "The complete EmulationStation logo must remain visible")
                    let esArtwork = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("TVMenus/es-de.png"))!
                    precondition(esArtwork.size == NSSize(width: 1676, height: 784))
                    self.preferredFrontend = nil
                    self.showFinishing()
                    precondition(!self.steamStorageAdvice.stringValue.isEmpty)
                    self.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
                    precondition(self.task == nil, "Focusing the app must not trigger storage checks")
                    self.report = assessment
                    self.updateSetupSummary()
                    self.selectPage(3)
                }
                self.window.contentView!.layoutSubtreeIfNeeded()
                self.window.displayIfNeeded()
                self.assertSmokePageScrolls()
                let fits = stack.fittingSize.height <= self.detail.bounds.height - 36
                let ok = discoveryOK && fits
                precondition(self.storageNext.isBordered && !self.playAction.isBordered)
                precondition(self.homePlayBackground.layer?.contents != nil)
                precondition(self.window.titleVisibility == .hidden && self.window.toolbar?.delegate === self)
                precondition(self.window.styleMask.contains(.fullSizeContentView))
                precondition(self.window.toolbar!.items.contains { $0 === self.backToolbarItem })
                precondition(self.window.toolbar!.items.contains { $0 === self.forwardToolbarItem })
                precondition(self.backToolbarItem.isNavigational && self.forwardToolbarItem.isNavigational)
                precondition(!self.screenTitle.isDescendant(of: self.mainDetail),
                             "Navigation belongs in the system toolbar, not a simulated content header")
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let control = self.window.standardWindowButton(kind)!
                    precondition(!control.isHidden)
                    let frame = self.sidebarPanel.convert(control.bounds, from: control)
                    precondition(self.sidebarPanel.bounds.contains(frame),
                                 "Native window controls must fit inside the inset sidebar: \(frame)")
                }
                precondition(self.sidebarPanel.alphaValue == 1)
                precondition(self.window.contentViewController === self.splitController)
                precondition(self.splitController.splitViewItems.first?.behavior == .sidebar)
                precondition(!self.sidebarPanel.subviews.contains { $0 is NSVisualEffectView },
                             "Legacy materials must not obscure the native sidebar glass")
                let layoutGuide = self.window.contentLayoutGuide as! NSLayoutGuide
                let navigationFrame = self.navigationBar.convert(self.navigationBar.bounds, to: self.window.contentView!)
                precondition(abs(navigationFrame.maxY - layoutGuide.frame.maxY) <= 1,
                             "Sidebar must begin directly below the native toolbar")
                precondition(abs(self.detail.frame.maxY - self.mainDetail.safeAreaLayoutGuide.frame.maxY) <= 1,
                             "Detail content must not have extra top padding")
                if args.contains("--smoke-activity") {
                    self.append("Activity appearance check: storage checked. No files changed.\n")
                    self.showActivity()
                    self.logWindow!.appearance = self.window.effectiveAppearance
                    self.append(String(repeating: "Live install output remains readable and scrollable.\n", count: 200))
                    let storage = self.log.textStorage!
                    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
                        precondition((attributes[.foregroundColor] as? NSColor) == NSColor.textColor)
                        precondition((attributes[.font] as? NSFont) == self.log.font)
                    }
                    self.logWindow!.contentView!.layoutSubtreeIfNeeded()
                    self.log.layoutManager!.ensureLayout(for: self.log.textContainer!)
                    precondition(self.log.bounds.height > self.log.enclosingScrollView!.contentSize.height, "Long Activity output must scroll")
                    self.logWindow!.displayIfNeeded()
                }
                if let index = args.firstIndex(of: "--capture"), args.indices.contains(index + 1) {
                    let captureWindow = args.contains("--smoke-activity") ? self.logWindow! : self.window!
                    let view = captureWindow.contentView!
                    captureWindow.effectiveAppearance.performAsCurrentDrawingAppearance {
                        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                              let context = NSGraphicsContext(bitmapImageRep: image) else {
                            fputs("Cannot create UI capture context.\n", stderr)
                            exit(1)
                        }
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        NSColor.windowBackgroundColor.setFill()
                        view.bounds.fill()
                        view.displayIgnoringOpacity(view.bounds, in: context)
                        NSGraphicsContext.restoreGraphicsState()
                        guard let png = image.representation(using: .png, properties: [:]) else { exit(1) }
                        do { try png.write(to: URL(fileURLWithPath: args[index + 1])) }
                        catch { fputs("Cannot capture UI: \(error)\n", stderr); exit(1) }
                    }
                }
                let failure: String = "Portable manager smoke test failed: " + self.status.stringValue
                let passed: String = "Native UI smoke test passed: settings navigation, apps, consoles and controller preview; no setup or pairing executed."
                print(ok ? passed : failure)
                let code: Int32 = ok ? 0 : 1
                exit(code)
        }
    }

    /// Rapid toggles: instant UI, no rebuild, one debounced save of the latest intent, serialized saves, stale refreshes ignored, failures reverted.
    /// Launch preload and every-tab-open refreshes: silent, keep rendered rows, newest result wins.
    private func smokeTestSilentRefresh() {
        let saved = (backendRead, consoleRoot, report, consoleSystems, consolesLoaded, consolesChecking,
                     appStates, appsHaveResults, lastAppsData, overviewChecks, appsPreloadPending)
        defer {
            (backendRead, consoleRoot, report) = (saved.0, saved.1, saved.2)
            consoleSystems = saved.3
            consolesLoaded = saved.4
            consolesChecking = saved.5
            appStates = saved.6
            appsHaveResults = saved.7
            lastAppsData = saved.8
            overviewChecks = saved.9
            appsPreloadPending = saved.10
            consoleSaveDirty = false
            consoleStatus.stringValue = ""
            renderSystems()
            renderApps()
            renderGeneral()
        }
        precondition(task == nil)
        var reads: [(args: [String], done: (Int32, Data) -> Void)] = []
        backendRead = { args, done in
            if args == ["frontend"] {
                done(0, try! JSONSerialization.data(withJSONObject: ["preferred": self.preferredFrontend as Any]))
            } else { reads.append((args, done)) }
        }
        func systemsJSON(_ enabled: Set<String>) -> Data {
            try! JSONSerialization.data(withJSONObject: consoleSystems.map { system -> [String: Any] in
                var item: [String: Any] = ["id": system.id, "name": system.name, "enabled": enabled.contains(system.id),
                                           "package": system.package, "requirement": system.requirement]
                if let installed = system.emulator_installed { item["emulator_installed"] = installed }
                return item
            })
        }
        func appsJSON(_ installed: Set<String>) -> Data {
            try! JSONSerialization.data(withJSONObject: appStates.map { app -> [String: Any] in
                ["id": app.id, "name": app.name, "installed": installed.contains(app.id), "path": app.path, "version": app.version,
                 "managed": app.managed, "manual": app.manual, "brew": app.brew]
            })
        }
        // Retro consoles: refresh keeps rows, ignores stale and wrong-library results, keeps unsaved toggle intent.
        consoleRoot = { "/smoke" }
        report = Assessment(state: "valid layout", issues: [], notes: [], missing: [], preferred_frontend: preferredFrontend)
        consolesLoaded = true
        renderSystems()
        let rows = consoleRows.arrangedSubviews.map(ObjectIdentifier.init)
        let ids = consoleSystems.map(\.id)
        loadSystems()
        precondition(reads.count == 1 && consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rows,
                     "Opening Retro consoles refreshes in the background without a loading rebuild")
        loadSystems()
        precondition(reads.count == 2)
        reads[1].done(0, systemsJSON([ids[0]]))
        reads[0].done(0, systemsJSON([ids[1]]))
        precondition(Set(consoleSystems.filter(\.enabled).map(\.id)) == [ids[0]], "An older read must not overwrite a newer one")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rows && systemSwitches[ids.firstIndex(of: ids[0])!].state == .on,
                     "Refresh results update switches in place")
        loadSystems()
        consoleRoot = { "/other" }
        reads[2].done(0, systemsJSON([ids[2]]))
        precondition(Set(consoleSystems.filter(\.enabled).map(\.id)) == [ids[0]], "Results for another library are ignored")
        consoleRoot = { "/smoke" }
        consoleSystems[1].enabled = true
        consoleSaveDirty = true
        loadSystems()
        reads[3].done(0, systemsJSON([ids[0]]))
        precondition(consoleSystems[1].enabled && consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rows,
                     "A refresh during a pending save keeps the user's latest toggle")
        consoleSaveDirty = false
        // App Store: launch preload and silent tab refresh.
        reads = []
        appsHaveResults = true
        lastAppsData = appsJSON([])
        appStates = try! JSONDecoder().decode([ManagedApp].self, from: lastAppsData!)
        renderApps()
        let appRows = appPCRows.arrangedSubviews.map(ObjectIdentifier.init)
        overviewChecks = [.apps]
        appsPreloadPending = true
        let finishing = smokeFinishing
        smokeFinishing = false
        runPendingAppsPreload()
        smokeFinishing = finishing
        precondition(reads.count == 1 && reads[0].args == ["apps", "--updates"] && !appsPreloadPending && !appsChecking,
                     "Launch preload reads App Store data in the background")
        precondition(appPCRows.arrangedSubviews.map(ObjectIdentifier.init) == appRows, "Preload keeps rendered rows")
        reads[0].done(0, lastAppsData!)
        precondition(!overviewChecks.contains(.apps) && appPCRows.arrangedSubviews.map(ObjectIdentifier.init) == appRows,
                     "Unchanged results finish the check without rebuilding rows")
        fetchApps(updates: false)
        fetchApps(updates: false)
        precondition(reads.count == 3 && !appsChecking && appPCRows.arrangedSubviews.map(ObjectIdentifier.init) == appRows,
                     "Opening App Store again refreshes silently")
        reads[2].done(0, appsJSON(["steamac"]))
        reads[1].done(0, appsJSON([]))
        precondition(appStates.first { $0.id == "steamac" }?.installed == true, "An older App Store read must not overwrite a newer one")
    }

    private func smokeTestConsoleBulkToggles() {
        let saved = (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay, consoleSystems, consolesLoaded, consolesChecking,
                     pendingEmulatorInstall, pendingAppStoreID)
        defer {
            (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay) = (saved.0, saved.1, saved.2, saved.3)
            consoleSaveTimer?.invalidate()
            consoleSaveTimer = nil
            consolePersistedEnabled = nil
            consoleSaveDirty = false
            consoleStatus.stringValue = ""
            consoleSystems = saved.4
            consolesLoaded = saved.5
            consolesChecking = saved.6
            (pendingEmulatorInstall, pendingAppStoreID) = (saved.7, saved.8)
            renderSystems()
        }
        var saves: [(enabled: Set<String>, done: (Int32, String) -> Void)] = []
        consoleSaver = { _, enabled, done in saves.append((Set(enabled), done)) }
        consoleRefresher = { _, _ in }
        consoleRoot = { "/smoke" }
        consoleSaveDelay = 60
        consolesLoaded = true
        consolesChecking = false
        consolePersistedEnabled = nil
        // Start mixed: every Nintendo home console on, everything else off. Uninstalled emulators are included on purpose.
        let home = Set(ConsoleArtwork.groups[0].systems), handheld = Set(ConsoleArtwork.groups[1].systems)
        for index in consoleSystems.indices { consoleSystems[index].enabled = home.contains(consoleSystems[index].id) }
        renderSystems()
        let rowsBefore = consoleRows.arrangedSubviews.map(ObjectIdentifier.init)
        let switchesBefore = systemSwitches.map(ObjectIdentifier.init)
        func bulk(_ scope: String) -> (toggle: NSSwitch, count: NSTextField, ids: Set<String>, scope: String) {
            consoleBulkToggles.first { $0.scope == scope }!
        }
        func press(_ scope: String) {
            let toggle = bulk(scope).toggle
            toggle.state = toggle.state == .on ? .off : .on
            toggleConsoleGroup(toggle)
        }
        func current() -> Set<String> { Set(consoleSystems.filter(\.enabled).map(\.id)) }
        func switchesMatch() -> Bool { zip(consoleSystems, systemSwitches).allSatisfy { ($0.enabled ? NSControl.StateValue.on : .off) == $1.state } }
        let all = Set(consoleSystems.map(\.id))
        let nintendo = home.union(handheld).intersection(all)
        precondition(bulk("Nintendo home consoles").toggle.state == .on && bulk("Nintendo home consoles").count.isHidden)
        precondition(bulk("Nintendo handhelds").toggle.state == .off && bulk("Nintendo handhelds").count.isHidden)
        precondition(bulk("Nintendo consoles").toggle.state == .off && !bulk("Nintendo consoles").count.isHidden &&
                     bulk("Nintendo consoles").count.stringValue == "\(home.count) of \(nintendo.count)", "Mixed groups show a count")
        precondition(bulk("all consoles").toggle.accessibilityLabel() == "Show all all consoles, \(home.count) of \(all.count) shown" ||
                     bulk("all consoles").toggle.accessibilityLabel()?.contains("\(home.count) of \(all.count) shown") == true)
        // Subsection level; parents recompute instantly.
        press("Nintendo handhelds")
        precondition(current() == nintendo && switchesMatch() && bulk("Nintendo consoles").toggle.state == .on &&
                     bulk("Nintendo consoles").count.isHidden && bulk("all consoles").toggle.state == .off)
        precondition(pendingEmulatorInstall == nil && pendingAppStoreID == nil, "Showing consoles never installs anything")
        // Clicking a mixed toggle shows all.
        precondition(!bulk("all consoles").count.isHidden)
        press("all consoles")
        precondition(current() == all && switchesMatch() && consoleBulkToggles.allSatisfy { $0.toggle.state == .on && $0.count.isHidden })
        // Section level hides only its own systems.
        press("PlayStation consoles")
        let playStation = bulk("PlayStation consoles").ids
        precondition(current() == all.subtracting(playStation) && bulk("all consoles").toggle.state == .off)
        // An individual switch updates every parent at once.
        let gb = consoleSystems.firstIndex { $0.id == "gb" }!
        systemSwitches[gb].state = .off
        toggleSystem(systemSwitches[gb])
        precondition(bulk("Nintendo handhelds").count.stringValue == "\(handheld.count - 1) of \(handheld.count)" &&
                     bulk("Nintendo consoles").toggle.state == .off)
        press("Nintendo handhelds")
        let expected = all.subtracting(playStation)
        precondition(current() == expected && saves.isEmpty, "Bulk and single toggles wait for a pause")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore &&
                     systemSwitches.map(ObjectIdentifier.init) == switchesBefore, "Bulk toggles must not rebuild the list")
        saveSystems()
        precondition(saves.count == 1 && saves[0].enabled == expected, "One save for the whole batch")
        saves[0].done(0, "")
        precondition(consolePersistedEnabled == expected)
        // Hide everything, then fail: the last saved choices and the group states come back.
        press("all consoles")
        precondition(current() == all, "All on except PlayStation was mixed; the click shows all")
        press("all consoles")
        precondition(current().isEmpty && consoleBulkToggles.allSatisfy { $0.toggle.state == .off && $0.count.isHidden })
        saveSystems()
        precondition(saves.count == 2 && saves[1].enabled.isEmpty)
        saves[1].done(1, "Disk is read-only\n")
        precondition(current() == expected && switchesMatch() && bulk("PlayStation consoles").toggle.state == .off &&
                     bulk("all consoles").toggle.state == .off && !bulk("all consoles").count.isHidden,
                     "A failed bulk save reverts the switches and the group states")
        precondition(consoleStatus.stringValue.hasPrefix("Couldn't save console selection"))
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore)
        // Not loaded yet: bulk switches are disabled and refuse.
        consolesLoaded = false
        updateConsoleBulkToggles()
        precondition(consoleBulkToggles.allSatisfy { !$0.toggle.isEnabled })
    }

    private func smokeTestRapidConsoleToggles() {
        let saved = (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay, consoleSystems, consolesLoaded, consolesChecking)
        defer {
            (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay) = (saved.0, saved.1, saved.2, saved.3)
            consoleSaveTimer?.invalidate()
            consoleSaveTimer = nil
            consolePersistedEnabled = nil
            consoleSaveDirty = false
            consoleStatus.stringValue = ""
            consoleSystems = saved.4
            consolesLoaded = saved.5
            consolesChecking = saved.6
            renderSystems()
        }
        var saves: [(enabled: Set<String>, done: (Int32, String) -> Void)] = []
        var refreshes: [(Int32, Data) -> Void] = []
        var disk: Set<String> = []
        consoleSaver = { _, enabled, done in saves.append((Set(enabled), done)) }
        consoleRefresher = { _, done in refreshes.append(done) }
        consoleRoot = { "/smoke" }
        consoleSaveDelay = 60
        consolesLoaded = true
        consolesChecking = false
        consolePersistedEnabled = nil
        // Fixture readiness: release runners have no emulators installed; the deferred restore puts real state back.
        for index in consoleSystems.indices { consoleSystems[index].emulator_installed = true }
        renderSystems()
        window.contentView!.layoutSubtreeIfNeeded()
        let scroll = tabs.selectedTabViewItem!.view as! NSScrollView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(120, max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height))))
        let offset = scroll.contentView.bounds.origin
        disk = Set(consoleSystems.filter(\.enabled).map(\.id))
        let rowsBefore = consoleRows.arrangedSubviews.map(ObjectIdentifier.init)
        let switchesBefore = systemSwitches.map(ObjectIdentifier.init)
        let ready = consoleSystems.indices.filter { index in
            let system = consoleSystems[index]
            return (system.emulator_installed ?? appStates.first { $0.id == system.package }?.installed) != false
        }
        precondition(ready.count >= 3, "Smoke data needs three ready consoles")
        let (a, b, c) = (ready[0], ready[1], ready[2])
        func flip(_ index: Int) {
            let toggle = systemSwitches[index]
            toggle.state = toggle.state == .on ? .off : .on
            toggleSystem(toggle)
        }
        func current() -> Set<String> { Set(consoleSystems.filter(\.enabled).map(\.id)) }
        func switchesMatch() -> Bool { zip(consoleSystems, systemSwitches).allSatisfy { ($0.enabled ? NSControl.StateValue.on : .off) == $1.state } }
        func toggled(_ set: Set<String>, _ index: Int) -> Set<String> {
            let id = consoleSystems[index].id
            return set.contains(id) ? set.subtracting([id]) : set.union([id])
        }
        let ids = (consoleSystems[a].id, consoleSystems[b].id, consoleSystems[c].id)
        let indexOf = { (id: String) in self.consoleSystems.firstIndex { $0.id == id }! }
        flip(a); flip(b); flip(a)
        let first = toggled(disk, indexOf(ids.1))
        precondition(saves.isEmpty && current() == first && switchesMatch(), "Toggles apply instantly; saving waits for a pause")
        precondition(systemSwitches.allSatisfy(\.isEnabled) && task == nil, "Toggling never blocks other switches")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore &&
                     systemSwitches.map(ObjectIdentifier.init) == switchesBefore, "Toggles must not rebuild the list")
        saveSystems()
        precondition(saves.count == 1 && saves[0].enabled == first, "One coalesced save with the latest choices")
        flip(indexOf(ids.2))
        let second = toggled(first, indexOf(ids.2))
        precondition(systemSwitches.allSatisfy(\.isEnabled), "Switches stay usable while saving")
        saveSystems()
        precondition(saves.count == 1, "Saves are serialized")
        disk = saves[0].enabled
        saves[0].done(0, "")
        precondition(saves.count == 2 && saves[1].enabled == second && refreshes.isEmpty,
                     "A change made during a save is saved next; no refresh while newer intent is pending")
        disk = saves[1].enabled
        saves[1].done(0, "")
        precondition(refreshes.count == 1 && consolePersistedEnabled == second)
        flip(indexOf(ids.2))
        func json(_ enabled: Set<String>) -> Data {
            try! JSONSerialization.data(withJSONObject: consoleSystems.map {
                ["id": $0.id, "name": $0.name, "enabled": enabled.contains($0.id), "package": $0.package,
                 "requirement": $0.requirement, "emulator_installed": $0.emulator_installed ?? true] as [String: Any]
            })
        }
        refreshes[0](0, json(second))
        precondition(current() == first && switchesMatch(), "A late refresh must not undo a newer toggle")
        saveSystems()
        precondition(saves.count == 3 && saves[2].enabled == first)
        saves[2].done(1, "Disk is read-only\n")
        precondition(current() == disk && switchesMatch() && consoleStatus.stringValue.hasPrefix("Couldn't save console selection"),
                     "A failed save shows the last saved choices and an explicit error")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore, "Reverting must not rebuild the list")
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.origin == offset, "Toggling must keep the scroll position")
        // Restart: a fresh load shows exactly what was last saved.
        consoleSystems = try! JSONDecoder().decode([ConsoleSystem].self, from: json(disk))
        renderSystems()
        precondition(current() == second && switchesMatch(), "After restart the last saved selection is shown")
    }

    /// Release never pops the Activity log on its own; problems surface in the app instead.
    private func smokeTestActivityStaysClosed() {
        precondition(!SetupController.activityAutoOpens || ProcessInfo.processInfo.environment["COUCH_CUBE_DEBUG_ACTIVITY"] == "1")
        guard !SetupController.activityAutoOpens else { return }
        let open = logWindow?.isVisible == true
        activityNeeded("Smoke problem")
        activityNeeded()
        precondition(lastProblemNotice == "Smoke problem")
        precondition((logWindow?.isVisible == true) == open, "Problems and operations must not open Activity")
        precondition(logWindow?.isRestorable != true, "Activity must not be restored at launch")
    }

    /// Windows launcher installers: download-only rows with real progress, never run and never claimed installed.
    private func smokeTestStoreAccounts() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func row(_ id: String) -> NSView { storeAccountsRows.arrangedSubviews.first { $0.identifier?.rawValue == "store-row-" + id }! }
        func status(_ id: String) -> String {
            views(row(id)).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "storeAccountStatus" }!.stringValue
        }
        func button(_ root: NSView, _ title: String) -> NSButton { views(root).compactMap { $0 as? NSButton }.first { $0.title == title }! }
        let fixture = Data("""
        {"clients":[
         {"id":"mac-steam","name":"Steam","state":"signed_in","detail":"Signed in as Gamer (gamer1)","platform":"Mac","kind":"mac",
          "accounts":[{"account":"gamer1","persona":"Gamer","most_recent":true},{"account":"kid","persona":null,"most_recent":false}]},
         {"id":"win-steam","name":"Steam (Windows)","state":"not_signed_in","detail":"Installed \\u2014 not signed in yet","platform":"Windows",
          "kind":"wine","host":"CrossOver","bottle":"Games","accounts":[]},
         {"id":"win-epic","name":"Epic Games Launcher","state":"installed","detail":"Installed \\u2014 sign in inside the launcher",
          "platform":"Windows","kind":"wine","host":"Whisky","bottle":"B1","accounts":[]},
         {"id":"win-gog","name":"GOG Galaxy","state":"not_installed","detail":"Not installed","platform":"Windows","kind":"wine","accounts":[]}
        ],"installed":3,"signed_in":1}
        """.utf8)
        let savedRead = storeAccountsRead, savedOpen = storeClientOpen
        defer { storeAccountsRead = savedRead; storeClientOpen = savedOpen; storeWalkthrough = nil }
        // State machine: stale replies are ignored and a failed check keeps the last good report.
        var model = StoreAccountsModel()
        precondition(model.summary.hasPrefix("Checking"))
        let first = model.begin(), second = model.begin()
        let report = try! JSONDecoder().decode(StoreAccountsReport.self, from: fixture)
        precondition(!model.finish(first, report: report, at: Date()) && model.phase == .checking, "A stale check must not land")
        precondition(model.finish(second, report: report, at: Date()) && model.phase == .loaded && model.summary == "1 of 3 signed in")
        _ = model.begin()
        precondition(model.finish(model.generation, report: nil, at: Date()) && model.phase == .failed && model.report == report)
        // Reads happen only when asked; replies may arrive later.
        var reads = 0
        var pending: [(Int32, Data) -> Void] = []
        storeAccountsRead = { reads += 1; pending.append($0) }
        loadStoreAccounts()
        precondition(storeAccounts.phase == .checking && storeAccountsSummary.stringValue.hasPrefix("Checking"))
        pending.removeFirst()(0, fixture)
        precondition(reads == 1 && storeAccountsSummary.stringValue == "1 of 3 signed in")
        precondition(storeAccountsRows.arrangedSubviews.filter { $0.identifier?.rawValue.hasPrefix("store-row-") == true }.count == 4)
        precondition(status("mac-steam").contains("Signed in as Gamer (gamer1)") && status("mac-steam").contains("1 more account"))
        precondition(status("win-steam").contains("CrossOver bottle"))
        precondition(status("win-epic").hasPrefix("Installed \u{2014} sign in inside the launcher"))
        precondition(status("win-gog") == "Not installed" && button(row("win-gog"), "App Store").isEnabled)
        // Open waits for the client to quit, guards duplicates, then checks again once.
        var opens: [String] = []
        var finishOpen: ((Int32) -> Void)?
        storeClientOpen = { id, done in opens.append(id); finishOpen = done }
        button(row("win-epic"), "Open").performClick(nil)
        precondition(opens == ["win-epic"] && status("win-epic").hasPrefix("Waiting for Epic Games Launcher to quit"))
        precondition(!button(row("win-epic"), "Open").isEnabled)
        openStoreClient(button(row("win-epic"), "Open"))
        precondition(opens == ["win-epic"], "A client that's already open isn't launched twice")
        finishOpen!(0)
        precondition(reads == 2 && storeAccounts.phase == .checking)
        pending.removeFirst()(0, fixture)
        precondition(storeAccounts.phase == .loaded && storeAccountsError == nil)
        storeClientOpen = { _, done in done(1) }
        button(row("mac-steam"), "Open").performClick(nil)
        pending.removeFirst()(1, Data())
        precondition(storeAccountsError?.hasPrefix("Couldn't open Steam") == true && storeAccounts.report == report,
                     "A failed launch or check keeps the last known status and explains it inline")
        storeAccountsError = nil
        // Guided walkthrough: installed clients only, one at a time, skippable, with a summary.
        storeClientOpen = { id, done in opens.append(id); done(0) }
        startStoreWalkthrough()
        func step() -> String {
            views(storeWalkthroughPanel).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "storeWalkthroughStep" }!.stringValue
        }
        precondition(storeWalkthrough?.ids == ["mac-steam", "win-steam", "win-epic"] && step().hasPrefix("Step 1 of 3: Steam"))
        button(storeWalkthroughPanel, "Next").performClick(nil)
        precondition(step().hasPrefix("Step 2 of 3: Steam (Windows)"))
        button(storeWalkthroughPanel, "Open Steam (Windows)").performClick(nil)
        precondition(opens.last == "win-steam")
        pending.removeFirst()(0, fixture)
        precondition(step().hasPrefix("Step 2 of 3"), "Returning from a client keeps the walkthrough on its step")
        button(storeWalkthroughPanel, "Skip").performClick(nil)
        button(storeWalkthroughPanel, "Next").performClick(nil)
        precondition(step() == "Done \u{2014} 1 of 3 signed in. Skipped: Steam (Windows).")
        button(storeWalkthroughPanel, "Done").performClick(nil)
        precondition(storeWalkthroughPanel.isHidden && pending.isEmpty)
    }

    private func smokeTestWindowsDownloads() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func row(_ id: String) -> NSView? { appWindowsRows.arrangedSubviews.first { $0.identifier?.rawValue == "win-row-" + id } }
        func statusText(_ id: String) -> String {
            let status = views(row(id)!).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { ($0 as? NSTextField)?.stringValue }.joined()
        }
        func dot(_ id: String) -> NSColor? {
            let status = views(row(id)!).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { $0 as? NSImageView }.first?.contentTintColor
        }
        func button(_ id: String, _ title: String) -> NSButton? {
            views(row(id)!).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func spinner(_ id: String) -> NSProgressIndicator? { views(row(id)!).compactMap { $0 as? NSProgressIndicator }.first }
        precondition(windowsDownloadProgress("PROGRESS 5 10")! == (5, 10) && windowsDownloadProgress("PROGRESS -1 10") == nil &&
                     windowsDownloadProgress("RESULT {}") == nil)
        precondition(backendErrorMessage("x\nERROR: Drive gone\n", fallback: "f") == "Drive gone")
        let saved = (windowsDownloads, windowsDownloadJobs, windowsLibrary, windowsDownloadsRead, windowsDownloadRun,
                     collapsedAppCategories, appOperations)
        defer {
            (windowsDownloads, windowsDownloadJobs, windowsLibrary, windowsDownloadsRead, windowsDownloadRun,
             collapsedAppCategories, appOperations) = saved
            renderApps()
            renderGeneral()
        }
        let ids = ["win-steam", "win-epic-games", "win-gog-galaxy", "win-ea", "win-battle-net"]
        var library: String? = nil
        var downloaded: [String: String] = [:]
        func reply() -> Data {
            let items = ids.map { id -> String in
                let file = downloaded[id].map { "\"\($0)\"" } ?? "null"
                return "{\"id\":\"\(id)\",\"name\":\"\(id) (Windows)\",\"vendor\":\"Vendor\",\"kind\":\"\(id == "win-epic-games" ? "msi" : "exe")\"," +
                    "\"downloaded\":\(downloaded[id] != nil),\"file\":\(file),\"size\":\(downloaded[id] != nil ? "2380800" : "null"),\"sha256\":null}"
            }
            return Data(("{\"library\":" + (library.map { "\"\($0)\"" } ?? "null") + ",\"folder\":null,\"items\":[" +
                         items.joined(separator: ",") + "]}").utf8)
        }
        var heldRead: ((Int32, Data) -> Void)?
        var holdRead = false
        windowsDownloadsRead = { done in if holdRead { heldRead = done } else { done(0, reply()) } }
        var runs: [String] = [], lineOut: ((String) -> Void)?, finish: ((Int32, String) -> Void)?, canceled: [String] = []
        windowsDownloadRun = { id, line, done in
            runs.append(id); lineOut = line; finish = done
            return { canceled.append(id) }
        }
        collapsedAppCategories = []
        appOperations = [:]
        loadWindowsDownloads()
        precondition(ids.allSatisfy { row($0) != nil }, "Windows launchers are listed under Windows games")
        precondition(button("win-steam", "Get")?.isEnabled == false, "Without a game library there is nowhere to download")
        library = "/Volumes/Smoke/Couch Cube"
        loadWindowsDownloads()
        precondition(button("win-steam", "Get")?.isEnabled == true && statusText("win-steam") == "Not downloaded")

        // Get starts the download at once; real byte progress drives a determinate indicator.
        getWindowsDownload(button("win-steam", "Get")!)
        precondition(runs == ["win-steam"] && spinner("win-steam")?.isIndeterminate == true && statusText("win-steam") == "Downloading\u{2026}")
        lineOut!("PROGRESS 50 100")
        precondition(spinner("win-steam")?.isIndeterminate == false && spinner("win-steam")?.doubleValue == 0.5)
        precondition(statusText("win-steam") == "Downloading \u{00B7} 50%")
        precondition(appOperations["steam"] == nil, "The Mac Steam app has its own, separate state")
        if let macSteam = appPCRows.arrangedSubviews.first(where: { $0.identifier?.rawValue == "app-row-steam" }) {
            precondition(!views(macSteam).contains { $0 is NSProgressIndicator })
        }
        renderGeneral()
        precondition(!sidebarTasks.contains { $0.title.contains("Windows") || $0.title.contains("win-") },
                     "Undownloaded Windows launchers aren't maintenance tasks")
        downloaded["win-steam"] = "/Volumes/Smoke/Couch Cube/Downloads/SteamSetup.exe"
        finish!(0, "")
        precondition(windowsDownloadJobs["win-steam"] == nil && statusText("win-steam") == "Downloaded" && dot("win-steam") == .systemGreen)
        precondition(button("win-steam", "Show in Finder") != nil && spinner("win-steam") == nil)
        precondition(views(row("win-steam")!).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("Not run or installed") },
                     "Downloaded never claims installed")

        // A failed run shows the backend's reason with Retry; nothing is green.
        getWindowsDownload(button("win-ea", "Get")!)
        finish!(1, "ERROR: The connection dropped during the download. Nothing was saved.\n")
        precondition(statusText("win-ea") == "Couldn't download" && dot("win-ea") == .systemRed && button("win-ea", "Retry") != nil)
        precondition(views(row("win-ea")!).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.hasPrefix("The connection dropped") })
        // Success that the status check can't confirm is a failure, not green.
        getWindowsDownload(button("win-gog-galaxy", "Get")!)
        finish!(0, "")
        precondition(statusText("win-gog-galaxy") == "Couldn't download" && dot("win-gog-galaxy") != .systemGreen)
        // Cancel stops the backend and returns to Get.
        getWindowsDownload(button("win-battle-net", "Get")!)
        let cancel = views(row("win-battle-net")!).compactMap { $0 as? NSButton }.first { $0.action == #selector(cancelWindowsDownload(_:)) }!
        cancelWindowsDownload(cancel)
        precondition(canceled == ["win-battle-net"])
        finish!(15, "")
        precondition(windowsDownloadJobs["win-battle-net"] == nil && statusText("win-battle-net") == "Not downloaded" &&
                     button("win-battle-net", "Get") != nil)
        // A second press while running doesn't start a duplicate.
        getWindowsDownload(button("win-epic-games", "Get")!)
        let started = runs.count
        windowsDownloadJobs["win-epic-games"].map { _ in getWindowsDownload({ let b = NSButton(); b.tag = 1; return b }()) }
        precondition(runs.count == started)
        // Library changes cancel running downloads before touching storage.
        canceled = []
        for (id, job) in windowsDownloadJobs where job.running { cancelWindowsDownload(id: id) }
        precondition(canceled == ["win-epic-games"])
        finish!(15, "")
        // An older status read can't revert a newer result.
        holdRead = true
        loadWindowsDownloads()
        let stale = heldRead!
        holdRead = false
        loadWindowsDownloads()
        downloaded["win-steam"] = nil
        stale(0, reply())
        precondition(statusText("win-steam") == "Downloaded")
        // Collapsed category keeps downloaded and failed rows, hides untouched ones.
        collapsedAppCategories = ["Windows games"]
        renderApps()
        precondition(row("win-steam") != nil && row("win-ea") != nil && row("win-epic-games") == nil)
        precondition(logWindow?.isVisible != true, "Downloads must not open Activity")
    }

    /// App Store rows: spinner while working, real phases, and green only after a targeted re-check confirms it.
    private func smokeTestAppOperations() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func appRow() -> NSView? { views(appPCRows.superview ?? appPCRows).first { $0.identifier?.rawValue == "app-row-dolphin" }
            ?? views(appRetroRows).first { $0.identifier?.rawValue == "app-row-dolphin" } }
        func statusDot(_ row: NSView) -> NSColor? {
            let status = views(row).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { $0 as? NSImageView }.first?.contentTintColor
        }
        func statusText(_ row: NSView) -> String {
            let status = views(row).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { ($0 as? NSTextField)?.stringValue }.joined()
        }
        func progress(_ row: NSView) -> NSProgressIndicator? { views(row).compactMap { $0 as? NSProgressIndicator }.first }
        func reply(_ app: ManagedApp) -> Data {
            Data(("[{\"id\":\"\(app.id)\",\"name\":\"\(app.name)\",\"installed\":\(app.installed),\"path\":\"\(app.path)\"," +
                  "\"version\":\"\(app.version)\",\"brew\":true,\"managed\":\(app.managed),\"update\":" +
                  (app.update.map { "\"\($0)\"" } ?? "null") + ",\"manual\":false,\"url\":null}]").utf8)
        }
        precondition(task == nil)
        let saved = (appStates, appOperations, appOperationRun, appVerifyRead, backendRead, appsHaveResults, lastAppsData,
                     collapsedAppCategories, appsStatus.stringValue)
        defer {
            (appStates, appOperations, appOperationRun, appVerifyRead, backendRead, appsHaveResults, lastAppsData,
             collapsedAppCategories, appsStatus.stringValue) = saved
            appOperationOutput = nil
            renderApps()
            renderGeneral()
        }
        precondition(appOperationPhase("==> Downloading https://example\n==> Upgrading Cask dolphin", action: "update") == "Updating")
        precondition(appOperationPhase("==> Fetching downloads for: dolphin", action: "install") == "Downloading")
        precondition(appOperationPhase("Already installed\n", action: "install") == nil, "No phase is invented")
        let outdated = ManagedApp(id: "dolphin", name: "Dolphin", installed: true, path: "/Applications/Dolphin.app", version: "1",
                                  managed: true, update: "2", manual: false, brew: true, url: nil)
        let current = ManagedApp(id: "dolphin", name: "Dolphin", installed: true, path: "/Applications/Dolphin.app", version: "2",
                                 managed: true, update: nil, manual: false, brew: true, url: nil)
        appStates = appStates.filter { $0.id != "dolphin" } + [outdated]
        appsHaveResults = true
        renderApps()
        renderGeneral()
        precondition(sidebarTasks.contains { $0.title == "Update Dolphin" })
        window.contentView!.layoutSubtreeIfNeeded()
        let before = appRow()!.fittingSize.height
        precondition(statusDot(appRow()!) == .systemYellow && progress(appRow()!) == nil)

        // A full app check that started earlier must not revert the verified result.
        var staleFetch: ((Int32, Data) -> Void)?
        backendRead = { _, done in staleFetch = done }
        fetchApps(updates: false)
        var runDone: ((Int32) -> Void)?
        var ran: [[String]] = []
        appOperationRun = { arguments, done in ran.append(arguments); runDone = done }
        var verifyReply = reply(current)
        var verifyDone: ((Int32, Data) -> Void)?
        appVerifyRead = { arguments, done in
            precondition(arguments == ["apps", "--updates", "--package", "dolphin"], "Only the changed app is re-checked")
            verifyDone = done
        }
        runAppOperation(outdated, action: "update")
        precondition(ran == [["manage-app", "--package", "dolphin", "--action", "update", "--confirm"]])
        var line = appRow()!
        precondition(progress(line)?.isIndeterminate == true, "Homebrew gives no real percentage, so the spinner is indeterminate")
        precondition(!views(line).contains { ($0 as? NSPopUpButton) != nil }, "The spinner replaces the ... button")
        precondition(statusText(line).hasPrefix("Updating") && statusDot(line) == .systemBlue)
        appOperationOutput?("==> Downloading https://example.invalid/dolphin.dmg\n")
        line = appRow()!
        precondition(statusText(line) == "Updating · Downloading\u{2026}")
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(abs(line.fittingSize.height - before) < 1, "Row height stays stable while updating")
        runDone!(0)
        precondition(statusText(appRow()!).contains("Checking") && progress(appRow()!) != nil, "Green waits for verification")
        verifyDone!(0, verifyReply)
        line = appRow()!
        precondition(statusDot(line) == .systemGreen && statusText(line) == "Installed" && progress(line) == nil)
        precondition(appOperations["dolphin"] == nil && !sidebarTasks.contains { $0.title == "Update Dolphin" })
        precondition(updateAllButton.isHidden || appStates.contains { $0.id != "dolphin" && $0.update?.isEmpty == false })
        staleFetch?(0, Data(("[" + String(decoding: reply(outdated), as: UTF8.self).dropFirst().dropLast() + "]").utf8))
        precondition(statusDot(appRow()!) == .systemGreen, "A stale full refresh must not revert the verified state")

        // Homebrew succeeded but the re-check still sees the old version: not green, inline failure, retry stays available.
        appStates = appStates.filter { $0.id != "dolphin" } + [outdated]
        renderApps()
        verifyReply = reply(outdated)
        runAppOperation(outdated, action: "update")
        runDone!(0)
        verifyDone!(0, verifyReply)
        line = appRow()!
        precondition(statusDot(line) == .systemRed && statusText(line) == "Couldn't update" && progress(line) == nil)
        precondition(views(line).contains { $0 is NSPopUpButton }, "Update stays available to retry")
        // A failed Homebrew run is never shown as green, even if the re-check fails too.
        runAppOperation(outdated, action: "update")
        runDone!(1)
        verifyDone!(1, Data())
        line = appRow()!
        precondition(statusDot(line) != .systemGreen && statusText(line) == "Couldn't confirm the update")

        // Steam is one app listed twice (TV menus: Steam Big Picture, PC games: Steam): both rows share one state.
        func steamRows() -> [(NSStackView, NSView)] {
            [appMenuRows, appPCRows, appWindowsRows, appRetroRows].flatMap { rows in
                rows.arrangedSubviews.filter { $0.identifier?.rawValue == "app-row-steam" }.map { (rows, $0) } }
        }
        func steam(installed: Bool, update: String? = nil) -> ManagedApp {
            ManagedApp(id: "steam", name: "Steam", installed: installed, path: installed ? "/Applications/Steam.app" : "",
                       version: installed ? "1" : "", managed: true, update: update, manual: false, brew: true, url: nil)
        }
        appVerifyRead = { arguments, done in
            precondition(arguments == ["apps", "--updates", "--package", "steam"], "Steam is re-checked once for both rows")
            verifyDone = done
        }
        collapsedAppCategories = []
        appStates = appStates.filter { $0.id != "steam" } + [steam(installed: true, update: "2")]
        renderApps()
        renderGeneral()
        precondition(steamRows().map { $0.0 } == [appMenuRows, appPCRows], "Steam is listed under TV menus and PC games")
        precondition(sidebarTasks.filter { $0.title == "Update Steam" }.count == 1, "The App Store badge counts Steam once")
        precondition(Set(steamRows().map { statusText($0.1) }).count == 1)
        for (rows, line) in steamRows() {
            precondition(views(line).compactMap { $0 as? NSTextField }.contains { $0.stringValue == (rows === appMenuRows ? "Steam Big Picture" : "Steam") })
        }
        // Start from the PC games row; the TV menu row shows the same spinner and phase, and can't start a second run.
        ran = []
        runAppOperation(appStates.first { $0.id == "steam" }!, action: "update")
        appOperationOutput?("==> Downloading https://example.invalid/steam.dmg\n")
        precondition(steamRows().allSatisfy { progress($0.1) != nil && statusText($0.1) == "Updating \u{00B7} Downloading\u{2026}" })
        precondition(steamRows().allSatisfy { !views($0.1).contains { $0 is NSButton && ($0 as! NSButton).isEnabled } })
        runAppOperation(appStates.first { $0.id == "steam" }!, action: "update")
        precondition(ran.count == 1 && appsStatus.stringValue.hasPrefix("Wait"), "A second Steam row can't start a duplicate run")
        runDone!(0)
        verifyDone!(0, reply(steam(installed: true)))
        renderGeneral()
        precondition(steamRows().count == 2 && steamRows().allSatisfy { statusDot($0.1) == .systemGreen && statusText($0.1) == "Installed" })
        precondition(!sidebarTasks.contains { $0.title == "Update Steam" })
        // A failure shows on both rows, with Retry on both.
        appStates = appStates.filter { $0.id != "steam" } + [steam(installed: false)]
        renderApps()
        runAppOperation(steam(installed: false), action: "install")
        runDone!(1)
        verifyDone!(0, reply(steam(installed: false)))
        precondition(steamRows().count == 2 && steamRows().allSatisfy {
            statusDot($0.1) == .systemRed && views($0.1).contains { ($0 as? NSButton)?.title == "Retry" } })
        // Installing from the TV menu row while PC games is collapsed: the PC games row appears once Steam is installed.
        collapsedAppCategories = ["PC games"]
        appOperations["steam"] = nil
        renderApps()
        precondition(steamRows().map { $0.0 } == [appMenuRows])
        runAppOperation(steam(installed: false), action: "install")
        runDone!(0)
        verifyDone!(0, reply(steam(installed: true)))
        precondition(steamRows().map { $0.0 } == [appMenuRows, appPCRows] && steamRows().allSatisfy { statusDot($0.1) == .systemGreen })
        precondition(logWindow?.isVisible != true, "App updates must not open Activity")
    }

    private func assertSmokeDeals() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        let page = tabs.selectedTabViewItem!.view!
        precondition(dealsOpened, "Cube Shop must load only once its page opens")
        precondition(screenTitle.stringValue == "Cube Shop")
        let defaults = UserDefaults.standard
        let shopKeys = [shopTabKey, shopScopeKey, shopCurrencyKey, shopFeeKey]
        let savedShop = shopKeys.map { defaults.object(forKey: $0) }
        // Cube Shop always opens on Home, even after another tab was used; other tabs keep their state.
        precondition(shopTab.selectedSegment == 0 && !homePane.isHidden, "Cube Shop opens on Home")
        selectShopTab(4)
        selectPage(0)
        selectPage(13)
        precondition(shopTab.selectedSegment == 0 && !homePane.isHidden && wishlistPane.isHidden && shopNav.selectedSegment == 0,
                     "Reopening Cube Shop starts on Home again")
        selectShopTab(4)
        precondition(!wishlistPane.isHidden && shopNav.selectedSegment == 3)
        selectShopTab(0)
        defaults.set("original", forKey: shopCurrencyKey)
        defaults.removeObject(forKey: shopFeeKey)
        rerenderShop()
        // URL safety: only https links on the services' own hosts open.
        precondition(safeDealURL("https://www.cheapshark.com/redirect?dealID=a", hosts: cheapSharkHosts) != nil)
        precondition(safeDealURL("http://www.cheapshark.com/redirect?dealID=a", hosts: cheapSharkHosts) == nil)
        precondition(safeDealURL("https://www.cheapshark.com.evil.example/x", hosts: cheapSharkHosts) == nil)
        precondition(safeDealURL("https://user@www.gamerpower.com/x", hosts: gamerPowerHosts) == nil)
        precondition(safeDealURL("steam://run/620", hosts: cheapSharkHosts) == nil)
        precondition(safeDealURL("javascript:alert(1)") == nil)
        precondition(dealsErrorText("ERROR: rate-limited:90").contains("2 min"))
        let savedTab = shopTab.selectedSegment, savedOpener = dealsOpener
        var opened: [URL] = []
        dealsOpener = { opened.append($0) }
        defer {
            dealsOpener = savedOpener
            for (key, value) in zip(shopKeys, savedShop) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            updateCurrencyNotes()
            selectShopTab(savedTab)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        selectShopTab(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(storeDeals.count == 4 && dealsStorePopup.numberOfItems == 3, "Store deals and store filter must render")
        precondition(!dealsFilters.arrangedSubviews.contains(dealsSearch) && dealsSearch.superview == nil && dealsFilters.arrangedSubviews.contains(dealsStatus) && dealsFilters.arrangedSubviews.contains(dealsSortPopup) && dealsStorePopup.itemTitles.first == "Any Store", "Deals: status, store and Sort by on one line; no second search field")
        var text = labels(page)
        precondition(text.contains("Portal 2") && text.contains("$1.99") && text.contains("$9.99") && text.contains { $0.hasSuffix("\u{2212}80%") })
        precondition(labels(dealsList).filter { $0.contains("Installed") }.count == 1, "Only the Steam-appID-matched deal is marked Installed")
        precondition(!dealsMore.isHidden, "More pages must offer Load More")
        let opens = views(dealsList).compactMap { $0 as? ClickableRowView }
        precondition(opens.count == 4, "Every deal row is one clickable row")
        precondition(opens.allSatisfy { $0.accessibilityRole() == .link && ($0.accessibilityLabel() ?? "").hasPrefix("Open ") })
        precondition(views(dealsList).compactMap { $0 as? NSButton }.allSatisfy { ["wishlistHeart", "shopTarget"].contains($0.accessibilityIdentifier()) },
                     "Deal rows have no buttons except Set Target and the wishlist heart")
        precondition(views(dealsList).filter { $0.accessibilityIdentifier() == "shopTarget" }.count == 4
                     && views(dealsList).filter { $0.accessibilityIdentifier() == "shopStoreTag" }.count == 4,
                     "Every deal row has Set Target and its store under the price")
        opens.forEach { $0.activate() }
        precondition(opened.map(\.absoluteString) == ["abc", "lng", "mc"].map { "https://www.cheapshark.com/redirect?dealID=" + $0 },
                     "Off-host deal links must never open")
        let attribution = views(page).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "dealsAttribution" }!
        let links = NSMutableSet()
        attribution.attributedStringValue.enumerateAttribute(.link, in: NSRange(location: 0, length: attribution.attributedStringValue.length)) { value, _, _ in
            if let value { links.add("\(value)") }
        }
        precondition(links.contains("https://www.gamerpower.com") && links.contains("https://www.cheapshark.com") &&
                     links.contains("https://frankfurter.dev") && links.contains("https://performance-partners.apple.com/search-api"),
                     "Attribution must link every data source")
        // A stale reply from a mode the user already left is ignored.
        let generation = dealsGeneration
        selectShopTab(2)
        precondition(dealsGeneration > generation)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        text = labels(dealsList)
        precondition(giveaways.count == 1 && text.contains("Free Adventure") && text.contains("Free") && !text.contains("Portal 2"))
        precondition(dealsFilters.arrangedSubviews.contains(giveawayPlatformPopup) && dealsFilters.arrangedSubviews.contains(giveawayTypePopup))
        precondition(dealsMore.isHidden)
        opened = []
        views(dealsList).compactMap { $0 as? ClickableRowView }.forEach { $0.activate() }
        precondition(opened.map(\.host) == ["www.gamerpower.com"])
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(dealsList.frame.width > 300, "Deal rows must use the page width")
        smokeTestDealReminders(opened: { opened })
        smokeTestCubeShop(opened: { opened })
        // Badges wrap instead of clipping, even at the narrowest window.
        selectShopTab(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let savedFrame = window.frame
        window.setContentSize(window.contentMinSize)
        window.contentView!.layoutSubtreeIfNeeded()
        for row in views(dealsList).compactMap({ $0 as? ClickableRowView }) {
            for badge in views(row).compactMap({ $0 as? NSTextField }).filter({ $0.accessibilityIdentifier() == "dealBadges" }) {
                let frame = badge.convert(badge.bounds, to: row)
                precondition(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Deal badges must stay inside their row")
                precondition(badge.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: badge.bounds.width, height: .greatestFiniteMagnitude)).height <= badge.bounds.height + 1,
                             "Deal badges must wrap, not clip")
            }
        }
        window.setFrame(savedFrame, display: false)
    }

    private func smokeTestCubeShop(opened: () -> [URL]) {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        func spin(_ seconds: Double = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func calls(_ command: String) -> [[String]] { smokeShopCalls.filter { $0.first == command } }
        func heart(_ key: String) -> NSButton? {
            views(shopPageView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistHeart" && $0.identifier?.rawValue == key }
        }
        let defaults = UserDefaults.standard
        let savedWishlist = smokeWishlist, savedStores = myStores, savedAsk = askTargetPrice
        defer {
            smokeWishlist = savedWishlist
            smokeWishlistOffline = false
            askTargetPrice = savedAsk
            myStores = savedStores
            defaults.set("original", forKey: shopCurrencyKey)
            defaults.removeObject(forKey: shopFeeKey)
            updateScopeHint()
            rerenderShop()
        }
        // Money: Decimal math through EUR, HUF has no minor units, the fee applies only to conversions, free stays Free.
        // A fresh (unset) preference means Original prices, regardless of the Mac's locale.
        let savedCurrency = defaults.object(forKey: shopCurrencyKey)
        defaults.removeObject(forKey: shopCurrencyKey)
        precondition(shopCurrency == nil && shopPrice(11.99, "USD").text == "$11.99" && !shopPrice(11.99, "USD").converted,
                     "Cube Shop defaults to original prices")
        defaults.set("bogus", forKey: shopCurrencyKey)
        precondition(shopCurrency == nil, "An unknown saved currency falls back to original prices")
        defaults.set("HUF", forKey: shopCurrencyKey)
        precondition(shopCurrency == "HUF", "An explicit currency is kept")
        if let savedCurrency { defaults.set(savedCurrency, forKey: shopCurrencyKey) } else { defaults.removeObject(forKey: shopCurrencyKey) }
        let rates = decodeDeals(ExchangeRates.self, Data(smokeRatesJSON.utf8))!
        let price = ShopMoney.decimal(11.99)
        precondition(ShopMoney.convert(price, from: "USD", to: "HUF", rates: rates) == 3869)
        precondition(ShopMoney.convert(price, from: "USD", to: "HUF", rates: rates, feePercent: 1) == 3907)
        precondition(ShopMoney.convert(price, from: "USD", to: "EUR", rates: rates) == ShopMoney.decimal(10.65))
        precondition(ShopMoney.convert(price, from: "USD", to: "USD", rates: rates, feePercent: 1) == price)
        precondition(ShopMoney.convert(price, from: "USD", to: "XXX", rates: rates) == nil &&
                     ShopMoney.convert(price, from: "USD", to: "HUF", rates: rates, feePercent: 25) == nil)
        precondition(ShopMoney.plain(price, "USD") == "11.99 USD" && ShopMoney.plain(3869, "HUF") == "3869 HUF")
        precondition(shopPrice(0, "USD").text == "Free")
        // PC stores only: no console or phone platforms anywhere in the filters.
        let platforms = giveawayPlatformPopup.itemTitles.joined(separator: " ")
        for banned in ["PlayStation", "Xbox", "Switch", "Android", "iOS"] { precondition(!platforms.contains(banned), "No \(banned) giveaways") }
        // My Stores / All Stores is saved and sent as --mine.
        selectShopTab(1)
        spin()
        precondition(!shopScopeBar.isHidden)
        shopScope.selectedSegment = 0
        shopScopeChanged()
        precondition(defaults.string(forKey: shopScopeKey) == "mine" && dealsArguments().contains("--mine"))
        shopScope.selectedSegment = 1
        shopScopeChanged()
        precondition(defaults.string(forKey: shopScopeKey) == "all" && !dealsArguments().contains("--mine"))
        spin()
        myStores = []
        updateScopeHint()
        precondition(shopScope.selectedSegment == 1 && !shopScope.isEnabled(forSegment: 0) && shopScopeHint.stringValue.hasPrefix("No store apps"))
        myStores = [ShopStoreRef(key: "steam", name: "Steam")]
        shopScope.selectedSegment = 0
        shopScopeChanged()
        precondition(shopScope.isEnabled(forSegment: 0) && shopScopeHint.stringValue.contains("Steam"))
        // Home: wishlist hits, featured deals, price drops and free games, for the saved scope.
        smokeWishlist = [["key": "cs:612", "title": "Portal 2", "game_id": "612", "steam_app_id": "620", "app_store_id": NSNull(),
                          "added": 1_700_000_000, "target_price": 2.5, "thumb": "https://cdn.example.com/portal2.jpg",
                          "best": ["price": 1.99, "normal_price": 9.99, "savings": 80, "store": "Steam", "currency": "USD", "checked": 1_700_000_000],
                          "on_sale": true, "target_hit": true, "sale_text": "On sale at Steam \u{2212}80%",
                          "insight": ["kind": "record", "percent": NSNull(), "low": 1.99, "currency": "USD", "date": "2025-09-29"]]]
        checkWishlist(refresh: false)
        spin()
        precondition(wishlist?.items.count == 1 && calls("wishlist").last!.contains("--check"))
        shopHome = nil
        homeLoadedScope = nil
        selectShopTab(0)
        spin()
        precondition(shopScopeBar.isHidden == false && !homePane.isHidden && dealsPane.isHidden)
        precondition(calls("shop-home").last! == ["shop-home", "--scope", "mine"])
        let home = labels(homeList).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        for title in ["Wishlist deals", "Featured deals", "Price drops", "Free now", "Drop Game", "Free Adventure", "Steam \u{2212}80%"] {
            precondition(home.contains { $0 == title || $0.contains(title) }, "Home shows \(title)")
        }
        precondition(!home.contains { $0.contains("On sale at") }, "The sale tag shows only the store and discount")
        let saleRow = views(homeList).first { $0.accessibilityIdentifier() == "wishlistRow" }!
        precondition(labels(saleRow).filter { $0.contains("\u{2212}80%") } == ["Steam \u{2212}80%"], "The sale shows once, under the price, not under the title too: \(labels(saleRow))")
        precondition(views(saleRow).contains { ($0 as? NSTextField)?.stringValue == "All-time low" && $0.accessibilityIdentifier() == "shopPriceInsight" },
                     "Wishlist rows note the all-time low too")
        precondition(((saleRow.toolTip ?? "") + (saleRow.accessibilityLabel() ?? "")).contains("On sale at Steam \u{2212}80%"),
                     "The full sentence stays in the tooltip and VoiceOver: \(saleRow.toolTip ?? "") / \(saleRow.accessibilityLabel() ?? "")")
        // Hearts: saved items are filled; adding sends only the allowed keys; removing clears it.
        precondition(heart("cs:612")?.image?.name() == nil && heart("cs:612")?.accessibilityLabel() == "Remove Portal 2 from wishlist")
        precondition(heart("cs:700")?.accessibilityLabel() == "Add Drop Game to wishlist" && heart("cs:700")!.isEnabled)
        heart("cs:700")!.performClick(nil)
        spin()
        let add = calls("wishlist").last!
        precondition(add[1] == "--add")
        let payload = try! JSONSerialization.jsonObject(with: Data(add[2].utf8)) as! [String: String]
        precondition(payload == ["title": "Drop Game", "game_id": "700", "steam_app_id": "700", "thumb": "https://cdn.example.com/drop.jpg"],
                     "The heart saves the art link (not the image) with the game")
        precondition(wishlist?.items.count == 2 && heart("cs:700")?.accessibilityLabel() == "Remove Drop Game from wishlist")
        heart("cs:700")!.performClick(nil)
        spin()
        precondition(calls("wishlist").last! == ["wishlist", "--remove", "cs:700"] && wishlist?.items.count == 1)
        // Drive unplugged: the cached wishlist is read-only, with a note.
        smokeWishlistOffline = true
        checkWishlist(refresh: false)
        spin()
        let offlineCalls = calls("wishlist").count
        heart("cs:700")!.performClick(nil)
        precondition(wishlist?.offline == true && calls("wishlist").count == offlineCalls && !dealsReminderBar.isHidden &&
                     dealsReminderNote.stringValue.contains("isn't connected"), "A read-only heart explains itself and changes nothing")
        dealsReminderBar.isHidden = true
        selectShopTab(4)
        precondition(wishlistStatus.stringValue.contains("isn't connected") &&
                     views(wishlistList).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier() == "wishlistRemove" }.allSatisfy { !$0.isEnabled })
        smokeWishlistOffline = false
        checkWishlist(refresh: false)
        spin()
        // Wishlist rows: target price and removal go through the backend file.
        let rows = views(wishlistList).filter { $0.accessibilityIdentifier() == "wishlistRow" }
        precondition(rows.count == 1 && labels(wishlistList).contains { $0.replacingOccurrences(of: "\u{00A0}", with: " ").contains("Target reached") })
        // Each item shows its art (a cached link), its current best price and a target editor, even at the minimum width.
        window.contentView!.layoutSubtreeIfNeeded()
        let wishArt = views(rows[0]).compactMap { $0 as? RemoteImageView }
        precondition(wishArt.count == 1 && wishArt[0].source?.absoluteString == "https://cdn.example.com/portal2.jpg", "Wishlist rows show the game's art")
        precondition(labels(rows[0]).contains { $0.contains("1.99") }, "Wishlist rows show the current best price: \(labels(rows[0]))")
        let targetButton = { views(self.wishlistList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistTarget" }! }
        for view in [wishArt[0], targetButton()] as [NSView] {
            let frame = view.convert(view.bounds, to: rows[0])
            precondition(frame.width > 0 && frame.minX >= 0 && frame.maxX <= rows[0].bounds.width + 0.5, "\(view) fits the wishlist row: \(frame)")
        }
        askTargetPrice = { _, _, code in precondition(code == "USD", "Original prices: the target stays in its currency"); return .some(5) }
        targetButton().performClick(nil)
        spin()
        precondition(calls("wishlist").last! == ["wishlist", "--target", "cs:612", "--price", "5.00", "--currency", "USD"])
        // With HUF as the Shop currency, targets are entered in forints and the USD price is converted to compare.
        defaults.set("HUF", forKey: shopCurrencyKey)
        exchangeRates = try! JSONDecoder().decode(ExchangeRates.self, from: Data(smokeRatesJSON.utf8))
        renderWishlist()
        precondition(targetButton().accessibilityLabel() == "Set a target price in HUF for Portal 2")
        var askedCurrent: Double?? = .none
        askTargetPrice = { _, current, code in precondition(code == "HUF"); askedCurrent = current; return .some(4000) }
        targetButton().performClick(nil)
        spin()
        precondition(askedCurrent! == nil, "A USD target isn't shown as forints")
        precondition(calls("wishlist").last! == ["wishlist", "--target", "cs:612", "--price", "4000", "--currency", "HUF"])
        let saved = wishlist!.items[0]
        precondition(saved.targetPrice == 4000 && saved.targetCurrency == "HUF" && targetReached(saved) == true,
                     "1.99 USD is about 642 HUF, under a 4000 HUF target")
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
        precondition(labels(wishlistList).contains { plain($0).contains("Target reached: " + plain(ShopMoney.format(4000, "HUF"))) })
        askTargetPrice = { _, current, _ in askedCurrent = current; return .some(500) }
        targetButton().performClick(nil)
        spin()
        precondition(askedCurrent! == 4000 && targetReached(wishlist!.items[0]) == false, "642 HUF is above a 500 HUF target")
        precondition(!labels(wishlistList).contains { $0.contains("Target reached") } && labels(wishlistList).contains { plain($0).contains("Target " + plain(ShopMoney.format(500, "HUF"))) })
        let loadedRates = exchangeRates
        exchangeRates = nil
        renderWishlist()
        precondition(targetReached(wishlist!.items[0]) == nil && targetButton().isEnabled, "No rates: still editable, comparison unknown")
        precondition(views(wishlistList).contains { ($0.toolTip ?? "").contains("Can't compare with USD prices") }, "The row says why")
        exchangeRates = loadedRates
        askTargetPrice = { _, _, _ in .some(2.5) }
        defaults.set("original", forKey: shopCurrencyKey)
        targetButton().performClick(nil)
        spin()
        precondition(parseTargetPrice("4 000 Ft", "HUF") == 4000 && parseTargetPrice("4.000", "HUF") == 4000 &&
                     parseTargetPrice("9,99", "EUR") == 9.99 && parseTargetPrice("$9.99", "USD") == 9.99 && parseTargetPrice("", "USD") == nil)
        askTargetPrice = { _, _, _ in .none }
        let targets = calls("wishlist").count
        views(wishlistList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistTarget" }!.performClick(nil)
        precondition(calls("wishlist").count == targets, "Cancelling the target changes nothing")
        // Search: too short does nothing; typing is debounced; identical searches are combined.
        selectShopTab(3)
        let searches = calls("shop-search").count
        shopSearchField.stringValue = "h"
        shopSearchSubmitted()
        precondition(calls("shop-search").count == searches)
        shopSearchField.stringValue = "hollow knight"
        shopSearchTyped()
        shopSearchTyped()
        spin(0.3)
        precondition(calls("shop-search").count == searches, "Search waits for a pause in typing")
        spin(1.0)
        precondition(calls("shop-search").count == searches + 1)
        precondition(calls("shop-search").last!.starts(with: ["shop-search", "--query", "hollow knight", "--country"]))
        shopSearchSubmitted()
        spin()
        precondition(calls("shop-search").count == searches + 1, "An identical search reuses the loaded results")
        func offers() -> [String] {
            views(searchList).filter { $0.accessibilityIdentifier() == "shopOffer" }.compactMap { $0.accessibilityLabel() }
        }
        func order() -> [String] {
            offers().map { $0.replacingOccurrences(of: "Open Hollow Knight at ", with: "").components(separatedBy: ",")[0] }
        }
        // Original prices: USD stores by price, then the App Store group in its own currency.
        precondition(order() == ["GOG", "Steam", "Mac App Store"], "\(order())")
        precondition(offers().filter { $0.hasSuffix(", cheapest") }.count == 1 && offers()[0].hasSuffix(", cheapest"))
        precondition(labels(searchList).contains("Mac App Store") && labels(searchList).contains("Hollow Pocket") &&
                     views(searchList).contains { $0.toolTip?.hasSuffix("in HUF") ?? false })
        precondition(views(searchList).filter { $0.accessibilityIdentifier() == "shopAppStoreRow" }.count == 1)
        // Converted to USD, then HUF: every store sorts by the converted price, marked with ≈ and the original.
        defaults.set("USD", forKey: shopCurrencyKey)
        loadRates(refresh: false)
        spin()
        precondition(exchangeRates == rates && !shopCurrencyNote.isHidden && shopCurrencyNote.stringValue.contains("Frankfurter"),
                     "rates \(String(describing: exchangeRates)) loading \(ratesLoading) note \(shopCurrencyNote.stringValue)")
        rerenderShop()
        precondition(order() == ["GOG", "Mac App Store", "Steam"], "\(order())")
        precondition(offers()[1].contains("\u{2248}") && offers()[1].contains("(3990 HUF)") && !offers()[0].contains("\u{2248}"))
        precondition(shopPrice(3990, "HUF").value == ShopMoney.decimal(12.37))
        defaults.set("HUF", forKey: shopCurrencyKey)
        rerenderShop()
        precondition(order() == ["GOG", "Mac App Store", "Steam"], "\(order())")
        precondition(offers()[0].contains("\u{2248}") && offers()[0].contains("(9.99 USD)") && !offers()[1].contains("\u{2248}"))
        precondition(shopPrice(9.99, "USD").value == 3223 && shopPrice(3990, "HUF").value == 3990)
        let tips = views(searchList).compactMap { $0 as? NSTextField }.compactMap(\.toolTip)
        precondition(tips.contains { $0.hasSuffix("(9.99 USD)") }, "Converted prices show the original in the tooltip")
        defaults.set(1.0, forKey: shopFeeKey)
        precondition(shopPrice(11.99, "USD").value == 3907 && shopPrice(3990, "HUF").value == 3990, "The fee applies only to conversions")
        defaults.removeObject(forKey: shopFeeKey)
        // Rows open the default browser: CheapShark redirects and apps.apple.com only.
        let before = opened().count
        let shopRows = views(searchList).compactMap { $0 as? ClickableRowView }
        shopRows.forEach { $0.activate() }
        let hosts = Set(opened().dropFirst(before).compactMap(\.host))
        precondition(opened().count - before == shopRows.count && hosts == ["www.cheapshark.com", "apps.apple.com"], "\(hosts)")
        // Search groups: one parent row per game (art, title, heart, lowest price), stores indented beneath it, cheapest first.
        defaults.set("original", forKey: shopCurrencyKey)
        rerenderShop()
        window.contentView!.layoutSubtreeIfNeeded()
        let list = searchList.arrangedSubviews.filter { !($0 is NSBox) }
        let parentIndex = list.firstIndex { $0.accessibilityIdentifier() == "shopGameRow" }!
        let parent = list[parentIndex]
        let children = Array(list[(parentIndex + 1)...].prefix { $0.accessibilityIdentifier() == "shopOffer" })
        precondition(children.count == 3, "Every store sits under its game")
        precondition(searchList.arrangedSubviews[searchList.arrangedSubviews.firstIndex(of: parent)! + 1].accessibilityIdentifier() == "shopOffer",
                     "No separator between a game and its stores")
        precondition(views(parent).contains { $0 is RemoteImageView && $0.accessibilityIdentifier() == "shopArtwork" }, "Search games show their art")
        precondition(children.allSatisfy { child in !views(child).contains { $0 is RemoteImageView } && !labels(child).contains("Hollow Knight") },
                     "Store rows don't repeat the art or title")
        func art(_ row: NSView) -> NSRect { let a = views(row).first { ["shopArtwork", "shopStoreIcon"].contains($0.accessibilityIdentifier()) }!; return a.convert(a.bounds, to: searchList) }
        func leftmost(_ row: NSView) -> CGFloat {
            views(row).filter { ($0 is NSTextField || $0 is NSImageView) && $0.frame.width > 0 && !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.convert($0.bounds, to: searchList).minX }.min()!
        }
        precondition(children.allSatisfy { leftmost($0) >= art(parent).minX + Self.shopChildIndent - 0.5 }, "Store rows are indented")
        let lowest = children.map { child in views(child).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "shopLowest" }?.stringValue }
        precondition(lowest.compactMap { $0 }.count == 1 && lowest[0]?.replacingOccurrences(of: "\u{00A0}", with: " ") == "Lowest USD",
                     "Only the cheapest store is marked, with its currency when prices are mixed: \(lowest)")
        let parentMarker = views(parent).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "shopLowest" }
        precondition(parentMarker == nil && parent.accessibilityLabel()!.contains("lowest price $9.99 at GOG"), parent.accessibilityLabel() ?? "")
        // Search → wishlist with real clicks while the search field is editing: the heart must survive and toggle.
        // Real mouse events through the window, like a user's click: hit testing, responder chain and button tracking.
        func click(_ view: NSView, expecting target: NSView? = nil) {
            view.scrollToVisible(view.bounds)
            window.contentView!.layoutSubtreeIfNeeded()
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let hit = window.contentView!.hitTest(window.contentView!.superview!.convert(point, from: nil))
            precondition(hit === (target ?? view), "\(view.accessibilityIdentifier()) receives its own clicks, not \(String(describing: hit)) \(hit?.accessibilityIdentifier() ?? "") at \(point) in \(window.contentView!.bounds), tab \(shopTab.selectedSegment) hidden \(view.isHiddenOrHasHiddenAncestor)")
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            // A mouse-up left over from an earlier step would end this click's tracking at the wrong spot.
            while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDown, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) != nil {}
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.sendEvent(event(.leftMouseDown))
            // An enabled button's tracking loop takes the mouse-up; otherwise deliver it the way the app would.
            // Under load the posted event can take a moment to reach the queue, so wait briefly for it.
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.3), inMode: .default, dequeue: true) { window.sendEvent(up) }
            spin()
        }
        let openedBefore = opened().count
        window.makeFirstResponder(shopSearchField)
        let searchHeart = views(searchList).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "cs:100" }!
        shopSearchSubmitted()
        precondition(searchHeart.window != nil, "Re-sending an identical search doesn't rebuild the rows under the pointer")
        click(searchHeart)
        precondition(calls("wishlist").last!.prefix(2) == ["wishlist", "--add"],
                     "\(calls("wishlist").last!) editable \(wishlistEditable) loaded \(wishlist != nil) payload \(wishlistPayloads["cs:100"] != nil) enabled \(searchHeart.isEnabled) key \(window.isKeyWindow) note \(wishlist?.note ?? "-")")
        let searchPayload = try! JSONSerialization.jsonObject(with: Data(calls("wishlist").last![2].utf8)) as! [String: String]
        precondition(searchPayload == ["title": "Hollow Knight", "game_id": "100", "steam_app_id": "367520"], "\(searchPayload)")
        precondition(searchHeart.accessibilityLabel() == "Remove Hollow Knight from wishlist" && opened().count == openedBefore,
                     "The heart fills at once and doesn't open the store")
        selectShopTab(4)
        precondition(labels(wishlistList).contains("Hollow Knight"), "The searched game is in the Wishlist")
        // One search field above every section: searching from Home shows the results in its place; clearing it goes back to Home.
        selectShopTab(0)
        precondition(!shopSearchField.isHiddenOrHasHiddenAncestor && shopNav.selectedSegment == 0, "The search field is on Home too")
        precondition(!views(shopPageView!).contains { ($0 as? NSSearchField).map { $0 !== shopSearchField } ?? false },
                     "The Shop has exactly one search field")
        shopSearchField.stringValue = "hollow knight"
        shopSearchSubmitted()
        spin()
        precondition(shopTab.selectedSegment == 3 && !searchPane.isHidden && homePane.isHidden && shopNav.selectedSegment == -1 && shopScopeBar.isHidden,
                     "Searching shows results, with no section selected: tab \(shopTab.selectedSegment) nav \(shopNav.selectedSegment)")
        let resultHeart = views(searchList).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "cs:100" }!
        precondition(resultHeart.accessibilityLabel() == "Remove Hollow Knight from wishlist")
        click(resultHeart)
        precondition(calls("wishlist").last! == ["wishlist", "--remove", "cs:100"] && !(wishlist?.items.contains { $0.key == "cs:100" } ?? true))
        precondition(resultHeart.accessibilityLabel() == "Add Hollow Knight to wishlist" && opened().count == openedBefore)
        shopSearchField.stringValue = ""
        shopSearchSubmitted()
        precondition(shopTab.selectedSegment == 0 && !homePane.isHidden && shopNav.selectedSegment == 0, "Clearing the search goes back to Home")
        shopNav.selectedSegment = 1
        shopNavChanged()
        precondition(shopTab.selectedSegment == 1 && !dealsPane.isHidden, "The section control switches sections")
        shopSearchField.stringValue = "hollow knight"
        shopSearchSubmitted()
        spin()
        precondition(shopTab.selectedSegment == 3)
        // Mac / Windows badges: only Steam's platform flags or the Mac App Store count; unknown games get no claim.
        for _ in 0..<40 where steamPlatformStatus["700"] == nil || steamPlatformStatus["367520"] == nil { spin(0.1) }
        precondition(calls("shop-platforms").allSatisfy { $0.count == 3 && $0[2].split(separator: ",").count <= 40 })
        precondition(compatibility(steamAppId: "620") == .mac && compatibility(steamAppId: "700") == .windowsOnly &&
                     compatibility(steamAppId: nil) == nil && compatibility(steamAppId: "999") == nil && compatibility(steamAppId: nil, appStore: true) == .mac,
                     "Platforms \(steamPlatformStatus) calls \(calls("shop-platforms")) requested \(platformsRequested)")
        func rowText(_ list: NSStackView, _ id: String, _ title: String) -> String? {
            views(list).first { $0.accessibilityIdentifier() == id && labels($0).contains(title) }
                .map { labels($0).joined(separator: " | ").replacingOccurrences(of: "\u{00A0}", with: " ") }
        }
        selectShopTab(0)
        window.contentView!.layoutSubtreeIfNeeded()
        let homeRows = views(homeList).filter { $0 is ClickableRowView }
        func homeRow(_ title: String) -> String { homeRows.first { labels($0).contains(title) }.map { labels($0).joined(separator: " | ").replacingOccurrences(of: "\u{00A0}", with: " ") } ?? "" }
        precondition(homeRow("Drop Game").hasPrefix("Drop Game | ") && homeRow("Drop Game").contains("\u{FFFC} Windows |") &&
                     !homeRow("Drop Game").contains("needs") && !homeRow("Drop Game").contains("only"), "Windows-only deal: \(homeRow("Drop Game"))")
        precondition(homeRow("Portal 2").contains("Mac") && !homeRow("Portal 2").contains("Windows"), homeRow("Portal 2"))
        precondition(!homeRow("Free Adventure").contains("Mac") && !homeRow("Free Adventure").contains("Windows"), "Giveaways make no claim")
        let dropTip = homeRows.first { labels($0).contains("Drop Game") }!.accessibilityLabel() ?? ""
        precondition(dropTip.contains("compatibility app"), "The Windows-only row explains it needs a compatibility app")
        let storeTexts = views(homeList).compactMap { $0 as? NSTextField }.filter { $0.attributedStringValue.containsAttachments }
        precondition(!storeTexts.isEmpty, "Store hints carry the store's mini icon")
        selectShopTab(3)
        window.contentView!.layoutSubtreeIfNeeded()
        let hollow = rowText(searchList, "shopGameRow", "Hollow Knight") ?? ""
        precondition(hollow.contains("Mac"), "Search parent: \(hollow)")
        if let silksong = views(searchList).first(where: { $0 is ClickableRowView && labels($0).contains { $0.hasPrefix("Hollow Knight: Silksong") } }) {
            let text = labels(silksong).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            precondition(!text.contains("Mac") && !text.contains { $0.hasPrefix("Windows") }, "No Steam ID, no claim: \(text)")
        }
        let offerViews = views(searchList).filter { $0.accessibilityIdentifier() == "shopOffer" }
        precondition(!offerViews.isEmpty)
        for offer in offerViews {
            let icons = views(offer).filter { $0.accessibilityIdentifier() == "shopStoreIcon" }
            let tags = views(offer).filter { $0.accessibilityIdentifier() == "shopStoreTag" }
            let sale = views(offer).contains { $0.accessibilityIdentifier() == "shopSaleTag" }
            let store = (tags.first?.accessibilityLabel() ?? "").components(separatedBy: ", ")[0]
            let tagText = labels(tags.first ?? offer)
            precondition(tags.count == 1 && (sale ? icons.isEmpty && tagText.count == 1 && tagText[0].hasPrefix(store + " \u{2212}") && tagText[0].hasSuffix("%")
                                                  : icons.count == 1 && icons[0].accessibilityLabel() == store && icons[0].frame.width == 12 && tagText == [store])
                         && labels(offer).filter { $0.hasPrefix(store) }.count == 1,
                         "Every store price names its store in full, once: gray with its icon, or a green tag with the discount: \(store) \(labels(offer))")
            let price = views(offer).first { $0.accessibilityIdentifier() == "shopPriceLine" }!
            let tagFrame = tags[0].convert(tags[0].bounds, to: offer), priceFrame = price.convert(price.bounds, to: offer)
            precondition(abs(tagFrame.maxX - priceFrame.maxX) < 0.5 && (offer.isFlipped ? tagFrame.minY >= priceFrame.maxY - 0.5 : tagFrame.maxY <= priceFrame.minY + 0.5),
                         "The store line sits right under the price, right-aligned: \(tagFrame) \(priceFrame)")
            let text = labels(offer).joined(separator: " ")
            if !(store == "Steam" || store == "Mac App Store") {
                precondition(!text.contains("Windows") && !text.contains("Mac\u{00A0}") && !text.hasSuffix("Mac"),
                             "Other PC stores may ship other builds, so they make no claim: \(text)")
            }
        }
        // The all-time low: only CheapShark's record minimum, as a small line under the price, with the record in the tooltip.
        let insights = views(searchList).filter { $0.accessibilityIdentifier() == "shopPriceInsight" }.compactMap { $0 as? NSTextField }
        precondition(insights.map(\.stringValue).sorted() == ["25% above all-time low", "All-time low"]
                     && insights.allSatisfy { ($0.toolTip ?? "").contains("7.99 USD") || ($0.toolTip ?? "").contains("19.99 USD") }
                     && insights.allSatisfy { !($0.toolTip ?? "").lowercased().contains("average") && ($0.toolTip ?? "").contains("2025") }
                     && !views(searchList).filter { $0.accessibilityIdentifier() == "shopOffer" }.contains { views($0).contains { $0.accessibilityIdentifier() == "shopPriceInsight" } },
                     "All-time-low notes on the game rows only: \(insights.map(\.stringValue))")
        for insight in insights {
            let column = insight.superview!.superview!
            precondition(column.accessibilityIdentifier() == "shopPriceColumn" && column.subviews.last === insight.superview, "The note sits under the price and store")
        }
        precondition(PriceInsight(kind: "above", percent: nil, low: 0, currency: "USD", date: nil).text == "Was free before"
                     && PriceInsight(kind: "above", percent: nil, low: 0, currency: "USD", date: nil).detail.contains("free"))
        precondition(Self.storeIconID("Steam") == "steam" && Self.storeIconID("GOG") == "gog-galaxy" && Self.storeIconID("Epic Games Store") == "epic-games" &&
                     Self.storeIconID("Origin") == "ea" && Self.storeIconID("Humble Store") == nil && !Self.storeIcon("Steam", size: 16).template &&
                     Self.storeIcon("Humble Store", size: 16).template)
        renderWishlist()
        let wished = views(wishlistList).filter { $0.accessibilityIdentifier() == "wishlistRow" }
        precondition(wished.allSatisfy { row in
            let item = wishlist!.items.first { labels(row).contains($0.title) }
            let text = labels(row).joined(separator: " ")
            return compatibility(steamAppId: item?.steamAppId, appStore: item?.appStoreId != nil) == .mac ? text.contains("Mac") : true
        })
        // Sort by: one stable comparator for every list; missing values last, prices grouped by currency unless converted.
        let sample = [ShopSortFields(title: "beta", price: 10, currency: "USD", discount: 20, rating: 80, added: 2, ends: 300),
                      ShopSortFields(title: "Alpha", price: 3000, currency: "HUF", rating: 90, added: 3),
                      ShopSortFields(title: "gamma", price: 5, currency: "USD", discount: 50, ends: 100),
                      ShopSortFields(title: "delta", discount: 20, rating: 80, added: 1, ends: 200)]
        func order(_ sort: ShopSort, _ convert: @escaping (Double, String) -> Double? = { _, _ in nil }) -> [String] {
            shopSorted(sample, by: sort, convert: convert) { $0 }.map(\.title)
        }
        let toUSD: (Double, String) -> Double? = { price, code in code == "USD" ? price : code == "HUF" ? price / 375 : nil }
        precondition(order(.relevance) == ["beta", "Alpha", "gamma", "delta"])
        precondition(order(.name) == ["Alpha", "beta", "delta", "gamma"])
        precondition(order(.priceAsc) == ["Alpha", "gamma", "beta", "delta"], "Original prices group by currency: \(order(.priceAsc))")
        precondition(order(.priceAsc, toUSD) == ["gamma", "Alpha", "beta", "delta"], "\(order(.priceAsc, toUSD))")
        precondition(order(.priceDesc, toUSD) == ["beta", "Alpha", "gamma", "delta"], "No price stays last: \(order(.priceDesc, toUSD))")
        precondition(order(.discount) == ["gamma", "beta", "delta", "Alpha"], "Ties keep their order: \(order(.discount))")
        precondition(order(.rating) == ["Alpha", "beta", "delta", "gamma"])
        precondition(order(.added) == ["Alpha", "beta", "delta", "gamma"])
        precondition(order(.endsSoon) == ["gamma", "delta", "beta", "Alpha"])
        // Each list remembers its choice; Deals and Free Games map onto their existing popups.
        func pick(_ popup: NSPopUpButton, _ value: String) {
            popup.selectItem(at: popup.indexOfItem(withRepresentedObject: value))
            popup.sendAction(popup.action, to: popup.target)
            spin()
        }
        precondition(searchSortPopup.accessibilityIdentifier() == "shopSortPopup" && !searchSortPopup.itemTitles.contains("Best Rating"),
                     "Search results have no ratings to sort by")
        pick(wishlistSortPopup, "name")
        precondition(UserDefaults.standard.string(forKey: wishlistSortKey) == "name")
        let wishedTitles = views(wishlistList).filter { $0.accessibilityIdentifier() == "wishlistRow" }
            .compactMap { row in wishlist!.items.first { labels(row).contains($0.title) }?.title }
        precondition(wishedTitles == wishedTitles.sorted { $0.localizedStandardCompare($1) == .orderedAscending } && !wishedTitles.isEmpty)
        pick(searchSortPopup, "price-desc")
        precondition(UserDefaults.standard.string(forKey: searchSortKey) == "price-desc")
        let parents = views(searchList).filter { $0.accessibilityIdentifier() == "shopGameRow" || $0.accessibilityIdentifier() == "shopSingleOffer" }
        precondition(!parents.isEmpty)
        let header = sortHeader(NSTextField(labelWithString: ""), NSPopUpButton(), [.relevance, .priceDesc], key: searchSortKey, label: "x")
        precondition((header.arrangedSubviews[1] as! NSPopUpButton).titleOfSelectedItem == "Highest Price", "The saved choice comes back")
        pick(searchSortPopup, "relevance")
        pick(wishlistSortPopup, "relevance")
        precondition(dealsSortPopup.indexOfItem(withRepresentedObject: "price-desc") >= 0 && giveawaySortPopup.indexOfItem(withRepresentedObject: "ends") >= 0)
        let savedGiveawaySort = giveawaySortPopup.selectedItem?.representedObject as? String
        giveawaySortPopup.selectItem(at: giveawaySortPopup.indexOfItem(withRepresentedObject: "ends"))
        let savedMode = dealsMode.selectedSegment
        dealsMode.selectedSegment = 1
        precondition(dealsArguments().contains("date") && !dealsArguments().contains("ends"), "Ends Soon sorts here, not on GamerPower")
        precondition(sortedGiveaways().count == giveaways.count)
        dealsMode.selectedSegment = savedMode
        giveawaySortPopup.selectItem(at: giveawaySortPopup.indexOfItem(withRepresentedObject: savedGiveawaySort ?? "date"))
        UserDefaults.standard.removeObject(forKey: searchSortKey)
        UserDefaults.standard.removeObject(forKey: wishlistSortKey)
        // A bundle replaced mid-run reports a friendly reopen message instead of the raw python error.
        precondition(friendlyBackendError("python3: can't open file '/x/CouchCube.app/Contents/Resources/scripts/console.py': [Errno 2] No such file or directory")
                     == Self.appUpdatedMessage)
        precondition(friendlyBackendError("Steam is not installed.") == "Steam is not installed.")
        // Store-style headings on Home; "See all" links open their tab.
        selectShopTab(0)
        let titles = views(homeList).compactMap { $0 as? NSTextField }.filter { $0.accessibilityIdentifier() == "shopSectionTitle" }
        precondition(!titles.isEmpty && titles.allSatisfy { $0.font!.pointSize == Self.shopHeadingSize }, "Home headings are large")
        // Sections are separated by about twice the old gap; a heading stays close to its own rows.
        window.contentView!.layoutSubtreeIfNeeded()
        let headers = homeList.arrangedSubviews.filter { $0.accessibilityIdentifier() == "shopSection" }
        precondition(headers.count >= 2)
        for header in headers {
            let index = homeList.arrangedSubviews.firstIndex(of: header)!
            let below = homeList.arrangedSubviews[index + 1]
            let tight = abs(header.frame.minY - below.frame.maxY) < 0.5 || abs(below.frame.minY - header.frame.maxY) < 0.5
            precondition(tight && (header as! NSStackView).edgeInsets.bottom <= 4, "A heading sits right on its rows")
            guard index > 0 else { continue }
            let above = homeList.arrangedSubviews[index - 1]
            let gap = abs(above.frame.minY - header.frame.maxY) < abs(header.frame.minY - above.frame.maxY)
                ? above.frame.minY - header.frame.maxY : header.frame.minY - above.frame.maxY
            precondition(gap >= Self.shopSectionGap - 0.5 && (header as! NSStackView).edgeInsets.top + gap >= 27.5,
                         "Sections are clearly separated: \(gap)")
        }
        let seeAll = views(homeList).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier() == "shopSeeAll" }
        precondition(seeAll.map(\.tag).contains(1) && seeAll.map(\.tag).contains(2))
        seeAll.first { $0.tag == 2 }!.performClick(nil)
        precondition(shopTab.selectedSegment == 2)
        // Every visible heart on every tab, at the narrowest and a roomy window, with real clicks: the heart alone
        // toggles the wishlist and never opens a store, whether the wishlist is editable or read-only.
        let roomyFrame = window.frame
        func visibleHearts() -> [NSButton] {
            views(shopPageView!).compactMap { $0 as? NSButton }.filter {
                ["wishlistHeart", "wishlistRemove"].contains($0.accessibilityIdentifier()) && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        func firstHeart(_ key: String, _ kind: String) -> NSButton? {
            visibleHearts().first { $0.identifier?.rawValue == key && $0.accessibilityIdentifier() == kind }
        }
        let savedHeartsWishlist = smokeWishlist
        // Reload the wishlist and wait for the reply, so a slow check never leaves the previous (read-only) state behind.
        func reloadWishlist() {
            let deadline = Date().addingTimeInterval(10)
            while wishlistLoading && Date() < deadline { spin() }
            checkWishlist(refresh: false)
            spin()
            while wishlistLoading && Date() < deadline { spin() }
            precondition(!wishlistLoading, "The wishlist check finishes")
        }
        for size in [window.contentMinSize, NSSize(width: 1240, height: 860)] {
            window.setContentSize(size)
            for tab in 0..<5 {
                selectShopTab(tab)
                spin()
                window.contentView!.layoutSubtreeIfNeeded()
                let targets = visibleHearts().map { ($0.identifier!.rawValue, $0.accessibilityIdentifier()) }
                precondition(!targets.isEmpty, "Tab \(tab) has hearts to test")
                var seen = Set<String>()
                for (key, kind) in targets where seen.insert(kind + key).inserted {
                    let openedBefore = opened().count, before = calls("wishlist").count
                    let heart = firstHeart(key, kind)!
                    precondition(heart.acceptsFirstMouse(for: nil), "Heart \(key) works with one click in an inactive window, like its row")
                    let saved = kind == "wishlistRemove" || heart.accessibilityLabel()!.hasPrefix("Remove ")
                    click(heart)
                    precondition(opened().count == openedBefore, "Heart \(key) on tab \(tab) at \(size) never opens a store")
                    precondition(calls("wishlist").count == before + 1 &&
                                 calls("wishlist").last![1] == (saved ? "--remove" : "--add"),
                                 "Heart \(key) on tab \(tab) at \(size) toggles the wishlist: \(calls("wishlist").suffix(2))")
                    if kind == "wishlistHeart", let again = firstHeart(key, kind) {
                        precondition(again.accessibilityLabel()!.hasPrefix(saved ? "Add " : "Remove "), "\(key) shows its new state at once")
                        click(again)
                        precondition(opened().count == openedBefore && calls("wishlist").count == before + 2)
                        precondition(firstHeart(key, kind)!.accessibilityLabel()!.hasPrefix(saved ? "Remove " : "Add "), "\(key) toggles back")
                    }
                    smokeWishlist = savedHeartsWishlist
                    reloadWishlist()
                }
                // Read-only (drive unplugged): hearts explain, change nothing and still never open the store.
                smokeWishlistOffline = true
                reloadWishlist()
                precondition(!wishlistEditable, "The wishlist is read-only while the drive is away")
                for heart in visibleHearts() {
                    let openedBefore = opened().count, before = calls("wishlist").count
                    dealsReminderBar.isHidden = true
                    click(heart)
                    precondition(opened().count == openedBefore && calls("wishlist").count == before,
                                 "A read-only heart on tab \(tab) at \(size) never opens a store")
                    precondition(heart.accessibilityIdentifier() == "wishlistRemove" || !dealsReminderBar.isHidden,
                                 "A read-only heart says why it can't change")
                }
                dealsReminderBar.isHidden = true
                smokeWishlistOffline = false
                reloadWishlist()
                precondition(wishlistEditable, "The wishlist is editable again")
            }
        }
        // The rest of a row still opens the store with a real click.
        selectShopTab(1)
        spin()
        let dealRowView = views(dealsList).compactMap { $0 as? ClickableRowView }.first!
        let dealTitle = views(dealRowView).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Portal 2" }!
        let openedBeforeRow = opened().count
        click(dealTitle, expecting: dealRowView)
        precondition(opened().count == openedBeforeRow + 1 && opened().last!.host == "www.cheapshark.com", "Clicking the row opens the deal")
        window.setFrame(roomyFrame, display: false)
        // Search: a game sold in one store is a plain row; groups mark only the cheapest store, not the game.
        let single = views(searchList).first { $0.accessibilityIdentifier() == "shopSingleOffer" }
        precondition(single != nil && !views(single!).contains { $0.accessibilityIdentifier() == "shopLowest" } &&
                     searchList.arrangedSubviews.filter { $0.accessibilityIdentifier() == "shopOffer" }.count == 3 &&
                     views(single!).contains { $0.accessibilityIdentifier() == "wishlistHeart" && $0.identifier?.rawValue == "cs:200" },
                     "A one-store game is an ordinary row with its own heart")
        // A real click on a one-store result's heart adds it, a second removes it, and neither opens the store.
        func singleHeart() -> NSButton {
            views(searchList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistHeart" && $0.identifier?.rawValue == "cs:200" }!
        }
        selectShopTab(3)
        spin()
        window.contentView!.layoutSubtreeIfNeeded()
        singleHeart().scrollToVisible(singleHeart().bounds)
        let openedBeforeSingle = opened().count
        let hadSingle = wishlist?.items.contains { $0.key == "cs:200" } ?? false
        click(singleHeart())
        spin()
        precondition((wishlist?.items.contains { $0.key == "cs:200" } ?? false) != hadSingle && opened().count == openedBeforeSingle,
                     "One-store heart toggles the wishlist without navigating")
        click(singleHeart())
        spin()
        precondition((wishlist?.items.contains { $0.key == "cs:200" } ?? false) == hadSingle && opened().count == openedBeforeSingle &&
                     calls("wishlist").suffix(2).map { $0[1] } == (hadSingle ? ["--remove", "--add"] : ["--add", "--remove"]))
        for list in [searchList] {
            for parent in views(list).filter({ $0.accessibilityIdentifier() == "shopGameRow" }) {
                precondition(!views(parent).contains { $0.accessibilityIdentifier() == "shopLowest" }, "No Lowest tag on the game row")
            }
        }
        // Ratings: each kind in its own column; a missing rating leaves its cell empty instead of sliding the others over.
        selectShopTab(1)
        spin()
        window.contentView!.layoutSubtreeIfNeeded()
        let dealRows = views(dealsList).compactMap { $0 as? ClickableRowView }
        for id in ["shopRatingSteam", "shopRatingMetacritic", "shopRatingDeal"] {
            let cells = dealRows.map { row in views(row).first { $0.accessibilityIdentifier() == id }! }
            let xs = Set(cells.map { Int(($0.convert($0.bounds, to: dealsList).minX * 2).rounded()) })
            precondition(xs.count == 1, "\(id) lines up in every row: \(xs)")
        }
        func cellText(_ row: NSView, _ id: String) -> String? {
            views(views(row).first { $0.accessibilityIdentifier() == id }!).compactMap { $0 as? NSTextField }.first?.stringValue
        }
        let skyrim = dealRows.first { $0.accessibilityLabel()!.contains("Skyrim") }!
        let critics = dealRows.first { $0.accessibilityLabel()!.contains("Critics Pick") }!
        precondition(cellText(skyrim, "shopRatingSteam") == "85%" && cellText(skyrim, "shopRatingMetacritic") == nil &&
                     cellText(skyrim, "shopRatingDeal") == "7.2", "Skyrim: Steam and deal rating, no Metacritic")
        precondition(cellText(critics, "shopRatingSteam") == nil && cellText(critics, "shopRatingMetacritic") == "71" &&
                     cellText(critics, "shopRatingDeal") == nil, "Critics Pick: Metacritic only, in the Metacritic column")
        precondition(views(skyrim).first { $0.accessibilityIdentifier() == "shopRatingSteam" }!.toolTip == "Steam reviews: Very Positive (85%)")
        smokeCaptureShop()
        // Every tab fits the narrowest window.
        let savedFrame = window.frame
        window.setContentSize(window.contentMinSize)
        for tab in 0..<5 {
            selectShopTab(tab)
            spin()
            window.contentView!.layoutSubtreeIfNeeded()
            let page = shopPageView!
            for row in views(page).compactMap({ $0 as? ClickableRowView }) where !row.isHiddenOrHasHiddenAncestor {
                let frame = row.convert(row.bounds, to: page)
                precondition(frame.minX >= -0.5 && frame.maxX <= page.bounds.width + 0.5, "Shop rows stay inside the page on tab \(tab)")
            }
            precondition(shopNav.convert(shopNav.bounds, to: page).maxX <= (shopScopeBar.isHidden ? dealsRefreshButton : shopScope).convert(NSPoint.zero, to: page).x + 0.5, "The Shop sections and store scope fit the narrowest window")
            // Right end of each row: price over usual price, discount over store, in fixed columns that line up row to row.
            var priceX: [String: (shape: String, price: CGFloat)] = [:]
            for row in views(page).compactMap({ $0 as? ClickableRowView }) where !row.isHiddenOrHasHiddenAncestor {
                guard let cluster = views(row).first(where: { $0.accessibilityIdentifier() == "shopPriceCluster" }) else { continue }
                func frame(_ id: String) -> NSRect? { views(cluster).first { $0.accessibilityIdentifier() == id }.map { $0.convert($0.bounds, to: row) } }
                precondition(frame("shopHeartColumn") == nil && frame("shopMarkerColumn") == nil, "Hearts and tags sit by the title, not in the price grid")
                let priceFrame = frame("shopPriceColumn")!
                precondition(frame("shopPercentColumn") == nil, "The discount sits with the store, not in its own column")
                precondition(abs(priceFrame.maxX - (row.bounds.maxX - 6)) < 1, "The price block ends at the row's edge on tab \(tab): \(priceFrame) \(row.bounds)")
                if let line = frame("shopPriceLine"), let tag = frame("shopStoreTag") {
                    precondition(abs(line.maxX - priceFrame.maxX) < 0.5 && abs(tag.maxX - priceFrame.maxX) < 0.5
                                 && (row.isFlipped ? tag.minY >= line.maxY - 0.5 : tag.maxY <= line.minY + 0.5)
                                 && tag.minX >= priceFrame.minX - 0.5 && line.width < priceFrame.width && tag.width < priceFrame.width,
                                 "Price on top, store under it, both right-aligned and inside the block on tab \(tab): \(line) \(tag) \(priceFrame)")
                }
                precondition(views(row).contains { ["shopArtwork", "shopStoreIcon", "shopSaleTag"].contains($0.accessibilityIdentifier()) }, "Every shop row has art or its store icon on tab \(tab)")
                // Every row of a list reserves the same columns, so heart, price and discount sit at one x each.
                let list = "\(ObjectIdentifier(row.superview!))"
                let shape = frame("shopRatingSteam") == nil ? "" : "ratings"
                let x = priceFrame.minX + row.convert(NSPoint.zero, to: page).x
                if let other = priceX[list] {
                    precondition(other.shape == shape && abs(other.price - x) < 0.5,
                                 "Columns line up on tab \(tab): \(other) vs \((shape, x)) \(row.accessibilityLabel() ?? "")")
                } else { priceX[list] = (shape, x) }
                // Fixed widths: a long converted price or a 100% discount never widens its column.
                precondition(abs(priceFrame.width - Self.shopOfferWidth) < 0.5)
                // A deal's usual price sits beside the sale price on the same line, struck through.
                if let was = views(cluster).first(where: { $0.accessibilityIdentifier() == "shopWasPrice" }) as? NSTextField,
                   let now = was.superview?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0 !== was }) {
                    let wasFrame = was.convert(was.bounds, to: row), nowFrame = now.convert(now.bounds, to: row)
                    precondition(nowFrame.maxX <= wasFrame.minX + 0.5 && abs(wasFrame.midY - nowFrame.midY) < 4 &&
                                 was.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil,
                                 "Usual price beside the price on tab \(tab): \(wasFrame) vs \(nowFrame)")
                }
            }
        }
        window.setFrame(savedFrame, display: false)
    }

    /// Screenshots of every Shop tab in Original, USD and HUF at the narrowest and a roomy window, for visual review.
    /// Only when COUCH_CUBE_SMOKE_CAPTURE names a folder.
    private func smokeCaptureShop() {
        guard let folder = ProcessInfo.processInfo.environment["COUCH_CUBE_SMOKE_CAPTURE"] else { return }
        let defaults = UserDefaults.standard
        let savedFrame = window.frame, savedCurrency = defaults.object(forKey: shopCurrencyKey)
        let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        for currency in ["original", "USD", "HUF"] {
            defaults.set(currency, forKey: shopCurrencyKey)
            updateCurrencyNotes()
            rerenderShop()
            for (sizeName, size) in [("min", window.contentMinSize), ("wide", NSSize(width: 1240, height: 860))] {
                window.setContentSize(size)
                for (tab, name) in ["home", "deals", "free", "search", "wishlist"].enumerated() {
                    selectShopTab(tab)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    let view = window.contentView!
                    view.layoutSubtreeIfNeeded()
                    for bottom in tab == 0 ? [false, true] : [false] {
                    if let scroll = shopPageView?.enclosingScrollView {
                        let end = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom ? end : 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    let name = bottom ? name + "-bottom" : name
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        // cacheDisplay skips the window's own background; paint it behind so dark mode reads as on screen.
                        let image = NSImage(size: view.bounds.size)
                        image.lockFocus()
                        NSColor.windowBackgroundColor.setFill()
                        view.bounds.fill()
                        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        image.unlockFocus()
                        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
                        let file = URL(fileURLWithPath: folder).appendingPathComponent("shop-\(appearance)-\(sizeName)-\(currency)-\(tab)-\(name).png")
                        try? out.representation(using: .png, properties: [:])?.write(to: file)
                    }
                    }
                }
            }
        }
        if let savedCurrency { defaults.set(savedCurrency, forKey: shopCurrencyKey) } else { defaults.removeObject(forKey: shopCurrencyKey) }
        rerenderShop()
        window.setFrame(savedFrame, display: false)
    }

    private func smokeTestDealReminders(opened: () -> [URL]) {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Budapest")!
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        // Parsing: GamerPower times are read as UTC; date-only means the end of that UTC day; N/A has no badge.
        let utc = DealExpiry.parseGamerPowerEnd("2026-10-24 23:59:59")!
        precondition(utc.timeIntervalSince1970 == 1_792_886_399)
        precondition(DealExpiry.parseGamerPowerEnd("2026-10-24")! == utc)
        precondition(DealExpiry.parseGamerPowerEnd("N/A") == nil && DealExpiry.parseGamerPowerEnd("2026-13-01") == nil &&
                     DealExpiry.parseGamerPowerEnd(nil) == nil)
        // Expiry text by local calendar day; urgent within two days; nothing once ended.
        let now = local(2026, 6, 10, 12)
        func label(_ end: Date) -> String? { DealExpiry.label(until: end, now: now, calendar: calendar).map { $0.text + ($0.urgent ? "!" : "") } }
        precondition(label(local(2026, 6, 10, 20)) == "Offer ends today!" && label(local(2026, 6, 11, 1)) == "Offer ends tomorrow!" &&
                     label(local(2026, 6, 12, 9)) == "Offer ends 12 June!" && label(local(2026, 6, 13, 20)) == "Offer ends 13 June" &&
                     label(local(2027, 1, 2, 9)) == "Offer ends 2 January 2027" &&
                     label(local(2026, 6, 10, 11)) == nil)
        // Reminder: 09:00 the day before; else 09:00 today if ahead; else a few minutes from now; never after the end.
        func remind(_ end: Date, _ at: Date) -> (Date, Bool)? {
            DealExpiry.reminderDate(for: end, now: at, calendar: calendar).map { ($0.date, $0.adjusted) }
        }
        precondition(remind(local(2026, 6, 13, 20), now)! == (local(2026, 6, 12, 9), false))
        precondition(remind(local(2026, 6, 11, 20), local(2026, 6, 10, 8))! == (local(2026, 6, 10, 9), false))
        precondition(remind(local(2026, 6, 11, 20), now)! == (local(2026, 6, 10, 12, 5), true))
        precondition(remind(local(2026, 6, 10, 20), local(2026, 6, 10, 8))! == (local(2026, 6, 10, 9), true))
        precondition(remind(local(2026, 6, 10, 12, 3), now) == nil && remind(local(2026, 6, 9, 12), now) == nil)
        // Across daylight-saving changes the alarm stays at 09:00 local time.
        for end in [local(2026, 3, 30, 12), local(2026, 10, 26, 12)] {
            let due = remind(end, local(2026, 3, 1, 12))!.0
            precondition(calendar.component(.hour, from: due) == 9 && calendar.component(.minute, from: due) == 0 &&
                         calendar.dateComponents([.day], from: due, to: end).day == 1)
        }
        // Badge flow with a mock Reminders store: nothing touches the user's real Reminders.
        final class MockReminders: DealReminderStore {
            var access = ReminderAccess.denied
            var grant = true
            var requests = 0
            var items: [String: (title: String, notes: String, url: URL?, due: Date)] = [:]
            func requestAccess(_ done: @escaping (Bool) -> Void) { requests += 1; access = grant ? .granted : .denied; done(grant) }
            func add(title: String, notes: String, url: URL?, due: Date) throws -> String {
                let id = "mock-\(items.count + 1)"
                items[id] = (title, notes, url, due)
                return id
            }
            func exists(_ identifier: String) -> Bool { items[identifier] != nil }
            func remove(_ identifier: String) throws { items[identifier] = nil }
        }
        let mock = MockReminders()
        let savedStore = reminderStore, savedReminders = dealReminders, savedConfirm = confirmReminderRemoval
        var confirm = false
        reminderStore = mock
        confirmReminderRemoval = { _ in confirm }
        dealReminders = [:]
        defer {
            reminderStore = savedStore
            confirmReminderRemoval = savedConfirm
            dealReminders = savedReminders
            dealsReminderBar.isHidden = true
        }
        renderDeals()
        func badge() -> NSButton { views(dealsList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "dealReminder" }! }
        precondition(badge().title.hasPrefix("Offer ends ") && badge().accessibilityLabel()!.hasPrefix("Remind me the day before this deal ends"))
        precondition(badge().superview?.superview?.accessibilityIdentifier() == "shopPriceColumn" && badge().superview?.superview?.subviews.last === badge().superview,
                     "The offer's end date sits right under its price block")
        let row = views(dealsList).compactMap { $0 as? ClickableRowView }.first!
        dealsList.window?.layoutIfNeeded()
        row.layoutSubtreeIfNeeded()
        let point = badge().convert(NSPoint(x: badge().bounds.midX, y: badge().bounds.midY), to: row.superview)
        precondition(row.hitTest(point) === badge(), "The reminder badge is its own control inside the clickable row")
        let opens = opened().count
        badge().performClick(nil)
        precondition(opened().count == opens, "Clicking the badge never opens the deal")
        precondition(!dealsReminderBar.isHidden && !dealsReminderSettings.isHidden && mock.items.isEmpty, "Denied access explains and offers Settings")
        dealsReminderSettings.performClick(nil)
        precondition(opened().last?.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") == true)
        mock.access = .notDetermined
        badge().performClick(nil)
        precondition(mock.requests == 1 && mock.items.count == 1 && badge().title.hasPrefix("Offer ends ") && badge().toolTip!.contains("reminder is set"))
        let item = mock.items["mock-1"]!
        precondition(item.title == "Free Adventure deal ends \u{2014} Epic Games Store" && item.url?.host == "www.gamerpower.com" &&
                     item.notes.contains("usually $19.99") && item.notes.contains("read as UTC") && item.notes.contains("free-adventure"))
        precondition(dealReminders == ["giveaway:1": "mock-1"] && dealsReminderSettings.isHidden)
        // No duplicates: a second add for the same giveaway does nothing; a second click offers removal.
        addDealReminder(giveaways[0], end: DealExpiry.parseGamerPowerEnd(giveaways[0].endDate)!, button: badge())
        badge().performClick(nil)
        precondition(mock.items.count == 1 && badge().title.hasPrefix("Offer ends ") && badge().toolTip!.contains("reminder is set"), "Cancelled removal keeps the reminder")
        confirm = true
        badge().performClick(nil)
        precondition(mock.items.isEmpty && dealReminders.isEmpty && badge().title.hasPrefix("Offer ends "))
        // A reminder deleted in Reminders resets the badge on the next render.
        badge().performClick(nil)
        precondition(mock.requests == 1 && dealReminders.count == 1)
        mock.items.removeAll()
        renderDeals()
        precondition(dealReminders.isEmpty && badge().title.hasPrefix("Offer ends "))
    }

    private func assertSmokePageScrolls() {
        window.contentView!.layoutSubtreeIfNeeded()
        let scroll = tabs.selectedTabViewItem!.view as! NSScrollView
        let document = scroll.documentView!
        precondition(document.bounds.height >= document.subviews.first!.fittingSize.height,
                     "Every settings page must scroll to its last control")
    }

    @objc private func disksChanged() {
        if smokeFinishing { return }
        if task != nil { refreshPending = true } else { refresh() }
    }

    @objc private func selectionChanged() {
        updateSelection(preservingStatus: false)
    }

    private func updateSelection(preservingStatus: Bool) {
        if !preservingStatus {
            report = nil
            consoleSystems = []
        }
        updateSetupSummary()
        storageNext.isEnabled = false
        guard let drive = selected else {
            summary.stringValue = preferredMode == "portable"
                ? "Connect an SSD to use it here, or choose Prepare an SSD above. Existing files won't be erased unless you explicitly choose preparation."
                : "Your storage is disconnected. Reconnect it and choose Refresh."
            modeLabel.stringValue = "NO STORAGE SELECTED"
            libraryTitle.stringValue = "Choose your game drive"
            libraryDescription.stringValue = "Select a connected SSD above, or use this Mac's internal storage."
            libraryControls.forEach { $0.isEnabled = false }
            selectedStorage.stringValue = "Storage disconnected"
            updateSelectedStorageMarker()
            return
        }
        libraryControls.forEach { $0.isEnabled = true }
        let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
        modeLabel.stringValue = drive.mode == "local" ? "LOCAL CONSOLE  ·  ONLY THIS MAC" : "PORTABLE CONSOLE  ·  EXTERNAL SSD"
        summary.stringValue = "\(free) free  ·  \(drive.filesystem.uppercased())"
        summary.toolTip = drive.root
        selectedStorage.stringValue = drive.mode == "local" ? drive.root : "\(drive.name)\n\(drive.root)"
        updateSelectedStorageMarker()
        if report == nil {
            libraryTitle.stringValue = "Checking your library..."
            libraryDescription.stringValue = "Reading the selected drive. No files will be changed."
        }
        checkStorage()
    }

    @objc private func checkStorage() {
        guard task == nil, let drive = selected else { return }
        overviewChecks.formUnion([.storage, .menu])
        renderGeneral()
        execute(["assess", "--drive", drive.id], capture: true) { code, data in
            guard self.selected?.id == drive.id else { self.checkStorage(); return }
            self.overviewChecks.subtract([.storage, .menu])
            guard code == 0 else {
                self.overviewCheckFailures.formUnion([.storage, .menu])
                self.overviewChecks = []
                self.renderGeneral()
                self.libraryTitle.stringValue = "Couldn't check this drive"
                self.libraryDescription.stringValue = self.lastError.isEmpty
                    ? "Reconnect the drive and press Refresh." : String(self.lastError.prefix(400))
                self.status.stringValue = "Storage check failed. Activity has the details."
                self.advanceAfterLibraryCheck = false
                self.finishSmokeTest(success: false)
                return
            }
            do {
                let report = try JSONDecoder().decode(Assessment.self, from: data)
                self.report = report
                self.storageNext.isEnabled = report.issues.isEmpty
                self.storageNext.title = report.state == "not prepared" ? "Create and activate library..." : "Use this library"
                if !report.issues.isEmpty {
                    self.summary.stringValue = "This storage needs attention before we can continue. Activity has the details."
                    if drive.mode == "portable" {
                        self.summary.stringValue += "\nTry another SSD, or prepare this one below after backing up its files."
                    }
                }
                if report.state == "not prepared" {
                    self.libraryTitle.stringValue = "No library on this drive yet"
                    self.libraryDescription.stringValue = "Creates folders and launcher files only. No apps are installed, no games are moved, and Steam settings are unchanged."
                    self.libraryAction.title = "Create game library..."
                } else if report.issues.isEmpty {
                    self.libraryTitle.stringValue = "Game folders created"
                    self.libraryDescription.stringValue = report.missing.contains("steam")
                        ? "Steam is not installed. Open App Store next. Creating folders did not install any apps."
                        : "Steam is installed. Its storage settings are managed in Steam, not here. See Steam & controller setup on Play."
                    self.libraryAction.title = "Update library links..."
                } else {
                    self.libraryTitle.stringValue = "This library needs attention"
                    self.libraryDescription.stringValue = report.issues.prefix(2).joined(separator: "\n")
                    self.libraryAction.title = "Update library links..."
                }
                self.helperButton.isHidden = !report.notes.contains { $0.hasPrefix("Homebrew missing") }
                self.helperAdvice.isHidden = self.helperButton.isHidden
                self.updateSetupSummary()
                if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[5] { self.updateSteamGuide() }
                if drive.free < 20 * 1024 * 1024 * 1024 {
                    self.summary.stringValue += "\nYou're low on space. Big games may need more room."
                }
                self.status.stringValue = "Drive checked. No files changed."
                self.append("\n--- Storage assessment: \(drive.name) ---\n"
                            + (report.issues + report.notes).joined(separator: "\n") + "\n")
                if !self.didRouteInitialLibrary {
                    self.didRouteInitialLibrary = true
                    self.selectPage(0)
                }
                if self.advanceAfterLibraryCheck {
                    self.advanceAfterLibraryCheck = false
                    if report.state == "valid layout" && report.issues.isEmpty {
                        self.selectPage(3)
                    } else {
                        self.status.stringValue = "Your library needs attention before continuing. Open Details for the error."
                    }
                }
                self.finishSmokeTest(success: true)
                if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    self.loadGeneralDetails()
                } else {
                    self.overviewChecks = []
                    self.renderGeneral()
                }
            } catch {
                self.overviewCheckFailures.formUnion([.storage, .menu])
                self.overviewChecks = []
                self.renderGeneral()
                self.advanceAfterLibraryCheck = false
                self.status.stringValue = "Cannot read assessment: \(error.localizedDescription)"
                self.finishSmokeTest(success: false)
            }
        }
    }

    @objc private func playSteam() {
        guard let drive = selected else { return }
        let frontend = effectiveFrontend == "es-de" ? "ES-DE" : "Steam Big Picture"
        execute(["console", "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "\(frontend) session finished or opened." : "Couldn't open console mode. Check App Store and Activity."
        }
    }

    @objc private func homebrew() {
        let alert = NSAlert()
        alert.messageText = "Set up the app download helper?"
        alert.informativeText = "Couch Cube uses Homebrew, a free tool that installs your game players.\n\nA Terminal window will guide you through the official Homebrew installer. Type INSTALL HOMEBREW when asked. macOS may request your administrator password there, never in Couch Cube.\n\nFinish that step, return here and click the app's Install button. No disks will be erased."
        alert.addButton(withTitle: "Set up Homebrew")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Official instructions only")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("Install Homebrew.command"))
            status.stringValue = "Homebrew helper opened in Terminal. Finish or cancel there, then refresh here."
        } else if response == .alertThirdButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        }
    }

    @objc private func copyDMG() {
        guard let drive = selected else { return }
        let panel = NSOpenPanel()
        panel.title = "Select a release DMG to keep as a backup"
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg")!]
        guard panel.runModal() == .OK, let source = panel.url else {
            status.stringValue = "No installer selected; nothing copied or downloaded."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Keep a release copy on this drive?"
        alert.informativeText = "\(source.path)\n\nDestination: \(drive.root)/Installer/\n\nNo automatic download. Existing copies are not overwritten. Formatting this drive later also erases this installer. Host dependencies are still required on another Mac."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["copy-installer", "--drive", drive.id, "--source", source.path, "--confirm"]) { code, _ in
            self.status.stringValue = code == 0 ? "Verified installer copied to Installer." : "Installer not copied. See details."
        }
    }

    @objc private func copyAppToSSD() {
        guard let drive = selected, drive.mode == "portable", task == nil else {
            status.stringValue = "Choose an external SSD first."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Copy Couch Cube to this SSD?"
        alert.informativeText = "Copies this verified app to \(drive.mount)/CouchCube.app without erasing the SSD. Existing app copies are not overwritten. Open the SSD copy afterwards. Emulators are still installed separately on each Mac."
        alert.addButton(withTitle: "Copy app")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            execute(["copy-app", "--drive", drive.id, "--confirm"]) { code, _ in
                self.status.stringValue = code == 0 ? "App copied to SSD. Open that copy to continue." : "App copy failed. See Activity."
            }
        }
    }

    @objc private func prepareDisk() {
        execute(["disks"], capture: true) { code, data in
            guard code == 0 else { self.status.stringValue = "Cannot enumerate external physical disks."; return }
            do {
                self.disks = try JSONDecoder().decode([PhysicalDisk].self, from: data)
                guard !self.disks.isEmpty else {
                    self.status.stringValue = "No external physical disks attached. Internal disks and DMG devices are excluded."
                    return
                }
                let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 550, height: 28))
                menu.addItems(withTitles: self.disks.map {
                    "\($0.device) - \($0.model) - \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))"
                })
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Select a WHOLE external disk to prepare"
                alert.informativeText = "Erase destroys ALL volumes, partitions, games and any installer DMG on that physical disk. This is not normal setup. Nothing is erased by selecting a disk. Never unplug or swap disks during review."
                alert.accessoryView = menu
                alert.addButton(withTitle: "Review selected disk")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let disk = self.disks[menu.indexOfSelectedItem]
                self.reviewErase(disk)
            } catch {
                self.status.stringValue = "Cannot read physical disk list: \(error.localizedDescription)"
            }
        }
    }

    private func reviewErase(_ disk: PhysicalDisk) {
        execute(["format-plan", "--device", disk.device], capture: true) { code, data in
            guard code == 0 else {
                self.status.stringValue = "Automatic erase refused. Activity explains why; use Disk Utility only after checking the device yourself."
                let alert = NSAlert()
                alert.messageText = "Automatic erase is unavailable for this disk"
                alert.informativeText = self.lastError + "\n\nDisk Utility > View > Show All Devices lets you verify the physical disk and erase as APFS / GUID manually. If the disk contains this running app, first copy the app to a different disk and relaunch it there. Disk Utility asks for its own confirmation."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Open Disk Utility")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
                return
            }
            do {
                let plan = try JSONDecoder().decode(ErasePlan.self, from: data)
                let typed = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
                let phrase = "ERASE \(plan.device)"
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Permanently erase \(plan.device)?"
                alert.informativeText = "\(plan.model)\n\(ByteCountFormatter.string(fromByteCount: plan.size, countStyle: .file))\n\nFirst stages this app on another disk and verifies its bundle signature. No download needed. If verification fails, nothing is erased. This is an ad-hoc signature, not publisher authentication.\n\nThen ALL volumes and data, including any installer, will be destroyed. New format: APFS, GUID; name: Mac Gaming. The app is copied to the SSD root afterward.\n\nType exactly: \(phrase)\n\nIf macOS denies authorization, use Disk Utility manually. A failure after erasure cannot restore your data."
                alert.accessoryView = typed
                alert.addButton(withTitle: "Erase entire disk")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, typed.stringValue == phrase else {
                    self.status.stringValue = "Erase cancelled or typed confirmation did not match. Nothing erased."
                    return
                }
                self.execute(["erase", "--device", plan.device, "--token", plan.token,
                              "--typed", typed.stringValue, "--confirm", "--prepare-portable"]) { code, _ in
                    self.status.stringValue = code == 0 ? "Portable app is at the SSD root. Open it there and create your game library." : "Preparation failed/refused. Activity explains which stage failed. Inspect the disk; do not blindly erase again."
                    if code == 0 {
                        self.preparationResult.stringValue = "Your SSD is prepared. Open CouchCube.app from its root to continue with your portable copy, or choose the new volume below."
                        self.preparationResult.isHidden = false
                        self.preferredMode = "portable"
                        self.volumeMenu.select(nil)
                        self.selectPage(4)
                    }
                    self.refreshPending = true
                }
            } catch {
                self.status.stringValue = "Invalid erase plan: \(error.localizedDescription)"
            }
        }
    }

    @objc private func setup() {
        guard let drive = selected else { return }
        let alert = NSAlert()
        alert.messageText = report?.state == "not prepared" ? "Create and activate your library?" : "Use this library?"
        alert.informativeText = "\(drive.root)\n\nSets this as the active library on this Mac. Creates game folders and launcher files only, or updates this app's existing files. Your games and saves are kept; other libraries stay untouched.\n\nDoes not install Steam or emulators, change Steam's storage, add shortcuts to Steam or move existing games. Save automatic console mode again if it points to another library."
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.lastPathComponent == "ES-DE.app" }) {
            alert.informativeText += "\n\nES-DE is running. Quit it first so it won't overwrite updated frontend settings."
            status.stringValue = "Quit ES-DE before updating its configuration."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status.stringValue = "Cancelled. No changes made."
            return
        }
        append("\n--- Create/update library ---\n")
        execute(["setup", "--drive", drive.id, "--confirm"]) { code, _ in
            if code == 0 {
                self.status.stringValue = "Library activated. Install any missing apps in App Store."
                self.advanceAfterLibraryCheck = true
                self.refresh()
            } else {
                self.status.stringValue = "Library couldn't be updated. Your games are kept; Activity explains the problem."
            }
        }
    }

    @objc private func openFolder() {
        guard let drive = selected else { return }
        let path = URL(fileURLWithPath: drive.root)
        guard FileManager.default.fileExists(atPath: path.path) else {
            status.stringValue = "Run setup first, or reconnect the drive."
            return
        }
        NSWorkspace.shared.open(path)
    }

    @objc private func instructions() {
        NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("README.md"))
    }

    @objc private func registerGame() {
        guard let drive = selected else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a native game or Porting Kit wrapper on the selected drive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: drive.root)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let root = drive.root + "/"
        guard app.path.hasPrefix(root), app.pathExtension == "app" else {
            status.stringValue = "Choose a .app inside Native/Games or Windows/Wrappers on this drive."
            return
        }
        let relative = String(app.path.dropFirst(root.count))
        let kind = relative.hasPrefix("Native/Games/") ? "native" : "windows"
        let alert = NSAlert()
        alert.messageText = "Create a Steam-compatible shortcut?"
        alert.informativeText = "This creates a launcher .app. You still add it in Steam manually. Windows games must already have a working Wine wrapper. Name: letters, numbers, spaces, _ or -."
        let name = NSTextField(string: app.deletingPathExtension().lastPathComponent)
        name.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["register", "--root", drive.root, "--kind", kind, "--name", name.stringValue, "--app", relative]) { code, _ in
            self.status.stringValue = code == 0
                ? "Shortcut created in Launchers. Add it as a Non-Steam Game in Steam."
                : "Shortcut not created. See error details."
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if task != nil {
            status.stringValue = "Wait for the current operation. Disconnecting or force quitting may leave a partial setup."
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return task == nil ? .terminateNow : .terminateCancel
    }
}

/// `--controller-sheet <dir>` writes Retina (2x) PNG sheets, then exits. Nothing else runs.
/// - `controller-fills-<style>-<light|dark>.png`: every controller type × key colors, plus the full palette on DualSense.
/// - `controller-styles-<light|dark>.png`: outline (A) and double wall (B) side by side, at row and preview sizes.
/// They render the same `ControllerArtView` used in the app.
/// Couch Cube used the bundle identifier org.macgameconsole.setup before it was renamed.
/// Copy those preferences once so saved choices survive the change; the old domain is left for Cleanup.
func migrateLegacyDefaults() {
    let defaults = UserDefaults.standard
    let marker = "CouchCubeMigratedLegacyDefaults"
    guard !defaults.bool(forKey: marker) else { return }
    if let legacy = defaults.persistentDomain(forName: "org.macgameconsole.setup") {
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
    defaults.set(true, forKey: marker)
}

func renderControllerSheets(to folder: URL) -> Bool {
    let kinds = Array(ControllerArtwork.kinds.dropFirst())
    func label(_ text: String, _ frame: NSRect, size: CGFloat = 10, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        field.alignment = frame.width < 100 ? .center : .left
        field.lineBreakMode = .byTruncatingTail
        field.frame = frame
        return field
    }
    func art(_ kind: String, _ color: NSColor?, alpha: CGFloat, style: ControllerOutlineStyle,
             size: NSSize = NSSize(width: 52, height: 38), inset: CGFloat = 2, at origin: NSPoint) -> NSView {
        let view = ControllerArtView(kind: kind)
        view.style = style
        view.contentTintColor = color ?? ControllerPalette.color(named: ControllerPalette.defaultName(forKind: kind))
        view.alphaValue = alpha
        let frame = ControllerIconFrame(imageView: view, size: size, inset: inset)
        frame.frame = NSRect(origin: origin, size: size)
        frame.layoutSubtreeIfNeeded()
        return frame
    }
    func canvas(_ width: CGFloat, _ height: CGFloat, _ appearance: NSAppearance.Name) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.appearance = NSAppearance(named: appearance)
        root.wantsLayer = true
        root.appearance!.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        return root
    }
    func write(_ root: NSView, _ file: String) -> Bool {
        root.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * 2), pixelsHigh: Int(root.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: folder.appendingPathComponent(file))) != nil
    }
    let styleNames: [ControllerOutlineStyle: String] = [.outline: "A · Outline", .doubleWall: "B · Double wall"]
    let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    let columns: [(String, NSColor?, CGFloat)] = [("Automatic", nil, 1)] +
        ["Black", "White", "Classic Gray", "Gray Camouflage", "Mineral Camo", "Cosmic Red", "Neon Red", "Neon Orange",
         "Galactic Purple", "Cobalt Blue", "Neon Blue", "Micro Green", "Neon Yellow"].map { ($0, ControllerPalette.color(named: $0), 1) } +
        [("Disconnected", NSColor.systemGray, 0.55), ("Discovered", NSColor.tertiaryLabelColor, 1)]
    let cell = NSSize(width: 64, height: 46), labelWidth: CGFloat = 150, header: CGFloat = 40
    let palette = ControllerPalette.colors
    let perRow = 12
    let paletteRows = (palette.count + perRow - 1) / perRow
    let width = labelWidth + CGFloat(columns.count) * cell.width + 16
    let height = header + CGFloat(kinds.count) * cell.height + 40 + CGFloat(paletteRows) * (cell.height + 16) + 16
    for style in ControllerOutlineStyle.allCases {
        for (name, appearanceName) in appearances {
            let root = canvas(width, height, appearanceName)
            var y = height - header
            root.addSubview(label("Couch Cube controller fills · \(styleNames[style]!) · \(name)",
                                  NSRect(x: 12, y: height - 24, width: 500, height: 16), size: 13, bold: true))
            for (index, column) in columns.enumerated() {
                root.addSubview(label(column.0, NSRect(x: labelWidth + CGFloat(index) * cell.width, y: y + 4, width: cell.width, height: 14), size: 9))
            }
            for kind in kinds {
                y -= cell.height
                root.addSubview(label(kind, NSRect(x: 12, y: y + 14, width: labelWidth - 16, height: 14), size: 11))
                for (index, column) in columns.enumerated() {
                    root.addSubview(art(kind, column.1, alpha: column.2, style: style,
                                        at: NSPoint(x: labelWidth + CGFloat(index) * cell.width + 6, y: y + 4)))
                }
            }
            y -= 34
            root.addSubview(label("Full palette · PS5 · DualSense", NSRect(x: 12, y: y + 8, width: 400, height: 16), size: 12, bold: true))
            for (index, entry) in palette.enumerated() {
                let column = index % perRow, row = index / perRow
                let x = labelWidth + CGFloat(column) * cell.width, top = y - CGFloat(row + 1) * (cell.height + 16)
                root.addSubview(art("PS5 · DualSense", entry.1, alpha: 1, style: style, at: NSPoint(x: x + 6, y: top + 16)))
                root.addSubview(label(entry.0, NSRect(x: x, y: top, width: cell.width, height: 14), size: 8))
            }
            guard write(root, "controller-fills-\(style.rawValue)-\(name).png") else { return false }
        }
    }

    // Side-by-side: per color, A and B at the list-row size, then A and B at the customize-preview size.
    let compareColors = ["Black", "White", "Galactic Purple", "Gray Camouflage", "Mineral Camo", "Neon Red"]
    let small = NSSize(width: 52, height: 38), large = NSSize(width: 88, height: 60)
    let group = 2 * (small.width + 6) + 2 * (large.width + 6) + 18
    let rowHeight = large.height + 8
    let compareWidth = labelWidth + CGFloat(compareColors.count) * group + 16
    let compareHeight = header + 34 + CGFloat(kinds.count) * rowHeight + 16
    for (name, appearanceName) in appearances {
        let root = canvas(compareWidth, compareHeight, appearanceName)
        root.addSubview(label("Controller outline styles · A outline vs B double wall · row size, preview size · \(name)",
                              NSRect(x: 12, y: compareHeight - 24, width: 800, height: 16), size: 13, bold: true))
        var y = compareHeight - header
        for (index, color) in compareColors.enumerated() {
            let x = labelWidth + CGFloat(index) * group
            root.addSubview(label(color, NSRect(x: x, y: y + 4, width: group - 18, height: 14), size: 10, bold: true))
            let subs = [("A", small.width), ("B", small.width), ("A", large.width), ("B", large.width)]
            var sx = x
            for (tag, w) in subs {
                root.addSubview(label(tag, NSRect(x: sx, y: y - 12, width: w, height: 12), size: 9))
                sx += w + 6
            }
        }
        y -= 22
        for kind in kinds {
            y -= rowHeight
            root.addSubview(label(kind, NSRect(x: 12, y: y + rowHeight / 2 - 7, width: labelWidth - 16, height: 14), size: 11))
            for (index, color) in compareColors.enumerated() {
                var x = labelWidth + CGFloat(index) * group
                for (style, size, inset) in [(ControllerOutlineStyle.outline, small, CGFloat(2)), (.doubleWall, small, 2),
                                             (.outline, large, 4), (.doubleWall, large, 4)] {
                    root.addSubview(art(kind, ControllerPalette.color(named: color), alpha: 1, style: style, size: size, inset: inset,
                                        at: NSPoint(x: x, y: y + (rowHeight - size.height) / 2)))
                    x += size.width + 6
                }
            }
        }
        guard write(root, "controller-styles-\(name).png") else { return false }
    }
    return true
}

let application = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--controller-sheet"), CommandLine.arguments.indices.contains(index + 1) {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    exit(renderControllerSheets(to: folder) ? 0 : 1)
}
application.setActivationPolicy(.regular)
if !CommandLine.arguments.contains("--smoke-test") { migrateLegacyDefaults() }
let controller = SetupController()
application.delegate = controller
application.run()
