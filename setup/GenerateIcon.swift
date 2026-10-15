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
    rounded(NSRect(x: 16, y: 16, width: 992, height: 992), 218, color(0x28334B))
    rounded(NSRect(x: 206, y: 245, width: 612, height: 590), 148, color(0x1C2538))
    rounded(NSRect(x: 206, y: 189, width: 612, height: 590), 148, color(0x8FD9CC))
    rounded(NSRect(x: 242, y: 215, width: 540, height: 126), 100, color(0xB6EBDD))
    rounded(NSRect(x: 206, y: 291, width: 612, height: 488), 122, color(0x8FD9CC))
    let ink = color(0x28334B)
    rounded(NSRect(x: 310, y: 420, width: 190, height: 64), 20, ink)
    rounded(NSRect(x: 373, y: 357, width: 64, height: 190), 20, ink)
    rounded(NSRect(x: 597, y: 382, width: 70, height: 70), 35, ink)
    rounded(NSRect(x: 681, y: 466, width: 70, height: 70), 35, ink)
    rounded(NSRect(x: 337, y: 652, width: 222, height: 18), 9, color(0x4B9D94))
    rounded(NSRect(x: 674, y: 646, width: 30, height: 30), 15, color(0xF4F7EE))
    if CommandLine.arguments.contains("--portable") || CommandLine.arguments.contains("--installer") {
        rounded(NSRect(x: 648, y: 680, width: 292, height: 250), 70, color(0x28334B))
        rounded(NSRect(x: 670, y: 702, width: 248, height: 206), 52, color(0xF4F7EE))
        if CommandLine.arguments.contains("--portable") {
            rounded(NSRect(x: 719, y: 752, width: 150, height: 100), 24, ink)
            rounded(NSRect(x: 739, y: 812, width: 66, height: 10), 5, color(0x8FD9CC))
            rounded(NSRect(x: 832, y: 809, width: 16, height: 16), 8, color(0x8FD9CC))
        } else {
            rounded(NSRect(x: 780, y: 740, width: 28, height: 82), 10, ink)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 744, y: 790))
            arrow.line(to: NSPoint(x: 794, y: 840))
            arrow.line(to: NSPoint(x: 844, y: 790))
            arrow.lineWidth = 28
            arrow.lineJoinStyle = .round
            arrow.lineCapStyle = .round
            ink.setStroke()
            arrow.stroke()
            rounded(NSRect(x: 737, y: 862, width: 114, height: 12), 6, ink)
        }
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
