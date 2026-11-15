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
/// `-UMDiagLeaderboard [skill|competitive|competitive-review|competitive-old]`: the Leaderboard
/// section inside the real tab bar with sample data only (no network, no account).
struct UMDiagLeaderboardView: View {
    var mode: String
    private let service = UMMockLeaderboardService()

    private var tab: UMLeaderboardTab { mode.hasPrefix("competitive") ? .competitive : .skill }
    private var round: UMRoundRef? {
        switch mode {
        case "competitive-old": UMRoundRef(season: 3, number: 2)
        case "competitive-review": UMRoundRef(season: 3, number: 5)
        default: nil
        }
    }

    var body: some View {
        let page = AnyView(NavigationStack {
            LeaderboardView(service: service, tab: tab, initialRound: round).umNavigationBar(.hidden)
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
