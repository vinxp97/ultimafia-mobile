import Foundation

/// Where the Leaderboard page gets its data. The page only talks to this protocol.
protocol UMLeaderboardService: AnyObject {
    /// True when the Skill board is sample data rather than the live Hall of Fame.
    var skillIsMock: Bool { get }
    /// True when the Competitive board is sample data (only after the live API failed).
    var competitiveIsMock: Bool { get }
    var meId: String? { get }

    /// `GET /api/hall-of-fame?category=skillRating&page=&pageSize=`
    func skillPage(page: Int, pageSize: Int) async throws -> UMSkillPage
    /// `GET /api/competitive/seasons`, newest season first.
    func seasons() async throws -> [UMSeasonSummary]
    /// `GET /api/competitive/roundInfo?seasonNumber=&roundNumber=`
    func round(_ ref: UMRoundRef) async throws -> UMRoundDetail
    /// `GET /api/competitive/season/:n` (accounted prestige only).
    func seasonStandings(_ season: Int) async throws -> [UMSeasonStanding]
}

/// Everything from `MockLeaderboardData`. Used by the DEBUG `-UMDiagLeaderboard` screenshots
/// and as the fallback when the live API fails.
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
}

/// Live site data for both boards. No login is needed for any of these reads. If the first
/// competitive read fails, the competitive board switches to sample data (and says so).
final class UMLiveLeaderboardService: UMLeaderboardService {
    private let mock = UMMockLeaderboardService()
    private(set) var skillIsMock = false
    private(set) var competitiveIsMock = false
    let meId: String?
    private var roundCache: [UMRoundRef: UMRoundDetail] = [:]
    private var seasonCache: [Int: [UMSeasonStanding]] = [:]

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

    func seasons() async throws -> [UMSeasonSummary] {
        do {
            let data = try await APIClient.shared.request("GET", path: "competitive/seasons", query: [:], body: nil)
            let list = UMCompetitiveParse.seasons(data)
            guard !list.isEmpty else { throw UMError.message("No seasons yet.") }
            competitiveIsMock = false
            return list
        } catch {
            competitiveIsMock = true
            return try await mock.seasons()
        }
    }

    func round(_ ref: UMRoundRef) async throws -> UMRoundDetail {
        if competitiveIsMock { return try await mock.round(ref) }
        if let hit = roundCache[ref] { return hit }
        let data = try await APIClient.shared.request("GET", path: "competitive/roundInfo", query: [
            "seasonNumber": String(ref.season), "roundNumber": String(ref.number),
        ], body: nil)
        guard let d = UMCompetitiveParse.roundInfo(data, now: Date()) else {
            throw UMError.message("Season \(ref.season) round \(ref.number) has no data.")
        }
        roundCache[ref] = d
        return d
    }

    func seasonStandings(_ season: Int) async throws -> [UMSeasonStanding] {
        if competitiveIsMock { return try await mock.seasonStandings(season) }
        if let hit = seasonCache[season] { return hit }
        let data = try await APIClient.shared.request("GET", path: "competitive/season/\(season)", query: [:], body: nil)
        let rows = UMCompetitiveParse.season(data)
        seasonCache[season] = rows
        return rows
    }
}
