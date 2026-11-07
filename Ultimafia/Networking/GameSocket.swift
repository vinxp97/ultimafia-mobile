import Foundation
import QuartzCore

struct SocketEvent {
    var name: String
    var json: Any?
}

final class GameSocket: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    var onEvent: ((String, Any?) -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var isOpen = false
    /// Raw JSON of the last `:object:` payload (for map key order, e.g. `players`).
    private(set) var lastObjectJSON: String?

    func connect(port: String) {
        disconnect()
        let url = UMConfig.socketBase.appendingPathComponent(port)
        var request = URLRequest(url: url)
        UMAccess.apply(&request)
        request.setValue("\(UMConfig.site)", forHTTPHeaderField: "Origin")
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        if #unavailable(iOS 18.4) {
            config.shouldUseExtendedBackgroundIdleMode = true
        }
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.webSocketTask(with: request)
        // URLSessionWebSocketTask rejects any single frame over 1 MiB by default
        // ("Message too long"). A long pregame chat makes the join `history`
        // event exceed that, which dropped the socket and bounced to the lobby.
        task?.maximumMessageSize = UMConfig.socketMaxMessageBytes
        UMDiag.log("socket", "connect port \(port)")
        listen()
        task?.resume()
        pingTimer = Timer.scheduledTimer(withTimeInterval: UMConfig.pingInterval, repeats: true) { [weak self] _ in
            self?.send("p")
        }
        RunLoop.main.add(pingTimer!, forMode: .common)
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        isOpen = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func send(_ event: String, object: Any? = nil) {
        let payload = stringify(event, data: object)
        task?.send(.string(payload)) { error in
            if let error {
                print("socket send error", error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        isOpen = true
        UMDiag.log("socket", "open")
        send("p")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isOpen = false
        UMDiag.log("socket", "closed code \(closeCode.rawValue)")
        onDisconnect?()
        onEvent?("disconnected", nil)
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                UMDiag.log("socket", "receive failed: \(error.localizedDescription)")
                self.isOpen = false
                self.onDisconnect?()
                self.onEvent?("disconnected", nil)
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text {
                    let t0 = CACurrentMediaTime()
                    if let parsed = parse(text) {
                        let t1 = CACurrentMediaTime()
                        self.lastObjectJSON = parsed.2
                        self.onEvent?(parsed.0, parsed.1)
                        let t2 = CACurrentMediaTime()
                        let parseMs = Int((t1 - t0) * 1000), handleMs = Int((t2 - t1) * 1000)
                        if parsed.0 != "p" && parsed.0 != "typing" {
                            UMDiag.log("evt", "\(parsed.0) \(text.utf8.count)B parse \(parseMs)ms handle \(handleMs)ms")
                        }
                    }
                }
                self.listen()
            }
        }
    }
}

func stringify(_ event: String, data: Any?) -> String {
    guard let data else { return event }
    if let s = data as? String { return "\(event):string:\(s)" }
    if let b = data as? Bool { return "\(event):boolean:\(b)" }
    if let i = data as? Int { return "\(event):number:\(i)" }
    if let d = data as? Double { return "\(event):number:\(d)" }
    if JSONSerialization.isValidJSONObject(data),
       let json = try? JSONSerialization.data(withJSONObject: data),
       let s = String(data: json, encoding: .utf8) {
        return "\(event):object:\(s)"
    }
    return "\(event):string:\(String(describing: data))"
}

func parse(_ message: String) -> (String, Any?, String?)? {
    guard let first = message.firstIndex(of: ":") else { return (message, nil, nil) }
    let event = String(message[..<first])
    let rest = String(message[message.index(after: first)...])
    guard let second = rest.firstIndex(of: ":") else { return (event, nil, nil) }
    let type = String(rest[..<second])
    let data = String(rest[rest.index(after: second)...])
    switch type {
    case "number": return (event, Double(data), nil)
    case "boolean": return (event, data != "false", nil)
    case "object":
        let bytes = Data(data.utf8)
        let obj = try? JSONSerialization.jsonObject(with: bytes)
        return (event, obj, data)
    default:
        return (event, data, nil)
    }
}

/// Top-level keys of a JSON object, in source order (JS Object.keys).
func umJSONTopLevelKeys(_ json: String?) -> [String] {
    guard let json else { return [] }
    let s = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.first == "{" else { return [] }
    var keys: [String] = []
    var i = s.index(after: s.startIndex)
    var depth = 1
    var inString = false
    var escape = false
    enum Mode { case seekKey, inKey, skipValue }
    var mode = Mode.seekKey
    var keyChars: [Character] = []
    while i < s.endIndex, depth > 0 {
        let c = s[i]
        if inString {
            if escape {
                if mode == .inKey { keyChars.append(c) }
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                inString = false
                if mode == .inKey {
                    keys.append(String(keyChars))
                    keyChars.removeAll()
                    mode = .skipValue
                }
            } else if mode == .inKey {
                keyChars.append(c)
            }
        } else {
            switch c {
            case "\"":
                inString = true
                if mode == .seekKey, depth == 1 {
                    mode = .inKey
                    keyChars.removeAll()
                }
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
            case ",":
                if depth == 1 { mode = .seekKey }
            default:
                break
            }
        }
        i = s.index(after: i)
    }
    return keys
}
