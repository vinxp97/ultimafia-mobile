import Foundation

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    var csrf: String?

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await request("GET", path: path, query: query, body: nil)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw UMError.message(decodeHint(path: path, data: data, error: error))
        }
    }

    func post(_ path: String, json: [String: Any] = [:]) async throws -> Data {
        try await request("POST", path: path, query: [:], body: json)
    }

    func postStatus(_ path: String, json: [String: Any] = [:]) async throws {
        _ = try await post(path, json: json)
    }

    @discardableResult
    func request(_ method: String, path: String, query: [String: String], body: [String: Any]?) async throws -> Data {
        let url = try makeURL(path: path, query: query)
        var req = URLRequest(url: url)
        UMAccess.apply(&req)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(UMConfig.site)", forHTTPHeaderField: "Origin")
        if let csrf, method != "GET" {
            req.setValue(csrf, forHTTPHeaderField: "x-csrf")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UMError.message("No response.") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UMAuthRejected(message: UMFriendlyError.serverText(data: data, status: http.statusCode, fallback: "Not signed in."))
        }
        if http.statusCode >= 400 {
            throw UMError.message(UMFriendlyError.serverText(data: data, status: http.statusCode, fallback: "Request failed (\(http.statusCode))."))
        }
        return data
    }

    /// multipart/form-data POST, like the site's axios FormData uploads (same cookie session + x-csrf).
    /// `progress` reports 0...1 of the request body sent.
    @discardableResult
    func upload(_ path: String, fields: [String: String] = [:], fileField: String, filename: String, mimeType: String,
                data fileData: Data, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> Data {
        let url = try makeURL(path: path, query: [:])
        let boundary = "UMBoundary-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        add("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        UMAccess.apply(&req)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(UMConfig.site)", forHTTPHeaderField: "Origin")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let csrf { req.setValue(csrf, forHTTPHeaderField: "x-csrf") }
        let delegate = UMUploadProgressDelegate(progress)
        let (data, response) = try await session.upload(for: req, from: body, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw UMError.message("No response.") }
        if http.statusCode == 413 { throw UMError.message("File too large for the server.") }
        if http.statusCode >= 400 {
            // Upload 401/403s are usually shop/perk gating, not sign-in loss: surface as a plain message.
            throw UMError.message(UMFriendlyError.serverText(data: data, status: http.statusCode, fallback: "Upload failed (\(http.statusCode))."))
        }
        return data
    }

    func establishSession(idToken: String) async throws {
        _ = try await post("auth", json: ["idToken": idToken])
    }

    func userInfo() async throws -> UserInfo {
        let info: UserInfo = try await get("user/info")
        csrf = info.csrfToken
        return info
    }

    func logout() async {
        try? await postStatus("user/logout")
        csrf = nil
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    func gameList(list: String, lobby: String, page: Int = 1) async throws -> [GameSummary] {
        let data = try await request("GET", path: "game/list", query: [
            "list": list,
            "lobby": lobby,
            "page": String(page),
        ], body: nil)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw UMError.message("Could not read game list.")
        }
        return rows.compactMap { row in
            guard JSONSerialization.isValidJSONObject(row),
                  let rowData = try? JSONSerialization.data(withJSONObject: row),
                  let game = try? decoder.decode(GameSummary.self, from: rowData)
            else { return nil }
            return game
        }
    }

    /// Finished games are cursor-paged by `endTime`: pass the oldest endTime seen as `last`.
    func finishedGames(before last: Double?) async throws -> [GameSummary] {
        var q = ["list": "finished", "lobby": "All"]
        if let last { q["last"] = String(format: "%.0f", last) }
        let data = try await request("GET", path: "game/list", query: q, body: nil)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw UMError.message("Could not read finished games.")
        }
        return rows.compactMap { row in
            guard JSONSerialization.isValidJSONObject(row),
                  let rowData = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(GameSummary.self, from: rowData)
        }
    }

    func openCounts() async throws -> OpenCounts {
        try await get("game/openCounts")
    }

    func connect(gameId: String, spectate: Bool = false) async throws -> GameConnect {
        try await get("game/\(gameId)/connect", query: GameJoinWire.connectQuery(spectate: spectate))
    }

    func leaveGame() async {
        try? await postStatus("game/leave")
    }

    func onlineUsers() async throws -> [OnlineUser] {
        try await get("user/online")
    }

    func pingOnline() async {
        try? await postStatus("user/online")
    }

    func userProfile(_ id: String) async throws -> [String: Any] {
        let any = try await jsonObject("user/\(id)/profile")
        guard let obj = any as? [String: Any] else {
            throw UMError.message("Could not read profile.")
        }
        return obj
    }

    /// GET /api/family/:familyId/profile (routes/family.js).
    func familyProfile(_ id: String) async throws -> [String: Any] {
        let any = try await jsonObject("family/\(id)/profile")
        guard let obj = any as? [String: Any] else {
            throw UMError.message("Could not read family.")
        }
        return obj
    }

    func jsonObject(_ path: String, query: [String: String] = [:]) async throws -> Any {
        let data = try await request("GET", path: path, query: query, body: nil)
        return try JSONSerialization.jsonObject(with: data)
    }

    func comments(location: String, page: Int = 1) async throws -> (comments: [[String: Any]], maxPage: Int, page: Int) {
        let any = try await jsonObject("comment", query: [
            "location": location,
            "page": String(page),
        ])
        if let arr = any as? [Any] {
            return (arr.compactMap { $0 as? [String: Any] }, 1, page)
        }
        guard let obj = any as? [String: Any] else {
            throw UMError.message("Could not read comments.")
        }
        let rows = (obj["comments"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let maxPage: Int
        if let n = obj["maxPage"] as? Int { maxPage = n }
        else if let n = obj["maxPage"] as? Double { maxPage = Int(n) }
        else if let n = obj["maxPage"] as? NSNumber { maxPage = n.intValue }
        else { maxPage = 1 }
        let pg: Int
        if let n = obj["page"] as? Int { pg = n }
        else if let n = obj["page"] as? Double { pg = Int(n) }
        else if let n = obj["page"] as? NSNumber { pg = n.intValue }
        else { pg = page }
        return (rows, max(1, maxPage), pg)
    }

    func postComment(content: String, location: String) async throws {
        try await postStatus("comment", json: ["content": content, "location": location])
    }

    func voteItem(item: String, itemType: String, direction: Int) async throws -> Int {
        let data = try await post("votes", json: [
            "item": item,
            "itemType": itemType,
            "direction": direction,
        ])
        if let n = try? JSONSerialization.jsonObject(with: data) as? Int { return n }
        if let n = try? JSONSerialization.jsonObject(with: data) as? NSNumber { return n.intValue }
        if let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let n = Int(s) {
            return n
        }
        return 0
    }

    func reactItem(item: String, itemType: String, emote: String, emoteKind: String = "unicode", emotePath: String = "") async throws -> [[String: Any]] {
        let data = try await post("reactions", json: [
            "item": item,
            "itemType": itemType,
            "emote": emote,
            "emoteKind": emoteKind,
            "emotePath": emotePath,
        ])
        let any = try JSONSerialization.jsonObject(with: data)
        if let obj = any as? [String: Any], let arr = obj["reactions"] as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private func makeURL(path: String, query: [String: String]) throws -> URL {
        let base = UMConfig.apiBase.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: base + "/" + rel) else {
            throw UMError.message("Bad URL.")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw UMError.message("Bad URL.") }
        return url
    }

    private func decodeHint(path: String, data: Data, error: Error) -> String {
        let snippet = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80) ?? ""
        if snippet.hasPrefix("<") || snippet.lowercased().contains("<!doctype") {
            return "Ultimafia sent an unexpected response. Try again in a moment."
        }
        if snippet.isEmpty {
            return "Empty response from /\(path)."
        }
        return "Could not read server response (\(path))."
    }
}

private final class UMUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (@MainActor @Sendable (Double) -> Void)?
    init(_ onProgress: (@MainActor @Sendable (Double) -> Void)?) { self.onProgress = onProgress }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let onProgress, totalBytesExpectedToSend > 0 else { return }
        let f = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in onProgress(f) }
    }
}
