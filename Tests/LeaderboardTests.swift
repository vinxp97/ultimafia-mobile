// swiftc -parse-as-library Tests/LeaderboardTests.swift Ultimafia/Features/Leaderboard/Leaderboard.swift
import Foundation

@main
struct LeaderboardTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL:", what) }
    }
    static func equal<T: Equatable>(_ got: T, _ expected: T, _ what: String) {
        check(got == expected, "\(what) (got \(got), expected \(expected))")
    }

    static func main() {
        rating()
        tiers()
        tieRanking()
        prestige()
        expiry()
        phases()
        countdown()
        decode()
        if failures == 0 {
            print("LeaderboardTests passed: rating, tiers, tie ranking, prestige, expiry window, phases, countdown, decode")
        } else {
            print("LeaderboardTests: \(failures) failed")
            exit(1)
        }
    }

    static func rating() {
        equal(UMSkill.conservativeRank(mu: UMSkill.defaultMu, sigma: UMSkill.defaultSigma), 0, "default player sits at 0")
        equal(UMSkill.conservativeRank(mu: 28.1, sigma: 3.2226), 18.4322, "mu - 3 sigma rounded to 4 places")
        equal(UMSkill.conservativeRank(mu: 20, sigma: 8), -4, "can go negative")
    }

    static func tiers() {
        // 101 players 0...100: percentile == value.
        let ratings = (0...100).map(Double.init)
        let t = UMSkill.tiers(for: ratings)
        equal(t[100], .master, "100th percentile")
        equal(t[98], .master, "98 is Master")
        equal(t[97], .diamond, "97 is Diamond")
        equal(t[90], .diamond, "90 is Diamond")
        equal(t[75], .platinum, "75 is Platinum")
        equal(t[50], .gold, "50 is Gold")
        equal(t[20], .silver, "20 is Silver")
        equal(t[19], .bronze, "19 is Bronze")
        equal(UMSkill.tiers(for: [5]), [.master], "a lone player is 100th percentile")
        equal(UMSkill.tiers(for: []), [], "empty population")
        equal(UMSkill.Tier(serverName: "Diamond"), .diamond, "server tier names")
        equal(UMSkill.Tier(serverName: nil), .unrated, "missing tier is Unrated")
    }

    static func tieRanking() {
        equal(UMCompetitive.competitionRanks([100, 90, 90, 80]), [0, 1, 1, 3], "1224 ranking")
        equal(UMCompetitive.competitionRanks([80, 90, 100, 90]), [3, 1, 0, 1], "aligned with input order")
        equal(UMCompetitive.competitionRanks([50, 50, 50]), [0, 0, 0], "all tied share 1st")
        equal(UMCompetitive.competitionRanks([]), [], "empty")
        let a = UMCompetitor(id: "a", name: "Alice", avatar: false)
        let b = UMCompetitor(id: "b", name: "Bob", avatar: false)
        let c = UMCompetitor(id: "c", name: "Cat", avatar: false)
        let d = UMCompetitor(id: "d", name: "Dan", avatar: false)
        let rows = UMRoundDetail.standings(totals: [(d, 80, 2), (c, 90, 3), (a, 100, 4), (b, 90, 3)])
        equal(rows.map(\.player.id), ["a", "b", "c", "d"], "sorted by rank then name")
        equal(rows.map(\.ranking), [0, 1, 1, 3], "ties share rank, next rank skips")
        equal(rows.map(\.prestige), [20, 18, 18, 14], "tied players both get 2nd-place prestige")
    }

    static func prestige() {
        equal(UMCompetitive.prestige(forRanking: 0), 20, "1st")
        equal(UMCompetitive.prestige(forRanking: 9), 6, "10th")
        equal(UMCompetitive.prestige(forRanking: 14), 3, "15th")
        equal(UMCompetitive.prestige(forRanking: 15), 0, "16th gets nothing")
        equal(UMCompetitive.prestige(forRanking: -1), 0, "bad ranking")
        equal(UMCompetitive.prestigeTable.count, 15, "15 paid places")
    }

    static func expiry() {
        let refs = (1...12).map { UMRoundRef(season: 2, number: $0) } + (1...6).map { UMRoundRef(season: 3, number: $0) }
        let kept = UMCompetitive.detailedRounds(refs.shuffled())
        equal(kept, [UMRoundRef(season: 3, number: 4), UMRoundRef(season: 3, number: 5), UMRoundRef(season: 3, number: 6)],
              "last 3 started rounds keep score detail")
        // Early in a season the window reaches back into the previous one.
        let early = UMCompetitive.detailedRounds([UMRoundRef(season: 2, number: 11), UMRoundRef(season: 2, number: 12),
                                                  UMRoundRef(season: 3, number: 1)])
        check(early.contains(UMRoundRef(season: 2, number: 11)), "window crosses seasons")
        equal(UMCompetitive.detailedRounds([UMRoundRef(season: 1, number: 1)]).count, 1, "fewer rounds than the window")
        check(UMRoundRef(season: 2, number: 12) < UMRoundRef(season: 3, number: 1), "season orders before round")
    }

    static func phases() {
        func r(day: Int, ended: Bool, completed: Bool, accounted: Bool) -> UMRoundSummary {
            UMRoundSummary(ref: .init(season: 1, number: 1), startDate: "2026-11-01", dateCompleted: nil, currentDay: day,
                           remainingOpenDays: 0, openPhaseEnded: ended, completed: completed, accounted: accounted)
        }
        equal(r(day: 0, ended: false, completed: false, accounted: false).phase, .upcoming, "day 0 is upcoming")
        equal(r(day: 3, ended: false, completed: false, accounted: false).phase, .open, "open")
        equal(r(day: 6, ended: true, completed: false, accounted: false).phase, .grace, "hammer/open end -> grace")
        equal(r(day: 10, ended: true, completed: true, accounted: false).phase, .review, "review")
        equal(r(day: 13, ended: true, completed: true, accounted: true).phase, .final, "accounted")
        check(!r(day: 0, ended: false, completed: false, accounted: false).hasStarted, "upcoming hasn't started")
    }

    static func countdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        equal(UMCompetitive.countdown(to: now.addingTimeInterval(3 * 86_400 + 4 * 3600 + 12 * 60 + 9), now: now), "3d 04:12:09", "days")
        equal(UMCompetitive.countdown(to: now.addingTimeInterval(59), now: now), "00:00:59", "under a day")
        equal(UMCompetitive.countdown(to: now.addingTimeInterval(-5), now: now), "now", "past")
        equal(UMCompetitive.ordinal(1), "1st", "1st")
        equal(UMCompetitive.ordinal(2), "2nd", "2nd")
        equal(UMCompetitive.ordinal(3), "3rd", "3rd")
        equal(UMCompetitive.ordinal(11), "11th", "11th")
        equal(UMCompetitive.ordinal(22), "22nd", "22nd")
    }

    static func decode() {
        let json = """
        {"category":"skillRating","users":[{"userId":"abc123","username":"Alice","avatar":true,"vanityUrl":"alice",
        "rank":1,"trophies":[],"wins":200,"losses":150,"winRate":0.5714,"kudos":42,"karma":null,"fortune":12000,
        "prestige":86,"skillRating":18.4321,"skillMu":28.1,"skillSigma":3.2226,"skillTier":"Master","skillGamesPlayed":80}],
        "total":400,"page":1,"pages":16,"pageSize":25,"myRank":null}
        """
        do {
            let page = try JSONDecoder().decode(UMSkillPage.self, from: Data(json.utf8))
            equal(page.users.first?.tier, .master, "tier decoded")
            equal(page.users.first?.skillRating, 18.4321, "rating decoded")
            equal(page.pages, 16, "pages")
            check(page.myRank == nil, "guest has no myRank")
        } catch {
            check(false, "decode Hall of Fame page: \(error)")
        }
    }
}
