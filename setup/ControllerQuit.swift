import AppKit
import GameController

/// How long Select + Start must be held to quit the game.
let holdSeconds: TimeInterval = 2

/// True once a controller has held the combo long enough; `since` is when the hold began.
func comboComplete(since: Date?, now: Date) -> Bool {
    guard let since = since else { return false }
    return now.timeIntervalSince(since) >= holdSeconds
}

func log(_ message: String) {
    FileHandle.standardError.write(Data(("Couch Cube: " + message + "\n").utf8))
}

/// Runs next to a game started from the TV menu. Many emulators (Cemu, Ryujinx, Azahar…) have no controller
/// hotkey to quit, so holding Select + Start on any controller closes the emulator and returns to the menu.
final class ControllerQuit: NSObject, NSApplicationDelegate {
    private let binary: URL
    private var timer: Timer?
    private var holdStart: Date?
    private var seen = false
    private var quitting = false
    private let started = Date()

    init(binary: URL) {
        self.binary = binary.standardizedFileURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GCController.shouldMonitorBackgroundEvents = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func emulator() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.executableURL?.standardizedFileURL == binary }
    }

    private func comboHeld() -> Bool {
        GCController.controllers().contains { controller in
            guard let pad = controller.extendedGamepad, let select = pad.buttonOptions else { return false }
            return select.isPressed && pad.buttonMenu.isPressed
        }
    }

    private func tick() {
        let app = emulator()
        if app != nil { seen = true }
        // The emulator is gone (or never appeared within a minute): nothing left to watch.
        if app == nil && (seen || Date().timeIntervalSince(started) > 60) {
            NSApp.terminate(nil)
            return
        }
        guard let app = app, !quitting else { return }
        if comboHeld() {
            if holdStart == nil { holdStart = Date() }
            if comboComplete(since: holdStart, now: Date()) {
                quitting = true
                log("Select + Start held: closing the emulator.")
                app.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if !app.isTerminated { app.forceTerminate() }
                }
            }
        } else {
            holdStart = nil
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--self-test") {
    let now = Date()
    precondition(!comboComplete(since: nil, now: now))
    precondition(!comboComplete(since: now.addingTimeInterval(-1.9), now: now))
    precondition(comboComplete(since: now.addingTimeInterval(-2), now: now))
    print("Controller quit policy passed; no apps were touched.")
    exit(0)
}
guard arguments.count == 3, arguments[1] == "--binary", arguments[2].hasPrefix("/") else {
    log("Expected --binary <absolute path of the emulator executable>.")
    exit(1)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let watcher = ControllerQuit(binary: URL(fileURLWithPath: arguments[2]))
application.delegate = watcher
application.run()
