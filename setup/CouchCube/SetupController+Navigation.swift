import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func settingsRow(_ title: String, subtitle: String, symbol: String, color: NSColor,
                             trailing: NSView, artwork: NSImage? = nil, detail: NSView? = nil,
                             neutralArtworkBackground: Bool = false, bareArtwork: Bool = false) -> NSView {
        let icon = NSImageView(image: artwork ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = artwork?.isTemplate == false ? nil :
            bareArtwork ? .secondaryLabelColor : neutralArtworkBackground ? color : .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = bareArtwork ? NSColor.clear.cgColor :
            neutralArtworkBackground ? NSColor.quaternaryLabelColor.cgColor : color.cgColor
        tile.layer?.cornerRadius = 5
        tile.widthAnchor.constraint(equalToConstant: 26).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 26).isActive = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        if artwork != nil {
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            icon.imageScaling = .scaleProportionallyUpOrDown
        }
        let labels = column([text(title, size: 13), detail ?? text(subtitle, size: 11, secondary: true)])
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let result = row([tile, labels, trailing])
        result.distribution = .fill
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        if let controls = trailing as? NSStackView {
            controls.setHuggingPriority(.required, for: .horizontal)
            for control in controls.arrangedSubviews {
                control.setContentHuggingPriority(.required, for: .horizontal)
            }
        }
        labels.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(greaterThanOrEqualTo: result.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: result.bottomAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: result.trailingAnchor)
        ])
        result.spacing = 12
        return result
    }

    func addPage(_ title: String, content: NSStackView, maxWidth: CGFloat = 640) {
        let page = NSTabViewItem(identifier: title)
        page.label = title
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let container = TopAlignedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        let isHome = tabs.tabViewItems.isEmpty
        if isHome {
            content.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -16).isActive = true
        } else {
            content.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
            // A fixed width that follows the container (see TopAlignedView), above content hugging so a page never
            // starts narrow; it only tracks the window, so it never resizes it.
            let width = content.widthAnchor.constraint(equalToConstant: maxWidth)
            width.priority = NSLayoutConstraint.Priority(rawValue: 999)
            width.isActive = true
            container.pageWidth = width
            container.maxPageWidth = maxWidth
        }
        page.view = scroll
        tabs.addTabViewItem(page)
    }

    func selectPage(_ index: Int) {
        // Library storage (2, 3) now lives in Game library.
        if index == 2 || index == 3 { selectPage(6); return }
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        let previousPage = currentPage
        if !replayingHistory && (historyIndex < 0 || pageHistory[historyIndex].page != index ||
            (index == 9 && pageHistory[historyIndex].systemID != inspectorSystemID) ||
            (index == 12 && pageHistory[historyIndex].systemID != driveDetailID) ||
            (index == 14 && pageHistory[historyIndex].systemID != shopDetailKey)) {
            pageHistory = Array(pageHistory.prefix(historyIndex + 1))
            pageHistory.append((index, index == 9 ? inspectorSystemID : index == 12 ? driveDetailID : index == 14 ? shopDetailKey : nil))
            historyIndex = pageHistory.count - 1
        }
        backToolbarItem.isEnabled = historyIndex > 0
        forwardToolbarItem.isEnabled = historyIndex + 1 < pageHistory.count
        selectingPage = true
        defer { selectingPage = false }
        if index == 5 { updateSteamGuide() }
        tabs.selectTabViewItem(at: index)
        navigationBar.isHidden = false
        mainWindow.title = "Couch Cube"
        screenTitle.stringValue = index == 0 ? "Play" : index == 9 ? inspectorTitle.stringValue :
            index == 12 ? (detailDrive.map(driveTitle) ?? driveDetailCache[driveDetailID ?? ""].map { driveTitle($0.drive) } ?? "Drive") : index == 4 ? "Library storage" :
            index == 5 ? "Steam setup guide" : index == 14 ? (shopDetails[shopDetailKey ?? ""]?.title ?? "Cube Shop") :
            index == 15 ? "Clean up gaming setup" :
            sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube"
        storageNext.isHidden = index != 4
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playAction.keyEquivalent = index == 0 ? "\r" : ""
        let sidebarPage = (index == 3 || index == 4) ? 6 : index == 5 ? 6 : index == 9 ? inspectorParent : index == 12 ? driveDetailParent :
            index == 14 ? 13 : index == 15 ? 11 : index
        if let selected = sidebarPages.firstIndex(of: sidebarPage), sidebar.selectedRow != selected {
            sidebar.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        controllerTimer?.invalidate()
        controllerTimer = nil
        if index != 8 && index != 0 { stopControllerTest() }
        if index != 8 && index != 0 { stopControllerDiscovery() }
        if index == 8 || index == 0 {
            refreshControllers()
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                startControllerTest()
                controllerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshControllers() }
            }
        }
        if index == 0 { renderGeneral() }
        if index == 6 { renderStorageLocations() }
        // Back from a game page returns to the same Shop list; any other way in starts on Home.
        if index == 13 && previousPage != 14 { openCubeShop() }
        if index == 11, shopCurrency != nil { loadRates(refresh: false) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .sidebarTrackingSeparator, backToolbarItem.itemIdentifier,
         forwardToolbarItem.itemIdentifier, NSToolbarItem.Identifier("PageTitle"), .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == backToolbarItem.itemIdentifier { return backToolbarItem }
        if itemIdentifier == forwardToolbarItem.itemIdentifier { return forwardToolbarItem }
        if itemIdentifier == NSToolbarItem.Identifier("PageTitle") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Page"
            item.view = screenTitle
            item.isBordered = false
            item.visibilityPriority = .high
            return item
        }
        return nil
    }

    @objc func goBack() { navigateHistory(-1) }
    @objc func goForward() { navigateHistory(1) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBack) { return historyIndex > 0 }
        if menuItem.action == #selector(goForward) { return historyIndex + 1 < pageHistory.count }
        return true
    }

    func navigateHistory(_ offset: Int) {
        let next = historyIndex + offset
        guard pageHistory.indices.contains(next) else { return }
        historyIndex = next
        replayingHistory = true
        defer { replayingHistory = false }
        let destination = pageHistory[next]
        if destination.page == 9, let id = destination.systemID,
           let index = consoleSystems.firstIndex(where: { $0.id == id }) {
            let sender = NSButton()
            sender.tag = index
            showConsoleDetails(sender)
        } else if destination.page == 12, let id = destination.systemID {
            showDriveDetail(id)
            return
        } else if destination.page == 14, let id = destination.systemID, let detail = shopDetails[id] {
            showShopGame(detail)
            return
        } else {
            selectPage(destination.page)
        }
        loadPageData(destination.page)
    }

    func loadPageData(_ page: Int) {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        if page == 10 { loadAutoLaunch() }
        if page == 11 { loadStoreAccounts() }
        if page == 1 { loadApps() }
        if page == 7 { loadSystems() }
        if page == 5 || page == 6 { loadSteamStatus() }
        if page == 0 {
            refreshGeneral()
            if steamReport == nil { loadSteamStatus() }
            loadLauncherLibrary()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTitles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: sidebarTitles[row])
        if sidebarPages[row] < 0 {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let view = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3)
            ])
            return view
        }
        label.font = .systemFont(ofSize: 13)
        let cell = NSTableCellView()
        cell.textField = label
        let image = NSImageView(image: NSImage(systemSymbolName: sidebarSymbols[row], accessibilityDescription: nil)!)
        image.contentTintColor = .secondaryLabelColor
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        image.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let markers = self.row([])
        markers.spacing = 3
        markers.identifier = NSUserInterfaceItemIdentifier("sidebar-markers")
        markers.setContentHuggingPriority(.required, for: .horizontal)
        // Fixed center-Y anchors: icon and title sit identically whether zero, one or two markers are shown.
        for view in [image, label, markers] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        }
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: markers.leadingAnchor, constant: -6),
            markers.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            markers.heightAnchor.constraint(equalToConstant: 16)
        ])
        cell.imageView = image
        applySidebarMarkers(to: cell, row: row)
        return cell
    }

    /// Refreshes only the markers of an existing sidebar cell, so badge updates never rebuild or re-lay out the title.
    func applySidebarMarkers(to cell: NSTableCellView, row: Int) {
        guard let markers = cell.subviews.first(where: { $0.identifier?.rawValue == "sidebar-markers" }) as? NSStackView else { return }
        markers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var accessibility = sidebarTitles[row]
        if let badge = sidebarTaskCounts[sidebarPages[row]] {
            let tooltip = badge.groups.map { group in
                (["\(group.count) \(sidebarSeverityName(group.color)):"] + group.titles.map { "• " + $0 }).joined(separator: "\n")
            }.joined(separator: "\n")
            for group in badge.groups {
                let dot = SidebarCountDot(count: group.count, color: group.color)
                let summary = "\(group.count) \(sidebarSeverityName(group.color))"
                dot.toolTip = tooltip
                dot.setAccessibilityElement(true)
                dot.setAccessibilityRole(.staticText)
                dot.setAccessibilityLabel(summary + ": " + group.titles.joined(separator: ", "))
                dot.setContentHuggingPriority(.required, for: .horizontal)
                markers.addArrangedSubview(dot)
            }
            accessibility += ", " + badge.groups.map { "\($0.count) \(sidebarSeverityName($0.color))" }.joined(separator: ", ")
        }
        cell.setAccessibilityLabel(accessibility)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { sidebarPages[row] >= 0 }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { sidebarPages[row] < 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { sidebarPages[row] < 0 ? 28 : 32 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NSTableRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingPage, sidebarPages.indices.contains(sidebar.selectedRow) else { return }
        let page = sidebarPages[sidebar.selectedRow]
        guard page >= 0 else { return }
        guard tabs.selectedTabViewItem !== tabs.tabViewItems[page] else { return }
        selectPage(page)
        loadPageData(page)
    }

    @objc func openSettings() {
        selectPage(6)
        loadPageData(6)
    }
}
