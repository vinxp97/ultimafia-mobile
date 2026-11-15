import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Messages tab (hidden in games): Public chat (the site's home chat rooms) or Direct messages.
struct MessagesView: View {
    @Environment(AppModel.self) private var app
    @State private var store = UMChatStore.shared
    @State private var mode: Mode = .publicChat
    @State private var path: [String] = []
    @State private var composing = false

    enum Mode: String, CaseIterable, Identifiable {
        case publicChat = "Public chat", direct = "Direct messages"
        var id: String { rawValue }
    }

    init(mode: Mode = .publicChat) {
        _mode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Chat", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        if m == .direct, store.unreadDMCount > 0 {
                            Text("\(m.rawValue) (\(store.unreadDMCount))").tag(m)
                        } else {
                            Text(m.rawValue).tag(m)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                switch mode {
                case .publicChat: PublicChatPane(store: store)
                case .direct: DMListView(store: store)
                }
            }
            .background(UMTheme.bg.ignoresSafeArea())
            .navigationTitle("Messages")
            .umMacLobbyButton(app)
            .umInlineTitle()
            .toolbar {
                if mode == .direct {
                    ToolbarItem(placement: .umTrailing) {
                        Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New message")
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                DMThreadView(store: store, channelId: id)
            }
            .sheet(isPresented: $composing) {
                NewMessageView(store: store)
            }
            .onChange(of: store.focusChannelId) { _, id in
                guard let id else { return }
                mode = .direct
                composing = false
                path = [id]
                store.focusChannelId = nil
            }
            .onAppear {
                if let id = store.focusChannelId {
                    mode = .direct
                    path = [id]
                    store.focusChannelId = nil
                }
            }
        }
    }
}

// MARK: Public chat

private struct PublicChatPane: View {
    var store: UMChatStore
    @State private var roomId: String?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if store.rooms.count > 1 {
                Picker("Room", selection: Binding(get: { roomId ?? store.rooms.first?.id }, set: { roomId = $0 })) {
                    ForEach(store.rooms) { Text($0.name ?? "Room").tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            }
            if !store.connected {
                ProgressView("Connecting to chat…").frame(maxHeight: .infinity)
            } else {
                ChatTranscript(store: store)
                ChatComposerBar(draft: $draft, placeholder: "Message public chat", disabled: false) {
                    store.send(draft)
                    draft = ""
                }
            }
        }
        .onAppear(perform: openRoom)
        .onChange(of: store.rooms) { _, _ in openRoom() }
        .onChange(of: roomId) { _, _ in openRoom() }
        .onDisappear { if let id = currentRoom { store.closeView(id) } }
    }

    private var currentRoom: String? { roomId ?? store.rooms.first?.id }

    private func openRoom() {
        guard let id = currentRoom, store.currentChannelId != id else { return }
        store.open(id)
    }
}

// MARK: DMs

private struct DMListView: View {
    var store: UMChatStore

    var body: some View {
        if store.directs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40)).foregroundStyle(UMTheme.muted)
                Text("No conversations yet").font(.headline)
                Text("Tap the pencil to message one or more players.")
                    .font(.subheadline).foregroundStyle(UMTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.directs) { ch in
                    NavigationLink(value: ch.id) {
                        HStack(spacing: 10) {
                            let others = ch.others(selfId: store.selfId)
                            UMAvatarView(userId: others.first?.id, hasAvatar: others.first?.avatar ?? false,
                                         name: others.first?.name ?? "", size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.title(selfId: store.selfId))
                                    .font(.body.weight(store.unread.contains(ch.id) ? .bold : .regular))
                                    .lineLimit(1)
                                if let s = ch.snippet {
                                    Text(s).font(.subheadline).foregroundStyle(UMTheme.muted).lineLimit(1)
                                }
                                if ch.lastMessageDate > .distantPast {
                                    Text(ch.lastMessageDate, style: .relative)
                                        .font(.caption).foregroundStyle(UMTheme.muted)
                                }
                            }
                            Spacer()
                            if store.unread.contains(ch.id) {
                                Circle().fill(UMTheme.blood).frame(width: 9, height: 9)
                            }
                        }
                    }
                    .listRowBackground(UMTheme.card)
                    .swipeActions {
                        Button("Close", role: .destructive) { store.closeDM(ch.id) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

struct DMThreadView: View {
    var store: UMChatStore
    var channelId: String
    @State private var draft = ""
    @State private var blocked: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if !blocked.isEmpty {
                Label("\(blocked.joined(separator: ", ")) only accept\(blocked.count == 1 ? "s" : "") DMs from friends. The server will reject messages until they add you as a friend.",
                      systemImage: "person.badge.shield.checkmark")
                    .font(.footnote)
                    .foregroundStyle(UMTheme.mafia)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UMTheme.card)
            }
            ChatTranscript(store: store)
            ChatComposerBar(draft: $draft, placeholder: "Message", disabled: !blocked.isEmpty || store.inGame) {
                store.send(draft)
                draft = ""
            }
        }
        .background(UMTheme.bg.ignoresSafeArea())
        .navigationTitle(store.channel(channelId)?.title(selfId: store.selfId) ?? "Message")
        .umInlineTitle()
        .onAppear { store.open(channelId) }
        .onDisappear { store.closeView(channelId) }
        .task(id: channelId) {
            guard let ch = store.channel(channelId) else { return }
            var names: [String] = []
            for u in ch.others(selfId: store.selfId) where await UMChatStore.dmBlockReason(for: u.id) != nil {
                names.append(u.name)
            }
            blocked = names
        }
    }
}

// MARK: New message (multi-recipient)

struct NewMessageView: View {
    var store: UMChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipients: [UMChatUser] = []
    @State private var blockReasons: [String: String] = [:]
    @State private var query = ""
    @State private var results: [UMChatUser] = []
    @State private var searching = false
    @State private var text = ""
    @FocusState private var queryFocused: Bool

    private var canSend: Bool {
        !recipients.isEmpty && blockReasons.isEmpty && !store.inGame
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                RecipientChips(recipients: recipients, blockReasons: blockReasons) { u in
                    recipients.removeAll { $0.id == u.id }
                    blockReasons[u.id] = nil
                }
                HStack {
                    Text("To:").foregroundStyle(UMTheme.muted)
                    TextField("Type a name", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($queryFocused)
                        .onSubmit { if let best = results.first { add(best) } }
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(12)
                .background(UMTheme.card)
                if !query.isEmpty {
                    List(results) { u in
                        Button { add(u) } label: {
                            HStack {
                                UMAvatarView(userId: u.id, hasAvatar: u.avatar, name: u.name, size: 28)
                                Text(u.name).foregroundStyle(.white)
                                Spacer()
                                if u.id == results.first?.id {
                                    Text("Return to add").font(.caption2).foregroundStyle(UMTheme.muted)
                                }
                            }
                        }
                        .listRowBackground(u.id == results.first?.id ? UMTheme.elevated : UMTheme.card)
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    if !blockReasons.isEmpty {
                        Text(blockReasons.keys.compactMap { id in recipients.first { $0.id == id }?.name }
                            .joined(separator: ", ") + " only accept DMs from friends.")
                            .font(.footnote).foregroundStyle(UMTheme.mafia).padding(12)
                    }
                    UMDictationBanner().clipShape(Capsule()).padding(.horizontal, 12)
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(3...8)
                            .padding(12)
                            .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        UMMicButton(text: $text, maxLength: UMConfig.maxChatLength,
                                    vocab: { DictationVocab(players: recipients.map(\.name)) }, glass: false)
                            .padding(.top, 6)
                    }
                    .padding(12)
                    Spacer()
                }
            }
            .background(UMTheme.bg.ignoresSafeArea())
            .navigationTitle("New Message")
            .umInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        store.startDM(userIds: recipients.map(\.id), firstMessage: text)
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
            .onAppear { queryFocused = true }
            // Real-time lookup, debounced like the site's user search.
            .task(id: query) {
                let q = query
                guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                searching = true
                let found = await UMChatStore.searchUsers(q)
                guard !Task.isCancelled else { return }
                searching = false
                let chosen = Set(recipients.map(\.id))
                results = found.filter { $0.id != store.selfId && !chosen.contains($0.id) }
            }
        }
    }

    private func add(_ u: UMChatUser) {
        guard !recipients.contains(where: { $0.id == u.id }) else { return }
        recipients.append(u)
        query = ""
        results = []
        Task {
            if let reason = await UMChatStore.dmBlockReason(for: u.id) { blockReasons[u.id] = reason }
        }
    }
}

private struct RecipientChips: View {
    var recipients: [UMChatUser]
    var blockReasons: [String: String]
    var onRemove: (UMChatUser) -> Void

    var body: some View {
        if !recipients.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(recipients) { u in
                        let blocked = blockReasons[u.id] != nil
                        Button { onRemove(u) } label: {
                            HStack(spacing: 4) {
                                if blocked { Image(systemName: "lock.fill").font(.caption2) }
                                Text(u.name).font(.subheadline.weight(.semibold))
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(blocked ? UMTheme.mafia.opacity(0.3) : UMTheme.blood.opacity(0.3), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(u.name)\(blocked ? ", only accepts DMs from friends" : "")")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

// MARK: Shared pieces

private struct ChatTranscript: View {
    var store: UMChatStore
    #if os(macOS)
    private static let bottomId = "chat-transcript-bottom"
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.hasMoreHistory && !store.messages.isEmpty {
                        Button("Load earlier") { store.loadOlder() }
                            .font(.caption).frame(maxWidth: .infinity)
                    }
                    ForEach(store.messages) { m in
                        HStack(alignment: .top, spacing: 8) {
                            UMAvatarView(userId: m.sender.id, hasAvatar: m.sender.avatar, name: m.sender.name, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.sender.name).font(.subheadline.weight(.semibold))
                                    Text(m.date, style: .time).font(.caption2).foregroundStyle(UMTheme.muted)
                                }
                                Text(m.content).font(.body).textSelection(.enabled)
                            }
                        }
                        .id(m.id)
                    }
                    #if os(macOS)
                    // True bottom: the sentinel sits below the last message's bottom padding, so
                    // "latest" lands with the whole last line clear of the composer.
                    Color.clear.frame(height: 1).id(Self.bottomId)
                    #endif
                }
                .padding(12)
                #if os(macOS)
                .padding(.bottom, 12)
                #endif
            }
            #if os(macOS)
            .defaultScrollAnchor(.bottom)
            #endif
            .onChange(of: store.messages.last?.id) { _, id in
                #if os(macOS)
                if id != nil { withAnimation { proxy.scrollTo(Self.bottomId, anchor: .bottom) } }
                #else
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                #endif
            }
            .onAppear {
                #if os(macOS)
                // Rows lay out after the first pass on AppKit; land on the true bottom again once
                // they have.
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                #else
                if let id = store.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                #endif
            }
        }
        .overlay(alignment: .top) {
            if let err = store.lastError {
                Text(err).font(.footnote).padding(8)
                    .background(UMTheme.mafia.opacity(0.9), in: Capsule())
                    .padding(.top, 6)
                    .onTapGesture { store.lastError = nil }
                    .task { try? await Task.sleep(for: .seconds(4)); store.lastError = nil }
            }
        }
    }
}

private struct ChatComposerBar: View {
    @Binding var draft: String
    var placeholder: String
    var disabled: Bool
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 18))
                .onChange(of: draft) { _, v in if v.count > UMConfig.maxChatLength { draft = String(v.prefix(UMConfig.maxChatLength)) } }
                .onSubmit(onSend)
            UMMicButton(text: $draft, maxLength: UMConfig.maxChatLength, vocab: { DictationVocab() }, glass: false)
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(disabled || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .disabled(disabled)
        .safeAreaInset(edge: .top, spacing: 4) { UMDictationBanner().clipShape(Capsule()) }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(UMTheme.bg)
    }
}

/// You tab: this device's push notifications, as their own list (Vinman). The master switch hides
/// every per-type row when off; turning it on turns every type on, and each can then be switched
/// off on its own. Settings are per device (iCloud key-value store, keyed by the install id) and
/// ride along with the device token to the server, which filters pushes per device.
struct DMNotificationSettingsSection: View {
    @State private var prefs = UMPushPrefs.shared
    @AppStorage(UMDMNotify.soundKey) private var sound = true
    @AppStorage(UMDMNotify.previewKey) private var preview = true
    @State private var systemDenied = false
    @State private var settingsAlert = false

    /// No moving animations anywhere in this list (Vinman).
    private func instantly(_ body: () -> Void) {
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t, body)
    }

    private var masterBinding: Binding<Bool> {
        Binding(get: { prefs.master }, set: { on in
            if !on { instantly { UMNotifyMaster.set(false) }; return }
            UMNotifyMaster.requestOn { r in
                instantly {
                    systemDenied = r == .denied
                    if r == .denied { settingsAlert = true }
                }
            }
        })
    }

    private func typeBinding(_ t: UMPushType) -> Binding<Bool> {
        Binding(get: { prefs.isOn(t) }, set: { on in instantly { prefs.set(t, on) } })
    }

    var body: some View {
        Section {
            Toggle("Push Notifications", isOn: masterBinding)
                .listRowBackground(UMTheme.card)
                .alert("Notifications are off", isPresented: $settingsAlert) {
                    Button("Open Settings") { UMNotifyMaster.openSettings() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Notifications for UltiMafia are disabled in iOS Settings. Turn them on there, then come back.")
                }
            if systemDenied && !prefs.master {
                Button {
                    UMNotifyMaster.openSettings()
                } label: {
                    HStack {
                        Label("Allow notifications in iOS Settings", systemImage: "bell.slash")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app").foregroundStyle(UMTheme.muted)
                    }
                }
                .foregroundStyle(.white)
                .listRowBackground(UMTheme.card)
            }
            if prefs.master {
                ForEach(UMPushType.allCases, id: \.self) { t in
                    Toggle(isOn: typeBinding(t)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title)
                            Text(t.detail).font(.caption).foregroundStyle(UMTheme.muted)
                        }
                    }
                    .listRowBackground(UMTheme.card)
                    if t == .dms && prefs.isOn(.dms) {
                        Toggle("Sound", isOn: $sound).padding(.leading, 16).listRowBackground(UMTheme.card)
                        Toggle("Show preview", isOn: $preview).padding(.leading, 16).listRowBackground(UMTheme.card)
                    }
                }
            }
        } header: {
            Text("Push Notifications")
        } footer: {
            Text(prefs.master
                 ? "For this device only, and saved to iCloud so they come back after a reinstall. Ready checks, mentions and kicks also alert while the app is in the background; DMs never alert during a game."
                 : (systemDenied
                    ? "Notifications are off for UltiMafia in iOS Settings."
                    : "Off on this device. Turn on to choose which alerts you get."))
        }
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        .animation(nil, value: prefs.master)
        .animation(nil, value: prefs.settings)
        .task { await refreshDenied() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshDenied() }
        }
    }

    private func refreshDenied() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let denied = s.authorizationStatus == .denied
        instantly { systemDenied = denied }
    }
}
