import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


/// A control inside a ClickableRowView. Like the row, it takes the first click in an inactive window,
/// so clicking a heart in a background window toggles it instead of being swallowed while the row would open.
final class RowControlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A whole list row that acts as one link: hover highlight, pointing-hand cursor, pressed state,
/// Return/Space when focused and a VoiceOver link. Dragging away cancels; nested buttons keep their own action.

/// Cube Shop's My Stores / All Stores choice: a quiet pop-up that answers to the segmented-control calls the Shop already makes.
final class ScopePopUp: NSPopUpButton {
    convenience init(labels: [String]) {
        self.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        labels.forEach { addItem(withTitle: $0) }
    }
    var selectedSegment: Int {
        get { indexOfSelectedItem }
        set { selectItem(at: newValue) }
    }
    func setEnabled(_ enabled: Bool, forSegment segment: Int) { item(at: segment)?.isEnabled = enabled }
    func isEnabled(forSegment segment: Int) -> Bool { item(at: segment)?.isEnabled ?? false }
    func setToolTip(_ toolTip: String?, forSegment segment: Int) { item(at: segment)?.toolTip = toolTip }
}

class ClickableRowView: NSView {
    var onActivate: (() -> Void)?
    /// The resting background (e.g. a tinted banner); hover and press tint over it, then return to it.
    var baseColor: NSColor = .clear { didSet { updateLook() } }
    private(set) var hovering = false
    private(set) var pressed = false
    private var downPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func activate() { onActivate?() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { activate(); return true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return current }
            view = current.superview
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateLook() }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; updateLook() }

    /// True when the event lands on a control inside the row (a heart, a reminder badge...), even a disabled one.
    /// Disabled buttons pass their mouse events up the responder chain, which must never open the row's link.
    private func landsOnControl(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        var view = super.hitTest(superview.convert(event.locationInWindow, from: nil))
        while let current = view, current !== self {
            if current is NSButton { return true }
            view = current.superview
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        guard !landsOnControl(event) else { downPoint = nil; return }
        downPoint = convert(event.locationInWindow, from: nil)
        pressed = true
        updateLook()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) > 4 {
            downPoint = nil
            pressed = false
            updateLook()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let click = downPoint != nil && inside && !landsOnControl(event)
        downPoint = nil
        pressed = false
        updateLook()
        if click { activate() }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { activate() } else { super.keyDown(with: event) }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = pressed ? NSColor.labelColor.withAlphaComponent(0.12)
                : hovering ? NSColor.labelColor.withAlphaComponent(0.06) : baseColor
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// A multi-line label that wraps to its current width (flow layout for inline badges).
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

final class RemoteImageView: NSImageView {
    private(set) var source: URL?
    private var task: URLSessionDataTask?
    /// Fills the frame and crops the overflow, so differently shaped store art lines up row to row.
    var aspectFill = false

    override var wantsUpdateLayer: Bool { aspectFill ? false : super.wantsUpdateLayer }

    override func draw(_ dirtyRect: NSRect) {
        guard aspectFill, let image else { super.draw(dirtyRect); return }
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    func load(_ url: URL?, enabled: Bool = true) {
        task?.cancel()
        source = url
        guard let url, enabled else { return }
        if let cached = dealImageCache.object(forKey: url as NSURL) { image = cached; return }
        task = dealImageSession.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, data.count <= 2 << 20, (response as? HTTPURLResponse)?.statusCode == 200,
                  response?.url.flatMap({ safeDealURL($0.absoluteString) }) != nil,
                  let picture = NSImage(data: data), picture.isValid else { return }
            dealImageCache.setObject(picture, forKey: url as NSURL)
            DispatchQueue.main.async {
                // A reused or re-rendered row may now show a different deal.
                guard let self, self.source == url else { return }
                self.image = picture
            }
        }
        task?.resume()
    }
}

final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
    /// The page column's width: the available width (minus margins) up to the page's cap. It is set from this view's own
    /// size, not left to content, so a page with little in it yet doesn't start narrow and then jump as rows arrive.
    var pageWidth: NSLayoutConstraint?
    var maxPageWidth: CGFloat = .greatestFiniteMagnitude

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let pageWidth, newSize.width > 16 else { return }
        let target = min(newSize.width - 16, maxPageWidth)
        if pageWidth.constant != target { pageWidth.constant = target }
    }
}

let settingsSectionBackground = NSColor.controlBackgroundColor
let settingsWindowBackground = NSColor.windowBackgroundColor

final class ControllerLEDHousing: NSBox {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .custom
        titlePosition = .noTitle
        borderWidth = 0
        cornerRadius = 10
        contentViewMargins = .zero
        fillColor = .quaternaryLabelColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

typealias SetupActionButton = NSButton

class TileActionButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { setHovered(false) }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea = hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        if let window = window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        } else {
            setHovered(false)
        }
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered && isEnabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        outline.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
    }
}

final class StorageChoiceButton: TileActionButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

/// A whole-row link to a drive's detail page; buttons inside (like the Finder path) keep their own clicks.
final class StorageOverviewRow: NSView {
    var driveID: String?
    var onOpen: ((String) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let id = driveID, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(id)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let id = driveID else { return false }
        onOpen?(id)
        return true
    }
    override func resetCursorRects() {
        if driveID != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

