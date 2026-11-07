import Foundation

/// Mirrors AppModel.resumeGame / returnToLobby / leave decisions for spectator parity with the
/// website (hosted Game kept mounted; lobby Spectate on the hosted game sends `spectate`;
/// Leave sends `leave`, Spectator.leaveGame; back only hides).
struct Session { var id: String; var spectate: Bool; var connected = true; var finished = false; var review = false }
enum Outcome: Equatable { case refused, reuse, sendSpectate, sendTakeSeat, newSession(spectate: Bool) }

struct Shell {
    var inGameId: String?          // redis inGame (players only)
    var game: Session?
    var sent: [String] = []

    var seatedGameId: String? { inGameId ?? game?.id }
    var spectatingGameId: String? {
        guard let g = game, g.spectate, !g.review, !g.finished, inGameId != g.id else { return nil }
        return g.id
    }

    mutating func resume(_ id: String, spectate: Bool) -> Outcome {
        let blocking = inGameId ?? (game?.spectate == false ? game?.id : nil)
        if let b = blocking, b != id { return .refused }
        if let g = game, g.id == id, g.spectate != spectate, g.connected, !g.finished {
            sent.append(spectate ? "spectate" : "takeSeat"); return spectate ? .sendSpectate : .sendTakeSeat
        }
        if let g = game, g.id == id, g.spectate == spectate { return .reuse }
        game = Session(id: id, spectate: spectate)   // old socket: disconnect only
        return .newSession(spectate: spectate)
    }
    mutating func returnFromBanner() -> Outcome {
        guard let id = seatedGameId else { return .refused }
        return resume(id, spectate: game?.id == id ? (game?.spectate ?? false) : false)
    }
    mutating func backArrow() { if game?.review == true { game = nil } }   // spectators retained
    mutating func leave() { if game != nil { sent.append("leave") }; game = nil; inGameId = nil }
}

@main
struct SpectatorLifecycleTests {
    static func main() {
        var s = Shell()
        precondition(s.resume("g1", spectate: true) == .newSession(spectate: true), "Watch opens spectator")
        s.backArrow()
        precondition(s.spectatingGameId == "g1" && s.sent.isEmpty, "back keeps spectator session, sends nothing")
        precondition(s.returnFromBanner() == .reuse && s.game?.spectate == true, "Return restores spectator view, not a seat")
        precondition(s.resume("g1", spectate: true) == .reuse, "Watch again on same game reuses socket")
        precondition(s.resume("g2", spectate: true) == .newSession(spectate: true), "spectator may watch another game")
        s.leave()
        precondition(s.sent == ["leave"] && s.game == nil && s.spectatingGameId == nil, "Leave sends leave and drops membership")

        var p = Shell(inGameId: "g1", game: Session(id: "g1", spectate: false))
        p.backArrow()
        precondition(p.game != nil && p.spectatingGameId == nil, "player kept, not labeled spectating")
        precondition(p.resume("g2", spectate: true) == .refused, "seated player can't watch another game")
        precondition(p.returnFromBanner() == .reuse && p.game?.spectate == false, "player Return stays player")
        precondition(p.resume("g1", spectate: true) == .sendSpectate, "Watch on own pregame game sends spectate over socket")

        var w = Shell(game: Session(id: "g1", spectate: true))
        precondition(w.resume("g1", spectate: false) == .sendTakeSeat, "Join from lobby while watching sends takeSeat")

        var r = Shell(game: Session(id: "g9", spectate: true, review: true))
        r.backArrow()
        precondition(r.game == nil, "review closes on back")
        print("SpectatorLifecycleTests passed")
    }
}
