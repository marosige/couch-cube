import AppKit
import GameController
import SwiftUI

/// One tile on Cube TV: a game, an app, a Cube TV page or a store deal.
struct TVGame: Identifiable {
    enum Art { case fill, fit, icon }
    enum Kind { case game, app, page, deal }
    /// A store deal or wishlist entry: what the detail page shows and how the wishlist is changed.
    struct Deal {
        let key: String
        let payload: [String: String]
        let price: String
        let was: String?
        let savings: Int
        let store: String?
        let inWishlist: Bool
    }

    let id: String
    let title: String
    let subtitle: String
    var image: NSImage?
    var art: Art = .icon
    var remoteURL: URL?
    var tint: NSColor?
    var kind: Kind = .game
    var deal: Deal?
    /// Starts a game or app, or opens a page.
    var launch: () -> Void = {}
    /// Games and native apps hand the screen over; web apps and pages keep Cube TV underneath.
    var closesTV = true
    /// An SF Symbol drawn on the plate instead of an image (Cube TV pages and web apps).
    var symbol: String?
    /// The Play page group a game belongs to (Steam games, Retro games...), for Cube TV's shelves.
    var subtitleSection = ""

    init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    init(_ item: LauncherItem) {
        self.init(id: item.id, title: item.title, subtitle: item.subtitle)
        image = item.artwork
        art = item.artwork == nil ? .icon : item.coverArt ? .fit : item.wideArtwork ? .fill : .icon
        remoteURL = item.wideArtwork ? nil : item.artworkURL
        launch = item.launch
        kind = item.section == .added || item.section == .apps ? .app : .game
        subtitleSection = item.section.rawValue
    }
}

struct TVShelf: Identifiable {
    let id: String
    let title: String
    var games: [TVGame]
}

/// Rows of tiles and where the focus is in them.
struct TVShelfSet {
    var shelves: [TVShelf] = []
    var row = 0
    var columns: [Int] = []

    var focused: TVGame? {
        guard shelves.indices.contains(row), columns.indices.contains(row),
              shelves[row].games.indices.contains(columns[row]) else { return nil }
        return shelves[row].games[columns[row]]
    }

    /// Replaces the shelves but keeps the focus on the same shelf and position.
    mutating func replace(_ new: [TVShelf]) {
        var remembered: [String: Int] = [:]
        for (index, shelf) in shelves.enumerated() where columns.indices.contains(index) { remembered[shelf.id] = columns[index] }
        let keepShelf = shelves.indices.contains(row) ? shelves[row].id : nil
        shelves = new
        columns = new.map { min(remembered[$0.id] ?? 0, max($0.games.count - 1, 0)) }
        row = keepShelf.flatMap { id in new.firstIndex { $0.id == id } } ?? min(row, max(new.count - 1, 0))
    }

    /// What changes the picture: used to publish only real changes.
    var signature: String {
        shelves.map { shelf in
            shelf.id + ":" + shelf.games.map { "\($0.id)|\($0.image != nil)|\($0.deal?.inWishlist ?? false)|\($0.deal?.price ?? "")" }.joined(separator: ",")
        }.joined(separator: ";")
    }

    mutating func move(dx: Int, dy: Int) {
        guard !shelves.isEmpty else { return }
        if dy != 0 { row = min(max(row + dy, 0), shelves.count - 1) }
        if dx != 0, !shelves[row].games.isEmpty { columns[row] = min(max(columns[row] + dx, 0), shelves[row].games.count - 1) }
    }
}

struct TVPad: Identifiable, Equatable {
    let id: String
    let name: String
    let battery: String
    let player: Int
}

struct TVPairable: Identifiable, Equatable {
    let id: String
    let name: String
}

enum TVPage { case home, detail, controllers, store }

/// The power menu (Start), like the Steam Deck's: back to games, sleep, restart, turn off, quit.
enum TVMenuAction: CaseIterable {
    case resume, sleep, restart, turnOff, quit

    var title: String {
        switch self {
        case .resume: return "Back to Games"
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .turnOff: return "Turn Off"
        case .quit: return "Quit Cube TV"
        }
    }

    var symbol: String {
        switch self {
        case .resume: return "play.fill"
        case .sleep: return "moon.fill"
        case .restart: return "arrow.clockwise"
        case .turnOff: return "power"
        case .quit: return "rectangle.portrait.and.arrow.right"
        }
    }

    /// Restart and Turn Off end everyone's session, so they ask for a second press.
    var needsConfirmation: Bool { self == .restart || self == .turnOff }
}

/// Cube TV's pages and focus. Navigation is plain state so the keyboard and every controller share it.
final class CubeTVModel: ObservableObject {
    @Published var page = TVPage.home
    @Published var home = TVShelfSet()
    @Published var store = TVShelfSet()
    @Published var detail: TVGame?
    @Published var detailIndex = 0
    @Published var pads: [TVPad] = []
    @Published var pairable: [TVPairable] = []
    @Published var padIndex = 0
    @Published var testText = ""
    @Published var menuOpen = false
    @Published var menuIndex = 0
    @Published var confirming: TVMenuAction?

    var onClose: () -> Void = {}
    var onAction: (TVMenuAction) -> Void = { _ in }
    var onOpenPage: (TVPage) -> Void = { _ in }
    var onClosePage: (TVPage) -> Void = { _ in }
    var onCyclePlayer: (String) -> Void = { _ in }
    var onPair: (String) -> Void = { _ in }
    var onToggleWishlist: (TVGame) -> Void = { _ in }
    var onLaunched: (TVGame) -> Void = { _ in }
    var isFavorite: (String) -> Bool = { _ in false }
    var toggleFavorite: (String) -> Void = { _ in }

    var activeSet: TVShelfSet { page == .store ? store : home }

    var focused: TVGame? { activeSet.focused }

    var detailButtons: [String] {
        guard let game = detail else { return [] }
        if let deal = game.deal { return [deal.inWishlist ? "Remove from Wishlist" : "Add to Wishlist"] }
        return ["Play", isFavorite(game.id) ? "Remove from Favorites" : "Add to Favorites"]
    }

    var controllerRows: Int { pads.count + pairable.count }

    func openMenu() {
        menuOpen.toggle()
        menuIndex = 0
        confirming = nil
    }

    /// Escape and the right controller button: step back one level; from the home screen the keyboard opens the menu.
    func back(menuAtHome: Bool) {
        if menuOpen { openMenu(); return }
        switch page {
        case .home: if menuAtHome { openMenu() }
        case .detail: page = .home
        case .controllers, .store:
            let left = page
            page = .home
            onClosePage(left)
        }
    }

    func move(dx: Int, dy: Int) {
        if menuOpen {
            menuIndex = min(max(menuIndex + dy, 0), TVMenuAction.allCases.count - 1)
            confirming = nil
            return
        }
        switch page {
        case .home: home.move(dx: dx, dy: dy)
        case .store: store.move(dx: dx, dy: dy)
        case .detail: detailIndex = min(max(detailIndex + dx + dy, 0), max(detailButtons.count - 1, 0))
        case .controllers: padIndex = min(max(padIndex + dy, 0), max(controllerRows - 1, 0))
        }
    }

    func select() {
        if menuOpen {
            let action = TVMenuAction.allCases[menuIndex]
            if action.needsConfirmation && confirming != action {
                confirming = action
                return
            }
            menuOpen = false
            confirming = nil
            onAction(action)
            return
        }
        switch page {
        case .home, .store:
            guard let game = focused else { return }
            switch game.kind {
            case .game, .deal:
                detail = game
                detailIndex = 0
                page = .detail
            case .app, .page:
                run(game)
            }
        case .detail:
            guard let game = detail else { return }
            if game.deal != nil {
                onToggleWishlist(game)
            } else if detailIndex == 0 {
                run(game)
            } else {
                toggleFavorite(game.id)
                objectWillChange.send()
            }
        case .controllers:
            if padIndex < pads.count { onCyclePlayer(pads[padIndex].id) }
            else if padIndex - pads.count < pairable.count { onPair(pairable[padIndex - pads.count].id) }
        }
    }

    private func run(_ game: TVGame) {
        onLaunched(game)
        game.launch()
        if game.closesTV { onClose() }
    }
}

/// Keyboard-free input: every connected controller steers Cube TV. One step per push on the pad or stick.
final class TVPadInput {
    var onMove: (Int, Int) -> Void = { _, _ in }
    var onSelect: () -> Void = {}
    var onBack: () -> Void = {}
    var onStart: () -> Void = {}
    var onChange: (GCController, String) -> Void = { _, _ in }
    private var last = (x: 0, y: 0)
    private var observer: NSObjectProtocol?

    func bind() {
        for pad in GCController.controllers() { bind(pad) }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                if let pad = note.object as? GCController { self?.bind(pad) }
            }
        }
    }

    func unbind() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for pad in GCController.controllers() {
            guard let gamepad = pad.extendedGamepad else { continue }
            gamepad.dpad.valueChangedHandler = nil
            gamepad.leftThumbstick.valueChangedHandler = nil
            gamepad.buttonA.pressedChangedHandler = nil
            gamepad.buttonB.pressedChangedHandler = nil
            gamepad.buttonMenu.pressedChangedHandler = nil
            gamepad.valueChangedHandler = nil
        }
    }

    private func bind(_ pad: GCController) {
        guard let gamepad = pad.extendedGamepad else { return }
        let direction: GCControllerDirectionPadValueChangedHandler = { [weak self] _, x, y in self?.directional(x: x, y: y) }
        gamepad.dpad.valueChangedHandler = direction
        gamepad.leftThumbstick.valueChangedHandler = direction
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onSelect() } }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onBack() } }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onStart() } }
        gamepad.valueChangedHandler = { [weak self] pad, _ in
            if let controller = pad.controller { self?.onChange(controller, TVPadInput.pressedText(pad)) }
        }
    }

    /// Neutral names (never A/B/X/Y or shapes), so every brand of controller reads the same.
    static func pressedText(_ gamepad: GCExtendedGamepad) -> String {
        var names: [String] = []
        let buttons: [(GCControllerButtonInput, String)] = [
            (gamepad.buttonA, "bottom button"), (gamepad.buttonB, "right button"), (gamepad.buttonX, "left button"),
            (gamepad.buttonY, "top button"), (gamepad.leftShoulder, "left bumper"), (gamepad.rightShoulder, "right bumper"),
            (gamepad.leftTrigger, "left trigger"), (gamepad.rightTrigger, "right trigger"), (gamepad.buttonMenu, "Start")
        ]
        for (button, name) in buttons where button.isPressed { names.append(name) }
        if gamepad.dpad.up.isPressed { names.append("pad up") }
        if gamepad.dpad.down.isPressed { names.append("pad down") }
        if gamepad.dpad.left.isPressed { names.append("pad left") }
        if gamepad.dpad.right.isPressed { names.append("pad right") }
        return names.isEmpty ? "" : names.joined(separator: ", ")
    }

    private func directional(x: Float, y: Float) {
        let now = (x: x > 0.6 ? 1 : x < -0.6 ? -1 : 0, y: y > 0.6 ? -1 : y < -0.6 ? 1 : 0)
        defer { last = now }
        guard now != last, now != (0, 0) else { return }
        onMove(now.x, now.y)
    }
}

final class CubeTVWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Couch Cube's own TV mode: a full-screen window, steered by keyboard and every connected controller.
final class CubeTVController {
    weak var host: SetupController?
    private var window: CubeTVWindow?
    private let model = CubeTVModel()
    private let input = TVPadInput()
    private var keyMonitor: Any?
    private var cachedItems: [TVGame] = []
    private var refreshTimer: Timer?
    private static let favoritesKey = "cubeTVFavorites"
    private static let recentKey = "cubeTVRecent"

    var isOpen: Bool { window != nil }

    private var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.favoritesKey) }
    }

    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentKey) }
    }

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }
        wireModel()
        model.page = .home
        model.menuOpen = false
        cachedItems = host?.tvItems() ?? []
        buildHome()
        refresh()
        let tv = CubeTVWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        tv.backgroundColor = .black
        tv.contentView = NSHostingView(rootView: CubeTVView(model: model))
        tv.setFrame(screen.frame, display: true)
        window = tv
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()
        NSApp.activate(ignoringOtherApps: true)
        tv.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        bindInput()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func close() {
        guard let window else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        input.unbind()
        if model.page == .controllers { host?.tvStopControllerSearch() }
        NSCursor.unhide()
        NSApp.presentationOptions = []
        window.orderOut(nil)
        self.window = nil
    }

    /// A web app took over the controllers while it was open; take them back.
    func resumeInput() {
        guard window != nil else { return }
        bindInput()
        window?.makeKeyAndOrderFront(nil)
    }

    private func wireModel() {
        model.onClose = { [weak self] in self?.close() }
        model.onAction = { [weak self] action in self?.perform(action) }
        model.isFavorite = { [weak self] id in self?.favorites.contains(id) ?? false }
        model.toggleFavorite = { [weak self] id in
            guard let self else { return }
            if let index = self.favorites.firstIndex(of: id) { self.favorites.remove(at: index) } else { self.favorites.append(id) }
            self.buildHome()
        }
        model.onLaunched = { [weak self] game in
            guard let self, game.kind == .game else { return }
            self.recent = Array(([game.id] + self.recent.filter { $0 != game.id }).prefix(12))
        }
        model.onOpenPage = { [weak self] page in
            if page == .controllers { self?.host?.tvStartControllerSearch() }
            if page == .store { self?.host?.tvLoadStore() }
        }
        model.onClosePage = { [weak self] page in
            if page == .controllers { self?.host?.tvStopControllerSearch() }
        }
        model.onCyclePlayer = { id in
            guard let pad = GCController.controllers().first(where: { Self.padID($0) == id }) else { return }
            let next = pad.playerIndex.rawValue + 1
            pad.playerIndex = GCControllerPlayerIndex(rawValue: next > 3 ? -1 : next) ?? .indexUnset
        }
        model.onPair = { [weak self] address in self?.host?.tvPair(address) }
        model.onToggleWishlist = { [weak self] game in
            guard let deal = game.deal else { return }
            self?.host?.tvToggleWishlist(key: deal.key, payload: deal.payload, inWishlist: deal.inWishlist)
        }
    }

    private func bindInput() {
        input.onMove = { [weak self] dx, dy in self?.model.move(dx: dx, dy: dy) }
        input.onSelect = { [weak self] in self?.select() }
        input.onBack = { [weak self] in self?.model.back(menuAtHome: false) }
        input.onStart = { [weak self] in self?.model.openMenu() }
        input.onChange = { [weak self] pad, text in
            guard let self, self.model.page == .controllers else { return }
            self.model.testText = text.isEmpty ? "" : "\(pad.vendorName ?? "Controller"): \(text)"
        }
        input.bind()
    }

    private func select() {
        let before = model.page
        model.select()
        if model.page != before { pageOpened(model.page) }
    }

    private func pageOpened(_ page: TVPage) {
        model.padIndex = 0
        model.onOpenPage(page)
        refresh()
    }

    static func padID(_ pad: GCController) -> String { String(UInt(bitPattern: ObjectIdentifier(pad).hashValue)) }

    /// Reads every game and app from the app (disk work, so only when the library changes), then builds the shelves.
    func reload() {
        guard let host, window != nil else { return }
        cachedItems = host.tvItems()
        buildHome()
    }

    func buildHome() {
        guard let host else { return }
        let items = cachedItems
        var shelves: [TVShelf] = []
        func games(_ ids: [String]) -> [TVGame] { ids.compactMap { id in items.first { $0.id == id && $0.kind == .game } } }
        let continuing = games(recent)
        if !continuing.isEmpty { shelves.append(TVShelf(id: "recent", title: "Continue", games: continuing)) }
        let liked = games(favorites)
        if !liked.isEmpty { shelves.append(TVShelf(id: "favorites", title: "Favorites", games: liked)) }
        let apps = items.filter { $0.kind == .app }
        if !apps.isEmpty { shelves.append(TVShelf(id: "apps", title: "Apps", games: apps)) }
        for section in [LauncherSection.steam, .retro, .windows, .mac] {
            let group = items.filter { $0.kind == .game && $0.subtitleSection == section.rawValue }
            if !group.isEmpty { shelves.append(TVShelf(id: section.rawValue, title: section.rawValue, games: group)) }
        }
        let pages = [
            host.tvPageTile(id: "page-controllers", title: "Controllers", subtitle: "Pair, order and test", symbol: "gamecontroller.fill",
                            color: .systemIndigo) { [weak self] in self?.openPage(.controllers) },
            host.tvPageTile(id: "page-store", title: "Store", subtitle: "Deals and your wishlist", symbol: "bag.fill",
                            color: .systemPink) { [weak self] in self?.openPage(.store) }
        ]
        shelves.append(TVShelf(id: "cube", title: "Cube TV", games: pages))
        var next = model.home
        next.replace(shelves)
        if next.signature != model.home.signature { model.home = next }
    }

    /// Controllers, pairing and the store change while Cube TV is open, so they are read every second or two.
    func refresh() {
        guard let host else { return }
        var store = model.store
        store.replace(host.tvStoreShelves())
        if store.signature != model.store.signature { model.store = store }
        if let detail = model.detail, detail.deal != nil,
           let updated = model.store.shelves.flatMap(\.games).first(where: { $0.id == detail.id }) {
            model.detail = updated
        }
        let pads = GCController.controllers().map { pad -> TVPad in
            let level = pad.battery.map { "\(Int(($0.batteryLevel * 100).rounded()))%" } ?? ""
            return TVPad(id: Self.padID(pad), name: pad.vendorName ?? "Controller", battery: level, player: pad.playerIndex.rawValue + 1)
        }
        if pads != model.pads { model.pads = pads }
        let pairable = host.tvPairable().map { TVPairable(id: $0.address, name: $0.name) }
        if pairable != model.pairable { model.pairable = pairable }
    }

    private func openPage(_ page: TVPage) {
        model.page = page
        pageOpened(page)
    }

    private func perform(_ action: TVMenuAction) {
        switch action {
        case .resume: break
        case .quit: close()
        case .sleep: run("/usr/bin/pmset", ["sleepnow"])
        case .restart: systemEvent("aevtrrst")
        case .turnOff: systemEvent("aevtrsdn")
        }
    }

    private func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }

    /// Restart / shut down through loginwindow, the way the Apple menu does it (apps may veto, nothing is forced).
    private func systemEvent(_ code: String) {
        run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to \u{AB}event \(code)\u{BB}"])
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow === window else { return false }
        switch event.keyCode {
        case 123: model.move(dx: -1, dy: 0)
        case 124: model.move(dx: 1, dy: 0)
        case 125: model.move(dx: 0, dy: 1)
        case 126: model.move(dx: 0, dy: -1)
        case 36, 76, 49: select()
        case 53: model.back(menuAtHome: true)
        default: return false
        }
        return true
    }
}
