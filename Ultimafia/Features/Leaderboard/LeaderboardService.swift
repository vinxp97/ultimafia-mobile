import Foundation

/// Where the Leaderboard page gets its data. The page only talks to this protocol, so the mock
/// competitive data can be swapped for the real endpoints without touching the views.
protocol UMLeaderboardService: AnyObject {
    /// True when the Skill board is sample data rather than the live Hall of Fame.
    var skillIsMock: Bool { get }
    /// True when the Competitive board is sample data. (Always, for the mock-up.)
    var competitiveIsMock: Bool { get }
    var meId: String? { get }

    /// `GET /api/hall-of-fame?category=skillRating&page=&pageSize=` (no login needed; `myRank`
    /// only with a session).
    func skillPage(page: Int, pageSize: Int) async throws -> UMSkillPage
    /// `GET /api/competitive/seasons`
    func seasons() async throws -> [UMSeasonSummary]
    /// `GET /api/competitive/roundInfo?seasonNumber=&roundNumber=`
    func round(_ ref: UMRoundRef) async throws -> UMRoundDetail
    /// `GET /api/competitive/season/:n`
    func seasonStandings(_ season: Int) async throws -> [UMSeasonStanding]
    /// One player's fortune / score per round in a season. No endpoint: the server keeps no
    /// per-round fortune snapshot, so this is mock-only until the server stores one.
    func history(playerId: String, season: Int) async throws -> [UMPlayerRoundPoint]
    func competitors(season: Int) async throws -> [UMCompetitor]
}

/// Everything from `MockLeaderboardData`. Used by the DEBUG `-UMDiagLeaderboard` screenshots.
final class UMMockLeaderboardService: UMLeaderboardService {
    let data: MockLeaderboardData
    init(data: MockLeaderboardData = .shared) { self.data = data }
    var skillIsMock: Bool { true }
    var competitiveIsMock: Bool { true }
    var meId: String? { MockLeaderboardData.meId }

    func skillPage(page: Int, pageSize: Int) async throws -> UMSkillPage {
        let start = max(0, (page - 1) * pageSize)
        let slice = Array(data.skill.dropFirst(start).prefix(pageSize))
        let pages = max(1, Int((Double(data.skill.count) / Double(pageSize)).rounded(.up)))
        return UMSkillPage(users: slice, total: data.skill.count, page: page, pages: pages,
                           pageSize: pageSize, myRank: data.myRank)
    }
    func seasons() async throws -> [UMSeasonSummary] { data.seasons }
    func round(_ ref: UMRoundRef) async throws -> UMRoundDetail {
        guard let d = data.details[ref] else { throw UMError.message("Round not found.") }
        return d
    }
    func seasonStandings(_ season: Int) async throws -> [UMSeasonStanding] { data.seasonStandings(season) }
    func history(playerId: String, season: Int) async throws -> [UMPlayerRoundPoint] {
        data.history(playerId: playerId, season: season)
    }
    func competitors(season: Int) async throws -> [UMCompetitor] { data.competitors(season: season) }
}

/// Skill board live from the Hall of Fame (public endpoint), falling back to the mock if the
/// request fails. Competitive stays on the mock for now.
///
/// To wire competitive later: decode `/api/competitive/seasons` into `UMSeasonSummary`
/// (`openPhaseEndedAt != nil` -> `openPhaseEnded`), `/roundInfo` into `UMRoundDetail`
/// (`standings[].ranking` is 0-based, `points` is round fortune; `gameCompletions` become
/// `games`, and an empty list on an old round means the games expired), and `/season/:n` into
/// `UMSeasonStanding` (`points` there is prestige, `tiebreakerPoints` is cumulative fortune).
final class UMLiveLeaderboardService: UMLeaderboardService {
    private let mock = UMMockLeaderboardService()
    private(set) var skillIsMock = false
    let meId: String?
    var competitiveIsMock: Bool { true }

    init(meId: String?) { self.meId = meId }

    func skillPage(page: Int, pageSize: Int) async throws -> UMSkillPage {
        do {
            let result: UMSkillPage = try await APIClient.shared.get("hall-of-fame", query: [
                "category": "skillRating", "page": String(page), "pageSize": String(min(100, pageSize)),
                "sortBy": "skillRating", "sortDirection": "desc",
            ])
            skillIsMock = false
            return result
        } catch {
            skillIsMock = true
            return try await mock.skillPage(page: page, pageSize: pageSize)
        }
    }
    func seasons() async throws -> [UMSeasonSummary] { try await mock.seasons() }
    func round(_ ref: UMRoundRef) async throws -> UMRoundDetail { try await mock.round(ref) }
    func seasonStandings(_ season: Int) async throws -> [UMSeasonStanding] { try await mock.seasonStandings(season) }
    func history(playerId: String, season: Int) async throws -> [UMPlayerRoundPoint] {
        try await mock.history(playerId: playerId, season: season)
    }
    func competitors(season: Int) async throws -> [UMCompetitor] { try await mock.competitors(season: season) }
}
