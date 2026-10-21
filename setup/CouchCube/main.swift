import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


/// `--controller-sheet <dir>` writes Retina (2x) PNG sheets, then exits. Nothing else runs.
/// - `controller-fills-<style>-<light|dark>.png`: every controller type × key colors, plus the full palette on DualSense.
/// - `controller-styles-<light|dark>.png`: outline (A) and double wall (B) side by side, at row and preview sizes.
/// They render the same `ControllerArtView` used in the app.
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
