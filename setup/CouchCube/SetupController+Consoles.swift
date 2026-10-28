import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func loadSystems() {
        if consoleSystems.isEmpty {
            consolesLoaded = false
            let catalog = [
                ("nes", "Nintendo Entertainment System"), ("snes", "Super Nintendo"),
                ("n64", "Nintendo 64"), ("gc", "GameCube"), ("wii", "Wii"),
                ("wiiu", "Wii U"), ("switch", "Nintendo Switch"),
                ("gb", "Game Boy"), ("gbc", "Game Boy Color"), ("gba", "Game Boy Advance"),
                ("nds", "Nintendo DS"), ("n3ds", "Nintendo 3DS"),
                ("psx", "PlayStation"), ("ps2", "PlayStation 2"),
                ("psp", "PlayStation Portable"), ("ps3", "PlayStation 3"),
                ("mastersystem", "Sega Master System"), ("megadrive", "Mega Drive / Genesis"), ("segacd", "Sega CD"),
                ("sega32x", "Sega 32X"), ("saturn", "Sega Saturn"), ("dreamcast", "Dreamcast"), ("gamegear", "Game Gear"),
                ("pcengine", "PC Engine / TurboGrafx-16"), ("neogeo", "Neo Geo"), ("arcade", "Arcade"), ("xbox", "Xbox")
            ]
            consoleSystems = catalog.map {
                let package = ["gc": "dolphin", "wii": "dolphin", "wiiu": "cemu-wiiu",
                               "switch": "switch", "ps2": "pcsx2", "ps3": "rpcs3", "n3ds": "azahar", "xbox": "xemu"][$0.0] ?? "retroarch-metal"
                return ConsoleSystem(id: $0.0, name: $0.1, enabled: false, package: package,
                                     requirement: "", bios: nil)
            }
        }
        consolesChecking = selected != nil && report?.state == "valid layout"
        // Refreshing already loaded consoles is silent: the rows stay as they are until real changes arrive.
        if !consolesLoaded { renderSystems() }
        if task != nil && consolesChecking {
            consoleRefreshPending = true
            return
        }
        guard task == nil, let root = consoleRoot(), report?.state == "valid layout" else {
            consolesChecking = false
            renderSystems()
            consoleStatus.stringValue = "Create game folders in Settings → Game library first. Wait for any current operation to finish."
            return
        }
        consoleRefreshPending = false
        consoleStatus.stringValue = ""
        consoleLoadGeneration += 1
        let generation = consoleLoadGeneration
        backendRead(["systems", "--root", root]) { code, data in
            guard generation == self.consoleLoadGeneration else { return }
            self.consolesChecking = false
            guard self.consoleRoot() == root else { return }
            guard code == 0 else {
                if !self.consolesLoaded { self.renderSystems() }
                self.consoleStatus.stringValue = "Couldn't read console selection. Choose View > Activity for details."
                self.append("Couldn't read console selection.\n")
                self.activityNeeded()
                return
            }
            do {
                self.acceptSystems(try JSONDecoder().decode([ConsoleSystem].self, from: data))
                self.renderGeneral()
                self.consoleStatus.stringValue = ""
            } catch {
                self.renderSystems()
                self.consoleStatus.stringValue = "Couldn't read consoles: \(error.localizedDescription)"
                self.append(self.consoleStatus.stringValue + "\n")
            }
        }
    }

    func renderSystems() {
        clearRows(consoleRows)
        systemSwitches = []
        systemStatusLines = []
        systemStoreLinks = []
        consoleBulkToggles = []
        let present = Set(consoleSystems.map(\.id))
        func ids(_ groups: [String]) -> Set<String> {
            Set(ConsoleArtwork.groups.filter { groups.contains($0.title) }.flatMap(\.systems)).intersection(present)
        }
        let order = ConsoleArtwork.groups.flatMap { $0.systems }
        consoleSystems.sort {
            (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100)
        }
        var manufacturerRows: [String: NSStackView] = [:]
        for manufacturer in ["Nintendo", "PlayStation", "SEGA", "Other"] {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
            manufacturerRows[manufacturer] = rows
            let groups = ConsoleArtwork.groups.map(\.title).filter { $0.hasPrefix(manufacturer) }
            let heading = consoleBulkRow(manufacturer, scope: manufacturer + " consoles", ids: ids(groups), size: 13)
            let box = card("", subtitle: nil, views: [heading, rows])
            consoleRows.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: consoleRows.widthAnchor).isActive = true
        }
        var previousGroup = ""
        for (index, system) in consoleSystems.enumerated() {
            let group = ConsoleArtwork.groups.first { $0.systems.contains(system.id) }?.title ?? "Other systems"
            let manufacturer = ["Nintendo", "PlayStation", "SEGA", "Other"].first { group.hasPrefix($0) } ?? group
            guard let rows = manufacturerRows[manufacturer] else { continue }
            if group != previousGroup {
                do {
                    // Every company card splits into Home consoles and Handhelds.
                    let title = group.hasSuffix("home consoles") ? "Home consoles" : "Handhelds"
                    let heading = text(title, size: 12, secondary: true)
                    heading.font = .systemFont(ofSize: 12, weight: .semibold)
                    let container = NSView()
                    heading.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(heading)
                    NSLayoutConstraint.activate([
                        heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                        heading.topAnchor.constraint(equalTo: container.topAnchor, constant: rows.arrangedSubviews.isEmpty ? 4 : 18),
                        heading.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
                    ])
                    rows.addArrangedSubview(container)
                    container.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                }
                previousGroup = group
            } else {
                let separator = NSBox()
                separator.boxType = .separator
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = system.enabled ? .on : .off
            toggle.isEnabled = consolesLoaded
            toggle.target = self
            toggle.action = #selector(toggleSystem(_:))
            toggle.setAccessibilityLabel(system.name)
            systemSwitches.append(toggle)
            let info = button("", #selector(showConsoleDetails(_:)))
            info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Details for \(system.name)")
            info.isBordered = false
            info.tag = index
            info.toolTip = "Details"
            info.setAccessibilityLabel("Details for \(system.name)")
            // The store shortcut only shows while the emulator is missing; Details always has it.
            let store = appStoreLink(for: system)
            systemStoreLinks.append(store)
            let controls = row([store, info, toggle])
            let statusLine = row([])
            statusLine.distribution = .fill
            systemStatusLines.append(statusLine)
            fillSystemStatus(statusLine, system)
            let line = settingsRow(system.name,
                subtitle: "",
                symbol: "gamecontroller.fill", color: .secondaryLabelColor, trailing: controls,
                artwork: ConsoleArtwork.image(for: system.id), detail: statusLine, bareArtwork: true)
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        }
        updateConsoleBulkToggles()
    }

    /// A heading with a trailing switch for every console beneath it; "3 of 7" marks a mixed group.
    func consoleBulkRow(_ title: String, scope: String, ids: Set<String>, size: CGFloat) -> NSStackView {
        let heading = text(title, size: size, secondary: size < 13)
        heading.font = .systemFont(ofSize: size, weight: .semibold)
        let count = text("", size: 11, secondary: true)
        count.identifier = NSUserInterfaceItemIdentifier("console-bulk-count")
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleConsoleGroup(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier("console-bulk")
        consoleBulkToggles.append((toggle, count, ids, scope))
        let line = row([heading, NSView(), count, toggle])
        line.distribution = .fill
        return line
    }

    /// On only when every console beneath is shown; a mixed group shows Off plus a count, so a click shows all.
    func updateConsoleBulkToggles() {
        let enabled = Set(consoleSystems.filter(\.enabled).map(\.id))
        for bulk in consoleBulkToggles {
            let shown = bulk.ids.intersection(enabled).count, total = bulk.ids.count
            let mixed = shown > 0 && shown < total
            bulk.toggle.state = total > 0 && shown == total ? .on : .off
            bulk.toggle.isEnabled = consolesLoaded && total > 0
            bulk.count.stringValue = mixed ? "\(shown) of \(total)" : ""
            bulk.count.isHidden = !mixed
            let state = shown == total ? "all \(total) shown" : shown == 0 ? "all hidden" : "\(shown) of \(total) shown"
            let action = shown == total ? "Hide" : "Show"
            bulk.toggle.setAccessibilityLabel("Show all \(bulk.scope), \(state)")
            bulk.toggle.toolTip = "\(action) all \(bulk.scope) (\(state))"
        }
    }

    /// Same fast path as single switches: rows update in place and one debounced save covers the whole batch.
    /// Showing consoles never installs emulators or asks to.
    @objc func toggleConsoleGroup(_ sender: NSSwitch) {
        guard consolesLoaded, let bulk = consoleBulkToggles.first(where: { $0.toggle === sender }),
              systemSwitches.count == consoleSystems.count else {
            updateConsoleBulkToggles()
            consoleStatus.stringValue = "Wait until your consoles are loaded."
            return
        }
        if esdeRunning {
            updateConsoleBulkToggles()
            consoleStatus.stringValue = "Quit ES-DE first. It must not overwrite updated frontend settings."
            return
        }
        let show = sender.state == .on
        if consolePersistedEnabled == nil { consolePersistedEnabled = Set(consoleSystems.filter(\.enabled).map(\.id)) }
        var changed = false
        for index in consoleSystems.indices where bulk.ids.contains(consoleSystems[index].id) && consoleSystems[index].enabled != show {
            consoleSystems[index].enabled = show
            systemSwitches[index].state = show ? .on : .off
            fillSystemStatus(systemStatusLines[index], consoleSystems[index])
            changed = true
        }
        updateConsoleBulkToggles()
        guard changed else { return }
        consoleEditGeneration += 1
        scheduleConsoleSave()
    }

    func fillSystemStatus(_ statusLine: NSStackView, _ system: ConsoleSystem) {
        statusLine.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let index = systemStatusLines.firstIndex(where: { $0 === statusLine }), systemStoreLinks.indices.contains(index) {
            systemStoreLinks[index].isHidden = emulatorInstalled(system) == true
        }
        let emulator = emulatorStatus(system)
        let initialCheck = consolesChecking && !consolesLoaded
        var indicators: [NSView] = [statusIndicator(initialCheck ? emulatorName(system) : emulator.title,
            color: initialCheck ? .systemBlue : emulator.color, pulsing: initialCheck)]
        if system.enabled, let bios = system.bios, bios.state != "not-needed" {
            indicators.append(initialCheck
                ? statusIndicator("BIOS", color: .systemBlue, pulsing: true)
                : biosIndicator(bios))
        }
        indicators.append(NSView())
        indicators.forEach(statusLine.addArrangedSubview)
        statusLine.toolTip = emulator.help
    }

    /// Takes a fresh status read, keeping unsaved toggles, and updates rows in place when the list is already shown.
    func acceptSystems(_ fresh: [ConsoleSystem]) {
        var systems = fresh
        consolePersistedEnabled = Set(systems.filter(\.enabled).map(\.id))
        if consoleSaveInFlight || consoleSaveTimer != nil || consoleSaveDirty {
            let intent = Dictionary(uniqueKeysWithValues: consoleSystems.map { ($0.id, $0.enabled) })
            systems = systems.map { system in
                var system = system
                system.enabled = intent[system.id] ?? system.enabled
                return system
            }
        }
        let wasLoaded = consolesLoaded
        consolesLoaded = true
        if !(wasLoaded && applySystemsInPlace(systems)) {
            consoleSystems = systems
            renderSystems()
        }
    }

    /// Updates switches and status lines without rebuilding the list, so scroll position and focus stay put.
    @discardableResult
    func applySystemsInPlace(_ systems: [ConsoleSystem]) -> Bool {
        guard systemSwitches.count == consoleSystems.count, systemStatusLines.count == consoleSystems.count,
              Set(systems.map(\.id)) == Set(consoleSystems.map(\.id)), systems.count == consoleSystems.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: systems.map { ($0.id, $0) })
        consoleSystems = consoleSystems.map { byID[$0.id]! }
        for (index, system) in consoleSystems.enumerated() {
            systemSwitches[index].state = system.enabled ? .on : .off
            systemSwitches[index].isEnabled = consolesLoaded
            fillSystemStatus(systemStatusLines[index], system)
        }
        updateConsoleBulkToggles()
        return true
    }

    func emulatorName(_ system: ConsoleSystem) -> String {
        ["retroarch-metal": "RetroArch", "cemu-wiiu": "Cemu", "switch": "Ryujinx",
         "pcsx2": "PCSX2", "rpcs3": "RPCS3", "dolphin": "Dolphin", "azahar": "Azahar", "xemu": "xemu"][system.package] ?? system.package
    }

    /// Whether the console's emulator is on this Mac; nil until it has been checked.
    func emulatorInstalled(_ system: ConsoleSystem) -> Bool? {
        let app = appsHaveResults ? appStates.first { $0.id == system.package } : nil
        return system.emulator_installed ?? app?.installed ?? report.map { !$0.missing.contains(system.package) }
    }

    func emulatorStatus(_ system: ConsoleSystem) -> (title: String, color: NSColor, help: String) {
        let name = emulatorName(system)
        guard system.enabled else { return (name, .systemGray, "Hidden from your game menu.") }
        let app = appsHaveResults ? appStates.first { $0.id == system.package } : nil
        let installed = emulatorInstalled(system)
        guard let installed = installed else { return (name, .systemGray, "Emulator not checked yet.") }
        guard installed else { return (name, .systemRed, "\(name) · Not installed. Install it in App Store.") }
        if app?.managed == true, app?.update?.isEmpty == false {
            return ("\(name) · Update available", .systemYellow, "\(name) · Update available in App Store.")
        }
        return (name, .systemGreen, "\(name) · Installed.")
    }

    func consoleReadiness(_ system: ConsoleSystem) -> (color: NSColor, help: String) {
        guard system.enabled else { return (.systemGray, "Hidden from your game menu. Switch on to check setup.") }
        let installed = system.emulator_installed ??
            report.map { !$0.missing.contains(system.package) } ??
            appStates.first(where: { $0.id == system.package })?.installed
        guard let installed = installed else { return (.systemGray, "Emulator not checked yet. Reopen Consoles to refresh.") }
        guard installed else { return (.systemRed, "Install \(emulatorName(system)) in App Store, then return here.") }
        guard let bios = system.bios else { return (.systemGray, "Emulator installed. Reopen Consoles to check BIOS requirements.") }
        switch bios.state {
        case "present", "not-needed": return (.systemGreen, "Emulator ready. Add your own games in Game library.")
        case "optional": return (.systemYellow, "BIOS recommended. A fallback is available; open help for optional filenames.")
        case "missing", "partial": return (.systemRed, "Required BIOS files are missing. Open help to copy filenames and see where they go.")
        default: return (.systemGray, bios.summary + ". Open the emulator to check its setup.")
        }
    }

    func biosIndicator(_ bios: BIOSStatus) -> NSView {
        let color: NSColor = bios.state == "present" || bios.state == "not-needed" ? .systemGreen :
            bios.state == "missing" || bios.state == "partial" ? .systemRed : bios.state == "manual" ? .systemGray : .systemYellow
        let title = bios.state == "optional" ? "BIOS recommended · Fallback available" :
            bios.state == "manual" ? "BIOS · Check in emulator" : "BIOS"
        let view = statusIndicator(title, color: color)
        view.toolTip = bios.summary
        return view
    }

    func biosStatusView(_ bios: BIOSStatus, searchQuery: String? = nil) -> NSView {
        let indicator = row([biosIndicator(bios), NSView()])
        indicator.distribution = .fill
        let missing = bios.files.filter { !$0.present }
        guard !missing.isEmpty && bios.state != "present" else { return indicator }
        var sections: [NSView] = [indicator]
        var folders: [String] = []
        for file in missing {
            let folder = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
            if !folders.contains(folder) { folders.append(folder) }
        }
        for folder in folders {
            var shown = folder
            if let root = selected?.root, folder.hasPrefix(root) {
                shown = URL(fileURLWithPath: root).lastPathComponent + folder.dropFirst(root.count)
            }
            let place = row([text("Put in", size: 11, secondary: true),
                             pill(shown, symbol: "folder", action: #selector(openBIOSFolder(_:)),
                                  value: folder, help: "Open " + folder), NSView()])
            place.distribution = .fill
            let names = missing.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == folder }
                .map { URL(fileURLWithPath: $0.filename).lastPathComponent }
            let fileRows = NSStackView()
            fileRows.orientation = .vertical
            fileRows.alignment = .leading
            fileRows.spacing = 4
            for start in stride(from: 0, to: names.count, by: 3) {
                fileRows.addArrangedSubview(row(names[start..<min(start + 3, names.count)].map {
                    pill($0, symbol: "doc.on.doc", action: #selector(copyBIOSNames(_:)), value: $0,
                         help: "Copy filename " + $0)
                }))
            }
            let files = row([text("Files", size: 11, secondary: true), fileRows, NSView()])
            files.distribution = .fill
            files.alignment = .top
            sections.append(column([place, files]))
        }
        if let query = searchQuery {
            let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
            glass.contentTintColor = .secondaryLabelColor
            glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            let phrase = text("Search online for \u{201C}\(query)\u{201D}", size: 11, secondary: true)
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyBIOSNames(_:)))
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            copy.font = .systemFont(ofSize: 11)
            copy.identifier = NSUserInterfaceItemIdentifier(query)
            copy.toolTip = "Copy search phrase: " + query
            copy.setAccessibilityLabel(copy.toolTip)
            let search = row([glass, phrase, copy, NSView()])
            search.spacing = 6
            search.distribution = .fill
            sections.append(search)
        }
        let result = column(sections)
        result.spacing = 8
        return result
    }

    /// Small inline link used for BIOS and library folders; the identifier carries the value.
    func pill(_ title: String, symbol: String, action: Selector, value: String, help: String) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        control.imagePosition = .imageLeading
        control.bezelStyle = .inline
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.identifier = NSUserInterfaceItemIdentifier(value)
        control.toolTip = help
        control.setAccessibilityLabel(help)
        return control
    }

    @objc func openBIOSFolder(_ sender: NSButton) {
        guard var url = sender.identifier.map({ URL(fileURLWithPath: $0.rawValue) }) else { return }
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(url)
    }

    @objc func copyBIOSNames(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(value, forType: .string) else {
            append("Couldn't copy \(value). Try again.\n")
            return
        }
        let title = sender.title, image = sender.image
        sender.title = "Copied"
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = title
            sender?.image = image
        }
    }

    /// Applies the switch immediately; saving is debounced, serialized and off the main thread so toggles never wait.
    @objc func toggleSystem(_ sender: NSSwitch) {
        guard consolesLoaded, let index = systemSwitches.firstIndex(of: sender), index < consoleSystems.count else {
            consoleStatus.stringValue = "Wait until your consoles are loaded."
            return
        }
        if esdeRunning {
            sender.state = consoleSystems[index].enabled ? .on : .off
            consoleStatus.stringValue = "Quit ES-DE first. It must not overwrite updated frontend settings."
            return
        }
        if consolePersistedEnabled == nil { consolePersistedEnabled = Set(consoleSystems.filter(\.enabled).map(\.id)) }
        consoleSystems[index].enabled = sender.state == .on
        consoleEditGeneration += 1
        fillSystemStatus(systemStatusLines[index], consoleSystems[index])
        updateConsoleBulkToggles()
        if sender.state == .on {
            let system = consoleSystems[index]
            let app = appStates.first { $0.id == system.package }
            if (system.emulator_installed ?? app?.installed) == false {
                let name = emulatorName(system)
                let alert = NSAlert()
                alert.messageText = "Install \(name)?"
                alert.informativeText = "\(system.name) needs \(name) to play games."
                alert.addButton(withTitle: "Install \(name)")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() == .alertFirstButtonReturn {
                    if appsHaveResults, let app = app, !app.manual { pendingEmulatorInstall = app }
                    else { pendingAppStoreID = system.package }
                }
            }
        }
        scheduleConsoleSave()
    }

    func scheduleConsoleSave() {
        consoleStatus.stringValue = ""
        consoleSaveTimer?.invalidate()
        consoleSaveTimer = Timer.scheduledTimer(withTimeInterval: consoleSaveDelay, repeats: false) { [weak self] _ in
            self?.consoleSaveTimer = nil
            self?.saveSystems()
        }
    }

    @objc func saveSystems() {
        consoleSaveTimer?.invalidate()
        consoleSaveTimer = nil
        if consoleSaveInFlight {
            consoleSaveDirty = true
            return
        }
        // Wait for other changes to the library (setup, cleanup, installs); the save restarts when they finish.
        if (task != nil && !ProcessInfo.processInfo.arguments.contains("--smoke-test")) || cleanupInProgress {
            consoleSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.consoleSaveTimer = nil
                self?.saveSystems()
            }
            return
        }
        guard let root = consoleRoot(), !consoleSystems.isEmpty else {
            revertConsoleSelection("Load your console selection first. Create game folders in Settings → Game library if needed.")
            return
        }
        if esdeRunning {
            revertConsoleSelection("Quit ES-DE first. It must not overwrite updated frontend settings.")
            return
        }
        let enabled = consoleSystems.filter(\.enabled).map(\.id)
        consoleSaveInFlight = true
        consoleSaveDirty = false
        consoleSaver(root, enabled) { code, errors in
            self.consoleSaveInFlight = false
            guard code == 0 else {
                if !errors.isEmpty { self.append(errors) }
                self.revertConsoleSelection("Couldn't save console selection. Your last saved choices are shown. Open Activity for details.")
                self.activityNeeded()
                return
            }
            self.consolePersistedEnabled = Set(enabled)
            if self.consoleSaveDirty || self.consoleSaveTimer != nil {
                if self.consoleSaveTimer == nil { self.saveSystems() }
                return
            }
            if let app = self.pendingEmulatorInstall {
                self.pendingEmulatorInstall = nil
                self.manage(app, action: "install")
            } else if let id = self.pendingAppStoreID {
                self.pendingAppStoreID = nil
                self.showAppInStore(id)
            }
            self.refreshConsoleStatusInPlace(root: root)
        }
    }

    func revertConsoleSelection(_ message: String) {
        consoleSaveTimer?.invalidate()
        consoleSaveTimer = nil
        consoleSaveDirty = false
        consoleEditGeneration += 1
        pendingEmulatorInstall = nil
        pendingAppStoreID = nil
        if let persisted = consolePersistedEnabled {
            applySystemsInPlace(consoleSystems.map { system in
                var system = system
                system.enabled = persisted.contains(system.id)
                return system
            })
        }
        consoleStatus.stringValue = message
        append(message + "\n")
    }

    /// Reads BIOS/emulator status after a save and merges it into the rows; ignored if newer toggles happened meanwhile.
    func refreshConsoleStatusInPlace(root: String) {
        let generation = consoleEditGeneration
        consoleRefresher(root) { code, data in
            guard generation == self.consoleEditGeneration, !self.consoleSaveInFlight, self.consoleSaveTimer == nil else { return }
            guard code == 0, let systems = try? JSONDecoder().decode([ConsoleSystem].self, from: data) else {
                self.consoleStatus.stringValue = "Saved. Couldn't refresh console status; reopen Retro consoles to check again."
                return
            }
            self.consolePersistedEnabled = Set(systems.filter(\.enabled).map(\.id))
            if !self.applySystemsInPlace(systems) {
                self.consoleSystems = systems
                self.renderSystems()
            }
            self.renderGeneral()
        }
    }
}
