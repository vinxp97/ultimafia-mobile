import Foundation

/// Pure windowing for the wide/Duo phase strip (mirrors PhaseStripWindow in PhaseChrome.swift).
enum PhaseStripWindowRef {
    static func start(selectedIndex: Int, count: Int, visible: Int = 3) -> Int {
        let v = max(1, visible)
        guard count > v else { return 0 }
        let i = min(max(0, selectedIndex), count - 1)
        return min(max(0, i - (v / 2)), count - v)
    }
}

@main
struct PhaseStripWindowTests {
    static func main() {
        func window(_ i: Int, _ n: Int, _ v: Int = 3) -> [Int] {
            let s = PhaseStripWindowRef.start(selectedIndex: i, count: n, visible: v)
            return Array(s..<min(n, s + v))
        }

        // Boundaries: 1 / 2 / 3 phases show everything.
        precondition(window(0, 1) == [0])
        precondition(window(0, 2) == [0, 1])
        precondition(window(1, 2) == [0, 1])
        precondition(window(0, 3) == [0, 1, 2])
        precondition(window(2, 3) == [0, 1, 2])

        // 7 phases (Day1..Night3 + Postgame style): earliest / middle / latest.
        precondition(window(0, 7) == [0, 1, 2], "earliest → first three")
        precondition(window(1, 7) == [0, 1, 2], "near start still first three")
        precondition(window(2, 7) == [1, 2, 3], "intermediate centred")
        precondition(window(3, 7) == [2, 3, 4], "intermediate centred")
        precondition(window(5, 7) == [4, 5, 6], "near end")
        precondition(window(6, 7) == [4, 5, 6], "latest → last three")

        // Stepping selection never skips an index out of the moving window.
        var seen = Set<Int>()
        for i in 0..<7 {
            let w = window(i, 7)
            precondition(w.contains(i), "selected \(i) must stay visible in \(w)")
            seen.formUnion(w)
        }
        precondition(seen == Set(0..<7), "arrows across selections must cover every phase chip eventually")

        print("PhaseStripWindowTests passed: 1/2/3 bounds, earliest/middle/latest windows, full reachability")
    }
}
