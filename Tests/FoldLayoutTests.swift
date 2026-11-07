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
        // Device log, iPhone Duo half open (Nov 6 20:18 ET): screen 951 pt tall, keyboard frame
        // top 455.5 / h 495.5, hinge partiallyOpen. The keyboard frame starts above the fold
        // (475.5) and the app stops at it, so no app-window band exists: this returned nil on
        // device (build 4049bb4) and the tabs never moved.
        precondition(P.tabBarTopInBand(contentBottom: 455.5, keyboardTop: 455.5, tabHeight: 47.7, portrait: true, hingePartiallyOpen: true, foldY: 475.5) == nil)
        // Production gate (device log Nov 6 21:26 ET, f58cc0d): inner screen 669x951, split keyboard
        // (top 455.5, h 495.5) with hinge status 3 (fully open, angle 3.1 rad) — the old hinge gate
        // was false there, so the accessory was removed. The screen is the gate now.
        precondition(P.tabsOnKeyboard(screenSize: CGSize(width: 669, height: 951), isPhone: true, threeColumns: false))
        // Outer screen (466x678), landscape inner, iPad/Mac, three columns: never.
        precondition(!P.tabsOnKeyboard(screenSize: CGSize(width: 466, height: 678), isPhone: true, threeColumns: false))
        precondition(!P.tabsOnKeyboard(screenSize: CGSize(width: 951, height: 669), isPhone: true, threeColumns: false))
        precondition(!P.tabsOnKeyboard(screenSize: CGSize(width: 834, height: 1194), isPhone: false, threeColumns: false))
        precondition(!P.tabsOnKeyboard(screenSize: CGSize(width: 669, height: 951), isPhone: true, threeColumns: true))
        // Glass wide header only for phones in wide header mode.
        precondition(P.usesGlassWideHeader(wideHeader: true, isPhone: true))
        precondition(!P.usesGlassWideHeader(wideHeader: true, isPhone: false))
        precondition(!P.usesGlassWideHeader(wideHeader: false, isPhone: true))
        print("FoldLayoutTests passed (production UMFoldLayout)")
    }
}
