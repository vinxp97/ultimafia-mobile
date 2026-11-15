import SwiftUI
import Charts

/// The Leaderboard page: the Hall of Fame skill board and the competitive rounds board on one
/// screen, like the site's Fame section (`/fame/hall-of-fame`, `/fame/competitive`).
enum UMLeaderboardTab: String, CaseIterable, Identifiable {
    case skill, competitive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skill: "Skill"
        case .competitive: "Competitive"
        }
    }
}

enum UMLeaderboardStyle {
    static let fortune = Color(red: 0.95, green: 0.74, blue: 0.27)
    static let prestige = Color(red: 0.72, green: 0.55, blue: 0.98)
    static let you = Color(red: 0.36, green: 0.62, blue: 0.98)

    static func tierColor(_ t: UMSkill.Tier) -> Color {
        switch t {
        case .master: Color(red: 0.93, green: 0.36, blue: 0.45)
        case .diamond: Color(red: 0.42, green: 0.80, blue: 0.98)
        case .platinum: Color(red: 0.45, green: 0.88, blue: 0.78)
        case .gold: Color(red: 0.96, green: 0.78, blue: 0.30)
        case .silver: Color(red: 0.78, green: 0.80, blue: 0.84)
        case .bronze: Color(red: 0.80, green: 0.52, blue: 0.32)
        case .unrated: UMTheme.muted
        }
    }

    static func tierSymbol(_ t: UMSkill.Tier) -> String {
        switch t {
        case .master: "crown.fill"
        case .diamond: "diamond.fill"
        case .platinum: "seal.fill"
        case .gold: "star.circle.fill"
        case .silver: "shield.fill"
        case .bronze: "shield.lefthalf.filled"
        case .unrated: "questionmark.circle"
        }
    }

    static func phaseColor(_ p: UMRoundPhase) -> Color {
        switch p {
        case .open: UMTheme.village
        case .grace: fortune
        case .review: prestige
        case .final: UMTheme.muted
        case .upcoming: you
        }
    }
}

struct LeaderboardView: View {
    let service: UMLeaderboardService
    @State var tab: UMLeaderboardTab
    var initialRound: UMRoundRef?
    var onOpenProfile: ((String, String) -> Void)?

    init(service: UMLeaderboardService, tab: UMLeaderboardTab = .skill, initialRound: UMRoundRef? = nil,
         onOpenProfile: ((String, String) -> Void)? = nil) {
        self.service = service
        _tab = State(initialValue: tab)
        self.initialRound = initialRound
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Board", selection: $tab) {
                    ForEach(UMLeaderboardTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Leaderboard board")
                switch tab {
                case .skill: SkillBoard(service: service, onOpenProfile: onOpenProfile)
                case .competitive: CompetitiveBoard(service: service, initialRound: initialRound, onOpenProfile: onOpenProfile)
                }
            }
            .padding(16)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .pointerScrolling()
        .background(UMTheme.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(UMLeaderboardStyle.fortune)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.tint(UMLeaderboardStyle.fortune.opacity(0.18)), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Leaderboard")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                Text(tab == .skill ? "Hall of Fame · skill rating" : "Competitive rounds · fortune & score")
                    .font(.caption)
                    .foregroundStyle(UMTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

struct UMLeaderboardCard<Content: View>: View {
    var title: String?
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(UMTheme.muted)
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(UMTheme.line))
    }
}

struct UMMockBadge: View {
    var body: some View {
        Text("SAMPLE DATA")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(UMLeaderboardStyle.fortune)
            .background(UMLeaderboardStyle.fortune.opacity(0.15), in: Capsule())
            .accessibilityLabel("Sample data")
    }
}

struct UMRankBadge: View {
    var ranking: Int  // 1-based
    var body: some View {
        let medal: Color? = switch ranking {
        case 1: Color(red: 0.96, green: 0.78, blue: 0.30)
        case 2: Color(red: 0.78, green: 0.80, blue: 0.84)
        case 3: Color(red: 0.80, green: 0.52, blue: 0.32)
        default: nil
        }
        Text("\(ranking)")
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(medal == nil ? UMTheme.muted : .black)
            .frame(minWidth: 28, minHeight: 28)
            .background(medal ?? Color.clear, in: Circle())
            .accessibilityLabel("Rank \(ranking)")
    }
}

struct UMTierChip: View {
    var tier: UMSkill.Tier
    var compact = false
    var body: some View {
        let c = UMLeaderboardStyle.tierColor(tier)
        HStack(spacing: 4) {
            Image(systemName: UMLeaderboardStyle.tierSymbol(tier))
            if !compact { Text(tier.rawValue) }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(c)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(c.opacity(0.14), in: Capsule())
        .accessibilityLabel("\(tier.rawValue) tier")
    }
}

struct UMYouTag: View {
    var body: some View {
        Text("YOU")
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(UMLeaderboardStyle.you, in: Capsule())
    }
}

// MARK: - Skill board

private struct SkillBoard: View {
    let service: UMLeaderboardService
    var onOpenProfile: ((String, String) -> Void)?
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var entries: [UMSkillEntry] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var total: Int?
    @State private var myRank: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var isMock = false
    @State private var showAbout = false

    private let pageSize = 50
    private var wide: Bool { hSize == .regular }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if entries.count >= 3 { podium }
            UMLeaderboardCard(title: "Rankings") {
                if wide { columnHeader }
                LazyVStack(spacing: 0) {
                    ForEach(entries.dropFirst(entries.count >= 3 ? 3 : 0)) { e in
                        row(e)
                        Divider().overlay(UMTheme.line)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(UMTheme.deadName)
                }
                if loading {
                    ProgressView().tint(UMTheme.blood).frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if page < pages {
                    Button("Show more") { Task { await load(next: true) } }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
        }
        .task { if entries.isEmpty { await load(next: false) } }
        .sheet(isPresented: $showAbout) { SkillAboutSheet() }
    }

    private func load(next: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await service.skillPage(page: next ? page + 1 : 1, pageSize: pageSize)
            entries = next ? entries + result.users : result.users
            page = result.page ?? (next ? page + 1 : 1)
            pages = result.pages ?? page
            total = result.total
            myRank = result.myRank
            isMock = service.skillIsMock
            error = nil
        } catch {
            self.error = UMFriendlyError.message(for: error)
        }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Skill Rating").font(.headline).foregroundStyle(.white)
                    if isMock { UMMockBadge() }
                }
                Text("Conservative rating μ − 3σ · \(UMSkill.minRatedGames)+ rated games\(total.map { " · \($0) players" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(UMTheme.muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(UMSkill.Tier.allCases.filter { $0 != .unrated }, id: \.self) { UMTierChip(tier: $0) }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if let myRank {
                    VStack(spacing: 0) {
                        Text("YOUR RANK").font(.system(size: 9, weight: .heavy)).foregroundStyle(UMTheme.muted)
                        Text("#\(myRank)").font(.title2.weight(.heavy).monospacedDigit()).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.tint(UMLeaderboardStyle.you.opacity(0.25)), in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
                Button { showAbout = true } label: {
                    Label("About", systemImage: "info.circle").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(UMTheme.muted)
            }
        }
        .padding(14)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(UMTheme.line))
    }

    private var podium: some View {
        HStack(alignment: .bottom, spacing: 10) {
            podiumCard(entries[1], height: 118)
            podiumCard(entries[0], height: 138)
            podiumCard(entries[2], height: 104)
        }
    }

    private func podiumCard(_ e: UMSkillEntry, height: CGFloat) -> some View {
        let me = e.userId == service.meId
        return Button { onOpenProfile?(e.vanityUrl ?? e.userId, e.username) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    UMAvatarView(userId: e.userId, hasAvatar: e.avatar ?? false, name: e.username, size: e.rank == 1 ? 52 : 44)
                    UMRankBadge(ranking: e.rank).scaleEffect(0.8).offset(x: 8, y: 6)
                }
                Text(e.username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(me ? UMLeaderboardStyle.you : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(String(format: "%.2f", e.skillRating ?? 0))
                    .font(.title3.weight(.heavy).monospacedDigit())
                    .foregroundStyle(UMLeaderboardStyle.tierColor(e.tier))
                UMTierChip(tier: e.tier, compact: !wide)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .bottom)
            .background(
                LinearGradient(colors: [UMLeaderboardStyle.tierColor(e.tier).opacity(0.18), UMTheme.card],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(me ? UMLeaderboardStyle.you : UMTheme.line, lineWidth: me ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(e.username), rank \(e.rank), rating \(String(format: "%.2f", e.skillRating ?? 0)), \(e.tier.rawValue)")
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("#").frame(width: 32)
            Text("Player").frame(maxWidth: .infinity, alignment: .leading)
            Text("Tier").frame(width: 92, alignment: .leading)
            Text("μ").frame(width: 56, alignment: .trailing)
            Text("σ").frame(width: 50, alignment: .trailing)
            Text("Matches").frame(width: 64, alignment: .trailing)
            Text("Win %").frame(width: 52, alignment: .trailing)
            Text("Rating").frame(width: 70, alignment: .trailing)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(UMTheme.muted)
    }

    private func row(_ e: UMSkillEntry) -> some View {
        let me = e.userId == service.meId
        return Button { onOpenProfile?(e.vanityUrl ?? e.userId, e.username) } label: {
            HStack(spacing: 10) {
                UMRankBadge(ranking: e.rank).frame(width: 32)
                UMAvatarView(userId: e.userId, hasAvatar: e.avatar ?? false, name: e.username, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(e.username).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        if me { UMYouTag() }
                    }
                    if !wide {
                        HStack(spacing: 6) {
                            UMTierChip(tier: e.tier, compact: true)
                            Text("\(e.skillGamesPlayed ?? 0) matches")
                                .font(.caption2).foregroundStyle(UMTheme.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    UMTierChip(tier: e.tier).frame(width: 92, alignment: .leading)
                    Text(String(format: "%.2f", e.skillMu ?? 0)).frame(width: 56, alignment: .trailing)
                    Text(String(format: "%.2f", e.skillSigma ?? 0)).frame(width: 50, alignment: .trailing)
                    Text("\(e.skillGamesPlayed ?? 0)").frame(width: 64, alignment: .trailing)
                    Text(e.winRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—").frame(width: 52, alignment: .trailing)
                }
                Text(String(format: "%.2f", e.skillRating ?? 0))
                    .font(.body.weight(.bold).monospacedDigit())
                    .foregroundStyle(UMLeaderboardStyle.tierColor(e.tier))
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(UMTheme.muted)
            .padding(.vertical, 8)
            .padding(.horizontal, me ? 6 : 0)
            .background(me ? UMLeaderboardStyle.you.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct SkillAboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Every ranked and competitive game with a winner and a loser updates one global rating: μ (estimated skill) and σ (uncertainty). The board ranks by the conservative rating μ − 3σ, so new players with high uncertainty start near 0 and climb as σ shrinks.")
                    Text("You appear after \(UMSkill.minRatedGames) rated games. Tiers are percentiles of everyone rated: Master 98%+, Diamond 90%+, Platinum 75%+, Gold 50%+, Silver 20%+, Bronze below that.")
                    Text("Players who hide their statistics are left off the board.")
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(20)
            }
            .background(UMTheme.bg.ignoresSafeArea())
            .navigationTitle("Skill rating")
            .umInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Competitive board

private struct CompetitiveBoard: View {
    let service: UMLeaderboardService
    var initialRound: UMRoundRef?
    var onOpenProfile: ((String, String) -> Void)?
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var seasons: [UMSeasonSummary] = []
    @State private var selected: UMRoundRef?
    @State private var detail: UMRoundDetail?
    @State private var seasonRows: [UMSeasonStanding] = []
    @State private var history: [UMPlayerRoundPoint] = []
    @State private var historyGames: [UMRoundRef: [UMRoundGame]] = [:]
    @State private var competitors: [UMCompetitor] = []
    @State private var focusId: String?
    @State private var error: String?

    private var wide: Bool { hSize == .regular }
    private var season: UMSeasonSummary? { seasons.first { $0.number == selected?.season } }
    private var detailedRefs: Set<UMRoundRef> {
        UMCompetitive.detailedRounds(seasons.flatMap(\.rounds).filter(\.hasStarted).map(\.ref))
    }
    private var focusName: String {
        competitors.first { $0.id == focusId }?.name ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error { Text(error).font(.footnote).foregroundStyle(UMTheme.deadName) }
            selectors
            if let detail {
                if wide {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            RoundStatusCard(detail: detail, isMock: service.competitiveIsMock)
                            chartCard
                            standingsCard(detail)
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            scoreCard(detail)
                            seasonCard
                        }
                        .frame(width: 360)
                    }
                } else {
                    RoundStatusCard(detail: detail, isMock: service.competitiveIsMock)
                    chartCard
                    standingsCard(detail)
                    scoreCard(detail)
                    seasonCard
                }
            } else {
                ProgressView().tint(UMTheme.blood).frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .task { await loadSeasons() }
        .task(id: selected) { await loadRound() }
        .task(id: "\(focusId ?? "")-\(selected?.season ?? 0)") { await loadHistory() }
    }

    // MARK: Loading

    private func loadSeasons() async {
        guard seasons.isEmpty else { return }
        do {
            seasons = try await service.seasons()
            focusId = service.meId
            if let initialRound { selected = initialRound }
            else if let s = seasons.first(where: { !$0.completed }) ?? seasons.first {
                selected = UMRoundRef(season: s.number, number: s.currentRound)
            }
        } catch { self.error = UMFriendlyError.message(for: error) }
    }

    private func loadRound() async {
        guard let selected else { return }
        do {
            let d = try await service.round(selected)
            withAnimation(.snappy) { detail = d }
            seasonRows = try await service.seasonStandings(selected.season)
            competitors = try await service.competitors(season: selected.season)
            if focusId == nil || !competitors.contains(where: { $0.id == focusId }) {
                focusId = d.standings.first?.player.id
            }
        } catch {
            detail = nil
            self.error = UMFriendlyError.message(for: error)
        }
    }

    private func loadHistory() async {
        guard let focusId, let s = selected?.season else { return }
        history = (try? await service.history(playerId: focusId, season: s)) ?? []
        var games: [UMRoundRef: [UMRoundGame]] = [:]
        for ref in detailedRefs where ref.season == s {
            if let d = try? await service.round(ref), let g = d.games { games[ref] = g }
        }
        historyGames = games
    }

    // MARK: Selectors

    private var selectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    ForEach(seasons) { s in
                        Button("Season \(s.number)\(s.completed ? " (final)" : "")") {
                            let n = s.completed ? s.numRounds : s.currentRound
                            selected = UMRoundRef(season: s.number, number: n)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trophy.fill").foregroundStyle(UMLeaderboardStyle.prestige)
                        Text("Season \(selected?.season ?? 0)").font(.subheadline.weight(.bold))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                Spacer(minLength: 0)
                if let season {
                    Text("\(season.rounds.filter(\.hasStarted).count) of \(season.numRounds) rounds")
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                }
            }
            if let season {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(season.rounds) { r in roundChip(r) .id(r.ref) }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
                    .onChange(of: selected) { _, now in
                        if let now { withAnimation { proxy.scrollTo(now, anchor: .center) } }
                    }
                }
            }
        }
    }

    private func roundChip(_ r: UMRoundSummary) -> some View {
        let on = r.ref == selected
        let expired = r.hasStarted && !detailedRefs.contains(r.ref)
        return Button { selected = r.ref } label: {
            VStack(spacing: 3) {
                Text("R\(r.ref.number)").font(.subheadline.weight(.bold).monospacedDigit())
                HStack(spacing: 3) {
                    Circle().fill(UMLeaderboardStyle.phaseColor(r.phase)).frame(width: 6, height: 6)
                    if expired { Image(systemName: "clock.badge.xmark").font(.system(size: 9)) }
                }
            }
            .foregroundStyle(on ? .white : (r.hasStarted ? .white.opacity(0.85) : UMTheme.muted))
            .frame(width: 48, height: 46)
            .background(on ? UMTheme.blood.opacity(0.85) : UMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? .clear : UMTheme.line))
        }
        .buttonStyle(.plain)
        .disabled(!r.hasStarted)
        .accessibilityLabel("Round \(r.ref.number), \(r.phase.label)\(expired ? ", game details expired" : "")")
    }

    // MARK: Chart

    private struct Segment: Identifiable {
        var id: String
        var round: String
        var points: Int
        var expired: Bool
        var selected: Bool
        var game: Int
    }

    private var segments: [Segment] {
        guard let s = selected?.season else { return [] }
        var out: [Segment] = []
        for p in history {
            let ref = UMRoundRef(season: s, number: p.round)
            let isSel = ref == selected
            if let games = historyGames[ref], let focusId {
                // Score detail: one stacked segment per game the player scored in.
                let scored = games.compactMap { $0.earned[focusId] }.filter { $0 > 0 }
                if scored.isEmpty {
                    out.append(Segment(id: "\(p.round)-0", round: "R\(p.round)", points: 0, expired: false, selected: isSel, game: 0))
                }
                for (i, pts) in scored.enumerated() {
                    out.append(Segment(id: "\(p.round)-\(i)", round: "R\(p.round)", points: pts, expired: false, selected: isSel, game: i))
                }
            } else {
                out.append(Segment(id: "\(p.round)-f", round: "R\(p.round)", points: p.fortune, expired: true, selected: isSel, game: 0))
            }
        }
        return out
    }

    private var chartCard: some View {
        UMLeaderboardCard(title: "Per-round results", trailing: AnyView(focusMenu)) {
            let segs = segments
            Chart {
                ForEach(segs) { seg in
                    BarMark(x: .value("Round", seg.round), y: .value("Fortune", seg.points), width: .ratio(0.62))
                        .foregroundStyle(barColor(seg))
                        .cornerRadius(3)
                }
                ForEach(history) { p in
                    if let r = p.ranking {
                        PointMark(x: .value("Round", "R\(p.round)"), y: .value("Fortune", p.fortune))
                            .symbolSize(0)
                            .annotation(position: .top, spacing: 3) {
                                Text(UMCompetitive.ordinal(r + 1))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(UMTheme.muted)
                            }
                    }
                }
            }
            .chartXSelection(value: Binding(
                get: { selected.map { "R\($0.number)" } },
                set: { label in
                    guard let label, let n = Int(label.dropFirst()), let s = selected?.season,
                          history.contains(where: { $0.round == n }) else { return }
                    selected = UMRoundRef(season: s, number: n)
                }))
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(UMTheme.line); AxisValueLabel() } }
            .frame(height: wide ? 230 : 190)
            .animation(.snappy, value: history)
            HStack(spacing: 14) {
                legend(color: UMLeaderboardStyle.fortune, text: "Score by game (last \(UMCompetitive.detailedRoundWindow) rounds)")
                legend(color: UMLeaderboardStyle.fortune.opacity(0.35), text: "Final fortune only")
            }
            .font(.caption2)
            .foregroundStyle(UMTheme.muted)
            if let p = history.first(where: { $0.round == selected?.number }) {
                HStack(spacing: 0) {
                    stat("Fortune", p.fortune.formatted(), UMLeaderboardStyle.fortune)
                    stat("Finish", p.ranking.map { UMCompetitive.ordinal($0 + 1) } ?? "—", .white)
                    stat("Prestige", "+\(p.prestige)", UMLeaderboardStyle.prestige)
                    stat("Score", p.score.map { $0.formatted() } ?? "expired", p.score == nil ? UMTheme.muted : .white)
                    stat("Games", p.games.map(String.init) ?? "—", .white)
                }
                .padding(.top, 2)
            }
        }
    }

    private func barColor(_ seg: Segment) -> Color {
        let base = UMLeaderboardStyle.fortune
        if seg.expired { return base.opacity(seg.selected ? 0.55 : 0.28) }
        // Alternate shades so stacked games read as separate scores.
        let shade = seg.game % 2 == 0 ? base : Color(red: 0.86, green: 0.58, blue: 0.18)
        return shade.opacity(seg.selected ? 1 : 0.6)
    }

    private var focusMenu: some View {
        Menu {
            ForEach(competitors, id: \.id) { c in
                Button { focusId = c.id } label: {
                    if c.id == focusId { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(focusId == service.meId ? "You" : focusName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .accessibilityLabel("Player shown in chart: \(focusName)")
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(UMTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Standings

    private func standingsCard(_ d: UMRoundDetail) -> some View {
        let projected = !d.round.accounted
        return UMLeaderboardCard(title: "Round \(d.round.ref.number) standings") {
            HStack(spacing: 10) {
                Text("#").frame(width: 32)
                Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                Text("Games").frame(width: 46, alignment: .trailing)
                Text("Fortune").frame(width: 62, alignment: .trailing)
                Text(projected ? "Prestige*" : "Prestige").frame(width: 62, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(UMTheme.muted)
            LazyVStack(spacing: 0) {
                ForEach(d.standings) { s in
                    standingRow(s)
                    Divider().overlay(UMTheme.line)
                }
            }
            if projected {
                Text("* Projected. Prestige is paid when the round is accounted after review.")
                    .font(.caption2).foregroundStyle(UMTheme.muted)
            }
        }
    }

    private func standingRow(_ s: UMRoundStanding) -> some View {
        let me = s.player.id == service.meId
        let focused = s.player.id == focusId
        return Button { focusId = s.player.id } label: {
            HStack(spacing: 10) {
                UMRankBadge(ranking: s.ranking + 1).frame(width: 32)
                UMAvatarView(userId: s.player.id, hasAvatar: s.player.avatar, name: s.player.name, size: 26)
                HStack(spacing: 5) {
                    Text(s.player.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if me { UMYouTag() }
                    if focused && !me {
                        Image(systemName: "chart.bar.fill").font(.caption2).foregroundStyle(UMLeaderboardStyle.fortune)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(s.gamesPlayed)").frame(width: 46, alignment: .trailing).foregroundStyle(UMTheme.muted)
                Text(s.fortune.formatted()).frame(width: 62, alignment: .trailing)
                    .foregroundStyle(UMLeaderboardStyle.fortune).fontWeight(.bold)
                Text(s.prestige > 0 ? "+\(s.prestige)" : "—").frame(width: 62, alignment: .trailing)
                    .foregroundStyle(s.prestige > 0 ? UMLeaderboardStyle.prestige : UMTheme.muted)
            }
            .font(.subheadline.monospacedDigit())
            .padding(.vertical, 7)
            .padding(.horizontal, me || focused ? 6 : 0)
            .background(me ? UMLeaderboardStyle.you.opacity(0.12) : (focused ? UMLeaderboardStyle.fortune.opacity(0.08) : .clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in chart", systemImage: "chart.bar") { focusId = s.player.id }
            if let onOpenProfile {
                Button("Open profile", systemImage: "person.crop.circle") { onOpenProfile(s.player.id, s.player.name) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(UMCompetitive.ordinal(s.ranking + 1)), \(s.player.name), \(s.fortune) fortune, \(s.gamesPlayed) games, \(s.prestige) prestige")
    }

    // MARK: Score by game

    @ViewBuilder
    private func scoreCard(_ d: UMRoundDetail) -> some View {
        UMLeaderboardCard(title: "Score by game") {
            if let games = d.games {
                let mine = focusId
                if games.isEmpty {
                    Text("No competitive games finished yet this round.").font(.footnote).foregroundStyle(UMTheme.muted)
                }
                ForEach(games.prefix(wide ? 14 : 8)) { g in
                    let pts = mine.flatMap { g.earned[$0] }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.setupName).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            Text("Day \(g.day) · \(g.endTime.formatted(date: .abbreviated, time: .shortened)) · \(g.earned.count) players")
                                .font(.caption2).foregroundStyle(UMTheme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let pts {
                            Text(pts > 0 ? "+\(pts)" : "0")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(pts > 0 ? UMLeaderboardStyle.fortune : UMTheme.muted)
                        } else {
                            Text("didn't play").font(.caption2).foregroundStyle(UMTheme.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if games.count > (wide ? 14 : 8) {
                    Text("+ \(games.count - (wide ? 14 : 8)) more games").font(.caption2).foregroundStyle(UMTheme.muted)
                }
                Text("Showing \(focusId == service.meId ? "your" : focusName + "'s") score per game. Losers earn 0.")
                    .font(.caption2).foregroundStyle(UMTheme.muted)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.title3)
                        .foregroundStyle(UMTheme.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Game details expired").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text("Games are deleted after 30 days, so per-game scores are kept for the last \(UMCompetitive.detailedRoundWindow) rounds only. Final fortune and prestige for this round are still shown.")
                            .font(.caption).foregroundStyle(UMTheme.muted)
                    }
                }
            }
        }
    }

    // MARK: Season

    private var seasonCard: some View {
        UMLeaderboardCard(title: "Season \(selected?.season ?? 0) prestige") {
            if seasonRows.isEmpty {
                Text("No prestige paid yet this season.").font(.footnote).foregroundStyle(UMTheme.muted)
            }
            ForEach(seasonRows.prefix(10)) { s in
                HStack(spacing: 10) {
                    UMRankBadge(ranking: s.ranking + 1).frame(width: 32)
                    Text(s.player.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if s.player.id == service.meId { UMYouTag() }
                    Spacer(minLength: 0)
                    Text(s.tiebreakerFortune.formatted())
                        .font(.caption.monospacedDigit()).foregroundStyle(UMLeaderboardStyle.fortune.opacity(0.8))
                    Text("\(s.prestige)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(UMLeaderboardStyle.prestige)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
            Text("Prestige from accounted rounds; fortune breaks ties. Top 3 at season end earn trophies.")
                .font(.caption2).foregroundStyle(UMTheme.muted)
        }
    }
}

private struct RoundStatusCard: View {
    var detail: UMRoundDetail
    var isMock: Bool

    var body: some View {
        let r = detail.round
        let color = UMLeaderboardStyle.phaseColor(r.phase)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Season \(detail.season) · Round \(r.ref.number)")
                        .font(.title3.weight(.heavy)).foregroundStyle(.white)
                    Text(dates).font(.caption).foregroundStyle(UMTheme.muted)
                }
                Spacer(minLength: 0)
                if isMock { UMMockBadge() }
                Text(r.phase.label.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(color.opacity(0.15), in: Capsule())
            }
            if r.phase == .open {
                ProgressView(value: Double(min(r.currentDay, UMCompetitive.openDaysPerRound)),
                             total: Double(UMCompetitive.openDaysPerRound))
                    .tint(color)
                HStack {
                    Text("Day \(r.currentDay) of \(UMCompetitive.openDaysPerRound)")
                    Spacer()
                    Text("Ends early at \(UMCompetitive.fortuneHammer.formatted()) fortune")
                }
                .font(.caption2).foregroundStyle(UMTheme.muted)
            }
            if let next = detail.nextEvent {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 8) {
                        Image(systemName: "timer").foregroundStyle(color)
                        Text(next.label).foregroundStyle(UMTheme.muted)
                        Spacer(minLength: 0)
                        Text(UMCompetitive.countdown(to: next.date, now: ctx.date))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .font(.subheadline)
                }
                .padding(10)
                .glassEffect(.regular.tint(color.opacity(0.12)), in: .rect(cornerRadius: 12))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(UMTheme.line))
    }

    private var dates: String {
        let r = detail.round
        if let end = r.dateCompleted { return "\(r.startDate) → \(end) (UTC)" }
        return "Started \(r.startDate) (UTC)"
    }
}
