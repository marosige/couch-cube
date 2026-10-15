import AppKit
import GameController
import IOKit

enum ConsoleDecision {
    case wait, stop, launch
}

func decision(elapsed: TimeInterval, delay: TimeInterval, hasDesktopInput: Bool,
              hasController: Bool) -> ConsoleDecision {
    if elapsed < delay { return .wait }
    if hasDesktopInput { return .stop }
    return hasController ? .launch : .wait
}

func desktopInputConnected() throws -> Bool {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator)
    guard result == KERN_SUCCESS else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(result),
                      userInfo: [NSLocalizedDescriptionKey: "Cannot check connected keyboards and mice."])
    }
    defer { IOObjectRelease(iterator) }
    var found = false
    while true {
        let device = IOIteratorNext(iterator)
        if device == 0 { break }
        defer { IOObjectRelease(device) }
        func property(_ name: String) -> Any? {
            IORegistryEntryCreateCFProperty(device, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let pairs = property("DeviceUsagePairs") as? [[String: Any]] ?? []
        let primary = ["DeviceUsagePage": property("PrimaryUsagePage") ?? 0,
                       "DeviceUsage": property("PrimaryUsage") ?? 0]
        for pair in pairs + [primary] {
            let page = (pair["DeviceUsagePage"] as? NSNumber)?.intValue
            let usage = (pair["DeviceUsage"] as? NSNumber)?.intValue
            if page == 1, let usage = usage, [1, 2, 6, 7].contains(usage) {
                found = true
            }
        }
    }
    return found
}

func log(_ message: String) {
    FileHandle.standardError.write(Data(("Couch Cube: " + message + "\n").utf8))
}

final class ConsoleAutoLaunch: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private let started = ProcessInfo.processInfo.systemUptime
    private let delay: TimeInterval
    private var opening = false
    private var launcher: Process?

    init(delay: TimeInterval) { self.delay = delay }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GCController.shouldMonitorBackgroundEvents = true
        log("Waiting \(Int(delay)) seconds after login, then checking desktop input and controllers.")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    private func check() {
        guard !opening, ProcessInfo.processInfo.systemUptime - started >= delay else { return }
        do {
            let action = decision(elapsed: ProcessInfo.processInfo.systemUptime - started, delay: delay,
                                  hasDesktopInput: try desktopInputConnected()
                                    || GCKeyboard.coalesced != nil || GCMouse.current != nil,
                                  hasController: !GCController.controllers().isEmpty)
            switch action {
            case .wait: return
            case .stop:
                log("Keyboard or mouse connected. Console auto-launch skipped for this login.")
                NSApp.terminate(nil)
            case .launch:
                opening = true
                timer?.invalidate()
                if let root = ProcessInfo.processInfo.environment["COUCH_CUBE_ROOT"] {
                    let resources = Bundle.main.resourceURL!
                    let process = Process()
                    process.executableURL = resources.appendingPathComponent("python/bin/python3")
                    process.arguments = ["-I", "-B", resources.appendingPathComponent("scripts/console.py").path,
                                         "console", "--root", root]
                    let errors = Pipe()
                    process.standardError = errors
                    process.standardInput = FileHandle.nullDevice
                    launcher = process
                    do { try process.run() }
                    catch { fail("Cannot start console mode: " + error.localizedDescription); return }
                    DispatchQueue.global().async {
                        let data = errors.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        DispatchQueue.main.async {
                            if process.terminationStatus != 0 {
                                self.fail(String(decoding: data, as: UTF8.self))
                            } else {
                                log("Console session finished.")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                    return
                }
                guard let steam = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "steam://open/bigpicture")!) else {
                    fail("Steam is not installed. Open Couch Cube > Game players to install it.")
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([URL(string: "steam://open/bigpicture")!], withApplicationAt: steam,
                                        configuration: configuration) { _, error in
                    DispatchQueue.main.async {
                        if let error = error { self.fail("Cannot open Steam: " + error.localizedDescription) }
                        else {
                            log("Controller connected. Steam Big Picture opened.")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        log(message)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couch Cube couldn't start console mode"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--self-test") {
    precondition(decision(elapsed: 29, delay: 30, hasDesktopInput: false, hasController: true) == .wait)
    precondition(decision(elapsed: 30, delay: 30, hasDesktopInput: false, hasController: true) == .launch)
    precondition(decision(elapsed: 30, delay: 30, hasDesktopInput: true, hasController: true) == .stop)
    precondition(decision(elapsed: 300, delay: 30, hasDesktopInput: false, hasController: false) == .wait)
    precondition(decision(elapsed: 301, delay: 30, hasDesktopInput: false, hasController: true) == .launch)
    precondition(decision(elapsed: 301, delay: 30, hasDesktopInput: true, hasController: false) == .stop)
    precondition(decision(elapsed: 4, delay: 5, hasDesktopInput: false, hasController: true) == .wait)
    precondition(decision(elapsed: 5, delay: 5, hasDesktopInput: false, hasController: true) == .launch)
    print("Console auto-launch policy passed; no login settings changed or apps launched.")
    exit(0)
}
if arguments.contains("--probe") {
    do { print("Desktop input connected: \(try desktopInputConnected())") }
    catch { log(error.localizedDescription); exit(1) }
    exit(0)
}
guard arguments.count == 3, arguments[1] == "--delay", let seconds = Int(arguments[2]),
      (5...300).contains(seconds) else {
    log("Expected --delay <5-300 seconds>.")
    exit(1)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = ConsoleAutoLaunch(delay: TimeInterval(seconds))
application.delegate = controller
application.run()
