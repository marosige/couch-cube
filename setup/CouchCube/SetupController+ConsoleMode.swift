import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import ServiceManagement
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
                self.autoLaunchStatus.isHidden = false
                self.activityNeeded()
                return
            }
            do {
                let settings = try JSONDecoder().decode(AutoLaunchSettings.self, from: data)
                self.autoLaunchToggle.state = settings.enabled ? .on : .off
                self.autoLaunchDelay.stringValue = String(settings.delay)
                self.autoLaunchLoaded = true
                self.autoLaunchStatus.stringValue = settings.legacy
                    ? "An older Steam-only launcher is set up. Choose an option below to replace it." : ""
                self.renderConsoleMode()
                self.renderGeneral()
            } catch {
                self.overviewCheckFailures.insert(.automatic)
                self.autoLaunchStatus.stringValue = "Cannot read login settings: \(error.localizedDescription)"
                self.autoLaunchStatus.isHidden = false
                self.append(self.autoLaunchStatus.stringValue + "\n")
                self.activityNeeded()
            }
        }
    }

    @objc func saveAutoLaunch() {
        guard autoLaunchLoaded else {
            autoLaunchStatus.stringValue = "Login settings haven't loaded. Reopen Console Mode to try again."
            autoLaunchStatus.isHidden = false
            return
        }
        let enabled = autoLaunchToggle.state == .on
        guard !enabled || (selected != nil && report?.state == "valid layout" && report?.issues.isEmpty == true) else {
            autoLaunchStatus.stringValue = "Choose Settings → Game library before enabling automatic console mode."
            autoLaunchStatus.isHidden = false
            return
        }
        guard let delay = Int(autoLaunchDelay.stringValue), (5...300).contains(delay) else {
            autoLaunchStatus.stringValue = "Enter a whole number between 5 and 300 seconds."
            autoLaunchStatus.isHidden = false
            return
        }
        var arguments = ["login", "--confirm", "--delay", String(delay)]
        if enabled, let drive = selected { arguments += ["--root", drive.root] }
        if !enabled { arguments.append("--disable") }
        execute(arguments) { code, _ in
            if code == 0 { self.loadAutoLaunch(); if enabled { self.setLoginItem(false) } }
            else {
                self.autoLaunchStatus.stringValue = "Couldn't save console mode. Open Details for the error."
                self.autoLaunchStatus.isHidden = false
                self.activityNeeded()
            }
        }
    }

    // MARK: Console Mode: three plain questions, answered by tapping a row

    /// A choice in a list: icon, title and one line of explanation, with a checkmark on the chosen one.
    func choiceRow(_ title: String, subtitle: String, symbol: String, color: NSColor, selected: Bool,
                   enabled: Bool = true, id: String, action: @escaping () -> Void) -> NSView {
        let row = ClickableRowView()
        row.layer?.cornerRadius = 8
        row.setAccessibilityIdentifier("choice-" + id)
        row.setAccessibilityRole(.radioButton)
        row.setAccessibilityLabel(title + ". " + subtitle + (selected ? ". Selected" : ""))
        row.setAccessibilityValue(selected ? 1 : 0)
        if enabled { row.onActivate = action }
        let check = NSImageView(image: NSImage(systemSymbolName: selected ? "checkmark.circle.fill" : "circle",
                                                accessibilityDescription: nil)!)
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        check.contentTintColor = selected ? .controlAccentColor : .tertiaryLabelColor
        let line = settingsRow(title, subtitle: subtitle, symbol: symbol, color: enabled ? color : .systemGray, trailing: check)
        line.alphaValue = enabled ? 1 : 0.5
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            line.topAnchor.constraint(equalTo: row.topAnchor),
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        if selected { row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor }
        return row
    }

    /// macOS's own automatic-login setting (readable by everyone; only System Settings changes it).
    var automaticLoginUser: String? {
        NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.loginwindow.plist")?["autoLoginUser"] as? String
    }

    var consoleSignIn: String {
        // The saved choice wins, so "auto" can be picked to show its guide before macOS has it on.
        UserDefaults.standard.string(forKey: "consoleSignIn") ?? (automaticLoginUser != nil ? "auto" : "password")
    }

    var loginItemEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    /// Opens Couch Cube (in its window) at login, through macOS's own Login Items.
    func setLoginItem(_ enabled: Bool) {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"), loginItemEnabled != enabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            autoLaunchStatus.stringValue = "macOS didn't allow the login item: \(error.localizedDescription). Check System Settings \u{203A} General \u{203A} Login Items."
            autoLaunchStatus.isHidden = false
        }
    }

    var consoleAfterLogin: String {
        autoLaunchToggle.state == .on ? "tv" : loginItemEnabled ? "window" : "none"
    }

    func addChoice(_ row: NSView, to list: NSStackView) {
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    func renderConsoleMode() {
        clearRows(signInChoices)
        clearRows(signInGuide)
        let signIn = consoleSignIn
        for (id, title, subtitle, symbol, color) in [
            ("password", "Type your password", "Like any Mac: at the login screen and when it wakes.", "key.fill", NSColor.systemGray),
            ("watch", "Password once, then Apple Watch", "Type it once after a restart; then your Apple Watch unlocks it when it wakes.", "applewatch", .systemBlue),
            ("auto", "Start without signing in", "Starts straight into your gaming account, and wakes without a password.", "bolt.fill", .systemOrange)
        ] {
            addChoice(choiceRow(title, subtitle: subtitle, symbol: symbol, color: color, selected: signIn == id, id: "signin-" + id) { [weak self] in
                UserDefaults.standard.set(id, forKey: "consoleSignIn")
                self?.renderConsoleMode()
            }, to: signInChoices)
        }
        if signIn == "watch" {
            signInGuide.addArrangedSubview(text("Turn on \u{201C}Use Apple Watch to unlock\u{201D} in Touch ID & Password.", size: 12, secondary: true))
            signInGuide.addArrangedSubview(button("Open Touch ID & Password", #selector(openAppleWatchUnlockSettings)))
        } else if signIn == "auto" {
            if let user = automaticLoginUser {
                signInGuide.addArrangedSubview(text("Automatic login is on for \u{201C}\(user)\u{201D}.", size: 12, secondary: true))
            } else {
                for step in ["1. In Users & Groups, add a Standard user for gaming.",
                             "2. Sign in as that user and set up Couch Cube there.",
                             "3. Choose that user under \u{201C}Automatically log in as\u{201D}.",
                             "4. In Lock Screen, set \u{201C}Require password after the display is turned off\u{201D} to Never.",
                             "This needs FileVault off, which lowers protection for the whole Mac."] {
                    signInGuide.addArrangedSubview(text(step, size: 12, secondary: step.first?.isNumber == false))
                }
            }
            signInGuide.addArrangedSubview(row([button("Users & Groups", #selector(openUsersAndGroups)),
                                                button("Lock Screen", #selector(openLockScreenSettings)),
                                                button("FileVault", #selector(openFileVaultSettings)),
                                                button("Apple Guide", #selector(openAutomaticLoginGuide))]))
        }
        signInGuide.isHidden = signInGuide.arrangedSubviews.isEmpty

        clearRows(afterLoginChoices)
        let after = consoleAfterLogin
        for (id, title, subtitle, symbol, color) in [
            ("none", "Nothing", "Open Couch Cube yourself when you want to play.", "moon.fill", NSColor.systemGray),
            ("window", "Open Couch Cube", "In its window, like any app.", "macwindow", .systemBlue),
            ("tv", "Open the TV menu", "The true console experience: when a controller is on and no keyboard or mouse is connected.", "tv.fill", .systemGreen)
        ] {
            addChoice(choiceRow(title, subtitle: subtitle, symbol: symbol, color: color, selected: after == id,
                                                           enabled: autoLaunchLoaded, id: "after-" + id) { [weak self] in
                self?.chooseAfterLogin(id)
            }, to: afterLoginChoices)
        }
        consoleDelayRow.isHidden = after != "tv"
        autoLaunchStatus.isHidden = autoLaunchStatus.stringValue.isEmpty

        clearRows(tvMenuChoices)
        for (id, title, subtitle, symbol, color) in [
            ("steam", "Steam Big Picture", "Your Steam games, made for the TV.", "gamecontroller.fill", NSColor.systemBlue),
            ("es-de", "ES-DE", "Your retro consoles and games.", "arcade.stick", .systemRed)
        ] {
            let installed = appStates.first { $0.id == id }?.installed ?? report.map { !$0.missing.contains(id) } ?? false
            addChoice(choiceRow(title, subtitle: installed ? subtitle : "Not installed \u{2014} get it in App Store.",
                                                       symbol: symbol, color: color, selected: effectiveFrontend == id,
                                                       id: "menu-" + id) { [weak self] in
                guard let self else { return }
                if let index = self.appStates.firstIndex(where: { $0.id == id && $0.installed }) {
                    let control = NSButton()
                    control.tag = index
                    self.setDefaultMenu(control)
                } else {
                    self.showAppStoreRow(id)
                }
            }, to: tvMenuChoices)
        }
        addChoice(choiceRow("Cube TV Home", subtitle: "Couch Cube's own TV home screen \u{2014} coming soon.",
                                                   symbol: "sparkles.tv.fill", color: .systemPurple, selected: false,
                                                   enabled: false, id: "menu-couchcube") {}, to: tvMenuChoices)
    }

    func chooseAfterLogin(_ mode: String) {
        guard autoLaunchLoaded else { return }
        switch mode {
        case "tv":
            guard selected != nil, report?.state == "valid layout", report?.issues.isEmpty == true else {
                autoLaunchStatus.stringValue = "Set up your game library first (Settings \u{203A} Game library)."
                autoLaunchStatus.isHidden = false
                return
            }
            autoLaunchToggle.state = .on
            saveAutoLaunch()
        case "window":
            setLoginItem(true)
            if autoLaunchToggle.state == .on { autoLaunchToggle.state = .off; saveAutoLaunch() }
        default:
            setLoginItem(false)
            if autoLaunchToggle.state == .on { autoLaunchToggle.state = .off; saveAutoLaunch() }
        }
        renderConsoleMode()
    }

    @objc func consoleDelayChanged() {
        if autoLaunchToggle.state == .on { saveAutoLaunch() }
    }

    func showAppStoreRow(_ id: String) {
        highlightedAppID = id
        selectPage(1)
        loadPageData(1)
    }

    @objc func openAppleWatchUnlockSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
