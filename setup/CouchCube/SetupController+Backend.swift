import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    /// A rebuilt or replaced app can leave this running copy without its backend files; say so instead of showing Python's error.
    func friendlyBackendError(_ text: String) -> String {
        let runtime = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3").path
        let missing = !FileManager.default.fileExists(atPath: backend.path) || !FileManager.default.fileExists(atPath: runtime)
        let pythonCannotOpen = text.contains("can't open file") && text.contains("/Contents/Resources/scripts/")
        return missing || pythonCannotOpen ? Self.appUpdatedMessage : text
    }

    /// A background backend run that reports stdout line by line and can be canceled with terminate().
    func runBackendStreaming(_ arguments: [String], line: @escaping (String) -> Void,
                                     completed: @escaping (Int32, String) -> Void) -> Process {
        precondition(!ProcessInfo.processInfo.arguments.contains("--smoke-test"), "Smoke tests must never download")
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completed(1, self.friendlyBackendError("ERROR: Cannot start bundled runtime: \(error.localizedDescription)")) }
                return
            }
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    DispatchQueue.main.async { line(text) }
                }
            }
            process.waitUntilExit()
            group.wait()
            let code = process.terminationStatus
            let text = String(decoding: errorData, as: UTF8.self)
            DispatchQueue.main.async { completed(code, code == 0 ? text : self.friendlyBackendError(text)) }
        }
        return process
    }

    func runBackendInBackground(_ arguments: [String], environment extra: [String: String] = [:],
                                completed: @escaping (Int32, Data, String) -> Void) {
        precondition(!arguments.contains("--confirm") || !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
                     "Read-only smoke tests must never run mutations")
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", backend.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completed(1, Data(), self.friendlyBackendError("Cannot start bundled runtime: \(error.localizedDescription)")) }
                return
            }
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.wait()
            let code = process.terminationStatus
            let text = String(decoding: errorData, as: UTF8.self)
            DispatchQueue.main.async { completed(code, data, code == 0 ? text : self.friendlyBackendError(text)) }
        }
    }

    /// Called where something failed or an operation started. Problems are shown in the app; the log stays closed.
    func activityNeeded(_ problem: String? = nil) {
        if SetupController.activityAutoOpens { showActivity(); return }
        guard let problem = problem?.trimmingCharacters(in: .whitespacesAndNewlines), !problem.isEmpty else { return }
        lastProblemNotice = problem
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"), let window = mainWindow ?? self.window,
              window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Something went wrong"
        alert.informativeText = String(problem.prefix(600))
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Activity")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { self.showActivity() }
        }
    }

    @objc func showActivity() {
        if logWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Activity"
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            log.frame = NSRect(origin: .zero, size: scroll.contentSize)
            log.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            log.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scroll.documentView = log
            status.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView!.addSubview(status)
            panel.contentView!.addSubview(scroll)
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
                status.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
                status.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 12),
                scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
                scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
            ])
            panel.center()
            logWindow = panel
        }
        logWindow!.makeKeyAndOrderFront(nil)
    }

    @objc func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
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

    func append(_ text: String) {
        appOperationOutput?(text)
        log.textStorage?.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]))
        log.scrollToEndOfDocument(nil)
    }

    func busy(_ value: Bool) {
        actions.forEach { $0.isEnabled = !value }
        if !value && selected == nil {
            libraryControls.forEach { $0.isEnabled = false }
        }
        storageNext.isEnabled = !value && selected != nil && report?.issues.isEmpty == true
        if !value {
            renderTVMenus()
            [volumeMenu, storageNext].forEach { $0.needsDisplay = true }
            updateAllButton.isEnabled = appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
            updateAllButton.isHidden = !appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
            updateSetupSummary()
        }
    }

    func execute(_ arguments: [String], capture: Bool = false,
                         completed: @escaping (Int32, Data) -> Void) {
        precondition(capture || !ProcessInfo.processInfo.arguments.contains("--smoke-test"), "Read-only smoke tests must never run mutations")
        guard task == nil, !cleanupInProgress else {
            status.stringValue = "An operation is already running. Activity shows its progress."
            return
        }
        lastError = ""
        if ["transfer-library", "retire-library", "initialize-drive", "removal-verify", "erase", "prepare-portable",
            "copy-app", "copy-installer", "cleanup-prepare", "cleanup-host", "setup"].contains(arguments.first ?? "") {
            // The library is about to change: stop installer downloads so no partial file is copied or left behind.
            for (id, job) in windowsDownloadJobs where job.running { cancelWindowsDownload(id: id) }
        }
        let readOnly = capture && ["drives", "storage-status", "assess", "apps", "systems", "system-catalog", "login-status", "frontend", "steam-status", "drive-detail", "removal-plan"].contains(arguments.first ?? "")
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
        case "drives", "storage-status", "assess": break
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
            lastError = friendlyBackendError("Cannot start bundled runtime: \(error.localizedDescription)")
            append(lastError + "\n")
            status.stringValue = lastError
            activityNeeded(lastError)
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
                if process.terminationStatus != 0 {
                    let friendly = self.friendlyBackendError(self.lastError)
                    if friendly != self.lastError { self.lastError = friendly; self.append(friendly + "\n"); self.status.stringValue = friendly }
                }
                if process.terminationStatus != 0 && !capture { self.activityNeeded(self.lastError.isEmpty ? "The operation didn't finish." : self.lastError) }
                completed(process.terminationStatus, result)
                if self.consoleRefreshPending && self.task == nil && !self.smokeFinishing {
                    self.consoleRefreshPending = false
                    if self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!) == 7 {
                        self.loadSystems()
                    }
                }
                self.runPendingAppsPreload()
                if self.appRefreshPending && self.task == nil && !self.smokeFinishing {
                    self.appRefreshPending = false
                    if [1, 6].contains(self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!)) {
                        self.loadApps()
                    }
                }
                if self.refreshPending && self.task == nil && !self.smokeFinishing {
                    self.refreshPending = false
                    self.refresh()
                }
                if self.driveDetailPending && self.task == nil && !self.smokeFinishing {
                    self.driveDetailPending = false
                    if self.currentPage == 12 { self.loadDriveDetail() }
                }
            }
        }
    }

    @objc func refresh() {
        if task != nil { refreshPending = true; return }
        let previous = selected?.id
        let previousRoot = selected?.root
        overviewChecks = Set(OverviewCheck.allCases)
        overviewCheckFailures = []
        renderGeneral()
        execute(["storage-status"], capture: true) { code, data in
            self.availableVolumes = []
            self.storageStatus = nil
            if code == 0 {
                do {
                    self.storageStatus = try JSONDecoder().decode(StorageStatus.self, from: data)
                    self.availableVolumes = self.storageStatus!.locations.map(\.drive)
                    self.lastLibraryTransfer = nil
                    self.status.stringValue = self.availableVolumes.isEmpty
                        ? "No writable supported storage found. Unlock/mount your drive and refresh."
                        : "Ready. Nothing has been changed."
                } catch {
                    self.status.stringValue = "Invalid drive information: \(error.localizedDescription)"
                    self.append(self.status.stringValue + "\n")
                    self.overviewCheckFailures.formUnion(OverviewCheck.allCases)
                }
            } else {
                self.overviewCheckFailures.formUnion(OverviewCheck.allCases)
                self.status.stringValue = "Drive discovery failed. Open Activity for details."
                self.activityNeeded(self.status.stringValue)
            }
            self.populateVolumes(previous: previous)
            self.renderStorageLocations()
            let preserve = previous == self.selected?.id && previousRoot == self.selected?.root
            let cachedReport = self.report
            let cachedSystems = self.consoleSystems.map { $0.id }
            self.updateSelection(preservingStatus: preserve)
            // Play opens before the drives are known; load its library games once they are.
            if self.currentPage == 0 { self.loadLauncherLibrary() }
            if preserve && ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                precondition(self.report?.state == cachedReport?.state,
                             "Refreshing unchanged storage must retain its last assessment")
                precondition(self.consoleSystems.map { $0.id } == cachedSystems,
                             "Refreshing unchanged storage must retain console visibility")
            }
            if self.selected == nil {
                self.overviewChecks = []
                self.renderGeneral()
                self.loadAutoLaunch()
                self.finishSmokeTest(success: false)
            }
        }
    }
}
