import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func updateSetupSummary() {
        defer { renderGeneral() }
        clearRows(libraryHealth)
        guard let report = report, let drive = selected else {
            libraryHealth.addArrangedSubview(statusIndicator(selected == nil ? "No storage selected" : "Checking library", color: .systemYellow))
            playAction.isEnabled = false
            return
        }
        let foldersReady = report.state == "valid layout" && report.issues.isEmpty
        libraryHealth.addArrangedSubview(statusIndicator(foldersReady ? "Ready" : report.issues.isEmpty ? "Setup required" : "Needs attention",
                                                        color: foldersReady ? .systemGreen : report.issues.isEmpty ? .systemYellow : .systemRed))
        let steamInstalled = !report.missing.contains("steam")
        let retroInstalled = !report.missing.contains("es-de")
        let menu = effectiveFrontend
        playAction.toolTip = menu == "steam" ? "Open Steam Big Picture" : menu == "es-de" ? "Open ES-DE" : "Install your TV menu to play"
        renderStorageLocations()
        setupAppStatus.stringValue = steamInstalled ? "Steam is installed. Optional emulators are managed in App Store." :
            retroInstalled ? "ES-DE is installed and is your console menu." : "Install Steam or ES-DE in App Store to get your TV menu."
        setupConnectionStatus.stringValue = drive.mode == "local"
            ? "Local Steam games stay in Steam's existing library. No storage change needed."
            : "For Steam games on the SSD, add its SteamLibrary in Steam → Settings → Storage."
        playAction.isEnabled = task == nil && foldersReady && menu != nil
    }

    func renderGeneral() {
        let ready = report?.state == "valid layout" && report?.issues.isEmpty == true
        let frontend = effectiveFrontend
        homeMenuLabel.stringValue = frontend == "steam" ? "Steam Big Picture" :
            frontend == "es-de" ? "ES-DE" : report == nil ? "Checking your console..." : "Choose a TV menu in Console Mode."
        let checking = !overviewChecks.isEmpty && report == nil
        if checking { homeProgress.startAnimation(nil) }
        else { homeProgress.stopAnimation(nil) }
        homeProgress.isHidden = !checking
        if report == nil && !overviewCheckFailures.isEmpty { homeMenuLabel.stringValue = "Couldn't check your console." }
        playAction.isEnabled = task == nil && ready && frontend != nil
        renderHomeControllers()
        renderLauncher()
        // The artwork names the menu; the small line under "Cube TV" only speaks up while nothing is chosen.
        if homeArtworkMenu != frontend || homePlayBackground.layer?.contents == nil {
            homeArtworkMenu = frontend
            let path = appStates.first { $0.id == frontend && $0.installed && !$0.path.isEmpty }?.path
            let art = TVMenuArtwork.image(for: frontend, appIcon: path.map { NSWorkspace.shared.icon(forFile: $0) })
            homePlayBackground.layer?.contentsGravity = .resizeAspectFill
            homePlayBackground.layer?.contents = art.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        homePlaySubtitle.stringValue = frontend == nil ? homeMenuLabel.stringValue : ""
        playAction.setAccessibilityLabel("Cube TV · \(homeMenuLabel.stringValue)")
        var tasks: [SidebarTask] = []
        if let report = report, !ready {
            if report.issues.isEmpty {
                tasks.append(SidebarTask(page: 6, color: .systemYellow, title: "Prepare your game library", setup: true))
            } else {
                tasks += report.issues.map { SidebarTask(page: 6, color: .systemRed, title: $0, setup: false) }
            }
        }
        if let report = report {
            if report.missing.contains("steam") && report.missing.contains("es-de") {
                tasks.append(SidebarTask(page: 1, color: .systemRed, title: "Get a TV menu: Steam or ES-DE", setup: true))
            } else if frontend == nil {
                tasks.append(SidebarTask(page: 10, color: .systemYellow, title: "Choose your TV menu", setup: true))
            }
            if installedAppCount(computerGameApps.union(emulatorApps)) == 0 &&
                !(report.missing.contains("steam") && report.missing.contains("es-de")) {
                tasks.append(SidebarTask(page: 1, color: .systemYellow, title: "Get a game app or emulator", setup: true))
            }
        }
        for (check, page, title) in [(OverviewCheck.storage, 6, "Library storage couldn't be checked"),
                                     (.menu, 1, "Apps couldn't be checked"), (.consoles, 7, "Retro consoles couldn't be checked"),
                                     (.automatic, 10, "Console mode couldn't be checked"), (.steam, 6, "Steam couldn't be checked")]
            where overviewCheckFailures.contains(check) {
            tasks.append(SidebarTask(page: page, color: .systemYellow, title: title, setup: false))
        }
        for system in consoleSystems where system.enabled {
            if system.emulator_installed == false {
                tasks.append(SidebarTask(page: 1, color: .systemRed, title: "Get the emulator for \(system.name)", setup: false))
            }
            if ["missing", "partial"].contains(system.bios?.state ?? "") {
                tasks.append(SidebarTask(page: 7, color: .systemRed, title: "Add BIOS files for \(system.name)", setup: false))
            } else if ["optional", "manual"].contains(system.bios?.state ?? "") {
                tasks.append(SidebarTask(page: 7, color: .systemYellow, title: "Check BIOS files for \(system.name)", setup: false))
            }
        }
        for app in appStates where app.installed && app.update?.isEmpty == false {
            tasks.append(SidebarTask(page: 1, color: .systemYellow, title: "Update \(app.name)", setup: false))
        }
        if couchCubeUpdateAvailable {
            tasks.append(SidebarTask(page: 11, color: .systemYellow, title: "Update Couch Cube", setup: false))
        }
        if controllerBluetoothNeedsAttention {
            tasks.append(SidebarTask(page: 8, color: .systemYellow, title: "Allow Bluetooth access", setup: true))
        }
        sidebarTasks = tasks
        let badges: [Int: SidebarBadge]
        if guidedSetup {
            let step = guidedSidebarStep(tasks, pinned: guidedPinnedPage, settled: overviewChecks.isEmpty, previous: sidebarTaskCounts)
            guidedPinnedPage = step.pinned
            badges = step.badges
        } else {
            guidedPinnedPage = nil
            badges = sidebarBadges(tasks, guided: false)
        }
        let attention = badges.mapValues(\.color)
        if sidebarTaskCounts != badges {
            let changed = IndexSet(sidebarPages.indices.filter {
                sidebarPages[$0] >= 0 && sidebarTaskCounts[sidebarPages[$0]] != badges[sidebarPages[$0]]
            })
            sidebarTaskCounts = badges
            sidebarAttention = attention
            if sidebar.numberOfRows == sidebarPages.count {
                for row in changed {
                    if let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                        applySidebarMarkers(to: cell, row: row)
                    } else {
                        sidebar.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                    }
                }
            } else {
                sidebar.reloadData()
            }
        }
    }

    @objc func guidedSetupChanged() {
        guidedSetup = guidedSetupToggle.state == .on
        guidedPinnedPage = nil
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            UserDefaults.standard.set(guidedSetup, forKey: guidedSetupKey)
        }
        renderGeneral()
    }

    func installedAppCount(_ ids: Set<String>) -> Int {
        if let report = report { return ids.subtracting(report.missing).count }
        return appStates.filter { ids.contains($0.id) && $0.installed }.count
    }

    func controllerOverviewStatus(count: Int) -> NSStackView {
        let dots = (0..<4).map { index -> NSImageView in
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            dot.contentTintColor = index < count ? .systemGreen : .systemGray
            dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            return dot
        }
        let leds = row(dots)
        leds.spacing = 5
        leds.translatesAutoresizingMaskIntoConstraints = false
        let housing = ControllerLEDHousing()
        housing.contentView!.addSubview(leds)
        NSLayoutConstraint.activate([
            leds.leadingAnchor.constraint(equalTo: housing.leadingAnchor, constant: 8),
            leds.trailingAnchor.constraint(equalTo: housing.trailingAnchor, constant: -8),
            leds.centerYAnchor.constraint(equalTo: housing.centerYAnchor),
            housing.heightAnchor.constraint(equalToConstant: 20)
        ])
        let label = NSTextField(labelWithString: count == 0 ? "Not Connected" : "\(count) Connected")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let result = row([housing, label])
        result.spacing = 7
        result.setAccessibilityLabel(label.stringValue)
        return result
    }

    @objc func refreshGeneral() {
        guard task == nil else { return }
        refresh()
    }

    func loadGeneralDetails() {
        guard task == nil else { return }
        appsPreloadPending = true
        guard report?.state == "valid layout", let drive = selected else {
            consoleSystems = []
            consolesLoaded = false
            overviewChecks.remove(.consoles)
            renderGeneral()
            loadAutoLaunch()
            return
        }
        let root = drive.root
        execute(["systems", "--root", root], capture: true) { code, data in
            self.overviewChecks.remove(.consoles)
            if self.selected?.root != root {
                // Storage changed meanwhile; its own refresh brings the right consoles.
            } else if code == 0 {
                do {
                    self.acceptSystems(try JSONDecoder().decode([ConsoleSystem].self, from: data))
                } catch {
                    self.overviewCheckFailures.insert(.consoles)
                    self.status.stringValue = "Couldn't read console status: \(error.localizedDescription)"
                    self.append(self.status.stringValue + "\n")
                }
            } else {
                self.overviewCheckFailures.insert(.consoles)
                self.status.stringValue = "Couldn't read console status. Open Details for the error."
            }
            self.renderGeneral()
            self.loadAutoLaunch()
        }
    }
}
