// swiftc -parse-as-library Tests/KudosTests.swift Ultimafia/Features/Game/Kudos.swift
import Foundation

@main
struct KudosTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL:", what) }
    }
    static func equal<T: Equatable>(_ got: T, _ expected: T, _ what: String) {
        check(got == expected, "\(what) (got \(got), expected \(expected))")
    }

    static func sample(
        votes: [String: String] = [:],
        awarded: [String: [String]] = [:],
        canVote: Bool = true,
        finalized: Bool = false,
        testMode: Bool = false,
        includeSelf: Bool = true
    ) -> KudosState {
        var village = ["p0", "p1", "p2", "p3"]
        if !includeSelf { village = ["p1", "p2", "p3"] }
        return KudosState(
            rows: [
                KudosRow(key: "Village", label: "Town", candidates: village),
                KudosRow(key: "Mafia", label: "Mafia", candidates: ["p4", "p5"]),
                KudosRow(key: "Cult", label: "Cult", candidates: ["p6"]),
                KudosRow(key: "Independent", label: "Independent", candidates: ["p7"]),
            ],
            myVotes: votes,
            awarded: awarded,
            canVote: canVote,
            finalized: finalized,
            testMode: testMode
        )
    }

    static func main() {
        parsePayload()
        parseDefensive()
        dockVisibility()
        voteEligibility()
        votePayload()
        awardedIds()
        tileStates()
        dockPhases()
        groupLayout()
        collapseLayout()

        if failures == 0 {
            print("KudosTests passed: parse, dock visibility, eligibility, locking, self-ban, spectators, awarded, phases, collapse")
        } else {
            print("KudosTests: \(failures) failed")
            exit(1)
        }
    }

    static func parsePayload() {
        let raw: [String: Any] = [
            "rows": [
                ["key": "Village", "label": "Town", "candidates": ["p0", "p1"]],
                ["key": "Mafia", "label": "Mafia", "candidates": ["p2"]],
            ],
            "myVotes": ["Village": "p1", "Mafia": "*"],
            "awarded": ["Village": ["p1"], "Mafia": []],
            "canVote": true,
            "finalized": false,
            "testMode": false,
        ]
        guard let state = KudosState.parse(raw) else {
            check(false, "parse valid payload")
            return
        }
        equal(state.rows.count, 2, "two rows")
        equal(state.rows[0].key, "Village", "row key is Village, not Town")
        equal(state.rows[0].label, "Town", "row label is Town")
        equal(state.rows[0].candidates, ["p0", "p1"], "village candidates")
        equal(state.myVotes["Village"], "p1", "locked village vote")
        equal(state.myVotes["Mafia"], "*", "no-one vote is *")
        equal(state.awarded["Village"] ?? [], ["p1"], "awarded village")
        equal(state.awarded["Mafia"] ?? [], [], "unawarded mafia empty list")
        check(state.canVote && !state.finalized && !state.testMode, "flags")
    }

    static func parseDefensive() {
        check(KudosState.parse(nil) == nil, "nil is not a state")
        check(KudosState.parse("kudos") == nil, "string is not a state")
        guard let empty = KudosState.parse([String: Any]()) else {
            check(false, "empty object still parses")
            return
        }
        check(empty.rows.isEmpty && empty.myVotes.isEmpty && !empty.canVote && !empty.finalized, "empty defaults")

        // Rows missing a key are skipped; a missing label falls back to the key.
        let partial = KudosState.parse([
            "rows": [
                ["label": "Town", "candidates": ["p0"]],
                ["key": "Mafia", "candidates": ["p1"]],
            ],
            "canVote": "true",
            "finalized": 0,
            "testMode": NSNumber(value: true),
            "myVotes": ["Mafia": 12],
            "awarded": ["Mafia": "p1"],
        ] as [String: Any])
        guard let partial else { check(false, "partial parse"); return }
        equal(partial.rows.count, 1, "row without key skipped")
        equal(partial.rows[0].key, "Mafia", "kept mafia")
        equal(partial.rows[0].label, "Mafia", "label falls back to key")
        check(partial.canVote, "canVote string true")
        check(!partial.finalized, "finalized 0 is false")
        check(partial.testMode, "testMode NSNumber")
        equal(partial.myVotes["Mafia"], "12", "myVotes number coerced")
        equal(partial.awarded["Mafia"] ?? [], ["p1"], "awarded single string")
    }

    static func dockVisibility() {
        let open = sample()
        check(KudosPolicy.showsDock(state: open), "open voter sees the dock")
        check(!KudosPolicy.showsDock(state: nil), "no payload, no dock")
        check(!KudosPolicy.showsDock(state: sample(canVote: false)), "spectator / canVote false: no dock")
        check(!KudosPolicy.showsDock(state: sample(canVote: false, finalized: true)), "finalized: no dock")
        check(!KudosPolicy.showsDock(state: sample(canVote: true, finalized: true)), "finalized even if canVote stays true")
        var empty = sample()
        empty.rows = []
        check(!KudosPolicy.showsDock(state: empty), "empty rows: no dock")

        // Locked rows stay as compact summaries, so the dock remains until voting ends.
        let allVoted = sample(votes: [
            "Village": "p1", "Mafia": "*", "Cult": "p6", "Independent": "p7",
        ])
        check(KudosPolicy.showsDock(state: allVoted), "all rows voted: dock stays with summaries")
    }

    static func voteEligibility() {
        let open = sample()
        let selfId = "p0"
        check(KudosPolicy.rejection(state: open, selfId: selfId, row: "Village", target: "p1") == nil, "teammate is votable")
        check(KudosPolicy.rejection(state: open, selfId: selfId, row: "Mafia", target: "p4") == nil, "enemy row is votable")
        check(KudosPolicy.rejection(state: open, selfId: selfId, row: "Village", target: "*") == nil, "No one is votable in a row that includes you")
        equal(KudosPolicy.rejection(state: open, selfId: selfId, row: "Village", target: "p0"), .selfVote, "cannot kudo yourself")
        equal(KudosPolicy.rejection(state: open, selfId: selfId, row: "Town", target: "p1"), .unknownRow, "label Town is not a row key")
        equal(KudosPolicy.rejection(state: open, selfId: selfId, row: "Village", target: "p4"), .invalidTarget, "mafia player is not in the town row")
        equal(KudosPolicy.rejection(state: open, selfId: selfId, row: "Village", target: "user-p1"), .invalidTarget, "user ids are not targets")

        let locked = sample(votes: ["Village": "p1"])
        equal(KudosPolicy.rejection(state: locked, selfId: selfId, row: "Village", target: "p2"), .alreadyLocked, "no undo / second vote")
        // A locked vote on this row does not lock other rows.
        check(KudosPolicy.rejection(state: locked, selfId: selfId, row: "Mafia", target: "p4") == nil, "other rows still open")

        let spectator = sample(canVote: false)
        equal(KudosPolicy.rejection(state: spectator, selfId: nil, row: "Village", target: "p1"), .cannotVote, "spectator cannot vote")
        equal(KudosPolicy.rejection(state: spectator, selfId: "p0", row: "Village", target: "p1"), .cannotVote, "canVote false blocks a seated-looking id")

        let done = sample(votes: ["Village": "p1"], canVote: false, finalized: true)
        equal(KudosPolicy.rejection(state: done, selfId: selfId, row: "Mafia", target: "p4"), .votingOver, "finalized: voting is over")

        // finalized is checked first (server: "Kudos voting is over.") even if canVote is still true.
        let closing = sample(canVote: true, finalized: true)
        equal(KudosPolicy.rejection(state: closing, selfId: selfId, row: "Village", target: "p1"), .votingOver, "finalized wins over canVote")
    }

    static func votePayload() {
        equal(KudosPolicy.votePayload(row: "Village", target: "p1"), ["row": "Village", "target": "p1"], "player vote")
        equal(KudosPolicy.votePayload(row: "Village", target: "*"), ["row": "Village", "target": "*"], "no-one vote")
        check(KudosPolicy.votePayload(row: "Village", target: "p1")["row"] != "Town", "payload never sends Town")
    }

    static func awardedIds() {
        let state = sample(awarded: [
            "Village": ["p1"],
            "Mafia": [],
            "Cult": ["p6", "p6"],
            "Independent": ["p7"],
        ])
        equal(KudosPolicy.awardedIds(state), ["p1", "p6", "p7"], "row order, de-duplicated, skips empty")
        check(KudosPolicy.isAwarded(state, playerId: "p1"), "p1 awarded")
        check(!KudosPolicy.isAwarded(state, playerId: "p0"), "self not awarded")
        check(!KudosPolicy.isAwarded(state, playerId: "*"), "no-one is not a receiver")
        equal(KudosPolicy.awardedIdsInRow(state, key: "Village"), ["p1"], "row winners")
        equal(KudosPolicy.awardedIdsInRow(state, key: "Mafia"), [], "unawarded row")

        // A tie lists every winner; * is ignored.
        let tie = sample(awarded: ["Village": ["p1", "p2", "*"]])
        equal(KudosPolicy.awardedIds(tie), ["p1", "p2"], "tie, no-one stripped")

        // Award on a key not present in rows is still listed.
        let extra = sample(awarded: ["Village": ["p1"], "Ghost": ["p9"]])
        equal(KudosPolicy.awardedIds(extra), ["p1", "p9"], "orphan award included")
    }

    static func tileStates() {
        let open = sample()
        check(KudosPolicy.isTileClickable(state: open, rowKey: "Village", target: "p1", selfId: "p0"), "open teammate clickable")
        check(!KudosPolicy.isTileClickable(state: open, rowKey: "Village", target: "p0", selfId: "p0"), "self not clickable")
        check(!KudosPolicy.isTileDimmed(state: open, rowKey: "Village", target: "p1", selfId: "p0"), "open tiles not dimmed")
        check(KudosPolicy.isSelf("p0", selfId: "p0"), "self match")
        check(!KudosPolicy.isSelf("*", selfId: "p0"), "no-one is not self")
        check(!KudosPolicy.isSelf("p0", selfId: nil), "nil self")

        let locked = sample(votes: ["Village": "p1"])
        check(!KudosPolicy.isTileClickable(state: locked, rowKey: "Village", target: "p2", selfId: "p0"), "locked row not clickable")
        check(KudosPolicy.isTileDimmed(state: locked, rowKey: "Village", target: "p2", selfId: "p0"), "other tiles dim after lock")
        check(!KudosPolicy.isTileDimmed(state: locked, rowKey: "Village", target: "p1", selfId: "p0"), "selected tile not dimmed")
        check(!KudosPolicy.isTileDimmed(state: locked, rowKey: "Village", target: "p0", selfId: "p0"), "self uses self-opacity, not dim")

        let spectator = sample(awarded: ["Village": ["p1"]], canVote: false)
        check(!KudosPolicy.isTileClickable(state: spectator, rowKey: "Village", target: "p1", selfId: nil), "spectator tiles not clickable")
        check(KudosPolicy.isAwarded(spectator, playerId: "p1"), "spectator still sees awards")
    }

    static func dockPhases() {
        let already = ["Village": "p1", "Mafia": "*"]
        let seen = Set(already.keys)
        var votes = already
        votes["Cult"] = "p6"
        equal(KudosPolicy.newlyLockedRows(seen: seen, myVotes: votes), ["Cult"], "new lock is Cult")
        equal(KudosPolicy.newlyLockedRows(seen: seen, myVotes: already), [], "no new locks")
        equal(KudosPolicy.newlyLockedRows(seen: [], myVotes: already), ["Mafia", "Village"], "unsorted keys come back sorted")

        check(KudosPolicy.confirmMilliseconds == 900, "confirm 900ms")
        check(KudosPolicy.collapseMilliseconds == 350, "collapse 350ms")
    }

    static func groupLayout() {
        check(KudosPolicy.takesFullLine(candidateCount: 4), "4+ takes a full line")
        check(KudosPolicy.takesFullLine(candidateCount: 6), "6 takes a full line")
        check(!KudosPolicy.takesFullLine(candidateCount: 3), "3 can share a line")
        check(!KudosPolicy.takesFullLine(candidateCount: 1), "1 can share a line")
        // 2 tiles, mobile: 2*92 + 6 + 16 = 206
        equal(KudosPolicy.groupWidth(candidateCount: 2, compact: true), 206, "mobile pair width")
        // 2 tiles, desktop: 2*108 + 8 + 16 = 240
        equal(KudosPolicy.groupWidth(candidateCount: 2, compact: false), 240, "desktop pair width")
        equal(KudosPolicy.groupWidth(candidateCount: 0, compact: true), 16, "empty is just padding")
        equal(KudosPolicy.groupWidth(candidateCount: 1, compact: true), 108, "single mobile tile")
    }

    static func collapseLayout() {
        let state = sample()
        // Village 4 takes a full line; Mafia 2 / Cult 1 / Independent 1 can share.

        equal(
            KudosPolicy.visualLines(rows: state.rows, containerWidth: 800, onePerLine: true),
            [["Village"], ["Mafia"], ["Cult"], ["Independent"]],
            "compact is one alignment per line"
        )
        // Unknown width also falls back to one per line.
        equal(
            KudosPolicy.visualLines(rows: state.rows, containerWidth: 0, onePerLine: false),
            [["Village"], ["Mafia"], ["Cult"], ["Independent"]],
            "unknown width is one per line"
        )

        // Wide 800, desktop tiles:
        // Village takes a full line (4+).
        // Mafia 240 + Cult 124 + Independent 124 + 16 gap = 504, all three share.
        equal(
            KudosPolicy.visualLines(rows: state.rows, containerWidth: 800, onePerLine: false),
            [["Village"], ["Mafia", "Cult", "Independent"]],
            "wide packs small teams onto one shared line"
        )

        // Narrow 300, desktop: Mafia 240, Cult+Independent 124+8+124=256.
        // 240+8+124=372 > 300, so Mafia is alone and Cult shares with Independent.
        equal(
            KudosPolicy.visualLines(rows: state.rows, containerWidth: 300, onePerLine: false),
            [["Village"], ["Mafia"], ["Cult", "Independent"]],
            "narrow wide-layout wraps when a team no longer fits"
        )

        // 124+8+124=256; at 250 nothing shares.
        equal(
            KudosPolicy.visualLines(rows: state.rows, containerWidth: 250, onePerLine: false),
            [["Village"], ["Mafia"], ["Cult"], ["Independent"]],
            "each small team gets its own line when they don't fit"
        )

        // Exactly-fitting pair shares (256 == 256).
        equal(
            KudosPolicy.visualLines(rows: state.rows, containerWidth: 256, onePerLine: false),
            [["Village"], ["Mafia"], ["Cult", "Independent"]],
            "teams that fit exactly still share a line"
        )

        let compactLines = [["Village"], ["Mafia"], ["Cult"], ["Independent"]]
        let sharedLines = [["Village"], ["Mafia", "Cult", "Independent"]]

        check(
            !KudosPolicy.isCollapsed(key: "Village", myVotes: [:], lines: compactLines),
            "unvoted row is never collapsed"
        )

        // Compact: a vote collapses that row alone.
        check(
            KudosPolicy.isCollapsed(key: "Village", myVotes: ["Village": "p1"], lines: compactLines),
            "own-line vote collapses after confirm"
        )
        check(
            !KudosPolicy.isCollapsed(key: "Mafia", myVotes: ["Village": "p1"], lines: compactLines),
            "unvoted sibling stays expanded"
        )
        check(
            !KudosPolicy.isCollapsed(
                key: "Village",
                myVotes: ["Village": "p1"],
                lines: compactLines,
                confirming: ["Village"]
            ),
            "confirm holds the lineup open"
        )

        // Shared line: Mafia voted, Cult and Independent still outstanding — stay expanded.
        let mafiaVoted = ["Mafia": "*"]
        check(
            !KudosPolicy.isCollapsed(key: "Mafia", myVotes: mafiaVoted, lines: sharedLines),
            "shared line stays expanded while a neighbor is outstanding"
        )
        check(
            !KudosPolicy.isCollapsed(key: "Cult", myVotes: mafiaVoted, lines: sharedLines),
            "unvoted neighbor on a shared line stays expanded"
        )
        // Same votes on compact: Mafia is on its own line, so it does collapse.
        check(
            KudosPolicy.isCollapsed(key: "Mafia", myVotes: mafiaVoted, lines: compactLines),
            "compact voted row collapses alone"
        )

        // Village is on its own visual line, so it collapses even while the shared line below is open.
        let villageAndMafia = ["Village": "p1", "Mafia": "*"]
        check(
            KudosPolicy.isCollapsed(key: "Village", myVotes: villageAndMafia, lines: sharedLines),
            "full-line vote collapses independently of the shared line"
        )
        check(
            !KudosPolicy.isCollapsed(key: "Mafia", myVotes: villageAndMafia, lines: sharedLines),
            "shared line still open after a neighbor line collapses"
        )

        // Every row on the shared line voted: the whole line collapses.
        let allSmall = ["Mafia": "*", "Cult": "p6", "Independent": "p7"]
        for key in ["Mafia", "Cult", "Independent"] {
            check(
                KudosPolicy.isCollapsed(key: key, myVotes: allSmall, lines: sharedLines),
                "\(key) collapses once the shared line is fully voted"
            )
        }

        // The last vote is still confirming: the whole shared line waits, then collapses together.
        check(
            !KudosPolicy.isCollapsed(
                key: "Mafia",
                myVotes: allSmall,
                lines: sharedLines,
                confirming: ["Independent"]
            ),
            "shared line waits for the last confirm before collapsing"
        )
        check(
            !KudosPolicy.isCollapsed(
                key: "Independent",
                myVotes: allSmall,
                lines: sharedLines,
                confirming: ["Independent"]
            ),
            "confirming last vote stays expanded"
        )

        // A confirming vote on a different line does not block this line.
        check(
            KudosPolicy.isCollapsed(
                key: "Mafia",
                myVotes: allSmall,
                lines: sharedLines,
                confirming: ["Village"]
            ),
            "confirm on another line does not hold this line open"
        )

        // Missing from the pack: a voted row with no line still collapses after confirm.
        check(
            KudosPolicy.isCollapsed(key: "Mafia", myVotes: mafiaVoted, lines: []),
            "voted row with no line collapses"
        )
        check(
            !KudosPolicy.isCollapsed(
                key: "Mafia",
                myVotes: mafiaVoted,
                lines: [],
                confirming: ["Mafia"]
            ),
            "voted row with no line stays open while confirming"
        )

        equal(KudosPolicy.voteSummary(target: "*", playerName: "Alice"), "No one", "star is No one")
        equal(KudosPolicy.voteSummary(target: "p1", playerName: "Alice"), "Alice", "named pick")
        equal(KudosPolicy.voteSummary(target: "p1", playerName: nil), "Someone", "missing name")
        equal(KudosPolicy.voteSummary(target: "p1", playerName: "  "), "Someone", "blank name")
    }
}
