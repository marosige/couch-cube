import AppKit


/// One row style for every game in Cube Shop lists (wishlist, deals, search):
/// heart · art · title / tags / store / platform  ……  [target] [discount] [price].
/// The right side is two fixed columns with three lines each, so prices line up row to row:
///   price column:    usual price (small, struck through) · price (large) · lowest price ever
///   discount column: (gap)                               · −40% pill      · that low's discount
/// When today's price is the record, the bottom line reads "All-time low" in green instead.
extension SetupController {
    static let shopPriceColumnWidth: CGFloat = 148
    static let shopDiscountColumnWidth: CGFloat = 58

    func offerColumns(price: ShopPrice?, priceText: String? = nil, was: String?, savings: Int?, insight: PriceInsight?,
                      normal: Double?, target: NSView? = nil, lowPill: NSView? = nil) -> NSView {
        let onSale = (savings ?? 0) > 0
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor,
                   strike: Bool = false, id: String? = nil) -> NSTextField {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                             .foregroundColor: color]
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let field = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attributes))
            field.alignment = .right
            field.lineBreakMode = .byTruncatingHead
            if let id { field.setAccessibilityIdentifier(id) }
            return field
        }
        func slot(_ view: NSView?, height: CGFloat) -> NSView {
            let line = NSStackView()
            line.orientation = .horizontal
            if let view { line.addView(view, in: .trailing) }
            line.heightAnchor.constraint(equalToConstant: height).isActive = true
            return line
        }
        // Price column.
        var top: NSView? = nil
        if onSale, let was { top = label(was, size: 11, strike: true, id: "shopWasPrice") }
        let shown = price ?? priceText.map { ShopPrice(text: $0, original: $0, converted: false, value: nil) }
        var middle: NSView? = nil
        if let shown {
            let main = label(shown.text, size: 17, weight: .semibold, color: onSale ? .systemGreen : .labelColor)
            if shown.converted {
                main.toolTip = "\(shown.text) (\(shown.original))"
                main.setAccessibilityLabel(shown.spoken)
            }
            let line = NSStackView(views: [main])
            line.setAccessibilityIdentifier("shopPriceLine")
            middle = line
        }
        var bottom: NSView? = nil, bottomPercent: NSView? = nil
        if let insight {
            if insight.kind == "record" {
                // Only a sale can be a new low worth pointing out; a full price at its low says nothing.
                if onSale { bottom = label("All-time low", size: 11, weight: .semibold, color: .systemGreen, id: "shopPriceInsight") }
            } else if insight.low == 0 {
                bottom = label(insight.text, size: 11, id: "shopPriceInsight")
            } else {
                bottom = label(lowestText(insight, normal: normal), size: 11, id: "shopPriceInsight")
            }
            for case let field as NSTextField in [bottom, bottomPercent] {
                field.toolTip = insight.detail
                field.setAccessibilityLabel(field.stringValue + ". " + insight.detail)
            }
        }
        if let lowPill { bottom = lowPill }
        let priceColumn = NSStackView(views: [slot(top, height: 14), slot(middle, height: 22), slot(bottom, height: 14)])
        priceColumn.orientation = .vertical
        priceColumn.alignment = .trailing
        priceColumn.spacing = 1
        priceColumn.setAccessibilityIdentifier("shopPriceColumn")
        priceColumn.widthAnchor.constraint(equalToConstant: Self.shopPriceColumnWidth).isActive = true
        for line in priceColumn.arrangedSubviews { line.widthAnchor.constraint(equalTo: priceColumn.widthAnchor).isActive = true }
        // Discount column: nothing on top, the pill level with the price, the low's discount level with the low.
        let discountColumn = NSStackView(views: [slot(nil, height: 14), slot(onSale ? discountPill(savings ?? 0, size: 12) : nil, height: 22),
                                                 slot(bottomPercent, height: 14)])
        discountColumn.orientation = .vertical
        discountColumn.alignment = .trailing
        discountColumn.spacing = 1
        discountColumn.setAccessibilityIdentifier("shopPercentColumn")
        discountColumn.widthAnchor.constraint(equalToConstant: Self.shopDiscountColumnWidth).isActive = true
        for line in discountColumn.arrangedSubviews { line.widthAnchor.constraint(equalTo: discountColumn.widthAnchor).isActive = true }
        let cluster = NSStackView(views: (target.map { [$0] } ?? []) + [discountColumn, priceColumn])
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 10
        cluster.setAccessibilityIdentifier("shopPriceCluster")
        cluster.setHuggingPriority(.required, for: .horizontal)
        return cluster
    }

    /// The left side: heart, art, then title, tags (DLC, Early Access), store and platform, one per line.
    func shopItemRow(heart: NSView, artwork: NSView, title: String, tags: [String], store: String?, platform: NSAttributedString,
                     tip: String, accessibility: String, right: NSView, background: NSColor? = nil,
                     open: @escaping () -> Void) -> ClickableRowView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lines: [NSView] = [name]
        if !tags.isEmpty {
            let tagLine = NSTextField(labelWithString: tags.joined(separator: " \u{00B7} ").uppercased())
            tagLine.font = .systemFont(ofSize: 9, weight: .bold)
            tagLine.textColor = .systemOrange
            tagLine.setAccessibilityIdentifier("shopItemTags")
            lines.append(tagLine)
        }
        if let store { lines.append(storeTag(store)) }
        if platform.length > 0 {
            let info = WrappingLabel(labelWithAttributedString: platform)
            info.lineBreakMode = .byWordWrapping
            info.maximumNumberOfLines = 0
            info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            info.setAccessibilityIdentifier("dealBadges")
            lines.append(info)
        }
        let texts = NSStackView(views: lines)
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        heart.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        let line = row([heart, artwork, texts, right])
        line.distribution = .fill
        line.spacing = 12
        line.alignment = .centerY
        let rowView = ClickableRowView()
        if let background { rowView.baseColor = background }
        rowView.toolTip = tip.isEmpty ? title : "\(title)\n\(tip)"
        rowView.setAccessibilityLabel(accessibility)
        rowView.setAccessibilityIdentifier("dealRow")
        rowView.onActivate = open
        line.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -8),
            rowView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        return rowView
    }

    /// DLC and the like, from the store title (CheapShark lists add-ons under their own names).
    func shopTags(title: String) -> [String] {
        let lowered = title.lowercased()
        var tags: [String] = []
        if ["dlc", "season pass", "expansion pass", "soundtrack", "add-on"].contains(where: { lowered.contains($0) }) { tags.append("DLC") }
        if lowered.contains("early access") { tags.append("Early Access") }
        return tags
    }

    /// The all-time low as a small pill: the same text as the line it stands in for, and a click makes it the target.
    func lowTargetPill(for item: WishlistItem) -> NSButton? {
        guard let insight = item.insight, insight.low > 0 else { return nil }
        let pill = RowControlButton(title: "", target: self, action: #selector(wishlistLowTargetClicked(_:)))
        pill.identifier = NSUserInterfaceItemIdentifier(item.key)
        pill.isBordered = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.borderWidth = 1
        let record = insight.kind == "record"
        let color: NSColor = record ? .systemGreen : .secondaryLabelColor
        pill.attributedTitle = NSAttributedString(string: lowestText(insight, normal: item.best?.normalPrice), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: record ? .semibold : .regular), .foregroundColor: color])
        pill.layer?.borderColor = color.withAlphaComponent(0.5).cgColor
        pill.heightAnchor.constraint(equalToConstant: 16).isActive = true
        pill.widthAnchor.constraint(equalToConstant: min(Self.shopPriceColumnWidth, ceil(pill.attributedTitle.size().width) + 14)).isActive = true
        pill.isEnabled = wishlistEditable
        pill.toolTip = insight.detail + "Click to be told when the price drops to this."
        pill.setAccessibilityIdentifier("wishlistLowTarget")
        pill.setAccessibilityLabel("Set the target price to the all-time low, " + lowestText(insight, normal: item.best?.normalPrice))
        return pill
    }

    /// The faint "Target price" pill on wishlist rows; stronger once a target is set, green once it's reached.
    func targetPill(for item: WishlistItem, reached: Bool?) -> NSButton {
        let code = targetCurrency(for: item)
        let pill = RowControlButton(title: "", target: self, action: #selector(wishlistTargetClicked(_:)))
        pill.identifier = NSUserInterfaceItemIdentifier(item.key)
        pill.isBordered = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 11
        pill.layer?.borderWidth = 1
        let text: String, color: NSColor
        if let target = item.targetPrice {
            text = "Target " + ShopMoney.format(ShopMoney.decimal(target), item.targetCurrency ?? "USD")
            color = reached == true ? .systemGreen : .labelColor
        } else {
            text = "Target price"
            color = .tertiaryLabelColor
        }
        pill.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: item.targetPrice == nil ? .regular : .semibold), .foregroundColor: color])
        pill.layer?.borderColor = (item.targetPrice == nil ? NSColor.quaternaryLabelColor : color.withAlphaComponent(0.6)).cgColor
        pill.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pill.widthAnchor.constraint(equalToConstant: max(92, ceil(pill.attributedTitle.size().width) + 20)).isActive = true
        pill.isEnabled = wishlistEditable
        pill.toolTip = "Click to set a target price in \(code)"
        pill.setAccessibilityIdentifier("wishlistTarget")
        pill.setAccessibilityLabel("Set a target price in \(code) for \(item.title)")
        return pill
    }
}
