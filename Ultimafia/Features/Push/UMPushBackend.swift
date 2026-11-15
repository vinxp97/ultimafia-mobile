import Foundation

/// Push + App Attest server calls, behind a protocol so the app runs (and tests run) before the
/// backend exists. Shapes are the PROPOSED ones in Pranay's contract.
protocol UMPushBackend: AnyObject {
    /// POST /api/user/apnsToken { token, env, bundleId, pushSettings }.
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
