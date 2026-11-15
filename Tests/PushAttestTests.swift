// swiftc -parse-as-library Tests/PushAttestTests.swift Ultimafia/Features/Push/UMPushCore.swift
import Foundation

@main
struct PushAttestTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL:", what) }
    }
    static func equal<T: Equatable>(_ got: T, _ expected: T, _ what: String) {
        check(got == expected, "\(what) (got \(got), expected \(expected))")
    }

    static func main() {
        tokenAndEnv()
        settingsModel()
        settingsStore()
        registrationBody()
        payloadRouting()
        universalLinks()
        clientField()
        attestWire()
        outcomes()
        if failures == 0 {
            print("PushAttestTests passed: token hex/env, settings model, per-device store, registration body, payload routing, universal links, client field, attest wire, 404 no-op")
        } else {
            print("PushAttestTests: \(failures) failure(s)")
            exit(1)
        }
    }

    static func tokenAndEnv() {
        let d = Data([0x00, 0x0f, 0xa0, 0xff, 0x12])
        equal(UMPushToken.hex(d), "000fa0ff12", "hex is lowercase, zero padded")
        check(UMPushToken.isValidHex("000fa0ff12"), "valid hex")
        check(!UMPushToken.isValidHex("000FA0"), "uppercase rejected")
        check(!UMPushToken.isValidHex("abc"), "odd length rejected")
        check(!UMPushToken.isValidHex(""), "empty rejected")
        equal(UMPushToken.hex(Data(repeating: 0xab, count: 32)).count, 64, "32-byte token -> 64 hex chars")
        equal(UMPushEnvironment.forBuild(debug: true), .sandbox, "debug -> sandbox")
        equal(UMPushEnvironment.forBuild(debug: false), .production, "release -> production")
        equal(UMPushEnvironment.sandbox.rawValue, "sandbox", "env wire value")
    }

    static func settingsModel() {
        var s = UMPushSettings.allOff
        check(!s.master && UMPushType.allCases.allSatisfy { !s.isOn($0) }, "all off")
        s.setMaster(true)
        equal(s, .allOn, "master on turns every type on")
        s.set(.pokes, false)
        check(!s.isOn(.pokes) && s.isOn(.dms), "a type can be switched off alone")
        s.setMaster(false)
        check(UMPushType.allCases.allSatisfy { !s.isOn($0) }, "master off hides every type")
        equal(s.types[.dms], true, "master off remembers the type values")
        s.setMaster(true)
        check(s.isOn(.pokes), "master back on turns every type on again (Vinman)")
        equal(Set(UMPushSettings.allOn.serverPayload.keys), ["gameStart", "dms", "pings", "friends", "pokes"], "Pranay's pushSettings keys")
        // Decoding is tolerant: missing types default to true, unknown keys ignored.
        let json = #"{"master":true,"types":{"dms":false,"future":true}}"#
        let dec = try? JSONDecoder().decode(UMPushSettings.self, from: Data(json.utf8))
        equal(dec?.types[.dms], false, "decoded type value")
        equal(dec?.types[.gameStart], true, "missing type defaults on")
        let round = try? JSONDecoder().decode(UMPushSettings.self, from: JSONEncoder().encode(s))
        equal(round, s, "codable round trip")
        equal(UMPushType.forPayloadType("gameReady"), .gameStart, "gameReady -> gameStart")
        equal(UMPushType.forPayloadType("forumQuote"), .pings, "forumQuote -> pings")
        equal(UMPushType.forPayloadType("poke"), .pokes, "poke -> pokes")
        equal(UMPushType.forPayloadType("friendRequest"), .friends, "friendRequest -> friends")
        equal(UMPushType.forPayloadType("moderation"), nil, "moderation has no switch")
    }

    static func settingsStore() {
        let cloud = UMMemoryKeyValue(), local = UMMemoryKeyValue()
        let a = UMPushSettingsStore(deviceId: "dev-A", cloud: cloud, local: local)
        let b = UMPushSettingsStore(deviceId: "dev-B", cloud: cloud, local: UMMemoryKeyValue())
        check(a.load() == nil, "nothing saved yet")
        var s = UMPushSettings.allOn; s.set(.friends, false)
        a.save(s)
        equal(a.load(), s, "device A reads its own settings")
        check(b.load() == nil, "device B doesn't see device A's settings in the shared iCloud store")
        check(a.key != b.key && a.key.hasSuffix("dev-A"), "keys namespaced by device id")
        // Reinstall: local copy gone, iCloud restores it.
        let reinstalled = UMPushSettingsStore(deviceId: "dev-A", cloud: cloud, local: UMMemoryKeyValue())
        equal(reinstalled.load(), s, "iCloud restores after reinstall")
        // No iCloud: UserDefaults-style local fallback still works.
        let offline = UMPushSettingsStore(deviceId: "dev-C", cloud: nil, local: UMMemoryKeyValue())
        offline.save(.allOn)
        equal(offline.load(), .allOn, "local fallback without iCloud")
    }

    static func registrationBody() {
        var s = UMPushSettings.allOn; s.set(.pings, false)
        let body = UMPushRegistration.body(token: "abcd", env: .sandbox, settings: s)
        equal(body["token"] as? String, "abcd", "token")
        equal(body["env"] as? String, "sandbox", "env")
        equal(body["bundleId"] as? String, "VCCCLLC.Ultimafia", "bundleId")
        equal((body["pushSettings"] as? [String: Bool])?["pings"], false, "pushSettings rides along")
        equal(UMPushRegistration.path, "user/apnsToken", "route under /api")
        equal(UMPushRegistration.deleteBody(token: "abcd") as? [String: String], ["token": "abcd"], "delete body")
    }

    static func payloadRouting() {
        equal(UMDeepLink.from(payload: ["type": "gameReady", "gameId": "abc123", "url": "/game/abc123"]), .game("abc123"), "game ready")
        equal(UMDeepLink.from(payload: ["type": "gameStarting", "gameId": "g9"]), .game("g9"), "game starting")
        equal(UMDeepLink.from(payload: ["type": "dm", "channelId": "ch1"]), .dm("ch1"), "dm by channelId")
        equal(UMDeepLink.from(payload: ["type": "dm", "threadId": "ch2"]), .dm("ch2"), "dm by threadId")
        equal(UMDeepLink.from(payload: ["dmChannel": "local1"]), .dm("local1"), "local DM alert")
        equal(UMDeepLink.from(payload: ["type": "chatPing", "channelId": "main"]), .chat("main"), "chat ping")
        equal(UMDeepLink.from(payload: ["type": "friendRequest", "url": "/user/u42"]), .profile("u42"), "friend request -> profile")
        equal(UMDeepLink.from(payload: ["type": "poke", "url": "https://ultimafia.com/user/u7"]), .profile("u7"), "poke with BASE_URL url")
        equal(UMDeepLink.from(payload: ["type": "forumReply", "url": "/community/forums/thread/t1?reply=r2"]),
              .web("/community/forums/thread/t1?reply=r2"), "forum -> in-app browser")
        equal(UMDeepLink.from(payload: ["aps": ["alert": "x"]]), nil, "no route info")
        equal(UMDeepLink.from(payload: ["type": "gameScheduled", "gameId": NSNumber(value: 5)]), .game("5"), "numeric id tolerated")
    }

    static func universalLinks() {
        func u(_ s: String) -> UMDeepLink? { UMDeepLink.from(url: URL(string: s)!) }
        equal(u("https://ultimafia.com/game/abc"), .game("abc"), "/game/*")
        equal(u("https://www.ultimafia.com/user/vin"), .profile("vin"), "/user/*")
        equal(u("https://ultimafia.com/user/settings"), .web("/user/settings"), "/user/settings is a web page")
        equal(u("https://ultimafia.com/user/family/f1"), .web("/user/family/f1"), "/user/family/* is a web page")
        equal(u("https://ultimafia.com/community/forums/board/b1"), .web("/community/forums/board/b1"), "/community/forums/*")
        equal(u("https://ultimafia.com/chat"), .chat(nil), "/chat")
        equal(u("https://ultimafia.com/chat/room1"), .chat("room1"), "/chat/:id")
        equal(u("https://ultimafia.com/play"), .play, "/play")
        equal(u("https://ultimafia.com/play/host"), .play, "/play/*")
        equal(u("https://ultimafia.com/fame"), .leaderboard, "/fame -> Leaderboard tab")
        equal(u("https://ultimafia.com/fame/competitive"), .leaderboard, "/fame* -> Leaderboard tab")
        equal(u("https://ultimafia.com/"), .play, "root -> lobby")
        equal(u("https://example.com/game/abc"), nil, "other hosts ignored")
        equal(u("ultimafia://game/abc"), nil, "non-https ignored")
    }

    static func clientField() {
        equal(UMPlayerClient.parse(["id": "p1", "client": "ios"]), "ios", "ios")
        equal(UMPlayerClient.parse(["id": "p1", "client": " iOS "]), "ios", "normalized")
        equal(UMPlayerClient.parse(["id": "p1"]), nil, "absent for web players")
        equal(UMPlayerClient.parse(["id": "p1", "client": 1]), nil, "wrong type ignored")
        equal(UMPlayerClient.parse(["id": "p1", "client": ""]), nil, "empty ignored")
        check(UMPlayerClient.showsAppleBadge(client: "ios", anonymousGame: false), "badge for ios")
        check(!UMPlayerClient.showsAppleBadge(client: "ios", anonymousGame: true), "hidden in anonymous games")
        check(!UMPlayerClient.showsAppleBadge(client: "android", anonymousGame: false), "no apple badge for android")
        check(!UMPlayerClient.showsAppleBadge(client: nil, anonymousGame: false), "none for web")
    }

    static func attestWire() {
        equal(UMAttestWire.clientData(challenge: "abc", socketNonce: "s1"), Data("abcs1".utf8), "challenge || socket nonce")
        equal(UMAttestWire.clientData(challenge: "abc", socketNonce: nil), Data("abc".utf8), "challenge only")
        let c = UMAttestWire.parseChallenge(["challenge": "xyz", "ttlSec": 120])
        equal(c?.challenge, "xyz", "challenge parsed")
        check(c?.socketNonce == nil, "no nonce over HTTP")
        equal(UMAttestWire.parseChallenge(["challenge": "q", "socketId": "sock"])?.socketNonce, "sock", "socket-pushed nonce")
        check(UMAttestWire.parseChallenge(["ttlSec": 1]) == nil, "missing challenge")
        let j = UMAttestWire.joinField(keyId: "k", assertion: Data([1, 2, 3]))
        equal(j["keyId"] as? String, "k", "join keyId")
        equal(j["assertion"] as? String, "AQID", "join assertion base64")
        let a = UMAttestWire.attestBody(keyId: "k", attestation: Data([0xff]), challenge: "c")
        equal(a["attestationObject"] as? String, "/w==", "attestation base64")
        equal(a["challenge"] as? String, "c", "attest challenge echoed")
    }

    static func outcomes() {
        equal(UMBackendOutcome.from(status: 200), .ok, "200 ok")
        equal(UMBackendOutcome.from(status: 204), .ok, "204 ok")
        equal(UMBackendOutcome.from(status: 404), .unsupported, "404 -> quiet no-op")
        equal(UMBackendOutcome.from(status: 501), .unsupported, "501 -> no-op")
        equal(UMBackendOutcome.from(status: 500), .failed("HTTP 500"), "500 failed")
    }
}
