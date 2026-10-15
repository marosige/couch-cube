import AppKit
import CoreBluetooth
import GameController
import IOBluetooth
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

struct ManagedApp: Decodable {
    let id: String
    let name: String
    let installed: Bool
    let path: String
    let version: String
    let managed: Bool
    let update: String?
    let manual: Bool
    let brew: Bool
    let url: String?
}

struct ConsoleSystem: Decodable {
    let id: String
    let name: String
    let enabled: Bool
    let package: String
    let requirement: String
}

struct PairedController {
    let name: String
    let address: String
    let connected: Bool
}

func isBluetoothController(deviceClass: UInt32, name: String) -> Bool {
    let peripheral = (deviceClass >> 8) & 0x1f == 5
    let subtype = (deviceClass >> 2) & 0x0f
    if peripheral && (subtype == 1 || subtype == 2) { return true }
    let name = name.lowercased()
    return ["dualsense", "dualshock", "xbox wireless", "xbox elite", "pro controller", "joy-con",
            "8bitdo", "gamesir", "wireless controller", "stadia controller", "nimbus", "stratus"].contains { name.contains($0) }
}

func controllerBatteryText(level: Float, state: GCDeviceBattery.State) -> String? {
    guard state != .unknown, level.isFinite, (0...1).contains(level) else { return nil }
    let percent = state == .full ? 100 : Int((level * 100).rounded())
    return state == .charging ? "Charging · \(percent)%" : "\(percent)% battery"
}

final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.windowBackgroundColor : NSColor(calibratedWhite: 0.95, alpha: 1)).setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class SettingsSidebarRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

final class SettingsSidebarCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { textField?.textColor = backgroundStyle == .emphasized ? .selectedMenuItemTextColor : .labelColor }
    }
}

typealias SetupActionButton = NSButton

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, CBCentralManagerDelegate {
    private var window: NSWindow!
    private var mainWindow: NSWindow!
    private let detail = NSView()
    private let mainDetail = SettingsBackgroundView()
    private let sidebar = NSTableView()
    private var selectingPage = false
    private let sidebarPages = [-1, 0, 3, 6, -1, 1, 7, 8, 5, -1, 2]
    private let sidebarTitles = ["Your console", "Play", "Setup", "Game library", "Games & devices", "Apps", "Consoles", "Controllers", "Steam setup", "This Mac", "Settings"]
    private let sidebarSymbols = ["", "play.fill", "checklist", "externaldrive.fill", "", "square.grid.2x2.fill", "gamecontroller.fill", "gamecontroller", "tv.fill", "", "gearshape.fill"]
    private let activeControllerRows = NSStackView()
    private let pairedControllerRows = NSStackView()
    private let controllerStatus = NSTextField(wrappingLabelWithString: "")
    private var controllerAccessButton: NSButton!
    private var bluetoothManager: CBCentralManager?
    private var controllerTimer: Timer?
    private var controllerQueryRunning = false
    private var pairedControllers: [PairedController] = []
    private let volumeMenu = NSPopUpButton()
    private let driveRows = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    private let libraryTitle = NSTextField(labelWithString: "Choose your game drive")
    private let libraryDescription = NSTextField(wrappingLabelWithString: "Connect an SSD, or use this Mac's internal storage.")
    private let libraryAction = SetupActionButton()
    private var playAction: NSButton!
    private let setupSummary = NSTextField(wrappingLabelWithString: "Checking your setup...")
    private let steamStorageAdvice = NSTextField(wrappingLabelWithString: "")
    private let retroAdvice = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSTabView()
    private let modeLabel = NSTextField(labelWithString: "PORTABLE MANAGER")
    private let log = NSTextView()
    private var actions: [NSControl] = []
    private var volumes: [Drive] = []
    private var availableVolumes: [Drive] = []
    private var task: Process?
    private let backend: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts/console.py")
    private var refreshPending = false
    private var disks: [PhysicalDisk] = []
    private var logWindow: NSWindow?
    private var report: Assessment?
    private var libraryControls: [NSControl] = []
    private var appStates: [ManagedApp] = []
    private let appRows = NSStackView()
    private let consoleRows = NSStackView()
    private var consoleSystems: [ConsoleSystem] = []
    private var systemSwitches: [NSSwitch] = []
    private let appsStatus = NSTextField(wrappingLabelWithString: "Open Apps to check installed versions.")
    private let consoleStatus = NSTextField(wrappingLabelWithString: "Create your game folders in Setup first.")
    private let setupFolderStatus = NSTextField(wrappingLabelWithString: "Choose where to keep your games.")
    private let setupAppStatus = NSTextField(wrappingLabelWithString: "Steam or ES-DE provides your TV menu.")
    private let setupConnectionStatus = NSTextField(wrappingLabelWithString: "Connect a controller and add your games.")
    private var lastError = ""
    private var smokeFinishing = false
    private var smokeAppsLoaded = false
    private var smokeSystemsLoaded = false
    private let updateStatus = NSTextField(wrappingLabelWithString: "Checking for updates...")
    private let updateButton = NSButton()
    private var updateTask: Process?
    private var updateURL: URL?
    private var didRouteInitialLibrary = false
    private var preferredMode: String?
    private let navigationBar = NSStackView()
    private let storageHeading = NSTextField(labelWithString: "Choose your game storage")
    private let storageAdvice = NSTextField(wrappingLabelWithString: "")
    private let storageNext = SetupActionButton()
    private let portablePreparation = NSStackView()
    private let selectedStorage = NSTextField(wrappingLabelWithString: "")
    private let libraryHealth = NSStackView()
    private let finishAdvice = NSTextField(wrappingLabelWithString: "")
    private var advanceAfterLibraryCheck = false
    private let preparationResult = NSTextField(wrappingLabelWithString: "")
    private var helperButton: NSButton!
    private let helperAdvice = NSTextField(wrappingLabelWithString:
        "Homebrew is needed only to install missing apps from here. Finish its Terminal installer, return here, then click the app's Install button. macOS may ask for administrator approval.")
    private let autoLaunchToggle = NSSwitch()
    private let autoLaunchDelay = NSTextField(string: "30")
    private let autoLaunchStatus = NSTextField(wrappingLabelWithString: "Open Settings to check automatic console mode.")
    private var autoLaunchLoaded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Couch Cube"
        window.minSize = NSSize(width: 960, height: 720)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
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
            navigationBar.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 44),
            navigationBar.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -8),
            sidebarBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            sidebarBackground.widthAnchor.constraint(lessThanOrEqualToConstant: 235)
        ])
        split.addArrangedSubview(sidebarBackground)
        split.addArrangedSubview(mainDetail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setPosition(220, ofDividerAt: 0)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--smoke-test"),
           let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
            let appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
            mainWindow.appearance = appearance
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        mainDetail.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: mainDetail.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: mainDetail.trailingAnchor),
            detail.topAnchor.constraint(equalTo: mainDetail.topAnchor, constant: 28),
            detail.bottomAnchor.constraint(equalTo: mainDetail.bottomAnchor)
        ])
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
        driveRows.orientation = .vertical
        driveRows.alignment = .leading
        driveRows.spacing = 12
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
        let playDescription = text("Steam Big Picture, or ES-DE when Steam isn't installed.", secondary: true)
        playDescription.alignment = .center
        let library = column([
            pageHeading("Play", "Your games. One big screen."),
            primary(play),
            playDescription,
            card("Ready for the couch?", subtitle: nil, views: [
                setupSummary,
                row([button("Apps & emulators", #selector(showPlayers)),
                     button("Steam & controller setup", #selector(showFinishing))]),
                button("Check status", #selector(checkStorage))
            ])
        ])
        library.alignment = .leading
        addPage("Play", content: library)

        let appChoices = appRows
        appChoices.orientation = .vertical
        appChoices.alignment = .leading
        appChoices.spacing = 0
        helperButton = button("Install Homebrew...", #selector(homebrew))
        helperAdvice.textColor = .secondaryLabelColor
        let apps = column([
            pageHeading("Apps & emulators", "Use Steam Big Picture, or ES-DE for a retro-only console."),
            card("On this Mac", subtitle: "Install only what you need. Removing an app keeps your games and saves.", views: [
                appsStatus, appChoices
            ]),
            text("Retro: ES-DE browses games; RetroArch or Dolphin runs them. You still need your own games, any required BIOS, RetroArch cores and controller setup.\nWindows: Porting Kit is not Proton. Each supported game needs a working wrapper.", size: 12, secondary: true),
            helperAdvice,
            row([helperButton, button("Refresh apps", #selector(loadApps)),
                 button("Check app updates", #selector(checkAppUpdates))])
        ])
        addPage("Game players", content: apps)
        autoLaunchDelay.widthAnchor.constraint(equalToConstant: 64).isActive = true
        autoLaunchToggle.controlSize = .small
        autoLaunchToggle.setAccessibilityLabel("Automatic console mode on this Mac")
        autoLaunchDelay.setAccessibilityLabel("Seconds to wait after login, from 5 to 300")
        autoLaunchStatus.textColor = .secondaryLabelColor
        actions += [autoLaunchToggle, autoLaunchDelay]
        let tools = column([
            pageHeading("Settings", "Preferences for this Mac."),
            card("Automatic console mode", subtitle:
                "Open Steam Big Picture, or ES-DE if Steam isn't installed, when a controller connects.", views: [
                settingsRow("Automatic console mode", subtitle: "Start after login when a controller is connected.", symbol: "power", color: .systemGreen, trailing: autoLaunchToggle),
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
            ]),
            card("Remove Couch Cube", subtitle: "Remove this app, its saved selection and login entry. Games, saves and other apps are kept. Remove other apps individually in Apps.", views: [
                button("Uninstall Couch Cube...", #selector(uninstallCouchCube))
            ])
        ])
        addPage("Settings", content: tools)
        updateButton.title = "View release..."
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.isEnabled = false
        updateButton.bezelStyle = .rounded
        addPage("Welcome", content: column([
            pageHeading("Set up your console", "Choose a home for your games. Everything stays here in the sidebar."),
            card("Game storage", subtitle: "No games are moved. Steam keeps its current library unless you change it.", views: [
                setupFolderStatus,
                row([choice("This Mac", "Built-in storage", symbol: "desktopcomputer", action: #selector(chooseLocal)),
                     choice("External SSD", "More space for games", symbol: "externaldrive.fill", action: #selector(choosePortable))])
            ]),
            card("TV menu & emulators", subtitle: nil, views: [
                settingsRow("Choose your consoles", subtitle: "Switch on only the systems you want. We'll show which emulator each needs.", symbol: "gamecontroller.fill", color: .systemPurple,
                            trailing: button("Consoles", #selector(showConsoles))),
                separator(),
                settingsRow("Install your apps", subtitle: "Steam Big Picture or ES-DE, plus your chosen emulators.", symbol: "square.grid.2x2.fill", color: .systemBlue,
                            trailing: button("Apps", #selector(showPlayers))),
                setupAppStatus
            ]),
            card("Connect & play", subtitle: nil, views: [
                settingsRow("Steam & controllers", subtitle: "Sign in, add your own games and connect a controller. We'll guide the manual steps.", symbol: "tv.fill", color: .systemOrange,
                            trailing: button("Open guide", #selector(showFinishing))),
                setupConnectionStatus
            ])
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
            card("Game storage", subtitle: "Choose a drive. Existing files are kept.", views: [
                driveRows,
                summary,
                button("Refresh connected drives", #selector(refresh)),
                primary(storageNext),
                button("Copy this app to SSD...", #selector(copyAppToSSD))
            ]),
            button("All setup options", #selector(backToChoices))
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
                        button("Controllers", #selector(showControllers))]),
            card("Optional: retro & Windows games in Big Picture", subtitle: nil, views: [
                retroAdvice, row([button("Open Steam desktop", #selector(openSteamDesktop)),
                                 button("Open game folders", #selector(openFolder))])
            ])
        ]))
        addPage("Game library", content: column([
            pageHeading("Game library", "Couch Cube's folders, not a list of installed Steam games."),
            card("Storage", subtitle: nil, views: [
                libraryHealth, selectedStorage, libraryTitle, libraryDescription,
                row([openGames, addGame])
            ]),
            card("Manage library", subtitle: "Updates Couch Cube's launcher paths, not Steam's storage settings. No games are moved.", views: [
                libraryAction,
                button("Check Library", #selector(checkStorage)),
                button("Change Storage…", #selector(changeStorage))
            ])
        ]))
        consoleRows.orientation = .vertical
        consoleRows.alignment = .leading
        consoleRows.spacing = 0
        addPage("Consoles", content: column([
            pageHeading("Consoles", "Only enable what you want to play."),
            consoleStatus,
            card("Your systems", subtitle: "Changes save automatically. Disabling a system never deletes ROMs or saves.", views: [consoleRows]),
            text("Use only games, BIOS, firmware and keys you own and are entitled to use. Nothing is downloaded here. Switch requires a separately obtained compatible macOS emulator; availability and compatibility are not guaranteed.", size: 12, secondary: true),
            button("Apps & emulators", #selector(showPlayers))
        ]))
        for rows in [activeControllerRows, pairedControllerRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        controllerAccessButton = controllerButton("Allow Bluetooth access", #selector(controllerBluetoothAccess))
        addPage("Controllers", content: column([
            pageHeading("Controllers", "Your game controllers, without the rest of the Bluetooth device list."),
            row([controllerButton("Add controller...", #selector(addController)),
                 controllerButton("Open Game Controller Settings", #selector(openGameControllerSettings)),
                 controllerButton("Refresh", #selector(refreshControllers))]),
            card("Active in games", subtitle: "Controllers currently recognized by macOS Game Controller, over USB or wirelessly.", views: [activeControllerRows]),
            card("Bluetooth pairings", subtitle: "Connected is the Bluetooth link; Active above means ready for games. Some Bluetooth LE pairings are only visible in System Settings.", views: [
                controllerStatus, controllerAccessButton, pairedControllerRows
            ]),
            text("Pairing and Forget This Device are confirmed in macOS Bluetooth settings. Switch a controller on to reconnect; USB controllers do not need pairing. Configure game buttons in Steam or your emulator.", size: 12, secondary: true)
        ]))
        navigationBar.orientation = .vertical
        navigationBar.alignment = .leading
        let brandImage = NSImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Console.icns"))!)
        brandImage.widthAnchor.constraint(equalToConstant: 44).isActive = true
        brandImage.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let brandLabels = column([text("Couch Cube", size: 16), text("Your Mac console", size: 11, secondary: true)])
        brandLabels.spacing = 5
        let sidebarLabel = row([brandImage, brandLabels])
        navigationBar.addArrangedSubview(sidebarLabel)
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Navigation")))
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 32
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Couch Cube navigation")
        sidebarScroll.documentView = sidebar
        navigationBar.addArrangedSubview(sidebarScroll)
        sidebarScroll.widthAnchor.constraint(equalTo: navigationBar.widthAnchor).isActive = true
        sidebarScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        stack.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let details = button("Details...", #selector(showActivity))
        let help = button("Help", #selector(instructions))
        details.isBordered = false
        help.isBordered = false
        actions.removeAll { $0 === details || $0 === help }
        let statusRow = row([status, details, help])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(statusRow)
        log.isEditable = false
        log.isSelectable = true
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textColor = .textColor
        log.backgroundColor = .textBackgroundColor
        log.autoresizingMask = [.width]
        log.isVerticallyResizable = true
        log.isHorizontallyResizable = false
        log.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(controllerConnectionChanged), name: name, object: nil)
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
        if tabs.selectedTabViewItem === tabs.tabViewItems[8] { refreshControllers() }
    }

    private func pageHeading(_ title: String, _ subtitle: String) -> NSStackView {
        let heading = text(title, size: 22)
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let result = column([heading, text(subtitle, size: 13, secondary: true)])
        result.spacing = 8
        return result
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
        choose.bezelStyle = .recessed
        choose.showsBorderOnlyWhileMouseInside = true
        choose.contentTintColor = .controlAccentColor
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
            ? "Create Couch Cube's game folders on this SSD. Steam storage is configured manually in Steam setup. Preparing an SSD is optional and erases it."
            : "Create Couch Cube's folders on this Mac. Steam can keep using its current library. No apps are installed and no Steam games are moved in this step."
        portablePreparation.isHidden = !portable
        renderDrives()
    }

    private func renderDrives() {
        clearRows(driveRows)
        for (index, drive) in volumes.enumerated() {
            let choose = button(index == volumeMenu.indexOfSelectedItem ? "Selected" : "Choose", #selector(selectStorage(_:)))
            choose.tag = index
            choose.state = index == volumeMenu.indexOfSelectedItem ? .on : .off
            let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
            let line = settingsRow(drive.mode == "local" ? "Macintosh HD" : drive.name,
                                   subtitle: "\(free) available · \(drive.filesystem.uppercased())\n\(drive.root)",
                                   symbol: drive.mode == "local" ? "internaldrive.fill" : "externaldrive.fill",
                                   color: .systemGray, trailing: choose)
            driveRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: driveRows.widthAnchor).isActive = true
        }
    }

    @objc private func selectStorage(_ sender: NSButton) {
        guard task == nil, volumes.indices.contains(sender.tag) else {
            status.stringValue = "Wait for the current operation before changing storage."
            return
        }
        volumeMenu.selectItem(at: sender.tag)
        renderDrives()
        selectionChanged()
    }

    @objc private func backToChoices() {
        selectPage(3)
    }

    @objc private func changeStorage() {
        selectPage(3)
    }

    @objc private func continueStorage() {
        guard let report = report, report.issues.isEmpty, selected != nil else { return }
        // Refresh absolute frontend paths when an SSD moves between Macs.
        setup()
    }

    @objc private func showPlayers() { selectPage(1); loadApps() }
    @objc private func showConsoles() { selectPage(7); loadSystems() }

    @objc private func showFinishing() { selectPage(5) }

    private func updateSteamGuide() {
        let missing = report?.missing ?? []
        finishAdvice.stringValue = report?.issues.isEmpty != true
            ? "Your library still needs attention. Go back to storage before continuing."
            : missing.contains("steam")
            ? "Using ES-DE only? Skip Steam setup. Configure your selected emulators in Apps and add your ROMs in Game library."
            : "Steam is installed. The steps below happen in Steam; they are not changed by Couch Cube."
        if let drive = selected {
            let path = (drive.root as NSString).appendingPathComponent("SteamLibrary")
            steamStorageAdvice.stringValue = drive.mode == "local"
                ? "No storage change needed on this Mac.\n\nSign in to Steam and use its existing Macintosh HD library. Couch Cube's folders are for retro games and launchers; existing Steam installs stay where they are."
                : "Do this manually in Steam:\n\nSteam → Settings (Preferences) → Storage → Add Drive\n\nChoose another location / Let me choose another location, then select:\n\(path)\n\nSteam may also call this library Macintosh HD: check the path underneath to identify the SSD. In its ••• menu, rename it Couch Cube if offered and choose Make Default. You can move existing games here using Steam's Move action.\n\nCouch Cube does not edit Steam's library database. The available labels vary by Steam version."
            steamStorageAdvice.font = .systemFont(ofSize: 13)
            retroAdvice.stringValue = "In Steam desktop → Games → Add a Non-Steam Game to My Library → Browse, add:\n\(drive.root)/Launchers/Retro.app\n\nES-DE needs the emulators for the consoles you enabled, plus your own games and any BIOS/cores. Add registered game .app shortcuts from Launchers in the same way. Steam shortcuts are not added automatically."
        }
    }

    @objc private func openBluetooth() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) {
            controllerStatus.stringValue = "Couldn't open Bluetooth settings. Open System Settings → Bluetooth manually."
        }
    }

    @objc private func openGameControllerSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!) {
            controllerStatus.stringValue = "Couldn't open Game Controllers settings. Open System Settings → Game Controllers manually."
        }
    }

    private func controllerButton(_ title: String, _ action: Selector) -> NSButton {
        let control = button(title, action)
        actions.removeAll { $0 === control }
        return control
    }

    @objc private func showControllers() { selectPage(8) }

    @objc private func addController() {
        let alert = NSAlert()
        alert.messageText = "Add a controller"
        alert.informativeText = "Put your controller in pairing mode, then select it in macOS Bluetooth settings.\n\nPlayStation: hold Create/Share + PS until the light flashes.\nXbox: hold the Pair button until the Xbox light flashes.\nSwitch Pro / Joy-Con: hold Sync until the lights cycle.\n\nUSB controllers can be plugged straight in. Return here to see whether macOS recognizes it for games."
        alert.addButton(withTitle: "Open Bluetooth Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openBluetooth() }
    }

    @objc private func forgetController(_ sender: NSButton) {
        guard let address = sender.identifier?.rawValue,
              let device = pairedControllers.first(where: { $0.address == address }) else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(device.name)?"
        alert.informativeText = "In Bluetooth settings, find \(device.name) (\(device.address)), open its info button and choose Forget This Device. macOS will confirm removal. Nothing has been removed by Couch Cube."
        alert.addButton(withTitle: "Open Bluetooth Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openBluetooth() }
    }

    @objc private func controllerBluetoothAccess() {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!) {
                controllerStatus.stringValue = "Open System Settings → Privacy & Security → Bluetooth to review access."
            }
        } else if bluetoothManager == nil {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { refreshControllers() }

    @objc private func controllerConnectionChanged() {
        DispatchQueue.main.async {
            if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8] { self.refreshControllers() }
        }
    }

    private func addControllerRow(to rows: NSStackView, name: String, note: String, trailing: NSView) {
        if !rows.arrangedSubviews.isEmpty {
            let line = separator()
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let view = settingsRow(name, subtitle: note, symbol: "gamecontroller.fill",
            color: .systemBlue, trailing: trailing)
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
    }

    private func renderPairedControllers() {
        clearRows(pairedControllerRows)
        for device in pairedControllers {
            let forget = controllerButton("Forget...", #selector(forgetController(_:)))
            forget.identifier = NSUserInterfaceItemIdentifier(device.address)
            addControllerRow(to: pairedControllerRows, name: device.name,
                note: "\(device.connected ? "Paired · Connected over Bluetooth" : "Paired · Not connected")\n\(device.address)",
                trailing: row([
                    statusIndicator(device.connected ? "Connected" : "Not connected", color: device.connected ? .systemGreen : .systemYellow), forget
                ]))
        }
    }

    @objc private func refreshControllers() {
        clearRows(activeControllerRows)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            addControllerRow(to: activeControllerRows, name: "DualSense Wireless Controller",
                note: "Read-only preview · DualSense · 75% battery", trailing: statusIndicator("Active", color: .systemGreen))
            pairedControllers = [
                PairedController(name: "DualSense Wireless Controller", address: "Preview · Connected", connected: true),
                PairedController(name: "Xbox Wireless Controller", address: "Preview · Paired", connected: false)
            ]
            controllerStatus.stringValue = "Read-only preview. No Bluetooth query, pairing or permission request."
            controllerAccessButton.isHidden = true
            renderPairedControllers()
            return
        }
        for controller in GCController.controllers() {
            let name = controller.vendorName ?? controller.productCategory
            var note = controller.productCategory
            if let battery = controller.battery,
               let level = controllerBatteryText(level: battery.batteryLevel, state: battery.batteryState) {
                note += " · " + level
            }
            let active = statusIndicator("Active", color: .systemGreen)
            addControllerRow(to: activeControllerRows, name: name, note: note, trailing: active)
        }
        if activeControllerRows.arrangedSubviews.isEmpty {
            activeControllerRows.addArrangedSubview(text("No active controllers. Connect by USB, or pair and switch on a wireless controller.", size: 12, secondary: true))
        }
        controllerAccessButton.isHidden = CBManager.authorization == .allowedAlways
        switch CBManager.authorization {
        case .notDetermined:
            controllerAccessButton.title = "Allow Bluetooth access"
            controllerStatus.stringValue = "Allow Bluetooth access to read paired controllers. Active USB/game controllers appear above without it."
        case .denied, .restricted:
            controllerAccessButton.title = "Bluetooth privacy..."
            controllerStatus.stringValue = "Bluetooth access is denied or restricted. Review Couch Cube in Privacy & Security → Bluetooth, or manage pairings in System Settings."
        case .allowedAlways:
            if bluetoothManager == nil {
                bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            guard let manager = bluetoothManager else { return }
            guard manager.state == .poweredOn || manager.state == .poweredOff else {
                controllerStatus.stringValue = manager.state == .unsupported ? "Bluetooth is not supported on this Mac." :
                    manager.state == .unauthorized ? "Bluetooth access is not authorized. Review Privacy & Security → Bluetooth." :
                    "Reading Bluetooth state..."
                return
            }
            guard !controllerQueryRunning else { return }
            controllerQueryRunning = true
            let poweredOn = manager.state == .poweredOn
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> PairedController? in
                    let name = device.name ?? "Game controller"
                    guard isBluetoothController(deviceClass: device.classOfDevice, name: name) else { return nil }
                    return PairedController(name: name, address: device.addressString ?? "Address unavailable", connected: device.isConnected())
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                DispatchQueue.main.async {
                    self.controllerQueryRunning = false
                    guard CBManager.authorization == .allowedAlways else { self.refreshControllers(); return }
                    self.pairedControllers = devices
                    self.renderPairedControllers()
                    self.controllerStatus.stringValue = (poweredOn ? "Bluetooth is on." : "Bluetooth is off. Turn it on in System Settings to reconnect.") +
                        (devices.isEmpty ? " No controller pairings exposed by macOS. Bluetooth LE pairings may still be listed in System Settings." :
                            " \(devices.count) controller pairing\(devices.count == 1 ? "" : "s") exposed by macOS.")
                }
            }
            return
        @unknown default:
            controllerStatus.stringValue = "Unknown Bluetooth access state. Manage controllers in System Settings → Bluetooth."
        }
        pairedControllers = []
        renderPairedControllers()
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
        clearRows(libraryHealth)
        guard let report = report, let drive = selected else {
            libraryHealth.addArrangedSubview(statusIndicator(selected == nil ? "No storage selected" : "Checking library", color: .systemYellow))
            setupSummary.stringValue = "Choose connected storage to check your folders and installed apps."
            playAction.isEnabled = false
            return
        }
        let foldersReady = report.state == "valid layout" && report.issues.isEmpty
        libraryHealth.addArrangedSubview(statusIndicator(foldersReady ? "Ready" : report.issues.isEmpty ? "Setup required" : "Needs attention",
                                                        color: foldersReady ? .systemGreen : report.issues.isEmpty ? .systemYellow : .systemRed))
        let steamInstalled = !report.missing.contains("steam")
        let retroInstalled = !report.missing.contains("es-de")
        playAction.title = steamInstalled ? "Open Steam Big Picture" : retroInstalled ? "Open ES-DE" : "Install Steam or ES-DE to play"
        setupFolderStatus.stringValue = foldersReady ? "Connected: \(drive.root)" : "Choose storage below to create your game folders."
        setupAppStatus.stringValue = steamInstalled ? "Steam is installed. Optional emulators are managed in Apps." :
            retroInstalled ? "ES-DE is installed and is your console menu." : "Install Steam or ES-DE in Apps to get your TV menu."
        setupSummary.stringValue = foldersReady
            ? (steamInstalled ? "Steam Big Picture is your TV menu.\nConnect a controller and choose a game in Steam." :
                retroInstalled ? "ES-DE is your TV menu.\nAdd your ROMs and install the emulators for your selected consoles." :
                "Your game folders are ready.\nInstall Steam or ES-DE in Apps to start playing.")
            : "Choose game storage in Setup first. No games will be moved."
        setupConnectionStatus.stringValue = drive.mode == "local"
            ? "Local Steam games stay in Steam's existing library. No storage change needed."
            : "For Steam games on the SSD, add its SteamLibrary in Steam → Settings → Storage."
        playAction.isEnabled = task == nil && foldersReady && (steamInstalled || retroInstalled)
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

    private func statusIndicator(_ title: String, color: NSColor) -> NSView {
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.contentTintColor = color
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let result = row([dot, label])
        result.setHuggingPriority(.required, for: .horizontal)
        result.spacing = 5
        result.setAccessibilityLabel(title)
        return result
    }

    private func addSectionHeading(_ title: String, to rows: NSStackView) {
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
        stack.distribution = .fill
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
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 12
        box.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.18, alpha: 1) : .controlBackgroundColor
        }
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        let heading = text(title, size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        var contents: [NSView] = title.isEmpty ? [] : [heading]
        if let subtitle = subtitle { contents.append(text(subtitle, size: 12, secondary: true)) }
        contents += views
        let stack = column(contents)
        for view in contents where !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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

    private func settingsRow(_ title: String, subtitle: String, symbol: String, color: NSColor,
                             trailing: NSView) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = color.cgColor
        tile.layer?.cornerRadius = 5
        tile.widthAnchor.constraint(equalToConstant: 26).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 26).isActive = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        let labels = column([text(title, size: 13), text(subtitle, size: 11, secondary: true)])
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let result = row([tile, labels, trailing])
        result.distribution = .fill
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        if let controls = trailing as? NSStackView {
            controls.setHuggingPriority(.required, for: .horizontal)
            for control in controls.arrangedSubviews {
                control.setContentHuggingPriority(.required, for: .horizontal)
            }
        }
        labels.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(greaterThanOrEqualTo: result.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: result.bottomAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: result.trailingAnchor)
        ])
        result.spacing = 12
        return result
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
        selectingPage = true
        defer { selectingPage = false }
        if index == 5 { updateSteamGuide() }
        tabs.selectTabViewItem(at: index)
        navigationBar.isHidden = false
        mainWindow.title = index == 0 ? "Couch Cube" : (sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube")
        storageNext.isHidden = index != 4
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playAction.keyEquivalent = index == 0 ? "\r" : ""
        if let selected = sidebarPages.firstIndex(of: index == 4 ? 3 : index), sidebar.selectedRow != selected {
            sidebar.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        controllerTimer?.invalidate()
        controllerTimer = nil
        if index == 8 {
            refreshControllers()
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                controllerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshControllers() }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTitles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: sidebarTitles[row])
        if sidebarPages[row] < 0 {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let view = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3)
            ])
            return view
        }
        label.font = .systemFont(ofSize: 13)
        let colors: [NSColor] = [.systemGray, .systemGreen, .systemGray, .systemOrange, .systemGray, .systemBlue, .systemPurple, .systemBlue, .systemIndigo, .systemGray, .systemGray]
        let cell = SettingsSidebarCell()
        cell.textField = label
        let image = NSImageView(image: NSImage(systemSymbolName: sidebarSymbols[row], accessibilityDescription: nil)!)
        image.contentTintColor = .white
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = colors[row].cgColor
        tile.layer?.cornerRadius = 4
        tile.widthAnchor.constraint(equalToConstant: 20).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 20).isActive = true
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                                     image.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        let contents = self.row([tile, label])
        contents.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(contents)
        pin(contents, to: cell)
        cell.setAccessibilityLabel(sidebarTitles[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { sidebarPages[row] >= 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { sidebarPages[row] < 0 ? 28 : 32 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SettingsSidebarRow() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingPage, sidebarPages.indices.contains(sidebar.selectedRow) else { return }
        let page = sidebarPages[sidebar.selectedRow]
        guard page >= 0 else { return }
        guard tabs.selectedTabViewItem !== tabs.tabViewItems[page] else { return }
        selectPage(page)
        if page == 2 { loadAutoLaunch() }
        if page == 1 { loadApps() }
        if page == 7 { loadSystems() }
    }

    @objc private func openSettings() {
        selectPage(2)
        loadAutoLaunch()
    }

    @objc private func loadApps() { fetchApps(updates: false) }
    @objc private func checkAppUpdates() { fetchApps(updates: true) }

    private func fetchApps(updates: Bool, completed: ((Bool) -> Void)? = nil) {
        guard task == nil else {
            appsStatus.stringValue = "An operation is running. Activity stays available; refresh apps when it finishes."
            completed?(false)
            return
        }
        appsStatus.stringValue = updates ? "Checking Homebrew for updates..." : "Reading apps installed on this Mac..."
        execute(updates ? ["apps", "--updates"] : ["apps"], capture: true) { code, data in
            guard code == 0 else {
                self.appsStatus.stringValue = "Couldn't read apps. Open Activity for the error."
                self.showActivity()
                completed?(false)
                return
            }
            do {
                self.appStates = try JSONDecoder().decode([ManagedApp].self, from: data)
                self.helperButton.isHidden = self.appStates.first?.brew == true
                self.helperAdvice.isHidden = self.helperButton.isHidden
                if let report = self.report {
                    self.report = Assessment(state: report.state, issues: report.issues, notes: report.notes,
                                             missing: self.appStates.filter { !$0.installed }.map { $0.id })
                    self.updateSetupSummary()
                }
                self.renderApps()
                self.appsStatus.stringValue = updates
                    ? "Update check complete. Steam and manually installed apps manage their own updates."
                    : "Installed versions shown below. Check updates when you want; no background downloads."
                completed?(true)
            } catch {
                self.appsStatus.stringValue = "Couldn't read app information: \(error.localizedDescription)"
                self.append(self.appsStatus.stringValue + "\n")
                completed?(false)
            }
        }
    }

    private func clearRows(_ stack: NSStackView) {
        actions.removeAll { $0.isDescendant(of: stack) }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func renderApps() {
        clearRows(appRows)
        let order = ["steam", "es-de", "retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch", "porting-kit"]
        appStates.sort { (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100) }
        for (index, app) in appStates.enumerated() {
            if app.id == "steam" { addSectionHeading("TV menus", to: appRows) }
            if app.id == "retroarch-metal" { addSectionHeading("Retro games", to: appRows) }
            if app.id == "porting-kit" { addSectionHeading("Windows games", to: appRows) }
            let action = button(app.installed ? "Installed" : app.manual ? "Get app..." : "Install", #selector(appAction(_:)))
            action.tag = index
            let controls = row([
                statusIndicator(app.installed ? (app.update == nil ? "Installed" : "Update available") : "Not installed",
                                color: app.installed && app.update == nil ? .systemGreen : .systemYellow), action
            ])
            if let update = app.update, !update.isEmpty {
                let upgrade = button("Update", #selector(updateApp(_:)))
                upgrade.tag = index
                controls.addArrangedSubview(upgrade)
            }
            let note = app.installed
                ? "Version \(app.version)" + (app.managed ? " · Homebrew" : " · Manual install") + (app.update.map { " · Update: \($0)" } ?? "")
                : app.id == "switch" ? "Bring your own compatible macOS emulator (Ryujinx.app). No bundled download." :
                    app.id == "cemu-wiiu" ? "Wii U · Manual download from cemu.info (not the CEmu calculator cask)." :
                    app.id == "rpcs3" ? "PS3 · Manual download from rpcs3.net; install Sony firmware in RPCS3." :
                    app.id == "pcsx2" ? "PS2 · Your own BIOS required; Homebrew build may require Rosetta." :
                    app.id == "es-de" ? "Your retro TV menu; games also need emulators." :
                    app.id == "steam" ? "Steam games & Big Picture TV menu." :
                    app.id == "dolphin" ? "GameCube & Wii." :
                    app.id == "retroarch-metal" ? "PS1 and classic systems; install only for consoles that need it." :
                    "Compatible Windows-game wrappers; not macOS Proton."
            let line = settingsRow(app.name, subtitle: note, symbol: app.id == "steam" ? "gamecontroller.fill" : "app.fill",
                                   color: .systemBlue, trailing: controls)
            if app.installed {
                let open = button("Open", #selector(openManagedApp(_:)))
                open.tag = index
                controls.insertArrangedSubview(open, at: 0)
                let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: app.path))
                icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
                if let stack = line as? NSStackView, let first = stack.arrangedSubviews.first {
                    stack.removeArrangedSubview(first)
                    first.removeFromSuperview()
                    stack.insertArrangedSubview(icon, at: 0)
                }
            }
            appRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: appRows.widthAnchor).isActive = true
            let separator = self.separator()
            appRows.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: appRows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        }
    }

    @objc private func openManagedApp(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path),
                                          configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                DispatchQueue.main.async { self.status.stringValue = "Couldn't open \(app.name): \(error.localizedDescription)" }
            }
        }
    }

    @objc private func appAction(_ sender: NSButton) {
        guard task == nil, appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        if app.installed && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) {
            appsStatus.stringValue = "Quit \(app.name) first, then choose Installed to remove it."
            return
        }
        if !app.installed && app.manual {
            if let url = app.url, let link = URL(string: url) {
                NSWorkspace.shared.open(link)
                appsStatus.stringValue = "Install the macOS app in Applications, then choose Refresh apps."
            } else {
                let alert = NSAlert()
                alert.messageText = "Switch emulator: manual setup"
                alert.informativeText = "No verified automatic Switch emulator download is bundled. If you have a compatible Ryujinx-based macOS build, install it as Ryujinx.app in Applications. Configure your own legally obtained keys, firmware and game dumps there, then Refresh apps. Availability and game compatibility are not guaranteed."
                alert.runModal()
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = app.installed ? "Remove \(app.name)?" : "Install \(app.name)?"
        alert.informativeText = app.installed
            ? "Quit \(app.name) first. The app will be removed. Game libraries, saves and preferences are kept. To remove another app, select it separately."
            : "Homebrew will install this app on this Mac. It won't install games or sign in to accounts."
        alert.addButton(withTitle: app.installed ? "Remove app" : "Install app")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

    @objc private func updateApp(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Update \(app.name)?"
        alert.informativeText = "Quit the app first. Homebrew will download and install the update."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { manage(app, action: "update") }
    }

    private func manage(_ app: ManagedApp, action: String) {
        if action == "install", appStates.first?.brew != true {
            fetchApps(updates: false) { success in
                guard success else { return }
                if self.appStates.first?.brew == true { self.manage(app, action: action) }
                else { self.homebrew() }
            }
            return
        }
        execute(["manage-app", "--package", app.id, "--action", action, "--confirm"]) { code, _ in
            if code == 0 { self.loadApps() }
        }
        showActivity()
    }

    private func loadSystems() {
        guard task == nil, let drive = selected, report?.state == "valid layout" else {
            consoleStatus.stringValue = "Create game folders in Setup first, then open Consoles. An operation in progress must finish before loading the selection."
            return
        }
        execute(["systems", "--root", drive.root], capture: true) { code, data in
            guard code == 0 else {
                self.consoleStatus.stringValue = "Couldn't read console selection. Open Activity for details."
                return
            }
            do {
                self.consoleSystems = try JSONDecoder().decode([ConsoleSystem].self, from: data)
                self.renderSystems()
                self.consoleStatus.stringValue = "Switch on your systems. Required apps are installed separately in Apps."
            } catch {
                self.consoleStatus.stringValue = "Couldn't read consoles: \(error.localizedDescription)"
                self.append(self.consoleStatus.stringValue + "\n")
            }
        }
    }

    private func renderSystems() {
        clearRows(consoleRows)
        systemSwitches = []
        let order = ["gc", "wii", "wiiu", "switch", "nes", "snes", "gb", "gbc", "gba", "n64",
                     "psx", "ps2", "ps3", "psp", "megadrive", "segacd", "dreamcast"]
        consoleSystems.sort {
            (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100)
        }
        let playerNames = ["retroarch-metal": "RetroArch", "cemu-wiiu": "Cemu", "switch": "Switch emulator",
                           "pcsx2": "PCSX2", "rpcs3": "RPCS3", "dolphin": "Dolphin"]
        var previousGroup = ""
        for system in consoleSystems {
            let group = ["psx", "ps2", "ps3", "psp"].contains(system.id) ? "PlayStation" :
                ["megadrive", "segacd", "dreamcast"].contains(system.id) ? "SEGA" : "Nintendo"
            if group != previousGroup {
                addSectionHeading(group, to: consoleRows)
                previousGroup = group
            } else {
                let separator = NSBox()
                separator.boxType = .separator
                consoleRows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: consoleRows.widthAnchor).isActive = true
            }
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = system.enabled ? .on : .off
            toggle.target = self
            toggle.action = #selector(toggleSystem(_:))
            toggle.setAccessibilityLabel(system.name)
            systemSwitches.append(toggle)
            let needsApp = report?.missing.contains(system.package) == true
            let state = system.enabled ? (needsApp ? "Needs emulator" : "Enabled") : "Off"
            let controls = row([statusIndicator(state, color: system.enabled ? (needsApp ? .systemYellow : .systemGreen) : .tertiaryLabelColor), toggle])
            let line = settingsRow(system.name,
                subtitle: "\(playerNames[system.package] ?? system.package) · \(system.requirement)",
                symbol: "gamecontroller.fill", color: .systemPurple, trailing: controls)
            consoleRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: consoleRows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        }
    }

    @objc private func toggleSystem(_ sender: NSSwitch) {
        guard task == nil else {
            if let index = systemSwitches.firstIndex(of: sender) {
                sender.state = consoleSystems[index].enabled ? .on : .off
            }
            consoleStatus.stringValue = "Wait for the current operation before changing consoles."
            return
        }
        saveSystems()
    }

    @objc private func saveSystems() {
        guard task == nil, let drive = selected, systemSwitches.count == consoleSystems.count, !consoleSystems.isEmpty else {
            consoleStatus.stringValue = "Load your console selection first. Create game folders in Setup if needed."
            return
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.lastPathComponent == "ES-DE.app" }) {
            for (system, toggle) in zip(consoleSystems, systemSwitches) { toggle.state = system.enabled ? .on : .off }
            consoleStatus.stringValue = "Quit ES-DE first. It must not overwrite updated frontend settings."
            return
        }
        let enabled = zip(consoleSystems, systemSwitches).filter { $0.1.state == .on }.map { $0.0.id }
        execute(["systems", "--root", drive.root, "--confirm", "--enabled"] + enabled) { code, _ in
            self.loadSystems()
            if code != 0 { self.showActivity() }
        }
    }

    @objc private func uninstallCouchCube() {
        guard task == nil else { status.stringValue = "Wait for the current operation to finish."; return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Couch Cube?"
        alert.informativeText = "Moves this copy of Couch Cube to Trash and removes its saved Mac selection, login entry and login log. Games, ROMs, BIOS, saves, other installed apps and game-library folders are kept. You can remove other apps individually in Apps."
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
            ? "Starting at your next macOS login, wait \(delay) seconds. If no keyboard or mouse is connected, wait for a controller and open Steam Big Picture, or ES-DE if Steam isn't installed.\n\nNo passwords or automatic macOS login are configured. Keep Couch Cube at:\n\(Bundle.main.bundleURL.path)\n\nIf you move or replace the app or game library, save this setting again. macOS may manage this under Login Items."
            : "Stops this app's waiting login helper and removes its login entry. Steam and your game library are unchanged."
        alert.addButton(withTitle: enabled ? "Enable" : "Turn off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var arguments = ["login", "--confirm", "--delay", String(delay)]
        if enabled, let drive = selected { arguments += ["--root", drive.root] }
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
            scroll.autohidesScrollers = true
            log.frame = NSRect(origin: .zero, size: scroll.contentSize)
            log.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            log.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
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
        button.setContentHuggingPriority(.required, for: .horizontal)
        if title.hasPrefix("Open Steam"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "steam://open/main")!) {
            let image = NSWorkspace.shared.icon(forFile: app.path)
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageLeading
        }
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
        systemSwitches.forEach { $0.isEnabled = !value }
        if !value && selected == nil {
            libraryControls.forEach { $0.isEnabled = false }
        }
        storageNext.isEnabled = !value && selected != nil && report?.issues.isEmpty == true
        if !value {
            [volumeMenu, storageNext].forEach { $0.needsDisplay = true }
            updateSetupSummary()
        }
    }

    private func execute(_ arguments: [String], capture: Bool = false,
                         completed: @escaping (Int32, Data) -> Void) {
        precondition(capture || !ProcessInfo.processInfo.arguments.contains("--smoke-test"), "Read-only smoke tests must never run mutations")
        guard task == nil else {
            status.stringValue = "An operation is already running. Activity shows its progress."
            return
        }
        lastError = ""
        let readOnly = capture && ["drives", "assess", "apps", "systems", "system-catalog", "login-status"].contains(arguments.first ?? "")
        if !readOnly { busy(true) }
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
        case "drives", "assess": break
        case "setup": status.stringValue = "Getting your library ready. Keep the drive connected."
        case "install-apps": status.stringValue = "Installing your game players. This may take a few minutes."
        case "manage-app": status.stringValue = "Updating apps. Open Activity for live Homebrew output."
        case "erase": status.stringValue = "Preparing your SSD. Keep it connected until this finishes."
        default: if !readOnly { status.stringValue = "Working on it..." }
        }
        do {
            try process.run()
        } catch {
            task = nil
            if !readOnly { busy(false) }
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
                if !readOnly { self.busy(false) }
                if process.terminationStatus != 0 && !capture { self.showActivity() }
                completed(process.terminationStatus, result)
                if self.refreshPending && self.task == nil && !self.smokeFinishing {
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
        let arguments = ProcessInfo.processInfo.arguments
        let requestedPage = arguments.firstIndex(of: "--page").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        if requestedPage != nil || arguments.contains("--smoke-flow") {
            if requestedPage == "1" || arguments.contains("--smoke-flow"), !smokeAppsLoaded {
                smokeAppsLoaded = true
                execute(["apps"], capture: true) { code, data in
                    do {
                        self.appStates = try JSONDecoder().decode([ManagedApp].self, from: data)
                        self.renderApps()
                        self.appsStatus.stringValue = "Installed versions. Updates are checked only when requested."
                        precondition(Set(self.appStates.map { $0.id }) == Set(["steam", "es-de", "retroarch-metal", "dolphin", "porting-kit", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]))
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
        smokeFinishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let stack = self.detail.subviews.compactMap { $0 as? NSStackView }.first!
                let discoveryOK = success && !self.volumes.isEmpty && self.window.isVisible
                    && self.selected != nil
                    && self.tabs.numberOfTabViewItems == 9 && self.logWindow == nil
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--minimum-size") { self.window.setContentSize(self.window.minSize) }
                if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
                   let page = Int(args[index + 1]), (0..<9).contains(page) {
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
                    let assessment = self.report
                    self.busy(true)
                    let statusRow = stack.arrangedSubviews.last as! NSStackView
                    let details = statusRow.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.action == #selector(self.showActivity) }
                    precondition(details?.isEnabled == true && self.sidebar.isEnabled, "Activity and navigation must stay available during operations")
                    self.busy(false)
                    for page in 0..<self.tabs.numberOfTabViewItems {
                        self.selectPage(page)
                        precondition(!self.navigationBar.isHidden && self.window === self.mainWindow)
                        precondition(self.sidebar.selectedRow == self.sidebarPages.firstIndex(of: page == 4 ? 3 : page))
                        self.assertSmokePageScrolls()
                        if page == 7 {
                            for toggle in self.systemSwitches {
                                precondition(toggle.controlSize == .small)
                                let frame = toggle.convert(toggle.bounds, to: self.consoleRows)
                                precondition(abs(frame.maxX - self.consoleRows.bounds.maxX) < 4, "Console switches must align to the right edge")
                            }
                        }
                    }
                    for (index, page) in self.sidebarPages.enumerated() where page < 0 {
                        precondition(!self.tableView(self.sidebar, shouldSelectRow: index), "Sidebar section headings must not navigate")
                    }
                    precondition(self.systemSwitches.count == 17 && self.activeControllerRows.arrangedSubviews.count == 1)
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
                    precondition(self.playAction.isEnabled && self.playAction.title == "Open ES-DE")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled)
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
                precondition(self.storageNext.isBordered && self.playAction.isBordered)
                precondition(self.window.titleVisibility == .hidden && self.window.toolbar == nil)
                precondition(self.window.styleMask.contains(.fullSizeContentView))
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    precondition(self.window.standardWindowButton(kind)?.isHidden == false)
                }
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
                print(ok ? "Native UI smoke test passed: settings navigation, apps, consoles and controller preview; no setup or pairing executed."
                         : "Portable manager smoke test failed: \(self.status.stringValue)")
                exit(ok ? 0 : 1)
        }
    }

    private func assertSmokePageScrolls() {
        window.contentView!.layoutSubtreeIfNeeded()
        let scroll = tabs.selectedTabViewItem!.view as! NSScrollView
        let document = scroll.documentView!
        precondition(document.bounds.height >= document.subviews.first!.fittingSize.height,
                     "Every settings page must scroll to its last control")
    }

    @objc private func disksChanged() {
        if smokeFinishing { return }
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
            guard self.selected?.id == drive.id else { self.checkStorage(); return }
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
                self.helperButton.isHidden = !report.notes.contains { $0.hasPrefix("Homebrew missing") }
                self.helperAdvice.isHidden = self.helperButton.isHidden
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
                    self.selectPage(report.state != "valid layout" || !report.issues.isEmpty ? 3 : 0)
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
            } catch {
                self.advanceAfterLibraryCheck = false
                self.status.stringValue = "Cannot read assessment: \(error.localizedDescription)"
                self.finishSmokeTest(success: false)
            }
        }
    }

    @objc private func playSteam() {
        guard let drive = selected else { return }
        let frontend = report?.missing.contains("steam") == true ? "ES-DE" : "Steam Big Picture"
        execute(["console", "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "\(frontend) session finished or opened." : "Couldn't open console mode. Check Apps & emulators and Activity."
        }
    }

    @objc private func homebrew() {
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

    @objc private func copyAppToSSD() {
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

    @objc private func setup() {
        guard let drive = selected else { return }
        let alert = NSAlert()
        alert.messageText = report?.state == "not prepared" ? "Create your game library?" : "Update your library links?"
        alert.informativeText = "\(drive.root)\n\nCreates game folders and launcher files only, or updates this app's existing files. Your games and saves are kept.\n\nDoes not install Steam or emulators, change Steam's storage, add shortcuts to Steam or move existing games. Next: choose your Consoles and install any missing Apps."
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
        execute(["setup", "--drive", drive.id, "--confirm", "--no-host-config"]) { code, _ in
            if code == 0 {
                self.status.stringValue = "Game folders created. Next: install missing apps, then finish setup in Steam."
                self.advanceAfterLibraryCheck = true
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
