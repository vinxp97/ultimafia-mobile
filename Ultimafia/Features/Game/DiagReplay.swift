#if DEBUG
import SwiftUI

/// DEBUG only. Launch with `-UMDiagReplay` to open a synthetic game (no network, no account) and
/// drive it through Day 1 -> Night 1 -> Day 2 with the same socket handlers, so phase-change stalls
/// and message latency show up in the diagnostics log / watchdog without joining a real game.
struct DiagReplayView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("-UMDiagTabs") {
            tabs
        } else {
            standalone
        }
        #else
        standalone
        #endif
    }

    #if os(iOS)
    /// `-UMDiagTabs`: the replay game inside the real app shell (UIKit tab controller, the Game
    /// section's NavigationStack, the lobby), not the bare game screen, so anything that depends on
    /// the hosting chain (status bar, tab bar) behaves the way it does when signed in. Then it walks
    /// game -> lobby (what the back arrow does for a seated player) -> game, 6 s apart.
    private var tabs: some View {
        @Bindable var app = app
        return NativeAppTabs(
            selected: app.section,
            mentionBadge: 0,
            showsBar: app.showsAppTabs,
            showsMessages: false,
            play: AnyView(LobbyView().environment(app)),
            game: AnyView(GameSectionView().environment(app)),
            you: AnyView(Text("You").environment(app)),
            onSelect: { app.select($0) }
        )
        .ignoresSafeArea()
        .task {
            app.section = .game
            await run()
        }
        .task {
            try? await Task.sleep(for: .seconds(6))
            if ProcessInfo.processInfo.arguments.contains("-UMDiagDetach") {
                // Spectator back-out: the session closes (and its pinned images are released).
                UMDiag.log("replay", "tabs: detach")
                app.detachFromGame()
                return
            }
            UMDiag.log("replay", "tabs: back to lobby")
            app.goToLobby()
            try? await Task.sleep(for: .seconds(6))
            UMDiag.log("replay", "tabs: game tab")
            app.select(.game)
        }
    }
    #endif

    @ViewBuilder private var standalone: some View {
        let replay = NavigationStack {
            GameView()
        }
        .task { await run() }
        // `-UMDiagWidth <pt> [compact|regular]`: approximate a Split View / Slide Over window for
        // screenshots (simctl can't resize the simulator's scene).
        if let w = Self.diagWidth {
            HStack(spacing: 0) {
                replay
                    .frame(width: w.width)
                    .environment(\.horizontalSizeClass, w.compact ? .compact : .regular)
                Rectangle().fill(Color.black).ignoresSafeArea()
            }
        } else {
            replay
        }
    }

    private static var diagWidth: (width: CGFloat, compact: Bool)? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UMDiagWidth"), args.indices.contains(i + 1),
              let w = Double(args[i + 1]) else { return nil }
        let compact = args.indices.contains(i + 2) ? args[i + 2] == "compact" : w < 600
        return (CGFloat(w), compact)
    }

    @MainActor
    private func run() async {
        let s = GameSession(gameId: "diag-replay", spectate: true)
        app.game = s
        UMDiag.log("replay", "start")
        var players: [String: Any] = [:]
        for i in 0..<12 {
            players["p\(i)"] = ["id": "p\(i)", "name": "Player\(i)", "avatar": false, "playerListPosition": i]
        }
        s.debugFeed("loaded", nil)
        s.debugFeed("players", players)
        func msg(_ n: Int, phase: Int) -> [String: Any] {
            ["id": "m\(phase)-\(n)", "senderId": "p\(n % 12)", "content": "message \(n) in phase \(phase) about the cop and mafia vig claims",
             "time": Date().timeIntervalSince1970 * 1000, "meetingId": "village"]
        }
        // `-UMDiagTopBar pregame|middle|latest`: a static game for screenshots of the header (with
        // -UMDiagReplay): a real setup strip, a running clock, and the viewed phase at the start,
        // in the middle (both arrows) or at the newest phase (back arrow only).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-UMDiagTopBar"), args.indices.contains(i + 1) {
            let mode = args[i + 1]
            // `overflow`: a 20-player setup with 16 distinct roles, more than the header can fit.
            let roles: [String: Int] = mode == "overflow"
                ? ["Villager:": 3, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1, "Hooker:": 1, "Vigilante:": 1,
                   "Mason:": 2, "Bodyguard:": 1, "Jailer:": 1, "Mayor:": 1, "Mafioso:": 2, "Godfather:": 1,
                   "Janitor:": 1, "Framer:": 1, "Serial Killer:": 1, "Fool:": 1]
                : ["Villager:": 4, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1,
                   "Hooker:": 1, "Mafioso:": 2, "Godfather:": 1, "Serial Killer:": 1]
            s.debugFeed("setup", ["id": "diag-setup", "name": mode == "overflow" ? "Big Town" : "Guns n Hookers",
                                  "gameType": "Mafia", "roles": [roles]])
            if mode == "pregame" || mode == "overflow" {
                s.debugFeed("timerInfo", ["name": "pregameCountdown", "delay": 154_000])
                for n in 0..<12 { s.debugFeed("message", msg(n, phase: -1)) }
            } else {
                for (id, name) in [(0, "Day"), (1, "Night"), (2, "Day")] {
                    s.debugFeed("state", ["id": id, "name": name, "dayCount": id / 2 + 1])
                    for n in 0..<8 { s.debugFeed("message", msg(n, phase: id)) }
                }
                s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
                if mode == "middle" { s.viewPhase(1) }
            }
            UMDiag.log("replay", "topbar \(mode)")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-UMDiagHistory") {
            // Joining a running game: the screen is up (empty) first, then the whole backlog arrives
            // in one `history` event, then `state`.
            try? await Task.sleep(for: .seconds(1.5))
            var states: [String: Any] = [:]
            for (phase, name) in [(0, "Day"), (1, "Night"), (2, "Day")] {
                var msgs: [[String: Any]] = []
                for n in 0..<(phase == 1 ? 20 : 150) {
                    var m = msg(n, phase: phase)
                    // Mixed row heights, like real chat (short lines and long paragraphs).
                    if n % 7 == 0 { m["content"] = String(repeating: "long claim about the cop and the vig and who to lynch today ", count: 1 + n % 4) }
                    msgs.append(m)
                }
                states["\(phase)"] = ["name": name, "dayCount": phase / 2 + 1,
                                      "meetings": ["village": ["id": "village", "name": "Village", "messages": msgs]]]
            }
            s.debugFeed("history", states)
            s.debugFeed("state", ["id": 2, "name": "Day", "dayCount": 2])
            // Then the meetings, one `meeting` event each (village first, then the Spectator Meeting,
            // which brings up the composer and changes the chat's bottom inset).
            s.debugFeed("meeting", ["id": "village", "name": "Village", "speech": true, "voting": true, "amMember": false,
                                    "canTalk": false, "targets": [String](), "votes": [String: Any]()])
            s.debugFeed("meeting", ["id": "spec", "name": "Spectator Meeting", "speech": true, "voting": false,
                                    "amMember": true, "canTalk": true])
            s.debugFeed("loaded", nil)
            UMDiag.log("replay", "history loaded")
            return
        }
        s.debugFeed("state", ["id": 0, "name": "Day", "dayCount": 1])
        for n in 0..<200 { s.debugFeed("message", msg(n, phase: 0)) }
        try? await Task.sleep(for: .seconds(3))
        UMDiag.log("replay", "-> night")
        s.debugFeed("state", ["id": 1, "name": "Night", "dayCount": 1])
        for n in 0..<10 {
            s.debugFeed("message", msg(n, phase: 1)); try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(2))
        UMDiag.log("replay", "-> day")
        s.debugFeed("state", ["id": 2, "name": "Day", "dayCount": 2])
        s.debugFeed("obituaries", ["source": "Night", "dayCount": 2, "time": Date().timeIntervalSince1970 * 1000,
                                   "obituaries": [["playerInfo": ["id": "p3", "name": "Player3"],
                                                   "snippets": ["deathMessage": "Player3 was found dead.", "revealMessage": "Player3's role is Villager."]]]])
        for n in 0..<30 {
            UMDiag.log("replay", "send m2-\(n)")
            s.debugFeed("message", msg(n, phase: 2)); try? await Task.sleep(for: .milliseconds(250))
        }
        for (i, t) in ["An Alien followed by a long sentence that should wrap across the whole paragraph",
                       "Player5 claimed Cop, but I think the Alien probed them last night and the Mafia will hit the Doctor next, so watch the votes"].enumerated() {
            s.debugFeed("message", ["id": "wrap\(i)", "senderId": "p\(4 + i)", "content": t,
                                    "time": Date().timeIntervalSince1970 * 1000, "meetingId": "village"])
        }
        UMDiag.log("replay", "done")
    }
}
#endif
