import AppKit
import QuartzCore

/// A loading placeholder: a soft rounded block with a light band sweeping across it, like Apple's own
/// storefront skeletons. Shapes are drawn where real content will appear, so the page doesn't jump when it lands.
final class ShimmerView: NSView {
    private let shine = CAGradientLayer()

    init(cornerRadius: CGFloat = 10) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.locations = [0, 0.5, 1]
        layer?.addSublayer(shine)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading")
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        shine.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { shine.removeAllAnimations() } else { animate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            let clear = NSColor.labelColor.withAlphaComponent(0).cgColor
            shine.colors = [clear, NSColor.labelColor.withAlphaComponent(0.08).cgColor, clear]
        }
    }

    private func animate() {
        guard shine.animation(forKey: "sweep") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Moves the band (three widths wide) by two widths: from fully left of the block to fully right.
        sweep.fromValue = -bounds.width
        sweep.toValue = bounds.width
        shine.add(sweep, forKey: "sweep")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed && window != nil {
            shine.removeAnimation(forKey: "sweep")
            animate()
        }
    }
}
