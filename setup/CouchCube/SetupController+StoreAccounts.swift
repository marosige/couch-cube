import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func storeAccountsCard() -> NSBox {
        storeAccountsSummary.font = .systemFont(ofSize: 13, weight: .semibold)
        storeAccountsSummary.setAccessibilityIdentifier("storeAccountsSummary")
        storeAccountsChecked.font = .systemFont(ofSize: 11)
        storeAccountsChecked.lineBreakMode = .byWordWrapping
        storeAccountsChecked.maximumNumberOfLines = 0
        storeAccountsChecked.preferredMaxLayoutWidth = 360
        storeAccountsChecked.textColor = .secondaryLabelColor
        storeAccountsRows.orientation = .vertical
        storeAccountsRows.alignment = .leading
        storeAccountsRows.spacing = 0
        storeWalkthroughPanel.orientation = .vertical
        storeWalkthroughPanel.alignment = .leading
        storeWalkthroughPanel.spacing = 8
        storeWalkthroughPanel.isHidden = true
        let note = text("Who is signed in to each game app. Read from the apps' own files; passwords are never read. Mac and Windows apps sign in separately.",
                        size: 11, secondary: true)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 520
        let header = row([column([storeAccountsSummary, storeAccountsChecked]),
                          button("Set Up Accounts...", #selector(startStoreWalkthrough)),
                          button("Check Again", #selector(checkStoreAccounts))])
        (header.arrangedSubviews[0] as? NSStackView)?.spacing = 2
        header.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        renderStoreAccounts()
        return card("Store Accounts", subtitle: nil, views: [header, note, storeWalkthroughPanel, storeAccountsRows])
    }

    @objc func checkStoreAccounts() { loadStoreAccounts() }

    func loadStoreAccounts() {
        let check = storeAccounts.begin()
        renderStoreAccounts()
        storeAccountsRead { [weak self] code, data in
            guard let self else { return }
            let report = code == 0 ? try? JSONDecoder().decode(StoreAccountsReport.self, from: data) : nil
            guard self.storeAccounts.finish(check, report: report, at: Date()) else { return }
            if report == nil { self.append("Couldn't check game client sign-ins.\n") }
            self.renderStoreAccounts()
        }
    }

    func storeAccountRow(_ client: StoreAccountRow) -> NSView {
        let checking = storeAccounts.phase == .checking
        let waiting = storeClientsOpen.contains(client.id)
        let color: NSColor = client.state == "signed_in" ? .systemGreen : client.state == "not_installed" ? .systemGray : .systemOrange
        var detail = client.detail
        if client.kind == "wine", let host = client.host, let bottle = client.bottle { detail += " · \(host) bottle \u{201C}\(bottle)\u{201D}" }
        if client.accounts.count > 1 { detail += " · \(client.accounts.count - 1) more account\(client.accounts.count == 2 ? "" : "s") on this Mac" }
        if waiting { detail = "Waiting for \(client.name) to quit\u{2026}" } else if checking { detail = "Checking\u{2026}" }
        let open: NSButton
        if client.state == "not_installed" {
            open = button("App Store", #selector(showAppStoreForClient(_:)))
        } else {
            open = button("Open", #selector(openStoreClient(_:)))
            open.isEnabled = !waiting
            open.setAccessibilityLabel("Open \(client.name) to sign in")
        }
        open.identifier = NSUserInterfaceItemIdentifier(client.id)
        let again = button("Check Again", #selector(checkStoreAccounts))
        again.isEnabled = !checking
        again.setAccessibilityLabel("Check \(client.name) sign-in again")
        let status = text(detail, size: 11, secondary: true)
        status.setAccessibilityIdentifier("storeAccountStatus")
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        dot.contentTintColor = color
        let line = row([dot, status])
        line.spacing = 5
        let title = client.platform == "Mac" ? client.name + " (Mac client)" : client.name
        let result = settingsRow(title, subtitle: detail, symbol: client.kind == "mac" ? "desktopcomputer" : "pc",
                                 color: client.kind == "mac" ? .systemBlue : .systemIndigo,
                                 trailing: row([open, again]), detail: line)
        result.identifier = NSUserInterfaceItemIdentifier("store-row-" + client.id)
        result.setAccessibilityElement(false)
        status.setAccessibilityLabel("\(title): \(detail)")
        return result
    }

    func renderStoreAccounts() {
        defer { renderLauncher() }
        storeAccountsSummary.stringValue = storeAccounts.summary
        storeAccountsChecked.textColor = storeAccountsError == nil ? .secondaryLabelColor : .systemRed
        if let error = storeAccountsError {
            storeAccountsChecked.stringValue = error
        } else if let date = storeAccounts.lastChecked {
            storeAccountsChecked.stringValue = "Last checked " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        } else {
            storeAccountsChecked.stringValue = storeAccounts.phase == .checking ? "Reading local client files\u{2026}" : ""
        }
        storeAccountsRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, client) in (storeAccounts.report?.clients ?? []).enumerated() {
            if index > 0 { storeAccountsRows.addArrangedSubview(separator()) }
            let view = storeAccountRow(client)
            storeAccountsRows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: storeAccountsRows.widthAnchor).isActive = true
        }
        renderStoreWalkthrough()
    }

    func renderStoreWalkthrough() {
        storeWalkthroughPanel.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let walkthrough = storeWalkthrough, let report = storeAccounts.report else {
            storeWalkthroughPanel.isHidden = true
            return
        }
        storeWalkthroughPanel.isHidden = false
        let heading: NSTextField
        var buttons: [NSView] = []
        if let id = walkthrough.current, let client = report.clients.first(where: { $0.id == id }) {
            let step = (walkthrough.ids.firstIndex(of: id) ?? 0) + 1
            heading = text("Step \(step) of \(walkthrough.ids.count): \(client.name) \u{2014} \(client.detail)", size: 12)
            let open = button("Open \(client.name)", #selector(openStoreClient(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(id)
            open.isEnabled = !storeClientsOpen.contains(id)
            buttons = [open, button("Skip", #selector(skipStoreWalkthrough)), button("Next", #selector(nextStoreWalkthrough))]
            let hint = text(client.state == "signed_in" ? "Already signed in. Choose Next to continue."
                            : "Open it, sign in there, then quit it; the status updates when it closes.", size: 11, secondary: true)
            storeWalkthroughPanel.addArrangedSubview(heading)
            storeWalkthroughPanel.addArrangedSubview(hint)
        } else {
            var summary = walkthrough.ids.isEmpty ? "No game clients are installed yet. Get them in the App Store."
                : "Done \u{2014} \(storeAccounts.summary)."
            let names = walkthrough.skipped.compactMap { id in report.clients.first { $0.id == id }?.name }
            if !names.isEmpty { summary += " Skipped: " + names.joined(separator: ", ") + "." }
            heading = text(summary, size: 12)
            storeWalkthroughPanel.addArrangedSubview(heading)
            buttons = [button("Done", #selector(endStoreWalkthrough))]
        }
        heading.setAccessibilityIdentifier("storeWalkthroughStep")
        heading.lineBreakMode = .byWordWrapping
        heading.maximumNumberOfLines = 0
        storeWalkthroughPanel.addArrangedSubview(row(buttons))
    }

    @objc func startStoreWalkthrough() {
        guard let report = storeAccounts.report else { loadStoreAccounts(); return }
        storeWalkthrough = StoreAccountsWalkthrough(report: report)
        renderStoreWalkthrough()
    }

    @objc func nextStoreWalkthrough() { storeWalkthrough?.next(); renderStoreWalkthrough() }
    @objc func skipStoreWalkthrough() { storeWalkthrough?.skip(); renderStoreWalkthrough() }
    @objc func endStoreWalkthrough() { storeWalkthrough = nil; renderStoreWalkthrough() }

    @objc func showAppStoreForClient(_ sender: NSButton) { selectPage(1) }

    @objc func openStoreClient(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, !storeClientsOpen.contains(id),
              let client = storeAccounts.report?.clients.first(where: { $0.id == id }), client.state != "not_installed" else { return }
        storeClientsOpen.insert(id)
        renderStoreAccounts()
        storeClientOpen(id) { [weak self] code in
            guard let self else { return }
            self.storeClientsOpen.remove(id)
            if code != 0 {
                self.storeAccountsError = "Couldn't open \(client.name). " + (client.kind == "wine"
                    ? "Open \(client.host ?? "CrossOver or Whisky") and start it from its bottle, then choose Check Again."
                    : "Open it from Applications, then choose Check Again.")
            } else {
                self.storeAccountsError = nil
            }
            self.loadStoreAccounts()
        }
    }
}
