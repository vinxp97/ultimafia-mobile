import Foundation

/// Post-game kudos vote: socket payload, eligibility, and dock collapse rules.
/// Voting is socket-only (`kudosVote` / `kudos`). There are no public tallies.
///
/// Row keys are alignment keys (`"Village"`, `"Mafia"`, `"Cult"`, `"Independent"`),
/// never the UI label `"Town"`. Targets are game player ids, or `"*"` for No one.

enum KudosTarget {
    static let noOne = "*"
}

struct KudosRow: Equatable, Sendable {
    var key: String
    var label: String
    var candidates: [String]
}

struct KudosState: Equatable, Sendable {
    var rows: [KudosRow] = []
    var myVotes: [String: String] = [:]
    var awarded: [String: [String]] = [:]
    var canVote: Bool = false
    var finalized: Bool = false
    var testMode: Bool = false

    static func parse(_ data: Any?) -> KudosState? {
        guard let obj = data as? [String: Any] else { return nil }
        var rows: [KudosRow] = []
        for raw in obj["rows"] as? [Any] ?? [] {
            guard let r = raw as? [String: Any] else { continue }
            guard let key = Self.string(r["key"]), !key.isEmpty else { continue }
            let label = Self.string(r["label"]).flatMap { $0.isEmpty ? nil : $0 } ?? key
            rows.append(KudosRow(key: key, label: label, candidates: Self.stringList(r["candidates"])))
        }
        var myVotes: [String: String] = [:]
        if let votes = obj["myVotes"] as? [String: Any] {
            for (key, value) in votes {
                if let s = Self.string(value) { myVotes[key] = s }
            }
        }
        var awarded: [String: [String]] = [:]
        if let map = obj["awarded"] as? [String: Any] {
            for (key, value) in map {
                awarded[key] = Self.stringList(value)
            }
        }
        return KudosState(
            rows: rows,
            myVotes: myVotes,
            awarded: awarded,
            canVote: Self.bool(obj["canVote"]),
            finalized: Self.bool(obj["finalized"]),
            testMode: Self.bool(obj["testMode"])
        )
    }

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func stringList(_ any: Any?) -> [String] {
        if let arr = any as? [Any] { return arr.compactMap(string) }
        if let s = string(any) { return [s] }
        return []
    }

    private static func bool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String { return s == "true" || s == "1" }
        return false
    }
}

enum KudosRowPhase: String, Equatable, Sendable {
    case open
    case confirm
}

enum KudosVoteRejection: String, Equatable, Sendable {
    case votingOver = "Kudos voting is over."
    case cannotVote = "You can't vote for kudos."
    case unknownRow = "Unknown kudos row."
    case invalidTarget = "Invalid kudos target."
    case selfVote = "You Cannot Kudo Yourself!"
    case alreadyLocked = "Your kudos vote for this row is locked."
}

enum KudosPolicy {
    static let confirmMilliseconds = 900
    static let collapseMilliseconds = 350
    static let bigTeamCount = 4
    static let noOne = KudosTarget.noOne

    /// Accent and alignment colors, as `#RRGGBB` (site Kudos.jsx).
    static let accentHex = "#FF8C00"
    static func rowColorHex(_ key: String) -> String {
        switch key {
        case "Village": return "#66ADFF"
        case "Mafia": return "#E45B5B"
        case "Cult": return "#B161D3"
        case "Independent": return "#C7CE48"
        default: return "#D3D3D3"
        }
    }

    /// Client-side checks matching `KudosVote.castVote`. The server still decides.
    static func rejection(state: KudosState, selfId: String?, row: String, target: String) -> KudosVoteRejection? {
        if state.finalized { return .votingOver }
        if !state.canVote { return .cannotVote }
        guard let lineup = state.rows.first(where: { $0.key == row }) else { return .unknownRow }
        if target != noOne, !lineup.candidates.contains(target) { return .invalidTarget }
        if let selfId, !selfId.isEmpty, target == selfId { return .selfVote }
        if state.myVotes[row] != nil { return .alreadyLocked }
        return nil
    }

    /// Payload for socket `kudosVote`. `row` is the row key (`"Village"`), never `"Town"`.
    static func votePayload(row: String, target: String) -> [String: String] {
        ["row": row, "target": target]
    }

    /// Dock is only for a voter, while voting is open, and there is at least one row.
    /// Locked rows stay as compact summaries, so the dock remains until voting ends.
    static func showsDock(state: KudosState?) -> Bool {
        guard let state, state.canVote, !state.finalized, !state.rows.isEmpty else { return false }
        return true
    }

    /// Freshly locked rows (in `myVotes` but not yet seen) enter the confirm animation.
    static func newlyLockedRows(seen: Set<String>, myVotes: [String: String]) -> [String] {
        myVotes.keys.filter { !seen.contains($0) }.sorted()
    }

    /// Awarded player ids, in row order, de-duplicated. Used by the Actions panel.
    static func awardedIds(_ state: KudosState) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for row in state.rows {
            for id in state.awarded[row.key] ?? [] where !id.isEmpty && id != noOne {
                if seen.insert(id).inserted { ids.append(id) }
            }
        }
        // Awards whose row is missing from `rows` still count.
        for (key, list) in state.awarded where !state.rows.contains(where: { $0.key == key }) {
            for id in list where !id.isEmpty && id != noOne {
                if seen.insert(id).inserted { ids.append(id) }
            }
        }
        return ids
    }

    static func isAwarded(_ state: KudosState, playerId: String) -> Bool {
        state.awarded.contains { _, ids in ids.contains(playerId) }
    }

    static func awardedIdsInRow(_ state: KudosState, key: String) -> [String] {
        (state.awarded[key] ?? []).filter { $0 != noOne && !$0.isEmpty }
    }

    static func isTileClickable(state: KudosState, rowKey: String, target: String, selfId: String?) -> Bool {
        rejection(state: state, selfId: selfId, row: rowKey, target: target) == nil
    }

    static func isTileDimmed(state: KudosState, rowKey: String, target: String, selfId: String?) -> Bool {
        if let selfId, target == selfId { return false }
        guard let vote = state.myVotes[rowKey] else { return false }
        return vote != target
    }

    static func isSelf(_ target: String, selfId: String?) -> Bool {
        guard let selfId, !selfId.isEmpty else { return false }
        return target == selfId
    }

    /// Natural width of a lineup group, matching site `kudosGroupWidth`.
    static func groupWidth(candidateCount: Int, compact: Bool) -> Double {
        let tile = compact ? 92.0 : 108.0
        let gap = compact ? 6.0 : 8.0
        let pad = 16.0
        let n = Double(max(0, candidateCount))
        return n * tile + max(0, n - 1) * gap + pad
    }

    static func takesFullLine(candidateCount: Int) -> Bool {
        candidateCount >= bigTeamCount
    }

    /// Packs alignment rows into visual lines.
    ///
    /// - `onePerLine`: compact (phone / folded) layouts put each alignment on its own line.
    /// - On wide layouts, a team of 4+ takes a full line; smaller teams share a line when
    ///   their natural widths plus gaps fit in `containerWidth`.
    /// - A non-positive width falls back to one row per line.
    static func visualLines(
        rows: [KudosRow],
        containerWidth: Double,
        onePerLine: Bool,
        compactTiles: Bool = false
    ) -> [[String]] {
        if onePerLine || containerWidth <= 0 {
            return rows.map { [$0.key] }
        }
        let gap = compactTiles ? 6.0 : 8.0
        var lines: [[String]] = []
        var current: [String] = []
        var used: Double = 0
        for row in rows {
            let count = row.candidates.count
            let natural = groupWidth(candidateCount: count, compact: compactTiles)
            let full = takesFullLine(candidateCount: count) || natural >= containerWidth
            if full {
                if !current.isEmpty {
                    lines.append(current)
                    current = []
                    used = 0
                }
                lines.append([row.key])
                continue
            }
            let extra = current.isEmpty ? natural : natural + gap
            if !current.isEmpty, used + extra > containerWidth {
                lines.append(current)
                current = []
                used = 0
            }
            current.append(row.key)
            used += current.count == 1 ? natural : natural + gap
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// A locked row collapses to a one-line summary only once every row on its visual
    /// line has a vote, and once any confirm animation on that line has finished.
    /// Unvoted rows, and a voted row that still shares a line with an outstanding vote,
    /// stay expanded.
    static func isCollapsed(
        key: String,
        myVotes: [String: String],
        lines: [[String]],
        confirming: Set<String> = []
    ) -> Bool {
        guard myVotes[key] != nil else { return false }
        guard let line = lines.first(where: { $0.contains(key) }) else {
            return !confirming.contains(key)
        }
        if line.contains(where: { confirming.contains($0) }) { return false }
        return line.allSatisfy { myVotes[$0] != nil }
    }

    /// Label for a locked vote: `"No one"` for `*`, otherwise the player's name.
    static func voteSummary(target: String, playerName: String?) -> String {
        if target == noOne { return "No one" }
        let name = (playerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Someone" : name
    }
}
