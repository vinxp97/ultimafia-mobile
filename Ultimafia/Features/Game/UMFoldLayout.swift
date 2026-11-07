import CoreGraphics

/// Geometry-only rules for the iPhone Duo layouts (no private hinge geometry):
/// - Half-folded portrait ("DS" posture): the system keeps the app's safe area above the hinge
///   while the keyboard sits on the lower panel, leaving an empty band between the app's bottom
///   edge and the top of the keyboard. When that band can hold the panel tabs, they move there.
/// - Horizontal wide header on a phone: floating Liquid Glass pieces instead of an opaque bar.
enum UMFoldLayout {
    /// Global y of the top of the panel tab row in the band above the keyboard, or nil to keep it
    /// in its normal place. `contentBottom` is the app's safe-area bottom (global), `keyboardTop`
    /// the keyboard's top edge (global, nil when hidden), `tabHeight` the row's height, `foldY` the
    /// screen's vertical midline (global) where the two panels meet.
    static func tabBarTopInBand(contentBottom: CGFloat, keyboardTop: CGFloat?, tabHeight: CGFloat,
                                portrait: Bool, hingePartiallyOpen: Bool?, foldY: CGFloat? = nil, margin: CGFloat = 4) -> CGFloat? {
        guard portrait, let kb = keyboardTop, tabHeight > 0 else { return nil }
        // A known flat or closed hinge never uses the band; unknown (no hinge API) uses geometry.
        if hingePartiallyOpen == false { return nil }
        let band = kb - contentBottom
        if band >= tabHeight + margin * 2 {
            // The app's safe area already stops above the band: tabs sit directly above the keyboard.
            return kb - margin - tabHeight
        }
        // The keyboard frame itself covers the band (app content ends at its top): with the hinge
        // reported partially open and the keyboard reaching well above the fold, the keys sit on
        // the lower panel, so the tabs go just above the fold line inside the empty band.
        guard hingePartiallyOpen == true, let fold = foldY, kb <= fold - tabHeight - margin * 2 else { return nil }
        return fold - margin - tabHeight
    }

    /// Half-folded Duo (hinge reported partially open) in portrait: the system gives the keyboard
    /// the lower panel and keeps the app's window above it, so app views can't be drawn there. The
    /// tabs go on the keyboard itself, as the composer's keyboard accessory. `screenPortrait` is the
    /// screen's shape: the app's own window can be landscape-shaped once shrunk to the upper panel.
    static func tabsOnKeyboard(hingePartiallyOpen: Bool?, screenPortrait: Bool, threeColumns: Bool) -> Bool {
        hingePartiallyOpen == true && screenPortrait && !threeColumns
    }

    /// Phone in a wide (one-row header) window: glass header floating over the panes.
    static func usesGlassWideHeader(wideHeader: Bool, isPhone: Bool) -> Bool { wideHeader && isPhone }
}
