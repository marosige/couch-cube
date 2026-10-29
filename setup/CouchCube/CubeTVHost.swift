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
}
