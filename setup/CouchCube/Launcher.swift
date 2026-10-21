import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers

/// Groups on the Play page's game grid, in display order. Only games: launchers and emulators live in App Store.
enum LauncherSection: String, CaseIterable {
    case steam = "Steam games"
    case retro = "Retro games"
    case windows = "Windows games"
    case mac = "Mac games"
    case added = "Added by you"
}

/// `library-games` (scripts/console.py): ROMs of shown consoles and game apps in the library and CrossOver.
struct LibraryGames: Decodable {
    struct Rom: Decodable { let system: String; let systemName: String; let name: String; let path: String }
    struct App: Decodable { let kind: String; let name: String; let path: String; let group: String? }
    let roms: [Rom]
    let apps: [App]
}

/// One thing the launcher can open: a Steam game, a store app, a Windows client in a bottle or any app you added.
struct LauncherItem {
    let id: String
    let title: String
    let subtitle: String
    let section: LauncherSection
    /// Wide artwork (Steam header) fills the tile; an icon sits centered on a tinted plate.
    let artwork: NSImage?
    let wideArtwork: Bool
    let path: String?
    let launch: () -> Void
}

/// Steam keeps tools and runtimes in the same manifests as games; they are not something to play.
func isSteamTool(appid: String, name: String) -> Bool {
    if ["228980", "1070560", "1391110", "1628350"].contains(appid) { return true }
    let lowered = name.lowercased()
    return ["redistributable", "steam linux runtime", "proton", "steamworks"].contains { lowered.contains($0) }
}

/// The header art Steam has already downloaded for a game, read from its local cache (no network).
func steamHeaderArtwork(appid: String, steamRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Steam")) -> NSImage? {
    let cache = steamRoot.appendingPathComponent("appcache/librarycache")
    let candidates = [cache.appendingPathComponent("\(appid)/header.jpg"),
                      cache.appendingPathComponent("\(appid)_header.jpg"),
                      cache.appendingPathComponent("\(appid)/library_header.jpg")]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        if let image = NSImage(contentsOf: url) { return image }
    }
    // Newer Steam clients nest the header under a hashed folder inside the app's cache folder.
    let folder = cache.appendingPathComponent(appid)
    let nested = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
    if let header = nested.sorted().first(where: { ($0 as NSString).lastPathComponent == "header.jpg" }) {
        return NSImage(contentsOf: folder.appendingPathComponent(header))
    }
    return nil
}

/// Lays out equally sized tiles in rows that fill the available width; its height follows that width.
/// Tiles keep Steam's header-art proportions (460 × 215) plus room for two lines of text.
final class TileFlowView: NSView {
    var minimumTileWidth: CGFloat = 168
    var spacing: CGFloat = 16
    static let artRatio: CGFloat = 215.0 / 460.0
    var textHeight: CGFloat = 42
    override var isFlipped: Bool { true }

    func setTiles(_ tiles: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        for tile in tiles {
            tile.translatesAutoresizingMaskIntoConstraints = true
            addSubview(tile)
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private var columns: Int { max(1, Int((bounds.width + spacing) / (minimumTileWidth + spacing))) }
    private var tileWidth: CGFloat { max(minimumTileWidth, (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)) }
    private var tileHeight: CGFloat { (tileWidth * Self.artRatio).rounded() + textHeight }

    override var intrinsicContentSize: NSSize {
        let rows = (subviews.count + columns - 1) / columns
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: rows == 0 ? 0 : CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        for (index, tile) in subviews.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % columns) * (tileWidth + spacing),
                                y: CGFloat(index / columns) * (tileHeight + spacing),
                                width: tileWidth, height: tileHeight)
        }
    }
}

/// A launcher tile: artwork on top, the name below. Click, Return or VoiceOver press opens it.
final class LauncherTile: ClickableRowView {
    let item: LauncherItem

    init(item: LauncherItem) {
        self.item = item
        super.init(frame: .zero)
        layer?.cornerRadius = 10
        onActivate = item.launch
        setAccessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
        toolTip = item.subtitle.isEmpty ? item.title : "\(item.title)\n\(item.subtitle)"

        let plate = NSView()
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        plate.layer?.masksToBounds = true
        plate.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        if let artwork = item.artwork, item.wideArtwork {
            plate.layer?.contentsGravity = .resizeAspectFill
            plate.layer?.contents = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            let icon = NSImageView(image: item.artwork ?? NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 56),
                icon.heightAnchor.constraint(equalToConstant: 56)
            ])
        }
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        for view in [plate, title, subtitle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.heightAnchor.constraint(equalTo: plate.widthAnchor, multiplier: TileFlowView.artRatio),
            title.topAnchor.constraint(equalTo: plate.bottomAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
