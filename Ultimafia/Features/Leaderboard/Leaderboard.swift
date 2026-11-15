import Foundation

// Leaderboard models and rules. Pure Foundation so the offline tests compile it on its own:
// swiftc -parse-as-library Tests/LeaderboardTests.swift Ultimafia/Features/Leaderboard/Leaderboard.swift
//
// Two boards share the page, following the site's Fame section:
// - Skill (`GET /api/hall-of-fame?category=skillRating`): one global rating per player, shown as
//   the conservative rank `mu - 3*sigma`, tiered by percentile of the rated population.
// - Competitive (`/api/competitive/seasons`, `/roundInfo`, `/season/:n`): fortune earned per round
//   (sum of valid game completions), competition-ranked, paid out as prestige from a fixed table.

// MARK: - Skill

enum UMSkill {
    static let defaultMu = 25.0
    static let defaultSigma = 25.0 / 3.0
    /// A player is listed only after this many rated (ranked or competitive) games.
    static let minRatedGames = 25

    /// The displayed rating: `mu - 3*sigma`, rounded to 4 places like the server.
    static func conservativeRank(mu: Double, sigma: Double) -> Double {
        ((mu - 3 * sigma) * 10_000).rounded() / 10_000
    }

    enum Tier: String, CaseIterable, Sendable {
        case master = "Master", diamond = "Diamond", platinum = "Platinum"
        case gold = "Gold", silver = "Silver", bronze = "Bronze", unrated = "Unrated"

        init(serverName: String?) {
            self = Tier(rawValue: serverName ?? "") ?? .unrated
        }
    }

    /// Server cutoffs: >= 98 Master, >= 90 Diamond, >= 75 Platinum, >= 50 Gold, >= 20 Silver.
    static func tier(percentile p: Double) -> Tier {
        if p >= 98 { return .master }
        if p >= 90 { return .diamond }
        if p >= 75 { return .platinum }
        if p >= 50 { return .gold }
        if p >= 20 { return .silver }
        return .bronze
    }

    /// Percentile of each rating within the population: sort ascending, `index / (n - 1) * 100`
    /// (100 when there is one player). Equal ratings take the first index, as `indexOf` does.
    static func tiers(for ratings: [Double]) -> [Tier] {
        guard !ratings.isEmpty else { return [] }
        let sorted = ratings.sorted()
        let n = sorted.count
        return ratings.map { r in
            if n == 1 { return tier(percentile: 100) }
            let index = sorted.firstIndex(of: r) ?? 0
            return tier(percentile: Double(index) / Double(n - 1) * 100)
        }
    }
}

struct UMSkillEntry: Identifiable, Hashable, Sendable, Decodable {
    var userId: String
    var username: String
    var avatar: Bool?
    var vanityUrl: String?
    var rank: Int
    var skillRating: Double?
    var skillMu: Double?
    var skillSigma: Double?
    var skillTier: String?
    var skillGamesPlayed: Int?
    var wins: Int?
    var losses: Int?
    var winRate: Double?
    var kudos: Int?
    var fortune: Int?
    var prestige: Int?

    var id: String { userId }
    var tier: UMSkill.Tier { UMSkill.Tier(serverName: skillTier) }
}

struct UMSkillPage: Sendable, Decodable {
    var users: [UMSkillEntry]
    var total: Int?
    var page: Int?
    var pages: Int?
    var pageSize: Int?
    /// Only filled when the request carries a session.
    var myRank: Int?
}

// MARK: - Competitive

enum UMCompetitive {
    /// Prestige by 0-based ranking (v2 table). 16th place and below earn nothing.
    static let prestigeTable = [20, 18, 16, 14, 12, 10, 9, 8, 7, 6, 3, 3, 3, 3, 3]
    /// The open phase ends early once anyone's round fortune reaches this.
    static let fortuneHammer = 1500
    static let openDaysPerRound = 8
    /// How many of the most recent rounds still have per-game detail. The server deletes games
    /// after 30 days (not a round count); 30 days is about the last two to three rounds, and the
    /// round API drops completions whose game is gone. The page keeps the last three.
    static let detailedRoundWindow = 3

    static func prestige(forRanking ranking: Int) -> Int {
        ranking >= 0 && ranking < prestigeTable.count ? prestigeTable[ranking] : 0
    }

    /// Competition ("1224") ranking, 0-based, aligned with the input order. Equal totals share
    /// the best index of that total in the descending list.
    static func competitionRanks(_ totals: [Int]) -> [Int] {
        let sorted = totals.sorted(by: >)
        var firstIndex: [Int: Int] = [:]
        for (i, t) in sorted.enumerated() where firstIndex[t] == nil { firstIndex[t] = i }
        return totals.map { firstIndex[$0] ?? 0 }
    }

    /// The rounds (across seasons) that still show per-game score detail: the newest
    /// `detailedRoundWindow` rounds that have started.
    static func detailedRounds(_ rounds: [UMRoundRef], window: Int = detailedRoundWindow) -> Set<UMRoundRef> {
        Set(rounds.sorted().suffix(window))
    }

    /// "3d 04:12:09", "04:12:09" under a day, "now" once passed.
    static func countdown(to date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        guard s > 0 else { return "now" }
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60, sec = s % 60
        let clock = String(format: "%02d:%02d:%02d", h, m, sec)
        return d > 0 ? "\(d)d \(clock)" : clock
    }

    /// "1st", "2nd", "3rd", "11th", "22nd".
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

struct UMRoundRef: Hashable, Comparable, Sendable {
    var season: Int
    var number: Int
    static func < (a: UMRoundRef, b: UMRoundRef) -> Bool {
        (a.season, a.number) < (b.season, b.number)
    }
}

enum UMRoundPhase: String, Sendable {
    case upcoming, open, grace, review, final

    var label: String {
        switch self {
        case .upcoming: "Upcoming"
        case .open: "Open"
        case .grace: "Grace period"
        case .review: "In review"
        case .final: "Final"
        }
    }
}

struct UMNextEvent: Hashable, Sendable {
    /// `start`, `complete` (open phase ends), `graceEnd`, `account` (prestige paid).
    var type: String
    var date: Date

    var label: String {
        switch type {
        case "start": "Starts in"
        case "complete": "Open phase ends in"
        case "graceEnd": "Grace ends in"
        case "account": "Prestige paid in"
        default: "Next event in"
        }
    }
}

struct UMRoundSummary: Identifiable, Hashable, Sendable {
    var ref: UMRoundRef
    var startDate: String
    var dateCompleted: String?
    var currentDay: Int
    var remainingOpenDays: Int
    var openPhaseEnded: Bool
    var completed: Bool
    var accounted: Bool

    var id: UMRoundRef { ref }

    /// Same classification as the lobby's CompetitiveRounds widget.
    var phase: UMRoundPhase {
        if accounted { return .final }
        if completed { return .review }
        if currentDay == 0 { return .upcoming }
        return openPhaseEnded ? .grace : .open
    }

    var hasStarted: Bool { phase != .upcoming }
}

struct UMSeasonSummary: Identifiable, Hashable, Sendable {
    var number: Int
    var numRounds: Int
    var currentRound: Int
    var paused: Bool
    var completed: Bool
    var rounds: [UMRoundSummary]
    var id: Int { number }
}

struct UMCompetitor: Hashable, Sendable {
    var id: String
    var name: String
    var avatar: Bool
}

/// One row of a round's standings. `fortune` is the round total; `ranking` is 0-based.
struct UMRoundStanding: Identifiable, Hashable, Sendable {
    var player: UMCompetitor
    var ranking: Int
    var fortune: Int
    var gamesPlayed: Int
    var id: String { player.id }
    var prestige: Int { UMCompetitive.prestige(forRanking: ranking) }
}

/// One finished game in a round and what each player earned from it.
struct UMRoundGame: Identifiable, Hashable, Sendable {
    var id: String
    var setupName: String
    var day: Int
    var endTime: Date
    var earned: [String: Int]
}

struct UMRoundDetail: Sendable {
    var season: Int
    var round: UMRoundSummary
    var standings: [UMRoundStanding]
    /// Per-game score detail; nil once the round's games have expired.
    var games: [UMRoundGame]?
    var nextEvent: UMNextEvent?

    var detailExpired: Bool { games == nil }

    /// Builds standings from per-player totals with competition ranking (ties share a rank).
    static func standings(totals: [(UMCompetitor, fortune: Int, games: Int)]) -> [UMRoundStanding] {
        let ranks = UMCompetitive.competitionRanks(totals.map(\.fortune))
        return zip(totals, ranks)
            .map { UMRoundStanding(player: $0.0.0, ranking: $0.1, fortune: $0.0.fortune, gamesPlayed: $0.0.games) }
            .sorted { ($0.ranking, $0.player.name.lowercased()) < ($1.ranking, $1.player.name.lowercased()) }
    }
}

/// Season prestige standings (`/api/competitive/season/:n`): prestige, then cumulative fortune.
struct UMSeasonStanding: Identifiable, Hashable, Sendable {
    var player: UMCompetitor
    var ranking: Int
    var prestige: Int
    var tiebreakerFortune: Int
    var id: String { player.id }
}

/// One player's history across a season's rounds, for the chart.
struct UMPlayerRoundPoint: Identifiable, Hashable, Sendable {
    var round: Int
    /// Final fortune that round. The server keeps no per-round snapshot; see MockLeaderboardData.
    var fortune: Int
    /// 0-based finish, or nil if they didn't play.
    var ranking: Int?
    var prestige: Int
    /// Sum of per-game scores, only while the round's games still exist.
    var score: Int?
    var games: Int?
    var id: Int { round }
}
