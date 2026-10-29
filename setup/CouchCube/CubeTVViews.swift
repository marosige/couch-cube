import AppKit
import SwiftUI

/// A tile's picture: art that fills, a box cover shown whole, or an icon on a plate (tinted for pages and apps).
struct TVArt: View {
    let game: TVGame

    var body: some View {
        ZStack {
            plate
            if let url = game.remoteURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } else { icon }
                }
            } else if let image = game.image {
                switch game.art {
                case .fill: Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                case .fit: Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
                case .icon: icon
                }
            } else {
                icon
            }
        }
    }

    private var plate: some View {
        let base = game.tint.map { Color(nsColor: $0) } ?? Color(white: 0.2)
        return LinearGradient(colors: [base.opacity(game.tint == nil ? 1 : 0.95), base.opacity(game.tint == nil ? 0.55 : 0.55)],
                              startPoint: .top, endPoint: .bottom)
    }

    private var icon: some View {
        Group {
            if let symbol = game.symbol {
                Image(systemName: symbol).font(.system(size: 64, weight: .medium)).foregroundColor(.white)
            } else if let image = game.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 96, height: 96)
            } else {
                Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

struct TVCard: View {
    let game: TVGame
    let focused: Bool
    /// Steam's header proportions (460 × 215), so the usual art is not cropped.
    static let size = CGSize(width: 400, height: 187)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArt(game: game)
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0.95 : 0), lineWidth: 4))
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 24, y: 14)
            Text(game.title).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                .lineLimit(1).opacity(focused ? 1 : 0.7)
        }
        .frame(width: Self.size.width)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct TVBackdrop: View {
    let game: TVGame?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let game {
                TVArt(game: game).blur(radius: 40).opacity(0.45).clipped()
                    .animation(.easeOut(duration: 0.3), value: game.id)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct TVHints: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 32) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item.0, systemImage: item.1)
            }
        }
        .font(.system(size: 18)).foregroundColor(.white.opacity(0.6))
        .padding(.horizontal, 80).padding(.vertical, 20)
    }
}

/// Home and Store: a hero for the focused tile above scrolling shelves.
struct TVBrowser: View {
    let set: TVShelfSet
    let heading: String?
    let empty: String
    let hints: [(String, String)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVBackdrop(game: set.focused)
            VStack(alignment: .leading, spacing: 0) {
                hero.frame(height: 280)
                if set.shelves.isEmpty {
                    Text(empty).font(.system(size: 24)).foregroundColor(.white.opacity(0.7)).padding(.horizontal, 80)
                    Spacer()
                } else {
                    shelves
                }
                TVHints(items: hints)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            if let heading {
                Text(heading.uppercased()).font(.system(size: 20, weight: .bold)).foregroundColor(.white.opacity(0.6))
            }
            Text(set.focused?.title ?? "Cube TV")
                .font(.system(size: 60, weight: .bold)).foregroundColor(.white).lineLimit(1)
            Text(set.focused?.subtitle ?? "")
                .font(.system(size: 26, weight: .medium)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
        }
        .padding(.horizontal, 80).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shelves: some View {
        ScrollViewReader { vertical in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(set.shelves.enumerated()), id: \.element.id) { index, shelf in
                        shelfView(index, shelf).id(shelf.id)
                    }
                }
                .padding(.bottom, 200)
            }
            .onChange(of: set.row) { row in
                guard set.shelves.indices.contains(row) else { return }
                withAnimation(.easeOut(duration: 0.25)) { vertical.scrollTo(set.shelves[row].id, anchor: .top) }
            }
        }
    }

    private func shelfView(_ index: Int, _ shelf: TVShelf) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shelf.title).font(.system(size: 26, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 80)
            ScrollViewReader { horizontal in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(Array(shelf.games.enumerated()), id: \.element.id) { column, game in
                            TVCard(game: game, focused: set.row == index && set.columns.indices.contains(index) && set.columns[index] == column)
                                .id(game.id)
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 24)
                }
                .onChange(of: set.columns) { columns in
                    guard set.row == index, columns.indices.contains(index), shelf.games.indices.contains(columns[index]) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { horizontal.scrollTo(shelf.games[columns[index]].id, anchor: .center) }
                }
            }
        }
    }
}

/// The page before a game starts, like the Steam Deck's: big art, name, then Play and a few more buttons.
struct TVDetail: View {
    @ObservedObject var model: CubeTVModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVBackdrop(game: model.detail)
            if let game = model.detail {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 56) {
                        TVArt(game: game)
                            .frame(width: 640, height: 299)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                        VStack(alignment: .leading, spacing: 14) {
                            Text(game.title).font(.system(size: 54, weight: .bold)).foregroundColor(.white).lineLimit(2)
                            Text(game.subtitle).font(.system(size: 26, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            if let deal = game.deal { dealLine(deal) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 80)
                    HStack(spacing: 20) {
                        ForEach(Array(model.detailButtons.enumerated()), id: \.offset) { index, title in
                            let selected = index == model.detailIndex
                            Text(title)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(selected ? .black : .white)
                                .padding(.horizontal, 36).padding(.vertical, 16)
                                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.18)))
                                .scaleEffect(selected ? 1.06 : 1)
                                .animation(.easeOut(duration: 0.15), value: selected)
                        }
                    }
                    .padding(.horizontal, 80).padding(.top, 40)
                    Spacer()
                    TVHints(items: [("Select: Return or bottom button", "return"), ("Back: Esc or right button", "chevron.left"),
                                    ("Menu: Start", "line.3.horizontal")])
                }
            }
        }
    }

    private func dealLine(_ deal: TVGame.Deal) -> some View {
        HStack(spacing: 14) {
            Text(deal.price).font(.system(size: 40, weight: .bold)).foregroundColor(.white)
            if let was = deal.was { Text(was).font(.system(size: 26)).strikethrough().foregroundColor(.white.opacity(0.5)) }
            if deal.savings > 0 {
                Text("-\(deal.savings)%").font(.system(size: 24, weight: .bold)).foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(Color.green))
            }
            if let store = deal.store { Text(store).font(.system(size: 24)).foregroundColor(.white.opacity(0.6)) }
        }
    }
}

/// Connected controllers (Return cycles the player number), the live test line and controllers ready to pair.
struct TVControllersPage: View {
    @ObservedObject var model: CubeTVModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            LinearGradient(colors: [Color(red: 0.16, green: 0.14, blue: 0.32), .black], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 18) {
                Text("Controllers").font(.system(size: 56, weight: .bold)).foregroundColor(.white)
                if model.pads.isEmpty {
                    Text("No controller is connected. Press a button on a controller that is already paired, or pair one below.")
                        .font(.system(size: 24)).foregroundColor(.white.opacity(0.7))
                }
                ForEach(Array(model.pads.enumerated()), id: \.element.id) { index, pad in
                    row(selected: model.padIndex == index, symbol: "gamecontroller.fill", title: pad.name,
                        detail: [pad.battery.isEmpty ? nil : "Battery \(pad.battery)", pad.player > 0 ? "Player \(pad.player)" : "No player number"]
                            .compactMap { $0 }.joined(separator: " \u{00B7} "),
                        action: "Change player")
                }
                if !model.testText.isEmpty {
                    Label(model.testText, systemImage: "hand.tap.fill").font(.system(size: 24)).foregroundColor(.green)
                }
                Text("Pair a new controller").font(.system(size: 30, weight: .semibold)).foregroundColor(.white).padding(.top, 20)
                Text(model.pairable.isEmpty
                     ? "Hold the pairing button on your controller until its light flashes. It shows up here."
                     : "Found nearby. Select one to pair it.")
                    .font(.system(size: 22)).foregroundColor(.white.opacity(0.7))
                ForEach(Array(model.pairable.enumerated()), id: \.element.id) { index, device in
                    row(selected: model.padIndex == model.pads.count + index, symbol: "dot.radiowaves.left.and.right",
                        title: device.name, detail: "Ready to pair", action: "Pair")
                }
                Spacer()
                TVHints(items: [("Select: Return or bottom button", "return"), ("Back: Esc or right button", "chevron.left"),
                                ("Menu: Start", "line.3.horizontal")])
            }
            .padding(.horizontal, 80).padding(.top, 70)
        }
    }

    private func row(selected: Bool, symbol: String, title: String, detail: String, action: String) -> some View {
        HStack(spacing: 20) {
            Image(systemName: symbol).font(.system(size: 34)).frame(width: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .semibold))
                Text(detail).font(.system(size: 20)).opacity(0.7)
            }
            Spacer()
            if selected { Text(action).font(.system(size: 22, weight: .medium)) }
        }
        .foregroundColor(selected ? .black : .white)
        .padding(.horizontal, 28).padding(.vertical, 16)
        .frame(maxWidth: 900)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Color.white : Color.white.opacity(0.12)))
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct CubeTVView: View {
    @ObservedObject var model: CubeTVModel

    var body: some View {
        ZStack {
            switch model.page {
            case .home:
                TVBrowser(set: model.home, heading: nil,
                          empty: "Your games appear here: Steam games, ROMs in your game library and Windows games.",
                          hints: [("Open: Return or bottom button", "play.fill"), ("Menu: Esc or Start", "line.3.horizontal")])
            case .store:
                TVBrowser(set: model.store, heading: "Store",
                          empty: "Loading the store\u{2026} Connect to the internet if this stays empty.",
                          hints: [("Open: Return or bottom button", "play.fill"), ("Back: Esc or right button", "chevron.left"),
                                  ("Menu: Start", "line.3.horizontal")])
            case .detail:
                TVDetail(model: model)
            case .controllers:
                TVControllersPage(model: model)
            }
            if model.menuOpen { powerMenu }
        }
        .ignoresSafeArea()
    }

    private func fill(_ action: TVMenuAction, _ selected: Bool) -> Color {
        if action.isDanger { return selected ? Color(red: 0.92, green: 0.2, blue: 0.2) : Color(red: 0.55, green: 0.12, blue: 0.12) }
        return selected ? Color.white : Color.white.opacity(0.16)
    }

    private var powerMenu: some View {
        ZStack {
            Color.black.opacity(0.65)
            VStack(spacing: 10) {
                Text("Cube TV").font(.system(size: 34, weight: .bold)).foregroundColor(.white).padding(.bottom, 12)
                ForEach(Array(TVMenuAction.allCases.enumerated()), id: \.element) { index, action in
                    let selected = index == model.menuIndex
                    if action == .preload { Divider().overlay(Color.white.opacity(0.25)).padding(.vertical, 6) }
                    HStack(spacing: 16) {
                        Image(systemName: action.symbol).frame(width: 32)
                        Text(model.confirming == action ? "Press again to \(action.title.lowercased())" : action.title)
                        Spacer()
                    }
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(selected && !action.isDanger ? .black : .white)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .frame(width: 520)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill(action, selected)))
                    .scaleEffect(selected ? 1.03 : 1)
                    .animation(.easeOut(duration: 0.12), value: selected)
                }
            }
            .padding(36)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
        }
    }
}
