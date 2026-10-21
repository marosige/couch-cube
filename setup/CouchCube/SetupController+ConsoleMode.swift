import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func loadAutoLaunch() {
        guard task == nil else { return }
        overviewChecks.insert(.automatic)
        overviewCheckFailures.remove(.automatic)
        defer { renderGeneral() }
        execute(["login-status"], capture: true) { code, data in
            self.overviewChecks.remove(.automatic)
            defer {
                self.renderGeneral()
                if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    if self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!) == 10 { self.loadApps() }
                    else { self.loadSteamStatus() }
                }
            }
            guard code == 0 else {
                self.overviewCheckFailures.insert(.automatic)
                self.autoLaunchStatus.stringValue = "Cannot read login settings. Open Details for the error."
                self.activityNeeded()
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
                self.renderGeneral()
            } catch {
                self.overviewCheckFailures.insert(.automatic)
                self.autoLaunchStatus.stringValue = "Cannot read login settings: \(error.localizedDescription)"
                self.append(self.autoLaunchStatus.stringValue + "\n")
                self.activityNeeded()
            }
        }
    }

    @objc func saveAutoLaunch() {
        guard autoLaunchLoaded else {
            autoLaunchStatus.stringValue = "Login settings haven't loaded. Reopen Console Mode to try again."
            return
        }
        let enabled = autoLaunchToggle.state == .on
        guard !enabled || (selected != nil && report?.state == "valid layout" && report?.issues.isEmpty == true) else {
            autoLaunchStatus.stringValue = "Choose Settings → Game library before enabling automatic console mode."
            return
        }
        guard let delay = Int(autoLaunchDelay.stringValue), (5...300).contains(delay) else {
            autoLaunchStatus.stringValue = "Enter a whole number between 5 and 300 seconds."
            return
        }
        let alert = NSAlert()
        alert.messageText = enabled ? "Enable automatic console mode on this Mac?" : "Turn off automatic console mode?"
        alert.informativeText = enabled
            ? "Starting at your next macOS login, wait \(delay) seconds. If no keyboard or mouse is connected, wait for a controller and open your default TV menu.\n\nNo passwords or automatic macOS login are configured. Keep Couch Cube at:\n\(Bundle.main.bundleURL.path)\n\nIf you move or replace the app or game library, save this setting again. macOS may manage this under Login Items."
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
                self.activityNeeded()
            }
        }
    }
}
