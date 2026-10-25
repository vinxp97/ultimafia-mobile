import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage("um.chatLayout") private var chatLayout: ChatLayout = .standard
    @AppStorage("um.showTypingIndicator") private var showTypingIndicator = true
    @AppStorage("um.showNameAutofill") private var showTabButton = true
    @AppStorage("um.showEmoteAutocomplete") private var showEmoteAutocomplete = true
    @AppStorage("um.showSetupGuides") private var showSetupGuides = true
    @AppStorage("um.showVotingLog") private var showVotingLog = true
    @AppStorage("um.chatIndentUserMessages") private var indentUserMessages = false
    @AppStorage(UMChatPrefs.spaceAfterAutocompleteKey) private var spaceAfterAutocomplete = true
    @AppStorage("um.hideTerminology") private var hideTerminology = false
    @AppStorage(UMSpeechLM.enabledKey) private var dictationEnabled = false
    @AppStorage("um.playerListSize") private var playerListSize = "compact"
    @AppStorage(UMActLayout.key) private var actLayout = UMActLayout.tabs
    @AppStorage(UMGameStatusBar.key) private var gameStatusBar = UMGameStatusBar.hide
    @AppStorage("um.musicVolume") private var musicVolume = 1.0
    @AppStorage("um.sfxVolume") private var sfxVolume = 1.0
    @AppStorage("um.deathSoundVolume") private var deathSoundVolume = 1.0
    @AppStorage(GameAudio.pregameMusicKey) private var pregameMusicVolume = 1.0
    @AppStorage(GameAudio.alertKey) private var alertVolume = 1.0
    @State private var confirmMuteAlerts = false
    @State private var confirmClearCache = false
    @State private var confirmSignOut = false
    @State private var cacheBytes: Int64 = 0
    @State private var clearedMessage: String?
    @State private var trophies: [UMTrophy] = []
    @State private var selectedTrophy: UMTrophy?

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.youPath) {
            ScrollViewReader { proxy in
            List {
                Section {
                    let me = app.user?.cosmeticPlayer
                    HStack(spacing: 14) {
                        if let me {
                            UMAvatarView(player: me, size: 52)
                            VStack(alignment: .leading, spacing: 6) {
                                PlayerNameView(player: me, fontSize: 20)
                                // Live /user/info balances (web navbar fields): emoji + number only.
                                HStack(spacing: 14) {
                                    balance("🪙", app.user?.coins?.value ?? 0, "coins")
                                    balance("💛", app.user?.goldHearts?.value ?? 0, "gold hearts")
                                    balance("❤️", app.user?.redHearts?.value ?? 0, "red hearts")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(UMTheme.card)
                }
                Section("Chat") {
                    Picker("Message layout", selection: $chatLayout) {
                        ForEach(ChatLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                    .listRowBackground(UMTheme.card)
                    Toggle("Show Typing Indicator", isOn: $showTypingIndicator)
                        .listRowBackground(UMTheme.card)
                    Toggle("Show Autofill Name", isOn: $showTabButton)
                        .listRowBackground(UMTheme.card)
                    Toggle("Show Autofill Emoji", isOn: $showEmoteAutocomplete)
                        .listRowBackground(UMTheme.card)
                    Toggle("Show Voting Log", isOn: $showVotingLog)
                        .listRowBackground(UMTheme.card)
                    Toggle("Indent Player Messages", isOn: $indentUserMessages)
                        .listRowBackground(UMTheme.card)
                    Toggle("Space after autocomplete", isOn: $spaceAfterAutocomplete)
                        .listRowBackground(UMTheme.card)
                    Toggle("Show Setup Guides", isOn: $showSetupGuides)
                        .listRowBackground(UMTheme.card)
                    Toggle("Dictation", isOn: $dictationEnabled)
                        .listRowBackground(UMTheme.card)
                        .onChange(of: dictationEnabled) { _, on in
                            if on {
                                Task { await RoleCatalog.shared.load(); UMSpeechLM.prepareIfNeeded() }
                            } else {
                                UMDictation.shared.stop()
                            }
                        }
                    Toggle("Hide Game Terminology", isOn: $hideTerminology)
                        .listRowBackground(UMTheme.card)
                    playerListSizePicker
                }
                if !trophies.isEmpty {
                    Section("Trophies") {
                        ForEach(trophies) { t in
                            Button { selectedTrophy = t } label: {
                                HStack(spacing: 12) {
                                    UMTrophyIcon(trophy: t, size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.name).foregroundStyle(.white)
                                        Text(t.awardedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Date unknown")
                                            .font(.caption)
                                            .foregroundStyle(UMTheme.muted)
                                    }
                                }
                            }
                            .listRowBackground(UMTheme.card)
                        }
                    }
                }
                Section {
                    NavigationLink("Custom Emojis & Stickers") { CustomMediaOrderView() }
                        .listRowBackground(UMTheme.card)
                }
                DMNotificationSettingsSection()
                Section("Audio") {
                    volumeRow("Music Volume", $musicVolume) {
                        GameMusic.applyVolume()
                        GameWinMusic.applyVolume()
                    }
                    volumeRow("Sound Volume", $sfxVolume) {
                        GameSFX.applyVolume()
                        ReadyBell.applyVolume()
                    }
                    volumeRow("Death Sound Volume", $deathSoundVolume) {
                        GameSFX.applyDeathVolume()
                    }
                    volumeRow("Pregame Music Volume", $pregameMusicVolume) {
                        GameMusic.applyVolume()
                    }
                    volumeRow("Alert Volume", $alertVolume) {
                        if alertVolume == 0 { confirmMuteAlerts = true }
                        GameSFX.applyVolume()
                        ReadyBell.applyVolume()
                    }
                }
                if let game = app.user?.inGameId {
                    Section("Status") {
                        row("In game", game)
                    }
                }
                Section {
                    Button("Clear Cached Media", role: .destructive) { confirmClearCache = true }
                        .listRowBackground(UMTheme.card)
                } header: {
                    Text("Storage")
                } footer: {
                    Text(clearedMessage ?? "Avatars, custom emotes/stickers, images, fonts and sounds saved on this device (shared by all accounts): \(Self.mb(cacheBytes)).")
                }
                Section {
                    HStack {
                        Text("Device")
                        Spacer()
                        Text(String(DeviceIdentity.installId.prefix(8)) + "…")
                            .foregroundStyle(UMTheme.muted)
                            .monospaced()
                            .textSelection(.enabled)
                    }
                    .listRowBackground(UMTheme.card)
                } footer: {
                    Text("Install ID, stored only on this device.")
                }
                Section {
                    NavigationLink("Advanced Settings") { AdvancedSettingsView() }
                        .listRowBackground(UMTheme.card)
                    if app.seatedGameId == nil {
                        Button("Add Another Account") { app.addAnotherAccount() }
                            .listRowBackground(UMTheme.card)
                    }
                    Button("Sign out", role: .destructive) {
                        // Signing out while a live game is running leaves it for you, so it asks
                        // first, exactly like the Leave action does.
                        if app.game?.leaveNeedsConfirm == true {
                            confirmSignOut = true
                        } else {
                            Task { await app.signOut() }
                        }
                    }
                    .listRowBackground(UMTheme.card)
                }
                Section {
                    UMCreditsFooter()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                }
            }
            .navigationDestination(for: AppModel.Route.self) { route in
                switch route {
                case .profile(let id, let name):
                    UMYouPushedProfile(userId: id, userName: name)
                case .family(let id, let name):
                    UMYouBackBar { FamilyView(familyId: id, familyName: name) }
                default:
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(UMTheme.bg.ignoresSafeArea())
            .navigationTitle("You")
            .umMacLobbyButton(app)
            // Web asks before silencing alerts; declining leaves them at 10%.
            .task { cacheBytes = UMCacheLocation.bytes() }
            .task { await app.refreshUserInfo() }
            .refreshable { await app.refreshUserInfo() }
            .task(id: app.user?.id) { await loadTrophies() }
            .sheet(item: $selectedTrophy) { UMTrophyDetailSheet(trophy: $0) }
            .confirmationDialog("Sign out and leave the game?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out and leave", role: .destructive) { Task { await app.signOut() } }
                Button("Stay", role: .cancel) {}
            } message: {
                Text(app.game?.participationRequired == true
                     ? "Your participation is still required in this game. Signing out leaves it and may be penalised."
                     : "Signing out will leave the game you're in.")
            }
            .confirmationDialog("Clear cached media?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    Task {
                        let freed = UMCacheLocation.bytes()
                        await UMCustomAssetCache.shared.clear()
                        UMImageCache.shared.clearAll()
                        for dir in [UMCacheLocation.nameFonts, UMCacheLocation.sounds, UMProfileCache.directory, UMCacheLocation.anonDecks] {
                            try? FileManager.default.removeItem(at: dir)
                        }
                        UMTerminology.shared.cacheCleared()
                        cacheBytes = 0
                        clearedMessage = "Cleared \(Self.mb(freed)) of cached media."
                    }
                }
            } message: {
                Text("Removes cached avatars, custom emotes and stickers, images, fonts and sounds for all accounts. They download again when needed. Saved accounts, sign-ins, emote order and settings are kept.")
            }
            .alert("Disable alert sounds?", isPresented: $confirmMuteAlerts) {
                Button("Disable", role: .destructive) {}
                Button("Keep at 10%", role: .cancel) { alertVolume = 0.1 }
            } message: {
                Text("You won't be alerted when a game starts or when you're about to be kicked for inactivity.")
            }
            #if DEBUG
            .task {
                // `-UMDiagSettings` (with -UMDiagReplay): open on the Action Layout picker for screenshots.
                guard ProcessInfo.processInfo.arguments.contains("-UMDiagSettings") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(UMActLayout.key, anchor: .center)
            }
            #endif
            }
        }
    }

    private func volumeRow(_ title: String, _ value: Binding<Double>, onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(UMTheme.muted)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...1, step: 0.05)
                .tint(UMTheme.blood)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
        }
        .listRowBackground(UMTheme.card)
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(UMTheme.muted)
        }
        .listRowBackground(UMTheme.card)
    }

    private func loadTrophies() async {
        guard let id = app.user?.id, !id.isEmpty,
              let blob = try? await APIClient.shared.userProfile(id) else { return }
        trophies = UMTrophy.list(from: blob)
    }

}

/// Profile pushed on the You tab (e.g. the "App Developed by Z" link): same view as avatar taps.
/// The system navigation bar already provides Back, so no extra Back bar here.
struct UMYouPushedProfile: View {
    var userId: String
    var userName: String
    @Environment(AppModel.self) private var app

    var body: some View {
        UserProfileView(userId: userId, userName: userName)
    }
}

/// Visible "‹ Back" over a screen pushed on the You stack.
struct UMYouBackBar<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(AppModel.self) private var app

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button {
                        if !app.youPath.isEmpty { app.youPath.removeLast() }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UMTheme.blood)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Spacer()
                }
                .background(UMTheme.bg)
            }
    }
}

/// You-page credits. "Z" (user id Fy2Ee8BH9, the site's /user/Z) opens Z's in-app profile
/// immediately; the profile view shows its own loading state.
struct UMCreditsFooter: View {
    static let devName = "Z"
    static let devUserId = UMProfileCache.devUserId
    @Environment(AppModel.self) private var app
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("App Developed by ")
                Button(Self.devName) {
                    app.youPath.append(.profile(id: Self.devUserId, name: Self.devName))
                }
                .buttonStyle(.borderless)
                .underline()
                .foregroundStyle(UMTheme.blood)
                .accessibilityHint("Opens Z's profile")
            }
            Text("UltiMafia © \(String(Calendar.current.component(.year, from: Date()))) - VCCC LLC - All Rights Reserved")
                // Hidden: long-press opens the diagnostics log.
                .onLongPressGesture(minimumDuration: 1.0) { showDiagnostics = true }
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .font(.caption2)
        .foregroundStyle(UMTheme.muted)
        .multilineTextAlignment(.center)
    }
}


extension ProfileView {
    fileprivate func balance(_ emoji: String, _ value: Int, _ label: String) -> some View {
        Text("\(emoji) \(value)")
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("\(value) \(label)")
    }
}

extension ProfileView {
    /// Three-column (regular-width, landscape) Village column only.
    @ViewBuilder fileprivate var playerListSizePicker: some View {
        if hSizeClass == .regular || UMPlatformInfo.isMac {
            settingPicker("Player List Size", caption: "Size of the player list on iPad landscape.",
                          selection: $playerListSize, options: [("Compact", "compact"), ("Expanded", "expanded")])
        }
        settingPicker("Action Layout", caption: "Legacy stacks every action in one scrolling list. Modern switches between actions with tabs.",
                      selection: $actLayout, options: [("Legacy", UMActLayout.stack), ("Modern", UMActLayout.tabs)])
            .id(UMActLayout.key)
        #if os(iOS)
        // The Mac (native, or the iPad app on a Mac) has no system status bar to show or hide.
        if !UMPlatformInfo.isMac {
            settingPicker("Status Bar", caption: "Show or hide the clock, battery and Wi-Fi while in a game.",
                          selection: $gameStatusBar, options: [("Hide", UMGameStatusBar.hide), ("Show", UMGameStatusBar.show)])
        }
        #endif
    }

    fileprivate func settingPicker(_ title: String, caption: String, selection: Binding<String>,
                                   options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Picker(title, selection: selection) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(caption)
                .font(.caption)
                .foregroundStyle(UMTheme.muted)
        }
        .padding(.vertical, 4)
        .listRowBackground(UMTheme.card)
    }
}
