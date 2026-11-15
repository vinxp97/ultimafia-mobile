import SwiftUI

/// Mac-only way back (Catalyst and native): ⌘[ / the Back button pops the visible section's stack,
/// and at a section's root returns to the lobby, so no screen is a dead end. iPhone/iPad keep the
/// system tab bar and back buttons and never use this.
extension AppModel {
    var macCanGoBack: Bool {
        switch section {
        case .play: !path.isEmpty
        case .game: !gamePath.isEmpty || game == nil
        case .leaderboard: true
        case .messages, .you: true
        }
    }

    func macBack() {
        switch section {
        case .play: if !path.isEmpty { path.removeLast() }
        case .game: if !gamePath.isEmpty { gamePath.removeLast() } else if game == nil { goToLobby() }
        case .you: if !youPath.isEmpty { youPath.removeLast() } else { goToLobby() }
        case .leaderboard: if !leaderboardPath.isEmpty { leaderboardPath.removeLast() } else { goToLobby() }
        case .messages: goToLobby()
        }
    }
}

extension View {
    /// Section roots (Messages, You): a "Lobby" button in the Mac toolbar. No-op on iPhone/iPad.
    @ViewBuilder func umMacLobbyButton(_ app: AppModel) -> some View {
        #if targetEnvironment(macCatalyst)
        self.toolbar {
            ToolbarItem(placement: .navigation) {
                Button { app.goToLobby() } label: { Label("Lobby", systemImage: "chevron.backward") }
                    .labelStyle(.titleAndIcon)
                    .help("Back to the lobby (⌘1)")
            }
        }
        #else
        self
        #endif
    }
}
