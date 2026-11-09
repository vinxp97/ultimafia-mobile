import Foundation

/// Mirrors UMGameLayout.usesGlassWideHeader / usesWideHeader for offline checks.
/// swiftc -parse-as-library Tests/GlassWideHeaderTests.swift
enum UMGameLayoutProbe {
    static func usesWideHeader(_ width: CGFloat, regular: Bool) -> Bool {
        regular && width >= 820
    }
    static func usesGlassWideHeader(_ wideHeader: Bool) -> Bool { wideHeader }
}

@main
struct GlassWideHeaderTests {
    static func main() {
        let P = UMGameLayoutProbe.self
        // Closed / compact iPhone: no wide header, no glass-wide path.
        precondition(!P.usesWideHeader(390, regular: false))
        precondition(!P.usesGlassWideHeader(false))
        // Duo inner / iPad regular width: wide + glass.
        precondition(P.usesWideHeader(1000, regular: true))
        precondition(P.usesGlassWideHeader(true))
        // Narrow regular window: still compact header.
        precondition(!P.usesWideHeader(700, regular: true))
        print("GlassWideHeaderTests passed")
    }
}
