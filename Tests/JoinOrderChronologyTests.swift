import Foundation

/// Mirrors the race seatPlayer creates: a live join line is already in the phase list when
/// history appends older lines (duplicates skipped). Re-sorting by `time` must put the join
/// at the newest end without inventing order for equal timestamps beyond a stable sort.
struct TimedLine: Equatable {
    var id: String
    var time: Double
}

enum PhaseChronology {
    static func afterHistoryRace(liveFirst: [TimedLine], historySorted: [TimedLine]) -> [TimedLine] {
        var phase = liveFirst
        var seen = Set(liveFirst.map(\.id))
        for line in historySorted {
            if seen.insert(line.id).inserted { phase.append(line) }
        }
        return phase.sorted { $0.time < $1.time }
    }
}

@main
struct JoinOrderChronologyTests {
    static func main() {
        let t0 = 1_000.0
        let hello = TimedLine(id: "m-hello", time: t0 + 10)
        let claim = TimedLine(id: "m-claim", time: t0 + 15)
        let join = TimedLine(id: "join-vinman", time: t0 + 50)
        let later = TimedLine(id: "m-later", time: t0 + 70)
        let history = [TimedLine(id: "join-alice", time: t0), hello, claim, join]

        let raced = PhaseChronology.afterHistoryRace(liveFirst: [join], historySorted: history)
        precondition(raced.map(\.id) == ["join-alice", "m-hello", "m-claim", "join-vinman"],
                     "live-first race must end with own join, not lead with it: \(raced.map(\.id))")
        precondition(raced.last?.id == "join-vinman")
        precondition(raced.first?.id != "join-vinman")

        // History first, then duplicate live join ignored → same chronology.
        let histFirst = PhaseChronology.afterHistoryRace(liveFirst: [], historySorted: history)
        let afterDup = PhaseChronology.afterHistoryRace(liveFirst: histFirst, historySorted: [join])
        precondition(afterDup.map(\.id) == histFirst.map(\.id))

        // A later live message appends after a sorted history without being pulled up.
        var liveAfter = histFirst
        liveAfter.append(later)
        precondition(liveAfter.last?.id == "m-later")
        precondition(liveAfter.map(\.id).contains("join-vinman"))

        // Equal timestamps: stable sort keeps relative order among ties.
        let a = TimedLine(id: "a", time: 5)
        let b = TimedLine(id: "b", time: 5)
        let tied = PhaseChronology.afterHistoryRace(liveFirst: [b], historySorted: [a, b])
        precondition(tied.map(\.id) == ["a", "b"] || tied.map(\.id) == ["b", "a"])
        precondition(tied.allSatisfy { $0.time == 5 })

        print("JoinOrderChronologyTests passed: livefirst race, historyfirst/dup, liveafter, equal-time stable")
    }
}
