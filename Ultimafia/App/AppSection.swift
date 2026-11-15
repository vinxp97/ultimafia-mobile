import Foundation

/// The bottom sections. Always present, always in this order: the bar never reorders, relabels or
/// hides an item, and every item is a place rather than an action. Hosting is not one of them —
/// it lives inside the lobby, matching the website — so the bar only ever offers places.
///
/// A standalone value type so the pure-logic tests can compile it without the app.
enum UMAppSection: String, CaseIterable, Hashable, Identifiable {
    case play, leaderboard, messages, game, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play: "Lobby"
        case .leaderboard: "Leaderboard"
        case .messages: "Messages"
        case .game: "Game"
        case .you: "You"
        }
    }

    var symbol: String {
        switch self {
        case .play: "list.bullet.rectangle"
        case .leaderboard: "chart.bar.xaxis"
        case .messages: "bubble.left.and.bubble.right"
        case .game: "gamecontroller"
        case .you: "person"
        }
    }
}
