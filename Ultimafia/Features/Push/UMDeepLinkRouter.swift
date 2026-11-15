import Foundation
import Observation
import SwiftUI

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
        case .profile(let idOrVanity):
            // /user/:id accepts a vanity name; /api/user/:id/profile answers with the real id, so the
            // pushed screen (and its cache, follow, DM actions) always use the canonical id.
            Task { @MainActor in
                var id = idOrVanity, name = ""
                if let r = try? await APIClient.shared.requestWithStatus("GET", path: "user/\(idOrVanity)/profile", body: nil),
                   r.status == 200,
                   let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] {
                    if let real = o["id"] as? String, !real.isEmpty { id = real }
                    name = (o["name"] as? String) ?? ""
                }
                var t = Transaction(animation: nil)
                t.disablesAnimations = true
                withTransaction(t) {
                    self.section = .play
                    self.path.append(.profile(id: id, name: name))
                }
            }
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
