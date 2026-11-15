import SwiftUI

struct LobbyView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    playHeader
                        .id("lobby-top")
                    onlineStrip
                    if app.isOnLobbyWhileSeated {
                        seatedBanner
                    }
                    section("Open", games: excludingSeated(app.openGames), empty: "No open games right now.")
                    section("In progress", games: excludingSeated(app.inProgressGames), empty: "Nothing in progress.")
                    section("Finished", games: app.finishedGames, empty: "No finished games.")
                    if app.finishedHasMore, !app.finishedGames.isEmpty {
                        // Infinite scroll: the lazy stack only builds this row near the bottom.
                        ProgressView()
                            .tint(UMTheme.blood)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear { Task { await app.loadFinished(reset: false) } }
                    }
                }
                .padding(16)
            }
            .pointerScrolling()
            .onChange(of: app.lobbyScrollToTop) { _, _ in
                // Wait for any pop back to the lobby to finish before scrolling.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation { proxy.scrollTo("lobby-top", anchor: .top) }
                }
            }
            }
            .background(UMTheme.bg.ignoresSafeArea())
            .umInlineTitle()
            .umNavigationBar(.hidden)
            .refreshable { await app.refreshLobby() }
            .task {
                await RoleCatalog.shared.load()
                UMSpeechLM.prepareIfNeeded()
                await app.refreshLobby()
                app.startPresence()
            }
            .navigationDestination(for: AppModel.Route.self) { route in
                switch route {
                case .profile(let id, let name):
                    UserProfileView(userId: id, userName: name)
                case .family(let id, let name):
                    FamilyView(familyId: id, familyName: name)
                case .review:
                    GameView(review: true)
                case .host:
                    SetupSearchView()
                }
            }
        }
    }

    private var playHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            // The branding stays one combined element, and the host button is a control of its own
            // beside it, so it stays reachable instead of being swallowed by the combined label.
            HStack(alignment: .center, spacing: 10) {
                Image(SeasonalLogo.current())
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 44, alignment: .leading)
                    .accessibilityHidden(true)
                Text("Mobile")
                    .font(.title3.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Ultimafia Mobile")
            .accessibilityHint("Pull down to refresh")
            Spacer(minLength: 0)
            // Hosting belongs to the lobby rather than a section of its own, the way the website has
            // it, so the way in lives in the lobby header and the bar never moves for it.
            if !app.hasCurrentGame {
            Button { app.openHost() } label: {
                Label("Host", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(UMTheme.card, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Host a game")
            }
        }
    }

    private var onlineStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(app.onlineUsers.count) Players online:")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(app.onlineUsers) { person in
                        Button {
                            let key = (person.vanityUrl?.isEmpty == false) ? person.vanityUrl! : person.id
                            app.openProfile(id: key, name: person.name ?? "")
                        } label: {
                            VStack(spacing: 4) {
                                UMAvatarView(
                                    userId: person.id,
                                    hasAvatar: person.avatar ?? false,
                                    name: person.name ?? "",
                                    size: 48
                                )
                                Text(person.name ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(UMTheme.muted)
                                    .lineLimit(1)
                                    .frame(width: 56)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The seated game is pinned in the banner up top, so don't list it again below.
    private func excludingSeated(_ games: [GameSummary]) -> [GameSummary] {
        guard app.isOnLobbyWhileSeated, let id = app.seatedGameId else { return games }
        return games.filter { $0.id != id }
    }

    private var seatedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app.spectatingGameId != nil ? "YOU'RE SPECTATING" : "YOU'RE IN A GAME")
                .font(.caption.weight(.bold))
                .foregroundStyle(UMTheme.blood)
            Text(UMText.clipped(app.seatedSetupName))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(app.seatedPhaseLabel)
                if let extra = app.seatedPlayerLabel {
                    Text("·")
                    Text(extra)
                }
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(UMTheme.muted)
            seatedRoleStrip
            HStack(spacing: 10) {
                Button("Return to Game") { app.resumeSeatedGame() }
                    .buttonStyle(.borderedProminent)
                    .tint(UMTheme.blood)
                Button("Leave Game", role: .destructive) { app.requestLeave() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(UMTheme.blood.opacity(0.55)))
    }

    @ViewBuilder
    private var seatedRoleStrip: some View {
        if let session = app.game, !session.setupRolesets.joined().isEmpty || !session.setupBanished.isEmpty || !session.setupEvents.isEmpty {
            SetupPreviewStrip(
                gameType: session.setupGameType,
                rolesets: session.setupRolesets,
                banished: session.setupBanished,
                isSimpleMulti: session.isSimpleMulti,
                displayedRoles: session.setupRoles,
                onCycle: { session.cycleSetupRoleset() },
                compact: true,
                events: session.setupEvents,
                eventsPerSet: session.setupEventsPerSet,
                grouped: session.setupGrouped,
                groupSizes: session.setupGroupSizes,
                banishedPerSet: session.setupBanishedPerSet,
                currentIndex: session.setupRolesetIndex
            )
        } else if let setup = app.seatedGameSummary?.setup {
            LobbySetupStrip(setup: setup, gameType: app.seatedGameSummary?.type ?? "Mafia")
        }
    }

    private func section(_ title: String, games: [GameSummary], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(UMTheme.muted)
            if games.isEmpty {
                Text(empty)
                    .foregroundStyle(UMTheme.muted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(games) { game in
                    GameRow(game: game)
                }
            }
        }
    }
}

struct GameRow: View {
    @Environment(AppModel.self) private var app
    let game: GameSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(game.type ?? "Game")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(UMTheme.blood)
                if game.ranked == true {
                    tag("Ranked", UMTheme.mafia)
                }
                if game.competitive == true {
                    tag("Comp", Color.yellow)
                }
                Spacer()
                Text("\(game.playerCount)/\(game.setupTotal)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Text(game.setup?.clippedName ?? "Custom setup")
                .font(.headline)
                .lineLimit(1)
            if let setup = game.setup {
                LobbySetupStrip(setup: setup, gameType: game.type ?? "Mafia")
            }
            HStack {
                Text(game.lobbyName ?? game.lobby ?? "")
                    .foregroundStyle(UMTheme.muted)
                    .font(.caption)
                Spacer()
                if game.id == app.seatedGameId {
                    Button("Return") { app.resumeSeatedGame() }
                        .buttonStyle(.borderedProminent)
                        .tint(UMTheme.blood)
                    Button("Leave Game", role: .destructive) { app.requestLeave() }
                        .buttonStyle(.bordered)
                } else if game.isOpen {
                    Button("Join") { app.openGame(game) }
                        .buttonStyle(.borderedProminent)
                        .tint(UMTheme.blood)
                    if game.spectating == true {
                        Button("Watch") { app.openGame(game, spectate: true) }
                            .buttonStyle(.bordered)
                    }
                } else if game.isFinished {
                    Button("Review") { app.openReview(game.id) }
                        .buttonStyle(.bordered)
                } else if game.spectating == true {
                    Button("Spectate") { app.openGame(game, spectate: true) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(UMTheme.line))
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

struct LobbySetupStrip: View {
    var setup: SetupInfo
    var gameType: String

    var body: some View {
        let bundle = setup.roleBundle(defaultGameType: gameType)
        SetupPreviewStrip(
            gameType: setup.gameType ?? gameType,
            rolesets: bundle.rolesets,
            banished: bundle.banished,
            isSimpleMulti: setup.isSimpleMulti(defaultGameType: gameType),
            compact: true,
            events: bundle.events,
            eventsPerSet: bundle.eventsPerSet,
            grouped: bundle.grouped,
            groupSizes: bundle.groupSizes,
            banishedPerSet: bundle.banishedPerSet
        )
    }
}


/// Lobby header logo, picked by month like the website (Feb, Jun, Jul, Oct, Nov, Dec), Default otherwise.
enum SeasonalLogo {
    static func current(_ date: Date = .now) -> String {
        switch Calendar.current.component(.month, from: date) {
        case 2: return "Logo-valentines"
        case 6: return "Logo-pride"
        case 7: return "Logo-july"
        case 10: return "Logo-halloween"
        case 11: return "Logo-thanksgiving"
        case 12: return "Logo-winter"
        default: return "Logo-default"
        }
    }
}
