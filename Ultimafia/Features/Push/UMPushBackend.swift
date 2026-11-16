import Foundation
import UserNotifications

/// Push + App Attest server calls, behind a protocol so the app runs (and tests run) before the
/// backend is deployed. Shapes: docs/ios-push-appattest.md (Gitea PR #92).
protocol UMPushBackend: AnyObject {
    /// POST /api/user/apnsToken { token, env, bundleId, settings }.
    func registerToken(_ body: [String: Any]) async -> UMBackendOutcome
    /// DELETE /api/user/apnsToken { token }.
    func deleteToken(_ token: String) async -> UMBackendOutcome
    /// GET /api/appattest/challenge -> { challenge, ttlSec }.
    func attestChallenge() async -> (challenge: String, socketNonce: String?)?
    /// POST /api/appattest/attest { keyId, attestationObject, challenge }.
    func attest(_ body: [String: Any]) async -> UMBackendOutcome
}

final class UMLivePushBackend: UMPushBackend {
    static let shared = UMLivePushBackend()

    private func call(_ method: String, _ path: String, _ body: [String: Any]?) async -> (UMBackendOutcome, Data?) {
        do {
            let r = try await APIClient.shared.requestWithStatus(method, path: path, body: body)
            return (.from(status: r.status), r.data)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    func registerToken(_ body: [String: Any]) async -> UMBackendOutcome {
        await call("POST", UMPushRegistration.path, body).0
    }

    func deleteToken(_ token: String) async -> UMBackendOutcome {
        await call("DELETE", UMPushRegistration.path, UMPushRegistration.deleteBody(token: token)).0
    }

    func attestChallenge() async -> (challenge: String, socketNonce: String?)? {
        let (outcome, data) = await call("GET", UMAttestWire.challengePath, nil)
        guard outcome == .ok, let data, let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return UMAttestWire.parseChallenge(obj)
    }

    func attest(_ body: [String: Any]) async -> UMBackendOutcome {
        await call("POST", UMAttestWire.attestPath, body).0
    }
}

/// App icon badge. Pushes set it to the site inbox unread count (`aps.badge`); the app re-reads
/// that count on foreground so reading the inbox on the site clears it here too, and zeroes it on
/// sign-out. The app has no native inbox screen yet.
@MainActor
enum UMInboxBadge {
    static func refresh() {
        guard UMPush.isConfigured, UMPush.signedIn else { return }
        Task { @MainActor in
            guard let r = try? await APIClient.shared.requestWithStatus("GET", path: UMInboxCount.path, body: nil),
                  r.status == 200 else { return }
            let obj = (try? JSONSerialization.jsonObject(with: r.data, options: [.fragmentsAllowed]))
                ?? String(data: r.data, encoding: .utf8)
            guard let n = UMInboxCount.parse(obj) else { return }
            try? await UNUserNotificationCenter.current().setBadgeCount(n)
        }
    }

    static func clear() {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }
}
