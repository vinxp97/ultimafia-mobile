import Foundation

/// MOCK-UP DATA. Every name, rating, round and game here is generated sample data for the
/// Leaderboard mock-up; none of it comes from the site.
///
/// The per-round fortune series in particular has no real source yet: the server stores no
/// per-round fortune snapshot (CompetitiveSeasonStanding only keeps season prestige plus a running
/// fortune tiebreaker), and `/api/competitive/roundInfo` loses its standings once a round's games
/// expire after 30 days. Showing real fortune for old rounds needs a server change.
///
/// Deterministic (seeded), so screenshots and tests are stable.
final class MockLeaderboardData {
    static let shared = MockLeaderboardData(now: Date())

    /// The signed-in player in mock mode.
    static let meId = "u-vinman"

    let now: Date
    private(set) var skill: [UMSkillEntry] = []
    private(set) var seasons: [UMSeasonSummary] = []
    private(set) var details: [UMRoundRef: UMRoundDetail] = [:]
    /// Full standings even for expired rounds, so season totals add up.
    private var fullStandings: [UMRoundRef: [UMRoundStanding]] = [:]

    private static let names = [
        "Vinman", "Pranay", "nightcrawler", "QuietCop", "Lazarus", "hollowpoint", "Mira", "ghostlamp",
        "Tobias", "redherring", "Sable", "the_vig", "Juniper", "Oswin", "pocketwatch", "Kestrel",
        "Marlowe", "duskrunner", "Ivy", "bellhop", "Corvid", "Tamsin", "lanternjaw", "Rook",
    ]
    private static let setups = [
        "Guns n Hookers", "Classic 7", "Mountainous", "Cult Classic", "Bread & Circuses", "Town of Mafia",
    ]

    init(now: Date) {
        self.now = now
        buildSkill()
        buildCompetitive()
    }

    var me: UMCompetitor { players[0] }
    var myRank: Int? { skill.first { $0.userId == Self.meId }?.rank }

    private lazy var players: [UMCompetitor] = Self.names.enumerated().map { i, name in
        UMCompetitor(id: i == 0 ? Self.meId : "u-\(name.lowercased())", name: name, avatar: false)
    }

    // MARK: Skill

    private func buildSkill() {
        var rng = SplitMix64(seed: 0x5EED_1)
        var rows: [(UMCompetitor, mu: Double, sigma: Double, games: Int)] = []
        // Rated population: the named players plus filler handles so tiers spread out.
        let filler = (1...36).map { UMCompetitor(id: "u-player\($0)", name: "player\($0)", avatar: false) }
        for p in players + filler {
            let games = 25 + Int(rng.next() % 400)
            let sigma = max(1.2, 6.5 - Double(games) / 90 + rng.unit() * 0.8)
            let named = !p.id.hasPrefix("u-player")
            var mu = (named ? 25 : 19) + rng.unit() * (named ? 8 : 10)
            var sig = sigma
            if p.id == Self.meId { mu = 34.6; sig = 2.05 }
            if p.name == "Pranay" { mu = 36.2; sig = 2.1 }
            rows.append((p, mu, sig, games))
        }
        let ratings = rows.map { UMSkill.conservativeRank(mu: $0.mu, sigma: $0.sigma) }
        let tiers = UMSkill.tiers(for: ratings)
        var entries: [UMSkillEntry] = []
        for (i, r) in rows.enumerated() {
            let wins = Int(Double(r.games) * (0.38 + rng.unit() * 0.25))
            entries.append(UMSkillEntry(
                userId: r.0.id, username: r.0.name, avatar: false, vanityUrl: nil, rank: 0,
                skillRating: ratings[i], skillMu: (r.mu * 10_000).rounded() / 10_000,
                skillSigma: (r.sigma * 10_000).rounded() / 10_000, skillTier: tiers[i].rawValue,
                skillGamesPlayed: r.games, wins: wins, losses: r.games - wins,
                winRate: Double(wins) / Double(r.games), kudos: Int(rng.next() % 60),
                fortune: 2000 + Int(rng.next() % 30_000), prestige: Int(rng.next() % 120)))
        }
        // Server order: conservative rank desc, ranks dense 1..N.
        entries.sort { ($0.skillRating ?? 0, $1.username) > ($1.skillRating ?? 0, $0.username) }
        for i in entries.indices { entries[i].rank = i + 1 }
        skill = entries
    }

    // MARK: Competitive

    private static let day: TimeInterval = 86_400

    private static func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func buildCompetitive() {
        // Season 3: 12 rounds, round 6 open on day 4; round 5 in review; 1-4 final.
        // Season 2: finished. Rounds are 13 days apart (8 open + grace + 4 review).
        let currentStart = now.addingTimeInterval(-3 * Self.day - 3600 * 5)
        var all: [UMRoundSummary] = []
        var s3: [UMRoundSummary] = []
        for n in 1...12 {
            let start = currentStart.addingTimeInterval(Double(n - 6) * 9 * Self.day)
            let r: UMRoundSummary
            switch n {
            case ..<5:
                r = UMRoundSummary(ref: .init(season: 3, number: n), startDate: Self.ymd(start),
                                   dateCompleted: Self.ymd(start.addingTimeInterval(9 * Self.day)), currentDay: 13,
                                   remainingOpenDays: 0, openPhaseEnded: true, completed: true, accounted: true)
            case 5:
                r = UMRoundSummary(ref: .init(season: 3, number: n), startDate: Self.ymd(start),
                                   dateCompleted: Self.ymd(start.addingTimeInterval(9 * Self.day)), currentDay: 10,
                                   remainingOpenDays: 0, openPhaseEnded: true, completed: true, accounted: false)
            case 6:
                r = UMRoundSummary(ref: .init(season: 3, number: n), startDate: Self.ymd(start), dateCompleted: nil,
                                   currentDay: 4, remainingOpenDays: 4, openPhaseEnded: false, completed: false, accounted: false)
            default:
                r = UMRoundSummary(ref: .init(season: 3, number: n), startDate: Self.ymd(start), dateCompleted: nil,
                                   currentDay: 0, remainingOpenDays: 8, openPhaseEnded: false, completed: false, accounted: false)
            }
            s3.append(r)
        }
        var s2: [UMRoundSummary] = []
        let s2End = currentStart.addingTimeInterval(-5 * 9 * Self.day - 20 * Self.day)
        for n in 1...12 {
            let start = s2End.addingTimeInterval(Double(n - 12) * 9 * Self.day)
            s2.append(UMRoundSummary(ref: .init(season: 2, number: n), startDate: Self.ymd(start),
                                     dateCompleted: Self.ymd(start.addingTimeInterval(9 * Self.day)), currentDay: 13,
                                     remainingOpenDays: 0, openPhaseEnded: true, completed: true, accounted: true))
        }
        seasons = [
            UMSeasonSummary(number: 3, numRounds: 12, currentRound: 6, paused: false, completed: false, rounds: s3),
            UMSeasonSummary(number: 2, numRounds: 12, currentRound: 12, paused: false, completed: true, rounds: s2),
        ]
        all = s2 + s3
        let detailed = UMCompetitive.detailedRounds(all.filter(\.hasStarted).map(\.ref))
        var rng = SplitMix64(seed: 0xF0F7)
        for r in all where r.hasStarted {
            details[r.ref] = makeRound(r, detailed: detailed.contains(r.ref), rng: &rng)
        }
    }

    private func makeRound(_ r: UMRoundSummary, detailed: Bool, rng: inout SplitMix64) -> UMRoundDetail {
        let roundStart = Self.date(r.startDate) ?? now
        let days = r.phase == .open ? r.currentDay : 8
        let gameCount = r.phase == .open ? 9 : 16 + Int(rng.next() % 6)
        var games: [UMRoundGame] = []
        var totals: [String: Int] = [:]
        var played: [String: Int] = [:]
        // Every round is simulated game by game so totals add up; old rounds then drop the games,
        // which is what the real API does once the games expire.
        for g in 0..<gameCount {
            let size = 7 + Int(rng.next() % 6)
            var seated = players.shuffledSeeded(&rng).prefix(size).map(\.id)
            if g % 3 == 0, !seated.contains(Self.meId) { seated[0] = Self.meId }
            let villageWins = rng.unit() < 0.55
            let payout = 50 + Int(rng.next() % 21)
            var earned: [String: Int] = [:]
            for (i, id) in seated.enumerated() {
                let mafia = i < max(2, size / 4)
                let won = mafia != villageWins
                earned[id] = won ? payout + (mafia ? Int(rng.next() % 40) : 0) : 0
                totals[id, default: 0] += earned[id]!
                played[id, default: 0] += 1
            }
            let day = 1 + g * max(1, days) / gameCount
            let end = roundStart.addingTimeInterval(Double(day - 1) * Self.day + Double(g % 5) * 3600 + 7200)
            games.append(UMRoundGame(id: "g\(r.ref.season)-\(r.ref.number)-\(g)",
                                     setupName: Self.setups[Int(rng.next() % UInt64(Self.setups.count))],
                                     day: day, endTime: end, earned: earned))
        }
        // Make sure each round shows a shared rank: whoever is 3rd ties 2nd.
        let order = totals.sorted { $0.value > $1.value }
        if order.count > 2, let gi = games.lastIndex(where: { ($0.earned[order[2].key] ?? 0) > 0 }) {
            let bump = order[1].value - order[2].value
            games[gi].earned[order[2].key, default: 0] += bump
            totals[order[2].key, default: 0] += bump
        }
        let rows = players.compactMap { p -> (UMCompetitor, fortune: Int, games: Int)? in
            guard let g = played[p.id] else { return nil }
            return (p, totals[p.id] ?? 0, g)
        }
        let next: UMNextEvent? = switch r.phase {
        case .open: UMNextEvent(type: "complete", date: now.addingTimeInterval(4 * Self.day - 3600 * 7 - 1234))
        case .review: UMNextEvent(type: "account", date: now.addingTimeInterval(1 * Self.day + 3600 * 9 + 600))
        default: nil
        }
        let table = UMRoundDetail.standings(totals: rows)
        fullStandings[r.ref] = table
        // Like the real API: once games expire there is no trustworthy round table.
        return UMRoundDetail(season: r.ref.season, round: r,
                             standings: detailed ? table : [],
                             games: detailed ? games.sorted { $0.endTime > $1.endTime } : nil,
                             nextEvent: next)
    }

    private static func date(_ ymd: String) -> Date? {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)
    }

    // MARK: Reads

    func seasonStandings(_ season: Int) -> [UMSeasonStanding] {
        var prestige: [String: Int] = [:]
        var fortune: [String: Int] = [:]
        for (ref, d) in details where ref.season == season && d.round.accounted {
            for s in fullStandings[ref] ?? [] {
                prestige[s.player.id, default: 0] += s.prestige
                fortune[s.player.id, default: 0] += s.fortune
            }
        }
        let rows = players.filter { (prestige[$0.id] ?? 0) > 0 }
            .sorted { (prestige[$0.id]!, fortune[$0.id] ?? 0) > (prestige[$1.id]!, fortune[$1.id] ?? 0) }
        return rows.enumerated().map { i, p in
            UMSeasonStanding(player: p, ranking: i, prestige: prestige[p.id] ?? 0, tiebreakerFortune: fortune[p.id] ?? 0)
        }
    }
}

/// Small seeded generator so the mock is identical on every launch.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

extension Array {
    func shuffledSeeded(_ rng: inout SplitMix64) -> [Element] {
        var a = self
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            a.swapAt(i, j)
        }
        return a
    }
}
