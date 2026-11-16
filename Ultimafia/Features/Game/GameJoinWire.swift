import Foundation

/// What a lobby entry puts on the wire (website parity: Game.jsx getConnectionInfo + socket join).
/// The server only honors spectating from the socket `join` payload (games.js -> game.userJoin
/// `{isBot, spectate}`); `/connect?spectate=true` just skips the player-only preflight checks.
/// So Watch / Spectate must send `spectate: true` in both, or an open pregame seats the user.
/// Tests/GameJoinWireTests.swift compiles this same file.
enum GameJoinWire {
    /// Query for `GET /api/game/:id/connect`.
    static func connectQuery(spectate: Bool) -> [String: String] {
        spectate ? ["spectate": "true"] : [:]
    }

    /// Body of the socket `join` event (signed-in and guest alike). `appAttest` is the
    /// `{keyId, assertion[, challenge]}` / `{devBypass}` field from UMAppAttest; nil omits it.
    static func joinPayload(
        gameId: String, spectate: Bool, isReview: Bool = false, appAttest: [String: Any]? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "gameId": gameId,
            "isBot": false,
            "spectate": spectate && !isReview,
        ]
        if let appAttest { payload["appAttest"] = appAttest }
        return payload
    }
}
