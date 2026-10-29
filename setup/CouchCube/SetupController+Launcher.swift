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
        let add = headerIconButton("plus", label: "Add a game or app", action: #selector(showAddLauncherMenu(_:)))
        add.toolTip = "Add any app or web app to Play"
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
            DispatchQueue.main.async { self.activityNeeded("Couldn't open \(name): \(error.localizedDescription)") }
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
                    if !NSWorkspace.shared.open(url) { self?.activityNeeded("Couldn't open Steam to start \(game.name).") }
                }, artworkURL: artwork == nil ? steamArtURL(game.appid).flatMap { safeDealURL($0) } : nil))
            }
        }
        // Each ROM starts straight in its console's emulator (no frontend in between).
        for rom in launcherLibrary?.roms ?? [] {
            // SteamGridDB's wide grid (when a key is set) fills the tile; else libretro's box cover; else the console.
            let grid = gameArt[rom.path]?["grid"].flatMap { NSImage(contentsOfFile: $0) }
            let cover = grid == nil ? rom.cover.flatMap { NSImage(contentsOfFile: $0) } : nil
            items.append(LauncherItem(id: "rom-" + rom.path, title: rom.name, subtitle: rom.systemName, section: .retro,
                                      artwork: grid ?? cover ?? ConsoleArtwork.image(for: rom.system), wideArtwork: grid != nil, path: rom.path,
                                      launch: { [weak self] in self?.launchRom(rom) }, coverArt: cover != nil))
        }
        for app in launcherLibrary?.apps ?? [] {
            let subtitle = ["native": "Mac", "windows": "Windows", "porting-kit": "Porting Kit",
                            "crossover": "CrossOver" + (app.group.map { " \u{00B7} \($0)" } ?? "")][app.kind] ?? ""
            let grid = gameArt[app.path]?["grid"].flatMap { NSImage(contentsOfFile: $0) }
            items.append(LauncherItem(id: "app-" + app.path, title: app.name, subtitle: subtitle,
                                      section: app.kind == "native" ? .mac : .windows,
                                      artwork: grid ?? NSWorkspace.shared.icon(forFile: app.path), wideArtwork: grid != nil, path: app.path,
                                      launch: { [weak self] in self?.openLauncherApp(app.path, name: app.name) }))
        }
        for app in TVWebApps.all {
            items.append(LauncherItem(id: "web-" + app.id, title: app.name, subtitle: "Web app", section: .apps,
                                      artwork: NSImage(systemSymbolName: app.id == "youtube" ? "play.rectangle.fill" : "globe", accessibilityDescription: nil),
                                      wideArtwork: false, path: nil, launch: { [weak self] in self?.openWebApp(app) }))
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
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        guard selected != nil else {
            // The library's drive is gone: its games can't start, so they leave Play too.
            if launcherLibrary != nil || !gameArt.isEmpty {
                launcherLibrary = nil
                gameArt = [:]
                renderLauncher()
            }
            return
        }
        runBackendInBackground(libraryCommand(["library-games"])) { [weak self] code, data, _ in
            guard let self, code == 0 else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            self.launcherLibrary = try? decoder.decode(LibraryGames.self, from: data)
            self.renderLauncher()
            self.loadRomArt()
            self.loadGameArt()
        }
    }

    /// SteamGridDB art for ROMs and game apps, only with the user's own key (saved in the library, so a portable
    /// drive brings it along). Fetched in the background a few games at a time and cached on this Mac.
    func loadGameArt() {
        guard !gameArtLoading, gameArtRounds < 10, selected != nil,
              !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        gameArtLoading = true
        gameArtRounds += 1
        runBackendInBackground(libraryCommand(["game-art"])) { [weak self] code, data, _ in
            guard let self else { return }
            self.gameArtLoading = false
            guard code == 0, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let art = reply["art"] as? [String: [String: String]] ?? [:]
            self.gameArtKeyField.placeholderString = reply["enabled"] as? Bool == true ? "Key saved" : "API key"
            let error = reply["error"] as? String
            self.gameArtStatus.stringValue = error ?? (art.isEmpty ? "" : "Artwork for \(art.count) game\(art.count == 1 ? "" : "s") on this Mac.")
            self.gameArtStatus.textColor = error == nil ? .secondaryLabelColor : .systemOrange
            if art != self.gameArt {
                self.gameArt = art
                self.renderLauncher()
            }
            if reply["more"] as? Bool == true && error == nil { self.loadGameArt() }
        }
    }

    func gameArtworkCard() -> NSView {
        gameArtKeyField.placeholderString = "API key"
        gameArtKeyField.target = self
        gameArtKeyField.action = #selector(saveGameArtKey)
        gameArtKeyField.setAccessibilityLabel("SteamGridDB API key")
        gameArtKeyField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        gameArtStatus.font = .systemFont(ofSize: 11)
        gameArtStatus.textColor = .secondaryLabelColor
        gameArtStatus.lineBreakMode = .byWordWrapping
        gameArtStatus.maximumNumberOfLines = 0
        let get = button("Get a Free Key", #selector(openSteamGridDBKeyPage))
        let remove = button("Remove Key", #selector(removeGameArtKey))
        let actions = row([get, remove, gameArtStatus, NSView()])
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 38, bottom: 0, right: 0)
        return card("Game artwork", subtitle: nil, views: [
            settingsRow("SteamGridDB", subtitle: "Optional: banners, logos and icons for retro and Windows games. Saved with your game library.",
                        symbol: "photo.on.rectangle.angled", color: .systemPurple,
                        trailing: row([gameArtKeyField, button("Save", #selector(saveGameArtKey))])),
            actions
        ])
    }

    @objc func openSteamGridDBKeyPage() {
        if let url = URL(string: "https://www.steamgriddb.com/profile/preferences/api") { NSWorkspace.shared.open(url) }
    }

    @objc func saveGameArtKey() {
        let key = gameArtKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard key.range(of: "^[A-Za-z0-9]{16,64}$", options: .regularExpression) != nil else {
            gameArtStatus.stringValue = "That doesn't look like a SteamGridDB API key."
            gameArtStatus.textColor = .systemOrange
            return
        }
        guard selected != nil else {
            gameArtStatus.stringValue = "Set up your game library first; the key is saved there."
            gameArtStatus.textColor = .systemOrange
            return
        }
        runBackendInBackground(libraryCommand(["game-art-key", "--set", key])) { [weak self] code, _, errors in
            guard let self else { return }
            guard code == 0 else {
                self.gameArtStatus.stringValue = "Couldn't save the key: " + backendErrorMessage(errors, fallback: "check Game library.")
                self.gameArtStatus.textColor = .systemOrange
                return
            }
            self.gameArtKeyField.stringValue = ""
            self.gameArtKeyField.placeholderString = "Key saved"
            self.gameArtStatus.stringValue = "Saved in your game library. Artwork loads in the background."
            self.gameArtStatus.textColor = .secondaryLabelColor
            self.gameArtRounds = 0
            self.loadGameArt()
        }
    }

    @objc func removeGameArtKey() {
        guard selected != nil else { return }
        runBackendInBackground(libraryCommand(["game-art-key", "--clear"])) { [weak self] code, _, _ in
            guard let self, code == 0 else { return }
            self.gameArt = [:]
            self.gameArtKeyField.placeholderString = "API key"
            self.gameArtStatus.stringValue = "Key removed."
            self.gameArtStatus.textColor = .secondaryLabelColor
            self.renderLauncher()
        }
    }

    /// Box covers for ROMs (libretro thumbnails, keyless), fetched in the background a batch at a time; the
    /// library reloads to show them. Covers stay cached on this Mac, so this only works once per game.
    func loadRomArt() {
        guard !romArtLoading, romArtRounds < 10, launcherLibrary?.roms.contains(where: { $0.cover == nil }) == true else { return }
        romArtLoading = true
        romArtRounds += 1
        runBackendInBackground(libraryCommand(["rom-art"])) { [weak self] code, data, _ in
            guard let self else { return }
            self.romArtLoading = false
            guard code == 0, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let covers = reply["covers"] as? [String: String] else { return }
            let known = Set(self.launcherLibrary?.roms.compactMap(\.cover) ?? [])
            if covers.values.contains(where: { !known.contains($0) }) || reply["more"] as? Bool == true {
                self.loadLauncherLibrary()
            }
        }
    }

    /// Library commands name the active library explicitly (`--root`); without it the backend falls back to a
    /// host setup file that a library used only on this Mac never writes.
    func libraryCommand(_ arguments: [String]) -> [String] {
        guard let root = selected?.root else { return arguments }
        return arguments + ["--root", root]
    }

    func launchRom(_ rom: LibraryGames.Rom) {
        status.stringValue = "Starting \(rom.name)\u{2026}"
        runBackendInBackground(libraryCommand(["emulate", "--system", rom.system, "--rom", rom.path])) { [weak self] code, _, errors in
            guard let self else { return }
            self.status.stringValue = ""
            if code != 0 { self.activityNeeded("Couldn't start \(rom.name): " + self.backendErrorMessageText(errors)) }
        }
    }

    func backendErrorMessageText(_ errors: String) -> String {
        backendErrorMessage(errors, fallback: "the emulator didn't open. Check it in App Store.")
    }

    /// renderGeneral runs after most backend replies; the game grid is rebuilt only when what it shows changed,
    /// so tiles aren't reloaded from disk (or swapped out mid-click) for unrelated updates.
    func renderLauncherIfChanged() {
        guard launcherSignatureNow() != launcherSignature || launcherSections.arrangedSubviews.isEmpty else { return }
        renderLauncher()
    }

    func launcherSignatureNow() -> Int {
        var hasher = Hasher()
        for library in steamReport?.libraries ?? [] where library.available {
            for game in library.games where game.installed { hasher.combine(game.appid) }
        }
        for rom in launcherLibrary?.roms ?? [] { hasher.combine(rom.path); hasher.combine(rom.cover) }
        for app in launcherLibrary?.apps ?? [] { hasher.combine(app.path) }
        hasher.combine(gameArt.count)
        hasher.combine(launcherAddedPaths)
        hasher.combine(TVWebApps.all.map(\.id))
        hasher.combine(launcherSearch.stringValue)
        hasher.combine(launcherSmokeItems?.map(\.id))
        return hasher.finalize()
    }

    func renderLauncher() {
        defer { cubeTV.reload() }
        let query = launcherSearch.stringValue.trimmingCharacters(in: .whitespaces)
        let items = launcherItems().filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
        launcherSignature = launcherSignatureNow()
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
        if item.id.hasPrefix("web-") {
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "Open", action: #selector(launcherMenuOpen(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = item.id
            if item.id != "web-youtube" {
                menu.addItem(.separator())
                let remove = menu.addItem(withTitle: "Remove from Play", action: #selector(launcherMenuRemoveWebApp(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = item.id
            }
            return menu
        }
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
