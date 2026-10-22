import AppKit

/// Couch Cube's section switcher: large capsule tabs on a soft track, the chosen one filled with the accent
/// colour. Click a tab, or focus it and use ← → (later also the controller's shoulder buttons). It keeps
/// NSSegmentedControl's `selectedSegment` (-1 = none) and target/action, so callers read it the same way.
final class PillTabs: NSView {
    weak var target: AnyObject?
    var action: Selector?
    private(set) var buttons: [NSButton] = []
    private let track = NSStackView()
    private var hovered: Int?

    var selectedSegment: Int = 0 { didSet { refresh() } }
    var segmentCount: Int { buttons.count }

    init(labels: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        track.orientation = .horizontal
        track.spacing = 2
        track.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: leadingAnchor), track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: topAnchor), track.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38)
        ])
        for (index, label) in labels.enumerated() {
            let button = NSButton(title: label, target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 16
            button.setButtonType(.momentaryChange)
            button.setAccessibilityRole(.radioButton)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                                  owner: self, userInfo: ["index": index]))
            track.addArrangedSubview(button)
            buttons.append(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: step(-1)  // ←
        case 124: step(1)   // →
        default: super.keyDown(with: event)
        }
    }

    /// Moves to the previous or next tab, wrapping around, and reports it like a click.
    func step(_ delta: Int) {
        guard !buttons.isEmpty else { return }
        let start = selectedSegment < 0 ? (delta > 0 ? -1 : 0) : selectedSegment
        selectedSegment = (start + delta + buttons.count) % buttons.count
        sendAction()
    }

    @objc private func clicked(_ sender: NSButton) {
        selectedSegment = sender.tag
        sendAction()
    }

    private func sendAction() {
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = event.trackingArea?.userInfo?["index"] as? Int
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            for button in buttons {
                let chosen = button.tag == selectedSegment
                let color: NSColor = chosen ? .white : .labelColor
                button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: chosen ? .semibold : .medium), .foregroundColor: color])
                button.layer?.backgroundColor = (chosen ? NSColor.controlAccentColor
                    : button.tag == hovered ? NSColor.labelColor.withAlphaComponent(0.08) : NSColor.clear).cgColor
                button.setAccessibilityValue(chosen)
            }
        }
        for button in buttons {
            // Room around the label so each tab reads as a pill, not a word.
            button.constraints.filter { $0.firstAttribute == .width }.forEach { button.removeConstraint($0) }
            button.widthAnchor.constraint(equalToConstant: ceil(button.attributedTitle.size().width) + 32).isActive = true
        }
    }
}
