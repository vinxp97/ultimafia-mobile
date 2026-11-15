import SwiftUI
import Charts

/// Competitive tab: Seasons and Rounds.
/// - The season's most recent round is the hero, with everything the API still has.
/// - Earlier rounds are compact podium cards (1st / 2nd / 3rd, ties shared).
/// - The season board ranks by prestige or fortune; provisional while a round is unaccounted.
/// - Where a round's games have expired the page points to season order instead of guessing.
struct CompetitiveBoard: View {
    let service: UMLeaderboardService
    var initialSeason: Int?
    var expandFirstPast = false
    /// DEBUG screenshots: open the standings on the Season toggle.
    var startOnSeason = false
    var onOpenProfile: ((String, String) -> Void)?
    var onLoaded: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var seasons: [UMSeasonSummary] = []
    @State private var seasonNo: Int?
    @State private var rounds: [UMRoundRef: UMRoundDetail] = [:]
    @State private var seasonBase: [UMSeasonStanding] = []
    @State private var allSeasonTop: [Int: [UMSeasonStanding]] = [:]
    @State private var expanded: Set<UMRoundRef> = []
    @State private var scope: StandingsScope = .round
    @State private var showAllStandings = false
    @State private var loading = false
    @State private var error: String?
    @State private var didSignalLoaded = false

    private var wide: Bool { hSize == .regular }
    private var season: UMSeasonSummary? { seasons.first { $0.number == seasonNo } }
    private var started: [UMRoundSummary] { season?.rounds.filter(\.hasStarted) ?? [] }
    private var heroRef: UMRoundRef? { started.last?.ref }
    private var pastRefs: [UMRoundRef] { started.dropLast().map(\.ref).reversed() }
    private var hero: UMRoundDetail? { heroRef.flatMap { rounds[$0] } }
    private var provisional: Bool { started.contains { !$0.accounted } }

    /// Season order: the API's accounted standings plus projected prestige from rounds that
    /// haven't been accounted yet (their standings come from roundInfo).
    private var seasonRows: [UMSeasonStanding] {
        let pending = started.filter { !$0.accounted }.compactMap { rounds[$0.ref]?.standings }
        return pending.isEmpty ? seasonBase : UMCompetitive.provisionalSeason(base: seasonBase, pending: pending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error { Text(error).font(.footnote).foregroundStyle(UMTheme.deadName) }
            seasonPicker
            if season != nil {
                // Two columns only when there are earlier rounds to fill the right one.
                if wide && !pastRefs.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) {
                            heroSection
                            standingsSection
                        }
                        .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 14) { pastSection }
                            .frame(width: 360)
                    }
                    allSeasonsSection
                } else {
                    heroSection
                    standingsSection
                    pastSection
                    allSeasonsSection
                }
            } else if loading || seasons.isEmpty {
                ProgressView().tint(UMTheme.blood).frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .task { await loadSeasons() }
        .task(id: seasonNo) { await loadSeason() }
    }

    // MARK: Loading

    private func loadSeasons() async {
        guard seasons.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            seasons = try await service.seasons()
            seasonNo = initialSeason.flatMap { n in seasons.contains { $0.number == n } ? n : nil } ?? seasons.first?.number
        } catch { self.error = UMFriendlyError.message(for: error) }
    }

    private func loadSeason() async {
        guard let season else { return }
        showAllStandings = false
        expanded = []
        scope = startOnSeason ? .season : .round
        do {
            seasonBase = try await service.seasonStandings(season.number)
            allSeasonTop[season.number] = seasonBase
            // Hero first so it paints while earlier rounds load.
            for ref in started.map(\.ref).reversed() where rounds[ref] == nil {
                if let d = try? await service.round(ref) {
                    withAnimation(.snappy) { rounds[ref] = d }
                }
            }
            if expandFirstPast, let first = pastRefs.first { expanded.insert(first) }
            error = nil
        } catch {
            self.error = UMFriendlyError.message(for: error)
        }
        if !didSignalLoaded { didSignalLoaded = true; onLoaded() }
        // Champions for the All Seasons list, lazily.
        for s in seasons where allSeasonTop[s.number] == nil {
            if let rows = try? await service.seasonStandings(s.number) { allSeasonTop[s.number] = rows }
        }
    }

    // MARK: Season picker

    private func seasonState(_ s: UMSeasonSummary) -> String {
        let begun = s.rounds.filter(\.hasStarted)
        if begun.contains(where: { $0.phase == .open }) { return "Live" }
        if begun.contains(where: { !$0.accounted }) { return "Awaiting results" }
        return s.completed ? "Final" : "Between rounds"
    }

    private var seasonPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(seasons) { s in
                        Button { seasonNo = s.number } label: {
                            Text("Season \(s.number) · \(seasonState(s))")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trophy.fill").foregroundStyle(UMLeaderboardStyle.prestige)
                        Text("Season \(seasonNo ?? 0)").font(.subheadline.weight(.bold))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                if service.competitiveIsMock { UMMockBadge() }
                Spacer(minLength: 0)
                if let season {
                    Text(seasonState(season).uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(provisional ? UMLeaderboardStyle.fortune : UMTheme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((provisional ? UMLeaderboardStyle.fortune : UMTheme.muted).opacity(0.15), in: Capsule())
                }
            }
            if let season {
                let first = season.rounds.first?.startDate ?? ""
                let last = season.rounds.last(where: \.hasStarted)?.dateCompleted
                Text("\(started.count) of \(season.numRounds) round\(season.numRounds == 1 ? "" : "s") played · \(first)\(last.map { " → \($0)" } ?? "") (UTC)")
                    .font(.caption)
                    .foregroundStyle(UMTheme.muted)
            }
        }
    }

    // MARK: Hero (most recent round)

    @ViewBuilder
    private var heroSection: some View {
        sectionTitle("Most recent round")
        if let hero {
            RoundStatusCard(detail: hero)
            if hero.standings.isEmpty {
                expiredCard(round: hero.round.ref.number)
            }
        } else if heroRef != nil {
            ProgressView().tint(UMTheme.blood).frame(maxWidth: .infinity).padding(.vertical, 30)
        } else {
            UMLeaderboardCard(title: nil) {
                Text("This season hasn't started yet.").font(.footnote).foregroundStyle(UMTheme.muted)
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.title3.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.top, 4)
    }

    private func expiredCard(round: Int) -> some View {
        UMLeaderboardCard(title: nil) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.badge.xmark").font(.title3).foregroundStyle(UMTheme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Round \(round) games expired").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("Games are deleted after 30 days, so this round's scores can't be rebuilt. Switch the standings to Season for where everyone finished.")
                        .font(.caption).foregroundStyle(UMTheme.muted)
                }
            }
        }
    }

    private func standingRow(_ s: UMRoundStanding) -> some View {
        let me = s.player.id == service.meId
        return Button { onOpenProfile?(s.player.profileKey, s.player.name) } label: {
            HStack(spacing: 10) {
                UMRankBadge(ranking: s.ranking + 1).frame(width: 32)
                UMAvatarView(userId: s.player.id, hasAvatar: s.player.avatar, name: s.player.name, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(s.player.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        if me { UMYouTag() }
                    }
                    if !wide {
                        Text("\(s.gamesPlayed) games").font(.caption2).foregroundStyle(UMTheme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    Text("\(s.gamesPlayed)").frame(width: 46, alignment: .trailing).foregroundStyle(UMTheme.muted)
                }
                Text(s.fortune.formatted()).frame(width: 62, alignment: .trailing)
                    .foregroundStyle(UMLeaderboardStyle.fortune).fontWeight(.bold)
                Text(s.prestige > 0 ? "+\(s.prestige)" : "—").frame(width: 64, alignment: .trailing)
                    .foregroundStyle(s.prestige > 0 ? UMLeaderboardStyle.prestige : UMTheme.muted)
            }
            .font(.subheadline.monospacedDigit())
            .padding(.vertical, 7)
            .padding(.horizontal, me ? 6 : 0)
            .background(me ? UMLeaderboardStyle.you.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(UMCompetitive.ordinal(s.ranking + 1)), \(s.player.name), \(s.fortune) fortune, \(s.gamesPlayed) games, \(s.prestige) prestige")
    }

    // MARK: Previous rounds

    @ViewBuilder
    private var pastSection: some View {
        if !pastRefs.isEmpty {
            sectionTitle("Previous rounds").id("past")
            ForEach(pastRefs, id: \.self) { ref in pastCard(ref) }
        }
    }

    private func pastCard(_ ref: UMRoundRef) -> some View {
        let d = rounds[ref]
        let summary = season?.rounds.first { $0.ref == ref }
        let isOpen = expanded.contains(ref)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { if isOpen { expanded.remove(ref) } else { expanded.insert(ref) } }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Round \(ref.number)").font(.headline).foregroundStyle(.white)
                        if let summary {
                            Text("\(summary.startDate)\(summary.dateCompleted.map { " → \($0)" } ?? "") · \(summary.phase.label)")
                                .font(.caption2).foregroundStyle(UMTheme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    if let d, !d.standings.isEmpty {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold)).foregroundStyle(UMTheme.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let d {
                if d.standings.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.xmark")
                        Text("Games expired. Season standings show where everyone finished.")
                    }
                    .font(.caption).foregroundStyle(UMTheme.muted)
                } else {
                    podiumRow(UMCompetitive.podium(d.standings).map { place in
                        (place.ranking, place.entries.map { ($0.player, "\($0.fortune.formatted())") })
                    })
                    if isOpen {
                        ForEach(d.standings.prefix(10)) { s in standingRow(s) }
                        if let games = d.games {
                            Text("\(games.count) games · \(d.standings.count) players")
                                .font(.caption2).foregroundStyle(UMTheme.muted)
                        }
                    }
                }
            } else {
                ProgressView().tint(UMTheme.blood).frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(UMTheme.line))
    }

    /// 1st / 2nd / 3rd columns; tied players stack inside their place.
    private func podiumRow(_ places: [(Int, [(UMCompetitor, String)])]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(places, id: \.0) { place in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "medal.fill").foregroundStyle(medal(place.0))
                        Text(UMCompetitive.ordinal(place.0 + 1) + (place.1.count > 1 ? " (tie)" : ""))
                            .font(.caption2.weight(.heavy)).foregroundStyle(medal(place.0))
                    }
                    ForEach(place.1.prefix(3), id: \.0.id) { p in
                        Button { onOpenProfile?(p.0.profileKey, p.0.name) } label: {
                            HStack(spacing: 5) {
                                UMAvatarView(userId: p.0.id, hasAvatar: p.0.avatar, name: p.0.name, size: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.0.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(p.1).font(.caption2.monospacedDigit()).foregroundStyle(UMLeaderboardStyle.fortune)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if place.1.count > 3 {
                        Text("+\(place.1.count - 3) tied").font(.caption2).foregroundStyle(UMTheme.muted)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(medal(place.0).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func medal(_ ranking: Int) -> Color {
        switch ranking {
        case 0: Color(red: 0.96, green: 0.78, blue: 0.30)
        case 1: Color(red: 0.78, green: 0.80, blue: 0.84)
        default: Color(red: 0.80, green: 0.52, blue: 0.32)
        }
    }

    // MARK: Standings (Round / Season)

    enum StandingsScope: Hashable { case round, season }

    @ViewBuilder
    private var standingsSection: some View {
        let n = seasonNo ?? 0
        let roundNo = heroRef?.number ?? 0
        sectionTitle("Standings").id("standings")
        UMLeaderboardCard(title: standingsSubtitle) {
            Picker("Standings", selection: $scope) {
                Text("Round \(roundNo)").tag(StandingsScope.round)
                Text("Season \(n)").tag(StandingsScope.season)
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in showAllStandings = false }
            switch scope {
            case .round: roundStandings
            case .season: seasonStandings
            }
        }
    }

    private var standingsSubtitle: String {
        switch scope {
        case .round:
            guard let hero else { return "Round" }
            let state = (hero.round.phase == .grace || hero.round.phase == .review) ? "Awaiting results · \(hero.round.phase.label)"
                : hero.round.phase.label
            return "Round \(hero.round.ref.number) · \(hero.standings.count) players · \(state)"
        case .season:
            return provisional ? "Season \(seasonNo ?? 0) · Provisional · includes projected prestige" : "Season \(seasonNo ?? 0) · Final"
        }
    }

    private func barChart(_ bars: [(String, Int)], label: String, color: Color) -> some View {
        Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
            BarMark(x: .value(label, bar.1), y: .value("Player", bar.0), height: .ratio(0.7))
                .foregroundStyle(color)
                .cornerRadius(2)
        }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white) } }
        .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(UMTheme.line); AxisValueLabel() } }
        .frame(height: CGFloat(bars.count) * 24 + 24)
        .animation(.snappy, value: scope)
    }

    @ViewBuilder
    private var roundStandings: some View {
        if let hero, !hero.standings.isEmpty {
            let projected = !hero.round.accounted
            let rows = hero.standings
            let limit = showAllStandings ? rows.count : (wide ? 20 : 12)
            barChart(rows.prefix(8).map { ("\($0.ranking + 1). \($0.player.name)", $0.fortune) },
                     label: "Fortune", color: UMLeaderboardStyle.fortune)
            HStack(spacing: 10) {
                Text("#").frame(width: 32)
                Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                if wide { Text("Games").frame(width: 46, alignment: .trailing) }
                Text("Fortune").frame(width: 62, alignment: .trailing)
                Text(projected ? "Prestige*" : "Prestige").frame(width: 64, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(UMTheme.muted)
            LazyVStack(spacing: 0) {
                ForEach(rows.prefix(limit)) { s in
                    standingRow(s)
                    Divider().overlay(UMTheme.line)
                }
            }
            showAllButton(total: rows.count, limit: limit)
            if projected {
                Text("* Projected. Prestige is paid when the round is accounted after review; until then these results can still change.")
                    .font(.caption2).foregroundStyle(UMTheme.muted)
            }
        } else if hero != nil {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.xmark")
                Text("This round's games expired, so its table can't be rebuilt. Season shows where everyone finished.")
            }
            .font(.caption).foregroundStyle(UMTheme.muted)
        } else {
            ProgressView().tint(UMTheme.blood).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var seasonStandings: some View {
        let rows = seasonRows
        if rows.isEmpty {
            Text("No prestige has been paid this season yet.").font(.footnote).foregroundStyle(UMTheme.muted)
        } else {
            let limit = showAllStandings ? rows.count : (wide ? 20 : 12)
            barChart(rows.prefix(8).map { ("\($0.ranking + 1). \($0.player.name)", $0.prestige) },
                     label: "Prestige", color: UMLeaderboardStyle.prestige)
            HStack(spacing: 10) {
                Text("#").frame(width: 32)
                Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                Text("Fortune").frame(width: 66, alignment: .trailing)
                Text(provisional ? "Prestige*" : "Prestige").frame(width: 64, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(UMTheme.muted)
            LazyVStack(spacing: 0) {
                ForEach(rows.prefix(limit)) { r in
                    Button { onOpenProfile?(r.player.profileKey, r.player.name) } label: {
                        HStack(spacing: 10) {
                            UMRankBadge(ranking: r.ranking + 1).frame(width: 32)
                            UMAvatarView(userId: r.player.id, hasAvatar: r.player.avatar, name: r.player.name, size: 26)
                            HStack(spacing: 5) {
                                Text(r.player.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                if r.player.id == service.meId { UMYouTag() }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(r.tiebreakerFortune.formatted()).frame(width: 66, alignment: .trailing)
                                .foregroundStyle(UMLeaderboardStyle.fortune)
                            Text("\(r.prestige)").frame(width: 64, alignment: .trailing)
                                .foregroundStyle(UMLeaderboardStyle.prestige).fontWeight(.bold)
                        }
                        .font(.subheadline.monospacedDigit())
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(UMTheme.line)
                }
            }
            showAllButton(total: rows.count, limit: limit)
            Text(provisional
                 ? "* Includes prestige the unaccounted round would pay at today's ranking. Final when it's accounted."
                 : "Ranked by prestige; fortune breaks ties. Top 3 earn season trophies.")
                .font(.caption2).foregroundStyle(UMTheme.muted)
        }
    }

    @ViewBuilder
    private func showAllButton(total: Int, limit: Int) -> some View {
        if total > limit || showAllStandings {
            Button(showAllStandings ? "Show fewer" : "Show all \(total)") {
                withAnimation { showAllStandings.toggle() }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: All seasons

    @ViewBuilder
    private var allSeasonsSection: some View {
        if seasons.count > 1 {
            sectionTitle("All seasons").id("seasons")
            UMLeaderboardCard(title: nil) {
                ForEach(seasons) { s in
                    let top = s.number == seasonNo ? seasonRows : (allSeasonTop[s.number] ?? [])
                    Button { seasonNo = s.number } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Season \(s.number)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                Text("\(s.rounds.filter(\.hasStarted).count) rd · \(seasonState(s))")
                                    .font(.caption2).foregroundStyle(UMTheme.muted)
                            }
                            .frame(width: 92, alignment: .leading)
                            if top.isEmpty {
                                Text(allSeasonTop[s.number] == nil && s.number != seasonNo ? "Loading…" : "No prestige paid")
                                    .font(.caption).foregroundStyle(UMTheme.muted)
                            } else {
                                HStack(spacing: 8) {
                                    ForEach(Array(top.prefix(wide ? 3 : 2).enumerated()), id: \.element.id) { i, r in
                                        HStack(spacing: 3) {
                                            Image(systemName: "medal.fill").font(.caption2).foregroundStyle(medal(i))
                                            Text(r.player.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                            Text("\(r.prestige)").font(.caption2.monospacedDigit()).foregroundStyle(UMLeaderboardStyle.prestige)
                                        }
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: s.number == seasonNo ? "checkmark.circle.fill" : "chevron.right")
                                .font(.caption).foregroundStyle(s.number == seasonNo ? UMTheme.blood : UMTheme.muted)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(UMTheme.line)
                }
            }
        }
    }
}

struct RoundStatusCard: View {
    var detail: UMRoundDetail

    private var awaiting: Bool { detail.round.phase == .grace || detail.round.phase == .review }

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
                VStack(alignment: .trailing, spacing: 3) {
                    Text(awaiting ? "AWAITING RESULTS" : r.phase.label.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(color.opacity(0.15), in: Capsule())
                    if awaiting {
                        Text(r.phase.label).font(.caption2).foregroundStyle(UMTheme.muted)
                    }
                }
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
            if awaiting {
                Text(r.phase == .grace
                     ? "Play has closed. Games already running can still finish during the 24-hour grace period, then mods review the results."
                     : "Play has closed and mods are reviewing results. Prestige is projected until the round is accounted.")
                    .font(.caption).foregroundStyle(UMTheme.muted)
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
                Text("\(next.label.replacingOccurrences(of: " in", with: "")): \(next.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(UMTheme.muted)
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
