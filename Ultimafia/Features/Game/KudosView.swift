import SwiftUI

enum KudosAccent {
    static let orange = Color(red: 255 / 255, green: 140 / 255, blue: 0)
    static func row(_ key: String) -> Color { Color(umHex: KudosPolicy.rowColorHex(key)) ?? Color(white: 0.83) }
}

struct KudosIcon: View {
    var size: CGFloat = 16
    var title: String = "Received kudos"

    var body: some View {
        Image("Kudos")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(title)
    }
}

/// Circular paper backing, used as a badge on player-list avatars and lineup tiles.
struct KudosBadge: View {
    var size: CGFloat = 18

    var body: some View {
        KudosIcon(size: size * 0.78, title: "Received kudos")
            .padding(2)
            .background(Circle().fill(UMTheme.card))
            .overlay(Circle().stroke(KudosAccent.orange.opacity(0.85), lineWidth: 1))
            .accessibilityLabel("Received kudos")
    }
}

/// Voting dock: sits between the transcript and the chat composer.
struct KudosDock: View {
    var session: GameSession
    var compact: Bool
    var maxHeight: CGFloat = 300
    /// Chat pane width minus dock padding; used for first-frame packing before measurement.
    var widthHint: CGFloat = 0

    @State private var confirming: Set<String> = []
    @State private var seenVotes: Set<String>?
    @State private var collapsed = false
    @State private var animationTask: Task<Void, Never>?
    @State private var groupsHeight: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var measured = false

    private var state: KudosState? { session.kudos }
    private var voteKey: String {
        (state?.myVotes.keys.sorted() ?? []).joined(separator: ",")
    }
    private var visible: Bool { KudosPolicy.showsDock(state: state) }
    private var lines: [[String]] {
        guard let state else { return [] }
        let width = containerWidth > 0 ? containerWidth : widthHint
        return KudosPolicy.visualLines(
            rows: state.rows,
            containerWidth: Double(width),
            onePerLine: compact,
            compactTiles: compact
        )
    }
    private var collapseSignature: String {
        guard let state else { return "" }
        return lines.map { line in
            line.map { key in
                KudosPolicy.isCollapsed(
                    key: key,
                    myVotes: state.myVotes,
                    lines: lines,
                    confirming: confirming
                ) ? "c:\(key)" : "e:\(key)"
            }.joined(separator: ",")
        }.joined(separator: "|")
    }

    var body: some View {
        Group {
        if visible, let state {
            VStack(spacing: 0) {
                header
                if !collapsed, state.testMode { testModeBanner }
                if !collapsed {
                    let cap = max(140, maxHeight - 48)
                    let duration = Double(KudosPolicy.collapseMilliseconds) / 1000
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(lines, id: \.self) { line in
                                lineView(line, state: state)
                            }
                        }
                        .animation(.easeInOut(duration: duration), value: collapseSignature)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if measured {
                                withAnimation(.easeInOut(duration: duration)) { groupsHeight = height }
                            } else {
                                groupsHeight = height
                                measured = true
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(groupsHeight > 0 ? groupsHeight : cap, cap), alignment: .top)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                UMTheme.card
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [KudosAccent.orange.opacity(0.16), KudosAccent.orange.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 40)
                    }
            }
            .overlay(alignment: .top) {
                Rectangle().fill(KudosAccent.orange).frame(height: 2)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: -3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kudos-dock")
            .accessibilityLabel("Kudos")
        }
        }
        // Adopt votes whenever the payload's myVotes set changes, including the first appearance.
        .onAppear { adoptVotes() }
        .onChange(of: voteKey) { _, _ in adoptVotes() }
        .onDisappear { animationTask?.cancel() }
    }

    @ViewBuilder
    private func lineView(_ line: [String], state: KudosState) -> some View {
        let rows = line.compactMap { key in state.rows.first(where: { $0.key == key }) }
        let allCollapsed = rows.allSatisfy { row in
            KudosPolicy.isCollapsed(
                key: row.key,
                myVotes: state.myVotes,
                lines: lines,
                confirming: confirming
            )
        }
        if allCollapsed {
            VStack(spacing: 4) {
                ForEach(rows, id: \.key) { row in
                    KudosCollapsedSummary(session: session, state: state, row: row)
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                removal: .opacity
            ))
        } else {
            HStack(alignment: .top, spacing: compact ? 6 : 8) {
                ForEach(rows, id: \.key) { row in
                    KudosLineupRow(
                        session: session,
                        state: state,
                        row: row,
                        phase: confirming.contains(row.key) ? .confirm : .open,
                        compact: compact,
                        onVote: { session.sendKudosVote(row: $0, target: $1) }
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            KudosIcon(size: 20, title: "Kudos")
            Text("Give Kudos")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UMTheme.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand kudos" : "Minimize kudos")
            .accessibilityIdentifier("kudos-collapse")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, collapsed ? 8 : 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed = false }
            }
        }
        .accessibilityIdentifier("kudos-dock-header")
    }

    private var testModeBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "flask")
                .font(.system(size: 12, weight: .semibold))
            Text("Test mode: kudos won't be saved")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(red: 1, green: 0.84, blue: 0))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1, green: 0.84, blue: 0).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color(red: 1, green: 0.84, blue: 0).opacity(0.55))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .accessibilityIdentifier("kudos-testmode")
    }

    private func adoptVotes() {
        guard let state else { return }
        if seenVotes == nil {
            // Already-locked rows skip confirm and collapse immediately if their line is fully voted.
            seenVotes = Set(state.myVotes.keys)
            return
        }
        let fresh = KudosPolicy.newlyLockedRows(seen: seenVotes!, myVotes: state.myVotes)
        guard !fresh.isEmpty else { return }
        seenVotes!.formUnion(fresh)
        confirming.formUnion(fresh)
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            #if DEBUG
            // `-UMDiagKudosHold`: freeze the "Kudos locked in" confirm for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-UMDiagKudosHold") { return }
            #endif
            let confirm = UInt64(KudosPolicy.confirmMilliseconds) * 1_000_000
            try? await Task.sleep(nanoseconds: confirm)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Double(KudosPolicy.collapseMilliseconds) / 1000)) {
                confirming.subtract(fresh)
            }
        }
    }
}

private struct KudosCollapsedSummary: View {
    var session: GameSession
    var state: KudosState
    var row: KudosRow

    var body: some View {
        let vote = state.myVotes[row.key] ?? ""
        let pickedName = session.player(for: vote)?.name
        let label = KudosPolicy.voteSummary(target: vote, playerName: pickedName)
        let color = KudosAccent.row(row.key)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 4, height: 12)
            Text(row.label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(color)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(KudosAccent.orange)
            if vote == KudosTarget.noOne {
                Image(systemName: "nosign")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KudosAccent.orange)
                Text("No one")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            } else if let player = session.player(for: vote) {
                UMAvatarView(
                    userId: player.userId,
                    hasAvatar: player.avatar,
                    name: player.name,
                    size: 22,
                    square: true,
                    deckPath: player.deckAvatarPath
                )
                PlayerNameView(player: player, fontSize: 13)
                if KudosPolicy.isAwarded(state, playerId: vote) {
                    KudosBadge(size: 14)
                }
            } else {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.02))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(color.opacity(0.33)).frame(height: 2)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kudos-row-collapsed")
        .accessibilityLabel("\(row.label): voted \(label)")
    }
}

private struct KudosLineupRow: View {
    var session: GameSession
    var state: KudosState
    var row: KudosRow
    var phase: KudosRowPhase
    var compact: Bool
    var onVote: (String, String) -> Void

    private var myVote: String? { state.myVotes[row.key] }
    private var locked: Bool { myVote != nil }
    private var awarded: [String] { KudosPolicy.awardedIdsInRow(state, key: row.key) }
    private var color: Color { KudosAccent.row(row.key) }
    private var tileSize: CGFloat { compact ? 50 : 56 }
    private var tileWidth: CGFloat { compact ? 92 : 108 }
    private var tileGap: CGFloat { compact ? 6 : 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tileGap) {
                    ForEach(row.candidates, id: \.self) { id in
                        tile(id)
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            noOneButton
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.02))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(color.opacity(0.33)).frame(height: 2)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        }
        .overlay {
            if phase == .confirm {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(KudosAccent.orange.opacity(0.55), lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("kudos-row")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 4, height: 12)
            Text(row.label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(color)
            if !awarded.isEmpty {
                Text(awardedNames + " received kudos!")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KudosAccent.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("kudos-row-awarded")
            }
            Spacer(minLength: 4)
            if locked {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text(phase == .confirm ? "Kudos locked in" : "Voted")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(KudosAccent.orange)
                .fixedSize()
            }
        }
        .frame(minHeight: 18)
    }

    private var awardedNames: String {
        awarded.map { session.player(for: $0)?.name ?? "?" }.joined(separator: ", ")
    }

    private func tile(_ id: String) -> some View {
        let player = session.player(for: id)
        let name = player?.name ?? "?"
        let isSelf = KudosPolicy.isSelf(id, selfId: session.selfId)
        let selected = myVote == id
        let clickable = KudosPolicy.isTileClickable(state: state, rowKey: row.key, target: id, selfId: session.selfId)
        let dimmed = KudosPolicy.isTileDimmed(state: state, rowKey: row.key, target: id, selfId: session.selfId)
        let opacity: Double = isSelf ? 0.45 : (dimmed ? 0.5 : 1)
        let role = session.kudosRole(for: id)

        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                if let player {
                    PlayerNameView(player: player, fontSize: 12)
                        .lineLimit(1)
                } else {
                    Text(name).font(.system(size: 12)).lineLimit(1).foregroundStyle(.white)
                }
                if let role, !role.isEmpty {
                    RoleIconView(role: role, gameType: session.gameType ?? "Mafia", size: 18)
                        .accessibilityIdentifier("kudos-role")
                }
            }
            .frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .center)

            ZStack(alignment: .topTrailing) {
                avatar(player, name: name, selected: selected, clickable: clickable, isSelf: isSelf) {
                    if clickable { onVote(row.key, id) }
                }
                if KudosPolicy.isAwarded(state, playerId: id) {
                    KudosBadge(size: compact ? 16 : 18)
                        .offset(x: 6, y: -4)
                        .accessibilityIdentifier("kudos-tile-awarded")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(width: tileWidth)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? KudosAccent.orange.opacity(0.14) : Color.white.opacity(0.035))
        )
        .opacity(opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kudos-tile")
        .accessibilityLabel(isSelf ? "\(name), you. You Cannot Kudo Yourself!" : "Give kudos to \(name)")
        .accessibilityAddTraits(clickable ? .isButton : [])
        .accessibilityHint(isSelf ? "You Cannot Kudo Yourself!" : "")
    }

    private func avatar(_ player: GamePlayer?, name: String, selected: Bool, clickable: Bool, isSelf: Bool, action: @escaping () -> Void) -> some View {
        let portrait = Group {
            if let player {
                // Site kudos tiles force a square portrait.
                UMAvatarView(userId: player.userId, hasAvatar: player.avatar, name: player.name,
                             size: tileSize, square: true, deckPath: player.deckAvatarPath)
            } else {
                UMAvatarView(userId: nil, hasAvatar: false, name: name, size: tileSize, square: true)
            }
        }
        return Button(action: action) {
            portrait
                .padding(2)
                .overlay {
                    let shape = RoundedRectangle(cornerRadius: tileSize * 0.18 + 2)
                    shape.strokeBorder(selected ? KudosAccent.orange : Color.clear, lineWidth: 2)
                }
                .shadow(color: selected ? KudosAccent.orange.opacity(0.45) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .disabled(!clickable)
        .accessibilityHidden(true)
    }

    private var noOneButton: some View {
        let selected = myVote == KudosTarget.noOne
        let clickable = KudosPolicy.isTileClickable(state: state, rowKey: row.key, target: KudosTarget.noOne, selfId: session.selfId)
        return Button {
            if clickable { onVote(row.key, KudosTarget.noOne) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "nosign")
                    .font(.system(size: 11, weight: .semibold))
                Text("No one")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? KudosAccent.orange : (clickable ? UMTheme.muted : UMTheme.muted.opacity(0.55)))
            .background(selected ? KudosAccent.orange.opacity(0.14) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(selected ? KudosAccent.orange : Color.white.opacity(clickable ? 0.22 : 0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(!clickable)
        .accessibilityIdentifier("kudos-noone")
        .accessibilityLabel("No one")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Kudos Awarded:" list at the top of the Actions pane. Hidden until someone is awarded.
struct KudosAwardedPanel: View {
    var session: GameSession
    @Environment(AppModel.self) private var app

    private var ids: [String] {
        guard let kudos = session.kudos else { return [] }
        return KudosPolicy.awardedIds(kudos)
    }

    var body: some View {
        if !session.isReview, !ids.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kudos Awarded:")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("kudos-awarded-title")
                ForEach(ids, id: \.self) { id in
                    let player = session.player(for: id)
                    let name = player?.name ?? "?"
                    Button {
                        if let uid = player?.userId, !uid.isEmpty {
                            app.openProfile(id: uid, name: name)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            KudosIcon(size: 16, title: "Kudos")
                            if let player {
                                UMAvatarView(player: player, size: 22)
                                PlayerNameView(player: player, fontSize: 14)
                                    .lineLimit(1)
                            } else {
                                Text(name).font(.subheadline).foregroundStyle(.white).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(player?.userId == nil)
                    .accessibilityIdentifier("kudos-awarded-name")
                    .accessibilityLabel("\(name) received kudos")
                }
            }
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("kudos-panel")
        }
    }
}
