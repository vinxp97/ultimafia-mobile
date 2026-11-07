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
        // `-UMDiagTopBar pregame|middle|latest|overflow|many|many-earliest|many-middle|many-latest|many-post`:
        // static header screenshots (with -UMDiagReplay). many*: six play phases + Postgame so the
        // wide strip's max-3 window can be checked at earliest / middle / latest / postgame.
        let args = ProcessInfo.processInfo.arguments
        // `-UMDiagJoinOrder [livefirst|historyfirst|liveafter|duphistory]`: lobby join chronology.
        // Server seatPlayer sends the live "X has joined" alert before `history`. The chat UI reads
        // phases[i].messages; without re-sorting that list after history, the join sticks at the top.
        // Modes: livefirst (default race), historyfirst (history then join at end), liveafter (history
        // then a later live chat), duphistory (second history with the same ids must not reshuffle).
        if let i = args.firstIndex(of: "-UMDiagJoinOrder") {
            let mode = args.indices.contains(i + 1) ? args[i + 1] : "livefirst"
            s.debugFeed("self", "p11")
            s.debugFeed("setup", ["id": "diag-setup", "name": "Guns n Hookers", "gameType": "Mafia", "total": 12,
                                  "roles": [["Villager:": 6, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1, "Mafioso:": 2, "Serial Killer:": 1]]])
            let t0 = Date().timeIntervalSince1970 * 1000 - 60_000
            let tHello = t0 + 10_000
            let tJoin = t0 + 50_000
            let tLater = t0 + 70_000
            func alert(_ id: String, _ content: String, _ time: Double) -> [String: Any] {
                ["id": id, "senderId": "server", "content": content, "time": time]
            }
            func chat(_ id: String, _ sender: String, _ content: String, _ time: Double) -> [String: Any] {
                ["id": id, "senderId": sender, "content": content, "time": time, "meetingId": "pregame"]
            }
            let joinLive = alert("join-vinman", "Vinman has joined.", tJoin)
            let history: [String: Any] = [
                "-1": [
                    "name": "Pregame",
                    "alerts": [
                        alert("join-alice", "Alice has joined.", t0),
                        alert("join-bob", "Bob has joined.", t0 + 5_000),
                        joinLive,
                    ],
                    "meetings": [
                        "pregame": [
                            "id": "pregame", "name": "Pregame", "speech": true, "messages": [
                                chat("m-hello", "p0", "hello lobby", tHello),
                                chat("m-claim", "p1", "I am claiming Cop", tHello + 5_000),
                            ],
                        ],
                    ],
                ],
            ]
            func writeCheck(_ label: String) {
                let lines = s.displayedMessages
                let first = lines.first?.content ?? "-"
                let last = lines.last?.content ?? "-"
                let joinIdx = lines.firstIndex(where: { $0.id == "join-vinman" }).map(String.init) ?? "-"
                let okTop = !(lines.first?.id == "join-vinman")
                let okPresent = lines.contains(where: { $0.id == "join-vinman" })
                let line = "JOINCHECK mode=\(mode) label=\(label) count=\(lines.count) joinIdx=\(joinIdx) first=\(first) last=\(last) okTop=\(okTop) okPresent=\(okPresent)"
                UMDiag.log("replay", line)
                if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? (line + "\n").write(to: dir.appendingPathComponent("joincheck.txt"), atomically: true, encoding: .utf8)
                }
            }
            switch mode {
            case "historyfirst":
                s.debugFeed("history", history)
                s.debugFeed("message", joinLive) // duplicate id — ignored; order already from history
                writeCheck("after")
            case "liveafter":
                s.debugFeed("history", history)
                s.debugFeed("message", chat("m-later", "p2", "anyone there?", tLater))
                writeCheck("after")
            case "duphistory":
                s.debugFeed("message", joinLive)
                s.debugFeed("history", history)
                s.debugFeed("history", history) // second pass: all ids already seen
                s.debugFeed("message", chat("m-later", "p2", "anyone there?", tLater))
                writeCheck("after")
            default: // livefirst — the real seatPlayer race
                s.debugFeed("message", joinLive)
                writeCheck("before-history")
                s.debugFeed("history", history)
                writeCheck("after")
            }
            s.debugFeed("meeting", ["id": "pregame", "name": "Pregame", "speech": true, "voting": false,
                                    "amMember": true, "canTalk": true])
            s.debugFeed("timerInfo", ["name": "pregameWait", "delay": 600_000])
            UMDiag.log("replay", "joinorder \(mode)")
            return
        }
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
        // `-UMDiagGhost night|clueother|clue|cluepass|day|dusk|over [act]` (with -UMDiagReplay): a
        // Mafia game with the Ghost role, events shaped like the server's (Mafia getStateInfo
        // extraInfo, OuijaBoard Give Clue, the giveClue broadcast, GhostGuessWord). night: you are a
        // Ghost picking the first clue giver; clueother: Eve's turn; clue: your turn (p0);
        // cluepass: your turn, then the fixture submits "stallion" through session.vote and the turn
        // passes to Eve; day: Day 2 with the Village condemn vote; dusk: you are the condemned Ghost
        // guessing the word; over: Postgame with the word reveal. `act` opens on the Act tab.
        // Prints a GHOSTCHECK line to stdout (and Documents/ghostcheck.txt) 5 s in (scripts/ghost-sim-test.sh asserts on it).
        if let i = args.firstIndex(of: "-UMDiagGhost") {
            let mode = args.indices.contains(i + 1) ? args[i + 1] : "clue"
            let names = ["Vinman", "Alice", "Bob", "Charlie", "Dana", "Eve", "Frank", "Grace"]
            var ps: [String: Any] = [:]
            for (n, name) in names.enumerated() {
                ps["p\(n)"] = ["id": "p\(n)", "name": name, "avatar": false, "playerListPosition": n]
            }
            s.debugFeed("players", ps)
            s.debugFeed("connected", nil)
            s.debugFeed("self", "p0")
            s.debugFeed("isSpectator", false)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                let line = "GHOSTCHECK mode=\(mode) stage=\(s.ghostStage) turn=\(s.ghostTurn?.name ?? "-") "
                    + "mine=\(s.isMyGhostTurn) clues=\(s.ghostClues.count) last=\(s.ghostClues.last.map { "\($0.name):\($0.text)" } ?? "-") "
                    + "word=\(s.ghostMyWord ?? "-") real=\(s.ghostRealWord ?? "-") len=\(s.ghostWordLength ?? 0) "
                    + "single=\(s.isSingleStateView) ghost=\(s.isGhostGame) panel=\(s.ghostHasContent) "
                    + "rounds=\(s.ghostClues.map { $0.round.map(String.init) ?? "e" }.joined(separator: "")) "
                    + "meetings=\(s.meetings.map(\.name).joined(separator: ","))"
                print(line)
                fflush(stdout)
                if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? (line + "\n").write(to: dir.appendingPathComponent("ghostcheck.txt"), atomically: true, encoding: .utf8)
                }
                UMDiag.log("replay", line)
            }
            let ids = (0..<names.count).map { "p\($0)" }
            // Reconnect / replay: one `history` payload. Pranay: currentClueHistory is the game's
            // one shared array, so every stored state after the first clue serializes ALL clues so
            // far; states before the first clue have it undefined; giveClue is not re-sent.
            // replay: alerts present, Dana's turn announced inside Give Clue 2 (expect 11 clues,
            // no duplicates, rounds 1/2). replaynight: Give Clue 1 alerts trimmed (seeded from
            // extraInfo), Give Clue 2 just started; Bob's turn was announced in Night 2.
            // host: Ghost + Host without Poet, no words / wordLength: plain Mafia.
            if mode == "host" {
                s.debugFeed("setup", ["id": "diag-ghost-host", "name": "Haunted Hosting", "gameType": "Mafia", "total": 8,
                                      "roles": [["Villager:": 5, "Ghost:": 2, "Host:": 1]]])
                s.debugFeed("state", ["id": -1, "name": "Pregame"])
                s.debugFeed("state", ["id": 0, "name": "Night 1", "dayCount": 1, "extraInfo": ["showGameInfo": false]])
                s.debugFeed("state", ["id": 1, "name": "Day 1", "dayCount": 1, "extraInfo": ["showGameInfo": false]])
                s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn",
                                        "speech": true, "voting": true, "amMember": true, "canTalk": true, "canVote": true,
                                        "targets": ids + ["*"], "votes": [String: Any]()])
                s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
                return
            }
            s.debugFeed("setup", ["id": "diag-ghost", "name": "Ghost Town", "gameType": "Mafia", "total": 8,
                                  "roles": [["Villager:": 5, "Ghost:": 2, "Miller:": 1]]])
            if mode == "replay" || mode == "replaynight" {
                let night = mode == "replaynight"
                var t0 = Date().timeIntervalSince1970 * 1000 - 600_000
                func al(_ id: String, _ text: String) -> [String: Any] {
                    t0 += 3_000
                    return ["id": id, "senderId": "server", "content": text, "time": t0]
                }
                let r1 = [("Alice", "saddle"), ("Bob", "gallop"), ("Charlie", "stable"), ("Dana", "hay"),
                          ("Eve", "carriage"), ("Frank", "mane"), ("Grace", "farm"), ("Vinman", "pony")]
                let r2 = night ? [] : [("Bob", "rider"), ("Charlie", "hooves")]
                let whole = (r1 + r2).map { "\($0.0): \($0.1)" }
                let xi: [String: Any] = ["wordLength": 5, "currentClueHistory": whole, "showGameInfo": true]
                var gc1: [[String: Any]] = []
                if !night { for (n, c) in r1.enumerated() { gc1.append(al("h1-\(n)", "\(c.0): \(c.1)")) } }
                var gc2: [[String: Any]] = []
                for (n, c) in r2.enumerated() { gc2.append(al("h2-\(n)", "\(c.0): \(c.1)")) }
                if !night { gc2.append(al("h2-turn", "Dana is giving a clue…")) }
                let history: [String: Any] = [
                    "-1": ["name": "Pregame", "alerts": [[String: Any]]()],
                    "0": ["name": "Night 1", "dayCount": 1, "extraInfo": ["wordLength": 5, "showGameInfo": false],
                          "alerts": [al("hw", "The secret word is: horse."), al("hn1", "Alice is giving a clue…")]],
                    "1": ["name": "Give Clue 1", "dayCount": 1, "extraInfo": ["wordLength": 5, "currentClueHistory": whole, "showGameInfo": false],
                          "alerts": gc1],
                    "2": ["name": "Day 1", "dayCount": 1, "extraInfo": xi,
                          "alerts": [al("hc", "Clues")] + r1.enumerated().map { al("hr-\($0.offset)", "\($0.element.0): \($0.element.1)") }],
                    "3": ["name": "Night 2", "dayCount": 2, "extraInfo": xi, "alerts": [al("hn2", "Bob is giving a clue…")]],
                    "4": ["name": "Give Clue 2", "dayCount": 2, "extraInfo": xi, "alerts": gc2],
                ]
                s.debugFeed("history", history)
                s.debugFeed("timerInfo", ["name": "main", "delay": 77_000])
                return
            }
            var t = Date().timeIntervalSince1970 * 1000 - 400_000
            func alert(_ id: String, _ text: String) {
                t += 3_000
                s.debugFeed("message", ["id": id, "senderId": "server", "content": text, "time": t])
            }
            func say(_ id: String, _ from: String, _ text: String, _ meeting: String) {
                t += 3_000
                s.debugFeed("message", ["id": id, "senderId": from, "content": text, "time": t, "meetingId": meeting])
            }
            let ghostMe = mode == "dusk" || mode == "night"
            s.debugFeed("state", ["id": -1, "name": "Pregame"])
            s.debugFeed("state", ["id": 0, "name": "Night 1", "dayCount": 1,
                                  "extraInfo": ["wordLength": 5, "showGameInfo": false]])
            alert("w", ghostMe ? "Guess the hidden word of length: 5" : "The secret word is: horse.")
            if mode == "night" {
                s.debugFeed("meeting", ["id": "ghostpick", "name": "Ghost", "actionName": "Pick first clue giver",
                                        "voting": true, "instant": true, "group": true, "mustAct": true,
                                        "amMember": true, "canVote": true,
                                        "targets": ids, "votes": ["p4": "p1"]])
                s.debugFeed("timerInfo", ["name": "main", "delay": 41_000])
                UMDiag.log("replay", "ghost night")
                return
            }
            alert("pick", "Alice is giving a clue…")
            s.debugFeed("giveClue", "p1")
            s.debugFeed("state", ["id": 1, "name": "Give Clue 1", "dayCount": 1,
                                  "extraInfo": ["wordLength": 5, "currentClueHistory": [String](), "showGameInfo": false]])
            let r1 = [("Alice", "saddle"), ("Bob", "gallop"), ("Charlie", "stable"), ("Dana", "hay"),
                      ("Eve", "carriage"), ("Frank", "mane"), ("Grace", "farm"), ("Vinman", "pony")]
            for (n, c) in r1.enumerated() { alert("c1-\(n)", "\(c.0): \(c.1)") }
            s.debugFeed("state", ["id": 2, "name": "Day 1", "dayCount": 1,
                                  "extraInfo": ["wordLength": 5, "currentClueHistory": r1.map { "\($0.0): \($0.1)" }, "showGameInfo": true]])
            say("d1", "p2", "Grace said farm, that's vague", "village1")
            say("d2", "p7", "farm fits, horses live on farms!", "village1")
            alert("d3", "No one was condemned.")
            s.debugFeed("state", ["id": 4, "name": "Night 2", "dayCount": 2,
                                  "extraInfo": ["wordLength": 5, "currentClueHistory": r1.map { "\($0.0): \($0.1)" }, "showGameInfo": true]])
            alert("n2", "Bob is giving a clue…")
            s.debugFeed("giveClue", "p2")
            s.debugFeed("state", ["id": 5, "name": "Give Clue 2", "dayCount": 2,
                                  "extraInfo": ["wordLength": 5, "currentClueHistory": r1.map { "\($0.0): \($0.1)" }, "showGameInfo": true]])
            let r2 = [("Bob", "rider"), ("Charlie", "hooves"), ("Dana", "barn")]
            for (n, c) in r2.enumerated() { alert("c2-\(n)", "\(c.0): \(c.1)") }
            let all = (r1 + r2).map { "\($0.0): \($0.1)" }
            switch mode {
            case "day", "dusk", "over":
                for (n, c) in [("Frank", "neigh"), ("Grace", "race"), ("Vinman", "stallion")].enumerated() {
                    alert("c3-\(n)", "\(c.0): \(c.1)")
                }
                let full = all + ["Frank: neigh", "Grace: race", "Vinman: stallion"]
                s.debugFeed("state", ["id": 6, "name": "Day 2", "dayCount": 2,
                                      "extraInfo": ["wordLength": 5, "currentClueHistory": full, "showGameInfo": true]])
                alert("cl", "Clues")
                say("e1", "p3", "Grace said race twice now, sus", "village")
                say("e2", "p7", "race is a horse thing!! vote Frank", "village")
                if mode == "over" {
                    alert("o1", "Grace has been condemned.")
                    alert("o2", "Grace guesses horse.")
                    alert("o3", "The Ghost has successfully guessed the word!")
                    s.debugFeed("state", ["id": -2, "name": "Postgame",
                                          "extraInfo": ["wordLength": 5, "currentClueHistory": full, "showGameInfo": true]])
                    alert("o4", "The real word was horse.")
                    alert("o5", "The fake word was zebra.")
                } else if mode == "dusk" {
                    alert("cd", "Vinman has been condemned.")
                    s.debugFeed("state", ["id": 7, "name": "Dusk 2", "dayCount": 2,
                                          "extraInfo": ["wordLength": 5, "currentClueHistory": full, "showGameInfo": true]])
                    s.debugFeed("meeting", ["id": "guess", "name": "Guess Word", "actionName": "Guess Word",
                                            "voting": true, "instant": true, "amMember": true, "canVote": true,
                                            "inputType": "text", "itemName": "GhostGuessWord",
                                            "textOptions": ["minLength": 2, "maxLength": 20, "alphaOnly": true,
                                                            "toLowerCase": true, "submit": "Confirm"],
                                            "targets": [String](), "votes": [String: Any]()])
                    s.debugFeed("timerInfo", ["name": "main", "delay": 52_000])
                } else {
                    s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn",
                                            "speech": true, "voting": true, "amMember": true, "canTalk": true, "canVote": true,
                                            "targets": ids + ["*"], "votes": [String: Any]()])
                    for (voter, target) in [("p1", "p6"), ("p3", "p7"), ("p7", "p6")] {
                        s.debugFeed("vote", ["meetingId": "village", "voterId": voter, "target": target])
                    }
                    s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
                }
            case "clueother":
                alert("turn", "Eve is giving a clue…")
                s.debugFeed("giveClue", "p5")
                s.debugFeed("timerInfo", ["name": "main", "delay": 104_000])
            default:
                alert("turn", "Vinman is giving a clue…")
                s.debugFeed("giveClue", "p0")
                s.debugFeed("meeting", ["id": "clue", "name": "Give Clue", "actionName": "Give Clue (1-50)",
                                        "voting": true, "instant": true, "amMember": true, "canVote": true,
                                        "inputType": "text", "itemName": "Ouija Board",
                                        "textOptions": ["minLength": 1, "maxLength": 50, "submit": "Confirm"],
                                        "targets": [String](), "votes": [String: Any]()])
                s.debugFeed("timerInfo", ["name": "main", "delay": 104_000])
                // What you submit is answered the way OuijaBoard does: the alert, then the next holder.
                s.debugSendHook = { [weak s] event, payload in
                    guard let s, event == "vote", payload["meetingId"] as? String == "clue",
                          let clue = payload["selection"] as? String else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        alert("mine", "Vinman: \(clue)")
                        s.debugFeed("leftMeeting", "clue")
                        alert("next", "Eve is giving a clue…")
                        s.debugFeed("giveClue", "p5")
                    }
                }
                if mode == "cluepass" {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        s.vote(meetingId: "clue", selection: "stallion")
                    }
                }
            }
            UMDiag.log("replay", "ghost \(mode)")
            return
        }
        // `-UMDiagSpectate [ok|fail]` (with -UMDiagReplay): a pregame lobby where you hold seat p0
        // and spectating is on, so the Spectate button shows. Tapping it is answered the way the
        // server does: `ok` = Game.movePlayerToSpectator (playerLeave, self, isSpectator, players,
        // alert); `fail` = spectateFromSeat's refusal (`spectateFailed`, seat kept).
        if let i = args.firstIndex(of: "-UMDiagSpectate") {
            let mode = args.indices.contains(i + 1) ? args[i + 1] : "ok"
            s.debugFeed("connected", nil)
            s.debugFeed("self", "p0")
            s.debugFeed("isSpectator", false)
            s.debugFeed("setup", ["id": "diag-setup", "name": "Guns n Hookers", "gameType": "Mafia", "total": 12,
                                  "roles": [["Villager:": 6, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1, "Mafioso:": 2, "Serial Killer:": 1]]])
            s.debugFeed("options", ["spectating": true, "ranked": false, "competitive": false])
            s.debugFeed("timerInfo", ["name": "pregameWait", "delay": 600_000])
            for n in 0..<6 { s.debugFeed("message", msg(n, phase: -1)) }
            UMDiag.log("replay", "spectate \(mode)")
            for _ in 0..<600 {
                if s.spectateRequestPending { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard s.spectateRequestPending else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if mode == "fail" {
                s.debugFeed("spectateFailed", "You are the only player in this game, so you cannot move to spectators. Leave the game instead, or wait for another player to join.")
                return
            }
            s.debugFeed("playerLeave", "p0")
            s.debugFeed("self", "s0")
            s.debugFeed("isSpectator", nil)
            var rest: [String: Any] = [:]
            for i in 1..<12 { rest["p\(i)"] = players["p\(i)"] }
            s.debugFeed("players", rest)
            s.debugFeed("message", ["id": "spec-alert", "senderId": "server", "content": "Player0 is now spectating.",
                                    "time": Date().timeIntervalSince1970 * 1000, "meetingId": "village"])
            return
        }
        // `-UMDiagSpecChat pregame|game|postgame|join|joinfail` (with -UMDiagReplay): you are
        // spectator s0 ("Vinman"). pregame: the Pregame chat (players + another spectator), the
        // Join open seat bar; game: Day 2 with village chat and Spectator Meeting lines merged by
        // time, a spectator quote, the Spectators list; postgame: no composer. What you send is
        // echoed back the way the server would (speak -> message in that meeting, quote -> quote);
        // join answers takeSeat with isSpectator false + playerJoin, joinfail with takeSeatFailed.
        // `-UMDiagReplies` (with -UMDiagReplay): you hold seat p0 on Day 2. Styled players (name
        // colour + BettyNoir font + text colour, gradient name, stickers), replies merged with their
        // quote, a reply whose original is a sticker, a reply carrying a sticker, a reply to a line
        // in another phase, and one whose quote never arrived. What you send as a reply is echoed
        // back the way the server posts it (quote, then the line with replyTo).
        if args.contains("-UMDiagReplies") {
            let sticker = UMSiteEmote.url(forToken: ":gun:")?.absoluteString ?? ""
            let t0 = Date().timeIntervalSince1970 * 1000 - 300_000
            var styled = players
            styled["p1"] = ["id": "p1", "name": "Bartholomew", "userId": "u1", "avatar": false, "playerListPosition": 1,
                            "nameColor": "#e05a9c", "nameFont": "bettynoir", "textColor": "#ffd27a"]
            styled["p2"] = ["id": "p2", "name": "Gradient", "userId": "u2", "avatar": false, "playerListPosition": 2,
                            "nameColor": "#68a9dc", "animatedNameColor": "gradient", "nameGradientColorA": "#ffffff",
                            "nameGradientColorB": "#be9d27", "nameGradientColorC": "#3dff6a", "textColor": "#a8e6ff"]
            styled["p3"] = ["id": "p3", "name": "Stickerman", "userId": "u3", "avatar": false, "playerListPosition": 3,
                            "customStickers": [":bigwave:": sticker]]
            styled["p5"] = ["id": "p5", "name": "Player5", "userId": "u5", "avatar": false, "playerListPosition": 5,
                            "customStickers": [":bigwave:": sticker]]
            s.debugFeed("players", styled)
            s.debugFeed("connected", nil)
            s.debugFeed("self", "p0")
            s.debugFeed("isSpectator", false)
            s.debugFeed("setup", ["id": "diag-setup", "name": "Guns n Hookers", "gameType": "Mafia", "total": 12,
                                  "roles": [["Villager:": 6, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1, "Mafioso:": 2, "Serial Killer:": 1]]])
            s.debugFeed("options", ["spectating": true])
            s.debugFeed("state", ["id": 0, "name": "Day", "dayCount": 1])
            s.debugFeed("message", ["id": "d1", "senderId": "p7", "content": "day one: I think the Cop is lying", "time": t0, "meetingId": "village0"])
            s.debugFeed("state", ["id": 2, "name": "Day", "dayCount": 2])
            s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn", "speech": true,
                                    "voting": true, "amMember": true, "canTalk": true, "canVote": true,
                                    "targets": (0..<12).map { "p\($0)" } + ["*"], "votes": [String: Any]()])
            var n = 0.0
            func say(_ id: String, _ sender: String, _ text: String, replyTo: String? = nil) {
                n += 1
                var m: [String: Any] = ["id": id, "senderId": sender, "content": text, "time": t0 + 60_000 + n * 4_000, "meetingId": "village"]
                if let replyTo { m["replyTo"] = replyTo }
                s.debugFeed("message", m)
            }
            func quote(_ id: String, _ sender: String, of messageId: String, fromState: Int = 2, fromMeeting: String = "village") {
                n += 1
                s.debugFeed("quote", ["id": id, "messageId": messageId, "senderId": sender, "toMeetingId": "village",
                                      "fromMeetingId": fromMeeting, "fromState": fromState, "time": t0 + 60_000 + n * 4_000])
            }
            say("m1", "p1", "the cop claim is fake, trust me :gun: see https://ultimafia.com")
            say("m2", "p2", "who do we vote today? Doctor speak up")
            say("m3", "p3", ":bigwave:")
            quote("q1", "p2", of: "m1")
            say("r1", "p2", "no, I believe the Cop", replyTo: "q1")
            say("m4", "p8", "lets hurry up")
            quote("q2", "p4", of: "m3")
            say("r2", "p4", "nice sticker lol", replyTo: "q2")
            quote("q3", "p5", of: "m2")
            say("r3", "p5", ":bigwave:", replyTo: "q3")
            quote("q4", "p6", of: "d1", fromState: 0, fromMeeting: "village0")
            say("r4", "p6", "you said that yesterday too", replyTo: "q4")
            say("r5", "p9", "replying to something old", replyTo: "q-missing")
            s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
            s.debugSendHook = { [weak s] event, payload in
                guard let s, event == "reply" || event == "speak" || event == "quote" else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    n += 1
                    let now = Date().timeIntervalSince1970 * 1000
                    if event == "reply", let q = payload["quote"] as? [String: Any], let m = payload["message"] as? [String: Any] {
                        let qid = "eq\(Int(n))"
                        UMDiag.log("replay", "replies reply -> \(q["messageId"] ?? "")")
                        var quote = q; quote["id"] = qid; quote["senderId"] = "p0"; quote["time"] = now
                        s.debugFeed("quote", quote)
                        s.debugFeed("message", ["id": "er\(Int(n))", "senderId": "p0", "content": m["content"] ?? "",
                                                "time": now + 1, "meetingId": m["meetingId"] ?? "village", "replyTo": qid])
                    } else if event == "quote" {
                        UMDiag.log("replay", "replies quote -> \(payload["messageId"] ?? "")")
                        var quote = payload; quote["id"] = "eq\(Int(n))"; quote["senderId"] = "p0"; quote["time"] = now
                        s.debugFeed("quote", quote)
                    } else {
                        UMDiag.log("replay", "replies speak")
                        s.debugFeed("message", ["id": "es\(Int(n))", "senderId": "p0", "content": payload["content"] ?? "",
                                                "time": now, "meetingId": payload["meetingId"] ?? "village"])
                    }
                }
            }
            UMDiag.log("replay", "replies")
            return
        }
        // `-UMDiagHistoricalReply` (with -UMDiagReplay): seated on Day 2 with Day 1 history.
        // Asserts quote / reply / speak / cancel / own-echo / denied-night / phase-step while
        // browsing Day 1 never force the live day; leaves Day 1 on screen with Replying-to bar
        // for a screenshot. No real network sends (debugSendHook only).
        if args.contains("-UMDiagHistoricalReply") {
            let t0 = Date().timeIntervalSince1970 * 1000 - 300_000
            s.debugFeed("players", players)
            s.debugFeed("connected", nil)
            s.debugFeed("self", "p0")
            s.debugFeed("isSpectator", false)
            s.debugFeed("setup", ["id": "diag-setup", "name": "Guns n Hookers", "gameType": "Mafia", "total": 12,
                                  "roles": [["Villager:": 6, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1, "Mafioso:": 2, "Serial Killer:": 1]]])
            s.debugFeed("options", ["spectating": true])
            s.debugFeed("state", ["id": 0, "name": "Day", "dayCount": 1])
            s.debugFeed("message", ["id": "d1-a", "senderId": "p3", "content": "day one claim: I am Cop",
                                    "time": t0, "meetingId": "village0"])
            s.debugFeed("message", ["id": "d1-b", "senderId": "p4", "content": "ok trust the Cop for now",
                                    "time": t0 + 5_000, "meetingId": "village0"])
            s.debugFeed("state", ["id": 1, "name": "Night", "dayCount": 1])
            s.debugFeed("state", ["id": 2, "name": "Day", "dayCount": 2])
            s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn", "speech": true,
                                    "voting": true, "amMember": true, "canTalk": true, "canVote": true,
                                    "targets": (0..<12).map { "p\($0)" } + ["*"], "votes": [String: Any]()])
            s.debugFeed("message", ["id": "d2-a", "senderId": "p5", "content": "day two: who to vote?",
                                    "time": t0 + 120_000, "meetingId": "village"])
            s.debugFeed("timerInfo", ["name": "main", "delay": 240_000])
            var sent: [(String, [String: Any])] = []
            s.debugSendHook = { event, payload in
                sent.append((event, payload))
            }
            GameMusic.stop()

            func expect(_ cond: Bool, _ label: String) {
                if cond { UMDiag.log("histReply", "PASS \(label)") }
                else { UMDiag.log("histReply", "FAIL \(label)") }
            }

            let day1 = 0
            let live = 2
            expect(s.currentPhaseId == live, "live is Day 2")
            s.viewPhase(day1)
            expect(s.viewingPhaseId == day1 && !s.isViewingLive && !s.followLive, "browsing Day 1")
            expect(s.showComposer, "composer visible while browsing history")
            let prior = s.displayedMessages.first(where: { $0.id == "d1-a" })
            expect(prior != nil, "Day 1 line present")
            guard let prior else {
                UMDiag.log("replay", "historical-reply setup missing d1-a")
                return
            }
            let anchorBefore = s.phaseScrollAnchors[day1]

            // Single-tap reply: stay put + Replying-to target.
            let pending = s.chatLineTapped(prior, at: Date())
            expect(pending == .pendingReply, "tap queues pending reply")
            // Advance past double-tap window so the reply bar commits.
            try? await Task.sleep(for: .milliseconds(350))
            expect(s.replyTarget?.id == prior.id, "reply target set")
            expect(s.viewingPhaseId == day1 && !s.followLive, "reply keeps Day 1")
            expect(s.phaseScrollAnchors[day1] == anchorBefore, "reply leaves scroll anchor")

            // Cancel reply: still on Day 1.
            s.cancelReply()
            expect(s.replyTarget == nil && s.replyHighlightId == nil, "cancel clears reply")
            expect(s.viewingPhaseId == day1, "cancel stays on Day 1")

            // Plain speak while browsing: destination is live village, view stays.
            sent.removeAll()
            expect(s.speak("watching yesterday still"), "plain speak allowed")
            expect(s.viewingPhaseId == day1, "plain speak stays on Day 1")
            expect(sent.contains(where: { $0.0 == "speak" }), "speak event emitted")
            if let speak = sent.first(where: { $0.0 == "speak" })?.1 {
                expect((speak["meetingId"] as? String) == "village", "speak targets live village")
            }

            // Re-queue reply and send it.
            _ = s.chatLineTapped(prior, at: Date())
            try? await Task.sleep(for: .milliseconds(350))
            sent.removeAll()
            expect(s.speak("quoting day one from here"), "reply speak allowed")
            expect(s.viewingPhaseId == day1, "reply send stays on Day 1")
            expect(s.replyTarget == nil, "reply cleared after send")
            expect(sent.contains(where: { $0.0 == "reply" }), "reply event emitted")
            if let reply = sent.first(where: { $0.0 == "reply" })?.1,
               let quote = reply["quote"] as? [String: Any],
               let message = reply["message"] as? [String: Any] {
                expect((quote["messageId"] as? String) == "d1-a", "reply quotes Day 1 line")
                expect((quote["toMeetingId"] as? String) == "village", "reply toMeeting is live")
                expect((message["meetingId"] as? String) == "village", "reply body to live village")
                expect((message["content"] as? String) == "quoting day one from here", "reply content")
            }

            // Own echo into live day must not yank the browse selection.
            let echoT = Date().timeIntervalSince1970 * 1000
            s.debugFeed("quote", ["id": "eq-own", "messageId": "d1-a", "senderId": "p0",
                                  "toMeetingId": "village", "fromMeetingId": "village0",
                                  "fromState": 0, "time": echoT])
            s.debugFeed("message", ["id": "er-own", "senderId": "p0", "content": "quoting day one from here",
                                    "time": echoT + 1, "meetingId": "village", "replyTo": "eq-own"])
            expect(s.viewingPhaseId == day1, "own echo stays on Day 1")
            expect(s.displayedMessages.contains(where: { $0.id == "d1-a" }), "still showing Day 1 lines")

            // Double-tap quote: must NOT jump (the original bug).
            let now = Date()
            _ = s.chatLineTapped(prior, at: now)
            sent.removeAll()
            let quoted = s.chatLineTapped(prior, at: now.addingTimeInterval(0.05))
            expect(quoted == .quoted, "double tap quotes")
            expect(s.viewingPhaseId == day1 && !s.followLive, "quote keeps Day 1 (no jump)")
            expect(sent.contains(where: { $0.0 == "quote" }), "quote event emitted")
            if let q = sent.first(where: { $0.0 == "quote" })?.1 {
                expect((q["toMeetingId"] as? String) == "village", "quote toMeeting is live")
                expect((q["messageId"] as? String) == "d1-a", "quote messageId")
            }

            // Night with no speakable meeting: draft-only / denied send while browsing Day 1.
            s.debugFeed("state", ["id": 3, "name": "Night", "dayCount": 2])
            // Drop speech meetings so canTalk is false (live night).
            s.debugFeed("meeting", ["id": "village", "name": "Village", "speech": false, "voting": false,
                                    "amMember": true, "canTalk": false, "canVote": false,
                                    "targets": [String](), "votes": [String: Any]()])
            s.viewPhase(day1)
            expect(s.currentPhaseId == 3 && s.viewingPhaseId == day1, "night live, browsing Day 1")
            expect(s.isDraftOnly || !s.canTalk, "cannot speak at night")
            expect(s.isDraftOnly || !(s.canTalk || s.speechChannels.contains(where: { $0.canTalk })),
                   "night has no speakable meeting")
            expect(!s.speak("should not send at night"), "night send denied")
            expect(s.viewingPhaseId == day1, "denied send stays on Day 1")

            // Restore a talkable Day so composer + reply bar work for the screenshot.
            s.debugFeed("state", ["id": 4, "name": "Day", "dayCount": 3])
            s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn", "speech": true,
                                    "voting": true, "amMember": true, "canTalk": true, "canVote": true,
                                    "targets": (0..<12).map { "p\($0)" } + ["*"], "votes": [String: Any]()])
            s.viewPhase(day1)
            expect(s.followLive == false && s.viewingPhaseId == day1, "explicit Day 1 after live day advance")
            _ = s.chatLineTapped(prior, at: Date())
            try? await Task.sleep(for: .milliseconds(350))
            expect(s.replyTarget?.id == prior.id && s.viewingPhaseId == day1, "screenshot: reply on Day 1")

            // Live path still follows when viewing live.
            s.viewLivePhase()
            expect(s.isViewingLive && s.followLive, "viewLive restores follow")
            let liveCount = s.displayedMessages.count
            s.debugFeed("message", ["id": "live-new", "senderId": "p6", "content": "new on live day",
                                    "time": Date().timeIntervalSince1970 * 1000, "meetingId": "village"])
            expect(s.displayedMessages.count == liveCount + 1, "live autoscroll source grows")
            // Back to Day 1 with reply for the capture.
            s.viewPhase(day1)
            _ = s.chatLineTapped(prior, at: Date())
            try? await Task.sleep(for: .milliseconds(350))
            GameMusic.stop()
            UMDiag.log("replay", "historical-reply ready (Day 1 + replying bar)")
            return
        }
        if let i = args.firstIndex(of: "-UMDiagSpecChat") {
            let mode = args.indices.contains(i + 1) ? args[i + 1] : "pregame"
            let t0 = Date().timeIntervalSince1970 * 1000 - 120_000
            var seq = 0
            func line(_ sender: String, _ text: String, _ meeting: String, _ dt: Double) -> [String: Any] {
                seq += 1
                return ["id": "sc\(seq)", "senderId": sender, "content": text, "time": t0 + dt, "meetingId": meeting]
            }
            var spectators: [String: Any] = [
                "s0": ["id": "s0", "name": "Vinman", "avatar": false, "watching": true],
                "s1": ["id": "s1", "name": "Watcher", "avatar": false, "watching": true],
                // Pregame-only speaker (getSpectatorInfoFor watching:false): not listed.
                "s2": ["id": "s2", "name": "Lurker", "avatar": false, "watching": false],
            ]
            s.debugFeed("connected", nil)
            s.debugFeed("self", "s0")
            s.debugFeed("isSpectator", nil)
            s.debugFeed("setup", ["id": "diag-setup", "name": "Guns n Hookers", "gameType": "Mafia", "total": 12,
                                  "roles": [["Villager:": 6, "Cop:": 1, "Doctor:": 1, "Gunsmith:": 1, "Mafioso:": 2, "Serial Killer:": 1]]])
            s.debugFeed("options", ["spectating": true, "ranked": false, "competitive": false])
            let pregameLike = mode == "pregame" || mode == "join" || mode == "joinfail"
            if pregameLike {
                var eleven: [String: Any] = [:]
                for i in 0..<11 { eleven["p\(i)"] = players["p\(i)"] }
                s.debugFeed("players", eleven)
            }
            s.debugFeed("spectators", spectators)
            s.debugFeed("spectatorCount", 2)
            var echoMeeting = "pregame"
            if pregameLike {
                s.debugFeed("meeting", ["id": "pregame", "name": "Pregame", "speech": true, "voting": false,
                                        "amMember": true, "canTalk": true])
                s.debugFeed("timerInfo", ["name": "pregameWait", "delay": 600_000])
                s.debugFeed("message", line("p0", "hi all, one more and we start", "pregame", 0))
                s.debugFeed("message", line("s1", "watching this one, good luck everyone", "pregame", 5_000))
                s.debugFeed("message", line("p3", "gl hf", "pregame", 9_000))
                s.debugFeed("message", line("s2", "brb", "pregame", 12_000))
            } else {
                let ids = (0..<12).map { "p\($0)" }
                s.debugFeed("state", ["id": 2, "name": "Day", "dayCount": 2])
                s.debugFeed("meeting", ["id": "village", "name": "Village", "actionName": "Vote to Condemn",
                                        "speech": true, "voting": true, "amMember": false, "canTalk": false,
                                        "canVote": false, "targets": ids + ["*"], "votes": ["p1": "p5", "p2": "p5"]])
                s.debugFeed("meeting", ["id": "spec", "name": "Spectator Meeting", "speech": true, "voting": false,
                                        "amMember": true, "canTalk": true])
                echoMeeting = "spec"
                s.debugFeed("message", line("p1", "I think p5 is scum, the claim makes no sense", "village", 0))
                s.debugFeed("message", line("s1", "p5 is totally the cop lol", "spec", 4_000))
                s.debugFeed("message", line("p5", "I am the cop. p8 is mafia", "village", 8_000))
                s.debugFeed("message", line("s0", "this is going to be close", "spec", 12_000))
                s.debugFeed("message", line("p8", "no way, I'm a villager", "village", 16_000))
                s.debugFeed("quote", ["id": "sq1", "messageId": "sc3", "senderId": "s1", "toMeetingId": "spec",
                                      "fromMeetingId": "village", "fromState": 2, "time": t0 + 20_000])
                s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
                if mode == "postgame" {
                    s.debugFeed("state", ["id": -2, "name": "Postgame"])
                    s.debugFeed("finished", nil)
                }
            }
            s.debugSendHook = { [weak s] event, payload in
                guard let s else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    switch event {
                    case "speak":
                        seq += 1
                        let m = payload["meetingId"] as? String ?? echoMeeting
                        UMDiag.log("replay", "specchat speak -> \(m)")
                        s.debugFeed("message", ["id": "echo\(seq)", "senderId": "s0", "content": payload["content"] ?? "",
                                                "time": Date().timeIntervalSince1970 * 1000, "meetingId": m])
                    case "quote":
                        seq += 1
                        UMDiag.log("replay", "specchat quote -> \(payload["toMeetingId"] ?? "")")
                        var q = payload
                        q["id"] = "eq\(seq)"; q["senderId"] = "s0"; q["time"] = Date().timeIntervalSince1970 * 1000
                        s.debugFeed("quote", q)
                    case "takeSeat" where mode == "joinfail":
                        UMDiag.log("replay", "specchat takeSeat -> fail")
                        s.debugFeed("takeSeatFailed", "This game is full.")
                    case "takeSeat":
                        UMDiag.log("replay", "specchat takeSeat -> seated")
                        s.debugFeed("isSpectator", false)
                        s.debugFeed("self", "p11")
                        s.debugFeed("playerJoin", ["id": "p11", "name": "Vinman", "avatar": false, "playerListPosition": 11])
                        spectators["s0"] = nil
                        s.debugFeed("spectators", spectators)
                        s.debugFeed("spectatorCount", 1)
                        s.debugFeed("message", ["id": "seat-alert", "senderId": "server", "content": "Vinman has joined.",
                                                "time": Date().timeIntervalSince1970 * 1000, "meetingId": "pregame"])
                    default: break
                    }
                }
            }
            UMDiag.log("replay", "specchat \(mode)")
            return
        }
        if let i = args.firstIndex(of: "-UMDiagTopBar"), args.indices.contains(i + 1) {
            let mode = args[i + 1]
            let many = mode.hasPrefix("many")
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
            } else if many {
                // Pregame is already present as id -1; add Day/Night through Day 3, then Postgame.
                let play: [(Int, String, Int)] = [
                    (0, "Day", 1), (1, "Night", 1), (2, "Day", 2), (3, "Night", 2),
                    (4, "Day", 3), (5, "Night", 3)
                ]
                let count = args.contains("-UMDiagLong") ? 40 : 6
                for (id, name, day) in play {
                    s.debugFeed("state", ["id": id, "name": name, "dayCount": day])
                    for n in 0..<count { s.debugFeed("message", msg(n, phase: id)) }
                }
                s.debugFeed("state", ["id": -2, "name": "Postgame"])
                for n in 0..<4 { s.debugFeed("message", msg(n, phase: -2)) }
                s.debugFeed("timerInfo", ["name": "main", "delay": 287_000])
                switch mode {
                case "many-earliest": s.viewPhase(-1)         // Pregame — absolute earliest (first three)
                case "many-middle": s.viewPhase(2)            // Day 2 — has before and after
                case "many-post", "many-latest", "many": s.viewPhase(-2)
                default: s.viewPhase(-2)
                }
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
