import SwiftUI

struct NewspaperDeath: Identifiable, Hashable {
    var id: String
    /// In-game player id (for matching a later death reveal).
    var playerId: String? = nil
    var name: String
    var userId: String?
    var avatar: Bool
    var deathMessage: String
    var revealLine: String?
    var revealRoleRaw: String? = nil
    /// "[Mafia-Aligned]" and the like, shown after the role (not part of the role name).
    var revealSuffix: String? = nil
    var lastWill: String?
}

struct NewspaperPerson: Identifiable, Hashable {
    var id: String
    var name: String
    var userId: String?
    var avatar: Bool
}

struct NewspaperWin: Identifiable, Hashable {
    var id: String { group }
    var group: String
    var message: String
    var players: [NewspaperPerson]
}

struct NewspaperIssue: Identifiable, Hashable {
    var id: String
    var title: String
    var source: String
    var phaseId: Int
    var dayCount: Int
    var time: Date
    var deaths: [NewspaperDeath] = []
    var wins: [NewspaperWin] = []

    var isWin: Bool { !wins.isEmpty }
}

enum NewspaperDate {
    static let est: TimeZone = TimeZone(identifier: "America/New_York") ?? .current

    static func line(epoch: Date, epochDayCount: Int, dayCount: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = est
        let days = dayCount - epochDayCount
        let shifted = cal.date(byAdding: .day, value: days, to: epoch) ?? epoch
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        comps.year = (comps.year ?? 2026) - 100
        let shown = cal.date(from: comps) ?? shifted
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = est
        fmt.dateFormat = "EEE MMM d yyyy, HH:mm"
        return fmt.string(from: shown)
    }
}

enum NewspaperCopy {
    static func title(source: String) -> String {
        if source.hasPrefix("instant") { return "Breaking News" }
        switch source {
        case "Day": return "Evening News"
        case "Night": return "Obituaries"
        case "Postgame": return "The Miller Times"
        case "Winners": return "The Miller Times"
        default: return "Breaking News"
        }
    }

    static func winHeadline(_ group: String) -> String {
        if group.last == "s" { return "\(group) Win!" }
        return "\(group) Wins!"
    }

    static func reveal(from raw: String?, playerName: String) -> (line: String, roleRaw: String?, suffix: String?)? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let role = extract(text, marker: "'s role is ") {
            guard isExposed(role) else { return nil }
            let (body, suffix) = splitAlignedSuffix(role)
            let raw = normalizeRole(body)
            return ("\(playerName)'s role was: \(reformatRole(raw))\(suffix.map { " \($0)" } ?? "").", raw, suffix)
        }
        if let alignment = extract(text, marker: "'s alignment is ") {
            guard isExposed(alignment) else { return nil }
            return ("\(playerName)'s alignment was: \(prettyAlignment(alignment))", nil, nil)
        }
        return nil
    }

    /// From a `reveal` broadcast's role ("Cop:Insane", or an alignment in alignment-only setups).
    static func reveal(fromRole role: String, playerName: String) -> (line: String, roleRaw: String?, suffix: String?)? {
        let r = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isExposed(r) else { return nil }
        if alignments.contains(r) {
            return ("\(playerName)'s alignment was: \(prettyAlignment(r))", nil, nil)
        }
        let (body, suffix) = splitAlignedSuffix(r)
        let raw = normalizeRole(body)
        return ("\(playerName)'s role was: \(reformatRole(raw))\(suffix.map { " \($0)" } ?? "").", raw, suffix)
    }

    private static let alignments: Set<String> = ["Village", "Town", "Mafia", "Cult", "Independent", "Event",
                                                 "Resistance", "Spies", "Host", "Liberals", "Fascists", "Liars", "Army"]

    /// Mafia death reveals of a converted player read "Cop [Mafia-Aligned]".
    static func splitAlignedSuffix(_ role: String) -> (String, String?) {
        let t = role.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("]"), let open = t.lastIndex(of: "[") else { return (t, nil) }
        let body = t[..<open].trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return (t, nil) }
        return (body, String(t[open...]))
    }

    private static func extract(_ text: String, marker: String) -> String? {
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        var value = String(text[range.upperBound...])
        if value.hasSuffix(".") { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isExposed(_ value: String) -> Bool {
        let v = value.lowercased()
        if v.isEmpty { return false }
        // Only placeholders are hidden. A cleaned (Janitor) death never carries a reveal at all on
        // the server, so "Janitor" here is the victim's real role and must show.
        if v == "???" || v == "?" || v == "unknown" { return false }
        return true
    }

    /// Death reveals (incl. day condemnations) arrive as "Cop (Insane/Telepathic)"
    /// (Role.getRevealText); role chips/icons want the "Cop:Insane/Telepathic" form.
    static func normalizeRole(_ role: String) -> String {
        let t = role.trimmingCharacters(in: .whitespaces)
        guard !t.contains(":"), t.hasSuffix(")"), let open = t.lastIndex(of: "(") else { return t }
        let name = t[..<open].trimmingCharacters(in: .whitespaces)
        let mods = t[t.index(after: open)..<t.index(before: t.endIndex)].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return t }
        return mods.isEmpty ? name : "\(name):\(mods)"
    }

    static func reformatRole(_ role: String) -> String {
        let tokens = role.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let name = tokens.first ?? role
        let modifiers = tokens.count > 1 ? tokens[1].split(separator: "/").map(String.init) : []
        let prefix = modifiers.filter { !$0.isEmpty }.joined(separator: " ")
        if prefix.isEmpty { return name }
        return "\(prefix) \(name)"
    }

    static func prettyAlignment(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "Village", "Town": return "Village 💙"
        case "Mafia": return "Mafia 🔪"
        case "Cult": return "Cult 🦑"
        case "Independent": return "Independent ✨"
        case "Event": return "Event ⚡"
        case "Resistance": return "Resistance ✊"
        case "Spies": return "Spies 🕵️"
        case "Host": return "Host 🎤"
        case "Liberals": return "Liberals 🇺🇸"
        case "Fascists": return "Fascists 🛠️"
        case "Liars": return "Liars 🤥"
        case "Army": return "Army ⚔️"
        default: return key
        }
    }
}

private let paperInk = Color(red: 0.12, green: 0.09, blue: 0.06)
private let paperCream = Color(red: 0.93, green: 0.88, blue: 0.72)
private let paperRule = Color(red: 0.45, green: 0.18, blue: 0.14)

struct NewspaperCard: View {
    var issue: NewspaperIssue
    var session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(issue.title)
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(paperInk)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Text(session.newspaperDateLine(for: issue))
                .font(.system(.caption, design: .serif).italic())
                .foregroundStyle(paperInk.opacity(0.7))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Rectangle()
                .fill(paperRule)
                .frame(height: 2)

            if issue.isWin {
                ForEach(issue.wins) { win in
                    winEntry(win)
                    if win.id != issue.wins.last?.id {
                        Rectangle().fill(paperRule.opacity(0.35)).frame(height: 1)
                    }
                }
            } else if issue.deaths.isEmpty {
                Text(issue.source == "Day" ? "No one was condemned." : "No one died last night.")
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(paperInk)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
            } else {
                ForEach(issue.deaths) { death in
                    obituary(death)
                    if death.id != issue.deaths.last?.id {
                        Rectangle().fill(paperRule.opacity(0.35)).frame(height: 1)
                    }
                }
            }
        }
        .padding(14)
        .background(paperCream, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(paperInk.opacity(0.25), lineWidth: 1)
        )
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func obituary(_ death: NewspaperDeath) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(death.name)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(paperInk)
            HStack(alignment: .top, spacing: 10) {
                newspaperAvatar(death)
                if death.deathMessage.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    EmoteText(
                        text: death.deathMessage,
                        color: paperInk,
                        italic: false,
                        system: true,
                        emoteSize: 16,
                        players: session.players,
                        gameType: session.setupGameType,
                        otherRoles: session.guessableRoles.map(\.raw),
                        roleColor: .red
                    )
                }
            }
            if let roleRaw = death.revealRoleRaw, !roleRaw.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(death.name)'s role was:")
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(paperInk)
                    RoleMentionChip(
                        roleRaw: roleRaw,
                        displayName: NewspaperCopy.reformatRole(roleRaw),
                        gameType: session.setupGameType,
                        otherRoles: session.guessableRoles.map(\.raw)
                    )
                    if let suffix = death.revealSuffix {
                        Text(suffix)
                            .font(.system(.callout, design: .serif))
                            .foregroundStyle(paperInk)
                    }
                }
            } else if let reveal = death.revealLine {
                EmoteText(
                    text: reveal,
                    color: paperInk,
                    italic: false,
                    system: true,
                    emoteSize: 16,
                    players: session.players,
                    gameType: session.setupGameType,
                    otherRoles: session.guessableRoles.map(\.raw),
                        roleColor: .red
                )
            }
            if let will = death.lastWill, !will.isEmpty {
                EmoteText(
                    text: will,
                    color: paperInk.opacity(0.85),
                    italic: true,
                    system: true,
                    emoteSize: 16,
                    players: session.players,
                    gameType: session.setupGameType,
                    otherRoles: session.guessableRoles.map(\.raw),
                        roleColor: .red
                )
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func winEntry(_ win: NewspaperWin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NewspaperCopy.winHeadline(win.group))
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(paperInk)
            HStack(alignment: .top, spacing: 10) {
                if win.players.count <= 1 {
                    if let person = win.players.first {
                        mugshot(person, size: 72)
                    }
                    winMessage(win.message)
                } else {
                    winGrid(win.players)
                    winMessage(win.message)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func winMessage(_ text: String) -> some View {
        EmoteText(
            text: text,
            color: paperInk,
            italic: false,
            system: true,
            emoteSize: 16,
            players: session.players,
            gameType: session.setupGameType,
            otherRoles: session.guessableRoles.map(\.raw),
                        roleColor: .red
        )
    }

    private func winGrid(_ people: [NewspaperPerson]) -> some View {
        let size: CGFloat = people.count <= 4 ? 56 : 44
        let columns = [GridItem(.adaptive(minimum: size), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(people) { person in
                mugshot(person, size: size)
            }
        }
        .frame(maxWidth: people.count <= 4 ? 128 : 160)
    }

    @ViewBuilder
    private func newspaperAvatar(_ death: NewspaperDeath) -> some View {
        mugshot(
            NewspaperPerson(id: death.id, name: death.name, userId: death.userId, avatar: death.avatar),
            size: 72
        )
    }

    @ViewBuilder
    private func mugshot(_ person: NewspaperPerson, size: CGFloat) -> some View {
        Group {
            if person.avatar, let userId = person.userId, !userId.isEmpty, let url = UMAvatarURL.live(userId: userId) {
                AnimatedWebPView(url: url)
            } else {
                UMDefaultAvatarView(name: person.name)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(paperInk.opacity(0.3), lineWidth: 1))
    }
}

private struct RoleMentionChip: View {
    var roleRaw: String
    var displayName: String
    var gameType: String
    var otherRoles: [String]
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 3) {
                RoleIconView(role: roleRaw, gameType: gameType.isEmpty ? "Mafia" : gameType, size: 16)
                Text(displayName)
                    .font(.system(.callout, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.red)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            RoleDetailsSheet(
                roleRaw: roleRaw,
                gameType: gameType.isEmpty ? "Mafia" : gameType,
                otherRoles: otherRoles
            )
        }
    }
}
