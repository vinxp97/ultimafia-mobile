import Foundation

nonisolated enum UMFeatureFlags {
    /// APNs remote push (game start, DMs, pings, friends/pokes). On: the app registers for remote
    /// notifications when this device's master push switch is on, and POSTs/DELETEs
    /// /api/user/apnsToken. Until Pranay's backend ships those routes answer 404, which the client
    /// treats as a quiet no-op. Needs `aps-environment` in Ultimafia/Ultimafia-iOS.entitlements.
    static let pushNotificationsEnabled = true
}
