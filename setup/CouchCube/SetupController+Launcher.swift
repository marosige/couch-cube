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
        for client in storeAccounts.report?.clients ?? [] where client.platform == "Windows" && client.state != "not_installed" {
            let host = client.host.map { " · \($0)" } ?? ""
            items.append(LauncherItem(id: client.id, title: client.name, subtitle: "Windows" + host, section: .windows,
                                      artwork: launcherIcon(path: nil, bundledID: Self.windowsClientIcons[client.id]),
                                      wideArtwork: false, path: nil, launch: { [weak self] in
                self?.storeClientOpen(client.id) { _ in }
            }))
        }
        let macLaunchers = computerGameApps.subtracting(["curseforge"])
        let retro = emulatorApps.union(["es-de"])
        for app in appStates where app.installed && !app.path.isEmpty && (macLaunchers.contains(app.id) || retro.contains(app.id)) {
            let section: LauncherSection = retro.contains(app.id) ? .retro : .launchers
            items.append(LauncherItem(id: "app-" + app.id, title: app.name, subtitle: appPurposes[app.id] ?? "", section: section,
                                      artwork: launcherIcon(path: app.path, bundledID: app.id), wideArtwork: false, path: app.path,
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

    func renderLauncher() {
        let query = launcherSearch.stringValue.trimmingCharacters(in: .whitespaces)
        let items = launcherItems().filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
        clearRows(launcherSections)
        guard !items.isEmpty else {
            launcherSections.addArrangedSubview(text(query.isEmpty
                ? "Your games appear here. Install Steam or a game launcher in App Store, or add any game with +."
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
                let tile = LauncherTile(item: item, artHeight: 86)
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
