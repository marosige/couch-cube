import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func configureShopPane(_ pane: NSStackView, _ views: [NSView], full: [NSView]) {
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 12
        pane.setViews(views, in: .leading)
        for view in full { view.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true }
    }

    func shopList(_ list: NSStackView, id: String) {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.setAccessibilityIdentifier(id)
    }

    func shopStatusLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func cubeShopPage() -> NSView {
        let deals = dealsPage()
        // Cube Shop always opens on Home; the other tabs keep their own state and scroll position once visited.
        shopTab.selectedSegment = 0
        shopTab.target = self
        shopTab.action = #selector(shopTabChanged)
        shopNav.selectedSegment = 0
        shopNav.target = self
        shopNav.action = #selector(shopNavChanged)
        shopNav.setAccessibilityLabel("Cube Shop section")
        shopNav.setAccessibilityIdentifier("shopNav")
        shopScope.target = self
        shopScope.action = #selector(shopScopeChanged)
        shopScope.controlSize = .small
        shopScope.isBordered = false
        shopScope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shopScope.setContentHuggingPriority(.required, for: .horizontal)
        shopScope.setAccessibilityIdentifier("shopScope")
        shopScope.selectedSegment = shopScopeMine ? 0 : 1
        shopScope.setAccessibilityLabel("Show deals for")
        shopScope.setToolTip("Only the stores whose app or launcher is installed on this Mac", forSegment: 0)
        shopScope.setToolTip("Every PC store", forSegment: 1)
        shopStatusLabel(shopScopeHint)
        shopScopeHint.setAccessibilityIdentifier("shopScopeHint")
        shopScopeBar.orientation = .horizontal
        shopScopeBar.alignment = .centerY
        shopScopeBar.spacing = 10
        shopMacOnlyToggle.controlSize = .small
        shopMacOnlyToggle.isBordered = false
        shopMacOnlyToggle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shopMacOnlyToggle.setContentHuggingPriority(.required, for: .horizontal)
        shopMacOnlyToggle.selectedSegment = shopMacOnly ? 1 : 0
        shopMacOnlyToggle.setAccessibilityLabel("Show games for")
        shopMacOnlyToggle.target = self
        shopMacOnlyToggle.action = #selector(shopMacOnlyChanged)
        shopMacOnlyToggle.toolTip = "Hide games without a macOS version (no Windows compatibility apps needed)"
        shopMacOnlyToggle.setAccessibilityIdentifier("shopMacOnly")
        shopScopeBar.setViews([shopScope, shopMacOnlyToggle], in: .leading)
        shopStatusLabel(shopCurrencyNote)
        shopCurrencyNote.setAccessibilityIdentifier("shopCurrencyNote")
        // Store header: the search field with the store scope and refresh beside it, then the sections as big
        // centred tabs (← → steps through them; a controller's shoulder buttons will too).
        shopSearchField.setAccessibilityIdentifier("shopSearchField")
        shopSearchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = row([shopSearchField, shopScopeBar, dealsProgress, dealsRefreshButton])
        top.alignment = .centerY
        top.spacing = 8
        let nav = NSView()
        shopNav.translatesAutoresizingMaskIntoConstraints = false
        nav.addSubview(shopNav)
        NSLayoutConstraint.activate([
            shopNav.centerXAnchor.constraint(equalTo: nav.centerXAnchor),
            shopNav.leadingAnchor.constraint(greaterThanOrEqualTo: nav.leadingAnchor),
            shopNav.topAnchor.constraint(equalTo: nav.topAnchor), shopNav.bottomAnchor.constraint(equalTo: nav.bottomAnchor)
        ])
        let header = column([top, nav])
        header.spacing = 14
        for view in [top, nav] { view.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        shopScopeHint.isHidden = true
        shopStatusLabel(homeStatus)
        shopList(homeList, id: "shopHomeList")
        shopSearchField.controlSize = .large
        shopSearchField.font = .systemFont(ofSize: 15)
        configureShopPane(homePane, [homeStatus, homeList], full: [homeStatus, homeList])
        shopSearchField.placeholderString = "Search games in every store"
        shopSearchField.sendsWholeSearchString = true
        shopSearchField.target = self
        shopSearchField.action = #selector(shopSearchSubmitted)
        shopSearchField.setAccessibilityLabel("Search every store")
        NotificationCenter.default.addObserver(self, selector: #selector(shopSearchTyped(_:)), name: NSControl.textDidChangeNotification, object: shopSearchField)
        shopStatusLabel(searchStatus)
        shopList(searchList, id: "shopSearchList")
        let searchHeader = sortHeader(searchStatus, searchSortPopup, [.relevance, .name, .priceAsc, .priceDesc, .discount],
                                      key: searchSortKey, label: "Sort search results")
        configureShopPane(searchPane, [searchHeader, searchList], full: [searchHeader, searchList])
        shopStatusLabel(wishlistStatus)
        wishlistStatus.setAccessibilityIdentifier("wishlistStatus")
        shopList(wishlistList, id: "wishlistList")
        let wishlistHeader = sortHeader(wishlistStatus, wishlistSortPopup, [.relevance, .added, .name, .priceAsc, .priceDesc, .discount],
                                        key: wishlistSortKey, label: "Sort wishlist")
        wishlistSortPopup.item(at: 0)?.title = "On Sale First"
        configureShopPane(wishlistPane, [wishlistHeader, wishlistList], full: [wishlistHeader, wishlistList])
        shopList(trendingList, id: "trendingList")
        configureShopPane(trendingPane, [trendingList], full: [trendingList])
        let attribution = NSTextField(labelWithAttributedString: dealsAttribution())
        attribution.isSelectable = true
        attribution.allowsEditingTextAttributes = true
        attribution.lineBreakMode = .byWordWrapping
        attribution.maximumNumberOfLines = 0
        attribution.setAccessibilityIdentifier("dealsAttribution")
        // Store-style page: one header row, the content, and the small print (scope, rates, sources) at the bottom.
        let page = column([header, dealsReminderBar, homePane, trendingPane, deals, searchPane, wishlistPane, shopScopeHint, shopCurrencyNote, attribution])
        page.spacing = 12
        page.setCustomSpacing(20, after: header)
        for view in [header, shopScopeHint, shopCurrencyNote, homePane, trendingPane, deals, searchPane, wishlistPane, attribution] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        shopPageView = page
        updateScopeHint()
        updateCurrencyNotes()
        showShopTab()
        return page
    }

    func showShopTab() {
        let tab = shopTab.selectedSegment
        homePane.isHidden = tab != 0
        dealsPane.isHidden = tab != 1 && tab != 2
        searchPane.isHidden = tab != 3
        wishlistPane.isHidden = tab != 4
        trendingPane.isHidden = tab != 5
        shopScopeBar.isHidden = tab > 2 && tab != 5
        shopNav.selectedSegment = Self.shopNavTabs.firstIndex(of: tab) ?? -1
        // The field shows a query only while its results are on screen.
        if tab != 3 { shopSearchField.stringValue = "" }
    }

    @objc func shopNavChanged() {
        guard Self.shopNavTabs.indices.contains(shopNav.selectedSegment) else { return }
        selectShopTab(Self.shopNavTabs[shopNav.selectedSegment])
    }

    func openCubeShop() {
        dealsOpened = true
        shopTab.selectedSegment = 0
        loadRates(refresh: false)
        if wishlistCheckedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { syncSteamWishlist() }
        shopTabChanged()
    }

    func selectShopTab(_ tab: Int) {
        if tab != 3 { shopReturnTab = tab }
        shopTab.selectedSegment = tab
        shopTabChanged()
    }

    @objc func shopTabChanged() {
        let tab = shopTab.selectedSegment
        if tab != 3 { shopReturnTab = tab }
        let scroll = shopPageView?.enclosingScrollView
        if let shown = shopShownTab, shown != tab, let scroll { shopScrollOffsets[shown] = scroll.contentView.bounds.origin.y }
        defer {
            // Each tab keeps its own scroll position.
            if shopShownTab != tab, let scroll, let page = shopPageView {
                page.layoutSubtreeIfNeeded()
                let limit = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(shopScrollOffsets[tab] ?? 0, limit)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            shopShownTab = tab
        }
        showShopTab()
        dealsReminderBar.isHidden = true
        guard dealsOpened else { return }
        switch tab {
        case 0: loadHome(refresh: false)
        case 1, 2:
            dealsMode.selectedSegment = tab - 1
            dealsModeChanged()
        case 3: renderSearch()
        case 5:
            renderTrending()
            loadHome(refresh: false)
        default: renderWishlist()
        }
    }

    @objc func refreshShop() {
        if shopCurrency != nil { loadRates(refresh: true) }
        switch shopTab.selectedSegment {
        case 0: loadHome(refresh: true)
        case 1, 2: loadDeals(page: 0, refresh: true)
        case 3: runSearch(refresh: true)
        case 5: loadHome(refresh: true)
        default: checkWishlist(refresh: true)
        }
    }

    func setShopLoading(_ name: String, _ on: Bool) {
        if on { shopLoading.insert(name) } else { shopLoading.remove(name) }
        if shopLoading.isEmpty { dealsProgress.stopAnimation(nil) } else { dealsProgress.startAnimation(nil) }
    }

    /// Re-renders every Shop list after a currency, rate or wishlist change (rows are cheap; data stays as loaded).
    func rerenderShop() {
        guard dealsOpened else { return }
        renderDeals()
        renderHome()
        renderTrending()
        renderSearch()
        renderWishlist()
        if shopDetailKey != nil { renderShopGame() }
    }

    /// Trending: Steam's new & trending games and top sellers as list rows, on sale or not (prices from every store).
    func renderTrending() {
        trendingList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let home = shopHome else {
            if homeLoadingKey != nil { shopSkeletonRows(6).forEach { addShopRow($0, to: trendingList) } }
            return
        }
        var seen = Set<String>()
        for (title, games) in [("New & Trending", home.trending ?? []), ("Top Sellers", home.topSellers ?? [])] {
            let shown = games.filter { shopShows(steamAppId: $0.steamAppId) && seen.insert($0.id).inserted }
            guard !shown.isEmpty else { continue }
            let heading = sectionHeader(title, size: Self.shopHeadingSize)
            heading.setAccessibilityIdentifier("shopSection")
            addShopRow(heading, to: trendingList, separated: false)
            for (index, game) in shown.enumerated() { addShopRow(searchGameRow(game), to: trendingList, separated: index > 0) }
        }
    }

    // MARK: My Stores / All Stores

    @objc func shopMacOnlyChanged() {
        UserDefaults.standard.set(shopMacOnlyToggle.selectedSegment == 1, forKey: "shopMacOnly")
        rerenderShop()
    }

    /// With "Mac games only" on, a game shows only once Steam confirms a macOS version (Mac App Store apps always do).
    func shopShows(steamAppId: String?, appStore: Bool = false) -> Bool {
        !shopMacOnly || compatibility(steamAppId: steamAppId, appStore: appStore) == .mac
    }

    @objc func shopScopeChanged() {
        UserDefaults.standard.set(shopScope.selectedSegment == 0 ? "mine" : "all", forKey: shopScopeKey)
        updateScopeHint()
        switch shopTab.selectedSegment {
        case 0: loadHome(refresh: false)
        case 1, 2: dealsFiltersChanged()
        default: break
        }
    }

    func updateScopeHint() {
        // The scope control explains itself in its tooltip; the small print only speaks up when nothing is installed.
        defer {
            shopScope.toolTip = shopScopeHint.stringValue
            shopScopeHint.isHidden = !(myStores?.isEmpty ?? false)
        }
        if let stores = myStores, stores.isEmpty {
            // Nothing installed: show every store, and say why My Stores is unavailable.
            shopScope.setEnabled(false, forSegment: 0)
            shopScope.selectedSegment = 1
            shopScopeHint.stringValue = "No store apps found on this Mac, so every PC store is shown."
            return
        }
        shopScope.setEnabled(true, forSegment: 0)
        shopScope.selectedSegment = shopScopeMine ? 0 : 1
        if !shopScopeMine {
            shopScopeHint.stringValue = "Showing every PC store."
        } else if let stores = myStores {
            shopScopeHint.stringValue = "Showing " + ListFormatter.localizedString(byJoining: stores.map(\.name)) + ", installed on this Mac."
        } else {
            shopScopeHint.stringValue = "Showing the stores installed on this Mac."
        }
    }

    // MARK: Currency

    func shopPrice(_ amount: Double, _ currency: String) -> ShopPrice {
        let value = ShopMoney.decimal(amount)
        let original = currency == "USD" && shopCurrency == nil ? dealPrice(amount) : ShopMoney.format(value, currency)
        if amount == 0 { return ShopPrice(text: "Free", original: "Free", converted: false, value: 0) }
        guard let target = shopCurrency else { return ShopPrice(text: original, original: original, converted: false, value: value) }
        if target == currency { return ShopPrice(text: ShopMoney.format(value, currency), original: original, converted: false, value: value) }
        guard let converted = ShopMoney.convert(value, from: currency, to: target, rates: exchangeRates, feePercent: shopFeePercent) else {
            return ShopPrice(text: original, original: original, converted: false, value: nil)
        }
        return ShopPrice(text: "\u{2248} " + ShopMoney.format(converted, target), original: ShopMoney.plain(value, currency),
                         converted: true, value: converted)
    }

    func priceLabel(_ price: ShopPrice, highlight: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: price.text)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = highlight ? .systemGreen : .labelColor
        label.alignment = .right
        if price.converted {
            label.toolTip = "\(price.text) (\(price.original))"
            label.setAccessibilityLabel(price.spoken)
        }
        return label
    }

    func loadRates(refresh: Bool) {
        guard shopCurrency != nil, !ratesLoading else { updateCurrencyNotes(); return }
        if !refresh, exchangeRates != nil, let loaded = ratesLoadedAt, Date().timeIntervalSince(loaded) < 3600 { updateCurrencyNotes(); return }
        ratesLoading = true
        updateCurrencyNotes()
        shopRead(["rates"] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, _ in
            guard let self else { return }
            self.ratesLoading = false
            if code == 0, let rates = decodeDeals(ExchangeRates.self, data) {
                let changed = rates != self.exchangeRates
                self.exchangeRates = rates
                self.ratesFailed = false
                self.ratesLoadedAt = Date()
                self.updateCurrencyNotes()
                if changed { self.rerenderShop() }
            } else {
                self.ratesFailed = true
                self.updateCurrencyNotes()
            }
        }
    }

    func updateCurrencyNotes() {
        let source = "ECB reference rate via Frankfurter"
        let caveat = "Revolut/bank rates may differ slightly."
        guard let target = shopCurrency else {
            shopCurrencyNote.isHidden = true
            shopRatesNote.stringValue = ""
            return
        }
        shopCurrencyNote.isHidden = false
        let fee = shopFeePercent > 0 ? " incl. \(shopFeePercent)% card/FX fee" : ""
        if let rates = exchangeRates {
            let date = rates.stale == true ? "rates from \(rates.date)" : "updated \(rates.date)"
            shopRatesNote.stringValue = "\(source), \(date); \(caveat) Prices are converted for display only."
            shopCurrencyNote.stringValue = "Prices \u{2248} \(target)\(fee) \u{00B7} \(source), \(date)"
        } else if ratesLoading {
            shopRatesNote.stringValue = "\(source), loading\u{2026} \(caveat)"
            shopCurrencyNote.stringValue = "Loading exchange rates\u{2026}"
        } else if ratesFailed {
            shopRatesNote.stringValue = "\(source) couldn't be reached and no saved rates exist yet, so prices stay in their original currency. \(caveat)"
            shopCurrencyNote.stringValue = "Exchange rates aren't available, so prices are shown in their original currency."
        } else {
            shopRatesNote.stringValue = "\(source), loaded when you open Cube Shop. \(caveat)"
            shopCurrencyNote.stringValue = ""
        }
    }

    func shopSettingsCard() -> NSView {
        shopCurrencyPopup.removeAllItems()
        shopCurrencyPopup.addItem(withTitle: "Original prices")
        shopCurrencyPopup.lastItem?.representedObject = "original"
        shopCurrencyPopup.menu?.addItem(.separator())
        for code in ShopMoney.currencies {
            let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
            shopCurrencyPopup.addItem(withTitle: "\(code) \u{2014} \(name)")
            shopCurrencyPopup.lastItem?.representedObject = code
            if code == "GBP" { shopCurrencyPopup.menu?.addItem(.separator()) }
        }
        let selected = shopCurrency ?? "original"
        if let item = shopCurrencyPopup.itemArray.first(where: { $0.representedObject as? String == selected }) { shopCurrencyPopup.select(item) }
        shopCurrencyPopup.target = self
        shopCurrencyPopup.action = #selector(shopCurrencyChanged)
        shopCurrencyPopup.controlSize = .small
        shopCurrencyPopup.setAccessibilityLabel("Shop currency")
        shopFeeField.stringValue = shopFeePercent == 0 ? "0" : "\(shopFeePercent)"
        shopFeeField.alignment = .right
        shopFeeField.controlSize = .small
        shopFeeField.font = .systemFont(ofSize: 11)
        shopFeeField.target = self
        shopFeeField.action = #selector(shopFeeChanged)
        shopFeeField.setAccessibilityLabel("Card or FX fee percent")
        shopFeeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        shopStatusLabel(shopRatesNote)
        shopRatesNote.setAccessibilityIdentifier("shopRatesNote")
        updateCurrencyNotes()
        return card("Cube Shop", subtitle: nil, views: [
            settingsRow("Shop currency", subtitle: "Prices in your currency, or each store's own.", symbol: "dollarsign.circle",
                        color: .systemGreen, trailing: shopCurrencyPopup, detail: nil),
            separator(),
            settingsRow("Card fee", subtitle: "Added to converted prices.", symbol: "percent",
                        color: .systemOrange, trailing: row([shopFeeField, text("%", size: 12)]), detail: nil),
            separator(),
            steamLinkRow(),
            shopRatesNote
        ])
    }

    @objc func shopCurrencyChanged() {
        UserDefaults.standard.set(shopCurrencyPopup.selectedItem?.representedObject as? String ?? "original", forKey: shopCurrencyKey)
        updateCurrencyNotes()
        loadRates(refresh: false)
        rerenderShop()
    }

    @objc func shopFeeChanged() {
        let text = shopFeeField.stringValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let value = Double(text.isEmpty ? "0" : text), value >= 0, value <= 20 {
            UserDefaults.standard.set(value, forKey: shopFeeKey)
        }
        shopFeeField.stringValue = shopFeePercent == 0 ? "0" : "\(shopFeePercent)"
        updateCurrencyNotes()
        rerenderShop()
    }

    // MARK: Home

    func loadHome(refresh: Bool) {
        let scope = shopScopeMine ? "mine" : "all"
        let key = scope + (refresh ? "\u{1F}refresh" : "")
        if homeLoadingKey == key { return }
        if !refresh, homeLoadedScope == scope, shopHome != nil { renderHome(); return }
        homeLoadingKey = key
        setShopLoading("home", true)
        if shopHome == nil { homeStatus.stringValue = "Loading\u{2026}" }
        shopRead(["shop-home", "--scope", scope] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self, self.homeLoadingKey == key else { return }
            self.homeLoadingKey = nil
            self.setShopLoading("home", false)
            guard code == 0, let reply = decodeDeals(ShopHomeReply.self, data) else {
                self.homeError = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
                self.renderHome()
                self.renderTrending()
                return
            }
            self.shopHome = reply
            self.homeLoadedScope = scope
            self.homeError = reply.errors.first.map(self.dealsErrorText)
            self.myStores = reply.myStores
            self.updateScopeHint()
            if self.wishlist == nil, let wishlist = reply.wishlist { self.wishlist = wishlist }
            self.renderHome()
            self.renderTrending()
        }
    }

    func sectionHeader(_ title: String, trailing: [NSView] = [], size: CGFloat = 13) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: size, weight: size > 13 ? .bold : .semibold)
        label.setAccessibilityIdentifier("shopSectionTitle")
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = row([label, NSView()] + trailing)
        line.edgeInsets = NSEdgeInsets(top: 14, left: 6, bottom: 4, right: 6)
        line.setAccessibilityIdentifier("shopSection")
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.group)
        line.setAccessibilityLabel(title)
        return line
    }

    /// Home is a storefront: one featured banner, then shelves of cards (wishlist games on sale, top deals,
    /// price drops, free games). Each card opens its game page; "See All" opens the full list.
    func renderHome() {
        schedulePlatformLookup()
        homeList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let home = shopHome else {
            homeStatus.stringValue = homeError ?? ""
            if homeError == nil && homeLoadingKey != nil {
                for view in shopHomeSkeleton() {
                    homeList.addArrangedSubview(view)
                    view.widthAnchor.constraint(equalTo: homeList.widthAnchor).isActive = true
                }
            }
            return
        }
        func add(_ view: NSView) {
            homeList.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: homeList.widthAnchor).isActive = true
        }
        let hits = (wishlist?.items ?? []).filter {
            ($0.onSale || targetReached($0) == true) && shopShows(steamAppId: $0.steamAppId, appStore: $0.appStoreId != nil)
        }
        let shown = home.featured.filter { shopShows(steamAppId: $0.steamAppId) }
        let hero = shown.first
        if let hero { add(shopHero(deal: hero)) }
        let featured = shown.dropFirst(hero == nil ? 0 : 1)
        let drops = home.drops.filter { shopShows(steamAppId: $0.steamAppId) }
        let topSellers = (home.topSellers ?? []).filter { shopShows(steamAppId: $0.steamAppId) }
        let trending = (home.trending ?? []).filter { shopShows(steamAppId: $0.steamAppId) }
        let couch = (home.couch ?? []).filter { shopShows(steamAppId: $0.steamAppId) }
        for (index, view) in [shopShelf("On Your Wishlist", cards: hits.prefix(4).map { shopCard(wishlist: $0) }, more: 4),
                              shopShelf("Top Deals", cards: featured.prefix(8).map { shopCard(deal: $0) }, more: 1),
                              shopShelf("New & Trending", cards: trending.prefix(8).map { shopCard(game: $0) }, more: nil),
                              shopShelf("Top Sellers", cards: topSellers.prefix(8).map { shopCard(game: $0) }, more: nil),
                              shopShelf("Couch Games", cards: couch.prefix(8).map { shopCard(game: $0) }, more: nil),
                              shopShelf("Price Drops", cards: drops.prefix(4).map { shopCard(deal: $0) }, more: 1),
                              shopShelf("Free to Keep", cards: shopMacOnly ? [] : home.free.prefix(4).map { shopCard(giveaway: $0) }, more: 2)]
            .joined().enumerated() {
            if index % 2 == 0, let previous = homeList.arrangedSubviews.last { homeList.setCustomSpacing(Self.shopSectionGap, after: previous) }
            add(view)
        }
        if homeList.arrangedSubviews.isEmpty {
            homeStatus.stringValue = homeError ?? "Nothing to recommend right now. Try All Stores or Refresh."
        } else {
            homeStatus.stringValue = homeError.map { "\($0) Some sections may be missing." } ?? ""
            homeStatus.toolTip = "Picked on this Mac from discounts, ratings, recency and your wishlist. Nothing about you is sent anywhere."
        }
    }

    // MARK: Search

    @objc func shopSeeAll(_ sender: NSButton) { selectShopTab(sender.tag) }

    /// The one search field sits above every section; searching shows the results in place of the section, and clearing it goes back.
    @objc func shopSearchTyped(_ note: Notification? = nil) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.shopSearchSubmitted() }
    }

    @objc func shopSearchSubmitted() {
        searchTimer?.invalidate()
        searchTimer = nil
        let searching = shopSearchQuery.count >= 2
        if searching, shopTab.selectedSegment != 3 { selectShopTab(3) }
        runSearch(refresh: false)
        if !searching, shopTab.selectedSegment == 3 { selectShopTab(shopReturnTab) }
    }

    func runSearch(refresh: Bool) {
        let query = shopSearchQuery
        guard query.count >= 2 else {
            guard searchReply != nil || searchLoadingQuery != nil || searchError != nil else { return }
            searchReply = nil
            searchLoadedQuery = nil
            searchLoadingQuery = nil
            searchError = nil
            setShopLoading("search", false)
            renderSearch()
            return
        }
        // Identical searches are combined; results are cached by the backend.
        if searchLoadingQuery == query { return }
        // Already showing it. Don't rebuild: ending editing re-sends the field's action, and rebuilding the rows
        // mid-click would swallow a wishlist heart click.
        if !refresh, searchLoadedQuery == query { return }
        searchLoadingQuery = query
        setShopLoading("search", true)
        searchStatus.stringValue = "Searching every store for \u{201C}\(query)\u{201D}\u{2026}"
        shopRead(["shop-search", "--query", query, "--country", shopCountry] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self, self.searchLoadingQuery == query else { return }
            self.searchLoadingQuery = nil
            self.setShopLoading("search", false)
            guard code == 0, let reply = decodeDeals(ShopSearchReply.self, data) else {
                self.searchError = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
                self.renderSearch()
                return
            }
            self.searchReply = reply
            self.searchLoadedQuery = query
            self.searchError = reply.errors.first.map(self.dealsErrorText)
            self.renderSearch()
        }
    }

    /// Offers in price order. With a Shop currency every store is compared by its converted price; with original
    /// prices only same-currency offers are compared and other currencies follow, grouped and labelled.
    func sortedShopOffers(_ offers: [ShopOffer]) -> [(offer: ShopOffer, price: ShopPrice, cheapest: Bool)] {
        let priced = offers.map { (offer: $0, price: shopPrice($0.price, $0.currency)) }
        let converting = shopCurrency != nil && exchangeRates != nil
        func group(_ item: (offer: ShopOffer, price: ShopPrice)) -> String {
            converting ? (item.price.value == nil ? "~" + item.offer.currency : "") : (item.offer.currency == "USD" ? "" : item.offer.currency)
        }
        let ordered = priced.sorted { a, b in
            let (ga, gb) = (group(a), group(b))
            if ga != gb { return ga < gb }
            let (va, vb) = (a.price.value ?? ShopMoney.decimal(a.offer.price), b.price.value ?? ShopMoney.decimal(b.offer.price))
            return va != vb ? va < vb : a.offer.store.localizedCaseInsensitiveCompare(b.offer.store) == .orderedAscending
        }
        guard let first = ordered.first else { return [] }
        let lowest = first.price.value ?? ShopMoney.decimal(first.offer.price)
        return ordered.map { item in
            (item.offer, item.price, group(item) == group(first) && (item.price.value ?? ShopMoney.decimal(item.offer.price)) == lowest)
        }
    }

    func symbolArtwork(_ symbol: String, size: CGFloat = 24, width: CGFloat? = nil) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        image.setAccessibilityIdentifier("shopArtwork")
        image.widthAnchor.constraint(equalToConstant: width ?? size).isActive = true
        image.heightAnchor.constraint(equalToConstant: size).isActive = true
        image.setAccessibilityElement(false)
        return image
    }

    /// One store's price on a game page: logo and name, Lowest on the cheapest, the discount and the price.
    /// Clicking it opens that store in the browser (CheapShark's redirect, or apps.apple.com).
    func offerRow(_ game: String, _ offer: ShopOffer, _ price: ShopPrice, cheapest: Bool, mixed: Bool = false, steamAppId: String? = nil) -> NSView {
        let appStore = offer.storeId == nil
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        if let savings = offer.savings, savings > 0 { tips.append("\(savings)% off") }
        let was = offer.normalPrice.flatMap { $0 > offer.price ? shopPrice($0, offer.currency) : nil }
        if let was { tips.append("Usually \(was.spoken)") }
        tips.append("Price in \(offer.currency)")
        if price.converted { tips.append("Price: \(price.spoken)") }
        let compat = compatibilityBadge(appStore ? .mac : offer.storeId == "1" ? compatibility(steamAppId: steamAppId) : nil)
        if let compat { badges.append(compat.badge); tips.append(compat.tip) }
        let lowest = cheapest ? dealBadge(lowestMarker(offer, mixed: mixed), color: .systemGreen) : nil
        lowest?.setAccessibilityIdentifier("shopLowest")
        let open = NSImageView(image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil) ?? NSImage())
        open.contentTintColor = .tertiaryLabelColor
        let view = dealRow(artwork: storeIconView(offer.store, size: 28), title: offer.store, detail: dealBadges(badges),
                           detailTip: tips.joined(separator: "\n"),
                           trailing: [priceCluster(price: price, was: was?.text, savings: offer.savings, highlight: cheapest), open],
                           accessibility: "Open \(game) at \(offer.store), \(price.spoken)" + (cheapest ? ", cheapest" : "") + (compat.map { ". " + $0.tip } ?? ""),
                           compact: true, actions: lowest.map { [$0] } ?? []) { [weak self] in
            self?.openShopLink(offer.url, hosts: appStore ? appStoreHosts : cheapSharkHosts)
        }
        view.setAccessibilityIdentifier("shopOffer")
        return view
    }

    func lowestMarker(_ offer: ShopOffer, mixed: Bool) -> String {
        mixed ? "Lowest\u{00A0}\(offer.currency)" : "Lowest"
    }

    /// One search result per game, in the shared row style: its best price, where, and how many stores sell it.
    /// The full store comparison is on the game page.
    func searchGameRow(_ game: ShopGame) -> NSView {
        let offers = sortedShopOffers(game.offers + (game.appStoreOffer.map { [$0.offer] } ?? []))
        let heart = wishlistHeart(key: "cs:" + game.id, title: game.title,
                                  payload: ["title": game.title, "game_id": game.id, "steam_app_id": game.steamAppId ?? "", "thumb": game.thumb ?? ""])
        let best = offers.first { $0.cheapest } ?? offers.first
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        let compat = compatibilityBadge(compatibility(steamAppId: game.steamAppId, appStore: game.appStoreOffer != nil))
        if let compat { badges.append(compat.badge) }
        if let owned = ownedBadge(game.steamAppId) { badges.append(owned) }
        if offers.count > 1 { badges.append((nil, "\(offers.count) stores", .secondaryLabelColor)) }
        let was = best.flatMap { item in item.offer.normalPrice.flatMap { $0 > item.offer.price ? shopPrice($0, item.offer.currency).text : nil } }
        let normal = game.offers.compactMap(\.normalPrice).max()
        let spoken = best.map { ", lowest price \($0.price.spoken) at \($0.offer.store)" + (($0.offer.savings ?? 0) > 0 ? ", \($0.offer.savings!)% off" : "") } ?? ""
        let right = offerColumns(price: best?.price, was: was, savings: best?.offer.savings,
                                 insight: best?.offer.storeId != nil ? game.insight : nil, normal: normal)
        let view = shopItemRow(heart: heart, artwork: dealArtwork(steamArtURL(game.steamAppId) ?? game.thumb), title: game.title,
                               tags: shopTags(title: game.title), store: best?.offer.store, platform: dealBadges(badges),
                               tip: ([best.map { "Lowest price: \($0.price.spoken) at \($0.offer.store)" }, compat?.tip].compactMap { $0 }).joined(separator: "\n"),
                               accessibility: "Open \(game.title)\(spoken)" + (compat.map { ". " + $0.tip } ?? ""), right: right) { [weak self] in
            self?.showShopGame(self?.shopDetail(game: game))
        }
        view.setAccessibilityIdentifier("shopGameRow")
        return view
    }

    func appStoreRow(_ app: AppStoreGame) -> NSView {
        let price = shopPrice(app.price, app.currency)
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        let compat = compatibilityBadge(.mac)!
        badges.append(compat.badge)
        let heart = wishlistHeart(key: "app:" + app.id, title: app.title, payload: ["title": app.title, "app_store_id": app.id, "thumb": app.thumb ?? ""])
        let view = dealRow(artwork: dealArtwork(app.thumb, fill: false), title: app.title, detail: dealBadges(badges),
                           detailTip: (app.seller.map { "By \($0)\n" } ?? "") + (price.converted ? "Price: \(price.spoken)" : "Mac App Store price in \(app.currency)"),
                           trailing: [priceCluster(price: price, store: "Mac App Store")],
                           accessibility: "Open \(app.title), Mac App Store, \(price.spoken). \(compat.tip)",
                           actions: [heart]) { [weak self] in
            self?.showShopGame(self?.shopDetail(app: app))
        }
        view.setAccessibilityIdentifier("shopAppStoreRow")
        return view
    }

    /// Home's search section: the best few results in the shared row style, with a link to the full comparison.
    /// A status line with a compact "Sort by" popup at its trailing edge; the choice is remembered per list.
    func sortHeader(_ status: NSTextField, _ popup: NSPopUpButton, _ options: [ShopSort], key: String, label: String) -> NSStackView {
        popup.removeAllItems()
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.rawValue
        }
        let saved = UserDefaults.standard.string(forKey: key)
        popup.selectItem(at: options.firstIndex { $0.rawValue == saved } ?? 0)
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(shopSortChanged(_:))
        popup.setAccessibilityLabel(label)
        popup.setAccessibilityIdentifier("shopSortPopup")
        popup.toolTip = "Sort by"
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [status, popup])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        return header
    }

    func selectedSort(_ popup: NSPopUpButton) -> ShopSort {
        (popup.selectedItem?.representedObject as? String).flatMap(ShopSort.init(rawValue:)) ?? .relevance
    }

    @objc func shopSortChanged(_ sender: NSPopUpButton) {
        let sort = selectedSort(sender).rawValue
        if sender === searchSortPopup { UserDefaults.standard.set(sort, forKey: searchSortKey); renderSearch() }
        if sender === wishlistSortPopup { UserDefaults.standard.set(sort, forKey: wishlistSortKey); renderWishlist() }
    }

    /// Converts into the Shop currency for sorting (unrounded); nil with Original prices, so prices group by currency.
    func sortConvert(_ price: Double, _ currency: String) -> Double? {
        guard let target = shopCurrency else { return nil }
        if currency == target { return price }
        return ShopMoney.convert(ShopMoney.decimal(price), from: currency, to: target, rates: exchangeRates,
                                 feePercent: shopFeePercent, round: false).map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    /// A search game sorts by its cheapest store (converted when a Shop currency is set) and its biggest discount.
    func searchSortFields(_ game: ShopGame) -> ShopSortFields {
        let offers = game.offers + (game.appStoreOffer.map { [$0.offer] } ?? [])
        let cheapest = offers.min { a, b in
            let x = sortConvert(a.price, a.currency), y = sortConvert(b.price, b.currency)
            if let x, let y { return x < y }
            if x != nil || y != nil { return x != nil }
            return a.currency == b.currency ? a.price < b.price : a.currency == (offers.first?.currency ?? "USD")
        }
        return ShopSortFields(title: game.title, price: cheapest?.price, currency: cheapest?.currency,
                              discount: offers.compactMap(\.savings).max().map(Double.init))
    }

    func wishlistSortFields(_ item: WishlistItem) -> ShopSortFields {
        ShopSortFields(title: item.title, price: item.best?.price, currency: item.best?.currency,
                       discount: item.best.map { Double($0.savings) }, added: item.added)
    }

    func sortedGiveaways() -> [Giveaway] {
        let sort: ShopSort = (giveawaySortPopup.selectedItem?.representedObject as? String).flatMap {
            ["ends": ShopSort.endsSoon, "name": .name][$0] } ?? .relevance
        return shopSorted(giveaways, by: sort) { giveaway in
            ShopSortFields(title: giveaway.title, ends: DealExpiry.parseGamerPowerEnd(giveaway.endDate)?.timeIntervalSince1970)
        }
    }

    func renderSearch() {
        schedulePlatformLookup()
        searchList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let reply = searchReply else {
            searchStatus.stringValue = searchError ?? (searchLoadingQuery != nil ? searchStatus.stringValue :
                "Search every PC store and the Mac App Store at once.")
            if searchError == nil && searchLoadingQuery != nil {
                for (index, view) in shopSkeletonRows(6).enumerated() { addShopRow(view, to: searchList, separated: index > 0) }
            }
            return
        }
        let sort = selectedSort(searchSortPopup)
        let games = shopSorted(reply.games.filter { shopShows(steamAppId: $0.steamAppId, appStore: $0.appStoreOffer != nil) }, by: sort, convert: sortConvert, fields: searchSortFields)
        for (index, game) in games.enumerated() { addShopRow(searchGameRow(game), to: searchList, separated: index > 0) }
        if !reply.appStore.apps.isEmpty {
            let currency = reply.appStore.currency ?? reply.appStore.apps[0].currency
            let heading = sectionHeader("Mac App Store", size: 15)
            heading.toolTip = "Mac App Store prices for your region, in \(currency)"
            addShopRow(heading, to: searchList, separated: false)
            let apps = shopSorted(reply.appStore.apps, by: sort, convert: sortConvert) {
                ShopSortFields(title: $0.title, price: $0.price, currency: $0.currency)
            }
            for app in apps { addShopRow(appStoreRow(app), to: searchList) }
        }
        let found = reply.games.count + reply.appStore.apps.count
        var line = found == 0 ? "No PC store or Mac App Store games match \u{201C}\(reply.query)\u{201D}." :
            "\(found) result\(found == 1 ? "" : "s") for \u{201C}\(reply.query)\u{201D}."
        if let searchError { line += " \(searchError)" }
        searchStatus.stringValue = line
    }

    // MARK: Wishlist

    func wishlistItem(key: String, title: String) -> WishlistItem? {
        wishlist?.items.first { $0.key == key || $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    // MARK: Mac / Windows compatibility

    /// Mac App Store games are Mac apps; otherwise only Steam's platform flags count. PC stores alone prove nothing.
    func compatibility(steamAppId: String?, appStore: Bool = false) -> GameCompatibility? {
        if appStore { return .mac }
        switch steamAppId.flatMap({ steamPlatformStatus[$0] }) {
        case "mac": return .mac
        case "windows": return .windowsOnly
        default: return nil
        }
    }

    func compatibilityBadge(_ value: GameCompatibility?) -> (badge: (symbol: String?, text: String, color: NSColor), tip: String)? {
        switch value {
        case .mac?:
            return (("apple.logo", "Mac", .systemGreen), "Mac: has a macOS version")
        case .windowsOnly?:
            let layers = compatibilityLayers
            let base = "Windows only: no macOS version on Steam. It needs a Windows compatibility app to run on a Mac, and may not work in every one"
            // Same compact badge as Mac; the compatibility-app note lives in the tooltip and VoiceOver only.
            let badge: (symbol: String?, text: String, color: NSColor) = ("square.grid.2x2.fill", "Windows", Self.windowsYellow)
            if let layers, !layers.isEmpty {
                return (badge, base + ". Installed here: \(layers.joined(separator: ", ")).")
            }
            return (badge, base + (layers == nil ? " (for example CrossOver)." : ". None is installed on this Mac yet (for example CrossOver)."))
        case nil:
            return nil
        }
    }

    func schedulePlatformLookup() {
        guard !platformLookupScheduled else { return }
        platformLookupScheduled = true
        // A run-loop timer (not the main queue) so it also fires while a modal or nested run loop is spinning.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.platformLookupScheduled = false
            self?.lookUpPlatforms()
        }
    }

    func lookUpPlatforms() {
        var ids = storeDeals.compactMap(\.steamAppId) + (shopHome.map { ($0.featured + $0.drops).compactMap(\.steamAppId) } ?? [])
        if let home = shopHome {
            let shelves: [[ShopGame]] = [home.topSellers ?? [], home.trending ?? [], home.couch ?? []]
            ids += shelves.joined().compactMap(\.steamAppId)
        }
        ids += (searchReply?.games ?? []).compactMap(\.steamAppId) + (wishlist?.items ?? []).compactMap(\.steamAppId)
        var seen = Set<String>()
        let wanted = ids.filter { !platformsRequested.contains($0) && seen.insert($0).inserted }.prefix(40)
        guard !wanted.isEmpty, platformLookupRounds < 20 else { return }
        platformLookupRounds += 1
        platformsRequested.formUnion(wanted)
        shopRead(["shop-platforms", "--steam", wanted.joined(separator: ",")]) { [weak self] code, data, _ in
            guard let self, code == 0, let reply = decodeDeals(PlatformsReply.self, data) else { return }
            var changed = false
            for (id, platforms) in reply.platforms {
                let status = platforms.status ?? "unknown"
                if self.steamPlatformStatus[id] != status { self.steamPlatformStatus[id] = status; changed = changed || status != "unknown" }
            }
            // Not looked up yet (Steam asks for a slow pace): try again on the next render, a little later.
            self.platformsRequested.subtract(reply.pending)
            if changed { self.rerenderShop() }
            if !reply.pending.isEmpty && reply.error == nil {
                Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.schedulePlatformLookup() }
            }
        }
    }

    func wishlistHeart(key: String, title: String, payload: [String: String]) -> NSButton {
        let heart = RowControlButton(title: "", target: self, action: #selector(wishlistHeartClicked(_:)))
        heart.identifier = NSUserInterfaceItemIdentifier(key)
        heart.bezelStyle = .inline
        heart.isBordered = false
        heart.imagePosition = .imageOnly
        heart.setAccessibilityIdentifier("wishlistHeart")
        heart.widthAnchor.constraint(equalToConstant: 22).isActive = true
        wishlistPayloads[key] = (title, payload.filter { !$0.value.isEmpty })
        configureHeart(heart)
        return heart
    }

    func configureHeart(_ heart: NSButton) {
        guard let key = heart.identifier?.rawValue, let entry = wishlistPayloads[key] else { return }
        let saved = wishlistItem(key: key, title: entry.title) != nil
        heart.image = NSImage(systemSymbolName: saved ? "heart.fill" : "heart", accessibilityDescription: nil)
        heart.contentTintColor = !wishlistEditable ? .tertiaryLabelColor : saved ? .systemPink : .secondaryLabelColor
        // Stays clickable while the wishlist is read-only: the click explains why instead of doing nothing.
        heart.isEnabled = true
        heart.toolTip = !wishlistEditable ? (wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            : saved ? "Remove from wishlist" : "Add to wishlist"
        heart.setAccessibilityLabel(saved ? "Remove \(entry.title) from wishlist" : "Add \(entry.title) to wishlist")
    }

    func refreshHearts() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        // The Shop lists and the game page both carry hearts and targets.
        let roots: [NSView] = [shopPageView, shopDetailContent].compactMap { $0 }
        for button in roots.flatMap(views).compactMap({ $0 as? NSButton }) {
            if button.accessibilityIdentifier() == "wishlistHeart" { configureHeart(button) }
            if button.accessibilityIdentifier() == "shopTarget" { configureShopTarget(button) }
        }
    }

    /// "Set Target…" on the game page: works whether or not the game is on the wishlist yet (setting one adds it).
    func shopTargetButton(key: String, title: String, currency: String) -> NSButton {
        let button = RowControlButton(title: "", target: self, action: #selector(shopTargetClicked(_:)))
        // Not the wishlist key itself, which identifies the heart.
        button.identifier = NSUserInterfaceItemIdentifier("target:" + key)
        button.controlSize = .small
        button.bezelStyle = .inline
        button.setAccessibilityIdentifier("shopTarget")
        shopTargetCurrencies[key] = currency
        configureShopTarget(button)
        return button
    }

    func shopTargetCode(key: String, title: String) -> String {
        wishlistItem(key: key, title: title).map(targetCurrency(for:)) ?? shopCurrency ?? shopTargetCurrencies[key] ?? "USD"
    }

    func configureShopTarget(_ button: NSButton) {
        guard let key = button.identifier?.rawValue.replacingOccurrences(of: "target:", with: ""), let entry = wishlistPayloads[key] else { return }
        let item = wishlistItem(key: key, title: entry.title)
        let code = shopTargetCode(key: key, title: entry.title)
        button.title = item?.targetPrice.map { "Target " + ShopMoney.format(ShopMoney.decimal($0), item?.targetCurrency ?? code) } ?? "Set Target\u{2026}"
        button.isEnabled = true
        button.toolTip = !wishlistEditable ? (wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            : item == nil ? "Set a target price in \(code). This also adds the game to your wishlist." : "Change the target price (\(code))"
        button.setAccessibilityLabel("Set a target price in \(code) for \(entry.title)")
    }

    @objc func shopTargetClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue.replacingOccurrences(of: "target:", with: ""), let entry = wishlistPayloads[key] else { return }
        guard wishlistEditable else {
            showReminderNote(wishlist == nil ? "The wishlist is still loading. Try again in a moment."
                             : wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            return
        }
        if let item = wishlistItem(key: key, title: entry.title) { promptTarget(item); return }
        let code = shopTargetCode(key: key, title: entry.title)
        guard let choice = askTargetPrice(entry.title, nil, code), let price = choice,
              let json = try? JSONSerialization.data(withJSONObject: entry.payload, options: [.sortedKeys]) else { return }
        shopRead(["wishlist", "--add", String(decoding: json, as: UTF8.self)]) { [weak self] code_, data, errors in
            guard let self else { return }
            guard code_ == 0, let reply = decodeDeals(WishlistReply.self, data) else {
                self.showReminderNote(self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors), error: true)
                return
            }
            self.applyWishlist(reply)
            // The backend may file it under another key (e.g. by title), so look the new item up again.
            guard let item = self.wishlistItem(key: key, title: entry.title) else { return }
            self.changeWishlist(["--target", item.key, "--price", String(format: "%.\(ShopMoney.minorUnits(code))f", price), "--currency", code])
        }
    }

    @objc func wishlistHeartClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let entry = wishlistPayloads[key] else { return }
        guard wishlistEditable else {
            showReminderNote(wishlist == nil ? "The wishlist is still loading. Try again in a moment."
                             : wishlist?.note ?? "Connect your Couch Cube drive to change the wishlist. It's saved on the drive.")
            return
        }
        if let item = wishlistItem(key: key, title: entry.title) {
            changeWishlist(["--remove", item.key])
        } else if let json = try? JSONSerialization.data(withJSONObject: entry.payload, options: [.sortedKeys]) {
            changeWishlist(["--add", String(decoding: json, as: UTF8.self)])
        }
    }

    func changeWishlist(_ arguments: [String]) {
        shopRead(["wishlist"] + arguments) { [weak self] code, data, errors in
            guard let self else { return }
            guard code == 0, let reply = decodeDeals(WishlistReply.self, data) else {
                self.showReminderNote(self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors), error: true)
                return
            }
            self.applyWishlist(reply)
        }
    }

    func checkWishlist(refresh: Bool) {
        guard !wishlistLoading else { return }
        wishlistLoading = true
        setShopLoading("wishlist", true)
        renderWishlist()
        shopRead(["wishlist", "--check", "--country", shopCountry] + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self else { return }
            self.wishlistLoading = false
            self.setShopLoading("wishlist", false)
            self.wishlistCheckedAt = Date()
            guard code == 0, let reply = decodeDeals(WishlistReply.self, data) else {
                self.wishlistStatus.stringValue = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
                return
            }
            self.applyWishlist(reply)
        }
    }

    func applyWishlist(_ reply: WishlistReply) {
        wishlist = reply
        refreshHearts()
        refreshShopSidebarDot()
        switch shopTab.selectedSegment {
        case 0: renderHome()
        case 4: renderWishlist()
        default: break
        }
    }

    func wishlistRow(_ item: WishlistItem, targetButton: Bool = true) -> NSView {
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        if let sale = item.saleText { tips.append(sale) }
        var bestPrice: ShopPrice?
        if let best = item.best {
            let price = shopPrice(best.price, best.currency)
            bestPrice = price
            tips.append("Best price: \(price.spoken)" + (best.store.map { " at \($0)" } ?? ""))
            if let checked = best.checked {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                tips.append("Checked " + formatter.localizedString(for: Date(timeIntervalSince1970: checked), relativeTo: Date()))
            }
        }
        let reached = targetReached(item)
        if let target = item.targetPrice {
            // The target stays in the currency it was entered in; the best price is converted to it for the comparison.
            let amount = ShopMoney.format(ShopMoney.decimal(target), item.targetCurrency ?? "USD")
            switch reached {
            case true?: tips.append("Target price \(amount) reached")
            case false?: tips.append("Target price: \(amount)")
            case nil:
                tips.append(item.best == nil ? "Target price: \(amount). No current price yet."
                            : "Target price: \(amount). Can't compare with \(item.best!.currency) prices until exchange rates load.")
            }
        }
        if let compat = compatibilityBadge(compatibility(steamAppId: item.steamAppId, appStore: item.appStoreId != nil)) {
            badges.append(compat.badge)
            tips.append(compat.tip)
        }
        if let owned = ownedBadge(item.steamAppId) { badges.append(owned) }
        if item.best == nil { badges.append((nil, "No price checked yet", .secondaryLabelColor)) }
        let heart = RowControlButton(title: "", target: self, action: #selector(wishlistRemoveClicked(_:)))
        heart.identifier = NSUserInterfaceItemIdentifier(item.key)
        heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
        heart.contentTintColor = .systemPink
        heart.bezelStyle = .inline
        heart.isBordered = false
        heart.isEnabled = wishlistEditable
        heart.toolTip = "Remove from wishlist"
        heart.setAccessibilityIdentifier("wishlistRemove")
        heart.setAccessibilityLabel("Remove \(item.title) from wishlist")
        heart.widthAnchor.constraint(equalToConstant: Self.shopHeartWidth).isActive = true
        let was = item.best.flatMap { best in best.normalPrice.flatMap { $0 > best.price ? shopPrice($0, best.currency).text : nil } }
        let right = offerColumns(price: bestPrice, priceText: bestPrice == nil ? "\u{2014}" : nil, was: was,
                                 savings: item.onSale ? item.best?.savings : nil, insight: item.insight, normal: item.best?.normalPrice,
                                 target: targetButton ? targetPill(for: item, reached: reached) : nil)
        let artURL = steamArtURL(item.steamAppId) ?? item.thumb
        let art: NSView = safeDealURL(artURL ?? "") == nil
            ? symbolArtwork(item.appStoreId != nil ? "apple.logo" : "gamecontroller", size: Self.shopArtworkSize.height, width: Self.shopArtworkSize.width)
            : dealArtwork(artURL, fill: item.appStoreId == nil)
        // A reached target lifts the whole row in a soft green.
        let view = shopItemRow(heart: heart, artwork: art, title: item.title, tags: shopTags(title: item.title), store: item.best?.store,
                               platform: dealBadges(badges), tip: tips.joined(separator: "\n"),
                               accessibility: "Open \(item.title). " + tips.joined(separator: ". "), right: right,
                               background: reached == true ? NSColor.systemGreen.withAlphaComponent(0.12) : nil) { [weak self] in
            self?.showShopGame(self?.shopDetail(wishlist: item))
        }
        view.setAccessibilityIdentifier("wishlistRow")
        return view
    }

    func searchFor(_ title: String) {
        shopSearchField.stringValue = title
        selectShopTab(3)
        shopSearchSubmitted()
    }

    func renderWishlist() {
        schedulePlatformLookup()
        wishlistList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let wishlist else {
            wishlistStatus.stringValue = wishlistLoading ? "Loading your wishlist\u{2026}" : ""
            return
        }
        func hit(_ item: WishlistItem) -> Bool { item.onSale || targetReached(item) == true }
        let byDefault = wishlist.items.sorted { a, b in
            hit(a) != hit(b) ? hit(a) : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        let items = shopSorted(byDefault, by: selectedSort(wishlistSortPopup), convert: sortConvert, fields: wishlistSortFields)
        items.forEach { addShopRow(wishlistRow($0), to: wishlistList) }
        var lines: [String] = []
        if let note = wishlist.note, note != Self.localWishlistNote { lines.append(note) }
        if items.isEmpty {
            lines.append("Your wishlist is empty. Click \u{2661} on any deal, free game or search result to add it.")
        } else {
            let hits = items.filter(hit).count
            lines.append("\(items.count) game\(items.count == 1 ? "" : "s")" + (hits > 0 ? " \u{00B7} \(hits) on sale" : ""))
        }
        // Where it's saved goes in the tooltip; the status line stays short.
        wishlistStatus.toolTip = (wishlist.note == Self.localWishlistNote ? "Saved on this Mac; it moves to your Couch Cube drive when you set one up."
            : "Saved on your Couch Cube drive (Couch Cube/Wishlist/wishlist.json); it works offline and moves with the drive.")
            + " Prices are checked when you open Cube Shop or refresh."
        wishlistStatus.stringValue = lines.joined(separator: " ")
    }

    /// Targets are entered in the Shop currency (e.g. HUF); with Original prices, in the currency already used or the game's own.
    func targetCurrency(for item: WishlistItem) -> String {
        shopCurrency ?? item.targetCurrency ?? item.best?.currency ?? "USD"
    }

    /// Whether the best price is at or below the target: the price is converted into the target's currency (with the card
    /// fee, unrounded, so a fraction above never counts). nil when there is no price yet or no exchange rate to compare with.
    func targetReached(_ item: WishlistItem) -> Bool? {
        guard let target = item.targetPrice, let best = item.best else { return nil }
        let code = item.targetCurrency ?? "USD"
        let price = ShopMoney.decimal(best.price)
        let converted = best.currency == code ? price
            : ShopMoney.convert(price, from: best.currency, to: code, rates: exchangeRates, feePercent: shopFeePercent, round: false)
        return converted.map { $0 <= ShopMoney.decimal(target) }
    }

    @objc func wishlistTargetClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let item = wishlist?.items.first(where: { $0.key == key }), wishlistEditable else { return }
        promptTarget(item)
    }

    func promptTarget(_ item: WishlistItem) {
        let key = item.key
        let code = targetCurrency(for: item)
        guard let choice = askTargetPrice(item.title, item.targetCurrency == code ? item.targetPrice : nil, code) else { return }
        let places = ShopMoney.minorUnits(code)
        changeWishlist(["--target", key] + (choice.map { ["--price", String(format: "%.\(places)f", $0), "--currency", code] } ?? []))
    }

    @objc func wishlistRemoveClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, wishlistEditable else { return }
        changeWishlist(["--remove", key])
    }

    /// In-memory stand-ins for the shop backend used by smoke tests (no network, no drive writes).
    func smokeShopReply(_ arguments: [String]) -> (Int32, String) {
        func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        func report() -> [String: Any] {
            ["items": smokeWishlist, "library": smokeWishlistOffline ? NSNull() : "/Volumes/Smoke/Couch Cube" as Any,
             "read_only": smokeWishlistOffline, "offline": smokeWishlistOffline, "merged": 0,
             "note": smokeWishlistOffline ? "The Couch Cube drive isn't connected. Showing the last saved wishlist (read-only)." as Any : NSNull()]
        }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        switch arguments.first {
        case "rates": return (0, smokeRatesJSON)
        case "shop-search": return (0, smokeShopSearchJSON)
        case "shop-steam":
            return (0, value("--app") == "620" ? smokeSteamDetailsJSON : json(["app_id": value("--app") ?? "", "found": false]))
        case "shop-game":
            // The search fixture's games, by CheapShark ID; anything else is unknown.
            let search = try! JSONSerialization.jsonObject(with: Data(smokeShopSearchJSON.utf8)) as! [String: Any]
            var found: Any = NSNull()
            if var game = (search["games"] as! [[String: Any]]).first(where: { $0["id"] as? String == value("--id") }) {
                game["app_store_offer"] = nil
                found = game
            }
            return (0, json(["game": found, "errors": [String]()]))
        case "shop-platforms":
            // Portal 2 and Hollow Knight have Mac builds; Drop Game is Windows only; anything else is unknown.
            let known: [String: [String: Any]] = ["620": ["mac": true, "windows": true, "status": "mac"],
                                                  "367520": ["mac": true, "windows": true, "status": "mac"],
                                                  "700": ["mac": false, "windows": true, "status": "windows"]]
            let ids = (value("--steam") ?? "").split(separator: ",").map(String.init)
            return (0, json(["platforms": Dictionary(uniqueKeysWithValues: ids.map { ($0, known[$0] ?? ["status": NSNull()]) }),
                             "pending": [String](), "error": NSNull()]))
        case "shop-home":
            var home = try! JSONSerialization.jsonObject(with: Data(smokeShopHomeJSON.utf8)) as! [String: Any]
            home["wishlist"] = report()
            // Trending reuses the search fixture's games (one on sale, one at a full price elsewhere).
            let search = try! JSONSerialization.jsonObject(with: Data(smokeShopSearchJSON.utf8)) as! [String: Any]
            home["trending"] = search["games"]
            if value("--scope") == "all" { home["scope"] = "all" }
            return (0, json(home))
        case "wishlist":
            if arguments.contains("--check") || arguments.count == 1 { return (0, json(report())) }
            guard !smokeWishlistOffline else { return (1, "ERROR: Connect your Couch Cube drive to change the wishlist.") }
            if let raw = value("--add"), let item = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] {
                let key = item["game_id"].map { "cs:" + $0 } ?? item["app_store_id"].map { "app:" + $0 } ?? "title:" + (item["title"] ?? "").lowercased()
                smokeWishlist.append(["key": key, "title": item["title"] ?? "", "game_id": item["game_id"] ?? NSNull(),
                                      "steam_app_id": item["steam_app_id"] ?? NSNull(), "app_store_id": item["app_store_id"] ?? NSNull(),
                                      "added": 1_700_000_000, "target_price": NSNull(), "target_currency": NSNull(),
                                      "thumb": item["thumb"] ?? NSNull(), "best": NSNull(), "on_sale": false,
                                      "target_hit": false, "sale_text": NSNull()])
            } else if let key = value("--remove") {
                smokeWishlist.removeAll { $0["key"] as? String == key }
            } else if let key = value("--target"), let index = smokeWishlist.firstIndex(where: { $0["key"] as? String == key }) {
                let price = value("--price").flatMap(Double.init)
                smokeWishlist[index]["target_price"] = price ?? NSNull()
                smokeWishlist[index]["target_currency"] = price == nil ? NSNull() : (value("--currency") ?? "USD")
            }
            return (0, json(report()))
        case "steam-link", "steam-wishlist-sync":
            return (0, json(["account": ["persona": "Gamer", "account": "gamer1"], "linked": arguments.contains("on"),
                             "synced": NSNull(), "owned": [String](), "imported": 0, "error": NSNull()]))
        default: return (1, "ERROR: unknown command")
        }
    }

    @objc func retryDeals() { loadDeals(page: 0, refresh: false) }

    @objc func loadMoreDeals() {
        guard dealsMode.selectedSegment == 0, storeDealsHasMore else { return }
        loadDeals(page: storeDealsPage + 1, refresh: false)
    }
}

extension SetupController {
    /// Steam on this Mac links without signing in here: the account comes from Steam's own files and its public wishlist
    /// is merged into the Cube Shop wishlist (one way). Owned games get a badge in every Shop list.
    func steamLinkRow() -> NSView {
        steamLinkSwitch.controlSize = .small
        steamLinkSwitch.target = self
        steamLinkSwitch.action = #selector(steamLinkChanged)
        steamLinkSwitch.setAccessibilityLabel("Add my Steam wishlist")
        shopStatusLabel(steamLinkNote)
        steamLinkNote.setAccessibilityIdentifier("steamLinkNote")
        renderSteamLink()
        loadSteamLink()
        return settingsRow("Steam wishlist", subtitle: "Games on your Steam wishlist show up here too.", symbol: "heart.circle",
                           color: .systemPink, trailing: steamLinkSwitch, detail: steamLinkNote)
    }

    func loadSteamLink(_ arguments: [String] = ["steam-link"], then: (() -> Void)? = nil) {
        steamLinkBusy = true
        renderSteamLink()
        shopRead(arguments) { [weak self] code, data, errors in
            guard let self else { return }
            self.steamLinkBusy = false
            if code == 0, let reply = decodeDeals(SteamLinkReply.self, data) {
                let ownedChanged = reply.owned != self.steamLink?.owned
                self.steamLink = reply
                if ownedChanged { self.rerenderShop() }
            } else if arguments.count > 1 {
                self.steamLinkNote.stringValue = self.dealsErrorText(String(decoding: data, as: UTF8.self) + errors)
            }
            self.renderSteamLink(keepNote: code != 0)
            then?()
        }
    }

    func renderSteamLink(keepNote: Bool = false) {
        let link = steamLink
        steamLinkSwitch.state = link?.linked == true ? .on : .off
        steamLinkSwitch.isEnabled = !steamLinkBusy && link?.account != nil
        guard !keepNote else { return }
        if steamLinkBusy && link == nil {
            steamLinkNote.stringValue = ""
        } else if let error = link?.error, link?.linked == true {
            steamLinkNote.stringValue = error
        } else if let account = link?.account {
            let name = account.persona ?? account.account
            var note = link?.linked == true ? "Linked to \(name)." : "Steam account: \(name)."
            if let imported = link?.imported, imported > 0 { note += " Added \(imported) game\(imported == 1 ? "" : "s")." }
            steamLinkNote.stringValue = note
        } else {
            steamLinkNote.stringValue = link == nil ? "" : "Sign in to Steam on this Mac to link it."
        }
    }

    @objc func steamLinkChanged() {
        let on = steamLinkSwitch.state == .on
        loadSteamLink(["steam-link", "--set", on ? "on" : "off"]) { [weak self] in
            if on { self?.syncSteamWishlist() }
        }
    }

    /// Takes in new Steam wishlist games (when linked), then checks wishlist prices as before.
    func syncSteamWishlist() {
        guard steamLink?.linked == true else { checkWishlist(refresh: false); return }
        loadSteamLink(["steam-wishlist-sync"]) { [weak self] in self?.checkWishlist(refresh: false) }
    }

    /// "Owned" for a Steam game this Mac's Steam account has (and isn't installed, which has its own badge).
    func ownedBadge(_ steamAppId: String?, installed: Bool = false) -> (symbol: String?, text: String, color: NSColor)? {
        guard !installed, let id = steamAppId, steamLink?.owned.contains(id) == true else { return nil }
        return ("bag.fill", "Owned", .systemBlue)
    }
}

extension SetupController {
    /// Home while it loads: the shapes of the featured banner and two shelves, shimmering.
    func shopHomeSkeleton() -> [NSView] {
        let hero = ShimmerView(cornerRadius: 14)
        hero.heightAnchor.constraint(equalToConstant: 300).isActive = true
        hero.setAccessibilityIdentifier("shopSkeleton")
        var views: [NSView] = [hero]
        for _ in 0..<2 {
            let heading = ShimmerView(cornerRadius: 6)
            heading.widthAnchor.constraint(equalToConstant: 180).isActive = true
            heading.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let headingRow = row([heading, NSView()])
            let grid = TileFlowView()
            grid.minimumTileWidth = 190
            grid.spacing = 18
            grid.textHeight = 52
            grid.setTiles((0..<4).map { _ in ShimmerView(cornerRadius: 10) })
            views += [headingRow, grid]
        }
        return views
    }

    /// List rows while a list loads: art, two lines of text and a price, shimmering.
    func shopSkeletonRows(_ count: Int) -> [NSView] {
        (0..<count).map { index in
            func block(_ width: CGFloat?, _ height: CGFloat, radius: CGFloat = 5) -> ShimmerView {
                let view = ShimmerView(cornerRadius: radius)
                if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
                view.heightAnchor.constraint(equalToConstant: height).isActive = true
                return view
            }
            let art = block(Self.shopArtworkSize.width, Self.shopArtworkSize.height, radius: 4)
            let lines = column([block(CGFloat(220 - index % 3 * 40), 13), block(110, 10)])
            lines.spacing = 8
            let line = row([art, lines, NSView(), block(64, 22, radius: 11)])
            line.alignment = .centerY
            line.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            line.setAccessibilityIdentifier("shopSkeleton")
            return line
        }
    }
}
