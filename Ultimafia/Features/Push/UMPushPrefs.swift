import Foundation
import Observation

/// This device's push settings (You tab). Per device, kept in iCloud key-value storage under the
/// Keychain install id so a reinstall on the same device restores them; UserDefaults when iCloud
/// is off. Every change mirrors the legacy UserDefaults keys the rest of the app reads
/// (`UMNotifyMaster.isOn`, `UMDMNotify.enabled`) and re-syncs the APNs registration.
@MainActor @Observable
final class UMPushPrefs {
    static let shared = UMPushPrefs()

    private(set) var settings: UMPushSettings
    /// True when this device had saved settings (local or restored from iCloud) at launch.
    @ObservationIgnored private(set) var hadSaved: Bool
    @ObservationIgnored private let store: UMPushSettingsStore

    init(store: UMPushSettingsStore? = nil) {
        let s = store ?? UMPushPrefs.makeStore()
        self.store = s
        if let saved = s.load() {
            settings = saved
            hadSaved = true
        } else if UserDefaults.standard.bool(forKey: UMNotifyMaster.key) {
            // Upgrade from the single master switch: keep it on, with every type on.
            settings = .allOn
            hadSaved = false
        } else {
            settings = .allOff
            hadSaved = false
        }
        mirror()
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in UMPushPrefs.shared.reloadFromCloud() }
        }
    }

    private static func makeStore() -> UMPushSettingsStore {
        let cloudOK = FileManager.default.ubiquityIdentityToken != nil
        if cloudOK { NSUbiquitousKeyValueStore.default.synchronize() }
        return UMPushSettingsStore(deviceId: DeviceIdentity.installId,
                                   cloud: cloudOK ? UMUbiquitousKeyValue() : nil,
                                   local: UMDefaultsKeyValue())
    }

    var master: Bool { settings.master }
    func isOn(_ t: UMPushType) -> Bool { settings.isOn(t) }

    /// Master switch. On turns every type on; off hides the rows and removes this device's token.
    func setMaster(_ on: Bool) {
        settings.setMaster(on)
        commit()
    }

    func set(_ t: UMPushType, _ on: Bool) {
        settings.set(t, on)
        commit()
    }

    /// First-launch permission answer: restore this device's saved settings if iCloud had them,
    /// otherwise everything on when allowed, off when not.
    func applyPermissionResult(_ granted: Bool) {
        if !granted { settings.master = false }
        else if !(hadSaved && store.load()?.master == true) { settings.setMaster(true) }
        commit()
    }

    /// System permission revoked in iOS Settings: master off, types remembered.
    func permissionRevoked() {
        guard settings.master else { return }
        settings.master = false
        commit()
    }

    private func reloadFromCloud() {
        guard let s = store.load(), s != settings else { return }
        settings = s
        mirror()
        UMPush.sync()
    }

    private func commit() {
        store.save(settings)
        hadSaved = true
        mirror()
        UMPush.sync()
    }

    private func mirror() {
        UserDefaults.standard.set(settings.master, forKey: UMNotifyMaster.key)
        UserDefaults.standard.set(settings.isOn(.dms), forKey: UMDMNotify.enabledKey)
    }
}
