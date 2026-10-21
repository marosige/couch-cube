import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func pageHeading(_ title: String, _ subtitle: String) -> NSStackView {
        column([text(subtitle, size: 13, secondary: true)])
    }

    func primary(_ button: NSButton) -> NSButton {
        button.bezelStyle = .rounded
        button.isBordered = true
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    func choice(_ title: String, _ description: String, symbol: String, action: Selector) -> NSView {
        let choose = StorageChoiceButton(title: "", target: self, action: action)
        choose.isBordered = false
        choose.setButtonType(.momentaryChange)
        choose.focusRingType = .exterior
        actions.append(choose)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let heading = text(title)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = column([heading, text(description, size: 12, secondary: true)])
        labels.spacing = 4
        let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let content = row([icon, labels, arrow])
        content.distribution = .fill
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        choose.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: choose.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: choose.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: choose.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: choose.bottomAnchor, constant: -12),
            choose.heightAnchor.constraint(greaterThanOrEqualToConstant: 68)
        ])
        choose.setAccessibilityLabel(title + ". " + description.replacingOccurrences(of: "\n", with: " "))
        return choose
    }

    func storageMode(_ mode: String) -> (mode: String, title: String, symbol: String) {
        Self.storageModes.first { $0.mode == mode } ?? Self.storageModes[1]
    }

    func storageModeIcon(_ view: NSImageView, mode: String) {
        view.image = NSImage(systemSymbolName: storageMode(mode).symbol, accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        view.contentTintColor = .secondaryLabelColor
    }

    func selectedStorageView() -> NSView {
        selectedStorageIcon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        selectedStorageIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        selectedStorageIcon.setContentHuggingPriority(.required, for: .horizontal)
        selectedStorageIcon.identifier = NSUserInterfaceItemIdentifier("library-storage-icon")
        selectedStorageMode.font = .systemFont(ofSize: 13, weight: .medium)
        selectedStorageMode.identifier = NSUserInterfaceItemIdentifier("library-storage-mode")
        selectedStorage.font = .systemFont(ofSize: 12)
        selectedStorage.textColor = .secondaryLabelColor
        selectedStorage.lineBreakMode = .byTruncatingMiddle
        selectedStorage.maximumNumberOfLines = 2
        selectedStorage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = column([selectedStorageMode, selectedStorage])
        labels.spacing = 4
        labels.setHuggingPriority(.init(1), for: .horizontal)
        let line = row([selectedStorageIcon, labels])
        line.spacing = 12
        line.distribution = .fill
        storageModeIcon(selectedStorageIcon, mode: "local")
        return line
    }

    /// Game library shows the same mode, icon and "· Active" marker as the Library Settings tiles.
    func updateSelectedStorageMarker() {
        guard let mode = selected?.mode ?? preferredMode else {
            selectedStorageIcon.isHidden = true
            selectedStorageMode.stringValue = "No storage selected"
            return
        }
        selectedStorageIcon.isHidden = false
        storageModeIcon(selectedStorageIcon, mode: mode)
        let marker: String
        if let drive = selected {
            let active = storageStatus.flatMap { storage in storage.locations.first {
                $0.drive.id == storage.active?.id && $0.drive.uuid == storage.active?.uuid && $0.configured
            } }
            marker = active?.drive.id == drive.id && active?.drive.uuid == drive.uuid ? " · Active" : ""
        } else {
            marker = " · Disconnected"
        }
        selectedStorageMode.stringValue = storageMode(mode).title + marker
        selectedStorageIcon.setAccessibilityLabel(selectedStorageMode.stringValue)
    }

    @objc func chooseLocal() { chooseMode("local") }
    @objc func choosePortable() { chooseMode("portable") }

    func renderStorageLocations() {
        updateSelectedStorageMarker()
        renderStorageOverview()
        if driveDetailID != nil {
            renderDriveDetail()
            if currentPage == 12 && detailDrive != nil { loadDriveDetail() }
        }
        guard let storage = storageStatus else {
            setupFolderStatus.stringValue = "Reading available storage..."
            transferLibraryButton.isEnabled = false
            return
        }
        let active = storage.locations.first {
            $0.drive.id == storage.active?.id && $0.drive.uuid == storage.active?.uuid && $0.configured
        }
        if let transfer = storage.transfer, let active = active {
            lastLibraryTransfer = (transfer, active.drive.id)
        }
        if let active = active {
            setupFolderStatus.stringValue = "Active · \(active.drive.mode == "local" ? "This Mac" : active.drive.name)\n\(active.drive.root)"
        } else if storage.active != nil {
            setupFolderStatus.stringValue = "Your active library is disconnected or needs setup. Reconnect its drive, or choose another location."
        } else if storage.locations.contains(where: \.configured) {
            setupFolderStatus.stringValue = "Choose an existing library to activate it, or set up another location. No files are moved when switching."
        } else {
            setupFolderStatus.stringValue = "Where should your game files live? Choose this Mac or an external SSD to set up your first library."
        }
        setupFolderStatus.isHidden = active != nil
        transferLibraryButton.isEnabled = task == nil && active != nil &&
            storage.locations.contains { $0.drive.id != active?.drive.id }
        transferLibraryButton.toolTip = active == nil ? "Set up or activate a library first." : "Transfer the active Couch Cube library to another drive."
        retireLibraryButton.isHidden = lastLibraryTransfer == nil
        retireLibraryButton.isEnabled = task == nil && lastLibraryTransfer != nil
    }

    func driveTitle(_ drive: Drive) -> String {
        drive.mode == "local" ? "This Mac" : drive.name.replacingOccurrences(of: " (portable console)", with: "")
    }

    /// One shared model for Game library and Library storage: This Mac, every connected drive, and honest placeholders.
    func storageOverviewEntries() -> [StorageOverviewEntry] {
        guard let storage = storageStatus else {
            return [StorageOverviewEntry(id: nil, mode: "local", title: "This Mac", state: "checking", active: false, path: nil),
                    StorageOverviewEntry(id: nil, mode: "portable", title: "External SSD", state: "checking", active: false, path: nil)]
        }
        var entries: [StorageOverviewEntry] = []
        var activeFound = false
        for mode in ["local", "portable"] {
            for location in storage.locations where location.drive.mode == mode {
                let drive = location.drive
                let state = location.environment ?? (location.configured ? "ready" : "absent")
                let active = storage.active.map { $0.id == drive.id && $0.uuid == drive.uuid } ?? false
                activeFound = activeFound || active
                entries.append(StorageOverviewEntry(id: drive.id, mode: mode, title: driveTitle(drive), state: state,
                                                    active: active && state == "ready", path: drive.root))
            }
        }
        if storage.active != nil && !activeFound {
            entries.append(StorageOverviewEntry(id: nil, mode: "portable", title: "Active library", state: "disconnected", active: true, path: nil))
        }
        if !entries.contains(where: { $0.mode == "portable" && $0.id != nil }) {
            entries.append(StorageOverviewEntry(id: nil, mode: "portable", title: "External SSD", state: "connect", active: false, path: nil))
        }
        return entries
    }

    func storageStateLabel(_ entry: StorageOverviewEntry) -> (text: String, symbol: String?, color: NSColor) {
        switch entry.state {
        case "ready": return ("Ready" + (entry.active ? " · Active" : ""), "checkmark.circle.fill", .systemGreen)
        case "absent": return ("Not set up", "plus.circle.fill", .systemGray)
        case "occupied": return ("Not set up · A Couch Cube folder is already there", "exclamationmark.circle.fill", .systemOrange)
        case "invalid": return ("Needs attention", "exclamationmark.triangle.fill", .systemOrange)
        case "disconnected": return ("Disconnected · Reconnect its drive", "bolt.horizontal.circle.fill", .systemGray)
        case "connect": return ("Connect one", nil, .systemGray)
        default: return ("Checking...", nil, .systemGray)
        }
    }

    /// Drive icon with its readiness drawn on it, as in Library Settings.
    func storageIconView(_ entry: StorageOverviewEntry) -> NSView {
        let icon = NSImageView()
        storageModeIcon(icon, mode: entry.mode)
        icon.identifier = NSUserInterfaceItemIdentifier("storage-overview-icon")
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 44), container.heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor), icon.topAnchor.constraint(equalTo: container.topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 36)
        ])
        let state = storageStateLabel(entry)
        if let symbol = state.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.text) {
            let badge = NSImageView(image: image)
            badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, state.color]))
            badge.identifier = NSUserInterfaceItemIdentifier("storage-overview-badge")
            badge.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                badge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                badge.widthAnchor.constraint(equalToConstant: 17), badge.heightAnchor.constraint(equalToConstant: 17)
            ])
        }
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.image)
        container.setAccessibilityLabel(entry.title + ", " + state.text)
        return container
    }

    func storageOverviewRow(_ entry: StorageOverviewEntry, navigable: Bool = true) -> StorageOverviewRow {
        let view = StorageOverviewRow()
        view.identifier = NSUserInterfaceItemIdentifier("storage-overview-row")
        let state = storageStateLabel(entry)
        let title = text(entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        let status = text(state.text, size: 11, secondary: true)
        status.identifier = NSUserInterfaceItemIdentifier("storage-overview-status")
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        var lines: [NSView] = [title, status]
        if let path = entry.path, !["absent", "checking", "connect", "disconnected"].contains(entry.state) {
            let link = pill((path as NSString).abbreviatingWithTildeInPath, symbol: "folder", action: #selector(openBIOSFolder(_:)),
                            value: path, help: "Open " + path + " in Finder")
            link.identifier = NSUserInterfaceItemIdentifier(path)
            link.lineBreakMode = .byTruncatingMiddle
            link.setContentCompressionResistancePriority(.init(490), for: .horizontal)
            lines.append(link)
        }
        let labels = column(lines)
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var parts: [NSView] = [storageIconView(entry), labels, spacer]
        if navigable, let id = entry.id {
            view.driveID = id
            view.onOpen = { [weak self] id in self?.showDriveDetail(id) }
            let chevron = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Manage \(entry.title)")!,
                                   target: self, action: #selector(openDriveDetail(_:)))
            chevron.isBordered = false
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.identifier = NSUserInterfaceItemIdentifier(id)
            chevron.toolTip = "Manage \(entry.title)"
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.widthAnchor.constraint(equalToConstant: 18).isActive = true
            parts.append(chevron)
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel("\(entry.title), \(state.text). Manage drive")
            view.toolTip = "Manage \(entry.title)"
        }
        if entry.state == "connect" {
            view.alphaValue = 0.45
            view.toolTip = "Connect an external SSD to keep games on it"
        }
        let content = row(parts)
        content.distribution = .fill
        content.spacing = 12
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        return view
    }

    /// Re-renders rows only when something visible changed, so silent refreshes don't flicker.
    func renderStorageOverview() {
        let entries = storageOverviewEntries()
        for rows in [gameLibraryOverviewRows] {
            guard storageOverviewRendered[ObjectIdentifier(rows)] != entries else { continue }
            storageOverviewRendered[ObjectIdentifier(rows)] = entries
            clearRows(rows)
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    let line = separator()
                    rows.addArrangedSubview(line)
                    line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                }
                let view = storageOverviewRow(entry)
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
    }

    @objc func openDriveDetail(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showDriveDetail(id)
    }

    func showDriveDetail(_ id: String) {
        let page = currentPage
        if page != 12 { driveDetailParent = 6 }
        if driveDetailID != id { driveDetailLoading = false }
        driveDetailID = id
        renderDriveDetail()
        selectPage(12)
        loadDriveDetail()
        if storageStatus?.locations.contains(where: { $0.drive.id == id }) ?? true {
            loadDriveGames(id)
            renderDriveDetail()
        }
    }

    /// Reads one drive in the background; older or other-drive results never overwrite the current page.
    func loadDriveDetail() {
        guard let id = driveDetailID else { return }
        guard task == nil else { driveDetailPending = true; return }
        driveDetailPending = false
        driveDetailGeneration += 1
        let generation = driveDetailGeneration
        driveDetailLoading = true
        if driveDetailCache[id] == nil { renderDriveDetail() }
        backendRead(["drive-detail", "--drive", id]) { code, data in
            guard generation == self.driveDetailGeneration else { return }
            self.driveDetailLoading = false
            if code == 0, let detail = try? JSONDecoder().decode(DriveDetail.self, from: data) {
                self.driveDetailCache[id] = detail
                self.driveDetailErrors[id] = nil
            } else {
                self.driveDetailErrors[id] = self.lastError.isEmpty ? "Couldn't read this drive." : self.lastError
            }
            if self.driveDetailID == id { self.renderDriveDetail() }
        }
    }

    /// Starts (or reuses) the per-game size scan for one drive. Results for another drive or an older scan are dropped.
    func loadDriveGames(_ id: String, force: Bool = false) {
        if !force, driveGamesScanning == id { return }
        if !force, let cached = driveGamesCache[id], Date().timeIntervalSince(cached.scanned) < 300 { return }
        driveGamesGeneration += 1
        let generation = driveGamesGeneration
        driveGamesScanning = id
        driveGamesErrors[id] = nil
        driveGamesRead(id) { code, data in
            guard generation == self.driveGamesGeneration else { return }
            self.driveGamesScanning = nil
            if code == 0, let games = DriveGames.decode(data), games.drive.id == id {
                self.driveGamesCache[id] = (games, Date())
            } else {
                self.driveGamesErrors[id] = "Couldn't measure games on this drive."
            }
            if self.driveDetailID == id { self.renderDriveDetail() }
        }
    }

    /// Cancels a running scan, e.g. when its drive is unplugged; nothing is written either way.
    func cancelDriveGames(_ id: String) {
        driveGamesCache[id] = nil
        guard driveGamesScanning == id else { return }
        driveGamesGeneration += 1
        driveGamesScanning = nil
        driveGamesProcess?.terminate()
        driveGamesProcess = nil
    }

    func runDriveGamesScan(_ id: String, _ done: @escaping (Int32, Data) -> Void) {
        driveGamesProcess?.terminate()
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path, "drive-games", "--drive", id]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        driveGamesProcess = process
        do { try process.run() } catch { driveGamesProcess = nil; done(1, Data()); return }
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                if self.driveGamesProcess === process { self.driveGamesProcess = nil }
                done(process.terminationStatus, data)
            }
        }
    }

    @objc func toggleDriveStorageGrouping(_ sender: NSButton) {
        let key = sender.identifier?.rawValue == "drive-group-roms" ? romsBySystemKey : pcByLauncherKey
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        renderDriveDetail()
    }

    @objc func toggleDriveStorageShowAll() {
        driveGamesShowAll.toggle()
        renderDriveDetail()
    }

    @objc func rescanDriveGames() {
        guard let id = driveDetailID, detailDrive != nil else { return }
        loadDriveGames(id, force: true)
        renderDriveDetail()
    }

    /// Bottom-of-page breakdown: each game's share of the games found on this drive, not of the drive's capacity.
    func driveGamesSection(_ id: String) -> NSView {
        let rescan = button("Rescan", #selector(rescanDriveGames))
        rescan.identifier = NSUserInterfaceItemIdentifier("drive-games-rescan")
        rescan.isEnabled = driveGamesScanning != id
        let scanning = driveGamesScanning == id
        guard let games = driveGamesCache[id]?.games else {
            let message = driveGamesErrors[id].map { $0 + " Nothing was changed." } ?? "Measuring games on this drive..."
            let status: NSView = driveGamesErrors[id] == nil
                ? statusIndicator(message, color: .systemBlue, pulsing: true) : text(message, size: 12, secondary: true)
            return detailSection("Game storage", trailing: [rescan], views: [status])
        }
        let romsBySystem = UserDefaults.standard.bool(forKey: romsBySystemKey)
        let pcByLauncher = UserDefaults.standard.bool(forKey: pcByLauncherKey)
        let slices = GameStorageSlice.slices(games, romsBySystem: romsBySystem, pcByLauncher: pcByLauncher)
        var views: [NSView] = []
        let checked = games.coverage.filter { $0.status != "unsupported" }.map { $0.games > 0 ? "\($0.name) (\($0.games))" : $0.name }
        let unsupported = games.coverage.filter { $0.status == "unsupported" }.compactMap(\.note)
        if games.items.isEmpty {
            views.append(text("No games found on this drive.", size: 13))
        } else {
            let total = ByteCountFormatter.string(fromByteCount: games.total, countStyle: .file)
            let denominator = text("Share of \(total) of games found on this drive (not of the drive's size).", size: 12, secondary: true)
            denominator.identifier = NSUserInterfaceItemIdentifier("drive-games-total")
            let bar = GameStorageBar()
            bar.identifier = NSUserInterfaceItemIdentifier("drive-games-bar")
            bar.segments = GameStorageBar.segments(for: slices)
            let roms = NSButton(checkboxWithTitle: "Group ROMs by system", target: self, action: #selector(toggleDriveStorageGrouping(_:)))
            roms.identifier = NSUserInterfaceItemIdentifier("drive-group-roms")
            roms.state = romsBySystem ? .on : .off
            let pc = NSButton(checkboxWithTitle: "Group PC games by launcher", target: self, action: #selector(toggleDriveStorageGrouping(_:)))
            pc.identifier = NSUserInterfaceItemIdentifier("drive-group-pc")
            pc.state = pcByLauncher ? .on : .off
            let toggles = row([roms, pc, NSView()])
            toggles.distribution = .fill
            views += [bar, denominator, toggles]
            let colors = Dictionary(uniqueKeysWithValues: slices.filter { ($0.bytes ?? 0) > 0 }.prefix(GameStorageBar.colored)
                .enumerated().map { ($1.id, GameStorageBar.colors[$0]) })
            let limit = 12
            for slice in driveGamesShowAll ? slices : Array(slices.prefix(limit)) {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = (colors[slice.id] ?? .tertiaryLabelColor).cgColor
                dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
                func single(_ value: String, _ size: CGFloat, secondary: Bool = false) -> NSTextField {
                    let field = NSTextField(labelWithString: value)
                    field.font = .systemFont(ofSize: size)
                    field.textColor = secondary ? .secondaryLabelColor : .labelColor
                    field.lineBreakMode = .byTruncatingTail
                    return field
                }
                let name = single(slice.title, 13)
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                var notes = [slice.detail]
                if slice.unknown > 0 { notes.append(slice.unknown == 1 ? "1 size unknown" : "\(slice.unknown) sizes unknown") }
                if slice.partial { notes.append("some files unreadable") }
                let detail = single(notes.joined(separator: " · "), 11, secondary: true)
                detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
                let size = single(slice.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown", 13)
                size.alignment = .right
                let percent = single(slice.percent, 12, secondary: true)
                percent.alignment = .right
                percent.widthAnchor.constraint(equalToConstant: 48).isActive = true
                let line = row([dot, name, detail, NSView(), size, percent])
                line.distribution = .fill
                line.identifier = NSUserInterfaceItemIdentifier("drive-games-row")
                line.setAccessibilityElement(true)
                line.setAccessibilityLabel("\(slice.title), \(size.stringValue), \(slice.percent)")
                views.append(line)
            }
            if slices.count > limit {
                let more = button(driveGamesShowAll ? "Show fewer" : "Show all \(slices.count)", #selector(toggleDriveStorageShowAll))
                more.identifier = NSUserInterfaceItemIdentifier("drive-games-more")
                views.append(row([more, NSView()]))
            }
        }
        var status: [String] = []
        if scanning { status.append("Rescanning...") }
        if !scanning, driveGamesErrors[id] != nil { status.append("The last rescan failed; showing earlier results.") }
        if games.unknown > 0 { status.append("\(games.unknown) with unknown size, left out of the bar.") }
        if games.partial > 0 { status.append("\(games.partial) only partly readable, so they may be larger.") }
        if games.items.contains(where: { !$0.measured && $0.bytes != nil }) { status.append("Missing Steam folders use Steam's reported size.") }
        if games.shared > 0 { status.append("Shared files are counted once.") }
        status.append("Checked: " + checked.joined(separator: ", ") + ".")
        status += unsupported
        let note = text(status.joined(separator: " "), size: 11, secondary: true)
        note.identifier = NSUserInterfaceItemIdentifier("drive-games-status")
        views.append(note)
        return detailSection("Game storage", subtitle: "Which games take the most space here. Nothing is deleted from this view.", trailing: [rescan], views: views)
    }

    func detailSection(_ title: String, subtitle: String? = nil, trailing: [NSView] = [], views: [NSView]) -> NSView {
        let heading = text(title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let header = row([heading, NSView()] + trailing)
        header.distribution = .fill
        var content: [NSView] = [header]
        if let subtitle = subtitle { content.append(text(subtitle, size: 12, secondary: true)) }
        return card("", subtitle: nil, views: content + views)
    }

    func renderDriveDetail() {
        clearRows(driveDetailRows)
        guard let id = driveDetailID else { return }
        func add(_ view: NSView) {
            driveDetailRows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: driveDetailRows.widthAnchor).isActive = true
        }
        let location = storageStatus?.locations.first { $0.drive.id == id }
        let detail = driveDetailCache[id]
        let drive = location?.drive ?? detail?.drive
        let title = drive.map(driveTitle) ?? "Drive"
        if currentPage == 12 { screenTitle.stringValue = title }
        if storageStatus != nil && location == nil {
            cancelDriveGames(id)
            add(detailSection(title, subtitle: "Disconnected. Reconnect this drive to see its library, storage and games. Nothing on it was changed.", views: []))
            return
        }
        guard let entry = storageOverviewEntries().first(where: { $0.id == id }) ?? drive.map({
            StorageOverviewEntry(id: $0.id, mode: $0.mode, title: driveTitle($0), state: "checking", active: false, path: $0.root)
        }) else {
            add(detailSection("Drive", subtitle: "Checking connected drives...", views: []))
            return
        }
        var library: [NSView] = [storageOverviewRow(entry, navigable: false)]
        var actions: [NSView] = []
        switch entry.state {
        case "ready":
            if !entry.active {
                actions.append(button("Use this library...", #selector(activateDetailDrive)))
            } else {
                actions.append(button("Move library...", #selector(moveLibrary)))
            }
            let remove = button("Remove...", #selector(removeDetailLibrary))
            remove.identifier = NSUserInterfaceItemIdentifier("drive-remove")
            actions.append(remove)
        case "absent":
            library.append(text("No Couch Cube library here yet. Initialize adds a Couch Cube folder with empty game, BIOS and save folders. Nothing existing is changed and your active library stays the same.", size: 12, secondary: true))
            let initialize = button("Initialize...", #selector(initializeDetailDrive))
            initialize.identifier = NSUserInterfaceItemIdentifier("drive-initialize")
            initialize.isEnabled = drive.map { ["apfs", "hfs"].contains($0.filesystem) } ?? false
            if !initialize.isEnabled { initialize.toolTip = "This drive must use APFS or Mac OS Extended. Couch Cube never formats it here." }
            actions.append(initialize)
        case "occupied", "invalid":
            let issue = location?.issue ?? detail?.issue
            library.append(text((issue ?? "This folder isn't a Couch Cube library Couch Cube can verify.") +
                                " Nothing will be overwritten. Rename or move it in Finder, then refresh.", size: 12, secondary: true))
        default:
            break
        }
        if !actions.isEmpty {
            let line = row(actions + [NSView()])
            line.distribution = .fill
            library.append(line)
        }
        add(detailSection("Couch Cube library", views: library))
        let loadingDetail = driveDetailLoading && detail == nil
        if let capacity = detail?.capacity {
            let full = capacity.total > 0 && Double(capacity.used) >= Double(capacity.total) * 0.95
            let couchColor = NSColor.controlAccentColor, otherColor = full ? NSColor.systemRed : NSColor.systemGray
            func amount(_ label: String, _ bytes: Int64, _ identifier: String, color: NSColor? = nil) -> NSView {
                let value = text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), size: 13)
                value.identifier = NSUserInterfaceItemIdentifier(identifier)
                value.alignment = .right
                var parts: [NSView] = [text(label, size: 13), NSView(), value]
                if let color {
                    let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
                    dot.symbolConfiguration = .init(pointSize: 8, weight: .regular)
                    dot.contentTintColor = color
                    parts.insert(dot, at: 0)
                }
                let line = row(parts)
                line.distribution = .fill
                return line
            }
            // One bar: other used files, then Couch Cube files; the rest of the track is free space.
            let couch = min(max(capacity.couch, 0), capacity.used)
            let bar = GameStorageBar()
            bar.accessibilityPrefix = "Drive space"
            bar.segments = [(title: "Other files", bytes: max(capacity.used - couch, 0), color: otherColor),
                            (title: "Couch Cube files", bytes: couch, color: couchColor),
                            (title: "Free", bytes: max(capacity.total - capacity.used, 0), color: .clear)].filter { $0.bytes > 0 }
            bar.identifier = NSUserInterfaceItemIdentifier("drive-space-bar")
            add(detailSection("Storage", views: [
                bar,
                amount("Drive size", capacity.total, "drive-total"),
                amount("Used by other files", max(capacity.used - couch, 0), "drive-used", color: otherColor),
                amount("Couch Cube files", capacity.couch, "drive-couch", color: couchColor),
                amount("Free space", capacity.free, "drive-free")
            ]))
        } else if loadingDetail {
            add(detailSection("Storage", views: [statusIndicator("Reading this drive...", color: .systemBlue, pulsing: true)]))
        }
        if let detail = detail, !detail.steam.isEmpty {
            var views: [NSView] = []
            for folder in detail.steam {
                let count = folder.games.filter(\.installed).count
                let heading = text(count == 1 ? "1 game" : "\(count) games", size: 11, secondary: true)
                heading.font = .systemFont(ofSize: 11, weight: .semibold)
                let link = pill((folder.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", action: #selector(openBIOSFolder(_:)),
                                value: folder.path, help: "Open " + folder.path + " in Finder")
                link.lineBreakMode = .byTruncatingMiddle
                link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let line = row([heading, link, NSView()])
                line.distribution = .fill
                views.append(line)
                views.append(contentsOf: folder.games.map(steamGameRow))
            }
            add(detailSection("Steam", trailing: [button("Open Steam Storage", #selector(openSteamStorage))], views: views))
        }
        if let detail = detail, !detail.retro.isEmpty {
            let views: [NSView] = detail.retro.map { system in
                let name = text(system.name, size: 13)
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let line = row([name, text(system.games == 1 ? "1 game" : "\(system.games) games", size: 11, secondary: true), NSView(),
                                pill("Open folder", symbol: "folder", action: #selector(openBIOSFolder(_:)),
                                     value: system.path, help: "Open " + system.path + " in Finder")])
                line.distribution = .fill
                line.identifier = NSUserInterfaceItemIdentifier("drive-retro-" + system.id)
                return line
            }
            add(detailSection("Retro games", views: views))
        }
        if location != nil || storageStatus == nil {
            add(driveGamesSection(id))
        }
        let errors = (detail?.errors ?? []) + (driveDetailErrors[id].map { [$0] } ?? [])
        if !errors.isEmpty {
            add(text(errors.prefix(3).joined(separator: "\n"), size: 11, secondary: true))
        }
    }

    @objc func activateDetailDrive() {
        guard task == nil, let drive = detailDrive else { return }
        chooseMode(drive.mode)
        populateVolumes(previous: drive.id)
        selectionChanged()
    }

    @objc func initializeDetailDrive() {
        guard task == nil, let drive = detailDrive else { return }
        let confirm = NSAlert()
        confirm.messageText = "Initialize a library on \(driveTitle(drive))?"
        confirm.informativeText = "Creates \(drive.root) with empty game, BIOS and save folders.\n\nNothing is formatted, overwritten or moved. If that folder already exists, nothing is changed. Your active library stays the same."
        confirm.addButton(withTitle: "Initialize")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        execute(["initialize-drive", "--drive", drive.id, "--confirm"]) { code, _ in
            if code != 0 {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't initialize this drive. Nothing was changed." : self.lastError)
            }
            self.refresh()
        }
    }

    /// Moves only this drive's verified Couch Cube folder to the Trash after a scoped plan and two confirmations.
    @objc func removeDetailLibrary() {
        guard task == nil, let drive = detailDrive else { return }
        if Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: drive.root).standardizedFileURL.path + "/") {
            storageOperationFailed("Couch Cube is running from this library. Quit it and open a copy from another location first. Nothing was removed.")
            return
        }
        backendRead(["removal-plan", "--drive", drive.id]) { code, data in
            guard code == 0, let plan = try? JSONDecoder().decode(DriveRemovalPlan.self, from: data) else {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't verify this library. Nothing was removed." : self.lastError)
                return
            }
            let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
            let review = NSAlert()
            review.alertStyle = .warning
            review.messageText = "Remove the Couch Cube library on \(self.driveTitle(drive))?"
            review.informativeText = "\(plan.path)\n\(size) · \(plan.files) files\n\nEverything in this folder is removed: ROMs, BIOS files, saves, launchers and settings stored there. The rest of the drive is not erased or formatted, and Steam games are not touched.\n\nBack up first: copy the library to another drive, or open it in Finder and copy what you want to keep."
            review.addButton(withTitle: "Continue...")
            review.addButton(withTitle: "Cancel")
            review.addButton(withTitle: "Show in Finder")
            review.addButton(withTitle: "Copy to another drive...")
            switch review.runModal() {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn:
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plan.path)])
                return
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                self.transferLibrary(from: drive)
                return
            default: return
            }
            let confirm = NSAlert()
            confirm.alertStyle = .critical
            confirm.messageText = "Move this library to the Trash?"
            confirm.informativeText = "\(plan.path)\n\nIt stays in the Trash until you empty it. Anything you didn't back up is lost when the Trash is emptied."
            confirm.showsSuppressionButton = true
            confirm.suppressionButton?.title = "I backed up what I want to keep"
            confirm.addButton(withTitle: "Move to Trash")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            guard confirm.suppressionButton?.state == .on else {
                self.storageOperationFailed("Confirm that you backed up what you want to keep. Nothing was removed.")
                return
            }
            self.execute(["removal-verify", "--drive", drive.id, "--token", plan.token, "--confirm"], capture: true) { code, data in
                guard code == 0, let target = try? JSONDecoder().decode(RetiredLibrary.self, from: data), target.path == plan.path else {
                    self.storageOperationFailed(self.lastError.isEmpty ? "The library changed or couldn't be verified. Nothing was removed." : self.lastError)
                    self.refresh()
                    return
                }
                self.cleanupInProgress = true
                self.busy(true)
                NSWorkspace.shared.recycle([URL(fileURLWithPath: target.path)]) { _, error in
                    DispatchQueue.main.async {
                        self.cleanupInProgress = false
                        self.busy(false)
                        if let error = error {
                            self.storageOperationFailed("Couldn't move the library to Trash: \(error.localizedDescription). Nothing else was changed.")
                        } else {
                            self.append("Moved \(target.path) to the Trash.\n")
                        }
                        self.driveDetailCache[drive.id] = nil
                        self.refresh()
                    }
                }
            }
        }
    }

    func storageOperationFailed(_ message: String) {
        status.stringValue = message
        append(message + "\n")
        let alert = NSAlert()
        alert.messageText = "Library storage"
        alert.informativeText = message
        alert.runModal()
    }

    @objc func moveLibrary() {
        guard task == nil, let storage = storageStatus,
              let source = storage.locations.first(where: { $0.drive.id == storage.active?.id && $0.configured })?.drive else {
            storageOperationFailed("Set up or activate a connected library before moving it.")
            return
        }
        transferLibrary(from: source)
    }

    func transferLibrary(from source: Drive) {
        guard task == nil, let storage = storageStatus else { return }
        let destinations = storage.locations.map(\.drive).filter { $0.id != source.id }
        guard !destinations.isEmpty else {
            storageOperationFailed("Connect another writable APFS or Mac OS Extended drive first.")
            return
        }
        let choose = NSAlert()
        choose.messageText = "Move your library"
        choose.informativeText = "From: \(source.root)\n\nChoose a destination. Its Couch Cube folder must not already exist; libraries are never merged. Steam files are not copied. Quit games and emulators before continuing."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 28))
        picker.addItems(withTitles: destinations.map { "\($0.mode == "local" ? "This Mac" : $0.name) · \($0.root)" })
        choose.accessoryView = picker
        choose.addButton(withTitle: "Review transfer")
        choose.addButton(withTitle: "Cancel")
        guard choose.runModal() == .alertFirstButtonReturn,
              destinations.indices.contains(picker.indexOfSelectedItem) else { return }
        let destination = destinations[picker.indexOfSelectedItem]
        execute(["transfer-plan", "--source", source.id, "--destination", destination.id], capture: true) { code, data in
            guard code == 0 else {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't review the library transfer. Open Activity for details." : self.lastError)
                return
            }
            do {
                let plan = try JSONDecoder().decode(LibraryTransferPlan.self, from: data)
                let confirm = NSAlert()
                confirm.messageText = "Copy, verify and activate this library?"
                confirm.informativeText = "From: \(plan.source.root)\nTo: \(plan.destination.root)\nSize: \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))\n\nCopies Couch Cube content except SteamLibrary, checks file contents, and activates the new location. The old library stays untouched until you separately move it to Trash. App installations and emulator data outside this folder are not moved. Keep both drives connected. Save automatic console mode again after moving."
                confirm.addButton(withTitle: "Copy and activate")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
                self.execute(["transfer-library", "--source", source.id, "--destination", destination.id,
                              "--token", plan.token, "--confirm"], capture: true) { code, data in
                    guard code == 0 else {
                        self.storageOperationFailed(self.lastError.isEmpty ? "Library transfer failed. Source files were kept. Open Activity for details." : self.lastError)
                        self.refresh()
                        return
                    }
                    do {
                        let result = try JSONDecoder().decode(LibraryTransferResult.self, from: data)
                        self.lastLibraryTransfer = (result, destination.id)
                        self.preferredMode = destination.mode
                        self.volumeMenu.select(nil)
                        self.refresh()
                        let done = NSAlert()
                        done.messageText = "Library copied and activated"
                        done.informativeText = "\(result.destination)\n\nThe old copy is still at \(result.source). Use Move old library to Trash when ready. Steam files or an old automatic console mode link must be handled first."
                        done.runModal()
                    } catch {
                        self.storageOperationFailed("Couldn't read the transfer result: \(error.localizedDescription). Inspect both libraries before retrying.")
                    }
                }
            } catch {
                self.storageOperationFailed("Couldn't read the transfer plan: \(error.localizedDescription)")
            }
        }
    }

    @objc func retireOldLibrary() {
        guard task == nil, let transfer = lastLibraryTransfer else { return }
        let confirm = NSAlert()
        confirm.messageText = "Move the old library to Trash?"
        confirm.informativeText = "\(transfer.result.source)\n\nThe new library remains active at \(transfer.result.destination). The old copy is removed only if it still matches the transfer and the copied content is present. Steam files must be moved separately first."
        confirm.addButton(withTitle: "Move to Trash")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        execute(["retire-library", "--destination", transfer.destinationID, "--token", transfer.result.token], capture: true) { code, data in
            guard code == 0 else {
                self.storageOperationFailed(self.lastError.isEmpty ? "Couldn't verify the old library. It was kept." : self.lastError)
                return
            }
            do {
                let target = try JSONDecoder().decode(RetiredLibrary.self, from: data)
                guard target.path == transfer.result.source else {
                    self.storageOperationFailed("The old library path changed. Nothing was removed.")
                    return
                }
                self.cleanupInProgress = true
                self.busy(true)
                NSWorkspace.shared.recycle([URL(fileURLWithPath: target.path)]) { _, error in
                    DispatchQueue.main.async {
                        self.cleanupInProgress = false
                        self.busy(false)
                        if let error = error {
                            self.storageOperationFailed("Couldn't move old library to Trash: \(error.localizedDescription)")
                        } else {
                            self.lastLibraryTransfer = nil
                            self.refresh()
                        }
                    }
                }
            } catch {
                self.storageOperationFailed("Couldn't read the old library path: \(error.localizedDescription)")
            }
        }
    }

    func chooseMode(_ mode: String) {
        guard task == nil else { status.stringValue = "Wait for the current operation before changing storage."; return }
        preferredMode = mode
        didRouteInitialLibrary = true
        preparationResult.isHidden = true
        populateVolumes(previous: nil)
        selectPage(4)
        selectionChanged()
    }

    func populateVolumes(previous: String?) {
        volumes = availableVolumes.filter { preferredMode == nil || $0.mode == preferredMode }
        volumeMenu.removeAllItems()
        volumeMenu.addItems(withTitles: volumes.map { $0.name })
        if let previous = previous {
            if let index = volumes.firstIndex(where: { $0.id == previous }) {
                volumeMenu.selectItem(at: index)
            } else {
                volumeMenu.select(nil)
            }
        } else if let activeID = storageStatus?.active?.id,
                  let index = volumes.firstIndex(where: { $0.id == activeID }) {
            volumeMenu.selectItem(at: index)
        } else if let index = volumes.firstIndex(where: {
            $0.mode == "portable" && Bundle.main.bundleURL.path.hasPrefix($0.mount + "/")
        }) {
            volumeMenu.selectItem(at: index)
        }
        let portable = preferredMode == "portable"
        storageHeading.stringValue = portable ? "External SSD" : "Mac storage"
        storageAdvice.stringValue = portable
            ? "Create your game folders on this SSD. Steam storage is configured in Game library's Steam setup guide. Preparing a new SSD is optional and erases it."
            : "Create Couch Cube's folders on this Mac. Steam can keep using its current library. No apps are installed and no Steam games are moved in this step."
        portablePreparation.isHidden = !portable
        renderDrives()
    }

    func renderDrives() {
        clearRows(driveRows)
        for (index, drive) in volumes.enumerated() {
            let choose = button(index == volumeMenu.indexOfSelectedItem ? "Selected" : "Choose", #selector(selectStorage(_:)))
            choose.tag = index
            choose.state = index == volumeMenu.indexOfSelectedItem ? .on : .off
            let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
            let location = storageStatus?.locations.first { $0.drive.id == drive.id }
            let active = storageStatus?.active?.id == drive.id && storageStatus?.active?.uuid == drive.uuid
            let state = active ? "Active library" : location?.configured == true ? "Library available" : "Not set up"
            let line = settingsRow((drive.mode == "local" ? "Macintosh HD" : drive.name) + (active ? " · Active" : ""),
                                   subtitle: "\(location?.issue ?? state) · \(free) available · \(drive.filesystem.uppercased())\n\(drive.root)",
                                   symbol: drive.mode == "local" ? "internaldrive.fill" : "externaldrive.fill",
                                   color: .systemGray, trailing: choose)
            driveRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: driveRows.widthAnchor).isActive = true
        }
    }

    @objc func selectStorage(_ sender: NSButton) {
        guard task == nil, volumes.indices.contains(sender.tag) else {
            status.stringValue = "Wait for the current operation before changing storage."
            return
        }
        volumeMenu.selectItem(at: sender.tag)
        renderDrives()
        selectionChanged()
    }

    @objc func backToChoices() {
        selectPage(6)
    }

    @objc func continueStorage() {
        guard let report = report, report.issues.isEmpty, selected != nil else { return }
        // Refresh absolute frontend paths when an SSD moves between Macs.
        setup()
    }

    @objc func showPlayers() { selectPage(1); loadApps() }
    @objc func showPlayOverview() {
        guard task == nil else { return }
        guard report?.state == "valid layout", report?.issues.isEmpty == true, selected != nil else {
            backToChoices()
            return
        }
        guard effectiveFrontend != nil else { showPlayers(); return }
        playSteam()
    }
    @objc func showLibraryOverview() { selectPage(6); loadPageData(6) }
    @objc func disksChanged() {
        if smokeFinishing { return }
        if task != nil { refreshPending = true } else { refresh() }
    }

    @objc func selectionChanged() {
        updateSelection(preservingStatus: false)
    }

    func updateSelection(preservingStatus: Bool) {
        if !preservingStatus {
            report = nil
            consoleSystems = []
        }
        updateSetupSummary()
        storageNext.isEnabled = false
        guard let drive = selected else {
            summary.stringValue = preferredMode == "portable"
                ? "Connect an SSD to use it here, or choose Prepare an SSD above. Existing files won't be erased unless you explicitly choose preparation."
                : "Your storage is disconnected. Reconnect it and choose Refresh."
            modeLabel.stringValue = "NO STORAGE SELECTED"
            libraryTitle.stringValue = "Choose your game drive"
            libraryDescription.stringValue = "Select a connected SSD above, or use this Mac's internal storage."
            libraryControls.forEach { $0.isEnabled = false }
            selectedStorage.stringValue = "Storage disconnected"
            updateSelectedStorageMarker()
            return
        }
        libraryControls.forEach { $0.isEnabled = true }
        let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
        modeLabel.stringValue = drive.mode == "local" ? "LOCAL CONSOLE  ·  ONLY THIS MAC" : "PORTABLE CONSOLE  ·  EXTERNAL SSD"
        summary.stringValue = "\(free) free  ·  \(drive.filesystem.uppercased())"
        summary.toolTip = drive.root
        selectedStorage.stringValue = drive.mode == "local" ? drive.root : "\(drive.name)\n\(drive.root)"
        updateSelectedStorageMarker()
        if report == nil {
            libraryTitle.stringValue = "Checking your library..."
            libraryDescription.stringValue = "Checking the drive\u{2026}"
        }
        checkStorage()
    }

    @objc func checkStorage() {
        guard task == nil, let drive = selected else { return }
        overviewChecks.formUnion([.storage, .menu])
        renderGeneral()
        execute(["assess", "--drive", drive.id], capture: true) { code, data in
            guard self.selected?.id == drive.id else { self.checkStorage(); return }
            self.overviewChecks.subtract([.storage, .menu])
            guard code == 0 else {
                self.overviewCheckFailures.formUnion([.storage, .menu])
                self.overviewChecks = []
                self.renderGeneral()
                self.libraryTitle.stringValue = "Couldn't check this drive"
                self.libraryDescription.stringValue = self.lastError.isEmpty
                    ? "Reconnect the drive and press Refresh." : String(self.lastError.prefix(400))
                self.status.stringValue = "Storage check failed. Activity has the details."
                self.advanceAfterLibraryCheck = false
                self.finishSmokeTest(success: false)
                return
            }
            do {
                let report = try JSONDecoder().decode(Assessment.self, from: data)
                self.report = report
                self.storageNext.isEnabled = report.issues.isEmpty
                self.storageNext.title = report.state == "not prepared" ? "Create and activate library..." : "Use this library"
                if !report.issues.isEmpty {
                    self.summary.stringValue = "This storage needs attention before we can continue. Activity has the details."
                    if drive.mode == "portable" {
                        self.summary.stringValue += "\nTry another SSD, or prepare this one below after backing up its files."
                    }
                }
                if report.state == "not prepared" {
                    self.libraryTitle.stringValue = "No library on this drive yet"
                    self.libraryDescription.stringValue = "Makes the game folders. Nothing else on your Mac changes."
                    self.libraryAction.title = "Create game library..."
                } else if report.issues.isEmpty {
                    self.libraryTitle.stringValue = "Game folders created"
                    self.libraryDescription.stringValue = report.missing.contains("steam")
                        ? "Ready. Next, get Steam or other game apps in App Store."
                        : "Ready. Steam keeps its own game folders; change them in Steam."
                    self.libraryAction.title = "Update library links..."
                } else {
                    self.libraryTitle.stringValue = "This library needs attention"
                    self.libraryDescription.stringValue = report.issues.prefix(2).joined(separator: "\n")
                    self.libraryAction.title = "Update library links..."
                }
                self.helperButton.isHidden = !report.notes.contains { $0.hasPrefix("Homebrew missing") }
                self.helperAdvice.isHidden = self.helperButton.isHidden
                self.updateSetupSummary()
                if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[5] { self.updateSteamGuide() }
                if drive.free < 20 * 1024 * 1024 * 1024 {
                    self.summary.stringValue += "\nYou're low on space. Big games may need more room."
                }
                self.status.stringValue = "Drive checked. No files changed."
                self.append("\n--- Storage assessment: \(drive.name) ---\n"
                            + (report.issues + report.notes).joined(separator: "\n") + "\n")
                if !self.didRouteInitialLibrary {
                    self.didRouteInitialLibrary = true
                    self.selectPage(0)
                }
                if self.advanceAfterLibraryCheck {
                    self.advanceAfterLibraryCheck = false
                    if report.state == "valid layout" && report.issues.isEmpty {
                        self.selectPage(3)
                    } else {
                        self.status.stringValue = "Your library needs attention before continuing. Open Details for the error."
                    }
                }
                self.finishSmokeTest(success: true)
                if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    self.loadGeneralDetails()
                } else {
                    self.overviewChecks = []
                    self.renderGeneral()
                }
            } catch {
                self.overviewCheckFailures.formUnion([.storage, .menu])
                self.overviewChecks = []
                self.renderGeneral()
                self.advanceAfterLibraryCheck = false
                self.status.stringValue = "Cannot read assessment: \(error.localizedDescription)"
                self.finishSmokeTest(success: false)
            }
        }
    }

    @objc func playSteam() {
        guard let drive = selected else { return }
        let frontend = effectiveFrontend == "es-de" ? "ES-DE" : "Steam Big Picture"
        execute(["console", "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "\(frontend) session finished or opened." : "Couldn't open console mode. Check App Store and Activity."
        }
    }

    @objc func homebrew() {
        let alert = NSAlert()
        alert.messageText = "Set up the app download helper?"
        alert.informativeText = "Couch Cube uses Homebrew, a free tool that installs your game players.\n\nA Terminal window will guide you through the official Homebrew installer. Type INSTALL HOMEBREW when asked. macOS may request your administrator password there, never in Couch Cube.\n\nFinish that step, return here and click the app's Install button. No disks will be erased."
        alert.addButton(withTitle: "Set up Homebrew")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Official instructions only")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("Install Homebrew.command"))
            status.stringValue = "Homebrew helper opened in Terminal. Finish or cancel there, then refresh here."
        } else if response == .alertThirdButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        }
    }

    @objc func copyAppToSSD() {
        guard let drive = selected, drive.mode == "portable", task == nil else {
            status.stringValue = "Choose an external SSD first."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Copy Couch Cube to this SSD?"
        alert.informativeText = "Copies this verified app to \(drive.mount)/CouchCube.app without erasing the SSD. Existing app copies are not overwritten. Open the SSD copy afterwards. Emulators are still installed separately on each Mac."
        alert.addButton(withTitle: "Copy app")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            execute(["copy-app", "--drive", drive.id, "--confirm"]) { code, _ in
                self.status.stringValue = code == 0 ? "App copied to SSD. Open that copy to continue." : "App copy failed. See Activity."
            }
        }
    }

    @objc func prepareDisk() {
        execute(["disks"], capture: true) { code, data in
            guard code == 0 else { self.status.stringValue = "Cannot enumerate external physical disks."; return }
            do {
                self.disks = try JSONDecoder().decode([PhysicalDisk].self, from: data)
                guard !self.disks.isEmpty else {
                    self.status.stringValue = "No external physical disks attached. Internal disks and DMG devices are excluded."
                    return
                }
                let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 550, height: 28))
                menu.addItems(withTitles: self.disks.map {
                    "\($0.device) - \($0.model) - \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))"
                })
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Select a WHOLE external disk to prepare"
                alert.informativeText = "Erase destroys ALL volumes, partitions, games and any installer DMG on that physical disk. This is not normal setup. Nothing is erased by selecting a disk. Never unplug or swap disks during review."
                alert.accessoryView = menu
                alert.addButton(withTitle: "Review selected disk")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let disk = self.disks[menu.indexOfSelectedItem]
                self.reviewErase(disk)
            } catch {
                self.status.stringValue = "Cannot read physical disk list: \(error.localizedDescription)"
            }
        }
    }

    func reviewErase(_ disk: PhysicalDisk) {
        execute(["format-plan", "--device", disk.device], capture: true) { code, data in
            guard code == 0 else {
                self.status.stringValue = "Automatic erase refused. Activity explains why; use Disk Utility only after checking the device yourself."
                let alert = NSAlert()
                alert.messageText = "Automatic erase is unavailable for this disk"
                alert.informativeText = self.lastError + "\n\nDisk Utility > View > Show All Devices lets you verify the physical disk and erase as APFS / GUID manually. If the disk contains this running app, first copy the app to a different disk and relaunch it there. Disk Utility asks for its own confirmation."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Open Disk Utility")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
                return
            }
            do {
                let plan = try JSONDecoder().decode(ErasePlan.self, from: data)
                let typed = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
                let phrase = "ERASE \(plan.device)"
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Permanently erase \(plan.device)?"
                alert.informativeText = "\(plan.model)\n\(ByteCountFormatter.string(fromByteCount: plan.size, countStyle: .file))\n\nFirst stages this app on another disk and verifies its bundle signature. No download needed. If verification fails, nothing is erased. This is an ad-hoc signature, not publisher authentication.\n\nThen ALL volumes and data, including any installer, will be destroyed. New format: APFS, GUID; name: Mac Gaming. The app is copied to the SSD root afterward.\n\nType exactly: \(phrase)\n\nIf macOS denies authorization, use Disk Utility manually. A failure after erasure cannot restore your data."
                alert.accessoryView = typed
                alert.addButton(withTitle: "Erase entire disk")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, typed.stringValue == phrase else {
                    self.status.stringValue = "Erase cancelled or typed confirmation did not match. Nothing erased."
                    return
                }
                self.execute(["erase", "--device", plan.device, "--token", plan.token,
                              "--typed", typed.stringValue, "--confirm", "--prepare-portable"]) { code, _ in
                    self.status.stringValue = code == 0 ? "Portable app is at the SSD root. Open it there and create your game library." : "Preparation failed/refused. Activity explains which stage failed. Inspect the disk; do not blindly erase again."
                    if code == 0 {
                        self.preparationResult.stringValue = "Your SSD is prepared. Open CouchCube.app from its root to continue with your portable copy, or choose the new volume below."
                        self.preparationResult.isHidden = false
                        self.preferredMode = "portable"
                        self.volumeMenu.select(nil)
                        self.selectPage(4)
                    }
                    self.refreshPending = true
                }
            } catch {
                self.status.stringValue = "Invalid erase plan: \(error.localizedDescription)"
            }
        }
    }

    @objc func setup() {
        guard let drive = selected else { return }
        let alert = NSAlert()
        alert.messageText = report?.state == "not prepared" ? "Create and activate your library?" : "Use this library?"
        alert.informativeText = "\(drive.root)\n\nSets this as the active library on this Mac. Creates game folders and launcher files only, or updates this app's existing files. Your games and saves are kept; other libraries stay untouched.\n\nDoes not install Steam or emulators, change Steam's storage, add shortcuts to Steam or move existing games. Save automatic console mode again if it points to another library."
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.lastPathComponent == "ES-DE.app" }) {
            alert.informativeText += "\n\nES-DE is running. Quit it first so it won't overwrite updated frontend settings."
            status.stringValue = "Quit ES-DE before updating its configuration."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status.stringValue = "Cancelled. No changes made."
            return
        }
        append("\n--- Create/update library ---\n")
        execute(["setup", "--drive", drive.id, "--confirm"]) { code, _ in
            if code == 0 {
                self.status.stringValue = "Library activated. Install any missing apps in App Store."
                self.advanceAfterLibraryCheck = true
                self.refresh()
            } else {
                self.status.stringValue = "Library couldn't be updated. Your games are kept; Activity explains the problem."
            }
        }
    }

    @objc func openFolder() {
        guard let drive = selected else { return }
        let path = URL(fileURLWithPath: drive.root)
        guard FileManager.default.fileExists(atPath: path.path) else {
            status.stringValue = "Run setup first, or reconnect the drive."
            return
        }
        NSWorkspace.shared.open(path)
    }

    @objc func instructions() {
        NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("README.md"))
    }

    @objc func registerGame() {
        guard let drive = selected else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a native game or Porting Kit wrapper on the selected drive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: drive.root)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let root = drive.root + "/"
        guard app.path.hasPrefix(root), app.pathExtension == "app" else {
            status.stringValue = "Choose a .app inside Native/Games or Windows/Wrappers on this drive."
            return
        }
        let relative = String(app.path.dropFirst(root.count))
        let kind = relative.hasPrefix("Native/Games/") ? "native" : "windows"
        let alert = NSAlert()
        alert.messageText = "Create a Steam-compatible shortcut?"
        alert.informativeText = "This creates a launcher .app. You still add it in Steam manually. Windows games must already have a working Wine wrapper. Name: letters, numbers, spaces, _ or -."
        let name = NSTextField(string: app.deletingPathExtension().lastPathComponent)
        name.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["register", "--root", drive.root, "--kind", kind, "--name", name.stringValue, "--app", relative]) { code, _ in
            self.status.stringValue = code == 0
                ? "Shortcut created in Launchers. Add it as a Non-Steam Game in Steam."
                : "Shortcut not created. See error details."
        }
    }
}
