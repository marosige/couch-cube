import AppKit
import CoreBluetooth
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
    static let kinds = ["Automatic", "Xbox", "PS4 · DualShock 4", "PS5 · DualSense", "PlayStation", "Switch Pro Controller", "Joy-Con", "Nintendo", "Steam Controller", "8BitDo SN30 Pro", "8BitDo Micro", "8BitDo Pro 2", "8BitDo Ultimate", "8BitDo", "Generic"]

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
        if model.contains("joycon") { return "Joy-Con" }
        if name.contains("pro controller") || model.contains("switchpro") { return "Switch Pro Controller" }
        if model.contains("steamcontroller") { return "Steam Controller" }
        if name.contains("nintendo") { return "Nintendo" }
        return "Generic"
    }

    static func image(_ kind: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 80, height: 52), flipped: true) { _ in
            NSColor.black.setStroke()
            func stroke(_ points: [(CGFloat, CGFloat)]) {
                let path = NSBezierPath()
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                if let first = points.first {
                    path.move(to: NSPoint(x: first.0, y: first.1))
                    for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
                }
                path.stroke()
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                let path = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                path.lineWidth = 1.8
                path.stroke()
            }
            if ["8BitDo", "8BitDo SN30 Pro", "8BitDo Micro"].contains(kind) {
                let micro = kind == "8BitDo Micro"
                let body = NSBezierPath(roundedRect: NSRect(x: micro ? 10 : 5, y: micro ? 12 : 8,
                                                           width: micro ? 60 : 70, height: micro ? 28 : 36),
                                        xRadius: micro ? 8 : 17, yRadius: micro ? 8 : 17)
                body.lineWidth = 2.3
                body.stroke()
                stroke([(15, 23), (27, 23)])
                stroke([(21, 17), (21, 29)])
                if !micro {
                    circle(31, 35, 4)
                    circle(49, 35, 4)
                }
                if kind == "8BitDo SN30 Pro" {
                    stroke([(12, 6), (26, 6)])
                    stroke([(54, 6), (68, 6)])
                }
                stroke([(36, 22), (38, 22)])
                stroke([(42, 22), (44, 22)])
                for p in [(59.0, 17.0), (54, 22), (64, 22), (59, 27)] { circle(p.0, p.1, 1.8) }
            } else if kind == "Nintendo" || kind == "Joy-Con" {
                let body = NSBezierPath(roundedRect: NSRect(x: 7, y: 5, width: 66, height: 42), xRadius: 10, yRadius: 10)
                body.lineWidth = 2
                body.stroke()
                stroke([(27, 6), (27, 46)])
                stroke([(53, 6), (53, 46)])
                if kind == "Joy-Con" {
                    stroke([(30, 8), (30, 44)])
                    stroke([(50, 8), (50, 44)])
                }
                circle(17, 17, 5)
                circle(63, 34, 5)
                stroke([(12, 34), (22, 34)])
                stroke([(17, 29), (17, 39)])
                for p in [(63.0, 12.0), (58, 17), (68, 17), (63, 22)] { circle(p.0, p.1, 1.5) }
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
                body.stroke()
                let playStation = ["PlayStation", "PS4 · DualShock 4", "PS5 · DualSense"].contains(kind)
                let symmetric = playStation || kind == "8BitDo Pro 2"
                let padX: CGFloat = symmetric ? 22 : 31
                let padY: CGFloat = symmetric ? 22 : 32
                if kind == "Steam Controller" {
                    circle(21, 21, 10)
                    circle(59, 21, 10)
                    circle(30, 35, 4)
                    stroke([(18, 21), (24, 21)])
                    stroke([(21, 18), (21, 24)])
                } else {
                    stroke([(padX - 5, padY), (padX + 5, padY)])
                    stroke([(padX, padY - 5), (padX, padY + 5)])
                    circle(symmetric ? 31 : 21, symmetric ? 33 : 20, 5)
                    circle(49, 33, 5)
                }
                if kind != "Steam Controller" {
                    for p in [(59.0, 16.0), (54, 21), (64, 21), (59, 26)] { circle(p.0, p.1, 1.8) }
                }
                if playStation {
                    if kind != "PlayStation" {
                        let touchpad = NSBezierPath(roundedRect: NSRect(x: dualSense ? 28 : 30, y: dualSense ? 8 : 12,
                                                                       width: dualSense ? 24 : 20, height: dualSense ? 13 : 10), xRadius: 3, yRadius: 3)
                        touchpad.lineWidth = 1.5
                        touchpad.stroke()
                    }
                    if dualSense {
                        stroke([(16, 31), (22, 40)])
                        stroke([(64, 31), (58, 40)])
                    }
                } else if kind == "Xbox" { circle(40, 16, 3) }
                else if kind == "Switch Pro Controller" {
                    stroke([(34, 14), (38, 14)])
                    stroke([(42, 12), (42, 16)])
                    stroke([(40, 10), (44, 10)])
                } else if kind == "8BitDo Ultimate" {
                    stroke([(34, 17), (36, 17)])
                    stroke([(44, 17), (46, 17)])
                    circle(40, 25, 2)
                    stroke([(14, 7), (25, 7)])
                    stroke([(55, 7), (66, 7)])
                } else if kind == "Steam Controller" { circle(40, 13, 3) }
                else if kind == "8BitDo Pro 2" {
                    stroke([(36, 20), (38, 20)])
                    stroke([(42, 20), (44, 20)])
                    stroke([(14, 6), (25, 6)])
                    stroke([(55, 6), (66, 6)])
                }
            }
            return true
        }
        image.isTemplate = true
        return image
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

    static func canonicalName(_ name: String, for entry: ControllerEntry) -> String {
        if colors.contains(where: { $0.0 == name }) { return name }
        if defaultName(for: entry) == "Micro Green" && name == "Green" { return "Micro Green" }
        return legacyNames[name] ?? defaultName(for: entry)
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

    static func menu(selecting selected: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.autoenablesItems = false
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

    static func selectedName(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    static func applyContrast(to view: NSImageView) {
        guard let rgb = view.contentTintColor?.usingColorSpace(.sRGB) else { view.shadow = nil; return }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard dark ? luminance < 0.22 : luminance > 0.72 else { view.shadow = nil; return }
        let halo = NSShadow()
        halo.shadowColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.75 : 0.6)
        halo.shadowBlurRadius = 1.2
        halo.shadowOffset = .zero
        view.shadow = halo
    }

    static func defaultName(for entry: ControllerEntry) -> String {
        switch ControllerArtwork.kind(name: entry.name, preference: nil) {
        case "8BitDo Micro": return "Micro Green"
        case "PS5 · DualSense": return "Chroma Indigo"
        case "Xbox", "PlayStation", "PS4 · DualShock 4": return "Black"
        case let kind where kind.hasPrefix("8BitDo"): return "Classic Gray"
        default: return "Shock Blue"
        }
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
    let name = property(kIOHIDProductKey)
    return ControllerEntry(id: id, name: name.isEmpty ? "Game controller" : name,
        connected: true, transport: transport == "USB" ? "Wired" :
            transport.hasPrefix("Bluetooth") ? "Bluetooth" : "Wireless / Other")
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

func isBluetoothController(deviceClass: UInt32, name: String) -> Bool {
    let peripheral = (deviceClass >> 8) & 0x1f == 5
    let subtype = (deviceClass >> 2) & 0x0f
    if peripheral && (subtype == 1 || subtype == 2) { return true }
    let name = name.lowercased()
    return ["dualsense", "dualshock", "xbox wireless", "xbox elite", "pro controller", "joy-con",
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

func verifiedBluetoothAlias(for id: String, knownBluetoothIDs: Set<String>) -> String? {
    let parts = id.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
    guard parts.count == 5, parts[0] == "hid", !parts[3].hasPrefix("Bluetooth"),
          parts[4].hasPrefix("serial:"),
          let address = controllerSerialAddress(String(parts[4].dropFirst("serial:".count))) else { return nil }
    let candidate = "bt:" + address
    return knownBluetoothIDs.contains(candidate) ? candidate : nil
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

let guidedSetupOrder = [2, 1, 10, 7, 8, 6, 11]
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
    private let sidebarPages = [-1, 0, 6, 1, 7, -1, 8, 10, 2, 11]
    private let sidebarTitles = ["Your console", "Couch Cube", "Game library", "App Store", "Retro consoles", "Settings", "Controllers", "Console Mode", "Library storage", "App Settings"]
    private let sidebarSymbols = ["", "house.fill", "books.vertical.fill", "storefront", "tv", "", "gamecontroller.fill", "power", "externaldrive.fill", "app"]
    private let screenTitle = NSTextField(labelWithString: "Couch Cube")
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
    private var bluetoothInquiry: IOBluetoothDeviceInquiry?
    private var bluetoothInquiryRestart: DispatchWorkItem?
    private var bluetoothPairing: IOBluetoothDevicePair?
    private var controllerBanner: NSBox!
    private var controllerSmokeBanner = false
    private let controllerDefaultsKey = "controllerPreferences"
    private struct ControllerPreferences: Codable {
        var entries: [ControllerEntry]
        var customizations: [String: ControllerCustomization]
        var connectedFirst: Bool
        var recentControllerIDs: [String]? = nil
        var aliases: [String: String]? = nil
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
    lazy var consoleRoot: () -> String? = { self.selected?.root }
    /// Injected in smoke tests; the default runs the backend off the main thread without the global busy state.
    lazy var consoleSaver: (_ root: String, _ enabled: [String], _ done: @escaping (Int32, String) -> Void) -> Void = { root, enabled, done in
        self.runBackendInBackground(["systems", "--root", root, "--confirm", "--enabled"] + enabled) { code, _, errors in done(code, errors) }
    }
    lazy var consoleRefresher: (_ root: String, _ done: @escaping (Int32, Data) -> Void) -> Void = { root, done in
        self.runBackendInBackground(["systems", "--root", root]) { code, data, _ in done(code, data) }
    }
    private let appsStatus = NSTextField(wrappingLabelWithString: "")
    private let consoleStatus = NSTextField(wrappingLabelWithString: "Create your game folders in Settings → Library storage first.")
    private let setupFolderStatus = NSTextField(wrappingLabelWithString: "Choose where to keep your games.")
    private let storageLocationRows = NSStackView()
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
    private let steamLibraryRows = NSStackView()
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
        let addControllerButton = headerIconButton("plus", label: "Add a controller", action: #selector(addController))
        let openControllersButton = headerIconButton("list.bullet", label: "Open Controllers", action: #selector(showControllers))
        let controllerHeader = cardHeader("Controllers", buttons: [addControllerButton, openControllersButton])
        controllerHeader.identifier = NSUserInterfaceItemIdentifier("home-controller-header")
        homeControllerStatus.spacing = 10
        let controllerCard = card("", subtitle: nil, views: [controllerHeader, homeControllerStatus])
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
        addPage("Couch Cube", content: column([
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
        storageLocationRows.orientation = .vertical
        storageLocationRows.alignment = .leading
        storageLocationRows.spacing = 0
        transferLibraryButton = button("Move library...", #selector(moveLibrary))
        retireLibraryButton = button("Move old library to Trash...", #selector(retireOldLibrary))
        retireLibraryButton.isHidden = true
        addPage("Library storage", content: column([
            card("Library storage", subtitle: "Choose where ROMs, BIOS, saves and portable games live. The app can stay on this Mac.", views: [
                setupFolderStatus, storageLocationRows,
                button("Refresh connected drives", #selector(refresh))
            ]),
            card("Move your library", subtitle: "Copy to another drive, verify the contents and activate it. The old copy stays until you choose to remove it. Steam libraries are moved in Steam.", views: [
                transferLibraryButton, retireLibraryButton
            ])
        ]))
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
        let steamHeader = cardHeader("Steam", buttons: [
            headerIconButton("arrow.clockwise", label: "Refresh Steam games", action: #selector(refreshSteamStatus)),
            headerIconButton("externaldrive", label: "Steam storage", action: #selector(openSteamStorage)),
            headerIconButton("questionmark.circle", label: "Steam setup guide", action: #selector(showFinishing))
        ])
        let retroHeader = cardHeader("Retro games", buttons: [
            headerIconButton("folder", label: "Open game folders", action: #selector(openFolder)),
            headerIconButton("arcade.stick.console", label: "Retro consoles", action: #selector(showConsoles))
        ])
        let storageHeader = cardHeader("Where your games live", buttons: [libraryStorageMenu()])
        addPage("Game library", content: column([
            card("", subtitle: nil, views: [yourGames, librarySummary]),
            card("", subtitle: nil, views: [steamHeader, steamLibraryRows]),
            card("", subtitle: nil, views: [
                retroHeader,
                text("Copy your game files into each console's folder. ES-DE lists them by console on the TV.", size: 12, secondary: true)
            ]),
            card("", subtitle: nil, views: [
                storageHeader, libraryHealth, selectedStorageView(), libraryTitle, libraryDescription, libraryAction
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
            ])
        ]))
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
                    self.updateStatus.stringValue = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        clearRows(storageLocationRows)
        updateSelectedStorageMarker()
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
        for (mode, title, symbol) in Self.storageModes {
            let action = mode == "local" ? #selector(chooseLocal) : #selector(choosePortable)
            let locations = storage.locations.filter { $0.drive.mode == mode }
            let isActive = active?.drive.mode == mode
            let ready = locations.filter(\.configured).count
            let description: String
            if isActive {
                description = "Active library · Choose to manage this storage."
            } else if ready > 0 {
                description = "Library available · Choose to activate it or manage this storage."
            } else if mode == "portable" && locations.isEmpty {
                description = "Connect an SSD to set up a library, or prepare a new drive."
            } else {
                description = "Not set up · Create a library here. Existing files are kept."
            }
            let tile = choice(title + (isActive ? " · Active" : ""), description, symbol: symbol, action: action)
            storageLocationRows.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: storageLocationRows.widthAnchor).isActive = true
        }
        transferLibraryButton.isEnabled = task == nil && active != nil &&
            storage.locations.contains { $0.drive.id != active?.drive.id }
        transferLibraryButton.toolTip = active == nil ? "Set up or activate a library first." : "Transfer the active Couch Cube library to another drive."
        retireLibraryButton.isHidden = lastLibraryTransfer == nil
        retireLibraryButton.isEnabled = task == nil && lastLibraryTransfer != nil
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
        selectPage(2)
    }

    @objc private func changeStorage() {
        selectPage(2)
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
        for (title, symbol, action) in [("Check Library", "checkmark.circle", #selector(checkStorage)),
                                        ("Change Storage…", "externaldrive", #selector(changeStorage))] {
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
        for rows in [steamLibraryRows, steamGuideRows] {
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
                if rows === steamLibraryRows {
                    let heading = text(label + (library.available ? "\(steamStorageKind(library)) · \(count == 1 ? "1 game" : "\(count) games")" :
                                                    "Disconnected drive · Connect it to play these games"), size: 11, secondary: true)
                    heading.font = .systemFont(ofSize: 11, weight: .semibold)
                    heading.toolTip = library.path
                    add(heading)
                    for game in library.games { add(steamGameRow(game)) }
                } else {
                    add(text(label + (library.available ? "\(steamStorageKind(library)) · \(count) games installed" : "Disconnected · Connect this drive"), size: 12))
                    add(text(library.path, size: 11, secondary: true))
                }
            }
            if !report.libraries.contains(where: { !$0.games.isEmpty }) && report.errors.isEmpty {
                if rows === steamLibraryRows {
                    let empty = row([text("No Steam games yet. Install one in Steam and it shows up here.", size: 12, secondary: true), NSView(),
                                     button("Open Steam", #selector(openSteamDesktop))])
                    empty.distribution = .fill
                    empty.identifier = NSUserInterfaceItemIdentifier("steam-empty")
                    add(empty)
                } else {
                    add(text("No Steam games found yet. Open Steam to install your first game.", size: 12, secondary: true))
                }
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

    @objc private func addController() {
        let alert = NSAlert()
        alert.messageText = "Add a controller"
        alert.informativeText = "Put your controller in pairing mode, then select it in macOS Bluetooth settings.\n\nPlayStation: hold Create/Share + PS until the light flashes.\nXbox: hold the Pair button until the Xbox light flashes.\nSwitch Pro / Joy-Con: hold Sync until the lights cycle.\n\nUSB controllers can be plugged straight in. Return here to see whether macOS recognizes it for games."
        alert.addButton(withTitle: "Open Bluetooth Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openBluetooth() }
    }

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
        for entry in controllerEntries {
            if let color = controllerCustomizations[entry.id]?.color {
                controllerCustomizations[entry.id]?.color = ControllerPalette.canonicalName(color, for: entry)
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
            aliases: controllerAliases.filter { !$0.key.contains("session:") })
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
        guard entry.connected else { return controllerBusy.contains(entry.id) ? "Connecting…" : "Not connected" }
        return "Connected"
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
        guard !entry.id.contains("session:"), entry.id.hasPrefix("bt:") || entry.id.hasPrefix("hid:") else { return [] }
        return controllerEntries.filter {
            $0.id != entry.id && !$0.id.contains("session:") &&
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
        let kind = ControllerArtwork.kind(name: entry.name, preference: customization?.artwork)
        let image = NSImageView(image: ControllerArtwork.image(kind))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 52).isActive = true
        image.heightAnchor.constraint(equalToConstant: 38).isActive = true
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
        let line = row([handle, image, labels, spacer, more])
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
        clearRows(homeControllerStatus)
        homeControllerInputLabels = [:]
        homeControllerImages = [:]
        homeControllerRowViews = [:]
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
        let colorName = customization?.color ?? entry.map { ControllerPalette.defaultName(for: $0) } ?? "Shock Blue"
        let color = connected ? ControllerPalette.color(named: colorName) : .systemGray
        for image in (homeControllerImages[id] ?? []) + (controllerImages[id] ?? []) {
            image.contentTintColor = color
            image.alphaValue = connected ? 1 : 0.55
            ControllerPalette.applyContrast(to: image)
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
        let color = ControllerPalette.menu(selecting: previous?.color ?? ControllerPalette.defaultName(for: entry))
        let artwork = NSPopUpButton()
        artwork.addItems(withTitles: ControllerArtwork.kinds)
        artwork.selectItem(withTitle: previous?.artwork ?? "Automatic")
        let contents = column([name, color, artwork])
        contents.frame = NSRect(x: 0, y: 0, width: 340, height: 108)
        name.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = contents
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controllerCustomizations[id] = ControllerCustomization(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                                               color: ControllerPalette.selectedName(in: color) ?? ControllerPalette.defaultName(for: entry),
                                                               artwork: artwork.titleOfSelectedItem)
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

    private func renderDiscoveredControllers() {
        clearRows(discoveredControllerRows)
        for device in discoveredControllers {
            let image = NSImageView(image: ControllerArtwork.image(ControllerArtwork.kind(name: device.name, preference: nil)))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.contentTintColor = .tertiaryLabelColor
            image.widthAnchor.constraint(equalToConstant: 52).isActive = true
            image.heightAnchor.constraint(equalToConstant: 38).isActive = true
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSTextField(labelWithString: device.name)
            name.font = .systemFont(ofSize: 13)
            name.lineBreakMode = .byTruncatingTail
            let pairing = controllerBusy.contains("pair:" + device.address)
            let status = NSTextField(labelWithString: pairing ? "Pairing…" : "Ready to pair")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            let labels = NSStackView(views: [name, status])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2
            let connect = NSButton(title: "Connect", target: self, action: #selector(pairDiscoveredController(_:)))
            connect.bezelStyle = .rounded
            connect.identifier = NSUserInterfaceItemIdentifier(device.address)
            connect.isEnabled = !pairing
            connect.setAccessibilityLabel("Connect \(device.name)")
            connect.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let line = row([spacer, image, labels, NSView(), connect])
            line.spacing = 10
            line.identifier = NSUserInterfaceItemIdentifier("discovered-controller")
            discoveredControllerRows.addArrangedSubview(separator())
            discoveredControllerRows.addArrangedSubview(line)
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            for view in discoveredControllerRows.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: discoveredControllerRows.widthAnchor).isActive = true
            }
        }
        discoveredControllerRows.isHidden = discoveredControllers.isEmpty
    }

    private func mergeControllerList(_ connected: [ControllerEntry], paired: [PairedController]) {
        var knownBluetooth = Set(controllerEntries.map(\.id).filter { $0.hasPrefix("bt:") })
        for device in paired { if let address = controllerAddress(device.address) { knownBluetooth.insert("bt:" + address) } }
        var current: [String: ControllerEntry] = [:]
        for var entry in connected {
            if controllerAliases[entry.id] == nil,
               let alias = verifiedBluetoothAlias(for: entry.id, knownBluetoothIDs: knownBluetooth) {
                controllerAliases[entry.id] = alias
            }
            let id = canonicalControllerID(entry.id)
            if let existing = current[id], existing.transport == "Wired" { continue }
            entry = ControllerEntry(id: id, name: entry.name, connected: true, transport: entry.transport)
            current[id] = entry
        }
        for device in paired {
            guard let address = controllerAddress(device.address) else { continue }
            let id = "bt:\(address)"
            if current[id] == nil {
                current[id] = ControllerEntry(id: id, name: device.name, connected: device.connected, transport: "Bluetooth")
            } else if current[id]?.transport == "Bluetooth" {
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

    private func linkController(_ alias: String, to canonical: String) {
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

    private func showControllerError(_ title: String, _ message: String, offerSettings: Bool = true) {
        append("\(title): \(message)\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if offerSettings { alert.addButton(withTitle: "Open Bluetooth Settings") }
        alert.addButton(withTitle: offerSettings ? "Close" : "OK")
        if alert.runModal() == .alertFirstButtonReturn && offerSettings { openBluetooth() }
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
            if status != kIOReturnSuccess {
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
        alert.informativeText = "This Mac removes the pairing. To use it again, put the controller in pairing mode and connect it again."
        alert.addButton(withTitle: "Forget Device")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
            self.controllerEntries.removeAll { $0.id == id }
            self.controllerCustomizations[id] = nil
            self.controllerAliases = self.controllerAliases.filter { $0.value != id }
            self.homeSessionControllers.removeAll { $0 == id }
            self.saveControllerPreferences()
            self.refreshControllers()
        }
    }

    private func startControllerDiscovery() {
        guard bluetoothInquiry == nil, !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              CBManager.authorization == .allowedAlways, bluetoothManager?.state == .poweredOn,
              tabs.selectedTabViewItem === tabs.tabViewItems[8] else { return }
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
        discoveredControllers.removeAll { controllerAddress($0.address) == controllerAddress(raw) }
        discoveredControllers.append(PairedController(name: name, address: raw, connected: false))
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
        guard let address = sender.identifier?.rawValue,
              let device = IOBluetoothDevice(addressString: address) else { return }
        stopControllerDiscovery()
        guard let pairing = IOBluetoothDevicePair(device: device) else {
            showControllerError("Couldn't pair", "macOS couldn't start pairing with this controller.")
            return
        }
        pairing.delegate = self
        let result = pairing.start()
        guard result == kIOReturnSuccess else {
            showControllerError("Couldn't pair", "\(bluetoothErrorText(result)) Put the controller back in pairing mode and try again.")
            startControllerDiscovery()
            return
        }
        bluetoothPairing = pairing
        controllerBusy.insert("pair:" + address)
        renderDiscoveredControllers()
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
        showControllerError("Pair in Bluetooth Settings", "This controller asks for a PIN code. Pair it in Bluetooth Settings.")
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let device = bluetoothPairing?.device()
        bluetoothPairing = nil
        controllerBusy = controllerBusy.filter { !$0.hasPrefix("pair:") }
        if error != kIOReturnSuccess {
            showControllerError("Couldn't pair", "\(bluetoothErrorText(error)) Put the controller back in pairing mode and try again.")
            renderDiscoveredControllers()
        } else if let device = device {
            discoveredControllers.removeAll { controllerAddress($0.address) == device.addressString.flatMap(controllerAddress) }
            _ = device.openConnection(self)
            if let address = device.addressString.flatMap(controllerAddress) { controllerBusy.insert("bt:" + address) }
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
        if tabs.selectedTabViewItem === tabs.tabViewItems[0] && homeControllerInputLabels[entry.id] == nil {
            renderHomeControllers()
        }
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
                if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8] { self.startControllerDiscovery() }
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
                tasks.append(SidebarTask(page: 2, color: .systemYellow, title: "Prepare your game library", setup: true))
            } else {
                tasks += report.issues.map { SidebarTask(page: 2, color: .systemRed, title: $0, setup: false) }
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
        for (check, page, title) in [(OverviewCheck.storage, 2, "Library storage couldn't be checked"),
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
        if neutralArtworkBackground { ControllerPalette.applyContrast(to: icon) }
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
        width.priority = isHome ? .required : .defaultHigh
        width.isActive = true
        page.view = scroll
        tabs.addTabViewItem(page)
    }

    private func selectPage(_ index: Int) {
        if index == 3 { selectPage(2); return }
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        if !replayingHistory && (historyIndex < 0 || pageHistory[historyIndex].page != index ||
            (index == 9 && pageHistory[historyIndex].systemID != inspectorSystemID)) {
            pageHistory = Array(pageHistory.prefix(historyIndex + 1))
            pageHistory.append((index, index == 9 ? inspectorSystemID : nil))
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
        screenTitle.stringValue = index == 0 ? "Couch Cube" : index == 9 ? inspectorTitle.stringValue : (index == 3 || index == 4) ? "Library storage" :
            index == 5 ? "Steam setup guide" :
            sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube"
        storageNext.isHidden = index != 4
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playAction.keyEquivalent = index == 0 ? "\r" : ""
        let sidebarPage = (index == 3 || index == 4) ? 2 : index == 5 ? 6 : index == 9 ? inspectorParent : index
        if let selected = sidebarPages.firstIndex(of: sidebarPage), sidebar.selectedRow != selected {
            sidebar.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        controllerTimer?.invalidate()
        controllerTimer = nil
        if index != 8 && index != 0 { stopControllerTest() }
        if index != 8 { stopControllerDiscovery() }
        if index == 8 || index == 0 {
            refreshControllers()
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                startControllerTest()
                controllerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshControllers() }
            }
        }
        if index == 0 { renderGeneral() }
        if index == 2 { renderStorageLocations() }
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
        } else {
            selectPage(destination.page)
        }
        loadPageData(destination.page)
    }

    private func loadPageData(_ page: Int) {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        if page == 10 { loadAutoLaunch() }
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
        selectPage(2)
        loadPageData(2)
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
                self.showActivity()
                completed?(false)
                return
            }
            do {
                let decoded = try JSONDecoder().decode([ManagedApp].self, from: data)
                // Unchanged results keep the rendered rows (scroll position, hover, focus) untouched.
                let unchanged = silent && data == self.lastAppsData
                self.lastAppsData = data
                self.appStates = decoded
                self.appsHaveResults = true
                self.helperButton.isHidden = self.appStates.first?.brew == true
                self.helperAdvice.isHidden = self.helperButton.isHidden
                if let report = self.report {
                    self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                             missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                             preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                    self.updateSetupSummary()
                }
                if !unchanged { self.renderApps() }
                self.renderTVMenus()
                self.renderGeneral()
                if self.collapsedAppCategories.isEmpty {
                    precondition(self.appMenuRows.arrangedSubviews.count == 4)
                    precondition(self.appPCRows.arrangedSubviews.count == 14)
                    precondition(self.appWindowsRows.arrangedSubviews.count == 4)
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
        if let steam = appStates.firstIndex(where: { $0.id == "steam" }) {
            if appStates[steam].installed || !collapsedAppCategories.contains("TV menus") {
                addAppRow(appStates[steam], index: steam, to: appMenuRows, title: "Steam Big Picture",
                          purpose: "Steam TV menu")
            }
        }
        for (index, app) in appStates.enumerated() {
            let rows = app.id == "es-de" ? appMenuRows :
                computerGameApps.contains(app.id) ? appPCRows :
                ["porting-kit", "crossover"].contains(app.id) ? appWindowsRows : appRetroRows
            if !app.installed && collapsedAppCategories.contains(appCategoryTitle(for: rows)) {
                hiddenApps[ObjectIdentifier(rows), default: 0] += 1
                continue
            }
            addAppRow(app, index: index, to: rows)
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
        let hasUpdate = app.installed && app.managed && app.update?.isEmpty == false
        let controls = row([])
        if app.id == "crossover" && app.installed {
            let open = button("Open", #selector(openCrossOver(_:)))
            open.tag = index
            controls.addArrangedSubview(open)
        }
        if app.installed {
            controls.addArrangedSubview(appPillButton("Remove", app: app, index: index,
                                                      action: #selector(appAction(_:)), destructive: true))
        } else {
            controls.addArrangedSubview(appPillButton("Get", app: app, index: index, action: #selector(appAction(_:))))
        }
        let unknown = !appsHaveResults && app.path.isEmpty && app.version.isEmpty
        let initialCheck = appsChecking && unknown
        let state = unknown ? (appsChecking ? "Checking..." : "Not checked") :
            app.installed ? (hasUpdate ? "Installed · Update available" : "Installed") : "Not installed"
        let statusLine = row([statusIndicator(state,
            color: initialCheck ? .systemBlue : unknown ? .systemGray :
                app.installed ? hasUpdate ? .systemYellow : .systemGreen : .systemRed,
            pulsing: initialCheck), NSView()])
        controls.isHidden = unknown
        controls.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = !appsChecking }
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
        rows.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        let separator = self.separator()
        rows.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
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
        showActivity()
    }

    private func updateNextApp(_ remaining: [ManagedApp]) {
        guard let app = remaining.first else { loadApps(); return }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            let message = "Quit \(app.name), then try Update all again."
            append(message + "\n")
            fetchApps(updates: false) { success in
                if success { self.appsStatus.stringValue = message }
            }
            return
        }
        execute(["manage-app", "--package", app.id, "--action", "update", "--confirm"]) { code, _ in
            if code == 0 { self.updateNextApp(Array(remaining.dropFirst())) }
            else {
                let message = "Update stopped at \(app.name). Open Activity for details."
                self.fetchApps(updates: false) { success in
                    if success { self.appsStatus.stringValue = message }
                }
            }
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
        execute(["manage-app", "--package", app.id, "--action", action, "--confirm"]) { code, _ in
            if code == 0 { self.loadApps() }
        }
        showActivity()
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
            consoleStatus.stringValue = "Create game folders in Settings → Library storage first. Wait for any current operation to finish."
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
                self.consoleStatus.stringValue = ""
                self.append("Couldn't read console selection.\n")
                self.showActivity()
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
            let box = card(manufacturer, subtitle: nil, views: [rows])
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
                    addSectionHeading(group == "Nintendo home consoles" ? "Home consoles" : "Handhelds", to: rows)
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
        return true
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
                DispatchQueue.main.async { completed(1, Data(), "Cannot start bundled runtime: \(error.localizedDescription)") }
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
            DispatchQueue.main.async { completed(code, data, String(decoding: errorData, as: UTF8.self)) }
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
        func pill(_ title: String, symbol: String, action: Selector, value: String, help: String) -> NSButton {
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
            revertConsoleSelection("Load your console selection first. Create game folders in Settings → Library storage if needed.")
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
                self.showActivity()
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
            guard code == 0 else { self.showActivity(); return }
            do {
                let plan = try JSONDecoder().decode(CleanupPlan.self, from: data)
                self.presentGamingCleanup(plan)
            } catch {
                self.status.stringValue = "Couldn't read cleanup items: \(error.localizedDescription)"
                self.append(self.status.stringValue + "\n")
                self.showActivity()
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
                self.showActivity()
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
                            self.showActivity()
                        } else if removeSelf.state == .on {
                            NSApp.terminate(nil)
                        } else {
                            if targets.paths.contains(where: { $0.hasSuffix("/org.macgameconsole.setup.plist") }),
                               let identifier = Bundle.main.bundleIdentifier {
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
                self.showActivity()
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
                self.showActivity()
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
                self.showActivity()
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
            autoLaunchStatus.stringValue = "Choose Settings → Library storage before enabling automatic console mode."
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
                self.showActivity()
            }
        }
    }

    @objc private func showActivity() {
        if logWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Activity"
            panel.isReleasedWhenClosed = false
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
        let readOnly = capture && ["drives", "storage-status", "assess", "apps", "systems", "system-catalog", "login-status", "frontend", "steam-status"].contains(arguments.first ?? "")
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
            lastError = "Cannot start bundled runtime: \(error.localizedDescription)"
            append(lastError + "\n")
            status.stringValue = lastError
            showActivity()
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
                if process.terminationStatus != 0 && !capture { self.showActivity() }
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
                    if [1, 2].contains(self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!)) {
                        self.loadApps()
                    }
                }
                if self.refreshPending && self.task == nil && !self.smokeFinishing {
                    self.refreshPending = false
                    self.refresh()
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
                self.showActivity()
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
                        precondition(!self.steamLibraryRows.arrangedSubviews.isEmpty)
                        precondition(!self.steamGuideRows.arrangedSubviews.isEmpty)
                        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
                        let gameRows = self.steamLibraryRows.arrangedSubviews.filter { $0.identifier?.rawValue == "steam-game" || $0.identifier?.rawValue == "steam-empty" }
                        precondition(!gameRows.isEmpty, "Steam games must be listed as game rows or a clear empty state")
                        for game in self.steamReport!.libraries.flatMap(\.games) where game.installed {
                            precondition(views(self.steamLibraryRows).contains { ($0 as? NSButton)?.identifier?.rawValue == game.appid && ($0 as? NSButton)?.title == "Play" },
                                         "Installed Steam games need a Play button")
                        }
                        precondition(!self.librarySummary.stringValue.isEmpty)
                        let page = self.tabs.tabViewItems[6].view!
                        precondition(views(page).contains { $0.identifier?.rawValue == "library-storage-menu" })
                        let menu = views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "library-storage-menu" }!
                        precondition(menu.itemArray.dropFirst().map(\.title) == ["Check Library", "Change Storage…"])
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
                        let mixed = sidebarBadges([SidebarTask(page: 2, color: .systemYellow, title: "a", setup: true),
                                                   SidebarTask(page: 2, color: .systemRed, title: "b", setup: false),
                                                   SidebarTask(page: 2, color: .systemYellow, title: "c", setup: false),
                                                   SidebarTask(page: 7, color: .systemRed, title: "d", setup: false)], guided: true)
                        precondition(mixed.keys.sorted() == [2] && mixed[2]?.groups.map(\.count) == [1, 2] &&
                                     mixed[2]?.groups[1].titles == ["a", "c"], "Guided step keeps both severity counts; later pages stay hidden")
                        // Guided step stays put while checks arrive in any order.
                        let storageTask = SidebarTask(page: 2, color: .systemYellow, title: "Prepare", setup: true)
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
                        precondition(step.pinned == 2 && step.badges.keys.sorted() == [2], "Once done, the next step in order appears")
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
                    && self.tabs.numberOfTabViewItems == 12 && self.logWindow == nil
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
                            (page == 3 || page == 4) ? 2 : page == 5 ? 6 : page == 9 ? self.inspectorParent : page))
                        self.assertSmokePageScrolls()
                        if page == 7 {
                            for toggle in self.systemSwitches {
                                precondition(toggle.controlSize == .small)
                                let controls = toggle.superview!
                                let frame = toggle.convert(toggle.bounds, to: controls)
                                precondition(abs(frame.maxX - controls.bounds.maxX) < 4, "Console switches must align to the right edge")
                            }
                            if !self.esdeRunning { self.smokeTestRapidConsoleToggles() }
                            if !self.esdeRunning { self.smokeTestSilentRefresh() }
                        }
                        if page == 2 {
                            let saved = self.storageStatus
                            let sample = self.availableVolumes[0]
                            self.storageStatus = StorageStatus(locations: [
                                StorageStatus.Location(drive: sample, configured: true, issue: nil)
                            ], active: StorageStatus.Active(id: sample.id, uuid: sample.uuid), transfer: nil)
                            self.renderStorageLocations()
                            precondition(self.storageLocationRows.arrangedSubviews.count == 2)
                            precondition(self.setupFolderStatus.stringValue.hasPrefix("Active · "))
                            precondition(self.setupFolderStatus.isDescendant(of: self.tabs.tabViewItems[2].view!),
                                         "Library storage must open the chooser directly")
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
                            precondition(ControllerPalette.defaultName(for: ControllerEntry(
                                id: "micro", name: "8BitDo Micro", connected: true, transport: "Bluetooth")) == "Micro Green")
                            precondition(ControllerPalette.defaultName(for: self.controllerEntries[0]) == "Chroma Indigo")
                            func identified(_ view: NSView, _ id: String) -> [NSView] {
                                (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap { identified($0, id) }
                            }
                            precondition(labels.filter { $0 == "Connected" }.count == 2 && labels.contains("25%") && labels.contains("60%"))
                            let controllerLines = self.controllerRowIDs.compactMap { self.controllerRowViews[$0] as? NSStackView }
                            precondition(controllerLines.count == self.controllerEntries.count)
                            for (entry, line) in zip(self.controllerEntries, controllerLines) {
                                precondition(line.arrangedSubviews.first is ControllerDragHandle, "Controllers need a drag handle")
                                precondition(line.arrangedSubviews.last is NSPopUpButton, "Controllers need a … menu")
                                let icon = line.arrangedSubviews[1] as! NSImageView
                                let selectedColor = self.controllerCustomizations[entry.id]?.color
                                let expected = entry.connected ?
                                    ControllerPalette.color(named: selectedColor ?? ControllerPalette.defaultName(for: entry)) : NSColor.systemGray
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
                                [self.window.frame, self.activeControllerRows.frame] +
                                    self.activeControllerRows.arrangedSubviews.map(\.frame) +
                                    (self.controllerRowViews[entry.id].map { row in [row.frame] + row.subviews.map(\.frame) } ?? [])
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
                    precondition(self.consoleRows.arrangedSubviews.count == 3,
                                 "Nintendo, PlayStation and SEGA must each have one card")
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
                    for (name, expected) in [
                        ("DualShock 4 Wireless Controller", "PS4 · DualShock 4"),
                        ("PS4 Controller", "PS4 · DualShock 4"),
                        ("DualSense Wireless Controller", "PS5 · DualSense"),
                        ("DualSense Edge", "PS5 · DualSense"),
                        ("PS5 Controller", "PS5 · DualSense"),
                        ("PlayStation Controller", "PlayStation"),
                        ("Joy-Con (L)", "Joy-Con"),
                        ("Joy-Con (R)", "Joy-Con"),
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
                    precondition(self.sidebarAttention[2] != nil, "Storage errors must mark the sidebar")
                    self.guidedSetup = true
                    self.renderGeneral()
                    precondition(self.sidebarAttention[2] != nil && self.sidebarAttention.count == 1,
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
                    precondition(controllerHeaderButtons.map { $0.action } == [#selector(self.addController), #selector(self.showControllers)])
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
                    controllerHeaderButtons[1].performClick(nil)
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8])
                    self.selectPage(0)
                    precondition(Array(self.sidebarPages.prefix(5)) == [-1, 0, 6, 1, 7])
                    precondition(self.sidebarTitles[1] == "Couch Cube" && self.sidebarSymbols[1] == "house.fill")
                    precondition(self.sidebarTitles[self.sidebarPages.firstIndex(of: 1)!] == "App Store")
                    for page in [0, 6, 1, 7, 8, 10, 2, 11] {
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
                    self.goBack()
                    precondition(self.screenTitle.stringValue == "Couch Cube")
                    self.goForward()
                    precondition(self.screenTitle.stringValue == "Library storage")
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
                print(ok ? "Native UI smoke test passed: settings navigation, apps, consoles and controller preview; no setup or pairing executed."
                         : "Portable manager smoke test failed: \(self.status.stringValue)")
                exit(ok ? 0 : 1)
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

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = SetupController()
application.delegate = controller
application.run()
