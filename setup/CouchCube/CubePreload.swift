import AppKit

/// Preload manager: launchers and emulators that open hidden before game night and close afterwards.
extension SetupController {
    var preloadPaths: [String] {
        get {
            if UserDefaults.standard.object(forKey: Self.preloadAppsKey) == nil {
                // First time: Steam is the one that is slow to start and covers the screen.
                let steam = appStates.first { $0.id == "steam" && $0.installed && !$0.path.isEmpty }?.path
                return steam.map { [$0] } ?? []
            }
            return UserDefaults.standard.stringArray(forKey: Self.preloadAppsKey) ?? []
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.preloadAppsKey) }
    }

    func runningApp(at path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path && !$0.isTerminated }
    }

    func preloadCardContent() -> NSView {
        preloadList.orientation = .vertical
        preloadList.alignment = .leading
        preloadList.spacing = 8
        runningList.orientation = .vertical
        runningList.alignment = .leading
        runningList.spacing = 8
        let auto = NSButton(checkboxWithTitle: "Preload when Couch Cube opens", target: self, action: #selector(preloadAutoChanged(_:)))
        auto.state = UserDefaults.standard.bool(forKey: Self.preloadAutoKey) ? .on : .off
        let note = text("Preloaded apps stay open in the background and use some memory and power. Close them when game night is over.",
                        size: 11, secondary: true)
        renderPreload()
        return column([preloadList,
                       row([button("Add App\u{2026}", #selector(addPreloadApp)), button("Preload Now", #selector(preloadNowClicked)),
                            button("Close Preloaded", #selector(closePreloadedClicked))]),
                       auto, note, runningList])
    }

    func renderPreload() {
        clearRows(preloadList)
        let paths = preloadPaths
        if paths.isEmpty {
            preloadList.addArrangedSubview(text("Nothing to preload yet. Add Steam or any launcher or emulator.", secondary: true))
        }
        for path in paths {
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let running = runningApp(at: path)
            let state = running == nil ? "Not running" : running?.isHidden == true ? "Preloaded" : "Open"
            let remove = button("Remove", #selector(removePreloadApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(path)
            preloadList.addArrangedSubview(row([icon, text(name), text(state, size: 12, secondary: true), remove]))
        }
        clearRows(runningList)
        let apps = tvRunningApps()
        guard !apps.isEmpty else { return }
        let heading = text("Running now", size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        runningList.addArrangedSubview(heading)
        for app in apps {
            let icon = NSImageView(image: app.icon ?? NSImage())
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let quit = button("Quit", #selector(quitRunningApp(_:)))
            quit.identifier = NSUserInterfaceItemIdentifier(String(app.processIdentifier))
            runningList.addArrangedSubview(row([icon, text(app.localizedName ?? "App"),
                                                text(app.isHidden ? "Background" : "Open", size: 12, secondary: true), quit]))
        }
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

    @objc func preloadNowClicked() { preloadNow() }

    @objc func closePreloadedClicked() {
        for path in preloadPaths { runningApp(at: path)?.terminate() }
    }

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
