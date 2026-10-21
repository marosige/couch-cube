import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    /// Game library and Library storage share one drive overview; each drive opens a read-only detail page.
    func smokeTestDriveOverview() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        func overviewRows(_ stack: NSStackView) -> [StorageOverviewRow] { stack.arrangedSubviews.compactMap { $0 as? StorageOverviewRow } }
        let saved = (storageStatus, driveDetailCache, driveDetailID, backendRead, driveDetailParent, driveDetailErrors, currentPage, driveDetailLoading)
        let savedGames = (driveGamesRead, driveGamesCache, driveGamesShowAll,
                          UserDefaults.standard.object(forKey: romsBySystemKey), UserDefaults.standard.object(forKey: pcByLauncherKey))
        let scans = SmokeScanLog()
        driveGamesRead = { id, done in scans.calls.append((id, done)) }
        UserDefaults.standard.removeObject(forKey: romsBySystemKey)
        UserDefaults.standard.removeObject(forKey: pcByLauncherKey)
        defer {
            (driveGamesRead, driveGamesCache, driveGamesShowAll) = (savedGames.0, savedGames.1, savedGames.2)
            UserDefaults.standard.set(savedGames.3, forKey: romsBySystemKey)
            UserDefaults.standard.set(savedGames.4, forKey: pcByLauncherKey)
            driveGamesScanning = nil
            driveGamesGeneration += 1
            (storageStatus, driveDetailCache, driveDetailID, backendRead, driveDetailParent, driveDetailErrors) = (saved.0, saved.1, saved.2, saved.3, saved.4, saved.5)
            driveDetailLoading = saved.7
            driveDetailGeneration += 1
            renderStorageLocations()
            selectPage(saved.6)
        }
        let local = Drive(id: "local", uuid: "u0", mode: "local", name: "Macintosh HD", root: "/Users/test/Games/Couch Cube",
                          filesystem: "apfs", free: 100, mount: "/")
        func ssd(_ number: Int) -> Drive {
            Drive(id: "ssd\(number)", uuid: "u\(number)", mode: "portable", name: "Game SSD \(number) (portable console)",
                  root: "/Volumes/G\(number)/Couch Cube", filesystem: "apfs", free: 100, mount: "/Volumes/G\(number)")
        }
        for entry in [StorageOverviewEntry(id: "local", mode: "local", title: "This Mac", state: "ready", active: true,
                                           path: "/Users/test/Games/Couch Cube"),
                      StorageOverviewEntry(id: nil, mode: "portable", title: "External SSD", state: "connect", active: false, path: nil)] {
            let probe = storageOverviewRow(entry)
            probe.frame = NSRect(x: 0, y: 0, width: 600, height: 80)
            probe.layoutSubtreeIfNeeded()
            for field in views(probe).compactMap({ $0 as? NSControl }) where field is NSTextField || field.identifier?.rawValue == entry.path {
                precondition(field.frame.width + 0.5 >= field.intrinsicContentSize.width,
                             "Drive titles, status and paths must not truncate when the row has room: \(field.stringValue)")
            }
        }
        storageStatus = nil
        precondition(storageOverviewEntries().map(\.state) == ["checking", "checking"], "Unchecked drives are never shown as ready or missing")
        storageStatus = StorageStatus(locations: [.init(drive: local, configured: true, issue: nil, environment: "ready")],
                                      active: .init(id: "local", uuid: "u0"), transfer: nil)
        renderStorageOverview()
        for stack in [gameLibraryOverviewRows] {
            let rows = overviewRows(stack)
            precondition(rows.count == 2 && rows[0].driveID == "local" && labels(rows[0]).contains("This Mac") &&
                         labels(rows[0]).contains("Ready · Active"), "This Mac is always listed with its readiness")
            precondition(rows[1].driveID == nil && rows[1].alphaValue < 1 && labels(rows[1]).contains("External SSD") &&
                         labels(rows[1]).contains("Connect one"), "Without a drive, External SSD is a disabled Connect one row")
        }
        precondition(gameLibraryOverviewRows.isDescendant(of: tabs.tabViewItems[6].view!), "Game library shows the drive overview")
        storageStatus = StorageStatus(locations: [
            .init(drive: local, configured: true, issue: nil, environment: "ready"),
            .init(drive: ssd(1), configured: false, issue: nil, environment: "absent"),
            .init(drive: ssd(2), configured: false, issue: "A Couch Cube folder is already there.", environment: "occupied"),
            .init(drive: ssd(3), configured: true, issue: nil, environment: "ready")
        ], active: .init(id: "local", uuid: "u0"), transfer: nil)
        renderStorageOverview()
        let rows = overviewRows(gameLibraryOverviewRows)
        precondition(rows.map(\.driveID) == ["local", "ssd1", "ssd2", "ssd3"], "Every connected drive gets its own row")
        precondition(labels(rows[1]).contains("Game SSD 1") && labels(rows[1]).contains("Not set up") &&
                     labels(rows[2]).contains { $0.hasPrefix("Not set up ·") } && labels(rows[3]).contains("Ready"))
        precondition(rows.allSatisfy { row in views(row).contains { $0.identifier?.rawValue == "storage-overview-badge" } },
                     "Readiness is drawn on each drive icon")
        precondition(!views(rows[1]).contains { ($0 as? NSButton)?.action == #selector(openBIOSFolder(_:)) },
                     "A path that doesn't exist yet isn't offered in Finder")
        let unchanged = rows[0]
        renderStorageOverview()
        precondition(overviewRows(gameLibraryOverviewRows)[0] === unchanged, "Silent refreshes keep rows in place")
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        selectPage(6)
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        let finder = views(rows[0]).compactMap { $0 as? NSButton }.first { $0.action == #selector(openBIOSFolder(_:)) }!
        precondition(finder.identifier?.rawValue == local.root, "The library path opens in Finder like BIOS folders")
        let finderPoint = rows[0].superview!.convert(NSPoint(x: finder.bounds.midX, y: finder.bounds.midY), from: finder)
        precondition(rows[0].hitTest(finderPoint).map { $0 === finder || $0.isDescendant(of: finder) } == true,
                     "The Finder link keeps its own click instead of opening the drive")
        let title = views(rows[0]).compactMap { $0 as? NSTextField }.first { $0.stringValue == "This Mac" }!
        precondition(rows[0].hitTest(rows[0].superview!.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), from: title)) === rows[0],
                     "The rest of the row opens the drive")
        var reads: [([String], (Int32, Data) -> Void)] = []
        backendRead = { arguments, done in reads.append((arguments, done)) }
        func detailJSON(_ drive: Drive, steam: String, retro: String) -> Data {
            Data("""
            {"drive":{"id":"\(drive.id)","uuid":"\(drive.uuid)","mode":"\(drive.mode)","name":"\(drive.name)","root":"\(drive.root)","filesystem":"apfs","free":100,"mount":"\(drive.mount)"},
             "environment":"ready","issue":null,"active":false,
             "capacity":{"total":1000000000000,"used":600000000000,"free":400000000000,"couch":5000000000},
             "steam":\(steam),"retro":\(retro),"errors":[]}
            """.utf8)
        }
        rows[1].onOpen?("ssd1")
        precondition(currentPage == 12 && driveDetailID == "ssd1" && driveDetailParent == 6 &&
                     sidebar.selectedRow == sidebarPages.firstIndex(of: 6) && screenTitle.stringValue == "Game SSD 1",
                     "A drive row opens its detail page under Game library")
        precondition(reads.last?.0 == ["drive-detail", "--drive", "ssd1"])
        precondition(views(driveDetailRows).contains { ($0 as? NSButton)?.identifier?.rawValue == "drive-initialize" && ($0 as? NSButton)?.isEnabled == true },
                     "A drive without a library offers Initialize")
        precondition(!views(driveDetailRows).contains { $0.identifier?.rawValue == "drive-remove" })
        precondition(labels(driveDetailRows).contains("Reading this drive..."))
        showDriveDetail("ssd3")
        precondition(reads.count == 2 && reads[1].0 == ["drive-detail", "--drive", "ssd3"])
        reads[0].1(0, detailJSON(ssd(1), steam: "[]", retro: "[]"))
        precondition(driveDetailCache["ssd1"] == nil && driveDetailID == "ssd3" && labels(driveDetailRows).contains("Reading this drive..."),
                     "A stale result for another drive never replaces the current page")
        reads[1].1(0, detailJSON(ssd(3), steam: """
            [{"path":"/Volumes/G3/SteamLibrary","games":[{"appid":"620","name":"Portal 2","state":"Installed","installed":true,"bytes":1000}]}]
            """, retro: """
            [{"id":"snes","name":"Super Nintendo","games":3,"path":"/Volumes/G3/Couch Cube/ROMs/snes"}]
            """))
        let detailLabels = labels(driveDetailRows)
        for heading in ["Couch Cube library", "Storage", "Drive size", "Used (all files)", "Couch Cube files", "Free space", "Steam", "Retro games", "Super Nintendo"] {
            precondition(detailLabels.contains(heading), "Drive detail shows \(heading)")
        }
        precondition(!detailLabels.contains("Reading this drive..."))
        let buttons = views(driveDetailRows).compactMap { $0 as? NSButton }
        precondition(buttons.contains { $0.identifier?.rawValue == "620" && $0.title == "Play" } &&
                     buttons.contains { $0.identifier?.rawValue == "620" && $0.title == "Manage" && $0.action == #selector(manageSteamGame(_:)) },
                     "Steam games on the drive keep Play and get a Steam manage link")
        precondition(buttons.contains { $0.identifier?.rawValue == "drive-remove" } && buttons.contains { $0.title == "Use this library..." },
                     "A ready library that isn't active can be activated or removed")
        precondition(views(driveDetailRows).contains { $0.identifier?.rawValue == "drive-retro-snes" } &&
                     !views(driveDetailRows).contains { $0.identifier?.rawValue.hasPrefix("drive-retro-") == true && $0.identifier?.rawValue != "drive-retro-snes" })
        smokeTestDriveGames(scans, labels: labels, views: views)
        reads.removeAll()
        showDriveDetail("ssd1")
        precondition(reads.count == 1)
        reads[0].1(0, detailJSON(ssd(1), steam: "[]", retro: "[]"))
        precondition(!labels(driveDetailRows).contains("Steam") && !labels(driveDetailRows).contains("Retro games"),
                     "Systems and stores without games on this drive are left out")
        storageStatus = StorageStatus(locations: [.init(drive: local, configured: true, issue: nil, environment: "ready")],
                                      active: .init(id: "local", uuid: "u0"), transfer: nil)
        reads.removeAll()
        renderStorageLocations()
        precondition(labels(driveDetailRows).contains { $0.hasPrefix("Disconnected.") } && reads.isEmpty,
                     "Unplugging the drive shows it as disconnected without reading it")
        precondition(driveGamesCache["ssd1"] == nil && driveGamesScanning == nil,
                     "Unplugging drops the drive's game sizes so a reconnect measures it again")
    }

    /// Game storage breakdown: one scan per drive, stale scans dropped, grouping is presentation-only.
    func smokeTestDriveGames(_ log: SmokeScanLog, labels: (NSView) -> [String], views: (NSView) -> [NSView]) {
        precondition(log.calls.map(\.0) == ["ssd1", "ssd3"], "Opening a drive measures its games once, separately from the detail read")
        func item(_ id: String, _ kind: String, _ source: String, _ sourceName: String, _ name: String, _ system: String?,
                  _ bytes: Int64?, measured: Bool = true, unreadable: Int = 0) -> String {
            let systemNames = ["psx": "PlayStation", "snes": "Super Nintendo"]
            let systemJSON = system.map { "\"\($0)\"" } ?? "null"
            let systemName = system.flatMap { systemNames[$0] }.map { "\"\($0)\"" } ?? "null"
            return """
            {"id":"\(id)","kind":"\(kind)","source":"\(source)","source_name":"\(sourceName)","name":"\(name)","system":\(systemJSON),
             "system_name":\(systemName),"bytes":\(bytes.map(String.init) ?? "null"),"measured":\(measured),"unreadable":\(unreadable),"path":"/Volumes/G3/x"}
            """
        }
        var items = [item("rom:psx:A", "rom", "rom", "ROMs", "Alpha", "psx", 300_000_000),
                     item("rom:psx:B", "rom", "rom", "ROMs", "Beta", "psx", 100_000_000, unreadable: 2),
                     item("rom:snes:C", "rom", "rom", "ROMs", "Gamma", "snes", 50_000_000),
                     item("steam:1", "pc", "steam", "Steam", "Portal 2", nil, 500_000_000),
                     item("steam:2", "pc", "steam", "Steam", "Reported", nil, 40_000_000, measured: false),
                     item("gog:1", "pc", "gog", "GOG", "Witcher", nil, 9_000_000),
                     item("bottle:1", "pc", "bottle", "Windows bottles", "Steam (CrossOver bottle)", nil, 1_000),
                     item("epic:1", "pc", "epic", "Epic Games", "Unknown size", nil, nil)]
        items += (0..<6).map { item("rom:snes:t\($0)", "rom", "rom", "ROMs", "Tiny \($0)", "snes", 1_000) }
        // Leftover files: a few kilobytes are hidden from the list, a real amount stays listed.
        items += [item("rom:snes:*other", "rom", "rom", "ROMs", "Other Super Nintendo files", "snes", 900_000),
                  item("rom:psx:*other", "rom", "rom", "ROMs", "Other PlayStation files", "psx", 2_000_000)]
        func games(_ drive: String, _ items: [String]) -> Data {
            Data("""
            {"drive":{"id":"\(drive)","uuid":"u3"},"items":[\(items.joined(separator: ","))],
             "coverage":[{"source":"rom","name":"ROMs","status":"scanned","games":9,"note":null},
                         {"source":"other","name":"Other launchers","status":"unsupported","games":0,"note":"Amazon isn't detected."}],
             "total":999007000,"unknown":1,"partial":1,"shared":4096,"errors":[]}
            """.utf8)
        }
        log.calls[0].1(0, games("ssd1", []))
        precondition(driveGamesCache["ssd1"] == nil && labels(driveDetailRows).contains("Measuring games on this drive..."),
                     "A scan for a drive that is no longer shown never lands")
        log.calls[1].1(0, games("ssd3", items))
        let decoded = driveGamesCache["ssd3"]!.games
        let individual = GameStorageSlice.slices(decoded, romsBySystem: false, pcByLauncher: false)
        precondition(!individual.contains { $0.title == "Other Super Nintendo files" } && individual.contains { $0.title == "Other PlayStation files" },
                     "Only negligible Other files rows are hidden")
        precondition(individual.count == 15 && individual.first?.title == "Portal 2" && individual.last?.bytes == nil,
                     "Individual view lists every game largest first, unknown sizes last")
        precondition(individual.map(\.tenths).reduce(0, +) == 1000, "Rounded shares add up to exactly 100%")
        precondition(individual.first { $0.title == "Tiny 0" }?.percent == "<0.1%", "Tiny games keep a visible share instead of 0%")
        precondition(individual.first { $0.title == "Unknown size" }?.percent == "—")
        let bySystem = GameStorageSlice.slices(decoded, romsBySystem: true, pcByLauncher: false)
        let psx = bySystem.first { $0.id == "system:psx" }!
        precondition(psx.title == "PlayStation ROMs" && psx.bytes == 402_000_000 && psx.games == 3 && psx.partial, "ROMs sum by system")
        precondition(bySystem.contains { $0.title == "Portal 2" } && !bySystem.contains { $0.title == "Alpha" },
                     "Grouping ROMs keeps PC games individual")
        let byLauncher = GameStorageSlice.slices(decoded, romsBySystem: false, pcByLauncher: true)
        let steam = byLauncher.first { $0.id == "launcher:steam" }!
        precondition(steam.title == "Steam games" && steam.bytes == 540_000_000 && steam.games == 2 &&
                     byLauncher.contains { $0.title == "GOG games" } && byLauncher.contains { $0.title == "Windows bottles (launcher unknown)" } &&
                     byLauncher.contains { $0.title == "Alpha" }, "PC games sum by launcher; bottles stay unattributed; ROMs stay individual")
        let epic = byLauncher.first { $0.id == "launcher:epic" }!
        precondition(epic.bytes == nil && epic.unknown == 1, "A launcher with only unknown sizes isn't shown as zero")
        let both = GameStorageSlice.slices(decoded, romsBySystem: true, pcByLauncher: true)
        // Split into typed values: one combined expression is too slow for older Swift type checkers (CI).
        let bothIDs: Set<String> = Set(both.map { $0.id })
        let expectedIDs: Set<String> = ["system:psx", "system:snes", "launcher:steam", "launcher:gog", "launcher:bottle", "launcher:epic"]
        let bothBytes: Int64 = both.compactMap { $0.bytes }.reduce(0, +)
        let individualBytes: Int64 = individual.compactMap { $0.bytes }.reduce(0, +)
        let bothTenths: Int = both.map { $0.tenths }.reduce(0, +)
        precondition(bothIDs == expectedIDs, "Both groupings: \(bothIDs)")
        precondition(bothBytes == individualBytes + 900_000, "Both groupings together keep the same total")
        precondition(bothTenths == 1000, "Both groupings' shares add up to 100%")
        func rows() -> [NSView] { views(driveDetailRows).filter { $0.identifier?.rawValue == "drive-games-row" } }
        func checkbox(_ id: String) -> NSButton { views(driveDetailRows).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }! }
        let page = labels(driveDetailRows)
        precondition(page.contains("Game storage") && page.contains { $0.hasPrefix("Share of ") && $0.contains("games found on this drive") },
                     "The breakdown names its denominator")
        precondition(views(driveDetailRows).last { $0.identifier?.rawValue == "drive-games-bar" } != nil && rows().count == 12 &&
                     checkbox("drive-games-more").title == "Show all 15", "The list starts with the biggest games and can show every one")
        precondition(page.contains { $0.contains("unknown size") && $0.contains("Amazon isn't detected.") }, "Coverage and unknowns are stated")
        let bar = views(driveDetailRows).compactMap { $0 as? GameStorageBar }.first!
        precondition(bar.segments.count == GameStorageBar.colored + 1 && bar.segments.last!.title.hasPrefix("Other ("),
                     "Only the largest games get colors; the rest share one gray segment")
        views(driveDetailRows).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drive-games-more" }!.performClick(nil)
        precondition(rows().count == 15 && checkbox("drive-games-more").title == "Show fewer", "Tiny games stay reachable")
        precondition(!labels(driveDetailRows).contains("Other Super Nintendo files") && labels(driveDetailRows).contains("Other PlayStation files"),
                     "Kilobytes of leftover files aren't listed")
        checkbox("drive-group-roms").performClick(nil)
        precondition(UserDefaults.standard.bool(forKey: romsBySystemKey) && labels(driveDetailRows).contains("PlayStation ROMs") &&
                     labels(driveDetailRows).contains("Portal 2") && log.calls.count == 2, "Grouping by system re-renders without rescanning")
        checkbox("drive-group-pc").performClick(nil)
        precondition(checkbox("drive-group-roms").state == .on && labels(driveDetailRows).contains("Steam games") &&
                     labels(driveDetailRows).contains("PlayStation ROMs") && rows().count == 6 && log.calls.count == 2,
                     "Launcher grouping keeps the ROM grouping")
        checkbox("drive-group-roms").performClick(nil)
        checkbox("drive-group-pc").performClick(nil)
        precondition(labels(driveDetailRows).contains("Alpha") && labels(driveDetailRows).contains("Portal 2"))
        showDriveDetail("ssd3")
        precondition(log.calls.count == 2, "Reopening a recently measured drive reuses its results")
        views(driveDetailRows).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drive-games-rescan" }!.performClick(nil)
        precondition(log.calls.count == 3 && log.calls[2].0 == "ssd3" && labels(driveDetailRows).contains { $0.hasPrefix("Rescanning...") },
                     "Rescan measures again while showing the previous results")
        log.calls[2].1(1, Data())
        precondition(driveGamesCache["ssd3"] != nil && labels(driveDetailRows).contains("Alpha"),
                     "A failed rescan keeps the last good results")
        driveGamesShowAll = false
    }

    func finishSmokeTest(success: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test"), !smokeFinishing else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let requestedPage = arguments.firstIndex(of: "--page").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        if requestedPage != nil || arguments.contains("--smoke-flow") {
            if ["0", "5", "6"].contains(requestedPage ?? "") || arguments.contains("--smoke-flow"), !smokeSteamLoaded {
                smokeSteamLoaded = true
                execute(["steam-status"], capture: true) { code, data in
                    do {
                        self.steamReport = try JSONDecoder().decode(SteamLibraryReport.self, from: data)
                        self.renderSteamLibraries()
                        self.renderGeneral()
                        precondition(!self.steamGuideRows.arrangedSubviews.isEmpty)
                        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
                        self.smokeTestDriveOverview()
                        self.smokeTestAppOperations()
                        self.smokeTestWindowsDownloads()
                        self.smokeTestStoreAccounts()
                        self.smokeTestActivityStaysClosed()
                        precondition(!self.librarySummary.stringValue.isEmpty)
                        let page = self.tabs.tabViewItems[6].view!
                        precondition(views(page).contains { $0.identifier?.rawValue == "library-storage-menu" })
                        let menu = views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "library-storage-menu" }!
                        precondition(menu.itemArray.dropFirst().map(\.title) == ["Check Library"], "Storage is changed on this page, not elsewhere")
                        // Sidebar task model: guided setup shows one page's tasks at a time; off shows all.
                        let tasks = [SidebarTask(page: 1, color: .systemYellow, title: "Get an app", setup: true),
                                     SidebarTask(page: 8, color: .systemYellow, title: "Allow Bluetooth", setup: true),
                                     SidebarTask(page: 7, color: .systemRed, title: "BIOS", setup: false),
                                     SidebarTask(page: 7, color: .systemYellow, title: "BIOS 2", setup: false),
                                     SidebarTask(page: 1, color: .systemYellow, title: "Update", setup: false)]
                        let guided = sidebarBadges(tasks, guided: true)
                        precondition(guided.keys.sorted() == [1] && guided[1]?.count == 2 && guided[1]?.color == .systemYellow,
                                     "Guided setup marks only the current step, including its maintenance tasks")
                        let free = sidebarBadges(tasks, guided: false)
                        precondition(free.keys.sorted() == [1, 7, 8] && free[8]?.count == 1 && free[1]?.count == 2 &&
                                     free[7]?.count == 2 && free[7]?.color == .systemRed, "Guided setup off shows every task")
                        let later = sidebarBadges(tasks.filter { $0.page != 1 }, guided: true)
                        precondition(later.keys.sorted() == [7] && later[7]?.color == .systemRed,
                                     "Maintenance-only pages are guided in order too")
                        let last = sidebarBadges(tasks.filter { $0.page == 8 }, guided: true)
                        precondition(last.keys.sorted() == [8], "The next step appears once earlier ones are done")
                        precondition(sidebarBadges([SidebarTask(page: 99, color: .systemRed, title: "x", setup: false)], guided: true)[99]?.count == 1,
                                     "Pages outside the guided order still surface when nothing earlier is open")
                        precondition(free[7]?.groups.map(\.color) == [.systemRed, .systemYellow] &&
                                     free[7]?.groups.map(\.count) == [1, 1] && free[1]?.groups.count == 1,
                                     "Mixed severities get separate red and yellow counts")
                        let mixed = sidebarBadges([SidebarTask(page: 6, color: .systemYellow, title: "a", setup: true),
                                                   SidebarTask(page: 6, color: .systemRed, title: "b", setup: false),
                                                   SidebarTask(page: 6, color: .systemYellow, title: "c", setup: false),
                                                   SidebarTask(page: 7, color: .systemRed, title: "d", setup: false)], guided: true)
                        precondition(mixed.keys.sorted() == [6] && mixed[6]?.groups.map(\.count) == [1, 2] &&
                                     mixed[6]?.groups[1].titles == ["a", "c"], "Guided step keeps both severity counts; later pages stay hidden")
                        // Guided step stays put while checks arrive in any order.
                        let storageTask = SidebarTask(page: 6, color: .systemYellow, title: "Prepare", setup: true)
                        let appTask = SidebarTask(page: 1, color: .systemRed, title: "Get a TV menu", setup: true)
                        let biosTask = SidebarTask(page: 7, color: .systemRed, title: "BIOS", setup: false)
                        var step = guidedSidebarStep([biosTask], pinned: nil, settled: false, previous: [:])
                        precondition(step.badges.isEmpty && step.pinned == nil, "Nothing is guided before checks settle")
                        step = guidedSidebarStep([biosTask, appTask], pinned: step.pinned, settled: false, previous: step.badges)
                        precondition(step.badges.isEmpty, "Partial results never pick a step")
                        step = guidedSidebarStep([biosTask, appTask], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == 1 && step.badges.keys.sorted() == [1], "Settled checks pick the first step")
                        step = guidedSidebarStep([], pinned: step.pinned, settled: false, previous: step.badges)
                        precondition(step.pinned == 1 && step.badges[1]?.titles == ["Get a TV menu"],
                                     "A refresh that hasn't loaded yet must not hide or move the step")
                        step = guidedSidebarStep([storageTask, biosTask, appTask], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == 1 && step.badges.keys.sorted() == [1],
                                     "A newly found earlier task must not displace the current step")
                        step = guidedSidebarStep([biosTask, storageTask], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == 6 && step.badges.keys.sorted() == [6], "Once done, the next step in order appears")
                        step = guidedSidebarStep([], pinned: step.pinned, settled: true, previous: step.badges)
                        precondition(step.pinned == nil && step.badges.isEmpty, "No stale markers once everything is done")
                        for (page, badge) in self.sidebarTaskCounts {
                            precondition(self.sidebarAttention[page] == badge.color && badge.count == badge.titles.count)
                        }
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load Steam smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
            if requestedPage == "1" || requestedPage == "2" || arguments.contains("--smoke-flow"), !smokeAppsLoaded {
                smokeAppsLoaded = true
                execute(["apps"], capture: true) { code, data in
                    do {
                        self.appStates = try JSONDecoder().decode([ManagedApp].self, from: data)
                        self.renderApps()
                        self.renderTVMenus()
                        self.appsStatus.stringValue = "Installed versions. Updates are checked only when requested."
                        precondition(Set(self.appStates.map { $0.id }) == Set(["steam", "steamac", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "porting-kit", "crossover", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]))
                        for app in self.appStates {
                            let iconURL = Bundle.main.resourceURL!.appendingPathComponent("AppIcons/\(app.id).png")
                            precondition(NSImage(contentsOf: iconURL) != nil, "Missing app icon: \(app.id)")
                        }
                        let porting = self.appStates.firstIndex { $0.id == "porting-kit" }!
                        precondition(self.appStates[porting + 1].id == "crossover")
                        let steamIndex = self.appStates.firstIndex { $0.id == "steam" }!
                        precondition(self.appStates[steamIndex + 1].id == "steamac", "FX Steam Launcher sits right below Steam")
                        let battle = self.appStates.firstIndex { $0.id == "battle-net" }!
                        precondition(self.appStates[battle + 1].id == "curseforge")
                        func buttons(in view: NSView) -> [NSButton] {
                            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
                        }
                        for installed in [false, true] {
                            for update in [false, true] {
                                let preview = ManagedApp(id: "pcsx2", name: "PCSX2", installed: installed,
                                    path: "/Applications/PCSX2.app", version: "1.0", managed: true,
                                    update: update ? "2.0" : nil, manual: false, brew: true, url: nil)
                                let rows = NSStackView()
                                self.addAppRow(preview, index: 0, to: rows)
                                let controls = buttons(in: rows)
                                func appLabels(_ view: NSView) -> [String] {
                                    (view as? NSTextField).map { [$0.stringValue] } ??
                                        view.subviews.flatMap { appLabels($0) }
                                }
                                precondition(appLabels(rows).contains(installed ?
                                    (update ? "Installed · Update available" : "Installed") : "Not installed"))
                                precondition(controls.count == 1)
                                if installed {
                                    precondition(controls.allSatisfy { $0.toolTip != nil })
                                    precondition(controls.last is NSPopUpButton)
                                    let menu = (controls.last as! NSPopUpButton).menu!
                                    precondition(menu.items.last?.title == "Remove…")
                                    precondition(menu.items.last?.action == #selector(self.removeAppFromMenu(_:)))
                                    precondition(menu.items.last?.tag == 0)
                                    precondition(controls.last?.toolTip == "More options for PCSX2")
                                    let updateItem = menu.items.first { $0.title == "Update" }
                                    precondition(updateItem?.action == #selector(self.updateAppFromMenu(_:)))
                                    precondition(updateItem?.isEnabled == update)
                                } else {
                                    precondition(controls.first?.bezelStyle == .rounded && controls.first?.title == "Get")
                                }
                                if !installed {
                                    precondition(controls.last?.action == #selector(self.appAction(_:)))
                                }
                                self.clearRows(rows)
                            }
                        }
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load app smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
            if requestedPage == "7" || arguments.contains("--smoke-flow"), !smokeSystemsLoaded {
                smokeSystemsLoaded = true
                execute(["system-catalog"], capture: true) { code, data in
                    do {
                        self.consoleSystems = try JSONDecoder().decode([ConsoleSystem].self, from: data)
                        self.renderSystems()
                        precondition(self.consoleSystems.contains { $0.id == "switch" })
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load console smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
        }
        if arguments.contains("--smoke-flow") && !smokeOverviewRefreshed {
            smokeOverviewRefreshed = true
            selectPage(0)
            refreshGeneral()
            precondition(task != nil && !overviewChecks.isEmpty,
                         "Home must refresh asynchronously with pending indicators")
            return
        }
        smokeFinishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let stack = self.detail.subviews.compactMap { $0 as? NSStackView }.first!
                let discoveryOK = success && !self.volumes.isEmpty && self.window.isVisible
                    && self.selected != nil
                    && self.tabs.numberOfTabViewItems == 14 && self.logWindow == nil
                precondition(self.sidebarPages.count == self.sidebarTitles.count &&
                             self.sidebarPages.count == self.sidebarSymbols.count)
                precondition(!self.sidebarPages.contains(3) && !self.sidebarPages.contains(4),
                             "Storage belongs under Settings, not in the sidebar")
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--minimum-size") { self.window.setContentSize(self.window.minSize) }
                precondition(self.window.frame.width >= 960, "Settings pages must preserve the minimum window width")
                if args.contains("--minimum-size") {
                    precondition(self.window.frame.width <= 980,
                                 "Header artwork must not expand the compact window: \(self.window.frame)")
                }
                if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
                   let page = Int(args[index + 1]), (0..<self.tabs.numberOfTabViewItems).contains(page) {
                    if page == 4 {
                        self.preferredMode = args.contains("--portable") ? "portable" : "local"
                        self.populateVolumes(previous: nil)
                        if self.selected == nil { self.selectionChanged() }
                    }
                    self.selectPage(page)
                }
                if args.contains("--smoke-flow") {
                    precondition(isBluetoothController(deviceClass: 0x0508, name: "HID device"))
                    precondition(isBluetoothController(deviceClass: 0, name: "DualSense Wireless Controller"))
                    precondition(!isBluetoothController(deviceClass: 0x0580, name: "Mouse"))
                    precondition(!isBluetoothController(deviceClass: 0x0540, name: "Keyboard"))
                    precondition(controllerBatteryText(level: -1, state: .discharging) == nil)
                    precondition(controllerBatteryText(level: 0, state: .unknown) == nil)
                    precondition(controllerBatteryText(level: 0.75, state: .discharging) == "75% battery")
                    for count in 0...4 {
                        let status = self.controllerOverviewStatus(count: count)
                        precondition(status.arrangedSubviews.count == 2)
                        let housing = status.arrangedSubviews[0] as! ControllerLEDHousing
                        let leds = housing.contentView!.subviews[0] as! NSStackView
                        precondition(leds.arrangedSubviews.count == 4)
                        for index in 0..<4 {
                            let dot = leds.arrangedSubviews[index] as! NSImageView
                            precondition(dot.contentTintColor == (index < count ? NSColor.systemGreen : NSColor.systemGray))
                        }
                        precondition((status.arrangedSubviews[1] as! NSTextField).stringValue ==
                                     (count == 0 ? "Not Connected" : "\(count) Connected"))
                    }
                    let assessment = self.report
                    self.busy(true)
                    precondition(stack.arrangedSubviews.count == 1 && stack.arrangedSubviews.first === self.tabs,
                                 "The main content must not include a status footer")
                    precondition(self.sidebar.isEnabled, "Navigation must stay available during operations")
                    self.busy(false)
                    for page in 0..<self.tabs.numberOfTabViewItems {
                        self.selectPage(page)
                        precondition(!self.navigationBar.isHidden && self.window === self.mainWindow)
                        precondition(self.sidebar.selectedRow == self.sidebarPages.firstIndex(of:
                            (page == 2 || page == 3 || page == 4) ? 6 : page == 5 ? 6 : page == 9 ? self.inspectorParent : page == 12 ? self.driveDetailParent : page))
                        if page == 13 { self.assertSmokeDeals() }
                        self.assertSmokePageScrolls()
                        if page == 7 {
                            for toggle in self.systemSwitches {
                                precondition(toggle.controlSize == .small)
                                let controls = toggle.superview!
                                let frame = toggle.convert(toggle.bounds, to: controls)
                                precondition(abs(frame.maxX - controls.bounds.maxX) < 4, "Console switches must align to the right edge")
                            }
                            if !self.esdeRunning {
                                self.smokeTestRapidConsoleToggles()
                                self.smokeTestConsoleBulkToggles()
                            }
                            if !self.esdeRunning { self.smokeTestSilentRefresh() }
                        }
                        if page == 6 {
                            let saved = self.storageStatus
                            let sample = self.availableVolumes[0]
                            self.storageStatus = StorageStatus(locations: [
                                StorageStatus.Location(drive: sample, configured: true, issue: nil)
                            ], active: StorageStatus.Active(id: sample.id, uuid: sample.uuid), transfer: nil)
                            self.renderStorageLocations()
                            precondition(self.gameLibraryOverviewRows.arrangedSubviews.contains { ($0 as? StorageOverviewRow)?.driveID == sample.id },
                                         "Game library lists drives with the shared overview rows")
                            precondition(self.setupFolderStatus.stringValue.hasPrefix("Active · "))
                            let library = self.tabs.tabViewItems[6].view!
                            precondition([self.setupFolderStatus, self.gameLibraryOverviewRows, self.transferLibraryButton, self.retireLibraryButton]
                                            .allSatisfy { $0.isDescendant(of: library) },
                                         "Game library includes the former Library storage controls")
                            // A button's own title only: newer AppKit draws it with an internal text field subview.
                            func texts(_ view: NSView) -> [String] {
                                if let button = view as? NSButton { return [button.title] }
                                return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts($0) }
                            }
                            let pageTexts: [String] = texts(library)
                            let refreshCount: Int = pageTexts.filter { $0 == "Refresh connected drives" }.count
                            let headingCount: Int = pageTexts.filter { $0 == "Where your games live" }.count
                            let storageDiagnostics: String = "refresh=\(refreshCount) heading=\(headingCount) texts=\(pageTexts.filter { !$0.isEmpty })"
                            precondition(refreshCount == 1, "The merged page has one drive refresh button: " + storageDiagnostics)
                            precondition(headingCount == 1, "The merged page has one storage heading: " + storageDiagnostics)
                            precondition(pageTexts.contains("Add or prepare an SSD..."), "The merged page offers SSD setup: " + storageDiagnostics)
                            precondition(pageTexts.contains("Move library..."), "The merged page offers moving the library: " + storageDiagnostics)
                            precondition(texts(self.tabs.tabViewItems[2].view!).isEmpty)
                            self.storageStatus = StorageStatus(locations: [], active: nil, transfer: nil)
                            self.renderStorageLocations()
                            precondition(self.setupFolderStatus.stringValue.contains("first library"))
                            precondition(!self.transferLibraryButton.isEnabled)
                            self.storageStatus = saved
                            self.renderStorageLocations()
                        }
                        if page == 8 {
                            func controllerLabels(_ view: NSView) -> [String] {
                                (view as? NSTextField).map { [$0.stringValue] } ??
                                    view.subviews.flatMap { controllerLabels($0) }
                            }
                            let labels = controllerLabels(self.activeControllerRows)
                            precondition(labels.contains("Purple PS5") && !labels.contains("DualSense Wireless Controller"))
                            precondition(labels.contains("Not connected"))
                            precondition(self.controllerColors.contains { $0.0 == "Chroma Indigo" })
                            precondition(self.controllerColors.contains { $0.0 == "Micro Green" })
                            precondition(Set(self.controllerColors.map { $0.0 }).count == self.controllerColors.count)
                            let picker = ControllerPalette.menu(selecting: "Gray Camouflage")
                            precondition(ControllerPalette.selectedName(in: picker) == "Gray Camouflage" &&
                                         picker.itemArray.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title) ==
                                            ControllerPalette.sections.map { $0.0 })
                            precondition(ControllerPalette.sections.flatMap { $0.1 }.allSatisfy {
                                !$0.brands.isEmpty && Set($0.brands).isSubset(of: ControllerPalette.brands) })
                            let micro = ControllerEntry(id: "micro", name: "8BitDo Micro", connected: true, transport: "Bluetooth")
                            precondition(ControllerPalette.canonicalName("Green", for: micro) == "Micro Green" &&
                                         ControllerPalette.canonicalName("Indigo", for: micro) == "Chroma Indigo" &&
                                         ControllerPalette.canonicalName("Carbon Black", for: micro) == "Black")
                            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                                NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
                                    for (_, color) in self.controllerColors {
                                        precondition(ControllerPalette.swatch(color).tiffRepresentation != nil)
                                    }
                                }
                            }
                            let savedBefore = self.controllerCustomizations
                            let previewArt = ControllerArtwork.menu(selecting: nil)
                            precondition(Set(ControllerArtwork.sections.flatMap(\.1)) == Set(ControllerArtwork.kinds.dropFirst()) &&
                                         ControllerArtwork.sections.flatMap(\.1).count == ControllerArtwork.kinds.count - 1,
                                         "Every artwork choice appears in exactly one company section")
                            let headers = previewArt.itemArray.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title)
                            precondition(headers == ControllerArtwork.sections.map(\.0) &&
                                         previewArt.itemArray.filter { !$0.isEnabled }.allSatisfy { $0.representedObject == nil },
                                         "Company headers are disabled, unselectable labels")
                            precondition(ControllerArtwork.selectedKind(in: previewArt) == "Automatic" &&
                                         ControllerArtwork.selectedKind(in: ControllerArtwork.menu(selecting: "Nintendo")) == "Nintendo" &&
                                         ControllerArtwork.selectedKind(in: ControllerArtwork.menu(selecting: "8BitDo Micro")) == "8BitDo Micro" &&
                                         ControllerArtwork.selectedKind(in: ControllerArtwork.menu(selecting: "Removed kind")) == "Automatic",
                                         "Saved artwork choices reselect the item, never a same-named header")
                            let previewColor = ControllerPalette.menu(selecting: "", automatic: "Black")
                            let preview = ControllerCustomizationPreview(controllerName: "Pro Controller", colorPopup: previewColor,
                                                                         artworkPopup: previewArt)
                            precondition(preview.kind == "Switch Pro Controller" && preview.colorName == "Black" &&
                                         preview.savedColor == "" && previewColor.titleOfSelectedItem == "Automatic (Black)" &&
                                         preview.imageView.image != nil && preview.iconFrame.imageView === preview.imageView &&
                                         preview.imageView.contentTintColor == ControllerPalette.color(named: "Black"),
                                         "Automatic is the default choice and shows the model color it resolves to")
                            func pick(_ popup: NSPopUpButton, _ value: String) {
                                popup.select(popup.itemArray.first { $0.representedObject as? String == value })
                                _ = popup.sendAction(popup.action, to: popup.target)
                            }
                            pick(previewArt, "Joy-Con (R)")
                            precondition(preview.colorName == "Neon Red" && previewColor.titleOfSelectedItem == "Automatic (Neon Red)",
                                         "Automatic follows the chosen artwork's model color")
                            pick(previewColor, "Shock Blue")
                            precondition(preview.kind == "Joy-Con (R)" && preview.savedColor == "Shock Blue" &&
                                         preview.imageView.contentTintColor == ControllerPalette.color(named: "Shock Blue"),
                                         "A manual color always wins over Automatic")
                            pick(previewArt, "PS5 · DualSense")
                            precondition(preview.colorName == "Shock Blue", "Changing artwork keeps a manual color")
                            pick(previewColor, "")
                            precondition(preview.colorName == "White" && preview.savedColor == "", "PS5 Automatic is DualSense white")
                            precondition(preview.iconFrame.subviews == [preview.imageView] && preview.iconFrame.layer?.backgroundColor == nil &&
                                         preview.iconFrame.frame.size == NSSize(width: 88, height: 60),
                                         "Controller art has no background: just the icon in a fixed-size frame")
                            precondition(self.controllerCustomizations.keys == savedBefore.keys &&
                                         self.controllerCustomizations.values.map(\.color) == savedBefore.values.map(\.color),
                                         "Previewing must not change saved customizations")
                            precondition(ControllerPalette.defaultName(for: ControllerEntry(
                                id: "micro", name: "8BitDo Micro", connected: true, transport: "Bluetooth")) == "Micro Green")
                            precondition(ControllerPalette.defaultName(for: self.controllerEntries[0]) == "White")
                            for (kind, expected) in [("PS5 · DualSense", "White"), ("PS4 · DualShock 4", "Black"), ("Xbox", "Black"),
                                                     ("Switch Pro Controller", "Black"), ("Joy-Con (L)", "Neon Blue"),
                                                     ("Joy-Con (R)", "Neon Red"), ("Nintendo", "Classic Gray"), ("Steam Controller", "Black")] {
                                precondition(ControllerPalette.defaultName(forKind: kind) == expected, "Marketing color for \(kind)")
                            }
                            let ps5 = ControllerEntry(id: "hid:ps5", name: "DualSense Wireless Controller", connected: true, transport: "USB")
                            precondition(ControllerPalette.migratedName("Chroma Indigo", for: ps5) == "" &&
                                         ControllerPalette.migratedName("Galactic Purple", for: ps5) == "Galactic Purple" &&
                                         ControllerPalette.canonicalName("Chroma Indigo", for: ps5) == "Chroma Indigo" &&
                                         ControllerPalette.canonicalName("Removed color", for: ps5) == "" &&
                                         ControllerPalette.resolvedName("", for: ps5) == "White" &&
                                         ControllerPalette.resolvedName("Galactic Purple", for: ps5) == "Galactic Purple" &&
                                         ControllerPalette.resolvedName("", for: ps5, artwork: "Xbox") == "Black",
                                         "Old inferred defaults become Automatic; explicit picks stay")
                            do {
                                let backup = (self.controllerEntries, self.controllerCustomizations, self.controllerAliases,
                                              self.homeSessionControllers, self.controllerConnectedFirst)
                                let legacy = ControllerPreferences(entries: [ps5], customizations: [
                                    ps5.id: ControllerCustomization(name: "", color: "Chroma Indigo", artwork: nil)],
                                    connectedFirst: false)
                                self.restoreControllerPreferences(try! JSONDecoder().decode(ControllerPreferences.self,
                                                                                            from: JSONEncoder().encode(legacy)))
                                precondition(self.controllerCustomizations[ps5.id]?.color == "", "Legacy inferred color migrates to Automatic")
                                self.controllerCustomizations[ps5.id]?.color = "Chroma Indigo"
                                let current = self.currentControllerPreferences()
                                precondition(current.colorVersion == 2)
                                self.restoreControllerPreferences(try! JSONDecoder().decode(ControllerPreferences.self,
                                                                                            from: JSONEncoder().encode(current)))
                                precondition(self.controllerCustomizations[ps5.id]?.color == "Chroma Indigo",
                                             "A color picked after Automatic exists is never migrated away")
                                (self.controllerEntries, self.controllerCustomizations, self.controllerAliases,
                                 self.homeSessionControllers, self.controllerConnectedFirst) = backup
                            }
                            func identified(_ view: NSView, _ id: String) -> [NSView] {
                                (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap { identified($0, id) }
                            }
                            precondition(labels.filter { $0 == "Connected" }.count == 2 && labels.contains("25%") && labels.contains("60%"))
                            let controllerLines = self.controllerRowIDs.compactMap { self.controllerRowViews[$0] as? NSStackView }
                            precondition(controllerLines.count == self.controllerEntries.count)
                            for (entry, line) in zip(self.controllerEntries, controllerLines) {
                                precondition(line.arrangedSubviews.first is ControllerDragHandle, "Controllers need a drag handle")
                                precondition(line.arrangedSubviews.last is NSPopUpButton, "Controllers need a … menu")
                                let plate = line.arrangedSubviews[1] as! ControllerIconFrame
                                let icon = plate.imageView
                                precondition(plate.frame.size == NSSize(width: 52, height: 38) || plate.frame.isEmpty)
                                let saved = self.controllerCustomizations[entry.id]
                                let expected = entry.connected ? ControllerPalette.color(named: ControllerPalette.resolvedName(
                                    saved?.color, for: entry, artwork: saved?.artwork)) : NSColor.systemGray
                                precondition(icon.contentTintColor == expected, "Connected controllers use their color, others stay gray")
                            }
                            precondition(identified(self.activeControllerRows, "controller-transport").count == 2,
                                         "Only connected controllers show a transport icon")
                            precondition(identified(self.activeControllerRows, "controller-battery").compactMap {
                                ($0 as? NSImageView)?.contentTintColor } == [controllerBatteryWarningColor, .systemGreen])
                            for (level, state, expected) in [
                                (Float(0.10), GCDeviceBattery.State.discharging, ControllerBatterySeverity?.some(.critical)),
                                (0.05, .discharging, .critical), (0.11, .discharging, .low), (0.30, .discharging, .low),
                                (0.31, .discharging, .normal), (0.05, .charging, .charging), (0.05, .full, .normal),
                                (0.50, .unknown, nil), (Float.nan, .discharging, nil), (1.2, .discharging, nil)
                            ] {
                                precondition(controllerBatterySeverity(level: level, state: state) == expected, "Battery \(level) \(state.rawValue)")
                            }
                            precondition(controllerBatteryColor(.critical) == .systemRed && controllerBatteryColor(.low) == controllerBatteryWarningColor &&
                                         controllerBatteryColor(.normal) == .secondaryLabelColor && controllerBatteryColor(.charging) == .systemGreen)
                            func menuTitles(_ popup: NSPopUpButton) -> [String: Bool] {
                                Dictionary(popup.itemArray.dropFirst().filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) },
                                           uniquingKeysWith: { first, _ in first })
                            }
                            let firstMenu = menuTitles(controllerLines[0].arrangedSubviews.last as! NSPopUpButton)
                            precondition(firstMenu["Customize…"] == true && firstMenu["Move Up"] == false && firstMenu["Move Down"] == true &&
                                         firstMenu["Remove from List"] == false && firstMenu["Forget Device…"] == nil)
                            let pairedMenu = menuTitles(self.controllerMenuButton(ControllerEntry(id: "bt:aabbccddeeff",
                                name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"), list: 1, position: 0, count: 1))
                            precondition(pairedMenu["Disconnect"] != nil && pairedMenu["Connect"] == nil && pairedMenu["Forget Device…"] != nil)
                            let offlineMenu = menuTitles(self.controllerMenuButton(ControllerEntry(id: "bt:aabbccddeeff",
                                name: "DualSense Wireless Controller", connected: false, transport: "Bluetooth"), list: 1, position: 0, count: 1))
                            precondition(offlineMenu["Connect"] == true && offlineMenu["Disconnect"] == nil)
                            precondition(self.discoveredControllerRows.arrangedSubviews.contains {
                                $0.identifier?.rawValue == "discovered-controller" } && !self.discoveredControllerRows.isHidden)
                            precondition(identified(self.discoveredControllerRows, "98-b6-e9-00-00-01").compactMap { $0 as? NSButton }.first?.title == "Connect")
                            precondition(self.controllerBanner.isHidden)
                            self.controllerSmokeBanner = true
                            self.updateControllerBanner()
                            precondition(!self.controllerBanner.isHidden && self.controllerAccessButton.title == "Allow Bluetooth Access")
                            precondition(self.sidebarTasks.filter { $0.page == 8 }.count == 1, "Bluetooth access must be a Controllers task")
                            self.controllerSmokeBanner = false
                            self.updateControllerBanner()
                            precondition(self.controllerBanner.isHidden && !self.sidebarTasks.contains { $0.page == 8 })
                            precondition(reorderedControllerIDs(["a", "b", "c", "d"], moving: "d", to: 0, among: ["b", "d"]) == ["a", "d", "b", "c"])
                            precondition(reorderedControllerIDs(["a", "b", "c", "d"], moving: "a", to: 2, among: ["a", "b", "c"]) == ["b", "c", "a", "d"])
                            let originalOrder = self.controllerEntries.map { $0.id }
                            self.controllerConnectedFirst = true
                            self.renderControllerList()
                            precondition(self.controllerRowIDs == ["preview:1", "preview:3", "preview:2"])
                            precondition(controllerLabels(self.activeControllerRows).contains("Not connected"))
                            self.moveController("preview:3", toVisibleIndex: 0, list: 1)
                            precondition(self.controllerEntries.map(\.id) == ["preview:3", "preview:1", "preview:2"])
                            self.moveController("preview:2", toVisibleIndex: 0, list: 1)
                            precondition(self.controllerRowIDs == ["preview:3", "preview:1", "preview:2"],
                                         "Connected first keeps disconnected controllers in their own group")
                            self.controllerConnectedFirst = false
                            self.renderControllerList()
                            precondition(self.controllerRowIDs == ["preview:3", "preview:1", "preview:2"])
                            self.moveController("preview:2", toVisibleIndex: 0, list: 1)
                            precondition(self.controllerEntries.map(\.id) == ["preview:2", "preview:3", "preview:1"])
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            let lastRow = self.controllerRowViews["preview:1"]!
                            let firstRow = self.controllerRowViews["preview:2"]!
                            let topPoint = firstRow.convert(NSPoint(x: 4, y: firstRow.bounds.midY), to: nil)
                            let abovePoint = NSPoint(x: topPoint.x, y: firstRow.convert(firstRow.bounds, to: nil).maxY - 2)
                            _ = lastRow
                            self.dragController("preview:1", in: self.activeControllerRows, to: abovePoint)
                            precondition(self.controllerDropIndicator.superview === self.activeControllerRows)
                            self.dropController("preview:1", in: self.activeControllerRows, at: abovePoint)
                            precondition(self.controllerDropIndicator.superview == nil)
                            precondition(self.controllerEntries.map(\.id) == ["preview:1", "preview:2", "preview:3"],
                                         "Dragging to the top must move the controller first: \(self.controllerEntries.map(\.id))")
                            let byID = Dictionary(uniqueKeysWithValues: self.controllerEntries.map { ($0.id, $0) })
                            self.controllerEntries = originalOrder.compactMap { byID[$0] }
                            self.renderControllerList()
                            let entry = self.controllerEntries[0]
                            let savedName = self.controllerCustomizations[entry.id]
                            self.controllerCustomizations[entry.id]?.name = String(repeating: "Very Long Controller Name ", count: 6)
                            self.renderControllerList()
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            func layoutSnapshot() -> [NSRect] {
                                var frames: [NSRect] = [self.window.frame, self.activeControllerRows.frame]
                                frames += self.activeControllerRows.arrangedSubviews.map { $0.frame }
                                if let row = self.controllerRowViews[entry.id] {
                                    frames.append(row.frame)
                                    frames += row.subviews.map { $0.frame }
                                }
                                return frames
                            }
                            let idleLayout = layoutSnapshot()
                            precondition(self.controllerRowViews[entry.id]!.frame.maxX <= self.activeControllerRows.bounds.maxX + 0.5,
                                         "Long names must truncate inside the row")
                            self.receiveControllerInput(entry, message: "Button 1 pressed")
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            precondition(self.controllerInputLabels[entry.id]?.stringValue == "Connected",
                                         "Input must not add inline status text")
                            precondition(self.controllerImages[entry.id]?.allSatisfy { $0.accessibilityValue() as? String == "Receiving input" &&
                                (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || $0.layer?.animation(forKey: "controllerActivity") != nil) } == true,
                                         "Input only flashes the controller icon")
                            precondition(!self.controllerRowViews[entry.id]!.subviews.contains { $0.identifier?.rawValue == "controller-activity" },
                                         "No extra activity indicator")
                            precondition(layoutSnapshot() == idleLayout, "Input activity must never change row, card or window layout")
                            self.controllerLastInput[entry.id] = ("Button 1 pressed", Date(timeIntervalSinceNow: -2))
                            self.updateHomeControllerActivity(entry.id)
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            precondition(self.controllerImages[entry.id]?.allSatisfy { $0.layer?.animation(forKey: "controllerActivity") == nil &&
                                $0.accessibilityValue() == nil } == true)
                            precondition(layoutSnapshot() == idleLayout, "Returning to idle must not shift layout")
                            self.controllerCustomizations[entry.id] = savedName
                            self.renderControllerList()
                            self.receiveControllerInput(entry, message: "Button 1 pressed")
                            precondition(self.controllerTestStatus.stringValue == "Purple PS5 · Button 1 pressed")
                            precondition(self.controllerInputLabels[entry.id]?.stringValue == "Connected")
                            precondition(self.controllerInputLabels[self.controllerEntries[2].id]?.stringValue == "Connected")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 1, minimum: 0, maximum: 1) == "Button 1 pressed")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 0, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 7, usage: 1, value: 1, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 128, minimum: 0, maximum: 255) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 255, minimum: 0, maximum: 255) == "Stick / trigger X · 100%")
                            precondition(controllerAddress("AA-BB-CC-DD-EE-FF") == "aabbccddeeff")
                            precondition(controllerAddress("not an address") == nil)
                            let bluetoothID = "bt:aabbccddeeff"
                            let usbSerial = "hid:1356:3302:USB:serial:aa-bb-cc-dd-ee-ff"
                            precondition(verifiedBluetoothAlias(for: usbSerial, knownBluetoothIDs: [bluetoothID]) == bluetoothID)
                            precondition(verifiedBluetoothAlias(for: "hid:1356:3302:USB:serial:AA:BB:CC:DD:EE:FF", knownBluetoothIDs: [bluetoothID]) == bluetoothID)
                            for unverified in ["hid:1356:3302:USB:location:12345", "hid:1356:3302:USB:serial:XYZ123",
                                               "hid:1356:3302:USB:serial:aabbccddee00", "hid:1356:3302:Bluetooth:serial:aa-bb-cc-dd-ee-ff",
                                               "hid:1356:3302:USB:serial:aabbccddeeff-2"] {
                                precondition(verifiedBluetoothAlias(for: unverified, knownBluetoothIDs: [bluetoothID]) == nil, unverified)
                            }
                            let savedPreviewEntries = self.controllerEntries
                            let savedCustomizations = self.controllerCustomizations
                            self.controllerEntries = [ControllerEntry(id: bluetoothID, name: "DualSense Wireless Controller", connected: false, transport: "Bluetooth")]
                            self.controllerCustomizations[bluetoothID] = ControllerCustomization(name: "Mine", color: "Galactic Purple")
                            let pairedDualSense = PairedController(name: "DualSense Wireless Controller", address: "aa-bb-cc-dd-ee-ff", connected: false)
                            self.mergeControllerList([ControllerEntry(id: usbSerial, name: "DualSense Wireless Controller", connected: true, transport: "Wired")],
                                                     paired: [pairedDualSense])
                            precondition(self.controllerEntries.count == 1 && self.controllerEntries[0].id == bluetoothID &&
                                         self.controllerEntries[0].connected && self.controllerEntries[0].transport == "Wired" &&
                                         self.controllerAliases[usbSerial] == bluetoothID, "A verified USB serial must reuse the Bluetooth profile")
                            let twins = (1...2).map { ControllerEntry(id: "hid:1356:3302:USB:location:\($0)", name: "DualSense Wireless Controller",
                                                                      connected: true, transport: "Wired") }
                            self.mergeControllerList(twins, paired: [pairedDualSense])
                            precondition(self.controllerEntries.count == 3 && self.controllerAliases.count == 1,
                                         "Same-model controllers must never merge by name or model")
                            let candidates = self.controllerLinkCandidates(for: twins[0])
                            precondition(candidates.isEmpty, "A Bluetooth profile that already has a verified USB link is not offered again")
                            self.controllerAliases = [:]
                            precondition(self.controllerLinkCandidates(for: twins[0]).map(\.id) == [bluetoothID])
                            self.linkController(twins[0].id, to: bluetoothID)
                            precondition(!self.controllerEntries.contains { $0.id == twins[0].id } &&
                                         self.controllerEntries.first { $0.id == bluetoothID }?.transport == "Wired")
                            let linkedPreferences = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(self.currentControllerPreferences()))
                            self.restoreControllerPreferences(linkedPreferences)
                            precondition(self.controllerAliases == [twins[0].id: bluetoothID] &&
                                         self.controllerCustomizations[bluetoothID]?.name == "Mine" &&
                                         !self.controllerEntries.contains { $0.id == twins[0].id }, "Aliases must survive a restart")
                            let separate = NSMenuItem()
                            separate.representedObject = bluetoothID
                            self.unlinkController(separate)
                            precondition(self.controllerAliases.isEmpty)
                            // Profiles follow the controller's own Bluetooth address across Forget, re-pair and USB.
                            precondition(controllerAddressFromSonyReport([0x09, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x08], reportID: 0x09) == "aabbccddeeff")
                            precondition(controllerAddressFromSonyReport([0x12, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa], reportID: 0x12) == "aabbccddeeff")
                            for bad in [[0x12, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa], [0x09, 0, 0, 0, 0, 0, 0], [0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0x09, 1, 2]] as [[UInt8]] {
                                precondition(controllerAddressFromSonyReport(bad, reportID: 0x09) == nil, "Unproven Sony address reports are rejected")
                            }
                            precondition(sonyAddressReportID(vendor: 0x054C, product: 0x0CE6) == 0x09 &&
                                         sonyAddressReportID(vendor: 0x054C, product: 0x09CC) == 0x12 &&
                                         sonyAddressReportID(vendor: 0x045E, product: 0x0B13) == nil &&
                                         sonyAddressReportID(vendor: 0x057E, product: 0x2009) == nil)
                            self.controllerAliases = [:]
                            self.controllerEntries = [ControllerEntry(id: bluetoothID, name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"),
                                                      ControllerEntry(id: "bt:112233445566", name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth")]
                            self.controllerCustomizations[bluetoothID] = ControllerCustomization(name: "Mine", color: "Galactic Purple", artwork: "PlayStation")
                            self.controllerCustomizations["bt:112233445566"] = ControllerCustomization(name: "Guest", color: "Cosmic Red")
                            self.forgetControllerPairing(bluetoothID, deleteProfile: false)
                            precondition(!self.controllerEntries.contains { $0.id == bluetoothID } &&
                                         self.controllerCustomizations[bluetoothID]?.name == "Mine", "Forget keeps the profile")
                            let afterForget = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(self.currentControllerPreferences()))
                            self.restoreControllerPreferences(afterForget)
                            self.mergeControllerList([], paired: [PairedController(name: "DualSense Wireless Controller", address: "AA:BB:CC:DD:EE:FF", connected: true),
                                                                  PairedController(name: "DualSense Wireless Controller", address: "11-22-33-44-55-66", connected: true)])
                            let repaired = self.controllerEntries.first { $0.id == bluetoothID }
                            precondition(repaired != nil && self.controllerDisplayName(repaired!) == "Mine" &&
                                         self.controllerCustomizations[bluetoothID]?.color == "Galactic Purple" &&
                                         self.controllerCustomizations[bluetoothID]?.artwork == "PlayStation" &&
                                         self.controllerCustomizations["bt:112233445566"]?.name == "Guest",
                                         "Re-pairing restores name, color and icon without touching an identical controller")
                            // USB first: the profile set over USB moves onto the Bluetooth address the pad reports, in place.
                            let usbFirst = "hid:1356:3302:USB:location:77"
                            self.controllerEntries = [ControllerEntry(id: "bt:112233445566", name: "DualSense Wireless Controller", connected: false, transport: "Bluetooth"),
                                                      ControllerEntry(id: usbFirst, name: "DualSense Wireless Controller", connected: true, transport: "Wired")]
                            self.controllerCustomizations = [usbFirst: ControllerCustomization(name: "Desk", color: "Starlight Blue"),
                                                             "bt:112233445566": ControllerCustomization(name: "Guest", color: "Cosmic Red")]
                            self.mergeControllerList([ControllerEntry(id: usbFirst, name: "DualSense Wireless Controller", connected: true, transport: "Wired",
                                                                      hardwareAddress: "a0b1c2d3e4f5")], paired: [])
                            precondition(self.controllerEntries.map(\.id) == ["bt:112233445566", "bt:a0b1c2d3e4f5"] &&
                                         self.controllerAliases[usbFirst] == "bt:a0b1c2d3e4f5" &&
                                         self.controllerCustomizations["bt:a0b1c2d3e4f5"]?.name == "Desk" &&
                                         self.controllerCustomizations[usbFirst] == nil, "A USB-reported address adopts the profile in place")
                            self.mergeControllerList([], paired: [PairedController(name: "DualSense Wireless Controller", address: "a0-b1-c2-d3-e4-f5", connected: true)])
                            precondition(self.controllerEntries.count == 2 && self.controllerEntries[1].transport == "Bluetooth" &&
                                         self.controllerDisplayName(self.controllerEntries[1]) == "Desk", "Bluetooth later uses the same profile")
                            // Joy-Cons never adopt anything, even with an address-looking serial.
                            let joyUSB = ControllerEntry(id: "hid:1406:8198:USB:serial:aa-bb-cc-dd-ee-ff", name: "Joy-Con (L)", connected: true,
                                                         transport: "Wired", model: "Joy-Con (L)", hardwareAddress: "aabbccddeeff")
                            precondition(controllerProfileAlias(for: joyUSB, knownBluetoothIDs: [bluetoothID]) == nil)
                            self.controllerAliases = [:]
                            self.forgetControllerPairing("bt:112233445566", deleteProfile: true)
                            precondition(self.controllerCustomizations["bt:112233445566"] == nil, "Forget and Delete Profile removes it")
                            self.controllerAliases = [:]
                            self.controllerEntries = savedPreviewEntries
                            self.controllerCustomizations = savedCustomizations
                            self.controllerCustomizations[bluetoothID] = nil
                            self.controllerConnectedFirst = true
                            let preferences = self.currentControllerPreferences()
                            let restored = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(preferences))
                            precondition(restored.customizations[entry.id]?.name == "Purple PS5")
                            precondition(restored.customizations[entry.id]?.color == "Galactic Purple")
                            precondition(restored.connectedFirst && restored.entries.map(\.id) == originalOrder)
                            self.controllerConnectedFirst = false
                            self.updateControllerSortMenu()
                            self.mergeControllerList([], paired: [])
                            precondition(self.controllerEntries.allSatisfy { !$0.connected })
                            precondition(self.controllerEntries.map { $0.id } == originalOrder)
                            self.refreshControllers()
                        }
                    }
                    for (index, page) in self.sidebarPages.enumerated() where page < 0 {
                        precondition(!self.tableView(self.sidebar, shouldSelectRow: index), "Sidebar section headings must not navigate")
                    }
                    precondition(self.systemSwitches.count == 17 && self.activeControllerRows.arrangedSubviews.count == 5)
                    precondition(self.consoleRows.arrangedSubviews.count == 4,
                                 "The all-consoles row, then one card each for Nintendo, PlayStation and SEGA")
                    precondition(self.consoleBulkToggles.map(\.scope) == ["all consoles", "Nintendo consoles", "PlayStation consoles",
                                 "SEGA consoles", "Nintendo home consoles", "Nintendo handhelds"],
                                 "Show/hide-all switches for the page, each section and each subsection")
                    let readyBIOS = BIOSStatus(state: "present", summary: "", files: [])
                    for (enabled, installed, bios, expected) in [
                        (false, false, readyBIOS, NSColor.systemGray),
                        (true, false, readyBIOS, NSColor.systemRed),
                        (true, true, readyBIOS, NSColor.systemGreen),
                        (true, true, BIOSStatus(state: "optional", summary: "", files: []), NSColor.systemYellow),
                        (true, true, BIOSStatus(state: "missing", summary: "", files: []), NSColor.systemRed),
                        (true, true, BIOSStatus(state: "manual", summary: "", files: []), NSColor.systemGray)
                    ] {
                        let preview = ConsoleSystem(id: "psx", name: "PlayStation", enabled: enabled,
                            package: "retroarch-metal", requirement: "", bios: bios, emulator_installed: installed)
                        precondition(self.consoleReadiness(preview).color == expected)
                        let emulatorColor = self.emulatorStatus(preview).color
                        if !enabled {
                            precondition(emulatorColor == .systemGray)
                        } else if !installed {
                            precondition(emulatorColor == .systemRed)
                        } else {
                            precondition(emulatorColor == .systemGreen || emulatorColor == .systemYellow,
                                         "Missing BIOS must not mark an installed emulator red")
                        }
                        precondition(self.emulatorName(preview) == "RetroArch")
                    }
                    precondition(self.controllerInputManager == nil, "Input monitoring must stop when leaving Controllers")
                    let previousTestText = self.controllerTestStatus.stringValue
                    self.receiveControllerInput(self.controllerEntries[0], message: "Ignored outside Controllers")
                    precondition(self.controllerTestStatus.stringValue == previousTestText)
                    self.selectPage(0)
                    let homeEntry = self.controllerEntries[0]
                    precondition(self.homeControllerRowIDs == Array(self.orderedControllers(self.controllerEntries).map(\.id).prefix(4)) &&
                                 self.homeControllerInputLabels.count == 3,
                                 "Home must show the same controllers, in the same order, as Controllers")
                    do {
                        // Regression: input on a connected controller must not move a disconnected neighbour's name.
                        let saved = self.controllerEntries
                        self.controllerEntries = Array(saved.prefix(2))
                        self.controllerEntries[0].connected = true
                        self.controllerEntries[1].connected = false
                        self.renderHomeControllers()
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        let ids = self.homeControllerRowIDs
                        precondition(ids.count == 2, "Jitter scenario needs two Home rows")
                        let rows = ids.map { self.homeControllerRowViews[$0]! }
                        func fields(_ view: NSView) -> [NSTextField] {
                            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
                        }
                        func nameFrames() -> [NSRect] {
                            rows.flatMap(fields).map { $0.convert($0.bounds, to: nil) }
                        }
                        let frames = nameFrames()
                        let renders = self.homeControllerRenderCount
                        for i in 0..<6 {
                            self.receiveControllerInput(self.controllerEntries[0], message: "Button \(i) pressed")
                            self.renderHomeControllers()
                            self.renderGeneral()
                            self.window.contentView!.layoutSubtreeIfNeeded()
                            precondition(ids.map { self.homeControllerRowViews[$0]! }.elementsEqual(rows, by: ===),
                                         "Controller input must not rebuild Home controller rows")
                            precondition(nameFrames() == frames, "Controller input must not move Home controller names")
                        }
                        self.updateHomeControllerActivity(ids[0])
                        precondition(nameFrames() == frames, "Ending input activity must not move Home controller names")
                        precondition(self.homeControllerRenderCount == renders,
                                     "Controller input and unchanged refreshes must not rebuild Home controllers")
                        self.controllerEntries = saved
                        self.renderHomeControllers()
                    }
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    func homeLayout() -> [NSRect] {
                        [self.window.frame, self.homeControllerStatus.frame] + self.homeControllerStatus.arrangedSubviews.map(\.frame) +
                            (self.homeControllerRowViews[homeEntry.id]?.subviews.map(\.frame) ?? [])
                    }
                    let homeIdle = homeLayout()
                    self.receiveControllerInput(homeEntry, message: "Button 1 pressed")
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.homeControllerInputLabels[homeEntry.id]?.stringValue == "Connected")
                    precondition(self.homeControllerImages[homeEntry.id]?.contains { $0.accessibilityValue() as? String == "Receiving input" } == true,
                                 "Home flashes the same controller icon")
                    precondition(homeLayout() == homeIdle, "Home input must not change the tile layout")
                    precondition(self.homeControllerInputLabels[self.controllerEntries[2].id]?.stringValue == "Connected",
                                 "Only the controller sending input should light up")
                    precondition(self.controllerTestStatus.stringValue == previousTestText,
                                 "Home input must not display detailed button information")
                    self.controllerLastInput[homeEntry.id] = ("Button 1 pressed", Date(timeIntervalSinceNow: -2))
                    self.updateHomeControllerActivity(homeEntry.id)
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.homeControllerImages[homeEntry.id]?.allSatisfy { $0.layer?.animation(forKey: "controllerActivity") == nil } == true &&
                                 homeLayout() == homeIdle, "Home activity must clear after input stops without moving layout")
                    self.mergeControllerList([], paired: [])
                    precondition(self.homeControllerInputLabels.count == 3 &&
                                 self.homeControllerInputLabels.values.allSatisfy { $0.stringValue == "Not connected" },
                                 "Listed controllers must remain gray after disconnecting")
                    func assertHomeStatusesFit(_ message: String) {
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        for label in self.homeControllerInputLabels.values {
                            precondition(label.frame.width + 0.5 >= max(label.intrinsicContentSize.width, self.controllerStatusWidth(label.font!)), message + ": \(label.stringValue) is truncated")
                        }
                    }
                    assertHomeStatusesFit("Not connected must fit in the Home tile")
                    let longName = homeEntry.id
                    let savedCustomization = self.controllerCustomizations[longName]
                    self.controllerCustomizations[longName] = ControllerCustomization(
                        name: "Living Room Wireless Controller With A Very Long Custom Name", color: "Shock Blue")
                    for _ in 0..<3 {
                        self.renderHomeControllers()
                        assertHomeStatusesFit("A long name must truncate before the status")
                        self.mergeControllerList([], paired: [])
                        for id in self.homeControllerRowIDs { self.updateHomeControllerActivity(id) }
                        assertHomeStatusesFit("Repeated refreshes must keep the status readable")
                    }
                    let nameLabel = (self.homeControllerRowViews[longName]?.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.first as? NSTextField)
                    precondition(nameLabel.map { $0.convert($0.bounds, to: self.homeControllerStatus).maxX <= self.homeControllerStatus.bounds.width + 0.5 } ?? true, "Long names stay inside the tile")
                    self.controllerCustomizations[longName] = savedCustomization
                    self.renderHomeControllers()
                    let disconnected = self.controllerEntries
                    for _ in 0..<3 {
                        self.controllerEntries = disconnected.map { var entry = $0; entry.connected = true; entry.transport = "Bluetooth"; return entry }
                        self.renderHomeControllers()
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        self.controllerEntries = disconnected
                        for id in self.homeControllerRowIDs { self.updateHomeControllerActivity(id) }
                        assertHomeStatusesFit("Connected → Not connected in place must not keep the old narrow width")
                    }
                    self.renderHomeControllers()
                    precondition(!self.homeControllerStatus.arrangedSubviews.contains {
                        ($0 as? NSTextField)?.stringValue == "Connect via USB or Bluetooth"
                    }, "Remembered disconnected controllers must not show the empty-state hint")
                    let savedEntries = self.controllerEntries
                    self.controllerEntries = []
                    self.renderHomeControllers()
                    precondition(self.homeControllerStatus.arrangedSubviews.contains {
                        ($0 as? NSTextField)?.stringValue == "Connect via USB or Bluetooth"
                    })
                    self.controllerEntries = savedEntries
                    self.renderHomeControllers()
                    let newer = (1...4).map {
                        ControllerEntry(id: "new:\($0)", name: "Xbox \($0)", connected: true, transport: "Bluetooth")
                    }
                    self.mergeControllerList(newer, paired: [])
                    precondition(Set(self.homeSessionControllers) == Set(newer.map(\.id)),
                                 "New connections must evict disconnected slots, never exceed four")
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.homeControllerInputLabels.count == 4)
                    for image in self.homeControllerImages.values.flatMap({ $0 }) {
                        let frame = image.convert(image.bounds, to: self.homeControllerStatus)
                        precondition(self.homeControllerStatus.bounds.contains(frame),
                                     "All four controller icons must fit in the Home tile")
                    }
                    self.mergeControllerList(newer, paired: [])
                    precondition(self.homeSessionControllers.count == 4)
                    func homeMatchesControllers(_ message: String) {
                        self.renderControllerList()
                        precondition(self.homeControllerRowIDs == Array(self.controllerRowIDs.prefix(4)), message)
                        let more = self.homeControllerStatus.arrangedSubviews.compactMap { $0 as? NSTextField }
                            .first { $0.identifier?.rawValue == "home-controller-more" }
                        precondition(self.controllerRowIDs.count > 4 ? more?.stringValue == "\(self.controllerRowIDs.count - 4) more in Controllers" : more == nil,
                                     "Home must say how many listed controllers do not fit")
                    }
                    homeMatchesControllers("Your Order must decide Home slots")
                    precondition(self.homeControllerRowIDs == savedEntries.map(\.id) + ["new:1"])
                    self.controllerConnectedFirst = true
                    self.renderHomeControllers()
                    homeMatchesControllers("Connected First must apply to Home")
                    precondition(self.homeControllerRowIDs == newer.map(\.id))
                    self.controllerConnectedFirst = false
                    self.renderControllerList()
                    self.moveController("new:3", toVisibleIndex: 0, list: 1)
                    homeMatchesControllers("Reordering in Controllers must update Home immediately")
                    precondition(self.homeControllerRowIDs.first == "new:3")
                    let hiddenID = savedEntries[1].id
                    let removeItem = NSMenuItem()
                    removeItem.representedObject = hiddenID
                    self.removeControllerFromList(removeItem)
                    homeMatchesControllers("Removed controllers must leave Home too")
                    precondition(!self.homeControllerRowIDs.contains(hiddenID))
                    let saved = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(self.currentControllerPreferences()))
                    let homeBeforeRestart = self.homeControllerRowIDs
                    self.restoreControllerPreferences(saved)
                    self.mergeControllerList(newer, paired: [])
                    homeMatchesControllers("Order and removals must survive restart on Home")
                    precondition(self.homeControllerRowIDs == homeBeforeRestart && !self.controllerEntries.contains { $0.id == hiddenID })
                    let remembered = ControllerPreferences(entries: self.controllerEntries,
                        customizations: self.controllerCustomizations,
                        connectedFirst: self.controllerConnectedFirst,
                        recentControllerIDs: self.homeSessionControllers)
                    let decoded = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(remembered))
                    self.restoreControllerPreferences(decoded)
                    self.renderHomeControllers()
                    precondition(Set(self.homeSessionControllers) == Set(newer.map(\.id)))
                    precondition(self.controllerEntries.allSatisfy { !$0.connected },
                                 "Restoring remembered controllers must never imply a live connection")
                    precondition(self.homeControllerInputLabels.count == 4 &&
                                 self.homeControllerInputLabels.values.allSatisfy { $0.stringValue == "Not connected" })
                    let legacy = ControllerPreferences(entries: newer, customizations: [:], connectedFirst: false)
                    let legacyDecoded = try! JSONDecoder().decode(ControllerPreferences.self,
                        from: JSONEncoder().encode(legacy))
                    self.restoreControllerPreferences(legacyDecoded)
                    precondition(self.homeSessionControllers == newer.map(\.id),
                                 "Existing saved controllers must migrate without a recent-ID field")
                    self.mergeControllerList(newer, paired: [])
                    for kind in ControllerArtwork.kinds.dropFirst() {
                        precondition(ControllerArtwork.image(kind).tiffRepresentation != nil)
                    }
                    let lightBG = NSColor.white, darkBG = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                    func ink(_ name: String, dark: Bool) -> (fill: NSColor, line: NSColor, context: NSColor, rim: NSColor?) {
                        ControllerInk.choose(fill: ControllerPalette.color(named: name), background: dark ? darkBG : lightBG,
                                             dark: dark, highContrast: false)
                    }
                    precondition(abs(ControllerInk.contrast(.black, .white) - 21) < 0.01 && abs(ControllerInk.contrast(.white, .white) - 1) < 0.01)
                    precondition(ink("Black", dark: true).line == ControllerInk.lightInk && ink("Black", dark: false).line == ControllerInk.lightInk,
                                 "Black bodies get light outlines in both appearances")
                    precondition(ink("Black", dark: true).rim == nil && ink("Black", dark: false).context == ControllerInk.darkInk)
                    precondition(ink("White", dark: false).line == ControllerInk.darkInk && ink("White", dark: false).rim == nil,
                                 "White bodies keep a dark outline that separates them from light windows")
                    for name in ["Neon Red", "Neon Yellow", "Micro Green", "Classic Gray", "Neon Blue"] {
                        precondition(ink(name, dark: false).line == ControllerInk.darkInk, "\(name) keeps black lines")
                    }
                    for name in ["Cobalt Blue", "Galactic Purple", "Chroma Indigo", "Cosmic Red", "Mineral Camo", "Gray Camouflage"] {
                        for dark in [false, true] {
                            precondition(ink(name, dark: dark).line == ControllerInk.darkInk, "\(name) is colored, not black: black lines")
                        }
                    }
                    precondition(ControllerInk.isNearBlack(NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1))
                                 && !ControllerInk.isNearBlack(NSColor(srgbRed: 0.18, green: 0.05, blue: 0.40, alpha: 1)),
                                 "Only neutral near-black counts as black")
                    for (name, _) in ControllerPalette.colors {
                        for dark in [false, true] {
                            let choice = ink(name, dark: dark), bg = dark ? darkBG : lightBG
                            precondition(choice.line == (name == "Black" ? ControllerInk.lightInk : ControllerInk.darkInk),
                                         "\(name): only Black gets a light outline")
                            if name == "Black" { precondition(ControllerInk.contrast(choice.line, choice.fill) >= 3, "Black details stay readable") }
                            precondition(ControllerInk.contrast(choice.context, bg) >= 3)
                            precondition(choice.rim != nil || max(ControllerInk.contrast(choice.fill, bg), ControllerInk.contrast(choice.line, bg)) >= 3,
                                         "\(name) silhouette must not vanish")
                        }
                    }
                    for (name, _) in ControllerPalette.colors {
                        let wall = ControllerInk.choose(fill: ControllerPalette.color(named: name), background: darkBG, dark: true,
                                                        highContrast: false, style: .doubleWall)
                        precondition(wall.line == ControllerInk.darkInk, "Double wall keeps black lines on \(name), black included")
                    }
                    func pixels(_ image: NSImage, scale: CGFloat) -> Data {
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(80 * scale), pixelsHigh: Int(52 * scale),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        rep.size = NSSize(width: 80, height: 52)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 52))
                        NSGraphicsContext.restoreGraphicsState()
                        return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) } ?? Data()
                    }
                    let aqua = NSAppearance(named: .aqua)!
                    let outlineArt = ControllerArtwork.filledImage("Xbox", color: ControllerPalette.color(named: "Black"), appearance: aqua,
                                                                   highContrast: false, style: .outline)
                    let wallArt = ControllerArtwork.filledImage("Xbox", color: ControllerPalette.color(named: "Black"), appearance: aqua,
                                                                highContrast: false, style: .doubleWall)
                    precondition(outlineArt !== wallArt && pixels(outlineArt, scale: 2) != pixels(wallArt, scale: 2),
                                 "Both outline styles render and are cached separately")
                    precondition(ControllerArtwork.outlineStyle == .outline, "Outline (A) is the default style")
                    for camoName in ["Gray Camouflage", "Mineral Camo"] {
                        let color = ControllerPalette.color(named: camoName)
                        precondition(ControllerCamo.matching(color)?.name == camoName, "\(camoName) gets its camo pattern")
                        precondition(ControllerCamo.matching(color.withAlphaComponent(0.55)) == nil, "Dimmed camo stays flat")
                        let camo = ControllerArtwork.filledImage("PS5 · DualSense", color: color, appearance: aqua, highContrast: false)
                        let flat = ControllerArtwork.draw("PS5 · DualSense", fill: color, line: ControllerInk.darkInk,
                                                          context: ControllerInk.darkInk, rim: nil, boost: 0)
                        precondition(pixels(camo, scale: 2) == pixels(camo, scale: 2), "Camo is deterministic")
                        precondition(pixels(camo, scale: 2) != pixels(flat, scale: 2), "Camo is patterned at preview scale")
                        precondition(pixels(camo, scale: 0.5) == pixels(flat, scale: 0.5), "Tiny camo falls back to the flat color")
                    }
                    precondition(ControllerCamo.matching(ControllerPalette.color(named: "Classic Gray")) == nil)
                    let translucent = ControllerInk.composite(NSColor.black.withAlphaComponent(0.5), over: .white).usingColorSpace(.sRGB)!
                    precondition(translucent.alphaComponent == 1 && abs(translucent.redComponent - 0.5) < 0.01, "Fills are opaque")
                    let highContrast = ControllerInk.choose(fill: ControllerPalette.color(named: "Black"), background: darkBG, dark: true, highContrast: true)
                    precondition(highContrast.line == .white && highContrast.context == .white)
                    for kind in ControllerArtwork.kinds.dropFirst() {
                        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
                            let red = ControllerArtwork.filledImage(kind, color: ControllerPalette.color(named: "Neon Red"), appearance: appearance, highContrast: false)
                            let black = ControllerArtwork.filledImage(kind, color: ControllerPalette.color(named: "Black"), appearance: appearance, highContrast: false)
                            precondition(!red.isTemplate && red.tiffRepresentation != nil && red.tiffRepresentation != black.tiffRepresentation)
                            precondition(ControllerArtwork.filledImage(kind, color: ControllerPalette.color(named: "Neon Red"), appearance: appearance,
                                                                       highContrast: false) === red, "Rendered art is cached")
                        }
                    }
                    let artView = ControllerArtView(kind: "Xbox")
                    precondition(artView.image?.isTemplate == true)
                    artView.contentTintColor = ControllerPalette.color(named: "White")
                    let filled = artView.image
                    precondition(filled?.isTemplate == false)
                    artView.appearance = NSAppearance(named: .darkAqua)
                    precondition(artView.image !== filled || NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                                 "Appearance changes re-render the fill")
                    artView.kind = "Steam Controller"
                    precondition(artView.image?.accessibilityDescription == "Steam Controller")
                    for (name, expected) in [
                        ("DualShock 4 Wireless Controller", "PS4 · DualShock 4"),
                        ("PS4 Controller", "PS4 · DualShock 4"),
                        ("DualSense Wireless Controller", "PS5 · DualSense"),
                        ("DualSense Edge", "PS5 · DualSense"),
                        ("PS5 Controller", "PS5 · DualSense"),
                        ("PlayStation Controller", "PlayStation"),
                        ("Joy-Con (L)", "Joy-Con (L)"),
                        ("Joy-Con (R)", "Joy-Con (R)"),
                        ("Joy-Con", "Joy-Con"),
                        ("Nintendo Wireless Gamepad", "Nintendo"),
                        ("Pro Controller", "Switch Pro Controller"),
                        ("Nintendo Switch Pro Controller", "Switch Pro Controller"),
                        ("Steam Controller", "Steam Controller"),
                        ("8BitDo Ultimate 2C", "8BitDo Ultimate"),
                        ("Unidentified gamepad", "Generic")
                    ] {
                        precondition(ControllerArtwork.kind(name: name, preference: nil) == expected)
                        precondition(ControllerArtwork.kind(name: name, preference: "PlayStation") == "PlayStation",
                                     "Existing manual artwork choices must remain valid")
                    }
                    let psKinds = ["PlayStation", "PS4 · DualShock 4", "PS5 · DualSense"]
                    for (index, kind) in psKinds.enumerated() {
                        for other in psKinds.dropFirst(index + 1) {
                            precondition(ControllerArtwork.image(kind).tiffRepresentation != ControllerArtwork.image(other).tiffRepresentation,
                                         "PlayStation models must have distinct drawings")
                        }
                    }
                    precondition(ControllerArtwork.kind(name: "8BitDo Pro 2", preference: nil) == "8BitDo Pro 2")
                    precondition(ControllerArtwork.kind(name: "8BitDo SN30 Pro", preference: nil) == "8BitDo SN30 Pro")
                    precondition(ControllerArtwork.kind(name: "SN30Pro", preference: nil) == "8BitDo SN30 Pro")
                    precondition(ControllerArtwork.kind(name: "8BitDo Micro gamepad", preference: nil) == "8BitDo Micro")
                    precondition(ControllerArtwork.kind(name: "8BitDo Ultimate", preference: nil) == "8BitDo Ultimate")
                    precondition(ControllerArtwork.kind(name: "DualSense", preference: "Xbox") == "Xbox")
                    precondition(controllerModel(vendor: 0x057E, product: 0x2009, name: "Pro Controller") == "Switch Pro Controller" &&
                                 controllerModel(vendor: 0x057E, product: 0x2006, name: "Joy-Con (L)") == "Joy-Con (L)" &&
                                 controllerModel(vendor: 0x057E, product: 0x2007, name: "Joy-Con (R)") == "Joy-Con (R)" &&
                                 controllerModel(vendor: 0x057E, product: 0x1234, name: "Wireless Gamepad") == "Nintendo" &&
                                 controllerModel(vendor: 0x2DC8, product: 0x6001, name: "Pro Controller") == "Generic" &&
                                 controllerModel(vendor: 0x2DC8, product: 0x6001, name: "8BitDo Pro 2") == nil &&
                                 controllerModel(vendor: nil, product: nil, name: "Pro Controller") == nil,
                                 "Only Nintendo's vendor ID proves a genuine Switch controller")
                    precondition(joyConSide(product: 0x2006) == "Joy-Con (L)" && joyConSide(product: 0x2007) == "Joy-Con (R)" &&
                                 joyConSide(product: 0x2009) == nil, "Joy-Con L and R stay distinct from the Pro Controller")
                    precondition(ControllerArtwork.kind(name: "Pro Controller", preference: "Generic") == "Generic" &&
                                 isBluetoothController(deviceClass: 0, name: "Pro Controller") &&
                                 isBluetoothController(deviceClass: 0, name: "Joy-Con (R)") &&
                                 isBluetoothController(deviceClass: 0x002508, name: "Anything"),
                                 "Pro Controller and Joy-Con must be discoverable for pairing")
                    precondition(controllerConnectionStatus(connected: true, inputDetected: false, connecting: false) == "Bluetooth only" &&
                                 controllerConnectionStatus(connected: true, inputDetected: true, connecting: false) == "Connected" &&
                                 controllerConnectionStatus(connected: true, inputDetected: nil, connecting: false) == "Connected" &&
                                 controllerConnectionStatus(connected: false, inputDetected: nil, connecting: true) == "Connecting…",
                                 "A Bluetooth link alone must not claim working game input, nor read as a failure")
                    let proAddress = "e4-17-d8-e1-5a-ce"
                    self.mergeControllerList([], paired: [PairedController(name: "Pro Controller", address: proAddress, connected: true)])
                    let linkOnly = self.controllerEntries.first { $0.id == "bt:e417d8e15ace" }
                    precondition(linkOnly?.connected == true && linkOnly?.inputDetected == false &&
                                 self.controllerStatusText(linkOnly!, active: false) == "Bluetooth only",
                                 "Connected Bluetooth controller absent from HID input must show Bluetooth only")
                    self.mergeControllerList([ControllerEntry(id: "bt:e417d8e15ace", name: "Pro Controller", connected: true,
                                                              transport: "Bluetooth", model: "Switch Pro Controller")],
                                             paired: [PairedController(name: "Pro Controller", address: proAddress, connected: true)])
                    let withInput = self.controllerEntries.first { $0.id == "bt:e417d8e15ace" }
                    precondition(withInput?.inputDetected == nil && withInput?.model == "Switch Pro Controller" &&
                                 self.controllerStatusText(withInput!, active: false) == "Connected",
                                 "HID input upgrades a Bluetooth-only link to Connected")
                    func connectButtons(_ view: NSView) -> [NSButton] {
                        ((view as? NSButton).map { $0.title == "Connect" ? [$0] : [] } ?? []) + view.subviews.flatMap(connectButtons)
                    }
                    let discoverAddress = "98-b6-e9-00-00-02"
                    self.discoveredControllers = [PairedController(name: "Pro Controller", address: discoverAddress, connected: false)]
                    self.renderDiscoveredControllers()
                    let fullConnect = connectButtons(self.discoveredControllerRows)
                    let homePairConnect = connectButtons(self.homeDiscoveredControllerRows)
                    precondition(fullConnect.count == 1 && homePairConnect.count == 1, "Both Home and Controllers offer Connect")
                    self.smokePairRequests = []
                    self.controllerErrors = []
                    self.bluetoothSettingsOpens = 0
                    fullConnect[0].performClick(nil)
                    homePairConnect[0].performClick(nil)
                    precondition(self.smokePairRequests == [discoverAddress, discoverAddress],
                                 "Connect on Home and Controllers must pair in-app")
                    self.devicePairingPINCodeRequest(nil)
                    self.devicePairingFinished(nil, error: kIOReturnError)
                    precondition(self.controllerErrors == ["PIN code needed", "Couldn't pair"] && self.bluetoothSettingsOpens == 0,
                                 "Pair/connect problems must stay in-app and never open Bluetooth Settings")
                    self.discoveredControllers = []
                    self.renderDiscoveredControllers()
                    // A newly found controller appears once, directly under Home's list, and stays put until macOS pairs it.
                    let previousTab = self.tabs.selectedTabViewItem
                    self.tabs.selectTabViewItem(at: 0)
                    let newAddress = "98-b6-e9-00-00-03"
                    self.discoveredControllers = [PairedController(name: "Wireless Controller", address: newAddress, connected: false)]
                    self.renderDiscoveredControllers()
                    self.window.contentView?.layoutSubtreeIfNeeded()
                    let rendersAfterFind = self.discoveredRenderCount
                    func windowFrame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
                    let firstRow = self.homeDiscoveredControllerRows.arrangedSubviews.first.map(windowFrame)
                    let listFrame = windowFrame(self.homeControllerStatus)
                    precondition(firstRow != nil && abs(listFrame.minY - firstRow!.maxY) <= 17,
                                 "A discovered controller must sit right under Home's list, not at the card's bottom")
                    precondition(!self.controllerEntries.contains { $0.id == "bt:98b6e9000003" },
                                 "A discovered controller is not in the paired list before macOS pairs it")
                    for _ in 0..<3 { self.renderDiscoveredControllers(); self.renderControllerList() }
                    self.discoveredControllers.insert(PairedController(name: "Other pad", address: "98-b6-e9-00-00-04", connected: false), at: 0)
                    self.discoveredControllers.removeFirst()
                    self.renderDiscoveredControllers()
                    self.window.contentView?.layoutSubtreeIfNeeded()
                    precondition(self.discoveredRenderCount == rendersAfterFind &&
                                 self.homeDiscoveredControllerRows.arrangedSubviews.first.map(windowFrame) == firstRow,
                                 "Refreshes must not rebuild or move an unchanged Connect row under the pointer")
                    self.mergeControllerList([], paired: [PairedController(name: "Wireless Controller", address: newAddress, connected: true)])
                    precondition(self.discoveredControllers.isEmpty && self.homeDiscoveredControllerRows.isHidden &&
                                 self.controllerEntries.last?.id == "bt:98b6e9000003",
                                 "Only macOS's paired state moves it into the list")
                    self.controllerEntries.removeAll { $0.id == "bt:98b6e9000003" }
                    if let previousTab = previousTab { self.tabs.selectTabViewItem(previousTab) }
                    let joyEntries = [
                        ControllerEntry(id: "bt:aa0000000001", name: "Joy-Con (L)", connected: true, transport: "Bluetooth", model: "Joy-Con (L)"),
                        ControllerEntry(id: "bt:aa0000000002", name: "Joy-Con (R)", connected: true, transport: "Bluetooth", model: "Joy-Con (R)"),
                        ControllerEntry(id: "hid:1406:8201:USB:serial:aa0000000001", name: "Joy-Con (L)", connected: true, transport: "Wired"),
                        ControllerEntry(id: "hid:1118:2835:USB:serial:abc", name: "Xbox Controller", connected: true, transport: "Wired")
                    ]
                    self.controllerEntries = joyEntries
                    self.controllerAliases = ["hid:1406:8201:USB:serial:aa0000000001": "bt:aa0000000001"]
                    self.mergeControllerList(joyEntries, paired: [])
                    precondition(self.controllerAliases.isEmpty, "Joy-Cons must never be auto-linked or keep stale links")
                    precondition(Set(self.controllerEntries.map(\.id)).isSuperset(of: joyEntries.prefix(3).map(\.id)),
                                 "Joy-Con L, R and their USB entry stay separate controllers")
                    for entry in self.controllerEntries where isJoyCon(entry) {
                        precondition(self.controllerLinkCandidates(for: entry).isEmpty, "Joy-Cons are never offered Same Controller As")
                    }
                    if let xbox = self.controllerEntries.first(where: { $0.name == "Xbox Controller" }) {
                        precondition(!self.controllerLinkCandidates(for: xbox).contains(where: isJoyCon),
                                     "Other controllers can't link to a Joy-Con")
                    }
                    self.linkController("hid:1406:8201:USB:serial:aa0000000001", to: "bt:aa0000000001")
                    precondition(self.controllerAliases.isEmpty, "Manual linking refuses Joy-Cons")
                    precondition(ControllerArtwork.kind(name: "Joy-Con (L)", preference: "Joy-Con (L)") == "Joy-Con (L)" &&
                                 ControllerArtwork.kind(name: "Nintendo Controller", preference: nil) == "Nintendo" &&
                                 ControllerArtwork.kind(name: "Steam Controller", preference: nil) == "Steam Controller")
                    let artKinds = ["Joy-Con (L)", "Joy-Con (R)", "Joy-Con", "Nintendo", "Switch Pro Controller", "Steam Controller", "Generic"]
                    let artData = artKinds.map { ControllerArtwork.image($0).tiffRepresentation! }
                    precondition(Set(artData).count == artKinds.count, "Joy-Con L/R/pair, SNES, Switch Pro and Steam art are distinct")
                    self.controllerAliases = [:]
                    self.controllerEntries = savedEntries
                    self.homeSessionControllers = []
                    self.homeObservedConnections = []
                    self.renderHomeControllers()
                    self.selectPage(7)
                    let biosPreview = BIOSStatus(state: "missing", summary: "Missing BIOS",
                        files: [
                            BIOSFileStatus(filename: "dc/dc_boot.bin", path: "/BIOS/dc/dc_boot.bin", present: false, note: ""),
                            BIOSFileStatus(filename: "dc/dc_flash.bin", path: "/BIOS/dc/dc_flash.bin", present: false, note: "")
                        ])
                    func biosCopyButtons(_ view: NSView) -> [NSButton] {
                        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { biosCopyButtons($0) }
                    }
                    let biosButtons = biosCopyButtons(self.biosStatusView(biosPreview, searchQuery: "Dreamcast BIOS"))
                    precondition(biosButtons.first?.action == #selector(self.openBIOSFolder(_:)) &&
                                 biosButtons.first?.identifier?.rawValue == "/BIOS/dc",
                                 "BIOS details must show the destination folder")
                    let copies = biosButtons.filter { $0.action == #selector(self.copyBIOSNames(_:)) }
                    precondition(copies.map { $0.title } == ["dc_boot.bin", "dc_flash.bin", "Copy"])
                    precondition(copies.map { $0.identifier!.rawValue } ==
                                 ["dc_boot.bin", "dc_flash.bin", "Dreamcast BIOS"])
                    precondition(!biosButtons.contains { $0.title.contains("Google") || $0.title == "Copy all" })
                    precondition(biosCopyButtons(self.biosStatusView(BIOSStatus(state: "present",
                        summary: "BIOS found", files: biosPreview.files))).isEmpty)
                    let orderedSystems = ConsoleArtwork.groups.flatMap { $0.systems }
                    precondition(self.consoleSystems.map { $0.id } == orderedSystems,
                                 "Systems must stay grouped and ordered by original release")
                    let artwork = orderedSystems.compactMap { ConsoleArtwork.image(for: $0).tiffRepresentation }
                    precondition(artwork.count == 17 && Set(artwork).count == 17,
                                 "Every system must have distinct, renderable original artwork")
                    precondition(orderedSystems.allSatisfy { !ConsoleArtwork.image(for: $0).isTemplate },
                                 "Console artwork must preserve its hardware colors")
                    let switchBitmap = NSBitmapImageRep(data: ConsoleArtwork.image(for: "switch").tiffRepresentation!)!
                    let leftJoyCon = switchBitmap.colorAt(x: switchBitmap.pixelsWide * 4 / 32,
                        y: switchBitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    let rightJoyCon = switchBitmap.colorAt(x: switchBitmap.pixelsWide * 27 / 32,
                        y: switchBitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    precondition(leftJoyCon.alphaComponent > 0.9 && leftJoyCon.blueComponent > leftJoyCon.redComponent &&
                                 rightJoyCon.alphaComponent > 0.9 && rightJoyCon.redComponent > rightJoyCon.blueComponent,
                                 "Switch Joy-Cons must retain separate blue and red colors")
                    let inspectorTrigger = NSButton()
                    inspectorTrigger.tag = 0
                    self.showConsoleDetails(inspectorTrigger)
                    precondition(self.inspectorTitle.stringValue == self.consoleSystems[0].name)
                    self.closeInspector()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[7])
                    self.selectPage(0)
                    func labels(in view: NSView) -> [String] {
                        if let label = view as? NSTextField { return [label.stringValue] }
                        return view.subviews.flatMap { labels(in: $0) }
                    }
                    func indicatorColors(in view: NSView) -> [NSColor] {
                        if let image = view as? NSImageView, let color = image.contentTintColor {
                            precondition(image.layer?.animation(forKey: "checking") == nil,
                                         "Cached status must not pulse during a refresh")
                            return [color]
                        }
                        return view.subviews.flatMap { indicatorColors(in: $0) }
                    }
                    let hadAppResults = self.appsHaveResults
                    self.appsHaveResults = true
                    self.appsChecking = false
                    self.renderApps()
                    let appColors = indicatorColors(in: self.appMenuRows)
                    self.appsChecking = true
                    self.renderApps()
                    precondition(indicatorColors(in: self.appMenuRows) == appColors,
                                 "App status colors must stay unchanged during background refresh")
                    self.appsChecking = false
                    self.appsHaveResults = hadAppResults
                    self.renderApps()
                    let savedAppsForConsoleStatus = self.appStates
                    let savedSystemsForStatus = self.consoleSystems
                    let hadConsoleResults = self.consolesLoaded
                    self.appsHaveResults = true
                    self.consolesLoaded = true
                    self.consoleSystems = [ConsoleSystem(id: "ps2", name: "PlayStation 2", enabled: true,
                        package: "pcsx2", requirement: "", bios: nil, emulator_installed: true)]
                    for hasUpdate in [false, true] {
                        self.appStates = [ManagedApp(id: "pcsx2", name: "PCSX2", installed: true,
                            path: "", version: "1.0", managed: true, update: hasUpdate ? "2.0" : nil,
                            manual: false, brew: true, url: nil)]
                        let expectedTitle = hasUpdate ? "PCSX2 · Update available" : "PCSX2"
                        for refreshing in [false, true] {
                            self.consolesChecking = refreshing
                            self.renderSystems()
                            precondition(labels(in: self.consoleRows).contains(expectedTitle),
                                         "Console rows must explain updates, including during refresh")
                        }
                        let trigger = NSButton()
                        trigger.tag = 0
                        self.showConsoleDetails(trigger)
                        precondition(labels(in: self.inspectorRows).contains(expectedTitle),
                                     "Console details must explain emulator updates")
                        precondition(!labels(in: self.inspectorRows).contains { $0.contains("Emulator ready") || $0.contains("core:") },
                                     "Console details must stay short")
                        func actions(_ view: NSView) -> [Selector] {
                            ((view as? NSButton)?.action).map { [$0] } ?? view.subviews.flatMap { actions($0) }
                        }
                        precondition(actions(self.inspectorRows) == [#selector(self.showEmulatorInAppStore(_:))],
                                     "Console details must offer only the App Store link without BIOS")
                        precondition(actions(self.consoleRows).contains(#selector(self.showEmulatorInAppStore(_:))) &&
                                     !actions(self.tabs.tabViewItems[7].view!).contains(#selector(self.showPlayers)),
                                     "Console rows link to App Store; the page has no bottom App Store button")
                        self.closeInspector()
                        self.appsChecking = false
                        self.renderApps()
                        self.highlightedAppID = "pcsx2"
                        self.highlightAppRow()
                        precondition(self.highlightedAppID == nil, "App Store highlight must finish after results load")
                        func row(_ view: NSView, _ id: String) -> NSView? {
                            view.identifier?.rawValue == id ? view : view.subviews.lazy.compactMap { row($0, id) }.first
                        }
                        precondition(row(self.appRetroRows, "app-row-pcsx2")?.layer?.backgroundColor != nil,
                                     "Opening an emulator in App Store must highlight its row")
                    }
                    self.appStates = savedAppsForConsoleStatus
                    self.consoleSystems = savedSystemsForStatus
                    self.appsHaveResults = hadAppResults
                    self.consolesLoaded = true
                    self.consolesChecking = false
                    self.renderSystems()
                    let consoleColors = indicatorColors(in: self.consoleRows)
                    self.consolesChecking = true
                    self.renderSystems()
                    precondition(indicatorColors(in: self.consoleRows) == consoleColors,
                                 "Emulator and BIOS status colors must stay unchanged during refresh")
                    self.consolesChecking = false
                    self.consolesLoaded = hadConsoleResults
                    self.renderSystems()
                    self.overviewChecks = Set(OverviewCheck.allCases)
                    self.renderGeneral()
                    precondition(self.homeProgress.isHidden, "Known Home status must stay stable during refresh")
                    self.overviewChecks = []
                    self.overviewCheckFailures = [.storage]
                    self.guidedSetup = false
                    self.renderGeneral()
                    precondition(self.sidebarAttention[6] != nil, "Storage errors must mark the sidebar")
                    self.guidedSetup = true
                    self.renderGeneral()
                    precondition(self.sidebarAttention[6] != nil && self.sidebarAttention.count == 1,
                                 "Guided setup shows storage first and nothing else")
                    let savedCounts = self.sidebarTaskCounts
                    self.sidebarTaskCounts = sidebarBadges([SidebarTask(page: 7, color: .systemYellow, title: "y1", setup: false),
                                                            SidebarTask(page: 7, color: .systemRed, title: "r1", setup: false),
                                                            SidebarTask(page: 7, color: .systemYellow, title: "y2", setup: false)], guided: false)
                    if let cell = self.tableView(self.sidebar, viewFor: nil, row: self.sidebarPages.firstIndex(of: 7)!) {
                        func dots(_ view: NSView) -> [SidebarCountDot] {
                            (view as? SidebarCountDot).map { [$0] } ?? view.subviews.flatMap(dots)
                        }
                        let found = dots(cell)
                        precondition(found.map(\.color) == [.systemRed, .systemYellow] &&
                                     found.compactMap { ($0.subviews.first as? NSTextField)?.stringValue } == ["1", "2"] &&
                                     found[0].accessibilityLabel() == "1 needs attention: r1" && found[0].toolTip?.contains("2 recommended") == true,
                                     "Sidebar shows separate red and yellow markers with their own counts")
                    } else { preconditionFailure("Sidebar row must render") }
                    self.updateSelectedStorageMarker()
                    if let drive = self.selected {
                        let expected = drive.mode == "local" ? "This Mac" : "External SSD"
                        precondition(self.selectedStorageMode.stringValue.hasPrefix(expected) && !self.selectedStorageIcon.isHidden &&
                                     self.selectedStorageIcon.image != nil && self.selectedStorageIcon.accessibilityLabel() == self.selectedStorageMode.stringValue &&
                                     self.storageMode(drive.mode).symbol == (drive.mode == "local" ? "macmini" : "externaldrive"),
                                     "Game library storage uses the Library Settings mode name and icon")
                    } else {
                        precondition(self.selectedStorageMode.stringValue == "No storage selected" ||
                                     self.selectedStorageMode.stringValue.hasSuffix("· Disconnected"))
                    }
                    let controllersRow = self.sidebarPages.firstIndex(of: 8)!
                    func controllersCellLayout(_ tasks: [SidebarTask]) -> [NSRect] {
                        self.sidebarTaskCounts = sidebarBadges(tasks, guided: false)
                        let cell = self.tableView(self.sidebar, viewFor: nil, row: controllersRow)!
                        cell.frame = NSRect(x: 0, y: 0, width: 180, height: self.tableView(self.sidebar, heightOfRow: controllersRow))
                        cell.layoutSubtreeIfNeeded()
                        let title = (cell as! NSTableCellView).textField!
                        let icon = (cell as! NSTableCellView).imageView!
                        precondition(abs(title.frame.midY - cell.bounds.midY) < 1, "Sidebar titles stay vertically centered")
                        // Width may shrink for truncation; position and height must not change.
                        return [title.frame, icon.frame].map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) }
                    }
                    let task = { (color: NSColor, n: Int) in (0..<n).map { SidebarTask(page: 8, color: color, title: "t\($0)", setup: false) } }
                    let noBadge = controllersCellLayout([])
                    for tasks in [task(.systemYellow, 1), task(.systemRed, 1) + task(.systemYellow, 2),
                                  task(.systemRed, 12) + task(.systemYellow, 140), [], task(.systemYellow, 3)] {
                        precondition(controllersCellLayout(tasks) == noBadge, "Sidebar badges must never move the Controllers title or icon")
                    }
                    self.sidebarTaskCounts = savedCounts
                    self.renderGeneral()
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    let liveCells = self.sidebarPages.indices.map { self.sidebar.view(atColumn: 0, row: $0, makeIfNecessary: false) }
                    let liveFrames = liveCells.map { ($0 as? NSTableCellView)?.textField.map { $0.convert($0.bounds, to: nil) } }
                    for guided in [false, true, false] {
                        self.guidedSetup = guided
                        self.overviewCheckFailures = guided ? [] : [.storage]
                        self.renderGeneral()
                        self.window.contentView!.layoutSubtreeIfNeeded()
                        let now = self.sidebarPages.indices.map { self.sidebar.view(atColumn: 0, row: $0, makeIfNecessary: false) }
                        precondition(zip(now, liveCells).allSatisfy { $0 === $1 }, "Badge refresh updates sidebar cells in place")
                        precondition(now.map { ($0 as? NSTableCellView)?.textField.map { $0.convert($0.bounds, to: nil) }.map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) } } ==
                                     liveFrames.map { $0.map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) } },
                                     "Badge refresh must not move any sidebar title")
                    }
                    self.guidedSetup = true
                    self.overviewCheckFailures = [.storage]
                    self.renderGeneral()
                    // Battery warning orange must stay readable on light and dark rows.
                    func luminance(_ color: NSColor) -> CGFloat {
                        let c = color.usingColorSpace(.sRGB)!
                        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
                    }
                    for name in [NSAppearance.Name.aqua, .darkAqua] {
                        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                            let fg = luminance(controllerBatteryWarningColor), bg = luminance(settingsSectionBackground)
                            let ratio = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
                            precondition(ratio >= 4.5, "Battery warning contrast \(ratio) in \(name.rawValue)")
                        }
                    }
                    self.overviewCheckFailures = []
                    self.renderGeneral()
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.playAction.action == #selector(self.showPlayOverview))
                    precondition(self.playAction.isDescendant(of: self.tabs.tabViewItems[0].view!))
                    let tiles = self.homeTiles.arrangedSubviews
                    precondition(tiles.count == 2 &&
                                 abs(tiles[0].frame.width - tiles[1].frame.width) <= 1 &&
                                 tiles[0].frame.width >= 280,
                                 "Discover tiles must have equal usable widths: \(self.homeTiles.frame), \(tiles.map(\.frame)), scroll \(self.tabs.tabViewItems[0].view!.frame)")
                    precondition(NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("HomeHeader.png")) != nil)
                    precondition(NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("HomeHeaderPortable.png")) != nil)
                    for name in ["HomeHeader.png", "HomeHeaderPortable.png"] {
                        let image = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(name))
                        precondition(image?.size == NSSize(width: 1680, height: 500))
                    }
                    func homeHeaderButtons(_ view: NSView) -> [NSButton] {
                        (view.identifier?.rawValue == "home-controller-header" ? (view as! NSStackView).arrangedSubviews.compactMap { $0 as? NSButton } : []) +
                            view.subviews.flatMap { homeHeaderButtons($0) }
                    }
                    let controllerHeaderButtons = homeHeaderButtons(self.homeTiles)
                    precondition(controllerHeaderButtons.map { $0.action } == [#selector(self.showControllers)],
                                 "Home lists discovered controllers itself, so it has no separate add button")
                    precondition(!self.homeDiscoveredControllerRows.isHidden, "Discovered controllers must appear on Home")
                    let homeConnect = self.homeDiscoveredControllerRows.arrangedSubviews.flatMap { ($0 as! NSStackView).arrangedSubviews }
                        .compactMap { $0 as? NSButton }
                    precondition(homeConnect.map(\.title) == ["Connect"] &&
                                 homeConnect.first?.identifier?.rawValue == "98-b6-e9-00-00-01" &&
                                 homeConnect.first?.action == #selector(self.pairDiscoveredController(_:)),
                                 "Home must offer the same real Connect action as Controllers")
                    precondition(!self.homeTiles.arrangedSubviews[1].subviews.flatMap { $0.subviews }.contains { $0 is TileActionButton },
                                 "The controller tile must not be one big button")
                    for (id, line) in self.homeControllerRowViews {
                        let stack = line as! NSStackView
                        precondition(stack.arrangedSubviews.first is ControllerDragHandle && stack.arrangedSubviews.last is NSPopUpButton, id)
                    }
                    let hoverEvent = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber,
                        context: nil, subtype: 0, data1: 0, data2: 0)!
                    for control in [self.playAction].compactMap({ $0 as? TileActionButton }) {
                        let enabled = control.isEnabled
                        control.isEnabled = true
                        control.mouseEntered(with: hoverEvent)
                        precondition(control.isHovered)
                        control.mouseExited(with: hoverEvent)
                        precondition(!control.isHovered)
                        control.isEnabled = false
                        control.mouseEntered(with: hoverEvent)
                        precondition(!control.isHovered, "Disabled tiles must not advertise an available action")
                        control.isEnabled = enabled
                    }
                    precondition(!labels(in: self.homeControllerStatus).contains { $0.contains("controller") && $0.contains("connected") })
                    controllerHeaderButtons[0].performClick(nil)
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8])
                    self.selectPage(0)
                    precondition(self.sidebarPages == [-1, 0, 8, 13, -1, 6, 1, 7, 10, 11] && !self.sidebarPages.contains(2))
                    precondition(self.sidebarTitles[0] == "Couch Cube" && self.sidebarTitles[1] == "Play" && self.sidebarSymbols[1] == "play.rectangle.fill")
                    precondition(self.sidebarTitles[self.sidebarPages.firstIndex(of: 1)!] == "App Store")
                    for page in [0, 8, 13, 6, 1, 7, 10, 11] {
                        let sidebarRow = self.sidebarPages.firstIndex(of: page)!
                        let cell = self.tableView(self.sidebar, viewFor: self.sidebar.tableColumns[0], row: sidebarRow)!
                        func colorTiles(in view: NSView) -> [NSBox] {
                            view.subviews.flatMap { child in
                                if let box = child as? NSBox, box.boxType == .custom { return [box] }
                                return colorTiles(in: child)
                            }
                        }
                        precondition(colorTiles(in: cell).isEmpty, "Sidebar symbols must not have colored tiles")
                        precondition((cell as? NSTableCellView)?.imageView?.contentTintColor == .secondaryLabelColor)
                    }
                    precondition(!self.sidebarPages.contains(5), "Steam guide is part of Game library, not a sidebar destination")
                    precondition(!self.homeControllerStatus.arrangedSubviews.isEmpty)
                    let homeReport = self.report
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.renderGeneral()
                    precondition(!labels(in: self.tabs.tabViewItems[0].view!).contains("Needs attention"),
                                 "Home must not show an attention section")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                        missing: Array(self.computerGameApps.union(self.emulatorApps).union(["es-de"])))
                    self.guidedSetup = false
                    self.renderGeneral()
                    precondition(self.sidebarAttention[1] == .systemRed, "Missing apps must mark Apps in red")
                    self.guidedSetup = true
                    self.report = homeReport
                    self.renderGeneral()
                    let countReport = self.report
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                                             missing: Array(self.computerGameApps.union(self.emulatorApps)))
                    precondition(self.overviewAppSummary == "0 PC game apps · 0 emulators installed")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                                             missing: Array(self.computerGameApps.union(self.emulatorApps).subtracting(["steam", "dolphin"])))
                    precondition(self.overviewAppSummary == "1 PC game app · 1 emulator installed")
                    self.report = countReport
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    self.selectPage(2)
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[6], "Library storage opens the merged Game library")
                    self.goBack()
                    precondition(self.screenTitle.stringValue == "Play")
                    self.goForward()
                    precondition(self.screenTitle.stringValue == "Game library")
                    self.showTVMenus()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[10])
                    precondition(self.screenTitle.stringValue == "Console Mode")
                    self.renderTVMenus()
                    precondition(self.defaultMenuPicker.numberOfItems >= 2)
                    for item in self.defaultMenuPicker.itemArray {
                        if let id = item.representedObject as? String {
                            precondition(item.isEnabled == (self.appStates.first { $0.id == id }?.installed == true))
                        }
                    }
                    precondition(self.defaultMenuPicker.isDescendant(of: self.tabs.tabViewItems[10].view!))
                    precondition(self.updateButton.isDescendant(of: self.tabs.tabViewItems[11].view!))
                    self.selectPage(11)
                    precondition(self.screenTitle.stringValue == "App Settings")
                    self.report = nil
                    self.continueStorage()
                    precondition(self.task == nil, "No storage assessment must never start setup")
                    self.report = Assessment(state: "needs attention", issues: ["Fixture: unsupported storage"], notes: [], missing: [])
                    self.continueStorage()
                    precondition(self.task == nil, "Storage issues must never start setup")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: ["steam", "es-de"])
                    self.updateSetupSummary()
                    precondition(!self.playAction.isEnabled)
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: ["steam"])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled && self.homeMenuLabel.stringValue == "ES-DE")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled)
                    self.preferredFrontend = "es-de"
                    self.updateSetupSummary()
                    precondition(self.homeMenuLabel.stringValue == "ES-DE")
                    precondition(self.homePlayBackground.layer?.contentsGravity == .resizeAspect,
                                 "The complete EmulationStation logo must remain visible")
                    let esArtwork = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("TVMenus/es-de.png"))!
                    precondition(esArtwork.size == NSSize(width: 1676, height: 784))
                    self.preferredFrontend = nil
                    self.showFinishing()
                    precondition(!self.steamStorageAdvice.stringValue.isEmpty)
                    self.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
                    precondition(self.task == nil, "Focusing the app must not trigger storage checks")
                    self.report = assessment
                    self.updateSetupSummary()
                    self.selectPage(3)
                }
                self.window.contentView!.layoutSubtreeIfNeeded()
                self.window.displayIfNeeded()
                self.assertSmokePageScrolls()
                let fits = stack.fittingSize.height <= self.detail.bounds.height - 36
                let ok = discoveryOK && fits
                precondition(self.storageNext.isBordered && !self.playAction.isBordered)
                precondition(self.homePlayBackground.layer?.contents != nil)
                precondition(self.window.titleVisibility == .hidden && self.window.toolbar?.delegate === self)
                precondition(self.window.styleMask.contains(.fullSizeContentView))
                precondition(self.window.toolbar!.items.contains { $0 === self.backToolbarItem })
                precondition(self.window.toolbar!.items.contains { $0 === self.forwardToolbarItem })
                precondition(self.backToolbarItem.isNavigational && self.forwardToolbarItem.isNavigational)
                precondition(!self.screenTitle.isDescendant(of: self.mainDetail),
                             "Navigation belongs in the system toolbar, not a simulated content header")
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let control = self.window.standardWindowButton(kind)!
                    precondition(!control.isHidden)
                    let frame = self.sidebarPanel.convert(control.bounds, from: control)
                    precondition(self.sidebarPanel.bounds.contains(frame),
                                 "Native window controls must fit inside the inset sidebar: \(frame)")
                }
                precondition(self.sidebarPanel.alphaValue == 1)
                precondition(self.window.contentViewController === self.splitController)
                precondition(self.splitController.splitViewItems.first?.behavior == .sidebar)
                precondition(!self.sidebarPanel.subviews.contains { $0 is NSVisualEffectView },
                             "Legacy materials must not obscure the native sidebar glass")
                let layoutGuide = self.window.contentLayoutGuide as! NSLayoutGuide
                let navigationFrame = self.navigationBar.convert(self.navigationBar.bounds, to: self.window.contentView!)
                precondition(abs(navigationFrame.maxY - layoutGuide.frame.maxY) <= 1,
                             "Sidebar must begin directly below the native toolbar")
                precondition(abs(self.detail.frame.maxY - self.mainDetail.safeAreaLayoutGuide.frame.maxY) <= 1,
                             "Detail content must not have extra top padding")
                if args.contains("--smoke-activity") {
                    self.append("Activity appearance check: storage checked. No files changed.\n")
                    self.showActivity()
                    self.logWindow!.appearance = self.window.effectiveAppearance
                    self.append(String(repeating: "Live install output remains readable and scrollable.\n", count: 200))
                    let storage = self.log.textStorage!
                    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
                        precondition((attributes[.foregroundColor] as? NSColor) == NSColor.textColor)
                        precondition((attributes[.font] as? NSFont) == self.log.font)
                    }
                    self.logWindow!.contentView!.layoutSubtreeIfNeeded()
                    self.log.layoutManager!.ensureLayout(for: self.log.textContainer!)
                    precondition(self.log.bounds.height > self.log.enclosingScrollView!.contentSize.height, "Long Activity output must scroll")
                    self.logWindow!.displayIfNeeded()
                }
                if let index = args.firstIndex(of: "--capture"), args.indices.contains(index + 1) {
                    let captureWindow = args.contains("--smoke-activity") ? self.logWindow! : self.window!
                    let view = captureWindow.contentView!
                    captureWindow.effectiveAppearance.performAsCurrentDrawingAppearance {
                        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                              let context = NSGraphicsContext(bitmapImageRep: image) else {
                            fputs("Cannot create UI capture context.\n", stderr)
                            exit(1)
                        }
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        NSColor.windowBackgroundColor.setFill()
                        view.bounds.fill()
                        view.displayIgnoringOpacity(view.bounds, in: context)
                        NSGraphicsContext.restoreGraphicsState()
                        guard let png = image.representation(using: .png, properties: [:]) else { exit(1) }
                        do { try png.write(to: URL(fileURLWithPath: args[index + 1])) }
                        catch { fputs("Cannot capture UI: \(error)\n", stderr); exit(1) }
                    }
                }
                let failure: String = "Portable manager smoke test failed: " + self.status.stringValue
                let passed: String = "Native UI smoke test passed: settings navigation, apps, consoles and controller preview; no setup or pairing executed."
                print(ok ? passed : failure)
                let code: Int32 = ok ? 0 : 1
                exit(code)
        }
    }

    /// Rapid toggles: instant UI, no rebuild, one debounced save of the latest intent, serialized saves, stale refreshes ignored, failures reverted.
    /// Launch preload and every-tab-open refreshes: silent, keep rendered rows, newest result wins.
    func smokeTestSilentRefresh() {
        let saved = (backendRead, consoleRoot, report, consoleSystems, consolesLoaded, consolesChecking,
                     appStates, appsHaveResults, lastAppsData, overviewChecks, appsPreloadPending)
        defer {
            (backendRead, consoleRoot, report) = (saved.0, saved.1, saved.2)
            consoleSystems = saved.3
            consolesLoaded = saved.4
            consolesChecking = saved.5
            appStates = saved.6
            appsHaveResults = saved.7
            lastAppsData = saved.8
            overviewChecks = saved.9
            appsPreloadPending = saved.10
            consoleSaveDirty = false
            consoleStatus.stringValue = ""
            renderSystems()
            renderApps()
            renderGeneral()
        }
        precondition(task == nil)
        var reads: [(args: [String], done: (Int32, Data) -> Void)] = []
        backendRead = { args, done in
            if args == ["frontend"] {
                done(0, try! JSONSerialization.data(withJSONObject: ["preferred": self.preferredFrontend as Any]))
            } else { reads.append((args, done)) }
        }
        func systemsJSON(_ enabled: Set<String>) -> Data {
            try! JSONSerialization.data(withJSONObject: consoleSystems.map { system -> [String: Any] in
                var item: [String: Any] = ["id": system.id, "name": system.name, "enabled": enabled.contains(system.id),
                                           "package": system.package, "requirement": system.requirement]
                if let installed = system.emulator_installed { item["emulator_installed"] = installed }
                return item
            })
        }
        func appsJSON(_ installed: Set<String>) -> Data {
            try! JSONSerialization.data(withJSONObject: appStates.map { app -> [String: Any] in
                ["id": app.id, "name": app.name, "installed": installed.contains(app.id), "path": app.path, "version": app.version,
                 "managed": app.managed, "manual": app.manual, "brew": app.brew]
            })
        }
        // Retro consoles: refresh keeps rows, ignores stale and wrong-library results, keeps unsaved toggle intent.
        consoleRoot = { "/smoke" }
        report = Assessment(state: "valid layout", issues: [], notes: [], missing: [], preferred_frontend: preferredFrontend)
        consolesLoaded = true
        renderSystems()
        let rows = consoleRows.arrangedSubviews.map(ObjectIdentifier.init)
        let ids = consoleSystems.map(\.id)
        loadSystems()
        precondition(reads.count == 1 && consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rows,
                     "Opening Retro consoles refreshes in the background without a loading rebuild")
        loadSystems()
        precondition(reads.count == 2)
        reads[1].done(0, systemsJSON([ids[0]]))
        reads[0].done(0, systemsJSON([ids[1]]))
        precondition(Set(consoleSystems.filter(\.enabled).map(\.id)) == [ids[0]], "An older read must not overwrite a newer one")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rows && systemSwitches[ids.firstIndex(of: ids[0])!].state == .on,
                     "Refresh results update switches in place")
        loadSystems()
        consoleRoot = { "/other" }
        reads[2].done(0, systemsJSON([ids[2]]))
        precondition(Set(consoleSystems.filter(\.enabled).map(\.id)) == [ids[0]], "Results for another library are ignored")
        consoleRoot = { "/smoke" }
        consoleSystems[1].enabled = true
        consoleSaveDirty = true
        loadSystems()
        reads[3].done(0, systemsJSON([ids[0]]))
        precondition(consoleSystems[1].enabled && consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rows,
                     "A refresh during a pending save keeps the user's latest toggle")
        consoleSaveDirty = false
        // App Store: launch preload and silent tab refresh.
        reads = []
        appsHaveResults = true
        lastAppsData = appsJSON([])
        appStates = try! JSONDecoder().decode([ManagedApp].self, from: lastAppsData!)
        renderApps()
        let appRows = appPCRows.arrangedSubviews.map(ObjectIdentifier.init)
        overviewChecks = [.apps]
        appsPreloadPending = true
        let finishing = smokeFinishing
        smokeFinishing = false
        runPendingAppsPreload()
        smokeFinishing = finishing
        precondition(reads.count == 1 && reads[0].args == ["apps", "--updates"] && !appsPreloadPending && !appsChecking,
                     "Launch preload reads App Store data in the background")
        precondition(appPCRows.arrangedSubviews.map(ObjectIdentifier.init) == appRows, "Preload keeps rendered rows")
        reads[0].done(0, lastAppsData!)
        precondition(!overviewChecks.contains(.apps) && appPCRows.arrangedSubviews.map(ObjectIdentifier.init) == appRows,
                     "Unchanged results finish the check without rebuilding rows")
        fetchApps(updates: false)
        fetchApps(updates: false)
        precondition(reads.count == 3 && !appsChecking && appPCRows.arrangedSubviews.map(ObjectIdentifier.init) == appRows,
                     "Opening App Store again refreshes silently")
        reads[2].done(0, appsJSON(["steamac"]))
        reads[1].done(0, appsJSON([]))
        precondition(appStates.first { $0.id == "steamac" }?.installed == true, "An older App Store read must not overwrite a newer one")
    }

    func smokeTestConsoleBulkToggles() {
        let saved = (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay, consoleSystems, consolesLoaded, consolesChecking,
                     pendingEmulatorInstall, pendingAppStoreID)
        defer {
            (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay) = (saved.0, saved.1, saved.2, saved.3)
            consoleSaveTimer?.invalidate()
            consoleSaveTimer = nil
            consolePersistedEnabled = nil
            consoleSaveDirty = false
            consoleStatus.stringValue = ""
            consoleSystems = saved.4
            consolesLoaded = saved.5
            consolesChecking = saved.6
            (pendingEmulatorInstall, pendingAppStoreID) = (saved.7, saved.8)
            renderSystems()
        }
        var saves: [(enabled: Set<String>, done: (Int32, String) -> Void)] = []
        consoleSaver = { _, enabled, done in saves.append((Set(enabled), done)) }
        consoleRefresher = { _, _ in }
        consoleRoot = { "/smoke" }
        consoleSaveDelay = 60
        consolesLoaded = true
        consolesChecking = false
        consolePersistedEnabled = nil
        // Start mixed: every Nintendo home console on, everything else off. Uninstalled emulators are included on purpose.
        let home = Set(ConsoleArtwork.groups[0].systems), handheld = Set(ConsoleArtwork.groups[1].systems)
        for index in consoleSystems.indices { consoleSystems[index].enabled = home.contains(consoleSystems[index].id) }
        renderSystems()
        let rowsBefore = consoleRows.arrangedSubviews.map(ObjectIdentifier.init)
        let switchesBefore = systemSwitches.map(ObjectIdentifier.init)
        func bulk(_ scope: String) -> (toggle: NSSwitch, count: NSTextField, ids: Set<String>, scope: String) {
            consoleBulkToggles.first { $0.scope == scope }!
        }
        func press(_ scope: String) {
            let toggle = bulk(scope).toggle
            toggle.state = toggle.state == .on ? .off : .on
            toggleConsoleGroup(toggle)
        }
        func current() -> Set<String> { Set(consoleSystems.filter(\.enabled).map(\.id)) }
        func switchesMatch() -> Bool { zip(consoleSystems, systemSwitches).allSatisfy { ($0.enabled ? NSControl.StateValue.on : .off) == $1.state } }
        let all = Set(consoleSystems.map(\.id))
        let nintendo = home.union(handheld).intersection(all)
        precondition(bulk("Nintendo home consoles").toggle.state == .on && bulk("Nintendo home consoles").count.isHidden)
        precondition(bulk("Nintendo handhelds").toggle.state == .off && bulk("Nintendo handhelds").count.isHidden)
        precondition(bulk("Nintendo consoles").toggle.state == .off && !bulk("Nintendo consoles").count.isHidden &&
                     bulk("Nintendo consoles").count.stringValue == "\(home.count) of \(nintendo.count)", "Mixed groups show a count")
        precondition(bulk("all consoles").toggle.accessibilityLabel() == "Show all all consoles, \(home.count) of \(all.count) shown" ||
                     bulk("all consoles").toggle.accessibilityLabel()?.contains("\(home.count) of \(all.count) shown") == true)
        // Subsection level; parents recompute instantly.
        press("Nintendo handhelds")
        precondition(current() == nintendo && switchesMatch() && bulk("Nintendo consoles").toggle.state == .on &&
                     bulk("Nintendo consoles").count.isHidden && bulk("all consoles").toggle.state == .off)
        precondition(pendingEmulatorInstall == nil && pendingAppStoreID == nil, "Showing consoles never installs anything")
        // Clicking a mixed toggle shows all.
        precondition(!bulk("all consoles").count.isHidden)
        press("all consoles")
        precondition(current() == all && switchesMatch() && consoleBulkToggles.allSatisfy { $0.toggle.state == .on && $0.count.isHidden })
        // Section level hides only its own systems.
        press("PlayStation consoles")
        let playStation = bulk("PlayStation consoles").ids
        precondition(current() == all.subtracting(playStation) && bulk("all consoles").toggle.state == .off)
        // An individual switch updates every parent at once.
        let gb = consoleSystems.firstIndex { $0.id == "gb" }!
        systemSwitches[gb].state = .off
        toggleSystem(systemSwitches[gb])
        precondition(bulk("Nintendo handhelds").count.stringValue == "\(handheld.count - 1) of \(handheld.count)" &&
                     bulk("Nintendo consoles").toggle.state == .off)
        press("Nintendo handhelds")
        let expected = all.subtracting(playStation)
        precondition(current() == expected && saves.isEmpty, "Bulk and single toggles wait for a pause")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore &&
                     systemSwitches.map(ObjectIdentifier.init) == switchesBefore, "Bulk toggles must not rebuild the list")
        saveSystems()
        precondition(saves.count == 1 && saves[0].enabled == expected, "One save for the whole batch")
        saves[0].done(0, "")
        precondition(consolePersistedEnabled == expected)
        // Hide everything, then fail: the last saved choices and the group states come back.
        press("all consoles")
        precondition(current() == all, "All on except PlayStation was mixed; the click shows all")
        press("all consoles")
        precondition(current().isEmpty && consoleBulkToggles.allSatisfy { $0.toggle.state == .off && $0.count.isHidden })
        saveSystems()
        precondition(saves.count == 2 && saves[1].enabled.isEmpty)
        saves[1].done(1, "Disk is read-only\n")
        precondition(current() == expected && switchesMatch() && bulk("PlayStation consoles").toggle.state == .off &&
                     bulk("all consoles").toggle.state == .off && !bulk("all consoles").count.isHidden,
                     "A failed bulk save reverts the switches and the group states")
        precondition(consoleStatus.stringValue.hasPrefix("Couldn't save console selection"))
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore)
        // Not loaded yet: bulk switches are disabled and refuse.
        consolesLoaded = false
        updateConsoleBulkToggles()
        precondition(consoleBulkToggles.allSatisfy { !$0.toggle.isEnabled })
    }

    func smokeTestRapidConsoleToggles() {
        let saved = (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay, consoleSystems, consolesLoaded, consolesChecking)
        defer {
            (consoleSaver, consoleRefresher, consoleRoot, consoleSaveDelay) = (saved.0, saved.1, saved.2, saved.3)
            consoleSaveTimer?.invalidate()
            consoleSaveTimer = nil
            consolePersistedEnabled = nil
            consoleSaveDirty = false
            consoleStatus.stringValue = ""
            consoleSystems = saved.4
            consolesLoaded = saved.5
            consolesChecking = saved.6
            renderSystems()
        }
        var saves: [(enabled: Set<String>, done: (Int32, String) -> Void)] = []
        var refreshes: [(Int32, Data) -> Void] = []
        var disk: Set<String> = []
        consoleSaver = { _, enabled, done in saves.append((Set(enabled), done)) }
        consoleRefresher = { _, done in refreshes.append(done) }
        consoleRoot = { "/smoke" }
        consoleSaveDelay = 60
        consolesLoaded = true
        consolesChecking = false
        consolePersistedEnabled = nil
        // Fixture readiness: release runners have no emulators installed; the deferred restore puts real state back.
        for index in consoleSystems.indices { consoleSystems[index].emulator_installed = true }
        renderSystems()
        window.contentView!.layoutSubtreeIfNeeded()
        let scroll = tabs.selectedTabViewItem!.view as! NSScrollView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(120, max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height))))
        let offset = scroll.contentView.bounds.origin
        disk = Set(consoleSystems.filter(\.enabled).map(\.id))
        let rowsBefore = consoleRows.arrangedSubviews.map(ObjectIdentifier.init)
        let switchesBefore = systemSwitches.map(ObjectIdentifier.init)
        let ready = consoleSystems.indices.filter { index in
            let system = consoleSystems[index]
            return (system.emulator_installed ?? appStates.first { $0.id == system.package }?.installed) != false
        }
        precondition(ready.count >= 3, "Smoke data needs three ready consoles")
        let (a, b, c) = (ready[0], ready[1], ready[2])
        func flip(_ index: Int) {
            let toggle = systemSwitches[index]
            toggle.state = toggle.state == .on ? .off : .on
            toggleSystem(toggle)
        }
        func current() -> Set<String> { Set(consoleSystems.filter(\.enabled).map(\.id)) }
        func switchesMatch() -> Bool { zip(consoleSystems, systemSwitches).allSatisfy { ($0.enabled ? NSControl.StateValue.on : .off) == $1.state } }
        func toggled(_ set: Set<String>, _ index: Int) -> Set<String> {
            let id = consoleSystems[index].id
            return set.contains(id) ? set.subtracting([id]) : set.union([id])
        }
        let ids = (consoleSystems[a].id, consoleSystems[b].id, consoleSystems[c].id)
        let indexOf = { (id: String) in self.consoleSystems.firstIndex { $0.id == id }! }
        flip(a); flip(b); flip(a)
        let first = toggled(disk, indexOf(ids.1))
        precondition(saves.isEmpty && current() == first && switchesMatch(), "Toggles apply instantly; saving waits for a pause")
        precondition(systemSwitches.allSatisfy(\.isEnabled) && task == nil, "Toggling never blocks other switches")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore &&
                     systemSwitches.map(ObjectIdentifier.init) == switchesBefore, "Toggles must not rebuild the list")
        saveSystems()
        precondition(saves.count == 1 && saves[0].enabled == first, "One coalesced save with the latest choices")
        flip(indexOf(ids.2))
        let second = toggled(first, indexOf(ids.2))
        precondition(systemSwitches.allSatisfy(\.isEnabled), "Switches stay usable while saving")
        saveSystems()
        precondition(saves.count == 1, "Saves are serialized")
        disk = saves[0].enabled
        saves[0].done(0, "")
        precondition(saves.count == 2 && saves[1].enabled == second && refreshes.isEmpty,
                     "A change made during a save is saved next; no refresh while newer intent is pending")
        disk = saves[1].enabled
        saves[1].done(0, "")
        precondition(refreshes.count == 1 && consolePersistedEnabled == second)
        flip(indexOf(ids.2))
        func json(_ enabled: Set<String>) -> Data {
            try! JSONSerialization.data(withJSONObject: consoleSystems.map {
                ["id": $0.id, "name": $0.name, "enabled": enabled.contains($0.id), "package": $0.package,
                 "requirement": $0.requirement, "emulator_installed": $0.emulator_installed ?? true] as [String: Any]
            })
        }
        refreshes[0](0, json(second))
        precondition(current() == first && switchesMatch(), "A late refresh must not undo a newer toggle")
        saveSystems()
        precondition(saves.count == 3 && saves[2].enabled == first)
        saves[2].done(1, "Disk is read-only\n")
        precondition(current() == disk && switchesMatch() && consoleStatus.stringValue.hasPrefix("Couldn't save console selection"),
                     "A failed save shows the last saved choices and an explicit error")
        precondition(consoleRows.arrangedSubviews.map(ObjectIdentifier.init) == rowsBefore, "Reverting must not rebuild the list")
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.origin == offset, "Toggling must keep the scroll position")
        // Restart: a fresh load shows exactly what was last saved.
        consoleSystems = try! JSONDecoder().decode([ConsoleSystem].self, from: json(disk))
        renderSystems()
        precondition(current() == second && switchesMatch(), "After restart the last saved selection is shown")
    }

    /// Release never pops the Activity log on its own; problems surface in the app instead.
    func smokeTestActivityStaysClosed() {
        precondition(!SetupController.activityAutoOpens || ProcessInfo.processInfo.environment["COUCH_CUBE_DEBUG_ACTIVITY"] == "1")
        guard !SetupController.activityAutoOpens else { return }
        let open = logWindow?.isVisible == true
        activityNeeded("Smoke problem")
        activityNeeded()
        precondition(lastProblemNotice == "Smoke problem")
        precondition((logWindow?.isVisible == true) == open, "Problems and operations must not open Activity")
        precondition(logWindow?.isRestorable != true, "Activity must not be restored at launch")
    }

    /// Windows launcher installers: download-only rows with real progress, never run and never claimed installed.
    func smokeTestStoreAccounts() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func row(_ id: String) -> NSView { storeAccountsRows.arrangedSubviews.first { $0.identifier?.rawValue == "store-row-" + id }! }
        func status(_ id: String) -> String {
            views(row(id)).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "storeAccountStatus" }!.stringValue
        }
        func button(_ root: NSView, _ title: String) -> NSButton { views(root).compactMap { $0 as? NSButton }.first { $0.title == title }! }
        let fixture = Data("""
        {"clients":[
         {"id":"mac-steam","name":"Steam","state":"signed_in","detail":"Signed in as Gamer (gamer1)","platform":"Mac","kind":"mac",
          "accounts":[{"account":"gamer1","persona":"Gamer","most_recent":true},{"account":"kid","persona":null,"most_recent":false}]},
         {"id":"win-steam","name":"Steam (Windows)","state":"not_signed_in","detail":"Installed \\u2014 not signed in yet","platform":"Windows",
          "kind":"wine","host":"CrossOver","bottle":"Games","accounts":[]},
         {"id":"win-epic","name":"Epic Games Launcher","state":"installed","detail":"Installed \\u2014 sign in inside the launcher",
          "platform":"Windows","kind":"wine","host":"Whisky","bottle":"B1","accounts":[]},
         {"id":"win-gog","name":"GOG Galaxy","state":"not_installed","detail":"Not installed","platform":"Windows","kind":"wine","accounts":[]}
        ],"installed":3,"signed_in":1}
        """.utf8)
        let savedRead = storeAccountsRead, savedOpen = storeClientOpen
        defer { storeAccountsRead = savedRead; storeClientOpen = savedOpen; storeWalkthrough = nil }
        // State machine: stale replies are ignored and a failed check keeps the last good report.
        var model = StoreAccountsModel()
        precondition(model.summary.hasPrefix("Checking"))
        let first = model.begin(), second = model.begin()
        let report = try! JSONDecoder().decode(StoreAccountsReport.self, from: fixture)
        precondition(!model.finish(first, report: report, at: Date()) && model.phase == .checking, "A stale check must not land")
        precondition(model.finish(second, report: report, at: Date()) && model.phase == .loaded && model.summary == "1 of 3 signed in")
        _ = model.begin()
        precondition(model.finish(model.generation, report: nil, at: Date()) && model.phase == .failed && model.report == report)
        // Reads happen only when asked; replies may arrive later.
        var reads = 0
        var pending: [(Int32, Data) -> Void] = []
        storeAccountsRead = { reads += 1; pending.append($0) }
        loadStoreAccounts()
        precondition(storeAccounts.phase == .checking && storeAccountsSummary.stringValue.hasPrefix("Checking"))
        pending.removeFirst()(0, fixture)
        precondition(reads == 1 && storeAccountsSummary.stringValue == "1 of 3 signed in")
        precondition(storeAccountsRows.arrangedSubviews.filter { $0.identifier?.rawValue.hasPrefix("store-row-") == true }.count == 4)
        precondition(status("mac-steam").contains("Signed in as Gamer (gamer1)") && status("mac-steam").contains("1 more account"))
        precondition(status("win-steam").contains("CrossOver bottle"))
        precondition(status("win-epic").hasPrefix("Installed \u{2014} sign in inside the launcher"))
        precondition(status("win-gog") == "Not installed" && button(row("win-gog"), "App Store").isEnabled)
        // Open waits for the client to quit, guards duplicates, then checks again once.
        var opens: [String] = []
        var finishOpen: ((Int32) -> Void)?
        storeClientOpen = { id, done in opens.append(id); finishOpen = done }
        button(row("win-epic"), "Open").performClick(nil)
        precondition(opens == ["win-epic"] && status("win-epic").hasPrefix("Waiting for Epic Games Launcher to quit"))
        precondition(!button(row("win-epic"), "Open").isEnabled)
        openStoreClient(button(row("win-epic"), "Open"))
        precondition(opens == ["win-epic"], "A client that's already open isn't launched twice")
        finishOpen!(0)
        precondition(reads == 2 && storeAccounts.phase == .checking)
        pending.removeFirst()(0, fixture)
        precondition(storeAccounts.phase == .loaded && storeAccountsError == nil)
        storeClientOpen = { _, done in done(1) }
        button(row("mac-steam"), "Open").performClick(nil)
        pending.removeFirst()(1, Data())
        precondition(storeAccountsError?.hasPrefix("Couldn't open Steam") == true && storeAccounts.report == report,
                     "A failed launch or check keeps the last known status and explains it inline")
        storeAccountsError = nil
        // Guided walkthrough: installed clients only, one at a time, skippable, with a summary.
        storeClientOpen = { id, done in opens.append(id); done(0) }
        startStoreWalkthrough()
        func step() -> String {
            views(storeWalkthroughPanel).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "storeWalkthroughStep" }!.stringValue
        }
        precondition(storeWalkthrough?.ids == ["mac-steam", "win-steam", "win-epic"] && step().hasPrefix("Step 1 of 3: Steam"))
        button(storeWalkthroughPanel, "Next").performClick(nil)
        precondition(step().hasPrefix("Step 2 of 3: Steam (Windows)"))
        button(storeWalkthroughPanel, "Open Steam (Windows)").performClick(nil)
        precondition(opens.last == "win-steam")
        pending.removeFirst()(0, fixture)
        precondition(step().hasPrefix("Step 2 of 3"), "Returning from a client keeps the walkthrough on its step")
        button(storeWalkthroughPanel, "Skip").performClick(nil)
        button(storeWalkthroughPanel, "Next").performClick(nil)
        precondition(step() == "Done \u{2014} 1 of 3 signed in. Skipped: Steam (Windows).")
        button(storeWalkthroughPanel, "Done").performClick(nil)
        precondition(storeWalkthroughPanel.isHidden && pending.isEmpty)
    }

    func smokeTestWindowsDownloads() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func row(_ id: String) -> NSView? { appWindowsRows.arrangedSubviews.first { $0.identifier?.rawValue == "win-row-" + id } }
        func statusText(_ id: String) -> String {
            let status = views(row(id)!).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { ($0 as? NSTextField)?.stringValue }.joined()
        }
        func dot(_ id: String) -> NSColor? {
            let status = views(row(id)!).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { $0 as? NSImageView }.first?.contentTintColor
        }
        func button(_ id: String, _ title: String) -> NSButton? {
            views(row(id)!).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func spinner(_ id: String) -> NSProgressIndicator? { views(row(id)!).compactMap { $0 as? NSProgressIndicator }.first }
        precondition(windowsDownloadProgress("PROGRESS 5 10")! == (5, 10) && windowsDownloadProgress("PROGRESS -1 10") == nil &&
                     windowsDownloadProgress("RESULT {}") == nil)
        precondition(backendErrorMessage("x\nERROR: Drive gone\n", fallback: "f") == "Drive gone")
        let saved = (windowsDownloads, windowsDownloadJobs, windowsLibrary, windowsDownloadsRead, windowsDownloadRun,
                     collapsedAppCategories, appOperations)
        defer {
            (windowsDownloads, windowsDownloadJobs, windowsLibrary, windowsDownloadsRead, windowsDownloadRun,
             collapsedAppCategories, appOperations) = saved
            renderApps()
            renderGeneral()
        }
        let ids = ["win-steam", "win-epic-games", "win-gog-galaxy", "win-ea", "win-battle-net"]
        var library: String? = nil
        var downloaded: [String: String] = [:]
        func reply() -> Data {
            let items = ids.map { id -> String in
                let file = downloaded[id].map { "\"\($0)\"" } ?? "null"
                return "{\"id\":\"\(id)\",\"name\":\"\(id) (Windows)\",\"vendor\":\"Vendor\",\"kind\":\"\(id == "win-epic-games" ? "msi" : "exe")\"," +
                    "\"downloaded\":\(downloaded[id] != nil),\"file\":\(file),\"size\":\(downloaded[id] != nil ? "2380800" : "null"),\"sha256\":null}"
            }
            return Data(("{\"library\":" + (library.map { "\"\($0)\"" } ?? "null") + ",\"folder\":null,\"items\":[" +
                         items.joined(separator: ",") + "]}").utf8)
        }
        var heldRead: ((Int32, Data) -> Void)?
        var holdRead = false
        windowsDownloadsRead = { done in if holdRead { heldRead = done } else { done(0, reply()) } }
        var runs: [String] = [], lineOut: ((String) -> Void)?, finish: ((Int32, String) -> Void)?, canceled: [String] = []
        windowsDownloadRun = { id, line, done in
            runs.append(id); lineOut = line; finish = done
            return { canceled.append(id) }
        }
        collapsedAppCategories = []
        appOperations = [:]
        loadWindowsDownloads()
        precondition(ids.allSatisfy { row($0) != nil }, "Windows launchers are listed under Windows games")
        precondition(button("win-steam", "Get")?.isEnabled == false, "Without a game library there is nowhere to download")
        library = "/Volumes/Smoke/Couch Cube"
        loadWindowsDownloads()
        precondition(button("win-steam", "Get")?.isEnabled == true && statusText("win-steam") == "Not downloaded")

        // Get starts the download at once; real byte progress drives a determinate indicator.
        getWindowsDownload(button("win-steam", "Get")!)
        precondition(runs == ["win-steam"] && spinner("win-steam")?.isIndeterminate == true && statusText("win-steam") == "Downloading\u{2026}")
        lineOut!("PROGRESS 50 100")
        precondition(spinner("win-steam")?.isIndeterminate == false && spinner("win-steam")?.doubleValue == 0.5)
        precondition(statusText("win-steam") == "Downloading \u{00B7} 50%")
        precondition(appOperations["steam"] == nil, "The Mac Steam app has its own, separate state")
        if let macSteam = appPCRows.arrangedSubviews.first(where: { $0.identifier?.rawValue == "app-row-steam" }) {
            precondition(!views(macSteam).contains { $0 is NSProgressIndicator })
        }
        renderGeneral()
        precondition(!sidebarTasks.contains { $0.title.contains("Windows") || $0.title.contains("win-") },
                     "Undownloaded Windows launchers aren't maintenance tasks")
        downloaded["win-steam"] = "/Volumes/Smoke/Couch Cube/Downloads/SteamSetup.exe"
        finish!(0, "")
        precondition(windowsDownloadJobs["win-steam"] == nil && statusText("win-steam") == "Downloaded" && dot("win-steam") == .systemGreen)
        precondition(button("win-steam", "Show in Finder") != nil && spinner("win-steam") == nil)
        precondition(views(row("win-steam")!).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("Not run or installed") },
                     "Downloaded never claims installed")

        // A failed run shows the backend's reason with Retry; nothing is green.
        getWindowsDownload(button("win-ea", "Get")!)
        finish!(1, "ERROR: The connection dropped during the download. Nothing was saved.\n")
        precondition(statusText("win-ea") == "Couldn't download" && dot("win-ea") == .systemRed && button("win-ea", "Retry") != nil)
        precondition(views(row("win-ea")!).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.hasPrefix("The connection dropped") })
        // Success that the status check can't confirm is a failure, not green.
        getWindowsDownload(button("win-gog-galaxy", "Get")!)
        finish!(0, "")
        precondition(statusText("win-gog-galaxy") == "Couldn't download" && dot("win-gog-galaxy") != .systemGreen)
        // Cancel stops the backend and returns to Get.
        getWindowsDownload(button("win-battle-net", "Get")!)
        let cancel = views(row("win-battle-net")!).compactMap { $0 as? NSButton }.first { $0.action == #selector(cancelWindowsDownload(_:)) }!
        cancelWindowsDownload(cancel)
        precondition(canceled == ["win-battle-net"])
        finish!(15, "")
        precondition(windowsDownloadJobs["win-battle-net"] == nil && statusText("win-battle-net") == "Not downloaded" &&
                     button("win-battle-net", "Get") != nil)
        // A second press while running doesn't start a duplicate.
        getWindowsDownload(button("win-epic-games", "Get")!)
        let started = runs.count
        windowsDownloadJobs["win-epic-games"].map { _ in getWindowsDownload({ let b = NSButton(); b.tag = 1; return b }()) }
        precondition(runs.count == started)
        // Library changes cancel running downloads before touching storage.
        canceled = []
        for (id, job) in windowsDownloadJobs where job.running { cancelWindowsDownload(id: id) }
        precondition(canceled == ["win-epic-games"])
        finish!(15, "")
        // An older status read can't revert a newer result.
        holdRead = true
        loadWindowsDownloads()
        let stale = heldRead!
        holdRead = false
        loadWindowsDownloads()
        downloaded["win-steam"] = nil
        stale(0, reply())
        precondition(statusText("win-steam") == "Downloaded")
        // Collapsed category keeps downloaded and failed rows, hides untouched ones.
        collapsedAppCategories = ["Windows games"]
        renderApps()
        precondition(row("win-steam") != nil && row("win-ea") != nil && row("win-epic-games") == nil)
        precondition(logWindow?.isVisible != true, "Downloads must not open Activity")
    }

    /// App Store rows: spinner while working, real phases, and green only after a targeted re-check confirms it.
    func smokeTestAppOperations() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func appRow() -> NSView? { views(appPCRows.superview ?? appPCRows).first { $0.identifier?.rawValue == "app-row-dolphin" }
            ?? views(appRetroRows).first { $0.identifier?.rawValue == "app-row-dolphin" } }
        func statusDot(_ row: NSView) -> NSColor? {
            let status = views(row).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { $0 as? NSImageView }.first?.contentTintColor
        }
        func statusText(_ row: NSView) -> String {
            let status = views(row).first { $0.identifier?.rawValue == "app-status" }!
            return views(status).compactMap { ($0 as? NSTextField)?.stringValue }.joined()
        }
        func progress(_ row: NSView) -> NSProgressIndicator? { views(row).compactMap { $0 as? NSProgressIndicator }.first }
        func reply(_ app: ManagedApp) -> Data {
            Data(("[{\"id\":\"\(app.id)\",\"name\":\"\(app.name)\",\"installed\":\(app.installed),\"path\":\"\(app.path)\"," +
                  "\"version\":\"\(app.version)\",\"brew\":true,\"managed\":\(app.managed),\"update\":" +
                  (app.update.map { "\"\($0)\"" } ?? "null") + ",\"manual\":false,\"url\":null}]").utf8)
        }
        precondition(task == nil)
        let saved = (appStates, appOperations, appOperationRun, appVerifyRead, backendRead, appsHaveResults, lastAppsData,
                     collapsedAppCategories, appsStatus.stringValue)
        defer {
            (appStates, appOperations, appOperationRun, appVerifyRead, backendRead, appsHaveResults, lastAppsData,
             collapsedAppCategories, appsStatus.stringValue) = saved
            appOperationOutput = nil
            renderApps()
            renderGeneral()
        }
        precondition(appOperationPhase("==> Downloading https://example\n==> Upgrading Cask dolphin", action: "update") == "Updating")
        precondition(appOperationPhase("==> Fetching downloads for: dolphin", action: "install") == "Downloading")
        precondition(appOperationPhase("Already installed\n", action: "install") == nil, "No phase is invented")
        let outdated = ManagedApp(id: "dolphin", name: "Dolphin", installed: true, path: "/Applications/Dolphin.app", version: "1",
                                  managed: true, update: "2", manual: false, brew: true, url: nil)
        let current = ManagedApp(id: "dolphin", name: "Dolphin", installed: true, path: "/Applications/Dolphin.app", version: "2",
                                 managed: true, update: nil, manual: false, brew: true, url: nil)
        appStates = appStates.filter { $0.id != "dolphin" } + [outdated]
        appsHaveResults = true
        renderApps()
        renderGeneral()
        precondition(sidebarTasks.contains { $0.title == "Update Dolphin" })
        window.contentView!.layoutSubtreeIfNeeded()
        let before = appRow()!.fittingSize.height
        precondition(statusDot(appRow()!) == .systemYellow && progress(appRow()!) == nil)

        // A full app check that started earlier must not revert the verified result.
        var staleFetch: ((Int32, Data) -> Void)?
        backendRead = { _, done in staleFetch = done }
        fetchApps(updates: false)
        var runDone: ((Int32) -> Void)?
        var ran: [[String]] = []
        appOperationRun = { arguments, done in ran.append(arguments); runDone = done }
        var verifyReply = reply(current)
        var verifyDone: ((Int32, Data) -> Void)?
        appVerifyRead = { arguments, done in
            precondition(arguments == ["apps", "--updates", "--package", "dolphin"], "Only the changed app is re-checked")
            verifyDone = done
        }
        runAppOperation(outdated, action: "update")
        precondition(ran == [["manage-app", "--package", "dolphin", "--action", "update", "--confirm"]])
        var line = appRow()!
        precondition(progress(line)?.isIndeterminate == true, "Homebrew gives no real percentage, so the spinner is indeterminate")
        precondition(!views(line).contains { ($0 as? NSPopUpButton) != nil }, "The spinner replaces the ... button")
        precondition(statusText(line).hasPrefix("Updating") && statusDot(line) == .systemBlue)
        appOperationOutput?("==> Downloading https://example.invalid/dolphin.dmg\n")
        line = appRow()!
        precondition(statusText(line) == "Updating · Downloading\u{2026}")
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(abs(line.fittingSize.height - before) < 1, "Row height stays stable while updating")
        runDone!(0)
        precondition(statusText(appRow()!).contains("Checking") && progress(appRow()!) != nil, "Green waits for verification")
        verifyDone!(0, verifyReply)
        line = appRow()!
        precondition(statusDot(line) == .systemGreen && statusText(line) == "Installed" && progress(line) == nil)
        precondition(appOperations["dolphin"] == nil && !sidebarTasks.contains { $0.title == "Update Dolphin" })
        precondition(updateAllButton.isHidden || appStates.contains { $0.id != "dolphin" && $0.update?.isEmpty == false })
        staleFetch?(0, Data(("[" + String(decoding: reply(outdated), as: UTF8.self).dropFirst().dropLast() + "]").utf8))
        precondition(statusDot(appRow()!) == .systemGreen, "A stale full refresh must not revert the verified state")

        // Homebrew succeeded but the re-check still sees the old version: not green, inline failure, retry stays available.
        appStates = appStates.filter { $0.id != "dolphin" } + [outdated]
        renderApps()
        verifyReply = reply(outdated)
        runAppOperation(outdated, action: "update")
        runDone!(0)
        verifyDone!(0, verifyReply)
        line = appRow()!
        precondition(statusDot(line) == .systemRed && statusText(line) == "Couldn't update" && progress(line) == nil)
        precondition(views(line).contains { $0 is NSPopUpButton }, "Update stays available to retry")
        // A failed Homebrew run is never shown as green, even if the re-check fails too.
        runAppOperation(outdated, action: "update")
        runDone!(1)
        verifyDone!(1, Data())
        line = appRow()!
        precondition(statusDot(line) != .systemGreen && statusText(line) == "Couldn't confirm the update")

        // Steam is one app listed twice (TV menus: Steam Big Picture, PC games: Steam): both rows share one state.
        func steamRows() -> [(NSStackView, NSView)] {
            [appMenuRows, appPCRows, appWindowsRows, appRetroRows].flatMap { rows in
                rows.arrangedSubviews.filter { $0.identifier?.rawValue == "app-row-steam" }.map { (rows, $0) } }
        }
        func steam(installed: Bool, update: String? = nil) -> ManagedApp {
            ManagedApp(id: "steam", name: "Steam", installed: installed, path: installed ? "/Applications/Steam.app" : "",
                       version: installed ? "1" : "", managed: true, update: update, manual: false, brew: true, url: nil)
        }
        appVerifyRead = { arguments, done in
            precondition(arguments == ["apps", "--updates", "--package", "steam"], "Steam is re-checked once for both rows")
            verifyDone = done
        }
        collapsedAppCategories = []
        appStates = appStates.filter { $0.id != "steam" } + [steam(installed: true, update: "2")]
        renderApps()
        renderGeneral()
        precondition(steamRows().map { $0.0 } == [appMenuRows, appPCRows], "Steam is listed under TV menus and PC games")
        precondition(sidebarTasks.filter { $0.title == "Update Steam" }.count == 1, "The App Store badge counts Steam once")
        precondition(Set(steamRows().map { statusText($0.1) }).count == 1)
        for (rows, line) in steamRows() {
            precondition(views(line).compactMap { $0 as? NSTextField }.contains { $0.stringValue == (rows === appMenuRows ? "Steam Big Picture" : "Steam") })
        }
        // Start from the PC games row; the TV menu row shows the same spinner and phase, and can't start a second run.
        ran = []
        runAppOperation(appStates.first { $0.id == "steam" }!, action: "update")
        appOperationOutput?("==> Downloading https://example.invalid/steam.dmg\n")
        precondition(steamRows().allSatisfy { progress($0.1) != nil && statusText($0.1) == "Updating \u{00B7} Downloading\u{2026}" })
        precondition(steamRows().allSatisfy { !views($0.1).contains { $0 is NSButton && ($0 as! NSButton).isEnabled } })
        runAppOperation(appStates.first { $0.id == "steam" }!, action: "update")
        precondition(ran.count == 1 && appsStatus.stringValue.hasPrefix("Wait"), "A second Steam row can't start a duplicate run")
        runDone!(0)
        verifyDone!(0, reply(steam(installed: true)))
        renderGeneral()
        precondition(steamRows().count == 2 && steamRows().allSatisfy { statusDot($0.1) == .systemGreen && statusText($0.1) == "Installed" })
        precondition(!sidebarTasks.contains { $0.title == "Update Steam" })
        // A failure shows on both rows, with Retry on both.
        appStates = appStates.filter { $0.id != "steam" } + [steam(installed: false)]
        renderApps()
        runAppOperation(steam(installed: false), action: "install")
        runDone!(1)
        verifyDone!(0, reply(steam(installed: false)))
        precondition(steamRows().count == 2 && steamRows().allSatisfy {
            statusDot($0.1) == .systemRed && views($0.1).contains { ($0 as? NSButton)?.title == "Retry" } })
        // Installing from the TV menu row while PC games is collapsed: the PC games row appears once Steam is installed.
        collapsedAppCategories = ["PC games"]
        appOperations["steam"] = nil
        renderApps()
        precondition(steamRows().map { $0.0 } == [appMenuRows])
        runAppOperation(steam(installed: false), action: "install")
        runDone!(0)
        verifyDone!(0, reply(steam(installed: true)))
        precondition(steamRows().map { $0.0 } == [appMenuRows, appPCRows] && steamRows().allSatisfy { statusDot($0.1) == .systemGreen })
        precondition(logWindow?.isVisible != true, "App updates must not open Activity")
    }

    func assertSmokeDeals() {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        let page = tabs.selectedTabViewItem!.view!
        precondition(dealsOpened, "Cube Shop must load only once its page opens")
        precondition(screenTitle.stringValue == "Cube Shop")
        let defaults = UserDefaults.standard
        let shopKeys = [shopTabKey, shopScopeKey, shopCurrencyKey, shopFeeKey]
        let savedShop = shopKeys.map { defaults.object(forKey: $0) }
        // Cube Shop always opens on Home, even after another tab was used; other tabs keep their state.
        precondition(shopTab.selectedSegment == 0 && !homePane.isHidden, "Cube Shop opens on Home")
        selectShopTab(4)
        selectPage(0)
        selectPage(13)
        precondition(shopTab.selectedSegment == 0 && !homePane.isHidden && wishlistPane.isHidden && shopNav.selectedSegment == 0,
                     "Reopening Cube Shop starts on Home again")
        selectShopTab(4)
        precondition(!wishlistPane.isHidden && shopNav.selectedSegment == 3)
        selectShopTab(0)
        defaults.set("original", forKey: shopCurrencyKey)
        defaults.removeObject(forKey: shopFeeKey)
        rerenderShop()
        // URL safety: only https links on the services' own hosts open.
        precondition(safeDealURL("https://www.cheapshark.com/redirect?dealID=a", hosts: cheapSharkHosts) != nil)
        precondition(safeDealURL("http://www.cheapshark.com/redirect?dealID=a", hosts: cheapSharkHosts) == nil)
        precondition(safeDealURL("https://www.cheapshark.com.evil.example/x", hosts: cheapSharkHosts) == nil)
        precondition(safeDealURL("https://user@www.gamerpower.com/x", hosts: gamerPowerHosts) == nil)
        precondition(safeDealURL("steam://run/620", hosts: cheapSharkHosts) == nil)
        precondition(safeDealURL("javascript:alert(1)") == nil)
        precondition(dealsErrorText("ERROR: rate-limited:90").contains("2 min"))
        let savedTab = shopTab.selectedSegment, savedOpener = dealsOpener
        var opened: [URL] = []
        dealsOpener = { opened.append($0) }
        defer {
            dealsOpener = savedOpener
            for (key, value) in zip(shopKeys, savedShop) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            updateCurrencyNotes()
            selectShopTab(savedTab)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        selectShopTab(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(storeDeals.count == 4 && dealsStorePopup.numberOfItems == 3, "Store deals and store filter must render")
        precondition(!dealsFilters.arrangedSubviews.contains(dealsSearch) && dealsSearch.superview == nil && dealsFilters.arrangedSubviews.contains(dealsStatus) && dealsFilters.arrangedSubviews.contains(dealsSortPopup) && dealsStorePopup.itemTitles.first == "Any Store", "Deals: status, store and Sort by on one line; no second search field")
        var text = labels(page)
        precondition(text.contains("Portal 2") && text.contains("$1.99") && text.contains("$9.99") && text.contains { $0.hasSuffix("\u{2212}80%") })
        precondition(labels(dealsList).filter { $0.contains("Installed") }.count == 1, "Only the Steam-appID-matched deal is marked Installed")
        precondition(!dealsMore.isHidden, "More pages must offer Load More")
        let opens = views(dealsList).compactMap { $0 as? ClickableRowView }
        precondition(opens.count == 4, "Every deal row is one clickable row")
        precondition(opens.allSatisfy { $0.accessibilityRole() == .link && ($0.accessibilityLabel() ?? "").hasPrefix("Open ") })
        precondition(views(dealsList).compactMap { $0 as? NSButton }.allSatisfy { ["wishlistHeart", "shopTarget"].contains($0.accessibilityIdentifier()) },
                     "Deal rows have no buttons except Set Target and the wishlist heart")
        precondition(views(dealsList).filter { $0.accessibilityIdentifier() == "shopTarget" }.count == 4
                     && views(dealsList).filter { $0.accessibilityIdentifier() == "shopStoreTag" }.count == 4,
                     "Every deal row has Set Target and its store under the price")
        opens.forEach { $0.activate() }
        precondition(opened.map(\.absoluteString) == ["abc", "lng", "mc"].map { "https://www.cheapshark.com/redirect?dealID=" + $0 },
                     "Off-host deal links must never open")
        let attribution = views(page).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "dealsAttribution" }!
        let links = NSMutableSet()
        attribution.attributedStringValue.enumerateAttribute(.link, in: NSRange(location: 0, length: attribution.attributedStringValue.length)) { value, _, _ in
            if let value { links.add("\(value)") }
        }
        precondition(links.contains("https://www.gamerpower.com") && links.contains("https://www.cheapshark.com") &&
                     links.contains("https://frankfurter.dev") && links.contains("https://performance-partners.apple.com/search-api"),
                     "Attribution must link every data source")
        // A stale reply from a mode the user already left is ignored.
        let generation = dealsGeneration
        selectShopTab(2)
        precondition(dealsGeneration > generation)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        text = labels(dealsList)
        precondition(giveaways.count == 1 && text.contains("Free Adventure") && text.contains("Free") && !text.contains("Portal 2"))
        precondition(dealsFilters.arrangedSubviews.contains(giveawayPlatformPopup) && dealsFilters.arrangedSubviews.contains(giveawayTypePopup))
        precondition(dealsMore.isHidden)
        opened = []
        views(dealsList).compactMap { $0 as? ClickableRowView }.forEach { $0.activate() }
        precondition(opened.map(\.host) == ["www.gamerpower.com"])
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(dealsList.frame.width > 300, "Deal rows must use the page width")
        smokeTestDealReminders(opened: { opened })
        smokeTestCubeShop(opened: { opened })
        // Badges wrap instead of clipping, even at the narrowest window.
        selectShopTab(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let savedFrame = window.frame
        window.setContentSize(window.contentMinSize)
        window.contentView!.layoutSubtreeIfNeeded()
        for row in views(dealsList).compactMap({ $0 as? ClickableRowView }) {
            for badge in views(row).compactMap({ $0 as? NSTextField }).filter({ $0.accessibilityIdentifier() == "dealBadges" }) {
                let frame = badge.convert(badge.bounds, to: row)
                precondition(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Deal badges must stay inside their row")
                precondition(badge.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: badge.bounds.width, height: .greatestFiniteMagnitude)).height <= badge.bounds.height + 1,
                             "Deal badges must wrap, not clip")
            }
        }
        window.setFrame(savedFrame, display: false)
    }

    func smokeTestCubeShop(opened: () -> [URL]) {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        func spin(_ seconds: Double = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func calls(_ command: String) -> [[String]] { smokeShopCalls.filter { $0.first == command } }
        func heart(_ key: String) -> NSButton? {
            views(shopPageView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistHeart" && $0.identifier?.rawValue == key }
        }
        let defaults = UserDefaults.standard
        let savedWishlist = smokeWishlist, savedStores = myStores, savedAsk = askTargetPrice
        defer {
            smokeWishlist = savedWishlist
            smokeWishlistOffline = false
            askTargetPrice = savedAsk
            myStores = savedStores
            defaults.set("original", forKey: shopCurrencyKey)
            defaults.removeObject(forKey: shopFeeKey)
            updateScopeHint()
            rerenderShop()
        }
        // Money: Decimal math through EUR, HUF has no minor units, the fee applies only to conversions, free stays Free.
        // A fresh (unset) preference means Original prices, regardless of the Mac's locale.
        let savedCurrency = defaults.object(forKey: shopCurrencyKey)
        defaults.removeObject(forKey: shopCurrencyKey)
        precondition(shopCurrency == nil && shopPrice(11.99, "USD").text == "$11.99" && !shopPrice(11.99, "USD").converted,
                     "Cube Shop defaults to original prices")
        defaults.set("bogus", forKey: shopCurrencyKey)
        precondition(shopCurrency == nil, "An unknown saved currency falls back to original prices")
        defaults.set("HUF", forKey: shopCurrencyKey)
        precondition(shopCurrency == "HUF", "An explicit currency is kept")
        if let savedCurrency { defaults.set(savedCurrency, forKey: shopCurrencyKey) } else { defaults.removeObject(forKey: shopCurrencyKey) }
        let rates = decodeDeals(ExchangeRates.self, Data(smokeRatesJSON.utf8))!
        let price = ShopMoney.decimal(11.99)
        precondition(ShopMoney.convert(price, from: "USD", to: "HUF", rates: rates) == 3869)
        precondition(ShopMoney.convert(price, from: "USD", to: "HUF", rates: rates, feePercent: 1) == 3907)
        precondition(ShopMoney.convert(price, from: "USD", to: "EUR", rates: rates) == ShopMoney.decimal(10.65))
        precondition(ShopMoney.convert(price, from: "USD", to: "USD", rates: rates, feePercent: 1) == price)
        precondition(ShopMoney.convert(price, from: "USD", to: "XXX", rates: rates) == nil &&
                     ShopMoney.convert(price, from: "USD", to: "HUF", rates: rates, feePercent: 25) == nil)
        precondition(ShopMoney.plain(price, "USD") == "11.99 USD" && ShopMoney.plain(3869, "HUF") == "3869 HUF")
        precondition(shopPrice(0, "USD").text == "Free")
        // PC stores only: no console or phone platforms anywhere in the filters.
        let platforms = giveawayPlatformPopup.itemTitles.joined(separator: " ")
        for banned in ["PlayStation", "Xbox", "Switch", "Android", "iOS"] { precondition(!platforms.contains(banned), "No \(banned) giveaways") }
        // My Stores / All Stores is saved and sent as --mine.
        selectShopTab(1)
        spin()
        precondition(!shopScopeBar.isHidden)
        shopScope.selectedSegment = 0
        shopScopeChanged()
        precondition(defaults.string(forKey: shopScopeKey) == "mine" && dealsArguments().contains("--mine"))
        shopScope.selectedSegment = 1
        shopScopeChanged()
        precondition(defaults.string(forKey: shopScopeKey) == "all" && !dealsArguments().contains("--mine"))
        spin()
        myStores = []
        updateScopeHint()
        precondition(shopScope.selectedSegment == 1 && !shopScope.isEnabled(forSegment: 0) && shopScopeHint.stringValue.hasPrefix("No store apps"))
        myStores = [ShopStoreRef(key: "steam", name: "Steam")]
        shopScope.selectedSegment = 0
        shopScopeChanged()
        precondition(shopScope.isEnabled(forSegment: 0) && shopScopeHint.stringValue.contains("Steam"))
        // Home: wishlist hits, featured deals, price drops and free games, for the saved scope.
        smokeWishlist = [["key": "cs:612", "title": "Portal 2", "game_id": "612", "steam_app_id": "620", "app_store_id": NSNull(),
                          "added": 1_700_000_000, "target_price": 2.5, "thumb": "https://cdn.example.com/portal2.jpg",
                          "best": ["price": 1.99, "normal_price": 9.99, "savings": 80, "store": "Steam", "currency": "USD", "checked": 1_700_000_000],
                          "on_sale": true, "target_hit": true, "sale_text": "On sale at Steam \u{2212}80%",
                          "insight": ["kind": "record", "percent": NSNull(), "low": 1.99, "currency": "USD", "date": "2025-09-29"]]]
        checkWishlist(refresh: false)
        spin()
        precondition(wishlist?.items.count == 1 && calls("wishlist").last!.contains("--check"))
        shopHome = nil
        homeLoadedScope = nil
        selectShopTab(0)
        spin()
        precondition(shopScopeBar.isHidden == false && !homePane.isHidden && dealsPane.isHidden)
        precondition(calls("shop-home").last! == ["shop-home", "--scope", "mine"])
        let home = labels(homeList).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        for title in ["Wishlist deals", "Featured deals", "Price drops", "Free now", "Drop Game", "Free Adventure", "Steam \u{2212}80%"] {
            precondition(home.contains { $0 == title || $0.contains(title) }, "Home shows \(title)")
        }
        precondition(!home.contains { $0.contains("On sale at") }, "The sale tag shows only the store and discount")
        let saleRow = views(homeList).first { $0.accessibilityIdentifier() == "wishlistRow" }!
        precondition(labels(saleRow).filter { $0.contains("\u{2212}80%") } == ["Steam \u{2212}80%"], "The sale shows once, under the price, not under the title too: \(labels(saleRow))")
        precondition(views(saleRow).contains { ($0 as? NSTextField)?.stringValue == "All-time low" && $0.accessibilityIdentifier() == "shopPriceInsight" },
                     "Wishlist rows note the all-time low too")
        precondition(((saleRow.toolTip ?? "") + (saleRow.accessibilityLabel() ?? "")).contains("On sale at Steam \u{2212}80%"),
                     "The full sentence stays in the tooltip and VoiceOver: \(saleRow.toolTip ?? "") / \(saleRow.accessibilityLabel() ?? "")")
        // Hearts: saved items are filled; adding sends only the allowed keys; removing clears it.
        precondition(heart("cs:612")?.image?.name() == nil && heart("cs:612")?.accessibilityLabel() == "Remove Portal 2 from wishlist")
        precondition(heart("cs:700")?.accessibilityLabel() == "Add Drop Game to wishlist" && heart("cs:700")!.isEnabled)
        heart("cs:700")!.performClick(nil)
        spin()
        let add = calls("wishlist").last!
        precondition(add[1] == "--add")
        let payload = try! JSONSerialization.jsonObject(with: Data(add[2].utf8)) as! [String: String]
        precondition(payload == ["title": "Drop Game", "game_id": "700", "steam_app_id": "700", "thumb": "https://cdn.example.com/drop.jpg"],
                     "The heart saves the art link (not the image) with the game")
        precondition(wishlist?.items.count == 2 && heart("cs:700")?.accessibilityLabel() == "Remove Drop Game from wishlist")
        heart("cs:700")!.performClick(nil)
        spin()
        precondition(calls("wishlist").last! == ["wishlist", "--remove", "cs:700"] && wishlist?.items.count == 1)
        // Drive unplugged: the cached wishlist is read-only, with a note.
        smokeWishlistOffline = true
        checkWishlist(refresh: false)
        spin()
        let offlineCalls = calls("wishlist").count
        heart("cs:700")!.performClick(nil)
        precondition(wishlist?.offline == true && calls("wishlist").count == offlineCalls && !dealsReminderBar.isHidden &&
                     dealsReminderNote.stringValue.contains("isn't connected"), "A read-only heart explains itself and changes nothing")
        dealsReminderBar.isHidden = true
        selectShopTab(4)
        precondition(wishlistStatus.stringValue.contains("isn't connected") &&
                     views(wishlistList).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier() == "wishlistRemove" }.allSatisfy { !$0.isEnabled })
        smokeWishlistOffline = false
        checkWishlist(refresh: false)
        spin()
        // Wishlist rows: target price and removal go through the backend file.
        let rows = views(wishlistList).filter { $0.accessibilityIdentifier() == "wishlistRow" }
        precondition(rows.count == 1 && labels(wishlistList).contains { $0.replacingOccurrences(of: "\u{00A0}", with: " ").contains("Target reached") })
        // Each item shows its art (a cached link), its current best price and a target editor, even at the minimum width.
        window.contentView!.layoutSubtreeIfNeeded()
        let wishArt = views(rows[0]).compactMap { $0 as? RemoteImageView }
        precondition(wishArt.count == 1 && wishArt[0].source?.absoluteString == "https://cdn.example.com/portal2.jpg", "Wishlist rows show the game's art")
        precondition(labels(rows[0]).contains { $0.contains("1.99") }, "Wishlist rows show the current best price: \(labels(rows[0]))")
        let targetButton = { views(self.wishlistList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistTarget" }! }
        for view in [wishArt[0], targetButton()] as [NSView] {
            let frame = view.convert(view.bounds, to: rows[0])
            precondition(frame.width > 0 && frame.minX >= 0 && frame.maxX <= rows[0].bounds.width + 0.5, "\(view) fits the wishlist row: \(frame)")
        }
        askTargetPrice = { _, _, code in precondition(code == "USD", "Original prices: the target stays in its currency"); return .some(5) }
        targetButton().performClick(nil)
        spin()
        precondition(calls("wishlist").last! == ["wishlist", "--target", "cs:612", "--price", "5.00", "--currency", "USD"])
        // With HUF as the Shop currency, targets are entered in forints and the USD price is converted to compare.
        defaults.set("HUF", forKey: shopCurrencyKey)
        exchangeRates = try! JSONDecoder().decode(ExchangeRates.self, from: Data(smokeRatesJSON.utf8))
        renderWishlist()
        precondition(targetButton().accessibilityLabel() == "Set a target price in HUF for Portal 2")
        var askedCurrent: Double?? = .none
        askTargetPrice = { _, current, code in precondition(code == "HUF"); askedCurrent = current; return .some(4000) }
        targetButton().performClick(nil)
        spin()
        precondition(askedCurrent! == nil, "A USD target isn't shown as forints")
        precondition(calls("wishlist").last! == ["wishlist", "--target", "cs:612", "--price", "4000", "--currency", "HUF"])
        let saved = wishlist!.items[0]
        precondition(saved.targetPrice == 4000 && saved.targetCurrency == "HUF" && targetReached(saved) == true,
                     "1.99 USD is about 642 HUF, under a 4000 HUF target")
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
        precondition(labels(wishlistList).contains { plain($0).contains("Target reached: " + plain(ShopMoney.format(4000, "HUF"))) })
        askTargetPrice = { _, current, _ in askedCurrent = current; return .some(500) }
        targetButton().performClick(nil)
        spin()
        precondition(askedCurrent! == 4000 && targetReached(wishlist!.items[0]) == false, "642 HUF is above a 500 HUF target")
        precondition(!labels(wishlistList).contains { $0.contains("Target reached") } && labels(wishlistList).contains { plain($0).contains("Target " + plain(ShopMoney.format(500, "HUF"))) })
        let loadedRates = exchangeRates
        exchangeRates = nil
        renderWishlist()
        precondition(targetReached(wishlist!.items[0]) == nil && targetButton().isEnabled, "No rates: still editable, comparison unknown")
        precondition(views(wishlistList).contains { ($0.toolTip ?? "").contains("Can't compare with USD prices") }, "The row says why")
        exchangeRates = loadedRates
        askTargetPrice = { _, _, _ in .some(2.5) }
        defaults.set("original", forKey: shopCurrencyKey)
        targetButton().performClick(nil)
        spin()
        precondition(parseTargetPrice("4 000 Ft", "HUF") == 4000 && parseTargetPrice("4.000", "HUF") == 4000 &&
                     parseTargetPrice("9,99", "EUR") == 9.99 && parseTargetPrice("$9.99", "USD") == 9.99 && parseTargetPrice("", "USD") == nil)
        askTargetPrice = { _, _, _ in .none }
        let targets = calls("wishlist").count
        views(wishlistList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistTarget" }!.performClick(nil)
        precondition(calls("wishlist").count == targets, "Cancelling the target changes nothing")
        // Search: too short does nothing; typing is debounced; identical searches are combined.
        selectShopTab(3)
        let searches = calls("shop-search").count
        shopSearchField.stringValue = "h"
        shopSearchSubmitted()
        precondition(calls("shop-search").count == searches)
        shopSearchField.stringValue = "hollow knight"
        shopSearchTyped()
        shopSearchTyped()
        spin(0.3)
        precondition(calls("shop-search").count == searches, "Search waits for a pause in typing")
        spin(1.0)
        precondition(calls("shop-search").count == searches + 1)
        precondition(calls("shop-search").last!.starts(with: ["shop-search", "--query", "hollow knight", "--country"]))
        shopSearchSubmitted()
        spin()
        precondition(calls("shop-search").count == searches + 1, "An identical search reuses the loaded results")
        func offers() -> [String] {
            views(searchList).filter { $0.accessibilityIdentifier() == "shopOffer" }.compactMap { $0.accessibilityLabel() }
        }
        func order() -> [String] {
            offers().map { $0.replacingOccurrences(of: "Open Hollow Knight at ", with: "").components(separatedBy: ",")[0] }
        }
        // Original prices: USD stores by price, then the App Store group in its own currency.
        precondition(order() == ["GOG", "Steam", "Mac App Store"], "\(order())")
        precondition(offers().filter { $0.hasSuffix(", cheapest") }.count == 1 && offers()[0].hasSuffix(", cheapest"))
        precondition(labels(searchList).contains("Mac App Store") && labels(searchList).contains("Hollow Pocket") &&
                     views(searchList).contains { $0.toolTip?.hasSuffix("in HUF") ?? false })
        precondition(views(searchList).filter { $0.accessibilityIdentifier() == "shopAppStoreRow" }.count == 1)
        // Converted to USD, then HUF: every store sorts by the converted price, marked with ≈ and the original.
        defaults.set("USD", forKey: shopCurrencyKey)
        loadRates(refresh: false)
        spin()
        precondition(exchangeRates == rates && !shopCurrencyNote.isHidden && shopCurrencyNote.stringValue.contains("Frankfurter"),
                     "rates \(String(describing: exchangeRates)) loading \(ratesLoading) note \(shopCurrencyNote.stringValue)")
        rerenderShop()
        precondition(order() == ["GOG", "Mac App Store", "Steam"], "\(order())")
        precondition(offers()[1].contains("\u{2248}") && offers()[1].contains("(3990 HUF)") && !offers()[0].contains("\u{2248}"))
        precondition(shopPrice(3990, "HUF").value == ShopMoney.decimal(12.37))
        defaults.set("HUF", forKey: shopCurrencyKey)
        rerenderShop()
        precondition(order() == ["GOG", "Mac App Store", "Steam"], "\(order())")
        precondition(offers()[0].contains("\u{2248}") && offers()[0].contains("(9.99 USD)") && !offers()[1].contains("\u{2248}"))
        precondition(shopPrice(9.99, "USD").value == 3223 && shopPrice(3990, "HUF").value == 3990)
        let tips = views(searchList).compactMap { $0 as? NSTextField }.compactMap(\.toolTip)
        precondition(tips.contains { $0.hasSuffix("(9.99 USD)") }, "Converted prices show the original in the tooltip")
        defaults.set(1.0, forKey: shopFeeKey)
        precondition(shopPrice(11.99, "USD").value == 3907 && shopPrice(3990, "HUF").value == 3990, "The fee applies only to conversions")
        defaults.removeObject(forKey: shopFeeKey)
        // Rows open the default browser: CheapShark redirects and apps.apple.com only.
        let before = opened().count
        let shopRows = views(searchList).compactMap { $0 as? ClickableRowView }
        shopRows.forEach { $0.activate() }
        let hosts = Set(opened().dropFirst(before).compactMap(\.host))
        precondition(opened().count - before == shopRows.count && hosts == ["www.cheapshark.com", "apps.apple.com"], "\(hosts)")
        // Search groups: one parent row per game (art, title, heart, lowest price), stores indented beneath it, cheapest first.
        defaults.set("original", forKey: shopCurrencyKey)
        rerenderShop()
        window.contentView!.layoutSubtreeIfNeeded()
        let list = searchList.arrangedSubviews.filter { !($0 is NSBox) }
        let parentIndex = list.firstIndex { $0.accessibilityIdentifier() == "shopGameRow" }!
        let parent = list[parentIndex]
        let children = Array(list[(parentIndex + 1)...].prefix { $0.accessibilityIdentifier() == "shopOffer" })
        precondition(children.count == 3, "Every store sits under its game")
        precondition(searchList.arrangedSubviews[searchList.arrangedSubviews.firstIndex(of: parent)! + 1].accessibilityIdentifier() == "shopOffer",
                     "No separator between a game and its stores")
        precondition(views(parent).contains { $0 is RemoteImageView && $0.accessibilityIdentifier() == "shopArtwork" }, "Search games show their art")
        precondition(children.allSatisfy { child in !views(child).contains { $0 is RemoteImageView } && !labels(child).contains("Hollow Knight") },
                     "Store rows don't repeat the art or title")
        func art(_ row: NSView) -> NSRect { let a = views(row).first { ["shopArtwork", "shopStoreIcon"].contains($0.accessibilityIdentifier()) }!; return a.convert(a.bounds, to: searchList) }
        func leftmost(_ row: NSView) -> CGFloat {
            views(row).filter { ($0 is NSTextField || $0 is NSImageView) && $0.frame.width > 0 && !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.convert($0.bounds, to: searchList).minX }.min()!
        }
        precondition(children.allSatisfy { leftmost($0) >= art(parent).minX + Self.shopChildIndent - 0.5 }, "Store rows are indented")
        let lowest = children.map { child in views(child).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "shopLowest" }?.stringValue }
        precondition(lowest.compactMap { $0 }.count == 1 && lowest[0]?.replacingOccurrences(of: "\u{00A0}", with: " ") == "Lowest USD",
                     "Only the cheapest store is marked, with its currency when prices are mixed: \(lowest)")
        let parentMarker = views(parent).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "shopLowest" }
        precondition(parentMarker == nil && parent.accessibilityLabel()!.contains("lowest price $9.99 at GOG"), parent.accessibilityLabel() ?? "")
        // Search → wishlist with real clicks while the search field is editing: the heart must survive and toggle.
        // Real mouse events through the window, like a user's click: hit testing, responder chain and button tracking.
        func click(_ view: NSView, expecting target: NSView? = nil) {
            view.scrollToVisible(view.bounds)
            window.contentView!.layoutSubtreeIfNeeded()
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let hit = window.contentView!.hitTest(window.contentView!.superview!.convert(point, from: nil))
            precondition(hit === (target ?? view), "\(view.accessibilityIdentifier()) receives its own clicks, not \(String(describing: hit)) \(hit?.accessibilityIdentifier() ?? "") at \(point) in \(window.contentView!.bounds), tab \(shopTab.selectedSegment) hidden \(view.isHiddenOrHasHiddenAncestor)")
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            // A mouse-up left over from an earlier step would end this click's tracking at the wrong spot.
            while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDown, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) != nil {}
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.sendEvent(event(.leftMouseDown))
            // An enabled button's tracking loop takes the mouse-up; otherwise deliver it the way the app would.
            // Under load the posted event can take a moment to reach the queue, so wait briefly for it.
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.3), inMode: .default, dequeue: true) { window.sendEvent(up) }
            spin()
        }
        let openedBefore = opened().count
        window.makeFirstResponder(shopSearchField)
        let searchHeart = views(searchList).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "cs:100" }!
        shopSearchSubmitted()
        precondition(searchHeart.window != nil, "Re-sending an identical search doesn't rebuild the rows under the pointer")
        click(searchHeart)
        precondition(calls("wishlist").last!.prefix(2) == ["wishlist", "--add"],
                     "\(calls("wishlist").last!) editable \(wishlistEditable) loaded \(wishlist != nil) payload \(wishlistPayloads["cs:100"] != nil) enabled \(searchHeart.isEnabled) key \(window.isKeyWindow) note \(wishlist?.note ?? "-")")
        let searchPayload = try! JSONSerialization.jsonObject(with: Data(calls("wishlist").last![2].utf8)) as! [String: String]
        precondition(searchPayload == ["title": "Hollow Knight", "game_id": "100", "steam_app_id": "367520"], "\(searchPayload)")
        precondition(searchHeart.accessibilityLabel() == "Remove Hollow Knight from wishlist" && opened().count == openedBefore,
                     "The heart fills at once and doesn't open the store")
        selectShopTab(4)
        precondition(labels(wishlistList).contains("Hollow Knight"), "The searched game is in the Wishlist")
        // One search field above every section: searching from Home shows the results in its place; clearing it goes back to Home.
        selectShopTab(0)
        precondition(!shopSearchField.isHiddenOrHasHiddenAncestor && shopNav.selectedSegment == 0, "The search field is on Home too")
        precondition(!views(shopPageView!).contains { ($0 as? NSSearchField).map { $0 !== shopSearchField } ?? false },
                     "The Shop has exactly one search field")
        shopSearchField.stringValue = "hollow knight"
        shopSearchSubmitted()
        spin()
        precondition(shopTab.selectedSegment == 3 && !searchPane.isHidden && homePane.isHidden && shopNav.selectedSegment == -1 && shopScopeBar.isHidden,
                     "Searching shows results, with no section selected: tab \(shopTab.selectedSegment) nav \(shopNav.selectedSegment)")
        let resultHeart = views(searchList).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "cs:100" }!
        precondition(resultHeart.accessibilityLabel() == "Remove Hollow Knight from wishlist")
        click(resultHeart)
        precondition(calls("wishlist").last! == ["wishlist", "--remove", "cs:100"] && !(wishlist?.items.contains { $0.key == "cs:100" } ?? true))
        precondition(resultHeart.accessibilityLabel() == "Add Hollow Knight to wishlist" && opened().count == openedBefore)
        shopSearchField.stringValue = ""
        shopSearchSubmitted()
        precondition(shopTab.selectedSegment == 0 && !homePane.isHidden && shopNav.selectedSegment == 0, "Clearing the search goes back to Home")
        shopNav.selectedSegment = 1
        shopNavChanged()
        precondition(shopTab.selectedSegment == 1 && !dealsPane.isHidden, "The section control switches sections")
        shopSearchField.stringValue = "hollow knight"
        shopSearchSubmitted()
        spin()
        precondition(shopTab.selectedSegment == 3)
        // Mac / Windows badges: only Steam's platform flags or the Mac App Store count; unknown games get no claim.
        for _ in 0..<40 where steamPlatformStatus["700"] == nil || steamPlatformStatus["367520"] == nil { spin(0.1) }
        precondition(calls("shop-platforms").allSatisfy { $0.count == 3 && $0[2].split(separator: ",").count <= 40 })
        precondition(compatibility(steamAppId: "620") == .mac && compatibility(steamAppId: "700") == .windowsOnly &&
                     compatibility(steamAppId: nil) == nil && compatibility(steamAppId: "999") == nil && compatibility(steamAppId: nil, appStore: true) == .mac,
                     "Platforms \(steamPlatformStatus) calls \(calls("shop-platforms")) requested \(platformsRequested)")
        func rowText(_ list: NSStackView, _ id: String, _ title: String) -> String? {
            views(list).first { $0.accessibilityIdentifier() == id && labels($0).contains(title) }
                .map { labels($0).joined(separator: " | ").replacingOccurrences(of: "\u{00A0}", with: " ") }
        }
        selectShopTab(0)
        window.contentView!.layoutSubtreeIfNeeded()
        let homeRows = views(homeList).filter { $0 is ClickableRowView }
        func homeRow(_ title: String) -> String { homeRows.first { labels($0).contains(title) }.map { labels($0).joined(separator: " | ").replacingOccurrences(of: "\u{00A0}", with: " ") } ?? "" }
        precondition(homeRow("Drop Game").hasPrefix("Drop Game | ") && homeRow("Drop Game").contains("\u{FFFC} Windows |") &&
                     !homeRow("Drop Game").contains("needs") && !homeRow("Drop Game").contains("only"), "Windows-only deal: \(homeRow("Drop Game"))")
        precondition(homeRow("Portal 2").contains("Mac") && !homeRow("Portal 2").contains("Windows"), homeRow("Portal 2"))
        precondition(!homeRow("Free Adventure").contains("Mac") && !homeRow("Free Adventure").contains("Windows"), "Giveaways make no claim")
        let dropTip = homeRows.first { labels($0).contains("Drop Game") }!.accessibilityLabel() ?? ""
        precondition(dropTip.contains("compatibility app"), "The Windows-only row explains it needs a compatibility app")
        let storeTexts = views(homeList).compactMap { $0 as? NSTextField }.filter { $0.attributedStringValue.containsAttachments }
        precondition(!storeTexts.isEmpty, "Store hints carry the store's mini icon")
        selectShopTab(3)
        window.contentView!.layoutSubtreeIfNeeded()
        let hollow = rowText(searchList, "shopGameRow", "Hollow Knight") ?? ""
        precondition(hollow.contains("Mac"), "Search parent: \(hollow)")
        if let silksong = views(searchList).first(where: { $0 is ClickableRowView && labels($0).contains { $0.hasPrefix("Hollow Knight: Silksong") } }) {
            let text = labels(silksong).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            precondition(!text.contains("Mac") && !text.contains { $0.hasPrefix("Windows") }, "No Steam ID, no claim: \(text)")
        }
        let offerViews = views(searchList).filter { $0.accessibilityIdentifier() == "shopOffer" }
        precondition(!offerViews.isEmpty)
        for offer in offerViews {
            let icons = views(offer).filter { $0.accessibilityIdentifier() == "shopStoreIcon" }
            let tags = views(offer).filter { $0.accessibilityIdentifier() == "shopStoreTag" }
            let sale = views(offer).contains { $0.accessibilityIdentifier() == "shopSaleTag" }
            let store = (tags.first?.accessibilityLabel() ?? "").components(separatedBy: ", ")[0]
            let tagText = labels(tags.first ?? offer)
            precondition(tags.count == 1 && (sale ? icons.isEmpty && tagText.count == 1 && tagText[0].hasPrefix(store + " \u{2212}") && tagText[0].hasSuffix("%")
                                                  : icons.count == 1 && icons[0].accessibilityLabel() == store && icons[0].frame.width == 12 && tagText == [store])
                         && labels(offer).filter { $0.hasPrefix(store) }.count == 1,
                         "Every store price names its store in full, once: gray with its icon, or a green tag with the discount: \(store) \(labels(offer))")
            let price = views(offer).first { $0.accessibilityIdentifier() == "shopPriceLine" }!
            let tagFrame = tags[0].convert(tags[0].bounds, to: offer), priceFrame = price.convert(price.bounds, to: offer)
            precondition(abs(tagFrame.maxX - priceFrame.maxX) < 0.5 && (offer.isFlipped ? tagFrame.minY >= priceFrame.maxY - 0.5 : tagFrame.maxY <= priceFrame.minY + 0.5),
                         "The store line sits right under the price, right-aligned: \(tagFrame) \(priceFrame)")
            let text = labels(offer).joined(separator: " ")
            if !(store == "Steam" || store == "Mac App Store") {
                precondition(!text.contains("Windows") && !text.contains("Mac\u{00A0}") && !text.hasSuffix("Mac"),
                             "Other PC stores may ship other builds, so they make no claim: \(text)")
            }
        }
        // The all-time low: only CheapShark's record minimum, as a small line under the price, with the record in the tooltip.
        let insights = views(searchList).filter { $0.accessibilityIdentifier() == "shopPriceInsight" }.compactMap { $0 as? NSTextField }
        precondition(insights.map(\.stringValue).sorted() == ["25% above all-time low", "All-time low"]
                     && insights.allSatisfy { ($0.toolTip ?? "").contains("7.99 USD") || ($0.toolTip ?? "").contains("19.99 USD") }
                     && insights.allSatisfy { !($0.toolTip ?? "").lowercased().contains("average") && ($0.toolTip ?? "").contains("2025") }
                     && !views(searchList).filter { $0.accessibilityIdentifier() == "shopOffer" }.contains { views($0).contains { $0.accessibilityIdentifier() == "shopPriceInsight" } },
                     "All-time-low notes on the game rows only: \(insights.map(\.stringValue))")
        for insight in insights {
            let column = insight.superview!.superview!
            precondition(column.accessibilityIdentifier() == "shopPriceColumn" && column.subviews.last === insight.superview, "The note sits under the price and store")
        }
        precondition(PriceInsight(kind: "above", percent: nil, low: 0, currency: "USD", date: nil).text == "Was free before"
                     && PriceInsight(kind: "above", percent: nil, low: 0, currency: "USD", date: nil).detail.contains("free"))
        precondition(Self.storeIconID("Steam") == "steam" && Self.storeIconID("GOG") == "gog-galaxy" && Self.storeIconID("Epic Games Store") == "epic-games" &&
                     Self.storeIconID("Origin") == "ea" && Self.storeIconID("Humble Store") == nil && !Self.storeIcon("Steam", size: 16).template &&
                     Self.storeIcon("Humble Store", size: 16).template)
        renderWishlist()
        let wished = views(wishlistList).filter { $0.accessibilityIdentifier() == "wishlistRow" }
        precondition(wished.allSatisfy { row in
            let item = wishlist!.items.first { labels(row).contains($0.title) }
            let text = labels(row).joined(separator: " ")
            return compatibility(steamAppId: item?.steamAppId, appStore: item?.appStoreId != nil) == .mac ? text.contains("Mac") : true
        })
        // Sort by: one stable comparator for every list; missing values last, prices grouped by currency unless converted.
        let sample = [ShopSortFields(title: "beta", price: 10, currency: "USD", discount: 20, rating: 80, added: 2, ends: 300),
                      ShopSortFields(title: "Alpha", price: 3000, currency: "HUF", rating: 90, added: 3),
                      ShopSortFields(title: "gamma", price: 5, currency: "USD", discount: 50, ends: 100),
                      ShopSortFields(title: "delta", discount: 20, rating: 80, added: 1, ends: 200)]
        func order(_ sort: ShopSort, _ convert: @escaping (Double, String) -> Double? = { _, _ in nil }) -> [String] {
            shopSorted(sample, by: sort, convert: convert) { $0 }.map(\.title)
        }
        let toUSD: (Double, String) -> Double? = { price, code in code == "USD" ? price : code == "HUF" ? price / 375 : nil }
        precondition(order(.relevance) == ["beta", "Alpha", "gamma", "delta"])
        precondition(order(.name) == ["Alpha", "beta", "delta", "gamma"])
        precondition(order(.priceAsc) == ["Alpha", "gamma", "beta", "delta"], "Original prices group by currency: \(order(.priceAsc))")
        precondition(order(.priceAsc, toUSD) == ["gamma", "Alpha", "beta", "delta"], "\(order(.priceAsc, toUSD))")
        precondition(order(.priceDesc, toUSD) == ["beta", "Alpha", "gamma", "delta"], "No price stays last: \(order(.priceDesc, toUSD))")
        precondition(order(.discount) == ["gamma", "beta", "delta", "Alpha"], "Ties keep their order: \(order(.discount))")
        precondition(order(.rating) == ["Alpha", "beta", "delta", "gamma"])
        precondition(order(.added) == ["Alpha", "beta", "delta", "gamma"])
        precondition(order(.endsSoon) == ["gamma", "delta", "beta", "Alpha"])
        // Each list remembers its choice; Deals and Free Games map onto their existing popups.
        func pick(_ popup: NSPopUpButton, _ value: String) {
            popup.selectItem(at: popup.indexOfItem(withRepresentedObject: value))
            popup.sendAction(popup.action, to: popup.target)
            spin()
        }
        precondition(searchSortPopup.accessibilityIdentifier() == "shopSortPopup" && !searchSortPopup.itemTitles.contains("Best Rating"),
                     "Search results have no ratings to sort by")
        pick(wishlistSortPopup, "name")
        precondition(UserDefaults.standard.string(forKey: wishlistSortKey) == "name")
        let wishedTitles = views(wishlistList).filter { $0.accessibilityIdentifier() == "wishlistRow" }
            .compactMap { row in wishlist!.items.first { labels(row).contains($0.title) }?.title }
        precondition(wishedTitles == wishedTitles.sorted { $0.localizedStandardCompare($1) == .orderedAscending } && !wishedTitles.isEmpty)
        pick(searchSortPopup, "price-desc")
        precondition(UserDefaults.standard.string(forKey: searchSortKey) == "price-desc")
        let parents = views(searchList).filter { $0.accessibilityIdentifier() == "shopGameRow" || $0.accessibilityIdentifier() == "shopSingleOffer" }
        precondition(!parents.isEmpty)
        let header = sortHeader(NSTextField(labelWithString: ""), NSPopUpButton(), [.relevance, .priceDesc], key: searchSortKey, label: "x")
        precondition((header.arrangedSubviews[1] as! NSPopUpButton).titleOfSelectedItem == "Highest Price", "The saved choice comes back")
        pick(searchSortPopup, "relevance")
        pick(wishlistSortPopup, "relevance")
        precondition(dealsSortPopup.indexOfItem(withRepresentedObject: "price-desc") >= 0 && giveawaySortPopup.indexOfItem(withRepresentedObject: "ends") >= 0)
        let savedGiveawaySort = giveawaySortPopup.selectedItem?.representedObject as? String
        giveawaySortPopup.selectItem(at: giveawaySortPopup.indexOfItem(withRepresentedObject: "ends"))
        let savedMode = dealsMode.selectedSegment
        dealsMode.selectedSegment = 1
        precondition(dealsArguments().contains("date") && !dealsArguments().contains("ends"), "Ends Soon sorts here, not on GamerPower")
        precondition(sortedGiveaways().count == giveaways.count)
        dealsMode.selectedSegment = savedMode
        giveawaySortPopup.selectItem(at: giveawaySortPopup.indexOfItem(withRepresentedObject: savedGiveawaySort ?? "date"))
        UserDefaults.standard.removeObject(forKey: searchSortKey)
        UserDefaults.standard.removeObject(forKey: wishlistSortKey)
        // A bundle replaced mid-run reports a friendly reopen message instead of the raw python error.
        precondition(friendlyBackendError("python3: can't open file '/x/CouchCube.app/Contents/Resources/scripts/console.py': [Errno 2] No such file or directory")
                     == Self.appUpdatedMessage)
        precondition(friendlyBackendError("Steam is not installed.") == "Steam is not installed.")
        // Store-style headings on Home; "See all" links open their tab.
        selectShopTab(0)
        let titles = views(homeList).compactMap { $0 as? NSTextField }.filter { $0.accessibilityIdentifier() == "shopSectionTitle" }
        precondition(!titles.isEmpty && titles.allSatisfy { $0.font!.pointSize == Self.shopHeadingSize }, "Home headings are large")
        // Sections are separated by about twice the old gap; a heading stays close to its own rows.
        window.contentView!.layoutSubtreeIfNeeded()
        let headers = homeList.arrangedSubviews.filter { $0.accessibilityIdentifier() == "shopSection" }
        precondition(headers.count >= 2)
        for header in headers {
            let index = homeList.arrangedSubviews.firstIndex(of: header)!
            let below = homeList.arrangedSubviews[index + 1]
            let tight = abs(header.frame.minY - below.frame.maxY) < 0.5 || abs(below.frame.minY - header.frame.maxY) < 0.5
            precondition(tight && (header as! NSStackView).edgeInsets.bottom <= 4, "A heading sits right on its rows")
            guard index > 0 else { continue }
            let above = homeList.arrangedSubviews[index - 1]
            let gap = abs(above.frame.minY - header.frame.maxY) < abs(header.frame.minY - above.frame.maxY)
                ? above.frame.minY - header.frame.maxY : header.frame.minY - above.frame.maxY
            precondition(gap >= Self.shopSectionGap - 0.5 && (header as! NSStackView).edgeInsets.top + gap >= 27.5,
                         "Sections are clearly separated: \(gap)")
        }
        let seeAll = views(homeList).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier() == "shopSeeAll" }
        precondition(seeAll.map(\.tag).contains(1) && seeAll.map(\.tag).contains(2))
        seeAll.first { $0.tag == 2 }!.performClick(nil)
        precondition(shopTab.selectedSegment == 2)
        // Every visible heart on every tab, at the narrowest and a roomy window, with real clicks: the heart alone
        // toggles the wishlist and never opens a store, whether the wishlist is editable or read-only.
        let roomyFrame = window.frame
        func visibleHearts() -> [NSButton] {
            views(shopPageView!).compactMap { $0 as? NSButton }.filter {
                ["wishlistHeart", "wishlistRemove"].contains($0.accessibilityIdentifier()) && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        func firstHeart(_ key: String, _ kind: String) -> NSButton? {
            visibleHearts().first { $0.identifier?.rawValue == key && $0.accessibilityIdentifier() == kind }
        }
        let savedHeartsWishlist = smokeWishlist
        // Reload the wishlist and wait for the reply, so a slow check never leaves the previous (read-only) state behind.
        func reloadWishlist() {
            let deadline = Date().addingTimeInterval(10)
            while wishlistLoading && Date() < deadline { spin() }
            checkWishlist(refresh: false)
            spin()
            while wishlistLoading && Date() < deadline { spin() }
            precondition(!wishlistLoading, "The wishlist check finishes")
        }
        for size in [window.contentMinSize, NSSize(width: 1240, height: 860)] {
            window.setContentSize(size)
            for tab in 0..<5 {
                selectShopTab(tab)
                spin()
                window.contentView!.layoutSubtreeIfNeeded()
                let targets = visibleHearts().map { ($0.identifier!.rawValue, $0.accessibilityIdentifier()) }
                precondition(!targets.isEmpty, "Tab \(tab) has hearts to test")
                var seen = Set<String>()
                for (key, kind) in targets where seen.insert(kind + key).inserted {
                    let openedBefore = opened().count, before = calls("wishlist").count
                    let heart = firstHeart(key, kind)!
                    precondition(heart.acceptsFirstMouse(for: nil), "Heart \(key) works with one click in an inactive window, like its row")
                    let saved = kind == "wishlistRemove" || heart.accessibilityLabel()!.hasPrefix("Remove ")
                    click(heart)
                    precondition(opened().count == openedBefore, "Heart \(key) on tab \(tab) at \(size) never opens a store")
                    precondition(calls("wishlist").count == before + 1 &&
                                 calls("wishlist").last![1] == (saved ? "--remove" : "--add"),
                                 "Heart \(key) on tab \(tab) at \(size) toggles the wishlist: \(calls("wishlist").suffix(2))")
                    if kind == "wishlistHeart", let again = firstHeart(key, kind) {
                        precondition(again.accessibilityLabel()!.hasPrefix(saved ? "Add " : "Remove "), "\(key) shows its new state at once")
                        click(again)
                        precondition(opened().count == openedBefore && calls("wishlist").count == before + 2)
                        precondition(firstHeart(key, kind)!.accessibilityLabel()!.hasPrefix(saved ? "Remove " : "Add "), "\(key) toggles back")
                    }
                    smokeWishlist = savedHeartsWishlist
                    reloadWishlist()
                }
                // Read-only (drive unplugged): hearts explain, change nothing and still never open the store.
                smokeWishlistOffline = true
                reloadWishlist()
                precondition(!wishlistEditable, "The wishlist is read-only while the drive is away")
                for heart in visibleHearts() {
                    let openedBefore = opened().count, before = calls("wishlist").count
                    dealsReminderBar.isHidden = true
                    click(heart)
                    precondition(opened().count == openedBefore && calls("wishlist").count == before,
                                 "A read-only heart on tab \(tab) at \(size) never opens a store")
                    precondition(heart.accessibilityIdentifier() == "wishlistRemove" || !dealsReminderBar.isHidden,
                                 "A read-only heart says why it can't change")
                }
                dealsReminderBar.isHidden = true
                smokeWishlistOffline = false
                reloadWishlist()
                precondition(wishlistEditable, "The wishlist is editable again")
            }
        }
        // The rest of a row still opens the store with a real click.
        selectShopTab(1)
        spin()
        let dealRowView = views(dealsList).compactMap { $0 as? ClickableRowView }.first!
        let dealTitle = views(dealRowView).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Portal 2" }!
        let openedBeforeRow = opened().count
        click(dealTitle, expecting: dealRowView)
        precondition(opened().count == openedBeforeRow + 1 && opened().last!.host == "www.cheapshark.com", "Clicking the row opens the deal")
        window.setFrame(roomyFrame, display: false)
        // Search: a game sold in one store is a plain row; groups mark only the cheapest store, not the game.
        let single = views(searchList).first { $0.accessibilityIdentifier() == "shopSingleOffer" }
        precondition(single != nil && !views(single!).contains { $0.accessibilityIdentifier() == "shopLowest" } &&
                     searchList.arrangedSubviews.filter { $0.accessibilityIdentifier() == "shopOffer" }.count == 3 &&
                     views(single!).contains { $0.accessibilityIdentifier() == "wishlistHeart" && $0.identifier?.rawValue == "cs:200" },
                     "A one-store game is an ordinary row with its own heart")
        // A real click on a one-store result's heart adds it, a second removes it, and neither opens the store.
        func singleHeart() -> NSButton {
            views(searchList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "wishlistHeart" && $0.identifier?.rawValue == "cs:200" }!
        }
        selectShopTab(3)
        spin()
        window.contentView!.layoutSubtreeIfNeeded()
        singleHeart().scrollToVisible(singleHeart().bounds)
        let openedBeforeSingle = opened().count
        let hadSingle = wishlist?.items.contains { $0.key == "cs:200" } ?? false
        click(singleHeart())
        spin()
        precondition((wishlist?.items.contains { $0.key == "cs:200" } ?? false) != hadSingle && opened().count == openedBeforeSingle,
                     "One-store heart toggles the wishlist without navigating")
        click(singleHeart())
        spin()
        precondition((wishlist?.items.contains { $0.key == "cs:200" } ?? false) == hadSingle && opened().count == openedBeforeSingle &&
                     calls("wishlist").suffix(2).map { $0[1] } == (hadSingle ? ["--remove", "--add"] : ["--add", "--remove"]))
        for list in [searchList] {
            for parent in views(list).filter({ $0.accessibilityIdentifier() == "shopGameRow" }) {
                precondition(!views(parent).contains { $0.accessibilityIdentifier() == "shopLowest" }, "No Lowest tag on the game row")
            }
        }
        // Ratings: each kind in its own column; a missing rating leaves its cell empty instead of sliding the others over.
        selectShopTab(1)
        spin()
        window.contentView!.layoutSubtreeIfNeeded()
        let dealRows = views(dealsList).compactMap { $0 as? ClickableRowView }
        for id in ["shopRatingSteam", "shopRatingMetacritic", "shopRatingDeal"] {
            let cells = dealRows.map { row in views(row).first { $0.accessibilityIdentifier() == id }! }
            let xs = Set(cells.map { Int(($0.convert($0.bounds, to: dealsList).minX * 2).rounded()) })
            precondition(xs.count == 1, "\(id) lines up in every row: \(xs)")
        }
        func cellText(_ row: NSView, _ id: String) -> String? {
            views(views(row).first { $0.accessibilityIdentifier() == id }!).compactMap { $0 as? NSTextField }.first?.stringValue
        }
        let skyrim = dealRows.first { $0.accessibilityLabel()!.contains("Skyrim") }!
        let critics = dealRows.first { $0.accessibilityLabel()!.contains("Critics Pick") }!
        precondition(cellText(skyrim, "shopRatingSteam") == "85%" && cellText(skyrim, "shopRatingMetacritic") == nil &&
                     cellText(skyrim, "shopRatingDeal") == "7.2", "Skyrim: Steam and deal rating, no Metacritic")
        precondition(cellText(critics, "shopRatingSteam") == nil && cellText(critics, "shopRatingMetacritic") == "71" &&
                     cellText(critics, "shopRatingDeal") == nil, "Critics Pick: Metacritic only, in the Metacritic column")
        precondition(views(skyrim).first { $0.accessibilityIdentifier() == "shopRatingSteam" }!.toolTip == "Steam reviews: Very Positive (85%)")
        smokeCaptureShop()
        smokeCapturePages()
        // Every tab fits the narrowest window.
        let savedFrame = window.frame
        window.setContentSize(window.contentMinSize)
        for tab in 0..<5 {
            selectShopTab(tab)
            spin()
            window.contentView!.layoutSubtreeIfNeeded()
            let page = shopPageView!
            for row in views(page).compactMap({ $0 as? ClickableRowView }) where !row.isHiddenOrHasHiddenAncestor {
                let frame = row.convert(row.bounds, to: page)
                precondition(frame.minX >= -0.5 && frame.maxX <= page.bounds.width + 0.5, "Shop rows stay inside the page on tab \(tab)")
            }
            precondition(shopNav.convert(shopNav.bounds, to: page).maxX <= (shopScopeBar.isHidden ? dealsRefreshButton : shopScope).convert(NSPoint.zero, to: page).x + 0.5, "The Shop sections and store scope fit the narrowest window")
            // Right end of each row: price over usual price, discount over store, in fixed columns that line up row to row.
            var priceX: [String: (shape: String, price: CGFloat)] = [:]
            for row in views(page).compactMap({ $0 as? ClickableRowView }) where !row.isHiddenOrHasHiddenAncestor {
                guard let cluster = views(row).first(where: { $0.accessibilityIdentifier() == "shopPriceCluster" }) else { continue }
                func frame(_ id: String) -> NSRect? { views(cluster).first { $0.accessibilityIdentifier() == id }.map { $0.convert($0.bounds, to: row) } }
                precondition(frame("shopHeartColumn") == nil && frame("shopMarkerColumn") == nil, "Hearts and tags sit by the title, not in the price grid")
                let priceFrame = frame("shopPriceColumn")!
                precondition(frame("shopPercentColumn") == nil, "The discount sits with the store, not in its own column")
                precondition(abs(priceFrame.maxX - (row.bounds.maxX - 6)) < 1, "The price block ends at the row's edge on tab \(tab): \(priceFrame) \(row.bounds)")
                if let line = frame("shopPriceLine"), let tag = frame("shopStoreTag") {
                    precondition(abs(line.maxX - priceFrame.maxX) < 0.5 && abs(tag.maxX - priceFrame.maxX) < 0.5
                                 && (row.isFlipped ? tag.minY >= line.maxY - 0.5 : tag.maxY <= line.minY + 0.5)
                                 && tag.minX >= priceFrame.minX - 0.5 && line.width < priceFrame.width && tag.width < priceFrame.width,
                                 "Price on top, store under it, both right-aligned and inside the block on tab \(tab): \(line) \(tag) \(priceFrame)")
                }
                precondition(views(row).contains { ["shopArtwork", "shopStoreIcon", "shopSaleTag"].contains($0.accessibilityIdentifier()) }, "Every shop row has art or its store icon on tab \(tab)")
                // Every row of a list reserves the same columns, so heart, price and discount sit at one x each.
                let list = "\(ObjectIdentifier(row.superview!))"
                let shape = frame("shopRatingSteam") == nil ? "" : "ratings"
                let x = priceFrame.minX + row.convert(NSPoint.zero, to: page).x
                if let other = priceX[list] {
                    precondition(other.shape == shape && abs(other.price - x) < 0.5,
                                 "Columns line up on tab \(tab): \(other) vs \((shape, x)) \(row.accessibilityLabel() ?? "")")
                } else { priceX[list] = (shape, x) }
                // Fixed widths: a long converted price or a 100% discount never widens its column.
                precondition(abs(priceFrame.width - Self.shopOfferWidth) < 0.5)
                // A deal's usual price sits beside the sale price on the same line, struck through.
                if let was = views(cluster).first(where: { $0.accessibilityIdentifier() == "shopWasPrice" }) as? NSTextField,
                   let now = was.superview?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0 !== was }) {
                    let wasFrame = was.convert(was.bounds, to: row), nowFrame = now.convert(now.bounds, to: row)
                    precondition(nowFrame.maxX <= wasFrame.minX + 0.5 && abs(wasFrame.midY - nowFrame.midY) < 4 &&
                                 was.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil,
                                 "Usual price beside the price on tab \(tab): \(wasFrame) vs \(nowFrame)")
                }
            }
        }
        window.setFrame(savedFrame, display: false)
    }

    /// Screenshots of every Shop tab in Original, USD and HUF at the narrowest and a roomy window, for visual review.
    /// Only when COUCH_CUBE_SMOKE_CAPTURE names a folder.
    func smokeCaptureShop() {
        guard let folder = ProcessInfo.processInfo.environment["COUCH_CUBE_SMOKE_CAPTURE"] else { return }
        let defaults = UserDefaults.standard
        let savedFrame = window.frame, savedCurrency = defaults.object(forKey: shopCurrencyKey)
        let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        for currency in ["original", "USD", "HUF"] {
            defaults.set(currency, forKey: shopCurrencyKey)
            updateCurrencyNotes()
            rerenderShop()
            for (sizeName, size) in [("min", window.contentMinSize), ("wide", NSSize(width: 1240, height: 860))] {
                window.setContentSize(size)
                for (tab, name) in ["home", "deals", "free", "search", "wishlist"].enumerated() {
                    selectShopTab(tab)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    let view = window.contentView!
                    view.layoutSubtreeIfNeeded()
                    for bottom in tab == 0 ? [false, true] : [false] {
                    if let scroll = shopPageView?.enclosingScrollView {
                        let end = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom ? end : 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    let name = bottom ? name + "-bottom" : name
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        // cacheDisplay skips the window's own background; paint it behind so dark mode reads as on screen.
                        let image = NSImage(size: view.bounds.size)
                        image.lockFocus()
                        NSColor.windowBackgroundColor.setFill()
                        view.bounds.fill()
                        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        image.unlockFocus()
                        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
                        let file = URL(fileURLWithPath: folder).appendingPathComponent("shop-\(appearance)-\(sizeName)-\(currency)-\(tab)-\(name).png")
                        try? out.representation(using: .png, properties: [:])?.write(to: file)
                    }
                    }
                }
            }
        }
        if let savedCurrency { defaults.set(savedCurrency, forKey: shopCurrencyKey) } else { defaults.removeObject(forKey: shopCurrencyKey) }
        rerenderShop()
        window.setFrame(savedFrame, display: false)
    }

    /// With COUCH_CUBE_SMOKE_CAPTURE set, saves every sidebar page (top and bottom) as PNG for design review.
    func smokeCapturePages() {
        guard let folder = ProcessInfo.processInfo.environment["COUCH_CUBE_SMOKE_CAPTURE"] else { return }
        let savedFrame = window.frame, savedPage = currentPage
        let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        window.setContentSize(NSSize(width: 1240, height: 860))
        func icon(_ id: String) -> NSImage? { NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("AppIcons/\(id).png")) }
        func sample(_ title: String, _ subtitle: String, _ section: LauncherSection, _ iconID: String) -> LauncherItem {
            LauncherItem(id: title, title: title, subtitle: subtitle, section: section, artwork: icon(iconID),
                         wideArtwork: false, path: nil, launch: {})
        }
        launcherSmokeItems = ["Overcooked! 2", "Pummel Party", "LEGO Party", "Runbow", "Rocket League"].map { sample($0, "Steam", .steam, "steam") } +
            [sample("Battle.net", "Windows · CrossOver", .windows, "battle-net"),
             sample("Epic Games Launcher", "Epic Games for Mac", .launchers, "epic-games"),
             sample("GOG Galaxy", "GOG games for Mac", .launchers, "gog-galaxy"),
             sample("ES-DE", "Retro game TV menu", .retro, "es-de"),
             sample("Dolphin", "GameCube · Wii", .retro, "dolphin"),
             sample("Nintendo Switch", "Switch emulator", .retro, "switch")]
        renderLauncher()
        defer { launcherSmokeItems = nil; renderLauncher() }
        for page in sidebarPages where page >= 0 {
            selectPage(page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            let scroll = tabs.tabViewItems[page].view as? NSScrollView
            let end = max(0, (scroll?.documentView?.bounds.height ?? 0) - (scroll?.contentView.bounds.height ?? 0))
            for (part, y) in end > 0 ? [("top", 0.0), ("bottom", end)] : [("top", 0.0)] {
                if let scroll {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let image = NSImage(size: view.bounds.size)
                    image.lockFocus()
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                    rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    image.unlockFocus()
                    guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
                    let title = screenTitle.stringValue.lowercased().replacingOccurrences(of: " ", with: "-")
                    let file = URL(fileURLWithPath: folder).appendingPathComponent("page-\(appearance)-\(page)-\(title)-\(part).png")
                    try? out.representation(using: .png, properties: [:])?.write(to: file)
                }
            }
            scroll?.contentView.scroll(to: .zero)
        }
        selectPage(savedPage)
        window.setFrame(savedFrame, display: false)
    }

    func smokeTestDealReminders(opened: () -> [URL]) {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Budapest")!
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        // Parsing: GamerPower times are read as UTC; date-only means the end of that UTC day; N/A has no badge.
        let utc = DealExpiry.parseGamerPowerEnd("2026-10-24 23:59:59")!
        precondition(utc.timeIntervalSince1970 == 1_792_886_399)
        precondition(DealExpiry.parseGamerPowerEnd("2026-10-24")! == utc)
        precondition(DealExpiry.parseGamerPowerEnd("N/A") == nil && DealExpiry.parseGamerPowerEnd("2026-13-01") == nil &&
                     DealExpiry.parseGamerPowerEnd(nil) == nil)
        // Expiry text by local calendar day; urgent within two days; nothing once ended.
        let now = local(2026, 6, 10, 12)
        func label(_ end: Date) -> String? { DealExpiry.label(until: end, now: now, calendar: calendar).map { $0.text + ($0.urgent ? "!" : "") } }
        precondition(label(local(2026, 6, 10, 20)) == "Offer ends today!" && label(local(2026, 6, 11, 1)) == "Offer ends tomorrow!" &&
                     label(local(2026, 6, 12, 9)) == "Offer ends 12 June!" && label(local(2026, 6, 13, 20)) == "Offer ends 13 June" &&
                     label(local(2027, 1, 2, 9)) == "Offer ends 2 January 2027" &&
                     label(local(2026, 6, 10, 11)) == nil)
        // Reminder: 09:00 the day before; else 09:00 today if ahead; else a few minutes from now; never after the end.
        func remind(_ end: Date, _ at: Date) -> (Date, Bool)? {
            DealExpiry.reminderDate(for: end, now: at, calendar: calendar).map { ($0.date, $0.adjusted) }
        }
        precondition(remind(local(2026, 6, 13, 20), now)! == (local(2026, 6, 12, 9), false))
        precondition(remind(local(2026, 6, 11, 20), local(2026, 6, 10, 8))! == (local(2026, 6, 10, 9), false))
        precondition(remind(local(2026, 6, 11, 20), now)! == (local(2026, 6, 10, 12, 5), true))
        precondition(remind(local(2026, 6, 10, 20), local(2026, 6, 10, 8))! == (local(2026, 6, 10, 9), true))
        precondition(remind(local(2026, 6, 10, 12, 3), now) == nil && remind(local(2026, 6, 9, 12), now) == nil)
        // Across daylight-saving changes the alarm stays at 09:00 local time.
        for end in [local(2026, 3, 30, 12), local(2026, 10, 26, 12)] {
            let due = remind(end, local(2026, 3, 1, 12))!.0
            precondition(calendar.component(.hour, from: due) == 9 && calendar.component(.minute, from: due) == 0 &&
                         calendar.dateComponents([.day], from: due, to: end).day == 1)
        }
        // Badge flow with a mock Reminders store: nothing touches the user's real Reminders.
        final class MockReminders: DealReminderStore {
            var access = ReminderAccess.denied
            var grant = true
            var requests = 0
            var items: [String: (title: String, notes: String, url: URL?, due: Date)] = [:]
            func requestAccess(_ done: @escaping (Bool) -> Void) { requests += 1; access = grant ? .granted : .denied; done(grant) }
            func add(title: String, notes: String, url: URL?, due: Date) throws -> String {
                let id = "mock-\(items.count + 1)"
                items[id] = (title, notes, url, due)
                return id
            }
            func exists(_ identifier: String) -> Bool { items[identifier] != nil }
            func remove(_ identifier: String) throws { items[identifier] = nil }
        }
        let mock = MockReminders()
        let savedStore = reminderStore, savedReminders = dealReminders, savedConfirm = confirmReminderRemoval
        var confirm = false
        reminderStore = mock
        confirmReminderRemoval = { _ in confirm }
        dealReminders = [:]
        defer {
            reminderStore = savedStore
            confirmReminderRemoval = savedConfirm
            dealReminders = savedReminders
            dealsReminderBar.isHidden = true
        }
        renderDeals()
        func badge() -> NSButton { views(dealsList).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "dealReminder" }! }
        precondition(badge().title.hasPrefix("Offer ends ") && badge().accessibilityLabel()!.hasPrefix("Remind me the day before this deal ends"))
        precondition(badge().superview?.superview?.accessibilityIdentifier() == "shopPriceColumn" && badge().superview?.superview?.subviews.last === badge().superview,
                     "The offer's end date sits right under its price block")
        let row = views(dealsList).compactMap { $0 as? ClickableRowView }.first!
        dealsList.window?.layoutIfNeeded()
        row.layoutSubtreeIfNeeded()
        let point = badge().convert(NSPoint(x: badge().bounds.midX, y: badge().bounds.midY), to: row.superview)
        precondition(row.hitTest(point) === badge(), "The reminder badge is its own control inside the clickable row")
        let opens = opened().count
        badge().performClick(nil)
        precondition(opened().count == opens, "Clicking the badge never opens the deal")
        precondition(!dealsReminderBar.isHidden && !dealsReminderSettings.isHidden && mock.items.isEmpty, "Denied access explains and offers Settings")
        dealsReminderSettings.performClick(nil)
        precondition(opened().last?.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") == true)
        mock.access = .notDetermined
        badge().performClick(nil)
        precondition(mock.requests == 1 && mock.items.count == 1 && badge().title.hasPrefix("Offer ends ") && badge().toolTip!.contains("reminder is set"))
        let item = mock.items["mock-1"]!
        precondition(item.title == "Free Adventure deal ends \u{2014} Epic Games Store" && item.url?.host == "www.gamerpower.com" &&
                     item.notes.contains("usually $19.99") && item.notes.contains("read as UTC") && item.notes.contains("free-adventure"))
        precondition(dealReminders == ["giveaway:1": "mock-1"] && dealsReminderSettings.isHidden)
        // No duplicates: a second add for the same giveaway does nothing; a second click offers removal.
        addDealReminder(giveaways[0], end: DealExpiry.parseGamerPowerEnd(giveaways[0].endDate)!, button: badge())
        badge().performClick(nil)
        precondition(mock.items.count == 1 && badge().title.hasPrefix("Offer ends ") && badge().toolTip!.contains("reminder is set"), "Cancelled removal keeps the reminder")
        confirm = true
        badge().performClick(nil)
        precondition(mock.items.isEmpty && dealReminders.isEmpty && badge().title.hasPrefix("Offer ends "))
        // A reminder deleted in Reminders resets the badge on the next render.
        badge().performClick(nil)
        precondition(mock.requests == 1 && dealReminders.count == 1)
        mock.items.removeAll()
        renderDeals()
        precondition(dealReminders.isEmpty && badge().title.hasPrefix("Offer ends "))
    }

    func assertSmokePageScrolls() {
        window.contentView!.layoutSubtreeIfNeeded()
        let scroll = tabs.selectedTabViewItem!.view as! NSScrollView
        let document = scroll.documentView!
        precondition(document.bounds.height >= document.subviews.first!.fittingSize.height,
                     "Every settings page must scroll to its last control")
    }
}
