import Foundation

nonisolated enum UMConfig {
    /// Selected backend host (Z-only switch on the developer profile). Persisted; .com by default.
    static var backend: UMBackend {
        UMBackend(rawValue: UserDefaults.standard.string(forKey: UMBackend.key) ?? "") ?? .com
    }
    static var host: String { backend.rawValue }
    /// "https://<host>" with no trailing slash.
    static var site: String { "https://\(host)" }
    static var apiBase: URL { URL(string: "\(site)/api")! }
    static var siteBase: URL { URL(string: site)! }
    static var socketBase: URL { URL(string: "wss://\(host)")! }

    /// Cookie domain belongs to the selected host (".ultimafia.gg" also covers dev./qa.).
    static func cookieMatchesHost(_ domain: String) -> Bool {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return host == d || host.hasSuffix("." + d)
    }
    /// Public web API key from the ultimafia.com client.
    /// Defined in Ultimafia/App/Secrets.swift.
    /// Firebase web config follows the selected backend (each host has its own project).
    static var firebase: UMFirebaseConfig { backend.firebase }
    static var firebaseAPIKey: String { firebase.apiKey }
    static let allowedEmailDomains: Set<String> = [
        "gmail.com", "hotmail.com", "aol.com", "msn.com", "yandex.ru",
        "live.com", "icloud.com", "gmail.com.sg", "yahoo.com", "mail.com",
        "outlook.com", "hotmail.co.uk",
    ]
    static let lobbies = ["Main", "Sandbox", "Competitive", "Games", "Survivor", "Roleplay"]
    static let maxChatLength = 240
    static let pingInterval: TimeInterval = 10
    /// Largest single socket frame accepted. Join `history` carries the whole
    /// pregame/game chat and can exceed URLSession's 1 MiB default.
    static let socketMaxMessageBytes = 64 * 1024 * 1024
}

nonisolated enum UMBackend: String, CaseIterable, Identifiable {
    case com = "ultimafia.com"
    case gg = "ultimafia.gg"
    case dev = "dev.ultimafia.gg"
    case qa = "qa.ultimafia.gg"
    static let key = "um.backend.host"
    var id: String { rawValue }
    static func set(_ b: UMBackend) { UserDefaults.standard.set(b.rawValue, forKey: key) }

    /// Public Firebase web client values per host (.com = beyondmaf, unchanged).
    var firebase: UMFirebaseConfig {
        switch self {
        case .com: return UMFirebaseConfig(apiKey: UMSecrets.firebaseAPIKey, authDomain: "beyondmaf.firebaseapp.com", projectId: "beyondmaf")
        case .dev: return UMFirebaseConfig(apiKey: "AIzaSyDdbZzZ8sFpYrD1zRqeaylOYM2-r6CcLuk", authDomain: "dev-ultimafia.firebaseapp.com", projectId: "dev-ultimafia")
        case .qa: return UMFirebaseConfig(apiKey: "AIzaSyCNBl7HAS9jVGUMAe8HrOqQu2B9ZfMDcmk", authDomain: "qa-ultimafia.firebaseapp.com", projectId: "qa-ultimafia")
        case .gg: return UMFirebaseConfig(apiKey: "AIzaSyAWHEMmiFg0DwgaIVbtyrWbth-6H75co-g", authDomain: "prod-ultimafia.firebaseapp.com", projectId: "prod-ultimafia")
        }
    }
}

nonisolated struct UMFirebaseConfig: Equatable {
    let apiKey: String
    let authDomain: String
    let projectId: String
}
