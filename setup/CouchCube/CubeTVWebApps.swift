import AppKit
import GameController
import WebKit

/// A full-screen web app (YouTube TV, Apple Music...): a name and an https address.
struct TVWebApp: Codable, Equatable {
    let id: String
    let name: String
    let url: String
}

enum TVWebApps {
    static let key = "cubeTVWebApps"
    static let youtube = TVWebApp(id: "youtube", name: "YouTube", url: "https://www.youtube.com/tv")
    /// Hosts YouTube's TV page and its sign-in need; everything else is the app's own site.
    static let youtubeHosts = ["youtube.com", "google.com", "googlevideo.com", "gstatic.com", "ytimg.com", "ggpht.com", "youtube-nocookie.com"]

    static var saved: [TVWebApp] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let apps = try? JSONDecoder().decode([TVWebApp].self, from: data) else { return [] }
            return apps
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static var all: [TVWebApp] { [youtube] + saved }

    /// A web app from what the person typed; nil unless it has a name and a plain https address.
    static func make(name: String, address: String) -> TVWebApp? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 40,
              let url = safeDealURL(address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let id = "app-" + String(url.absoluteString.hashValue.magnitude, radix: 36)
        return TVWebApp(id: id, name: title, url: url.absoluteString)
    }

    /// The site's registrable domain: sign-in and CDN subdomains of the same company stay allowed.
    static func baseDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        let take = labels[labels.count - 2].count <= 3 && secondLevel.contains(labels[labels.count - 2]) && labels.last?.count == 2 ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    static func allowedDomains(for app: TVWebApp) -> [String] {
        if app.id == youtube.id { return youtubeHosts }
        return URL(string: app.url)?.host.map { [baseDomain($0)] } ?? []
    }

    static func isAllowed(host: String, app: TVWebApp) -> Bool {
        let host = host.lowercased()
        return allowedDomains(for: app).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// YouTube serves its remote-control "leanback" page only to TV browsers.
    static func userAgent(for app: TVWebApp) -> String? {
        app.id == youtube.id
            ? "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) 85.0.4183.93/6.5 TV Safari/537.36"
            : nil
    }
}

/// A web app in its own full-screen window. It can only open its own site's pages, there is no address bar and no
/// new tabs. Controllers and keyboard steer it; Start (or Command-W) goes back to Cube TV.
final class TVWebWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static var current: TVWebWindowController?

    private let app: TVWebApp
    private let onExit: () -> Void
    private let window: CubeTVWindow
    private let webView: WKWebView
    private let input = TVPadInput()
    private var monitor: Any?
    private var finished = false

    static func open(_ app: TVWebApp, onExit: @escaping () -> Void = {}) {
        if let current {
            current.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = TVWebWindowController(app, onExit: onExit)
        current = controller
        controller.show()
    }

    private init(_ app: TVWebApp, onExit: @escaping () -> Void) {
        self.app = app
        self.onExit = onExit
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = CubeTVWindow.standard(title: app.name)
        super.init()
        window.delegate = self
        webView.customUserAgent = TVWebApps.userAgent(for: app)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        window.contentView = webView
    }

    private func show() {
        if let url = URL(string: app.url) { webView.load(URLRequest(url: url)) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        window.makeFirstResponder(webView)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.keyCode == 13 else { return event }
            self.exit()
            return nil
        }
        input.onMove = { [weak self] dx, dy in
            switch (dx, dy) {
            case (-1, _): self?.press(123, NSLeftArrowFunctionKey)
            case (1, _): self?.press(124, NSRightArrowFunctionKey)
            case (_, -1): self?.press(126, NSUpArrowFunctionKey)
            default: self?.press(125, NSDownArrowFunctionKey)
            }
        }
        input.onSelect = { [weak self] in self?.press(36, 13) }
        input.onBack = { [weak self] in self?.press(53, 27) }
        input.onStart = { [weak self] in self?.exit() }
        input.bind()
        hint("Start (or \u{2318}W) goes back to Cube TV")
    }

    func windowWillClose(_ notification: Notification) { exit() }

    func exit() {
        guard !finished else { return }
        finished = true
        window.delegate = nil
        input.unbind()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.close()
        Self.current = nil
        onExit()
    }

    /// Sends a real key press to the page, so TV web apps (which listen for arrows, Return and Escape) just work.
    private func press(_ code: UInt16, _ scalar: Int) {
        guard let value = UnicodeScalar(UInt32(scalar)) else { return }
        let text = String(Character(value))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    private func hint(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.drawsBackground = true
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 40, y: 40)
        webView.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { label.removeFromSuperview() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        let allowed = url.scheme == "https" && url.host.map { TVWebApps.isAllowed(host: $0, app: app) } == true
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// Links that want a new window open in this one, if they stay on the app's own site.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https",
           let host = url.host, TVWebApps.isAllowed(host: host, app: app) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
