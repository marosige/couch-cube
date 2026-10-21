import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


/// One actionable item behind a numbered sidebar dot. Guided setup shows one page's tasks at a time; otherwise all show.
struct SidebarTask: Equatable {
    let page: Int
    let color: NSColor
    let title: String
    let setup: Bool
}

struct SidebarSeverity: Equatable {
    let color: NSColor
    let titles: [String]
    var count: Int { titles.count }
}

/// A page's tasks split by severity, most severe first, so red and yellow each get their own count.
struct SidebarBadge: Equatable {
    let groups: [SidebarSeverity]
    var count: Int { groups.reduce(0) { $0 + $1.count } }
    var color: NSColor { groups.first?.color ?? .systemYellow }
    var titles: [String] { groups.flatMap(\.titles) }
}

func sidebarSeverityRank(_ color: NSColor) -> Int {
    color == .systemRed ? 0 : color == .systemYellow ? 1 : 2
}

let guidedSetupOrder = [6, 1, 10, 7, 8, 11]
/// With guidance on, only the first page (in setup order) that has any task is marked, setup or maintenance alike.
/// Guided markers wait for checks to settle and never jump: while checks run, the shown step is kept as it was
/// (nothing is shown before the first step is known); once settled, the pinned step stays until it has no tasks.
func guidedSidebarStep(_ tasks: [SidebarTask], pinned: Int?, settled: Bool,
                       previous: [Int: SidebarBadge]) -> (badges: [Int: SidebarBadge], pinned: Int?) {
    guard settled else {
        guard let pinned = pinned else { return ([:], nil) }
        return (previous.filter { $0.key == pinned }, pinned)
    }
    let badges = sidebarBadges(tasks, guided: true, pinned: pinned)
    return (badges, badges.keys.first)
}

func sidebarSeverityName(_ color: NSColor) -> String {
    color == .systemRed ? "needs attention" : color == .systemYellow ? "recommended" : "info"
}

/// With guidance on, only one page is marked, setup or maintenance alike: the pinned page while it still has tasks,
/// otherwise the first page in setup order that has any.
func sidebarBadges(_ tasks: [SidebarTask], guided: Bool, pinned: Int? = nil) -> [Int: SidebarBadge] {
    let guidedPage = guided ? ([pinned].compactMap { $0 } + guidedSetupOrder + tasks.map(\.page)).first { page in tasks.contains { $0.page == page } } : nil
    let visible = tasks.filter { !guided || $0.page == guidedPage }
    return Dictionary(grouping: visible, by: \.page).mapValues { tasks in
        var colors: [NSColor] = []
        for task in tasks where !colors.contains(task.color) { colors.append(task.color) }
        let groups = colors.enumerated().sorted {
            (sidebarSeverityRank($0.element), $0.offset) < (sidebarSeverityRank($1.element), $1.offset)
        }.map { _, color in
            SidebarSeverity(color: color, titles: tasks.filter { $0.color == color }.map(\.title))
        }
        return SidebarBadge(groups: groups)
    }
}

final class SidebarCountDot: NSView {
    init(count: Int, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: count > 99 ? "99+" : "\(count)")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.identifier = NSUserInterfaceItemIdentifier("sidebar-count")
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        self.color = color
    }

    required init?(coder: NSCoder) { nil }

    var color: NSColor = .systemYellow { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = color.usingColorSpace(.sRGB) ?? color
            layer?.backgroundColor = fill.withAlphaComponent(0.28).cgColor
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let number = dark ? fill.blended(withFraction: 0.25, of: .white) : fill.blended(withFraction: 0.45, of: .black)
            (subviews.first as? NSTextField)?.textColor = number ?? fill
        }
    }
}
