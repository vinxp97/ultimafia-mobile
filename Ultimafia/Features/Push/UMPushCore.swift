import Foundation

// Pure push / deep-link / App Attest helpers (Foundation only, so Tests/PushAttestTests.swift can
// compile this file on its own). Server shapes follow Pranay's APNs + App Attest design contract;
// everything marked PROPOSED there is still PROPOSED here until his backend lands.

/// APNs host the token belongs to. A sandbox token sent to production fails with BadDeviceToken,
/// so the server needs this with every registration.
nonisolated enum UMPushEnvironment: String, Sendable {
    case sandbox, production

    /// Debug (Xcode) builds are signed with aps-environment=development; Release is exported with
    /// a distribution profile that turns it into production.
    static func forBuild(debug: Bool) -> UMPushEnvironment { debug ? .sandbox : .production }

    static var current: UMPushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

nonisolated enum UMPushToken {
    /// APNs device token bytes as lowercase hex, the form APNs and the server expect.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidHex(_ s: String) -> Bool {
        !s.isEmpty && s.count % 2 == 0 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// The per-type switches. Raw values are Pranay's planned `pushSettings` keys.
nonisolated enum UMPushType: String, CaseIterable, Codable, Sendable {
    case gameStart, dms, pings, friends, pokes

    var title: String {
        switch self {
        case .gameStart: "Game ready & starting"
        case .dms: "Direct messages"
        case .pings: "Chat & forum pings"
        case .friends: "Friend requests"
        case .pokes: "Pokes"
        }
    }

    var detail: String {
        switch self {
        case .gameStart: "Ready checks and games you joined starting"
        case .dms: "New direct messages (never during a game)"
        case .pings: "@mentions in chat, forum mentions, replies and quotes"
        case .friends: "Friend requests and accepts"
        case .pokes: "Pokes and poke-backs"
        }
    }

    /// Which switch an incoming payload `type` belongs to (contract §1d suggested values).
    static func forPayloadType(_ type: String?) -> UMPushType? {
        switch type {
        case "gameReady", "gameStarting", "gameScheduled", "gameStart": .gameStart
        case "dm": .dms
        case "chatPing", "forumMention", "forumReply", "forumQuote", "ping": .pings
        case "friendRequest", "friendAccepted", "friend": .friends
        case "poke", "pokeBack": .pokes
        default: nil
        }
    }
}

/// One device's push preferences. Stored per device (iCloud KVS keyed by the install id, with a
/// UserDefaults fallback) and sent to the server with this device's token.
nonisolated struct UMPushSettings: Codable, Equatable, Sendable {
    var master: Bool
    var types: [UMPushType: Bool]

    static let allOff = UMPushSettings(master: false, types: Dictionary(uniqueKeysWithValues: UMPushType.allCases.map { ($0, false) }))
    static let allOn = UMPushSettings(master: true, types: Dictionary(uniqueKeysWithValues: UMPushType.allCases.map { ($0, true) }))

    func isOn(_ t: UMPushType) -> Bool { master && (types[t] ?? true) }

    /// Turning the master on turns every type on (Vinman); off keeps the types but hides them.
    mutating func setMaster(_ on: Bool) {
        if on { self = .allOn } else { master = false }
    }

    mutating func set(_ t: UMPushType, _ on: Bool) { types[t] = on }

    /// `pushSettings` as the server would read it: every key present, all true by default.
    var serverPayload: [String: Bool] {
        Dictionary(uniqueKeysWithValues: UMPushType.allCases.map { ($0.rawValue, types[$0] ?? true) })
    }

    var anyTypeOn: Bool { UMPushType.allCases.contains { types[$0] ?? true } }

    // Codable with string keys so the stored JSON is readable and tolerant of new types.
    private enum CodingKeys: String, CodingKey { case master, types }
    init(master: Bool, types: [UMPushType: Bool]) { self.master = master; self.types = types }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = (try? c.decode(Bool.self, forKey: .master)) ?? false
        let raw = (try? c.decode([String: Bool].self, forKey: .types)) ?? [:]
        var t: [UMPushType: Bool] = [:]
        for type in UMPushType.allCases { t[type] = raw[type.rawValue] ?? true }
        types = t
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(master, forKey: .master)
        try c.encode(serverPayload, forKey: .types)
    }
}

/// A key-value backend for settings: iCloud KVS on device, UserDefaults as fallback, a dictionary in tests.
nonisolated protocol UMKeyValueBackend: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

nonisolated final class UMMemoryKeyValue: UMKeyValueBackend {
    var store: [String: Data] = [:]
    init() {}
    func data(forKey key: String) -> Data? { store[key] }
    func set(_ data: Data?, forKey key: String) { store[key] = data }
}

nonisolated final class UMDefaultsKeyValue: UMKeyValueBackend {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
}

nonisolated final class UMUbiquitousKeyValue: UMKeyValueBackend {
    private var kvs: NSUbiquitousKeyValueStore { .default }
    init() {}
    func data(forKey key: String) -> Data? { kvs.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) {
        if let data { kvs.set(data, forKey: key) } else { kvs.removeObject(forKey: key) }
        kvs.synchronize()
    }
}

/// Per-device settings store. `cloud` is nil when iCloud is unavailable; the local copy is always
/// written so the app works offline and before the first iCloud sync.
nonisolated final class UMPushSettingsStore {
    let deviceId: String
    let cloud: UMKeyValueBackend?
    let local: UMKeyValueBackend

    init(deviceId: String, cloud: UMKeyValueBackend?, local: UMKeyValueBackend) {
        self.deviceId = deviceId
        self.cloud = cloud
        self.local = local
    }

    /// Namespaced by device so each device keeps its own settings in the shared iCloud store.
    var key: String { "um.push.settings.v1.\(deviceId)" }

    /// iCloud wins (it is what survives a reinstall); then the local copy; nil if never saved.
    func load() -> UMPushSettings? {
        let dec = JSONDecoder()
        if let d = cloud?.data(forKey: key), let s = try? dec.decode(UMPushSettings.self, from: d) { return s }
        if let d = local.data(forKey: key), let s = try? dec.decode(UMPushSettings.self, from: d) { return s }
        return nil
    }

    func save(_ s: UMPushSettings) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        local.set(d, forKey: key)
        cloud?.set(d, forKey: key)
    }
}

/// POST /api/user/apnsToken body (PROPOSED). `pushSettings` rides along so the server can filter
/// per device. TODO(Pranay): confirm settings belong on this route vs a separate /api/user/pushSettings.
nonisolated enum UMPushRegistration {
    static let path = "user/apnsToken"
    static let bundleId = "VCCCLLC.Ultimafia"

    static func body(token: String, env: UMPushEnvironment, settings: UMPushSettings) -> [String: Any] {
        ["token": token, "env": env.rawValue, "bundleId": bundleId, "pushSettings": settings.serverPayload]
    }

    static func deleteBody(token: String) -> [String: Any] { ["token": token] }
}

/// Where a notification tap or universal link should take the user.
nonisolated enum UMDeepLink: Equatable, Sendable {
    case game(String)
    case dm(String)
    case chat(String?)
    case profile(String)
    case leaderboard
    case play
    /// No native screen (forums, family, anything else on the site): show it in the in-app browser.
    case web(String)

    /// Universal-link hosts the app answers for.
    static let hosts: Set<String> = ["ultimafia.com", "www.ultimafia.com"]

    /// APNs payload (contract §1d): `type`, `gameId`, `url`, `threadId`, `channelId`.
    /// Local DM alerts use `dmChannel`.
    static func from(payload info: [AnyHashable: Any]) -> UMDeepLink? {
        func str(_ k: String) -> String? {
            if let s = info[k] as? String, !s.isEmpty { return s }
            if let n = info[k] as? NSNumber { return n.stringValue }
            return nil
        }
        if let ch = str("dmChannel") { return .dm(ch) }
        let type = str("type")
        switch type {
        case "gameReady", "gameStarting", "gameScheduled", "gameStart":
            if let g = str("gameId") { return .game(g) }
        case "dm":
            if let ch = str("channelId") ?? str("threadId") { return .dm(ch) }
        case "chatPing":
            return .chat(str("channelId") ?? str("threadId"))
        default:
            break
        }
        if let g = str("gameId") { return .game(g) }
        if let url = str("url"), let link = from(path: url) { return link }
        return nil
    }

    /// A full https URL (universal link). Other hosts are not ours.
    static func from(url: URL) -> UMDeepLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        var path = url.path
        if let q = url.query, !q.isEmpty { path += "?" + q }
        return from(path: path)
    }

    /// A site path ("/game/abc", or a BASE_URL-prefixed URL string). AASA paths (Pranay):
    /// /game/*, /user/*, /community/forums/*, /chat*, /play*, /fame*.
    static func from(path raw: String) -> UMDeepLink? {
        if raw.hasPrefix("http"), let u = URL(string: raw) { return from(url: u) }
        let pathOnly = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
        let parts = pathOnly.split(separator: "/").map(String.init)
        guard let first = parts.first?.lowercased() else { return .play }
        switch first {
        case "game":
            // /game/:id (and /game/:id/review etc. still open the game's live/replay path).
            if parts.count >= 2 { return .game(parts[1]) }
            return .play
        case "user":
            // /user/:id is a profile; /user/family/:id, /user/settings, /user/inbox… are web pages.
            if parts.count == 2, !["settings", "inbox", "shop", "family", "notifications"].contains(parts[1].lowercased()) {
                return .profile(parts[1])
            }
            return .web(raw)
        case let s where s.hasPrefix("fame"):
            return .leaderboard
        case let s where s.hasPrefix("chat"):
            return .chat(parts.count >= 2 ? parts[1] : nil)
        case "lobby":
            return .play
        case let s where s.hasPrefix("play"):
            return .play
        case "community":
            return .web(raw)
        default:
            return .web(raw)
        }
    }
}

/// Optional `client` field on getPlayerInfo (PROPOSED). Only "ios" draws the Apple icon; any
/// other value (or none) is ignored so web players look exactly as before.
nonisolated enum UMPlayerClient {
    static func parse(_ obj: [String: Any]) -> String? {
        guard let s = obj["client"] as? String else { return nil }
        let v = s.trimmingCharacters(in: .whitespaces).lowercased()
        return v.isEmpty ? nil : v
    }

    static func showsAppleBadge(client: String?, anonymousGame: Bool) -> Bool {
        client == "ios" && !anonymousGame
    }
}

/// App Attest wire helpers (contract §2c).
nonisolated enum UMAttestWire {
    static let challengePath = "appattest/challenge"
    static let attestPath = "appattest/attest"

    /// Per-socket clientData: challenge bytes followed by the socket nonce bytes (UTF-8), so a
    /// captured assertion can't authorize another connection. The app then signs SHA256(clientData).
    /// TODO(Pranay): confirm the exact concatenation and where the socket nonce comes from.
    static func clientData(challenge: String, socketNonce: String?) -> Data {
        var d = Data(challenge.utf8)
        if let socketNonce { d.append(Data(socketNonce.utf8)) }
        return d
    }

    /// GET /api/appattest/challenge -> { challenge, ttlSec }. Also accepts the socket's
    /// `appAttestChallenge` event, which may carry `socketId` / `nonce`.
    static func parseChallenge(_ any: Any?) -> (challenge: String, socketNonce: String?)? {
        guard let o = any as? [String: Any], let c = o["challenge"] as? String, !c.isEmpty else { return nil }
        let nonce = (o["socketNonce"] as? String) ?? (o["nonce"] as? String) ?? (o["socketId"] as? String)
        return (c, nonce)
    }

    static func attestBody(keyId: String, attestation: Data, challenge: String) -> [String: Any] {
        ["keyId": keyId, "attestationObject": attestation.base64EncodedString(), "challenge": challenge]
    }

    static func joinField(keyId: String, assertion: Data) -> [String: Any] {
        ["keyId": keyId, "assertion": assertion.base64EncodedString()]
    }
}

/// Result of a call to an endpoint Pranay hasn't shipped yet.
nonisolated enum UMBackendOutcome: Equatable {
    case ok
    /// 404 / 501: the route doesn't exist on this server yet. Callers treat this as a quiet no-op.
    case unsupported
    case failed(String)

    static func from(status: Int) -> UMBackendOutcome {
        switch status {
        case 200..<300: .ok
        case 404, 405, 501: .unsupported
        default: .failed("HTTP \(status)")
        }
    }
}

