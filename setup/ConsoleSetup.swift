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

final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

final class SetupActionButton: NSButton {
    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }
}

final class SetupChoiceButton: NSButton {
    var detail = ""
    var symbol = ""

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        (isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .controlBackgroundColor).setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
                .applying(.init(paletteColors: [.controlAccentColor])))?
            .draw(in: NSRect(x: 24, y: (bounds.height - 40) / 2, width: 40, height: 40))
        (title as NSString).draw(in: NSRect(x: 88, y: 20, width: bounds.width - 140, height: 30),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                                                 .foregroundColor: NSColor.labelColor])
        (detail as NSString).draw(in: NSRect(x: 88, y: 55, width: bounds.width - 140, height: 48),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                                  .foregroundColor: NSColor.secondaryLabelColor])
        ("›" as NSString).draw(in: NSRect(x: bounds.width - 40, y: 39, width: 24, height: 32),
                              withAttributes: [.font: NSFont.systemFont(ofSize: 26),
                                               .foregroundColor: NSColor.tertiaryLabelColor])
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let volumeMenu = NSPopUpButton()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    private let libraryTitle = NSTextField(labelWithString: "Choose your game drive")
    private let libraryDescription = NSTextField(wrappingLabelWithString: "Connect an SSD, or use this Mac's internal storage.")
    private let libraryAction = SetupActionButton()
    private let hostSummary = NSTextField(wrappingLabelWithString: "Checking this Mac...")
    private let tabs = NSTabView()
    private var navigation: [NSButton] = []
    private let modeLabel = NSTextField(labelWithString: "PORTABLE MANAGER")
    private let log = NSTextView()
    private let progress = NSProgressIndicator()
    private var actions: [NSControl] = []
    private var packages: [(String, NSButton)] = []
    private var volumes: [Drive] = []
    private var availableVolumes: [Drive] = []
    private var task: Process?
    private var pipe: Pipe?
    private let backend: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts/console.py")
    private var refreshPending = false
    private var disks: [PhysicalDisk] = []
    private var logWindow: NSWindow?
    private var report: Assessment?
    private var libraryControls: [NSControl] = []
    private var packageTitles: [String: String] = [:]
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
    private let journey = NSTextField(labelWithString: "")
    private let storageHeading = NSTextField(labelWithString: "Choose your game storage")
    private let storageAdvice = NSTextField(wrappingLabelWithString: "")
    private let storageNext = SetupActionButton()
    private let portablePreparation = NSStackView()
    private let selectedStorage = NSTextField(wrappingLabelWithString: "")
    private let finishAdvice = NSTextField(wrappingLabelWithString: "")
    private let playerContinue = SetupActionButton()
    private var advanceAfterLibraryCheck = false
    private let preparationResult = NSTextField(wrappingLabelWithString: "")
    private var helperButton: NSButton!
    private let helperAdvice = NSTextField(wrappingLabelWithString:
        "The free download helper installs your game players. Set it up once, then come back here. macOS may ask for administrator approval.")
    private var lastConsoleID: String?
    private var returnToConsole: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Couch Cube"
        window.minSize = NSSize(width: 800, height: 760)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        let title = NSTextField(labelWithString: "Couch Cube")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let icon = NSImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Console.icns"))!)
        icon.setAccessibilityLabel("TV and Mac mini on an oak console")
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        let headings = column([
            title,
            text("Your Mac. Your games. Your couch.", size: 13, secondary: true)
        ])
        headings.spacing = 4
        let header = row([icon, headings])
        header.spacing = 14
        headings.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -70).isActive = true
        stack.addArrangedSubview(header)
        modeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        volumeMenu.target = self
        volumeMenu.action = #selector(selectionChanged)
        volumeMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let storageRow = row([volumeMenu, button("Refresh", #selector(refresh))])
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        actions.append(volumeMenu)
        for (index, name) in ["Home", "Game players", "Settings"].enumerated() {
            let button = NSButton(title: name, target: self, action: #selector(changePage(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            navigation.append(button)
        }
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
        libraryControls += [openGames, addGame, play]
        let library = column([
            pageHeading("Your couch is calling.", "Your games, one big screen."),
            card("Your console", subtitle: nil, views: [
                selectedStorage, libraryTitle, libraryDescription,
                primary(play), row([openGames, addGame])
            ]),
            row([button("Change storage...", #selector(changeStorage)),
                 button("Connection & controller guide", #selector(showFinishing))])
        ])
        addPage("Library", content: library)

        hostSummary.textColor = .secondaryLabelColor
        let appChoices = column([])
        for (id, text) in [
            ("steam", "Steam — PC games and your TV menu"),
            ("es-de", "Retro game browser — find your classics in one place"),
            ("retroarch-metal", "Classic consoles — Nintendo, Sega, PlayStation & more"),
            ("dolphin", "GameCube & Wii"),
            ("porting-kit", "Windows games — optional, compatibility varies")
        ] {
            let checkbox = NSButton(checkboxWithTitle: text, target: nil, action: nil)
            checkbox.state = .off
            packageTitles[id] = text
            packages.append((id, checkbox))
            actions.append(checkbox)
            appChoices.addArrangedSubview(checkbox)
        }
        playerContinue.title = "Continue"
        playerContinue.target = self
        playerContinue.action = #selector(showFinishing)
        playerContinue.bezelStyle = .rounded
        actions.append(playerContinue)
        helperButton = button("Set up download helper...", #selector(homebrew))
        helperAdvice.textColor = .secondaryLabelColor
        let apps = column([
            pageHeading("What would you like to play?", "Choose only what you need. You can add more later."),
            card("Your game players", subtitle: "These apps run your games on this Mac, even when your library is on an SSD.", views: [
                hostSummary, appChoices,
                primary(button("Install my selection...", #selector(installApps)))
            ]),
            helperAdvice,
            row([helperButton, button("Check installed players", #selector(checkStorage))]),
            row([button("Back", #selector(backFromPlayers)), primary(playerContinue)])
        ])
        addPage("Game players", content: apps)
        let tools = column([
            card("Game storage", subtitle: "Change your location or update the links after moving your app or SSD.", views: [
                button("Choose storage or prepare an SSD...", #selector(changeStorage)), libraryAction,
                button("Check library again", #selector(checkStorage))
            ]),
            card("App updates", subtitle: "Checks GitHub at launch. Downloads and app replacement are never automatic.", views: [
                updateStatus, row([button("Check for updates", #selector(checkUpdates)), updateButton])
            ]),
            card("Carry the app with your games", subtitle: "In Finder, copy CouchCube.app to your SSD and open it there. Or use the DMG to copy it to Applications for this Mac.", views: [
                text("Keep the app and your game library on the same drive. Launchers use relative paths so they travel together. After moving the app within that drive, open it and update the library.", size: 12, secondary: true),
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
        returnToConsole = button("Back to my console", #selector(cancelSetup))
        returnToConsole.isHidden = true
        addPage("Welcome", content: column([
            pageHeading("Make room for game night.", "Choose your setup. We'll take care of the next steps together."),
            choice("On this Mac", "Keep your games on this Mac's internal storage.\nThe simplest choice for one living-room setup.",
                   symbol: "desktopcomputer", action: #selector(chooseLocal)),
            choice("On a portable SSD", "Take the app and your games between Macs.\nUse an existing SSD or prepare a new one here.",
                   symbol: "externaldrive", action: #selector(choosePortable)),
            text("Nothing is installed or erased until you review and confirm.", size: 12, secondary: true),
            returnToConsole
        ]))
        storageHeading.font = .systemFont(ofSize: 26, weight: .bold)
        storageAdvice.textColor = .secondaryLabelColor
        storageNext.title = "Use this storage..."
        storageNext.target = self
        storageNext.action = #selector(continueStorage)
        storageNext.bezelStyle = .rounded
        actions.append(storageNext)
        portablePreparation.orientation = .vertical
        portablePreparation.alignment = .leading
        let prepare = card("New SSD, or want a fresh start?", subtitle:
            "We'll download the portable app, then prepare the SSD and put the app on it. Erasing removes everything on the entire SSD — we'll ask you to confirm the exact disk first.",
            views: [button("Prepare an SSD...", #selector(prepareDisk))])
        portablePreparation.addArrangedSubview(prepare)
        prepare.widthAnchor.constraint(equalTo: portablePreparation.widthAnchor).isActive = true
        addPage("Storage", content: column([
            storageHeading, storageAdvice,
            preparationResult,
            portablePreparation,
            card("Use storage you already have", subtitle: "Your existing files stay where they are. Just choose where your game library should live.", views: [
                storageRow, summary, modeLabel, primary(storageNext)
            ]),
            button("Back to choices", #selector(backToChoices))
        ]))
        preparationResult.isHidden = true
        addPage("Finish", content: column([
            pageHeading("One last thing. Then, game time.", "Steam needs a little help connecting your library. You only do this once per Mac."),
            finishAdvice,
            card("1. Connect your games", subtitle:
                "In Steam → Settings → Storage, add the SteamLibrary folder from your game library.\nFor retro games, use Games → Add a Non-Steam Game and choose Launchers/Retro.app.",
                views: [button("Open my game library", #selector(openFolder)),
                        button("Open Steam", #selector(playSteam))]),
            card("2. Grab your controller", subtitle:
                "Pair it in macOS Bluetooth settings or connect it with USB. Steam → Settings → Controller lets you check the buttons. Retro players may need their own controller setup.",
                views: [button("Open Bluetooth settings", #selector(openBluetooth))]),
            row([button("Back to game players", #selector(showPlayers)),
                 primary(button("Go to my console", #selector(finishOnboarding)))])
        ]))
        navigationBar.orientation = .horizontal
        navigationBar.spacing = 10
        navigation.forEach { navigationBar.addArrangedSubview($0); actions.append($0) }
        navigationBar.distribution = .fillEqually
        journey.font = .systemFont(ofSize: 12, weight: .medium)
        journey.textColor = .secondaryLabelColor
        stack.addArrangedSubview(journey)
        stack.addArrangedSubview(navigationBar)
        stack.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let details = button("Details...", #selector(showActivity))
        let help = button("Help", #selector(instructions))
        details.isBordered = false
        help.isBordered = false
        let statusRow = row([progress, status, details, help])
        stack.addArrangedSubview(statusRow)
        log.isEditable = false
        log.isSelectable = true
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        for view in stack.arrangedSubviews where view !== tabs {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        selectPage(3)
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
              tabs.selectedTabViewItem === tabs.tabViewItems[1],
              !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        checkStorage()
    }

    private func pageHeading(_ title: String, _ subtitle: String) -> NSStackView {
        let heading = text(title, size: 28)
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        return column([heading, text(subtitle, size: 15, secondary: true)])
    }

    private func primary(_ button: NSButton) -> NSButton {
        button.bezelColor = .controlAccentColor
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        button.layer?.cornerRadius = 9
        button.contentTintColor = .white
        button.controlSize = .large
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ])
        return button
    }

    private func choice(_ title: String, _ description: String, symbol: String, action: Selector) -> NSButton {
        let choose = SetupChoiceButton(title: title, target: self, action: action)
        choose.detail = description
        choose.symbol = symbol
        choose.isBordered = false
        choose.setAccessibilityLabel(title + ". " + description.replacingOccurrences(of: "\n", with: " "))
        choose.heightAnchor.constraint(equalToConstant: 124).isActive = true
        actions.append(choose)
        return choose
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
            ? "Already have games on an SSD? Use it as it is. Starting fresh? Prepare an SSD below."
            : "Your library gets its own folder on this Mac. No disk preparation needed."
        portablePreparation.isHidden = !portable
    }

    @objc private func backToChoices() {
        selectPage(3)
    }

    @objc private func changeStorage() {
        onboarding = true
        if report?.state == "valid layout", report?.issues.isEmpty == true {
            lastConsoleID = selected?.id
        }
        returnToConsole.isHidden = lastConsoleID == nil
        selectPage(3)
    }

    @objc private func cancelSetup() {
        guard let id = lastConsoleID, task == nil else { return }
        preferredMode = nil
        populateVolumes(previous: id)
        onboarding = false
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

    @objc private func showFinishing() {
        let missing = report?.missing ?? []
        finishAdvice.stringValue = report?.issues.isEmpty != true
            ? "Your library still needs attention. Go back to storage before continuing."
            : missing.contains("steam")
            ? "Steam isn't installed yet. Go back to Game players to install it, or finish that later. Your library can still be created without it."
            : "Your library is in place. Add your own games and finish these connections before playing."
        selectPage(5)
    }

    @objc private func finishOnboarding() {
        guard report?.state == "valid layout", report?.issues.isEmpty == true else {
            status.stringValue = "Choose storage and create your game library first."
            selectPage(4)
            return
        }
        onboarding = false
        selectPage(0)
    }

    @objc private func openBluetooth() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    private func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
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
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        page.view = scroll
        tabs.addTabViewItem(page)
    }

    private func selectPage(_ index: Int) {
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        tabs.selectTabViewItem(at: index)
        navigationBar.isHidden = onboarding || index >= 3
        playerContinue.isHidden = !onboarding
        journey.isHidden = !onboarding || index == 3
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playerContinue.keyEquivalent = index == 1 && onboarding ? "\r" : ""
        switch index {
        case 3: journey.stringValue = ""
        case 4: journey.stringValue = "STEP 1 OF 3  ·  YOUR STORAGE"
        case 1: journey.stringValue = "STEP 2 OF 3  ·  YOUR GAME PLAYERS"
        case 5: journey.stringValue = "STEP 3 OF 3  ·  CONNECT & PLAY"
        default: journey.stringValue = ""
        }
        for button in navigation {
            let selected = button.tag == index
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            ])
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
    }

    @objc private func changePage(_ sender: NSButton) {
        selectPage(sender.tag)
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
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
        actions.append(button)
        return button
    }

    private var selected: Drive? {
        let index = volumeMenu.indexOfSelectedItem
        return volumes.indices.contains(index) ? volumes[index] : nil
    }

    private func append(_ text: String) {
        log.textStorage?.append(NSAttributedString(string: text))
        log.scrollToEndOfDocument(nil)
    }

    private func busy(_ value: Bool) {
        actions.forEach { $0.isEnabled = !value }
        if !value && selected == nil {
            libraryControls.forEach { $0.isEnabled = false }
        }
        storageNext.isEnabled = !value && selected != nil && report?.issues.isEmpty == true
        if !value {
            [volumeMenu, storageNext].forEach { $0.needsDisplay = true }
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
        pipe = output
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
            pipe = nil
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
                self.pipe = nil
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
                let stack = self.window.contentView!.subviews.compactMap { $0 as? NSStackView }.first!
                let fits = stack.fittingSize.height <= self.window.contentView!.bounds.height - 48
                let ok = success && !self.volumes.isEmpty && self.window.isVisible
                    && self.packages.count == 5 && self.selected != nil && fits
                    && self.tabs.numberOfTabViewItems == 6 && self.logWindow == nil
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
                   let page = Int(args[index + 1]), (0..<6).contains(page) {
                    self.onboarding = page >= 3 || page == 1
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
                    self.preferredMode = "portable"
                    self.populateVolumes(previous: nil)
                    self.selectPage(4)
                    precondition(!self.portablePreparation.isHidden)
                    precondition(self.volumes.allSatisfy { $0.mode == "portable" })
                    self.preferredMode = "local"
                    self.populateVolumes(previous: nil)
                    precondition(self.portablePreparation.isHidden)
                    precondition(self.volumes.allSatisfy { $0.mode == "local" })
                    self.showPlayers()
                    precondition(!self.playerContinue.isHidden && self.navigationBar.isHidden)
                    self.backFromPlayers()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[4])
                    self.backToChoices()
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
                    self.report = assessment
                    self.onboarding = false
                    self.selectPage(0)
                    precondition(!self.navigationBar.isHidden)
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
                self.window.contentView!.layoutSubtreeIfNeeded()
                self.window.displayIfNeeded()
                if let index = args.firstIndex(of: "--capture"), args.indices.contains(index + 1) {
                    let view = self.window.contentView!
                    if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        if let png = image.representation(using: .png, properties: [:]) {
                            do { try png.write(to: URL(fileURLWithPath: args[index + 1])) }
                            catch { fputs("Cannot capture UI: \(error)\n", stderr); exit(1) }
                        }
                    }
                }
                print(ok ? "Guided setup smoke test passed: welcome, storage, players, connection guide and console; no setup executed."
                         : "Portable manager smoke test failed: \(self.status.stringValue)")
                exit(ok ? 0 : 1)
        }
    }

    @objc private func disksChanged() {
        if task != nil { refreshPending = true } else { refresh() }
    }

    @objc private func selectionChanged() {
        report = nil
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
        selectedStorage.stringValue = drive.name
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
                self.storageNext.attributedTitle = NSAttributedString(string: self.storageNext.title, attributes: [
                    .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                ])
                if !report.issues.isEmpty {
                    self.summary.stringValue = "This storage needs attention before we can continue. Activity has the details."
                    if drive.mode == "portable" {
                        self.summary.stringValue += "\nTry another SSD, or prepare this one below after backing up its files."
                    }
                }
                if report.state == "not prepared" {
                    self.libraryTitle.stringValue = "No library on this drive yet"
                    self.libraryDescription.stringValue = "Create folders for Steam games, ROMs, BIOS and saves. Existing files won't be erased."
                    self.libraryAction.title = "Create game library..."
                } else if report.issues.isEmpty {
                    self.libraryTitle.stringValue = "Your game library is connected"
                    self.libraryDescription.stringValue = report.missing.contains("steam")
                        ? "Install Steam from Game players to open your TV menu. Your library folders are ready."
                        : "Open Steam for your TV menu. You can add games or change your players whenever you like."
                    self.libraryAction.title = "Update library links..."
                } else {
                    self.libraryTitle.stringValue = "This library needs attention"
                    self.libraryDescription.stringValue = report.issues.prefix(2).joined(separator: "\n")
                    self.libraryAction.title = "Update library links..."
                }
                let missing = report.missing.count
                self.hostSummary.stringValue = missing == 0
                    ? "Your players are already installed. You can continue."
                    : "Already installed players are marked below. Choose any others you want, or continue and install them later."
                self.helperButton.isHidden = !report.notes.contains { $0.hasPrefix("Homebrew missing") }
                self.helperAdvice.isHidden = self.helperButton.isHidden
                for (id, checkbox) in self.packages {
                    let available = !report.missing.contains(id)
                    checkbox.title = (self.packageTitles[id] ?? id) + (available ? "  ✓ Installed" : "")
                }
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
                        self.status.stringValue = "Your library needs attention before continuing. See Settings or Activity."
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
        let installs = packages.filter { $0.1.state == .on }.map { $0.0 }
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
                self.status.stringValue = "Apps installed on this Mac."
                self.checkStorage()
            } else {
                self.status.stringValue = "An app couldn't be installed. Activity shows what to do next."
            }
        }
    }

    @objc private func playSteam() {
        guard let drive = selected else { return }
        execute(["steam", "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "Steam Big Picture opened." : "Couldn't open Steam. Check Game players and Activity."
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
        alert.informativeText = "\(drive.root)\n\nCreates game folders and Steam-compatible launchers, or updates this app's existing files. Your games and saves are kept. No formatting, account changes or Mac app installations.\n\nClose ES-DE before continuing."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status.stringValue = "Cancelled. No changes made."
            return
        }
        append("\n--- Create/update library ---\n")
        execute(["setup", "--drive", drive.id, "--confirm", "--no-host-config"]) { code, _ in
            if code == 0 {
                self.status.stringValue = "Your game library is ready. Let's choose your players."
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
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return task == nil ? .terminateNow : .terminateCancel
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = SetupController()
application.delegate = controller
application.run()
