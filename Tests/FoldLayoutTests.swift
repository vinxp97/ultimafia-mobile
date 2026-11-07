import CoreGraphics
import Foundation

/// swiftc -parse-as-library Ultimafia/Features/Game/UMFoldLayout.swift Tests/FoldLayoutTests.swift
@main
struct FoldLayoutTests {
    static func main() {
        let P = UMFoldLayout.self
        // Normal phone: keyboard right under content -> unchanged.
        precondition(P.tabBarTopInBand(contentBottom: 500, keyboardTop: 500, tabHeight: 50, portrait: true, hingePartiallyOpen: nil) == nil)
        // No keyboard -> unchanged.
        precondition(P.tabBarTopInBand(contentBottom: 400, keyboardTop: nil, tabHeight: 50, portrait: true, hingePartiallyOpen: true) == nil)
        // Landscape -> unchanged.
        precondition(P.tabBarTopInBand(contentBottom: 300, keyboardTop: 420, tabHeight: 50, portrait: false, hingePartiallyOpen: true) == nil)
        // Band between safe-area bottom and keyboard top (DS posture): tabs directly above keys.
        precondition(P.tabBarTopInBand(contentBottom: 400, keyboardTop: 525, tabHeight: 50, portrait: true, hingePartiallyOpen: nil) == 471)
        // Flat/closed hinge reported: never moves.
        precondition(P.tabBarTopInBand(contentBottom: 400, keyboardTop: 525, tabHeight: 50, portrait: true, hingePartiallyOpen: false) == nil)
        // Band too small for the row.
        precondition(P.tabBarTopInBand(contentBottom: 500, keyboardTop: 540, tabHeight: 50, portrait: true, hingePartiallyOpen: nil) == nil)
        // Keyboard frame covers the band, hinge half open: tabs just above the fold line.
        precondition(P.tabBarTopInBand(contentBottom: 400, keyboardTop: 400, tabHeight: 50, portrait: true, hingePartiallyOpen: true, foldY: 512) == 458)
        // Same geometry but no hinge signal: unchanged (no guessing).
        precondition(P.tabBarTopInBand(contentBottom: 400, keyboardTop: 400, tabHeight: 50, portrait: true, hingePartiallyOpen: nil, foldY: 512) == nil)
        // Keyboard below fold (ordinary keyboard on a flat-ish phone): unchanged.
        precondition(P.tabBarTopInBand(contentBottom: 600, keyboardTop: 600, tabHeight: 50, portrait: true, hingePartiallyOpen: true, foldY: 512) == nil)
        // Glass wide header only for phones in wide header mode.
        precondition(P.usesGlassWideHeader(wideHeader: true, isPhone: true))
        precondition(!P.usesGlassWideHeader(wideHeader: true, isPhone: false))
        precondition(!P.usesGlassWideHeader(wideHeader: false, isPhone: true))
        print("FoldLayoutTests passed (production UMFoldLayout)")
    }
}
