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
    let enabled: Bool
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

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSMenuItemValidation, CBCentralManagerDelegate {
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
    private var homeControllersAction: NSButton!
    private var homeControllerInputLabels: [String: NSTextField] = [:]
    private var homeControllerImages: [String: [NSImageView]] = [:]
    private var homeSessionControllers: [String] = []
    private var homeObservedConnections = Set<String>()
    private let homePlayBackground = NSView()
    private var homeTiles: NSStackView!
    private var sidebarAttention: [Int: NSColor] = [:]
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
    private let connectedFirstToggle = NSSwitch()
    private let controllerDefaultsKey = "controllerPreferences"
    private struct ControllerPreferences: Codable {
        var entries: [ControllerEntry]
        var customizations: [String: ControllerCustomization]
        var connectedFirst: Bool
        var recentControllerIDs: [String]? = nil
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
    private var appsHaveResults = true
    private var appRefreshPending = false
    private let appMenuRows = NSStackView()
    private let appPCRows = NSStackView()
    private let appWindowsRows = NSStackView()
    private let appRetroRows = NSStackView()
    private let consoleRows = NSStackView()
    private var consoleSystems: [ConsoleSystem] = []
    private var consolesChecking = false
    private var consolesLoaded = false
    private var consoleRefreshPending = false
    private var systemSwitches: [NSSwitch] = []
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
    private let libraryHealth = NSStackView()
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
    private enum OverviewCheck: CaseIterable { case storage, menu, consoles, automatic, steam }
    private var overviewChecks = Set<OverviewCheck>()
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

        libraryTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        libraryDescription.textColor = .secondaryLabelColor
        libraryAction.title = "Update game library..."
        libraryAction.target = self
        libraryAction.action = #selector(setup)
        libraryAction.bezelStyle = .rounded
        actions.append(libraryAction)
        libraryControls.append(libraryAction)
        let openGames = button("Open game folders", #selector(openFolder))
        let addGame = button("Add a game...", #selector(registerGame))
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
        let controllerCard = card("Controllers", subtitle: nil, views: [homeControllerStatus])
        homeControllersAction = TileActionButton(title: "", target: self, action: #selector(showControllers))
        homeControllersAction.isBordered = false
        homeControllersAction.toolTip = "Manage controllers"
        homeControllersAction.setAccessibilityLabel("Controllers")
        homeControllersAction.translatesAutoresizingMaskIntoConstraints = false
        controllerCard.contentView!.addSubview(homeControllersAction)
        pin(homeControllersAction, to: controllerCard.contentView!)
        controllerCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        for section in [playCard, controllerCard] {
            section.fillColor = .quaternaryLabelColor
            section.cornerRadius = 16
            section.borderWidth = 0
            if let contents = section.contentView?.subviews.first as? NSStackView,
               let title = contents.arrangedSubviews.first as? NSTextField {
                title.font = .systemFont(ofSize: 22, weight: .bold)
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
            card("TV menus", subtitle: nil, views: [appMenuRows]),
            card("PC games", subtitle: nil, views: [appPCRows]),
            card("Windows games", subtitle: nil, views: [appWindowsRows]),
            card("Retro games", subtitle: nil, views: [appRetroRows]),
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
        addPage("Game library", content: column([
            card("Storage", subtitle: nil, views: [
                libraryHealth, selectedStorage, libraryTitle, libraryDescription,
                row([openGames, addGame])
            ]),
            card("Manage library", subtitle: "Keep your game folders connected. No games are moved.", views: [
                libraryAction,
                button("Check Library", #selector(checkStorage)),
                button("Change Storage…", #selector(changeStorage))
            ]),
            card("Steam games", subtitle: "Your installed Steam games, grouped by storage. Connect your SSD to see its games.", views: [
                steamLibraryRows,
                row([button("Open Steam Storage", #selector(openSteamStorage)),
                     button("Refresh Steam status", #selector(refreshSteamStatus)),
                     button("Steam setup guide", #selector(showFinishing))])
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
        controllerAccessButton = controllerButton("Allow Bluetooth access", #selector(controllerBluetoothAccess))
        connectedFirstToggle.target = self
        connectedFirstToggle.action = #selector(controllerSortChanged)
        connectedFirstToggle.controlSize = .small
        connectedFirstToggle.setAccessibilityLabel("Show connected controllers first")
        loadControllerPreferences()
        addPage("Controllers", content: column([
            card("Connected Controllers", subtitle: "Your paired and connected controllers. Choose the pencil to set a name and color.", views: [
                settingsRow("Show connected first", subtitle: "Off keeps the list in its original order.",
                            symbol: "arrow.up.arrow.down", color: .systemGray, trailing: connectedFirstToggle),
                activeControllerRows
            ]),
            card("Manage Controllers", subtitle: nil, views: [
                controllerStatus, controllerAccessButton,
                row([controllerButton("Open Bluetooth Settings", #selector(openBluetooth)),
                     controllerButton("Open Controller Settings", #selector(openGameControllerSettings))])
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
        addPage("App Settings", content: column([
            card("App Settings", subtitle: nil, views: [
                settingsRow("App updates", subtitle: "Check for a new version of Couch Cube.",
                            symbol: "arrow.down.circle", color: .systemGreen,
                            trailing: row([button("Check...", #selector(checkUpdates)), updateButton]),
                            detail: updateStatus),
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

    @objc private func chooseLocal() { chooseMode("local") }
    @objc private func choosePortable() { chooseMode("portable") }

    private func renderStorageLocations() {
        clearRows(storageLocationRows)
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
        for (mode, title, symbol, action) in [
            ("local", "This Mac", "macmini", #selector(chooseLocal)),
            ("portable", "External SSD", "externaldrive", #selector(choosePortable))
        ] {
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

    private func renderSteamLibraries() {
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
                add(text(label + (library.available ? "\(steamStorageKind(library)) · \(count) games installed" : "Disconnected · Connect this drive"), size: 12))
                add(text(library.path, size: 11, secondary: true))
                if rows === steamLibraryRows {
                    for game in library.games {
                        let size = game.bytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                        add(text("\(game.name) · \(game.state)\(size)", size: 11, secondary: true))
                    }
                }
            }
            if report.libraries.isEmpty && report.errors.isEmpty {
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

    func centralManagerDidUpdateState(_ central: CBCentralManager) { refreshControllers() }

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
        controllerEntries = preferences.entries.filter { !$0.id.contains("session:") }.map {
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
        connectedFirstToggle.state = preferences.connectedFirst ? .on : .off
        let knownIDs = Set(controllerEntries.map(\.id))
        var recent: [String] = []
        for id in preferences.recentControllerIDs ?? controllerEntries.suffix(4).map(\.id) {
            if knownIDs.contains(id) && !recent.contains(id) { recent.append(id) }
        }
        homeSessionControllers = Array(recent.suffix(4))
        homeObservedConnections = []
    }

    private func saveControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        do {
            let preferences = ControllerPreferences(entries: controllerEntries.filter { !$0.id.contains("session:") },
                customizations: controllerCustomizations, connectedFirst: connectedFirstToggle.state == .on,
                recentControllerIDs: homeSessionControllers.filter { !$0.contains("session:") })
            let data = try JSONEncoder().encode(preferences)
            if data != UserDefaults.standard.data(forKey: controllerDefaultsKey) {
                UserDefaults.standard.set(data, forKey: controllerDefaultsKey)
            }
        } catch {
            controllerStatus.stringValue = "Couldn't save controller names. Activity has details."
            append("Couldn't save controller names: \(error.localizedDescription)\n")
        }
    }

    @objc private func controllerSortChanged() {
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    private var controllerPageVisible: Bool {
        tabs.selectedTabViewItem === tabs.tabViewItems[0] ||
            tabs.selectedTabViewItem === tabs.tabViewItems[8]
    }

    private func renderHomeControllers() {
        clearRows(homeControllerStatus)
        homeControllerInputLabels = [:]
        homeControllerImages = [:]
        let connected = controllerEntries.filter(\.connected)
        for entry in connected where !homeObservedConnections.contains(entry.id) {
            homeSessionControllers.removeAll { $0 == entry.id }
            homeSessionControllers.append(entry.id)
        }
        homeObservedConnections = Set(connected.map(\.id))
        while homeSessionControllers.count > 4 {
            let index = homeSessionControllers.firstIndex { id in
                !connected.contains { $0.id == id }
            } ?? 0
            homeSessionControllers.remove(at: index)
        }
        let recent = homeSessionControllers.compactMap { id in controllerEntries.first { $0.id == id } }
        if recent.isEmpty {
            homeControllerStatus.addArrangedSubview(text("Connect via USB or Bluetooth", size: 13, secondary: true))
        }
        for entry in recent {
            let customization = controllerCustomizations[entry.id]
            let name = customization?.name ?? ""
            let activity = text(entry.connected ? "Connected" : "Not connected", size: 11, secondary: true)
            homeControllerInputLabels[entry.id] = activity
            let kind = ControllerArtwork.kind(name: entry.name, preference: customization?.artwork)
            let image = NSImageView(image: ControllerArtwork.image(kind))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 52).isActive = true
            image.heightAnchor.constraint(equalToConstant: 38).isActive = true
            homeControllerImages[entry.id] = [image]
            let label = text(name.isEmpty ? entry.name : name, size: 12)
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = name.isEmpty ? entry.name : name
            let labels = column([label, activity])
            labels.spacing = 2
            let line = row([image, labels])
            line.spacing = 10
            homeControllerStatus.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: homeControllerStatus.widthAnchor).isActive = true
            updateHomeControllerActivity(entry.id)
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
        var parts = [connected ? "Connected" : "Not connected"]
        if connected, let entry = entry { parts.append(entry.connectionLabel) }
        if active { parts.append("Receiving input") }
        homeControllerInputLabels[id]?.stringValue = parts.joined(separator: " · ")
        homeControllerInputLabels[id]?.textColor = active ? .systemGreen : .secondaryLabelColor
        let customization = controllerCustomizations[id]
        let colorName = customization?.color ?? entry.map { ControllerPalette.defaultName(for: $0) } ?? "Shock Blue"
        let color = connected ? ControllerPalette.color(named: colorName) : .systemGray
        for image in homeControllerImages[id] ?? [] {
            image.contentTintColor = color
            ControllerPalette.applyContrast(to: image)
            image.wantsLayer = true
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

    @objc private func customizeController(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
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

    private func renderControllerList() {
        clearRows(activeControllerRows)
        controllerInputLabels = [:]
        let ordered = controllerEntries.enumerated().sorted {
            if connectedFirstToggle.state == .on && $0.element.connected != $1.element.connected {
                return $0.element.connected
            }
            return $0.offset < $1.offset
        }.map { $0.element }
        for entry in ordered {
            if !activeControllerRows.arrangedSubviews.isEmpty {
                let line = separator()
                activeControllerRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            }
            let customization = controllerCustomizations[entry.id]
            let customName = customization?.name ?? ""
            let edit = controllerButton("", #selector(customizeController(_:)))
            edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Customize controller")
            edit.identifier = NSUserInterfaceItemIdentifier(entry.id)
            edit.toolTip = "Rename and change icon color (\(entry.name))"
            edit.setAccessibilityLabel("Customize \(customName.isEmpty ? entry.name : customName)")
            let activity = text(entry.connected ? "Connected · \(entry.connectionLabel)" : "Not connected",
                                size: 12, secondary: true)
            controllerInputLabels[entry.id] = activity
            if entry.connected, let last = controllerLastInput[entry.id], Date().timeIntervalSince(last.date) < 1.5 {
                activity.stringValue += " · Receiving input"
            }
            let connectionDot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            connectionDot.contentTintColor = entry.connected ? .systemGreen : .systemGray
            connectionDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            connectionDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            connectionDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let connectionLine = row([connectionDot, activity])
            connectionLine.spacing = 5
            let info = column([connectionLine])
            info.spacing = 0
            let color = ControllerPalette.color(named: customization?.color ?? ControllerPalette.defaultName(for: entry))
            let line = settingsRow(customName.isEmpty ? entry.name : customName, subtitle: "",
                symbol: "gamecontroller.fill", color: color, trailing: edit,
                artwork: ControllerArtwork.image(ControllerArtwork.kind(name: entry.name, preference: customization?.artwork)),
                detail: info, neutralArtworkBackground: true)
            if let labels = (line as? NSStackView)?.arrangedSubviews[1] as? NSStackView {
                labels.spacing = 0
            }
            activeControllerRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        }
        if ordered.isEmpty {
            activeControllerRows.addArrangedSubview(text("No controllers yet. Connect one by USB or pair it below.", size: 12, secondary: true))
        }
    }

    private func mergeControllerList(_ connected: [ControllerEntry], paired: [PairedController]) {
        var current = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for device in paired {
            guard let address = controllerAddress(device.address) else { continue }
            let id = "bt:\(address)"
            if current[id] == nil {
                current[id] = ControllerEntry(id: id, name: device.name, connected: device.connected, transport: "Bluetooth")
            } else {
                current[id]?.name = device.name
            }
        }
        for index in controllerEntries.indices {
            if let updated = current.removeValue(forKey: controllerEntries[index].id) {
                controllerEntries[index] = updated
            } else {
                controllerEntries[index].connected = false
            }
        }
        controllerEntries += current.values.sorted { $0.id < $1.id }
        controllerEntries.removeAll { !$0.connected && $0.id.contains("session:") && !homeSessionControllers.contains($0.id) }
        renderControllerList()
        renderHomeControllers()
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

    private func receiveControllerInput(_ entry: ControllerEntry, message: String) {
        guard controllerPageVisible else { return }
        let now = Date()
        if let last = controllerLastInput[entry.id], last.message == message && now.timeIntervalSince(last.date) < 0.1 { return }
        if !controllerEntries.contains(where: { $0.id == entry.id }) {
            controllerEntries.append(entry)
            renderControllerList()
        } else if let index = controllerEntries.firstIndex(where: { $0.id == entry.id }),
                  !controllerEntries[index].connected {
            controllerEntries[index].connected = true
            renderHomeControllers()
        }
        controllerLastInput[entry.id] = (message, now)
        if tabs.selectedTabViewItem === tabs.tabViewItems[0] {
            if homeControllerInputLabels[entry.id] == nil { renderHomeControllers() }
            updateHomeControllerActivity(entry.id)
        }
        let name = controllerCustomizations[entry.id]?.name ?? ""
        if tabs.selectedTabViewItem === tabs.tabViewItems[8] {
            controllerTestStatus.stringValue = "\(name.isEmpty ? entry.name : name) · \(message)"
        }
        controllerInputLabels[entry.id]?.stringValue = "Connected · \(entry.connectionLabel) · Receiving input"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let last = self.controllerLastInput[entry.id],
                  last.date == now else { return }
            if let current = self.controllerEntries.first(where: { $0.id == entry.id }) {
                self.controllerInputLabels[entry.id]?.stringValue = current.connected ?
                    "Connected · \(current.connectionLabel)" : "Not connected"
            }
            self.updateHomeControllerActivity(entry.id)
        }
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
            controllerStatus.stringValue = "Read-only preview. No Bluetooth query, pairing or permission request."
            controllerAccessButton.isHidden = true
            renderControllerList()
            renderHomeControllers()
            return
        }
        controllerAccessButton.isHidden = CBManager.authorization == .allowedAlways
        switch CBManager.authorization {
        case .notDetermined:
            controllerAccessButton.title = "Allow Bluetooth access"
            controllerStatus.stringValue = "Allow Bluetooth access to show paired controllers. USB controllers work without it."
        case .denied, .restricted:
            controllerAccessButton.title = "Bluetooth privacy..."
            controllerStatus.stringValue = "Bluetooth access is off. Open Bluetooth privacy or pair in macOS Settings."
        case .allowedAlways:
            if bluetoothManager == nil {
                bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            controllerStatus.stringValue = bluetoothManager?.state == .poweredOff ?
                "Bluetooth is off. Turn it on in macOS Settings to pair a controller." :
                "Pair in macOS Bluetooth settings. Some Bluetooth LE pairings are only visible there."
        @unknown default:
            controllerStatus.stringValue = "Open macOS Bluetooth settings to pair a controller."
        }
        if controllerInputUnavailable {
            controllerStatus.stringValue += " Input activity unavailable. Check Input Monitoring in macOS Privacy & Security."
        }
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
        var attention: [Int: NSColor] = [:]
        if report != nil && !ready {
            attention[2] = report?.issues.isEmpty == false ? .systemRed : .systemYellow
        }
        if let report = report {
            if report.missing.contains("steam") && report.missing.contains("es-de") {
                attention[1] = .systemRed
            } else if frontend == nil {
                attention[10] = .systemYellow
            }
            if installedAppCount(computerGameApps.union(emulatorApps)) == 0 && attention[1] == nil {
                attention[1] = .systemYellow
            }
        }
        for (check, page) in [(OverviewCheck.storage, 2), (.menu, 1), (.consoles, 7), (.automatic, 10), (.steam, 6)] {
            if overviewCheckFailures.contains(check) && attention[page] == nil {
                attention[page] = .systemYellow
            }
        }
        for system in consoleSystems where system.enabled {
            if system.emulator_installed == false { attention[1] = .systemRed }
            if ["missing", "partial"].contains(system.bios?.state ?? "") { attention[7] = .systemRed }
            else if ["optional", "manual"].contains(system.bios?.state ?? "") && attention[7] == nil {
                attention[7] = .systemYellow
            }
        }
        if appStates.contains(where: { $0.installed && $0.update?.isEmpty == false }) && attention[1] == nil {
            attention[1] = .systemYellow
        }
        if couchCubeUpdateAvailable { attention[11] = .systemYellow }
        if sidebarAttention != attention {
            sidebarAttention = attention
            sidebar.reloadData()
        }
    }

    private let computerGameApps: Set<String> = ["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge"]
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
        guard report?.state == "valid layout", let drive = selected else {
            consoleSystems = []
            overviewChecks.remove(.consoles)
            renderGeneral()
            loadAutoLaunch()
            return
        }
        execute(["systems", "--root", drive.root], capture: true) { code, data in
            self.overviewChecks.remove(.consoles)
            if code == 0 {
                do {
                    self.consoleSystems = try JSONDecoder().decode([ConsoleSystem].self, from: data)
                    self.renderSystems()
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
        var rowViews: [NSView] = [image, label]
        if let color = sidebarAttention[sidebarPages[row]] {
            let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                                     accessibilityDescription: color == .systemRed ? "Action required" : "Needs attention")!)
            warning.contentTintColor = color
            warning.toolTip = color == .systemRed ? "Action required — open this page" : "Needs attention — open this page"
            warning.widthAnchor.constraint(equalToConstant: 14).isActive = true
            warning.heightAnchor.constraint(equalToConstant: 14).isActive = true
            rowViews += [NSView(), warning]
        }
        let contents = self.row(rowViews)
        contents.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(contents)
        cell.imageView = image
        pin(contents, to: cell)
        cell.setAccessibilityLabel(sidebarTitles[row])
        return cell
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

    private func fetchApps(updates: Bool, completed: ((Bool) -> Void)? = nil) {
        guard task == nil else {
            if completed == nil { appRefreshPending = true }
            appsStatus.stringValue = "An operation is running. App information will refresh when it finishes."
            completed?(false)
            return
        }
        appRefreshPending = false
        appsChecking = true
        if appStates.isEmpty {
            appsHaveResults = false
            let catalog = [
                ("steam", "Steam"), ("gog-galaxy", "GOG Galaxy"), ("ea", "EA app"),
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
        renderApps()
        appsStatus.stringValue = ""
        execute(updates ? ["apps", "--updates"] : ["apps"], capture: true) { code, data in
            self.appsChecking = false
            guard code == 0 else {
                self.renderApps()
                self.appsStatus.stringValue = "Couldn't read apps. Open Activity for the error."
                self.showActivity()
                completed?(false)
                return
            }
            do {
                self.appStates = try JSONDecoder().decode([ManagedApp].self, from: data)
                self.appsHaveResults = true
                self.helperButton.isHidden = self.appStates.first?.brew == true
                self.helperAdvice.isHidden = self.helperButton.isHidden
                if let report = self.report {
                    self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                             missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                             preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                    self.updateSetupSummary()
                }
                self.renderApps()
                self.renderTVMenus()
                precondition(self.appMenuRows.arrangedSubviews.count == 4)
                precondition(self.appPCRows.arrangedSubviews.count == 12)
                precondition(self.appWindowsRows.arrangedSubviews.count == 4)
                precondition(self.appRetroRows.arrangedSubviews.count == 12)
                precondition(Set([self.appMenuRows, self.appPCRows, self.appWindowsRows, self.appRetroRows]
                    .compactMap { $0.superview?.superview }.map { ObjectIdentifier($0) }).count == 4,
                    "Each Apps category must have its own card")
                self.appsStatus.stringValue = ""
                self.execute(["frontend"], capture: true) { code, data in
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

    private func renderApps() {
        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] { clearRows(rows) }
        let order = ["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch", "porting-kit", "crossover"]
        appStates.sort { (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100) }
        if let steam = appStates.firstIndex(where: { $0.id == "steam" }) {
            addAppRow(appStates[steam], index: steam, to: appMenuRows, title: "Steam Big Picture",
                      purpose: "Steam TV menu")
        }
        for (index, app) in appStates.enumerated() {
            let rows = app.id == "es-de" ? appMenuRows :
                computerGameApps.contains(app.id) ? appPCRows :
                ["porting-kit", "crossover"].contains(app.id) ? appWindowsRows : appRetroRows
            addAppRow(app, index: index, to: rows)
        }
        updateAllButton.isEnabled = task == nil && appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
        updateAllButton.isHidden = !appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
        if highlightedAppID != nil { DispatchQueue.main.async { self.highlightAppRow() } }
    }

    private let appPurposes = [
            "steam": "Steam games for Mac",
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
        let emulatorRow = row([statusIndicator(emulator.title, color: emulator.color),
                               appStoreLink(for: system), NSView()])
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
        control.contentTintColor = .controlAccentColor
        control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
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
        renderSystems()
        if task != nil && consolesChecking {
            consoleRefreshPending = true
            return
        }
        guard task == nil, let drive = selected, report?.state == "valid layout" else {
            consolesChecking = false
            renderSystems()
            consoleStatus.stringValue = "Create game folders in Settings → Library storage first. Wait for any current operation to finish."
            return
        }
        consoleRefreshPending = false
        consoleStatus.stringValue = ""
        execute(["systems", "--root", drive.root], capture: true) { code, data in
            self.consolesChecking = false
            guard code == 0 else {
                self.renderSystems()
                self.consoleStatus.stringValue = ""
                self.append("Couldn't read console selection.\n")
                self.showActivity()
                return
            }
            do {
                self.consoleSystems = try JSONDecoder().decode([ConsoleSystem].self, from: data)
                self.consolesLoaded = true
                self.renderSystems()
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
            toggle.isEnabled = consolesLoaded && !consolesChecking && task == nil
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
            let controls = row([info, toggle])
            let emulator = emulatorStatus(system)
            let initialCheck = consolesChecking && !consolesLoaded
            var indicators: [NSView] = [statusIndicator(initialCheck ? emulatorName(system) : emulator.title,
                color: initialCheck ? .systemBlue : emulator.color, pulsing: initialCheck), appStoreLink(for: system)]
            if system.enabled, let bios = system.bios, bios.state != "not-needed" {
                indicators.append(initialCheck
                    ? statusIndicator("BIOS", color: .systemBlue, pulsing: true)
                    : biosIndicator(bios))
            }
            indicators.append(NSView())
            let statusLine = row(indicators)
            statusLine.distribution = .fill
            statusLine.toolTip = emulator.help
            let line = settingsRow(system.name,
                subtitle: "",
                symbol: "gamecontroller.fill", color: .secondaryLabelColor, trailing: controls,
                artwork: ConsoleArtwork.image(for: system.id), detail: statusLine, bareArtwork: true)
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
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
            sections.append(row([pill("Copy search", symbol: "magnifyingglass", action: #selector(copyBIOSNames(_:)),
                                      value: query, help: "Copy search: " + query), NSView()]))
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

    @objc private func toggleSystem(_ sender: NSSwitch) {
        guard task == nil, !consolesChecking, consolesLoaded else {
            if let index = systemSwitches.firstIndex(of: sender) {
                sender.state = consoleSystems[index].enabled ? .on : .off
            }
            consoleStatus.stringValue = "Wait for the current operation before changing consoles."
            return
        }
        if sender.state == .on, let index = systemSwitches.firstIndex(of: sender) {
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
        saveSystems()
    }

    @objc private func saveSystems() {
        guard task == nil, let drive = selected, systemSwitches.count == consoleSystems.count, !consoleSystems.isEmpty else {
            consoleStatus.stringValue = "Load your console selection first. Create game folders in Settings → Library storage if needed."
            return
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.lastPathComponent == "ES-DE.app" }) {
            for (system, toggle) in zip(consoleSystems, systemSwitches) { toggle.state = system.enabled ? .on : .off }
            consoleStatus.stringValue = "Quit ES-DE first. It must not overwrite updated frontend settings."
            return
        }
        let enabled = zip(consoleSystems, systemSwitches).filter { $0.1.state == .on }.map { $0.0.id }
        consoleStatus.stringValue = "Saving console selection..."
        execute(["systems", "--root", drive.root, "--confirm", "--enabled"] + enabled) { code, _ in
            guard code == 0 else {
                for (system, toggle) in zip(self.consoleSystems, self.systemSwitches) {
                    toggle.state = system.enabled ? .on : .off
                }
                self.consoleStatus.stringValue = "Couldn't save console selection. Open Activity for details."
                self.pendingEmulatorInstall = nil
                self.pendingAppStoreID = nil
                self.showActivity()
                return
            }
            if let app = self.pendingEmulatorInstall {
                self.pendingEmulatorInstall = nil
                self.manage(app, action: "install")
            } else if let id = self.pendingAppStoreID {
                self.pendingAppStoreID = nil
                self.showAppInStore(id)
            }
            self.loadSystems()
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
        let gamingApps = Set(["Steam.app", "GOG Galaxy.app", "EA app.app", "Epic Games Launcher.app",
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
        systemSwitches.forEach { $0.isEnabled = !value }
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
                        precondition(Set(self.appStates.map { $0.id }) == Set(["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "porting-kit", "crossover", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]))
                        for app in self.appStates {
                            let iconURL = Bundle.main.resourceURL!.appendingPathComponent("AppIcons/\(app.id).png")
                            precondition(NSImage(contentsOf: iconURL) != nil, "Missing app icon: \(app.id)")
                        }
                        let porting = self.appStates.firstIndex { $0.id == "porting-kit" }!
                        precondition(self.appStates[porting + 1].id == "crossover")
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
                            precondition(labels.contains("Connected · Bluetooth") && labels.contains("Connected · USB"))
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
                            let controllerLines = self.activeControllerRows.arrangedSubviews.compactMap { $0 as? NSStackView }
                            precondition(controllerLines.count == self.controllerEntries.count)
                            for (entry, line) in zip(self.controllerEntries, controllerLines) {
                                let tile = line.arrangedSubviews[0]
                                let icon = tile.subviews[0] as! NSImageView
                                let selectedColor = self.controllerCustomizations[entry.id]?.color
                                let expected = ControllerPalette.color(named: selectedColor ?? ControllerPalette.defaultName(for: entry))
                                precondition(icon.contentTintColor == expected,
                                             "Controller outlines must use their selected color")
                                precondition(tile.layer?.backgroundColor == NSColor.quaternaryLabelColor.cgColor,
                                             "Controller icon backgrounds must stay gray")
                            }
                            let originalOrder = self.controllerEntries.map { $0.id }
                            self.connectedFirstToggle.state = .on
                            self.controllerSortChanged()
                            let sortedLabels = controllerLabels(self.activeControllerRows)
                            precondition(sortedLabels.firstIndex(of: "8BitDo Controller")! <
                                         sortedLabels.firstIndex(of: "Xbox Wireless Controller")!)
                            self.connectedFirstToggle.state = .off
                            self.controllerSortChanged()
                            precondition(self.controllerEntries.map { $0.id } == originalOrder)
                            let entry = self.controllerEntries[0]
                            self.receiveControllerInput(entry, message: "Button 1 pressed")
                            precondition(self.controllerTestStatus.stringValue == "Purple PS5 · Button 1 pressed")
                            precondition(self.controllerInputLabels[entry.id]?.stringValue == "Connected · Bluetooth · Receiving input")
                            precondition(self.controllerInputLabels[self.controllerEntries[2].id]?.stringValue == "Connected · USB")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 1, minimum: 0, maximum: 1) == "Button 1 pressed")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 0, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 7, usage: 1, value: 1, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 128, minimum: 0, maximum: 255) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 255, minimum: 0, maximum: 255) == "Stick / trigger X · 100%")
                            precondition(controllerAddress("AA-BB-CC-DD-EE-FF") == "aabbccddeeff")
                            precondition(controllerAddress("not an address") == nil)
                            let preferences = ControllerPreferences(entries: self.controllerEntries,
                                customizations: self.controllerCustomizations, connectedFirst: false)
                            let restored = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(preferences))
                            precondition(restored.customizations[entry.id]?.name == "Purple PS5")
                            precondition(restored.customizations[entry.id]?.color == "Galactic Purple")
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
                    precondition(self.homeControllerInputLabels.count == 2,
                                 "Home must list connected controllers only")
                    self.receiveControllerInput(homeEntry, message: "Button 1 pressed")
                    precondition(self.homeControllerInputLabels[homeEntry.id]?.stringValue == "Connected · Bluetooth · Receiving input")
                    precondition(self.homeControllerInputLabels[self.controllerEntries[2].id]?.stringValue == "Connected · USB",
                                 "Only the controller sending input should light up")
                    precondition(self.controllerTestStatus.stringValue == previousTestText,
                                 "Home input must not display detailed button information")
                    self.controllerLastInput[homeEntry.id] = ("Button 1 pressed", Date(timeIntervalSinceNow: -2))
                    self.updateHomeControllerActivity(homeEntry.id)
                    precondition(self.homeControllerInputLabels[homeEntry.id]?.stringValue == "Connected · Bluetooth",
                                 "Home activity must clear after input stops")
                    self.mergeControllerList([], paired: [])
                    precondition(self.homeControllerInputLabels.count == 2 &&
                                 self.homeControllerInputLabels.values.allSatisfy { $0.stringValue == "Not connected" },
                                 "Controllers seen this session must remain gray after disconnecting")
                    precondition(!self.homeControllerStatus.arrangedSubviews.contains {
                        ($0 as? NSTextField)?.stringValue == "Connect via USB or Bluetooth"
                    }, "Remembered disconnected controllers must not show the empty-state hint")
                    self.homeSessionControllers = []
                    self.renderHomeControllers()
                    precondition(self.homeControllerStatus.arrangedSubviews.contains {
                        ($0 as? NSTextField)?.stringValue == "Connect via USB or Bluetooth"
                    })
                    let savedEntries = self.controllerEntries
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
                    let remembered = ControllerPreferences(entries: self.controllerEntries,
                        customizations: self.controllerCustomizations,
                        connectedFirst: self.connectedFirstToggle.state == .on,
                        recentControllerIDs: self.homeSessionControllers)
                    let decoded = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(remembered))
                    self.restoreControllerPreferences(decoded)
                    self.renderHomeControllers()
                    precondition(self.homeSessionControllers == newer.map(\.id))
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
                    precondition(copies.map { $0.title } == ["dc_boot.bin", "dc_flash.bin", "Copy search"])
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
                    self.renderGeneral()
                    precondition(self.sidebarAttention[2] != nil, "Storage errors must mark the sidebar")
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
                    precondition(self.homeControllersAction.action == #selector(self.showControllers))
                    let hoverEvent = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber,
                        context: nil, subtype: 0, data1: 0, data2: 0)!
                    for control in [self.homeControllersAction, self.playAction].compactMap({ $0 as? TileActionButton }) {
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
                    precondition(!self.homeControllersAction.isBordered && self.homeControllersAction.title.isEmpty)
                    precondition(self.homeControllersAction.frame == self.homeControllersAction.superview!.bounds,
                                 "The entire controller tile must open controller settings")
                    precondition(!labels(in: self.homeControllerStatus).contains { $0.contains("controller") && $0.contains("connected") })
                    self.homeControllersAction.performClick(nil)
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
                    self.renderGeneral()
                    precondition(self.sidebarAttention[1] == .systemRed, "Missing apps must mark Apps in red")
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
            return
        }
        libraryControls.forEach { $0.isEnabled = true }
        let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
        modeLabel.stringValue = drive.mode == "local" ? "LOCAL CONSOLE  ·  ONLY THIS MAC" : "PORTABLE CONSOLE  ·  EXTERNAL SSD"
        summary.stringValue = "\(free) free  ·  \(drive.filesystem.uppercased())"
        summary.toolTip = drive.root
        selectedStorage.stringValue = "\(drive.name)\n\(drive.root)"
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
