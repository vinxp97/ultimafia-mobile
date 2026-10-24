import SwiftUI

struct PhaseBar: View {
    var session: GameSession

    var body: some View {
        let phases = session.sortedPhases
        HStack(spacing: 4) {
            Button {
                session.viewAdjacentPhase(delta: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.bold))
                    .frame(width: 32, height: 32)
            }
            .disabled(phases.first?.id == session.viewingPhaseId)
            .foregroundStyle(phases.first?.id == session.viewingPhaseId ? UMTheme.muted : .white)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(phases) { phase in
                            Button {
                                session.viewPhase(phase.id)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: Self.icon(for: phase.name))
                                        .font(.title3)
                                        .foregroundStyle(phase.id == session.viewingPhaseId ? UMTheme.blood : UMTheme.muted)
                                        .frame(width: 32, height: 28)
                                    Text(Self.shortLabel(phase))
                                        .font(.caption2.weight(phase.id == session.viewingPhaseId ? .bold : .regular))
                                        .foregroundStyle(phase.id == session.viewingPhaseId ? .white : UMTheme.muted)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(phase.id)
                            .opacity(phase.id == session.viewingPhaseId ? 1 : 0.55)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: session.viewingPhaseId) { _, id in
                    proxy.scrollTo(id, anchor: .center)
                }
            }

            Button {
                session.viewAdjacentPhase(delta: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
                    .frame(width: 32, height: 32)
            }
            .disabled(phases.last?.id == session.viewingPhaseId)
            .foregroundStyle(phases.last?.id == session.viewingPhaseId ? UMTheme.muted : .white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(UMTheme.card)
    }

    static func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("pregame") { return "house.fill" }
        if n.contains("night") { return "moon.fill" }
        if n.contains("day") { return "sun.max.fill" }
        if n.contains("dawn") { return "sunrise.fill" }
        if n.contains("dusk") { return "sunset.fill" }
        if n.contains("post") { return "flag.checkered" }
        return "circle.fill"
    }

    static func shortLabel(_ phase: GamePhase) -> String {
        let n = phase.name
        if let day = phase.dayCount, n == "Day" || n == "Night" {
            return "\(n) \(day)"
        }
        if n.lowercased() == "pregame" { return "Pre" }
        return n
    }
}

/// iPad one-row header: at most `visible` phase chips; chevrons or a horizontal swipe page to
/// older/newer phases. Follows the newest phase unless the user paged back.
struct PagedPhaseBar: View {
    var session: GameSession
    var visible = 6
    /// nil = pinned to the newest page.
    @State private var start: Int?

    var body: some View {
        let phases = session.sortedPhases
        let maxStart = max(0, phases.count - visible)
        let s = min(start ?? maxStart, maxStart)
        let window = phases.isEmpty ? [] : Array(phases[s..<min(phases.count, s + visible)])
        HStack(spacing: 2) {
            Button { page(-1, s, maxStart) } label: {
                Image(systemName: "chevron.left").font(.footnote.weight(.bold)).frame(width: 22, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(s == 0)
            .foregroundStyle(s == 0 ? UMTheme.muted.opacity(0.4) : .white)
            .accessibilityLabel("Older phases")

            HStack(spacing: 8) {
                ForEach(window) { phase in
                    let on = phase.id == session.viewingPhaseId
                    Button { session.viewPhase(phase.id) } label: {
                        VStack(spacing: 1) {
                            Image(systemName: PhaseBar.icon(for: phase.name))
                                .font(.body)
                                .foregroundStyle(on ? UMTheme.blood : UMTheme.muted)
                                .frame(width: 28, height: 22)
                            Text(PhaseBar.shortLabel(phase))
                                .font(.caption2.weight(on ? .bold : .regular))
                                .foregroundStyle(on ? .white : UMTheme.muted)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(on ? 1 : 0.55)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { v in
                    if v.translation.width < -30 { page(1, s, maxStart) }
                    else if v.translation.width > 30 { page(-1, s, maxStart) }
                }
            )
            .animation(.snappy(duration: 0.2), value: s)

            Button { page(1, s, maxStart) } label: {
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).frame(width: 22, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(s >= maxStart)
            .foregroundStyle(s >= maxStart ? UMTheme.muted.opacity(0.4) : .white)
            .accessibilityLabel("Newer phases")
        }
        .onChange(of: session.viewingPhaseId) { _, id in reveal(id) }
    }

    private func page(_ delta: Int, _ s: Int, _ maxStart: Int) {
        let n = min(max(0, s + delta * visible), maxStart)
        start = n >= maxStart ? nil : n
    }

    /// Keep the viewed phase on screen when it changes elsewhere (bottom arrows, review, live).
    private func reveal(_ id: Int) {
        let phases = session.sortedPhases
        guard let i = phases.firstIndex(where: { $0.id == id }) else { return }
        let maxStart = max(0, phases.count - visible)
        let s = min(start ?? maxStart, maxStart)
        var n = s
        if i < s { n = i } else if i >= s + visible { n = i - visible + 1 }
        start = n >= maxStart ? nil : n
    }
}

struct RoleRevealOverlay: View {
    var session: GameSession

    var body: some View {
        if session.showRoleReveal, let role = session.selfRoleName {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text("Your role is")
                        .font(.subheadline)
                        .foregroundStyle(UMTheme.muted)
                    Text(role)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(UMTheme.blood)
                    if !session.selfRoleModifiers.isEmpty {
                        Text(session.selfRoleModifiers.joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(UMTheme.muted)
                    }
                    if let cat = session.selfRoleCategory {
                        Text(cat)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(UMTheme.muted)
                    }
                    if !session.teammates.isEmpty {
                        VStack(spacing: 8) {
                            Text("Your teammates")
                                .font(.subheadline.weight(.semibold))
                            ForEach(session.teammates) { mate in
                                HStack(spacing: 8) {
                                    UMAvatarView(player: mate, size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        PlayerNameView(player: mate, fontSize: 16, dead: session.currentPhaseId != -2 && session.isDead(mate.id))
                                        if let r = session.knownRoles[mate.id] {
                                            Text(r.split(separator: ":").first.map(String.init) ?? r)
                                                .font(.caption2)
                                                .foregroundStyle(UMTheme.muted)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    Button("OK") {
                        session.showRoleReveal = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(UMTheme.blood)
                    .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: 360)
                .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 18))
                .padding(28)
            }
        }
    }
}

struct TypingStrip: View {
    var session: GameSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Color.clear
                        .frame(width: 1, height: 22)
                        .id("typing-start")
                    ForEach(session.typingPlayers) { player in
                        HStack(spacing: 4) {
                            UMAvatarView(player: player, size: 22)
                            PulsingDots()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(UMTheme.card, in: Capsule())
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            .background(UMTheme.elevated)
            .onChange(of: session.typingPlayerIds) { old, ids in
                if ids.isEmpty || ids.count < old.count {
                    proxy.scrollTo("typing-start", anchor: .leading)
                }
            }
        }
    }
}

struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = (sin(t * 5.5 + Double(i) * 0.7) + 1) / 2
                    Circle()
                        .fill(.white.opacity(0.35 + 0.65 * wave))
                        .frame(width: 5, height: 5)
                        .offset(y: -2.5 * wave)
                }
            }
            .frame(width: 22, height: 12)
        }
    }
}


struct PhaseTimerBadge: View {
    var session: GameSession
    /// Compact game header: a Liquid Glass capsule, tinted for the warning clocks.
    var glass = false
    /// Tap the clock: scroll the chat to the top of the phase (game header).
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { clock }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Scrolls the chat to the top of this phase")
                .accessibilityAddTraits(.isButton)
        } else {
            clock
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let kind = session.clockKind
            let text = format(session.clockRemainingMs(at: context.date))
            if glass {
                Text(text)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(foreground(kind))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .glassEffect(kind == .normal ? .regular : .regular.tint(border(kind).opacity(0.3)), in: .capsule)
                    .overlay {
                        if kind != .normal {
                            Capsule().strokeBorder(border(kind), style: StrokeStyle(lineWidth: 1.5, dash: dashes(kind)))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Time left")
                    .accessibilityValue(text)
            } else {
            Text(text)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(foreground(kind))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(UMTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(border(kind), style: StrokeStyle(lineWidth: 1.5, dash: dashes(kind)))
                )
            }
        }
    }

    private func format(_ ms: Double?) -> String {
        guard let ms else { return "--:--" }
        let total = max(0, Int((ms / 1000).rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func foreground(_ kind: ClockKind) -> Color {
        switch kind {
        case .vegKick, .vegKickCountdown: return UMTheme.mafia
        case .secondary: return Color(red: 0.93, green: 0.54, blue: 0.05)
        case .normal: return .white
        }
    }

    private func border(_ kind: ClockKind) -> Color {
        switch kind {
        case .vegKick, .vegKickCountdown: return UMTheme.mafia
        case .secondary: return Color(red: 0.93, green: 0.54, blue: 0.05)
        case .normal: return UMTheme.line
        }
    }

    private func dashes(_ kind: ClockKind) -> [CGFloat] {
        switch kind {
        case .secondary, .vegKickCountdown: return [5, 3]
        default: return []
        }
    }
}

/// A glass disc with an SF Symbol, sized for a 44 pt hit target (or drawn smaller inside one).
struct GlassCircleLabel: View {
    var systemName: String
    var diameter: CGFloat = 44
    var hitSize: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: max(hitSize, diameter), height: max(hitSize, diameter))
            .contentShape(Circle())
    }
}

/// Compact game header phase row: the viewed phase (icon + name) on a glass capsule, with glass
/// previous / next circles. An arrow is drawn only when there is a phase that way (a same-size
/// clear slot keeps the capsule centred). The capsule opens a menu of every phase, which keeps the
/// old bar's "tap any phase" jump. Navigation goes through the same session calls as before.
struct GlassPhaseNavigator: View {
    var session: GameSession

    /// Phase capsule only: tap opens the jump-to-phase menu; previous / next is a sideways swipe on
    /// the chat (UMPhaseSwipeBridge), and VoiceOver gets adjustable + named actions for both.
    var body: some View {
        let phases = session.sortedPhases
        let index = phases.firstIndex { $0.id == session.viewingPhaseId }
        let current = index.map { phases[$0] } ?? phases.last
        Menu {
            ForEach(phases) { phase in
                Button {
                    session.viewPhase(phase.id)
                } label: {
                    Label(PhaseBar.shortLabel(phase) + (phase.id == session.currentPhaseId ? " (now)" : ""),
                          systemImage: PhaseBar.icon(for: phase.name))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let current {
                    Image(systemName: PhaseBar.icon(for: current.name))
                        .foregroundStyle(session.isViewingLive ? UMTheme.blood : UMTheme.muted)
                    Text(PhaseBar.shortLabel(current))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if !session.isViewingLive {
                    Text("past")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(UMTheme.muted)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minWidth: 96, minHeight: 36)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Phase")
        .accessibilityValue(current.map { PhaseBar.shortLabel($0) + (session.isViewingLive ? "" : ", past phase") } ?? "")
        .accessibilityHint("Choose a phase to view. Swipe the chat sideways to change phase.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.swipeToAdjacentPhase(delta: 1)
            case .decrement: session.swipeToAdjacentPhase(delta: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Previous phase") { session.swipeToAdjacentPhase(delta: -1) }
        .accessibilityAction(named: "Next phase") { session.swipeToAdjacentPhase(delta: 1) }
        .frame(maxWidth: .infinity)
    }
}
