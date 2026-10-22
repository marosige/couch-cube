import AppKit


extension SetupController {
    // MARK: Party Challenges (page 17): a party game for the couch, played on the TV between video games.

    func partyPage() -> NSStackView {
        partyContent.orientation = .vertical
        partyContent.alignment = .leading
        partyContent.spacing = 16
        partyContent.setAccessibilityIdentifier("partyPage")
        partyNameField.placeholderString = "Player name"
        partyNameField.target = self
        partyNameField.action = #selector(partyAddPlayer)
        partyNameField.setAccessibilityLabel("New player name")
        partyClock.font = .monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        partyClock.alignment = .center
        partyClock.setAccessibilityIdentifier("partyClock")
        party.players = UserDefaults.standard.stringArray(forKey: "partyPlayers") ?? []
        party.props = Set((UserDefaults.standard.stringArray(forKey: "partyProps") ?? []).compactMap(PartyProp.init(rawValue:)))
        party.herd = !UserDefaults.standard.bool(forKey: "partyNoHerd")
        renderParty()
        return column([partyContent])
    }

    func renderParty() {
        clearRows(partyContent)
        func add(_ view: NSView) {
            partyContent.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: partyContent.widthAnchor).isActive = true
        }
        if !party.started {
            partySetupViews().forEach(add)
        } else if party.finished {
            partyResultViews().forEach(add)
        } else {
            partyRoundViews().forEach(add)
        }
    }

    // MARK: Setup

    func partySetupViews() -> [NSView] {
        let intro = text("Short challenges for everyone in the room. Tick what you have, add the players and go.", size: 13, secondary: true)
        let add = button("Add", #selector(partyAddPlayer))
        let entry = row([partyNameField, add])
        partyNameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var playerViews: [NSView] = [entry]
        if party.players.isEmpty {
            playerViews.append(text("Add at least two players.", size: 12, secondary: true))
        } else {
            let pills: [NSView] = party.players.enumerated().map { index, name in
                let chip = button(name + "  \u{2715}", #selector(partyRemovePlayer(_:)))
                chip.tag = index
                chip.toolTip = "Remove \(name)"
                chip.setAccessibilityLabel("Remove \(name)")
                return chip
            }
            playerViews.append(row(pills + [NSView()]))
        }
        let players = card("Players", subtitle: nil, views: playerViews)

        let checks: [NSView] = PartyProp.allCases.map { prop in
            let check = NSButton(checkboxWithTitle: prop.title, target: self, action: #selector(partyPropToggled(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(prop.rawValue)
            check.state = party.props.contains(prop) ? .on : .off
            return check
        }
        let grid = NSGridView(views: stride(from: 0, to: checks.count, by: 2).map { start in
            Array(checks[start..<min(start + 2, checks.count)]) + (start + 1 < checks.count ? [] : [NSView()])
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 24
        let props = card("What do you have?", subtitle: "Only challenges you can play come up.", views: [grid, herd])

        let herd = NSButton(checkboxWithTitle: "Mix in Herd Mind questions", target: self, action: #selector(partyHerdToggled(_:)))
        herd.state = party.herd ? .on : .off
        herd.toolTip = "Every other round everyone answers a question; the most common answer scores"
        let available = PartyChallenges.playable(with: party.props).count + (party.herd ? PartyChallenges.herdQuestions.count : 0)
        let rounds = NSPopUpButton()
        for count in [5, 8, 12] { rounds.addItem(withTitle: "\(count) rounds"); rounds.lastItem?.tag = count }
        rounds.selectItem(withTag: party.rounds)
        rounds.target = self
        rounds.action = #selector(partyRoundsChanged(_:))
        let start = primary(button("Start", #selector(partyStart)))
        start.isEnabled = party.players.count >= 2 && available > 0
        start.setAccessibilityIdentifier("partyStart")
        let note = text("\(available) challenges fit what you have.", size: 12, secondary: true)
        return [intro, players, props, row([rounds, note, NSView(), start])]
    }

    @objc func partyAddPlayer() {
        let name = partyNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !party.players.contains(name), party.players.count < 16 else { return }
        party.players.append(String(name.prefix(20)))
        partyNameField.stringValue = ""
        savePartySetup()
        renderParty()
        mainWindow.makeFirstResponder(partyNameField)
    }

    @objc func partyRemovePlayer(_ sender: NSButton) {
        guard party.players.indices.contains(sender.tag) else { return }
        party.players.remove(at: sender.tag)
        savePartySetup()
        renderParty()
    }

    @objc func partyPropToggled(_ sender: NSButton) {
        guard let prop = sender.identifier.flatMap({ PartyProp(rawValue: $0.rawValue) }) else { return }
        if sender.state == .on { party.props.insert(prop) } else { party.props.remove(prop) }
        savePartySetup()
        renderParty()
    }

    @objc func partyHerdToggled(_ sender: NSButton) {
        party.herd = sender.state == .on
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") { UserDefaults.standard.set(!party.herd, forKey: "partyNoHerd") }
        renderParty()
    }

    @objc func partyRoundsChanged(_ sender: NSPopUpButton) {
        party.rounds = sender.selectedTag()
    }

    func savePartySetup() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        UserDefaults.standard.set(party.players, forKey: "partyPlayers")
        UserDefaults.standard.set(party.props.map(\.rawValue).sorted(), forKey: "partyProps")
    }

    @objc func partyStart() {
        guard party.players.count >= 2 else { return }
        party.start()
        beginPartyRound()
    }

    // MARK: Rounds

    func beginPartyRound() {
        partyTimer?.invalidate()
        partyTimer = nil
        partySecondsLeft = party.current?.seconds
        partyLetter = PartyGame.letters.randomElement() ?? "A"
        partyHerdPicks = []
        renderParty()
    }

    func partyRoundViews() -> [NSView] {
        guard let challenge = party.current else { return [] }
        if let question = challenge.question { return partyHerdViews(question) }
        let kicker = text("ROUND \(party.round + 1) OF \(party.queue.count)", size: 12, secondary: true)
        kicker.font = .systemFont(ofSize: 12, weight: .heavy)
        let header = row([kicker, NSView(), button("End Game", #selector(partyEnd))])
        let title = text(challenge.title, size: 34)
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.setAccessibilityIdentifier("partyChallengeTitle")
        var views: [NSView] = [title, text(challenge.text, size: 17)]
        if challenge.title == "Word Hunt" {
            let letter = text("Letter: \(partyLetter)", size: 28)
            letter.font = .systemFont(ofSize: 28, weight: .bold)
            letter.textColor = .controlAccentColor
            views.append(letter)
        }
        if challenge.seconds != nil {
            updatePartyClock()
            let toggle = button(partyTimer == nil ? (partySecondsLeft == challenge.seconds ? "Start Timer" : "Resume") : "Pause",
                                #selector(partyClockToggle))
            toggle.setAccessibilityIdentifier("partyClockToggle")
            views.append(row([partyClock, toggle, NSView()]))
        }
        if !challenge.needs.isEmpty {
            let needs = challenge.needs.sorted { $0.rawValue < $1.rawValue }.map { $0.title }
            views.append(text("You need: " + needs.joined(separator: ", "), size: 12, secondary: true))
        }
        let card = self.card("", subtitle: nil, views: views, inset: 24)

        let winners: [NSView] = party.players.map { name in
            let pick = button(name, #selector(partyWinner(_:)))
            pick.identifier = NSUserInterfaceItemIdentifier("winner:" + name)
            pick.controlSize = .large
            return pick
        }
        let nobody = button("Nobody", #selector(partyWinner(_:)))
        nobody.identifier = NSUserInterfaceItemIdentifier("winner:")
        let whoWon = text("Who won this round?", size: 15)
        whoWon.font = .systemFont(ofSize: 15, weight: .semibold)
        let score = text("Score: " + party.ranking.map { "\($0.name) \($0.points)" }.joined(separator: " \u{00B7} "), size: 12, secondary: true)
        return [header, card, whoWon, row(winners + [nobody, NSView()]), score]
    }

    func updatePartyClock() {
        guard let left = partySecondsLeft else { partyClock.stringValue = ""; return }
        partyClock.stringValue = String(format: "%d:%02d", left / 60, left % 60)
        partyClock.textColor = left == 0 ? .systemRed : left <= 10 ? .systemOrange : .labelColor
    }

    @objc func partyClockToggle() {
        if let timer = partyTimer {
            timer.invalidate()
            partyTimer = nil
        } else {
            if partySecondsLeft == 0 { partySecondsLeft = party.current?.seconds }
            partyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard let self, let left = self.partySecondsLeft else { timer.invalidate(); return }
                self.partySecondsLeft = max(0, left - 1)
                self.updatePartyClock()
                if self.partySecondsLeft == 0 {
                    timer.invalidate()
                    self.partyTimer = nil
                    NSSound(named: "Glass")?.play()
                    self.renderParty()
                }
            }
        }
        renderParty()
    }

    @objc func partyWinner(_ sender: NSButton) {
        let name = String(sender.identifier?.rawValue.dropFirst("winner:".count) ?? "")
        party.finishRound(winners: name.isEmpty ? [] : [name])
        beginPartyRound()
    }

    /// Herd Mind: a question, how to answer fairly with or without paper, then tick everyone who gave the top answer.
    func partyHerdViews(_ question: String) -> [NSView] {
        let kicker = text("ROUND \(party.round + 1) OF \(party.queue.count) \u{00B7} HERD MIND", size: 12, secondary: true)
        kicker.font = .systemFont(ofSize: 12, weight: .heavy)
        let header = row([kicker, NSView(), button("End Game", #selector(partyEnd))])
        let title = text(question, size: 34)
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.setAccessibilityIdentifier("partyChallengeTitle")
        let how = party.props.contains(.paper) && party.props.contains(.pens)
            ? "Everyone writes an answer secretly, then all reveal at once."
            : "Raise your hand when you have an answer. When every hand is up, say it together on three: one, two, three! No changing your answer."
        let card = self.card("", subtitle: nil, views: [title, text(how, size: 17),
                                                        text("Everyone with the most common answer gets a point.", size: 13, secondary: true)], inset: 24)
        let who = text("Who gave the most common answer?", size: 15)
        who.font = .systemFont(ofSize: 15, weight: .semibold)
        let checks: [NSView] = party.players.map { name in
            let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(partyHerdPick(_:)))
            check.identifier = NSUserInterfaceItemIdentifier("herd:" + name)
            check.state = partyHerdPicks.contains(name) ? .on : .off
            return check
        }
        let give = primary(button(partyHerdPicks.isEmpty ? "Nobody Scores" : "Give Points", #selector(partyHerdDone)))
        give.setAccessibilityIdentifier("partyHerdDone")
        let score = text("Score: " + party.ranking.map { "\($0.name) \($0.points)" }.joined(separator: " \u{00B7} "), size: 12, secondary: true)
        return [header, card, who, row(checks + [NSView()]), row([give, NSView()]), score]
    }

    @objc func partyHerdPick(_ sender: NSButton) {
        let name = String(sender.identifier?.rawValue.dropFirst("herd:".count) ?? "")
        if sender.state == .on { partyHerdPicks.insert(name) } else { partyHerdPicks.remove(name) }
        renderParty()
    }

    @objc func partyHerdDone() {
        party.finishRound(winners: Array(partyHerdPicks))
        beginPartyRound()
    }

    @objc func partyEnd() {
        partyTimer?.invalidate()
        partyTimer = nil
        party.round = party.queue.count
        renderParty()
    }

    // MARK: Results

    func partyResultViews() -> [NSView] {
        let ranking = party.ranking
        let top = ranking.first?.points ?? 0
        let winners = ranking.filter { $0.points == top && top > 0 }.map(\.name)
        let headline = text(winners.isEmpty ? "Nobody scored. Rematch?"
                            : ListFormatter.localizedString(byJoining: winners) + (winners.count == 1 ? " wins!" : " share the win!"), size: 34)
        headline.font = .systemFont(ofSize: 34, weight: .bold)
        headline.setAccessibilityIdentifier("partyWinner")
        let trophy = NSImageView(image: NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: nil)!)
        trophy.symbolConfiguration = .init(pointSize: 44, weight: .bold)
        trophy.contentTintColor = .systemYellow
        let lines: [NSView] = ranking.enumerated().map { index, entry in
            let place = text("\(index + 1).", size: 15, secondary: true)
            let name = text(entry.name, size: 15)
            let points = text(entry.points == 1 ? "1 point" : "\(entry.points) points", size: 15, secondary: true)
            return row([place, name, NSView(), points])
        }
        let again = primary(button("Play Again", #selector(partyPlayAgain)))
        return [row([trophy, headline, NSView()]), card("Scores", subtitle: nil, views: lines),
                row([again, button("New Game", #selector(partyNewGame)), NSView()])]
    }

    @objc func partyPlayAgain() {
        party.start()
        beginPartyRound()
    }

    @objc func partyNewGame() {
        party.started = false
        party.queue = []
        renderParty()
    }
}
