import AppKit

/// Preload manager: launchers and emulators that open hidden before game night and close afterwards.
extension SetupController {
    var preloadPaths: [String] {
        get {
            if UserDefaults.standard.object(forKey: Self.preloadAppsKey) == nil {
                // First time: Steam and Battle.net are the slow ones that cover the screen.
                return ["steam", "battle-net"].compactMap { id in
                    appStates.first { $0.id == id && $0.installed && !$0.path.isEmpty }?.path
                }
            }
            return UserDefaults.standard.stringArray(forKey: Self.preloadAppsKey) ?? []
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.preloadAppsKey) }
    }

    func runningApp(at path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path && !$0.isTerminated }
    }

    var quitAtStart: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.quitAtStartKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.quitAtStartKey) }
    }

    func preloadCardContent() -> NSView {
        for stack in [preloadList, runningList] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
        }
        let auto = NSButton(checkboxWithTitle: "Start game night when Couch Cube opens", target: self, action: #selector(preloadAutoChanged(_:)))
        auto.state = UserDefaults.standard.bool(forKey: Self.preloadAutoKey) ? .on : .off
        let note = text("Preloaded apps stay open in the background and use some memory and power. Close them when game night is over, or when a demanding game is lagging.",
                        size: 11, secondary: true)
        let focusNote = text("Gaming Focus: create a Shortcut with the \u{201C}Set Focus\u{201D} action (for example Gaming, which macOS includes) "
                             + "and type its name here. It runs when game night starts; a second Shortcut can switch the Focus off when it ends.",
                             size: 11, secondary: true)
        renderPreload()
        return column([preloadList,
                       row([button("Add App\u{2026}", #selector(addPreloadApp)), button("Start Game Night", #selector(startGameNightClicked)),
                            button("End Game Night", #selector(endGameNightClicked))]),
                       auto, note,
                       focusRow("Focus on", key: Self.focusOnKey, placeholder: "Shortcut name, e.g. Gaming Focus On"),
                       focusRow("Focus off", key: Self.focusOffKey, placeholder: "Shortcut name (optional)"),
                       focusNote, runningList])
    }

    private func focusRow(_ title: String, key: String, placeholder: String) -> NSView {
        let field = NSTextField(string: UserDefaults.standard.string(forKey: key) ?? "")
        field.placeholderString = placeholder
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.target = self
        field.action = #selector(focusShortcutChanged(_:))
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return row([text(title), field])
    }

    @objc func focusShortcutChanged(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.stringValue.trimmingCharacters(in: .whitespaces), forKey: key)
    }

    func renderPreload() {
        clearRows(preloadList)
        let paths = preloadPaths
        if paths.isEmpty {
            preloadList.addArrangedSubview(text("Nothing to preload yet. Add Steam or any launcher or emulator.", secondary: true))
        }
        for path in paths {
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            let running = runningApp(at: path)
            let state = running == nil ? "Not running" : running?.isHidden == true ? "Preloaded" : "Open"
            let remove = button("Remove", #selector(removePreloadApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(path)
            preloadList.addArrangedSubview(row([iconView(NSWorkspace.shared.icon(forFile: path)), text(name),
                                                text(state, size: 12, secondary: true), remove]))
        }
        // Suggestions: installed launchers and emulators that are not on the list yet, one click each.
        let chosen = Set(paths)
        let suggestions = appStates.filter {
            $0.installed && !$0.path.isEmpty && !chosen.contains($0.path)
                && (computerGameApps.contains($0.id) || emulatorApps.contains($0.id) || ["es-de", "sikarugir", "crossover"].contains($0.id))
        }
        if !suggestions.isEmpty {
            let title = text("Suggestions", size: 12, secondary: true)
            preloadList.addArrangedSubview(title)
            for start in stride(from: 0, to: suggestions.count, by: 4) {
                let buttons = suggestions[start..<min(start + 4, suggestions.count)].map { app -> NSButton in
                    let add = button("+ " + app.name, #selector(addSuggestedPreload(_:)))
                    add.identifier = NSUserInterfaceItemIdentifier(app.path)
                    return add
                }
                preloadList.addArrangedSubview(row(buttons))
            }
        }
        clearRows(runningList)
        let heading = text("Running now \u{00B7} tick the apps that should always close when game night starts", size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        runningList.addArrangedSubview(heading)
        let saved = quitAtStart
        let apps = tvRunningApps()
        for app in apps {
            let bundleID = app.bundleIdentifier ?? ""
            let always = NSButton(checkboxWithTitle: "Always quit", target: self, action: #selector(toggleQuitAtStart(_:)))
            always.identifier = NSUserInterfaceItemIdentifier(bundleID)
            always.state = saved.contains(bundleID) ? .on : .off
            always.controlSize = .small
            always.isEnabled = !bundleID.isEmpty
            let quit = button("Quit", #selector(quitRunningApp(_:)))
            quit.identifier = NSUserInterfaceItemIdentifier(String(app.processIdentifier))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            runningList.addArrangedSubview(row([iconView(app.icon ?? NSImage()), text(app.localizedName ?? "App"),
                                                text(app.isHidden ? "Background" : "Open", size: 12, secondary: true),
                                                spacer, always, quit]))
        }
        // Apps saved to quit that are not open right now stay listed, so they can be taken off again.
        let openIDs = Set(apps.compactMap(\.bundleIdentifier))
        for bundleID in saved where !openIDs.contains(bundleID) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
            let remove = button("Remove", #selector(removeQuitAtStart(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            runningList.addArrangedSubview(row([iconView(url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()), text(name),
                                                text("Always quits at game night", size: 12, secondary: true), spacer, remove]))
        }
        runningList.addArrangedSubview(button("Add App to Quit\u{2026}", #selector(addQuitAtStart)))
    }

    private func iconView(_ image: NSImage) -> NSImageView {
        let icon = NSImageView(image: image)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return icon
    }

    @objc func addSuggestedPreload(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !preloadPaths.contains(path) else { return }
        preloadPaths += [path]
        renderPreload()
    }

    @objc func toggleQuitAtStart(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue, !bundleID.isEmpty else { return }
        var list = quitAtStart.filter { $0 != bundleID }
        if sender.state == .on { list.append(bundleID) }
        quitAtStart = list
        renderPreload()
    }

    @objc func removeQuitAtStart(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        quitAtStart = quitAtStart.filter { $0 != bundleID }
        renderPreload()
    }

    @objc func addQuitAtStart() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to quit when game night starts"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var list = quitAtStart
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !list.contains(id) { list.append(id) }
        }
        quitAtStart = list
        renderPreload()
    }

    /// Game night starts: the apps saved to quit close, the preload apps open hidden, and the Focus Shortcut runs.
    func startGameNight() {
        let mine = Bundle.main.bundleIdentifier
        for id in quitAtStart where id != mine && id != "com.apple.finder" {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        }
        preloadNow()
        runFocusShortcut(Self.focusOnKey)
    }

    /// Game night ends: the preloaded apps close and the Focus switches off.
    func endGameNight() {
        for path in preloadPaths { runningApp(at: path)?.terminate() }
        runFocusShortcut(Self.focusOffKey)
    }

    func runFocusShortcut(_ key: String) {
        guard let name = UserDefaults.standard.string(forKey: key), !name.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try? process.run()
    }

    /// Opens every preload app that is not running yet, hidden and without taking the screen.
    func preloadNow() {
        for path in preloadPaths where FileManager.default.fileExists(atPath: path) && runningApp(at: path) == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { app, _ in
                // Some launchers (Steam) show their window after starting; put them away again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { app?.hide() }
            }
        }
    }

    @objc func startGameNightClicked() { startGameNight() }

    @objc func endGameNightClicked() { endGameNight() }

    @objc func preloadAutoChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.preloadAutoKey)
    }

    @objc func addPreloadApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to preload"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var paths = preloadPaths
        for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
        preloadPaths = paths
        renderPreload()
    }

    @objc func removePreloadApp(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        preloadPaths = preloadPaths.filter { $0 != path }
        renderPreload()
    }

    @objc func quitRunningApp(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let pid = pid_t(raw) else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }
}
