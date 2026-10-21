import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    // MARK: Game pages: one per game, opened from any Cube Shop list

    func shopDetail(deal: StoreDeal) -> ShopDetail {
        let offer = ShopOffer(storeId: deal.store == "Steam" ? "1" : "0", store: deal.store ?? "Store", price: deal.salePrice,
                              normalPrice: deal.normalPrice, savings: deal.savings, currency: "USD", url: deal.url)
        return ShopDetail(key: deal.gameId.map { "cs:" + $0 } ?? "title:" + deal.title.lowercased(), title: deal.title,
                          gameId: deal.gameId, steamAppId: deal.steamAppId, thumb: deal.thumb, offers: [offer],
                          ratings: ShopRatings(steamPercent: deal.steamRatingPercent, steamText: deal.steamRating,
                                               metacritic: deal.metacritic, deal: deal.dealRating),
                          installed: deal.installed,
                          payload: ["title": deal.title, "game_id": deal.gameId ?? "", "steam_app_id": deal.steamAppId ?? "", "thumb": deal.thumb ?? ""])
    }

    func shopDetail(giveaway: Giveaway) -> ShopDetail {
        ShopDetail(key: "title:" + giveaway.title.lowercased(), title: giveaway.title, thumb: giveaway.thumb, offers: [],
                   giveaway: giveaway, payload: ["title": giveaway.title, "thumb": giveaway.thumb ?? ""])
    }

    func shopDetail(wishlist item: WishlistItem) -> ShopDetail {
        var offers: [ShopOffer] = []
        if let id = item.appStoreId, let best = item.best {
            offers.append(ShopOffer(storeId: nil, store: "Mac App Store", price: best.price, normalPrice: best.normalPrice,
                                    savings: best.savings, currency: best.currency, url: "https://apps.apple.com/app/id\(id)"))
        }
        return ShopDetail(key: item.key, title: item.title, gameId: item.gameId, steamAppId: item.steamAppId, appStoreId: item.appStoreId,
                          thumb: item.thumb, offers: offers, insight: item.insight,
                          payload: ["title": item.title, "game_id": item.gameId ?? "", "steam_app_id": item.steamAppId ?? "",
                                    "app_store_id": item.appStoreId ?? "", "thumb": item.thumb ?? ""])
    }

    func shopDetail(game: ShopGame) -> ShopDetail {
        ShopDetail(key: "cs:" + game.id, title: game.title, gameId: game.id, steamAppId: game.steamAppId, appStoreId: game.appStoreOffer?.id,
                   thumb: game.thumb, offers: game.offers + (game.appStoreOffer.map { [$0.offer] } ?? []), insight: game.insight,
                   payload: ["title": game.title, "game_id": game.id, "steam_app_id": game.steamAppId ?? "", "thumb": game.thumb ?? ""])
    }

    func shopDetail(app: AppStoreGame) -> ShopDetail {
        ShopDetail(key: "app:" + app.id, title: app.title, appStoreId: app.id, thumb: app.thumb, offers: [app.offer],
                   payload: ["title": app.title, "app_store_id": app.id, "thumb": app.thumb ?? ""])
    }

    /// Opens a game page; Back returns to the Shop list it came from, in the same state.
    func showShopGame(_ detail: ShopDetail?) {
        guard var detail else { return }
        let fresh = detail.offers.isEmpty || (detail.offers.count == 1 && detail.offers[0].storeId != nil)
        if let gameId = detail.gameId, detail.giveaway == nil, fresh, shopDetails[detail.key]?.loading != true {
            detail.loading = true
            loadShopGame(key: detail.key, gameId: gameId)
        }
        if let appId = detail.steamAppId, detail.steam == nil, !detail.steamLoading, shopDetails[detail.key]?.steamLoading != true {
            detail.steamLoading = true
            loadSteamDetails(key: detail.key, appId: appId)
        }
        if shopDetailKey != detail.key { shopGalleryIndex = 0 }
        shopDetails[detail.key] = detail
        shopDetailKey = detail.key
        renderShopGame()
        selectPage(14)
        if let scroll = tabs.tabViewItems[14].view as? NSScrollView { scroll.contentView.scroll(to: .zero) }
    }

    /// Every current store offer and the all-time low for a game opened from a single deal or the wishlist.
    func loadShopGame(key: String, gameId: String) {
        shopRead(["shop-game", "--id", gameId]) { [weak self] code, data, errors in
            guard let self, var detail = self.shopDetails[key] else { return }
            detail.loading = false
            if code == 0, let reply = decodeDeals(ShopGameReply.self, data), let game = reply.game {
                // Mac App Store offers come from search or the wishlist, never from CheapShark; keep them.
                detail.offers = game.offers + detail.offers.filter { $0.storeId == nil }
                detail.insight = game.insight ?? detail.insight
                detail.steamAppId = detail.steamAppId ?? game.steamAppId
                detail.thumb = detail.thumb ?? game.thumb
            } else if code != 0 {
                detail.error = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
            }
            self.shopDetails[key] = detail
            if self.shopDetailKey == key { self.renderShopGame() }
        }
    }

    /// Steam's screenshots and store facts (genre, developer, size, controller and couch play) for the page.
    func loadSteamDetails(key: String, appId: String) {
        shopRead(["shop-steam", "--app", appId]) { [weak self] code, data, _ in
            guard let self, var detail = self.shopDetails[key] else { return }
            detail.steamLoading = false
            if code == 0, let facts = decodeDeals(SteamDetails.self, data), facts.found { detail.steam = facts }
            self.shopDetails[key] = detail
            if self.shopDetailKey == key { self.renderShopGame() }
        }
    }

    func renderShopGame() {
        schedulePlatformLookup()
        clearRows(shopDetailContent)
        guard let key = shopDetailKey, let detail = shopDetails[key] else { return }
        var views: [NSView] = []

        // Big art: Steam's banner when the game is on Steam, otherwise the store's own picture; then screenshots.
        shopGalleryImages = ([steamArtURL(detail.steamAppId, "capsule_616x353.jpg") ?? detail.thumb] + (detail.steam?.screenshots ?? []))
            .compactMap { $0 }.filter { safeDealURL($0) != nil }
        shopGalleryIndex = min(shopGalleryIndex, max(0, shopGalleryImages.count - 1))
        views.append(shopGallery(fill: detail.appStoreId == nil || detail.steamAppId != nil))

        let title = NSTextField(wrappingLabelWithString: detail.title)
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.setAccessibilityIdentifier("shopGameTitle")
        views.append(title)

        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        let compat = compatibilityBadge(compatibility(steamAppId: detail.steamAppId, appStore: detail.appStoreId != nil && detail.gameId == nil))
        if let compat { badges.append(compat.badge); tips.append(compat.tip) }
        if detail.installed { badges.append(("checkmark.circle.fill", "Installed", .systemGreen)) }
        if let owned = ownedBadge(detail.steamAppId, installed: detail.installed) { badges.append(owned) }
        if let percent = detail.ratings.steamPercent {
            badges.append(("hand.thumbsup.fill", "Steam \(percent)%", Self.ratingColor(Double(percent), good: 80, fair: 50)))
            tips.append("Steam reviews: " + (detail.ratings.steamText.map { "\($0) (\(percent)%)" } ?? "\(percent)%"))
        }
        if let score = detail.ratings.metacritic {
            badges.append(("m.square.fill", "Metacritic \(score)", Self.ratingColor(Double(score), good: 75, fair: 50)))
            tips.append("Metacritic score: \(score)")
        }
        if let type = detail.giveaway?.type { badges.append((nil, type, .secondaryLabelColor)) }
        if !badges.isEmpty {
            let line = NSTextField(labelWithAttributedString: dealBadges(badges))
            line.toolTip = tips.joined(separator: "\n")
            line.setAccessibilityIdentifier("dealBadges")
            views.append(line)
        }
        // What kind of game it is, right under the name (Steam's genres), like a store's category tags.
        if let genres = detail.steam?.genres, !genres.isEmpty {
            let tags = row(genres.map { genre in
                let tag = NSTextField(labelWithString: genre)
                tag.font = .systemFont(ofSize: 11, weight: .medium)
                tag.textColor = .secondaryLabelColor
                let pill = NSBox()
                pill.boxType = .custom
                pill.titlePosition = .noTitle
                pill.borderWidth = 0
                pill.cornerRadius = 9
                pill.fillColor = .quaternaryLabelColor
                pill.contentViewMargins = NSSize(width: 8, height: 2)
                pill.contentView = tag
                return pill
            } + [NSView()])
            tags.spacing = 6
            tags.setAccessibilityIdentifier("shopGameGenres")
            tags.setAccessibilityElement(true)
            tags.setAccessibilityLabel("Genre: " + genres.joined(separator: ", "))
            views.append(tags)
        }

        views.append(shopGamePriceCard(detail))
        if let about = shopGameAboutCard(detail) { views.append(about) }
        if detail.giveaway == nil { views.append(shopGameStoresCard(detail)) }
        let note = text("Prices from CheapShark and the Mac App Store. Couch Cube never buys anything: every store opens in your browser.",
                        size: 11, secondary: true)
        views.append(note)
        for view in views {
            shopDetailContent.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: shopDetailContent.widthAnchor).isActive = true
        }
        shopDetailContent.setCustomSpacing(6, after: title)
        if currentPage == 14 { screenTitle.stringValue = detail.title }
    }

    /// The price, the discount, the all-time low and the main action, with the wishlist heart and target beside them.
    func shopGamePriceCard(_ detail: ShopDetail) -> NSView {
        let heart = wishlistHeart(key: detail.key, title: detail.title, payload: detail.payload)
        var lines: [NSView] = []
        let priceLine = NSStackView()
        priceLine.orientation = .horizontal
        priceLine.alignment = .centerY
        priceLine.spacing = 10
        let action = NSButton(title: "", target: self, action: #selector(shopGameOpen(_:)))
        action.bezelStyle = .rounded
        action.controlSize = .large
        action.keyEquivalent = "\r"
        action.setAccessibilityIdentifier("shopGameOpen")
        if let giveaway = detail.giveaway {
            let free = NSTextField(labelWithString: "Free")
            free.font = .systemFont(ofSize: 24, weight: .bold)
            free.textColor = .systemGreen
            priceLine.addArrangedSubview(free)
            if let worth = giveawayWorth(giveaway)?.text ?? giveaway.worth {
                priceLine.addArrangedSubview(strikethrough("Usually " + worth))
            }
            action.title = "Get It" + (giveawayStore(giveaway).map { " on \($0)" } ?? "")
            action.identifier = NSUserInterfaceItemIdentifier("gp:" + giveaway.url)
            if let end = DealExpiry.parseGamerPowerEnd(giveaway.endDate), end > dealsNow() {
                lines.append(reminderButton(giveaway, end: end))
            }
        } else if let best = sortedShopOffers(detail.offers).first {
            if let savings = best.offer.savings, savings > 0 { priceLine.addArrangedSubview(discountPill(savings, size: 15)) }
            let price = NSTextField(labelWithString: best.price.text)
            price.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
            if best.price.converted { price.toolTip = "\(best.price.text) (\(best.price.original))" }
            price.setAccessibilityIdentifier("shopGamePrice")
            priceLine.addArrangedSubview(price)
            if let normal = best.offer.normalPrice, normal > best.offer.price {
                priceLine.addArrangedSubview(strikethrough(shopPrice(normal, best.offer.currency).text))
            }
            action.title = "View at \(best.offer.store)"
            action.identifier = NSUserInterfaceItemIdentifier((best.offer.storeId == nil ? "app:" : "cs:") + best.offer.url)
            let normal = detail.offers.filter { $0.storeId != nil }.compactMap(\.normalPrice).max()
            if best.offer.storeId != nil, let insight = insightLabel(detail.insight, normal: normal) {
                (insight as? NSTextField)?.font = .systemFont(ofSize: 12, weight: detail.insight?.kind == "record" ? .semibold : .regular)
                lines.append(insight)
            }
        } else {
            let price = NSTextField(labelWithString: detail.loading ? "Checking prices\u{2026}" : "No current price")
            price.font = .systemFont(ofSize: 17, weight: .semibold)
            price.textColor = .secondaryLabelColor
            priceLine.addArrangedSubview(price)
            action.title = "Search Every Store"
            action.identifier = NSUserInterfaceItemIdentifier("search:" + detail.title)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        priceLine.addArrangedSubview(spacer)
        if detail.giveaway == nil {
            priceLine.addArrangedSubview(shopTargetButton(key: detail.key, title: detail.title,
                                                          currency: sortedShopOffers(detail.offers).first?.offer.currency ?? "USD"))
        }
        priceLine.addArrangedSubview(heart)
        let videos = NSButton(title: "Gameplay Videos", target: self, action: #selector(shopGameVideos(_:)))
        videos.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)
        videos.imagePosition = .imageLeading
        videos.bezelStyle = .rounded
        videos.controlSize = .large
        videos.identifier = NSUserInterfaceItemIdentifier(detail.title)
        videos.toolTip = "Search YouTube for \u{201C}\(detail.title) gameplay\u{201D} in your browser"
        videos.setAccessibilityIdentifier("shopGameVideos")
        let actions = row([action, videos])
        return card("", subtitle: nil, views: [priceLine] + lines + [actions])
    }

    func strikethrough(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        label.setAccessibilityIdentifier("shopWasPrice")
        return label
    }

    /// Every store selling the game, cheapest first, each opening that store in the browser.
    func shopGameStoresCard(_ detail: ShopDetail) -> NSView {
        let offers = sortedShopOffers(detail.offers)
        let mixed = Set(offers.map(\.offer.currency)).count > 1 && !(shopCurrency != nil && exchangeRates != nil)
        let list = NSStackView()
        shopList(list, id: "shopGameStores")
        for (index, item) in offers.enumerated() {
            addShopRow(offerRow(detail.title, item.offer, item.price, cheapest: item.cheapest && offers.count > 1, mixed: mixed,
                                steamAppId: detail.steamAppId), to: list, separated: index > 0)
        }
        var views: [NSView] = [list]
        if detail.loading { views.append(text("Checking every store\u{2026}", size: 12, secondary: true)) }
        if let error = detail.error { views.append(text(error, size: 12, secondary: true)) }
        if offers.isEmpty && !detail.loading { views.append(text("No store sells it right now.", size: 12, secondary: true)) }
        let box = card("Where to Buy", subtitle: nil, views: views)
        box.setAccessibilityIdentifier("shopGameStoresCard")
        return box
    }

    /// YouTube search for "<game> gameplay" in the default browser.
    @objc func shopGameVideos(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue else { return }
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: title + " gameplay")]
        openShopLink(components.url?.absoluteString, hosts: youTubeHosts)
    }

    /// The cover and screenshots, one at a time, with arrows on the sides (dimmed at either end) and "2 / 8".
    func shopGallery(fill: Bool) -> NSView {
        let container = NSView()
        container.setAccessibilityIdentifier("shopGameGallery")
        let image = RemoteImageView()
        image.aspectFill = fill
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 12
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        image.setAccessibilityIdentifier("shopGameHero")
        image.setAccessibilityElement(false)
        func arrow(_ symbol: String, _ step: Int, _ label: String) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self,
                                  action: #selector(shopGalleryStep(_:)))
            button.tag = step
            button.isBordered = false
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            button.layer?.cornerRadius = 17
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(step < 0 ? "shopGalleryPrevious" : "shopGalleryNext")
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return button
        }
        let previous = arrow("chevron.left", -1, "Previous picture"), next = arrow("chevron.right", 1, "Next picture")
        let counter = NSTextField(labelWithString: "")
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        counter.textColor = .white
        counter.wantsLayer = true
        counter.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        counter.layer?.cornerRadius = 6
        counter.alignment = .center
        counter.setAccessibilityIdentifier("shopGalleryCounter")
        for view in [image, previous, next, counter] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: container.topAnchor), image.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor), image.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 353.0 / 616.0),
            previous.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            previous.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            next.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            counter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            counter.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        shopGalleryView = image
        shopGalleryPrevious = previous
        shopGalleryNext = next
        shopGalleryCounter = counter
        showGalleryPicture()
        return container
    }

    func showGalleryPicture() {
        let count = shopGalleryImages.count
        shopGalleryView?.image = nil
        shopGalleryView?.load(count > 0 ? safeDealURL(shopGalleryImages[shopGalleryIndex]) : nil,
                              enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        // The cover keeps its own framing; screenshots are shown whole.
        shopGalleryPrevious?.isHidden = count < 2
        shopGalleryNext?.isHidden = count < 2
        shopGalleryCounter?.isHidden = count < 2
        shopGalleryPrevious?.isEnabled = shopGalleryIndex > 0
        shopGalleryNext?.isEnabled = shopGalleryIndex < count - 1
        shopGalleryPrevious?.alphaValue = shopGalleryIndex > 0 ? 1 : 0.35
        shopGalleryNext?.alphaValue = shopGalleryIndex < count - 1 ? 1 : 0.35
        shopGalleryCounter?.stringValue = " \(shopGalleryIndex + 1) / \(count) "
        shopGalleryView?.setAccessibilityLabel(shopGalleryIndex == 0 ? "Cover" : "Screenshot \(shopGalleryIndex) of \(count - 1)")
    }

    @objc func shopGalleryStep(_ sender: NSButton) {
        let next = shopGalleryIndex + sender.tag
        guard shopGalleryImages.indices.contains(next) else { return }
        shopGalleryIndex = next
        showGalleryPicture()
    }

    /// A few facts about the game from Steam: what it is, who made it, how it plays on a couch, and whether it fits.
    func shopGameAboutCard(_ detail: ShopDetail) -> NSView? {
        guard let steam = detail.steam else {
            return detail.steamLoading ? card("About", subtitle: nil, views: [text("Loading details from Steam\u{2026}", size: 12, secondary: true)]) : nil
        }
        var views: [NSView] = []
        if let description = steam.description, !description.isEmpty { views.append(text(description, size: 13)) }
        var facts: [(String, String, NSColor?)] = []
        if let genres = steam.genres, !genres.isEmpty { facts.append(("Genre", genres.joined(separator: ", "), nil)) }
        if let developers = steam.developers, !developers.isEmpty { facts.append(("Developer", developers.joined(separator: ", "), nil)) }
        if let release = steam.release { facts.append(("Released", release, nil)) }
        if let controller = steam.controller {
            facts.append(("Controllers", controller == "full" ? "Full controller support" : "Partial controller support",
                          controller == "full" ? .systemGreen : nil))
        }
        if let couch = steam.couch, !couch.isEmpty {
            facts.append(("Couch play", couch.map { $0.replacingOccurrences(of: "Shared/", with: "") }.joined(separator: ", "), .systemGreen))
        }
        if let size = steam.storageBytes {
            let free = shopLibraryFreeSpace()
            var value = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            var color: NSColor?
            if let free {
                value += " \u{00B7} " + ByteCountFormatter.string(fromByteCount: free.bytes, countStyle: .file) + " free on " + free.name
                if free.bytes < size { color = .systemOrange; value += " \u{2014} not enough space" }
            }
            facts.append(("Size", value, color))
        }
        if !facts.isEmpty {
            let grid = NSGridView(views: facts.map { fact -> [NSView] in
                let name = NSTextField(labelWithString: fact.0)
                name.font = .systemFont(ofSize: 12)
                name.textColor = .secondaryLabelColor
                let value = NSTextField(wrappingLabelWithString: fact.1)
                value.font = .systemFont(ofSize: 12, weight: .medium)
                if let color = fact.2 { value.textColor = color }
                return [name, value]
            })
            grid.rowSpacing = 6
            grid.columnSpacing = 14
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 0).width = 96
            grid.setAccessibilityIdentifier("shopGameFacts")
            views.append(grid)
        }
        guard !views.isEmpty else { return nil }
        return card("About", subtitle: nil, views: views)
    }

    /// Free space where your games live: the active Couch Cube library drive, otherwise this Mac's disk.
    func shopLibraryFreeSpace() -> (bytes: Int64, name: String)? {
        if let active = storageStatus?.active,
           let drive = storageStatus?.locations.first(where: { $0.drive.id == active.id })?.drive {
            return (drive.free, drive.mode == "local" ? "this Mac" : drive.name)
        }
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { ($0, "this Mac") }
    }

    @objc func shopGameOpen(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        if value.hasPrefix("search:") {
            searchFor(String(value.dropFirst(7)))
            selectPage(13)
        } else if value.hasPrefix("gp:") {
            openShopLink(String(value.dropFirst(3)), hosts: gamerPowerHosts)
        } else {
            openShopLink(String(value.dropFirst(value.hasPrefix("app:") ? 4 : 3)), hosts: value.hasPrefix("app:") ? appStoreHosts : cheapSharkHosts)
        }
    }

    // MARK: Home storefront pieces

    /// A store card for Home: big art, the title, and the discount and price beneath, with the heart on the art.
    func shopCard(title: String, art: String?, price: ShopPrice?, priceText: String? = nil, was: String?, savings: Int?,
                  compat: GameCompatibility?, heart: NSButton, accessibility: String, open: @escaping () -> Void) -> NSView {
        let card = ClickableRowView()
        card.layer?.cornerRadius = 10
        card.onActivate = open
        card.setAccessibilityLabel(accessibility + (was.map { ", usually \($0)" } ?? "") + (compatibilityBadge(compat).map { ". " + $0.tip } ?? ""))
        card.setAccessibilityIdentifier("shopCard")
        card.toolTip = title
        let image = RemoteImageView()
        image.aspectFill = true
        image.wantsLayer = true
        image.layer?.cornerRadius = 8
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        image.setAccessibilityIdentifier("shopArtwork")
        image.setAccessibilityElement(false)
        image.load(safeDealURL(art), enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var bottom: [NSView] = []
        if let compat = compatibilityBadge(compat) {
            let badge = NSTextField(labelWithAttributedString: dealBadges([compat.badge]))
            badge.toolTip = compat.tip
            bottom.append(badge)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottom.append(spacer)
        // Cards are narrow: the pill says how much is off; the usual price is on the game page and in VoiceOver.
        if let savings, savings > 0 { bottom.append(discountPill(savings)) }
        if let shown = price ?? priceText.map({ ShopPrice(text: $0, original: $0, converted: false, value: nil) }) {
            bottom.append(priceLabel(shown, highlight: price == nil || shown.text == "Free"))
        }
        let priceRow = NSStackView(views: bottom)
        priceRow.orientation = .horizontal
        priceRow.alignment = .centerY
        priceRow.spacing = 6
        (bottom.last as? NSTextField)?.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [image, name, priceRow, heart] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        heart.wantsLayer = true
        heart.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        heart.layer?.cornerRadius = 11
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: card.topAnchor),
            image.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: TileFlowView.artRatio),
            heart.topAnchor.constraint(equalTo: image.topAnchor, constant: 6),
            heart.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -6),
            heart.heightAnchor.constraint(equalToConstant: 22),
            name.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -2),
            priceRow.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            priceRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2),
            priceRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2)
        ])
        return card
    }

    func shopCard(deal: StoreDeal) -> NSView {
        let heart = wishlistHeart(key: deal.gameId.map { "cs:" + $0 } ?? "title:" + deal.title.lowercased(), title: deal.title,
                                  payload: ["title": deal.title, "game_id": deal.gameId ?? "", "steam_app_id": deal.steamAppId ?? "", "thumb": deal.thumb ?? ""])
        let price = shopPrice(deal.salePrice, "USD")
        let was = deal.normalPrice.flatMap { $0 > deal.salePrice ? shopPrice($0, "USD").text : nil }
        return shopCard(title: deal.title, art: steamArtURL(deal.steamAppId) ?? deal.thumb, price: price, was: was, savings: deal.savings,
                        compat: compatibility(steamAppId: deal.steamAppId), heart: heart,
                        accessibility: "Open \(deal.title), \(price.spoken)" + (deal.savings > 0 ? ", \(deal.savings)% off" : "")) { [weak self] in
            self?.showShopGame(self?.shopDetail(deal: deal))
        }
    }

    /// A Shop game (every store's offer) as a card: the cheapest offer's price, struck-through usual price when on sale.
    func shopCard(game: ShopGame) -> NSView {
        let heart = wishlistHeart(key: "cs:" + game.id, title: game.title,
                                  payload: ["title": game.title, "game_id": game.id, "steam_app_id": game.steamAppId ?? "", "thumb": game.thumb ?? ""])
        let best = game.offers.min { $0.price < $1.price }
        let price = best.map { shopPrice($0.price, $0.currency) }
        let was = best.flatMap { offer in offer.normalPrice.flatMap { $0 > offer.price ? shopPrice($0, offer.currency).text : nil } }
        let savings = best?.savings ?? 0
        return shopCard(title: game.title, art: steamArtURL(game.steamAppId) ?? game.thumb, price: price, was: was,
                        savings: savings > 0 ? savings : nil, compat: compatibility(steamAppId: game.steamAppId), heart: heart,
                        accessibility: "Open \(game.title)" + (price.map { ", \($0.spoken)" } ?? "") + (savings > 0 ? ", \(savings)% off" : "")) { [weak self] in
            self?.showShopGame(self?.shopDetail(game: game))
        }
    }

    func shopCard(giveaway: Giveaway) -> NSView {
        let heart = wishlistHeart(key: "title:" + giveaway.title.lowercased(), title: giveaway.title,
                                  payload: ["title": giveaway.title, "thumb": giveaway.thumb ?? ""])
        return shopCard(title: giveaway.title, art: giveaway.thumb, price: nil, priceText: "Free",
                        was: giveawayWorth(giveaway)?.text ?? giveaway.worth, savings: nil, compat: nil, heart: heart,
                        accessibility: "Open \(giveaway.title), free") { [weak self] in
            self?.showShopGame(self?.shopDetail(giveaway: giveaway))
        }
    }

    func shopCard(wishlist item: WishlistItem) -> NSView {
        let heart = wishlistHeart(key: item.key, title: item.title,
                                  payload: ["title": item.title, "game_id": item.gameId ?? "", "steam_app_id": item.steamAppId ?? "",
                                            "app_store_id": item.appStoreId ?? "", "thumb": item.thumb ?? ""])
        let price = item.best.map { shopPrice($0.price, $0.currency) }
        let was = item.best.flatMap { best in best.normalPrice.flatMap { $0 > best.price ? shopPrice($0, best.currency).text : nil } }
        return shopCard(title: item.title, art: steamArtURL(item.steamAppId) ?? item.thumb, price: price, was: was,
                        savings: item.onSale ? item.best?.savings : nil,
                        compat: compatibility(steamAppId: item.steamAppId, appStore: item.appStoreId != nil), heart: heart,
                        accessibility: "Open \(item.title)" + (price.map { ", \($0.spoken)" } ?? "") + (item.saleText.map { ". \($0)" } ?? "")) { [weak self] in
            self?.showShopGame(self?.shopDetail(wishlist: item))
        }
    }

    /// The big banner at the top of Home: the best pick, with its art, discount and price.
    func shopHero(deal: StoreDeal) -> NSView {
        let view = ClickableRowView()
        view.layer?.cornerRadius = 14
        view.onActivate = { [weak self] in self?.showShopGame(self?.shopDetail(deal: deal)) }
        view.setAccessibilityIdentifier("shopHero")
        let price = shopPrice(deal.salePrice, "USD")
        view.setAccessibilityLabel("Open \(deal.title), \(price.spoken)" + (deal.savings > 0 ? ", \(deal.savings)% off" : ""))
        let image = RemoteImageView()
        image.aspectFill = true
        image.wantsLayer = true
        image.layer?.cornerRadius = 12
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        image.setAccessibilityIdentifier("shopArtwork")
        image.setAccessibilityElement(false)
        image.load(safeDealURL(steamArtURL(deal.steamAppId, "capsule_616x353.jpg") ?? deal.thumb),
                   enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        let kicker = NSTextField(labelWithString: "FEATURED DEAL")
        kicker.font = .systemFont(ofSize: 11, weight: .semibold)
        kicker.textColor = .secondaryLabelColor
        let name = NSTextField(wrappingLabelWithString: deal.title)
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.maximumNumberOfLines = 3
        var detailParts: [(symbol: String?, text: String, color: NSColor)] = []
        if let compat = compatibilityBadge(compatibility(steamAppId: deal.steamAppId)) { detailParts.append(compat.badge) }
        if let percent = deal.steamRatingPercent {
            detailParts.append(("hand.thumbsup.fill", "\(percent)%", Self.ratingColor(Double(percent), good: 80, fair: 50)))
        }
        let detail = NSTextField(labelWithAttributedString: dealBadges(detailParts))
        var priceViews: [NSView] = []
        if deal.savings > 0 { priceViews.append(discountPill(deal.savings, size: 14)) }
        let priceLabel = NSTextField(labelWithString: price.text)
        priceLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        priceViews.append(priceLabel)
        if let normal = deal.normalPrice, normal > deal.salePrice { priceViews.append(strikethrough(shopPrice(normal, "USD").text)) }
        let priceRow = NSStackView(views: priceViews)
        priceRow.orientation = .horizontal
        priceRow.alignment = .centerY
        priceRow.spacing = 8
        let store = NSTextField(labelWithString: deal.store.map { "at \($0)" } ?? "")
        store.font = .systemFont(ofSize: 12)
        store.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [kicker, name, detail, priceRow, store])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8
        texts.setCustomSpacing(4, after: kicker)
        let heart = wishlistHeart(key: deal.gameId.map { "cs:" + $0 } ?? "title:" + deal.title.lowercased(), title: deal.title,
                                  payload: ["title": deal.title, "game_id": deal.gameId ?? "", "steam_app_id": deal.steamAppId ?? "", "thumb": deal.thumb ?? ""])
        heart.wantsLayer = true
        heart.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        heart.layer?.cornerRadius = 11
        for subview in [image, texts, heart] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heart.topAnchor.constraint(equalTo: image.topAnchor, constant: 8),
            heart.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -8),
            heart.heightAnchor.constraint(equalToConstant: 22)
        ])
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            image.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            image.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.56),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 353.0 / 616.0),
            texts.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 20),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            texts.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        return view
    }

    /// A Home shelf: a large heading with "See all" and a grid of cards that fills the page width.
    func shopShelf(_ title: String, cards: [NSView], more tab: Int?) -> [NSView] {
        guard !cards.isEmpty else { return [] }
        let more = NSButton(title: "See All", target: self, action: #selector(shopSeeAll(_:)))
        more.tag = tab ?? 0
        more.isHidden = tab == nil
        more.bezelStyle = .inline
        more.isBordered = false
        more.contentTintColor = .controlAccentColor
        more.setAccessibilityIdentifier("shopSeeAll")
        more.setAccessibilityLabel("See all: \(title)")
        let grid = TileFlowView()
        grid.minimumTileWidth = 190
        grid.spacing = 18
        grid.textHeight = 52
        grid.setTiles(cards)
        grid.setAccessibilityIdentifier("shopShelf")
        return [sectionHeader(title, trailing: [more], size: Self.shopHeadingSize), grid]
    }
}
