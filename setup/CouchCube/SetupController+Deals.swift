import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func dealsPage() -> NSView {
        dealsMode.target = self
        dealsMode.action = #selector(dealsModeChanged)
        dealsMode.selectedSegment = UserDefaults.standard.integer(forKey: dealsModeKey) == 1 ? 1 : 0
        dealsMode.setAccessibilityLabel("Deal type")
        dealsSearch.placeholderString = "Search store deals"
        dealsSearch.sendsWholeSearchString = true
        dealsSearch.target = self
        dealsSearch.action = #selector(dealsFiltersChanged)
        dealsSearch.setAccessibilityLabel("Search store deals")
        func popup(_ button: NSPopUpButton, _ items: [(String, String)], label: String, selected: String?) {
            button.removeAllItems()
            for (title, value) in items {
                button.addItem(withTitle: title)
                button.lastItem?.representedObject = value
            }
            if let selected, let index = items.firstIndex(where: { $0.1 == selected }) { button.selectItem(at: index) }
            button.target = self
            button.action = #selector(dealsFiltersChanged)
            button.controlSize = .small
            button.setAccessibilityLabel(label)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        popup(dealsStorePopup, [("Any Store", "")], label: "Store", selected: nil)
        // CheapShark sorts Deals across pages, so these stay server-side; the labels match the other lists' Sort by.
        popup(dealsSortPopup, [("Best Deals", "rating"), ("Biggest Discount", "savings"), ("Lowest Price", "price"), ("Highest Price", "price-desc"),
                               ("Newest", "recent"), ("Best Reviews", "reviews"), ("Name A\u{2013}Z", "title")],
              label: "Sort deals", selected: UserDefaults.standard.string(forKey: dealsSortKey))
        // PC stores and launchers only: console and phone giveaways are never requested or shown.
        popup(giveawayPlatformPopup, [("All PC Stores", ""), ("PC", "pc"), ("Steam", "steam"), ("Epic Games Store", "epic-games-store"),
                                      ("GOG", "gog"), ("itch.io", "itchio"), ("Ubisoft", "ubisoft"), ("EA", "origin"),
                                      ("Battle.net", "battlenet"), ("DRM-Free", "drm-free")],
              label: "Platform", selected: nil)
        popup(giveawayTypePopup, [("All Types", ""), ("Full Games", "game"), ("In-Game Loot", "loot"), ("Beta Access", "beta")],
              label: "Giveaway type", selected: nil)
        // GamerPower sorts by date, value and popularity; Ends Soon and Name sort the fetched list here.
        popup(giveawaySortPopup, [("Newest", "date"), ("Ends Soon", "ends"), ("Highest Value", "value"), ("Most Popular", "popularity"),
                                  ("Name A\u{2013}Z", "name")],
              label: "Sort giveaways", selected: UserDefaults.standard.string(forKey: giveawaySortKey))
        dealsFilters.orientation = .horizontal
        dealsFilters.spacing = 8
        dealsFilters.alignment = .centerY
        dealsRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        dealsRefreshButton.bezelStyle = .inline
        dealsRefreshButton.isBordered = false
        dealsRefreshButton.contentTintColor = .secondaryLabelColor
        dealsRefreshButton.target = self
        dealsRefreshButton.action = #selector(refreshShop)
        dealsRefreshButton.toolTip = "Refresh"
        dealsRefreshButton.setAccessibilityLabel("Refresh")
        dealsProgress.style = .spinning
        dealsProgress.controlSize = .small
        dealsProgress.isDisplayedWhenStopped = false
        dealsStatus.font = .systemFont(ofSize: 11)
        dealsStatus.textColor = .secondaryLabelColor
        dealsRetry.target = self
        dealsRetry.action = #selector(retryDeals)
        dealsRetry.controlSize = .small
        dealsRetry.isHidden = true
        dealsStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dealsStatus.lineBreakMode = .byTruncatingTail
        dealsList.orientation = .vertical
        dealsList.alignment = .leading
        dealsList.spacing = 0
        dealsMore.target = self
        dealsMore.action = #selector(loadMoreDeals)
        dealsMore.isHidden = true
        dealsReminderNote.font = .systemFont(ofSize: 11)
        dealsReminderNote.setAccessibilityIdentifier("dealsReminderNote")
        dealsReminderNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dealsReminderSettings.controlSize = .small
        dealsReminderSettings.target = self
        dealsReminderSettings.action = #selector(openReminderPrivacy)
        dealsReminderBar.orientation = .horizontal
        dealsReminderBar.alignment = .firstBaseline
        dealsReminderBar.spacing = 8
        dealsReminderBar.setViews([dealsReminderNote, dealsReminderSettings], in: .leading)
        dealsReminderBar.isHidden = true
        configureShopPane(dealsPane, [dealsFilters, dealsList, dealsMore], full: [dealsFilters, dealsList])
        dealsList.setAccessibilityIdentifier("dealsList")
        layoutDealsFilters()
        renderDeals()
        return dealsPane
    }

    func dealsAttribution() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let result = NSMutableAttributedString()
        func plain(_ value: String) { result.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        func link(_ value: String, _ url: String) { result.append(NSAttributedString(string: value, attributes: [.font: font, .link: URL(string: url)!])) }
        plain("Deals by ")
        link("CheapShark", "https://www.cheapshark.com")
        plain(" \u{00B7} Free games by ")
        link("GamerPower", "https://www.gamerpower.com")
        plain(" \u{00B7} App Store via ")
        link("iTunes Search", "https://performance-partners.apple.com/search-api")
        plain(" \u{00B7} Rates by ")
        link("Frankfurter", "https://frankfurter.dev")
        plain(". PC stores only; not a promise a game runs on a Mac.")
        return result
    }

    func layoutDealsFilters() {
        dealsFilters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Status on the left, the list's own filters and Sort by on the right; titles are found with the search field above.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let views: [NSView] = [dealsStatus, dealsRetry, spacer] + (dealsMode.selectedSegment == 0
            ? [dealsStorePopup, dealsSortPopup]
            : [giveawayPlatformPopup, giveawayTypePopup, giveawaySortPopup])
        views.forEach { dealsFilters.addArrangedSubview($0) }
    }

    func dealsArguments(page: Int = 0) -> [String] {
        func value(_ button: NSPopUpButton) -> String { (button.selectedItem?.representedObject as? String) ?? "" }
        var arguments: [String]
        if dealsMode.selectedSegment == 0 {
            arguments = ["--source", "cheapshark", "--page", String(page), "--sort", value(dealsSortPopup).isEmpty ? "rating" : value(dealsSortPopup)]
            if !value(dealsStorePopup).isEmpty { arguments += ["--store", value(dealsStorePopup)] }
            let search = dealsSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty { arguments += ["--search", String(search.prefix(100))] }
        } else {
            let sort = value(giveawaySortPopup)
            arguments = ["--source", "gamerpower", "--sort", ["value", "popularity"].contains(sort) ? sort : "date"]
            if !value(giveawayPlatformPopup).isEmpty { arguments += ["--platform", value(giveawayPlatformPopup)] }
            if !value(giveawayTypePopup).isEmpty { arguments += ["--type", value(giveawayTypePopup)] }
        }
        if shopScopeMine { arguments.append("--mine") }
        return arguments
    }

    /// Loads deals only when the Deals page is shown. Identical in-flight requests are coalesced; visible results stay while refreshing.
    func openDeals() {
        dealsOpened = true
        let key = dealsArguments().joined(separator: "\u{1F}")
        if dealsLoadedKey[dealsMode.selectedSegment] == key { renderDeals(); return }
        loadDeals(page: 0, refresh: false)
    }

    func loadDeals(page: Int, refresh: Bool) {
        guard dealsOpened else { return }
        let mode = dealsMode.selectedSegment
        let base = dealsArguments(page: page)
        let key = base.joined(separator: "\u{1F}") + (refresh ? "\u{1F}refresh" : "")
        if dealsLoadingKey == key { return }
        dealsLoadingKey = key
        dealsGeneration += 1
        let generation = dealsGeneration
        let filtersKey = dealsArguments().joined(separator: "\u{1F}")
        setShopLoading("deals", true)
        dealsRetry.isHidden = true
        dealsMore.isEnabled = false
        if (mode == 0 ? storeDeals.isEmpty : giveaways.isEmpty) { dealsStatus.stringValue = "Loading\u{2026}" }
        dealsRead(base + (refresh ? ["--refresh"] : [])) { [weak self] code, data, errors in
            guard let self else { return }
            // Ignore replies for filters or modes the user has already left.
            guard generation == self.dealsGeneration else { return }
            self.dealsLoadingKey = nil
            self.setShopLoading("deals", false)
            self.dealsMore.isEnabled = true
            guard code == 0 else {
                let message = String(decoding: data, as: UTF8.self) + errors
                self.dealsFailed(self.dealsErrorText(message))
                return
            }
            if mode == 0, let reply = decodeDeals(StoreDealsReply.self, data) {
                self.dealsStores = reply.stores
                self.updateDealStores()
                self.storeDeals = page == 0 ? reply.deals : self.storeDeals + reply.deals.filter { deal in !self.storeDeals.contains { $0.id == deal.id } }
                self.storeDealsPage = reply.page
                self.storeDealsHasMore = reply.more
                self.dealsLoadedKey[0] = filtersKey
                if let stores = reply.myStores { self.myStores = stores; self.updateScopeHint() }
                self.renderDeals(reply.stale ? self.dealsErrorText(reply.error ?? "") : nil, fetched: reply.fetched)
            } else if mode == 1, let reply = decodeDeals(GiveawaysReply.self, data) {
                self.giveaways = reply.giveaways
                self.dealsLoadedKey[1] = filtersKey
                if let stores = reply.myStores { self.myStores = stores; self.updateScopeHint() }
                self.renderDeals(reply.stale ? self.dealsErrorText(reply.error ?? "") : nil, fetched: reply.fetched)
            } else {
                self.dealsFailed("The deals service returned data Couch Cube couldn't read.")
            }
        }
    }

    func dealsErrorText(_ raw: String) -> String {
        let message = raw.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "rate-limited:") {
            let seconds = Int(message[range.upperBound...].prefix { $0.isNumber }) ?? 60
            return "The deals service asked Couch Cube to slow down. Try again in about \(max(1, (seconds + 59) / 60)) min."
        }
        return message.isEmpty ? "Couldn't load deals. Check your internet connection." : String(message.prefix(300))
    }

    func dealsFailed(_ message: String) {
        let empty = dealsMode.selectedSegment == 0 ? storeDeals.isEmpty : giveaways.isEmpty
        dealsStatus.stringValue = empty ? message : "\(message) Showing the last loaded deals."
        dealsRetry.isHidden = false
        dealsMore.isHidden = dealsMode.selectedSegment != 0 || !storeDealsHasMore
    }

    func updateDealStores() {
        let selected = dealsStorePopup.selectedItem?.representedObject as? String ?? ""
        dealsStorePopup.removeAllItems()
        dealsStorePopup.addItem(withTitle: "Any Store")
        dealsStorePopup.lastItem?.representedObject = ""
        for store in dealsStores {
            dealsStorePopup.addItem(withTitle: store.name)
            dealsStorePopup.lastItem?.representedObject = store.id
        }
        if let index = dealsStorePopup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            dealsStorePopup.selectItem(at: index)
        }
    }

    func renderDeals(_ warning: String? = nil, fetched: Double? = nil) {
        schedulePlatformLookup()
        dealsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let store = dealsMode.selectedSegment == 0
        let count = store ? storeDeals.count : giveaways.count
        if let fetched { dealsFetched[dealsMode.selectedSegment] = fetched }
        let fetched = fetched ?? dealsFetched[dealsMode.selectedSegment]
        if store {
            for deal in storeDeals { addDealRow(storeDealRow(deal)) }
        } else {
            for giveaway in sortedGiveaways() { addDealRow(giveawayRow(giveaway)) }
        }
        dealsMore.isHidden = !store || !storeDealsHasMore || storeDeals.isEmpty
        if let warning {
            dealsStatus.stringValue = "\(warning) Showing saved deals."
            dealsRetry.isHidden = false
        } else if dealsLoadingKey == nil || count > 0 {
            dealsRetry.isHidden = true
            if count == 0 {
                dealsStatus.stringValue = dealsLoadedKey[dealsMode.selectedSegment] == nil ? "" :
                    store ? "No deals match these filters." : "No active giveaways match these filters."
            } else {
                var line = store ? "\(count) deals" : "\(count) active giveaways"
                if let fetched, fetched > 0 {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .short
                    line += " \u{00B7} updated \(formatter.localizedString(for: Date(timeIntervalSince1970: fetched), relativeTo: Date()))"
                }
                dealsStatus.stringValue = line
            }
        }
    }

    func addDealRow(_ view: NSView) { addShopRow(view, to: dealsList) }

    func addShopRow(_ view: NSView, to list: NSStackView, separated: Bool = true) {
        if separated, let last = list.arrangedSubviews.last, last.accessibilityIdentifier() != "shopSection" {
            let line = separator()
            list.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    /// Game art in one shared frame: wide store art is cropped to fill it; square app icons are fitted.
    func dealArtwork(_ source: String?, width: CGFloat = SetupController.shopArtworkSize.width,
                             height: CGFloat = SetupController.shopArtworkSize.height, fill: Bool = true) -> RemoteImageView {
        let image = RemoteImageView()
        image.aspectFill = fill
        image.setAccessibilityIdentifier("shopArtwork")
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 4
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        image.widthAnchor.constraint(equalToConstant: width).isActive = true
        image.heightAnchor.constraint(equalToConstant: height).isActive = true
        image.setAccessibilityElement(false)
        image.load(safeDealURL(source), enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        return image
    }

    func dealRow(artwork: NSView, title: String, detail: NSAttributedString, detailTip: String, trailing: [NSView],
                         accessibility: String, compact: Bool = false, indent: CGFloat = 0, actions: [NSView] = [],
                         open: @escaping () -> Void) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.isHidden = title.isEmpty
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Rating badges wrap to a second line instead of truncating; full wording lives in the tooltip.
        let info = WrappingLabel(labelWithAttributedString: detail)
        info.lineBreakMode = .byWordWrapping
        info.maximumNumberOfLines = 0
        info.cell?.wraps = true
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        info.setAccessibilityIdentifier("dealBadges")
        // Rows without a detail line (store rows under a game) center their title instead of leaving a blank line.
        info.isHidden = detail.length == 0
        let texts = NSStackView(views: [name, info])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        if !actions.isEmpty {
            // Title and platform on top, then a clear gap, then the row's own controls (target, wishlist, reminder).
            let bar = NSStackView(views: actions)
            bar.orientation = .horizontal
            bar.alignment = .centerY
            bar.spacing = 8
            bar.setAccessibilityIdentifier("shopRowActions")
            for view in actions { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
            if let above = [info, name].first(where: { !$0.isHidden }) { texts.setCustomSpacing(compact ? 4 : 10, after: above) }
            texts.addArrangedSubview(bar)
        }
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text column takes the slack, so the price columns always end at the row's edge.
        texts.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        info.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let line = row([artwork, texts] + trailing)
        line.distribution = .fill
        line.spacing = 12
        line.alignment = .centerY
        for view in trailing {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let rowView = ClickableRowView()
        rowView.toolTip = detailTip.isEmpty ? title : "\(title)\n\(detailTip)"
        rowView.setAccessibilityLabel(accessibility)
        rowView.setAccessibilityIdentifier("dealRow")
        rowView.onActivate = open
        line.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 6 + indent),
            line.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: rowView.topAnchor, constant: compact ? 5 : 8),
            line.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: compact ? -5 : -8),
            rowView.heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 36 : 59)
        ])
        return rowView
    }

    /// Compact inline badges: a mini symbol plus a short colored value, kept together with no-break spaces.
    /// Bundled launcher icon for a store name (CheapShark names), nil when Couch Cube has none.
    static func storeIconID(_ store: String) -> String? {
        let name = store.lowercased()
        if name.hasPrefix("steam") { return "steam" }
        if name.hasPrefix("epic") { return "epic-games" }
        if name.hasPrefix("gog") { return "gog-galaxy" }
        if name == "origin" || name.hasPrefix("ea ") || name == "ea" { return "ea" }
        if name.hasPrefix("battle.net") || name.hasPrefix("blizzard") { return "battle-net" }
        return nil
    }

    /// A small store logo: the bundled launcher icon, the Apple logo for the Mac App Store, otherwise a cart symbol.
    static func storeIcon(_ store: String, size: CGFloat) -> (image: NSImage, template: Bool) {
        if let id = storeIconID(store) {
            if let cached = storeIconCache.object(forKey: id as NSString) { return (cached, false) }
            if let image = Bundle.main.resourceURL.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("AppIcons/\(id).png")) }) {
                storeIconCache.setObject(image, forKey: id as NSString)
                return (image, false)
            }
        }
        let symbol = store.lowercased().contains("app store") ? "apple.logo" : "cart"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .medium)) ?? NSImage()
        return (image, true)
    }

    /// The store under the price, by its full name: gray with its logo, or on a sale a green tag with the discount
    /// ("Steam −75%"). A game row covering several stores shows just the best discount.
    func storeTag(_ store: String?, savings: Int? = nil) -> NSView {
        let text = [store, savings.map { "\u{2212}\($0)%" }].compactMap { $0 }.joined(separator: " ")
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = savings != nil ? .systemGreen : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .right
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        let icon: NSView
        if savings != nil {
            let image = NSImageView(image: NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? NSImage())
            image.contentTintColor = .systemGreen
            image.setAccessibilityIdentifier("shopSaleTag")
            icon = image
        } else {
            icon = storeIconView(store ?? "", size: 12)
        }
        let tag = NSStackView(views: [icon, label])
        tag.orientation = .horizontal
        tag.alignment = .centerY
        tag.spacing = 3
        let spoken = [store, savings.map { "\($0)% off" }].compactMap { $0 }.joined(separator: ", ")
        tag.toolTip = spoken
        tag.setAccessibilityIdentifier("shopStoreTag")
        tag.setAccessibilityElement(true)
        tag.setAccessibilityRole(.staticText)
        tag.setAccessibilityLabel(spoken)
        return tag
    }

    /// The all-time-low note: a small third line under the price, green only at the record.
    func insightLabel(_ insight: PriceInsight?) -> NSView? {
        guard let insight else { return nil }
        let label = NSTextField(labelWithString: insight.text)
        label.font = .systemFont(ofSize: 10, weight: insight.kind == "record" ? .semibold : .regular)
        label.textColor = insight.kind == "record" ? .systemGreen : .tertiaryLabelColor
        label.toolTip = insight.detail
        label.setAccessibilityLabel(insight.text + ". " + insight.detail)
        label.setAccessibilityIdentifier("shopPriceInsight")
        return label
    }

    func storeIconView(_ store: String, size: CGFloat = 16) -> NSView {
        let icon = Self.storeIcon(store, size: size)
        let view = NSImageView(image: icon.image)
        view.imageScaling = .scaleProportionallyUpOrDown
        if icon.template { view.contentTintColor = .secondaryLabelColor }
        view.setAccessibilityIdentifier("shopStoreIcon")
        view.setAccessibilityLabel(store)
        view.toolTip = store
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }

    /// Badge symbols are SF Symbol names; "store:<name>" puts that store's small logo in front of the text instead.
    func dealBadges(_ parts: [(symbol: String?, text: String, color: NSColor)]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  \u{00B7}  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if let symbol = part.symbol, symbol.hasPrefix("store:") {
                let icon = Self.storeIcon(String(symbol.dropFirst(6)), size: 12)
                let attachment = NSTextAttachment()
                attachment.image = icon.template ? icon.image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [part.color]))) ?? icon.image
                    : icon.image
                attachment.bounds = icon.template ? NSRect(x: 0, y: -1, width: attachment.image!.size.width, height: attachment.image!.size.height)
                    : NSRect(x: 0, y: -2, width: 12, height: 12)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: font]))
            } else if let symbol = part.symbol,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [part.color]))) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: part.text.replacingOccurrences(of: " ", with: "\u{00A0}"),
                                             attributes: [.font: font, .foregroundColor: part.color]))
        }
        return result
    }

    static func ratingColor(_ value: Double, good: Double, fair: Double) -> NSColor {
        value >= good ? .systemGreen : value >= fair ? .systemOrange : .systemRed
    }

    func dealBadge(_ title: String, color: NSColor) -> NSTextField {
        let badge = NSTextField(labelWithString: title)
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = color
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        badge.layer?.cornerRadius = 4
        badge.alignment = .center
        let padded = badge.widthAnchor.constraint(greaterThanOrEqualToConstant: badge.intrinsicContentSize.width + 10)
        padded.priority = .defaultHigh
        padded.isActive = true
        badge.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.heightAnchor.constraint(equalToConstant: 17).isActive = true
        return badge
    }

    func ratingCell(_ symbol: String, _ value: String?, color: NSColor, width: CGFloat, id: String, tip: String?) -> NSView {
        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 3
        cell.setAccessibilityIdentifier(id)
        cell.widthAnchor.constraint(equalToConstant: width).isActive = true
        cell.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.setHuggingPriority(.required, for: .horizontal)
        if let value {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))!)
            icon.contentTintColor = color
            let label = NSTextField(labelWithString: value)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = color
            label.setAccessibilityIdentifier("shopRatingValue")
            cell.setViews([NSView(), icon, label], in: .trailing)
            cell.toolTip = tip
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel(tip)
        }
        return cell
    }

    /// The right end of every shop row, in fixed-width columns that line up from row to row:
    /// [Steam | Metacritic | Deal rating]  heart  [Lowest]  price (usual price beneath)  discount.
    /// Rating columns appear when `ratings` is given and the marker column when `marker` is non-nil, even if empty,
    /// so every row of a list reserves the same slots. Missing values leave their cell blank.
    func priceCluster(heart: NSView?, price: ShopPrice?, priceText: String? = nil, was: String? = nil,
                              savings: Int? = nil, highlight: Bool = false, marker: String?? = nil, ratings: ShopRatings? = nil,
                              ratingOverlay: NSView? = nil, store: String? = nil, footer: NSView? = nil) -> NSView {
        func column(_ views: [NSView], width: CGFloat, id: String) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .trailing
            stack.spacing = 1
            stack.setAccessibilityIdentifier(id)
            stack.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.setHuggingPriority(.required, for: .horizontal)
            return stack
        }
        var columns: [NSView] = []
        if let ratings {
            let widths = Self.shopRatingWidths
            var cells: [NSView] = []
            cells.append(ratingCell("hand.thumbsup.fill", ratings.steamPercent.map { "\($0)%" },
                                      color: ratings.steamPercent.map { Self.ratingColor(Double($0), good: 80, fair: 50) } ?? .clear,
                                      width: widths.steam, id: "shopRatingSteam",
                                      tip: ratings.steamPercent.map { p in "Steam reviews: " + (ratings.steamText.map { "\($0) (\(p)%)" } ?? "\(p)%") }))
            cells.append(ratingCell("m.square.fill", ratings.metacritic.map { "\($0)" },
                                      color: ratings.metacritic.map { Self.ratingColor(Double($0), good: 75, fair: 50) } ?? .clear,
                                      width: widths.metacritic, id: "shopRatingMetacritic",
                                      tip: ratings.metacritic.map { "Metacritic score: \($0)" }))
            cells.append(ratingCell("tag.fill", ratings.deal.map { String(format: "%.1f", $0) },
                                      color: ratings.deal.map { Self.ratingColor($0, good: 8, fair: 5) } ?? .clear,
                                      width: widths.deal, id: "shopRatingDeal",
                                      tip: ratings.deal.map { String(format: "CheapShark deal rating: %.1f of 10", $0) }))
            if let ratingOverlay {
                // A row without ratings (a free game on Home) uses the empty rating area for its own control.
                let stack = NSStackView(views: cells)
                stack.spacing = 6
                let area = NSView()
                for view in [stack, ratingOverlay] {
                    view.translatesAutoresizingMaskIntoConstraints = false
                    area.addSubview(view)
                }
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: area.leadingAnchor), stack.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: area.topAnchor), stack.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                    ratingOverlay.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                    ratingOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor),
                    ratingOverlay.centerYAnchor.constraint(equalTo: area.centerYAnchor),
                    area.heightAnchor.constraint(greaterThanOrEqualTo: ratingOverlay.heightAnchor)
                ])
                columns.append(area)
            } else {
                columns += cells
            }
        }
        if let heart {
            let heartColumn = column([heart], width: Self.shopHeartWidth, id: "shopHeartColumn")
            heartColumn.alignment = .centerX
            columns.append(heartColumn)
        }
        // Search rows add a "Lowest" column beside the price; nil-in-optional keeps the column empty for alignment.
        if let marker {
            let badge = marker.map { dealBadge($0, color: .systemGreen) }
            badge?.setAccessibilityIdentifier("shopLowest")
            columns.append(column(badge.map { [$0] } ?? [], width: Self.shopMarkerWidth, id: "shopMarkerColumn"))
        }
        // Two right-aligned lines: the price, with the usual price struck through beside it on a sale; beneath it the
        // store in gray, or a green tag with the store and the discount on a sale. A real end date or the all-time-low
        // note goes on a small third line.
        var top: [NSView] = []
        if let shown = price ?? priceText.map({ ShopPrice(text: $0, original: $0, converted: false, value: nil) }) {
            top.append(priceLabel(shown, highlight: highlight))
        }
        if let was {
            let label = NSTextField(labelWithAttributedString: NSAttributedString(string: was, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
            label.setAccessibilityIdentifier("shopWasPrice")
            top.append(label)
        }
        for case let label as NSTextField in top {
            label.lineBreakMode = .byTruncatingHead
            label.alignment = .right
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let topLine = NSStackView(views: top)
        topLine.orientation = .horizontal
        topLine.alignment = .firstBaseline
        topLine.spacing = 6
        topLine.setAccessibilityIdentifier("shopPriceLine")
        let sale = savings.flatMap { $0 > 0 ? $0 : nil }
        let storeLine: NSView? = store != nil || sale != nil ? storeTag(store, savings: sale) : nil
        func slot(_ view: NSView?, height: CGFloat?) -> NSView {
            // A full-width line with its content pinned to the right edge.
            let line = NSStackView()
            line.orientation = .horizontal
            if let view { line.addView(view, in: .trailing) }
            if let height { line.heightAnchor.constraint(equalToConstant: height).isActive = true }
            return line
        }
        var lines = [slot(topLine, height: 17), slot(storeLine, height: 15)]
        if let footer { lines.append(slot(footer, height: nil)) }
        let block = column(lines, width: Self.shopOfferWidth, id: "shopPriceColumn")
        for line in lines { line.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
        block.spacing = 2
        columns.append(block)
        let cluster = NSStackView(views: columns)
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 6
        cluster.setAccessibilityIdentifier("shopPriceCluster")
        cluster.setHuggingPriority(.required, for: .horizontal)
        return cluster
    }

    func storeDealRow(_ deal: StoreDeal) -> NSView {
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips = [deal.store ?? "Store"]
        let compat = compatibilityBadge(compatibility(steamAppId: deal.steamAppId))
        if let compat { badges.append(compat.badge); tips.append(compat.tip) }
        if let percent = deal.steamRatingPercent {
            tips.append("Steam reviews: " + (deal.steamRating.map { "\($0) (\(percent)%)" } ?? "\(percent)%"))
        }
        if let metacritic = deal.metacritic { tips.append("Metacritic score: \(metacritic)") }
        if let rating = deal.dealRating { tips.append(String(format: "CheapShark deal rating: %.1f of 10", rating)) }
        if deal.installed { badges.append(("checkmark.circle.fill", "Installed", .systemGreen)) }
        let ratings = ShopRatings(steamPercent: deal.steamRatingPercent, steamText: deal.steamRating,
                                  metacritic: deal.metacritic, deal: deal.dealRating)
        let salePrice = shopPrice(deal.salePrice, "USD")
        let heart = wishlistHeart(key: deal.gameId.map { "cs:" + $0 } ?? "title:" + deal.title.lowercased(), title: deal.title,
                                  payload: ["title": deal.title, "game_id": deal.gameId ?? "", "steam_app_id": deal.steamAppId ?? "", "thumb": deal.thumb ?? ""])
        let trailing = [priceCluster(heart: nil, price: salePrice,
                                     was: deal.normalPrice.flatMap { $0 > deal.salePrice ? shopPrice($0, "USD").text : nil },
                                     savings: deal.savings, ratings: ratings, store: deal.store)]
        if salePrice.converted { tips.append("Price: \(salePrice.spoken)") }
        var spoken = "\(deal.title), \(salePrice.spoken)"
        if let normal = deal.normalPrice, normal > deal.salePrice { spoken += ", was \(shopPrice(normal, "USD").spoken), \(deal.savings)% off" }
        spoken += (deal.installed ? ", installed" : "") + ". " + tips.dropFirst().joined(separator: ". ")
        return dealRow(artwork: dealArtwork(deal.thumb), title: deal.title,
                       detail: dealBadges(badges), detailTip: tips.joined(separator: "\n"), trailing: trailing,
                       accessibility: "Open \(deal.title) deal at \(deal.store ?? "store"), " + spoken,
                       actions: [shopTargetButton(key: heart.identifier!.rawValue, title: deal.title, currency: "USD"), heart]) { [weak self] in
            self?.openShopLink(deal.url, hosts: cheapSharkHosts)
        }
    }

    /// `ratingColumns` reserves the (empty) rating columns when the row shares a list with store deals, as on Home.
    func giveawayRow(_ giveaway: Giveaway, ratingColumns: Bool = false) -> NSView {
        var badges: [(symbol: String?, text: String, color: NSColor)] = []
        var tips: [String] = []
        if let type = giveaway.type { badges.append((nil, type, .secondaryLabelColor)); tips.append(type) }
        if !giveaway.platforms.isEmpty { tips.append("Platforms: " + giveaway.platforms.joined(separator: ", ")) }
        // The store giving it away goes under the price, like every other row; plain "PC" says nothing about the store.
        let giver = giveaway.platforms.first { !["pc", "drm-free"].contains($0.lowercased()) }
        var trailing: [NSView] = []
        var reminder: NSButton?
        if let end = DealExpiry.parseGamerPowerEnd(giveaway.endDate), end > dealsNow() {
            tips.append("Ends " + DateFormatter.localizedString(from: end, dateStyle: .medium, timeStyle: .short))
            let key = "giveaway:" + giveaway.id
            if let id = dealReminders[key], reminderStore.access == .granted, !reminderStore.exists(id) {
                dealReminders[key] = nil
            }
            let remind = RowControlButton(title: "", target: self, action: #selector(dealReminderClicked(_:)))
            remind.identifier = NSUserInterfaceItemIdentifier(giveaway.id)
            configureReminderButton(remind, giveaway: giveaway, end: end)
            reminder = remind
        }
        // GamerPower lists the usual value in US dollars ("$19.99").
        let worthPrice = giveaway.worth.flatMap { Double($0.replacingOccurrences(of: "$", with: "")) }.map { shopPrice($0, "USD") }
        let heart = wishlistHeart(key: "title:" + giveaway.title.lowercased(), title: giveaway.title, payload: ["title": giveaway.title, "thumb": giveaway.thumb ?? ""])
        trailing.append(priceCluster(heart: nil, price: nil, priceText: "Free", was: worthPrice?.text ?? giveaway.worth, highlight: true,
                                     ratings: ratingColumns ? ShopRatings.none : nil, store: giver, footer: reminder))
        if let worthPrice, worthPrice.converted { tips.append("Usually \(worthPrice.spoken)") }
        return dealRow(artwork: dealArtwork(giveaway.thumb), title: giveaway.title,
                       detail: dealBadges(badges), detailTip: tips.joined(separator: "\n"), trailing: trailing,
                       accessibility: "Open \(giveaway.title) giveaway, free" + ((worthPrice?.spoken ?? giveaway.worth).map { ", usually \($0)" } ?? "")
                        + (tips.isEmpty ? "" : ". " + tips.joined(separator: ". ")),
                       actions: [heart]) { [weak self] in
            self?.openShopLink(giveaway.url, hosts: gamerPowerHosts)
        }
    }

    func configureReminderButton(_ button: NSButton, giveaway: Giveaway, end: Date) {
        button.bezelStyle = .inline
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("dealReminder")
        let set = dealReminders["giveaway:" + giveaway.id] != nil
        let expiry = DealExpiry.label(until: end, now: dealsNow())
        // The real end date stays visible either way; the icon says whether a reminder is set.
        let title = expiry?.text ?? "Offer ended"
        let color: NSColor = set ? .systemGreen : expiry?.urgent == true ? .systemOrange : .secondaryLabelColor
        button.image = NSImage(systemSymbolName: set ? "checkmark.circle.fill" : "bell", accessibilityDescription: nil)
        button.contentTintColor = color
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
        button.toolTip = set ? "A reminder is set for the day before this giveaway ends. Click to remove it."
            : "Remind me at 9:00 the day before this giveaway ends."
        button.setAccessibilityLabel(set ? "Reminder set for the day before this deal ends. Activate to remove it."
            : "Remind me the day before this deal ends" + (expiry.map { ", \($0.text.lowercased())" } ?? ""))
    }

    func showReminderNote(_ text: String, error: Bool = false, privacy: Bool = false) {
        dealsReminderNote.stringValue = text
        dealsReminderNote.textColor = error ? .systemRed : .secondaryLabelColor
        dealsReminderSettings.isHidden = !privacy
        dealsReminderBar.isHidden = false
    }

    @objc func openReminderPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { dealsOpener(url) }
    }

    @objc func dealReminderClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let giveaway = (giveaways + (shopHome?.free ?? [])).first(where: { $0.id == id }) else { return }
        guard let end = DealExpiry.parseGamerPowerEnd(giveaway.endDate) else { return }
        let key = "giveaway:" + giveaway.id
        let store = reminderStore
        if let id = dealReminders[key] {
            if store.access == .granted, !store.exists(id) {
                dealReminders[key] = nil
                configureReminderButton(sender, giveaway: giveaway, end: end)
                showReminderNote("That reminder was deleted in Reminders. Click again to add a new one.")
                return
            }
            guard confirmReminderRemoval(giveaway.title) else { return }
            do { try store.remove(id) } catch {
                showReminderNote("Couldn't remove the reminder: \(error.localizedDescription)", error: true)
                return
            }
            dealReminders[key] = nil
            configureReminderButton(sender, giveaway: giveaway, end: end)
            showReminderNote("Reminder removed.")
            return
        }
        let denied = { [weak self] in
            self?.showReminderNote("Couch Cube isn't allowed to add reminders. Turn it on in Privacy & Security \u{203A} Reminders.",
                                   error: true, privacy: true)
        }
        switch store.access {
        case .denied: denied()
        case .granted: addDealReminder(giveaway, end: end, button: sender)
        case .notDetermined:
            store.requestAccess { [weak self] granted in
                guard let self else { return }
                if granted { self.addDealReminder(giveaway, end: end, button: sender) } else { denied() }
            }
        }
    }

    func addDealReminder(_ giveaway: Giveaway, end: Date, button: NSButton) {
        let key = "giveaway:" + giveaway.id
        guard dealReminders[key] == nil else { return }
        guard let due = DealExpiry.reminderDate(for: end, now: dealsNow()) else {
            showReminderNote("This giveaway ends too soon for a reminder.")
            return
        }
        let store = giveaway.platforms.first { $0 != "PC" } ?? giveaway.platforms.first ?? "GamerPower"
        let endText = DateFormatter.localizedString(from: end, dateStyle: .full, timeStyle: .short)
        var notes = "Free" + (giveaway.worth.map { " (usually \($0))" } ?? "") + " on \(giveaway.platforms.joined(separator: ", ")).\n"
        notes += "Ends: \(endText). GamerPower lists end times without a time zone; read as UTC.\n"
        notes += giveaway.url
        do {
            let id = try reminderStore.add(title: "\(giveaway.title) deal ends \u{2014} \(store)", notes: notes,
                                           url: safeDealURL(giveaway.url, hosts: gamerPowerHosts), due: due.date)
            dealReminders[key] = id
        } catch {
            showReminderNote("Couldn't add the reminder: \(error.localizedDescription)", error: true)
            return
        }
        configureReminderButton(button, giveaway: giveaway, end: end)
        let when = DateFormatter.localizedString(from: due.date, dateStyle: .medium, timeStyle: .short)
        showReminderNote(due.adjusted
            ? "9:00 the day before has already passed, so the reminder is set for \(when) in your default Reminders list."
            : "Reminder set for \(when) in your default Reminders list.")
    }

    /// Shop links open in the default browser, and only as https links on the expected service's own hosts.
    func openShopLink(_ value: String?, hosts: Set<String>) {
        guard let link = safeDealURL(value, hosts: hosts) else {
            showReminderNote("This link isn't from CheapShark, GamerPower or the Mac App Store, so Couch Cube didn't open it.", error: true)
            return
        }
        dealsOpener(link)
    }

    @objc func dealsModeChanged() {
        UserDefaults.standard.set(dealsMode.selectedSegment, forKey: dealsModeKey)
        dealsGeneration += 1
        dealsLoadingKey = nil
        setShopLoading("deals", false)
        layoutDealsFilters()
        renderDeals()
        openDeals()
    }

    @objc func dealsFiltersChanged() {
        if let sort = dealsSortPopup.selectedItem?.representedObject as? String { UserDefaults.standard.set(sort, forKey: dealsSortKey) }
        if let sort = giveawaySortPopup.selectedItem?.representedObject as? String { UserDefaults.standard.set(sort, forKey: giveawaySortKey) }
        if dealsLoadedKey[dealsMode.selectedSegment] == dealsArguments().joined(separator: "\u{1F}") { renderDeals(); return }
        if dealsMode.selectedSegment == 0 { storeDealsPage = 0 }
        loadDeals(page: 0, refresh: false)
    }

    @objc func refreshDeals() { loadDeals(page: 0, refresh: true) }

    // MARK: Cube Shop
}
