import SwiftUI
import CoreText
import Observation

/// Registers the cosmetic name fonts (web PR #2928 `settings.nameFont`). Bundled in Fonts/; falls back to ultimafia.com.
/// The site serves them under content-hashed paths, so we read the @font-face rules from the
/// live stylesheet, download each face once, cache it on disk, and register it process-wide.
@Observable
final class UMNameFonts {
    static let shared = UMNameFonts()

    /// nameFont key -> CSS font-family declared by the site.
    nonisolated private static let webFamilies: [String: String] = [
        "slab": "RobotoSlab", "mono": "RobotoMono", "poppins": "Poppins",
        "bettynoir": "BettyNoir", "autophobia": "Autophobia", "spooky": "Spooky", "nabla": "Nabla",
    ]
    /// Fonts that ship with iOS, matching the web stacks directly.
    private static let systemFamilies: [String: String] = [
        "georgia": "Georgia", "trebuchet": "TrebuchetMS", "verdana": "Verdana",
    ]

    /// nameFont key -> registered PostScript name.
    private(set) var registered: [String: String] = [:]
    @ObservationIgnored private var started = false

    func loadIfNeeded() {
        guard !started else { return }
        started = true
        Task { await load() }
    }

    func postScriptName(for key: String) -> String? {
        let k = key.lowercased()
        return registered[k] ?? Self.systemFamilies[k]
    }

    /// File reads, temp-file writes and CoreText registration run off the main actor (they used to
    /// block launch: Xcode's "Performing I/O on the main thread can cause slow launches").
    /// Only the `registered` map is updated here, on the main actor.
    private func load() async {
        let families = Self.webFamilies
        // Bundled copies (Fonts/<CSS family>.ttf) are the primary source.
        let bundled = await Task.detached(priority: .utility) { () -> [String: String] in
            var out: [String: String] = [:]
            for (key, family) in families {
                if let url = Bundle.main.url(forResource: family, withExtension: "ttf")
                    ?? Bundle.main.url(forResource: family, withExtension: "ttf", subdirectory: "Fonts"),
                   let data = try? Data(contentsOf: url), let ps = Self.register(data) { out[key] = ps }
            }
            return out
        }.value
        registered.merge(bundled) { _, new in new }
        guard registered.count < families.count else { return }
        // Fallback for any bundled face that is missing: disk cache, then the live site.
        // Cached files first so names render correctly offline / before the network returns.
        let missing = families.filter { registered[$0.key] == nil }
        let cached = await Task.detached(priority: .utility) { () -> [String: String] in
            var byFamily: [String: URL] = [:]
            if let files = try? FileManager.default.contentsOfDirectory(at: UMCacheLocation.nameFonts, includingPropertiesForKeys: nil) {
                for f in files { byFamily[f.deletingPathExtension().lastPathComponent] = f }
            }
            var out: [String: String] = [:]
            for (key, family) in missing {
                if let file = byFamily[family], let data = try? Data(contentsOf: file), let ps = Self.register(data) { out[key] = ps }
            }
            return out
        }.value
        registered.merge(cached) { _, new in new }
        guard registered.count < families.count, let urls = try? await fetchFontFaceURLs() else { return }
        for (key, family) in families where registered[key] == nil {
            guard let url = urls[family],
                  let (data, resp) = try? await URLSession.shared.data(for: UMAccess.request(url)),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let ps = await Task.detached(priority: .utility) { () -> String? in
                guard let ps = Self.register(data) else { return nil }
                try? data.write(to: UMCacheLocation.nameFonts.appendingPathComponent(family + ".ttf"), options: .atomic)
                return ps
            }.value
            if let ps { registered[key] = ps }
        }
    }

    /// Registers one face process-wide; returns its PostScript name. Thread-safe (CoreText).
    nonisolated private static func register(_ data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider),
              let ps = cgFont.postScriptName as String? else { return nil }
        // Register from a file URL (CTFontManagerRegisterGraphicsFont is deprecated in iOS 18).
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("umfont-\(ps)").appendingPathExtension("ttf")
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        if !CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil) {
            // Already registered (e.g. second load) is fine; anything else is a bad file.
            let font = CTFontCreateWithName(ps as CFString, 12, nil)
            guard CTFontCopyPostScriptName(font) as String == ps else { return nil }
        }
        return ps
    }

    /// Reads the site's stylesheets and returns CSS family -> absolute font URL.
    private func fetchFontFaceURLs() async throws -> [String: URL] {
        let base = UMConfig.siteBase
        let (htmlData, _) = try await URLSession.shared.data(for: UMAccess.request(base))
        let html = String(decoding: htmlData, as: UTF8.self)
        let hrefs = matches(#"href="([^"]+\.css)""#, in: html)
        var out: [String: URL] = [:]
        for href in hrefs {
            guard let cssURL = URL(string: href, relativeTo: base),
                  let (cssData, _) = try? await URLSession.shared.data(for: UMAccess.request(cssURL)) else { continue }
            let css = String(decoding: cssData, as: UTF8.self)
            for block in matches(#"@font-face\s*\{([^}]*)\}"#, in: css) {
                guard let fam = matches(#"font-family:\s*["']?([^;"']+)"#, in: block).first,
                      let src = matches(#"url\(["']?([^)"']+)"#, in: block).first,
                      let url = URL(string: src, relativeTo: cssURL)?.absoluteURL else { continue }
                out[fam.trimmingCharacters(in: .whitespaces)] = url
            }
        }
        return out
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}
