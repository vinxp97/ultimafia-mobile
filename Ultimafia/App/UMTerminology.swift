import Foundation
import Observation

/// Game terminology (web `react_main/src/constants/slangList.js`, shown on the site as dotted
/// underlines with a definition popover in chat). The site has no API for it, so the list is
/// fetched from the public repo source, cached in UMCache/terminology.json (survives launches,
/// removed by Clear Cached Media) and falls back to the bundled UMTerminology.json copy.
@Observable
final class UMTerminology {
    static let shared = UMTerminology()

    struct Term: Hashable { let key: String; let definition: String }

    /// Lowercased key -> term.
    private(set) var terms: [String: Term] = [:]
    /// Bumps when the list changes so views re-tokenize.
    private(set) var version = 0
    @ObservationIgnored private var keysByLength: [String] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var refreshing = false

    static let sourceURL = URL(string: "https://raw.githubusercontent.com/UltiMafia/Ultimafia/master/react_main/src/constants/slangList.js")!
    nonisolated static var cacheFile: URL { UMCacheLocation.root.appendingPathComponent("terminology.json") }
    /// Web's conjugation handling (lib/slangMatch.js) for single words.
    private static let suffixes = ["ing", "ed", "es", "s"]

    /// Cached copy (else bundled) right away; network refresh when there's no cached copy yet.
    /// Disk reads and JSON decoding run off the main actor (they used to run during launch).
    func load() async {
        let first = !loaded
        loaded = true
        let (stored, hasCache) = await Task.detached(priority: .utility) { () -> ([String: String]?, Bool) in
            let hasCache = FileManager.default.fileExists(atPath: Self.cacheFile.path)
            guard first else { return (nil, hasCache) }
            if let data = try? Data(contentsOf: Self.cacheFile), let dict = Self.decode(data) { return (dict, hasCache) }
            if let url = Bundle.main.url(forResource: "UMTerminology", withExtension: "json"),
               let data = try? Data(contentsOf: url), let dict = Self.decode(data) { return (dict, hasCache) }
            return (nil, hasCache)
        }.value
        if let stored { apply(stored) }
        if !hasCache { await refresh() }
    }

    /// Called after Clear Cached Media: drop the file and download again.
    func cacheCleared() {
        try? FileManager.default.removeItem(at: Self.cacheFile)
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let (data, response) = try? await URLSession.shared.data(for: UMAccess.request(Self.sourceURL)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let js = String(data: data, encoding: .utf8) else { return }
        let dict = Self.parse(js)
        guard dict.count >= 50 else { return }  // parse failed or format changed: keep what we have
        await Task.detached(priority: .utility) {
            if let json = try? JSONSerialization.data(withJSONObject: dict.mapValues { ["definition": $0] }) {
                try? json.write(to: Self.cacheFile, options: .atomic)
            }
        }.value
        apply(dict)
    }

    private func apply(_ dict: [String: String]) {
        var next: [String: Term] = [:]
        for (k, v) in dict where !k.isEmpty && !v.isEmpty { next[k.lowercased()] = Term(key: k, definition: v) }
        terms = next
        keysByLength = next.keys.sorted { $0.count > $1.count }
        version &+= 1
    }

    nonisolated private static func decode(_ data: Data) -> [String: String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let d = (v as? [String: Any])?["definition"] as? String { out[k] = d }
        }
        return out.isEmpty ? nil : out
    }

    /// Pulls `key: { definition: "..." }` entries out of slangList.js (comment lines skipped).
    static func parse(_ js: String) -> [String: String] {
        let body = js.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let pattern = #"(?:"([^"\n]+)"|'([^'\n]+)'|([A-Za-z0-9_]+))\s*:\s*\{\s*definition\s*:\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = body as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            var key = ""
            for g in 1...3 where m.range(at: g).location != NSNotFound { key = ns.substring(with: m.range(at: g)) }
            let defRange = m.range(at: 4).location != NSNotFound ? m.range(at: 4) : m.range(at: 5)
            guard defRange.location != NSNotFound else { continue }
            let def = ns.substring(with: defRange)
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\n", with: "\n")
            if !key.isEmpty { out[key] = def }
        }
        return out
    }

    func term(_ key: String) -> Term? { terms[key.lowercased()] }

    /// Whole-word, case-insensitive matches, longest term first, no overlaps. Single-word terms
    /// also match web's conjugations (bussing -> bus). Words in `excluded` (e.g. player names) and
    /// links are skipped.
    func matches(in s: String, excluded: Set<String> = []) -> [(range: Range<String.Index>, key: String)] {
        guard !terms.isEmpty, !s.isEmpty else { return [] }
        let lower = s.lowercased()
        guard lower.count == s.count else { return [] }  // keep indices aligned
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var taken: [Range<String.Index>] = []
        var out: [(Range<String.Index>, String)] = []
        func free(_ r: Range<String.Index>) -> Bool { !taken.contains { $0.overlaps(r) } }
        func bounded(_ r: Range<String.Index>) -> Bool {
            let before = r.lowerBound == s.startIndex || !isWordChar(s[s.index(before: r.lowerBound)])
            let after = r.upperBound == s.endIndex || !isWordChar(s[r.upperBound])
            return before && after
        }
        // Mask link tokens.
        var cursor = s.startIndex
        for word in s.split(separator: " ") {
            if word.hasPrefix("http://") || word.hasPrefix("https://") || word.hasPrefix("www.") { taken.append(word.startIndex..<word.endIndex) }
            if excluded.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters)) { taken.append(word.startIndex..<word.endIndex) }
            cursor = word.endIndex
        }
        _ = cursor
        func idx(_ lowerIndex: String.Index) -> String.Index {
            s.index(s.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: lowerIndex))
        }
        for key in keysByLength {
            var search = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: key, range: search) {
                let sr = idx(r.lowerBound)..<idx(r.upperBound)
                if bounded(sr), free(sr) { taken.append(sr); out.append((sr, key)) }
                search = r.upperBound..<lower.endIndex
            }
        }
        // Conjugated single words.
        var i = s.startIndex
        while i < s.endIndex {
            guard isWordChar(s[i]) else { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex, isWordChar(s[j]) { j = s.index(after: j) }
            let r = i..<j
            if free(r) {
                let w = s[r].lowercased()
                for suf in Self.suffixes where w.count > suf.count && w.hasSuffix(suf) {
                    let base = String(w.dropLast(suf.count))
                    if base.count >= 2, terms[base] != nil, !base.contains(" ") {
                        taken.append(r); out.append((r, base)); break
                    }
                }
            }
            i = j
        }
        return out.sorted { $0.0.lowerBound < $1.0.lowerBound }.map { (range: $0.0, key: $0.1) }
    }
}
