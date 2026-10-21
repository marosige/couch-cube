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
        cleanupReviewChoices.forEach { $0.state = sender.tag == 1 ? .on : .off }
    }

    @objc func reviewGamingCleanup() {
        guard task == nil, !cleanupInProgress else {
            status.stringValue = "Wait for the current operation to finish."
            return
        }
        execute(["cleanup-plan"], capture: true) { code, data in
            guard code == 0 else { self.activityNeeded("Couldn't scan for cleanup items."); return }
            do {
                let plan = try JSONDecoder().decode(CleanupPlan.self, from: data)
                self.presentGamingCleanup(plan)
            } catch {
                self.status.stringValue = "Couldn't read cleanup items: \(error.localizedDescription)"
                self.append(self.status.stringValue + "\n")
                self.activityNeeded(self.status.stringValue)
            }
        }
    }

    func presentGamingCleanup(_ plan: CleanupPlan) {
        let alert = NSAlert()
        alert.messageText = "Clean up gaming setup"
        alert.informativeText = "Select what to remove, including anything installed before Couch Cube. Back up first and quit all games and launchers.\n\nGame data includes saves, BIOS, addons and Windows bottles. Removing Couch Cube settings also disables automatic console mode.\n\nOnly detected locations are listed. Custom folders, other accounts and disconnected drives are not scanned. Homebrew, shared dependencies and Rosetta are kept. Trash is not emptied."
        alert.addButton(withTitle: "Continue...")
        alert.addButton(withTitle: "Cancel")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        var choices: [NSButton] = []
        for item in plan.items {
            let checkbox = NSButton(checkboxWithTitle: "\(item.name) (\(item.category))", target: nil, action: nil)
            checkbox.state = .off
            choices.append(checkbox)
            list.addArrangedSubview(checkbox)
            let path = NSTextField(wrappingLabelWithString: item.path)
            path.font = .systemFont(ofSize: 11)
            path.textColor = .secondaryLabelColor
            path.isSelectable = true
            path.widthAnchor.constraint(equalToConstant: 550).isActive = true
            list.addArrangedSubview(path)
        }
        let removeSelf = NSButton(checkboxWithTitle: "Also move this copy of Couch Cube to Trash", target: nil, action: nil)
        list.addArrangedSubview(removeSelf)
        cleanupReviewChoices = choices
        defer { cleanupReviewChoices = [] }
        let selectAll = NSButton(title: "Select all detected items", target: self, action: #selector(selectCleanupItems(_:)))
        selectAll.tag = 1
        let deselectAll = NSButton(title: "Deselect all", target: self, action: #selector(selectCleanupItems(_:)))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 360))
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            list.widthAnchor.constraint(equalToConstant: 560)
        ])
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = column([row([selectAll, deselectAll]), scroll])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = zip(plan.items, choices).filter { $0.1.state == .on }.map { $0.0 }
        guard !selected.isEmpty else {
            status.stringValue = "No cleanup items selected. Use Uninstall to remove only Couch Cube."
            return
        }
        let gamingApps = Set(["Steam.app", "FX Steam Launcher.app", "GOG Galaxy.app", "EA app.app", "Epic Games Launcher.app",
                              "Battle.net.app", "CurseForge.app", "ES-DE.app", "RetroArch.app",
                              "Dolphin.app", "Porting Kit.app", "CrossOver.app", "PCSX2.app",
                              "RPCS3.app", "Cemu.app", "Ryujinx.app"])
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL else { return false }
            return gamingApps.contains(url.lastPathComponent) ||
                selected.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
        }
        guard running.isEmpty else {
            let warning = NSAlert()
            warning.messageText = "Quit gaming apps first"
            warning.informativeText = running.map { $0.localizedName ?? "Gaming app" }.joined(separator: ", ")
            warning.runModal()
            return
        }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Remove \(selected.count) selected items?"
        confirmation.informativeText = "Homebrew-managed apps will be uninstalled. Other selected files move to Trash where supported; macOS may report that an external disk cannot use Trash. Recovery of uninstalled apps or unsynced saves is not guaranteed.\n\nType REMOVE to confirm."
        let summary = NSTextView(frame: NSRect(x: 0, y: 0, width: 550, height: 180))
        summary.isEditable = false
        summary.font = .systemFont(ofSize: 12)
        summary.isVerticallyResizable = true
        summary.maxSize = NSSize(width: 550, height: CGFloat.greatestFiniteMagnitude)
        summary.textContainer?.widthTracksTextView = true
        summary.string = selected.map { "\($0.name)\n\($0.path)" }.joined(separator: "\n\n") +
            (removeSelf.state == .on ? "\n\nCouch Cube\n\(Bundle.main.bundleURL.path)" : "")
        let summaryScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 550, height: 180))
        summaryScroll.hasVerticalScroller = true
        summaryScroll.documentView = summary
        summaryScroll.widthAnchor.constraint(equalToConstant: 550).isActive = true
        summaryScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let typed = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        typed.setAccessibilityLabel("Type REMOVE to confirm cleanup")
        confirmation.accessoryView = column([summaryScroll, typed])
        confirmation.addButton(withTitle: "Remove selected items")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn, typed.stringValue == "REMOVE" else { return }
        var arguments = ["cleanup-prepare", "--confirm", "--token", plan.token, "--items"]
        arguments += selected.map(\.id)
        execute(arguments, capture: true) { code, data in
            guard code == 0 else {
                self.status.stringValue = "Cleanup stopped. Some apps may already be uninstalled. Review Activity and scan again."
                self.activityNeeded(self.status.stringValue)
                return
            }
            do {
                let targets = try JSONDecoder().decode(CleanupTargets.self, from: data)
                var urls = targets.paths.map { URL(fileURLWithPath: $0) }
                if removeSelf.state == .on { urls.append(Bundle.main.bundleURL) }
                if urls.isEmpty {
                    self.status.stringValue = "Selected apps removed. Shared dependencies and unselected data were kept."
                    self.appsHaveResults = false
                    self.consolesLoaded = false
                    self.refresh()
                    return
                }
                self.cleanupInProgress = true
                self.busy(true)
                NSWorkspace.shared.recycle(urls) { moved, error in
                    DispatchQueue.main.async {
                        self.cleanupInProgress = false
                        self.busy(false)
                        if let error = error {
                            let remaining = urls.filter { moved[$0] == nil }.map(\.path).joined(separator: "\n")
                            self.status.stringValue = "Cleanup incomplete: \(error.localizedDescription)"
                            self.append(self.status.stringValue + "\nNot moved:\n" + remaining + "\n")
                            self.activityNeeded(self.status.stringValue)
                        } else if removeSelf.state == .on {
                            NSApp.terminate(nil)
                        } else {
                            if let identifier = Bundle.main.bundleIdentifier,
                               targets.paths.contains(where: { $0.hasSuffix("/\(identifier).plist") }) {
                                UserDefaults.standard.removePersistentDomain(forName: identifier)
                            }
                            self.status.stringValue = "Selected items removed. Trash was not emptied. Unselected and undetected items were kept."
                            self.appsHaveResults = false
                            self.consolesLoaded = false
                            self.refresh()
                        }
                    }
                }
            } catch {
                self.status.stringValue = "Cleanup stopped after app removal: \(error.localizedDescription)"
                self.append(self.status.stringValue + "\n")
                self.activityNeeded(self.status.stringValue)
            }
        }
    }

    @objc func uninstallCouchCube() {
        guard task == nil else { status.stringValue = "Wait for the current operation to finish."; return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Couch Cube?"
        alert.informativeText = "Moves this copy of Couch Cube to Trash and removes its saved Mac selection, login entry and login log. Games, ROMs, BIOS, saves, other installed apps and game-library folders are kept. You can remove other apps individually in App Store."
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
