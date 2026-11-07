import Foundation

/// Modern Action Layout: which action tab is selected.
nonisolated enum ActSelectionPolicy {
    /// You > Settings > "Jump to Next Action". On (default, the existing behaviour): with no tab
    /// picked by hand, the selection follows the first action still waiting on your vote, so
    /// voting in one action moves you to the next. Off: whatever is selected stays selected.
    static let autoSwitchKey = "um.actAutoSwitch"

    /// - ids: actions in display order; needing: ids still waiting on your vote;
    ///   pinned: the tab stored for this phase (picked by hand, or latched when auto-switch is off).
    /// - Returns: the tab to show, and what to store for this phase (nil = nothing pinned).
    ///   A pinned tab that no longer exists falls back to the default.
    static func resolve(ids: [String], needing: Set<String>, pinned: String?,
                        autoSwitch: Bool) -> (selected: String?, pin: String?) {
        if let pinned, ids.contains(pinned) { return (pinned, pinned) }
        let fallback = ids.first(where: needing.contains) ?? ids.first
        return (fallback, autoSwitch ? nil : fallback)
    }
}

/// Gun "Shoot" meetings. A Fabricator's broken gun is a real "Gun" item on the server with the
/// same meeting, so both are detected and shown the same way; only the meeting id differs.
nonisolated enum GunMeetingPolicy {
    static let targetEmoji = "🔫"
    static let title = "Shoot"
    static let source = "Gun"

    /// Item Gun (first gun "Shoot Gun", later ones "<itemId> N"), or the base meeting name.
    static func isGun(name: String, actionName: String, itemName: String?) -> Bool {
        if let itemName, !itemName.isEmpty { return itemName == "Gun" }
        return name.hasPrefix("Shoot Gun")
    }

    /// Targets offered: guns never show "No one" (not shooting is just not choosing anyone);
    /// every other meeting keeps the server's list.
    static func visibleTargets(_ targets: [String], isGun: Bool) -> [String] {
        isGun ? targets.filter { $0 != "*" } : targets
    }
}
