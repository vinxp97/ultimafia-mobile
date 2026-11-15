import Foundation
import Observation

/// Notification taps and universal links can arrive before the signed-in shell exists (cold
/// launch from a banner). They wait here until MainTabs drains them.
@MainActor @Observable
final class UMDeepLinkInbox {
    static let shared = UMDeepLinkInbox()
    var pending: UMDeepLink?
    /// A site page with no native screen, shown in the in-app browser.
    var browserURL: URL?

    func post(_ link: UMDeepLink) {
        UMDiag.log("link", "deep link \(link)")
        pending = link
    }
}

extension AppModel {
    /// One place that turns a deep link into existing navigation. Never leaves or replaces a live
    /// game: opening a different game while seated goes through resumeGame's refusal like any join.
    func route(_ link: UMDeepLink) {
        let inGame = game != nil || seatedGameId != nil
        switch link {
        case .game(let id):
            if seatedGameId == id || game?.gameId == id {
                resumeGame(id, spectate: GameEntryPolicy.returnRole(target: id, current: game?.entryState))
            } else {
                resumeGame(id)
            }
        case .dm(let channelId):
            guard !inGame else { return }   // DMs are hidden while seated or spectating.
            UMChatStore.shared.focusChannelId = channelId
            section = .messages
        case .chat(let channelId):
            guard !inGame else { return }
            if let channelId { UMChatStore.shared.focusChannelId = channelId }
            section = .messages
        case .profile(let id):
            section = .play
            path.append(.profile(id: id, name: ""))
        case .leaderboard:
            select(.leaderboard)
        case .play:
            goToLobby()
        case .web(let path):
            let full = path.hasPrefix("http") ? path : "\(UMConfig.site)\(path.hasPrefix("/") ? "" : "/")\(path)"
            if let url = URL(string: full) { UMDeepLinkInbox.shared.browserURL = url }
        }
    }
}
