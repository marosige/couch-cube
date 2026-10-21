import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


/// An official Windows launcher installer that Couch Cube can download (never run) into the library's Downloads folder.
struct StoreAccountName: Decodable, Equatable {
    let account: String
    let persona: String?
    let most_recent: Bool
}

/// One game client's sign-in status, read by the backend from local client files only (no web, no secrets).
struct StoreAccountRow: Decodable, Equatable {
    let id: String
    let name: String
    let state: String
    let detail: String
    let platform: String
    let kind: String
    let host: String?
    let bottle: String?
    let accounts: [StoreAccountName]
}

struct StoreAccountsReport: Decodable, Equatable {
    let clients: [StoreAccountRow]
    let installed: Int
    let signed_in: Int
}

/// Checks run only when asked (page open, Check Again, a launched client quitting); a stale reply never wins.
struct StoreAccountsModel {
    enum Phase: Equatable { case idle, checking, loaded, failed }
    private(set) var phase = Phase.idle
    private(set) var report: StoreAccountsReport?
    private(set) var lastChecked: Date?
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation += 1
        phase = .checking
        return generation
    }

    /// Returns false when the reply belongs to an older check. A failed check keeps the last good report.
    @discardableResult
    mutating func finish(_ check: Int, report newReport: StoreAccountsReport?, at date: Date) -> Bool {
        guard check == generation, phase == .checking else { return false }
        if let newReport {
            report = newReport
            lastChecked = date
            phase = .loaded
        } else {
            phase = .failed
        }
        return true
    }

    var summary: String {
        guard let report else { return phase == .failed ? "Couldn't check game clients" : "Checking game clients\u{2026}" }
        if report.installed == 0 { return "No game clients installed" }
        return "\(report.signed_in) of \(report.installed) signed in"
    }
}

/// The guided walkthrough visits installed clients one at a time; any step can be skipped.
struct StoreAccountsWalkthrough: Equatable {
    let ids: [String]
    private(set) var index = 0
    private(set) var skipped: [String] = []

    init(report: StoreAccountsReport) {
        ids = report.clients.filter { $0.state != "not_installed" }.map(\.id)
    }

    var current: String? { ids.indices.contains(index) ? ids[index] : nil }
    var finished: Bool { current == nil }

    mutating func next() { if !finished { index += 1 } }
    mutating func skip() {
        if let current { skipped.append(current) }
        next()
    }
}

struct WindowsDownloadItem: Decodable, Equatable {
    let id: String
    let name: String
    let vendor: String
    let kind: String
    let downloaded: Bool
    let file: String?
    let size: Int64?
    let sha256: String?
}

struct WindowsDownloadsReply: Decodable {
    let library: String?
    let folder: String?
    let items: [WindowsDownloadItem]
}

struct WindowsDownloadJob {
    var done: Int64 = 0
    var total: Int64 = 0
    var failure: String?
    var running = true
    var canceled = false
    var cancel: (() -> Void)?
}

/// Real byte progress reported by the backend as "PROGRESS <done> <total>" (total 0 when the server didn't say).
func windowsDownloadProgress(_ line: String) -> (done: Int64, total: Int64)? {
    let parts = line.split(separator: " ")
    guard parts.count == 3, parts[0] == "PROGRESS", let done = Int64(parts[1]), let total = Int64(parts[2]),
          done >= 0, total >= 0 else { return nil }
    return (done, total)
}

func windowsDownloadStatus(_ item: WindowsDownloadItem, job: WindowsDownloadJob?) -> (title: String, color: NSColor, pulsing: Bool) {
    if let job, job.running {
        if job.total > 0 { return ("Downloading \u{00B7} \(min(99, job.done * 100 / job.total))%", .systemBlue, true) }
        if job.done > 0 { return ("Downloading \u{00B7} " + ByteCountFormatter.string(fromByteCount: job.done, countStyle: .file), .systemBlue, true) }
        return ("Downloading\u{2026}", .systemBlue, true)
    }
    if job?.failure != nil { return ("Couldn't download", .systemRed, false) }
    return item.downloaded ? ("Downloaded", .systemGreen, false) : ("Not downloaded", .systemGray, false)
}

/// Last backend "ERROR: ..." line, for an inline message.
func backendErrorMessage(_ errors: String, fallback: String) -> String {
    let line = errors.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
    let message = line.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
    return message.isEmpty ? fallback : String(message.prefix(300))
}

struct AppOperation: Equatable {
    let action: String
    var phase: String?
    var failure: String?
    var running: Bool
}

/// The latest real Homebrew phase in a chunk of output. Homebrew hides download percentages when its output isn't a terminal,
/// so App Store rows show phases with an indeterminate spinner rather than invented percentages.
func appOperationPhase(_ output: String, action: String) -> String? {
    var phase: String?
    for line in output.split(whereSeparator: \.isNewline) {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("==> Downloading") || text.hasPrefix("==> Fetching") { phase = "Downloading" }
        else if text.hasPrefix("==> Uninstalling") || text.hasPrefix("==> Removing") || text.hasPrefix("==> Backing App") || text.hasPrefix("==> Purging") {
            phase = action == "remove" ? "Removing" : "Installing"
        } else if text.hasPrefix("==> Installing") || text.hasPrefix("==> Upgrading") || text.hasPrefix("==> Moving") {
            phase = action == "update" ? "Updating" : "Installing"
        }
    }
    return phase
}

/// Row status for an App Store app. Green means a verified installed, up-to-date app.
func appRowStatus(_ app: ManagedApp, operation: AppOperation?, unknown: Bool, checking: Bool) -> (title: String, color: NSColor, pulsing: Bool) {
    if let operation, operation.running {
        let verb = operation.action == "remove" ? "Removing" : operation.action == "update" ? "Updating" : "Installing"
        let phase = operation.phase.map { $0 == verb ? "" : " · \($0)" } ?? ""
        return (verb + phase + "\u{2026}", .systemBlue, true)
    }
    if let failure = operation?.failure { return (failure, .systemRed, false) }
    if unknown { return (checking ? "Checking..." : "Not checked", checking ? .systemBlue : .systemGray, checking) }
    let hasUpdate = app.installed && app.managed && app.update?.isEmpty == false
    return app.installed ? (hasUpdate ? ("Installed · Update available", .systemYellow, false) : ("Installed", .systemGreen, false))
        : ("Not installed", .systemRed, false)
}
