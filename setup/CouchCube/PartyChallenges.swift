import Foundation

/// Things a group might have at hand; a challenge only comes up when everything it needs is there.
enum PartyProp: String, CaseIterable {
    case paper, pens, cups, coins, ball, spoons, outside

    var title: String {
        switch self {
        case .paper: return "A4 paper"
        case .pens: return "Pens"
        case .cups: return "Cups"
        case .coins: return "Coins"
        case .ball: return "A ball"
        case .spoons: return "Spoons"
        case .outside: return "We're outside (beach, park)"
        }
    }
}

/// One round's task: what to do, how long (nil: no clock, play until there's a winner) and what it needs.
struct PartyChallenge: Equatable {
    let title: String
    let text: String
    let seconds: Int?
    let needs: Set<PartyProp>
    /// Only playable indoors (e.g. needs a table and a quiet room); left out when the group is outside.
    var indoors = false
    /// A Herd Mind round: everyone answers the question, and everyone with the most common answer scores.
    var question: String? = nil
}

enum PartyChallenges {
    static let all: [PartyChallenge] = [
        // Paper
        .init(title: "Paper Planes", text: "Fold a paper plane. When time is up, everyone throws from the same line. The farthest flight wins.", seconds: 180, needs: [.paper]),
        .init(title: "Paper Tower", text: "Build the tallest tower from one sheet of paper. No tape, no help. It must stand on its own for 5 seconds.", seconds: 180, needs: [.paper]),
        .init(title: "Paper Hat", text: "Make a hat from one sheet and wear it. Everyone votes for the best one (not your own).", seconds: 120, needs: [.paper]),
        .init(title: "Snowfall", text: "Tear one sheet into the most pieces you can. Most pieces when time runs out wins.", seconds: 60, needs: [.paper], indoors: true),
        .init(title: "Paper Ball Basket", text: "Crumple a paper ball and stand three big steps from a cup. Three throws each; most hits wins.", seconds: nil, needs: [.paper, .cups]),
        // Pens and paper
        .init(title: "Blind Portrait", text: "Draw the player on your left with your eyes closed. Everyone votes for the best (or funniest) portrait.", seconds: 60, needs: [.paper, .pens]),
        .init(title: "One-Line Animal", text: "Draw an animal without lifting the pen. The others guess; the first drawing guessed right wins.", seconds: 45, needs: [.paper, .pens]),
        .init(title: "Word Hunt", text: "Write as many words as you can that start with the letter shown on screen. Longest valid list wins.", seconds: 60, needs: [.paper, .pens]),
        .init(title: "Tiny Comic", text: "Draw a three-panel comic about tonight. Everyone votes for their favourite.", seconds: 180, needs: [.paper, .pens]),
        // Cups, coins, spoons, ball
        .init(title: "Cup Pyramid", text: "Stack every cup into a pyramid, then back into one stack. Fastest wins; take turns with the timer.", seconds: nil, needs: [.cups]),
        .init(title: "Coin Flick", text: "Flick a coin across the table. Closest to the edge without falling off wins.", seconds: nil, needs: [.coins], indoors: true),
        .init(title: "Coin Tower", text: "Build the tallest coin tower you can. Tallest tower still standing when time is up wins.", seconds: 60, needs: [.coins], indoors: true),
        .init(title: "Spoon on Nose", text: "Hang a spoon on your nose. The one who keeps it there longest wins.", seconds: nil, needs: [.spoons]),
        .init(title: "Egg-Free Race", text: "Carry a coin on a spoon in your mouth around the room and back. Drop it and you start again. Fastest wins.", seconds: nil, needs: [.spoons, .coins]),
        .init(title: "Keepy-Uppy", text: "Keep the ball in the air without hands. Most touches in one go wins.", seconds: nil, needs: [.ball]),
        .init(title: "Bounce Count", text: "Bounce the ball off the floor and catch it, as many times as you can. Most catches wins.", seconds: 30, needs: [.ball]),
        // Nothing needed
        .init(title: "Statue", text: "Everyone freezes in a pose. Move, blink a lot or laugh and you're out. Last statue wins.", seconds: nil, needs: []),
        .init(title: "Category Chain", text: "Name animals, one each, round the circle. Repeat one or take longer than 3 seconds and you're out. Last one in wins.", seconds: nil, needs: []),
        .init(title: "Hum That Song", text: "Take turns humming a song. The first to guess it gets a point; most points wins.", seconds: 180, needs: []),
        .init(title: "Staring Contest", text: "Pair up and stare. First to blink loses; winners face each other until one is left.", seconds: nil, needs: []),
        .init(title: "Flamingo", text: "Stand on one leg with your eyes closed. The last one standing wins.", seconds: nil, needs: []),
        .init(title: "Tongue Twister", text: "Say \u{201C}Red lorry, yellow lorry\u{201D} five times fast. The others judge; cleanest and fastest wins.", seconds: nil, needs: []),
        .init(title: "Silent Movie", text: "Act out a film without words. First to guess scores; the actor with the fastest guess wins.", seconds: 180, needs: []),
        .init(title: "Alphabet Story", text: "Tell a story together, each sentence starting with the next letter (A, B, C…). Get stuck and you're out.", seconds: nil, needs: []),
        .init(title: "Robot Dance", text: "Thirty seconds of your best robot dance each. Everyone votes for the best robot.", seconds: nil, needs: []),
        .init(title: "Plank", text: "Everyone holds a plank. The last one still up wins.", seconds: nil, needs: []),
        // Outside
        .init(title: "Long Jump", text: "Standing long jump from the same line. Farthest landing wins.", seconds: nil, needs: [.outside]),
        .init(title: "Treasure Hunt", text: "Collect as many different things as you can: shells, stones, leaves. Most different finds wins.", seconds: 120, needs: [.outside]),
        .init(title: "Sand Sculpture", text: "Build a sculpture in the sand (or from what's around). Everyone votes for the best.", seconds: 300, needs: [.outside]),
        .init(title: "Stone Skimming", text: "Skim a flat stone on water. Most bounces in three tries wins. No water? Throw at a target instead.", seconds: nil, needs: [.outside]),
        .init(title: "Giant Drawing", text: "Draw the biggest smiley you can with your foot or a stick. Biggest finished smiley wins.", seconds: 60, needs: [.outside]),
        .init(title: "Ball Target", text: "Mark a target 10 steps away. Three throws each; closest to the target wins.", seconds: nil, needs: [.outside, .ball])
    ]

    /// Herd Mind: no right answers, only the most popular one. Short, common answers work best.
    static let herdQuestions = [
        "Name a fruit.", "Name a colour.", "Name a pizza topping.", "Name a famous footballer.", "Name an animal at the zoo.",
        "Name a breakfast food.", "Name a country in Europe.", "Name a superhero.", "Name something you take to the beach.",
        "Name a sport played with a ball.", "Name a Disney film.", "Name an ice cream flavour.", "Name a car brand.",
        "Name a musical instrument.", "Name a board game.", "Name a vegetable.", "Name a city with a famous tower.",
        "Name a farm animal.", "Name a cartoon character.", "Name a drink you'd order on holiday.", "Name a day of the week.",
        "Name a number between 1 and 10.", "Name something yellow.", "Name a video game.", "Name a sea creature.",
        "Name a dessert.", "Name a famous singer.", "Name something in a kitchen.", "Name a thing you pack in a suitcase.",
        "Name a bird.", "Name a Harry Potter character.", "Name a planet.", "Name a pet's name.", "Name a fast-food chain."
    ]

    /// Challenges the group can play with what it has; indoor-only ones are skipped outside.
    static func playable(with props: Set<PartyProp>) -> [PartyChallenge] {
        all.filter { $0.needs.isSubset(of: props) && !(props.contains(.outside) && $0.indoors) }
    }
}

/// One party: players, scores and a shuffled run of challenges with no repeats.
struct PartyGame {
    var players: [String] = []
    var props: Set<PartyProp> = []
    var rounds = 8
    /// Every other round is a Herd Mind question (on by default).
    var herd = true
    var scores: [String: Int] = [:]
    var queue: [PartyChallenge] = []
    var round = 0
    var started = false

    var current: PartyChallenge? { started && round < queue.count ? queue[round] : nil }
    var finished: Bool { started && round >= queue.count }
    var ranking: [(name: String, points: Int)] {
        players.map { ($0, scores[$0] ?? 0) }.sorted { $0.points != $1.points ? $0.points > $1.points : $0.name < $1.name }
    }

    mutating func start<G: RandomNumberGenerator>(using generator: inout G) {
        let challenges = PartyChallenges.playable(with: props).shuffled(using: &generator)
        if herd {
            var questions = PartyChallenges.herdQuestions.shuffled(using: &generator).makeIterator()
            queue = []
            var picks = challenges.makeIterator()
            while queue.count < rounds {
                let next: PartyChallenge?
                if queue.count % 2 == 1, let question = questions.next() {
                    next = PartyChallenge(title: "Herd Mind", text: "", seconds: nil, needs: [], question: question)
                } else {
                    next = picks.next() ?? questions.next().map { PartyChallenge(title: "Herd Mind", text: "", seconds: nil, needs: [], question: $0) }
                }
                guard let next else { break }
                queue.append(next)
            }
        } else {
            queue = Array(challenges.prefix(rounds))
        }
        scores = Dictionary(uniqueKeysWithValues: players.map { ($0, 0) })
        round = 0
        started = true
    }

    mutating func start() {
        var generator = SystemRandomNumberGenerator()
        start(using: &generator)
    }

    /// Ends the round; each winner (a Herd Mind round can have many, a challenge one or none) gets a point.
    mutating func finishRound(winners: [String]) {
        guard current != nil else { return }
        for winner in Set(winners) where players.contains(winner) { scores[winner, default: 0] += 1 }
        round += 1
    }

    /// The letter for Word Hunt, picked once per round so it stays put while the round is on screen.
    static let letters = Array("ABCDEFGHIKLMNOPRSTW")
}
