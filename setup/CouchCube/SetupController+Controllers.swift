import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    @objc func openBluetooth() {
        bluetoothSettingsOpens += 1
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) {
            controllerStatus.stringValue = "Couldn't open Bluetooth settings. Open System Settings → Bluetooth manually."
        }
    }

    func openConsoleSettingsURL(_ address: String, name: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(name)"
            alert.informativeText = "Open \(name) manually in System Settings."
            alert.runModal()
            return
        }
    }

    @objc func openUsersAndGroups() {
        openConsoleSettingsURL("x-apple.systempreferences:com.apple.Users-Groups-Settings.extension", name: "Users & Groups")
    }

    @objc func openFileVaultSettings() {
        openConsoleSettingsURL("x-apple.systempreferences:com.apple.preference.security?FileVault", name: "Privacy & Security → FileVault")
    }

    @objc func openLockScreenSettings() {
        openConsoleSettingsURL("x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension", name: "Lock Screen")
    }

    @objc func openAutomaticLoginGuide() {
        openConsoleSettingsURL("https://support.apple.com/en-us/102316", name: "Apple's automatic login guide")
    }

    @objc func openGameControllerSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!) {
            controllerStatus.stringValue = "Couldn't open Game Controllers settings. Open System Settings → Game Controllers manually."
        }
    }

    func controllerButton(_ title: String, _ action: Selector) -> NSButton {
        let control = button(title, action)
        actions.removeAll { $0 === control }
        return control
    }

    @objc func showControllers() { selectPage(8) }

    @objc func controllerBluetoothAccess() {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!) {
                controllerStatus.stringValue = "Open System Settings → Privacy & Security → Bluetooth to review access."
            }
        } else if bluetoothManager == nil {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refreshControllers()
        if central.state == .poweredOn { startControllerDiscovery() } else { stopControllerDiscovery() }
    }

    @objc func controllerConnectionChanged() {
        DispatchQueue.main.async {
            self.renderGeneral()
            if self.controllerPageVisible { self.refreshControllers() }
        }
    }

    func loadControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              let data = UserDefaults.standard.data(forKey: controllerDefaultsKey) else { return }
        do {
            let preferences = try JSONDecoder().decode(ControllerPreferences.self, from: data)
            restoreControllerPreferences(preferences)
        } catch {
            append("Couldn't read controller names: \(error.localizedDescription)\n")
            controllerStatus.stringValue = "Couldn't read saved controller names. Activity has details."
        }
    }

    func restoreControllerPreferences(_ preferences: ControllerPreferences) {
        controllerAliases = (preferences.aliases ?? [:]).filter { !$0.key.contains("session:") && $0.key != $0.value }
        controllerEntries = preferences.entries.filter { !$0.id.contains("session:") && controllerAliases[$0.id] == nil }.map {
            var entry = $0
            entry.connected = false
            return entry
        }
        controllerCustomizations = preferences.customizations
        let legacyColors = (preferences.colorVersion ?? 1) < 2
        for entry in controllerEntries {
            if let color = controllerCustomizations[entry.id]?.color {
                controllerCustomizations[entry.id]?.color = legacyColors ?
                    ControllerPalette.migratedName(color, for: entry) : ControllerPalette.canonicalName(color, for: entry)
            }
        }
        controllerConnectedFirst = preferences.connectedFirst
        updateControllerSortMenu()
        let knownIDs = Set(controllerEntries.map(\.id))
        var recent: [String] = []
        for id in preferences.recentControllerIDs ?? controllerEntries.suffix(4).map(\.id) {
            let id = canonicalControllerID(id)
            if knownIDs.contains(id) && !recent.contains(id) { recent.append(id) }
        }
        homeSessionControllers = Array(recent.suffix(4))
        homeObservedConnections = []
    }

    func currentControllerPreferences() -> ControllerPreferences {
        ControllerPreferences(entries: controllerEntries.filter { !$0.id.contains("session:") },
            customizations: controllerCustomizations, connectedFirst: controllerConnectedFirst,
            recentControllerIDs: homeSessionControllers.filter { !$0.contains("session:") },
            aliases: controllerAliases.filter { !$0.key.contains("session:") }, colorVersion: 2)
    }

    func saveControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        do {
            let data = try JSONEncoder().encode(currentControllerPreferences())
            if data != UserDefaults.standard.data(forKey: controllerDefaultsKey) {
                UserDefaults.standard.set(data, forKey: controllerDefaultsKey)
            }
        } catch {
            controllerStatus.stringValue = "Couldn't save controller names. Activity has details."
            append("Couldn't save controller names: \(error.localizedDescription)\n")
        }
    }

    func canonicalControllerID(_ id: String) -> String { controllerAliases[id] ?? id }

    func updateControllerSortMenu() {
        guard controllerSortMenu.numberOfItems > 2 else { return }
        controllerSortMenu.item(at: 1)?.state = controllerConnectedFirst ? .off : .on
        controllerSortMenu.item(at: 2)?.state = controllerConnectedFirst ? .on : .off
        controllerSortMenu.toolTip = controllerConnectedFirst ? "Sorted: connected first, then your order" : "Sorted: your order"
    }

    @objc func controllerSortChanged(_ sender: NSMenuItem) {
        controllerConnectedFirst = sender.tag == 1
        updateControllerSortMenu()
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    /// Home mirrors the Controllers list exactly: same entries, saved order and sort mode, limited to the first slots.
    func homeControllerList() -> [ControllerEntry] { orderedControllers(controllerEntries) }

    func orderedControllers(_ entries: [ControllerEntry]) -> [ControllerEntry] {
        guard controllerConnectedFirst else { return entries }
        return entries.filter(\.connected) + entries.filter { !$0.connected }
    }

    func controllerDisplayName(_ entry: ControllerEntry) -> String {
        let custom = controllerCustomizations[entry.id]?.name ?? ""
        return custom.isEmpty ? entry.name : custom
    }

    func controllerID(from sender: Any) -> String? {
        if let item = sender as? NSMenuItem {
            return (item.representedObject as? String) ?? (item.representedObject as? [String])?.first
        }
        return (sender as? NSView)?.identifier?.rawValue
    }

    /// Width of the longest status, so in-place Connected ↔ Not connected changes never reuse a narrower width.
    func controllerStatusWidth(_ font: NSFont) -> CGFloat {
        ["Not connected", "Connecting…", "Connected"].map { text -> CGFloat in
            let label = NSTextField(labelWithString: text)
            label.font = font
            return ceil(label.intrinsicContentSize.width)
        }.max() ?? 0
    }

    func controllerStatusText(_ entry: ControllerEntry, active: Bool) -> String {
        controllerConnectionStatus(connected: entry.connected, inputDetected: entry.inputDetected,
                                   connecting: controllerBusy.contains(entry.id))
    }

    func controllerIcon(_ image: NSImage?, color: NSColor, label: String, size: CGFloat = 11) -> NSImageView? {
        guard let image = image else { return nil }
        let view = NSImageView(image: image)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        view.toolTip = label
        view.setAccessibilityLabel(label)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    func controllerDetailSeparator() -> NSTextField {
        let dot = NSTextField(labelWithString: "·")
        dot.font = .systemFont(ofSize: 11)
        dot.textColor = .tertiaryLabelColor
        return dot
    }

    func controllerConnectionViews(_ entry: ControllerEntry) -> [NSView] {
        guard entry.connected else { return [] }
        var views: [NSView] = []
        let transport: NSImage? = entry.transport == "Bluetooth" ? ControllerGlyph.bluetooth :
            entry.transport == "Wired" ? (NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil) ??
                                          NSImage(systemSymbolName: "powerplug", accessibilityDescription: nil)) :
            entry.transport.isEmpty ? nil : NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
        if let icon = controllerIcon(transport, color: .secondaryLabelColor, label: entry.connectionLabel) {
            icon.identifier = NSUserInterfaceItemIdentifier("controller-transport")
            if transport === ControllerGlyph.bluetooth {
                icon.widthAnchor.constraint(equalToConstant: 8).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 11).isActive = true
            }
            views += [controllerDetailSeparator(), icon]
        }
        if let battery = controllerBatteries[entry.id],
           let severity = controllerBatterySeverity(level: battery.level, state: battery.state) {
            let color = controllerBatteryColor(severity)
            let description = controllerBatteryText(level: battery.level, state: battery.state) ?? ""
            let percent = battery.state == .full ? 100 : Int((battery.level * 100).rounded())
            if let icon = controllerIcon(NSImage(systemSymbolName: controllerBatterySymbol(level: battery.level, state: battery.state),
                                                 accessibilityDescription: nil), color: color, label: description, size: 12) {
                icon.identifier = NSUserInterfaceItemIdentifier("controller-battery")
                let value = NSTextField(labelWithString: "\(percent)%")
                value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                value.textColor = severity == .normal ? .secondaryLabelColor : color
                value.identifier = NSUserInterfaceItemIdentifier("controller-battery-text")
                value.toolTip = description
                let battery = row([icon, value])
                battery.spacing = 3
                battery.setAccessibilityElement(true)
                battery.setAccessibilityLabel(description)
                views += [controllerDetailSeparator(), battery]
            }
        }
        return views
    }

    func controllerMenuButton(_ entry: ControllerEntry, list: Int, position: Int, count: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.addItem(withTitle: "")
        popup.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        popup.menu?.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: Selector, enabled: Bool = true,
                 object: Any? = nil, to menu: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = list
            item.representedObject = object ?? entry.id
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            (menu ?? popup.menu)?.addItem(item)
        }
        add("Customize…", "pencil", #selector(customizeController(_:)))
        add("Move Up", "arrow.up", #selector(moveControllerUp(_:)), enabled: position > 0)
        add("Move Down", "arrow.down", #selector(moveControllerDown(_:)), enabled: position < count - 1)
        let bluetooth = entry.id.hasPrefix("bt:")
        if bluetooth {
            popup.menu?.addItem(.separator())
            if entry.connected && entry.transport == "Bluetooth" {
                add("Disconnect", "xmark.circle", #selector(disconnectController(_:)))
            } else if !entry.connected {
                add("Connect", "link", #selector(connectController(_:)), enabled: !controllerBusy.contains(entry.id))
            }
        }
        let candidates = controllerLinkCandidates(for: entry)
        let linked = controllerAliases.values.contains(entry.id)
        if !candidates.isEmpty || linked {
            popup.menu?.addItem(.separator())
        }
        if !candidates.isEmpty {
            let parent = NSMenuItem(title: "Same Controller As", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: nil)
            let submenu = NSMenu()
            for candidate in candidates {
                add("\(controllerDisplayName(candidate)) · \(candidate.id.hasPrefix("bt:") ? "Bluetooth" : candidate.connectionLabel)",
                    "gamecontroller", #selector(linkControllers(_:)), object: [entry.id, candidate.id], to: submenu)
            }
            parent.submenu = submenu
            popup.menu?.addItem(parent)
        }
        if linked {
            add("Separate USB Connection", "personalhotspot.slash", #selector(unlinkController(_:)))
        }
        popup.menu?.addItem(.separator())
        if bluetooth {
            add("Forget Device…", "trash", #selector(forgetController(_:)), enabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
        } else {
            add("Remove from List", "trash", #selector(removeControllerFromList(_:)), enabled: !entry.connected)
        }
        popup.bezelStyle = .inline
        popup.isBordered = false
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popup.toolTip = "More options for \(controllerDisplayName(entry))"
        popup.setAccessibilityLabel(popup.toolTip)
        popup.identifier = NSUserInterfaceItemIdentifier("controller-menu:" + entry.id)
        popup.widthAnchor.constraint(equalToConstant: 26).isActive = true
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    /// One Bluetooth identity and one USB identity can be joined. Same-model controllers are never merged automatically.
    func controllerLinkCandidates(for entry: ControllerEntry) -> [ControllerEntry] {
        guard !entry.id.contains("session:"), entry.id.hasPrefix("bt:") || entry.id.hasPrefix("hid:"),
              !isJoyCon(entry) else { return [] }
        return controllerEntries.filter {
            $0.id != entry.id && !$0.id.contains("session:") && !isJoyCon($0) &&
                (entry.id.hasPrefix("bt:") ? $0.id.hasPrefix("hid:") : $0.id.hasPrefix("bt:")) &&
                !($0.id.hasPrefix("bt:") && controllerAliases.values.contains($0.id)) &&
                !(entry.id.hasPrefix("bt:") && controllerAliases.values.contains(entry.id))
        }
    }

    func controllerRow(_ entry: ControllerEntry, compact: Bool, list: NSStackView,
                               position: Int, count: Int) -> NSView {
        let customization = controllerCustomizations[entry.id]
        let title = controllerDisplayName(entry)
        let handle = ControllerDragHandle()
        handle.toolTip = "Drag to reorder"
        handle.setAccessibilityLabel("Reorder \(title)")
        handle.onDrag = { [weak self, weak list] point in
            guard let self = self, let list = list else { return }
            self.dragController(entry.id, in: list, to: point)
        }
        handle.onDrop = { [weak self, weak list] point in
            guard let self = self, let list = list else { return }
            self.dropController(entry.id, in: list, at: point)
        }
        let kind = ControllerArtwork.kind(for: entry, artwork: customization?.artwork)
        let image = ControllerArtView(kind: kind)
        let plate = ControllerIconFrame(imageView: image, size: NSSize(width: 52, height: 38), inset: 2)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: compact ? 12 : 13)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = title == entry.name ? title : "\(title) · \(entry.name)"
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSTextField(labelWithString: controllerStatusText(entry, active: false))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let detail = NSStackView(views: [status] + controllerConnectionViews(entry))
        detail.orientation = .horizontal
        detail.spacing = 4
        detail.alignment = .centerY
        let labels = NSStackView(views: [label, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Short statuses beat stack hugging (250) but stay below window resizing (500); long names truncate first.
        detail.setContentCompressionResistancePriority(controllerStatusResistance, for: .horizontal)
        status.setContentCompressionResistancePriority(controllerStatusResistance, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        status.identifier = NSUserInterfaceItemIdentifier("controller-status")
        let reserved = status.widthAnchor.constraint(greaterThanOrEqualToConstant: controllerStatusWidth(status.font!))
        reserved.priority = controllerStatusResistance
        reserved.isActive = true
        let listID = list === homeControllerStatus ? 0 : 1
        let more = controllerMenuButton(entry, list: listID, position: position, count: count)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = row([handle, plate, labels, spacer, more])
        line.spacing = 10
        line.identifier = NSUserInterfaceItemIdentifier("controller-row:" + entry.id)
        if listID == 0 {
            homeControllerInputLabels[entry.id] = status
            homeControllerImages[entry.id] = [image]
            homeControllerRowViews[entry.id] = line
        } else {
            controllerInputLabels[entry.id] = status
            controllerImages[entry.id] = [image]
            controllerRowViews[entry.id] = line
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        }
        return line
    }

    func renderHomeControllers() {
        let connected = controllerEntries.filter(\.connected)
        for entry in connected where !homeObservedConnections.contains(entry.id) {
            homeSessionControllers.removeAll { $0 == entry.id }
            homeSessionControllers.append(entry.id)
        }
        homeObservedConnections = Set(connected.map(\.id))
        let knownIDs = Set(controllerEntries.map(\.id))
        homeSessionControllers = homeSessionControllers.map(canonicalControllerID).reduce(into: [String]()) { result, id in
            if !result.contains(id) && knownIDs.contains(id) { result.append(id) }
        }
        while homeSessionControllers.count > 4 {
            let index = homeSessionControllers.firstIndex { id in
                !connected.contains { $0.id == id }
            } ?? 0
            homeSessionControllers.remove(at: index)
        }
        let all = homeControllerList()
        let recent = Array(all.prefix(homeControllerLimit))
        // Rebuilding recreates every row and makes neighbours re-layout, so unchanged content is updated in place.
        let signature = homeControllerSignature(recent, total: all.count)
        if signature == homeControllerRenderedSignature, homeControllerRowIDs == recent.map(\.id) {
            for entry in recent { updateHomeControllerActivity(entry.id) }
            saveControllerPreferences()
            return
        }
        homeControllerRenderedSignature = signature
        homeControllerRenderCount += 1
        clearRows(homeControllerStatus)
        homeControllerInputLabels = [:]
        homeControllerImages = [:]
        homeControllerRowViews = [:]
        homeControllerRowIDs = recent.map(\.id)
        if recent.isEmpty {
            homeControllerStatus.addArrangedSubview(text("Connect via USB or Bluetooth", size: 13, secondary: true))
        }
        for (position, entry) in recent.enumerated() {
            let line = controllerRow(entry, compact: true, list: homeControllerStatus, position: position, count: recent.count)
            homeControllerStatus.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: homeControllerStatus.widthAnchor).isActive = true
            updateHomeControllerActivity(entry.id)
        }
        if all.count > recent.count {
            let more = all.count - recent.count
            let note = text("\(more) more in Controllers", size: 11, secondary: true)
            note.identifier = NSUserInterfaceItemIdentifier("home-controller-more")
            homeControllerStatus.addArrangedSubview(note)
        }
        if controllerInputUnavailable {
            homeControllerStatus.addArrangedSubview(text("Input activity unavailable. Check Input Monitoring in macOS Privacy & Security.", size: 12, secondary: true))
        }
        saveControllerPreferences()
    }

    func homeControllerSignature(_ entries: [ControllerEntry], total: Int) -> String {
        var parts = ["\(total)", "\(controllerInputUnavailable)"]
        for entry in entries {
            let customization = controllerCustomizations[entry.id]
            let battery = controllerBatteries[entry.id].map { "\(Int(($0.level * 100).rounded())):\($0.state.rawValue)" } ?? "-"
            parts.append([entry.id, entry.name, controllerDisplayName(entry), "\(entry.connected)", entry.transport,
                          "\(controllerBusy.contains(entry.id))", customization?.color ?? "",
                          customization?.artwork ?? "", battery].joined(separator: "\u{1f}"))
        }
        return parts.joined(separator: "\u{1e}")
    }

    func updateHomeControllerActivity(_ id: String) {
        let entry = controllerEntries.first { $0.id == id }
        let connected = entry?.connected == true
        let active = connected && (controllerLastInput[id].map { Date().timeIntervalSince($0.date) < 1.5 } ?? false)
        for label in [homeControllerInputLabels[id], controllerInputLabels[id]].compactMap({ $0 }) {
            if let entry = entry, label.stringValue != controllerStatusText(entry, active: active) {
                label.stringValue = controllerStatusText(entry, active: active)
                label.invalidateIntrinsicContentSize()
            }
        }
        let customization = controllerCustomizations[id]
        let colorName = entry.map { ControllerPalette.resolvedName(customization?.color, for: $0, artwork: customization?.artwork) } ?? "Black"
        let color = connected ? ControllerPalette.color(named: colorName) : .systemGray
        for image in (homeControllerImages[id] ?? []) + (controllerImages[id] ?? []) {
            image.contentTintColor = color
            image.alphaValue = connected ? 1 : 0.55
            image.wantsLayer = true
            image.setAccessibilityValue(active ? "Receiving input" : nil)
            if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if image.layer?.animation(forKey: "controllerActivity") == nil {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 1
                    pulse.toValue = 0.35
                    pulse.duration = 0.35
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    image.layer?.add(pulse, forKey: "controllerActivity")
                }
            } else { image.layer?.removeAnimation(forKey: "controllerActivity") }
        }
    }

    @objc func customizeController(_ sender: Any) {
        guard let id = controllerID(from: sender),
              let entry = controllerEntries.first(where: { $0.id == id }) else { return }
        let previous = controllerCustomizations[id]
        let alert = NSAlert()
        alert.messageText = "Customize controller"
        alert.informativeText = "Choose a name and icon color in Couch Cube. Leave the name empty to use \(entry.name)."
        let name = NSTextField(string: previous?.name ?? "")
        name.placeholderString = entry.name
        let color = ControllerPalette.menu(selecting: previous?.color ?? "",
                                           automatic: ControllerPalette.defaultName(for: entry, artwork: previous?.artwork))
        let artwork = ControllerArtwork.menu(selecting: previous?.artwork)
        let preview = ControllerCustomizationPreview(controllerName: entry.name, automaticModel: entry.model, colorPopup: color, artworkPopup: artwork)
        let pickers = NSStackView(views: [color, artwork])
        pickers.orientation = .vertical
        pickers.alignment = .leading
        pickers.spacing = 8
        let previewRow = NSStackView(views: [preview.iconFrame, pickers])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 12
        let contents = column([name, previewRow])
        contents.frame = NSRect(x: 0, y: 0, width: 340, height: 108)
        name.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = contents
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response = withExtendedLifetime(preview) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return }
        controllerCustomizations[id] = ControllerCustomization(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                                               color: preview.savedColor,
                                                               artwork: ControllerArtwork.selectedKind(in: artwork))
        renderControllerList()
        renderHomeControllers()
    }

    func controllerRowIDs(for list: Int) -> [String] { list == 0 ? homeControllerRowIDs : controllerRowIDs }

    /// Moves a controller inside the visible list. With Connected first on, it stays inside its own group.
    func moveController(_ id: String, toVisibleIndex index: Int, list: Int) {
        let visible = controllerRowIDs(for: list)
        guard let current = visible.firstIndex(of: id) else { return }
        var target = max(0, min(index, visible.count))
        if controllerConnectedFirst {
            let connectedIDs = Set(controllerEntries.filter(\.connected).map(\.id))
            let split = visible.filter { connectedIDs.contains($0) }.count
            target = connectedIDs.contains(id) ? min(target, split) : max(target, split)
        }
        if target > current { target -= 1 }
        guard target != current else { return }
        let ids = reorderedControllerIDs(controllerEntries.map(\.id), moving: id, to: target, among: visible)
        let byID = Dictionary(controllerEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        controllerEntries = ids.compactMap { byID[$0] }
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    @objc func moveControllerUp(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender),
              let index = controllerRowIDs(for: sender.tag).firstIndex(of: id) else { return }
        moveController(id, toVisibleIndex: index - 1, list: sender.tag)
    }

    @objc func moveControllerDown(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender),
              let index = controllerRowIDs(for: sender.tag).firstIndex(of: id) else { return }
        moveController(id, toVisibleIndex: index + 2, list: sender.tag)
    }

    func controllerDropIndex(in list: NSStackView, at point: NSPoint) -> Int {
        let local = list.convert(point, from: nil)
        let ids = list === homeControllerStatus ? homeControllerRowIDs : controllerRowIDs
        let views = list === homeControllerStatus ? homeControllerRowViews : controllerRowViews
        return ids.compactMap { views[$0] }.filter {
            list.isFlipped ? local.y > $0.frame.midY : local.y < $0.frame.midY
        }.count
    }

    func dragController(_ id: String, in list: NSStackView, to point: NSPoint) {
        let ids = list === homeControllerStatus ? homeControllerRowIDs : controllerRowIDs
        let views = (list === homeControllerStatus ? homeControllerRowViews : controllerRowViews)
        let rows = ids.compactMap { views[$0] }
        guard let last = rows.last, let first = rows.first else { return }
        views[id]?.alphaValue = 0.4
        let index = controllerDropIndex(in: list, at: point)
        let y: CGFloat
        if index < rows.count {
            y = list.isFlipped ? rows[index].frame.minY - 1 : rows[index].frame.maxY - 1
        } else {
            y = list.isFlipped ? last.frame.maxY - 1 : last.frame.minY - 1
        }
        controllerDropIndicator.boxType = .custom
        controllerDropIndicator.borderWidth = 0
        controllerDropIndicator.fillColor = .controlAccentColor
        controllerDropIndicator.cornerRadius = 1
        if controllerDropIndicator.superview !== list { list.addSubview(controllerDropIndicator) }
        controllerDropIndicator.frame = NSRect(x: first.frame.minX, y: y, width: first.frame.width, height: 2)
    }

    func dropController(_ id: String, in list: NSStackView, at point: NSPoint) {
        controllerDropIndicator.removeFromSuperview()
        let listID = list === homeControllerStatus ? 0 : 1
        (listID == 0 ? homeControllerRowViews : controllerRowViews)[id]?.alphaValue = 1
        moveController(id, toVisibleIndex: controllerDropIndex(in: list, at: point), list: listID)
    }

    func renderControllerList() {
        clearRows(activeControllerRows)
        controllerInputLabels = [:]
        controllerImages = [:]
        controllerRowViews = [:]
        let ordered = orderedControllers(controllerEntries)
        controllerRowIDs = ordered.map(\.id)
        let split = ordered.filter(\.connected).count
        for (position, entry) in ordered.enumerated() {
            if !activeControllerRows.arrangedSubviews.isEmpty {
                let line = separator()
                activeControllerRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            }
            if controllerConnectedFirst && position == split && split > 0 {
                addSectionHeading("Not connected", to: activeControllerRows)
            }
            let line = controllerRow(entry, compact: false, list: activeControllerRows, position: position, count: ordered.count)
            activeControllerRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            updateHomeControllerActivity(entry.id)
        }
        if ordered.isEmpty {
            activeControllerRows.addArrangedSubview(text("No controllers yet. Plug one in, or put a wireless one in pairing mode.", size: 12, secondary: true))
        }
        renderDiscoveredControllers()
    }

    /// Home and Controllers list the same discovered devices with the same real Connect action.
    func renderDiscoveredControllers() {
        // Refreshes and name callbacks repeat often; rebuilding identical rows would move the Connect button under the pointer.
        let signature = discoveredControllers.map { [$0.address, $0.name, "\(controllerBusy.contains("pair:" + $0.address))"]
            .joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        guard signature != discoveredControllersSignature else { return }
        discoveredControllersSignature = signature
        discoveredRenderCount += 1
        clearRows(discoveredControllerRows)
        clearRows(homeDiscoveredControllerRows)
        for device in discoveredControllers {
            discoveredControllerRows.addArrangedSubview(separator())
            let line = discoveredControllerRow(device, compact: false)
            discoveredControllerRows.addArrangedSubview(line)
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            for view in discoveredControllerRows.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: discoveredControllerRows.widthAnchor).isActive = true
            }
            let home = discoveredControllerRow(device, compact: true)
            homeDiscoveredControllerRows.addArrangedSubview(home)
            home.widthAnchor.constraint(equalTo: homeDiscoveredControllerRows.widthAnchor).isActive = true
        }
        discoveredControllerRows.isHidden = discoveredControllers.isEmpty
        homeDiscoveredControllerRows.isHidden = discoveredControllers.isEmpty
    }

    func discoveredControllerRow(_ device: PairedController, compact: Bool) -> NSView {
        let image = ControllerArtView(kind: ControllerArtwork.kind(name: device.name, preference: nil))
        image.contentTintColor = .tertiaryLabelColor
        let plate = ControllerIconFrame(imageView: image, size: NSSize(width: 52, height: 38), inset: 2)
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: compact ? 12 : 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pairing = controllerBusy.contains("pair:" + device.address)
        let status = NSTextField(labelWithString: pairing ? "Pairing…" : "Ready to pair")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let connect = NSButton(title: "Connect", target: self, action: #selector(pairDiscoveredController(_:)))
        connect.bezelStyle = .rounded
        connect.controlSize = compact ? .small : .regular
        connect.identifier = NSUserInterfaceItemIdentifier(device.address)
        connect.isEnabled = !pairing
        connect.setAccessibilityLabel("Connect \(device.name)")
        connect.widthAnchor.constraint(equalToConstant: compact ? 68 : 76).isActive = true
        connect.setContentCompressionResistancePriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = row([spacer, plate, labels, filler, connect])
        line.spacing = 10
        line.identifier = NSUserInterfaceItemIdentifier(compact ? "home-discovered-controller" : "discovered-controller")
        return line
    }

    func mergeControllerList(_ connected: [ControllerEntry], paired: [PairedController]) {
        let joyConIDs = Set((controllerEntries + connected).filter(isJoyCon).map(\.id) +
            paired.filter { ControllerArtwork.kind(name: $0.name, preference: nil).hasPrefix("Joy-Con") }
                .compactMap { controllerAddress($0.address).map { "bt:" + $0 } })
        controllerAliases = controllerAliases.filter { !joyConIDs.contains($0.key) && !joyConIDs.contains($0.value) }
        var knownBluetooth = Set(controllerEntries.map(\.id).filter { $0.hasPrefix("bt:") })
        for device in paired { if let address = controllerAddress(device.address) { knownBluetooth.insert("bt:" + address) } }
        var current: [String: ControllerEntry] = [:]
        for var entry in connected {
            if controllerAliases[entry.id] == nil,
               let alias = controllerProfileAlias(for: entry, knownBluetoothIDs: knownBluetooth) {
                adoptControllerProfile(entry.id, into: alias)
            }
            let id = canonicalControllerID(entry.id)
            if let existing = current[id], existing.transport == "Wired" { continue }
            entry = ControllerEntry(id: id, name: entry.name, connected: true, transport: entry.transport, model: entry.model)
            current[id] = entry
        }
        for device in paired {
            guard let address = controllerAddress(device.address) else { continue }
            let id = "bt:\(address)"
            if current[id] == nil {
                current[id] = ControllerEntry(id: id, name: device.name, connected: device.connected, transport: "Bluetooth",
                                              inputDetected: device.connected ? false : nil)
            } else if current[id]?.transport == "Bluetooth", current[id]?.name.lowercased().contains("joy-con") != true {
                current[id]?.name = device.name
            }
        }
        controllerEntries.removeAll { controllerAliases[$0.id] != nil }
        for index in controllerEntries.indices {
            if let updated = current.removeValue(forKey: controllerEntries[index].id) {
                controllerEntries[index] = updated
            } else {
                controllerEntries[index].connected = false
            }
        }
        controllerEntries += current.values.sorted { $0.id < $1.id }
        controllerEntries.removeAll { !$0.connected && $0.id.contains("session:") && !homeSessionControllers.contains($0.id) }
        controllerBusy = controllerBusy.filter { id in !controllerEntries.contains { $0.id == id && $0.connected } }
        discoveredControllers.removeAll { device in
            controllerAddress(device.address).map { knownBluetooth.contains("bt:" + $0) } ?? true
        }
        updateControllerBatteries()
        renderControllerList()
        renderHomeControllers()
    }

    /// GameController exposes battery per controller but not its HID or Bluetooth identity, so only unambiguous names are matched.
    func updateControllerBatteries() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        var batteries: [String: (level: Float, state: GCDeviceBattery.State)] = [:]
        let gameControllers = GCController.controllers()
        let connected = controllerEntries.filter(\.connected)
        for entry in connected {
            let matches = gameControllers.filter { $0.vendorName == entry.name }
            guard matches.count == 1, connected.filter({ $0.name == entry.name }).count == 1,
                  let battery = matches[0].battery else { continue }
            batteries[entry.id] = (battery.batteryLevel, battery.batteryState)
        }
        controllerBatteries = batteries
    }

    @objc func linkControllers(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let bluetooth = pair.first { $0.hasPrefix("bt:") }
        let usb = pair.first { $0.hasPrefix("hid:") }
        guard let canonical = bluetooth, let alias = usb,
              let canonicalEntry = controllerEntries.first(where: { $0.id == canonical }),
              let aliasEntry = controllerEntries.first(where: { $0.id == alias }) else { return }
        let alert = NSAlert()
        alert.messageText = "Use one profile for both connections?"
        alert.informativeText = "\(controllerDisplayName(canonicalEntry)) over Bluetooth and \(controllerDisplayName(aliasEntry)) over USB will share one name, color and place in the list. Only do this for the same physical controller."
        alert.addButton(withTitle: "Use One Profile")
        alert.addButton(withTitle: "Cancel")
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test") || alert.runModal() == .alertFirstButtonReturn else { return }
        linkController(alias, to: canonical)
    }

    /// Automatic, device-proven link: the USB profile moves onto the Bluetooth-address profile, keeping its list place.
    func adoptControllerProfile(_ alias: String, into canonical: String) {
        guard alias != canonical else { return }
        for (key, value) in controllerAliases where value == alias { controllerAliases[key] = canonical }
        controllerAliases[alias] = canonical
        if let custom = controllerCustomizations.removeValue(forKey: alias), controllerCustomizations[canonical] == nil {
            controllerCustomizations[canonical] = custom
        }
        if !controllerEntries.contains(where: { $0.id == canonical }),
           let index = controllerEntries.firstIndex(where: { $0.id == alias }) {
            let old = controllerEntries[index]
            controllerEntries[index] = ControllerEntry(id: canonical, name: old.name, connected: old.connected,
                                                       transport: old.transport, model: old.model)
        }
        homeSessionControllers = homeSessionControllers.map { $0 == alias ? canonical : $0 }
    }

    func linkController(_ alias: String, to canonical: String) {
        guard !controllerEntries.contains(where: { ($0.id == alias || $0.id == canonical) && isJoyCon($0) }) else { return }
        for (key, value) in controllerAliases where value == alias { controllerAliases[key] = canonical }
        controllerAliases[alias] = canonical
        if controllerCustomizations[canonical] == nil, let custom = controllerCustomizations[alias] {
            controllerCustomizations[canonical] = custom
        }
        controllerCustomizations[alias] = nil
        if let aliasEntry = controllerEntries.first(where: { $0.id == alias }), aliasEntry.connected,
           let index = controllerEntries.firstIndex(where: { $0.id == canonical }) {
            controllerEntries[index].connected = true
            controllerEntries[index].transport = aliasEntry.transport
        }
        controllerEntries.removeAll { $0.id == alias }
        homeSessionControllers = homeSessionControllers.map(canonicalControllerID)
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    @objc func unlinkController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender) else { return }
        controllerAliases = controllerAliases.filter { $0.value != id }
        saveControllerPreferences()
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            renderControllerList()
            renderHomeControllers()
        } else {
            refreshControllers()
        }
    }

    @objc func removeControllerFromList(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender),
              controllerEntries.first(where: { $0.id == id })?.connected == false else { return }
        controllerEntries.removeAll { $0.id == id }
        controllerCustomizations[id] = nil
        controllerAliases = controllerAliases.filter { $0.key != id && $0.value != id }
        homeSessionControllers.removeAll { $0 == id }
        saveControllerPreferences()
        renderControllerList()
        renderHomeControllers()
    }

    func bluetoothDevice(for id: String) -> IOBluetoothDevice? {
        guard id.hasPrefix("bt:"), let address = controllerAddress(String(id.dropFirst(3))) else { return nil }
        return IOBluetoothDevice(addressString: dashedControllerAddress(address))
    }

    /// Connect/pair problems stay in the app. Bluetooth Settings only opens from its own explicit header button.
    func showControllerError(_ title: String, _ message: String) {
        append("\(title): \(message)\n")
        controllerErrors.append(title)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func bluetoothErrorText(_ code: IOReturn) -> String {
        String(format: "macOS Bluetooth error 0x%08X.", UInt32(bitPattern: code))
    }

    @objc func connectController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender) else { return }
        guard CBManager.authorization == .allowedAlways else {
            showControllerError("Bluetooth access needed", "Allow Bluetooth access for Couch Cube, then try again.")
            return
        }
        guard let device = bluetoothDevice(for: id) else {
            showControllerError("Couldn't find this controller", "macOS has no Bluetooth device with this address.")
            return
        }
        let result = device.openConnection(self)
        guard result == kIOReturnSuccess else {
            showControllerError("Couldn't connect", "\(bluetoothErrorText(result)) Turn the controller on, or press its home button, then try again.")
            return
        }
        controllerBusy.insert(id)
        renderControllerList()
        renderHomeControllers()
    }

    @objc(connectionComplete:status:) func bluetoothConnectionComplete(_ device: IOBluetoothDevice?, status: IOReturn) {
        DispatchQueue.main.async {
            if let address = device?.addressString.flatMap(controllerAddress) { self.controllerBusy.remove("bt:" + address) }
            if status != kIOReturnSuccess && device?.isConnected() != true {
                self.showControllerError("Couldn't connect",
                    "\(self.bluetoothErrorText(status)) Most controllers connect when you press their home button. If it still fails, forget it and pair again.")
            }
            self.refreshControllers()
        }
    }

    @objc func disconnectController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender), let device = bluetoothDevice(for: id) else { return }
        let result = device.closeConnection()
        if result != kIOReturnSuccess {
            showControllerError("Couldn't disconnect", "\(bluetoothErrorText(result)) Turn the controller off, or disconnect it in Bluetooth Settings.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshControllers() }
    }

    @objc func forgetController(_ sender: NSMenuItem) {
        guard let id = controllerID(from: sender), let entry = controllerEntries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(controllerDisplayName(entry))?"
        alert.informativeText = "Its name, color and icon come back if you pair it again."
        alert.addButton(withTitle: "Forget Device")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Forget and Delete Profile")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.last?.hasDestructiveAction = true
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertThirdButtonReturn else { return }
        let deleteProfile = response == .alertThirdButtonReturn
        guard let device = bluetoothDevice(for: id) else {
            showControllerError("Couldn't forget this controller", "macOS has no Bluetooth device with this address.")
            return
        }
        // macOS has no public unpair API. This uses IOBluetooth's remove method when available and verifies the result.
        let remove = Selector(("remove"))
        if device.responds(to: remove) { _ = device.perform(remove) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if device.isPaired() {
                self.showControllerError("Forget it in Bluetooth Settings",
                    "This version of macOS didn't let Couch Cube remove the pairing. In Bluetooth Settings, choose ⓘ next to \(entry.name), then Forget This Device.")
                return
            }
            self.forgetControllerPairing(id, deleteProfile: deleteProfile)
            self.refreshControllers()
        }
    }

    /// Forgetting removes the Mac's pairing and the list row only. Name, color, icon and links stay keyed by the
    /// controller's Bluetooth address, so pairing it again restores them, unless the profile is explicitly deleted.
    func forgetControllerPairing(_ id: String, deleteProfile: Bool) {
        controllerEntries.removeAll { $0.id == id }
        homeSessionControllers.removeAll { $0 == id }
        if deleteProfile {
            controllerCustomizations[id] = nil
            controllerAliases = controllerAliases.filter { $0.value != id }
        }
        saveControllerPreferences()
    }

    func startControllerDiscovery() {
        guard bluetoothInquiry == nil, !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              CBManager.authorization == .allowedAlways, bluetoothManager?.state == .poweredOn,
              controllerPageVisible else { return }
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else { return }
        inquiry.inquiryLength = 8
        inquiry.updateNewDeviceNames = true
        let result = inquiry.start()
        guard result == kIOReturnSuccess else {
            append("Bluetooth controller search failed: \(bluetoothErrorText(result))\n")
            return
        }
        bluetoothInquiry = inquiry
    }

    func stopControllerDiscovery() {
        bluetoothInquiry?.stop()
        bluetoothInquiry = nil
        bluetoothInquiryRestart?.cancel()
        bluetoothInquiryRestart = nil
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        addDiscoveredController(device)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        addDiscoveredController(device)
    }

    func addDiscoveredController(_ device: IOBluetoothDevice?) {
        guard let device = device, !device.isPaired(), let name = device.name,
              isBluetoothController(deviceClass: device.classOfDevice, name: name),
              let raw = device.addressString, controllerAddress(raw) != nil else { return }
        let found = PairedController(name: name, address: raw, connected: false)
        if let index = discoveredControllers.firstIndex(where: { controllerAddress($0.address) == controllerAddress(raw) }) {
            discoveredControllers[index] = found
        } else {
            discoveredControllers.append(found)
        }
        renderDiscoveredControllers()
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        bluetoothInquiry = nil
        guard !aborted else { return }
        if error != kIOReturnSuccess { append("Bluetooth controller search ended: \(bluetoothErrorText(error))\n") }
        let restart = DispatchWorkItem { [weak self] in
            self?.bluetoothInquiryRestart = nil
            self?.startControllerDiscovery()
        }
        bluetoothInquiryRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: restart)
    }

    @objc func pairDiscoveredController(_ sender: NSButton) {
        guard let address = sender.identifier?.rawValue, bluetoothPairing == nil,
              !controllerBusy.contains(where: { $0.hasPrefix("pair:") }) else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            smokePairRequests.append(address)
            return
        }
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        let scanning = bluetoothInquiry != nil
        stopControllerDiscovery()
        controllerBusy.insert("pair:" + address)
        renderDiscoveredControllers()
        // Paging a controller while the discovery scan is still winding down can fail; give the radio a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + (scanning ? 0.8 : 0)) { [weak self] in
            self?.startPairing(device, address: address)
        }
    }

    func startPairing(_ device: IOBluetoothDevice, address: String) {
        guard let pairing = IOBluetoothDevicePair(device: device) else {
            controllerBusy.remove("pair:" + address)
            renderDiscoveredControllers()
            showControllerError("Couldn't pair", "macOS couldn't start pairing with this controller.")
            startControllerDiscovery()
            return
        }
        pairing.delegate = self
        let result = pairing.start()
        guard result == kIOReturnSuccess else {
            controllerBusy.remove("pair:" + address)
            renderDiscoveredControllers()
            showControllerError("Couldn't pair", "\(bluetoothErrorText(result)) Put the controller back in pairing mode and try again.")
            startControllerDiscovery()
            return
        }
        bluetoothPairing = pairing
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        let alert = NSAlert()
        alert.messageText = "Confirm pairing code"
        alert.informativeText = "Does the controller show \(String(format: "%06u", numericValue))? If it has no screen, click Pair."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        bluetoothPairing?.replyUserConfirmation(alert.runModal() == .alertFirstButtonReturn)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        bluetoothPairing?.stop()
        bluetoothPairing = nil
        controllerBusy = controllerBusy.filter { !$0.hasPrefix("pair:") }
        renderDiscoveredControllers()
        showControllerError("PIN code needed", "This controller asks for a PIN code, which Couch Cube can't enter. Pair it in Bluetooth Settings instead.")
        startControllerDiscovery()
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let device = bluetoothPairing?.device()
        bluetoothPairing = nil
        controllerBusy = controllerBusy.filter { !$0.hasPrefix("pair:") }
        if error != kIOReturnSuccess && device?.isPaired() != true {
            showControllerError("Couldn't pair", "\(bluetoothErrorText(error)) Put the controller back in pairing mode and try again.")
            renderDiscoveredControllers()
        } else if let device = device {
            discoveredControllers.removeAll { controllerAddress($0.address) == device.addressString.flatMap(controllerAddress) }
            if !device.isConnected() { _ = device.openConnection(self) }
            if !device.isConnected(), let address = device.addressString.flatMap(controllerAddress) { controllerBusy.insert("bt:" + address) }
        }
        refreshControllers()
        startControllerDiscovery()
    }

    func startControllerTest() {
        guard controllerInputManager == nil, !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context = context else { return }
            let owner = Unmanaged<SetupController>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard let message = controllerInputDescription(page: IOHIDElementGetUsagePage(element),
                    usage: IOHIDElementGetUsage(element), value: IOHIDValueGetIntegerValue(value),
                    minimum: IOHIDElementGetLogicalMin(element), maximum: IOHIDElementGetLogicalMax(element)) else { return }
            owner.receiveControllerInput(hidControllerEntry(device), message: message)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            controllerTestStatus.stringValue = "Couldn't start the controller test. Check macOS Privacy & Security → Input Monitoring if access was denied, then reopen this page."
            controllerInputUnavailable = true
            renderHomeControllers()
            append("Controller input access failed: \(result)\n")
            return
        }
        controllerInputManager = manager
        controllerInputUnavailable = false
        controllerTestStatus.stringValue = "Press a button or move a stick to identify and test a controller."
    }

    func stopControllerTest() {
        guard let manager = controllerInputManager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        controllerInputManager = nil
        controllerLastInput = [:]
    }

    func receiveControllerInput(_ raw: ControllerEntry, message: String) {
        guard controllerPageVisible else { return }
        let entry = ControllerEntry(id: canonicalControllerID(raw.id), name: raw.name, connected: true, transport: raw.transport)
        let now = Date()
        if let last = controllerLastInput[entry.id], last.message == message && now.timeIntervalSince(last.date) < 0.1 { return }
        if !controllerEntries.contains(where: { $0.id == entry.id }) {
            controllerEntries.append(entry)
            renderControllerList()
            renderHomeControllers()
        } else if let index = controllerEntries.firstIndex(where: { $0.id == entry.id }),
                  !controllerEntries[index].connected {
            controllerEntries[index].connected = true
            controllerEntries[index].transport = entry.transport
            renderControllerList()
            renderHomeControllers()
        }
        controllerLastInput[entry.id] = (message, now)
        if tabs.selectedTabViewItem === tabs.tabViewItems[8] {
            let name = controllerCustomizations[entry.id]?.name ?? ""
            controllerTestStatus.stringValue = "\(name.isEmpty ? entry.name : name) · \(message)"
        }
        updateHomeControllerActivity(entry.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let last = self.controllerLastInput[entry.id],
                  last.date == now else { return }
            self.updateHomeControllerActivity(entry.id)
        }
    }

    func updateControllerBanner() {
        var visible = true
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            visible = controllerSmokeBanner
            controllerAccessButton.title = "Allow Bluetooth Access"
            controllerStatus.stringValue = "Allow Bluetooth access to see and connect paired controllers. USB controllers work without it."
        } else {
            switch CBManager.authorization {
            case .notDetermined:
                controllerAccessButton.title = "Allow Bluetooth Access"
                controllerAccessButton.isHidden = false
                controllerStatus.stringValue = "Allow Bluetooth access to see and connect paired controllers. USB controllers work without it."
            case .denied, .restricted:
                controllerAccessButton.title = "Open Privacy Settings"
                controllerAccessButton.isHidden = false
                controllerStatus.stringValue = "Bluetooth access is off for Couch Cube. Turn it on in Privacy & Security → Bluetooth."
            case .allowedAlways:
                controllerAccessButton.isHidden = true
                if bluetoothManager?.state == .poweredOff {
                    controllerAccessButton.title = "Bluetooth Settings"
                    controllerAccessButton.isHidden = false
                    controllerStatus.stringValue = "Bluetooth is off. Turn it on to use wireless controllers."
                } else {
                    visible = false
                }
            @unknown default:
                visible = false
            }
        }
        if controllerInputUnavailable {
            visible = true
            controllerStatus.stringValue += (controllerStatus.stringValue.isEmpty ? "" : " ") +
                "Input activity unavailable. Check Input Monitoring in Privacy & Security."
        }
        controllerBanner.isHidden = !visible
        renderGeneral()
    }

    @objc func refreshControllers() {
        guard controllerPageVisible, !controllerQueryRunning else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            controllerEntries = [
                ControllerEntry(id: "preview:1", name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"),
                ControllerEntry(id: "preview:2", name: "Xbox Wireless Controller", connected: false, transport: "Bluetooth"),
                ControllerEntry(id: "preview:3", name: "8BitDo Controller", connected: true, transport: "Wired")
            ]
            controllerCustomizations["preview:1"] = ControllerCustomization(name: "Purple PS5", color: "Galactic Purple")
            controllerBatteries = ["preview:1": (0.25, .discharging), "preview:3": (0.6, .charging)]
            discoveredControllers = [PairedController(name: "Pro Controller", address: "98-b6-e9-00-00-01", connected: false)]
            updateControllerBanner()
            renderControllerList()
            renderHomeControllers()
            return
        }
        if CBManager.authorization == .allowedAlways && bluetoothManager == nil {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        updateControllerBanner()
        controllerQueryRunning = true
        let readBluetooth = CBManager.authorization == .allowedAlways
        DispatchQueue.global(qos: .userInitiated).async {
            let connected = connectedHIDControllers()
            let devices = readBluetooth ?
                (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> PairedController? in
                    let name = device.name ?? "Game controller"
                    guard isBluetoothController(deviceClass: device.classOfDevice, name: name) else { return nil }
                    return PairedController(name: name, address: device.addressString ?? "Address unavailable", connected: device.isConnected())
                } : []
            DispatchQueue.main.async {
                self.controllerQueryRunning = false
                guard self.controllerPageVisible else { return }
                self.pairedControllers = CBManager.authorization == .allowedAlways ? devices : []
                self.mergeControllerList(connected, paired: self.pairedControllers)
                self.startControllerDiscovery()
            }
        }
    }
}
