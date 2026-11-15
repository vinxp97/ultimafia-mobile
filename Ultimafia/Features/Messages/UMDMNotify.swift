import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Client-side DM notification options (You tab). Local notifications only; closed-app delivery
/// needs APNs (UMPush) once the server side exists.
enum UMDMNotify {
    static let enabledKey = "um.dm.notify"
    static let soundKey = "um.dm.sound"
    static let previewKey = "um.dm.preview"
    static let invitesKey = "um.invites.notify"
    static let prefix = "dm."

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var sound: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
    static var preview: Bool { UserDefaults.standard.object(forKey: previewKey) as? Bool ?? true }

    static var isAppActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    /// Ask when the user turns DM notifications on. Calls back with whether alerts are allowed.
    static func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().delegate = ReadyNotificationDelegate.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                done(granted)
                if granted { UMPush.registerIfConfigured() }
            }
        }
    }

    /// Posts a DM alert unless: off, in a game, or the user is looking at that thread right now.
    /// `text` is nil when the server only sent `newNotif` (no message body for DMs).
    @MainActor
    static func post(channel: UMChatChannel?, sender: String?, text: String?, selfId: String?, inGame: Bool,
                     channelId: String? = nil) {
        guard UMNotifyMaster.isOn, enabled, !inGame else { return }
        guard let id = channel?.id ?? channelId else { return }
        let viewing = UMChatStore.shared.currentChannelId == id
        if viewing && isAppActive { return }
        let content = UNMutableNotificationContent()
        let who = sender ?? channel?.title(selfId: selfId)
        if preview {
            content.title = who ?? "Direct message"
            content.body = text ?? "New direct message"
        } else {
            content.title = "UltiMafia"
            content.body = "New direct message"
        }
        if sound { content.sound = .default }
        content.threadIdentifier = prefix + id
        content.userInfo = ["dmChannel": id]
        let request = UNNotificationRequest(identifier: prefix + id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clear(channelId: String) {
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [prefix + channelId])
    }

    /// Entering a game: drop every pending/delivered DM alert (no stale banners mid-game).
    static func clearAll() {
        let c = UNUserNotificationCenter.current()
        c.getDeliveredNotifications { list in
            let ids = list.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            c.removeDeliveredNotifications(withIdentifiers: ids)
        }
        c.getPendingNotificationRequests { list in
            let ids = list.map(\.identifier).filter { $0.hasPrefix(prefix) }
            c.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Foreground banners. Remote pushes (they carry `aps`) show unless their type is switched off on
    /// this device, they are DMs while in a game / in that thread, or game nudges while already in a
    /// game. Local DM alerts keep their rule; other local alerts never show in the foreground.
    static func foregroundOptions(for n: UNNotification) -> UNNotificationPresentationOptions {
        let info = n.request.content.userInfo
        if info["aps"] != nil {
            return MainActor.assumeIsolated {
                if let t = UMPushType.forPayloadType(info["type"] as? String), !UMPushPrefs.shared.isOn(t) { return [] }
                let inGame = UMChatStore.shared.inGame
                switch UMDeepLink.from(payload: info) {
                case .dm(let id)?:
                    if inGame || UMChatStore.shared.currentChannelId == id { return [] }
                case .game?:
                    if inGame { return [] }
                case .chat?:
                    if inGame { return [] }
                default: break
                }
                return [.banner, .sound, .list]
            }
        }
        guard n.request.identifier.hasPrefix(prefix) || info["dmChannel"] != nil else { return [] }
        return MainActor.assumeIsolated { UMChatStore.shared.inGame } ? [] : (sound ? [.banner, .sound, .list] : [.banner, .list])
    }

    /// Notification tap (local or remote): route by payload type / gameId / url / threadId through
    /// the shell's existing navigation (game, DMs, chat, profile, leaderboard, or the in-app browser).
    @MainActor
    static func handleTap(_ userInfo: [AnyHashable: Any]) {
        guard let link = UMDeepLink.from(payload: userInfo) else { return }
        UMDeepLinkInbox.shared.post(link)
    }
}

extension Notification.Name {
    static let umOpenMessages = Notification.Name("umOpenMessages")
}

/// APNs registration for this device (docs/ios-push-appattest.md on pranay/ios-push-appattest):
/// POST /api/user/apnsToken { token, env: sandbox|production, bundleId, settings } -> {ok, settings};
/// DELETE /api/user/apnsToken { token } when push is turned off; logout sends { apnsToken }.
/// The route allows 1 call a second, so posts are debounced 1.2 s and retried once on 429.
/// Registers only when signed in, the device's master push switch is on and iOS permission is
/// granted. A 404 (server without the routes) is a quiet no-op.
enum UMPush {
    static let isConfigured = UMFeatureFlags.pushNotificationsEnabled
    static let tokenKey = "um.apns.token"
    static var environment: UMPushEnvironment { .current }

    /// Swappable for tests / previews.
    @MainActor static var backend: UMPushBackend = UMLivePushBackend.shared
    /// Set by the signed-in shell; uploads wait for it.
    @MainActor static var signedIn = false
    /// token + settings last accepted by the server, so unchanged state isn't re-posted.
    @MainActor private static var uploadedKey: String?
    @MainActor private static var pendingUpload: Task<Void, Never>?
    @MainActor private(set) static var serverSupportsPush: Bool?

    static var savedToken: String? { UserDefaults.standard.string(forKey: tokenKey) }

    /// After login, on enabling the master switch, and on every foreground: ask APNs for a token.
    @MainActor
    static func registerIfConfigured() {
        guard isConfigured, signedIn, UMPushPrefs.shared.master else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            Task { @MainActor in
                #if canImport(UIKit)
                UIApplication.shared.registerForRemoteNotifications()
                #endif
                // Settings may have changed while the token stayed the same.
                if let hex = savedToken { upload(hex) }
            }
        }
    }

    @MainActor
    static func didRegister(token: Data) {
        guard isConfigured else { return }
        let hex = UMPushToken.hex(token)
        UserDefaults.standard.set(hex, forKey: tokenKey)
        UMDiag.log("push", "apns token \(hex.prefix(8))… env \(environment.rawValue)")
        upload(hex)
    }

    /// Settings changed (You tab, iCloud, permission): re-post with the new settings, or remove
    /// this device from the account when the master switch is off.
    @MainActor
    static func sync() {
        guard isConfigured, signedIn else { return }
        if UMPushPrefs.shared.master { registerIfConfigured() } else {
            pendingUpload?.cancel()
            Task { await unregister() }
        }
    }

    private static func key(_ hex: String, _ settings: UMPushSettings) -> String {
        hex + "|" + settings.serverPayload.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    /// Debounced: rapid toggles collapse into one POST of the latest settings.
    @MainActor
    private static func upload(_ hex: String) {
        guard isConfigured, signedIn, UMPushPrefs.shared.master,
              uploadedKey != key(hex, UMPushPrefs.shared.settings) else { return }
        pendingUpload?.cancel()
        pendingUpload = Task { @MainActor in
            try? await Task.sleep(for: .seconds(UMPushRegistration.debounceSeconds))
            guard !Task.isCancelled else { return }
            await post(hex)
        }
    }

    @MainActor
    private static func post(_ hex: String) async {
        let settings = UMPushPrefs.shared.settings
        guard signedIn, settings.master else { return }
        let k = key(hex, settings)
        guard uploadedKey != k else { return }
        let body = UMPushRegistration.body(token: hex, env: environment, settings: settings)
        var outcome = await backend.registerToken(body)
        if outcome == .rateLimited {
            try? await Task.sleep(for: .seconds(UMPushRegistration.debounceSeconds))
            guard !Task.isCancelled else { return }
            outcome = await backend.registerToken(body)
        }
        switch outcome {
        case .ok:
            serverSupportsPush = true
            uploadedKey = k
            UMDiag.log("push", "token registered")
        case .unsupported:
            serverSupportsPush = false
            UMDiag.log("push", "apnsToken route missing (404); skipping")
        default:
            UMDiag.log("push", "token register failed: \(outcome)")
        }
    }

    /// Account switch, backend switch, or master off: remove this device from the current
    /// account. Must run while the old session is still valid. (Sign-out uses `logoutToken`.)
    @MainActor
    static func unregister() async {
        pendingUpload?.cancel()
        guard isConfigured, let hex = savedToken else { return }
        uploadedKey = nil
        var r = await backend.deleteToken(hex)
        if r == .rateLimited {
            try? await Task.sleep(for: .seconds(UMPushRegistration.debounceSeconds))
            r = await backend.deleteToken(hex)
        }
        UMDiag.log("push", "token unregister: \(r)")
    }

    /// Sign-out: the token rides on POST /api/user/logout { apnsToken } instead of a DELETE.
    @MainActor
    static func logoutToken() -> String? {
        pendingUpload?.cancel()
        uploadedKey = nil
        return isConfigured ? savedToken : nil
    }

    /// The server checks game membership itself, so nothing to report.
    static func reportInGame(_ inGame: Bool) {}
}

#if canImport(UIKit)
/// Remote-notification callbacks and launch-time notification delegate.
final class UMAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = ReadyNotificationDelegate.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { UMPush.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UMDiag.log("push", "apns register failed: \(error.localizedDescription)")
    }
}
#endif


/// Device-wide master switch for ALL app notifications (DM alerts, ready check, mentions, kicks alerts,
/// and APNs registration when UMFeatureFlags allows it). Plain UserDefaults: shared by every account.
/// The Live Activity is not a notification and ignores this.
enum UMNotifyMaster {
    nonisolated static let key = "um.notifications.master"
    nonisolated static let didAskKey = "um.notifications.didAskFirstLaunch"

    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The device's master push switch lives in UMPushPrefs (per device, iCloud); `key` is its mirror.
    @MainActor static func set(_ on: Bool) {
        UMPushPrefs.shared.setMaster(on)
    }

    @MainActor private static var observing = false

    /// App launch: delegate, one-time permission ask, and foreground re-sync.
    @MainActor static func launch() {
        UNUserNotificationCenter.current().delegate = ReadyNotificationDelegate.shared
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                Task { @MainActor in resync() }
            }
        }
        if !UserDefaults.standard.bool(forKey: didAskKey) {
            UserDefaults.standard.set(true, forKey: didAskKey)
            // First launch: the system prompt (Vinman). The answer sets this device's push settings,
            // restoring them from iCloud after a reinstall.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                Task { @MainActor in UMPushPrefs.shared.applyPermissionResult(granted) }
            }
        } else {
            resync()
        }
    }

    /// System permission revoked in Settings -> show the toggle off.
    @MainActor static func resync() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            #if os(macOS)
            let allowed = [.authorized, .provisional].contains(s.authorizationStatus)
            #else
            let allowed = [.authorized, .provisional, .ephemeral].contains(s.authorizationStatus)
            #endif
            Task { @MainActor in
                if !allowed { UMPushPrefs.shared.permissionRevoked() } else { UMPush.registerIfConfigured() }
                UMInboxBadge.refresh()
            }
        }
    }

    enum Outcome { case on, denied, off }

    /// User turned the toggle on.
    @MainActor static func requestOn(_ done: @escaping @MainActor (Outcome) -> Void) {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .denied:
                Task { @MainActor in set(false); done(.denied) }
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    Task { @MainActor in set(granted); done(granted ? .on : .off) }
                }
            default:
                Task { @MainActor in set(true); done(.on) }
            }
        }
    }

    @MainActor static func openSettings() {
        let s = URL(string: UIApplication.openNotificationSettingsURLString) ?? URL(string: UIApplication.openSettingsURLString)
        if let s { UIApplication.shared.open(s) }
    }
}
