#if os(macOS)
import SwiftUI
import AppKit

/// Native Mac shell: a persistent sidebar (Lobby, Messages, Game, You) in place of the iOS tab bar.
/// Every section stays alive in the detail column so its navigation stack survives switching.
/// The lobby shows public chat beside the game list; a live game gets the whole detail column.
struct NativeAppTabs: View {
    @Environment(AppModel.self) private var app
    var selected: UMAppSection
    var mentionBadge: Int
    var showsBar: Bool
    var showsMessages: Bool
    var messagesBadge: Int
    var play: AnyView
    var leaderboard: AnyView = AnyView(EmptyView())
    var messages: AnyView
    var game: AnyView
    var you: AnyView
    var onSelect: (UMAppSection) -> Void

    @State private var columns: NavigationSplitViewVisibility = .all

    private var sections: [UMAppSection] {
        UMAppSection.allCases.filter { $0 != .messages || showsMessages }
    }

    private func badge(_ s: UMAppSection) -> Int {
        switch s {
        case .messages: messagesBadge
        case .game: mentionBadge
        default: 0
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ultimafia")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(UMTheme.muted)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    ForEach(sections) { s in
                        SidebarRow(title: s == .you ? "Profile" : s.title, symbol: s.symbol,
                                   badge: badge(s), selected: selected == s,
                                   shortcut: (UMAppSection.allCases.firstIndex(of: s) ?? 0) + 1) {
                            onSelect(s)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)
            .background(UMTheme.card)
            .safeAreaInset(edge: .bottom) {
                if app.game != nil || app.seatedGameId != nil {
                    Button { app.select(.game) } label: {
                        Label("Game in progress", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UMTheme.blood)
                    .padding(10)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            ZStack {
                page(.play) {
                    if showsMessages {
                        HSplitView {
                            play.frame(minWidth: 460, maxWidth: .infinity)
                            MessagesView(mode: .publicChat).environment(app)
                                .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
                        }
                    } else {
                        play
                    }
                }
                page(.leaderboard) { leaderboard }
                page(.messages) { messages }
                page(.game) { game }
                page(.you) { you }
            }
            .background(UMTheme.bg)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { app.macBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .help("Back (⌘[)")
                    .disabled(!app.macCanGoBack)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if selected == .play {
                    Button { Task { await app.refreshLobby() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.help("Refresh the lobby (⌘R)")
                    Button { app.openHost() } label: { Label("Host", systemImage: "plus") }
                        .help("Host a game (⌘N)")
                }
                if app.game != nil || app.seatedGameId != nil {
                    if selected != .game {
                        Button { app.select(.game) } label: { Label("Return to Game", systemImage: "gamecontroller") }
                    }
                    Button(role: .destructive) { app.requestLeave() } label: {
                        Label("Leave Game", systemImage: "rectangle.portrait.and.arrow.right")
                    }.help("Leave the game (⇧⌘L)")
                }
            }
        }
    }

    private struct SidebarRow: View {
        var title: String
        var symbol: String
        var badge: Int
        var selected: Bool
        var shortcut: Int
        var action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(selected ? .white : UMTheme.blood)
                    Text(title)
                    Spacer(minLength: 4)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.25) : UMTheme.blood))
                    }
                }
                .font(.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? UMTheme.blood.opacity(0.85) : (hover ? Color.white.opacity(0.07) : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("\(title) (⌘\(shortcut))")
            .accessibilityLabel(badge > 0 ? "\(title), \(badge) new" : title)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    @ViewBuilder
    private func page<C: View>(_ s: UMAppSection, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .opacity(selected == s ? 1 : 0)
            .allowsHitTesting(selected == s)
            .accessibilityHidden(selected != s)
    }
}

/// Menu bar: Go (⌘1–4, ⌘[), Game (Host, Refresh, Leave). Settings (⌘,) is its own scene.
struct UMMacNativeCommands: Commands {
    let app: AppModel

    private var inGame: Bool { app.game != nil || app.seatedGameId != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Host Game…") { app.section = .play; app.openHost() }
                .keyboardShortcut("n")
                .disabled(!app.isSignedIn)
        }
        CommandMenu("Go") {
            ForEach(Array(UMAppSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s == .you ? "Profile" : s.title) { app.select(s) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .disabled(!app.isSignedIn || (s == .messages && inGame))
            }
            Divider()
            Button("Back") { app.macBack() }
                .keyboardShortcut("[")
                .disabled(!app.isSignedIn || !app.macCanGoBack)
        }
        CommandMenu("Game") {
            Button("Refresh Lobby") { Task { await app.refreshLobby() } }
                .keyboardShortcut("r")
                .disabled(!app.isSignedIn)
            Button("Return to Game") { app.select(.game) }
                .disabled(!inGame)
            Divider()
            Button("Leave Game") { app.requestLeave() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!inGame)
        }
    }
}

/// Settings window (⌘,): Chat (the You page's chat toggles, same stored values) and Advanced.
struct UMMacSettingsScene: View {
    @Environment(AppModel.self) private var app
    @AppStorage(UMChatPrefs.spaceAfterAutocompleteKey) private var spaceAfterAutocomplete = true
    @AppStorage("um.showNameAutofill") private var showNameAutofill = true
    @AppStorage("um.showEmoteAutocomplete") private var showEmoteAutocomplete = true
    @AppStorage("um.chatIndentUserMessages") private var indentUserMessages = false

    var body: some View {
        TabView {
            Form {
                Section("Chat") {
                    Toggle("Show Autofill Name", isOn: $showNameAutofill)
                    Toggle("Show Autofill Emoji", isOn: $showEmoteAutocomplete)
                    Toggle("Indent Player Messages", isOn: $indentUserMessages)
                    Toggle("Space after autocomplete", isOn: $spaceAfterAutocomplete)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack {
                if app.isSignedIn {
                    AdvancedSettingsView()
                } else {
                    ContentUnavailableView("Sign in to change settings", systemImage: "person.crop.circle")
                }
            }
            .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
    }
}

#if DEBUG
/// `-UMMacSnapshot <path> [seconds]`: once the main window is up, waits `seconds` and writes it to
/// a PNG (inside the sandbox container) so screenshots don't need Screen Recording permission.
/// A shell-launched app may only get its first window when it's activated, so this polls for it.
enum UMMacNativeSnapshot {
    private static var fallback: NSWindow?
    static func scheduleIfRequested(root: @escaping () -> AnyView) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UMMacSnapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let delay = (i + 2 < args.count ? Double(args[i + 2]) : nil) ?? 6
        // Fallback: if AppKit hasn't opened the scene's window (no activation), host the same root
        // view in a plain window so the snapshot still shows real UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard mainWindow() == nil else { return }
            let host = NSHostingView(rootView: root())
            host.sceneBridgingOptions = .all
            let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 900),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.orderFrontRegardless()
            fallback = w
            NSLog("UMMacSnapshot: using a fallback window")
        }
        waitForWindow(tries: 120) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // The scene's own window wins over the fallback once it exists; any other visible
                // window is written alongside as <name>-2.png, <name>-3.png.
                let windows = (NSApp?.windows ?? []).filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
                    .sorted { ($0 === fallback ? 1 : 0) < ($1 === fallback ? 1 : 0) }
                for (n, w) in windows.enumerated() {
                    write(w, to: n == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(n + 1).png"))
                }
            }
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp?.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    private static func waitForWindow(tries: Int, _ then: @escaping (NSWindow) -> Void) {
        if let w = mainWindow() { return then(w) }
        guard tries > 0 else { return NSLog("UMMacSnapshot: no window") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForWindow(tries: tries - 1, then) }
    }

    private static func write(_ window: NSWindow, to path: String) {
        guard let content = window.contentView else { return }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Note: cacheDisplay can't draw the Liquid Glass sidebar column (it comes out as a blank
        // strip); the rest of the window is exact.
        let data = rep.representation(using: .png, properties: [:])
        do {
            try data?.write(to: URL(fileURLWithPath: path))
            NSLog("UMMacSnapshot: wrote %@", path)
        } catch {
            NSLog("UMMacSnapshot: %@", String(describing: error))
        }
    }
}

/// `-UMDiagShell [play|messages|game|you]`: the real Mac shell (sidebar, toolbar, lobby + chat)
/// with demo chat and the synthetic replay game, for screenshots without an account.
struct DiagShellView: View {
    @Environment(AppModel.self) private var app

    private static let demo: Void = UMChatStore.shared.loadDemo(selfId: "me")

    init(section: String) {
        _ = Self.demo
        initial = UMAppSection(rawValue: section) ?? .play
    }
    private let initial: UMAppSection
    @State private var started = false

    var body: some View {
        NativeAppTabs(
            selected: app.section,
            mentionBadge: 0,
            showsBar: true,
            showsMessages: app.game == nil,
            messagesBadge: app.game == nil ? UMChatStore.shared.unreadDMCount : 0,
            play: AnyView(LobbyView()),
            messages: AnyView(MessagesView(mode: .publicChat)),
            game: AnyView(Group {
                if app.section == .game || app.game != nil { DiagReplayView() }
                else { ContentUnavailableView("No game", systemImage: "gamecontroller") }
            }),
            you: AnyView(ContentUnavailableView("Profile", systemImage: "person.crop.circle",
                                                description: Text("Signed-out demo"))),
            onSelect: { app.select($0) }
        )
        .onAppear { if !started { started = true; app.section = initial } }
    }
}
#endif
#endif
