import AppKit
import CoreBluetooth
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
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
    var preferred_frontend: String? = nil
}

struct FrontendPreference: Decodable {
    let preferred: String?
}

struct SteamLibraryReport: Decodable {
    let libraries: [SteamLibrary]
    let errors: [String]
}

struct SteamLibrary: Decodable {
    let path: String
    let available: Bool
    let games: [SteamGame]
}

struct SteamGame: Decodable {
    let appid: String
    let name: String
    let state: String
    let installed: Bool
    let bytes: Int64?
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
    let bios: BIOSStatus?
    var emulator_installed: Bool? = nil
}

struct BIOSStatus: Decodable {
    let state: String
    let summary: String
    let files: [BIOSFileStatus]
}

struct BIOSFileStatus: Decodable {
    let filename: String
    let path: String
    let present: Bool
    let note: String
}

enum ConsoleArtwork {
    static let groups: [(title: String, systems: [String])] = [
        ("Nintendo home consoles", ["nes", "snes", "n64", "gc", "wii", "wiiu", "switch"]),
        ("Nintendo handhelds", ["gb", "gbc", "gba"]),
        ("PlayStation", ["psx", "ps2", "psp", "ps3"]),
        ("SEGA", ["megadrive", "segacd", "dreamcast"])
    ]

    static func image(for id: String) -> NSImage {
        // Original hardware-inspired drawings, without manufacturer logos.
        NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat = 2) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                             xRadius: radius, yRadius: radius).stroke()
            }
            func line(_ points: [NSPoint]) {
                let path = NSBezierPath()
                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.line(to: point) }
                }
                path.stroke()
            }
            func stroke(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat) {
                line([NSPoint(x: x, y: y), NSPoint(x: endX, y: endY)])
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 2) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
            }
            func disc(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).stroke()
            }
            func pad(_ x: CGFloat, _ y: CGFloat) {
                stroke(x - 2, y, x + 2, y)
                stroke(x, y - 2, x, y + 2)
            }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.white.setStroke()
            NSColor.white.setFill()
            let previousLineWidth = NSBezierPath.defaultLineWidth
            NSBezierPath.defaultLineWidth = 1.6
            defer { NSBezierPath.defaultLineWidth = previousLineWidth }
            switch id {
            case "nes":
                box(3, 7, 26, 18)
                stroke(3, 18, 29, 18)
                box(15, 10, 10, 5, 0)
                stroke(7, 22, 11, 22)
                dot(25, 21)
            case "snes":
                box(3, 9, 26, 16, 5)
                box(9, 7, 14, 9)
                stroke(12, 11, 20, 11)
                box(8, 19, 5, 3, 1)
                box(19, 19, 5, 3, 1)
            case "n64":
                line([NSPoint(x: 3, y: 24), NSPoint(x: 5, y: 13), NSPoint(x: 10, y: 10),
                      NSPoint(x: 22, y: 10), NSPoint(x: 27, y: 13), NSPoint(x: 29, y: 24),
                      NSPoint(x: 3, y: 24)])
                stroke(11, 13, 21, 13)
                for x in [7, 12, 18, 23] { dot(CGFloat(x), 20) }
            case "gc":
                box(6, 10, 20, 18, 3)
                box(11, 4, 10, 6, 2)
                disc(10, 12, 12)
                dot(10, 25)
                dot(20, 25)
            case "wii":
                line([NSPoint(x: 8, y: 27), NSPoint(x: 10, y: 5), NSPoint(x: 23, y: 3),
                      NSPoint(x: 23, y: 27), NSPoint(x: 8, y: 27)])
                stroke(19, 8, 19, 22)
                dot(12, 8)
                stroke(6, 29, 26, 29)
            case "wiiu":
                box(6, 4, 22, 9, 3)
                stroke(14, 8, 25, 8)
                box(2, 16, 28, 13, 4)
                box(9, 19, 14, 7, 1)
                pad(5, 22)
                dot(26, 21)
            case "switch":
                box(2, 7, 28, 18, 5)
                box(9, 9, 14, 14, 1)
                stroke(8, 8, 8, 24)
                stroke(24, 8, 24, 24)
                dot(4, 11, 2.5)
                dot(26, 18, 2.5)
            case "gb", "gbc":
                box(7, 2, 18, 28, id == "gb" ? 2 : 5)
                box(10, 5, 12, id == "gb" ? 10 : 11, 1)
                pad(12, 22)
                dot(19, 21)
                dot(22, 19)
                if id == "gb" { stroke(16, 27, 20, 27) }
                else { stroke(17, 26, 21, 25); stroke(17, 28, 21, 27) }
            case "gba":
                box(1, 7, 30, 18, 7)
                box(10, 10, 12, 12, 1)
                pad(5, 16)
                dot(25, 16)
                dot(28, 13)
            case "psx":
                box(2, 7, 28, 19, 3)
                disc(9, 9, 14)
                dot(5, 11, 3)
                dot(25, 11, 3)
                box(7, 23, 6, 2, 0)
                box(19, 23, 6, 2, 0)
            case "ps2":
                box(8, 3, 15, 26, 1)
                stroke(18, 3, 18, 29)
                for y in [8, 12, 16, 20] { stroke(10, CGFloat(y), 16, CGFloat(y)) }
                stroke(21, 7, 21, 20)
                stroke(5, 29, 27, 29)
            case "psp":
                box(1, 8, 30, 16, 7)
                box(10, 10, 12, 12, 1)
                pad(5, 16)
                for point in [(26, 12), (24, 15), (28, 15), (26, 18)] {
                    dot(CGFloat(point.0), CGFloat(point.1), 1.5)
                }
                dot(5, 20, 1.5)
            case "ps3":
                box(6, 3, 20, 26, 7)
                stroke(20, 5, 20, 27)
                stroke(23, 10, 23, 21)
                stroke(10, 25, 16, 25)
            case "megadrive":
                box(2, 8, 28, 18, 6)
                disc(9, 10, 14)
                stroke(12, 13, 20, 13)
                box(5, 22, 7, 3, 1)
                box(20, 22, 7, 3, 1)
            case "segacd":
                box(2, 4, 28, 14, 4)
                disc(11, 6, 10)
                box(2, 20, 28, 9, 2)
                box(13, 22, 14, 5, 1)
                dot(6, 24)
            case "dreamcast":
                box(3, 5, 26, 23, 4)
                disc(8, 7, 16)
                stroke(11, 9, 21, 9)
                for x in [7, 12, 18, 23] { dot(CGFloat(x), 25) }
            default:
                box(4, 6, 24, 20, 4)
                pad(11, 16)
                dot(22, 15)
            }
            return true
        }
    }
}

struct PairedController {
    let name: String
    let address: String
    let connected: Bool
}

struct ControllerEntry: Codable {
    let id: String
    var name: String
    var connected: Bool
    var transport: String
}

struct ControllerCustomization: Codable {
    var name: String
    var color: String
}

func controllerAddress(_ value: String) -> String? {
    let address = value.lowercased().filter { $0.isHexDigit }
    return address.count == 12 ? address : nil
}

func hidControllerEntry(_ device: IOHIDDevice) -> ControllerEntry {
    func property(_ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString).map { String(describing: $0) } ?? ""
    }
    let transport = property(kIOHIDTransportKey)
    let serial = property(kIOHIDSerialNumberKey)
    var registryID: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
    let address = transport.hasPrefix("Bluetooth") ? controllerAddress(serial) : nil
    let location = property(kIOHIDLocationIDKey)
    let identity = !serial.isEmpty ? "serial:\(serial)" : !location.isEmpty && location != "0" ?
        "location:\(location)" : "session:\(registryID)"
    let id = address.map { "bt:\($0)" } ??
        "hid:\(property(kIOHIDVendorIDKey)):\(property(kIOHIDProductIDKey)):\(transport):\(identity)"
    let name = property(kIOHIDProductKey)
    return ControllerEntry(id: id, name: name.isEmpty ? "Game controller" : name,
        connected: true, transport: transport == "USB" ? "Wired" :
            transport.hasPrefix("Bluetooth") ? "Bluetooth" : "Wireless / Other")
}

func controllerInputDescription(page: UInt32, usage: UInt32, value: Int,
                                minimum: Int, maximum: Int) -> String? {
    if page == 9 {
        return value == 0 ? nil : "Button \(usage) pressed"
    }
    guard page == 1 else { return nil }
    if usage == 0x39 {
        return value >= minimum && value <= maximum ? "D-pad · Direction \(value - minimum + 1)" : nil
    }
    let axes: [UInt32: String] = [0x30: "X", 0x31: "Y", 0x32: "Z", 0x33: "RX", 0x34: "RY", 0x35: "RZ"]
    guard let axis = axes[usage], maximum > minimum else { return nil }
    let normalized = (Double(value) - Double(minimum)) / (Double(maximum) - Double(minimum))
    guard abs(normalized - 0.5) > 0.2 else { return nil }
    return "Stick / trigger \(axis) · \(Int(normalized * 100))%"
}

func connectedHIDControllers() -> [ControllerEntry] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matches = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
    }
    IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    var result: [String: ControllerEntry] = [:]
    for device in devices {
        let entry = hidControllerEntry(device)
        result[entry.id] = entry
    }
    return result.values.sorted { $0.id < $1.id }
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

let settingsSectionBackground = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.18, alpha: 1) : .controlBackgroundColor
}

let settingsWindowBackground = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? .windowBackgroundColor : NSColor(calibratedWhite: 0.95, alpha: 1)
}

final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        settingsWindowBackground.setFill()
        dirtyRect.intersection(bounds).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class RoundedSidebarView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        settingsSectionBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class AppGetButton: NSButton {
    var destructive = false
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = destructive ? NSColor.white :
            NSColor(calibratedWhite: dark ? 0.25 : 0.92, alpha: 1)
        (isHighlighted ? background.blended(withFraction: 0.10, of: .black) ?? background : background).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if destructive {
            (isEnabled ? NSColor.systemRed : NSColor.disabledControlTextColor).setStroke()
            let minus = NSBezierPath()
            minus.lineWidth = 1.5
            minus.lineCapStyle = .round
            minus.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY))
            minus.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY))
            minus.stroke()
            return
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: isEnabled ? (destructive ? NSColor.systemRed : NSColor.controlAccentColor) : NSColor.disabledControlTextColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class ControllerLEDHousing: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 0.16 : 0.94, alpha: 1).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        shape.fill()
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

final class StorageChoiceButton: NSButton {
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        if !title.isEmpty { super.draw(dirtyRect) }
    }
}

final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, CBCentralManagerDelegate {
    private var window: NSWindow!
    private var mainWindow: NSWindow!
    private let detail = NSView()
    private let mainDetail = SettingsBackgroundView()
    private let sidebar = NSTableView()
    private var selectingPage = false
    private let sidebarPages = [9, -1, 0, 8, -1, 3, 1, 11, 7, 5, -1, 6, 2]
    private let sidebarTitles = ["Overview", "Play", "Play", "Controllers", "Console", "Setup", "Apps", "TV menu", "Consoles", "Steam setup", "Settings", "Game library", "Settings"]
    private let sidebarSymbols = ["square.grid.2x2", "", "play.fill", "gamecontroller", "", "checklist", "square.grid.2x2.fill", "tv.fill", "gamecontroller.fill", "tv.fill", "", "externaldrive.fill", "gearshape.fill"]
    private let screenTitle = NSTextField(labelWithString: "Overview")
    private let historyControl = NSSegmentedControl()
    private var pageHistory: [(page: Int, systemID: String?)] = []
    private var historyIndex = -1
    private var replayingHistory = false
    private var inspectorSystemID: String?
    private var preferredFrontend: String?
    private let tvMenuRows = NSStackView()
    private let tvMenuStatus = NSTextField(wrappingLabelWithString: "")
    private let updateAllButton = NSButton()
    private let generalRows = NSStackView()
    private let inspectorRows = NSStackView()
    private let inspectorTitle = NSTextField(labelWithString: "")
    private var inspectorParent = 1
    private let activeControllerRows = NSStackView()
    private let controllerStatus = NSTextField(wrappingLabelWithString: "")
    private var controllerAccessButton: NSButton!
    private var bluetoothManager: CBCentralManager?
    private var controllerTimer: Timer?
    private var controllerQueryRunning = false
    private var pairedControllers: [PairedController] = []
    private var controllerEntries: [ControllerEntry] = []
    private var controllerCustomizations: [String: ControllerCustomization] = [:]
    private var controllerInputManager: IOHIDManager?
    private let controllerTestStatus = NSTextField(wrappingLabelWithString: "Press a button or move a stick to identify and test a controller.")
    private var controllerInputLabels: [String: NSTextField] = [:]
    private var controllerLastInput: [String: (message: String, date: Date)] = [:]
    private let connectedFirstToggle = NSSwitch()
    private let controllerDefaultsKey = "controllerPreferences"
    private struct ControllerPreferences: Codable {
        var entries: [ControllerEntry]
        var customizations: [String: ControllerCustomization]
        var connectedFirst: Bool
    }
    private let volumeMenu = NSPopUpButton()
    private let driveRows = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    private let libraryTitle = NSTextField(labelWithString: "Choose your game drive")
    private let libraryDescription = NSTextField(wrappingLabelWithString: "Connect an SSD, or use this Mac's internal storage.")
    private let libraryAction = SetupActionButton()
    private var playAction: NSButton!
    private var playSteamMenu: NSButton!
    private var playRetroMenu: NSButton!
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
    private var appRefreshPending = false
    private let appMenuRows = NSStackView()
    private let appPCRows = NSStackView()
    private let appWindowsRows = NSStackView()
    private let appRetroRows = NSStackView()
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
    private var smokeSteamLoaded = false
    private var smokeOverviewRefreshed = false
    private let updateStatus = NSTextField(wrappingLabelWithString: "Checking for updates...")
    private let updateButton = NSButton()
    private var updateTask: Process?
    private var updateURL: URL?
    private var didRouteInitialLibrary = false
    private var preferredMode: String?
    private let navigationBar = NSStackView()
    private let sidebarPanel = RoundedSidebarView()
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
    private enum OverviewCheck: CaseIterable { case storage, menu, consoles, automatic, steam }
    private var overviewChecks = Set<OverviewCheck>()
    private var overviewCheckFailures = Set<OverviewCheck>()
    private var steamReport: SteamLibraryReport?
    private let steamLibraryRows = NSStackView()
    private let steamGuideRows = NSStackView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Couch Cube"
        window.minSize = NSSize(width: 960, height: 720)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let chrome = NSToolbar(identifier: "WindowChrome")
        chrome.showsBaselineSeparator = false
        chrome.allowsUserCustomization = false
        window.toolbar = chrome
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.backgroundColor = settingsWindowBackground
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
        let content = mainWindow.contentView!
        let sidebarBackground = sidebarPanel
        sidebarBackground.translatesAutoresizingMaskIntoConstraints = false
        mainDetail.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebarBackground)
        content.addSubview(mainDetail)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 960),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 720),
            sidebarBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            sidebarBackground.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            sidebarBackground.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 220),
            mainDetail.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: 12),
            mainDetail.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainDetail.topAnchor.constraint(equalTo: content.topAnchor),
            mainDetail.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        sidebarBackground.addSubview(navigationBar)
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 8),
            navigationBar.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: -8),
            navigationBar.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 54),
            navigationBar.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -12)
        ])
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
            detail.topAnchor.constraint(equalTo: mainDetail.topAnchor, constant: 48),
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
            stack.topAnchor.constraint(equalTo: detail.topAnchor),
            stack.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -16)
        ])
        historyControl.segmentCount = 2
        historyControl.trackingMode = .momentary
        historyControl.segmentStyle = .rounded
        historyControl.controlSize = .regular
        historyControl.target = self
        historyControl.action = #selector(historyClicked(_:))
        for (index, symbol, label) in [(0, "chevron.left", "Back"), (1, "chevron.right", "Forward")] {
            historyControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            historyControl.setWidth(28, forSegment: index)
            historyControl.setToolTip(label, forSegment: index)
        }
        screenTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let screenHeader = row([historyControl, screenTitle])
        screenHeader.spacing = 12
        screenHeader.translatesAutoresizingMaskIntoConstraints = false
        mainDetail.addSubview(screenHeader)
        NSLayoutConstraint.activate([
            screenHeader.leadingAnchor.constraint(equalTo: mainDetail.leadingAnchor),
            screenHeader.topAnchor.constraint(equalTo: mainDetail.topAnchor, constant: 12),
            screenHeader.heightAnchor.constraint(equalToConstant: 28),
            historyControl.widthAnchor.constraint(equalToConstant: 68)
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
        let playDescription = text("Opens your default TV menu. Change it in TV menu.", secondary: true)
        playDescription.alignment = .center
        playSteamMenu = button("Open Steam Big Picture", #selector(playChosenMenu(_:)))
        playSteamMenu.tag = 0
        playRetroMenu = button("Open ES-DE", #selector(playChosenMenu(_:)))
        playRetroMenu.tag = 1
        let ownMenu = NSButton(title: "Coming soon", target: nil, action: nil)
        ownMenu.bezelStyle = .rounded
        ownMenu.isEnabled = false
        libraryControls += [playSteamMenu, playRetroMenu]
        let library = column([
            pageHeading("Play", "Your games. One big screen."),
            primary(play),
            playDescription,
            card("Open another menu", subtitle: "Launch a different menu without changing your default.", views: [
                settingsRow("Steam Big Picture", subtitle: "Steam games on the big screen.", symbol: "tv.fill",
                            color: .systemBlue, trailing: playSteamMenu),
                separator(),
                settingsRow("ES-DE", subtitle: "Your retro game menu.", symbol: "gamecontroller.fill",
                            color: .systemPurple, trailing: playRetroMenu),
                separator(),
                settingsRow("Couch Cube Launcher", subtitle: "Our own TV menu. Not available yet.", symbol: "cube.fill",
                            color: .systemGray, trailing: ownMenu)
            ]),
            card("Ready for the couch?", subtitle: nil, views: [
                setupSummary,
                row([button("Apps & emulators", #selector(showPlayers)),
                     button("Steam & controller setup", #selector(showFinishing))]),
                button("Check status", #selector(checkStorage))
            ])
        ])
        library.alignment = .leading
        addPage("Play", content: library)

        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        helperButton = button("Install Homebrew...", #selector(homebrew))
        helperAdvice.textColor = .secondaryLabelColor
        let apps = column([
            pageHeading("Apps", "Game launchers and emulators for this Mac."),
            row([appsStatus, updateAllButton]),
            card("TV menus", subtitle: nil, views: [appMenuRows]),
            card("PC games", subtitle: nil, views: [appPCRows]),
            card("Windows games", subtitle: nil, views: [appWindowsRows]),
            card("Retro games", subtitle: nil, views: [appRetroRows]),
            helperAdvice,
            helperButton
        ])
        updateAllButton.title = "Update all"
        updateAllButton.target = self
        updateAllButton.action = #selector(updateAllApps)
        updateAllButton.bezelStyle = .rounded
        updateAllButton.setContentHuggingPriority(.required, for: .horizontal)
        updateAllButton.toolTip = "Update outdated Homebrew-managed apps. Other apps use their own updaters."
        updateAllButton.isEnabled = false
        actions.append(updateAllButton)
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
                "Open your default TV menu when a controller connects.", views: [
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
        let storageChoices = column([
            choice("This Mac", "Keep your game folders on this Mac.", symbol: "macmini", action: #selector(chooseLocal)),
            separator(),
            choice("External SSD", "Keep your game folders on an external drive.", symbol: "externaldrive", action: #selector(choosePortable))
        ])
        storageChoices.spacing = 0
        addPage("Welcome", content: column([
            pageHeading("Set up your console", "Choose a home for your games. Everything stays here in the sidebar."),
            card("Game storage", subtitle: "No games are moved. Steam keeps its current library unless you change it.", views: [
                setupFolderStatus,
                storageChoices
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
            storageAdvice,
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
            card("Steam libraries", subtitle: "See where your Steam games are installed. Change storage in Steam.", views: [
                steamGuideRows,
                row([button("Open Steam Storage", #selector(openSteamStorage)),
                     button("Refresh Steam status", #selector(refreshSteamStatus))])
            ]),
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
            ]),
            card("Steam games", subtitle: "Your installed Steam games, grouped by storage. Connect your SSD to see its games.", views: [
                steamLibraryRows,
                row([button("Open Steam Storage", #selector(openSteamStorage)),
                     button("Refresh Steam status", #selector(refreshSteamStatus))])
            ])
        ]))
        consoleRows.orientation = .vertical
        consoleRows.alignment = .leading
        consoleRows.spacing = 16
        addPage("Consoles", content: column([
            pageHeading("Consoles", "Choose which systems appear in your game menu."),
            consoleStatus,
            text("Switch on the consoles you want in your game menu. Hiding one keeps its games and saves.", size: 12, secondary: true),
            consoleRows,
            button("Apps & emulators", #selector(showPlayers))
        ]))
        for rows in [activeControllerRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        controllerAccessButton = controllerButton("Allow Bluetooth access", #selector(controllerBluetoothAccess))
        connectedFirstToggle.target = self
        connectedFirstToggle.action = #selector(controllerSortChanged)
        connectedFirstToggle.controlSize = .small
        connectedFirstToggle.setAccessibilityLabel("Show connected controllers first")
        loadControllerPreferences()
        addPage("Controllers", content: column([
            card("Connected Controllers", subtitle: "Your paired and connected controllers. Choose the pencil to set a name and color.", views: [
                settingsRow("Show connected first", subtitle: "Off keeps the list in its original order.",
                            symbol: "arrow.up.arrow.down", color: .systemGray, trailing: connectedFirstToggle),
                activeControllerRows
            ]),
            card("Searching...", subtitle: "Put a new controller in pairing mode, then open Bluetooth settings. This list refreshes automatically while you are here.", views: [
                controllerStatus, controllerAccessButton,
                row([controllerButton("Pair a controller...", #selector(addController)),
                     controllerButton("Controller settings", #selector(openGameControllerSettings))])
            ]),
            card("Controller test", subtitle: "Press a button or move a stick. The controller's name and signal appear here. Button numbers follow the controller, not a Steam button layout.", views: [
                controllerTestStatus
            ])
        ]))
        generalRows.orientation = .vertical
        generalRows.alignment = .leading
        generalRows.spacing = 0
        addPage("Overview", content: column([
            card("", subtitle: nil, views: [generalRows], inset: 6),
            text("Choose a row to get started or fix something that needs attention.", size: 12, secondary: true),
            button("Refresh status", #selector(refreshGeneral))
        ]))
        inspectorTitle.font = .systemFont(ofSize: 22, weight: .bold)
        inspectorRows.orientation = .vertical
        inspectorRows.alignment = .leading
        inspectorRows.spacing = 12
        addPage("Details", content: column([
            card("Details", subtitle: nil, views: [inspectorRows])
        ]))
        tvMenuRows.orientation = .vertical
        tvMenuRows.alignment = .leading
        tvMenuRows.spacing = 0
        addPage("TV menu", content: column([
            pageHeading("TV menu", "Choose the menu that opens from Play and automatic console mode."),
            card("Default menu", subtitle: "Use Steam Big Picture for a Steam-first console or ES-DE for a retro-first console. You can keep both installed.", views: [tvMenuStatus, tvMenuRows]),
            text("Steam can open ES-DE as a non-Steam shortcut. ES-DE can launch Steam shortcuts you configure. Installing a menu does not add games or shortcuts automatically.", size: 12, secondary: true)
        ]))
        navigationBar.orientation = .vertical
        navigationBar.alignment = .leading
        let brandImage = NSImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Console.icns"))!)
        brandImage.widthAnchor.constraint(equalToConstant: 44).isActive = true
        brandImage.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let brandLabels = column([text("Couch Cube", size: 16), text("Your Mac console", size: 11, secondary: true)])
        brandLabels.spacing = 5
        let sidebarLabel = row([brandImage, brandLabels])
        let brandLink = StorageChoiceButton(title: "", target: self, action: #selector(openWebsite))
        brandLink.isBordered = false
        brandLink.toolTip = "Couch Cube website & downloads"
        brandLink.setAccessibilityLabel("Couch Cube website & downloads")
        sidebarLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLink.addSubview(sidebarLabel)
        NSLayoutConstraint.activate([
            sidebarLabel.leadingAnchor.constraint(equalTo: brandLink.leadingAnchor),
            sidebarLabel.trailingAnchor.constraint(equalTo: brandLink.trailingAnchor),
            sidebarLabel.topAnchor.constraint(equalTo: brandLink.topAnchor),
            sidebarLabel.bottomAnchor.constraint(equalTo: brandLink.bottomAnchor)
        ])
        navigationBar.addArrangedSubview(brandLink)
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
        selectPage(9)
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
        column([text(subtitle, size: 13, secondary: true)])
    }

    private func primary(_ button: NSButton) -> NSButton {
        button.bezelStyle = .rounded
        button.isBordered = true
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    private func choice(_ title: String, _ description: String, symbol: String, action: Selector) -> NSView {
        let choose = StorageChoiceButton(title: "", target: self, action: action)
        choose.isBordered = false
        choose.setButtonType(.momentaryChange)
        choose.focusRingType = .exterior
        actions.append(choose)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let heading = text(title)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = column([heading, text(description, size: 12, secondary: true)])
        labels.spacing = 4
        let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let content = row([icon, labels, arrow])
        content.distribution = .fill
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        choose.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: choose.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: choose.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: choose.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: choose.bottomAnchor, constant: -12),
            choose.heightAnchor.constraint(greaterThanOrEqualToConstant: 68)
        ])
        choose.setAccessibilityLabel(title + ". " + description.replacingOccurrences(of: "\n", with: " "))
        return choose
    }

    @objc private func chooseLocal() { chooseMode("local") }
    @objc private func choosePortable() { chooseMode("portable") }

    private func chooseMode(_ mode: String) {
        guard task == nil else { status.stringValue = "Wait for the current operation before changing storage."; return }
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
    @objc private func showPlayOverview() { selectPage(0) }
    @objc private func showLibraryOverview() { selectPage(6); loadPageData(6) }
    @objc private func showConsoles() { selectPage(7); loadSystems() }

    @objc private func showFinishing() { selectPage(5); loadPageData(5) }

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
                ? "Sign in to Steam and use its existing Macintosh HD library. Open Steam Storage to choose the default install location. Couch Cube's folders are for retro games and launchers; existing Steam installs stay where they are."
                : "In Steam Storage → Add Drive, choose another location and select:\n\(path)\n\nCheck the path to identify your SSD. In its ••• menu, rename the Steam library Console Port if offered and choose Make Default. This is a Steam display name, not a disk rename. Use Steam's Move action for existing games.\n\nSteamCMD's force_install_dir does not configure the desktop client's default library. Couch Cube does not edit Steam's library database. Labels vary by Steam version."
            steamStorageAdvice.font = .systemFont(ofSize: 13)
            retroAdvice.stringValue = "In Steam desktop → Games → Add a Non-Steam Game to My Library → Browse, add:\n\(drive.root)/Launchers/Retro.app\n\nES-DE needs the emulators for the consoles you enabled, plus your own games and any BIOS/cores. Add registered game .app shortcuts from Launchers in the same way. Steam shortcuts are not added automatically."
        }
    }

    @objc private func openWebsite() {
        if !NSWorkspace.shared.open(URL(string: "https://marosige.github.io/couch-cube/")!) {
            status.stringValue = "Couldn't open the website: https://marosige.github.io/couch-cube/"
            append(status.stringValue + "\n")
        }
    }

    @objc private func openSteamStorage() {
        guard NSWorkspace.shared.open(URL(string: "steam://open/settings/storage")!) else {
            status.stringValue = "Couldn't open Steam Storage. Open Steam → Settings → Storage manually."
            append(status.stringValue + "\n")
            return
        }
    }

    @objc private func refreshSteamStatus() {
        guard task == nil else {
            status.stringValue = "Wait for the current operation before refreshing Steam status."
            return
        }
        loadSteamStatus()
    }

    private func steamStorageKind(_ library: SteamLibrary) -> String {
        guard library.available,
              let values = try? URL(fileURLWithPath: library.path).resourceValues(forKeys: [.volumeIsInternalKey]),
              let internalVolume = values.volumeIsInternal else { return "Storage type unknown" }
        return internalVolume ? "Local" : "External"
    }

    private var steamOverviewSummary: String {
        guard let report = steamReport else { return "Not checked" }
        if !report.errors.isEmpty { return "Couldn't read some games · Open Game library" }
        let online = report.libraries.filter { $0.available }
        let local = online.filter { steamStorageKind($0) == "Local" }.reduce(0) { $0 + $1.games.filter { $0.installed }.count }
        let external = online.filter { steamStorageKind($0) == "External" }.reduce(0) { $0 + $1.games.filter { $0.installed }.count }
        let unknown = online.filter { steamStorageKind($0) == "Storage type unknown" }.reduce(0) { $0 + $1.games.filter { $0.installed }.count }
        let offline = report.libraries.filter { !$0.available }.count
        return "\(local) local · \(external) external Steam games" +
            (unknown > 0 ? " · \(unknown) other" : "") + (offline > 0 ? " · \(offline) offline libraries" : "")
    }

    private func renderSteamLibraries() {
        for rows in [steamLibraryRows, steamGuideRows] {
            clearRows(rows)
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 8
            func add(_ view: NSView) {
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            if overviewChecks.contains(.steam) {
                let checking = row([statusIndicator("Checking Steam libraries...", color: .systemBlue, pulsing: true), NSView()])
                checking.distribution = .fill
                add(checking)
            }
            guard let report = steamReport else {
                add(text(overviewCheckFailures.contains(.steam) ? "Couldn't read Steam libraries. Open Activity for details." : "Steam libraries have not been checked yet.", size: 12, secondary: true))
                continue
            }
            for library in report.libraries {
                let count = library.games.filter { $0.installed }.count
                let label = selected.map { URL(fileURLWithPath: $0.root).appendingPathComponent("SteamLibrary").standardizedFileURL.path == URL(fileURLWithPath: library.path).standardizedFileURL.path } == true ? "Console Port · " : ""
                add(text(label + (library.available ? "\(steamStorageKind(library)) · \(count) games installed" : "Disconnected · Connect this drive"), size: 12))
                add(text(library.path, size: 11, secondary: true))
                if rows === steamLibraryRows {
                    for game in library.games {
                        let size = game.bytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                        add(text("\(game.name) · \(game.state)\(size)", size: 11, secondary: true))
                    }
                }
            }
            if report.libraries.isEmpty && report.errors.isEmpty {
                add(text("No Steam games found yet. Open Steam to install your first game.", size: 12, secondary: true))
            }
            if !report.errors.isEmpty {
                add(text("Some games couldn't be checked. Open Steam, then refresh. Activity has technical details.", size: 11, secondary: true))
            }
            if overviewCheckFailures.contains(.steam) && report.errors.isEmpty {
                add(text("Refresh failed. Last results shown; see Activity.", size: 11, secondary: true))
            }
        }
    }

    private func loadSteamStatus() {
        guard task == nil else { return }
        overviewChecks.insert(.steam)
        overviewCheckFailures.remove(.steam)
        renderSteamLibraries()
        renderGeneral()
        execute(["steam-status"], capture: true) { code, data in
            self.overviewChecks.remove(.steam)
            defer { self.renderSteamLibraries(); self.renderGeneral() }
            guard code == 0 else {
                self.overviewCheckFailures.insert(.steam)
                self.append("Couldn't read Steam libraries. " + self.lastError + "\n")
                return
            }
            do {
                let report = try JSONDecoder().decode(SteamLibraryReport.self, from: data)
                self.steamReport = report
                if !report.errors.isEmpty {
                    self.overviewCheckFailures.insert(.steam)
                    self.append(report.errors.joined(separator: "\n") + "\n")
                }
            } catch {
                self.overviewCheckFailures.insert(.steam)
                self.append("Couldn't decode Steam libraries: \(error.localizedDescription)\n")
            }
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
            self.renderGeneral()
            if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8] { self.refreshControllers() }
        }
    }

    private let controllerColors: [(String, NSColor)] = [
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Pink", .systemPink),
        ("Green", .systemGreen), ("Red", .systemRed), ("Orange", .systemOrange),
        ("Yellow", .systemYellow), ("Gray", .systemGray)
    ]

    private func loadControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              let data = UserDefaults.standard.data(forKey: controllerDefaultsKey) else { return }
        do {
            let preferences = try JSONDecoder().decode(ControllerPreferences.self, from: data)
            controllerEntries = preferences.entries.map {
                var entry = $0
                entry.connected = false
                return entry
            }
            controllerCustomizations = preferences.customizations
            connectedFirstToggle.state = preferences.connectedFirst ? .on : .off
        } catch {
            append("Couldn't read controller names: \(error.localizedDescription)\n")
            controllerStatus.stringValue = "Couldn't read saved controller names. Activity has details."
        }
    }

    private func saveControllerPreferences() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        do {
            let preferences = ControllerPreferences(entries: controllerEntries.filter { !$0.id.contains("session:") },
                customizations: controllerCustomizations, connectedFirst: connectedFirstToggle.state == .on)
            let data = try JSONEncoder().encode(preferences)
            if data != UserDefaults.standard.data(forKey: controllerDefaultsKey) {
                UserDefaults.standard.set(data, forKey: controllerDefaultsKey)
            }
        } catch {
            controllerStatus.stringValue = "Couldn't save controller names. Activity has details."
            append("Couldn't save controller names: \(error.localizedDescription)\n")
        }
    }

    @objc private func controllerSortChanged() {
        saveControllerPreferences()
        renderControllerList()
    }

    @objc private func customizeController(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let entry = controllerEntries.first(where: { $0.id == id }) else { return }
        let previous = controllerCustomizations[id]
        let alert = NSAlert()
        alert.messageText = "Customize controller"
        alert.informativeText = "Choose a name and icon color in Couch Cube. Leave the name empty to use \(entry.name)."
        let name = NSTextField(string: previous?.name ?? "")
        name.placeholderString = entry.name
        let color = NSPopUpButton()
        color.addItems(withTitles: controllerColors.map { $0.0 })
        color.selectItem(withTitle: previous?.color ?? "Blue")
        let contents = column([name, color])
        contents.frame = NSRect(x: 0, y: 0, width: 300, height: 66)
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = contents
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controllerCustomizations[id] = ControllerCustomization(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                                               color: color.titleOfSelectedItem ?? "Blue")
        saveControllerPreferences()
        renderControllerList()
    }

    private func renderControllerList() {
        clearRows(activeControllerRows)
        controllerInputLabels = [:]
        let ordered = controllerEntries.enumerated().sorted {
            if connectedFirstToggle.state == .on && $0.element.connected != $1.element.connected {
                return $0.element.connected
            }
            return $0.offset < $1.offset
        }.map { $0.element }
        for entry in ordered {
            if !activeControllerRows.arrangedSubviews.isEmpty {
                let line = separator()
                activeControllerRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            }
            let customization = controllerCustomizations[entry.id]
            let customName = customization?.name ?? ""
            let edit = controllerButton("", #selector(customizeController(_:)))
            edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Customize controller")
            edit.identifier = NSUserInterfaceItemIdentifier(entry.id)
            edit.toolTip = "Rename and change icon color"
            edit.setAccessibilityLabel("Customize \(customName.isEmpty ? entry.name : customName)")
            let status = statusIndicator(entry.connected ? "Connected · \(entry.transport)" : "Not connected",
                                         color: entry.connected ? .systemGreen : .systemGray)
            let statusLine = row([status, NSView()])
            statusLine.distribution = .fill
            let activity = text("", size: 11, secondary: true)
            activity.isHidden = true
            controllerInputLabels[entry.id] = activity
            if let last = controllerLastInput[entry.id], Date().timeIntervalSince(last.date) < 1.5 {
                activity.stringValue = "Receiving input · " + last.message
                activity.isHidden = false
            }
            let info = column((customName.isEmpty ? [] : [text(entry.name, size: 11, secondary: true)]) + [statusLine, activity])
            let color = controllerColors.first { $0.0 == customization?.color }?.1 ?? .systemBlue
            let line = settingsRow(customName.isEmpty ? entry.name : customName, subtitle: "",
                symbol: "gamecontroller.fill", color: color, trailing: edit, detail: info)
            activeControllerRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: activeControllerRows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        }
        if ordered.isEmpty {
            activeControllerRows.addArrangedSubview(text("No controllers yet. Connect one by USB or pair it below.", size: 12, secondary: true))
        }
    }

    private func mergeControllerList(_ connected: [ControllerEntry], paired: [PairedController]) {
        var current = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for device in paired {
            guard let address = controllerAddress(device.address) else { continue }
            let id = "bt:\(address)"
            if current[id] == nil {
                current[id] = ControllerEntry(id: id, name: device.name, connected: device.connected, transport: "Bluetooth")
            } else {
                current[id]?.name = device.name
            }
        }
        for index in controllerEntries.indices {
            if let updated = current.removeValue(forKey: controllerEntries[index].id) {
                controllerEntries[index] = updated
            } else {
                controllerEntries[index].connected = false
            }
        }
        controllerEntries += current.values.sorted { $0.id < $1.id }
        controllerEntries.removeAll { !$0.connected && $0.id.contains("session:") }
        saveControllerPreferences()
        renderControllerList()
    }

    private func startControllerTest() {
        guard controllerInputManager == nil, !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context = context else { return }
            let owner = Unmanaged<SetupController>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard let message = controllerInputDescription(page: IOHIDElementGetUsagePage(element),
                    usage: IOHIDElementGetUsage(element), value: IOHIDValueGetIntegerValue(value),
                    minimum: IOHIDElementGetLogicalMin(element), maximum: IOHIDElementGetLogicalMax(element)) else { return }
            owner.receiveControllerInput(hidControllerEntry(device), message: message)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            controllerTestStatus.stringValue = "Couldn't start the controller test. Check macOS Privacy & Security → Input Monitoring if access was denied, then reopen this page."
            append("Controller input access failed: \(result)\n")
            return
        }
        controllerInputManager = manager
        controllerTestStatus.stringValue = "Press a button or move a stick to identify and test a controller."
    }

    private func stopControllerTest() {
        guard let manager = controllerInputManager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        controllerInputManager = nil
        controllerLastInput = [:]
    }

    private func receiveControllerInput(_ entry: ControllerEntry, message: String) {
        guard tabs.selectedTabViewItem === tabs.tabViewItems[8] else { return }
        let now = Date()
        if let last = controllerLastInput[entry.id], last.message == message && now.timeIntervalSince(last.date) < 0.1 { return }
        if !controllerEntries.contains(where: { $0.id == entry.id }) {
            controllerEntries.append(entry)
            renderControllerList()
        }
        controllerLastInput[entry.id] = (message, now)
        let name = controllerCustomizations[entry.id]?.name ?? ""
        controllerTestStatus.stringValue = "\(name.isEmpty ? entry.name : name) · \(message)"
        controllerInputLabels[entry.id]?.stringValue = "Receiving input · " + message
        controllerInputLabels[entry.id]?.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let last = self.controllerLastInput[entry.id],
                  last.date == now else { return }
            self.controllerInputLabels[entry.id]?.isHidden = true
        }
    }

    @objc private func refreshControllers() {
        guard tabs.selectedTabViewItem === tabs.tabViewItems[8], !controllerQueryRunning else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            controllerEntries = [
                ControllerEntry(id: "preview:1", name: "DualSense Wireless Controller", connected: true, transport: "Bluetooth"),
                ControllerEntry(id: "preview:2", name: "Xbox Wireless Controller", connected: false, transport: "Bluetooth"),
                ControllerEntry(id: "preview:3", name: "8BitDo Controller", connected: true, transport: "Wired")
            ]
            controllerCustomizations["preview:1"] = ControllerCustomization(name: "Purple PS5", color: "Purple")
            controllerStatus.stringValue = "Read-only preview. No Bluetooth query, pairing or permission request."
            controllerAccessButton.isHidden = true
            renderControllerList()
            return
        }
        controllerAccessButton.isHidden = CBManager.authorization == .allowedAlways
        switch CBManager.authorization {
        case .notDetermined:
            controllerAccessButton.title = "Allow Bluetooth access"
            controllerStatus.stringValue = "Allow Bluetooth access to show paired controllers. USB controllers work without it."
        case .denied, .restricted:
            controllerAccessButton.title = "Bluetooth privacy..."
            controllerStatus.stringValue = "Bluetooth access is off. Open Bluetooth privacy or pair in macOS Settings."
        case .allowedAlways:
            if bluetoothManager == nil {
                bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            controllerStatus.stringValue = bluetoothManager?.state == .poweredOff ?
                "Bluetooth is off. Turn it on in macOS Settings to pair a controller." :
                "Pair in macOS Bluetooth settings. Some Bluetooth LE pairings are only visible there."
        @unknown default:
            controllerStatus.stringValue = "Open macOS Bluetooth settings to pair a controller."
        }
        controllerQueryRunning = true
        let readBluetooth = CBManager.authorization == .allowedAlways
        DispatchQueue.global(qos: .userInitiated).async {
            let connected = connectedHIDControllers()
            let devices = readBluetooth ?
                (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> PairedController? in
                    let name = device.name ?? "Game controller"
                    guard isBluetoothController(deviceClass: device.classOfDevice, name: name) else { return nil }
                    return PairedController(name: name, address: device.addressString ?? "Address unavailable", connected: device.isConnected())
                } : []
            DispatchQueue.main.async {
                self.controllerQueryRunning = false
                guard self.tabs.selectedTabViewItem === self.tabs.tabViewItems[8] else { return }
                self.pairedControllers = CBManager.authorization == .allowedAlways ? devices : []
                self.mergeControllerList(connected, paired: self.pairedControllers)
            }
        }
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
        defer { renderGeneral() }
        clearRows(libraryHealth)
        guard let report = report, let drive = selected else {
            libraryHealth.addArrangedSubview(statusIndicator(selected == nil ? "No storage selected" : "Checking library", color: .systemYellow))
            setupSummary.stringValue = "Choose connected storage to check your folders and installed apps."
            playAction.isEnabled = false
            playSteamMenu.isEnabled = false
            playRetroMenu.isEnabled = false
            return
        }
        let foldersReady = report.state == "valid layout" && report.issues.isEmpty
        libraryHealth.addArrangedSubview(statusIndicator(foldersReady ? "Ready" : report.issues.isEmpty ? "Setup required" : "Needs attention",
                                                        color: foldersReady ? .systemGreen : report.issues.isEmpty ? .systemYellow : .systemRed))
        let steamInstalled = !report.missing.contains("steam")
        let retroInstalled = !report.missing.contains("es-de")
        let menu = effectiveFrontend
        playAction.title = menu == "steam" ? "Open Steam Big Picture" : menu == "es-de" ? "Open ES-DE" : "Install your TV menu to play"
        setupFolderStatus.stringValue = foldersReady ? "Connected: \(drive.root)" : "Choose storage below to create your game folders."
        setupAppStatus.stringValue = steamInstalled ? "Steam is installed. Optional emulators are managed in Apps." :
            retroInstalled ? "ES-DE is installed and is your console menu." : "Install Steam or ES-DE in Apps to get your TV menu."
        setupSummary.stringValue = foldersReady
            ? (menu == "steam" ? "Steam Big Picture is your TV menu.\nConnect a controller and choose a game in Steam." :
                menu == "es-de" ? "ES-DE is your TV menu.\nAdd your ROMs and install the emulators for your selected consoles." :
                "Your game folders are ready.\nInstall Steam or ES-DE in Apps to start playing.")
            : "Choose game storage in Setup first. No games will be moved."
        setupConnectionStatus.stringValue = drive.mode == "local"
            ? "Local Steam games stay in Steam's existing library. No storage change needed."
            : "For Steam games on the SSD, add its SteamLibrary in Steam → Settings → Storage."
        playAction.isEnabled = task == nil && foldersReady && menu != nil
        playSteamMenu.isEnabled = task == nil && foldersReady && steamInstalled
        playRetroMenu.isEnabled = task == nil && foldersReady && retroInstalled
    }

    private var effectiveFrontend: String? {
        guard report != nil || !appStates.isEmpty else { return nil }
        func installed(_ id: String) -> Bool {
            if let report = report { return !report.missing.contains(id) }
            return appStates.contains { $0.id == id && $0.installed }
        }
        if let preferred = preferredFrontend ?? report?.preferred_frontend {
            return installed(preferred) ? preferred : nil
        }
        return installed("steam") ? "steam" : installed("es-de") ? "es-de" : nil
    }

    private func renderGeneral() {
        clearRows(generalRows)
        let ready = report?.state == "valid layout" && report?.issues.isEmpty == true
        let frontend = effectiveFrontend
        let controllerCount = GCController.controllers().count
        func add(_ title: String, _ state: String, _ color: NSColor, _ symbol: String, _ action: Selector,
                 controllerCount: Int? = nil, check: OverviewCheck? = nil) {
            if !generalRows.arrangedSubviews.isEmpty {
                let line = separator()
                generalRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: generalRows.widthAnchor).isActive = true
            }
            let checking = check.map { overviewChecks.contains($0) } ?? false
            let failed = check.map { overviewCheckFailures.contains($0) } ?? false
            let statusText = checking && state == "Not checked" ? "Checking..." :
                failed ? (state == "Not checked" ? "Couldn't check · See Activity" : state + " · Refresh failed · See Activity") : state
            let statusView: NSView
            if let count = controllerCount {
                statusView = controllerOverviewStatus(count: count)
            } else {
                statusView = statusIndicator(statusText, color: checking ? .systemBlue : failed ? .systemYellow : color,
                                             pulsing: checking)
            }
            let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
            arrow.contentTintColor = .tertiaryLabelColor
            arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let statusLine = row([statusView, NSView()])
            statusLine.distribution = .fill
            let line = settingsRow(title, subtitle: "", symbol: symbol, color: .systemBlue,
                                   trailing: arrow, detail: statusLine)
            let view = StorageChoiceButton(title: "", target: self, action: action)
            view.isBordered = false
            view.setButtonType(.momentaryChange)
            view.setAccessibilityLabel(title + ". " + statusText + (checking && statusText != "Checking..." ? ". Refreshing" : ""))
            line.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
                line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
                line.topAnchor.constraint(equalTo: view.topAnchor),
                line.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            generalRows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: generalRows.widthAnchor).isActive = true
        }
        add("Play", report == nil ? "Not checked" : !ready ? "Set up game storage first" :
            frontend == "steam" ? "Ready · Steam Big Picture" : frontend == "es-de" ? "Ready · ES-DE" : "Install a TV menu",
            report == nil ? .systemGray : ready && frontend != nil ? .systemGreen : .systemYellow,
            "play.fill", #selector(showPlayOverview), check: .storage)
        add("Setup",
            ready ? "Game storage set up" : report == nil ? "Not checked" : report?.state == "not prepared" ? "Game storage not set up" : "Storage needs attention",
            report == nil ? .systemGray : ready ? .systemGreen : report?.state == "not prepared" ? .systemRed : .systemYellow,
            "externaldrive.fill", #selector(backToChoices), check: .storage)
        add("Game library", steamOverviewSummary,
            steamReport == nil ? .systemGray : overviewCheckFailures.contains(.steam) ? .systemYellow : .systemGreen,
            "folder.fill", #selector(showLibraryOverview), check: .steam)
        add("Apps", overviewAppSummary,
            report == nil && appStates.isEmpty ? .systemGray : installedAppCount(computerGameApps.union(emulatorApps)) > 0 ? .systemGreen : .systemRed,
            "square.grid.2x2.fill", #selector(showPlayers), check: .menu)
        let hasMenu = report.map { !$0.missing.contains("steam") || !$0.missing.contains("es-de") }
        add("TV menu", report == nil ? "Not checked" : frontend == "steam" ? "Steam Big Picture installed" :
            frontend == "es-de" ? "ES-DE installed" : hasMenu == true ? "Choose an installed default" : "Not installed",
            report == nil ? .systemGray : frontend != nil ? .systemGreen : hasMenu == true ? .systemYellow : .systemRed,
            "tv.fill", #selector(showTVMenus), check: .menu)
        add("Controllers", controllerCount == 0 ? "Not Connected" : "\(controllerCount) Connected", .systemGray,
            "gamecontroller.fill", #selector(showControllers), controllerCount: controllerCount)
        let enabled = consoleSystems.filter { $0.enabled }
        let missing = Set(enabled.filter { report?.missing.contains($0.package) == true }.map { $0.package })
        add("Console visibility",
            consoleSystems.isEmpty ? "Not checked" : enabled.isEmpty ? "No systems shown" : "\(enabled.count) systems shown" + (missing.isEmpty ? "" : " · Emulators needed"),
            consoleSystems.isEmpty || enabled.isEmpty ? .systemGray : missing.isEmpty ? .systemGreen : .systemYellow,
            "gamecontroller", #selector(showConsoles), check: .consoles)
        add("Steam setup", report == nil ? "Not checked" : report?.missing.contains("steam") == true ?
            "Steam not installed" : "Steam installed · Sign-in & storage guide",
            report == nil ? .systemGray : report?.missing.contains("steam") == true ? .systemRed : .systemGreen,
            "desktopcomputer", #selector(showFinishing), check: .menu)
        add("Settings",
            autoLaunchLoaded ? autoLaunchToggle.state == .on ? "Automatic console mode On" : "Automatic console mode Off" : "Not checked",
            !autoLaunchLoaded ? .systemGray : autoLaunchToggle.state == .on ? .systemGreen : .systemRed,
            "power", #selector(openSettings), check: .automatic)
    }

    private let computerGameApps: Set<String> = ["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge"]
    private let emulatorApps: Set<String> = ["retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]

    private func installedAppCount(_ ids: Set<String>) -> Int {
        if let report = report { return ids.subtracting(report.missing).count }
        return appStates.filter { ids.contains($0.id) && $0.installed }.count
    }

    private var overviewAppSummary: String {
        guard report != nil || !appStates.isEmpty else { return "Not checked" }
        let computer = installedAppCount(computerGameApps)
        let emulators = installedAppCount(emulatorApps)
        return "\(computer) PC game app\(computer == 1 ? "" : "s") · \(emulators) emulator\(emulators == 1 ? "" : "s") installed"
    }

    private func controllerOverviewStatus(count: Int) -> NSStackView {
        let dots = (0..<4).map { index -> NSImageView in
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            dot.contentTintColor = index < count ? .systemGreen : .systemGray
            dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            return dot
        }
        let leds = row(dots)
        leds.spacing = 5
        leds.translatesAutoresizingMaskIntoConstraints = false
        let housing = ControllerLEDHousing()
        housing.addSubview(leds)
        NSLayoutConstraint.activate([
            leds.leadingAnchor.constraint(equalTo: housing.leadingAnchor, constant: 8),
            leds.trailingAnchor.constraint(equalTo: housing.trailingAnchor, constant: -8),
            leds.centerYAnchor.constraint(equalTo: housing.centerYAnchor),
            housing.heightAnchor.constraint(equalToConstant: 20)
        ])
        let label = NSTextField(labelWithString: count == 0 ? "Not Connected" : "\(count) Connected")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let result = row([housing, label])
        result.spacing = 7
        result.setAccessibilityLabel(label.stringValue)
        return result
    }

    @objc private func refreshGeneral() {
        guard task == nil else { return }
        refresh()
    }

    private func loadGeneralDetails() {
        guard task == nil else { return }
        guard report?.state == "valid layout", let drive = selected else {
            consoleSystems = []
            overviewChecks.remove(.consoles)
            renderGeneral()
            loadAutoLaunch()
            return
        }
        execute(["systems", "--root", drive.root], capture: true) { code, data in
            self.overviewChecks.remove(.consoles)
            if code == 0 {
                do {
                    self.consoleSystems = try JSONDecoder().decode([ConsoleSystem].self, from: data)
                    self.renderSystems()
                } catch {
                    self.overviewCheckFailures.insert(.consoles)
                    self.status.stringValue = "Couldn't read console status: \(error.localizedDescription)"
                    self.append(self.status.stringValue + "\n")
                }
            } else {
                self.overviewCheckFailures.insert(.consoles)
                self.status.stringValue = "Couldn't read console status. Open Details for the error."
            }
            self.renderGeneral()
            self.loadAutoLaunch()
        }
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

    private func statusIndicator(_ title: String, color: NSColor, pulsing: Bool = false) -> NSView {
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.contentTintColor = color
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        if pulsing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            dot.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "checking")
        }
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
            if view is NSButton && !(view is StorageChoiceButton) {
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

    private func card(_ title: String, subtitle: String?, views: [NSView], inset: CGFloat = 16) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 12
        box.fillColor = settingsSectionBackground
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
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -inset)
        ])
        return box
    }

    private func settingsRow(_ title: String, subtitle: String, symbol: String, color: NSColor,
                             trailing: NSView, artwork: NSImage? = nil, detail: NSView? = nil) -> NSView {
        let icon = NSImageView(image: artwork ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
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
        if artwork != nil {
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            icon.imageScaling = .scaleProportionallyUpOrDown
        }
        let labels = column([text(title, size: 13), detail ?? text(subtitle, size: 11, secondary: true)])
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
        if !replayingHistory && (historyIndex < 0 || pageHistory[historyIndex].page != index ||
            (index == 10 && pageHistory[historyIndex].systemID != inspectorSystemID)) {
            pageHistory = Array(pageHistory.prefix(historyIndex + 1))
            pageHistory.append((index, index == 10 ? inspectorSystemID : nil))
            historyIndex = pageHistory.count - 1
        }
        historyControl.setEnabled(historyIndex > 0, forSegment: 0)
        historyControl.setEnabled(historyIndex + 1 < pageHistory.count, forSegment: 1)
        selectingPage = true
        defer { selectingPage = false }
        if index == 5 { updateSteamGuide() }
        tabs.selectTabViewItem(at: index)
        navigationBar.isHidden = false
        mainWindow.title = index == 0 ? "Couch Cube" : (sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube")
        screenTitle.stringValue = index == 10 ? inspectorTitle.stringValue : index == 4 ? "Game storage" :
            sidebarPages.firstIndex(of: index).map { sidebarTitles[$0] } ?? "Couch Cube"
        storageNext.isHidden = index != 4
        storageNext.keyEquivalent = index == 4 ? "\r" : ""
        playAction.keyEquivalent = index == 0 ? "\r" : ""
        let sidebarPage = index == 4 ? 3 : index == 10 ? inspectorParent : index
        if let selected = sidebarPages.firstIndex(of: sidebarPage), sidebar.selectedRow != selected {
            sidebar.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        controllerTimer?.invalidate()
        controllerTimer = nil
        if index != 8 { stopControllerTest() }
        if index == 8 {
            refreshControllers()
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                startControllerTest()
                controllerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshControllers() }
            }
        }
        if index == 9 { renderGeneral() }
    }

    @objc private func goBack() { navigateHistory(-1) }
    @objc private func goForward() { navigateHistory(1) }
    @objc private func historyClicked(_ sender: NSSegmentedControl) {
        navigateHistory(sender.selectedSegment == 0 ? -1 : 1)
    }

    private func navigateHistory(_ offset: Int) {
        let next = historyIndex + offset
        guard pageHistory.indices.contains(next) else { return }
        historyIndex = next
        replayingHistory = true
        defer { replayingHistory = false }
        let destination = pageHistory[next]
        if destination.page == 10, let id = destination.systemID,
           let index = consoleSystems.firstIndex(where: { $0.id == id }) {
            let sender = NSButton()
            sender.tag = index
            showConsoleDetails(sender)
        } else {
            selectPage(destination.page)
        }
        loadPageData(destination.page)
    }

    private func loadPageData(_ page: Int) {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        if page == 2 { loadAutoLaunch() }
        if page == 1 || page == 11 { loadApps() }
        if page == 7 { loadSystems() }
        if page == 5 || page == 6 { loadSteamStatus() }
        if page == 9 { refreshGeneral() }
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
        let colors: [Int: NSColor] = [9: .systemGray, 0: .systemGreen, 6: .systemOrange,
                                     1: .systemBlue, 11: .systemIndigo, 8: .systemBlue, 7: .systemPurple, 5: .systemIndigo]
        let cell = SettingsSidebarCell()
        cell.textField = label
        let image = NSImageView(image: NSImage(systemSymbolName: sidebarSymbols[row], accessibilityDescription: nil)!)
        image.contentTintColor = .white
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = (colors[sidebarPages[row]] ?? .systemGray).cgColor
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
        loadPageData(page)
    }

    @objc private func openSettings() {
        selectPage(2)
        loadAutoLaunch()
    }

    @objc private func loadApps() { fetchApps(updates: true) }

    private func fetchApps(updates: Bool, completed: ((Bool) -> Void)? = nil) {
        guard task == nil else {
            if completed == nil { appRefreshPending = true }
            appsStatus.stringValue = "An operation is running. App information will refresh when it finishes."
            completed?(false)
            return
        }
        appRefreshPending = false
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
                                             missing: self.appStates.filter { !$0.installed }.map { $0.id },
                                             preferred_frontend: self.preferredFrontend ?? report.preferred_frontend)
                    self.updateSetupSummary()
                }
                self.renderApps()
                self.renderTVMenus()
                precondition(self.appMenuRows.arrangedSubviews.count == 5)
                precondition(self.appPCRows.arrangedSubviews.count == 12)
                precondition(self.appWindowsRows.arrangedSubviews.count == 4)
                precondition(self.appRetroRows.arrangedSubviews.count == 12)
                precondition(Set([self.appMenuRows, self.appPCRows, self.appWindowsRows, self.appRetroRows]
                    .compactMap { $0.superview?.superview }.map { ObjectIdentifier($0) }).count == 4,
                    "Each Apps category must have its own card")
                self.appsStatus.stringValue = updates
                    ? self.appStates.first?.brew == true
                        ? "Update check complete. Self-updating and manual apps also have their own updaters."
                        : "Installed versions shown. Install Homebrew to check managed updates; other apps use their own updaters."
                    : "Installed versions shown below."
                self.execute(["frontend"], capture: true) { code, data in
                    guard code == 0 else {
                        self.tvMenuStatus.stringValue = "Couldn't read the default menu. Open Activity for details."
                        completed?(false)
                        return
                    }
                    do {
                        self.preferredFrontend = try JSONDecoder().decode(FrontendPreference.self, from: data).preferred
                        self.renderTVMenus()
                        self.updateSetupSummary()
                        completed?(true)
                    } catch {
                        self.tvMenuStatus.stringValue = "Couldn't read TV menu preference: \(error.localizedDescription)"
                        self.append(self.tvMenuStatus.stringValue + "\n")
                        completed?(false)
                    }
                }
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
        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] { clearRows(rows) }
        let order = ["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch", "porting-kit", "crossover"]
        appStates.sort { (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100) }
        if let steam = appStates.firstIndex(where: { $0.id == "steam" }) {
            addAppRow(appStates[steam], index: steam, to: appMenuRows, title: "Steam Big Picture",
                      purpose: "Steam TV menu")
        }
        for (index, app) in appStates.enumerated() {
            let rows = app.id == "es-de" ? appMenuRows :
                computerGameApps.contains(app.id) ? appPCRows :
                ["porting-kit", "crossover"].contains(app.id) ? appWindowsRows : appRetroRows
            addAppRow(app, index: index, to: rows)
        }
        addComingSoon(to: appMenuRows)
        updateAllButton.isEnabled = task == nil && appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
    }

    private let appPurposes = [
            "steam": "Steam games for Mac",
            "gog-galaxy": "GOG games for Mac",
            "ea": "EA games for Mac",
            "epic-games": "Epic Games for Mac",
            "battle-net": "Blizzard games · World of Warcraft",
            "curseforge": "World of Warcraft addons",
            "es-de": "Retro game TV menu",
            "retroarch-metal": "NES · SNES · Nintendo 64 · Game Boy · Game Boy Color · Game Boy Advance · PlayStation · PSP · Mega Drive · Sega CD · Dreamcast",
            "dolphin": "GameCube · Wii",
            "pcsx2": "PlayStation 2",
            "rpcs3": "PlayStation 3",
            "cemu-wiiu": "Wii U",
            "switch": "Nintendo Switch",
            "porting-kit": "Compatible Windows games on Mac",
            "crossover": "Compatible Windows games on Mac · Paid license or trial"
    ]

    private func appPillButton(_ title: String, app: ManagedApp, index: Int,
                               action: Selector, destructive: Bool = false) -> NSButton {
        let control = AppGetButton(title: destructive ? "" : title, target: self, action: action)
        control.destructive = destructive
        control.isBordered = false
        control.setButtonType(.momentaryChange)
        control.tag = index
        control.toolTip = "\(title) \(app.name)"
        control.setAccessibilityLabel("\(title) \(app.name)")
        control.widthAnchor.constraint(equalToConstant: destructive ? 26 : title == "Get" ? 64 : 76).isActive = true
        control.heightAnchor.constraint(equalToConstant: 26).isActive = true
        actions.append(control)
        return control
    }

    private func addAppRow(_ app: ManagedApp, index: Int, to rows: NSStackView, title: String? = nil,
                           purpose: String? = nil, menu: Bool = false) {
        let hasUpdate = app.installed && app.managed && app.update?.isEmpty == false
        let controls = row([])
        if app.id == "crossover" && app.installed {
            let open = button("Open", #selector(openCrossOver(_:)))
            open.tag = index
            controls.addArrangedSubview(open)
        }
        if menu && app.installed {
            if effectiveFrontend == app.id {
                let label = NSTextField(labelWithString: "Default")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                controls.addArrangedSubview(label)
            } else {
                let choose = button("Make default", #selector(setDefaultMenu(_:)))
                choose.tag = index
                controls.addArrangedSubview(choose)
            }
        }
        if hasUpdate {
            controls.addArrangedSubview(appPillButton("Update", app: app, index: index, action: #selector(updateApp(_:))))
        }
        if app.installed {
            controls.addArrangedSubview(appPillButton("Remove", app: app, index: index,
                                                      action: #selector(appAction(_:)), destructive: true))
        } else {
            controls.addArrangedSubview(appPillButton("Get", app: app, index: index, action: #selector(appAction(_:))))
        }
        let state = app.installed ? (hasUpdate ? "Installed · Update available" : "Installed") : "Not installed"
        let statusLine = row([statusIndicator(state, color: app.installed ? hasUpdate ? .systemYellow : .systemGreen : .systemRed), NSView()])
        statusLine.toolTip = app.installed ? "Version \(app.version)" + (app.update.map { " · Update \($0) available" } ?? "") : nil
        statusLine.distribution = .fill
        let info = column([statusLine,
                           text(purpose ?? appPurposes[app.id] ?? app.name, size: 11, secondary: true)])
        info.spacing = 4
        let line = settingsRow(title ?? app.name, subtitle: "", symbol: menu ? "tv.fill" : "app.fill",
                               color: .systemBlue, trailing: controls, detail: info)
        if app.installed, let stack = line as? NSStackView, let first = stack.arrangedSubviews.first {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: app.path))
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
            stack.insertArrangedSubview(icon, at: 0)
        }
        rows.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        let separator = self.separator()
        rows.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private func addComingSoon(to rows: NSStackView) {
        let coming = NSButton(title: "Coming soon", target: nil, action: nil)
        coming.isEnabled = false
        coming.bezelStyle = .rounded
        let line = settingsRow("Couch Cube Launcher", subtitle: "Our own TV menu. Not available yet.",
                               symbol: "cube.fill", color: .systemGray, trailing: coming)
        rows.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private func renderTVMenus() {
        clearRows(tvMenuRows)
        tvMenuStatus.stringValue = effectiveFrontend == "steam" ? "Default: Steam Big Picture" :
            effectiveFrontend == "es-de" ? "Default: ES-DE" : "Install a menu, then choose your default."
        for id in ["steam", "es-de"] {
            if let index = appStates.firstIndex(where: { $0.id == id }) {
                addAppRow(appStates[index], index: index, to: tvMenuRows,
                          title: id == "steam" ? "Steam Big Picture" : "ES-DE", menu: true)
            }
        }
        addComingSoon(to: tvMenuRows)
    }

    @objc private func showTVMenus() { selectPage(11); loadApps() }

    @objc private func setDefaultMenu(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        execute(["frontend", "--default", app.id, "--confirm"]) { code, _ in
            if code == 0 {
                self.preferredFrontend = app.id
                self.renderTVMenus()
                self.updateSetupSummary()
            } else {
                self.tvMenuStatus.stringValue = "Couldn't save the default menu. Open Activity for details."
            }
        }
    }

    @objc private func updateAllApps() {
        let updates = appStates.filter { $0.installed && $0.managed && $0.update?.isEmpty == false }
        guard task == nil, !updates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Update \(updates.count) apps?"
        alert.informativeText = "Quit these apps first: " + updates.map { $0.name }.joined(separator: ", ") +
            ". Homebrew will update only these managed apps. Self-updating and manually installed apps use their own updaters."
        alert.addButton(withTitle: "Update all")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateNextApp(updates)
        showActivity()
    }

    private func updateNextApp(_ remaining: [ManagedApp]) {
        guard let app = remaining.first else { loadApps(); return }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            let message = "Quit \(app.name), then try Update all again."
            append(message + "\n")
            fetchApps(updates: false) { success in
                if success { self.appsStatus.stringValue = message }
            }
            return
        }
        execute(["manage-app", "--package", app.id, "--action", "update", "--confirm"]) { code, _ in
            if code == 0 { self.updateNextApp(Array(remaining.dropFirst())) }
            else {
                let message = "Update stopped at \(app.name). Open Activity for details."
                self.fetchApps(updates: false) { success in
                    if success { self.appsStatus.stringValue = message }
                }
            }
        }
    }

    @objc private func closeInspector() {
        selectPage(inspectorParent)
    }

    @objc private func showConsoleDetails(_ sender: NSButton) {
        guard consoleSystems.indices.contains(sender.tag) else { return }
        let system = consoleSystems[sender.tag]
        inspectorSystemID = system.id
        inspectorParent = 7
        inspectorTitle.stringValue = system.name
        clearRows(inspectorRows)
        let readiness = consoleReadiness(system)
        inspectorRows.addArrangedSubview(row([statusIndicator(emulatorName(system), color: readiness.color), NSView()]))
        let guidance = text(readiness.help, secondary: true)
        inspectorRows.addArrangedSubview(guidance)
        guidance.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
        let requirement = text(system.requirement, secondary: true)
        inspectorRows.addArrangedSubview(requirement)
        requirement.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
        if let bios = system.bios {
            let status = biosStatusView(bios)
            inspectorRows.addArrangedSubview(status)
            status.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
            for file in bios.files {
                let info = column([text(file.path, size: 11, secondary: true)])
                inspectorRows.addArrangedSubview(info)
                info.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
            }
            let disclaimer = text("Filename check only. Contents, authenticity and compatibility are not verified. Use only BIOS dumps you are entitled to use.", size: 11, secondary: true)
            inspectorRows.addArrangedSubview(disclaimer)
            disclaimer.widthAnchor.constraint(equalTo: inspectorRows.widthAnchor).isActive = true
            if bios.state != "present" && bios.state != "not-needed" {
                let query = system.name + " BIOS files"
                let copy = button("Copy search: \(query)", #selector(copyBIOSNames(_:)))
                copy.identifier = NSUserInterfaceItemIdentifier(query)
                let search = button("Google search", #selector(searchConsoleBIOS(_:)))
                search.identifier = NSUserInterfaceItemIdentifier(query)
                inspectorRows.addArrangedSubview(row([copy, search]))
            }
        }
        inspectorRows.addArrangedSubview(button("Manage emulator in Apps", #selector(inspectorApps)))
        selectPage(10)
    }

    @objc private func searchConsoleBIOS(_ sender: NSButton) {
        guard let query = sender.identifier?.rawValue else { return }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components.url, !NSWorkspace.shared.open(url) {
            status.stringValue = "Couldn't open Google. Copy the search text and paste it into your browser."
            append(status.stringValue + "\n")
        }
    }

    @objc private func inspectorApps() {
        clearRows(inspectorRows)
        showPlayers()
    }

    @objc private func openCrossOver(_ sender: NSButton) {
        guard appStates.indices.contains(sender.tag), appStates[sender.tag].id == "crossover",
              appStates[sender.tag].installed else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appStates[sender.tag].path),
                                          configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.appsStatus.stringValue = "Couldn't open CrossOver: \(error.localizedDescription)"
                    self.append(self.appsStatus.stringValue + "\n")
                }
            }
        }
    }

    @objc private func appAction(_ sender: NSButton) {
        guard task == nil, appStates.indices.contains(sender.tag) else { return }
        let app = appStates[sender.tag]
        if app.installed && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) {
            appsStatus.stringValue = "Quit \(app.name) first, then choose Remove."
            return
        }
        if !app.installed && app.manual {
            if let url = app.url, let link = URL(string: url) {
                NSWorkspace.shared.open(link)
                appsStatus.stringValue = "Finish the official installer, then reopen Apps to check the installation."
            } else {
                let alert = NSAlert()
                alert.messageText = "Switch emulator: manual setup"
                alert.informativeText = "No verified automatic Switch emulator download is bundled. If you have a compatible Ryujinx-based macOS build, install it as Ryujinx.app in Applications. Configure your own legally obtained keys, firmware and game dumps there, then reopen Apps. Availability and game compatibility are not guaranteed."
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
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) else {
            appsStatus.stringValue = "Quit \(app.name) before updating."
            return
        }
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
                self.renderGeneral()
                self.consoleStatus.stringValue = "Choose the systems ES-DE shows. Install their emulators separately in Apps."
            } catch {
                self.consoleStatus.stringValue = "Couldn't read consoles: \(error.localizedDescription)"
                self.append(self.consoleStatus.stringValue + "\n")
            }
        }
    }

    private func renderSystems() {
        clearRows(consoleRows)
        systemSwitches = []
        let order = ConsoleArtwork.groups.flatMap { $0.systems }
        consoleSystems.sort {
            (order.firstIndex(of: $0.id) ?? 100) < (order.firstIndex(of: $1.id) ?? 100)
        }
        var manufacturerRows: [String: NSStackView] = [:]
        for manufacturer in ["Nintendo", "PlayStation", "SEGA"] {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
            manufacturerRows[manufacturer] = rows
            let box = card(manufacturer, subtitle: nil, views: [rows])
            consoleRows.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: consoleRows.widthAnchor).isActive = true
        }
        var previousGroup = ""
        for (index, system) in consoleSystems.enumerated() {
            let group = ConsoleArtwork.groups.first { $0.systems.contains(system.id) }?.title ?? "Other systems"
            let manufacturer = group.hasPrefix("Nintendo") ? "Nintendo" : group
            guard let rows = manufacturerRows[manufacturer] else { continue }
            if group != previousGroup {
                if manufacturer == "Nintendo" {
                    addSectionHeading(group == "Nintendo home consoles" ? "Home consoles" : "Handhelds", to: rows)
                }
                previousGroup = group
            } else {
                let separator = NSBox()
                separator.boxType = .separator
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = system.enabled ? .on : .off
            toggle.target = self
            toggle.action = #selector(toggleSystem(_:))
            toggle.setAccessibilityLabel(system.name)
            systemSwitches.append(toggle)
            let info = button("", #selector(showConsoleDetails(_:)))
            info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Details for \(system.name)")
            info.isBordered = false
            info.tag = index
            let readiness = consoleReadiness(system)
            info.toolTip = readiness.help
            info.setAccessibilityLabel("Help with \(system.name). \(readiness.help)")
            let controls = row([info, toggle])
            let statusLine = row([statusIndicator(emulatorName(system), color: readiness.color), NSView()])
            statusLine.distribution = .fill
            statusLine.toolTip = readiness.help
            let line = settingsRow(system.name,
                subtitle: "",
                symbol: "gamecontroller.fill", color: .systemPurple, trailing: controls,
                artwork: ConsoleArtwork.image(for: system.id), detail: statusLine)
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        }
    }

    private func emulatorName(_ system: ConsoleSystem) -> String {
        ["retroarch-metal": "RetroArch", "cemu-wiiu": "Cemu", "switch": "Ryujinx",
         "pcsx2": "PCSX2", "rpcs3": "RPCS3", "dolphin": "Dolphin"][system.package] ?? system.package
    }

    private func consoleReadiness(_ system: ConsoleSystem) -> (color: NSColor, help: String) {
        guard system.enabled else { return (.systemGray, "Hidden from your game menu. Switch on to check setup.") }
        let installed = system.emulator_installed ??
            report.map { !$0.missing.contains(system.package) } ??
            appStates.first(where: { $0.id == system.package })?.installed
        guard let installed = installed else { return (.systemGray, "Emulator not checked yet. Reopen Consoles to refresh.") }
        guard installed else { return (.systemRed, "Install \(emulatorName(system)) in Apps, then return here.") }
        guard let bios = system.bios else { return (.systemGray, "Emulator installed. Reopen Consoles to check BIOS requirements.") }
        switch bios.state {
        case "present", "not-needed": return (.systemGreen, "Emulator ready. Add your own games in Game library.")
        case "optional": return (.systemYellow, "BIOS recommended. A fallback is available; open help for optional filenames.")
        case "missing", "partial": return (.systemRed, "Required BIOS files are missing. Open help to copy filenames and see where they go.")
        default: return (.systemGray, bios.summary + ". Open the emulator to check its setup.")
        }
    }

    private func biosIndicator(_ bios: BIOSStatus) -> NSView {
        let color: NSColor = bios.state == "present" || bios.state == "not-needed" ? .systemGreen :
            bios.state == "missing" || bios.state == "partial" ? .systemRed : bios.state == "manual" ? .systemGray : .systemYellow
        let title = bios.state == "optional" ? "BIOS recommended · Fallback available" :
            bios.state == "manual" ? "BIOS · Check in emulator" : "BIOS"
        let view = statusIndicator(title, color: color)
        view.toolTip = bios.summary
        return view
    }

    private func biosStatusView(_ bios: BIOSStatus) -> NSView {
        let indicator = row([biosIndicator(bios), NSView()])
        indicator.distribution = .fill
        let missing = bios.files.filter { !$0.present }
        guard !missing.isEmpty && bios.state != "present" else { return indicator }
        func copyButton(_ title: String, value: String) -> NSButton {
            let control = NSButton(title: title, target: self, action: #selector(copyBIOSNames(_:)))
            control.bezelStyle = .inline
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11)
            control.identifier = NSUserInterfaceItemIdentifier(value)
            control.toolTip = "Copy " + value
            control.setAccessibilityLabel("Copy " + title)
            return control
        }
        let names = missing.map { URL(fileURLWithPath: $0.filename).lastPathComponent }
        let copyAll = copyButton("Copy all", value: names.joined(separator: "\n"))
        let fileRows = NSStackView()
        fileRows.orientation = .vertical
        fileRows.alignment = .leading
        fileRows.spacing = 2
        for start in stride(from: 0, to: missing.count, by: 2) {
            let buttons = (start..<min(start + 2, missing.count)).map { index -> NSButton in
                let control = copyButton(names[index], value: names[index])
                control.toolTip = "Copy filename · Put the file at " + missing[index].path
                return control
            }
            fileRows.addArrangedSubview(row(buttons))
        }
        let files = row([copyAll, fileRows, NSView()])
        files.distribution = .fill
        files.alignment = .top
        let result = column([indicator, files])
        result.spacing = 3
        return result
    }

    @objc private func copyBIOSNames(_ sender: NSButton) {
        guard let names = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(names, forType: .string) {
            consoleStatus.stringValue = "Copied BIOS filenames."
        } else {
            consoleStatus.stringValue = "Couldn't copy BIOS filenames. Try again."
            append(consoleStatus.stringValue + "\n")
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
        guard task == nil else { return }
        overviewChecks.insert(.automatic)
        overviewCheckFailures.remove(.automatic)
        defer { renderGeneral() }
        execute(["login-status"], capture: true) { code, data in
            self.overviewChecks.remove(.automatic)
            defer {
                self.renderGeneral()
                if !ProcessInfo.processInfo.arguments.contains("--smoke-test") { self.loadSteamStatus() }
            }
            guard code == 0 else {
                self.overviewCheckFailures.insert(.automatic)
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
                self.renderGeneral()
            } catch {
                self.overviewCheckFailures.insert(.automatic)
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
        guard !enabled || (selected != nil && report?.state == "valid layout" && report?.issues.isEmpty == true) else {
            autoLaunchStatus.stringValue = "Create game storage in Setup before enabling automatic console mode."
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
            updateAllButton.isEnabled = appStates.contains { $0.installed && $0.managed && $0.update?.isEmpty == false }
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
        let readOnly = capture && ["drives", "assess", "apps", "systems", "system-catalog", "login-status", "frontend", "steam-status"].contains(arguments.first ?? "")
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
                if self.appRefreshPending && self.task == nil && !self.smokeFinishing {
                    self.appRefreshPending = false
                    if [1, 11].contains(self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!)) {
                        self.loadApps()
                    }
                }
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
        let previousRoot = selected?.root
        overviewChecks = Set(OverviewCheck.allCases)
        overviewCheckFailures = []
        renderGeneral()
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
                    self.append(self.status.stringValue + "\n")
                    self.overviewCheckFailures.formUnion(OverviewCheck.allCases)
                }
            } else {
                self.overviewCheckFailures.formUnion(OverviewCheck.allCases)
                self.status.stringValue = "Drive discovery failed. Open Activity for details."
                self.showActivity()
            }
            self.populateVolumes(previous: previous)
            let preserve = previous == self.selected?.id && previousRoot == self.selected?.root
            let cachedReport = self.report
            let cachedSystems = self.consoleSystems.map { $0.id }
            self.updateSelection(preservingStatus: preserve)
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

    private func finishSmokeTest(success: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test"), !smokeFinishing else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let requestedPage = arguments.firstIndex(of: "--page").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        if requestedPage != nil || arguments.contains("--smoke-flow") {
            if ["5", "6", "9"].contains(requestedPage ?? "") || arguments.contains("--smoke-flow"), !smokeSteamLoaded {
                smokeSteamLoaded = true
                execute(["steam-status"], capture: true) { code, data in
                    do {
                        self.steamReport = try JSONDecoder().decode(SteamLibraryReport.self, from: data)
                        self.renderSteamLibraries()
                        self.renderGeneral()
                        precondition(!self.steamLibraryRows.arrangedSubviews.isEmpty)
                        precondition(!self.steamGuideRows.arrangedSubviews.isEmpty)
                        self.finishSmokeTest(success: success && code == 0)
                    } catch {
                        fputs("Cannot load Steam smoke data: \(error)\n", stderr)
                        exit(1)
                    }
                }
                return
            }
            if requestedPage == "1" || requestedPage == "11" || arguments.contains("--smoke-flow"), !smokeAppsLoaded {
                smokeAppsLoaded = true
                execute(["apps"], capture: true) { code, data in
                    do {
                        self.appStates = try JSONDecoder().decode([ManagedApp].self, from: data)
                        self.renderApps()
                        self.renderTVMenus()
                        self.appsStatus.stringValue = "Installed versions. Updates are checked only when requested."
                        precondition(Set(self.appStates.map { $0.id }) == Set(["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge", "es-de", "retroarch-metal", "dolphin", "porting-kit", "crossover", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]))
                        let porting = self.appStates.firstIndex { $0.id == "porting-kit" }!
                        precondition(self.appStates[porting + 1].id == "crossover")
                        let battle = self.appStates.firstIndex { $0.id == "battle-net" }!
                        precondition(self.appStates[battle + 1].id == "curseforge")
                        func buttons(in view: NSView) -> [NSButton] {
                            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
                        }
                        for installed in [false, true] {
                            for update in [false, true] {
                                let preview = ManagedApp(id: "pcsx2", name: "PCSX2", installed: installed,
                                    path: "/Applications/PCSX2.app", version: "1.0", managed: true,
                                    update: update ? "2.0" : nil, manual: false, brew: true, url: nil)
                                let rows = NSStackView()
                                self.addAppRow(preview, index: 0, to: rows)
                                let controls = buttons(in: rows)
                                func appLabels(_ view: NSView) -> [String] {
                                    (view as? NSTextField).map { [$0.stringValue] } ??
                                        view.subviews.flatMap { appLabels($0) }
                                }
                                precondition(appLabels(rows).contains(installed ?
                                    (update ? "Installed · Update available" : "Installed") : "Not installed"))
                                precondition(controls.count == (installed && update ? 2 : 1))
                                if installed {
                                    precondition(controls.allSatisfy { $0 is AppGetButton && $0.toolTip != nil })
                                    precondition(controls.last?.title == "" && (controls.last as! AppGetButton).destructive)
                                    precondition(controls.last?.toolTip == "Remove PCSX2")
                                } else {
                                    precondition(controls.first is AppGetButton && controls.first?.title == "Get")
                                }
                                precondition(controls.last?.action == #selector(self.appAction(_:)))
                                if installed && update {
                                    precondition(controls.first?.action == #selector(self.updateApp(_:)))
                                    precondition(controls.first?.title == "Update" && !(controls.first as! AppGetButton).destructive)
                                }
                                self.clearRows(rows)
                            }
                        }
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
        if arguments.contains("--smoke-flow") && !smokeOverviewRefreshed {
            smokeOverviewRefreshed = true
            selectPage(9)
            refreshGeneral()
            precondition(task != nil && !overviewChecks.isEmpty,
                         "Overview must refresh asynchronously with pending indicators")
            return
        }
        smokeFinishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let stack = self.detail.subviews.compactMap { $0 as? NSStackView }.first!
                let discoveryOK = success && !self.volumes.isEmpty && self.window.isVisible
                    && self.selected != nil
                    && self.tabs.numberOfTabViewItems == 12 && self.logWindow == nil
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--minimum-size") { self.window.setContentSize(self.window.minSize) }
                precondition(self.window.frame.width >= 960, "Settings pages must preserve the minimum window width")
                if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
                   let page = Int(args[index + 1]), (0..<12).contains(page) {
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
                    for count in 0...4 {
                        let status = self.controllerOverviewStatus(count: count)
                        precondition(status.arrangedSubviews.count == 2)
                        let housing = status.arrangedSubviews[0] as! ControllerLEDHousing
                        let leds = housing.subviews[0] as! NSStackView
                        precondition(leds.arrangedSubviews.count == 4)
                        for index in 0..<4 {
                            let dot = leds.arrangedSubviews[index] as! NSImageView
                            precondition(dot.contentTintColor == (index < count ? NSColor.systemGreen : NSColor.systemGray))
                        }
                        precondition((status.arrangedSubviews[1] as! NSTextField).stringValue ==
                                     (count == 0 ? "Not Connected" : "\(count) Connected"))
                    }
                    let assessment = self.report
                    self.busy(true)
                    let statusRow = stack.arrangedSubviews.last as! NSStackView
                    let details = statusRow.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.action == #selector(self.showActivity) }
                    precondition(details?.isEnabled == true && self.sidebar.isEnabled, "Activity and navigation must stay available during operations")
                    self.busy(false)
                    for page in 0..<self.tabs.numberOfTabViewItems {
                        self.selectPage(page)
                        precondition(!self.navigationBar.isHidden && self.window === self.mainWindow)
                        precondition(self.sidebar.selectedRow == self.sidebarPages.firstIndex(of: page == 4 ? 3 : page == 10 ? self.inspectorParent : page))
                        self.assertSmokePageScrolls()
                        if page == 7 {
                            for toggle in self.systemSwitches {
                                precondition(toggle.controlSize == .small)
                                let controls = toggle.superview!
                                let frame = toggle.convert(toggle.bounds, to: controls)
                                precondition(abs(frame.maxX - controls.bounds.maxX) < 4, "Console switches must align to the right edge")
                            }
                        }
                        if page == 8 {
                            func controllerLabels(_ view: NSView) -> [String] {
                                (view as? NSTextField).map { [$0.stringValue] } ??
                                    view.subviews.flatMap { controllerLabels($0) }
                            }
                            let labels = controllerLabels(self.activeControllerRows)
                            precondition(labels.contains("Purple PS5") && labels.contains("DualSense Wireless Controller"))
                            precondition(labels.contains("Connected · Bluetooth") && labels.contains("Connected · Wired"))
                            precondition(labels.contains("Not connected"))
                            let originalOrder = self.controllerEntries.map { $0.id }
                            self.connectedFirstToggle.state = .on
                            self.controllerSortChanged()
                            let sortedLabels = controllerLabels(self.activeControllerRows)
                            precondition(sortedLabels.firstIndex(of: "8BitDo Controller")! <
                                         sortedLabels.firstIndex(of: "Xbox Wireless Controller")!)
                            self.connectedFirstToggle.state = .off
                            self.controllerSortChanged()
                            precondition(self.controllerEntries.map { $0.id } == originalOrder)
                            let entry = self.controllerEntries[0]
                            self.receiveControllerInput(entry, message: "Button 1 pressed")
                            precondition(self.controllerTestStatus.stringValue == "Purple PS5 · Button 1 pressed")
                            precondition(self.controllerInputLabels[entry.id]?.isHidden == false)
                            precondition(self.controllerInputLabels[self.controllerEntries[2].id]?.isHidden == true)
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 1, minimum: 0, maximum: 1) == "Button 1 pressed")
                            precondition(controllerInputDescription(page: 9, usage: 1, value: 0, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 7, usage: 1, value: 1, minimum: 0, maximum: 1) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 128, minimum: 0, maximum: 255) == nil)
                            precondition(controllerInputDescription(page: 1, usage: 0x30, value: 255, minimum: 0, maximum: 255) == "Stick / trigger X · 100%")
                            precondition(controllerAddress("AA-BB-CC-DD-EE-FF") == "aabbccddeeff")
                            precondition(controllerAddress("not an address") == nil)
                            let preferences = ControllerPreferences(entries: self.controllerEntries,
                                customizations: self.controllerCustomizations, connectedFirst: false)
                            let restored = try! JSONDecoder().decode(ControllerPreferences.self,
                                from: JSONEncoder().encode(preferences))
                            precondition(restored.customizations[entry.id]?.name == "Purple PS5")
                            precondition(restored.customizations[entry.id]?.color == "Purple")
                            self.mergeControllerList([], paired: [])
                            precondition(self.controllerEntries.allSatisfy { !$0.connected })
                            precondition(self.controllerEntries.map { $0.id } == originalOrder)
                            self.refreshControllers()
                        }
                    }
                    for (index, page) in self.sidebarPages.enumerated() where page < 0 {
                        precondition(!self.tableView(self.sidebar, shouldSelectRow: index), "Sidebar section headings must not navigate")
                    }
                    precondition(self.systemSwitches.count == 17 && self.activeControllerRows.arrangedSubviews.count == 5)
                    precondition(self.consoleRows.arrangedSubviews.count == 3,
                                 "Nintendo, PlayStation and SEGA must each have one card")
                    let readyBIOS = BIOSStatus(state: "present", summary: "", files: [])
                    for (enabled, installed, bios, expected) in [
                        (false, false, readyBIOS, NSColor.systemGray),
                        (true, false, readyBIOS, NSColor.systemRed),
                        (true, true, readyBIOS, NSColor.systemGreen),
                        (true, true, BIOSStatus(state: "optional", summary: "", files: []), NSColor.systemYellow),
                        (true, true, BIOSStatus(state: "missing", summary: "", files: []), NSColor.systemRed),
                        (true, true, BIOSStatus(state: "manual", summary: "", files: []), NSColor.systemGray)
                    ] {
                        let preview = ConsoleSystem(id: "psx", name: "PlayStation", enabled: enabled,
                            package: "retroarch-metal", requirement: "", bios: bios, emulator_installed: installed)
                        precondition(self.consoleReadiness(preview).color == expected)
                        precondition(self.emulatorName(preview) == "RetroArch")
                    }
                    precondition(self.controllerInputManager == nil, "Input monitoring must stop when leaving Controllers")
                    let previousTestText = self.controllerTestStatus.stringValue
                    self.receiveControllerInput(self.controllerEntries[0], message: "Ignored outside Controllers")
                    precondition(self.controllerTestStatus.stringValue == previousTestText)
                    let biosPreview = BIOSStatus(state: "missing", summary: "Missing BIOS",
                        files: [
                            BIOSFileStatus(filename: "dc/dc_boot.bin", path: "/BIOS/dc/dc_boot.bin", present: false, note: ""),
                            BIOSFileStatus(filename: "dc/dc_flash.bin", path: "/BIOS/dc/dc_flash.bin", present: false, note: "")
                        ])
                    func biosCopyButtons(_ view: NSView) -> [NSButton] {
                        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { biosCopyButtons($0) }
                    }
                    let copies = biosCopyButtons(self.biosStatusView(biosPreview))
                    precondition(copies.map { $0.title } == ["Copy all", "dc_boot.bin", "dc_flash.bin"])
                    precondition(copies.map { $0.identifier!.rawValue } ==
                                 ["dc_boot.bin\ndc_flash.bin", "dc_boot.bin", "dc_flash.bin"])
                    precondition(copies.allSatisfy { $0.action == #selector(self.copyBIOSNames(_:)) })
                    precondition(biosCopyButtons(self.biosStatusView(BIOSStatus(state: "present",
                        summary: "BIOS found", files: biosPreview.files))).isEmpty)
                    let orderedSystems = ConsoleArtwork.groups.flatMap { $0.systems }
                    precondition(self.consoleSystems.map { $0.id } == orderedSystems,
                                 "Systems must stay grouped and ordered by original release")
                    let artwork = orderedSystems.compactMap { ConsoleArtwork.image(for: $0).tiffRepresentation }
                    precondition(artwork.count == 17 && Set(artwork).count == 17,
                                 "Every system must have distinct, renderable original artwork")
                    let inspectorTrigger = NSButton()
                    inspectorTrigger.tag = 0
                    self.showConsoleDetails(inspectorTrigger)
                    precondition(self.inspectorTitle.stringValue == self.consoleSystems[0].name)
                    self.closeInspector()
                    precondition(self.tabs.selectedTabViewItem === self.tabs.tabViewItems[7])
                    self.selectPage(9)
                    func labels(in view: NSView) -> [String] {
                        if let label = view as? NSTextField { return [label.stringValue] }
                        return view.subviews.flatMap { labels(in: $0) }
                    }
                    let cachedLabels = labels(in: self.generalRows)
                    self.overviewChecks = Set(OverviewCheck.allCases)
                    self.renderGeneral()
                    let pendingLabels = labels(in: self.generalRows)
                    precondition(pendingLabels == cachedLabels.map { $0 == "Not checked" ? "Checking..." : $0 },
                                 "Checking must replace unknown status, while known statuses remain visible")
                    self.overviewChecks = []
                    self.overviewCheckFailures = [.storage]
                    self.renderGeneral()
                    precondition(labels(in: self.generalRows).contains { $0.contains("See Activity") })
                    self.overviewCheckFailures = []
                    self.renderGeneral()
                    self.window.contentView!.layoutSubtreeIfNeeded()
                    precondition(self.generalRows.arrangedSubviews.count == 17)
                    let overviewButtons = self.generalRows.arrangedSubviews.compactMap { $0 as? StorageChoiceButton }
                    precondition(overviewButtons.count == 9)
                    precondition(overviewButtons.map { $0.action! } == [
                        #selector(self.showPlayOverview), #selector(self.backToChoices), #selector(self.showLibraryOverview),
                        #selector(self.showPlayers), #selector(self.showTVMenus), #selector(self.showControllers),
                        #selector(self.showConsoles), #selector(self.showFinishing), #selector(self.openSettings)
                    ])
                    let countReport = self.report
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                                             missing: Array(self.computerGameApps.union(self.emulatorApps)))
                    precondition(self.overviewAppSummary == "0 PC game apps · 0 emulators installed")
                    self.report = Assessment(state: "valid layout", issues: [], notes: [],
                                             missing: Array(self.computerGameApps.union(self.emulatorApps).subtracting(["steam", "dolphin"])))
                    precondition(self.overviewAppSummary == "1 PC game app · 1 emulator installed")
                    self.report = countReport
                    for view in self.generalRows.arrangedSubviews where view is StorageChoiceButton {
                        precondition(abs(view.frame.width - self.generalRows.bounds.width) < 1)
                    }
                    self.selectPage(11)
                    self.goBack()
                    precondition(self.screenTitle.stringValue == "Overview")
                    self.goForward()
                    precondition(self.screenTitle.stringValue == "TV menu")
                    self.renderTVMenus()
                    precondition(self.tvMenuRows.arrangedSubviews.count == 5)
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
                    precondition(!self.playSteamMenu.isEnabled && self.playRetroMenu.isEnabled)
                    self.report = Assessment(state: "valid layout", issues: [], notes: [], missing: [])
                    self.updateSetupSummary()
                    precondition(self.playAction.isEnabled)
                    self.preferredFrontend = "es-de"
                    self.updateSetupSummary()
                    precondition(self.playAction.title == "Open ES-DE")
                    precondition(self.playSteamMenu.isEnabled && self.playRetroMenu.isEnabled)
                    self.preferredFrontend = nil
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
                precondition(self.window.titleVisibility == .hidden && self.window.toolbar?.items.isEmpty == true)
                precondition(self.window.styleMask.contains(.fullSizeContentView))
                let headerFrame = self.historyControl.convert(self.historyControl.bounds, to: self.mainDetail)
                precondition(abs(self.mainDetail.bounds.maxY - headerFrame.midY - 26) < 8,
                             "History controls must sit in the top bar, not in page content")
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let control = self.window.standardWindowButton(kind)!
                    precondition(!control.isHidden)
                    let frame = self.sidebarPanel.convert(control.bounds, from: control)
                    precondition(self.sidebarPanel.bounds.contains(frame),
                                 "Native window controls must fit inside the inset sidebar: \(frame)")
                }
                precondition(self.sidebarPanel.alphaValue == 1)
                precondition(self.sidebarPanel.frame.minX == 12 && self.sidebarPanel.frame.minY == 12)
                precondition(self.navigationBar.frame.minY >= 12 &&
                             self.navigationBar.frame.maxY <= self.sidebarPanel.bounds.maxY - 54)
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
        updateSelection(preservingStatus: false)
    }

    private func updateSelection(preservingStatus: Bool) {
        if !preservingStatus {
            report = nil
            consoleSystems = []
        }
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
        overviewChecks.formUnion([.storage, .menu])
        renderGeneral()
        execute(["assess", "--drive", drive.id], capture: true) { code, data in
            guard self.selected?.id == drive.id else { self.checkStorage(); return }
            self.overviewChecks.subtract([.storage, .menu])
            guard code == 0 else {
                self.overviewCheckFailures.formUnion([.storage, .menu])
                self.overviewChecks = []
                self.renderGeneral()
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
                if self.tabs.selectedTabViewItem === self.tabs.tabViewItems[5] { self.updateSteamGuide() }
                if drive.free < 20 * 1024 * 1024 * 1024 {
                    self.summary.stringValue += "\nYou're low on space. Big games may need more room."
                }
                self.status.stringValue = "Drive checked. No files changed."
                self.append("\n--- Storage assessment: \(drive.name) ---\n"
                            + (report.issues + report.notes).joined(separator: "\n") + "\n")
                if !self.didRouteInitialLibrary {
                    self.didRouteInitialLibrary = true
                    self.selectPage(9)
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
                if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    self.loadGeneralDetails()
                } else {
                    self.overviewChecks = []
                    self.renderGeneral()
                }
            } catch {
                self.overviewCheckFailures.formUnion([.storage, .menu])
                self.overviewChecks = []
                self.renderGeneral()
                self.advanceAfterLibraryCheck = false
                self.status.stringValue = "Cannot read assessment: \(error.localizedDescription)"
                self.finishSmokeTest(success: false)
            }
        }
    }

    @objc private func playSteam() {
        guard let drive = selected else { return }
        let frontend = effectiveFrontend == "es-de" ? "ES-DE" : "Steam Big Picture"
        execute(["console", "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "\(frontend) session finished or opened." : "Couldn't open console mode. Check Apps & emulators and Activity."
        }
    }

    @objc private func playChosenMenu(_ sender: NSButton) {
        guard let drive = selected else {
            status.stringValue = "Create game storage in Setup before opening a console menu."
            return
        }
        let menu = sender.tag == 0 ? "steam" : "retro"
        execute([menu, "--root", drive.root]) { code, _ in
            self.status.stringValue = code == 0 ? "TV menu opened. Your default is unchanged." :
                "Couldn't open the TV menu. Open Activity for details."
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
