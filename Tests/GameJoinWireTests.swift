// swiftc -parse-as-library Tests/GameJoinWireTests.swift Ultimafia/Features/Game/GameJoinWire.swift Ultimafia/App/GameEntryPolicy.swift
import Foundation

/// Regression: lobby Watch (not already in a game) must spectate, never take a seat.
/// Before the fix the socket `join` had no `spectate`, so an open pregame seated the user.
@main
struct GameJoinWireTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL:", what) }
    }

    static func main() {
        // Lobby Watch / Spectate call openGame(spectate: true) -> resumeGame -> this decision.
        let watchSpectate = true
        let decision = GameEntryPolicy.decide(target: "g1", spectate: watchSpectate, inGameId: nil, current: nil)
        check(decision == .replace, "Watch with nothing open starts a new session (got \(decision))")

        // New session's wire: connect query and socket join both say spectate.
        check(GameJoinWire.connectQuery(spectate: watchSpectate) == ["spectate": "true"], "connect?spectate=true")
        let join = GameJoinWire.joinPayload(gameId: "g1", spectate: watchSpectate)
        check(join["spectate"] as? Bool == true, "join payload spectate:true")
        check(join["gameId"] as? String == "g1", "join payload gameId")
        check(join["isBot"] as? Bool == false, "join payload isBot:false")

        // Join keeps player semantics (explicit false, no connect query).
        check(GameJoinWire.connectQuery(spectate: false).isEmpty, "Join: no spectate query")
        check(GameJoinWire.joinPayload(gameId: "g1", spectate: false)["spectate"] as? Bool == false, "Join: spectate:false")
        // Review never sends a spectate join.
        check(GameJoinWire.joinPayload(gameId: "g1", spectate: true, isReview: true)["spectate"] as? Bool == false, "review")

        // Watch never maps to takeSeat (switchRole toSpectator:false), whatever session is open.
        let states: [GameEntryState?] = [
            nil,
            GameEntryState(gameId: "g1", spectate: true, connected: true, finished: false),
            GameEntryState(gameId: "g1", spectate: true, connected: false, finished: false),
            GameEntryState(gameId: "g1", spectate: false, connected: true, finished: false),
            GameEntryState(gameId: "g1", spectate: false, connected: false, finished: true),
            GameEntryState(gameId: "g2", spectate: true, connected: true, finished: false),
            GameEntryState(gameId: "g1", spectate: true, connected: true, finished: false, isReview: true),
        ]
        for s in states {
            for inGame in [nil, "g1"] as [String?] {
                let d = GameEntryPolicy.decide(target: "g1", spectate: true, inGameId: inGame, current: s)
                check(d != .switchRole(toSpectator: false), "Watch -> takeSeat for \(String(describing: s)) inGame=\(inGame ?? "-")")
            }
        }

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("GameJoinWireTests: all passed")
    }
}
