import Foundation

/// Pure stand-in for browsing a prior phase while the live game advances / user replies.
/// Mirrors the GameSession contract fixed for historical quote/reply/send stay-put.
struct HistoricalBrowseState {
    var viewingPhaseId: Int
    var currentPhaseId: Int
    var followLive: Bool
    var replyTargetId: String?
    var replyHighlightId: String?
    var phaseScrollAnchors: [Int: String]
    var canTalk: Bool
    var isDraftOnly: Bool
    var sent: [(event: String, toMeeting: String, quotedId: String?)]

    var isViewingLive: Bool { viewingPhaseId == currentPhaseId }

    /// Composer visibility must not require viewing the live day.
    var showComposer: Bool {
        canTalk || isDraftOnly
    }

    mutating func viewPhase(_ id: Int) {
        viewingPhaseId = id
        followLive = id == currentPhaseId
    }

    mutating func viewLivePhase() {
        viewPhase(currentPhaseId)
    }

    /// Selecting a reply target (after the double-tap window) must keep day + anchor.
    mutating func queueReply(lineId: String, anchor: String?) {
        replyTargetId = lineId
        replyHighlightId = lineId
        if let anchor { phaseScrollAnchors[viewingPhaseId] = anchor }
        // Explicitly must not call viewLivePhase.
    }

    mutating func cancelReply() {
        replyTargetId = nil
        replyHighlightId = nil
    }

    /// Quote posts to the live meeting without navigating.
    mutating func quote(lineId: String, liveMeeting: String) {
        sent.append((event: "quote", toMeeting: liveMeeting, quotedId: lineId))
    }

    mutating func speakPlain(text: String, liveMeeting: String) -> Bool {
        guard canTalk, !isDraftOnly else { return false }
        sent.append((event: "speak", toMeeting: liveMeeting, quotedId: nil))
        _ = text
        return true
    }

    mutating func speakReply(text: String, liveMeeting: String) -> Bool {
        guard canTalk, !isDraftOnly, let q = replyTargetId else { return false }
        sent.append((event: "reply", toMeeting: liveMeeting, quotedId: q))
        cancelReply()
        _ = text
        return true
    }

    /// Live phase advance while browsing: only moves view if followLive.
    mutating func livePhaseAdvanced(to id: Int) {
        currentPhaseId = id
        if followLive { viewingPhaseId = id }
    }

    mutating func ownEchoArrived() {
        // Echo lands in the live transcript; browsing selection is untouched.
    }
}

@main
struct HistoricalReplyStayTests {
    static func main() {
        var s = HistoricalBrowseState(
            viewingPhaseId: 2, currentPhaseId: 2, followLive: true,
            replyTargetId: nil, replyHighlightId: nil,
            phaseScrollAnchors: [0: "d1-a", 2: "d2-a"],
            canTalk: true, isDraftOnly: false, sent: []
        )

        // Browse Day 1.
        s.viewPhase(0)
        precondition(s.viewingPhaseId == 0 && !s.isViewingLive && !s.followLive)
        precondition(s.showComposer, "composer while browsing")
        let anchor = s.phaseScrollAnchors[0]

        // Reply queue + cancel.
        s.queueReply(lineId: "d1-a", anchor: anchor)
        precondition(s.replyTargetId == "d1-a")
        precondition(s.viewingPhaseId == 0 && s.phaseScrollAnchors[0] == anchor)
        s.cancelReply()
        precondition(s.replyTargetId == nil && s.viewingPhaseId == 0)

        // Plain send while browsing.
        precondition(s.speakPlain(text: "hi", liveMeeting: "village"))
        precondition(s.viewingPhaseId == 0)
        precondition(s.sent.last?.event == "speak" && s.sent.last?.toMeeting == "village")

        // Reply send.
        s.queueReply(lineId: "d1-a", anchor: anchor)
        precondition(s.speakReply(text: "re: cop", liveMeeting: "village"))
        precondition(s.replyTargetId == nil)
        precondition(s.viewingPhaseId == 0)
        precondition(s.sent.last?.event == "reply" && s.sent.last?.quotedId == "d1-a")

        // Quote without jump.
        s.quote(lineId: "d1-a", liveMeeting: "village")
        precondition(s.viewingPhaseId == 0 && !s.followLive)
        precondition(s.sent.last?.event == "quote")

        // Own echo + live phase advance while browsing.
        s.ownEchoArrived()
        s.livePhaseAdvanced(to: 3)
        precondition(s.currentPhaseId == 3 && s.viewingPhaseId == 0 && !s.followLive)

        // Denied send (night / draft-only).
        s.canTalk = false
        s.isDraftOnly = true
        precondition(s.showComposer, "draft-only composer still visible on prior day")
        precondition(!s.speakPlain(text: "nope", liveMeeting: "village"))
        precondition(s.viewingPhaseId == 0)

        // Explicit navigation still works; live follow when on live day.
        s.canTalk = true
        s.isDraftOnly = false
        s.viewPhase(1)
        precondition(s.viewingPhaseId == 1 && !s.followLive)
        s.viewLivePhase()
        precondition(s.isViewingLive && s.followLive)
        s.livePhaseAdvanced(to: 4)
        precondition(s.viewingPhaseId == 4 && s.followLive, "normal live autoscroll / follow")

        // Unread must not be modeled as forced navigation.
        s.viewPhase(0)
        let before = s.viewingPhaseId
        // "new messages on live" — selection unchanged unless user navigates.
        s.ownEchoArrived()
        precondition(s.viewingPhaseId == before)

        print("HistoricalReplyStayTests passed: reply/cancel/plain/reply-send/quote/echo/phase-advance/denied/live-follow/unread-no-force")
    }
}
