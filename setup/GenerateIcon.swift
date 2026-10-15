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
    NSColor(calibratedRed: 0.53, green: 0.67, blue: 0.64, alpha: 1).setFill()
    backdrop.fill()

    NSGraphicsContext.saveGraphicsState()
    backdrop.addClip()
    NSColor(calibratedRed: 0.78, green: 0.59, blue: 0.36, alpha: 1).setFill()
    NSRect(x: 16, y: 16, width: 992, height: 111).fill()
    NSGraphicsContext.restoreGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    NSGraphicsContext.saveGraphicsState()
    NSAffineTransform(transform: AffineTransform(m11: 1.22, m12: 0, m21: 0, m22: 1.22,
                                                 tX: -112.64, tY: -69.8)).concat()
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    rounded(NSRect(x: 154, y: 390, width: 716, height: 413), 46,
            NSColor(calibratedWhite: 0.10, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    let screen = NSBezierPath(roundedRect: NSRect(x: 166, y: 402, width: 692, height: 389.25),
                             xRadius: 34, yRadius: 34)
    NSColor.black.setFill()
    screen.fill()
    if CommandLine.arguments.contains("--installer") {
        rounded(NSRect(x: 496, y: 640, width: 32, height: 70), 5, .systemBlue)
        NSColor.systemBlue.setFill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 464, y: 645))
        arrow.line(to: NSPoint(x: 512, y: 590))
        arrow.line(to: NSPoint(x: 560, y: 645))
        arrow.close()
        arrow.fill()
        rounded(NSRect(x: 464, y: 550, width: 96, height: 12), 6, .systemBlue)
    }
    rounded(NSRect(x: 507, y: 394, width: 10, height: 2), 1,
            NSColor.white.withAlphaComponent(0.5))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSAffineTransform(transform: AffineTransform(m11: 2.8, m12: 0, m21: 0, m22: 2.8,
                                                 tX: -1500, tY: -620.6)).concat()
    rounded(NSRect(x: 755, y: 267, width: 100, height: 9), 4,
            NSColor(calibratedWhite: 0.23, alpha: 1))
    let mini = NSBezierPath(roundedRect: NSRect(x: 744, y: 276, width: 122, height: 54),
                           xRadius: 18, yRadius: 18)
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    mini.fill()
    rounded(NSRect(x: 748, y: 320, width: 114, height: 12), 6,
            NSColor(calibratedWhite: 0.92, alpha: 1))
    for x in [CGFloat(776), CGFloat(801)] {
        rounded(NSRect(x: x, y: 291, width: 12, height: 5), 2, .darkGray)
    }
    rounded(NSRect(x: 836, y: 291, width: 4, height: 4), 2, .white)
    if CommandLine.arguments.contains("--portable") {
        let cable = NSBezierPath()
        cable.move(to: NSPoint(x: 782, y: 293.5))
        cable.curve(to: NSPoint(x: 751, y: 319),
                    controlPoint1: NSPoint(x: 770, y: 298),
                    controlPoint2: NSPoint(x: 769, y: 321))
        cable.curve(to: NSPoint(x: 721, y: 282),
                    controlPoint1: NSPoint(x: 733, y: 317),
                    controlPoint2: NSPoint(x: 740, y: 282))
        cable.lineWidth = 5
        cable.lineCapStyle = .round
        NSColor(calibratedWhite: 0.16, alpha: 1).setStroke()
        cable.stroke()
        rounded(NSRect(x: 776, y: 291, width: 12, height: 5), 2,
                NSColor(calibratedWhite: 0.65, alpha: 1))
        rounded(NSRect(x: 774, y: 287.5, width: 16, height: 12), 4,
                NSColor(calibratedWhite: 0.22, alpha: 1))
        NSGraphicsContext.saveGraphicsState()
        let placement = AffineTransform(translationByX: 665, byY: 282)
        (placement as NSAffineTransform).concat()
        rounded(NSRect(x: -54, y: -15, width: 108, height: 7), 3,
                NSColor.black.withAlphaComponent(0.16))
        let enclosure = NSBezierPath(roundedRect: NSRect(x: -54, y: -10, width: 108, height: 18),
                                     xRadius: 6, yRadius: 6)
        NSGradient(starting: NSColor(calibratedRed: 0.39, green: 0.45, blue: 0.48, alpha: 1),
                   ending: NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.28, alpha: 1))!
            .draw(in: enclosure, angle: -90)
        rounded(NSRect(x: -49, y: 5, width: 98, height: 3), 1.5,
                NSColor.white.withAlphaComponent(0.3))
        rounded(NSRect(x: 48, y: -4, width: 12, height: 8), 3,
                NSColor(calibratedWhite: 0.20, alpha: 1))
        rounded(NSRect(x: -39, y: 5, width: 4, height: 2), 1,
                NSColor(calibratedRed: 0.49, green: 0.86, blue: 0.89, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
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
