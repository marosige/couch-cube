import AppKit

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--set-file-icon" {
    guard let image = NSImage(contentsOfFile: CommandLine.arguments[2]),
          NSWorkspace.shared.setIcon(image, forFile: CommandLine.arguments[3], options: []) else {
        fputs("Cannot assign the local disk-image icon.\n", stderr)
        exit(1)
    }
    exit(0)
}

func rounded(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon() {
    let backdrop = NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 992, height: 992), xRadius: 210, yRadius: 210)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1),
        NSColor(calibratedRed: 0.79, green: 0.84, blue: 0.82, alpha: 1)
    ])!.draw(in: backdrop, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    rounded(NSRect(x: 74, y: 238, width: 876, height: 33), 10,
            NSColor(calibratedRed: 0.78, green: 0.59, blue: 0.36, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()

    let oak = NSColor(calibratedRed: 0.68, green: 0.46, blue: 0.25, alpha: 1)
    rounded(NSRect(x: 93, y: 143, width: 838, height: 104), 8, oak)
    rounded(NSRect(x: 120, y: 101, width: 28, height: 52), 6, oak)
    rounded(NSRect(x: 876, y: 101, width: 28, height: 52), 6, oak)
    rounded(NSRect(x: 350, y: 158, width: 324, height: 73), 4,
            NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.13, alpha: 1))
    rounded(NSRect(x: 365, y: 169, width: 294, height: 7), 2, oak)
    for index in 0..<15 {
        let y = CGFloat(154 + index * 6)
        NSColor(calibratedRed: 0.44, green: 0.28, blue: 0.13, alpha: 0.18).setStroke()
        let grain = NSBezierPath()
        grain.lineWidth = 1.5
        for (start, end) in [(CGFloat(110), CGFloat(335)), (CGFloat(689), CGFloat(913))] {
            grain.move(to: NSPoint(x: start, y: y))
            grain.curve(to: NSPoint(x: end, y: y + 2),
                        controlPoint1: NSPoint(x: start + 70, y: y + 6),
                        controlPoint2: NSPoint(x: end - 50, y: y - 5))
        }
        grain.stroke()
    }
    rounded(NSRect(x: 82, y: 250, width: 860, height: 7), 3,
            NSColor(calibratedRed: 0.91, green: 0.73, blue: 0.49, alpha: 1))

    NSGraphicsContext.saveGraphicsState()
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    rounded(NSRect(x: 154, y: 390, width: 716, height: 413), 15,
            NSColor(calibratedWhite: 0.10, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    // The visible black screen is exactly 16:9.
    let screen = NSBezierPath(roundedRect: NSRect(x: 166, y: 402, width: 692, height: 389.25),
                             xRadius: 5, yRadius: 5)
    NSGradient(starting: NSColor(calibratedWhite: 0.055, alpha: 1),
               ending: .black)!.draw(in: screen, angle: -65)
    if CommandLine.arguments.contains("--installer") {
        rounded(NSRect(x: 496, y: 640, width: 32, height: 70), 5, .systemBlue)
        NSColor.systemBlue.setFill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 464, y: 645))
        arrow.line(to: NSPoint(x: 512, y: 590))
        arrow.line(to: NSPoint(x: 560, y: 645))
        arrow.close()
        arrow.fill()
        rounded(NSRect(x: 432, y: 520, width: 160, height: 50), 12,
                NSColor(calibratedWhite: 0.72, alpha: 1))
        rounded(NSRect(x: 436, y: 563, width: 152, height: 10), 5,
                NSColor(calibratedWhite: 0.92, alpha: 1))
        rounded(NSRect(x: 449, y: 537, width: 13, height: 5), 2, .darkGray)
        rounded(NSRect(x: 472, y: 537, width: 13, height: 5), 2, .darkGray)
        rounded(NSRect(x: 330, y: 440, width: 364, height: 50), 12,
                NSColor(calibratedWhite: 0.15, alpha: 1))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        ("Install on this Mac" as NSString).draw(
            in: NSRect(x: 330, y: 447, width: 364, height: 36),
            withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                             .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    }
    rounded(NSRect(x: 507, y: 394, width: 10, height: 2), 1,
            NSColor.white.withAlphaComponent(0.5))

    rounded(NSRect(x: 755, y: 267, width: 100, height: 9), 4,
            NSColor(calibratedWhite: 0.23, alpha: 1))
    let mini = NSBezierPath(roundedRect: NSRect(x: 744, y: 276, width: 122, height: 54),
                           xRadius: 12, yRadius: 12)
    NSGradient(starting: NSColor(calibratedWhite: 0.90, alpha: 1),
               ending: NSColor(calibratedWhite: 0.62, alpha: 1))!.draw(in: mini, angle: -90)
    rounded(NSRect(x: 748, y: 320, width: 114, height: 12), 6,
            NSColor(calibratedWhite: 0.92, alpha: 1))
    for x in [CGFloat(776), CGFloat(801)] {
        rounded(NSRect(x: x, y: 291, width: 12, height: 5), 2, .darkGray)
    }
    rounded(NSRect(x: 836, y: 291, width: 4, height: 4), 2, .white)
    if CommandLine.arguments.contains("--portable") {
        let cable = NSBezierPath()
        cable.move(to: NSPoint(x: 716, y: 287))
        cable.curve(to: NSPoint(x: 777, y: 293),
                    controlPoint1: NSPoint(x: 741, y: 265),
                    controlPoint2: NSPoint(x: 754, y: 293))
        cable.lineWidth = 4
        NSColor(calibratedWhite: 0.16, alpha: 1).setStroke()
        cable.stroke()
        rounded(NSRect(x: 770, y: 289, width: 11, height: 8), 2,
                NSColor(calibratedWhite: 0.22, alpha: 1))
        rounded(NSRect(x: 616, y: 273, width: 102, height: 29), 6,
                NSColor(calibratedWhite: 0.27, alpha: 1))
        rounded(NSRect(x: 620, y: 296, width: 94, height: 7), 3,
                NSColor(calibratedWhite: 0.45, alpha: 1))
        for x in stride(from: 630, through: 702, by: 8) {
            rounded(NSRect(x: CGFloat(x), y: 281, width: 2, height: 13), 1,
                    NSColor(calibratedWhite: 0.43, alpha: 1))
        }
        rounded(NSRect(x: 623, y: 279, width: 3, height: 3), 1, .systemBlue)
    }
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
