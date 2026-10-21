import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    @objc func loadApps() { fetchApps(updates: true) }

    /// Launch preload: App Store data loads in the background once no other command is running.
    func runPendingAppsPreload() {
        if appsPreloadPending && task == nil && !smokeFinishing { fetchApps(updates: true) }
    }

    func fetchApps(updates: Bool, completed: ((Bool) -> Void)? = nil) {
        guard task == nil else {
            if completed == nil { appRefreshPending = true }
            appsStatus.stringValue = "An operation is running. App information will refresh when it finishes."
            completed?(false)
            return
        }
        appRefreshPending = false
        appsPreloadPending = false
        loadWindowsDownloads()
        let silent = appsHaveResults
        appsChecking = !silent
        if appStates.isEmpty {
            appsHaveResults = false
            let catalog = [
                ("steam", "Steam"), ("gog-galaxy", "GOG Galaxy"), ("ea", "EA app"),
                ("epic-games", "Epic Games Launcher"), ("battle-net", "Battle.net"),
                ("curseforge", "CurseForge"), ("es-de", "ES-DE"),
                ("retroarch-metal", "RetroArch"), ("dolphin", "Dolphin"),
                ("pcsx2", "PCSX2"), ("rpcs3", "RPCS3"), ("cemu-wiiu", "Cemu"),
                ("switch", "Ryujinx"), ("porting-kit", "Porting Kit"), ("crossover", "CrossOver")
            ]
            appStates = catalog.map {
                ManagedApp(id: $0.0, name: $0.1, installed: false, path: "", version: "",
                           managed: false, update: nil, manual: false, brew: false, url: nil)
            }
        }
        if !silent { renderApps() }
        appsStatus.stringValue = ""
        appsLoadGeneration += 1
        let generation = appsLoadGeneration
        backendRead(updates ? ["apps", "--updates"] : ["apps"]) { code, data in
            guard generation == self.appsLoadGeneration else { return }
            self.appsChecking = false
            if self.overviewChecks.remove(.apps) != nil { self.renderGeneral() }
            guard code == 0 else {
                self.renderApps()
                self.appsStatus.stringValue = "Couldn't read apps. Open Activity for the error."
                self.activityNeeded()
                completed?(false)
                return
            }
            do {
                let decoded = try JSONDecoder().decode([ManagedApp].self, from: data)
                // Unchanged results keep the rendered rows (scroll position, hover, focus) untouched.
                let unchanged = silent && data == self.lastAppsData
                self.lastAppsData = data
                self.appStates = decoded
                // A fresh full check supersedes earlier inline failures.
                let failures = self.appOperations.filter { !$0.value.running }.count
                self.appOperations = self.appOperations.filter { $0.value.running }
                self.appsHaveResults = true
                self.helperButton.isHidden = self.appStates.first?.brew == true
                self.helperAdvice.isHidden = self.helperButton.isHidden
                if let report = self.report {
                    self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                             missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                             preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                    self.updateSetupSummary()
                }
                if !unchanged || failures > 0 { self.renderApps() }
                self.renderTVMenus()
                self.renderGeneral()
                if self.collapsedAppCategories.isEmpty {
                    precondition(self.appMenuRows.arrangedSubviews.count == 4)
                    precondition(self.appPCRows.arrangedSubviews.count == 12)
                    precondition(self.appWindowsRows.arrangedSubviews.count == 4 + 2 * self.windowsDownloads.count)
                    precondition(self.appRetroRows.arrangedSubviews.count == 12)
                }
                precondition(Set([self.appMenuRows, self.appPCRows, self.appWindowsRows, self.appRetroRows]
                    .compactMap { $0.superview?.superview }.map { ObjectIdentifier($0) }).count == 4,
                    "Each Apps category must have its own card")
                self.appsStatus.stringValue = ""
                self.backendRead(["frontend"]) { code, data in
                    guard code == 0 else {
                        self.tvMenuStatus.stringValue = "Couldn't read the default menu. Open Activity for details."
                        completed?(false)
                        return
                    }
                    do {
                        self.preferredFrontend = try JSONDecoder().decode(FrontendPreference.self, from: data).preferred
                        self.renderTVMenus()
                        self.updateSetupSummary()
                        completed?(true)
                    } catch {
                        self.tvMenuStatus.stringValue = "Couldn't read TV menu preference: \(error.localizedDescription)"
                        self.append(self.tvMenuStatus.stringValue + "\n")
                        completed?(false)
                    }
                }
            } catch {
                self.renderApps()
                self.appsStatus.stringValue = "Couldn't read app information: \(error.localizedDescription)"
                self.append(self.appsStatus.stringValue + "\n")
                completed?(false)
            }
        }
    }

    func clearRows(_ stack: NSStackView) {
        actions.removeAll { $0.isDescendant(of: stack) }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    func appCategoryTitle(for rows: NSStackView) -> String {
        rows === appMenuRows ? "TV menus" : rows === appPCRows ? "PC games" :
            rows === appWindowsRows ? "Windows games" : "Retro games"
    }

    func appCategoryCard(_ title: String, rows: NSStackView, extra: [NSView] = []) -> NSBox {
        let toggle = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!,
                              target: self, action: #selector(toggleAppCategory(_:)))
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        toggle.identifier = NSUserInterfaceItemIdentifier(title)
        appCategoryToggles[title] = toggle
        updateAppCategoryToggle(title)
        return card("", subtitle: nil, views: [cardHeader(title, buttons: extra + [toggle]), rows])
    }

    func updateAppCategoryToggle(_ title: String) {
        guard let toggle = appCategoryToggles[title] else { return }
        let collapsed = collapsedAppCategories.contains(title)
        toggle.image = NSImage(systemSymbolName: collapsed ? "chevron.up" : "chevron.down",
                               accessibilityDescription: nil)
        toggle.toolTip = collapsed ? "Show all \(title)" : "Show installed \(title) only"
        toggle.setAccessibilityLabel(toggle.toolTip)
    }

    @objc func toggleAppCategory(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue else { return }
        if collapsedAppCategories.contains(title) { collapsedAppCategories.remove(title) }
        else { collapsedAppCategories.insert(title) }
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            UserDefaults.standard.set(collapsedAppCategories.sorted(), forKey: collapsedAppCategoriesKey)
        }
        updateAppCategoryToggle(title)
        renderApps()
    }

    func renderApps() {
        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] { clearRows(rows) }
        var hiddenApps: [ObjectIdentifier: Int] = [:]
        let order = ["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch", "porting-kit", "crossover"]
        appStates.sort { (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100) }
        for (index, app) in appStates.enumerated() {
            for placement in appPlacements(app) {
                if !appPlacementVisible(app, placement) {
                    hiddenApps[ObjectIdentifier(placement.rows), default: 0] += 1
                    continue
                }
                addAppRow(app, index: index, to: placement.rows, title: placement.title, purpose: placement.purpose)
            }
        }
        for item in windowsDownloads {
            if !item.downloaded && windowsDownloadJobs[item.id] == nil && collapsedAppCategories.contains("Windows games") {
                hiddenApps[ObjectIdentifier(appWindowsRows), default: 0] += 1
                continue
            }
            addRow(makeWindowsDownloadRow(item), to: appWindowsRows)
        }
        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] {
            guard let hidden = hiddenApps[ObjectIdentifier(rows)] else { continue }
            let note = text("\(hidden) more app\(hidden == 1 ? "" : "s") to get · Expand to show",
                            size: 11, secondary: true)
            note.identifier = NSUserInterfaceItemIdentifier("app-hidden-note")
            rows.addArrangedSubview(note)
        }
        updateAllButton.isEnabled = task == nil && appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
        updateAllButton.isHidden = !appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
        if highlightedAppID != nil { DispatchQueue.main.async { self.highlightAppRow() } }
    }

    /// Every place an app is listed. One app can appear in several categories (Steam is both a TV menu and a PC game app);
    /// all its rows are built from the same app state and operation, so they always show the same status.
    func appPlacements(_ app: ManagedApp) -> [(rows: NSStackView, title: String?, purpose: String?)] {
        if app.id == "steam" { return [(appMenuRows, "Steam Big Picture", "Steam TV menu"), (appPCRows, nil, nil)] }
        let rows = app.id == "es-de" ? appMenuRows :
            computerGameApps.contains(app.id) ? appPCRows :
            ["porting-kit", "crossover"].contains(app.id) ? appWindowsRows : appRetroRows
        return [(rows, nil, nil)]
    }

    func appPlacementVisible(_ app: ManagedApp, _ placement: (rows: NSStackView, title: String?, purpose: String?)) -> Bool {
        app.installed || !collapsedAppCategories.contains(appCategoryTitle(for: placement.rows))
    }

    func appPillButton(_ title: String, app: ManagedApp, index: Int,
                               action: Selector, destructive: Bool = false) -> NSButton {
        let control: NSButton
        if destructive {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.addItem(withTitle: "")
            popup.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
            let open = NSMenuItem(title: "Open", action: #selector(openAppFromMenu(_:)), keyEquivalent: "")
            open.target = self
            open.tag = index
            open.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            popup.menu?.addItem(open)
            let update = NSMenuItem(title: "Update", action: #selector(updateAppFromMenu(_:)), keyEquivalent: "")
            update.target = self
            update.tag = index
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            popup.menu?.addItem(update)
            popup.menu?.autoenablesItems = false
            update.isEnabled = app.managed && app.update?.isEmpty == false
            let remove = NSMenuItem(title: "Remove…", action: #selector(removeAppFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            popup.menu?.addItem(remove)
            popup.bezelStyle = .inline
            popup.isBordered = false
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            control = popup
        } else {
            control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded
            control.controlSize = .regular
        }
        control.setButtonType(.momentaryChange)
        control.tag = index
        control.toolTip = destructive ? "More options for \(app.name)" : "\(title) \(app.name)"
        control.setAccessibilityLabel(control.toolTip)
        control.widthAnchor.constraint(equalToConstant: destructive ? 26 : title == "Get" ? 64 : 76).isActive = true
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        actions.append(control)
        return control
    }

    /// The Porting Kit folder pinned to Finder's sidebar by Couch Cube, while it is still there.
    var pinnedPortingKitFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: "portingKitPinnedFolder") else { return nil }
        let url = URL(fileURLWithPath: path)
        return ProcessInfo.processInfo.arguments.contains("--smoke-test") || FinderSidebar.contains(url) ? url : nil
    }

    /// Makes the library's Windows/Porting Kit folder and pins it to the top of Finder's sidebar (which Porting Kit's
    /// folder dialog shows too), so it's one click away; Unpin Folder takes it off again. If macOS doesn't allow the
    /// pin, the path goes on the clipboard instead. Porting Kit's own setting isn't changed for you.
    @objc func preparePortingKitFolder() {
        if let pinned = pinnedPortingKitFolder {
            FinderSidebar.unpin(pinned)
            UserDefaults.standard.removeObject(forKey: "portingKitPinnedFolder")
            appsStatus.stringValue = "Removed the Porting Kit folder from Finder's sidebar."
            renderApps()
            return
        }
        guard let drive = selected else { return }
        runBackendInBackground(["porting-kit-folder", "--root", drive.root]) { [weak self] code, data, errors in
            guard let self else { return }
            guard code == 0, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: String], let path = reply["path"] else {
                self.appsStatus.stringValue = "Couldn't make the Porting Kit folder: " + backendErrorMessage(errors, fallback: "check Game library.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            if FinderSidebar.pin(URL(fileURLWithPath: path)) {
                UserDefaults.standard.set(path, forKey: "portingKitPinnedFolder")
                self.appsStatus.stringValue = "\u{201C}Porting Kit\u{201D} is now at the top of the sidebar in Finder and in Porting Kit's folder dialog. In Porting Kit, choose Change for \u{201C}Applications default path\u{201D} and pick it, then choose Unpin Folder here."
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                self.appsStatus.stringValue = "Path copied. In Porting Kit, choose Change for \u{201C}Applications default path\u{201D}, press \u{2318}\u{21E7}G, paste and press Return. New ports then appear in Play."
            }
            self.renderApps()
        }
    }

    @objc func openAppManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAppFromMenu(_ sender: NSMenuItem) {
        guard appStates.indices.contains(sender.tag), !appStates[sender.tag].path.isEmpty else { return }
        let app = appStates[sender.tag]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { self.appsStatus.stringValue = "Couldn't open \(app.name): \(error.localizedDescription)" }
        }
    }

    @objc func removeAppFromMenu(_ sender: NSMenuItem) {
        let control = NSButton()
        control.tag = sender.tag
        appAction(control)
    }

    @objc func updateAppFromMenu(_ sender: NSMenuItem) {
        let control = NSButton()
        control.tag = sender.tag
        updateApp(control)
    }

    func addAppRow(_ app: ManagedApp, index: Int, to rows: NSStackView, title: String? = nil,
                           purpose: String? = nil) {
        addRow(makeAppRow(app, index: index, title: title, purpose: purpose), to: rows)
    }

    func addRow(_ line: NSView, to rows: NSStackView) {
        rows.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        let separator = self.separator()
        rows.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    /// Replaces only this app's row(s) in place, so the list keeps its scroll position and other rows don't flicker.
    func refreshAppRow(_ id: String) {
        guard let index = appStates.firstIndex(where: { $0.id == id }) else { return }
        let app = appStates[index]
        let placements = appPlacements(app).filter { appPlacementVisible(app, $0) }
        let existing = [appMenuRows, appPCRows, appWindowsRows, appRetroRows].flatMap { rows in
            rows.arrangedSubviews.filter { $0.identifier?.rawValue == "app-row-" + id }.map { (rows, $0) }
        }
        // A row appeared or disappeared (for example in a collapsed category): rebuild the list instead.
        guard existing.count == placements.count,
              zip(existing, placements).allSatisfy({ $0.0 === $1.rows }) else { return renderApps() }
        for ((rows, old), placement) in zip(existing, placements) {
            guard let position = rows.arrangedSubviews.firstIndex(of: old) else { continue }
            let line = makeAppRow(app, index: index, title: placement.title, purpose: placement.purpose)
            actions.removeAll { $0.isDescendant(of: old) }
            rows.insertArrangedSubview(line, at: position)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            rows.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
    }

    func loadWindowsDownloads(verifying id: String? = nil) {
        windowsDownloadsGeneration += 1
        let generation = windowsDownloadsGeneration
        windowsDownloadsRead { [weak self] code, data in
            guard let self, generation == self.windowsDownloadsGeneration else { return }
            let reply = code == 0 ? try? JSONDecoder().decode(WindowsDownloadsReply.self, from: data) : nil
            if let id, self.windowsDownloadJobs[id]?.running == true {
                if reply?.items.first(where: { $0.id == id })?.downloaded == true {
                    self.windowsDownloadJobs[id] = nil
                } else {
                    self.windowsDownloadJobs[id]?.running = false
                    self.windowsDownloadJobs[id]?.failure = "The download finished, but Couch Cube couldn't find the installer in Downloads."
                }
            }
            guard let reply else {
                if let id { self.refreshWindowsDownloadRow(id) }
                return
            }
            let changedList = reply.items.map(\.id) != self.windowsDownloads.map(\.id)
            let changed = reply.items.filter { item in self.windowsDownloads.first { $0.id == item.id } != item }.map(\.id)
            let libraryChanged = reply.library != self.windowsLibrary
            self.windowsDownloads = reply.items
            self.windowsLibrary = reply.library
            if changedList || libraryChanged { self.renderApps() }
            else { Set(changed + (id.map { [$0] } ?? [])).forEach { self.refreshWindowsDownloadRow($0) } }
        }
    }

    func refreshWindowsDownloadRow(_ id: String) {
        guard let item = windowsDownloads.first(where: { $0.id == id }),
              let old = appWindowsRows.arrangedSubviews.first(where: { $0.identifier?.rawValue == "win-row-" + id }),
              let position = appWindowsRows.arrangedSubviews.firstIndex(of: old) else { return renderApps() }
        let line = makeWindowsDownloadRow(item)
        actions.removeAll { $0.isDescendant(of: old) }
        appWindowsRows.insertArrangedSubview(line, at: position)
        line.widthAnchor.constraint(equalTo: appWindowsRows.widthAnchor).isActive = true
        appWindowsRows.removeArrangedSubview(old)
        old.removeFromSuperview()
    }

    func makeWindowsDownloadRow(_ item: WindowsDownloadItem) -> NSView {
        let index = windowsDownloads.firstIndex(of: item) ?? 0
        let job = windowsDownloadJobs[item.id]
        let controls = row([])
        if job?.running == true {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.minValue = 0
            progress.maxValue = 1
            // Determinate only from the real byte count; spins when the server didn't send a size.
            progress.isIndeterminate = (job?.total ?? 0) == 0
            if progress.isIndeterminate { progress.startAnimation(nil) }
            else { progress.doubleValue = Double(job!.done) / Double(job!.total) }
            let cancel = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel download")!,
                                  target: self, action: #selector(cancelWindowsDownload(_:)))
            cancel.isBordered = false
            cancel.contentTintColor = .secondaryLabelColor
            cancel.tag = index
            cancel.toolTip = "Cancel downloading \(item.name)"
            cancel.setAccessibilityLabel(cancel.toolTip)
            let slot = row([progress, cancel])
            slot.spacing = 6
            slot.identifier = NSUserInterfaceItemIdentifier("win-progress")
            slot.widthAnchor.constraint(equalToConstant: 64).isActive = true
            slot.heightAnchor.constraint(equalToConstant: 26).isActive = true
            progress.setAccessibilityLabel(windowsDownloadStatus(item, job: job).title + " " + item.name)
            controls.addArrangedSubview(slot)
        } else if item.downloaded {
            let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)!,
                                target: self, action: #selector(windowsDownloadHelp(_:)))
            help.isBordered = false
            help.contentTintColor = .secondaryLabelColor
            help.tag = index
            help.toolTip = "How to run this installer"
            help.setAccessibilityLabel("How to run \(item.name)")
            let show = button("Show in Finder", #selector(showWindowsDownload(_:)))
            show.tag = index
            show.setAccessibilityLabel("Show \(item.name) installer in Finder")
            controls.addArrangedSubview(help)
            controls.addArrangedSubview(show)
        } else {
            let get = NSButton(title: job?.failure == nil ? "Get" : "Retry", target: self, action: #selector(getWindowsDownload(_:)))
            get.bezelStyle = .rounded
            get.tag = index
            get.isEnabled = windowsLibrary != nil
            get.toolTip = windowsLibrary == nil ? "Set up a game library first. The installer is saved in its Downloads folder." :
                "Download the official \(item.kind == "msi" ? ".msi" : ".exe") installer from \(item.vendor)"
            get.setAccessibilityLabel("\(get.title) \(item.name) installer")
            get.widthAnchor.constraint(equalToConstant: 64).isActive = true
            controls.addArrangedSubview(get)
        }
        let state = windowsDownloadStatus(item, job: job)
        let statusLine = row([statusIndicator(state.title, color: state.color, pulsing: state.pulsing), NSView()])
        statusLine.identifier = NSUserInterfaceItemIdentifier("app-status")
        statusLine.distribution = .fill
        let detail: NSTextField
        if let failure = job?.failure, job?.running != true {
            detail = text(failure, size: 11, secondary: true)
            detail.textColor = .systemRed
        } else if item.downloaded, let file = item.file {
            let size = item.size.map { " \u{00B7} " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            detail = text((file as NSString).lastPathComponent + size +
                          " \u{00B7} Not run or installed. Open it with Porting Kit or CrossOver.", size: 11, secondary: true)
            detail.toolTip = file + (item.sha256.map { "\nSHA-256 \($0)" } ?? "")
        } else {
            detail = text("Official Windows installer from \(item.vendor) \u{00B7} Saved to Downloads in your game library",
                          size: 11, secondary: true)
        }
        detail.identifier = NSUserInterfaceItemIdentifier("win-detail")
        let info = column([statusLine, detail])
        info.spacing = 4
        let line = settingsRow(item.name, subtitle: "", symbol: "arrow.down.app", color: .systemGray, trailing: controls, detail: info)
        let macID = String(item.id.dropFirst(4))
        if let image = Bundle.main.resourceURL.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("AppIcons/\(macID).png")) }),
           let stack = line as? NSStackView, let first = stack.arrangedSubviews.first {
            let icon = NSImageView(image: image)
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
            stack.insertArrangedSubview(icon, at: 0)
        }
        line.identifier = NSUserInterfaceItemIdentifier("win-row-" + item.id)
        return line
    }

    @objc func getWindowsDownload(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag), windowsLibrary != nil else { return }
        let item = windowsDownloads[sender.tag]
        guard windowsDownloadJobs[item.id]?.running != true else { return }
        windowsDownloadJobs[item.id] = WindowsDownloadJob()
        refreshWindowsDownloadRow(item.id)
        let cancel = windowsDownloadRun(item.id, { [weak self] line in
            guard let self, let progress = windowsDownloadProgress(line), self.windowsDownloadJobs[item.id]?.running == true else { return }
            self.windowsDownloadJobs[item.id]?.done = progress.done
            self.windowsDownloadJobs[item.id]?.total = progress.total
            self.refreshWindowsDownloadRow(item.id)
        }, { [weak self] code, errors in
            guard let self, let job = self.windowsDownloadJobs[item.id], job.running else { return }
            if job.canceled {
                self.windowsDownloadJobs[item.id] = nil
                self.loadWindowsDownloads(verifying: nil)
                self.refreshWindowsDownloadRow(item.id)
            } else if code == 0 {
                self.loadWindowsDownloads(verifying: item.id)
            } else {
                self.windowsDownloadJobs[item.id]?.running = false
                self.windowsDownloadJobs[item.id]?.cancel = nil
                self.windowsDownloadJobs[item.id]?.failure = backendErrorMessage(errors, fallback: "The download failed. Nothing was saved.")
                self.refreshWindowsDownloadRow(item.id)
            }
        })
        if windowsDownloadJobs[item.id]?.running == true { windowsDownloadJobs[item.id]?.cancel = cancel }
    }

    @objc func cancelWindowsDownload(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag) else { return }
        cancelWindowsDownload(id: windowsDownloads[sender.tag].id)
    }

    func cancelWindowsDownload(id: String) {
        guard windowsDownloadJobs[id]?.running == true else { return }
        windowsDownloadJobs[id]?.canceled = true
        windowsDownloadJobs[id]?.cancel?()
    }

    @objc func showWindowsDownload(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag), let file = windowsDownloads[sender.tag].file else { return }
        let url = URL(fileURLWithPath: file)
        // Only reveal files the backend reported inside the library's Downloads folder.
        guard let library = windowsLibrary, url.standardizedFileURL.deletingLastPathComponent().path ==
                URL(fileURLWithPath: library).appendingPathComponent("Downloads").standardizedFileURL.path,
              FileManager.default.fileExists(atPath: url.path) else {
            loadWindowsDownloads()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func windowsDownloadHelp(_ sender: NSButton) {
        guard windowsDownloads.indices.contains(sender.tag) else { return }
        let item = windowsDownloads[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Running \(item.name)"
        alert.informativeText = "Couch Cube only downloaded the official installer. It doesn't run Windows programs.\n\n" +
            "To install the launcher, open the installer with a Windows compatibility app such as Porting Kit or CrossOver " +
            "(listed above under Windows games). Whether a launcher or game works depends on that app and its settings."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Porting Kit & CrossOver")
        let show = { (response: NSApplication.ModalResponse) in
            guard response == .alertSecondButtonReturn else { return }
            self.highlightedAppID = "porting-kit"
            self.highlightAppRow()
        }
        if window.isVisible && window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: show) }
        else { show(alert.runModal()) }
    }

    func makeAppRow(_ app: ManagedApp, index: Int, title: String? = nil, purpose: String? = nil) -> NSView {
        let controls = row([])
        let operation = appOperations[app.id]
        if operation?.running == true {
            // A spinner takes the action button's place at the same size; Homebrew doesn't report real percentages here.
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            progress.translatesAutoresizingMaskIntoConstraints = false
            let slot = NSView()
            slot.addSubview(progress)
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: app.installed ? 26 : 64),
                slot.heightAnchor.constraint(equalToConstant: 26),
                progress.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                progress.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
            ])
            slot.identifier = NSUserInterfaceItemIdentifier("app-progress")
            slot.setAccessibilityElement(true)
            slot.setAccessibilityRole(.progressIndicator)
            slot.setAccessibilityLabel(appRowStatus(app, operation: operation, unknown: false, checking: false).title + " " + app.name)
            controls.addArrangedSubview(slot)
        } else {
            if app.id == "porting-kit" && app.installed && selected != nil {
                // Porting Kit asks where to put its ports; this makes the library folder and copies its path.
                let pinned = pinnedPortingKitFolder != nil
                let folder = button(pinned ? "Unpin Folder" : "Games Folder", #selector(preparePortingKitFolder))
                folder.toolTip = pinned ? "Take the Porting Kit folder off Finder's sidebar"
                    : "Create Couch Cube \u{203A} Windows \u{203A} Porting Kit and pin it to the top of Finder's sidebar for Porting Kit's Applications path"
                folder.setAccessibilityIdentifier("portingKitFolder")
                controls.addArrangedSubview(folder)
            }
            if app.id == "crossover" && app.installed {
                let open = button("Open", #selector(openCrossOver(_:)))
                open.tag = index
                controls.addArrangedSubview(open)
            }
            if app.installed {
                controls.addArrangedSubview(appPillButton("Remove", app: app, index: index,
                                                          action: #selector(appAction(_:)), destructive: true))
            } else {
                controls.addArrangedSubview(appPillButton(operation?.failure == nil ? "Get" : "Retry", app: app, index: index,
                                                          action: #selector(appAction(_:))))
            }
        }
        let unknown = !appsHaveResults && app.path.isEmpty && app.version.isEmpty && operation == nil
        let state = appRowStatus(app, operation: operation, unknown: unknown, checking: appsChecking)
        let statusLine = row([statusIndicator(state.title, color: state.color, pulsing: state.pulsing), NSView()])
        statusLine.identifier = NSUserInterfaceItemIdentifier("app-status")
        controls.isHidden = unknown
        controls.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = !appsChecking && task == nil }
        statusLine.toolTip = app.installed ? "Version \(app.version)" + (app.update.map { " · Update \($0) available" } ?? "") : nil
        statusLine.distribution = .fill
        let info = column([statusLine,
                           text(purpose ?? appPurposes[app.id] ?? app.name, size: 11, secondary: true)])
        info.spacing = 4
        let line = settingsRow(title ?? app.name, subtitle: "", symbol: "app.fill",
                               color: .systemBlue, trailing: controls, detail: info)
        let bundledIcon = Bundle.main.resourceURL?.appendingPathComponent("AppIcons/\(app.id).png")
        let appIcon = app.installed ? NSWorkspace.shared.icon(forFile: app.path) :
            bundledIcon.flatMap { NSImage(contentsOf: $0) }
        if let appIcon = appIcon, let stack = line as? NSStackView, let first = stack.arrangedSubviews.first {
            let icon = NSImageView(image: appIcon)
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
            stack.insertArrangedSubview(icon, at: 0)
        }
        line.identifier = NSUserInterfaceItemIdentifier("app-row-" + app.id)
        return line
    }

    func renderTVMenus() {
        defaultMenuPicker.removeAllItems()
        defaultMenuPicker.autoenablesItems = false
        var selectedIndex: Int?
        for id in ["steam", "es-de"] {
            let installed = appStates.first { $0.id == id }?.installed ??
                report.map { !$0.missing.contains(id) } ?? false
            defaultMenuPicker.addItem(withTitle: (id == "steam" ? "Steam Big Picture" : "ES-DE") +
                (installed ? "" : " — Not installed"))
            let item = defaultMenuPicker.lastItem!
            item.representedObject = id
            item.isEnabled = installed
            if effectiveFrontend == id { selectedIndex = defaultMenuPicker.numberOfItems - 1 }
        }
        if let index = selectedIndex { defaultMenuPicker.selectItem(at: index) }
        else {
            defaultMenuPicker.insertItem(withTitle: "Choose a menu", at: 0)
            defaultMenuPicker.item(at: 0)?.isEnabled = false
            defaultMenuPicker.selectItem(at: 0)
        }
        defaultMenuPicker.isEnabled = task == nil && !appsChecking &&
            defaultMenuPicker.itemArray.contains { $0.representedObject != nil && $0.isEnabled }
        tvMenuStatus.stringValue = selectedIndex == nil ? "Install Steam or ES-DE in App Store to get started." : ""
        tvMenuStatus.isHidden = tvMenuStatus.stringValue.isEmpty
        renderConsoleMode()
    }

    @objc func defaultMenuChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let index = appStates.firstIndex(where: { $0.id == id && $0.installed }) else {
            renderTVMenus()
            return
        }
        let control = NSButton()
        control.tag = index
        setDefaultMenu(control)
    }

    @objc func showTVMenus() { selectPage(10); loadPageData(10) }

    @objc func setDefaultMenu(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        execute(["frontend", "--default", app.id, "--confirm"]) { code, _ in
            if code == 0 {
                self.preferredFrontend = app.id
                self.renderTVMenus()
                self.updateSetupSummary()
            } else {
                self.renderTVMenus()
                self.tvMenuStatus.isHidden = false
                self.tvMenuStatus.stringValue = "Couldn't save the default menu. Open Activity for details."
            }
        }
    }

    @objc func updateAllApps() {
        let updates = appStates.filter { $0.installed && $0.managed && $0.update?.isEmpty == false }
        guard task == nil, !updates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Update \(updates.count) apps?"
        alert.informativeText = "Quit these apps first: " + updates.map { $0.name }.joined(separator: ", ") +
            ". Homebrew will update only these managed apps. Self-updating and manually installed apps use their own updaters."
        alert.addButton(withTitle: "Update all")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateNextApp(updates)
    }

    func updateNextApp(_ remaining: [ManagedApp]) {
        guard let app = remaining.first else { return }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            let message = "Quit \(app.name), then try Update all again."
            append(message + "\n")
            fetchApps(updates: false) { success in
                if success { self.appsStatus.stringValue = message }
            }
            return
        }
        runAppOperation(app, action: "update") { verified in
            if verified { self.updateNextApp(Array(remaining.dropFirst())) }
            else { self.appsStatus.stringValue = "Update stopped at \(app.name). Try again, or choose View > Activity for details." }
        }
    }

    @objc func closeInspector() {
        selectPage(inspectorParent)
    }

    @objc func showConsoleDetails(_ sender: NSButton) {
        guard consoleSystems.indices.contains(sender.tag) else { return }
        let system = consoleSystems[sender.tag]
        inspectorSystemID = system.id
        inspectorParent = 7
        inspectorTitle.stringValue = system.name
        clearRows(inspectorRows)
        let emulator = emulatorStatus(system)
        let store = NSButton(title: "Show in App Store", target: self, action: #selector(showEmulatorInAppStore(_:)))
        store.image = NSImage(systemSymbolName: "storefront", accessibilityDescription: nil)
        store.imagePosition = .imageLeading
        store.bezelStyle = .rounded
        store.controlSize = .small
        store.identifier = NSUserInterfaceItemIdentifier(system.package)
        store.toolTip = "Show \(emulatorName(system)) in App Store"
        let emulatorRow = row([statusIndicator(emulator.title, color: emulator.color), NSView(), store])
        emulatorRow.distribution = .fill
        inspectorRows.addArrangedSubview(emulatorRow)
        if let bios = system.bios, bios.state != "not-needed" {
            let status = biosStatusView(bios, searchQuery: system.name + " BIOS")
            inspectorRows.addArrangedSubview(status)
            status.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
        }
        selectPage(9)
    }

    func appStoreLink(for system: ConsoleSystem) -> NSButton {
        let name = emulatorName(system)
        let control = NSButton(image: NSImage(systemSymbolName: "storefront",
                                              accessibilityDescription: "Show \(name) in App Store")!,
                               target: self, action: #selector(showEmulatorInAppStore(_:)))
        control.isBordered = false
        control.contentTintColor = .secondaryLabelColor
        control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        control.identifier = NSUserInterfaceItemIdentifier(system.package)
        control.toolTip = "Show \(name) in App Store"
        control.setAccessibilityLabel(control.toolTip)
        return control
    }

    @objc func showEmulatorInAppStore(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showAppInStore(id)
    }

    func showAppInStore(_ id: String) {
        highlightedAppID = id
        let category = id == "steam" || id == "es-de" ? "TV menus" : computerGameApps.contains(id) ? "PC games" :
            ["porting-kit", "crossover"].contains(id) ? "Windows games" : "Retro games"
        if appStates.first(where: { $0.id == id })?.installed != true && collapsedAppCategories.contains(category),
           let toggle = appCategoryToggles[category] {
            toggleAppCategory(toggle)
        }
        showPlayers()
        highlightAppRow()
    }

    func highlightAppRow() {
        guard let id = highlightedAppID else { return }
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "app-row-" + id { return view }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        guard let line = [appMenuRows, appPCRows, appWindowsRows, appRetroRows].lazy.compactMap({ find($0) }).first else { return }
        if !appsChecking { highlightedAppID = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        line.scrollToVisible(line.bounds.insetBy(dx: 0, dy: -120))
        line.wantsLayer = true
        line.layer?.cornerRadius = 8
        let color = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        line.layer?.backgroundColor = color
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = color
        fade.toValue = NSColor.clear.cgColor
        fade.beginTime = CACurrentMediaTime() + 1.6
        fade.duration = 0.8
        fade.fillMode = .backwards
        line.layer?.add(fade, forKey: "highlight")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak line] in
            line?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc func openCrossOver(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag), appStates[sender.tag].id == "crossover",
              appStates[sender.tag].installed else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appStates[sender.tag].path),
                                          configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.appsStatus.stringValue = "Couldn't open CrossOver: \(error.localizedDescription)"
                    self.append(self.appsStatus.stringValue + "\n")
                }
            }
        }
    }

    @objc func appAction(_ sender: NSButton) {
        guard task == nil, appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        if app.installed && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) {
            appsStatus.stringValue = "Quit \(app.name) first, then choose Remove."
            return
        }
        if !app.installed && app.manual {
            if let url = app.url, let link = URL(string: url) {
                NSWorkspace.shared.open(link)
                appsStatus.stringValue = "Finish the official installer, then reopen App Store to check the installation."
            } else {
                let alert = NSAlert()
                alert.messageText = "Switch emulator: manual setup"
                alert.informativeText = "No verified automatic Switch emulator download is bundled. If you have a compatible Ryujinx-based macOS build, install it as Ryujinx.app in Applications. Configure your own legally obtained keys, firmware and game dumps there, then reopen App Store. Availability and game compatibility are not guaranteed."
                alert.runModal()
            }
            return
        }
        // Get installs right away (it's what the button says); only removing asks first.
        if app.installed {
            let alert = NSAlert()
            alert.messageText = "Remove \(app.name)?"
            alert.informativeText = "Your games, saves and settings are kept."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if app.installed && !app.managed {
            NSWorkspace.shared.recycle([URL(fileURLWithPath: app.path)]) { _, error in
                DispatchQueue.main.async {
                    if let error = error { self.appsStatus.stringValue = "Couldn't remove app: \(error.localizedDescription)" }
                    else { self.loadApps() }
                }
            }
            return
        }
        manage(app, action: app.installed ? "remove" : "install")
    }

    @objc func updateApp(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            appsStatus.stringValue = "Quit \(app.name) before updating."
            return
        }
        manage(app, action: "update")
    }

    func manage(_ app: ManagedApp, action: String) {
        if action == "install", appStates.first?.brew != true {
            fetchApps(updates: false) { success in
                guard success else { return }
                if self.appStates.first?.brew == true { self.manage(app, action: action) }
                else { self.homebrew() }
            }
            return
        }
        runAppOperation(app, action: action)
    }

    /// Runs one Homebrew app operation, then re-checks only that app before showing it as done (green).
    func runAppOperation(_ app: ManagedApp, action: String, completed: ((Bool) -> Void)? = nil) {
        guard task == nil, appOperations[app.id]?.running != true else {
            appsStatus.stringValue = "Wait for the current operation to finish."
            completed?(false)
            return
        }
        appsStatus.stringValue = ""
        // Results of app checks started before this change must not overwrite it.
        appsLoadGeneration += 1
        appsChecking = false
        appOperations[app.id] = AppOperation(action: action, phase: nil, failure: nil, running: true)
        refreshAppRow(app.id)
        appOperationOutput = { [weak self] output in
            guard let self, let phase = appOperationPhase(output, action: action),
                  self.appOperations[app.id]?.running == true, self.appOperations[app.id]?.phase != phase else { return }
            self.appOperations[app.id]?.phase = phase
            self.refreshAppRow(app.id)
        }
        appOperationRun(["manage-app", "--package", app.id, "--action", action, "--confirm"]) { code in
            self.appOperationOutput = nil
            self.verifyApp(app.id, action: action, succeeded: code == 0, completed: completed)
        }
    }

    func verifyApp(_ id: String, action: String, succeeded: Bool, completed: ((Bool) -> Void)?) {
        appVerifyTokens[id, default: 0] += 1
        let token = appVerifyTokens[id]!
        appOperations[id]?.phase = "Checking"
        refreshAppRow(id)
        appVerifyRead(["apps", "--updates", "--package", id]) { code, data in
            guard self.appVerifyTokens[id] == token else { return }
            let verified = code == 0 ? (try? JSONDecoder().decode([ManagedApp].self, from: data))?.first { $0.id == id } : nil
            if let verified, let index = self.appStates.firstIndex(where: { $0.id == id }) { self.appStates[index] = verified }
            let reached = verified.map { action == "remove" ? !$0.installed : $0.installed && $0.update?.isEmpty != false } ?? false
            let name = verified?.name ?? self.appStates.first { $0.id == id }?.name ?? id
            if succeeded && reached {
                self.appOperations[id] = nil
                self.appManagementHint.isHidden = true
            } else {
                let verb = action == "remove" ? "remove" : action == "update" ? "update" : "install"
                self.appOperations[id] = AppOperation(action: action, phase: nil,
                    failure: verified == nil ? "Couldn't confirm the \(verb)" : "Couldn't \(verb)", running: false)
                self.appsStatus.stringValue = verified == nil
                    ? "Couldn't check \(name) after the \(verb). Reopen App Store to check again."
                    : "Couldn't \(verb) \(name). Try again, or choose View > Activity for details."
                self.appManagementHint.isHidden = verified == nil
            }
            // Any full app check still in flight predates this verified state.
            self.appsLoadGeneration += 1
            self.appsChecking = false
            self.lastAppsData = nil
            if let report = self.report {
                self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                         missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                         preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                self.updateSetupSummary()
            }
            self.refreshAppRow(id)
            let updates = self.appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
            self.updateAllButton.isHidden = !updates
            self.updateAllButton.isEnabled = updates && self.task == nil
            self.renderTVMenus()
            self.renderGeneral()
            completed?(succeeded && reached)
        }
    }
}
