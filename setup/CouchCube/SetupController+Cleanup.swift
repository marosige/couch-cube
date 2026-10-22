import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    @objc func selectCleanupItems(_ sender: NSButton) {
        cleanupReviewChoices.forEach { $0.state = sender.state }
        updateCleanupSummary()
    }

    @objc func cleanupChoiceChanged(_ sender: NSButton) { updateCleanupSummary() }

    /// Opens the Clean up page (under App Settings) and scans what can be removed.
    @objc func reviewGamingCleanup() {
        guard task == nil, !cleanupInProgress else {
            status.stringValue = "Wait for the current operation to finish."
            return
        }
        selectPage(15)
        cleanupPlan = nil
        cleanupMessage = nil
        renderCleanup(scanning: true)
        execute(["cleanup-plan"], capture: true) { code, data in
            guard code == 0, let plan = try? JSONDecoder().decode(CleanupPlan.self, from: data) else {
                self.cleanupMessage = ("Couldn't scan for cleanup items. See Activity for details.", .systemRed)
                self.renderCleanup()
                return
            }
            self.cleanupPlan = plan
            self.renderCleanup()
        }
    }

    /// One cleanup row: checkbox, the item's own icon (or a category symbol), its name and where it is.
    func cleanupRow(_ item: CleanupItem, checkbox: NSButton) -> NSView {
        let symbol = item.category == "App" ? "app.fill" : item.name.lowercased().contains("setting") ? "gearshape.fill" : "folder.fill"
        let image = item.category == "App" && FileManager.default.fileExists(atPath: item.path)
            ? NSWorkspace.shared.icon(forFile: item.path) : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: (item.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = item.path
        for label in [name, path] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        checkbox.target = self
        checkbox.action = #selector(cleanupChoiceChanged(_:))
        checkbox.setAccessibilityLabel("\(item.name), \(item.path)")
        let line = NSStackView(views: [checkbox, icon, labels])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        return line
    }

    var selectedCleanupItems: [CleanupItem] {
        guard let plan = cleanupPlan else { return [] }
        return zip(plan.items, cleanupReviewChoices).filter { $0.1.state == .on }.map(\.0)
    }

    func renderCleanup(scanning: Bool = false) {
        clearRows(cleanupContent)
        cleanupReviewChoices = []
        func add(_ view: NSView) {
            cleanupContent.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: cleanupContent.widthAnchor).isActive = true
        }
        add(text("Choose what to remove from this Mac. Back up your saves first and quit games and launchers.", size: 13, secondary: true))
        guard let plan = cleanupPlan else {
            if let message = cleanupMessage {
                let label = text(message.text, size: 12)
                label.textColor = message.color
                add(card("", subtitle: nil, views: [label, button("Scan Again", #selector(reviewGamingCleanup))]))
            } else if scanning {
                add(card("", subtitle: nil, views: [statusIndicator("Looking for gaming apps and data\u{2026}", color: .systemBlue, pulsing: true)]))
            }
            return
        }
        guard !plan.items.isEmpty else {
            add(card("", subtitle: nil, views: [text("Nothing to clean up was found.", size: 13)]))
            return
        }
        let order = ["App", "Games and data", "Games"]
        let categories = Array(Set(plan.items.map(\.category)))
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
        var choiceFor: [String: NSButton] = [:]
        let selectAll = NSButton(checkboxWithTitle: "Select all", target: self, action: #selector(selectCleanupItems(_:)))
        selectAll.setAccessibilityIdentifier("cleanupSelectAll")
        add(row([selectAll, NSView(), button("Scan Again", #selector(reviewGamingCleanup))]))
        for category in categories {
            var views: [NSView] = []
            for item in plan.items where item.category == category {
                let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                choiceFor[item.id] = checkbox
                if !views.isEmpty { views.append(separator()) }
                views.append(cleanupRow(item, checkbox: checkbox))
            }
            add(card(category == "App" ? "Apps" : category, subtitle: nil, views: views))
        }
        cleanupReviewChoices = plan.items.map { choiceFor[$0.id]! }

        cleanupRemoveSelf.title = "Also move Couch Cube to the Trash"
        cleanupRemoveSelf.target = self
        cleanupRemoveSelf.action = #selector(cleanupChoiceChanged(_:))
        cleanupConfirmField.placeholderString = "Type REMOVE"
        cleanupConfirmField.stringValue = ""
        cleanupConfirmField.setAccessibilityLabel("Type REMOVE to confirm cleanup")
        cleanupConfirmField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        cleanupRemoveButton.title = "Remove"
        cleanupRemoveButton.bezelStyle = .rounded
        cleanupRemoveButton.hasDestructiveAction = true
        cleanupRemoveButton.bezelColor = .systemRed
        cleanupRemoveButton.target = self
        cleanupRemoveButton.action = #selector(runGamingCleanup)
        cleanupSummary.font = .systemFont(ofSize: 12)
        cleanupSummary.lineBreakMode = .byWordWrapping
        cleanupSummary.maximumNumberOfLines = 0
        let note = text("Apps are uninstalled; files go to the Trash (an external disk may delete them instead). Homebrew and Rosetta stay, and the Trash isn't emptied. Only what Couch Cube found is listed.",
                        size: 11, secondary: true)
        var views: [NSView] = [cleanupSummary, cleanupRemoveSelf, note, row([cleanupConfirmField, cleanupRemoveButton, NSView()])]
        if let message = cleanupMessage {
            let label = text(message.text, size: 12)
            label.textColor = message.color
            views.append(label)
        }
        add(card("Remove", subtitle: nil, views: views))
        updateCleanupSummary()
    }

    func updateCleanupSummary() {
        let names = selectedCleanupItems.map(\.name) + (cleanupRemoveSelf.state == .on ? ["Couch Cube"] : [])
        cleanupSummary.stringValue = names.isEmpty ? "Nothing selected yet." : "\(names.count) selected: " + names.joined(separator: ", ")
        cleanupRemoveButton.isEnabled = !names.isEmpty && !cleanupInProgress
    }

    @objc func runGamingCleanup() {
        guard let plan = cleanupPlan, !cleanupInProgress, task == nil else { return }
        let selected = selectedCleanupItems
        let removeSelf = cleanupRemoveSelf.state == .on
        func say(_ message: String, _ color: NSColor = .systemRed) {
            cleanupMessage = (message, color)
            renderCleanup()
        }
        guard cleanupConfirmField.stringValue == "REMOVE" else {
            say("Type REMOVE in the box to confirm.")
            return
        }
        guard !selected.isEmpty || removeSelf else { return }
        let gamingApps = Set(["Steam.app", "GOG Galaxy.app", "EA app.app", "Epic Games Launcher.app",
                              "Battle.net.app", "CurseForge.app", "ES-DE.app", "RetroArch.app",
                              "Dolphin.app", "Porting Kit.app", "CrossOver.app", "PCSX2.app",
                              "RPCS3.app", "Cemu.app", "Ryujinx.app"])
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL else { return false }
            return gamingApps.contains(url.lastPathComponent) ||
                selected.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
        }
        guard running.isEmpty else {
            say("Quit these first: " + running.map { $0.localizedName ?? "Gaming app" }.joined(separator: ", ") + ".")
            return
        }
        if selected.isEmpty {
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                DispatchQueue.main.async {
                    if let error { say("Couldn't move Couch Cube to the Trash: \(error.localizedDescription)") } else { NSApp.terminate(nil) }
                }
            }
            return
        }
        cleanupInProgress = true
        updateCleanupSummary()
        execute(["cleanup-prepare", "--confirm", "--token", plan.token, "--items"] + selected.map(\.id), capture: true) { code, data in
            guard code == 0, let targets = try? JSONDecoder().decode(CleanupTargets.self, from: data) else {
                self.cleanupInProgress = false
                say("Cleanup stopped. Some apps may already be uninstalled. Scan again to see what's left.")
                self.activityNeeded("Cleanup stopped.")
                return
            }
            var urls = targets.paths.map { URL(fileURLWithPath: $0) }
            if removeSelf { urls.append(Bundle.main.bundleURL) }
            func finished() {
                self.cleanupInProgress = false
                self.appsHaveResults = false
                self.consolesLoaded = false
                self.refresh()
                self.reviewGamingCleanup()
                self.cleanupMessage = ("Removed. The Trash wasn't emptied.", .systemGreen)
            }
            if urls.isEmpty { finished(); return }
            self.busy(true)
            NSWorkspace.shared.recycle(urls) { moved, error in
                DispatchQueue.main.async {
                    self.busy(false)
                    if let error {
                        self.cleanupInProgress = false
                        let remaining = urls.filter { moved[$0] == nil }.map(\.path).joined(separator: "\n")
                        self.append("Cleanup incomplete: \(error.localizedDescription)\nNot moved:\n" + remaining + "\n")
                        say("Cleanup incomplete: \(error.localizedDescription)")
                    } else if removeSelf {
                        NSApp.terminate(nil)
                    } else {
                        if let identifier = Bundle.main.bundleIdentifier,
                           targets.paths.contains(where: { $0.hasSuffix("/\(identifier).plist") }) {
                            UserDefaults.standard.removePersistentDomain(forName: identifier)
                        }
                        finished()
                    }
                }
            }
        }
    }

    @objc func uninstallCouchCube() {
        guard task == nil else { status.stringValue = "Wait for the current operation to finish."; return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Couch Cube?"
        alert.informativeText = "Moves Couch Cube to the Trash and removes its login settings. Your games, saves and other apps are kept."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["cleanup-host", "--confirm"]) { code, _ in
            guard code == 0 else { return }
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                DispatchQueue.main.async {
                    if let error = error { self.status.stringValue = "Settings removed, but couldn't move app to Trash: \(error.localizedDescription)" }
                    else { NSApp.terminate(nil) }
                }
            }
        }
    }
}
