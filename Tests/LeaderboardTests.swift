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
        podium()
        expiredFallback()
        provisional()
        parseSeasons()
        parseRoundInfo()
        parseSeason()
        if failures == 0 {
            print("LeaderboardTests passed: rating, tiers, tie ranking, prestige, expiry window, phases, countdown, decode, podium, expired fallback, provisional season, seasons/roundInfo/season parsing")
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

    static func p(_ id: String) -> UMCompetitor { UMCompetitor(id: id, name: id.uppercased(), avatar: false) }

    static func podium() {
        let rows = UMRoundDetail.standings(totals: [(p("a"), 100, 1), (p("b"), 90, 1), (p("c"), 90, 1), (p("d"), 80, 1)])
        let pod = UMCompetitive.podium(rows)
        equal(pod.map(\.ranking), [0, 1], "1, 2, 2, 4: no 3rd step")
        equal(pod[1].entries.map(\.player.id), ["b", "c"], "tied 2nd shares a step")
        let three = UMRoundDetail.standings(totals: [(p("a"), 100, 1), (p("b"), 100, 1), (p("c"), 100, 1), (p("d"), 50, 1)])
        equal(UMCompetitive.podium(three).count, 1, "three-way tie for 1st")
        equal(UMCompetitive.podium(three)[0].entries.count, 3, "all three on the top step")
        let plain = UMRoundDetail.standings(totals: [(p("a"), 3, 1), (p("b"), 2, 1), (p("c"), 1, 1), (p("d"), 0, 1)])
        equal(UMCompetitive.podium(plain).map(\.ranking), [0, 1, 2], "distinct 1st 2nd 3rd")
        equal(UMCompetitive.podium([UMRoundStanding]()).count, 0, "empty round")
    }

    static func expiredFallback() {
        let now = UMCompetitiveParse.day("2026-11-14")!
        check(UMCompetitive.roundDetailExpired(completions: 0, dateCompleted: "2026-11-12", now: now), "no completions -> season order")
        check(!UMCompetitive.roundDetailExpired(completions: 112, dateCompleted: "2026-11-12", now: now), "recent round keeps detail")
        check(UMCompetitive.roundDetailExpired(completions: 1, dateCompleted: "2026-01-25", now: now), "a few archived games left: still expired")
        check(!UMCompetitive.roundDetailExpired(completions: 5, dateCompleted: nil, now: now), "open round")
    }

    static func provisional() {
        let base = [UMSeasonStanding(player: p("a"), ranking: 0, prestige: 20, tiebreakerFortune: 500),
                    UMSeasonStanding(player: p("b"), ranking: 1, prestige: 18, tiebreakerFortune: 400)]
        let pending = UMRoundDetail.standings(totals: [(p("b"), 300, 3), (p("c"), 200, 2), (p("a"), 100, 1)])
        let rows = UMCompetitive.provisionalSeason(base: base, pending: [pending])
        equal(rows.map(\.player.id), ["b", "a", "c"], "b 18+20, a 20+16, c 18")
        equal(rows.map(\.prestige), [38, 36, 18], "projected prestige added")
        equal(rows.map(\.tiebreakerFortune), [700, 600, 200], "round fortune added to tiebreaker")
        equal(rows.map(\.ranking), [0, 1, 2], "index ranking")
        let fresh = UMCompetitive.provisionalSeason(base: [], pending: [pending])
        equal(fresh.first?.player.id, "b", "season with nothing accounted yet uses the pending round")
        equal(UMCompetitive.provisionalSeason(base: base, pending: []).map(\.player.id), ["a", "b"], "nothing pending")
    }

    static func parseSeasons() {
        let json = """
        [{"number":3,"setupOrder":[[0,1],[2,3]],"currentRound":2,"startDate":"2026-10-01","paused":false,"completed":false,"numRounds":12,
          "rounds":[{"season":3,"number":2,"currentDay":3,"completed":false,"accounted":false,"startDate":"2026-10-15","dateCompleted":null,
                     "remainingOpenDays":5,"remainingReviewDays":4,"openPhaseEndedAt":null},
                    {"season":3,"number":1,"currentDay":13,"completed":true,"accounted":true,"startDate":"2026-10-01","dateCompleted":"2026-10-10",
                     "remainingOpenDays":0,"remainingReviewDays":0,"openPhaseEndedAt":1770580800000}]},
         {"number":11,"currentRound":1,"startDate":"2026-11-04","paused":false,"completed":false,"numRounds":1,
          "rounds":[{"season":11,"number":1,"currentDay":12,"completed":true,"accounted":false,"startDate":"2026-11-04",
                     "remainingOpenDays":0,"remainingReviewDays":0,"openPhaseEndedAt":1794355310041,"dateCompleted":"2026-11-12"}]}]
        """
        let list = UMCompetitiveParse.seasons(Data(json.utf8))
        equal(list.map(\.number), [11, 3], "newest season first")
        equal(list[1].rounds.map(\.ref.number), [1, 2], "rounds in order")
        equal(list[1].rounds[0].phase, .final, "accounted round is final")
        equal(list[1].rounds[1].phase, .open, "open round")
        equal(list[0].rounds[0].phase, .review, "season 11 round 1 awaiting results")
        equal(list[0].numRounds, 1, "round count from the API")
    }

    static func parseRoundInfo() {
        let json = """
        {"seasonNumber":3,"seasonPaused":false,
         "round":{"season":3,"number":2,"currentDay":3,"completed":false,"accounted":false,"startDate":"2026-10-15","dateCompleted":null,
                  "remainingOpenDays":5,"remainingReviewDays":4,"openPhaseEndedAt":null},
         "allowedSetups":[{"id":"setupShortId","name":"Example Setup","roles":["..."]}],
         "setupPlayCounts":{"setupShortId":4},
         "gameCompletions":[{"game":{"id":"gameShortId","status":"Finished","setup":{"id":"setupShortId","name":"Example Setup"},
                             "endTime":1771000000000,"ranked":false,"competitive":true},"day":3,"valid":true,
                             "pointsEarnedByPlayers":[{"userId":"abc123","points":50},{"userId":"def456","points":0}]}],
         "standings":[{"userId":"abc123","ranking":0,"points":240},{"userId":"def456","ranking":1,"points":180}],
         "users":{"abc123":{"points":240,"gamesPlayed":5,"user":{"id":"abc123","name":"Alice","avatar":true,"points":"12000","vanityUrl":"alice"}},
                  "def456":{"points":180,"gamesPlayed":4,"user":{"id":"def456","name":"Bob","avatar":false}}},
         "nextEvent":{"type":"complete","date":"2026-10-23T00:00:00.000Z"}}
        """
        let now = UMCompetitiveParse.day("2026-10-18")!
        guard let d = UMCompetitiveParse.roundInfo(Data(json.utf8), now: now) else { return check(false, "roundInfo parses") }
        equal(d.season, 3, "season")
        equal(d.round.ref.number, 2, "round")
        equal(d.standings.map(\.player.name), ["Alice", "Bob"], "names from users map")
        equal(d.standings.map(\.fortune), [240, 180], "standings points are round fortune")
        equal(d.standings.first?.gamesPlayed, 5, "games played")
        equal(d.standings.first?.player.profileKey, "alice", "vanity url for profile")
        equal(d.games?.first?.setupName, "Example Setup", "setup name")
        equal(d.games?.first?.earned["abc123"], 50, "per-game score")
        equal(d.nextEvent?.type, "complete", "next event type")
        check(d.nextEvent?.date == ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z"), "next event date")
        let empty = json.replacingOccurrences(of: #""gameCompletions":[{"game""#, with: #""gameCompletionsX":[{"game""#)
        let expired = UMCompetitiveParse.roundInfo(Data(empty.utf8), now: now)
        check(expired?.detailExpired == true, "no completions -> expired")
        equal(expired?.standings.count, 0, "expired round drops its partial table")
        check(UMCompetitiveParse.roundInfo(Data(#"{"seasonNumber":null,"round":null,"standings":[]}"#.utf8), now: now) == nil, "offseason")
    }

    static func parseSeason() {
        let json = """
        {"setups":[{"id":"setupShortId","name":"Example Setup"}],"setupOrder":[[0,1],[1,0]],
         "standings":[{"userId":"abc123","points":20,"tiebreakerPoints":240,"ranking":0},
                      {"userId":"xyz","points":18,"tiebreakerPoints":5364.6,"ranking":1}],
         "users":{"abc123":{"points":20,"tiebreakerPoints":240,"user":{"id":"abc123","name":"Alice","avatar":true}}}}
        """
        let rows = UMCompetitiveParse.season(Data(json.utf8))
        equal(rows.map(\.prestige), [20, 18], "points is prestige")
        equal(rows.map(\.tiebreakerFortune), [240, 5365], "tiebreaker fortune, floats rounded")
        equal(rows[0].player.name, "Alice", "name")
        equal(rows[1].player.name, "Unknown", "missing user entry")
    }
}
