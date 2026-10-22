import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    @objc func showConsoles() { selectPage(7); loadSystems() }

    @objc func showFinishing() { selectPage(5); loadPageData(5) }

    func updateSteamGuide() {
        let missing = report?.missing ?? []
        finishAdvice.stringValue = report?.issues.isEmpty != true
            ? "Your library still needs attention. Go back to storage before continuing."
            : missing.contains("steam")
            ? "Using ES-DE only? Skip Steam setup. Configure your selected emulators in App Store and add your ROMs in Game library."
            : "Steam is installed. The steps below happen in Steam; they are not changed by Couch Cube."
        if let drive = selected {
            let path = (drive.root as NSString).appendingPathComponent("SteamLibrary")
            steamStorageAdvice.stringValue = drive.mode == "local"
                ? "Sign in to Steam and use its existing Macintosh HD library. Open Steam Storage to choose the default install location. Couch Cube's folders are for retro games and launchers; existing Steam installs stay where they are."
                : "In Steam Storage → Add Drive, choose another location and select:\n\(path)\n\nCheck the path to identify your SSD. In its ••• menu, rename the Steam library Console Port if offered and choose Make Default. This is a Steam display name, not a disk rename. Use Steam's Move action for existing games.\n\nSteamCMD's force_install_dir does not configure the desktop client's default library. Couch Cube does not edit Steam's library database. Labels vary by Steam version."
            steamStorageAdvice.font = .systemFont(ofSize: 13)
            retroAdvice.stringValue = "In Steam desktop → Games → Add a Non-Steam Game to My Library → Browse, add:\n\(drive.root)/Launchers/Retro.app\n\nES-DE needs the emulators for the consoles you enabled, plus your own games and any BIOS/cores. Add registered game .app shortcuts from Launchers in the same way. Steam shortcuts are not added automatically."
        }
    }

    @objc func openWebsite() {
        if !NSWorkspace.shared.open(URL(string: "https://marosige.github.io/couch-cube/")!) {
            status.stringValue = "Couldn't open the website: https://marosige.github.io/couch-cube/"
            append(status.stringValue + "\n")
        }
    }

    @objc func openSteamStorage() {
        guard NSWorkspace.shared.open(URL(string: "steam://open/settings/storage")!) else {
            status.stringValue = "Couldn't open Steam Storage. Open Steam → Settings → Storage manually."
            append(status.stringValue + "\n")
            return
        }
    }

    @objc func refreshSteamStatus() {
        guard task == nil else {
            status.stringValue = "Wait for the current operation before refreshing Steam status."
            return
        }
        loadSteamStatus()
    }

    func steamStorageKind(_ library: SteamLibrary) -> String {
        guard library.available,
              let values = try? URL(fileURLWithPath: library.path).resourceValues(forKeys: [.volumeIsInternalKey]),
              let internalVolume = values.volumeIsInternal else { return "Storage type unknown" }
        return internalVolume ? "Local" : "External"
    }

    func libraryStorageMenu() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.addItem(withTitle: "")
        popup.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        for (title, symbol, action) in [("Check Library", "checkmark.circle", #selector(checkStorage))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            popup.menu?.addItem(item)
        }
        popup.bezelStyle = .inline
        popup.isBordered = false
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popup.toolTip = "Storage options"
        popup.setAccessibilityLabel("Storage options")
        popup.identifier = NSUserInterfaceItemIdentifier("library-storage-menu")
        popup.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return popup
    }

    func updateLibrarySummary() {
        var parts: [String] = []
        if let report = steamReport {
            let count = report.libraries.filter(\.available).reduce(0) { $0 + $1.games.filter(\.installed).count }
            parts.append(count == 1 ? "1 Steam game" : "\(count) Steam games")
        }
        let retro = consoleSystems.filter { $0.enabled && $0.emulator_installed != false }.count
        if !consoleSystems.isEmpty {
            parts.append(retro == 1 ? "1 retro console ready" : "\(retro) retro consoles ready")
        }
        librarySummary.stringValue = parts.isEmpty ? "Add a game with +, or install one in Steam." : parts.joined(separator: " · ")
    }

    func steamGameRow(_ game: SteamGame) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let name = text(game.name, size: 13)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let size = game.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let detail = text(game.installed ? (size ?? "Installed") : game.state + (size.map { " · " + $0 } ?? ""), size: 11, secondary: true)
        let labels = column([name, detail])
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, labels]
        if game.appid.allSatisfy(\.isNumber) {
            let manage = NSButton(title: "Manage", target: self, action: #selector(manageSteamGame(_:)))
            manage.bezelStyle = .rounded
            manage.controlSize = .small
            manage.identifier = NSUserInterfaceItemIdentifier(game.appid)
            manage.toolTip = "Open \(game.name) in Steam to manage, move or uninstall it"
            manage.setAccessibilityLabel("Manage \(game.name) in Steam")
            manage.setContentHuggingPriority(.required, for: .horizontal)
            views.append(manage)
        }
        if game.installed {
            let play = NSButton(title: "Play", target: self, action: #selector(playSteamGame(_:)))
            play.bezelStyle = .rounded
            play.controlSize = .small
            play.identifier = NSUserInterfaceItemIdentifier(game.appid)
            play.setAccessibilityLabel("Play \(game.name)")
            play.setContentHuggingPriority(.required, for: .horizontal)
            views.append(play)
        }
        let line = row(views)
        line.distribution = .fill
        line.spacing = 10
        line.identifier = NSUserInterfaceItemIdentifier("steam-game")
        return line
    }

    /// Steam's documented game details link; moving or uninstalling happens in Steam.
    @objc func manageSteamGame(_ sender: NSButton) {
        guard let appid = sender.identifier?.rawValue, appid.allSatisfy(\.isNumber),
              let url = URL(string: "steam://nav/games/details/" + appid) else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't open Steam"
            alert.informativeText = "Install or open Steam, then try again."
            alert.runModal()
        }
    }

    @objc func playSteamGame(_ sender: NSButton) {
        guard let appid = sender.identifier?.rawValue, appid.allSatisfy(\.isNumber),
              let url = URL(string: "steam://rungameid/" + appid) else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't start this game"
            alert.informativeText = "Open Steam, then try again."
            alert.runModal()
        }
    }

    func renderSteamLibraries() {
        updateLibrarySummary()
        for rows in [steamGuideRows] {
            clearRows(rows)
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 8
            func add(_ view: NSView) {
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            if overviewChecks.contains(.steam) {
                let checking = row([statusIndicator("Checking Steam libraries\u{2026}", color: .systemBlue, pulsing: true), NSView()])
                checking.distribution = .fill
                add(checking)
            }
            guard let report = steamReport else {
                add(text(overviewCheckFailures.contains(.steam) ? "Couldn't read Steam libraries. Open Activity for details." : "Steam libraries have not been checked yet.", size: 12, secondary: true))
                continue
            }
            for library in report.libraries {
                let count = library.games.filter { $0.installed }.count
                let label = selected.map { URL(fileURLWithPath: $0.root).appendingPathComponent("SteamLibrary").standardizedFileURL.path == URL(fileURLWithPath: library.path).standardizedFileURL.path } == true ? "Console Port · " : ""
                add(text(label + (library.available ? "\(steamStorageKind(library)) · \(count) games installed" : "Disconnected · Connect this drive"), size: 12))
                add(text(library.path, size: 11, secondary: true))
            }
            if !report.libraries.contains(where: { !$0.games.isEmpty }) && report.errors.isEmpty {
                add(text("No Steam games found yet. Open Steam to install your first game.", size: 12, secondary: true))
            }
            if !report.errors.isEmpty {
                add(text("Some games couldn't be checked. Open Steam, then refresh. Activity has technical details.", size: 11, secondary: true))
            }
            if overviewCheckFailures.contains(.steam) && report.errors.isEmpty {
                add(text("Refresh failed. Last results shown; see Activity.", size: 11, secondary: true))
            }
        }
    }

    func loadSteamStatus() {
        guard task == nil else { return }
        overviewChecks.insert(.steam)
        overviewCheckFailures.remove(.steam)
        renderSteamLibraries()
        renderGeneral()
        execute(["steam-status"], capture: true) { code, data in
            self.overviewChecks.remove(.steam)
            defer { self.renderSteamLibraries(); self.renderGeneral() }
            guard code == 0 else {
                self.overviewCheckFailures.insert(.steam)
                self.append("Couldn't read Steam libraries. " + self.lastError + "\n")
                return
            }
            do {
                let report = try JSONDecoder().decode(SteamLibraryReport.self, from: data)
                self.steamReport = report
                if !report.errors.isEmpty {
                    self.overviewCheckFailures.insert(.steam)
                    self.append(report.errors.joined(separator: "\n") + "\n")
                }
            } catch {
                self.overviewCheckFailures.insert(.steam)
                self.append("Couldn't decode Steam libraries: \(error.localizedDescription)\n")
            }
        }
    }

    @objc func openSteamDesktop() {
        guard report?.missing.contains("steam") == false else {
            status.stringValue = "Install Steam in App Store, then return to the Steam setup guide."
            showPlayers()
            return
        }
        if !NSWorkspace.shared.open(URL(string: "steam://open/main")!) {
            status.stringValue = "Couldn't open Steam. Check its installation in App Store."
        }
    }

    @objc func showSteamFolder() {
        guard let drive = selected else { return }
        let folder = URL(fileURLWithPath: drive.root).appendingPathComponent("SteamLibrary")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            status.stringValue = "Create your game folders in Game library before connecting Steam storage."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
