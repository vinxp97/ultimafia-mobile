import SwiftUI

/// The Leaderboard section: its own stack so a profile opened from a board comes back here.
struct LeaderboardSectionView: View {
    @Environment(AppModel.self) private var app
    @State private var service: UMLiveLeaderboardService?

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.leaderboardPath) {
            Group {
                if let service {
                    LeaderboardView(service: service) { id, name in app.openProfile(id: id, name: name) }
                } else {
                    UMTheme.bg.ignoresSafeArea()
                }
            }
            .umNavigationBar(.hidden)
            .umMacLobbyButton(app)
            .navigationDestination(for: AppModel.Route.self) { SectionRouteView(route: $0) }
        }
        .onAppear { if service == nil { service = UMLiveLeaderboardService(meId: app.user?.id) } }
    }
}

#if DEBUG
/// `-UMDiagLeaderboard <mode>`: the Leaderboard section inside the real tab bar.
/// Sample data (offline): `skill`, `competitive` (hero round), `competitive-past` (previous
/// rounds, first expanded), `competitive-standings` (Round standings), `competitive-season` (Season standings), `competitive-expired`
/// (an older season whose games are gone), `competitive-past-tap` (toggles
/// the first previous round after 5 s, for checking it doesn't animate). Append `@N` for season N. Prefix `live-` (e.g. `live-competitive`) to read the
/// real public endpoints instead.
struct UMDiagLeaderboardView: View {
    var mode: String
    private let service: UMLeaderboardService

    init(mode: String) {
        self.mode = mode
        service = mode.hasPrefix("live-") ? UMLiveLeaderboardService(meId: nil) : UMMockLeaderboardService()
    }

    /// `<mode>@<season>` picks a season, e.g. `live-competitive@10`.
    private var base: String {
        let m = mode.split(separator: "@").first.map(String.init) ?? mode
        return m.hasPrefix("live-") ? String(m.dropFirst(5)) : m
    }
    private var seasonArg: Int? { mode.split(separator: "@").dropFirst().first.flatMap { Int($0) } }
    private var tab: UMLeaderboardTab { base.hasPrefix("competitive") ? .competitive : .skill }
    private var season: Int? { seasonArg ?? (base == "competitive-expired" && !mode.hasPrefix("live-") ? 2 : nil) }
    private var anchor: String? {
        switch base {
        case "competitive-past": "past"
        case "competitive-season": "season"
        case "competitive-standings": "standings"
        case "competitive-past-tap": "past-tap"
        case "competitive-seasons": "seasons"
        default: nil
        }
    }

    var body: some View {
        let page = AnyView(NavigationStack {
            LeaderboardView(service: service, tab: tab, initialSeason: season, anchor: anchor).umNavigationBar(.hidden)
        })
        #if os(iOS)
        NativeAppTabs(
            selected: .leaderboard, mentionBadge: 0, showsBar: true,
            play: AnyView(UMTheme.bg), leaderboard: page,
            game: AnyView(UMTheme.bg), you: AnyView(UMTheme.bg), onSelect: { _ in }
        )
        .ignoresSafeArea()
        #else
        page
        #endif
    }
}
#endif
