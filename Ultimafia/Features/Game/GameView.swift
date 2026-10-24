import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct GameView: View {
    @Environment(AppModel.self) private var app
    var review = false
    @State private var draft = ""
    @State private var selectedPanel = 0
    /// Composer focus (UIKit-backed field; Return never resigns first responder).
    @State private var chatFocused = false

    var body: some View {
        Group {
            if review, let session = app.reviewSession {
                GameScreen(
                    session: session,
                    draft: $draft,
                    selectedPanel: $selectedPanel,
                    chatFocused: $chatFocused,
                    onLeave: { app.closeReview() },
                    onDetach: { app.closeReview() }
                )
            } else if !review, let session = app.game {
                GameScreen(
                    session: session,
                    draft: $draft,
                    selectedPanel: $selectedPanel,
                    chatFocused: $chatFocused,
                    // One owner for the rule: requestLeave confirms when participation is still
                    // required and leaves outright otherwise.
                    onLeave: { app.requestLeave() },
                    onDetach: { app.detachFromGame() }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(UMTheme.bg.ignoresSafeArea())
            }
        }
    }
}

private struct GameScreen: View {
    @Environment(AppModel.self) private var app
    var session: GameSession
    @Binding var draft: String
    @Binding var selectedPanel: Int
    var chatFocused: Binding<Bool>
    var onLeave: () -> Void
    var onDetach: () -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Height of the floating glass header (compact layouts); the panes reserve it as a top inset
    /// so their content scrolls underneath the glass without anything being stuck behind it.
    @State private var headerHeight: CGFloat = 0
    /// The game screen hides the status bar only while it is the screen on show; any other tab,
    /// a pushed profile or the lobby gets it back.
    @State private var isOnScreen = false

    var body: some View {
        GeometryReader { geo in
            #if os(macOS)
            let regular = true   // Mac windows are always "regular"; width alone picks the layout
            #else
            let regular = hSizeClass == .regular
            #endif
            let threeColumns = UMGameLayout.usesThreeColumns(geo.size, regular: regular)
            let wideHeader = UMGameLayout.usesWideHeader(geo.size.width, regular: regular)
            // Compact layouts (iPhone, narrow iPad windows): the header is Liquid Glass floating over
            // the panes, so the chat scrolls underneath it. The wide iPad header stays a solid row.
            let floating = !wideHeader
            let topInset = floating ? headerHeight : 0
            // returnToLobby keeps a seated player's connection (the Lobby tab action does the
            // same) and closes spectators and reviews, so the header always has a way out.
            let header = GameHeader(session: session, wide: wideHeader, onClose: returnToLobby, onLeave: onLeave,
                           // requestLeave: pregame leaves at once (no lock, no overlay); a started game shows LeaveConfirmOverlay.
                           onLeavePrompt: { app.requestLeave() },
                           showsGuides: threeColumns)
            VStack(spacing: 0) {
                if !floating {
                    header
                    Divider().overlay(UMTheme.line)
                }
                Group {
                    if threeColumns {
                        // iPad landscape: Village 25% | Chat 50% | Act 25%, each scrolling on its own.
                        // selectedPanel is kept untouched so rotating back restores the same tab.
                        HStack(spacing: 0) {
                            GameTownPane(session: session, compact: true)
                                .frame(width: UMGameLayout.sideColumnWidth(geo.size.width))
                            Divider().overlay(UMTheme.line)
                            GameChatPane(session: session, draft: $draft, chatFocused: chatFocused, showsPhaseBar: false)
                                .frame(maxWidth: .infinity)
                            Divider().overlay(UMTheme.line)
                            GameActPane(session: session)
                                .frame(width: UMGameLayout.sideColumnWidth(geo.size.width))
                        }
                    } else {
                        // Every panel stays in the hierarchy, so leaving the chat and coming back keeps
                        // its scroll view and where it was. A `switch` here tore the chat pane down,
                        // and rebuilding it started at the top: that is only corrected when you were
                        // following, which is why reading in the middle put you back at the top. Only
                        // the selected panel is drawn and hit-testable, and the chat stops recording
                        // what is on screen while it is hidden.
                        ZStack {
                            GameTownPane(session: session)
                                .safeAreaPadding(.top, topInset)
                                .opacity(selectedPanel == 1 ? 1 : 0)
                                .allowsHitTesting(selectedPanel == 1)
                                .accessibilityHidden(selectedPanel != 1)
                            GameActPane(session: session)
                                .safeAreaPadding(.top, topInset)
                                .opacity(selectedPanel == 2 ? 1 : 0)
                                .allowsHitTesting(selectedPanel == 2)
                                .accessibilityHidden(selectedPanel != 2)
                            GameChatPane(
                                session: session,
                                draft: $draft,
                                chatFocused: chatFocused,
                                showsPhaseBar: false,
                                isOnScreen: selectedPanel == 0,
                                topInset: topInset
                            )
                            .opacity(selectedPanel == 0 ? 1 : 0)
                            .allowsHitTesting(selectedPanel == 0)
                            .accessibilityHidden(selectedPanel != 0)
                        }
                        .onChange(of: selectedPanel) { _, panel in
                            // Leaving the chat puts the keyboard away, the way the old teardown did.
                            if panel != 0 { chatFocused.wrappedValue = false }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if floating {
                        header
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                                if abs(headerHeight - h) > 0.25 { headerHeight = h }
                            }
                    }
                }
                GamePanelPicker(session: session, selectedPanel: $selectedPanel, showsPanelTabs: !threeColumns)
            }
        }
        .background(UMTheme.bg.ignoresSafeArea())
        .background { gameShortcuts }
        #if os(iOS)
        // iPhone / iPad: the game is full-bleed; the clock and battery come back everywhere else.
        .statusBarHidden(isOnScreen)
        #endif
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .umNavigationBar(.hidden)
        .navigationBarBackButtonHidden(true)
        .alert("Game", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
        .onChange(of: session.displaced) { _, displaced in
            if displaced { onDetach() }
        }
        .onAppear { UMDiag.log("view", "game screen appear \(session.gameId)") }
        .onDisappear { UMDiag.log("view", "game screen disappear \(session.gameId)") }
        .task { await RoleCatalog.shared.load(); UMSpeechLM.prepareIfNeeded() }
        // Warm the on-disk custom asset cache: own maps once, then every player's maps/avatars.
        .task(id: session.players.count) { await prefetchCustomAssets() }
        // Hold every avatar / role icon / emote this game can show, decoded, until the session
        // closes (AppModel unpins on leave, detach, review close), so phases never refetch.
        .task(id: "\(session.players.count)|\(session.setupId ?? "")|\(session.setupRolesets.count)") {
            await UMImageCache.shared.pin(session.assetURLs, scope: session.assetScope)
        }
        // Whether the bar is showing is the AppModel's single decision (`showsAppTabs`), not
        // something this screen toggles; all the screen owns is whether the game is being watched.
        .onAppear {
            if !session.isReview {
                app.isViewingGame = true
                app.mentionCount = 0
            }
        }
        .onDisappear { if !session.isReview { app.isViewingGame = false } }
    }

    private func returnToLobby() {
        // Only spectators/reviews close their session. Seated players keep the existing
        // connection and its chat/phase memory, exactly like the main Lobby tab action.
        if session.isReview || session.spectate { onDetach() }
        else { app.goToLobby() }
    }

    /// Option+Left/Right: phases; Option+Up/Down: chat top/latest. Hidden buttons so the
    /// shortcuts show in the iPad Cmd-hold overlay; the composer claims the same keys while typing.
    private var gameShortcuts: some View {
        ZStack {
            shortcutButton(.previousPhase, .leftArrow)
            shortcutButton(.nextPhase, .rightArrow)
            shortcutButton(.chatTop, .upArrow)
            shortcutButton(.chatBottom, .downArrow)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(_ s: UMGameShortcut, _ key: KeyEquivalent) -> some View {
        Button(s.title) { session.performShortcut(s) }
            .keyboardShortcut(key, modifiers: .option)
    }

    private func prefetchCustomAssets() async {
        var paths = Array(app.myCustomEmotes.values) + Array(app.myCustomStickers.values)
        var urls: [URL] = []
        for p in session.players {
            paths += Array(p.customEmotes.values) + Array(p.customStickers.values)
            if let path = p.deckAvatarPath, let u = UMAvatarURL.deck(path: path) { urls.append(u) }
            else if p.avatar, let id = p.userId, !id.isEmpty, let u = UMAvatarURL.live(userId: id) { urls.append(u) }
        }
        urls += paths.compactMap(UMMediaURL.resolve)
        urls += UMDeckCache.avatarURLs(deckIds: session.anonymousDeckIds)
        await UMCustomAssetCache.shared.prefetch(urls)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil; onDetach() } }
        )
    }
}

/// Game screen layout by window, not device: a compact-width window (iPhone, iPad Slide Over,
/// narrow Split View / Stage Manager windows) gets the tabbed iPhone layout; a regular-width
/// window gets the iPad layout. Re-evaluated live as the window is resized.
enum UMGameLayout {
    /// Three columns in a regular-width, landscape-shaped window wide enough for ~340 pt side
    /// columns (full screen 11"/13"; narrower windows keep the tabs).
    static func usesThreeColumns(_ size: CGSize, regular: Bool) -> Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
        // Mac: desktop-style table (players | chat | actions) whenever the window is wide enough,
        // whatever its shape; the minimum window (1100 pt) always qualifies.
        return regular && size.width >= 980
        #else
        return regular && size.width > size.height && size.width >= 1000
        #endif
    }

    /// Side column width in three-column mode. iPad keeps 25% each; Mac clamps so big windows
    /// give the extra room to the chat instead of stretching the player list and actions.
    static func sideColumnWidth(_ total: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return min(max(total * 0.25, 300), 440)
        #else
        return total * 0.25
        #endif
    }

    /// One-row header (name, roles, phases, timer) in a regular-width window when there's room.
    static func usesWideHeader(_ width: CGFloat, regular: Bool) -> Bool {
        regular && width >= 820
    }
}

private struct GameHeader: View {
    @Environment(AppModel.self) private var app
    var session: GameSession
    /// iPad: setup name, roles strip, paged phases and timer in one row.
    var wide = false
    var onClose: (() -> Void)? = nil
    var onLeave: (() -> Void)? = nil
    /// Long press on the back arrow: Leave confirmation (5 s lock while participation is required).
    var onLeavePrompt: (() -> Void)? = nil

    /// Seated in a live (or pregame) game: the back arrow also offers hold-to-leave.
    private var seated: Bool {
        !session.isReview && !session.spectate && !session.finished
            && session.players.contains { $0.id == session.selfId }
    }
    /// The panel row carries the guides where it is drawn; the three-column iPad layout has no row,
    /// so the header has to carry them instead.
    var showsGuides = false
    @AppStorage("um.showSetupGuides") private var showSetupGuides = true

    var body: some View {
        if wide { wideBody } else { compactBody }
    }

    /// Clock tap: the current phase's chat to its first message (what the old up-arrow did).
    private func scrollChatToTop() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        session.chatJumpTopTick &+= 1
    }

    /// Back / leave: a Liquid Glass circle with a chevron. Seated players keep tap = lobby and
    /// press-and-hold = Leave (same confirmation rules as before); everyone else gets tap only.
    @ViewBuilder private var backButton: some View {
        if let onClose {
            Group {
                if seated, let onLeavePrompt {
                    HoldToLeaveBackButton(onTap: onClose, onHold: onLeavePrompt)
                } else {
                    Button(action: onClose) {
                        GlassCircleLabel(systemName: "chevron.left", diameter: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.isReview ? "Back to games" : (session.spectate ? "Stop spectating" : "Return to lobby"))
                }
            }
        }
    }

    @ViewBuilder private var statusBadges: some View {
        if session.isReview {
            Text("REVIEW")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).frame(height: 26)
                .foregroundStyle(UMTheme.blood)
                .glassEffect(.regular.tint(UMTheme.blood.opacity(0.25)), in: .capsule)
        }
        if session.finished, !session.isReview {
            Text("Finished")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).frame(height: 26)
                .foregroundStyle(UMTheme.muted)
                .glassEffect(.regular, in: .capsule)
        }
        if session.readyCheckActive {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let left = max(0, Int(session.readyEndTime.timeIntervalSince(context.date).rounded(.up)))
                Text("Ready \(left)s")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(left < 10 ? UMTheme.mafia : UMTheme.village)
                    .padding(.horizontal, 8).frame(height: 26)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    /// iPhone (and iPad / Mac windows too narrow for the one-row header): two compact rows of
    /// Liquid Glass. Row 1: back circle, roles strip, status, timer. Row 2: phase capsule with
    /// previous / next circles (each shown only when there is a phase that way).
    private var compactBody: some View {
        // Spacing below the row gaps so the back circle, roles capsule and timer stay three
        // separate pieces of glass instead of melting into one bar.
        GlassEffectContainer(spacing: 2) {
            VStack(spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    backButton
                    if session.isLiarsDice {
                        Spacer(minLength: 8)
                    } else {
                        // One glass capsule for every role (centred, "…" at its right end).
                        SetupRoleStrip(session: session, inHeader: true)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                            .glassEffect(.regular, in: .capsule)
                            .layoutPriority(-1)
                    }
                    statusBadges
                    PhaseTimerBadge(session: session, glass: true, onTap: scrollChatToTop)
                    if showsGuides, showSetupGuides, session.setupId != nil {
                        SetupGuidesButton(session: session, fillsWidth: false)
                    }
                }
                if !session.isLiarsDice {
                    GlassPhaseNavigator(session: session)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    /// iPad one-row header (regular width, 820 pt+): unchanged apart from the glass back circle.
    private var wideBody: some View {
        HStack(alignment: .center, spacing: 8) {
            backButton
            if session.isReview {
                Text("REVIEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(UMTheme.blood.opacity(0.25), in: Capsule())
                    .foregroundStyle(UMTheme.blood)
            }
            Text(session.setupName ?? session.gameType ?? "Game")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: wide ? 220 : nil, alignment: .leading)
            if session.finished, !session.isReview {
                Text("Finished")
                    .font(.caption)
                    .foregroundStyle(UMTheme.muted)
            }
            if session.readyCheckActive {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let left = max(0, Int(session.readyEndTime.timeIntervalSince(context.date).rounded(.up)))
                    Text("Ready \(left)s")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(left < 10 ? UMTheme.mafia : UMTheme.village)
                }
            }
            if wide {
                Group { if session.isLiarsDice { Color.clear } else { SetupRoleStrip(session: session) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                if !session.isLiarsDice {
                    PagedPhaseBar(session: session, visible: 6)
                        .fixedSize()
                }
            } else {
                Spacer(minLength: 8)
            }
            PhaseTimerBadge(session: session, onTap: scrollChatToTop)
            if showsGuides, showSetupGuides, session.setupId != nil {
                SetupGuidesButton(session: session, fillsWidth: false)
            }
            // Leaving: long press the back arrow (tap returns to the lobby and keeps the session).
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(UMTheme.card)
    }
}

/// Game header back arrow, Haptic Touch style: a quick tap returns to the lobby (session stays);
/// press and hold ~0.4 s shrinks the arrow while held, then a firm haptic and the Leave confirmation.
/// A Button (reliable tap + press state) with a simultaneous long press; the tap is swallowed once the
/// hold has fired so releasing doesn't also go to the lobby. 44 pt hit target.
private struct HoldToLeaveBackButton: View {
    var onTap: () -> Void
    var onHold: () -> Void
    @State private var holdFired = false

    var body: some View {
        Button {
            if holdFired { holdFired = false; return }
            onTap()
        } label: {
            GlassCircleLabel(systemName: "chevron.left", diameter: 44)
        }
        .buttonStyle(HoldScaleButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    holdFired = true
                    UMHaptics.holdTriggered()
                    onHold()
                }
        )
        .accessibilityLabel("Return to lobby")
        .accessibilityHint("Press and hold to leave the game")
        .accessibilityAction(named: "Leave game", onHold)
    }
}

private struct HoldScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.4), value: configuration.isPressed)
    }
}

private struct GamePanelPicker: View {
    var session: GameSession
    @Binding var selectedPanel: Int
    var showsPanelTabs = true
    @AppStorage("um.showSetupGuides") private var showSetupGuides = true

    var body: some View {
        // Only drawn when there are panels to switch. The three-column iPad layout shows the panels
        // themselves, and this row used to render anyway holding just the guides button — which,
        // sizing to its content, left a lone grey capsule at the bottom that reads as a leftover tab
        // bar. On that layout the header carries the guides instead.
        if showsPanelTabs {
            HStack(spacing: 4) {
                tabBtn("Village", 1, "person.3")
                tabBtn("Chat", 0, "text.bubble")
                tabBtn(session.isLiarsDice ? "Dice" : "Act", 2, session.isLiarsDice ? "die.face.5" : "hand.raised")
                if showSetupGuides, session.setupId != nil { SetupGuidesButton(session: session) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(UMTheme.card)
        }
    }

    private func tabBtn(_ title: String, _ tag: Int, _ icon: String) -> some View {
        Button {
            selectedPanel = tag
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selectedPanel == tag ? UMTheme.elevated : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedPanel == tag ? .white : UMTheme.muted)
    }
}

/// The setup guides. The panel row gives it an equal share of the width; the header, where it goes
/// on the three-column iPad layout, wants a plain icon.
private struct SetupGuidesButton: View {
    var session: GameSession
    var fillsWidth = true
    @State private var showGuides = false

    var body: some View {
        Button { showGuides = true } label: {
            if fillsWidth {
                Label("Guides", systemImage: "book")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Image(systemName: "book")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(UMTheme.muted)
        .accessibilityLabel("Setup guides")
        .sheet(isPresented: $showGuides) {
            if let id = session.setupId {
                GuidesView(setupId: id, setupName: session.setupName, gameType: session.setupGameType,
                           otherRoles: session.guessableRoles.map(\.raw))
            }
        }
    }
}

/// Non-observed buffer so scroll-visibility callbacks coalesce into one state update per frame.
private final class VisibleIdBuffer {
    var pending: Set<String> = []
    var scheduled = false
}

private struct GameChatPane: View {
    var session: GameSession
    @Binding var draft: String
    var chatFocused: Binding<Bool>
    var showsPhaseBar = true
    /// False while another panel is showing. The pane stays alive so its position survives the
    /// switch, but it stops recording what the reader can see while it is off screen.
    var isOnScreen = true
    /// Room for the floating glass header: the transcript scrolls under it, but its first line,
    /// "top" and the jump buttons sit below it.
    var topInset: CGFloat = 0
    @AppStorage("um.chatLayout") private var chatLayout: ChatLayout = .standard
    @AppStorage("um.showTypingIndicator") private var showTypingIndicator = true
    @AppStorage("um.showVotingLog") private var showVotingLog = true
    @State private var transcriptScroll = UMTranscriptScrollController()
    @State private var unreadCount = 0
    @State private var composerOverlayHeight: CGFloat = 0
    @State private var visibleLineIds: Set<String> = []
    @State private var visibleBuffer = VisibleIdBuffer()
    /// Phase whose rows the scroll tracking belongs to. Only changed by the phase-switch handler, so
    /// visibility callbacks fired while the content swaps can't write the new rows into the old
    /// phase (or old-offset rows into the new one).
    @State private var trackedPhase: Int?
    /// True while a phase switch restores its position; tracking and auto-follow stand down.
    @State private var restoringScroll = false
    @State private var restoreGeneration = UUID()
    /// Pane width, for the phase swipe's distance threshold.
    @State private var paneWidth: CGFloat = 390

    private var chatLines: [ChatLine] {
        session.displayedMessages.filter { showVotingLog || !$0.isVoteLog }
    }

    /// Every line that has ever been on screen (or was already there when the chat opened).
    private var seenLineIds: Set<String> {
        get { session.chatSeenLineIds }
        nonmutating set { session.chatSeenLineIds = newValue }
    }

    private func markAllSeen() {
        seenLineIds.formUnion(chatLines.map(\.id))
    }

    private func noteVisibility(_ id: String, visible: Bool, phase: Int) {
        guard isOnScreen else { return }
        guard phase == trackedPhase, phase == session.viewingPhaseId else { return }
        let buffer = visibleBuffer
        if visible { buffer.pending.insert(id) } else { buffer.pending.remove(id) }
        guard !buffer.scheduled else { return }
        buffer.scheduled = true
        DispatchQueue.main.async {
            buffer.scheduled = false
            guard !restoringScroll, phase == trackedPhase, phase == session.viewingPhaseId else { return }
            guard buffer.pending != visibleLineIds else { return }
            visibleLineIds = buffer.pending
            let first = chatLines.first(where: { buffer.pending.contains($0.id) })?.id
            session.chatAnchorId = first
            if let first { session.phaseScrollAnchors[phase] = first }
            recomputeUnread()
        }
    }

    /// Unseen = live messages that have never been on screen. Reviews have no incoming messages.
    private func recomputeUnread() {
        guard !session.isReview, session.isViewingLive else { unreadCount = 0; return }
        seenLineIds.formUnion(visibleLineIds)
        if transcriptScroll.isFollowingLatest { markAllSeen(); unreadCount = 0; return }
        unreadCount = chatLines.reduce(0) { $0 + (seenLineIds.contains($1.id) ? 0 : 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPhaseBar { PhaseBar(session: session) }
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                    let lines = chatLines
                    let phase = session.viewingPhaseId
                    LazyVStack(alignment: .leading, spacing: chatLayout == .compact ? 4 : 2) {
                        Color.clear
                            .frame(height: 1)
                            .id("chat-top")
                        ForEach(session.viewingNewspapers) { paper in
                            NewspaperCard(issue: paper, session: session)
                                .id("newspaper-\(paper.id)")
                                .onAppear { UMDiag.log("view", "newspaper appear \(paper.id)") }
                                .onDisappear { UMDiag.log("view", "newspaper disappear \(paper.id)") }
                        }
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            ChatRow(
                                line: line,
                                previous: index > 0 ? lines[index - 1] : nil,
                                session: session,
                                layout: chatLayout
                            )
                            .id(line.id)
                            .onAppear { UMDiag.messageRendered(line.id) }
                            .onScrollVisibilityChange(threshold: 0.6) { visible in
                                noteVisibility(line.id, visible: visible, phase: phase)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        UMTranscriptScrollBridge(controller: transcriptScroll)
                    }
                    #if os(iOS)
                    .background {
                        UMPhaseSwipeBridge(enabled: !session.isLiarsDice,
                                           onChange: swipeChanged, onEnd: swipeEnded)
                    }
                    #endif
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    // The last line sits close under the floating composer: the composer's own height
                    // is already reserved by the scroll content margin, so this is only the room
                    // between the two.
                    .padding(.bottom, 12)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
                #if DEBUG
                // `-UMDiagSwipeRelease <dx>`: one swipe of dx, released, through the real handler.
                // `-UMDiagPhaseFlip <n>`: n swipes back and forth 1 s apart, logging how many image
                // network fetches happened across them (should be 0 once the game is pinned).
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-UMDiagSwipeRelease"), args.indices.contains(i + 1),
                       let dx = Double(args[i + 1]) {
                        try? await Task.sleep(for: .seconds(3))
                        swipeEnded(CGFloat(dx), 0)
                    }
                    if let i = args.firstIndex(of: "-UMDiagPhaseFlip"), args.indices.contains(i + 1),
                       let n = Int(args[i + 1]) {
                        try? await Task.sleep(for: .seconds(4))
                        let before = UMImageCache.networkFetches.withLock { $0 }
                        let loadsBefore = UMImageCache.loads.withLock { $0 }
                        UMDiag.log("img", "flip start: \(before) fetches so far, phase \(session.viewingPhaseId)")
                        for k in 0..<n {
                            swipeEnded(k % 2 == 0 ? 200 : -200, 0)
                            try? await Task.sleep(for: .seconds(1))
                            UMDiag.log("img", "flip \(k + 1): phase \(session.viewingPhaseId)")
                        }
                        let after = UMImageCache.networkFetches.withLock { $0 }
                        let loadsAfter = UMImageCache.loads.withLock { $0 }
                        UMDiag.log("img", "flip done: \(after - before) network fetches, \(loadsAfter - loadsBefore) image loads (memory misses) during \(n) phase switches")
                    }
                }
                #endif
                .pointerScrolling()
                .contentMargins(.bottom, composerOverlayHeight, for: .scrollContent)
                .contentMargins(.top, topInset, for: .scrollContent)
                .contentMargins(.top, topInset, for: .scrollIndicators)
                .scrollDismissesKeyboard(.interactively)
                // No floating scroll-to-top button: tapping the clock in the header does it
                // (session.chatJumpTopTick, same as Option+Up).
                .overlay(alignment: .topTrailing) {
                    if showTypingIndicator, transcriptScroll.isFollowingLatest {
                        VStack(alignment: .trailing, spacing: 6) {
                            ForEach(session.typingPlayers) { player in
                                HStack(spacing: 4) {
                                    UMAvatarView(player: player, size: 22)
                                    PulsingDots()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(UMTheme.card.opacity(0.92), in: Capsule())
                            }
                        }
                        .padding(.trailing, 6)
                        .padding(.top, topInset + 4)
                    }
                }
                .overlay(alignment: .bottom) {
                        if !transcriptScroll.isAtBottom, !session.isReview {
                            Button {
                                markAllSeen()
                                unreadCount = 0
                                jumpToLatest()
                            } label: {
                                Text(unreadCount > 0 ? "\(unreadCount) unseen message\(unreadCount == 1 ? "" : "s") ↓" : "Scroll to latest message ↓")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(UMTheme.blood, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, composerOverlayHeight + 8)
                            .accessibilityLabel(unreadCount > 0 ? "\(unreadCount) unseen messages, scroll to latest" : "Scroll to latest message")
                        }
                }
                .onChange(of: session.displayedMessages.count) { _, _ in
                    // Phase restoration owns navigation while the rows swap.
                    guard !restoringScroll else { return }
                    jumpToLatestIfPinned()
                }
                .onChange(of: session.viewingPhaseId) { oldPhase, newPhase in
                    session.phasePinned[oldPhase] = transcriptScroll.isFollowingLatest
                    transcriptScroll.setFollowingAllowed(!session.isReview && session.isViewingLive)
                    trackedPhase = newPhase
                    visibleBuffer.pending.removeAll()
                    visibleLineIds.removeAll()
                    markAllSeen()
                    unreadCount = 0
                    let forceTop = session.reviewScrollTopPending
                    session.reviewScrollTopPending = false
                    let live = !session.isReview && !forceTop && newPhase == session.currentPhaseId
                    let anchor = forceTop ? nil : session.phaseScrollAnchors[newPhase]
                    if live, session.phasePinned[newPhase] != false || anchor == nil {
                        restoringScroll = false
                        restoreGeneration = UUID()
                        jumpToLatest()
                    } else {
                        restorePhasePosition(anchor: anchor, phase: newPhase, proxy: proxy)
                        if forceTop {
                            // Top right away (not only on the restore retries), so the new phase's
                            // first frame is already at its first message.
                            transcriptScroll.requestTop()
                            DispatchQueue.main.async { transcriptScroll.applyPendingNow() }
                        }
                    }
                }
                .onAppear {
                    transcriptScroll.setFollowingAllowed(!session.isReview && session.isViewingLive)
                    trackedPhase = session.viewingPhaseId
                    if session.chatHasOpened, !session.chatPinnedToBottom, let anchor = session.chatAnchorId,
                       chatLines.contains(where: { $0.id == anchor }) {
                        restorePhasePosition(anchor: anchor, phase: session.viewingPhaseId, proxy: proxy)
                        recomputeUnread()
                    } else if session.isReview || !session.isViewingLive {
                        let anchor = session.reviewScrollTopPending ? nil : session.phaseScrollAnchors[session.viewingPhaseId]
                        session.reviewScrollTopPending = false
                        markAllSeen()
                        restorePhasePosition(anchor: anchor, phase: session.viewingPhaseId, proxy: proxy)
                    } else {
                        // The native bridge follows actual UIKit bounds as rows/keyboard lay out.
                        markAllSeen()
                        session.chatPinnedToBottom = true
                        jumpToLatest()
                    }
                    session.chatHasOpened = true
                    trackedPhase = session.viewingPhaseId
                }
                .onChange(of: session.isViewingLive) { _, live in
                    // A phase switch must record the old pin before changing the policy.
                    guard trackedPhase == session.viewingPhaseId else { return }
                    transcriptScroll.setFollowingAllowed(!session.isReview && live)
                }
                .onChange(of: transcriptScroll.isFollowingLatest) { _, pinned in
                    session.chatPinnedToBottom = pinned
                    recomputeUnread()
                }
                .onChange(of: transcriptScroll.isAtBottom) { _, bottom in
                    if bottom { recomputeUnread() }
                }
                .onChange(of: session.chatJumpTopTick) { _, _ in jumpToTop() }
                .onChange(of: session.chatJumpBottomTick) { _, _ in
                    markAllSeen()
                    unreadCount = 0
                    jumpToLatest()
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Outside the transcript scroll hierarchy, but floating above its content rather
            // than reserving a separate opaque strip. Only the composer's own controls draw a glass
            // background, so nothing else gains an opaque strip.
            if session.showComposer {
                ChatComposer(session: session, draft: $draft, chatFocused: chatFocused)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(composerOverlayHeight - height) > 0.25 {
                            composerOverlayHeight = height
                            // The reserved inset moves with the composer, so the bottom of the
                            // transcript has to move with it in the same pass. Otherwise the last row
                            // is drawn under the pill until the next per-frame sample, which is the
                            // same one-frame slip as a newly arrived row.
                            DispatchQueue.main.async { transcriptScroll.applyPendingNow() }
                        }
                    }
            }
        }
        .onChange(of: session.showComposer) { _, show in
            if !show { composerOverlayHeight = 0 }
        }
    }

    /// Scoped navigation retries only for a phase switch, never geometry or draft updates.
    private func restorePhasePosition(anchor: String?, phase: Int, proxy: ScrollViewProxy) {
        transcriptScroll.pauseFollowing()
        restoringScroll = true
        let generation = UUID()
        restoreGeneration = generation
        let target = anchor.flatMap { id in chatLines.contains(where: { $0.id == id }) ? id : nil }
        for delay in [0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard restoringScroll, restoreGeneration == generation,
                      trackedPhase == phase, session.viewingPhaseId == phase else { return }
                if let target { proxy.scrollTo(target, anchor: .top) }
                else { transcriptScroll.requestTop() }
                if delay == 0.3 {
                    restoringScroll = false
                    visibleLineIds = visibleBuffer.pending
                    if let first = chatLines.first(where: { visibleLineIds.contains($0.id) })?.id {
                        session.chatAnchorId = first
                        session.phaseScrollAnchors[phase] = first
                    }
                    recomputeUnread()
                }
            }
        }
    }

    private func jumpToLatestIfPinned() {
        guard !session.isReview, session.isViewingLive, let last = session.displayedMessages.last else { return }
        let mine = last.senderId == session.selfId
        // A quote is yours, but it is written while reading back through the chat: following it
        // would throw away the very position the quote was picked from. It still lands at the
        // bottom; you keep your place.
        if mine, last.isQuote, !transcriptScroll.isFollowingLatest { return }
        if transcriptScroll.isFollowingLatest || mine {
            markAllSeen()
            unreadCount = 0
            jumpToLatest()
        } else {
            recomputeUnread()
        }
    }

    private func jumpToLatest() {
        restoringScroll = false
        restoreGeneration = UUID()
        transcriptScroll.requestLatest()
        // The row that just arrived is laid out after this update pass, so apply the scroll as soon
        // as that has happened rather than leaving it to the next display-link tick, which is late
        // enough for the row to be drawn behind the composer for one frame.
        DispatchQueue.main.async { transcriptScroll.applyPendingNow() }
    }

    // MARK: Phase swipe
    // Left to right = previous phase, right to left = next. Nothing moves while the finger is down
    // (no follow, fade or rubber band: moving the rows inside the scroll view re-ran visibility
    // tracking and fought the phase-position restore, which is what made it feel buggy). On
    // release, a long enough or quick enough sideways swipe switches phase in one frame with
    // animations off, plus a light haptic. With no phase that way it does nothing but a soft tick.

    private func swipeChanged(_ dx: CGFloat) {}

    private func swipeEnded(_ dx: CGFloat, _ vx: CGFloat) {
        guard dx != 0 else { return }
        let far = abs(dx) > min(paneWidth * 0.22, 110)
        let flick = abs(vx) > 500 && abs(dx) > 30 && (vx > 0) == (dx > 0)
        let reversing = abs(vx) > 300 && (vx > 0) != (dx > 0)
        guard far || flick, !reversing else { return }
        let delta = dx > 0 ? -1 : 1
        guard session.hasAdjacentPhase(delta: delta) else {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
            #endif
            return
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { session.swipeToAdjacentPhase(delta: delta) }
    }

    private func jumpToTop() {
        restoringScroll = false
        restoreGeneration = UUID()
        transcriptScroll.requestTop()
    }
}

private struct ChatComposer: View {
    /// Mirrors keyboard visibility from will* notifications (drives the chevron icon).
    @State private var keyboardShown = false
    var session: GameSession
    @Binding var draft: String
    var chatFocused: Binding<Bool>
    @State private var savedDraft = ""
    @AppStorage("um.showNameAutofill") private var showTabButton = true
    @AppStorage("um.showEmoteAutocomplete") private var showEmoteAutocomplete = true
    @Environment(AppModel.self) private var app
    @State private var keyboardExpanded = false

    private var composerIdleHeight: CGFloat {
        ceil(UMComposerField.font.lineHeight) + 20
    }

    private struct MediaSuggestion: Identifiable {
        var id: String { (isSticker ? "s" : "e") + code }
        let code: String
        let url: URL
        let isSticker: Bool
    }

    /// Current word when it starts with `:` (emoji) or `;` (sticker), bare or followed by a letter/digit.
    /// Only a token start counts, so `hi;` or `a;b` never trigger.
    private var mediaToken: (query: String, sticker: Bool, range: Range<String.Index>)? {
        guard let last = draft.last, !last.isWhitespace, !draft.hasPrefix("/") else { return nil }
        let start = draft.lastIndex(where: { $0.isWhitespace }).map { draft.index(after: $0) } ?? draft.startIndex
        let word = draft[start...]
        guard let trigger = word.first, trigger == ":" || trigger == ";" else { return nil }
        guard word.count == 1 || word.dropFirst().first.map({ $0.isLetter || $0.isNumber }) == true else { return nil }
        var q = String(word.dropFirst()).lowercased()
        if q.last == trigger { q.removeLast() }
        return (q, trigger == ";", start..<draft.endIndex)
    }

    private var selfPlayer: GamePlayer? {
        guard let me = app.user?.id else { return nil }
        return session.players.first { $0.userId == me || $0.id == me }
    }

    private var stickerMap: [String: String] {
        app.myCustomStickers.isEmpty ? (selfPlayer?.customStickers ?? [:]) : app.myCustomStickers
    }

    nonisolated private static func bareCode(_ code: String) -> String {
        code.trimmingCharacters(in: CharacterSet(charactersIn: ":;")).lowercased()
    }

    /// Rewrites whole-token `;name;` to `:name:` when `name` is one of the user's stickers (case-insensitive,
    /// like the site's word match). Anything else, including prose semicolons, is left as typed.
    nonisolated static func rewriteStickerTokens(_ text: String, stickerNames: Set<String>) -> String {
        guard !stickerNames.isEmpty, text.contains(";"),
              let re = try? NSRegularExpression(pattern: "(?<!\\S);([^\\s;]+);(?!\\S)") else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1))
            guard stickerNames.contains(name.lowercased()), let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: ":\(name):")
        }
        return out
    }

    /// Own custom emotes and stickers only. API data first, in-game self player maps as fallback.
    private var mediaSuggestions: [MediaSuggestion] {
        guard showEmoteAutocomplete, chatFocused.wrappedValue, let t = mediaToken else { return [] }
        return mediaMatches(t)
    }

    /// Ordered matches for a `:`/`;` token (same order as the suggestion chips).
    private func mediaMatches(_ t: (query: String, sticker: Bool, range: Range<String.Index>)) -> [MediaSuggestion] {
        let me = app.user?.id
        let emotes = app.myCustomEmotes.isEmpty ? (selfPlayer?.customEmotes ?? [:]) : app.myCustomEmotes
        let rank = EmoteOrderStore.shared.rank(for: me)
        func ranked(_ map: [String: String], sticker: Bool) -> [MediaSuggestion] {
            let items = map.compactMap { code, path -> (String, URL)? in
                guard let url = UMMediaURL.resolve(path) else { return nil }
                let bare = code.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
                return (t.query.isEmpty || bare.contains(t.query)) ? (code, url) : nil
            }
            let bare: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased() }
            // Prefix matches first while filtering; then the user's You-tab order; then name.
            let ix: (String) -> Int = { rank[EmoteOrderStore.key(code: $0, sticker: sticker)] ?? Int.max }
            return items.sorted { a, b in
                let pa = bare(a.0).hasPrefix(t.query), pb = bare(b.0).hasPrefix(t.query)
                if pa != pb { return pa }
                let ia = ix(a.0), ib = ix(b.0)
                return ia != ib ? ia < ib : a.0 < b.0
            }.map { MediaSuggestion(code: $0.0, url: $0.1, isSticker: sticker) }
        }
        return t.sticker ? ranked(stickerMap, sticker: true) : ranked(emotes, sticker: false)
    }

    private func applyMedia(_ item: MediaSuggestion) {
        guard let t = mediaToken else { return }
        var next = draft
        let bare = Self.bareCode(item.code)
        next.replaceSubrange(t.range, with: (item.isSticker ? ";\(bare);" : ":\(bare):") + UMChatPrefs.completionSuffix)
        draft = String(next.prefix(UMConfig.maxChatLength))
        session.noteTyping()
    }

    /// Last word of the draft (cursor is assumed at the end), keeping any leading @ or %.
    private var nameToken: (prefix: String, query: String, range: Range<String.Index>)? {
        guard let last = draft.last, !last.isWhitespace else { return nil }
        let start = draft.lastIndex(where: { $0.isWhitespace }).map { draft.index(after: $0) } ?? draft.startIndex
        let word = draft[start...]
        let prefix = String(word.prefix(while: { $0 == "@" || $0 == "%" }))
        let query = String(word.dropFirst(prefix.count))
        guard query.count >= 2, !draft.hasPrefix("/") else { return nil }
        return (prefix, query, start..<draft.endIndex)
    }

    private var nameSuggestions: [String] {
        guard showTabButton, chatFocused.wrappedValue, mediaToken == nil, let t = nameToken else { return [] }
        var seen = Set<String>()
        return session.players.map(\.name).filter { name in
            name.lowercased().hasPrefix(t.query.lowercased())
                && name.caseInsensitiveCompare(t.query) != .orderedSame
                && seen.insert(name).inserted
        }.prefix(3).map { $0 }
    }

    private func applySuggestion(_ name: String) {
        guard let t = nameToken else { return }
        var next = draft
        next.replaceSubrange(t.range, with: t.prefix + name + UMChatPrefs.completionSuffix)
        draft = String(next.prefix(UMConfig.maxChatLength))
        session.noteTyping()
    }

    // MARK: Slash commands

    private enum SlashSuggestion: Identifiable {
        case command(SlashCommand)
        case player(String, GamePlayer)
        case noOne(String)
        var id: String {
            switch self {
            case .command(let c): return "c:" + c.name
            case .player(let cmd, let p): return "p:\(cmd):" + p.id
            case .noOne(let label): return "n:" + label
            }
        }
    }

    /// "/" + partial command -> matching valid commands; "/cmd " + partial name -> valid targets.
    private var slashSuggestions: [SlashSuggestion] {
        guard chatFocused.wrappedValue, draft.hasPrefix("/") else { return [] }
        let body = String(draft.dropFirst())
        let commands = session.availableSlashCommands
        guard let space = body.firstIndex(of: " ") else {
            let q = body.lowercased()
            return commands.filter { q.isEmpty || $0.name.hasPrefix(q) }.map { .command($0) }
        }
        let cmd = body[..<space].lowercased()
        guard let def = commands.first(where: { $0.name == cmd }),
              [.player, .playerThenText, .optionalPlayer].contains(def.arg) else { return [] }
        let arg = String(body[body.index(after: space)...])
        guard !arg.contains(" ") else { return [] }
        let targets = session.slashTargets(for: cmd)
        if targets.contains(where: { $0.name.caseInsensitiveCompare(arg) == .orderedSame }) { return [] }
        var out: [SlashSuggestion] = targets
            .filter { arg.isEmpty || $0.name.lowercased().hasPrefix(arg.lowercased()) }
            .map { .player(cmd, $0) }
        // /vote: No One goes last when the meeting offers it.
        if cmd == "vote", let m = session.villageMeeting, m.targets.contains("*") {
            let label = session.voteLabel("*", meeting: m)
            if arg.isEmpty || label.lowercased().hasPrefix(arg.lowercased()) || "nl".hasPrefix(arg.lowercased()) {
                out.append(.noOne(label))
            }
        }
        return out
    }

    private func applySlash(_ item: SlashSuggestion) {
        switch item {
        case .command(let c):
            draft = "/" + c.name + (c.arg == .none ? "" : UMChatPrefs.completionSuffix)
        case .player(let cmd, let p):
            draft = "/\(cmd) \(p.name)" + UMChatPrefs.completionSuffix
        case .noOne:
            // "nl" means No one, unless a player is literally named nl.
            let nlIsPlayer = session.players.contains { $0.name.caseInsensitiveCompare("nl") == .orderedSame }
            draft = nlIsPlayer ? "/vote " : "/vote nl"
        }
        session.slashHint = nil
    }

    @ViewBuilder
    private var slashBar: some View {
        let items = slashSuggestions
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Button { applySlash(item) } label: {
                            HStack(spacing: 6) {
                                switch item {
                                case .command(let c):
                                    Image(systemName: c.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(c.usage).font(.subheadline.weight(.semibold))
                                        Text(c.summary).font(.system(size: 10)).foregroundStyle(UMTheme.muted)
                                    }
                                case .player(_, let p):
                                    UMAvatarView(player: p, size: 20)
                                    Text(p.name).font(.subheadline.weight(.semibold))
                                case .noOne(let label):
                                    Image(systemName: "nosign")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 20, height: 20)
                                    Text(label).font(.subheadline.weight(.semibold))
                                }
                            }
                            .lineLimit(1)
                            .frame(minHeight: 20)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(UMTheme.card, in: Capsule())
                            .overlay(Capsule().stroke(UMTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(UMTheme.elevated)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
        if let hint = session.slashHint {
            Text(hint)
                .font(.caption.weight(.semibold))
                .foregroundStyle(UMTheme.mafia)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(UMTheme.elevated)
        }
        let media = session.isSpeakCoolingDown || draft.hasPrefix("/") ? [] : mediaSuggestions
        if draft.hasPrefix("/") {
            slashBar
        } else if !media.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(media) { item in
                        Button { applyMedia(item) } label: {
                            HStack(spacing: 5) {
                                AnimatedWebPView(url: item.url, showsPlaceholder: false, fitHeight: 20)
                                    .fixedSize()
                                Text(item.code)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(height: 20)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(UMTheme.card, in: Capsule())
                            .overlay(Capsule().stroke(item.isSticker ? UMTheme.blood.opacity(0.7) : UMTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel(item.isSticker ? "Sticker \(item.code)" : "Emote \(item.code)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(UMTheme.elevated)
        } else if !session.isSpeakCoolingDown, !nameSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(nameSuggestions, id: \.self) { name in
                        Button { applySuggestion(name) } label: {
                            Text(name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(UMTheme.card, in: Capsule())
                                .overlay(Capsule().stroke(UMTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(UMTheme.elevated)
        }
        UMDictationBanner()
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let cooling = (session.speakCooldownUntil ?? .distantPast) > context.date
            HStack(alignment: .bottom, spacing: 8) {
                    Button {
                        session.cycleSpeechOption()
                    } label: {
                        Text(session.speechLabel)
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 52, height: composerIdleHeight)
                    .background {
                        Color.clear.glassEffect(
                            .regular.tint(cooling ? .red : nil).interactive(!cooling),
                            in: Capsule()
                        )
                    }
                    .foregroundStyle(.white)
                    .disabled(cooling)
                    .contextMenu {
                        ForEach(session.speechOptions) { option in
                            Button(option.menuTitle) {
                                session.selectSpeechOption(option.id)
                            }
                        }
                        if session.setupWhispers {
                            Divider()
                            Toggle("Leak Whispers", isOn: Binding(
                                get: { session.whisperForceLeak },
                                set: { session.whisperForceLeak = $0 }
                            ))
                        }
                    }

                    // Return sends (commands too) without ever dismissing the keyboard.
                    UMComposerField(
                        text: cappedDraft,
                        isFocused: chatFocused,
                        placeholder: placeholder(cooling: cooling),
                        enabled: !cooling,
                        textColor: cooling ? .white : .label,
                        maxLength: UMConfig.maxChatLength,
                        onReturn: send,
                        onTab: {
                            guard !cooling, let last = draft.last, !last.isWhitespace else { return true }
                            return completeMedia() || completeName()
                        },
                        onShortcut: { session.performShortcut($0) }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        Color.clear.glassEffect(
                            .regular.tint(cooling ? .red : nil).interactive(!cooling),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )
                    }
                    .onChange(of: draft) { oldValue, newValue in
                        if cooling { return }
                        handleTyping(oldValue, newValue)
                    }

                    UMMicButton(text: cappedDraft, maxLength: UMConfig.maxChatLength, vocab: { dictationVocab })
                        .disabled(cooling)

                    #if !os(macOS)
                    // Keyboard toggle (Return is the send key). Macs have a hardware keyboard.
                    Button {
                        chatFocused.wrappedValue.toggle()
                    } label: {
                        // Icon follows keyboardWillShow/WillHide (fires before the slide begins) and swaps
                        // with no transition of its own, so it rides the same keyboard animation as the bar.
                        Image(systemName: keyboardShown ? "chevron.down" : "chevron.up")
                            .contentTransition(.identity)
                            .transaction { $0.animation = nil }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(UMTheme.muted)
                            .frame(width: 32, height: 32)
                            .background {
                                // A glass bubble like the Say pill, so the row's controls read as one
                                // set rather than two pills and a bare icon.
                                Color.clear.glassEffect(.regular.interactive(true), in: Capsule())
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(keyboardShown ? "Hide keyboard" : "Show keyboard")
                    #if canImport(UIKit)
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        keyboardShown = true
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        keyboardShown = false
                    }
                    #endif
                    #endif
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            .onChange(of: cooling) { _, nowCooling in
                if nowCooling {
                    if !draft.isEmpty {
                        savedDraft = draft
                        draft = ""
                    }
                    session.stopTyping()
                } else if draft.isEmpty, !savedDraft.isEmpty {
                    draft = savedDraft
                    savedDraft = ""
                }
            }
        }
        }
        .bindKeyboardExpanded($keyboardExpanded)
    }

    /// Current game's players, then its setup roles, for dictation.
    private var dictationVocab: DictationVocab {
        DictationVocab(players: session.players.map(\.name),
                       roles: session.setupRoles.map(\.name) + session.setupRolesets.flatMap { $0.map(\.name) })
    }

    private func placeholder(cooling: Bool) -> String {
        if cooling {
            let left = session.speakCooldownSecondsLeft
            return "Please do not spam! \(max(left, 1))s"
        }
        return session.speechPlaceholder
    }


    private var cappedDraft: Binding<String> {
        Binding(
            get: { draft },
            set: { draft = String($0.prefix(UMConfig.maxChatLength)) }
        )
    }

    /// Tab on a `:emo` / `;stick` token: complete to the exact match if there is one, else the
    /// first match in chip order. Like names, no cycling; an already-complete exact token is kept.
    private func completeMedia() -> Bool {
        guard let t = mediaToken, !t.query.isEmpty else { return false }
        let matches = mediaMatches(t)
        guard !matches.isEmpty else { return false }
        let exact = matches.first { Self.bareCode($0.code) == t.query }
        let item = exact ?? matches[0]
        let bare = Self.bareCode(item.code)
        let token = item.isSticker ? ";\(bare);" : ":\(bare):"
        let spaced = t.range.upperBound < draft.endIndex && draft[t.range.upperBound].isWhitespace
        let suffix = UMChatPrefs.completionSuffix
        if String(draft[t.range]).lowercased() == token, spaced || suffix.isEmpty { return true }
        var next = draft
        next.replaceSubrange(t.range, with: spaced ? token : token + suffix)
        draft = String(next.prefix(UMConfig.maxChatLength))
        session.noteTyping()
        return true
    }

    @discardableResult
    private func completeName() -> Bool {
        guard let next = session.completePlayerName(draft), next != draft else { return false }
        draft = String(next.prefix(UMConfig.maxChatLength))
        if !draft.hasPrefix("/") { session.noteTyping() }
        return true
    }

    private func handleTyping(_ oldValue: String, _ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            session.stopTyping()
            return
        }
        if session.slashHint != nil, newValue != oldValue { session.slashHint = nil }
        if newValue.hasPrefix("/") {
            // Suppress typing until the next normal message is sent.
            session.typingSuppressed = true
            session.stopTyping()
            return
        }
        if newValue != oldValue {
            session.noteTyping()
        }
    }

    private func send() {
        // Ready check up: Return accepts it instead of sending (composer may still have focus).
        if session.needsReadyConfirm { session.acceptReadyCheck(); return }
        // Draft-only (no speakable meeting): Return does nothing; the draft is kept.
        guard !session.isSpeakCoolingDown, !session.isDraftOnly else { return }
        let text = Self.rewriteStickerTokens(draft, stickerNames: Set(stickerMap.keys.map(Self.bareCode)))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.stopTyping()
        if session.speak(text) {
            draft = ""
        }
    }
}

private struct ChatRow: View {
    @AppStorage("um.chatIndentUserMessages") private var indentUser = false
    let line: ChatLine
    var previous: ChatLine?
    var session: GameSession
    var layout: ChatLayout = .standard

    /// "Indent Player Messages": inset only the message text (never the avatar/name header).
    private var textInset: CGFloat { indentUser ? 10 : 0 }

    private var grouped: Bool {
        guard layout == .standard else { return false }
        if line.isQuote { return false }
        guard isPlayerChat(line), let previous, isPlayerChat(previous), !previous.isQuote else { return false }
        return previous.senderId == line.senderId
    }

    private func isPlayerChat(_ line: ChatLine) -> Bool {
        !line.isServer && line.senderId != "vote" && line.senderId != "server"
    }

    var body: some View {
        let player = session.player(for: line.senderId)
        Group {
            if let paper = line.newspaper {
                // Live copy: a death reveal that arrives after the paper updates it in place.
                NewspaperCard(issue: session.currentIssue(paper), session: session)
            } else if line.senderId == "vote" {
                voteRow
            } else if line.isServer {
                serverRow
            } else if layout == .compact {
                compactRow(player: player)
            } else {
                standardRow(player: player)
            }
        }
        .frame(maxWidth: .infinity, alignment: line.senderId == "vote" ? .trailing : .leading)
        .contentShape(Rectangle())
        .opacity(session.dimsInChat(line) ? 0.35 : (line.isQuote ? 0.9 : 1))
        .padding(.top, grouped ? 0 : (layout == .standard && isPlayerChat(line) ? 8 : 0))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                // The haptic is the acknowledgement for the gesture, so it fires on the same answer
                // as the quote itself: a double tap that would do nothing stays silent.
                guard session.canQuote(line) else { return }
                UMHaptics.quoteTapped()
                session.quote(line)
            }
        )
    }

    /// Vote text right-aligned with its timestamp at the far right of the same row.
    private var voteRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer(minLength: 0)
            Text(line.content)
                .font(.caption.italic())
                .foregroundStyle(UMTheme.muted)
                .multilineTextAlignment(.trailing)
            Text(minuteSecond(line.time))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(UMTheme.muted)
                .fixedSize()
        }
    }

    private var serverRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(minuteSecond(line.time))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(UMTheme.muted)
                .frame(width: 36, alignment: .leading)
                .fixedSize()
                .padding(.top, 2)
            EmoteText(text: line.content, color: UMTheme.muted, italic: true, system: true, emoteSize: 16, players: session.players, gameType: session.setupGameType, otherRoles: session.guessableRoles.map(\.raw))
        }
    }

    private func compactRow(player: GamePlayer?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(minuteSecond(line.time))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(UMTheme.muted)
                .frame(width: 36, alignment: .leading)
                .fixedSize()
                .padding(.top, 2)
            playerRow(player: player)
        }
    }

    private func standardRow(player: GamePlayer?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !grouped {
                HStack(alignment: .center, spacing: 6) {
                    UMAvatarView(
                        userId: player?.userId,
                        hasAvatar: player?.avatar ?? false,
                        name: player?.name ?? line.senderName,
                        size: 28,
                        square: player?.squareAvatar ?? false,
                        deckPath: player?.deckAvatarPath
                    )
                    Group {
                        if let player {
                            HStack(spacing: 0) {
                                PlayerNameView(player: player, fontSize: 14, dead: session.deadStyled(line))
                                if session.showsDeadSuffix(line) {
                                    Text(" (dead)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(UMTheme.deadName)
                                }
                                if session.isSpectatorLine(line) {
                                    Text(" (spectator)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(UMTheme.deadName)
                                }
                            }
                        } else {
                            Text(line.senderId == "anonymous" ? "Anonymous" : line.senderName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.white)
                        }
                    }
                    Text(minuteSecond(line.time))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(UMTheme.muted)
                    Spacer(minLength: 0)
                }
            }
            messageBody(player: player)
                .padding(.leading, textInset)
        }
    }

    @ViewBuilder
    private func messageBody(player: GamePlayer?) -> some View {
        let me = line.content.hasPrefix("/me ")
        let body = me ? String(line.content.dropFirst(4)) : line.content
        HStack(alignment: .top, spacing: 4) {
            if line.isQuote {
                Image(systemName: "quote.opening")
                    .font(.caption2)
                    .foregroundStyle(UMTheme.muted)
                    .padding(.top, 3)
            }
            if line.isQuote {
                quoteAuthorLabel
            }
            if let prefix = line.prefix, !prefix.isEmpty {
                Text(prefix)
                    .font(.caption2.italic())
                    .foregroundStyle(UMTheme.muted)
                    .fixedSize()
            }
            EmoteText(
                text: body,
                color: line.isQuote ? UMTheme.muted : chatBodyColor(player: player),
                italic: me || line.isQuote,
                customEmotes: line.isQuote ? line.customEmotes : (player?.customEmotes ?? line.customEmotes),
                customStickers: line.isQuote ? line.customStickers : (player?.customStickers ?? line.customStickers),
                system: false,
                players: session.players,
                gameType: session.setupGameType,
                otherRoles: session.guessableRoles.map(\.raw)
            )
            if line.isQuote {
                Image(systemName: "quote.closing")
                    .font(.caption2)
                    .foregroundStyle(UMTheme.muted)
                    .padding(.top, 3)
            }
        }
    }

    private var quotedAuthor: String {
        if let name = line.quotedSenderName, !name.isEmpty { return name }
        if line.quotedSenderId == "anonymous" { return "Anonymous" }
        return "Anonymous"
    }

    @ViewBuilder
    private var quoteAuthorLabel: some View {
        let name = quotedAuthor
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let quotedTime = line.quotedTime {
                Text(minuteSecond(quotedTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(UMTheme.muted)
                    .fixedSize()
            }
            if let phase = line.quotedFromStateName, !phase.isEmpty {
                Text("\(name) on \(phase):")
                    .font(.caption.italic())
                    .foregroundStyle(UMTheme.muted)
                    .fixedSize()
            } else {
                Text("\(name):")
                    .font(.caption.italic())
                    .foregroundStyle(UMTheme.muted)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func playerRow(player: GamePlayer?) -> some View {
        let me = line.content.hasPrefix("/me ")
        let body = me ? String(line.content.dropFirst(4)) : line.content
        UMAvatarView(
            userId: player?.userId,
            hasAvatar: player?.avatar ?? false,
            name: player?.name ?? line.senderName,
            size: 18,
            square: player?.squareAvatar ?? false,
            deckPath: player?.deckAvatarPath
        )
        .offset(y: -1.5)
        .padding(.top, 2)

        if line.isQuote {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(UMTheme.muted)
                .padding(.top, 3)
        }

        Group {
            if line.isQuote {
                quoteAuthorLabel
            } else if let player {
                HStack(spacing: 0) {
                                PlayerNameView(player: player, fontSize: 14, dead: session.deadStyled(line))
                                if session.showsDeadSuffix(line) {
                                    Text(" (dead)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(UMTheme.deadName)
                                }
                                if session.isSpectatorLine(line) {
                                    Text(" (spectator)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(UMTheme.deadName)
                                }
                            }
            } else {
                Text(line.senderId == "anonymous" ? "Anonymous" : line.senderName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .fixedSize()
        if let prefix = line.prefix, !prefix.isEmpty {
            Text(prefix)
                .font(.caption2.italic())
                .foregroundStyle(UMTheme.muted)
                .fixedSize()
        }

        EmoteText(
            text: body,
            color: line.isQuote ? UMTheme.muted : chatBodyColor(player: player),
            italic: me || line.isQuote,
            customEmotes: line.isQuote ? line.customEmotes : (player?.customEmotes ?? line.customEmotes),
            customStickers: line.isQuote ? line.customStickers : (player?.customStickers ?? line.customStickers),
            system: false,
            players: session.players,
            gameType: session.setupGameType,
            otherRoles: session.guessableRoles.map(\.raw)
        )
        .padding(.leading, textInset)
        if line.isQuote {
            Image(systemName: "quote.closing")
                .font(.caption2)
                .foregroundStyle(UMTheme.muted)
                .padding(.top, 3)
        }
    }

    private func chatBodyColor(player: GamePlayer?) -> Color {
        if session.deadStyled(line) || session.isSpectatorLine(line) { return .red }
        return player?.bodyColor ?? .white
    }

    private func minuteSecond(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.minute, .second], from: date)
        return String(format: "%02d:%02d", c.minute ?? 0, c.second ?? 0)
    }
}

private struct GameTownPane: View {
    var session: GameSession
    /// iPad three-column Village column: dense rows so 10+ players fit without scrolling.
    var compact = false
    @AppStorage("um.playerListSize") private var playerListSize = "compact"
    private var expanded: Bool { compact && playerListSize == "expanded" }
    /// Phone/tab size, iPad-column Compact size, iPad-column Expanded size.
    private func dim(_ normal: CGFloat, _ small: CGFloat, _ big: CGFloat) -> CGFloat {
        compact ? (expanded ? big : small) : normal
    }
    @Environment(AppModel.self) private var app
    @State private var pickingPlayerId: String?
    /// Post-game only: the row whose Report/Block bar is open.
    @State private var moderatingPlayerId: String?
    /// Measured natural height of the Report/Block bar (for the clipped reveal).
    @State private var moderationBarHeight: CGFloat = 44
    private static let revealAnimation = Animation.easeInOut(duration: 0.25)

    /// Ended game still on screen, or a review; never yourself or anonymous (no userId) players.
    private func canModerate(_ player: GamePlayer) -> Bool {
        guard session.finished || session.isReview, let uid = player.userId, !uid.isEmpty else { return false }
        return !app.isSelf(player, selfSeatId: session.selfId)
    }

    var body: some View {
        List {
            Section {
                ForEach(session.villagePlayers) { player in
                    townRow(player, dead: false)
                }
            }
            if !session.graveyardPlayers.isEmpty {
                Section("Graveyard") {
                    ForEach(session.graveyardPlayers) { player in
                        townRow(player, dead: true)
                    }
                }
            }
            if session.canIsolate {
                Section {
                    Button {
                        if session.isolating { session.isolating = false; session.isolatedIds = [] }
                        else { session.isolating = true }
                    } label: {
                        Label(session.isolating ? (session.isolatedIds.isEmpty ? "Done" : "Clear isolation") : "Isolate messages",
                              systemImage: session.isolating ? "xmark.circle" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: dim(15, 13, 16), weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Choose players whose messages stay prominent; others are dimmed")
                } footer: {
                    if session.isolating {
                        Text(session.isolatedIds.isEmpty ? "Check players to keep their messages prominent." :
                             "\(session.isolatedIds.count) isolated. Other players' messages are dimmed.")
                    }
                }
            }
            if !session.spectatorList.isEmpty, !session.isReview {
                Section("Spectators") {
                    ForEach(session.spectatorList) { spectator in
                        HStack(spacing: dim(8, 6, 8)) {
                            UMAvatarView(userId: spectator.userId, hasAvatar: spectator.avatar,
                                         name: spectator.name, size: dim(24, 18, 32), square: spectator.squareAvatar)
                            PlayerNameView(player: spectator, fontSize: dim(14, 12, 16), dead: false)
                                .lineLimit(1)
                            Text("(spectator)")
                                .font(.system(size: dim(13, 11, 14)))
                                .foregroundStyle(UMTheme.deadName)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .modifier(CompactTownRow(on: compact, pad: expanded ? 6 : 3))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .modifier(CompactTownList(on: compact))
        .pointerScrolling()
        .sheet(isPresented: pickingBinding) {
            if let id = pickingPlayerId {
                RoleGuessPickerSheet(
                    session: session,
                    playerName: session.player(for: id)?.name ?? "Player"
                ) { role in
                    session.pickRoleGuess(playerId: id, role: role)
                    pickingPlayerId = nil
                }
            }
        }
    }

    private func townRow(_ player: GamePlayer, dead: Bool) -> some View {
        let open = moderatingPlayerId == player.id
        return VStack(alignment: .leading, spacing: 0) {
            // Header never changes size or position; only the area below it opens.
            townRowContent(player, dead: dead)
            if canModerate(player) {
                // Always in the tree (no insert/remove); a top-anchored clipped height reveal.
                UMPlayerModerationBar(player: player, gameId: session.gameId)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if h > 0 { moderationBarHeight = h }
                    }
                    .frame(height: open ? moderationBarHeight : 0, alignment: .top)
                    .clipped()
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .listRowBackground(UMTheme.card)
        .modifier(CompactTownRow(on: compact, pad: expanded ? 6 : 3))
    }

    private func townRowContent(_ player: GamePlayer, dead: Bool) -> some View {
        HStack(spacing: dim(10, 6, 10)) {
            if session.isGameInProgress {
                RoleGuessBadge(session: session, player: player, size: dim(30, 20, 36)) {
                    pickingPlayerId = player.id
                }
            }
            if session.isolating {
                let on = session.isolatedIds.contains(player.id)
                Button {
                    if on { session.isolatedIds.remove(player.id) } else { session.isolatedIds.insert(player.id) }
                } label: {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .font(.system(size: dim(22, 16, 24)))
                        .foregroundStyle(on ? UMTheme.blood : UMTheme.muted)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(on ? "Isolated: \(player.name)" : "Isolate \(player.name)")
            }
            UMAvatarView(player: player, size: dim(36, 22, 44))
            VStack(alignment: .leading, spacing: dim(2, 0, 2)) {
                // Graveyard keeps custom name colors (dead-red is for chat lines only).
                PlayerNameView(player: player, fontSize: dim(16, 13, 17))
                    .lineLimit(1)
                    .opacity(dead && session.currentPhaseId != -2 ? 0.7 : 1)
                if player.id == session.selfId {
                    HStack(spacing: 6) {
                        Text("you").font(.caption2).foregroundStyle(UMTheme.muted)
                        if let role = session.selfRoleName {
                            Text(role).font(.caption2.weight(.semibold)).foregroundStyle(UMTheme.blood)
                        }
                    }
                } else if session.teammateIds.contains(player.id) {
                    HStack(spacing: 6) {
                        Text("teammate").font(.caption2).foregroundStyle(UMTheme.mafia)
                        if let role = session.knownRoles[player.id] {
                            Text(role.split(separator: ":").first.map(String.init) ?? role)
                                .font(.caption2)
                                .foregroundStyle(UMTheme.muted)
                        }
                    }
                }
            }
            Spacer()
            if session.readyCheckActive, !dead {
                let ready = session.readyPlayerIds.contains(player.id)
                Text(ready ? "✅" : "❌")
                    .font(.system(size: dim(15, 12, 17)))
                    .accessibilityLabel(ready ? "Ready" : "Not ready")
            }
            if canModerate(player) {
                Image(systemName: "chevron.down")
                    .foregroundStyle(UMTheme.muted)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(moderatingPlayerId == player.id ? 180 : 0))
                    .accessibilityLabel(moderatingPlayerId == player.id ? "Hide report and block" : "Report or block")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canModerate(player) else { return }
            withAnimation(Self.revealAnimation) {
                moderatingPlayerId = moderatingPlayerId == player.id ? nil : player.id
            }
        }
    }

    private var pickingBinding: Binding<Bool> {
        Binding(
            get: { pickingPlayerId != nil },
            set: { if !$0 { pickingPlayerId = nil } }
        )
    }
}

/// iPad column only: tight insets, no min row height, no extra row/section gaps.
private struct CompactTownRow: ViewModifier {
    var on: Bool
    var pad: CGFloat = 3
    func body(content: Content) -> some View {
        if on {
            content.listRowInsets(EdgeInsets(top: pad, leading: 8, bottom: pad, trailing: 8))
        } else {
            content
        }
    }
}

private struct CompactTownList: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on {
            content
                .environment(\.defaultMinListRowHeight, 0)
                #if !os(macOS)
                .listRowSpacing(0)
                .listSectionSpacing(4)
                #endif
                .contentMargins(.top, 4, for: .scrollContent)
        } else {
            content
        }
    }
}

private struct GameActPane: View {
    var session: GameSession
    /// Chosen meeting per phase (live and review), so updates don't jump the selection.
    @State private var selectedByPhase: [Int: String] = [:]

    /// Server/web order (meetings arrive in the game's meeting order).
    private var actMeetings: [VoteMeeting] {
        session.meetingsForViewing.filter {
            !$0.isVoteKick && !(session.isLiarsDice && LDState.importantMeetings.contains($0.name))
        }
    }

    private var phaseKey: Int { session.isViewingLive ? session.currentPhaseId : session.viewingPhaseId }

    /// Stable selection; default is the first meeting still needing your vote (web Game.jsx
    /// picks `!playerHasVoted && voting && canVote`), else the first meeting.
    private var selected: VoteMeeting? {
        let list = actMeetings
        if let id = selectedByPhase[phaseKey], let m = list.first(where: { $0.id == id }) { return m }
        return list.first { $0.canVote && !$0.playerHasVoted && $0.selections(of: session.selfId).isEmpty } ?? list.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.isLiarsDice {
                    LiarsDiceBoard(session: session)
                }
                if actMeetings.isEmpty, session.isLiarsDice {
                    EmptyView()
                } else if actMeetings.isEmpty {
                    Text(emptyCopy)
                        .foregroundStyle(UMTheme.muted)
                        .padding(16)
                } else if actMeetings.count == 1, let only = actMeetings.first {
                    MeetingBlock(session: session, meeting: only)
                } else {
                    meetingSwitcher
                    if let meeting = selected {
                        MeetingBlock(session: session, meeting: meeting)
                            .id(meeting.id)
                    }
                }
            }
            .padding(16)
            if session.kickMeeting != nil, !(session.selfId.map(session.isDead) ?? true) {
                kickCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .pointerScrolling()
    }

    /// Web "Vote Kick" button: shown in any phase while the veg-kick meeting is live.
    private var kickCard: some View {
        let done = session.hasKicked
        let can = session.kickMeeting?.canVote == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vote Kick").font(.headline)
                Spacer()
                if let p = session.kickProgress {
                    Text("\(p.count) / \(p.needed)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(UMTheme.muted)
                }
            }
            if let p = session.kickProgress, p.needed > 0 {
                ProgressView(value: Double(min(p.count, p.needed)), total: Double(p.needed))
                    .tint(UMTheme.blood)
            }
            Button {
                session.sendKick()
            } label: {
                Label(done ? "Kicked" : "Kick", systemImage: done ? "checkmark" : "figure.walk.departure")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(done ? UMTheme.elevated : UMTheme.blood)
            .disabled(done || !can)
            if !done && !can {
                Text("Finish your votes in every meeting to kick.")
                    .font(.caption)
                    .foregroundStyle(UMTheme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var meetingSwitcher: some View {
        let binding = Binding<String>(
            get: { selected?.id ?? "" },
            set: { selectedByPhase[phaseKey] = $0 }
        )
        return ScrollView(.horizontal, showsIndicators: false) {
            Picker("Meeting", selection: binding) {
                ForEach(actMeetings) { m in
                    Text(switcherTitle(m)).tag(m.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .accessibilityLabel("Choose meeting")
    }

    /// Dot marks a live meeting still waiting on your vote.
    private func switcherTitle(_ m: VoteMeeting) -> String {
        let needs = session.isViewingLive && m.canVote && m.selections(of: session.selfId).isEmpty
        let title = m.name == m.actionName ? m.name : m.actionName
        return needs ? "• " + title : title
    }

    private var emptyCopy: String {
        if session.spectate { return "Spectating. No actions." }
        if !session.isViewingLive { return "No actions in this phase." }
        return "No actions right now."
    }
}


private struct MeetingBlock: View {
    var session: GameSession
    var meeting: VoteMeeting
    @AppStorage("um.voteListDisplay") private var voteListDisplay = "avatars"
    @State private var textDraft = ""

    private var clickable: Bool {
        session.isViewingLive && meeting.canVote && !session.spectate
    }

    /// Web useAction `notClickable`.
    private var locked: Bool { meeting.lockedAfterVote(selfId: session.selfId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.actionName)
                    .font(.headline)
                Spacer(minLength: 8)
                if let item = meeting.itemName, !item.isEmpty {
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                }
            }
            if meeting.inputType == "text", session.isReview {
                if meeting.votesInvisible {
                    Text("Vote targets are hidden.")
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                } else {
                    reviewLines
                }
            } else if meeting.inputType == "text" {
                if clickable {
                    HStack(spacing: 8) {
                        TextField("Type…", text: $textDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {
                            let s = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !s.isEmpty else { return }
                            session.vote(meetingId: meeting.id, selection: s)
                            textDraft = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(UMTheme.blood)
                    }
                }
            } else {
                // One card row per option: [count] Name votes <their pick>; non-player options
                // ("No One", …) after a separator. Options come from the server's `targets`
                // (must-condemn setups omit "*").
                let split = splitTargets
                VStack(spacing: 6) {
                    ForEach(split.players, id: \.self) { target in
                        targetRow(target)
                    }
                    if !split.players.isEmpty, !split.others.isEmpty {
                        Divider().overlay(UMTheme.line).padding(.vertical, 2)
                    }
                    ForEach(split.others, id: \.self) { target in
                        targetRow(target)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Review: only what happened. One line per member who voted, e.g. "Bob litigated Alice";
    /// members who didn't vote and unchosen options are hidden.
    @ViewBuilder
    private var reviewLines: some View {
        let ordered: [String] = {
            var ids = meeting.members.map(\.id).filter {
                !meeting.hiddenVoterIds.contains($0) && !meeting.selections(of: $0).isEmpty
            }
            for (voter, _) in meeting.ballot where !meeting.hiddenVoterIds.contains(voter) && !ids.contains(voter) { ids.append(voter) }
            return ids
        }()
        if ordered.isEmpty {
            Text("No votes")
                .font(.caption)
                .foregroundStyle(UMTheme.muted)
        } else {
            let verb = Self.reviewVerb(meeting.actionName)
            ForEach(ordered, id: \.self) { voter in
                let selectionIds = meeting.selections(of: voter)
                let picks = selectionIds.map { session.voteLabel($0, meeting: meeting) }
                let who = Text(session.displayVoter(voter, meeting: meeting)).fontWeight(.semibold)
                let what = Text(picks.joined(separator: ", ")).fontWeight(.semibold).foregroundStyle(UMTheme.roleMention)
                let how = Text(" \(verb) ").foregroundStyle(UMTheme.muted)
                let receivedCount = selectionIds.reduce(0) { $0 + meeting.count(for: $1) }
                HStack(spacing: 8) {
                    Text("\(who)\(how)\(what)")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(receivedCount) received")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(UMTheme.muted)
                        .fixedSize()
                }
                .padding(10)
                .background(UMTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// Single-word actions read as past tense ("Litigate" -> "litigated"); multi-word meeting
    /// names (Village Vote, Mafia Kill…) fall back to the existing "votes" wording.
    static func reviewVerb(_ actionName: String) -> String {
        let words = actionName.split(separator: " ")
        guard words.count == 1 else { return "votes" }
        let w = words[0].lowercased()
        let irregular: [String: String] = [
            "vote": "voted", "shoot": "shot", "hide": "hid", "steal": "stole", "give": "gave",
            "choose": "chose", "see": "saw", "make": "made", "take": "took", "eat": "ate",
            "bite": "bit", "bind": "bound", "find": "found", "hold": "held", "read": "read",
            "send": "sent", "put": "put", "set": "set", "hit": "hit", "cut": "cut", "meet": "met",
            "sell": "sold", "tell": "told", "win": "won", "lead": "led", "feed": "fed",
            "speak": "spoke", "write": "wrote", "break": "broke", "wake": "woke", "freeze": "froze",
            "swap": "swapped", "stab": "stabbed", "rob": "robbed", "kidnap": "kidnapped",
            "spy": "spied on", "visit": "visited", "follow": "followed", "watch": "watched",
        ]
        if let v = irregular[w] { return v }
        guard w.count > 2, w.allSatisfy(\.isLetter) else { return "votes" }
        if w.hasSuffix("e") { return w + "d" }
        if w.hasSuffix("y"), let before = w.dropLast().last, !"aeiou".contains(before) {
            return String(w.dropLast()) + "ied"
        }
        return w + "ed"
    }

    /// Options in Village (player-list) order, alive players only, then non-player options
    /// ("No One", Yes/No, …) in server order. Meetings that only target dead players
    /// (e.g. revive) keep those, in player-list order.
    private var orderedTargets: [String] {
        let targets = meeting.targets
        let playerIds = Set(session.players.map(\.id))
        let alive = session.villagePlayers.map(\.id).filter(targets.contains)
        let others = targets.filter { !playerIds.contains($0) }
        if !alive.isEmpty { return alive + others }
        let deadOrdered = session.graveyardPlayers.map(\.id).filter(targets.contains)
        let rest = targets.filter { playerIds.contains($0) && !deadOrdered.contains($0) }
        return deadOrdered + rest + others
    }

    private var splitTargets: (players: [String], others: [String]) {
        let ids = Set(session.players.map(\.id))
        let all = orderedTargets
        return (all.filter(ids.contains), all.filter { !ids.contains($0) })
    }

    private var leaderCount: Int {
        meeting.targets.map { meeting.count(for: $0) }.max() ?? 0
    }

    private func targetRow(_ target: String) -> some View {
        let mine = meeting.selections(of: session.selfId).contains(target)
        let count = meeting.count(for: target)
        let canTap = clickable && !locked
        let isPlayer = session.players.contains { $0.id == target }
        let label = session.voteLabel(target, meeting: meeting)
        let pickIds: [String] = (isPlayer && !meeting.votesInvisible && !meeting.hiddenVoterIds.contains(target)) ? meeting.selections(of: target) : []
        let theirPick = pickIds.map { session.voteLabel($0, meeting: meeting) }.joined(separator: ", ")
        let avatars = voteListDisplay != "names"
        let leader = count > 0 && count == leaderCount
        return Button {
            guard canTap else { return }
            session.vote(meetingId: meeting.id, selection: target)
        } label: {
            HStack(spacing: 8) {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 26, minHeight: 20)
                    .background(leader ? Color(red: 0.78, green: 0.29, blue: 0.29) : Color(red: 0.24, green: 0.45, blue: 0.75),
                                in: Capsule())
                // Voter is always an avatar; the setting only changes how their pick is shown.
                if isPlayer, let p = session.player(for: target) {
                    UMAvatarView(player: p, size: 24)
                } else {
                    Text(label)
                        .font(.system(size: 14, weight: isPlayer ? .semibold : .regular))
                        .foregroundStyle(isPlayer ? Color.white : UMTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                if !theirPick.isEmpty {
                    Text("votes")
                        .font(.system(size: 11))
                        .foregroundStyle(UMTheme.muted)
                        .fixedSize()
                    if avatars, pickIds.allSatisfy({ session.player(for: $0) != nil }) {
                        HStack(spacing: 4) {
                            ForEach(pickIds, id: \.self) { id in
                                if let tp = session.player(for: id) {
                                    UMAvatarView(player: tp, size: 22)
                                }
                            }
                        }
                    } else {
                        Text(theirPick)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(UMTheme.roleMention)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? UMTheme.blood.opacity(0.22) : UMTheme.elevated.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(mine ? UMTheme.blood.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canTap)
        .accessibilityLabel("\(label), \(count) vote\(count == 1 ? "" : "s")\(theirPick.isEmpty ? "" : ", votes \(theirPick)")\(mine ? ", your vote" : "")")
    }
}


#if canImport(UIKit)
private struct KeyboardExpandedBinder: ViewModifier {
    @Binding var expanded: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let height = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                expanded = height > 160
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                expanded = false
            }
    }
}
#endif

private extension View {
    func bindKeyboardExpanded(_ expanded: Binding<Bool>) -> some View {
        #if canImport(UIKit)
        modifier(KeyboardExpandedBinder(expanded: expanded))
        #else
        self
        #endif
    }
}
