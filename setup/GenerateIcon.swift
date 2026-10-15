import AppKit

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--set-file-icon" {
    guard let image = NSImage(contentsOfFile: CommandLine.arguments[2]),
          NSWorkspace.shared.setIcon(image, forFile: CommandLine.arguments[3], options: []) else {
        fputs("Cannot assign the local disk-image icon.\n", stderr)
        exit(1)
    }
    exit(0)
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon() {
    NSGraphicsContext.saveGraphicsState()
    NSAffineTransform(transform: AffineTransform(m11: 1, m12: 0, m21: 0, m22: -1, tX: 0, tY: 1024)).concat()
    let silhouette = NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 992, height: 992), xRadius: 218, yRadius: 218)
    color(0x718C91).setFill()
    silhouette.fill()
    silhouette.addClip()

    rounded(NSRect(x: -160, y: -130, width: 840, height: 462), 42, color(0x242A2D))
    rounded(NSRect(x: -144, y: -114, width: 808, height: 424), 28, color(0x10191E))
    rounded(NSRect(x: -100, y: 310, width: 742, height: 8), 4, color(0x424D52))

    color(0x9C704E).setFill()
    NSRect(x: 16, y: 730, width: 992, height: 278).fill()
    color(0xB88B62).setFill()
    NSRect(x: 16, y: 730, width: 992, height: 30).fill()
    rounded(NSRect(x: 175, y: 732, width: 708, height: 49), 24, color(0x815B41))
    rounded(NSRect(x: 250, y: 712, width: 552, height: 44), 22, color(0x303638))

    rounded(NSRect(x: 192, y: 455, width: 640, height: 286), 82, color(0xBCC3C8))
    rounded(NSRect(x: 192, y: 345, width: 640, height: 300), 82, color(0xE6E9EB))
    rounded(NSRect(x: 225, y: 625, width: 574, height: 6), 3, color(0xCED4D8))
    for x in [CGFloat(321), CGFloat(429)] {
        rounded(NSRect(x: x + 21.5, y: 638.5, width: 21, height: 64), 10, color(0x424B52))
        rounded(NSRect(x: x + 29.5, y: 648.5, width: 5, height: 44), 2.5, color(0x202A30))
    }
    rounded(NSRect(x: 556, y: 657, width: 27, height: 27), 13.5, color(0x424B52))
    rounded(NSRect(x: 774, y: 663, width: 13, height: 13), 6.5, color(0xF7FAF8))
    if CommandLine.arguments.contains("--portable") {
        let cable = NSBezierPath()
        cable.move(to: NSPoint(x: 353, y: 670))
        cable.curve(to: NSPoint(x: 276, y: 829),
                    controlPoint1: NSPoint(x: 355, y: 774),
                    controlPoint2: NSPoint(x: 186, y: 772))
        cable.curve(to: NSPoint(x: 440, y: 849),
                    controlPoint1: NSPoint(x: 308, y: 854),
                    controlPoint2: NSPoint(x: 390, y: 849))
        cable.lineWidth = 18
        cable.lineCapStyle = .round
        color(0x303A3E).setStroke()
        cable.stroke()
        rounded(NSRect(x: 337, y: 647, width: 32, height: 58), 7, color(0x303A3E))
        rounded(NSRect(x: 434, y: 838, width: 36, height: 24), 6, color(0x303A3E))
        rounded(NSRect(x: 455, y: 886, width: 400, height: 48), 23, color(0x815B41))
        rounded(NSRect(x: 455, y: 805, width: 400, height: 105), 28, color(0x35464E))
        rounded(NSRect(x: 455, y: 790, width: 400, height: 86), 28, color(0x526771))
        rounded(NSRect(x: 482, y: 804, width: 346, height: 8), 4, color(0x748890))
        rounded(NSRect(x: 798, y: 859, width: 16, height: 12), 6, color(0xA7DED4))
    }
    NSGraphicsContext.restoreGraphicsState()
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
