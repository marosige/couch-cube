import AppKit

/// The Play tile's picture. Cube TV's wide scene is anchored to the right, so the Mac mini stays in view when the window
/// is narrow and the TV slides into view as the tile grows; once the tile is wider than the picture, the bottom stays.
/// Without an `imageAspect` it is a plain centered fill (the Steam and ES-DE artwork is drawn for that).
final class PlayPictureView: NSView {
    var imageAspect: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        guard imageAspect > 0, bounds.width > 0, bounds.height > 0 else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let tileAspect = bounds.width / bounds.height
        if tileAspect < imageAspect {
            let visible = tileAspect / imageAspect
            layer.contentsRect = CGRect(x: 1 - visible, y: 0, width: visible, height: 1)
        } else {
            let visible = imageAspect / tileAspect
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: visible)
        }
    }
}
