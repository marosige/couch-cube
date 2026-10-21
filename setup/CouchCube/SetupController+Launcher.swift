import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    /// The Play page's game launcher: every game and launcher on this Mac in one place.
    func launcherSection() -> NSView {
        let heading = text("Games", size: 22)
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        launcherSearch.placeholderString = "Search games"
        launcherSearch.sendsSearchStringImmediately = true
        launcherSearch.target = self
        launcherSearch.action = #selector(launcherSearchChanged)
        launcherSearch.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let add = headerIconButton("plus", label: "Add a game or app", action: #selector(addLauncherApps))
        add.toolTip = "Add any game or app to Play"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = row([heading, spacer, launcherSearch, add])
        launcherSections.orientation = .vertical
        launcherSections.alignment = .leading
        launcherSections.spacing = 20
        return column([header, launcherSections])
    }

    var launcherAddedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.launcherAppsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.launcherAppsKey) }
    }

    func launcherIcon(path: String?, bundledID: String?) -> NSImage? {
        if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return bundledID.flatMap { id in
            Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("AppIcons/\(id).png")) }
        }
    }

    func openLauncherApp(_ path: String, name: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { self.status.stringValue = "Couldn't open \(name): \(error.localizedDescription)" }
        }
    }

    func launcherItems() -> [LauncherItem] {
        if let smoke = launcherSmokeItems { return smoke }
        var items: [LauncherItem] = []
        var seenSteam = Set<String>()
        for library in steamReport?.libraries ?? [] where library.available {
            for game in library.games where game.installed && !isSteamTool(appid: game.appid, name: game.name) {
                guard seenSteam.insert(game.appid).inserted else { continue }
                let artwork = steamHeaderArtwork(appid: game.appid)
                items.append(LauncherItem(id: "steam-" + game.appid, title: game.name, subtitle: "Steam", section: .steam,
                                          artwork: artwork ?? launcherIcon(path: nil, bundledID: "steam"), wideArtwork: artwork != nil,
                                          path: nil, launch: { [weak self] in
                    guard let url = URL(string: "steam://rungameid/\(game.appid)") else { return }
                    if !NSWorkspace.shared.open(url) { self?.status.stringValue = "Couldn't open Steam to start \(game.name)." }
                }))
            }
        }
        // Each ROM starts straight in its console's emulator (no frontend in between).
        for rom in launcherLibrary?.roms ?? [] {
            items.append(LauncherItem(id: "rom-" + rom.path, title: rom.name, subtitle: rom.systemName, section: .retro,
                                      artwork: ConsoleArtwork.image(for: rom.system), wideArtwork: false, path: rom.path,
                                      launch: { [weak self] in self?.launchRom(rom) }))
        }
        for app in launcherLibrary?.apps ?? [] {
            let subtitle = ["native": "Mac", "windows": "Windows", "porting-kit": "Porting Kit",
                            "crossover": "CrossOver" + (app.group.map { " \u{00B7} \($0)" } ?? "")][app.kind] ?? ""
            items.append(LauncherItem(id: "app-" + app.path, title: app.name, subtitle: subtitle,
                                      section: app.kind == "native" ? .mac : .windows,
                                      artwork: NSWorkspace.shared.icon(forFile: app.path), wideArtwork: false, path: app.path,
                                      launch: { [weak self] in self?.openLauncherApp(app.path, name: app.name) }))
        }
        for path in launcherAddedPaths where FileManager.default.fileExists(atPath: path) {
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            items.append(LauncherItem(id: "added-" + path, title: name, subtitle: "", section: .added,
                                      artwork: NSWorkspace.shared.icon(forFile: path), wideArtwork: false, path: path,
                                      launch: { [weak self] in self?.openLauncherApp(path, name: name) }))
        }
        return items
    }

    /// Games in the Couch Cube library (ROMs, Mac games, Windows wrappers, Porting Kit) and CrossOver shortcuts.
    func loadLauncherLibrary() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"), selected != nil else { return }
        runBackendInBackground(["library-games"]) { [weak self] code, data, _ in
            guard let self, code == 0 else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            self.launcherLibrary = try? decoder.decode(LibraryGames.self, from: data)
            self.renderLauncher()
        }
    }

    func launchRom(_ rom: LibraryGames.Rom) {
        status.stringValue = "Starting \(rom.name)\u{2026}"
        runBackendInBackground(["emulate", "--system", rom.system, "--rom", rom.path]) { [weak self] code, _, errors in
            guard let self else { return }
            self.status.stringValue = code == 0 ? "" : "Couldn't start \(rom.name): " +
                self.backendErrorMessageText(errors)
        }
    }

    func backendErrorMessageText(_ errors: String) -> String {
        backendErrorMessage(errors, fallback: "the emulator didn't open. Check it in App Store.")
    }

    func renderLauncher() {
        let query = launcherSearch.stringValue.trimmingCharacters(in: .whitespaces)
        let items = launcherItems().filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
        clearRows(launcherSections)
        guard !items.isEmpty else {
            launcherSections.addArrangedSubview(text(query.isEmpty
                ? "Your games appear here: Steam games, ROMs in your library and Windows games. Add any other game with +."
                : "No games match \u{201C}\(query)\u{201D}.", size: 13, secondary: true))
            return
        }
        for section in LauncherSection.allCases {
            let group = items.filter { $0.section == section }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            guard !group.isEmpty else { continue }
            let title = text(section.rawValue, size: 15)
            title.font = .systemFont(ofSize: 15, weight: .semibold)
            let flow = TileFlowView()
            flow.setTiles(group.map { item in
                let tile = LauncherTile(item: item)
                tile.identifier = NSUserInterfaceItemIdentifier("launcher-" + item.id)
                tile.menu = launcherMenu(for: item)
                return tile
            })
            let stack = column([title, flow])
            stack.spacing = 10
            launcherSections.addArrangedSubview(stack)
            stack.widthAnchor.constraint(equalTo: launcherSections.widthAnchor).isActive = true
        }
    }

    func launcherMenu(for item: LauncherItem) -> NSMenu? {
        guard let path = item.path else { return nil }
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open", action: #selector(launcherMenuOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = item.id
        let finder = menu.addItem(withTitle: "Show in Finder", action: #selector(launcherMenuShowInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = path
        if item.section == .added {
            menu.addItem(.separator())
            let remove = menu.addItem(withTitle: "Remove from Play", action: #selector(launcherMenuRemove(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = path
        }
        return menu
    }

    @objc func launcherMenuOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        launcherItems().first { $0.id == id }?.launch()
    }

    @objc func launcherMenuShowInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func launcherMenuRemove(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        launcherAddedPaths.removeAll { $0 == path }
        renderLauncher()
    }

    @objc func launcherSearchChanged() { renderLauncher() }

    @objc func addLauncherApps() {
        let panel = NSOpenPanel()
        panel.title = "Add games or apps to Play"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var paths = launcherAddedPaths
        for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
        launcherAddedPaths = paths
        renderLauncher()
    }
}
