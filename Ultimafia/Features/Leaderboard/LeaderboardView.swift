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
    var initialSeason: Int?
    /// DEBUG screenshots: scroll to a competitive section (`past`, `season`, `seasons`).
    var anchor: String?
    var onOpenProfile: ((String, String) -> Void)?

    init(service: UMLeaderboardService, tab: UMLeaderboardTab = .skill, initialSeason: Int? = nil,
         anchor: String? = nil, onOpenProfile: ((String, String) -> Void)? = nil) {
        self.service = service
        _tab = State(initialValue: tab)
        self.initialSeason = initialSeason
        self.anchor = anchor
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                case .competitive:
                    CompetitiveBoard(service: service, initialSeason: initialSeason, expandFirstPast: anchor == "past",
                                     onOpenProfile: onOpenProfile) {
                        guard let anchor else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .pointerScrolling()
        }
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
            .fixedSize()
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

