import AppKit


extension SetupController {
    /// The "Windows games" guide (page 16, under App Store): what the helper apps are for and, step by step,
    /// how a Windows game ends up in Play. Plain words, no setup is done for you here.
    func windowsGuidePage() -> NSStackView {
        func steps(_ lines: [String]) -> NSView {
            let list = NSStackView(views: lines.enumerated().map { index, line in
                let number = text("\(index + 1)", size: 12)
                number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
                number.alignment = .center
                number.textColor = .white
                let badge = NSStackView(views: [number])
                badge.wantsLayer = true
                badge.layer?.cornerRadius = 10
                badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
                badge.heightAnchor.constraint(equalToConstant: 20).isActive = true
                let label = text(line, size: 13)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let entry = NSStackView(views: [badge, label])
                entry.alignment = .top
                entry.spacing = 10
                return entry
            })
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 10
            return list
        }
        func option(_ title: String, _ tagline: String, symbol: String, color: NSColor, lines: [String], buttons: [NSView]) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
            icon.contentTintColor = color
            let heading = text(title, size: 17)
            heading.font = .systemFont(ofSize: 17, weight: .semibold)
            let header = row([icon, column([heading, text(tagline, size: 12, secondary: true)])])
            header.spacing = 12
            (header.arrangedSubviews[1] as? NSStackView)?.spacing = 2
            return card("", subtitle: nil, views: [header, steps(lines), row(buttons + [NSView()])])
        }
        func appButton(_ title: String, _ id: String) -> NSButton {
            let control = button(title, #selector(windowsGuideShowApp(_:)))
            control.identifier = NSUserInterfaceItemIdentifier(id)
            return control
        }
        let intro = text("Windows games need a helper app that translates them for the Mac. Check first: many games have a Mac version, shown with a Mac badge in Cube Shop.",
                         size: 13, secondary: true)
        let portingFolder = button("Games Folder", #selector(preparePortingKitFolder))
        portingFolder.setAccessibilityIdentifier("windowsGuidePortingFolder")
        return column([
            intro,
            option("CrossOver", "Easiest. Paid, with a free 14-day trial.", symbol: "star.fill", color: .systemOrange, lines: [
                "Get CrossOver and open it.",
                "Click Install, search for your store (Steam, Battle.net, EA app or Epic Games) and install it.",
                "Sign in to the store inside CrossOver and install your game there.",
                "The game shows up in Play under Windows games."
            ], buttons: [appButton("Get CrossOver", "crossover")]),
            option("Porting Kit", "Free. Ready-made installers for many games.", symbol: "shippingbox.fill", color: .systemBlue, lines: [
                "Get Porting Kit and open it.",
                "Click Games Folder below. In Porting Kit open Settings, choose Change next to \u{201C}Applications default path\u{201D} and pick \u{201C}Porting Kit\u{201D} at the top of the sidebar.",
                "Search for your game in Porting Kit, click Install and follow its steps.",
                "The game shows up in Play under Windows games. Back here, click Unpin Folder."
            ], buttons: [appButton("Get Porting Kit", "porting-kit"), portingFolder]),
            text("Not every Windows game runs on a Mac, and online games with anti-cheat usually don't.", size: 11, secondary: true)
        ])
    }

    @objc func showWindowsGuide() { selectPage(16) }

    @objc func windowsGuideShowApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showAppStoreRow(id)
    }
}

extension SetupController {
    func windowsGuideButton() -> NSButton {
        let guide = NSButton(title: "How to Play Windows Games", target: self, action: #selector(showWindowsGuide))
        guide.bezelStyle = .inline
        guide.isBordered = false
        guide.contentTintColor = .controlAccentColor
        guide.font = .systemFont(ofSize: 12, weight: .medium)
        guide.setAccessibilityIdentifier("windowsGuideButton")
        guide.setAccessibilityLabel("How to play Windows games")
        return guide
    }
}
