import AppKit
import GameController
import SwiftUI

/// One game on Cube TV, flattened from a `LauncherItem` so the SwiftUI side needs nothing else.
struct TVGame: Identifiable {
    enum Art { case fill, fit, icon }
    let id: String
    let title: String
    let subtitle: String
    let image: NSImage?
    let art: Art
    let remoteURL: URL?
    let launch: () -> Void

    init(_ item: LauncherItem) {
        id = item.id
        title = item.title
        subtitle = item.subtitle
        image = item.artwork
        art = item.artwork == nil ? .icon : item.coverArt ? .fit : item.wideArtwork ? .fill : .icon
        remoteURL = item.wideArtwork ? nil : item.artworkURL
        launch = item.launch
    }
}

struct TVShelf: Identifiable {
    let id: String
    let title: String
    let games: [TVGame]
}

/// The power menu (Esc or the right button), like the Steam Deck's: resume, sleep, restart, turn off, quit.
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

/// Cube TV's focus and shelves. Navigation is plain row/column state so keyboard and every controller share it.
final class CubeTVModel: ObservableObject {
    @Published var shelves: [TVShelf] = []
    @Published var row = 0
    @Published var columns: [Int] = []
    @Published var menuOpen = false
    @Published var menuIndex = 0
    @Published var confirming: TVMenuAction?
    var onClose: () -> Void = {}
    var onAction: (TVMenuAction) -> Void = { _ in }

    func load(_ items: [LauncherItem]) {
        shelves = LauncherSection.allCases.compactMap { section in
            let games = items.filter { $0.section == section }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map(TVGame.init)
            return games.isEmpty ? nil : TVShelf(id: section.rawValue, title: section.rawValue, games: games)
        }
        row = 0
        columns = Array(repeating: 0, count: shelves.count)
    }

    var focused: TVGame? {
        guard shelves.indices.contains(row), columns.indices.contains(row),
              shelves[row].games.indices.contains(columns[row]) else { return nil }
        return shelves[row].games[columns[row]]
    }

    func back() {
        menuOpen.toggle()
        menuIndex = 0
        confirming = nil
    }

    func move(dx: Int, dy: Int) {
        if menuOpen {
            menuIndex = min(max(menuIndex + dy, 0), TVMenuAction.allCases.count - 1)
            confirming = nil
            return
        }
        guard !shelves.isEmpty else { return }
        if dy != 0 { row = min(max(row + dy, 0), shelves.count - 1) }
        if dx != 0 { columns[row] = min(max(columns[row] + dx, 0), shelves[row].games.count - 1) }
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
        guard let game = focused else { return }
        game.launch()
        onClose()
    }
}

struct TVArt: View {
    let game: TVGame

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            if let url = game.remoteURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } else { icon }
                }
            } else if let image = game.image {
                switch game.art {
                case .fill: Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                case .fit: Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
                case .icon: icon
                }
            } else {
                icon
            }
        }
    }

    private var icon: some View {
        Group {
            if let image = game.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 84, height: 84)
            } else {
                Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

struct TVCard: View {
    let game: TVGame
    let focused: Bool
    static let size = CGSize(width: 320, height: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArt(game: game)
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0.95 : 0), lineWidth: 4))
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 24, y: 14)
            Text(game.title).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                .lineLimit(1).opacity(focused ? 1 : 0.7)
        }
        .frame(width: Self.size.width)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct CubeTVView: View {
    @ObservedObject var model: CubeTVModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let game = model.focused {
                TVArt(game: game).blur(radius: 40).opacity(0.45).clipped()
                    .animation(.easeOut(duration: 0.3), value: game.id)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            browser
            if model.menuOpen { powerMenu }
        }
        .ignoresSafeArea()
    }

    private var powerMenu: some View {
        ZStack {
            Color.black.opacity(0.65)
            VStack(spacing: 10) {
                Text("Cube TV").font(.system(size: 34, weight: .bold)).foregroundColor(.white).padding(.bottom, 12)
                ForEach(Array(TVMenuAction.allCases.enumerated()), id: \.element) { index, action in
                    let selected = index == model.menuIndex
                    HStack(spacing: 16) {
                        Image(systemName: action.symbol).frame(width: 32)
                        Text(model.confirming == action ? "Press again to \(action.title.lowercased())" : action.title)
                        Spacer()
                    }
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(selected ? .black : .white)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .frame(width: 520)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? Color.white : Color.white.opacity(0.12)))
                }
            }
        }
    }

    private var browser: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                hero.frame(height: 300)
                if model.shelves.isEmpty {
                    Text("Your games appear here: Steam games, ROMs in your game library and Windows games.")
                        .font(.system(size: 24)).foregroundColor(.white.opacity(0.7)).padding(.horizontal, 80)
                    Spacer()
                } else {
                    shelves
                }
                hints
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(model.focused?.title ?? "Cube TV")
                .font(.system(size: 64, weight: .bold)).foregroundColor(.white).lineLimit(1)
            Text(model.focused?.subtitle ?? "")
                .font(.system(size: 26, weight: .medium)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 80).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shelves: some View {
        ScrollViewReader { vertical in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.shelves.enumerated()), id: \.element.id) { index, shelf in
                        shelfView(index, shelf).id(shelf.id)
                    }
                }
                .padding(.bottom, 200)
            }
            .onChange(of: model.row) { row in
                guard model.shelves.indices.contains(row) else { return }
                withAnimation(.easeOut(duration: 0.25)) { vertical.scrollTo(model.shelves[row].id, anchor: .top) }
            }
        }
    }

    private func shelfView(_ index: Int, _ shelf: TVShelf) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shelf.title).font(.system(size: 26, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 80)
            ScrollViewReader { horizontal in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(Array(shelf.games.enumerated()), id: \.element.id) { column, game in
                            TVCard(game: game, focused: model.row == index && model.columns.indices.contains(index) && model.columns[index] == column)
                                .id(game.id)
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 24)
                }
                .onChange(of: model.columns) { columns in
                    guard model.row == index, columns.indices.contains(index), shelf.games.indices.contains(columns[index]) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { horizontal.scrollTo(shelf.games[columns[index]].id, anchor: .center) }
                }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 32) {
            Label("Play: Return or bottom button", systemImage: "play.fill")
            Label("Menu: Esc or right button", systemImage: "line.3.horizontal")
        }
        .font(.system(size: 18)).foregroundColor(.white.opacity(0.6))
        .padding(.horizontal, 80).padding(.vertical, 20)
    }
}

final class CubeTVWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Couch Cube's own TV mode: a full-screen window, steered by keyboard and every connected controller.
final class CubeTVController {
    private var window: CubeTVWindow?
    private let model = CubeTVModel()
    private var keyMonitor: Any?
    private var connectObserver: NSObjectProtocol?
    private var lastDirection = (x: 0, y: 0)

    var isOpen: Bool { window != nil }

    func show(items: [LauncherItem]) {
        guard window == nil, let screen = NSScreen.main else { return }
        model.load(items)
        model.onClose = { [weak self] in self?.close() }
        model.onAction = { [weak self] action in self?.perform(action) }
        model.menuOpen = false
        let tv = CubeTVWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        tv.backgroundColor = .black
        tv.contentView = NSHostingView(rootView: CubeTVView(model: model))
        tv.setFrame(screen.frame, display: true)
        self.window = tv
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()
        NSApp.activate(ignoringOtherApps: true)
        tv.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        for pad in GCController.controllers() { bind(pad) }
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let pad = note.object as? GCController { self?.bind(pad) }
        }
    }

    func close() {
        guard let window else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        keyMonitor = nil
        connectObserver = nil
        for pad in GCController.controllers() {
            pad.extendedGamepad?.dpad.valueChangedHandler = nil
            pad.extendedGamepad?.leftThumbstick.valueChangedHandler = nil
            pad.extendedGamepad?.buttonA.pressedChangedHandler = nil
            pad.extendedGamepad?.buttonB.pressedChangedHandler = nil
        }
        NSCursor.unhide()
        NSApp.presentationOptions = []
        window.orderOut(nil)
        self.window = nil
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
        switch event.keyCode {
        case 123: model.move(dx: -1, dy: 0)
        case 124: model.move(dx: 1, dy: 0)
        case 125: model.move(dx: 0, dy: 1)
        case 126: model.move(dx: 0, dy: -1)
        case 36, 76, 49: model.select()
        case 53: model.back()
        default: return false
        }
        return true
    }

    private func bind(_ pad: GCController) {
        guard let gamepad = pad.extendedGamepad else { return }
        let direction: GCControllerDirectionPadValueChangedHandler = { [weak self] _, x, y in
            self?.directional(x: x, y: y)
        }
        gamepad.dpad.valueChangedHandler = direction
        gamepad.leftThumbstick.valueChangedHandler = direction
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.model.select() } }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.model.back() } }
    }

    /// One step per push: the stick or pad must return to center before the next step.
    private func directional(x: Float, y: Float) {
        let now = (x: x > 0.6 ? 1 : x < -0.6 ? -1 : 0, y: y > 0.6 ? -1 : y < -0.6 ? 1 : 0)
        defer { lastDirection = now }
        guard now != lastDirection, now != (0, 0) else { return }
        model.move(dx: now.x, dy: now.y)
    }
}

extension SetupController {
    @objc func openCubeTV() {
        cubeTV.show(items: launcherItems())
    }
}
