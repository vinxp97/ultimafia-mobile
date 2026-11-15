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
    var onOpenProfile: ((String, String) -> Void)?
    var onLoaded: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var seasons: [UMSeasonSummary] = []
    @State private var seasonNo: Int?
    @State private var rounds: [UMRoundRef: UMRoundDetail] = [:]
    @State private var seasonBase: [UMSeasonStanding] = []
    @State private var allSeasonTop: [Int: [UMSeasonStanding]] = [:]
    @State private var expanded: Set<UMRoundRef> = []
    @State private var sortByFortune = false
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
        let rows = pending.isEmpty ? seasonBase : UMCompetitive.provisionalSeason(base: seasonBase, pending: pending)
        guard sortByFortune else { return rows }
        return rows.sorted { ($0.tiebreakerFortune, $0.prestige) > ($1.tiebreakerFortune, $1.prestige) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error { Text(error).font(.footnote).foregroundStyle(UMTheme.deadName) }
            seasonPicker
            if season != nil {
                if wide {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) { heroSection }
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 14) {
                            pastSection
                            seasonSection
                        }
                        .frame(width: 380)
                    }
                    allSeasonsSection
                } else {
                    heroSection
                    pastSection
                    seasonSection
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

    private func name(_ id: String) -> String {
        for d in rounds.values { if let p = d.standings.first(where: { $0.player.id == id }) { return p.player.name } }
        return seasonBase.first { $0.player.id == id }?.player.name ?? "Player"
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
            } else {
                topFortuneChart(hero)
                standingsCard(hero)
                scoreCard(hero)
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
                    Text("Games are deleted after 30 days, so this round's scores can't be rebuilt. Season order is shown below instead.")
                        .font(.caption).foregroundStyle(UMTheme.muted)
                }
            }
        }
    }

    private struct ChartSeg: Identifiable {
        var id: String
        var player: String
        var points: Int
        var shade: Int
    }

    private func topFortuneChart(_ d: UMRoundDetail) -> some View {
        let top = Array(d.standings.prefix(wide ? 12 : 8))
        var segs: [ChartSeg] = []
        for s in top {
            let label = "\(s.ranking + 1). \(s.player.name)"
            let parts = (d.games ?? []).reversed().compactMap { $0.earned[s.player.id] }.filter { $0 > 0 }
            if parts.isEmpty || parts.reduce(0, +) != s.fortune {
                segs.append(ChartSeg(id: s.id, player: label, points: s.fortune, shade: 0))
            } else {
                for (i, p) in parts.enumerated() {
                    segs.append(ChartSeg(id: "\(s.id)-\(i)", player: label, points: p, shade: i % 2))
                }
            }
        }
        return UMLeaderboardCard(title: "Top fortune · score by game") {
            Chart(segs) { seg in
                BarMark(x: .value("Fortune", seg.points), y: .value("Player", seg.player), height: .ratio(0.7))
                    .foregroundStyle(seg.shade == 0 ? UMLeaderboardStyle.fortune : Color(red: 0.86, green: 0.58, blue: 0.18))
                    .cornerRadius(2)
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white) } }
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(UMTheme.line); AxisValueLabel() } }
            .frame(height: CGFloat(top.count) * 26 + 24)
            Text("Each segment is one winning game. Losers earn 0.")
                .font(.caption2).foregroundStyle(UMTheme.muted)
        }
    }

    private func standingsCard(_ d: UMRoundDetail) -> some View {
        let projected = !d.round.accounted
        let limit = showAllStandings ? d.standings.count : (wide ? 20 : 12)
        return UMLeaderboardCard(title: "Round \(d.round.ref.number) standings · \(d.standings.count) players") {
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
                ForEach(d.standings.prefix(limit)) { s in
                    standingRow(s)
                    Divider().overlay(UMTheme.line)
                }
            }
            if d.standings.count > limit || showAllStandings {
                Button(showAllStandings ? "Show fewer" : "Show all \(d.standings.count)") {
                    withAnimation { showAllStandings.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            if projected {
                Text("* Projected. Prestige is paid when the round is accounted after review; until then these results can still change.")
                    .font(.caption2).foregroundStyle(UMTheme.muted)
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

    private func scoreCard(_ d: UMRoundDetail) -> some View {
        let games = d.games ?? []
        let shown = wide ? 12 : 6
        return UMLeaderboardCard(title: "Score by game · \(games.count) games") {
            ForEach(games.prefix(shown)) { g in
                let winners = g.earned.filter { $0.value > 0 }.sorted { $0.value > $1.value }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(g.setupName).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 0)
                        if let me = service.meId, let pts = g.earned[me] {
                            Text(pts > 0 ? "You +\(pts)" : "You 0")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(pts > 0 ? UMLeaderboardStyle.you : UMTheme.muted)
                        }
                    }
                    Text("Day \(g.day) · \(g.endTime.formatted(date: .abbreviated, time: .shortened)) · \(g.earned.count) players")
                        .font(.caption2).foregroundStyle(UMTheme.muted).lineLimit(1)
                    Text(winners.isEmpty ? "No fortune paid" :
                            winners.prefix(4).map { "\(name($0.key)) +\($0.value)" }.joined(separator: ", ")
                            + (winners.count > 4 ? " +\(winners.count - 4) more" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UMLeaderboardStyle.fortune)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
                Divider().overlay(UMTheme.line)
            }
            if games.count > shown {
                Text("+ \(games.count - shown) more games").font(.caption2).foregroundStyle(UMTheme.muted)
            }
        }
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
                        Text("Games expired. Season order below shows where everyone finished.")
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

    // MARK: Season standings

    @ViewBuilder
    private var seasonSection: some View {
        sectionTitle("Season \(seasonNo ?? 0) standings").id("season")
        let rows = seasonRows
        UMLeaderboardCard(title: provisional ? "Provisional · includes projected prestige" : "Final") {
            Picker("Sort", selection: $sortByFortune) {
                Text("Prestige").tag(false)
                Text("Top fortune").tag(true)
            }
            .pickerStyle(.segmented)
            if rows.isEmpty {
                Text("No prestige has been paid this season yet.").font(.footnote).foregroundStyle(UMTheme.muted)
            } else {
                let top = Array(rows.prefix(8))
                Chart(top) { r in
                    BarMark(x: .value(sortByFortune ? "Fortune" : "Prestige", sortByFortune ? r.tiebreakerFortune : r.prestige),
                            y: .value("Player", r.player.name), height: .ratio(0.7))
                        .foregroundStyle(sortByFortune ? UMLeaderboardStyle.fortune : UMLeaderboardStyle.prestige)
                        .cornerRadius(2)
                }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white) } }
                .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(UMTheme.line); AxisValueLabel() } }
                .frame(height: CGFloat(top.count) * 24 + 24)
                .animation(.snappy, value: sortByFortune)
                HStack(spacing: 10) {
                    Text("#").frame(width: 32)
                    Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Fortune").frame(width: 66, alignment: .trailing)
                    Text(provisional ? "Prestige*" : "Prestige").frame(width: 64, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(UMTheme.muted)
                ForEach(Array(rows.prefix(15).enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 10) {
                        UMRankBadge(ranking: i + 1).frame(width: 32)
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
                    .padding(.vertical, 3)
                }
                Text(provisional
                     ? "* Includes prestige the unaccounted round would pay at today's ranking. Final when it's accounted."
                     : "Ranked by prestige; fortune breaks ties. Top 3 earn season trophies.")
                    .font(.caption2).foregroundStyle(UMTheme.muted)
            }
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
