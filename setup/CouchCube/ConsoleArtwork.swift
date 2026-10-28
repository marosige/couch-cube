import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


enum ConsoleArtwork {
    static let groups: [(title: String, systems: [String])] = [
        ("Nintendo home consoles", ["nes", "snes", "n64", "gc", "wii", "wiiu", "switch"]),
        ("Nintendo handhelds", ["gb", "gbc", "gba", "nds", "n3ds"]),
        ("PlayStation home consoles", ["psx", "ps2", "ps3"]),
        ("PlayStation handhelds", ["psp"]),
        ("SEGA home consoles", ["mastersystem", "megadrive", "segacd", "sega32x", "saturn", "dreamcast"]),
        ("SEGA handhelds", ["gamegear"]),
        ("Other home consoles", ["pcengine", "neogeo", "arcade", "xbox"])
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
        case "gamegear": colors = (0x2B2C31, 0x666A73)
        case "dreamcast": colors = (0xEEEDE8, 0xF3F2EE)
        case "nds": colors = (0xE3E4E8, 0xECEDEF)
        case "n3ds": colors = (0x2E78C7, 0x5B9BE3)
        case "mastersystem", "sega32x": colors = (0x1F2024, 0x585B63)
        case "saturn": colors = (0xB9BBBF, 0xC8CACD)
        case "pcengine": colors = (0xEAE8E3, 0xF1EFEB)
        case "neogeo": colors = (0x2D2F34, 0x62666E)
        case "arcade": colors = (0xB3282E, 0xE0494F)
        case "xbox": colors = (0x2F7D32, 0x4CAF50)
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
            case "gamegear": solid(1, 7, 30, 18, 6)
            case "nds": solid(6, 2, 20, 12, 2); solid(6, 17, 20, 13, 2)
            case "n3ds": solid(5, 2, 22, 12, 2); solid(3, 16, 26, 13, 3)
            case "mastersystem": solid(2, 9, 28, 15, 2)
            case "sega32x": solid(8, 4, 16, 24, 2)
            case "saturn": solid(2, 8, 28, 16, 5)
            case "pcengine": solid(9, 9, 14, 14, 2)
            case "neogeo": solid(1, 10, 30, 12, 3)
            case "xbox": solid(5, 5, 22, 22, 11)
            case "arcade": solid(7, 2, 18, 28, 2)
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
            case "gamegear":
                box(1, 7, 30, 18, 6)
                box(10, 10, 12, 11, 1)
                pad(5, 15)
                dot(25, 13, 1.8)
                dot(28, 16, 1.8)
            case "nds":
                box(6, 2, 20, 12)
                box(9, 4, 14, 8, 1)
                box(6, 17, 20, 13)
                box(9, 19, 14, 8, 1)
            case "n3ds":
                box(5, 2, 22, 12)
                box(8, 4, 16, 8, 1)
                box(3, 16, 26, 13, 3)
                pad(8, 22)
                dot(24, 21)
            case "mastersystem":
                box(2, 9, 28, 15)
                box(5, 12, 8, 6, 1)
                stroke(17, 13, 26, 13)
                stroke(17, 17, 26, 17)
            case "sega32x":
                box(8, 4, 16, 24)
                stroke(11, 9, 21, 9)
                stroke(11, 13, 21, 13)
                dot(14, 22)
            case "saturn":
                box(2, 8, 28, 16, 5)
                disc(7, 10, 10)
                stroke(19, 12, 26, 12)
                dot(24, 19)
            case "pcengine":
                box(9, 9, 14, 14)
                stroke(12, 13, 20, 13)
                dot(14, 17)
            case "neogeo":
                box(1, 10, 30, 12, 3)
                box(4, 13, 9, 6, 1)
                dot(21, 15)
                dot(25, 15)
            case "xbox":
                box(5, 5, 22, 22, 11)
                stroke(10, 10, 22, 22)
                stroke(22, 10, 10, 22)
            case "arcade":
                box(7, 2, 18, 28)
                box(10, 5, 12, 9, 1)
                stroke(10, 19, 22, 19)
                dot(13, 23)
                dot(18, 23)
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
