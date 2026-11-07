import Foundation

/// Pure lobby-entry / return / back decisions for players and spectators (website parity, see
/// react_main Main.jsx hosted Game + GameRow membershipRequest). AppModel acts on the result;
/// Tests/SpectatorLifecycleTests.swift compiles this same file.
struct GameEntryState: Equatable {
    var gameId: String
    var spectate: Bool
    var connected: Bool
    var finished: Bool
    var isReview: Bool = false
}

enum GameEntryDecision: Equatable {
    /// A seat elsewhere (redis inGame, or a seated session) refuses the entry.
    case refuse(blockingGameId: String)
    /// Same game, other role: ask over the existing socket (web sends `spectate` / `takeSeat`).
    case switchRole(toSpectator: Bool)
    /// Same game and role: show it (reconnect via /connect, keeping the role, if dropped).
    case reuse(reconnect: Bool)
    /// New session; the old one is only disconnected (web unmount -> Socket.clear, no `leave`;
    /// a spectator is removed by the server after its disconnect grace).
    case replace
}

enum GameEntryPolicy {
    static func decide(target: String, spectate: Bool, inGameId: String?, current: GameEntryState?) -> GameEntryDecision {
        let blocking = inGameId ?? (current?.spectate == false ? current?.gameId : nil)
        if let b = blocking, b != target { return .refuse(blockingGameId: b) }
        if let c = current, c.gameId == target, c.spectate != spectate, c.connected, !c.finished {
            return .switchRole(toSpectator: spectate)
        }
        if let c = current, c.gameId == target, c.spectate == spectate {
            return .reuse(reconnect: !c.connected && !c.finished)
        }
        return .replace
    }

    /// Role the lobby Return button resumes with: the retained session's own role.
    static func returnRole(target: String, current: GameEntryState?) -> Bool {
        current?.gameId == target ? (current?.spectate ?? false) : false
    }

    /// Game-screen back arrow: only reviews close; players and spectators keep the session.
    static func backClosesSession(_ current: GameEntryState) -> Bool { current.isReview }

    /// The lobby's "YOU'RE SPECTATING" target (spectators are never in redis inGame).
    static func spectatingGameId(inGameId: String?, current: GameEntryState?) -> String? {
        guard let c = current, c.spectate, !c.isReview, !c.finished, inGameId != c.gameId else { return nil }
        return c.gameId
    }
}
