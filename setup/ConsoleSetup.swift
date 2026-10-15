import AppKit
import UniformTypeIdentifiers

struct Drive: Decodable {
    let id: String
    let mode: String
    let name: String
    let root: String
    let filesystem: String
    let free: Int64
    let mount: String
}

struct Assessment: Decodable {
    let state: String
    let issues: [String]
    let notes: [String]
    let missing: [String]
}

struct PhysicalDisk: Decodable {
    let device: String
    let model: String
    let size: Int64
}

struct ErasePlan: Decodable {
    let device: String
    let model: String
    let size: Int64
    let token: String
}

struct UpdateReport: Decodable {
    let version: String
    let available: Bool
    let url: String
}

struct AutoLaunchSettings: Decodable {
    let enabled: Bool
    let delay: Int
    let legacy: Bool
}

final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

typealias SetupActionButton = NSButton

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var mainWindow: NSWindow!
    private var setupWindow: NSWindow!
    private let detail = NSView()
    private let mainDetail = NSView()
    private let sidebar = NSTableView()
    private let sidebarPages = [0, 6, 1, 2]
    private let sidebarTitles = ["Play", "Game library", "Apps", "Settings"]
    private let sidebarSymbols = ["play.fill", "square.stack", "gamecontroller", "gearshape"]
    private let volumeMenu = NSPopUpButton()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    private let libraryTitle = NSTextField(labelWithString: "Choose your game drive")
    private let libraryDescription = NSTextField(wrappingLabelWithString: "Connect an SSD, or use this Mac's internal storage.")
    private let libraryAction = SetupActionButton()
    private var playAction: NSButton!
    private let setupSummary = NSTextField(wrappingLabelWithString: "Checking your setup...")
    private let steamStorageAdvice = NSTextField(wrappingLabelWithString: "")
    private let retroAdvice = NSTextField(wrappingLabelWithString: "")
    private let hostSummary = NSTextField(wrappingLabelWithString: "Checking this Mac...")
    private let tabs = NSTabView()
    private let modeLabel = NSTextField(labelWithString: "PORTABLE MANAGER")
    private let log = NSTextView()
    private let progress = NSProgressIndicator()
    private var actions: [NSControl] = []
    private var packages: [(String, NSButton)] = []
    private var volumes: [Drive] = []
    private var availableVolumes: [Drive] = []
    private var task: Process?
    private let backend: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts/console.py")
    private var refreshPending = false
    private var disks: [PhysicalDisk] = []
    private var logWindow: NSWindow?
    private var report: Assessment?
    private var libraryControls: [NSControl] = []
    private var packageTitles: [String: String] = [:]
    private var installedLabels: [String: NSTextField] = [:]
    private var lastError = ""
    private var smokeFinishing = false
    private let updateStatus = NSTextField(wrappingLabelWithString: "Checking for updates...")
    private let updateButton = NSButton()
    private var updateTask: Process?
    private var updateURL: URL?
    private var onboarding = true
    private var didRouteInitialLibrary = false
    private var preferredMode: String?
    private let navigationBar = NSStackView()
    private let setupBack = NSButton()
    private let journey = NSTextField(labelWithString: "")
    private let storageHeading = NSTextField(labelWithString: "Choose your game storage")
    private let storageAdvice = NSTextField(wrappingLabelWithString: "")
    private let storageNext = SetupActionButton()
    private let portablePreparation = NSStackView()
    private let selectedStorage = NSTextField(wrappingLabelWithString: "")
    private let finishAdvice = NSTextField(wrappingLabelWithString: "")
    private let playerContinue = SetupActionButton()
    private let finishButton = SetupActionButton(title: "Done", target: nil, action: nil)
    private let wizardFooter = NSStackView()
    private let wizardHeader = NSStackView()
    private var advanceAfterLibraryCheck = false
    private let preparationResult = NSTextField(wrappingLabelWithString: "")
    private var helperButton: NSButton!
    private let helperAdvice = NSTextField(wrappingLabelWithString:
        "Homebrew is needed only to install missing apps from here. Finish its Terminal installer, return here, then click Install selected apps. macOS may ask for administrator approval.")
    private var lastConsoleID: String?
    private let autoLaunchToggle = NSButton(checkboxWithTitle: "Automatic console mode on this Mac", target: nil, action: nil)
    private let autoLaunchDelay = NSTextField(string: "30")
    private let autoLaunchStatus = NSTextField(wrappingLabelWithString: "Open Settings to check automatic console mode.")
    private var autoLaunchLoaded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Couch Cube"
        window.minSize = NSSize(width: 880, height: 680)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Couch Cube", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Couch Cube", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Couch Cube Help", action: #selector(instructions), keyEquivalent: "").target = self
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)
        NSApp.mainMenu = menu
        mainWindow = window
        mainWindow.toolbar = NSToolbar(identifier: "CouchCubeToolbar")
        mainWindow.toolbarStyle = .unified
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        mainWindow.contentView!.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: mainWindow.contentView!.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: mainWindow.contentView!.trailingAnchor),
            split.topAnchor.constraint(equalTo: mainWindow.contentView!.topAnchor),
            split.bottomAnchor.constraint(equalTo: mainWindow.contentView!.bottomAnchor)
        ])
        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.addSubview(navigationBar)
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 8),
            navigationBar.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: -8),
            navigationBar.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 16),
            navigationBar.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -8),
            sidebarBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            sidebarBackground.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])
        split.addArrangedSubview(sidebarBackground)
        split.addArrangedSubview(mainDetail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setPosition(200, ofDividerAt: 0)
        setupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        setupWindow.title = "Set Up Couch Cube"
        setupWindow.minSize = NSSize(width: 680, height: 660)
        setupWindow.isReleasedWhenClosed = false
        setupWindow.delegate = self
        setupWindow.center()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--smoke-test"),
           let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
            let appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
            mainWindow.appearance = appearance
            setupWindow.appearance = appearance
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        mainDetail.addSubview(detail)
        pin(detail, to: mainDetail)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: detail.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -16)
        ])
        modeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        volumeMenu.target = self
        volumeMenu.action = #selector(selectionChanged)
        volumeMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let storageRow = row([volumeMenu, button("Refresh", #selector(refresh))])
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        actions.append(volumeMenu)
        tabs.tabViewType = .noTabsNoBorder

        libraryTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        libraryDescription.textColor = .secondaryLabelColor
        libraryAction.title = "Update game library..."
        libraryAction.target = self
        libraryAction.action = #selector(setup)
        libraryAction.bezelStyle = .rounded
        actions.append(libraryAction)
        libraryControls.append(libraryAction)
        let openGames = button("Open game folders", #selector(openFolder))
        let addGame = button("Add a game...", #selector(registerGame))
        let play = button("Open Steam Big Picture", #selector(playSteam))
        playAction = play
        libraryControls += [openGames, addGame, play]
        let playDescription = text("Open your games with Steam's controller-friendly interface.", secondary: true)
        playDescription.alignment = .center
        let library = column([
            hero("Couch Cube", subtitle: "Your games. One big screen."),
            primary(play),
            playDescription,
            card("Your setup", subtitle: "Folders, installed apps and in-app setup are separate steps.", views: [
                setupSummary,
                row([button("Apps & emulators", #selector(showPlayers)),
                     button("Steam & controller setup", #selector(showFinishing))]),
                button("Check status", #selector(checkStorage))
            ])
        ])
        library.alignment = .centerX
        addPage("Play", content: library)

        hostSummary.textColor = .secondaryLabelColor
        let appChoices = column([])
        for (id, text) in [
            ("steam", "Steam — required for the Big Picture menu"),
            ("es-de", "ES-DE — optional retro game browser"),
            ("retroarch-metal", "RetroArch — optional classic console emulator"),
            ("dolphin", "Dolphin — optional GameCube & Wii emulator"),
            ("porting-kit", "Porting Kit — optional Windows-game wrappers")
        ] {
            let checkbox = NSButton(checkboxWithTitle: text, target: nil, action: nil)
            checkbox.state = id == "steam" ? .on : .off
            packageTitles[id] = text
            packages.append((id, checkbox))
            actions.append(checkbox)
            let installed = self.text(text + "  ✓ Installed")
            installed.isHidden = true
            installedLabels[id] = installed
            appChoices.addArrangedSubview(column([checkbox, installed]))
        }
        playerContinue.title = "Next: Steam setup"
        playerContinue.target = self
        playerContinue.action = #selector(showFinishing)
        playerContinue.bezelStyle = .rounded
        actions.append(playerContinue)
        helperButton = button("Install Homebrew...", #selector(homebrew))
        helperAdvice.textColor = .secondaryLabelColor
        let apps = column([
            pageHeading("Apps & emulators", "Start with Steam. Everything else is optional."),
            card("Installed on this Mac", subtitle: "Creating your game folders did not install these apps. Existing apps are detected below.", views: [
                hostSummary, appChoices,
                primary(button("Install selected apps...", #selector(installApps)))
            ]),
            text("Retro: ES-DE browses games; RetroArch or Dolphin runs them. You still need your own games, any required BIOS, RetroArch cores and controller setup.\nWindows: Porting Kit is not Proton. Each supported game needs a working wrapper.", size: 12, secondary: true),
            helperAdvice,
            row([helperButton, button("Check Again", #selector(checkStorage))])
        ])
        addPage("Game players", content: apps)
        autoLaunchDelay.widthAnchor.constraint(equalToConstant: 64).isActive = true
        autoLaunchDelay.setAccessibilityLabel("Seconds to wait after login, from 5 to 300")
        autoLaunchStatus.textColor = .secondaryLabelColor
        actions += [autoLaunchToggle, autoLaunchDelay]
        let tools = column([
            pageHeading("Settings", "Preferences for this Mac."),
            card("Automatic console mode", subtitle:
                "Open Steam Big Picture when a controller connects, without a keyboard or mouse.", views: [
                autoLaunchToggle,
                row([text("Wait after login:"), autoLaunchDelay, text("seconds (5–300)")]),
                text("Runs once after login. Keep the app in place and its drive connected. Turn off Steam's own login startup.", size: 12, secondary: true),
                autoLaunchStatus,
                button("Save automatic console mode", #selector(saveAutoLaunch))
            ]),
            card("App updates", subtitle: "Checks GitHub at launch. Downloads and app replacement are never automatic.", views: [
                updateStatus, row([button("Check for updates", #selector(checkUpdates)), updateButton])
            ]),
            card("App location", subtitle: "Run Couch Cube from Applications or beside your library on an external SSD.", views: [
                button("Show this app in Finder", #selector(revealApp))
            ]),
            card("Keep a download copy", subtitle: "Optional: store the release DMG alongside your games. You can still run the app directly from the SSD.", views: [
                button("Copy release DMG to drive...", #selector(copyDMG))
            ])
        ])
        addPage("Settings", content: tools)
        updateButton.title = "View release..."
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.isEnabled = false
        updateButton.bezelStyle = .rounded
        addPage("Welcome", content: column([
            hero("Welcome to Couch Cube", subtitle: "Set up your Mac for Steam Big Picture and optional retro games."),
            text("1. Create game folders.\n2. Install Steam and any optional emulators.\n3. Sign in to Steam, choose game storage and connect a controller."),
            choice("This Mac", "Use this Mac's built-in storage.",
                   symbol: "desktopcomputer", action: #selector(chooseLocal)),
            choice("External SSD", "More room for games. Take your library between Macs.",
                   symbol: "externaldrive", action: #selector(choosePortable)),
            text("Nothing is installed or erased until you review and confirm.", size: 12, secondary: true)
        ]))
        storageHeading.font = .systemFont(ofSize: 24, weight: .bold)
        storageAdvice.textColor = .secondaryLabelColor
        storageNext.title = "Use this storage..."
        storageNext.target = self
        storageNext.action = #selector(continueStorage)
        storageNext.bezelStyle = .rounded
        actions.append(storageNext)
        portablePreparation.orientation = .vertical
        portablePreparation.alignment = .leading
        let prepare = card("Prepare a new SSD", subtitle:
            "Erase and format an external SSD, then copy Couch Cube onto it. You'll review the disk before anything is erased.",
            views: [button("Prepare an SSD...", #selector(prepareDisk))])
        portablePreparation.addArrangedSubview(prepare)
        prepare.widthAnchor.constraint(equalTo: portablePreparation.widthAnchor).isActive = true
        addPage("Storage", content: column([
            storageHeading, storageAdvice,
            preparationResult,
            portablePreparation,
            card("Library location", subtitle: "Choose a drive. Existing files are kept.", views: [
                storageRow, summary, modeLabel
            ])
        ]))
        preparationResult.isHidden = true
        addPage("Finish", content: column([
            pageHeading("Set up Steam", "These steps happen in Steam, not automatically in Couch Cube."),
            finishAdvice,
            card("1. Sign in & choose game storage", subtitle: nil, views: [
                steamStorageAdvice,
                row([button("Open Steam desktop", #selector(openSteamDesktop)),
                     button("Show SteamLibrary folder", #selector(showSteamFolder))])
            ]),
            card("2. Connect a controller & install a game", subtitle:
                "Pair it in macOS Bluetooth settings or connect it with USB. Steam → Settings → Controller lets you check the buttons. Retro players may need their own controller setup.",
                views: [text("Install a game from your Steam library, then open Big Picture from Play. Existing Steam games stay where they are.", size: 12, secondary: true),
                        button("Open Bluetooth settings", #selector(openBluetooth))]),
            card("Optional: retro & Windows games in Big Picture", subtitle: nil, views: [
                retroAdvice, button("Open game folders", #selector(openFolder))
            ])
        ]))
        addPage("Game library", content: column([
            pageHeading("Game library", "Couch Cube's folders, not a list of installed Steam games."),
            card("Storage", subtitle: nil, views: [
                selectedStorage, libraryTitle, libraryDescription,
                row([openGames, addGame])
            ]),
            card("Manage library", subtitle: "Updates Couch Cube's launcher paths, not Steam's storage settings. No games are moved.", views: [
                libraryAction,
                button("Check Library", #selector(checkStorage)),
                button("Change Storage…", #selector(changeStorage))
            ])
        ]))
        navigationBar.orientation = .vertical
        navigationBar.alignment = .leading
        let sidebarLabel = text("Couch Cube", size: 12, secondary: true)
        sidebarLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        navigationBar.addArrangedSubview(sidebarLabel)
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = false
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Navigation")))
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 36
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Couch Cube navigation")
        sidebarScroll.documentView = sidebar
        navigationBar.addArrangedSubview(sidebarScroll)
        sidebarScroll.widthAnchor.constraint(equalTo: navigationBar.widthAnchor).isActive = true
        sidebarScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        journey.font = .systemFont(ofSize: 12, weight: .medium)
        journey.textColor = .secondaryLabelColor
        setupBack.target = self
        setupBack.action = #selector(goBack)
        setupBack.isBordered = false
        setupBack.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        setupBack.imagePosition = .imageLeading
        setupBack.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        setupBack.font = .systemFont(ofSize: 14, weight: .medium)
        setupBack.contentTintColor = .controlAccentColor
        setupBack.heightAnchor.constraint(equalToConstant: 32).isActive = true
        actions.append(setupBack)
        wizardHeader.orientation = .horizontal
        wizardHeader.alignment = .centerY
        wizardHeader.spacing = 16
        wizardHeader.addArrangedSubview(setupBack)
        wizardHeader.addArrangedSubview(journey)
        stack.addArrangedSubview(wizardHeader)
        stack.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        wizardFooter.orientation = .horizontal
        wizardFooter.spacing = 12
        [NSView(), primary(storageNext), primary(playerContinue), primary(finishButton)]
            .forEach { wizardFooter.addArrangedSubview($0) }
        finishButton.target = self
        finishButton.action = #selector(finishOnboarding)
        actions.append(finishButton)
        stack.addArrangedSubview(wizardFooter)
        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let details = button("Details...", #selector(showActivity))
        let help = button("Help", #selector(instructions))
        details.isBordered = false
        help.isBordered = false
        let statusRow = row([progress, status, details, help])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(statusRow)
        log.isEditable = false
        log.isSelectable = true
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textColor = .textColor
        log.backgroundColor = .textBackgroundColor
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        for view in stack.arrangedSubviews where view !== tabs {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        selectPage(3)
        mainWindow.center()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(disksChanged), name: name, object: nil)
        }
        refresh()
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            updateStatus.stringValue = "Startup network check skipped for read-only verification."
        } else {
            checkUpdates()
        }
    }

    @objc private func checkUpdates() {
        guard updateTask == nil else { return }
        updateStatus.stringValue = "Checking GitHub for the latest portable release..."
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path, "update-check"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        updateTask = process
        do {
            try process.run()
        } catch {
            updateTask = nil
            updateStatus.stringValue = "Couldn't check for updates: \(error.localizedDescription)"
            return
        }
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                self.updateTask = nil
                guard process.terminationStatus == 0 else {
                    self.updateStatus.stringValue = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                do {
                    let report = try JSONDecoder().decode(UpdateReport.self, from: data)
                    self.updateStatus.stringValue = report.available
                        ? "Couch Cube \(report.version) is available. Download it and replace the app after quitting."
                        : "You're up to date. Latest published release: \(report.version)."
                    self.updateURL = URL(string: report.url)
                    self.updateButton.isEnabled = self.updateURL != nil
                    if report.available {
                        self.status.stringValue = "App update available. Open Settings to view the release."
                    }
                } catch {
                    self.updateStatus.stringValue = "Couldn't read GitHub update information: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func openUpdate() {
        if let url = updateURL { NSWorkspace.shared.open(url) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didRouteInitialLibrary, task == nil, NSApp.modalWindow == nil,
              [0, 1, 5].contains(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!)),
              !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        checkStorage()
    }

    private func pageHeading(_ title: String, _ subtitle: String) -> NSStackView {
        let heading = text(title, size: 28)
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        return column([heading, text(subtitle, size: 15, secondary: true)])
    }

    private func primary(_ button: NSButton) -> NSButton {
        button.bezelStyle = .rounded
        button.isBordered = true
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    private func choice(_ title: String, _ description: String, symbol: String, action: Selector) -> NSView {
        let choose = button(title, action)
        choose.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        choose.imagePosition = .imageLeading
        choose.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        choose.controlSize = .large
        choose.setAccessibilityLabel(title + ". " + description.replacingOccurrences(of: "\n", with: " "))
        return card("", subtitle: nil, views: [choose, text(description, secondary: true)])
    }

    @objc private func chooseLocal() { chooseMode("local") }
    @objc private func choosePortable() { chooseMode("portable") }

    private func chooseMode(_ mode: String) {
        guard task == nil else { return }
        preferredMode = mode
        didRouteInitialLibrary = true
        preparationResult.isHidden = true
        populateVolumes(previous: nil)
        selectPage(4)
        selectionChanged()
    }

    private func populateVolumes(previous: String?) {
        volumes = availableVolumes.filter { preferredMode == nil || $0.mode == preferredMode }
        volumeMenu.removeAllItems()
        volumeMenu.addItems(withTitles: volumes.map { $0.name })
        if let previous = previous {
            if let index = volumes.firstIndex(where: { $0.id == previous }) {
                volumeMenu.selectItem(at: index)
            } else {
                volumeMenu.select(nil)
            }
        } else if let index = volumes.firstIndex(where: {
            $0.mode == "portable" && Bundle.main.bundleURL.path.hasPrefix($0.mount + "/")
        }) {
            volumeMenu.selectItem(at: index)
        }
        let portable = preferredMode == "portable"
        storageHeading.stringValue = portable ? "Let's get your SSD ready." : "Your Mac. Your console."
        storageAdvice.stringValue = portable
            ? "Create Couch Cube's game folders on this SSD. Steam storage is connected manually in step 3. Preparing an SSD is optional and erases it."
            : "Create Couch Cube's folders on this Mac. Steam can keep using its current library. No apps are installed and no Steam games are moved in this step."
        portablePreparation.isHidden = !portable
    }

    @objc private func backToChoices() {
        selectPage(3)
    }

    @objc private func goBack() {
        switch tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) {
        case 4: backToChoices()
        case 1: backFromPlayers()
        case 5:
            if onboarding { showPlayers() } else { selectPage(0) }
        case 3: cancelSetup()
        default: break
        }
    }

    @objc private func changeStorage() {
        onboarding = true
        if report?.state == "valid layout", report?.issues.isEmpty == true {
            lastConsoleID = selected?.id
        }
        selectPage(3)
    }

    @objc private func cancelSetup() {
        guard let id = lastConsoleID, task == nil else { return }
        preferredMode = nil
        populateVolumes(previous: id)
        onboarding = false
        lastConsoleID = selected?.id
        selectPage(0)
        selectionChanged()
    }

    @objc private func continueStorage() {
        guard let report = report, report.issues.isEmpty, selected != nil else { return }
        // Refresh absolute frontend paths when an SSD moves between Macs.
        setup()
    }

    @objc private func showPlayers() { selectPage(1) }

    @objc private func backFromPlayers() {
        selectPage(onboarding ? 4 : 0)
    }

    @objc private func showFinishing() { selectPage(5) }

    private func updateSteamGuide() {
        let missing = report?.missing ?? []
        finishAdvice.stringValue = report?.issues.isEmpty != true
            ? "Your library still needs attention. Go back to storage before continuing."
            : missing.contains("steam")
            ? "Steam is not installed. Install it from Apps & emulators first. Only your game folders have been created."
            : "Steam is installed. Sign-in, storage selection and controller setup are not verified by Couch Cube."
        if let drive = selected {
            let path = (drive.root as NSString).appendingPathComponent("SteamLibrary")
            steamStorageAdvice.stringValue = (drive.mode == "local"
                ? "Sign in to Steam. You can keep its existing/default game library; no storage change is required.\n\nOptional: to use Couch Cube's folder instead, add the path below in Steam → Settings → Storage:"
                : "Sign in to Steam. To install Steam games on this SSD, add the path below in Steam → Settings → Storage and choose it when installing games:")
                + "\n\n\(path)\n\nCouch Cube does not change Steam settings or move existing games. Move games yourself in Steam → Settings → Storage if needed."
            retroAdvice.stringValue = "In Steam desktop → Games → Add a Non-Steam Game → Browse, add:\n\(drive.root)/Launchers/Retro.app\n\nRequires ES-DE plus the appropriate emulator, games and any required BIOS/cores. For registered native or Windows-wrapper games, add their .app shortcuts from Launchers too. These shortcuts are not added to Steam automatically."
        }
        finishButton.title = "Return to Play"
    }

    @objc private func finishOnboarding() {
        guard report?.state == "valid layout", report?.issues.isEmpty == true else {
            status.stringValue = "Choose storage and create your game library first."
            selectPage(4)
            return
        }
        onboarding = false
        lastConsoleID = selected?.id
        selectPage(0)
    }

    @objc private func openBluetooth() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    @objc private func openSteamDesktop() {
        guard report?.missing.contains("steam") == false else {
            status.stringValue = "Install Steam from Apps & emulators, then return to Steam setup."
            showPlayers()
            return
        }
        if !NSWorkspace.shared.open(URL(string: "steam://open/main")!) {
            status.stringValue = "Couldn't open Steam. Check its installation in Apps & emulators."
        }
    }

    @objc private func showSteamFolder() {
        guard let drive = selected else { return }
        let folder = URL(fileURLWithPath: drive.root).appendingPathComponent("SteamLibrary")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            status.stringValue = "Create your game folders in Game library before connecting Steam storage."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func updateSetupSummary() {
        guard let report = report, let drive = selected else {
            setupSummary.stringValue = "Choose connected storage to check your folders and installed apps."
            playAction.isEnabled = false
            return
        }
        let foldersReady = report.state == "valid layout" && report.issues.isEmpty
        let steamInstalled = !report.missing.contains("steam")
        setupSummary.stringValue = "1. Game folders: \(foldersReady ? "Created" : "Needs setup")\n"
            + "\(drive.root)\n\n"
            + "2. Steam: \(steamInstalled ? "Installed" : "Not installed — open Apps & emulators")\n"
            + "Optional apps: \(packages.filter { $0.0 != "steam" && !report.missing.contains($0.0) }.count) of 4 installed. Not required for Steam games.\n\n"
            + "3. In Steam: sign in, install a game and check your controller.\n"
            + (drive.mode == "local"
                ? "Keep Steam's current storage, or choose another folder yourself."
                : "Add this SSD's SteamLibrary in Steam → Settings → Storage to use it.")
            + "\nManual steps are not verified. Couch Cube does not move Steam games."
        playAction.isEnabled = task == nil && foldersReady && steamInstalled
    }

    private func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func pin(_ view: NSView, to host: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func hero(_ title: String, subtitle: String) -> NSStackView {
        let image = NSImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Console.icns"))!)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 88).isActive = true
        image.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let images = row([NSView(), image, NSView()])
        images.arrangedSubviews[0].widthAnchor.constraint(equalTo: images.arrangedSubviews[2].widthAnchor).isActive = true
        let heading = text(title, size: 28)
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.alignment = .center
        let caption = text(subtitle, size: 14, secondary: true)
        caption.alignment = .center
        let result = column([images, heading, caption])
        result.spacing = 16
        return result
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        for view in views {
            if view is NSButton {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            } else {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func card(_ title: String, subtitle: String?, views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        let heading = text(title, size: 15)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        var contents: [NSView] = title.isEmpty ? [] : [heading]
        if let subtitle = subtitle { contents.append(text(subtitle, size: 12, secondary: true)) }
        contents += views
        let stack = column(contents)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -16)
        ])
        return box
    }

    private func addPage(_ title: String, content: NSStackView) {
        let page = NSTabViewItem(identifier: title)
        page.label = title
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let container = TopAlignedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        let width = content.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -16)
        width.priority = .defaultHigh
        width.isActive = true
        page.view = scroll
        tabs.addTabViewItem(page)
    }

    private func selectPage(_ index: Int) {
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        if index == 5 { updateSteamGuide() }
        tabs.selectTabViewItem(at: index)
        let inWizard = onboarding || index == 3 || index == 4 || index == 5
        navigationBar.isHidden = inWizard
        let destination = inWizard ? setupWindow.contentView! : mainDetail
        if detail.superview !== destination {
            detail.removeFromSuperview()
            destination.addSubview(detail)
            pin(detail, to: destination)
        }
        let nextWindow = inWizard ? setupWindow! : mainWindow!
        if window !== nextWindow {
            window.orderOut(nil)
            window = nextWindow
            window.makeKeyAndOrderFront(nil)
        }
        mainWindow.title = index == 0 ? "Couch Cube" : (sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube")
        wizardHeader.isHidden = !inWizard
        wizardFooter.isHidden = !inWizard || index == 3
        storageNext.isHidden = index != 4
        finishButton.isHidden = index != 5
        finishButton.keyEquivalent = index == 5 ? "\r" : ""
        setupBack.isHidden = ![4, 5].contains(index) && !(index == 1 && onboarding)
            && !(index == 3 && lastConsoleID != nil)
        switch index {
        case 4: setupBack.title = "Setup"
        case 1: setupBack.title = "Storage"
        case 5: setupBack.title = onboarding ? "Apps & emulators" : "Play"
        default: setupBack.title = "My console"
        }
        setupBack.setAccessibilityLabel("Back to " + setupBack.title)
        playerContinue.isHidden = !onboarding || index != 1
        journey.isHidden = !onboarding || index == 3
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playAction.keyEquivalent = index == 0 ? "\r" : ""
        playerContinue.keyEquivalent = index == 1 && onboarding ? "\r" : ""
        switch index {
        case 3: journey.stringValue = ""
        case 4: journey.stringValue = "STEP 1 OF 3  ·  YOUR STORAGE"
        case 1: journey.stringValue = "STEP 2 OF 3  ·  INSTALL APPS"
        case 5: journey.stringValue = "STEP 3 OF 3  ·  STEAM SETUP"
        default: journey.stringValue = ""
        }
        if !inWizard, let selected = sidebarPages.firstIndex(of: index), sidebar.selectedRow != selected {
            sidebar.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTitles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: sidebarTitles[row])
        let image = NSImageView(image: NSImage(systemSymbolName: sidebarSymbols[row], accessibilityDescription: nil)!)
        image.contentTintColor = .controlAccentColor
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let cell = NSTableCellView()
        cell.textField = label
        cell.imageView = image
        let contents = self.row([image, label])
        contents.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(contents)
        pin(contents, to: cell)
        cell.setAccessibilityLabel(sidebarTitles[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { task == nil }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard sidebarPages.indices.contains(sidebar.selectedRow), !onboarding else { return }
        let page = sidebarPages[sidebar.selectedRow]
        guard tabs.selectedTabViewItem !== tabs.tabViewItems[page] else { return }
        selectPage(page)
        if page == 2 { loadAutoLaunch() }
    }

    @objc private func openSettings() {
        guard !onboarding, task == nil else {
            status.stringValue = "Finish the current setup before opening Settings."
            return
        }
        selectPage(2)
        loadAutoLaunch()
    }

    private func loadAutoLaunch() {
        autoLaunchLoaded = false
        execute(["login-status"], capture: true) { code, data in
            guard code == 0 else {
                self.autoLaunchStatus.stringValue = "Cannot read login settings. Open Details for the error."
                self.showActivity()
                return
            }
            do {
                let settings = try JSONDecoder().decode(AutoLaunchSettings.self, from: data)
                self.autoLaunchToggle.state = settings.enabled ? .on : .off
                self.autoLaunchDelay.stringValue = String(settings.delay)
                self.autoLaunchLoaded = true
                self.autoLaunchStatus.stringValue = settings.legacy
                    ? "An older always-on Steam login launcher is installed. Save to replace it with controller-aware console mode."
                    : settings.enabled ? "Enabled for the next login on this Mac." : "Off. Nothing starts automatically."
            } catch {
                self.autoLaunchStatus.stringValue = "Cannot read login settings: \(error.localizedDescription)"
                self.append(self.autoLaunchStatus.stringValue + "\n")
                self.showActivity()
            }
        }
    }

    @objc private func saveAutoLaunch() {
        guard autoLaunchLoaded else {
            autoLaunchStatus.stringValue = "Login settings haven't loaded. Reopen Settings to try again."
            return
        }
        let enabled = autoLaunchToggle.state == .on
        guard let delay = Int(autoLaunchDelay.stringValue), (5...300).contains(delay) else {
            autoLaunchStatus.stringValue = "Enter a whole number between 5 and 300 seconds."
            return
        }
        let alert = NSAlert()
        alert.messageText = enabled ? "Enable automatic console mode on this Mac?" : "Turn off automatic console mode?"
        alert.informativeText = enabled
            ? "Starting at your next macOS login, wait \(delay) seconds. If no keyboard or mouse is connected, wait for a controller and open Steam Big Picture once.\n\nNo passwords or automatic macOS login are configured. Keep Couch Cube at:\n\(Bundle.main.bundleURL.path)\n\nIf you move or replace the app, save this setting again. macOS may manage this under Login Items."
            : "Stops this app's waiting login helper and removes its login entry. Steam and your game library are unchanged."
        alert.addButton(withTitle: enabled ? "Enable" : "Turn off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var arguments = ["login", "--confirm", "--delay", String(delay)]
        if !enabled { arguments.append("--disable") }
        execute(arguments) { code, _ in
            if code == 0 { self.loadAutoLaunch() }
            else {
                self.autoLaunchStatus.stringValue = "Couldn't save console mode. Open Details for the error."
                self.showActivity()
            }
        }
    }

    @objc private func showActivity() {
        if logWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Activity"
            panel.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.documentView = log
            panel.contentView!.addSubview(scroll)
            panel.center()
            logWindow = panel
        }
        logWindow!.makeKeyAndOrderFront(nil)
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = SetupActionButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        actions.append(button)
        return button
    }

    private var selected: Drive? {
        let index = volumeMenu.indexOfSelectedItem
        return volumes.indices.contains(index) ? volumes[index] : nil
    }

    private func append(_ text: String) {
        log.textStorage?.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]))
        log.scrollToEndOfDocument(nil)
    }

    private func busy(_ value: Bool) {
        actions.forEach { $0.isEnabled = !value }
        for (id, checkbox) in packages {
            checkbox.isEnabled = !value && report?.missing.contains(id) == true
        }
        if !value && selected == nil {
            libraryControls.forEach { $0.isEnabled = false }
        }
        storageNext.isEnabled = !value && selected != nil && report?.issues.isEmpty == true
        if !value {
            [volumeMenu, storageNext].forEach { $0.needsDisplay = true }
            updateSetupSummary()
        }
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func execute(_ arguments: [String], capture: Bool = false,
                         completed: @escaping (Int32, Data) -> Void) {
        guard task == nil else { return }
        lastError = ""
        busy(true)
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        task = process
        switch arguments.first {
        case "drives", "assess": status.stringValue = "Checking your storage. Nothing is being changed."
        case "setup": status.stringValue = "Getting your library ready. Keep the drive connected."
        case "install-apps": status.stringValue = "Installing your game players. This may take a few minutes."
        case "erase": status.stringValue = "Preparing your SSD. Keep it connected until this finishes."
        default: status.stringValue = "Working on it..."
        }
        do {
            try process.run()
        } catch {
            task = nil
            busy(false)
            lastError = "Cannot start bundled runtime: \(error.localizedDescription)"
            append(lastError + "\n")
            status.stringValue = lastError
            showActivity()
            completed(1, Data())
            return
        }
        // Drain both pipes off the UI thread, including large Homebrew output.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async {
                        self.lastError += text
                        self.append(text)
                    }
            }
            group.leave()
        }
        DispatchQueue.global().async {
            var collected = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                if capture { collected.append(data) }
                else {
                    let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async { self.append(text) }
                }
            }
            process.waitUntilExit()
            group.wait()
            let result = collected
            DispatchQueue.main.async {
                self.task = nil
                self.busy(false)
                if process.terminationStatus != 0 && !capture { self.showActivity() }
                completed(process.terminationStatus, result)
                if self.refreshPending && self.task == nil {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    @objc private func refresh() {
        if task != nil { refreshPending = true; return }
        let previous = selected?.id
        execute(["drives"], capture: true) { code, data in
            self.availableVolumes = []
            if code == 0 {
                do {
                    self.availableVolumes = try JSONDecoder().decode([Drive].self, from: data)
                    self.status.stringValue = self.availableVolumes.isEmpty
                        ? "No writable supported storage found. Unlock/mount your drive and refresh."
                        : "Ready. Nothing has been changed."
                } catch {
                    self.status.stringValue = "Invalid drive information: \(error.localizedDescription)"
                }
            } else {
                self.status.stringValue = "Drive discovery failed. Open Activity for details."
                self.showActivity()
            }
            self.populateVolumes(previous: previous)
            self.selectionChanged()
            if self.selected == nil { self.finishSmokeTest(success: false) }
        }
    }

    private func finishSmokeTest(success: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test"), !smokeFinishing else { return }
        smokeFinishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let stack = self.detail.subviews.compactMap { $0 as? NSStackView }.first!
                let discoveryOK = success && !self.volumes.isEmpty && self.window.isVisible
                    && self.packages.count == 5 && self.selected != nil
                    && self.tabs.numberOfTabViewItems == 7 && self.logWindow == nil
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
                   let page = Int(args[index + 1]), (0..<7).contains(page) {
                    self.onboarding = [1, 3, 4, 5].contains(page)
                    if page == 4 {
                        self.preferredMode = "portable"
                        self.populateVolumes(previous: nil)
                        if self.selected == nil { self.selectionChanged() }
                    }
                    self.selectPage(page)
                }
                if args.contains("--smoke-flow") {
                    self.onboarding = true
                    self.selectPage(3)
                    precondition(self.navigationBar.isHidden)
                    precondition(self.window === self.setupWindow && !self.mainWindow.isVisible)
                    self.preferredMode = "portable"
                    self.populateVolumes(previous: nil)
                    self.selectPage(4)
                    precondition(!self.setupBack.isHidden && self.setupBack.title == "Setup")
                    precondition(!self.portablePreparation.isHidden)
                    precondition(self.volumes.allSatisfy { $0.mode == "portable" })
                    self.preferredMode = "local"
                    self.populateVolumes(previous: nil)
                    precondition(self.portablePreparation.isHidden)
                    precondition(self.volumes.allSatisfy { $0.mode == "local" })
                    self.showPlayers()
                    precondition(!self.playerContinue.isHidden && self.navigationBar.isHidden)
                    precondition(!self.setupBack.isHidden && self.setupBack.title == "Storage")
                    self.showFinishing()
                    precondition(!self.setupBack.isHidden && self.setupBack.title == "Apps & emulators")
                    self.goBack()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[1])
                    self.goBack()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[4])
                    self.goBack()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[3])
                    let assessment = self.report
                    self.report = nil
                    self.continueStorage()
                    precondition(self.task == nil, "No storage assessment must never start setup")
                    self.report = Assessment(state: "needs attention", issues: ["Fixture: unsupported storage"], notes: [], missing: [])
                    self.continueStorage()
                    precondition(self.task == nil, "Storage issues must never start setup")
                    self.finishOnboarding()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[4])
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: ["steam"])
                    self.finishOnboarding()
                    precondition(!self.onboarding && self.tabs.selectedTabViewItem === self.tabs.tabViewItems[0])
                    precondition(self.window === self.mainWindow && !self.setupWindow.isVisible)
                    self.selectPage(6)
                    precondition(self.sidebar.selectedRow == 1 && !self.navigationBar.isHidden)
                    self.showFinishing()
                    precondition(self.window === self.setupWindow)
                    precondition(self.setupBack.title == "Play")
                    self.goBack()
                    precondition(self.window === self.mainWindow)
                    self.report = assessment
                    self.onboarding = false
                    self.selectPage(0)
                    precondition(!self.navigationBar.isHidden)
                    precondition(self.setupBack.isHidden)
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: ["steam"])
                    self.updateSetupSummary()
                    precondition(!self.playAction.isEnabled)
                    precondition(self.setupSummary.stringValue.contains("Not installed"))
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled)
                    precondition(self.setupSummary.stringValue.contains("Manual steps are not verified"))
                    self.showFinishing()
                    precondition(self.steamStorageAdvice.stringValue.contains("Couch Cube does not change Steam settings"))
                    precondition(self.steamStorageAdvice.stringValue.contains("/SteamLibrary"))
                    self.report = assessment
                    self.updateSetupSummary()
                    self.selectPage(1)
                    precondition(self.playerContinue.isHidden)
                    self.changeStorage()
                    precondition(self.onboarding && self.navigationBar.isHidden)
                    self.preferredMode = "portable"
                    self.populateVolumes(previous: nil)
                    self.volumeMenu.select(nil)
                    self.selectionChanged()
                    precondition(!self.storageNext.isEnabled && self.report == nil)
                    precondition(self.task == nil, "Disconnected storage must not run setup")
                }
                if args.contains("--minimum-size") { self.window.setContentSize(self.window.minSize) }
                self.window.contentView!.layoutSubtreeIfNeeded()
                self.window.displayIfNeeded()
                let fits = stack.fittingSize.height <= self.detail.bounds.height - 36
                let ok = discoveryOK && fits
                precondition(self.storageNext.isBordered && self.playerContinue.isBordered && self.playAction.isBordered)
                if args.contains("--smoke-activity") {
                    self.append("Activity appearance check: storage checked. No files changed.\n")
                    self.showActivity()
                    self.logWindow!.appearance = self.window.effectiveAppearance
                    self.append("New output remains readable in the current appearance.\n")
                    let storage = self.log.textStorage!
                    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
                        precondition((attributes[.foregroundColor] as? NSColor) == NSColor.textColor)
                        precondition((attributes[.font] as? NSFont) == self.log.font)
                    }
                    self.logWindow!.contentView!.layoutSubtreeIfNeeded()
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
                print(ok ? "Native UI smoke test passed: separate setup assistant, sidebar, library, players and console; no setup executed."
                         : "Portable manager smoke test failed: \(self.status.stringValue)")
                exit(ok ? 0 : 1)
        }
    }

    @objc private func disksChanged() {
        if task != nil { refreshPending = true } else { refresh() }
    }

    @objc private func selectionChanged() {
        report = nil
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
            if !onboarding { onboarding = true; selectPage(4) }
            return
        }
        libraryControls.forEach { $0.isEnabled = true }
        let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
        modeLabel.stringValue = drive.mode == "local" ? "LOCAL CONSOLE  ·  ONLY THIS MAC" : "PORTABLE CONSOLE  ·  EXTERNAL SSD"
        summary.stringValue = "\(free) free  ·  \(drive.filesystem.uppercased())"
        summary.toolTip = drive.root
        selectedStorage.stringValue = "\(drive.name)\n\(drive.root)"
        libraryTitle.stringValue = "Checking your library..."
        libraryDescription.stringValue = "Reading the selected drive. No files will be changed."
        checkStorage()
    }

    @objc private func checkStorage() {
        guard task == nil, let drive = selected else { return }
        execute(["assess", "--drive", drive.id], capture: true) { code, data in
            guard code == 0 else {
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
                self.storageNext.title = report.state == "not prepared" ? "Create my game library..." : "Continue with this library"
                if !report.issues.isEmpty {
                    self.summary.stringValue = "This storage needs attention before we can continue. Activity has the details."
                    if drive.mode == "portable" {
                        self.summary.stringValue += "\nTry another SSD, or prepare this one below after backing up its files."
                    }
                }
                if report.state == "not prepared" {
                    self.libraryTitle.stringValue = "No library on this drive yet"
                    self.libraryDescription.stringValue = "Creates folders and launcher files only. No apps are installed, no games are moved, and Steam settings are unchanged."
                    self.libraryAction.title = "Create game library..."
                } else if report.issues.isEmpty {
                    self.libraryTitle.stringValue = "Game folders created"
                    self.libraryDescription.stringValue = report.missing.contains("steam")
                        ? "Steam is not installed. Open Apps & emulators next. Creating folders did not install any apps."
                        : "Steam is installed. Its storage settings are managed in Steam, not here. See Steam & controller setup on Play."
                    self.libraryAction.title = "Update library links..."
                } else {
                    self.libraryTitle.stringValue = "This library needs attention"
                    self.libraryDescription.stringValue = report.issues.prefix(2).joined(separator: "\n")
                    self.libraryAction.title = "Update library links..."
                }
                self.hostSummary.stringValue = report.missing.contains("steam")
                    ? "Steam is not installed. Select it below and install it to use Big Picture; other apps are optional."
                    : "Steam is installed. No other apps are needed for native Steam games. Select optional apps only if you want them."
                self.helperButton.isHidden = !report.notes.contains { $0.hasPrefix("Homebrew missing") }
                self.helperAdvice.isHidden = self.helperButton.isHidden
                for (id, checkbox) in self.packages {
                    let available = !report.missing.contains(id)
                    checkbox.title = (self.packageTitles[id] ?? id) + (available ? "  ✓ Installed" : "  · Not installed")
                    checkbox.isEnabled = !available
                    checkbox.isHidden = available
                    self.installedLabels[id]?.isHidden = !available
                    if available { checkbox.state = .off }
                }
                self.updateSetupSummary()
                if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[5] { self.showFinishing() }
                if drive.free < 20 * 1024 * 1024 * 1024 {
                    self.summary.stringValue += "\nYou're low on space. Big games may need more room."
                }
                self.status.stringValue = "Drive checked. No files changed."
                self.append("\n--- Storage assessment: \(drive.name) ---\n"
                            + (report.issues + report.notes).joined(separator: "\n") + "\n")
                if !self.didRouteInitialLibrary {
                    self.didRouteInitialLibrary = true
                    self.onboarding = report.state != "valid layout" || !report.issues.isEmpty
                    if !self.onboarding { self.lastConsoleID = drive.id }
                    self.selectPage(self.onboarding ? 3 : 0)
                }
                if self.advanceAfterLibraryCheck {
                    self.advanceAfterLibraryCheck = false
                    if report.state == "valid layout" && report.issues.isEmpty {
                        self.showPlayers()
                    } else {
                        self.status.stringValue = "Your library needs attention before continuing. Open Details for the error."
                    }
                }
                self.finishSmokeTest(success: true)
            } catch {
                self.advanceAfterLibraryCheck = false
                self.status.stringValue = "Cannot read assessment: \(error.localizedDescription)"
                self.finishSmokeTest(success: false)
            }
        }
    }

    @objc private func installApps() {
        let installs = packages.filter { $0.1.state == .on && report?.missing.contains($0.0) == true }.map { $0.0 }
        guard !installs.isEmpty else {
            status.stringValue = "Select at least one app above. Nothing will be installed until you confirm."
            return
        }
        if report?.notes.contains(where: { $0.hasPrefix("Homebrew missing") }) == true {
            homebrew()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install apps on this Mac?"
        alert.informativeText = installs.map { packageTitles[$0] ?? $0 }.joined(separator: "\n")
            + "\n\nThis uses Homebrew. It does not install the manager, modify your game drive or sign in to any account."
        alert.addButton(withTitle: "Install selected apps")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["install-apps", "--confirm", "--packages"] + installs) { code, _ in
            if code == 0 {
                self.packages.forEach { $0.1.state = .off }
                self.status.stringValue = "Selected apps installed. Steam sign-in, game downloads and controller setup are still manual."
                self.checkStorage()
            } else {
                self.status.stringValue = "An app couldn't be installed. Activity shows what to do next."
            }
        }
    }

    @objc private func playSteam() {
        guard let drive = selected else { return }
        execute(["steam", "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "Steam Big Picture opened." : "Couldn't open Steam. Check Apps & emulators and Activity."
        }
    }

    @objc private func homebrew() {
        let alert = NSAlert()
        alert.messageText = "Set up the app download helper?"
        alert.informativeText = "Couch Cube uses Homebrew, a free tool that installs your game players.\n\nA Terminal window will guide you through the official Homebrew installer. Type INSTALL HOMEBREW when asked. macOS may request your administrator password there, never in Couch Cube.\n\nFinish that step, then return here and install your selection. No disks will be erased."
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

    @objc private func copyDMG() {
        guard let drive = selected else { return }
        let panel = NSOpenPanel()
        panel.title = "Select a release DMG to keep as a backup"
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg")!]
        guard panel.runModal() == .OK, let source = panel.url else {
            status.stringValue = "No installer selected; nothing copied or downloaded."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Keep a release copy on this drive?"
        alert.informativeText = "\(source.path)\n\nDestination: \(drive.root)/Installer/\n\nNo automatic download. Existing copies are not overwritten. Formatting this drive later also erases this installer. Host dependencies are still required on another Mac."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        execute(["copy-installer", "--drive", drive.id, "--source", source.path, "--confirm"]) { code, _ in
            self.status.stringValue = code == 0 ? "Verified installer copied to Installer." : "Installer not copied. See details."
        }
    }

    @objc private func prepareDisk() {
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

    private func reviewErase(_ disk: PhysicalDisk) {
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
                alert.informativeText = "\(plan.model)\n\(ByteCountFormatter.string(fromByteCount: plan.size, countStyle: .file))\n\nFirst downloads the latest portable app and verifies its checksum and bundle signature. If unavailable, nothing is erased. The release is ad-hoc signed, not publisher-verified.\n\nThen ALL volumes and data, including any installer, will be destroyed. New format: APFS, GUID; name: Mac Gaming. The app is copied to the SSD root afterward.\n\nType exactly: \(phrase)\n\nIf macOS denies authorization, use Disk Utility manually. A failure after erasure cannot restore your data."
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

    @objc private func setup() {
        guard let drive = selected else { return }
        let alert = NSAlert()
        alert.messageText = report?.state == "not prepared" ? "Create your game library?" : "Update your library links?"
        alert.informativeText = "\(drive.root)\n\nCreates game folders and launcher files only, or updates this app's existing files. Your games and saves are kept.\n\nDoes not install Steam or emulators, change Steam's storage, add shortcuts to Steam or move existing games. Next: install any missing apps, then complete Steam setup.\n\nClose ES-DE before continuing."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status.stringValue = "Cancelled. No changes made."
            return
        }
        append("\n--- Create/update library ---\n")
        execute(["setup", "--drive", drive.id, "--confirm", "--no-host-config"]) { code, _ in
            if code == 0 {
                self.status.stringValue = "Game folders created. Next: install missing apps, then finish setup in Steam."
                self.advanceAfterLibraryCheck = self.onboarding
                self.checkStorage()
            } else {
                self.status.stringValue = "Library couldn't be updated. Your games are kept; Activity explains the problem."
            }
        }
    }

    @objc private func openFolder() {
        guard let drive = selected else { return }
        let path = URL(fileURLWithPath: drive.root)
        guard FileManager.default.fileExists(atPath: path.path) else {
            status.stringValue = "Run setup first, or reconnect the drive."
            return
        }
        NSWorkspace.shared.open(path)
    }

    @objc private func instructions() {
        NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("README.md"))
    }

    @objc private func registerGame() {
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if task != nil {
            status.stringValue = "Wait for the current operation. Disconnecting or force quitting may leave a partial setup."
            return false
        }
        if sender === setupWindow, lastConsoleID != nil {
            cancelSetup()
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return task == nil ? .terminateNow : .terminateCancel
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = SetupController()
application.delegate = controller
application.run()
