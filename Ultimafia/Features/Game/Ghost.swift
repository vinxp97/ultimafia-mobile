import SwiftUI

/// Ghost mini-game. On the site Ghost is not its own game type: it is a Mafia game whose setup
/// has the Ghost role (Cult). Server: Mafia/roles/cards/GhostGame.js, items/OuijaBoard.js
/// ("Give Clue", text 1–50, instant) and items/GhostGuessWord.js ("Guess Word", text 2–20 letters,
/// Dusk, condemned Cult). Every Mafia `state` carries `extraInfo` { wordLength,
/// currentClueHistory: ["Name: clue", …] (whole game, never reset), showGameInfo }. The turn moves
/// inside one "Give Clue N" state; `giveClue` broadcasts the id of the player holding the board.
/// Clues also arrive live as alerts ("Name: clue"). The app shows the game as one continuous
/// chat (like Liars Dice), with the clues and whose turn it is pinned in the header and the Act tab.
nonisolated struct GhostInfo: Hashable {
    var wordLength: Int?
    var clues: [String]
    var showGameInfo: Bool

    init?(_ extra: Any?) {
        guard let x = extra as? [String: Any] else { return nil }
        var len: Int?
        if let i = x["wordLength"] as? Int { len = i }
        else if let d = x["wordLength"] as? Double { len = Int(d) }
        else if let s = x["wordLength"] as? String { len = Int(s) }
        let list = (x["currentClueHistory"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard len != nil || !list.isEmpty else { return nil }
        wordLength = len
        clues = list
        showGameInfo = (x["showGameInfo"] as? Bool) ?? !list.isEmpty
    }

    init(wordLength: Int?, clues: [String]) {
        self.wordLength = wordLength
        self.clues = clues
        showGameInfo = !clues.isEmpty
    }

    /// "Name: clue", split on the first colon (web MafiaGame Clue).
    static func split(_ raw: String) -> (name: String, text: String) {
        guard let i = raw.firstIndex(of: ":") else { return ("", raw.trimmingCharacters(in: .whitespaces)) }
        return (String(raw[..<i]).trimmingCharacters(in: .whitespaces),
                String(raw[raw.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }
}

struct GhostClue: Identifiable, Hashable {
    var index: Int
    var name: String
    var text: String
    /// Day number of the clue round (the Give Clue state's dayCount).
    var round: Int?
    var id: Int { index }
}

enum GhostStage { case pregame, night, clue, day, dusk, other, over }

extension GameSession {
    /// Mafia setup with the Ghost role. Host without Poet turns the mini-game off on the server
    /// (GhostGame.js picks no words, no clue rounds, wordLength undefined): treat that as plain
    /// Mafia unless a word length or clue shows up anyway.
    var isGhostGame: Bool {
        guard !isLiarsDice else { return false }
        let names = Set((setupRoles + setupRolesets.flatMap { $0 }).map(\.name))
        let seenInfo = ghostByPhase.values.contains { $0.wordLength != nil || !$0.clues.isEmpty }
        guard names.contains("Ghost") || seenInfo else { return false }
        if names.contains("Host"), !names.contains("Poet"), !seenInfo, ghostClues.isEmpty { return false }
        return true
    }

    /// Something to show in the Ghost panel (word length, a word, or clues).
    var ghostHasContent: Bool {
        ghostWordLength != nil || ghostMyWord != nil || ghostIAmGuessing || ghostRealWord != nil || !ghostClues.isEmpty
    }

    /// Games shown as one continuous chat with no phase switcher.
    var isSingleStateView: Bool { isLiarsDice || isGhostGame }

    private func ghostRank(_ id: Int) -> Int { id == -2 ? Int.max : id }

    var ghostWordLength: Int? {
        ghostByPhase.sorted { ghostRank($0.key) > ghostRank($1.key) }.lazy.compactMap(\.value.wordLength).first
    }

    var ghostStage: GhostStage {
        if finished { return .over }
        let n = stateName.lowercased()
        if currentPhaseId < 0 || n.contains("pregame") { return .pregame }
        if n.hasPrefix("give clue") { return .clue }
        if n.hasPrefix("night") || n.hasPrefix("dawn") { return .night }
        if n.hasPrefix("dusk") { return .dusk }
        if n.hasPrefix("day") { return .day }
        return .other
    }

    private func ghostClueKey(_ raw: String) -> String {
        let sp = GhostInfo.split(raw)
        return "\(sp.name): \(sp.text)"
    }

    /// Every clue so far, rebuilt from the "<name>: <clue>" alerts of each Give Clue state (the
    /// Day-start "Clues" repeats are ignored). extraInfo.currentClueHistory is one shared, growing
    /// array: the live `state` is a snapshot at state start, but history/replays show the whole
    /// game in every state after the first clue. So it is only a seed for clues whose alerts we
    /// don't have (e.g. trimmed chat), put first and never duplicated.
    var ghostClues: [GhostClue] {
        let ordered = phases.sorted { ghostRank($0.id) < ghostRank($1.id) }
        let seed = ghostByPhase.values.max { $0.clues.count < $1.clues.count }?.clues ?? []
        var names = Set(players.map(\.name))
        for raw in seed { names.insert(GhostInfo.split(raw).name) }
        var fromAlerts: [GhostClue] = []
        var seenIds = Set<String>()
        for p in ordered where p.name.lowercased().hasPrefix("give clue") {
            for line in p.messages where line.isServer && line.meetingId == nil {
                guard seenIds.insert(line.id).inserted else { continue }
                let sp = GhostInfo.split(line.content)
                guard !sp.name.isEmpty, !sp.text.isEmpty, names.contains(sp.name) else { continue }
                fromAlerts.append(GhostClue(index: 0, name: sp.name, text: sp.text, round: p.dayCount))
            }
        }
        var out: [GhostClue] = []
        if seed.count > fromAlerts.count {
            var have: [String: Int] = [:]
            for c in fromAlerts { have["\(c.name): \(c.text)", default: 0] += 1 }
            for raw in seed {
                let key = ghostClueKey(raw)
                if let n = have[key], n > 0 { have[key] = n - 1; continue }
                let sp = GhostInfo.split(raw)
                out.append(GhostClue(index: 0, name: sp.name, text: sp.text, round: nil))
            }
        }
        out += fromAlerts
        for i in out.indices { out[i].index = i }
        return out
    }

    /// You hold the Ouija Board: only the holder is a member of its "Give Clue" meeting.
    var ghostHoldsBoard: Bool {
        meetings.contains { ($0.name == "Give Clue" || $0.itemName == "Ouija Board") && $0.amMember }
    }

    /// Whose turn it is to give a clue (only during Give Clue). You: the Give Clue meeting. Others:
    /// the newest "<name> is giving a clue…" alert in this state, else the state before it (the
    /// round's first holder is announced at Night). `giveClue` (not re-sent on reconnect) is the
    /// last resort.
    var ghostTurn: (id: String?, name: String)? {
        guard ghostStage == .clue else { return nil }
        if ghostHoldsBoard, let me = selfId {
            return (me, players.first { $0.id == me }?.name ?? "You")
        }
        let ordered = phases.sorted { ghostRank($0.id) < ghostRank($1.id) }
        if let i = ordered.firstIndex(where: { $0.id == currentPhaseId }) {
            for p in [ordered[i]] + (i > 0 ? [ordered[i - 1]] : []) {
                for line in p.messages.reversed() where line.isServer {
                    for suffix in [" is giving a clue…", " is giving a clue..."] where line.content.hasSuffix(suffix) {
                        let name = String(line.content.dropLast(suffix.count))
                        return (players.first { $0.name == name }?.id, name)
                    }
                }
            }
        }
        if let id = ghostTurnPlayerId, let p = players.first(where: { $0.id == id }) { return (id, p.name) }
        return nil
    }

    var isMyGhostTurn: Bool { ghostHoldsBoard }

    private func ghostAlertValue(prefix: String) -> String? {
        for line in messages.reversed() where line.isServer && line.content.hasPrefix(prefix) {
            var v = String(line.content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if v.hasSuffix(".") { v.removeLast() }
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// The private "The secret word is: X." alert (Ghosts never get one).
    var ghostMyWord: String? { ghostAlertValue(prefix: "The secret word is:") }
    var ghostIAmGuessing: Bool { ghostAlertValue(prefix: "Guess the hidden word of length:") != nil }
    var ghostRealWord: String? { ghostAlertValue(prefix: "The real word was ") }
    var ghostFakeWord: String? { ghostAlertValue(prefix: "The fake word was ") }

    /// Alive non-Host players without a clue this round, in the order the board will reach them:
    /// seat order (players list / playerListPosition), starting after the holder, wrapping.
    var ghostStillToGive: [GamePlayer] {
        guard ghostStage == .clue else { return [] }
        let clues = ghostClues
        let round = clues.last(where: { $0.round != nil })?.round ?? dayCount
        let given = Set(clues.filter { $0.round == round }.map(\.name))
        let seats = orderedPlayers(players).filter { !$0.left && !isDead($0.id) && knownRoles[$0.id] != "Host" }
        let holder = ghostTurn
        var order = seats
        if let h = holder, let i = seats.firstIndex(where: { $0.id == h.id || $0.name == h.name }) {
            order = Array(seats[(i + 1)...] + seats[..<i])
        }
        return order.filter { !given.contains($0.name) && $0.name != holder?.name }
    }

    func ghostPlayer(named name: String) -> GamePlayer? { players.first { $0.name == name } }

    /// Short status for the header and Act tab.
    var ghostStatusText: String {
        switch ghostStage {
        case .pregame: return "Clues start after the first night"
        case .night:
            if meetings.contains(where: { $0.name == "Ghost" && $0.amMember }) { return "Pick the first clue giver" }
            return "Night"
        case .clue:
            if isMyGhostTurn { return "Your turn: give a clue" }
            if let t = ghostTurn { return "\(t.name) is giving a clue" }
            return "Clue round"
        case .day: return "Vote out who you think is a Ghost"
        case .dusk:
            if meetings.contains(where: { $0.name == "Guess Word" && $0.amMember }) { return "Your guess: type the word" }
            return "The condemned may guess the word"
        case .over:
            if let w = ghostRealWord { return "The word was \(w)" }
            return "Game over"
        case .other: return stateName
        }
    }

    /// Header-sized version of ghostStatusText.
    var ghostShortStatus: String {
        switch ghostStage {
        case .pregame: return "Waiting"
        case .night:
            return meetings.contains(where: { $0.name == "Ghost" && $0.amMember }) ? "Pick clue giver" : "Night"
        case .clue:
            if isMyGhostTurn { return "Your turn!" }
            if let t = ghostTurn { return "\(t.name)'s turn" }
            return "Clues"
        case .day: return "Vote out a Ghost"
        case .dusk:
            return meetings.contains(where: { $0.name == "Guess Word" && $0.amMember }) ? "Guess the word" : "Dusk"
        case .over: return ghostRealWord.map { "Word: \($0)" } ?? "Game over"
        case .other: return stateName
        }
    }

    var ghostNeedsMe: Bool {
        isMyGhostTurn
            || meetings.contains { ($0.name == "Guess Word" || $0.name == "Ghost") && $0.amMember && $0.canVote && !$0.playerHasVoted }
    }
}

private struct GhostAvatar: View {
    var session: GameSession
    var name: String
    var size: CGFloat = 20
    var body: some View {
        let p = session.ghostPlayer(named: name)
        UMAvatarView(userId: p?.userId, hasAvatar: p?.avatar ?? false, name: name, size: size,
                     square: p?.squareAvatar ?? false, deckPath: p?.deckAvatarPath)
    }
}

/// Pinned at the top of the game (inside the floating header): phase, whose turn, word length and
/// every clue so far. Collapsed it shows only the newest clue.
struct GhostHeaderPanel: View {
    var session: GameSession
    var glass = true
    /// Wide one-row header: a single line; the full list is in the Act pane next to it.
    var singleLine = false
    @AppStorage("um.ghostCluesExpanded") private var expanded = true

    var body: some View {
        let clues = session.ghostClues
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("👻").font(.caption)
                Text(session.stateName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                statusChip
                Spacer(minLength: 4)
                if let n = session.ghostWordLength {
                    Text("\(n) letters")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(UMTheme.muted)
                        .fixedSize()
                }
                if !singleLine { SpectatorCountChip(session: session, glass: false) }
                if !singleLine, !clues.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide clues" : "Show all clues")
                }
            }
            if !singleLine {
                if let word = session.ghostMyWord, expanded {
                    Text("Your word: \(Text(word).fontWeight(.bold).foregroundStyle(UMTheme.roleMention))")
                        .font(.caption)
                } else if session.ghostIAmGuessing, expanded, session.ghostRealWord == nil {
                    Text("You're a Ghost: guess the word")
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                }
                if clues.isEmpty {
                    if session.ghostStage != .pregame {
                        Text("No clues yet")
                            .font(.caption)
                            .foregroundStyle(UMTheme.muted)
                    }
                } else if expanded {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(clues) { clueRow($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(maxHeight: min(CGFloat(clues.count) * 22, 110))
                } else if let last = clues.last {
                    clueRow(last)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GhostPanelBackground(glass: glass))
        .accessibilityElement(children: .contain)
    }

    private var statusChip: some View {
        let mine = session.ghostNeedsMe
        return Text(session.ghostShortStatus)
            .font(.caption.weight(mine ? .bold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(mine ? .white : .primary)
            .background(mine ? UMTheme.blood : UMTheme.elevated.opacity(0.8), in: Capsule())
            .accessibilityLabel(session.ghostStatusText)
    }

    private func clueRow(_ c: GhostClue) -> some View {
        HStack(spacing: 6) {
            GhostAvatar(session: session, name: c.name, size: 16)
            Text("\(Text(c.name).fontWeight(.semibold))  \(c.text)")
                .font(.caption)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct GhostPanelBackground: ViewModifier {
    var glass: Bool
    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            content.background(UMTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Act tab: the full Ghost board above the actions (Give Clue / Guess Word / Ghost pick and the
/// Village vote render below it as normal meetings).
struct GhostBoard: View {
    var session: GameSession

    var body: some View {
        let clues = session.ghostClues
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ghost").font(.headline)
                Spacer()
                if let n = session.ghostWordLength {
                    Text("Word length \(n)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(UMTheme.elevated, in: Capsule())
                }
            }
            if let real = session.ghostRealWord {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Real word: \(Text(real).fontWeight(.bold).foregroundStyle(UMTheme.village))")
                    if let fake = session.ghostFakeWord {
                        Text("Fake word: \(Text(fake).fontWeight(.bold).foregroundStyle(UMTheme.mafia))")
                    }
                }
                .font(.subheadline)
            } else if let word = session.ghostMyWord {
                Text("Your word: \(Text(word).fontWeight(.bold).foregroundStyle(UMTheme.roleMention))")
                    .font(.subheadline)
            } else if session.ghostIAmGuessing {
                Text("You're a Ghost: work out the hidden word from the clues.")
                    .font(.subheadline).foregroundStyle(UMTheme.muted)
            }
            HStack(spacing: 8) {
                if let t = session.ghostTurn {
                    GhostAvatar(session: session, name: t.name, size: 26)
                }
                Text(session.ghostStatusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.ghostNeedsMe ? UMTheme.blood : .primary)
            }
            let waiting = session.ghostStillToGive
            if !waiting.isEmpty {
                Text("Up next: \(waiting.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(UMTheme.muted)
            }
            if clues.isEmpty {
                Text("No clues yet.").font(.caption).foregroundStyle(UMTheme.muted)
            } else {
                let rounds = groupedRounds(clues)
                ForEach(Array(rounds.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.round.map { "Round \($0)" } ?? "Earlier clues")
                            .font(.caption.weight(.bold)).foregroundStyle(UMTheme.muted)
                        ForEach(group.clues) { c in
                            HStack(alignment: .top, spacing: 8) {
                                GhostAvatar(session: session, name: c.name, size: 20)
                                Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(c.text).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(UMTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func groupedRounds(_ clues: [GhostClue]) -> [(round: Int?, clues: [GhostClue])] {
        var out: [(round: Int?, clues: [GhostClue])] = []
        for c in clues {
            if let last = out.last, last.round == c.round {
                out[out.count - 1].clues.append(c)
            } else {
                out.append((c.round, [c]))
            }
        }
        return out.reversed()
    }
}

/// Server `textOptions` for text-input meetings (web ActionText).
nonisolated struct UMTextOptions: Hashable {
    var minLength = 0
    var maxLength: Int?
    var alphaOnly = false
    var alphaOnlyWithSpaces = false
    var numericOnly = false
    var toLowerCase = false
    var submit: String?

    init() {}

    init(_ any: Any?) {
        guard let o = any as? [String: Any] else { return }
        func int(_ a: Any?) -> Int? {
            if let i = a as? Int { return i }
            if let d = a as? Double { return Int(d) }
            return nil
        }
        minLength = int(o["minLength"]) ?? 0
        maxLength = int(o["maxLength"])
        alphaOnly = (o["alphaOnly"] as? Bool) ?? false
        alphaOnlyWithSpaces = (o["alphaOnlyWithSpaces"] as? Bool) ?? false
        numericOnly = (o["numericOnly"] as? Bool) ?? false
        toLowerCase = (o["toLowerCase"] as? Bool) ?? false
        submit = o["submit"] as? String
    }

    func filter(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\n", with: " ")
        if numericOnly { s = s.filter(\.isNumber) }
        if alphaOnly { s = s.filter { $0.isASCII && $0.isLetter } }
        if alphaOnlyWithSpaces {
            s = s.filter { ($0.isASCII && $0.isLetter) || $0 == " " }
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        }
        if toLowerCase { s = s.lowercased() }
        if let maxLength, s.count > maxLength { s = String(s.prefix(maxLength)) }
        return s
    }

    func accepts(_ s: String) -> Bool { s.count >= max(1, minLength) }
}
