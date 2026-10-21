import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers

/// The Cube TV tile's background for each TV menu, drawn in code so it stays sharp at any size:
/// the menu's own colors, a soft glow, its app logo and a short name, like an Apple TV top shelf.
enum TVMenuArtwork {
    static let size = NSSize(width: 1280, height: 720)

    /// `appIcon` is the installed app's own icon (full resolution); the bundled 128 px icon is the fallback.
    static func image(for menu: String?, appIcon: NSImage? = nil) -> NSImage {
        let style: (top: NSColor, bottom: NSColor, glow: NSColor, icon: String?, title: String, kicker: String)
        switch menu {
        case "steam":
            style = (NSColor(srgbRed: 0.09, green: 0.16, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.05, green: 0.07, blue: 0.11, alpha: 1),
                     NSColor(srgbRed: 0.40, green: 0.75, blue: 0.96, alpha: 1), "steam", "Big Picture", "STEAM")
        case "es-de":
            style = (NSColor(srgbRed: 0.33, green: 0.07, blue: 0.11, alpha: 1), NSColor(srgbRed: 0.09, green: 0.03, blue: 0.06, alpha: 1),
                     NSColor(srgbRed: 0.98, green: 0.36, blue: 0.33, alpha: 1), "es-de", "Retro Games", "ES-DE")
        default:
            style = (NSColor(srgbRed: 0.20, green: 0.16, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.06, green: 0.05, blue: 0.12, alpha: 1),
                     NSColor(srgbRed: 0.62, green: 0.50, blue: 1.0, alpha: 1), nil, "Choose a TV menu", "CUBE TV")
        }
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: style.top, ending: style.bottom)?.draw(in: rect, angle: -90)
            // A soft light behind the logo, like a TV glowing in a dark room.
            let glow = NSGradient(colors: [style.glow.withAlphaComponent(0.55), style.glow.withAlphaComponent(0)])
            glow?.draw(fromCenter: NSPoint(x: rect.midX, y: rect.height * 0.6), radius: 0,
                       toCenter: NSPoint(x: rect.midX, y: rect.height * 0.6), radius: rect.height * 0.75, options: [])
            // Fine scanlines give the TV feel without competing with the logo.
            NSColor.white.withAlphaComponent(0.035).setFill()
            for y in stride(from: 0, to: rect.height, by: 6) { NSRect(x: 0, y: y, width: rect.width, height: 2).fill() }
            // The Play tile crops the sides (it can be as narrow as a square), so everything sits in the
            // centered 720 × 720 safe area: logo above, kicker and name below, all centered.
            let logoSide: CGFloat = 250
            let logoRect = NSRect(x: rect.midX - logoSide / 2, y: rect.height * 0.52 - logoSide / 2 + 40,
                                  width: logoSide, height: logoSide)
            if let id = style.icon,
               let logo = appIcon ?? Bundle.main.resourceURL.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("AppIcons/\(id).png")) }) {
                NSGraphicsContext.current?.imageInterpolation = .high
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
                shadow.shadowBlurRadius = 40
                shadow.shadowOffset = NSSize(width: 0, height: -12)
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                logo.draw(in: logoRect)
                NSGraphicsContext.restoreGraphicsState()
            } else if let symbol = NSImage(systemSymbolName: "sparkles.tv.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 200, weight: .regular)
                            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.9)]))) {
                symbol.draw(in: logoRect.insetBy(dx: 10, dy: 30))
            }
            guard style.icon != nil else { return true }
            let kicker = NSAttributedString(string: style.kicker, attributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .heavy), .kern: 8,
                .foregroundColor: style.glow.blended(withFraction: 0.4, of: .white) ?? .white])
            // Shrinks to fit the safe area, so a longer name never runs off the cropped tile.
            var size: CGFloat = 84
            var title = NSAttributedString()
            repeat {
                title = NSAttributedString(string: style.title, attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.white])
                size -= 4
            } while title.size().width > 640 && size > 40
            kicker.draw(at: NSPoint(x: rect.midX - kicker.size().width / 2, y: logoRect.minY - 70))
            title.draw(at: NSPoint(x: rect.midX - title.size().width / 2, y: logoRect.minY - 70 - title.size().height))
            return true
        }
    }
}
