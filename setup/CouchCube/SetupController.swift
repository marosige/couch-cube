import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


final class SetupController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSMenuItemValidation, CBCentralManagerDelegate,
    IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    var window: NSWindow!
    var mainWindow: NSWindow!
    let detail = NSView()
    let mainDetail = NSView()
    let sidebar = NSTableView()
    var selectingPage = false
    let sidebarPages = [-1, 0, 8, 13, -1, 6, 1, 7, 10, 11]
    let sidebarTitles = ["Couch Cube", "Play", "Controllers", "Cube Shop", "Settings", "Game library", "App Store", "Retro consoles", "Console Mode", "App Settings"]
    let sidebarSymbols = ["", "play.rectangle.fill", "gamecontroller.fill", "bag.fill", "", "books.vertical.fill", "storefront", "tv", "power", "gearshape"]
    let screenTitle = NSTextField(labelWithString: "Play")
    // Deals: lazy, cached, read-only views of CheapShark store deals and GamerPower giveaways.
    lazy var dealsRead: ([String], @escaping (Int32, Data, String) -> Void) -> Void = { [weak self] arguments, completed in
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            // Smoke tests never touch the network: serve fixed, already-normalized replies.
            let data = Data((arguments.contains("gamerpower") ? smokeGiveawaysJSON : smokeStoreDealsJSON).utf8)
            // RunLoop (not the main queue) so replies also arrive while a smoke check spins a nested run loop.
            RunLoop.main.perform { completed(0, data, "") }
            return
        }
        self?.runBackendInBackground(["deals"] + arguments, completed: completed)
    }
    let dealsModeKey = "dealsMode", dealsSortKey = "dealsSort", giveawaySortKey = "giveawaySort"
    let dealsMode = NSSegmentedControl(labels: ["Store Deals", "Free Games"], trackingMode: .selectOne, target: nil, action: nil)
    let dealsSearch = NSSearchField()
    let dealsStorePopup = NSPopUpButton()
    let dealsSortPopup = NSPopUpButton()
    let giveawayPlatformPopup = NSPopUpButton()
    let giveawayTypePopup = NSPopUpButton()
    let giveawaySortPopup = NSPopUpButton()
    let dealsFilters = NSStackView()
    let dealsStatus = NSTextField(wrappingLabelWithString: "")
    let dealsList = NSStackView()
    /// Reminders access is created only on first use; smoke tests swap in a mock so nothing is written.
    lazy var reminderStore: DealReminderStore = EventKitReminderStore()
    var dealsNow: () -> Date = { Date() }
    /// Asks before removing a reminder; smoke tests answer it directly.
    lazy var confirmReminderRemoval: (String) -> Bool = { title in
        let alert = NSAlert()
        alert.messageText = "Remove the reminder for \u{201C}\(title)\u{201D}?"
        alert.informativeText = "It will be deleted from Reminders."
        alert.addButton(withTitle: "Remove Reminder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Reminder identifiers by giveaway, so a deal never gets a duplicate reminder.
    var dealReminders: [String: String] = UserDefaults.standard.dictionary(forKey: "dealReminders") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(dealReminders, forKey: "dealReminders") }
    }
    let dealsReminderNote = NSTextField(wrappingLabelWithString: "")
    let dealsReminderSettings = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    let dealsReminderBar = NSStackView()
    let dealsMore = NSButton(title: "Load More Deals", target: nil, action: nil)
    let dealsRetry = NSButton(title: "Try Again", target: nil, action: nil)
    let dealsRefreshButton = NSButton(title: "", target: nil, action: nil)
    let dealsProgress = NSProgressIndicator()
    var dealsStores: [DealStore] = []
    var storeDeals: [StoreDeal] = []
    var giveaways: [Giveaway] = []
    var storeDealsPage = 0, storeDealsHasMore = false
    var dealsGeneration = 0
    var dealsLoadingKey: String?
    var dealsLoadedKey: [Int: String] = [:]
    var dealsOpened = false
    var dealsOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var dealsFetched: [Int: Double] = [:]
    // Cube Shop: Home, Deals, Free Games, Search and the drive-saved Wishlist, with optional display-currency conversion.
    let shopTabKey = "shopTab", shopScopeKey = "shopScope", shopCurrencyKey = "shopCurrency", shopFeeKey = "shopFeePercent"
    let shopTab = NSSegmentedControl(labels: ["Home", "Deals", "Free Games", "Search", "Wishlist"], trackingMode: .selectOne, target: nil, action: nil)
    /// The visible navigation; Search isn't a tab but the results of the search field above it.
    let shopNav = NSSegmentedControl(labels: ["Home", "Deals", "Free Games", "Wishlist"], trackingMode: .selectOne, target: nil, action: nil)
    static let shopNavTabs = [0, 1, 2, 4]
    var shopReturnTab = 0
    /// Cube Shop game pages, by wishlist key; Back and Forward reopen them from here.
    var shopDetails: [String: ShopDetail] = [:]
    var shopDetailKey: String?
    let shopDetailContent = NSStackView()
    /// The game page's picture gallery: the cover first, then Steam's screenshots.
    var shopGalleryIndex = 0
    var shopGalleryImages: [String] = []
    weak var shopGalleryView: RemoteImageView?
    weak var shopGalleryPrevious: NSButton?
    weak var shopGalleryNext: NSButton?
    weak var shopGalleryCounter: NSTextField?
    let shopScope = ScopePopUp(labels: ["My Stores", "All Stores"])
    let shopScopeHint = NSTextField(wrappingLabelWithString: "")
    let shopScopeBar = NSStackView()
    let shopCurrencyNote = NSTextField(wrappingLabelWithString: "")
    let dealsPane = NSStackView(), homePane = NSStackView(), searchPane = NSStackView(), wishlistPane = NSStackView()
    let homeStatus = NSTextField(wrappingLabelWithString: ""), homeList = NSStackView()
    let shopSearchField = NSSearchField()
    var shopScrollOffsets: [Int: CGFloat] = [:], shopShownTab: Int?
    let searchStatus = NSTextField(wrappingLabelWithString: ""), searchList = NSStackView()
    let wishlistStatus = NSTextField(wrappingLabelWithString: ""), wishlistList = NSStackView()
    let searchSortPopup = NSPopUpButton(), wishlistSortPopup = NSPopUpButton()
    let searchSortKey = "shopSort.search", wishlistSortKey = "shopSort.wishlist"
    var shopPageView: NSView?
    var shopHome: ShopHomeReply?
    var homeLoadingKey: String?, homeLoadedScope: String?, homeError: String?
    var searchReply: ShopSearchReply?
    /// Steam platform status per app ID, looked up a few at a time after lists render.
    var steamPlatformStatus: [String: String] = [:]
    var platformsRequested: Set<String> = []
    var platformLookupScheduled = false
    var platformLookupRounds = 0
    var searchLoadingQuery: String?, searchLoadedQuery: String?, searchError: String?
    var searchTimer: Timer?
    var wishlist: WishlistReply?
    var wishlistLoading = false, wishlistCheckedAt: Date?
    var steamLink: SteamLinkReply?
    var steamLinkBusy = false
    let steamLinkSwitch = NSSwitch()
    let steamLinkNote = NSTextField(labelWithString: "")
    var wishlistPayloads: [String: (title: String, payload: [String: String])] = [:]
    /// The currency a store row's price is in, for a target set before the game is on the wishlist (with Original prices).
    var shopTargetCurrencies: [String: String] = [:]
    var exchangeRates: ExchangeRates?
    var ratesLoading = false, ratesFailed = false, ratesLoadedAt: Date?
    var myStores: [ShopStoreRef]?
    var shopLoading: Set<String> = []
    let shopCurrencyPopup = NSPopUpButton()
    let shopFeeField = NSTextField()
    let shopRatesNote = NSTextField(wrappingLabelWithString: "")
    /// Shop, wishlist and exchange-rate commands; smoke tests serve fixtures and an in-memory wishlist instead.
    lazy var shopRead: ([String], @escaping (Int32, Data, String) -> Void) -> Void = { [weak self] arguments, completed in
        guard let self else { return }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            self.smokeShopCalls.append(arguments)
            let reply = self.smokeShopReply(arguments)
            RunLoop.main.perform { completed(reply.0, Data(reply.1.utf8), "") }
            return
        }
        self.runBackendInBackground(arguments, completed: completed)
    }
    var smokeShopCalls: [[String]] = []
    var smokeWishlist: [[String: Any]] = []
    var smokeWishlistOffline = false
    /// Asks for a wishlist target price in the given currency: .none = cancelled, .some(nil) = clear the target.
    lazy var askTargetPrice: (String, Double?, String) -> Double?? = { title, current, code in
        let alert = NSAlert()
        alert.messageText = "Target price for \u{201C}\(title)\u{201D}"
        alert.informativeText = "Cube Shop marks the game when its best price is at or below this, converted at today's ECB rate. Leave it empty to clear the target."
        let places = ShopMoney.minorUnits(code)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = places == 0 ? "e.g. 4000" : "e.g. 9.99"
        field.setAccessibilityLabel("Target price in \(code)")
        if let current { field.stringValue = String(format: "%.\(places)f", current) }
        let unit = NSTextField(labelWithString: code)
        unit.textColor = .secondaryLabelColor
        let box = NSStackView(views: [field, unit])
        box.spacing = 6
        box.frame = NSRect(x: 0, y: 0, width: 170, height: 24)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .none }
        return .some(parseTargetPrice(field.stringValue, code))
    }
    let backToolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Back"))
    let forwardToolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Forward"))
    var pageHistory: [(page: Int, systemID: String?)] = []
    var historyIndex = -1
    var replayingHistory = false
    var inspectorSystemID: String?
    var preferredFrontend: String?
    let defaultMenuPicker = NSPopUpButton()
    let tvMenuStatus = NSTextField(wrappingLabelWithString: "")
    let updateAllButton = NSButton()
    let homeMenuLabel = NSTextField(wrappingLabelWithString: "Checking your console...")
    let homePlaySubtitle = NSTextField(labelWithString: "")
    var homeArtworkMenu: String?? = .none
    let homeProgress = NSProgressIndicator()
    let homeControllerStatus = NSStackView()
    var homeControllerRowViews: [String: NSView] = [:]
    var homeControllerRowIDs: [String] = []
    var homeControllerRenderedSignature: String?
    var homeControllerRenderCount = 0
    var homeControllerInputLabels: [String: NSTextField] = [:]
    var homeControllerImages: [String: [NSImageView]] = [:]
    var homeSessionControllers: [String] = []
    var homeObservedConnections = Set<String>()
    let homePlayBackground = NSView()
    let launcherSections = NSStackView()
    /// Shown after an app operation fails: macOS's App Management permission is the usual cause.
    let appManagementHint = NSStackView()
    var systemStoreLinks: [NSButton] = []
    let launcherSearch = NSSearchField()
    static let launcherAppsKey = "launcherApps"
    var launcherLibrary: LibraryGames?
    /// Smoke screenshots show sample tiles instead of whatever the build machine has installed.
    var launcherSmokeItems: [LauncherItem]?
    var homeTiles: NSStackView!
    var sidebarAttention: [Int: NSColor] = [:]
    var sidebarTasks: [SidebarTask] = []
    var sidebarTaskCounts: [Int: SidebarBadge] = [:]
    /// The sidebar marks one setup step at a time (no setting: it ends by itself once everything is done).
    var guidedSetup = true
    var couchCubeUpdateAvailable = false
    var controllerInputUnavailable = false
    let inspectorRows = NSStackView()
    let inspectorTitle = NSTextField(labelWithString: "")
    var inspectorParent = 1
    let activeControllerRows = NSStackView()
    let controllerStatus = NSTextField(wrappingLabelWithString: "")
    var controllerAccessButton: NSButton!
    var bluetoothManager: CBCentralManager?
    var controllerTimer: Timer?
    var controllerQueryRunning = false
    var pairedControllers: [PairedController] = []
    var controllerEntries: [ControllerEntry] = []
    var controllerCustomizations: [String: ControllerCustomization] = [:]
    var controllerInputManager: IOHIDManager?
    let controllerTestStatus = NSTextField(wrappingLabelWithString: "Press a button or move a stick to identify and test a controller.")
    var controllerInputLabels: [String: NSTextField] = [:]
    var controllerLastInput: [String: (message: String, date: Date)] = [:]
    let controllerSortMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    var controllerConnectedFirst = false
    var controllerAliases: [String: String] = [:]
    var controllerBatteries: [String: (level: Float, state: GCDeviceBattery.State)] = [:]
    var controllerImages: [String: [NSImageView]] = [:]
    var controllerRowViews: [String: NSView] = [:]
    var controllerRowIDs: [String] = []
    let controllerDropIndicator = NSBox()
    var controllerBusy = Set<String>()
    var discoveredControllers: [PairedController] = []
    let discoveredControllerRows = NSStackView()
    let homeDiscoveredControllerRows = NSStackView()
    var discoveredControllersSignature: String?
    var discoveredRenderCount = 0
    var bluetoothInquiry: IOBluetoothDeviceInquiry?
    var bluetoothInquiryRestart: DispatchWorkItem?
    var bluetoothPairing: IOBluetoothDevicePair?
    var controllerErrors: [String] = []
    var bluetoothSettingsOpens = 0
    var smokePairRequests: [String] = []
    var controllerBanner: NSBox!
    var controllerSmokeBanner = false
    let controllerDefaultsKey = "controllerPreferences"
    struct ControllerPreferences: Codable {
        var entries: [ControllerEntry]
        var customizations: [String: ControllerCustomization]
        var connectedFirst: Bool
        var recentControllerIDs: [String]? = nil
        var aliases: [String: String]? = nil
        /// 2 = empty color means Automatic; older saves stored the inferred default instead.
        var colorVersion: Int? = nil
    }
    let volumeMenu = NSPopUpButton()
    let driveRows = NSStackView()
    let summary = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Choose storage, then review setup.")
    let libraryTitle = NSTextField(labelWithString: "Choose your game drive")
    let libraryDescription = NSTextField(wrappingLabelWithString: "Connect an SSD, or use this Mac's internal storage.")
    let libraryAction = SetupActionButton()
    var playAction: NSButton!
    let steamStorageAdvice = NSTextField(wrappingLabelWithString: "")
    let retroAdvice = NSTextField(wrappingLabelWithString: "")
    let tabs = NSTabView()
    let modeLabel = NSTextField(labelWithString: "PORTABLE MANAGER")
    let log = NSTextView()
    var actions: [NSControl] = []
    var volumes: [Drive] = []
    var availableVolumes: [Drive] = []
    var task: Process?
    let backend: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts/console.py")
    var refreshPending = false
    var disks: [PhysicalDisk] = []
    var logWindow: NSWindow?
    var report: Assessment?
    var libraryControls: [NSControl] = []
    var appStates: [ManagedApp] = []
    var appsChecking = false
    /// Startup preload of App Store data; runs in the background as soon as no other command is running.
    var appsPreloadPending = false
    var lastAppsData: Data?
    var appsLoadGeneration = 0
    var consoleLoadGeneration = 0
    /// Read-only backend reads for App Store and Retro consoles; smoke tests replace it to control completion order.
    lazy var backendRead: (_ arguments: [String], _ done: @escaping (Int32, Data) -> Void) -> Void = { arguments, done in
        self.execute(arguments, capture: true, completed: done)
    }
    var appsHaveResults = true
    var windowsDownloads: [WindowsDownloadItem] = []
    var windowsDownloadJobs: [String: WindowsDownloadJob] = [:]
    var windowsLibrary: String?
    var windowsDownloadsGeneration = 0
    lazy var windowsDownloadsRead: (@escaping (Int32, Data) -> Void) -> Void = { [weak self] done in
        self?.runBackendInBackground(["windows-downloads"]) { code, data, _ in done(code, data) }
    }
    /// Starts one download and returns its cancel action. Lines arrive in order on the main thread.
    lazy var windowsDownloadRun: (String, @escaping (String) -> Void, @escaping (Int32, String) -> Void) -> (() -> Void) = { [weak self] id, line, done in
        guard let self else { return {} }
        let process = self.runBackendStreaming(["windows-download", "--package", id, "--confirm"], line: line, completed: done)
        return { if process.isRunning { process.terminate() } }
    }
    var appOperations: [String: AppOperation] = [:]
    var storeAccounts = StoreAccountsModel()
    var storeWalkthrough: StoreAccountsWalkthrough?
    var storeClientsOpen: Set<String> = []
    var storeAccountsError: String?
    let storeAccountsSummary = NSTextField(labelWithString: "")
    let storeAccountsChecked = NSTextField(labelWithString: "")
    let storeAccountsRows = NSStackView()
    let storeWalkthroughPanel = NSStackView()
    /// Read-only local status; smoke tests replace it so no real client files are read.
    lazy var storeAccountsRead: (@escaping (Int32, Data) -> Void) -> Void = { [weak self] done in
        self?.runBackendInBackground(["store-accounts"]) { code, data, _ in done(code, data) }
    }
    /// Opens one client and calls back once it quits; smoke tests replace it so nothing launches.
    lazy var storeClientOpen: (String, @escaping (Int32) -> Void) -> Void = { [weak self] id, done in
        self?.runBackendInBackground(["store-account-open", "--id", id]) { code, _, _ in done(code) }
    }
    var appVerifyTokens: [String: Int] = [:]
    var appOperationOutput: ((String) -> Void)?
    lazy var appOperationRun: ([String], @escaping (Int32) -> Void) -> Void = { arguments, done in
        self.execute(arguments) { code, _ in done(code) }
    }
    lazy var appVerifyRead: ([String], @escaping (Int32, Data) -> Void) -> Void = { arguments, done in
        self.backendRead(arguments, done)
    }
    var appRefreshPending = false
    let appMenuRows = NSStackView()
    let appPCRows = NSStackView()
    let appWindowsRows = NSStackView()
    let appRetroRows = NSStackView()
    let consoleRows = NSStackView()
    var consoleSystems: [ConsoleSystem] = [] { didSet { updateLibrarySummary() } }
    var consolesChecking = false
    var consolesLoaded = false
    var consoleRefreshPending = false
    var systemSwitches: [NSSwitch] = []
    var systemStatusLines: [NSStackView] = []
    /// Console selection last confirmed on disk; failed saves fall back to it.
    var consolePersistedEnabled: Set<String>?
    var consoleSaveTimer: Timer?
    var consoleSaveInFlight = false
    var consoleSaveDirty = false
    var consoleEditGeneration = 0
    var consoleSaveDelay: TimeInterval = 0.4
    /// Show/hide-all switches for the page, each company card and each Nintendo subsection.
    var consoleBulkToggles: [(toggle: NSSwitch, count: NSTextField, ids: Set<String>, scope: String)] = []
    lazy var consoleRoot: () -> String? = { self.selected?.root }
    /// Injected in smoke tests; the default runs the backend off the main thread without the global busy state.
    lazy var consoleSaver: (_ root: String, _ enabled: [String], _ done: @escaping (Int32, String) -> Void) -> Void = { root, enabled, done in
        self.runBackendInBackground(["systems", "--root", root, "--confirm", "--enabled"] + enabled) { code, _, errors in done(code, errors) }
    }
    lazy var consoleRefresher: (_ root: String, _ done: @escaping (Int32, Data) -> Void) -> Void = { root, done in
        self.runBackendInBackground(["systems", "--root", root]) { code, data, _ in done(code, data) }
    }
    let appsStatus = NSTextField(wrappingLabelWithString: "")
    let consoleStatus = NSTextField(wrappingLabelWithString: "Create your game folders in Settings → Game library first.")
    let setupFolderStatus = NSTextField(wrappingLabelWithString: "Choose where to keep your games.")
    let gameLibraryOverviewRows = NSStackView()
    var storageOverviewRendered: [ObjectIdentifier: [StorageOverviewEntry]] = [:]
    let driveDetailRows = NSStackView()
    var driveDetailID: String?
    var driveDetailParent = 6
    var driveDetailCache: [String: DriveDetail] = [:]
    var driveDetailErrors: [String: String] = [:]
    var driveDetailGeneration = 0
    var driveDetailLoading = false
    var driveDetailPending = false
    var driveGamesCache: [String: (games: DriveGames, scanned: Date)] = [:]
    var driveGamesErrors: [String: String] = [:]
    var driveGamesScanning: String?
    var driveGamesGeneration = 0
    var driveGamesShowAll = false
    var driveGamesProcess: Process?
    let romsBySystemKey = "DriveStorageGroupRomsBySystem"
    let pcByLauncherKey = "DriveStorageGroupPCByLauncher"
    /// Independent of the shared backend task, so a long size scan never blocks other actions; smoke tests replace it.
    lazy var driveGamesRead: (_ id: String, _ done: @escaping (Int32, Data) -> Void) -> Void = { id, done in
        self.runDriveGamesScan(id, done)
    }
    var storageStatus: StorageStatus?
    var transferLibraryButton: NSButton!
    var retireLibraryButton: NSButton!
    var lastLibraryTransfer: (result: LibraryTransferResult, destinationID: String)?
    let setupAppStatus = NSTextField(wrappingLabelWithString: "Steam or ES-DE provides your TV menu.")
    let setupConnectionStatus = NSTextField(wrappingLabelWithString: "Connect a controller and add your games.")
    var lastError = ""
    var smokeFinishing = false
    var smokeAppsLoaded = false
    var smokeSystemsLoaded = false
    var smokeSteamLoaded = false
    var smokeOverviewRefreshed = false
    let updateStatus = NSTextField(wrappingLabelWithString: "Checking for updates...")
    let updateButton = NSButton()
    var updateTask: Process?
    var updateURL: URL?
    var didRouteInitialLibrary = false
    var preferredMode: String?
    let navigationBar = NSStackView()
    let sidebarPanel = NSView()
    let splitController = NSSplitViewController()
    let storageHeading = NSTextField(labelWithString: "Choose your game storage")
    let storageAdvice = NSTextField(wrappingLabelWithString: "")
    let storageNext = SetupActionButton()
    let portablePreparation = NSStackView()
    let selectedStorage = NSTextField(wrappingLabelWithString: "")
    let selectedStorageIcon = NSImageView()
    let selectedStorageMode = NSTextField(labelWithString: "")
    let libraryHealth = NSStackView()
    let librarySummary = NSTextField(wrappingLabelWithString: "Checking your games…")
    let finishAdvice = NSTextField(wrappingLabelWithString: "")
    var advanceAfterLibraryCheck = false
    let preparationResult = NSTextField(wrappingLabelWithString: "")
    var helperButton: NSButton!
    let helperAdvice = NSTextField(wrappingLabelWithString:
        "Homebrew is needed only to install missing apps from here. Finish its Terminal installer, return here, then click the app's Install button. macOS may ask for administrator approval.")
    let autoLaunchToggle = NSSwitch()
    let signInChoices = NSStackView()
    let signInGuide = NSStackView()
    let afterLoginChoices = NSStackView()
    let tvMenuChoices = NSStackView()
    var consoleDelayRow = NSStackView()
    let autoLaunchDelay = NSTextField(string: "30")
    let autoLaunchStatus = NSTextField(wrappingLabelWithString: "")
    var autoLaunchLoaded = false
    enum OverviewCheck: CaseIterable { case storage, menu, consoles, automatic, steam, apps }
    var overviewChecks = Set<OverviewCheck>()
    /// The guided step currently shown; it stays until its tasks are done so arriving checks never make markers jump.
    var guidedPinnedPage: Int?
    var overviewCheckFailures = Set<OverviewCheck>()
    var steamReport: SteamLibraryReport?
    let steamGuideRows = NSStackView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Couch Cube"
        window.minSize = NSSize(width: 960, height: 720)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let chrome = NSToolbar(identifier: "WindowChrome")
        chrome.allowsUserCustomization = false
        chrome.displayMode = .iconOnly
        chrome.delegate = self
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
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[").target = self
        viewMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Activity", action: #selector(showActivity), keyEquivalent: "").target = self
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
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
        let sidebarBackground = sidebarPanel
        let sidebarController = NSViewController()
        sidebarController.view = sidebarBackground
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 210
        sidebarItem.canCollapse = false
        sidebarItem.allowsFullHeightLayout = true
        let detailController = NSViewController()
        detailController.view = mainDetail
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 716
        splitController.splitView.isVertical = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(detailItem)
        mainWindow.contentViewController = splitController
        sidebarBackground.addSubview(navigationBar)
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            navigationBar.topAnchor.constraint(equalTo: (mainWindow.contentLayoutGuide as! NSLayoutGuide).topAnchor),
            navigationBar.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -24)
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
            detail.topAnchor.constraint(equalTo: mainDetail.safeAreaLayoutGuide.topAnchor),
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
        for (item, symbol, label, action) in [
            (backToolbarItem, "chevron.left", "Back", #selector(goBack)),
            (forwardToolbarItem, "chevron.right", "Forward", #selector(goForward))
        ] {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isNavigational = true
            item.isBordered = true
            item.autovalidates = false
        }
        screenTitle.font = .systemFont(ofSize: 16, weight: .semibold)
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

        libraryTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        libraryDescription.textColor = .secondaryLabelColor
        libraryAction.title = "Update game library..."
        libraryAction.target = self
        libraryAction.action = #selector(setup)
        libraryAction.bezelStyle = .rounded
        actions.append(libraryAction)
        libraryControls.append(libraryAction)
        let openGames = headerIconButton("folder", label: "Open game folders", action: #selector(openFolder))
        let addGame = headerIconButton("plus", label: "Add a game…", action: #selector(registerGame))
        let play = TileActionButton(title: "", target: self, action: #selector(showPlayOverview))
        playAction = play
        libraryControls += [openGames, addGame, play]
        homeMenuLabel.textColor = .secondaryLabelColor
        homeProgress.style = .spinning
        homeProgress.controlSize = .small
        homeProgress.isDisplayedWhenStopped = false
        homeProgress.setAccessibilityLabel("Checking console status")
        homeControllerStatus.orientation = .vertical
        homeControllerStatus.alignment = .leading
        homeControllerStatus.spacing = 8
        let playCard = NSBox()
        playCard.boxType = .custom
        playCard.titlePosition = .noTitle
        playCard.contentViewMargins = .zero
        // The tile is Cube TV: it opens whichever TV menu you chose in Console Mode, named underneath.
        let playTitle = text("Cube TV", size: 22)
        playTitle.font = .systemFont(ofSize: 22, weight: .bold)
        playTitle.textColor = .white
        playTitle.shadow = NSShadow()
        playTitle.shadow?.shadowColor = .black
        playTitle.shadow?.shadowBlurRadius = 6
        play.title = ""
        play.isBordered = false
        play.toolTip = "Play"
        play.setAccessibilityLabel("Play")
        homePlayBackground.wantsLayer = true
        homePlayBackground.layer?.contentsGravity = .resizeAspectFill
        homePlayBackground.layer?.masksToBounds = true
        homePlayBackground.layer?.cornerRadius = 16
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        shade.layer?.cornerRadius = 16
        homePlaySubtitle.font = .systemFont(ofSize: 13, weight: .semibold)
        homePlaySubtitle.textColor = NSColor.white.withAlphaComponent(0.85)
        homePlaySubtitle.shadow = playTitle.shadow
        for view in [homePlayBackground, shade, playTitle, homePlaySubtitle, play] {
            view.translatesAutoresizingMaskIntoConstraints = false
            playCard.contentView!.addSubview(view)
        }
        pin(homePlayBackground, to: playCard.contentView!)
        pin(shade, to: playCard.contentView!)
        pin(play, to: playCard.contentView!)
        NSLayoutConstraint.activate([
            playTitle.topAnchor.constraint(equalTo: playCard.contentView!.topAnchor, constant: 16),
            playTitle.leadingAnchor.constraint(equalTo: playCard.contentView!.leadingAnchor, constant: 16),
            homePlaySubtitle.topAnchor.constraint(equalTo: playTitle.bottomAnchor, constant: 2),
            homePlaySubtitle.leadingAnchor.constraint(equalTo: playTitle.leadingAnchor),
            playCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        let openControllersButton = headerIconButton("list.bullet", label: "Open Controllers", action: #selector(showControllers))
        let controllerHeader = cardHeader("Controllers", buttons: [openControllersButton])
        controllerHeader.identifier = NSUserInterfaceItemIdentifier("home-controller-header")
        homeControllerStatus.spacing = 10
        homeDiscoveredControllerRows.orientation = .vertical
        homeDiscoveredControllerRows.alignment = .leading
        homeDiscoveredControllerRows.spacing = 10
        homeDiscoveredControllerRows.isHidden = true
        // The card is as tall as the Play tile; this filler takes the spare height so a newly shown
        // discovery row sits right under the list instead of being stretched to the card's bottom first.
        homeControllerStatus.setContentHuggingPriority(.required, for: .vertical)
        homeDiscoveredControllerRows.setContentHuggingPriority(.required, for: .vertical)
        let controllerCardFiller = NSView()
        controllerCardFiller.identifier = NSUserInterfaceItemIdentifier("home-controller-filler")
        controllerCardFiller.setContentHuggingPriority(.init(1), for: .vertical)
        controllerCardFiller.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let controllerCard = card("", subtitle: nil, views: [controllerHeader, homeControllerStatus, homeDiscoveredControllerRows, controllerCardFiller])
        controllerCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        for section in [playCard, controllerCard] {
            section.fillColor = .quaternaryLabelColor
            section.cornerRadius = 16
            section.borderWidth = 0
            if let contents = section.contentView?.subviews.first as? NSStackView {
                let first = contents.arrangedSubviews.first
                let title = first as? NSTextField ?? (first as? NSStackView)?.arrangedSubviews.first as? NSTextField
                title?.font = .systemFont(ofSize: 22, weight: .bold)
            }
        }
        playCard.fillColor = .systemBlue.withAlphaComponent(0.12)
        let homeCards = row([playCard, controllerCard])
        homeTiles = homeCards
        homeCards.distribution = .fillEqually
        homeCards.spacing = 20
        playCard.widthAnchor.constraint(equalTo: controllerCard.widthAnchor).isActive = true
        playCard.heightAnchor.constraint(equalTo: controllerCard.heightAnchor).isActive = true
        addPage("Play", content: column([
            homeCards,
            launcherSection()
        ]))

        for rows in [appMenuRows, appPCRows, appWindowsRows, appRetroRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        helperButton = button("Install Homebrew...", #selector(homebrew))
        helperAdvice.textColor = .secondaryLabelColor
        let appManagementText = text("macOS may block Couch Cube from updating or removing apps. Turn on Couch Cube in Privacy & Security \u{203A} App Management, then try again.", size: 12, secondary: true)
        appManagementHint.addArrangedSubview(appManagementText)
        appManagementHint.addArrangedSubview(button("Open App Management", #selector(openAppManagementSettings)))
        appManagementHint.orientation = .vertical
        appManagementHint.alignment = .leading
        appManagementHint.spacing = 6
        appManagementHint.isHidden = true
        appManagementHint.setAccessibilityIdentifier("appManagementHint")
        let apps = column([
            row([appsStatus, updateAllButton]),
            appManagementHint,
            appCategoryCard("TV menus", rows: appMenuRows),
            appCategoryCard("PC games", rows: appPCRows),
            appCategoryCard("Windows games", rows: appWindowsRows),
            appCategoryCard("Retro games", rows: appRetroRows),
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
        updateAllButton.isHidden = true
        actions.append(updateAllButton)
        addPage("App Store", content: apps)
        autoLaunchDelay.widthAnchor.constraint(equalToConstant: 64).isActive = true
        autoLaunchToggle.controlSize = .small
        autoLaunchToggle.setAccessibilityLabel("Automatic console mode on this Mac")
        autoLaunchDelay.setAccessibilityLabel("Seconds to wait after login, from 5 to 300")
        autoLaunchStatus.textColor = .secondaryLabelColor
        actions += [autoLaunchToggle, autoLaunchDelay]
        defaultMenuPicker.target = self
        defaultMenuPicker.action = #selector(defaultMenuChanged(_:))
        defaultMenuPicker.setAccessibilityLabel("Default TV menu")
        actions.append(defaultMenuPicker)
        transferLibraryButton = button("Move library...", #selector(moveLibrary))
        retireLibraryButton = button("Move old library to Trash...", #selector(retireOldLibrary))
        retireLibraryButton.isHidden = true
        // Library storage is part of Game library; the index stays so page numbers remain stable.
        addPage("Library storage", content: column([]))
        updateButton.title = "View release..."
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.isEnabled = false
        updateButton.bezelStyle = .rounded
        addPage("Library storage", content: column([]))
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
            card("Library storage", subtitle: "Choose a drive. Existing files are kept.", views: [
                driveRows,
                summary,
                button("Refresh connected drives", #selector(refresh)),
                primary(storageNext),
                button("Copy this app to SSD...", #selector(copyAppToSSD))
            ]),
            button("Change storage type", #selector(backToChoices))
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
                views: [text("Install a game from your Steam library, then choose Play on Home. Existing Steam games stay where they are.", size: 12, secondary: true),
                        button("Controllers", #selector(showControllers))]),
            card("Optional: retro & Windows games in Big Picture", subtitle: nil, views: [
                retroAdvice, row([button("Open Steam desktop", #selector(openSteamDesktop)),
                                 button("Open game folders", #selector(openFolder))])
            ])
        ]))
        librarySummary.font = .systemFont(ofSize: 12)
        librarySummary.textColor = .secondaryLabelColor
        librarySummary.identifier = NSUserInterfaceItemIdentifier("library-summary")
        let yourGames = cardHeader("Your games", buttons: [addGame, openGames])
        yourGames.identifier = NSUserInterfaceItemIdentifier("library-header")
        (yourGames.arrangedSubviews.first as? NSTextField)?.font = .systemFont(ofSize: 17, weight: .semibold)
        let storageHeader = cardHeader("Where your games live", buttons: [libraryStorageMenu()])
        (storageHeader.arrangedSubviews.first as? NSTextField)?.font = .systemFont(ofSize: 17, weight: .semibold)
        gameLibraryOverviewRows.orientation = .vertical
        gameLibraryOverviewRows.alignment = .leading
        gameLibraryOverviewRows.spacing = 0
        addPage("Game library", content: column([
            card("", subtitle: nil, views: [
                storageHeader,
                text("Keep games on this Mac or an external SSD. Choose a drive to see what's on it.", size: 12, secondary: true),
                setupFolderStatus, gameLibraryOverviewRows, libraryHealth, libraryTitle, libraryDescription, libraryAction,
                row([button("Refresh connected drives", #selector(refresh)), button("Add or prepare an SSD...", #selector(choosePortable))])
            ]),
            card("", subtitle: nil, views: [yourGames, librarySummary]),
            card("Move your library", subtitle: "Copies everything to another drive and checks it. The old copy stays until you remove it.", views: [
                transferLibraryButton, retireLibraryButton
            ])
        ]))
        consoleRows.orientation = .vertical
        consoleRows.alignment = .leading
        consoleRows.spacing = 16
        addPage("Consoles", content: column([
            consoleStatus,
            consoleRows
        ]))
        for rows in [activeControllerRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
        }
        controllerAccessButton = controllerButton("Allow Bluetooth Access", #selector(controllerBluetoothAccess))
        controllerAccessButton.bezelStyle = .rounded
        controllerSortMenu.addItem(withTitle: "")
        controllerSortMenu.item(at: 0)?.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
        for (tag, title) in ["Your Order", "Connected First"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(controllerSortChanged(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            controllerSortMenu.menu?.addItem(item)
        }
        controllerSortMenu.bezelStyle = .inline
        controllerSortMenu.isBordered = false
        (controllerSortMenu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        controllerSortMenu.setAccessibilityLabel("Sort controllers")
        controllerSortMenu.widthAnchor.constraint(equalToConstant: 28).isActive = true
        updateControllerSortMenu()
        discoveredControllerRows.orientation = .vertical
        discoveredControllerRows.alignment = .leading
        discoveredControllerRows.spacing = 0
        discoveredControllerRows.isHidden = true
        loadControllerPreferences()
        controllerStatus.font = .systemFont(ofSize: 12)
        let bannerIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Attention")!)
        bannerIcon.contentTintColor = .systemYellow
        bannerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        bannerIcon.setContentHuggingPriority(.required, for: .horizontal)
        controllerStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controllerBanner = card("", subtitle: nil, views: [row([bannerIcon, controllerStatus, controllerAccessButton])], inset: 12)
        controllerBanner.fillColor = NSColor.systemYellow.withAlphaComponent(0.12)
        controllerBanner.borderColor = NSColor.systemYellow.withAlphaComponent(0.35)
        controllerBanner.isHidden = true
        let bluetoothSettings = headerIconButton("", label: "Bluetooth Settings", action: #selector(openBluetooth))
        bluetoothSettings.image = ControllerGlyph.bluetooth
        bluetoothSettings.imageScaling = .scaleNone
        let gameControllerSettings = headerIconButton("gearshape", label: "Game Controller Settings", action: #selector(openGameControllerSettings))
        let pairingHint = text("To add a wireless controller, put it in pairing mode. It appears here with a Connect button. Xbox and other Bluetooth LE controllers may only appear in Bluetooth Settings.", size: 11, secondary: true)
        addPage("Controllers", content: column([
            controllerBanner,
            card("", subtitle: nil, views: [
                cardHeader("Controllers", buttons: [controllerSortMenu, bluetoothSettings, gameControllerSettings]),
                activeControllerRows, discoveredControllerRows, pairingHint
            ])
        ]))
        inspectorTitle.font = .systemFont(ofSize: 22, weight: .bold)
        inspectorRows.orientation = .vertical
        inspectorRows.alignment = .leading
        inspectorRows.spacing = 12
        addPage("Details", content: column([
            card("Details", subtitle: nil, views: [inspectorRows])
        ]))
        // Console Mode answers three questions in the order they happen: getting in, what starts, and what opens.
        for list in [signInChoices, signInGuide, afterLoginChoices, tvMenuChoices] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 2
        }
        signInGuide.spacing = 8
        signInGuide.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
        autoLaunchDelay.target = self
        autoLaunchDelay.action = #selector(consoleDelayChanged)
        consoleDelayRow = row([text("Wait"), autoLaunchDelay, text("seconds after signing in, so the Mac can settle.", secondary: true)])
        consoleDelayRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 0, right: 8)
        addPage("Console Mode", content: column([
            card("1  Signing in & waking", subtitle: "After a restart, and when the Mac wakes from sleep.", views: [signInChoices, signInGuide]),
            card("2  Open at Login", subtitle: "What starts by itself after you sign in.", views: [afterLoginChoices, consoleDelayRow, autoLaunchStatus]),
            card("3  On the TV", subtitle: "Which menu Play and the TV mode open.", views: [tvMenuChoices, tvMenuStatus])
        ]))
        renderConsoleMode()
        addPage("App Settings", content: column([
            card("App Settings", subtitle: nil, views: [
                settingsRow("App updates", subtitle: "Check for a new version of Couch Cube.",
                            symbol: "arrow.down.circle", color: .systemGreen,
                            trailing: row([button("Check...", #selector(checkUpdates)), updateButton]),
                            detail: updateStatus),
                separator(),
                settingsRow("App location", subtitle: "Find this copy of Couch Cube.", symbol: "folder",
                            color: .systemGray, trailing: button("Show in Finder", #selector(revealApp))),
                separator(),
                settingsRow("Remove Couch Cube", subtitle: "Your games, saves and other apps are kept.", symbol: "trash",
                            color: .systemGray, trailing: button("Uninstall...", #selector(uninstallCouchCube))),
                separator(),
                settingsRow("Clean up gaming setup", subtitle: "Choose what to remove from this Mac.", symbol: "trash",
                            color: .systemRed, trailing: button("Review...", #selector(reviewGamingCleanup)))
            ]),
            shopSettingsCard(),
            storeAccountsCard()
        ]))
        driveDetailRows.orientation = .vertical
        driveDetailRows.alignment = .leading
        driveDetailRows.spacing = 16
        addPage("Drive", content: column([driveDetailRows]))
        // Cube Shop is a storefront: wider than the settings pages, so shelves show several games side by side.
        addPage("Cube Shop", content: column([cubeShopPage()]), maxWidth: 960)
        shopDetailContent.orientation = .vertical
        shopDetailContent.alignment = .leading
        shopDetailContent.spacing = 16
        shopDetailContent.setAccessibilityIdentifier("shopGamePage")
        addPage("Game", content: column([shopDetailContent]), maxWidth: 820)
        cleanupContent.orientation = .vertical
        cleanupContent.alignment = .leading
        cleanupContent.spacing = 16
        cleanupContent.setAccessibilityIdentifier("cleanupPage")
        addPage("Clean up", content: column([cleanupContent]))
        navigationBar.orientation = .vertical
        navigationBar.alignment = .leading
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        let navigationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Navigation"))
        navigationColumn.resizingMask = .autoresizingMask
        sidebar.addTableColumn(navigationColumn)
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        selectPage(0)
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

    @objc func checkUpdates() {
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
                    self.updateStatus.stringValue = self.friendlyBackendError(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                do {
                    let report = try JSONDecoder().decode(UpdateReport.self, from: data)
                    self.updateStatus.stringValue = report.available
                        ? "Couch Cube \(report.version) is available. Download it and replace the app after quitting."
                        : "You're up to date. Latest published release: \(report.version)."
                    self.updateURL = URL(string: report.url)
                    self.updateButton.title = "Download..."
                    self.updateButton.isHidden = !report.available
                    self.updateButton.isEnabled = report.available && self.updateURL != nil
                    self.couchCubeUpdateAvailable = report.available
                    self.renderGeneral()
                    if report.available {
                        self.status.stringValue = "App update available. Open Settings to view the release."
                    }
                } catch {
                    self.updateStatus.stringValue = "Couldn't read GitHub update information: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc func openUpdate() {
        if let url = updateURL { NSWorkspace.shared.open(url) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if controllerPageVisible { refreshControllers() }
    }

    /// Shared with Library Settings so both pages name and draw storage modes the same way.
    static let storageModes: [(mode: String, title: String, symbol: String)] = [
        ("local", "This Mac", "macmini"), ("portable", "External SSD", "externaldrive")
    ]

    var currentPage: Int {
        tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? -1
    }

    var detailDrive: Drive? {
        driveDetailID.flatMap { id in storageStatus?.locations.first { $0.drive.id == id }?.drive }
    }

    var steamOverviewSummary: String {
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

    let controllerColors = ControllerPalette.colors

    /// Your order is the stored list order. Connected first is a stable partition of that same order.
    let homeControllerLimit = 4

    var controllerPageVisible: Bool {
        tabs.selectedTabViewItem === tabs.tabViewItems[0] ||
            tabs.selectedTabViewItem === tabs.tabViewItems[8]
    }

    let controllerStatusResistance = NSLayoutConstraint.Priority(490)

    var effectiveFrontend: String? {
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

    var controllerBluetoothNeedsAttention: Bool {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return controllerSmokeBanner }
        return CBManager.authorization != .allowedAlways || bluetoothManager?.state == .poweredOff
    }

    let computerGameApps: Set<String> = ["steam", "gog-galaxy", "ea", "epic-games", "battle-net", "curseforge"]
    let emulatorApps: Set<String> = ["retroarch-metal", "dolphin", "pcsx2", "rpcs3", "cemu-wiiu", "switch"]

    var overviewAppSummary: String {
        guard report != nil || !appStates.isEmpty else { return "Not checked" }
        let computer = installedAppCount(computerGameApps)
        let emulators = installedAppCount(emulatorApps)
        return "\(computer) PC game app\(computer == 1 ? "" : "s") · \(emulators) emulator\(emulators == 1 ? "" : "s") installed"
    }

    let collapsedAppCategoriesKey = "collapsedAppCategories"
    lazy var collapsedAppCategories: Set<String> = ProcessInfo.processInfo.arguments.contains("--smoke-test") ? [] :
        Set(UserDefaults.standard.stringArray(forKey: collapsedAppCategoriesKey) ?? [])
    var appCategoryToggles: [String: NSButton] = [:]

    static let shopArtworkSize = NSSize(width: 112, height: 52)
    static let shopHeadingSize: CGFloat = 19
    /// Extra room above each Home section after the first (on top of the heading's own 14 pt), so sections read as blocks.
    static let shopSectionGap: CGFloat = 14
    static let shopHeartWidth: CGFloat = 22, shopPriceWidth: CGFloat = 96, shopPercentWidth: CGFloat = 128, shopOfferWidth: CGFloat = 190, shopMarkerWidth: CGFloat = 80, shopChildIndent: CGFloat = 40

    static let storeIconCache = NSCache<NSString, NSImage>()

    /// Ratings a store deal can carry. Each kind has its own fixed column, so Steam always sits under Steam,
    /// Metacritic under Metacritic and the deal rating under the deal rating; a missing one leaves its slot empty.
    struct ShopRatings {
        var steamPercent: Int? = nil
        var steamText: String? = nil
        var metacritic: Int? = nil
        var deal: Double? = nil
        static let none = ShopRatings()
    }

    static let shopRatingWidths: (steam: CGFloat, metacritic: CGFloat, deal: CGFloat) = (50, 40, 40)

    var shopScopeMine: Bool { UserDefaults.standard.string(forKey: shopScopeKey) != "all" }

    /// The display currency, or nil for original prices (the default, whatever the Mac's locale).
    var shopCurrency: String? {
        let saved = UserDefaults.standard.string(forKey: shopCurrencyKey)
        guard let saved, ShopMoney.currencies.contains(saved) else { return nil }
        return saved
    }

    var shopFeePercent: Decimal {
        let value = UserDefaults.standard.double(forKey: shopFeeKey)
        return value > 0 && value <= 20 ? ShopMoney.decimal(value) : 0
    }

    var shopCountry: String { Locale.current.region?.identifier ?? "US" }

    var shopSearchQuery: String {
        String(shopSearchField.stringValue.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
    }

    /// Installed apps that run Windows games (nil until the app list has been read).
    var compatibilityLayers: [String]? {
        guard lastAppsData != nil else { return nil }
        return ["crossover", "porting-kit"].compactMap { id in appStates.first { $0.id == id && $0.installed }?.name }
    }

    /// A compact badge (logo + short label) and the full explanation for tooltips and VoiceOver.
    /// System yellow is too pale for small text on a light background, so light mode uses a deeper amber.
    static let windowsYellow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : NSColor(srgbRed: 0.72, green: 0.53, blue: 0, alpha: 1)
    }

    var wishlistEditable: Bool { wishlist.map { !$0.readOnly && !$0.offline } ?? false }

    /// Matches LOCAL_WISHLIST_NOTE in scripts/console.py: no drive is set up yet, so the wishlist lives on this Mac.
    static let localWishlistNote = "Saved on this Mac. It moves to your Couch Cube drive when you set one up."

    let appPurposes = [
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

    var highlightedAppID: String?

    static let appUpdatedMessage = "Couch Cube was updated while it was open. Please quit and reopen Couch Cube."

    var pendingEmulatorInstall: ManagedApp?
    var pendingAppStoreID: String?

    var esdeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.lastPathComponent == "ES-DE.app" }
    }

    var cleanupInProgress = false
    var cleanupReviewChoices: [NSButton] = []
    var cleanupPlan: CleanupPlan?
    var cleanupMessage: (text: String, color: NSColor)?
    let cleanupContent = NSStackView()
    let cleanupSummary = NSTextField(labelWithString: "")
    let cleanupRemoveSelf = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let cleanupConfirmField = NSTextField()
    let cleanupRemoveButton = NSButton()

    /// Only an explicit debug flag lets Activity open by itself; release builds open it solely from View > Activity.
    static let activityAutoOpens = ProcessInfo.processInfo.environment["COUCH_CUBE_DEBUG_ACTIVITY"] == "1"
    var lastProblemNotice: String?

    var selected: Drive? {
        let index = volumeMenu.indexOfSelectedItem
        return volumes.indices.contains(index) ? volumes[index] : nil
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
