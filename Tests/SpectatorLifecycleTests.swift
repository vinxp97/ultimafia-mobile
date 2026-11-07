import Foundation

/// Compiled together with production Ultimafia/App/GameEntryPolicy.swift (see run line below):
///   swiftc -parse-as-library Ultimafia/App/GameEntryPolicy.swift Tests/SpectatorLifecycleTests.swift
@main
struct SpectatorLifecycleTests {
    static func main() {
        typealias P = GameEntryPolicy
        let watching = GameEntryState(gameId: "g1", spectate: true, connected: true, finished: false)
        let seated = GameEntryState(gameId: "g1", spectate: false, connected: true, finished: false)

        // Watch from lobby with nothing open -> new spectator session.
        precondition(P.decide(target: "g1", spectate: true, inGameId: nil, current: nil) == .replace)
        // Back arrow keeps spectator and player sessions; review closes.
        precondition(!P.backClosesSession(watching) && !P.backClosesSession(seated))
        var rev = watching; rev.isReview = true
        precondition(P.backClosesSession(rev))
        // Lobby banner target + Return resumes as spectator, reusing the socket.
        precondition(P.spectatingGameId(inGameId: nil, current: watching) == "g1")
        precondition(P.returnRole(target: "g1", current: watching) == true)
        precondition(P.decide(target: "g1", spectate: true, inGameId: nil, current: watching) == .reuse(reconnect: false))
        // Dropped socket: Return reconnects keeping spectator role (/connect?spectate=true).
        var dropped = watching; dropped.connected = false
        precondition(P.decide(target: "g1", spectate: P.returnRole(target: "g1", current: dropped),
                              inGameId: nil, current: dropped) == .reuse(reconnect: true))
        // Spectator watching another game: replace (disconnect only), never refused.
        precondition(P.decide(target: "g2", spectate: true, inGameId: nil, current: watching) == .replace)
        // Join on the watched game -> takeSeat over socket.
        precondition(P.decide(target: "g1", spectate: false, inGameId: nil, current: watching) == .switchRole(toSpectator: false))

        // Seated player: not labeled spectating, Return stays player, other games refused.
        precondition(P.spectatingGameId(inGameId: "g1", current: seated) == nil)
        precondition(P.returnRole(target: "g1", current: seated) == false)
        precondition(P.decide(target: "g2", spectate: true, inGameId: "g1", current: seated) == .refuse(blockingGameId: "g1"))
        precondition(P.decide(target: "g1", spectate: true, inGameId: "g1", current: seated) == .switchRole(toSpectator: true))
        // Seated per server with no session yet (relaunch) still blocks.
        precondition(P.decide(target: "g2", spectate: true, inGameId: "g1", current: nil) == .refuse(blockingGameId: "g1"))
        // Finished spectated game: no banner.
        var done = watching; done.finished = true
        precondition(P.spectatingGameId(inGameId: nil, current: done) == nil)
        print("SpectatorLifecycleTests passed (production GameEntryPolicy)")
    }
}
