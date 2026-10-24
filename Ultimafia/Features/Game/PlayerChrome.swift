import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
typealias UMPlatformImage = UIImage
#else
import AppKit
typealias UMPlatformImage = NSImage
#endif

extension UMPlatformImage {
    static func um(cg: CGImage) -> UMPlatformImage {
        #if canImport(UIKit)
        UIImage(cgImage: cg)
        #else
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}

func platformImage(_ image: UMPlatformImage) -> Image {
    #if canImport(UIKit)
    Image(uiImage: image)
    #else
    Image(nsImage: image)
    #endif
}


nonisolated enum UMAvatarURL {
    static func live(userId: String) -> URL? {
        URL(string: "\(UMConfig.site)/uploads/\(userId)_avatar.webp")
    }

    /// Web Avatar: a string avatar containing "decks" is shown from `/uploads<path>`.
    static func deckPath(_ raw: Any?) -> String? {
        guard let s = raw as? String, s.contains("decks") else { return nil }
        return s.hasPrefix("/") ? s : "/" + s
    }

    static func deck(path: String) -> URL? {
        URL(string: "\(UMConfig.site)/uploads\(path)")
    }
}

enum UMDefaultAvatar {
    // Same palette as react_main/src/components/Basic.jsx InlineAvatar
    static let hexes = [
        "#fff59d", "#ef9a9a", "#9fa8da", "#ce93d8", "#a5d6a7",
        "#f48fb1", "#ffcc80", "#90deea", "#80cbc4",
    ]
    static let iconURL = URL(string: "https://cdn.jsdelivr.net/gh/UltiMafia/Ultimafia@master/react_main/src/images/avatar.webp")

    static func color(for username: String) -> Color {
        var rand: Int32 = 0
        let units = Array(username.utf16)
        for unit in units {
            rand ^= Int32(unit)
        }
        if units.count > 1 {
            rand ^= Int32(units[1])
        }
        rand ^= rand &<< 13
        rand ^= rand &>> 7
        rand ^= rand &<< 17
        let mixed = abs(Double(rand)) / 2_147_483_648.0
        let i = min(hexes.count - 1, Int(floor(mixed * Double(hexes.count))))
        return Color(umHex: hexes[i]) ?? Color(white: 0.7)
    }
}

struct UMDefaultAvatarView: View {
    var name: String

    var body: some View {
        ZStack {
            UMDefaultAvatar.color(for: name)
            if let url = UMDefaultAvatar.iconURL {
                AnimatedWebPView(url: url, showsPlaceholder: false)
                    .scaledToFill()
            }
        }
    }
}

struct UMAvatarView: View {
    let userId: String?
    let hasAvatar: Bool
    var name: String = ""
    var size: CGFloat = 28
    var square: Bool = false
    /// Anonymous deck avatar path; wins over the user avatar.
    var deckPath: String? = nil

    init(userId: String?, hasAvatar: Bool, name: String = "", size: CGFloat = 28, square: Bool = false, deckPath: String? = nil) {
        self.userId = userId
        self.hasAvatar = hasAvatar
        self.deckPath = deckPath
        self.name = name
        self.size = size
        self.square = square
    }

    init(player: GamePlayer, size: CGFloat = 28) {
        self.init(userId: player.userId, hasAvatar: player.avatar, name: player.name, size: size,
                  square: player.squareAvatar, deckPath: player.deckAvatarPath)
    }

    var body: some View {
        Group {
            if let deckPath, let url = UMAvatarURL.deck(path: deckPath) {
                // Deck images go through UMCustomAssetCache (/uploads/), so they're on disk after first use.
                AnimatedWebPView(url: url, freeze: UMViewerPrefs.shared.disableAnimatedAvatars)
            } else if hasAvatar, let userId, !userId.isEmpty, let url = UMAvatarURL.live(userId: userId) {
                // Site "Disable Animated Avatars": other users' avatars show a still first frame.
                let prefs = UMViewerPrefs.shared
                AnimatedWebPView(url: url, freeze: prefs.disableAnimatedAvatars && userId != prefs.myUserId)
            } else {
                UMDefaultAvatarView(name: name)
            }
        }
        .frame(width: size, height: size)
        .clipShape(square ? AnyShape(RoundedRectangle(cornerRadius: size * 0.18)) : AnyShape(Circle()))
        .overlay {
            if square {
                RoundedRectangle(cornerRadius: size * 0.18).stroke(UMTheme.line, lineWidth: 1)
            } else {
                Circle().stroke(UMTheme.line, lineWidth: 1)
            }
        }
    }
}

/// Decoded frames in memory + raw bytes on disk, so avatars/role icons don't refetch or flicker
/// when rows re-render or the app relaunches.
/// Shared by all accounts (keyed by URL only); not cleared on sign-out or account switch.
final class UMImageCache: @unchecked Sendable {
    static let shared = UMImageCache()
    private final class Entry { let images: [UMPlatformImage]; let delays: [Double]
        init(_ i: [UMPlatformImage], _ d: [Double]) { images = i; delays = d } }
    private let memory = NSCache<NSURL, Entry>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                                   directory: UMCacheLocation.images)
        // Uploads are `no-cache` + ETag: disk copy is revalidated with a cheap 304, so avatar
        // changes still show up; the in-memory frame cache keeps re-renders from flickering.
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    init() { memory.countLimit = 1500 }

    /// Decoded frames held strongly for an open game / review / spectate session (NSCache may
    /// evict under pressure; these may not), keyed by session scope. Dropped when that session
    /// closes (`unpin`), and gone with the process, so nothing outlives the app.
    private let pinned = UMLocked<[String: [URL: Entry]]>([:])
    /// One fetch + decode per URL at a time: rows that appear together share it.
    private let inflight = UMLocked<[URL: Task<Entry?, Never>]>([:])
    #if DEBUG
    /// Network fetches made by this cache (memory/pinned hits don't count). Diagnostics only.
    static let networkFetches = UMLocked<Int>(0)
    /// Memory misses that had to read bytes (network, URL cache, upload disk cache or file) and decode.
    static let loads = UMLocked<Int>(0)
    #endif

    func frames(for url: URL) -> (images: [UMPlatformImage], delays: [Double])? {
        if let e = memory.object(forKey: url as NSURL) { return (e.images, e.delays) }
        let pin = pinned.withLock { p in p.values.lazy.compactMap { $0[url] }.first }
        if let pin {
            memory.setObject(pin, forKey: url as NSURL)
            return (pin.images, pin.delays)
        }
        return nil
    }

    func store(_ images: [UMPlatformImage], delays: [Double], for url: URL) {
        memory.setObject(Entry(images, delays), forKey: url as NSURL)
    }

    /// Memory, then a shared in-flight load, then disk/network + decode (stored for next time).
    func loadFrames(for url: URL) async -> (images: [UMPlatformImage], delays: [Double])? {
        if let hit = frames(for: url) { return hit }
        let task: Task<Entry?, Never> = inflight.withLock { map in
            if let t = map[url] { return t }
            let t = Task<Entry?, Never> {
                #if DEBUG
                let n = Self.loads.withLock { v in v += 1; return v }
                UMDiag.log("img", "load #\(n) \(url.isFileURL ? "file" : url.host() ?? "?") \(url.lastPathComponent)")
                #endif
                guard let data = try? await self.data(for: url) else { return nil }
                let parsed = AnimatedWebPView.decodeFrames(data)
                guard !parsed.images.isEmpty else { return nil }
                let e = Entry(parsed.images, parsed.delays)
                self.memory.setObject(e, forKey: url as NSURL)
                return e
            }
            map[url] = t
            return t
        }
        let entry = await task.value
        inflight.withLock { _ = $0.removeValue(forKey: url) }
        return entry.map { ($0.images, $0.delays) }
    }

    /// Load (if needed) and hold every URL for `scope` until `unpin(scope:)`. Six at a time.
    func pin(_ urls: [URL], scope: String) async {
        let todo = Array(Set(urls))
        guard !todo.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var it = todo.makeIterator()
            func addNext() -> Bool {
                guard let url = it.next() else { return false }
                group.addTask {
                    guard let f = await self.loadFrames(for: url) else { return }
                    self.pinned.withLock { $0[scope, default: [:]][url] = Entry(f.images, f.delays) }
                }
                return true
            }
            for _ in 0..<6 { if !addNext() { break } }
            while await group.next() != nil { _ = addNext() }
        }
        #if DEBUG
        let n = pinned.withLock { $0[scope]?.count ?? 0 }
        UMDiag.log("img", "pinned \(n) of \(todo.count) for \(scope)")
        #endif
    }

    func unpin(scope: String) {
        let n = pinned.withLock { $0.removeValue(forKey: scope)?.count ?? 0 }
        if n > 0 { UMDiag.log("img", "unpinned \(n) for \(scope)") }
    }

    /// Drops decoded frames for custom user assets only (site emotes / role icons stay).
    func evictCustomUserAssets() {
        for url in customKeys.withLock({ k in defer { k.removeAll() }; return k }) {
            memory.removeObject(forKey: url as NSURL)
        }
    }
    private let customKeys = UMLocked<Set<URL>>([])

    /// You-tab clear: drop every decoded frame and the on-disk image responses.
    func clearAll() {
        memory.removeAllObjects()
        pinned.withLock { $0.removeAll() }
        customKeys.withLock { $0.removeAll() }
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    static let didPurge = Notification.Name("UMImageCache.didPurge")

    /// After a confirmed upload/removal: drop `urls` from memory frames, both URLCaches and the
    /// custom-asset disk cache, refetch fresh bytes, then tell visible views to reload.
    func purge(_ urls: [URL]) async {
        for url in urls {
            memory.removeObject(forKey: url as NSURL)
            customKeys.withLock { _ = $0.remove(url) }
            pinned.withLock { p in for k in p.keys { p[k]?[url] = nil } }
            let req = URLRequest(url: url)
            session.configuration.urlCache?.removeCachedResponse(for: req)
            URLCache.shared.removeCachedResponse(for: req)
        }
        await UMCustomAssetCache.shared.purge(urls)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didPurge, object: nil, userInfo: ["urls": urls])
        }
    }

    func data(for url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        if UMCustomAssetCache.isCustomUserAsset(url) {
            customKeys.withLock { _ = $0.insert(url) }
            return try await UMCustomAssetCache.shared.data(for: url)
        }
        #if DEBUG
        let n = Self.networkFetches.withLock { v in v += 1; return v }
        UMDiag.log("img", "fetch #\(n) \(url.lastPathComponent)")
        #endif
        let (data, response) = try await session.data(for: UMAccess.request(url))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
        return data
    }
}

nonisolated final class UMLocked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

struct AnimatedWebPView: View {
    let url: URL
    var showsPlaceholder: Bool = true
    /// When set, renders at this height with width from the image's own aspect ratio (emotes).
    var fitHeight: CGFloat? = nil
    /// Show only the first frame (no animation loop).
    var freeze: Bool = false
    var interpolation: Image.Interpolation? = nil
    @State private var frames: [UMPlatformImage] = []
    @State private var delays: [Double] = []
    @State private var index = 0
    /// Bumped when this URL is purged after an upload, forcing a reload.
    @State private var revision = 0
    /// URL the `frames` state belongs to.
    @State private var loadedURL: URL?

    /// What to draw now. A freshly created view (a row that just appeared, a new phase's rows)
    /// reads the shared cache synchronously, so a cached image is on screen in the very first
    /// frame instead of a spinner until `.task` runs.
    private var shownFrames: [UMPlatformImage] {
        if loadedURL == url, !frames.isEmpty { return frames }
        return UMImageCache.shared.frames(for: url)?.images ?? []
    }

    var body: some View {
        let frames = shownFrames
        Group {
            if let image = frames.indices.contains(index) ? frames[index] : frames.first {
                if let h = fitHeight {
                    resizableImage(image)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: h * Self.aspect(image), height: h)
                } else {
                    resizableImage(image)
                        .scaledToFill()
                }
            } else if let h = fitHeight {
                Color.clear.frame(width: h, height: h)
            } else if showsPlaceholder {
                ProgressView().scaleEffect(0.6)
            } else {
                Color.clear
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UMImageCache.didPurge)) { note in
            if let urls = note.userInfo?["urls"] as? [URL], urls.contains(url) { revision += 1 }
        }
        .task(id: "\(url.absoluteString)#\(revision)#\(freeze)") {
            await load()
            if freeze { index = 0; return }
            while !Task.isCancelled, frames.count > 1 {
                let delay = delays.indices.contains(index) ? delays[index] : 0.1
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.04) * 1_000_000_000))
                await MainActor.run {
                    if frames.count > 1 { index = (index + 1) % frames.count }
                }
            }
        }
    }

    private func resizableImage(_ image: UMPlatformImage) -> Image {
        let image = platformImage(image).resizable()
        if let interpolation { return image.interpolation(interpolation) }
        return image
    }

    private static func aspect(_ image: UMPlatformImage) -> CGFloat {
        let sz = image.size
        guard sz.width > 0, sz.height > 0 else { return 1 }
        return sz.width / sz.height
    }

    private func load() async {
        let target = url
        if let hit = UMImageCache.shared.frames(for: target) {
            frames = hit.images
            delays = hit.delays
            loadedURL = target
            index = 0
            return
        }
        let loaded = await UMImageCache.shared.loadFrames(for: target)
        await MainActor.run {
            frames = loaded?.images ?? []
            delays = loaded?.delays ?? []
            loadedURL = target
            index = 0
        }
    }

    static func decodeFrames(_ data: Data) -> (images: [UMPlatformImage], delays: [Double]) {
        frames(from: data)
    }

    private static func frames(from data: Data) -> (images: [UMPlatformImage], delays: [Double]) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return ([], []) }
        let count = CGImageSourceGetCount(src)
        var images: [UMPlatformImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(UMPlatformImage.um(cg: cg))
            delays.append(frameDelay(src, index: i))
        }
        return (images, delays)
    }

    private static func frameDelay(_ src: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any] else { return 0.1 }
        for key in ["{GIF}", "{WebP}", "{PNG}"] {
            if let dict = props[key] as? [String: Any] {
                if let d = dict["UnclampedDelayTime"] as? Double, d > 0 { return d }
                if let d = dict["DelayTime"] as? Double, d > 0 { return d }
            }
        }
        return 0.1
    }
}

extension Color {
    init?(umHex raw: String?) {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a, r, g, b: Double
        if s.count == 8 {
            a = Double((v >> 24) & 0xFF) / 255
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else {
            a = 1
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

func umNormalizedColorToken(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    let lower = t.lowercased()
    if ["none", "default", "null", "undefined"].contains(lower) { return nil }
    return t
}

func umColorString(_ any: Any?) -> String? {
    if let s = any as? String {
        return umNormalizedColorToken(s)
    }
    if let d = any as? [String: Any] {
        for key in ["darkTheme", "dark", "lightTheme", "light"] {
            if let s = d[key] as? String, let token = umNormalizedColorToken(s) {
                return token
            }
        }
    }
    return nil
}

func umNameFill(_ hex: String?) -> Color {
    Color(umHex: hex) ?? .white
}

struct PlayerNameView: View {
    let player: GamePlayer
    var fontSize: CGFloat = 14
    var dead: Bool = false

    private var anim: String { (player.animatedNameColor ?? "none").lowercased() }
    private var shouldAnimate: Bool { !dead && anim != "none" && !anim.isEmpty }
    private var usesClip: Bool {
        ["rainbow", "patriotic", "gradient", "tricolor"].contains(anim)
    }
    private var nameFont: Font { player.displayFont(size: fontSize) }
    private var solidColor: Color { umNameFill(player.nameColorHex) }

    var body: some View {
        Group {
            if dead {
                label.foregroundStyle(Color.red)
            } else if shouldAnimate, usesClip {
                loopingClipName
            } else if shouldAnimate {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    label
                        .foregroundStyle(solidColor)
                        .shadow(color: glowColor(t: t), radius: glowRadius(t: t))
                        .opacity(pulseOpacity(t: t))
                }
            } else {
                label.foregroundStyle(solidColor)
            }
        }
        .lineLimit(1)
    }

    private var label: Text {
        Text(player.name).font(nameFont)
    }

    private var loopingClipName: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let shift = CGFloat((context.date.timeIntervalSinceReferenceDate / 3.0).truncatingRemainder(dividingBy: 1))
            label
                .foregroundStyle(Color.white)
                .overlay {
                    GeometryReader { geo in
                        periodGradient
                            .frame(width: geo.size.width * 2, height: geo.size.height)
                            .offset(x: -shift * geo.size.width)
                    }
                    .allowsHitTesting(false)
                }
                .mask(label)
        }
    }

    private var periodGradient: LinearGradient {
        LinearGradient(stops: gradientStops, startPoint: .leading, endPoint: .trailing)
    }

    private var gradientStops: [Gradient.Stop] {
        let a = Color(umHex: player.nameGradientColorA) ?? Color(umHex: "#ff0040") ?? .red
        let b = Color(umHex: player.nameGradientColorB) ?? Color(umHex: "#00c2ff") ?? .cyan
        let c = Color(umHex: player.nameGradientColorC) ?? Color(umHex: "#3dff6a") ?? .green
        switch anim {
        case "patriotic":
            let red = Color(umHex: "#b22234") ?? Color(red: 0.70, green: 0.13, blue: 0.20)
            let blue = Color(umHex: "#3c3b6e") ?? Color(red: 0.24, green: 0.23, blue: 0.43)
            return [
                .init(color: red, location: 0),
                .init(color: .white, location: 0.1666),
                .init(color: blue, location: 0.3333),
                .init(color: red, location: 0.5),
                .init(color: .white, location: 0.6666),
                .init(color: blue, location: 0.8333),
                .init(color: red, location: 1),
            ]
        case "gradient":
            return [
                .init(color: a, location: 0),
                .init(color: b, location: 0.25),
                .init(color: a, location: 0.5),
                .init(color: b, location: 0.75),
                .init(color: a, location: 1),
            ]
        case "tricolor":
            return [
                .init(color: a, location: 0),
                .init(color: b, location: 0.1666),
                .init(color: c, location: 0.3333),
                .init(color: a, location: 0.5),
                .init(color: b, location: 0.6666),
                .init(color: c, location: 0.8333),
                .init(color: a, location: 1),
            ]
        default:
            let r = Color(umHex: "#ff0040") ?? .red
            let o = Color(umHex: "#ff7a00") ?? .orange
            let y = Color(umHex: "#ffd000") ?? .yellow
            let g = Color(umHex: "#3dff6a") ?? .green
            let c2 = Color(umHex: "#00c2ff") ?? .cyan
            let p = Color(umHex: "#7a5cff") ?? .purple
            return [
                .init(color: r, location: 0),
                .init(color: o, location: 0.0833),
                .init(color: y, location: 0.1666),
                .init(color: g, location: 0.25),
                .init(color: c2, location: 0.3333),
                .init(color: p, location: 0.4166),
                .init(color: r, location: 0.5),
                .init(color: o, location: 0.5833),
                .init(color: y, location: 0.6666),
                .init(color: g, location: 0.75),
                .init(color: c2, location: 0.8333),
                .init(color: p, location: 0.9166),
                .init(color: r, location: 1),
            ]
        }
    }

    private func glowColor(t: TimeInterval) -> Color {
        guard anim == "glow" || anim == "pulse" else { return .clear }
        return solidColor.opacity(anim == "glow" ? 0.55 + 0.35 * sin(t * 4) : 0.35)
    }

    private func glowRadius(t: TimeInterval) -> CGFloat {
        if anim == "glow" { return 4 + 2 * CGFloat(sin(t * 4)) }
        return 0
    }

    private func pulseOpacity(t: TimeInterval) -> Double {
        guard anim == "pulse" else { return 1 }
        return 0.65 + 0.35 * (0.5 + 0.5 * sin(t * (.pi * 2 / 1.1)))
    }
}

extension GamePlayer {
    /// Web: only the name (player list + chat nameplates) gets `name-font-<key>`; message text never does.
    func displayFont(size: CGFloat) -> Font {
        let key = UMViewerPrefs.shared.ignoreNameFonts ? "default" : (nameFont ?? "default").lowercased()
        if key != "default", let ps = UMNameFonts.shared.postScriptName(for: key) {
            // Roboto faces are variable (default Regular); other faces carry their own fixed weight.
            return .custom(ps, fixedSize: size).weight(key == "slab" || key == "mono" ? .semibold : .regular)
        }
        return .system(size: size, weight: .semibold)
    }

    var bodyColor: Color {
        umNameFill(UMViewerPrefs.shared.ignoreTextColor ? nil : textColorHex)
    }
}
