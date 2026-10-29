import AppKit
import GameController

/// What Cube TV reads from, and asks of, the rest of the app: games, store, controllers and web apps.
extension SetupController {
    @objc func openCubeTV() {
        cubeTV.host = self
        cubeTV.show()
    }

    func tvItems() -> [TVGame] {
        launcherItems().map { item in
            var game = TVGame(item)
            if item.id.hasPrefix("web-") {
                game.kind = .app
                game.closesTV = false
                game.tint = item.id == "web-youtube" ? NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1) : NSColor.systemBlue
                game.symbol = item.id == "web-youtube" ? "play.rectangle.fill" : "globe"
                game.art = .icon
                game.image = nil
            }
            return game
        }
    }

    func tvPageTile(id: String, title: String, subtitle: String, symbol: String, color: NSColor, open: @escaping () -> Void) -> TVGame {
        var game = TVGame(id: id, title: title, subtitle: subtitle)
        game.kind = .page
        game.symbol = symbol
        game.tint = color
        game.closesTV = false
        game.launch = open
        return game
    }

    func openWebApp(_ app: TVWebApp) {
        TVWebWindowController.open(app) { [weak self] in self?.cubeTV.resumeInput() }
    }

    // MARK: Controllers

    func tvStartControllerSearch() {
        tvControllersOpen = true
        refreshControllers()
        startControllerDiscovery()
    }

    func tvStopControllerSearch() {
        tvControllersOpen = false
        if !controllerPageVisible { stopControllerDiscovery() }
    }

    func tvPairable() -> [PairedController] { discoveredControllers }

    func tvPair(_ address: String) {
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(address)
        pairDiscoveredController(button)
    }

    // MARK: Store

    func tvLoadStore() {
        loadHome(refresh: false)
        if wishlist == nil { checkWishlist(refresh: false) }
    }

    func tvStoreShelves() -> [TVShelf] {
        var shelves: [TVShelf] = []
        let wished = (wishlist?.items ?? []).map { tvWishTile($0) }
        if !wished.isEmpty { shelves.append(TVShelf(id: "wishlist", title: "Your Wishlist", games: wished)) }
        if let home = shopHome {
            let featured = home.featured.prefix(20).map { tvDealTile($0) }
            if !featured.isEmpty { shelves.append(TVShelf(id: "featured", title: "Featured Deals", games: Array(featured))) }
            let drops = home.drops.prefix(20).map { tvDealTile($0) }
            if !drops.isEmpty { shelves.append(TVShelf(id: "drops", title: "Price Drops", games: Array(drops))) }
        }
        return shelves
    }

    private func tvDealTile(_ deal: StoreDeal) -> TVGame {
        let key = deal.gameId.map { "cs:" + $0 } ?? "title:" + deal.title.lowercased()
        let price = shopPrice(deal.salePrice, "USD").text
        var game = TVGame(id: "deal-" + deal.id, title: deal.title, subtitle: [deal.store, price].compactMap { $0 }.joined(separator: " \u{00B7} "))
        game.kind = .deal
        game.closesTV = false
        game.remoteURL = (steamArtURL(deal.steamAppId) ?? deal.thumb).flatMap { safeDealURL($0) }
        game.deal = TVGame.Deal(
            key: key,
            payload: ["title": deal.title, "game_id": deal.gameId ?? "", "steam_app_id": deal.steamAppId ?? "", "thumb": deal.thumb ?? ""]
                .filter { !$0.value.isEmpty },
            price: price,
            was: deal.normalPrice.flatMap { $0 > deal.salePrice ? shopPrice($0, "USD").text : nil },
            savings: deal.savings, store: deal.store,
            inWishlist: wishlistItem(key: key, title: deal.title) != nil)
        return game
    }

    private func tvWishTile(_ item: WishlistItem) -> TVGame {
        var game = TVGame(id: "wish-" + item.key, title: item.title, subtitle: item.saleText ?? "Wishlist")
        game.kind = .deal
        game.closesTV = false
        game.remoteURL = (steamArtURL(item.steamAppId) ?? item.thumb).flatMap { safeDealURL($0) }
        let best = item.best
        var wasText: String?
        if let best, let normal = best.normalPrice, normal > best.price { wasText = shopPrice(normal, best.currency).text }
        game.deal = TVGame.Deal(
            key: item.key, payload: ["title": item.title],
            price: best.map { shopPrice($0.price, $0.currency).text } ?? "No price yet",
            was: wasText,
            savings: best?.savings ?? 0, store: best?.store, inWishlist: true)
        return game
    }

    func tvToggleWishlist(key: String, payload: [String: String], inWishlist: Bool) {
        guard wishlistEditable else { return }
        if let item = wishlistItem(key: key, title: payload["title"] ?? "") {
            changeWishlist(["--remove", item.key])
        } else if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            changeWishlist(["--add", String(decoding: json, as: UTF8.self)])
        }
    }

    // MARK: Adding apps (Desktop)

    @objc func showAddLauncherMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Add App\u{2026}", action: #selector(addLauncherApps), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Web App\u{2026}", action: #selector(addWebApp), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func addWebApp() {
        let alert = NSAlert()
        alert.messageText = "Add a web app"
        alert.informativeText = "It opens full screen, on the Mac and in Cube TV, and can only visit its own site (including that company's sign-in pages). Example: https://music.apple.com"
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        name.placeholderString = "Name, e.g. Apple Music"
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        address.placeholderString = "https://\u{2026}"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        box.addSubview(name)
        box.addSubview(address)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let app = TVWebApps.make(name: name.stringValue, address: address.stringValue) else {
            activityNeeded("A web app needs a name and an https:// address.")
            return
        }
        TVWebApps.saved = TVWebApps.saved.filter { $0.id != app.id } + [app]
        renderLauncher()
    }

    @objc func launcherMenuRemoveWebApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        TVWebApps.saved = TVWebApps.saved.filter { "web-" + $0.id != id }
        renderLauncher()
    }

    // MARK: Running apps and the Home button

    /// Apps that are open right now: not Couch Cube, Finder or other system helpers.
    func tvRunningApps() -> [NSRunningApplication] {
        let hidden: Set<String> = ["me.marosi.couchcube", "com.apple.finder", "com.apple.dock", "com.apple.loginwindow"]
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !hidden.contains($0.bundleIdentifier ?? "")
        }
    }

    /// Games and apps you would want to see on the TV: running, but not just a launcher waiting in the background.
    func tvForegroundApps() -> [NSRunningApplication] {
        let preloaded = Set(preloadPaths)
        return tvRunningApps().filter { !$0.isHidden && !preloaded.contains($0.bundleURL?.path ?? "") }
    }

    func tvRunning() -> [TVGame] {
        tvRunningApps().map { app in
            var game = TVGame(id: "running-\(app.processIdentifier)", title: app.localizedName ?? "App",
                              subtitle: app.isHidden ? "Preloaded in the background" : "Running")
            game.kind = .running
            game.pid = app.processIdentifier
            game.image = app.icon
            game.art = .icon
            game.closesTV = false
            return game
        }
    }

    func tvRunningAction(pid: pid_t, action: Int) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        switch action {
        case 0:
            app.unhide()
            app.activate(options: [.activateAllWindows])
        case 1: app.terminate()
        default: app.forceTerminate()
        }
    }

    /// The controller's Home button (or a quick tap of Select + Start) brings Cube TV back, whatever is in front.
    /// Handlers fire at once; a 0.1 s poll catches presses the handlers miss, the way the in-game quit helper reads pads.
    func startHomeWatcher() {
        guard !homeWatcherStarted else { return }
        homeWatcherStarted = true
        GCController.shouldMonitorBackgroundEvents = true
        for pad in GCController.controllers() { bindHome(pad) }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let pad = note.object as? GCController { self?.bindHome(pad) }
        }
        homeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollHome() }
    }

    private func bindHome(_ pad: GCController) {
        guard let home = pad.extendedGamepad?.buttonHome else { return }
        home.preferredSystemGestureState = .disabled
        home.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.homePressed("Home button") }
        }
    }

    private func pollHome() {
        var homeDown = false
        var comboDown = false
        for pad in GCController.controllers() {
            guard let gamepad = pad.extendedGamepad else { continue }
            if gamepad.buttonHome?.isPressed == true { homeDown = true }
            if gamepad.buttonOptions?.isPressed == true && gamepad.buttonMenu.isPressed { comboDown = true }
        }
        if homeDown && !homeWasDown { homePressed("Home button") }
        homeWasDown = homeDown
        if comboDown {
            if comboStart == nil { comboStart = Date() }
        } else if let start = comboStart {
            comboStart = nil
            // A quick tap goes home; holding for two seconds is the in-game quit and is left alone.
            if Date().timeIntervalSince(start) < 0.8 { homePressed("Select + Start") }
        }
        renderHomeStatus()
    }

    func homePressed(_ source: String) {
        homeLast = (Date(), source)
        guard Date().timeIntervalSince(homeFiredAt) > 1 else { return }
        homeFiredAt = Date()
        cubeTV.host = self
        cubeTV.goHome()
    }

    func renderHomeStatus() {
        let pads = GCController.controllers()
        let hasHome = pads.contains { $0.extendedGamepad?.buttonHome != nil }
        var line = pads.isEmpty ? "No controller connected."
            : hasHome ? "Home button found on your controller." : "Your controller reports no Home button; tap Select + Start instead."
        if let last = homeLast {
            line += " Last: \(last.1) at \(DateFormatter.localizedString(from: last.0, dateStyle: .none, timeStyle: .medium))."
        } else if !pads.isEmpty {
            line += " Press it to test: nothing seen yet."
        }
        if homeStatus.stringValue != line { homeStatus.stringValue = line }
    }

    /// Keeps the Play tile and the running list current, and brings Cube TV back when the last game closes.
    func startRunningWatcher() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.renderGeneral()
                self.renderPreload()
                let ended = note.name == NSWorkspace.didTerminateApplicationNotification
                if ended, self.tvResumeAfterGame, !self.cubeTV.isOpen, self.tvForegroundApps().isEmpty {
                    self.tvResumeAfterGame = false
                    self.openCubeTV()
                }
            }
        }
    }
}
