#if DEBUG
import SwiftUI

/// DEBUG only. Launch with `-UMDiagReplay` to open a synthetic game (no network, no account) and
/// drive it through Day 1 -> Night 1 -> Day 2 with the same socket handlers, so phase-change stalls
/// and message latency show up in the diagnostics log / watchdog without joining a real game.
struct DiagReplayView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("-UMDiagSettings") {
            // Settings (You) screen only, scrolled to the Action Layout picker.
            ProfileView()
        } else if ProcessInfo.processInfo.arguments.contains("-UMDiagTabs") {
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
        // `-UMDiagVotes [act|actbottom|chat]` (with -UMDiagReplay): a Day with four actions and long
        // names for the Act tab and the chat vote log. Server order puts the Gun first; it should
        // be listed last (true item). `act` opens on Act, `actbottom` also scrolls to the end.
        if args.contains("-UMDiagVotes") {
            let names = ["Bartholomew_The_Unrelenting", "x", "MaximilianoGuadalupeRodriguez", "Ann",
                         "SuperLongUsernameForTesting", "VeryVeryLongNameIndeed123", "Bob", "ChristopherColumbusJr"]
            var long: [String: Any] = [:]
            for (i, n) in names.enumerated() {
                long["p\(i)"] = ["id": "p\(i)", "name": n, "avatar": false, "playerListPosition": i]
            }
            s.debugFeed("players", long)
            s.debugFeed("setup", ["id": "diag-setup", "name": "Guns n Hookers", "gameType": "Mafia",
                                  "roles": [["Villager:": 4, "Cop:": 1, "Gunsmith:": 1, "Mafioso:": 2]]])
            s.debugFeed("state", ["id": 2, "name": "Day", "dayCount": 2])
            let ids = (0..<names.count).map { "p\($0)" }
            s.debugFeed("meeting", ["id": "gun", "name": "Shoot Gun", "actionName": "Shoot", "itemName": "Gun",
                                    "itemIsTrueItem": true, "voting": true, "amMember": true,
                                    "targets": ids + ["*"], "votes": [String: Any]()])
            s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn",
                                    "speech": true, "voting": true, "amMember": true, "canTalk": false,
                                    "targets": ids + ["*"], "votes": [String: Any]()])
            s.debugFeed("meeting", ["id": "mafia", "name": "Mafia", "actionName": "Mafia Kill", "voting": true,
                                    "amMember": true, "targets": ids, "votes": ["p4": "p1", "p7": "p2"]])
            s.debugFeed("meeting", ["id": "cop", "name": "Learn Alignment", "actionName": "Learn Alignment",
                                    "voting": true, "amMember": true, "targets": ids, "votes": [String: Any]()])
            for (voter, target) in [("p0", "p5"), ("p1", "p5"), ("p2", "p7"), ("p3", "*"), ("p5", "p2"), ("p6", "p0"), ("p7", "p4")] {
                s.debugFeed("vote", ["meetingId": "village", "voterId": voter, "target": target])
            }
            s.debugFeed("unvote", ["meetingId": "village", "voterId": "p3"])
            for n in 0..<4 { s.debugFeed("message", msg(n, phase: 2)) }
            s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
            UMDiag.log("replay", "votes")
            return
        }
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
                    // `-UMDiagLong`: 40 lines a phase, so "top of the phase" is visibly not the end.
                    let count = args.contains("-UMDiagLong") ? 40 : 8
                    for n in 0..<count { s.debugFeed("message", msg(n, phase: id)) }
                }
                s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
                if mode == "middle" { s.viewPhase(1) }
            }
            UMDiag.log("replay", "topbar \(mode)")
            // `-UMDiagGunshot [late|hidden]`: a Day gunshot 3 s in, sent the way the server does
            // (gunshot, alert, death, reveal, instant obituaries). `late`: the obituary carries no
            // reveal and the `reveal` event comes 2 s after the paper; `hidden`: no reveal at all;
            // `eventonly`: see below. `real`: the exact shape of a live Frontier Justice Sheriff shot
            // (Games/core: Gun.js -> Player.kill -> queueDeathMessage/revealToAll -> processObituaryQueue),
            // a Janitor victim with a custom death message ("${name}#e9f792") and full getPlayerInfo().
            if let i = args.firstIndex(of: "-UMDiagGunshot") {
                let variant = args.indices.contains(i + 1) ? args[i + 1] : "normal"
                try? await Task.sleep(for: .seconds(3))
                let now = Date().timeIntervalSince1970 * 1000
                if variant == "real" {
                    s.debugFeed("gunshot", nil)
                    s.debugFeed("message", ["id": "gun-alert", "senderId": "server", "content": ":gun: Player2 pulls a gun and shoots at Player4!",
                                            "time": now, "meetingId": "village"])
                    s.debugFeed("death", "p4")
                    s.debugFeed("reveal", ["playerId": "p4", "role": "Janitor:"])
                    let info: [String: Any] = ["id": "p4", "name": "Player4", "userId": "u4", "avatar": false,
                                               "textColor": "#FFF", "nameColor": "#68a9dc", "animatedNameColor": "gradient",
                                               "nameGradientColorA": "#ffffff", "nameGradientColorB": "#be9d27",
                                               "nameGradientColorC": "#3dff6a", "customEmotes": [String: Any](),
                                               "customStickers": [String: Any](), "isBirthday": false,
                                               "avatarShape": "circle", "playerListPosition": 4]
                    s.debugFeed("obituaries", ["id": "2:instant-\(Int(now))", "source": "instant-\(Int(now))", "dayCount": 1, "time": now,
                                               "obituaries": [["snippets": ["deathMessage": "Player4#e9f792",
                                                                            "revealMessage": "Player4's role is Janitor."],
                                                               "id": "p4", "playerInfo": info]]])
                    UMDiag.log("replay", "gunshot real")
                    return
                }
                s.debugFeed("gunshot", nil)
                s.debugFeed("message", ["id": "gun-alert", "senderId": "server", "content": ":gun: Player2 pulls a gun and shoots at Player4!",
                                        "time": now, "meetingId": "village"])
                s.debugFeed("death", "p4")
                // `eventonly`: the reveal broadcast arrives (in server order) but the obituary has no revealMessage.
                if variant == "normal" || variant == "eventonly" { s.debugFeed("reveal", ["playerId": "p4", "role": "Cop"]) }
                var snippets: [String: Any] = ["deathMessage": "Player4 was shot."]
                if variant == "normal" { snippets["revealMessage"] = "Player4's role is Cop." }
                s.debugFeed("obituaries", ["id": "2:instant-\(Int(now))", "source": "instant-\(Int(now))", "dayCount": 1, "time": now,
                                           "obituaries": [["id": "p4", "playerInfo": ["id": "p4", "name": "Player4", "avatar": false],
                                                           "snippets": snippets]]])
                UMDiag.log("replay", "gunshot \(variant)")
                if variant == "late" {
                    try? await Task.sleep(for: .seconds(2))
                    s.debugFeed("reveal", ["playerId": "p4", "role": "Cop"])
                    UMDiag.log("replay", "late reveal")
                }
            }
            // `-UMDiagClockTap`: what tapping the header clock sends (chat to the top), 5 s in.
            if args.contains("-UMDiagClockTap") {
                try? await Task.sleep(for: .seconds(5))
                s.chatJumpTopTick &+= 1
                UMDiag.log("replay", "clock tap")
            }
            // `-UMDiagIncoming`: one new live message 6 s in (after any diag swipe), to check it
            // doesn't pull a reader who is at the top down to the end.
            if args.contains("-UMDiagIncoming") {
                try? await Task.sleep(for: .seconds(6))
                s.debugFeed("message", ["id": "late-1", "senderId": "p5", "content": "a new message arrives in the live phase",
                                        "time": Date().timeIntervalSince1970 * 1000, "meetingId": "village"])
                UMDiag.log("replay", "incoming late-1")
            }
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
