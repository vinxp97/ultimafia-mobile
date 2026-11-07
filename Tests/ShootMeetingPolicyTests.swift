// swiftc -parse-as-library Tests/ShootMeetingPolicyTests.swift Ultimafia/Features/Game/ActMeetingPolicy.swift
import Foundation

@main struct ShootMeetingPolicyTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

    static func main() {
        let ids = ["village", "gun"]
        // Sheriff Day: before voting, Village needs a vote in both modes.
        var r = ActSelectionPolicy.resolve(ids: ids, needing: ["village", "gun"], pinned: nil, autoSwitch: true)
        check(r.selected == "village" && r.pin == nil, "auto: starts on first action needing a vote")
        // After the Village vote: auto jumps to the gun (existing behaviour) ...
        r = ActSelectionPolicy.resolve(ids: ids, needing: ["gun"], pinned: nil, autoSwitch: true)
        check(r.selected == "gun", "auto: moves to the gun after voting")
        // ... auto off: the latched Village tab stays.
        r = ActSelectionPolicy.resolve(ids: ids, needing: ["village", "gun"], pinned: nil, autoSwitch: false)
        check(r.selected == "village" && r.pin == "village", "off: latches the shown tab")
        r = ActSelectionPolicy.resolve(ids: ids, needing: ["gun"], pinned: r.pin, autoSwitch: false)
        check(r.selected == "village", "off: stays on Village after voting")
        // Manual pick wins in both modes.
        for auto in [true, false] {
            r = ActSelectionPolicy.resolve(ids: ids, needing: ["village"], pinned: "gun", autoSwitch: auto)
            check(r.selected == "gun" && r.pin == "gun", "manual pick sticks (auto=\(auto))")
        }
        // Pinned meeting disappears (gun used/dropped): safe fallback.
        r = ActSelectionPolicy.resolve(ids: ["village"], needing: [], pinned: "gun", autoSwitch: false)
        check(r.selected == "village" && r.pin == "village", "off: vanished pin falls back and re-latches")
        r = ActSelectionPolicy.resolve(ids: ["village"], needing: [], pinned: "gun", autoSwitch: true)
        check(r.selected == "village" && r.pin == nil, "auto: vanished pin falls back, unpinned")
        r = ActSelectionPolicy.resolve(ids: [], needing: [], pinned: "gun", autoSwitch: false)
        check(r.selected == nil && r.pin == nil, "no meetings: nothing selected")

        // Gun detection: real and Fabricator's broken gun share the server shape; later guns get "<itemId> N".
        let real = GunMeetingPolicy.isGun(name: "Shoot Gun", actionName: "Shoot", itemName: "Gun")
        let fab = GunMeetingPolicy.isGun(name: "Shoot Gun", actionName: "Shoot", itemName: "Gun")
        let second = GunMeetingPolicy.isGun(name: "itm_8f2 1", actionName: "Shoot", itemName: "Gun")
        check(real && fab && second, "real, broken and renamed gun meetings are guns")
        check(!GunMeetingPolicy.isGun(name: "Village", actionName: "Vote to Condemn", itemName: nil), "village is not a gun")
        check(!GunMeetingPolicy.isGun(name: "Shoot Rifle", actionName: "Shoot", itemName: "Rifle"), "rifle is not the gun")
        check(!GunMeetingPolicy.isGun(name: "Mafia", actionName: "Mafia Kill", itemName: nil), "mafia kill untouched")

        // No one: hidden only for guns; ids kept as-is.
        let t = ["p0", "p1", "*"]
        check(GunMeetingPolicy.visibleTargets(t, isGun: true) == ["p0", "p1"], "gun hides No one")
        check(GunMeetingPolicy.visibleTargets(t, isGun: false) == t, "village keeps No one")
        check(GunMeetingPolicy.visibleTargets(["p0"], isGun: false) == ["p0"], "must-condemn list unchanged")
        // Same visible metadata for both guns.
        check(GunMeetingPolicy.title == "Shoot" && GunMeetingPolicy.source == "Gun" && GunMeetingPolicy.targetEmoji == "🔫", "gun labels")

        if failures == 0 { print("ShootMeetingPolicyTests passed: auto/off/manual/vanished selection, gun detection, No one filtering, labels") }
        else { print("ShootMeetingPolicyTests: \(failures) failed"); exit(1) }
    }
}
