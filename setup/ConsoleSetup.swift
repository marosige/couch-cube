import AppKit

struct Drive: Decodable {
    let id: String
    let mode: String
    let name: String
    let root: String
    let filesystem: String
    let free: Int64
}

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let volumeMenu = NSPopUpButton()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    private let log = NSTextView()
    private let progress = NSProgressIndicator()
    private var actions: [NSControl] = []
    private var packages: [(String, NSButton)] = []
    private var volumes: [Drive] = []
    private var task: Process?
    private var pipe: Pipe?
    private let backend: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts/console.py")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mac Game Console Setup"
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        let title = NSTextField(labelWithString: "Your Mac. Your game console.")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Steam Big Picture for the TV; ES-DE for retro. This is a setup app, not a web launcher."))
        let row = NSStackView()
        row.orientation = .horizontal
        volumeMenu.target = self
        volumeMenu.action = #selector(selectionChanged)
        volumeMenu.widthAnchor.constraint(equalToConstant: 520).isActive = true
        row.addArrangedSubview(volumeMenu)
        row.addArrangedSubview(button("Refresh drives", #selector(refresh)))
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(summary)
        actions.append(volumeMenu)
        stack.addArrangedSubview(NSTextField(labelWithString: "Optional installations on this Mac (Homebrew required):"))
        for (id, text) in [
            ("steam", "Steam (may require Rosetta, installed separately)"),
            ("es-de", "ES-DE - Apple Silicon controller frontend"),
            ("retroarch-metal", "RetroArch Metal - universal build"),
            ("dolphin", "Dolphin - GameCube / Wii, universal build"),
            ("porting-kit", "Porting Kit - free Wine-based Windows wrappers (manual per-game setup)")
        ] {
            let checkbox = NSButton(checkboxWithTitle: text, target: nil, action: nil)
            checkbox.state = .off
            packages.append((id, checkbox))
            actions.append(checkbox)
            stack.addArrangedSubview(checkbox)
        }
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "No formatting or deletion. Existing games are preserved. Portable means portable data, not a bootable OS: each Mac still needs apps, cores, Wine engines and controller settings. Use APFS or Mac OS Extended."))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.addArrangedSubview(button("Review & Set Up", #selector(setup)))
        buttons.addArrangedSubview(button("Open game folder", #selector(openFolder)))
        buttons.addArrangedSubview(button("Add game shortcut...", #selector(registerGame)))
        buttons.addArrangedSubview(button("Instructions", #selector(instructions)))
        stack.addArrangedSubview(buttons)
        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [progress, status])
        statusRow.orientation = .horizontal
        stack.addArrangedSubview(statusRow)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        log.isEditable = false
        log.isSelectable = true
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        scroll.documentView = log
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
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
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func execute(_ arguments: [String], capture: Bool = false,
                         completed: @escaping (Int32, Data) -> Void) {
        guard task == nil else { return }
        busy(true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [backend.path] + arguments
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
        status.stringValue = "Working... Do not unplug the drive."
        do {
            try process.run()
        } catch {
            task = nil
            pipe = nil
            busy(false)
            status.stringValue = "Cannot start backend: \(error.localizedDescription)"
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
                DispatchQueue.main.async { self.append(text) }
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
                completed(process.terminationStatus, result)
            }
        }
    }

    @objc private func refresh() {
        execute(["drives"], capture: true) { code, data in
            self.volumes = []
            self.volumeMenu.removeAllItems()
            if code == 0 {
                do {
                    self.volumes = try JSONDecoder().decode([Drive].self, from: data)
                    self.volumeMenu.addItems(withTitles: self.volumes.map { $0.name })
                    self.status.stringValue = self.volumes.isEmpty
                        ? "No writable supported storage found. Unlock/mount your drive and refresh."
                        : "Ready. Nothing has been changed."
                } catch {
                    self.status.stringValue = "Invalid drive information: \(error.localizedDescription)"
                }
            } else {
                self.status.stringValue = "Drive discovery failed. See details below."
            }
            self.selectionChanged()
            if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let stack = self.window.contentView!.subviews.compactMap { $0 as? NSStackView }.first!
                let fits = stack.fittingSize.height <= self.window.contentView!.bounds.height - 48
                let ok = code == 0 && !self.volumes.isEmpty && self.window.isVisible
                    && self.packages.count == 5 && self.selected != nil && fits
                print(ok ? "Native setup smoke test passed: visible window, drive menu, choices; no setup executed."
                         : "Native setup smoke test failed: \(self.status.stringValue)")
                exit(ok ? 0 : 1)
            }
        }
    }

    @objc private func selectionChanged() {
        guard let drive = selected else { summary.stringValue = "No drive selected."; return }
        let free = ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)
        summary.stringValue = "\(drive.mode == "local" ? "Local console" : "Portable data") - \(drive.filesystem.uppercased()) - \(free) free\n\(drive.root)"
    }

    @objc private func setup() {
        guard let drive = selected else { return }
        let installs = packages.filter { $0.1.state == .on }.map { $0.0 }
        let alert = NSAlert()
        alert.messageText = "Set up \(drive.mode == "local" ? "local console" : "portable game data")?"
        alert.informativeText = "Create/update only managed setup files in:\n\(drive.root)\n\nInstall on this Mac: \(installs.isEmpty ? "Nothing" : installs.joined(separator: ", "))\n\nNo disk formatting, no game downloads, no deletion. Existing setup files modified by you will not be overwritten. Close ES-DE before proceeding. Homebrew may require interactive permission; if it fails, install the listed apps in Terminal and retry with installations unchecked."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status.stringValue = "Cancelled. No changes made."
            return
        }
        append("\n--- Setup ---\n")
        execute(["setup", "--drive", drive.id, "--confirm", "--install"] + installs) { code, _ in
            self.status.stringValue = code == 0
                ? "Ready. Next: Steam Storage, add Retro.app, install cores, pair controller. See Instructions."
                : "Setup failed or incomplete. See error below; fix it and rerun. Existing games preserved."
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
