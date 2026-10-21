import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


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
