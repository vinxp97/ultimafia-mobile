import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// App Attest (contract §2c, PROPOSED): proves the game socket is this genuine app on a real
/// device so the server can mark the player `client: "ios"` (the Apple icon).
///
/// - Enrollment, once per signed-in user on this install: generate a Secure Enclave key, GET a
///   challenge, attest the key with SHA256(challenge), POST it. The keyId lives in the Keychain
///   (device-only), keyed by user id, so an account switch enrolls its own key.
/// - Per game socket, after `authSuccess`: a fresh challenge (pushed by the socket or fetched over
///   HTTP) -> assertion over SHA256(challenge || socketNonce), sent as `appAttest` on `join`.
///
/// Fail open everywhere: Simulator, unsupported devices, guests, a 404 backend, or any error means
/// no `appAttest` field and the player joins exactly as before, just without the badge.
@MainActor
final class UMAppAttest {
    static let shared = UMAppAttest()
    /// The signed-in user (set by AppModel); guests have none and never attest.
    var userId: String?

    /// Race `work` against a deadline; nil when the deadline wins. Used so a slow attest never
    /// holds up joining a game.
    static func withTimeout(seconds: Double, _ work: @escaping @MainActor () async -> [String: Any]?) async -> [String: Any]? {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            let job = Task { @MainActor in
                let r = await work()
                if !once.done { once.done = true; cont.resume(returning: r) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !once.done { once.done = true; job.cancel(); cont.resume(returning: nil) }
            }
        }
    }

    private let service = "VCCCLLC.Ultimafia.appattest"
    private var enrolling: Task<String?, Never>?
    /// The backend answered 404 for the challenge route this launch; stop asking until relaunch.
    private var backendMissing = false

    var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif canImport(DeviceCheck) && os(iOS)
        return DCAppAttestService.shared.isSupported
        #else
        return false
        #endif
    }

    private func keyAccount(_ userId: String) -> String { "keyId.\(userId)" }
    private func attestedAccount(_ userId: String) -> String { "attested.\(userId)" }

    private func storedKey(_ userId: String) -> String? {
        UMKeychain.get(service: service, account: keyAccount(userId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func isAttested(_ userId: String) -> Bool {
        UMKeychain.get(service: service, account: attestedAccount(userId)) != nil
    }

    private func forget(_ userId: String) {
        UMKeychain.delete(service: service, account: keyAccount(userId))
        UMKeychain.delete(service: service, account: attestedAccount(userId))
    }

    /// Enroll in the background after sign-in so the first join doesn't wait on it.
    func warmUp(userId: String?) {
        guard let userId else { return }
        Task { _ = await enrolledKey(userId: userId) }
    }

    /// The attested keyId for this user, enrolling once if needed. nil = skip the badge.
    func enrolledKey(userId: String) async -> String? {
        guard isSupported, !backendMissing else { return nil }
        if let k = storedKey(userId), isAttested(userId) { return k }
        if let running = enrolling { return await running.value }
        let task = Task<String?, Never> { await self.enroll(userId: userId) }
        enrolling = task
        let k = await task.value
        enrolling = nil
        return k
    }

    private func enroll(userId: String) async -> String? {
        #if canImport(DeviceCheck) && os(iOS) && !targetEnvironment(simulator)
        let svc = DCAppAttestService.shared
        do {
            let keyId: String
            if let k = storedKey(userId) { keyId = k } else {
                keyId = try await svc.generateKey()
                UMKeychain.set(Data(keyId.utf8), service: service, account: keyAccount(userId), synced: false)
            }
            guard let ch = await UMPush.backend.attestChallenge() else {
                backendMissing = true
                UMDiag.log("attest", "no challenge (backend missing?); skipping")
                return nil
            }
            let hash = Data(SHA256.hash(data: Data(ch.challenge.utf8)))
            let attestation = try await svc.attestKey(keyId, clientDataHash: hash)
            switch await UMPush.backend.attest(UMAttestWire.attestBody(keyId: keyId, attestation: attestation, challenge: ch.challenge)) {
            case .ok:
                UMKeychain.set(Data([1]), service: service, account: attestedAccount(userId), synced: false)
                UMDiag.log("attest", "enrolled key \(keyId.prefix(6))…")
                return keyId
            case .unsupported:
                backendMissing = true
                return nil
            case .failed(let why):
                UMDiag.log("attest", "attest rejected: \(why)")
                // A rejected attestation can't be retried with the same key; start over next time.
                forget(userId)
                return nil
            }
        } catch {
            UMDiag.log("attest", "enroll failed: \(error.localizedDescription)")
            if let dc = error as? DCError, dc.code == .invalidKey { forget(userId) }
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The `appAttest` object for the game `join` payload, or nil to join without it.
    /// `pushed` is an `appAttestChallenge` the socket sent after auth, if any.
    func joinField(userId: String?, pushed: (challenge: String, socketNonce: String?)?) async -> [String: Any]? {
        #if canImport(DeviceCheck) && os(iOS) && !targetEnvironment(simulator)
        guard let userId, let keyId = await enrolledKey(userId: userId) else { return nil }
        let ch: (challenge: String, socketNonce: String?)?
        if let pushed { ch = pushed } else { ch = await UMPush.backend.attestChallenge() }
        guard let ch else { return nil }
        let hash = Data(SHA256.hash(data: UMAttestWire.clientData(challenge: ch.challenge, socketNonce: ch.socketNonce)))
        do {
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: hash)
            return UMAttestWire.joinField(keyId: keyId, assertion: assertion)
        } catch {
            UMDiag.log("attest", "assertion failed: \(error.localizedDescription)")
            if let dc = error as? DCError, dc.code == .invalidKey { forget(userId) }
            return nil
        }
        #else
        return nil
        #endif
    }
}
