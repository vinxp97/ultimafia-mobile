import SwiftUI
import AVKit
#if canImport(WebKit)
import WebKit
#endif

struct UserProfileView: View {
    var userId: String
    var userName: String

    @Environment(AppModel.self) private var app
    @State private var blob: [String: Any] = [:]
    @State private var error: String?
    @State private var loading = true
    @State private var mediaOpen = true
    @State private var browserItem: UMBrowserItem?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if loading {
                ProgressView()
                    .tint(UMTheme.blood)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let error {
                UMLoadErrorView(title: "Couldn't load profile.", detail: error) {
                    Task { await load() }
                }
            } else {
                profileBody
                if userId == UMProfileCache.devUserId, app.user?.id == UMProfileCache.devUserId {
                    UMBackendSwitch().padding()
                }
            }
        }
        #if DEBUG
        .task(id: loading) {
            // `-UMDiagProfileScrollTo <image file name>`: center that bio image (animation checks).
            let a = ProcessInfo.processInfo.arguments
            guard !loading, let i = a.firstIndex(of: "-UMDiagProfileScrollTo"), a.indices.contains(i + 1) else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo("bioimg:" + a[i + 1], anchor: .center)
        }
        #endif
        }
        .background(pageBackground)
        .navigationTitle("")
        .umInlineTitle()
        .umNavigationBar(.visible)
        .task { await load() }
        .environment(\.openURL, OpenURLAction { url in
            let scheme = (url.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" else { return .systemAction }
            browserItem = UMBrowserItem(url: url)
            return .handled
        })
        .umFullScreenCover(item: $browserItem) { item in
            UMInAppBrowser(url: item.url) {
                browserItem = nil
            }
        }
    }

    private var displayName: String {
        let n = string("name")
        if !n.isEmpty { return n }
        return userName.isEmpty ? "Profile" : userName
    }

    private var canonicalId: String {
        let id = string("id")
        return id.isEmpty ? userId : id
    }

    private var settings: [String: Any] {
        blob["settings"] as? [String: Any] ?? [:]
    }

    private var squareAvatar: Bool {
        (settings["avatarShape"] as? String) == "square"
    }

    private var panelColor: Color {
        Color(umHex: settings["backgroundColor"] as? String) ?? UMTheme.card
    }

    private var customOutline: Color? {
        Color(umHex: settings["backgroundColor"] as? String)
    }

    private func outlinedCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Site: .box-panel has 8px padding + backgroundColor (the frame).
        // Inner .bio / .content fill is --scheme-color, not the custom color.
        content()
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UMTheme.card)
            .padding(8)
            .background(customOutline ?? UMTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var pageBackground: some View {
        let repeatMode = (settings["backgroundRepeatMode"] as? String) ?? "checker"
        if bool("profileBackground"), let url = URL(string: "\(UMConfig.site)/uploads/\(canonicalId)_profileBackground.webp") {
            AnimatedWebPView(url: url, showsPlaceholder: false)
                .scaledToFill()
                .clipped()
                .opacity(repeatMode == "stretch" ? 1 : 0.55)
                .ignoresSafeArea()
                .background(UMTheme.bg)
        } else {
            UMTheme.bg.ignoresSafeArea()
        }
    }

    private var profileBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 12) {
                let trophies = UMTrophy.list(from: blob)
                if !trophies.isEmpty {
                    outlinedCard {
                        UMTrophyRow(trophies: trophies)
                    }
                }
                if !string("bio").isEmpty {
                    outlinedCard {
                        UMMarkdownView(text: string("bio"))
                    }
                }
                if let media = settings["youtube"] as? String, !media.isEmpty {
                    outlinedCard {
                        mediaCard(media)
                    }
                }
                outlinedCard {
                    metaTiles
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            ProfileCommentsView(location: canonicalId)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            bannerImage
            identityBlock
        }
        .padding(8)
        .background(customOutline ?? UMTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 12)
    }

    private var bannerImage: some View {
        GeometryReader { proxy in
            Group {
                if bool("banner"), let url = bannerURL {
                    AnimatedWebPView(url: url)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    UMTheme.elevated
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipped()
    }

    private var identityBlock: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 6) {
                Color.clear.frame(height: showsFamilyOrLove ? 52 : 36)
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        PlayerNameView(player: namePlayer, fontSize: 20)
                        ForEach(nameBadges, id: \.self) { name in
                            Text(name)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(UMTheme.blood.opacity(0.35), in: Capsule())
                        }
                    }
                    if !string("pronouns").isEmpty {
                        Text(string("pronouns"))
                            .font(.caption)
                            .foregroundStyle(UMTheme.muted)
                    }
                    if let joined = joinDate {
                        Text("Joined \(joined)")
                            .font(.caption)
                            .foregroundStyle(UMTheme.muted)
                    }
                    if let status = blob["status"] as? String, !status.isEmpty {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status == "online" ? Color.green : UMTheme.muted)
                                .frame(width: 8, height: 8)
                            Text(status.capitalized)
                                .font(.caption)
                                .foregroundStyle(UMTheme.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            HStack(alignment: .top, spacing: 6) {
                familyCell
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 72)
                loveCell
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            UMAvatarView(
                userId: canonicalId,
                hasAvatar: bool("avatar"),
                name: displayName,
                size: 64,
                square: squareAvatar
            )
            .overlay {
                Circle().stroke(UMTheme.card, lineWidth: 3).opacity(squareAvatar ? 0 : 1)
            }
            .offset(y: -32)
        }
        .background(UMTheme.card)
    }

    private var showsFamilyOrLove: Bool {
        if blob["family"] is [String: Any] { return true }
        let love = blob["love"] as? [String: Any] ?? [:]
        let loveId = umDictString(love, "id")
        let isLove = bool("isLove") || umDictBool(blob, "isLove")
        let isMarried = bool("isMarried") || umDictBool(blob, "isMarried")
        return !loveId.isEmpty && (isLove || isMarried)
    }

    private var namePlayer: GamePlayer {
        GamePlayer(
            id: canonicalId,
            name: displayName,
            userId: canonicalId,
            avatar: bool("avatar"),
            nameColorHex: umColorString(settings["nameColor"]),
            nameFont: settings["nameFont"] as? String,
            animatedNameColor: settings["animatedNameColor"] as? String,
            nameGradientColorA: umColorString(settings["nameGradientColorA"]),
            nameGradientColorB: umColorString(settings["nameGradientColorB"]),
            nameGradientColorC: umColorString(settings["nameGradientColorC"])
        )
    }

    @ViewBuilder
    private var familyCell: some View {
        if let fam = blob["family"] as? [String: Any] {
            let id = umDictString(fam, "id")
            let name = umDictString(fam, "name")
            let has = umDictBool(fam, "avatar")
            Button {
                if !id.isEmpty { app.openFamily(id: id, name: name) }
            } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Member of")
                    .font(.caption.italic())
                    .foregroundStyle(UMTheme.muted)
                HStack(spacing: 6) {
                    if has, !id.isEmpty, let url = URL(string: "\(UMConfig.site)/uploads/\(id)_family_avatar.webp") {
                        AnimatedWebPView(url: url, showsPlaceholder: false)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the family page")
        }
    }

    @ViewBuilder
    private var loveCell: some View {
        let love = blob["love"] as? [String: Any] ?? [:]
        let loveId = umDictString(love, "id")
        let isLove = bool("isLove") || umDictBool(blob, "isLove")
        let isMarried = bool("isMarried") || umDictBool(blob, "isMarried")
        if !loveId.isEmpty, isLove || isMarried {
            let title: String = {
                switch umDictString(love, "type") {
                case "Married": return "Married To"
                default: return "In Love With"
                }
            }()
            let name = umDictString(love, "name")
            Button {
                app.openProfile(id: loveId, name: name)
            } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(title)
                        .font(.caption.italic())
                        .foregroundStyle(UMTheme.muted)
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        UMAvatarView(
                            userId: loveId,
                            hasAvatar: umDictBool(love, "avatar"),
                            name: name,
                            size: 32
                        )
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var metaTiles: some View {
        HStack(spacing: 10) {
            tile("Kudos", number("kudos"))
            tile("Karma", number("karma"))
            if showsGamesTile {
                tile("Games", mafiaGamesTotal)
            }
        }
    }

    private var showsGamesTile: Bool {
        blob["stats"] != nil
    }

    private func tile(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(UMTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(UMTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func mediaCard(_ raw: String) -> some View {
        let autoplay = settings["autoplay"] as? Bool ?? false
        let collapsedDefault = settings["collapseMedia"] as? Bool ?? false
        VStack(alignment: .leading, spacing: 8) {
            Button {
                mediaOpen.toggle()
            } label: {
                HStack {
                    Image(systemName: "music.note")
                    Text("Media")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: mediaOpen ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                }
            }
            .buttonStyle(.plain)
            // Keep the player mounted when collapsed (desktop CSS-hides it).
            ProfileMediaEmbed(raw: raw, autoplay: autoplay)
                .frame(height: mediaOpen ? 200 : 0)
                .opacity(mediaOpen ? 1 : 0)
                .clipped()
                .allowsHitTesting(mediaOpen)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .onAppear { mediaOpen = !collapsedDefault }
    }

    private var bannerURL: URL? {
        let ext = (blob["bannerExt"] as? String)?.lowercased() ?? "webp"
        let safe = ["webp", "gif", "png", "jpg", "jpeg"].contains(ext) ? ext : "webp"
        return URL(string: "\(UMConfig.site)/uploads/\(canonicalId)_banner.\(safe)")
    }

    private var groupNames: [String] {
        let groups = blob["groups"] as? [[String: Any]] ?? []
        return groups.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
    }

    private var nameBadges: [String] {
        groupNames.filter { name in
            let l = name.lowercased()
            if l.contains("ranked") || l.contains("competitive") { return false }
            return true
        }
    }

    private var joinDate: String? {
        let raw = blob["joined"]
        let ms: Double?
        if let n = raw as? Double { ms = n }
        else if let n = raw as? Int { ms = Double(n) }
        else if let n = raw as? NSNumber { ms = n.doubleValue }
        else { ms = nil }
        guard let ms else { return nil }
        let sec = ms > 10_000_000_000 ? ms / 1000 : ms
        let date = Date(timeIntervalSince1970: sec)
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func string(_ key: String) -> String {
        if let s = blob[key] as? String { return s }
        return ""
    }

    private func bool(_ key: String) -> Bool {
        if let b = blob[key] as? Bool { return b }
        if let n = blob[key] as? NSNumber { return n.boolValue }
        if let s = blob[key] as? String { return s == "true" || s == "1" }
        return false
    }

    private func number(_ key: String) -> Int {
        umStatInt(blob[key])
    }

    /// Ranked+competitive (`stats.Mafia.all`) + unranked. Matches desktop All Games.
    /// `stats` is omitted when hideStatistics is on.
    private var mafiaGamesTotal: Int {
        guard let stats = blob["stats"] as? [String: Any],
              let mafia = stats["Mafia"] as? [String: Any] else { return 0 }
        return umGetTotalGames(mafia["all"]) + umGetTotalGames(mafia["unranked"])
    }

    private func load() async {
        // Stale-while-revalidate for prefetched profiles (Z): show the cached copy now,
        // refresh quietly; a failed refresh keeps the cached copy on screen.
        if UMProfileCache.isCached(userId) {
            if blob.isEmpty, let cached = UMProfileCache.cachedProfile(userId) {
                blob = cached
                loading = false
            }
            if !blob.isEmpty {
                if let data = try? await APIClient.shared.request("GET", path: "user/\(userId)/profile", query: [:], body: nil),
                   let fresh = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    UMProfileCache.store(data, for: userId)
                    blob = fresh
                }
                return
            }
        }
        loading = true
        error = nil
        do {
            blob = try await APIClient.shared.userProfile(userId)
        } catch {
            self.error = UMFriendlyError.message(for: error)
        }
        loading = false
    }
}

private let umLinkBlue = Color(red: 104 / 255, green: 169 / 255, blue: 220 / 255)

private func umStatInt(_ any: Any?) -> Int {
    if let n = any as? Int { return n }
    if let n = any as? Double { return Int(n) }
    if let n = any as? NSNumber { return n.intValue }
    return 0
}

/// Same as react_main/src/utils/mafiaStats.js getTotalGames.
private func umGetTotalGames(_ any: Any?) -> Int {
    guard let stats = any as? [String: Any] else { return 0 }
    let wins = stats["wins"] as? [String: Any] ?? [:]
    let abandons = stats["abandons"] as? [String: Any] ?? [:]
    let winsCount = max(0, umStatInt(wins["count"]))
    let winsTotalRaw = max(winsCount, umStatInt(wins["total"]))
    let abandonCount = max(0, umStatInt(abandons["count"]))
    let totalGamesField = max(0, umStatInt(stats["totalGames"]))
    var completed = winsTotalRaw
    if abandonCount > 0, totalGamesField > 0, totalGamesField <= winsTotalRaw {
        completed = max(winsCount, winsTotalRaw - abandonCount)
    }
    return completed + abandonCount
}


struct UMMarkdownView: View {
    var text: String
    /// When set, role names render like in-game chat mentions (yellow + icon, tap for details).
    var roleGameType: String? = nil
    var otherRoles: [String] = []

    @State private var selectedRole: UMRoleMentionItem?
    @State private var spoilersRevealed = false
    @State private var emoteCache = UMInlineEmoteCache.shared

    var body: some View {
        if roleGameType != nil {
            content
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == UMRoleMentionItem.scheme else { return .systemAction }
                    let name = url.host(percentEncoded: false) ?? url.path(percentEncoded: false)
                    selectedRole = UMRoleMentionItem(name: name.removingPercentEncoding ?? name)
                    return .handled
                })
                .sheet(item: $selectedRole) { item in
                    RoleDetailsSheet(roleRaw: item.name, gameType: roleGameType ?? "Mafia", otherRoles: otherRoles)
                }
        } else {
            content
        }
    }

    private var content: some View {
        contentStack
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .text(let s):
                    textBlocks(s)
                case .image(let url, let link):
                    Group {
                        if let link {
                            Link(destination: link) {
                                imageView(url)
                            }
                        } else {
                            imageView(url)
                        }
                    }
                    .id("bioimg:" + url.lastPathComponent)
                }
            }
        }
    }

    private enum Chunk {
        case text(String)
        case image(URL, link: URL?)
    }

    /// Block structure of the site's markdown (react-markdown v8, plain CommonMark, no GFM).
    private enum Block {
        case heading(Int, String)
        /// `marker` is "•" for bullets or "3." for ordered items; `depth` is the nesting level.
        case listItem(marker: String, depth: Int, text: String)
        case paragraph(String, centered: Bool)
        case quote(String)
        case code(String)
        case rule
    }

    @ViewBuilder
    private func textBlocks(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks(from: raw).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    richLine(t, headingLevel: level)
                case .listItem(let marker, let depth, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        richLine(t, headingLevel: nil)
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .paragraph(let t, let centered):
                    if centered {
                        richLine(t, headingLevel: nil, alignment: .center)
                    } else {
                        richLine(t, headingLevel: nil)
                    }
                case .quote(let t):
                    richLine(t, headingLevel: nil)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(UMTheme.muted.opacity(0.6)).frame(width: 3)
                        }
                case .code(let t):
                    Text(t)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                case .rule:
                    Divider().overlay(UMTheme.line)
                }
            }
        }
    }

    @ViewBuilder
    private func imageView(_ url: URL) -> some View {
        AnimatedWebPView(url: url)
            .scaledToFit()
            // Never wider than the column: big uploads otherwise push the whole block off-screen.
            .frame(maxWidth: .infinity, maxHeight: 280, alignment: .leading)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var chunks: [Chunk] {
        let linked = try? NSRegularExpression(pattern: #"\[!\[([^\]]*)\]\(([^)]+)\)\]\(([^)]+)\)"#)
        let bare = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
        guard let linked, let bare else { return [.text(text)] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var marks: [(NSRange, Chunk)] = []
        for match in linked.matches(in: text, range: full) {
            let imgStr = ns.substring(with: match.range(at: 2))
            let hrefStr = ns.substring(with: match.range(at: 3))
            if let img = absoluteUpload(imgStr) {
                marks.append((match.range, .image(img, link: absoluteUpload(hrefStr))))
            }
        }
        for match in bare.matches(in: text, range: full) {
            if marks.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) { continue }
            let imgStr = ns.substring(with: match.range(at: 2))
            if let img = absoluteUpload(imgStr) {
                marks.append((match.range, .image(img, link: nil)))
            }
        }
        marks.sort { $0.0.location < $1.0.location }
        var out: [Chunk] = []
        var cursor = 0
        for (range, chunk) in marks {
            if range.location > cursor {
                let raw = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(.text(raw))
                }
            }
            out.append(chunk)
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            let raw = ns.substring(from: cursor)
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.text(raw))
            }
        }
        return out.isEmpty ? [.text(text)] : out
    }

    // MARK: Block parsing

    private func blocks(from raw: String) -> [Block] {
        let lines = preprocess(raw).components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                i += 1
                out.append(.code(body.joined(separator: "\n")))
                continue
            }
            if isRule(trimmed) { out.append(.rule); i += 1; continue }
            if let heading = parseHeading(trimmed) {
                out.append(.heading(heading.0, heading.1)); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                var parts: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    parts.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(joinSoft(parts)))
                continue
            }
            if let item = parseListItem(trimmed) {
                let depth = indentWidth(line) / 2
                var parts = [item.text]
                var rawParts = [line]
                i += 1
                // Lazy continuation: following non-blank lines that don't start a new block belong to the item.
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || startsBlock(t) { break }
                    parts.append(t); rawParts.append(lines[i]); i += 1
                }
                out.append(.listItem(marker: item.marker, depth: min(depth, 4), text: joinSoft(parts, raw: rawParts)))
                continue
            }
            var parts = [trimmed]
            var rawParts = [line]
            i += 1
            var setext: Int?
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; i += 1; break }
                if t.count >= 2, t.allSatisfy({ $0 == "-" }) { setext = 2; i += 1; break }
                if startsBlock(t) { break }
                parts.append(t); rawParts.append(lines[i]); i += 1
            }
            let text = joinSoft(parts, raw: rawParts)
            if let setext {
                out.append(.heading(setext, text))
            } else if let inner = centeredBody(text) {
                out.append(.paragraph(inner, centered: true))
            } else {
                out.append(.paragraph(text, centered: false))
            }
        }
        return out
    }

    private func startsBlock(_ t: String) -> Bool {
        parseHeading(t) != nil || parseListItem(t) != nil || isRule(t)
            || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    /// CommonMark: a single newline is a soft break (space); two trailing spaces or a trailing
    /// backslash make a hard break.
    private func joinSoft(_ parts: [String], raw: [String]? = nil) -> String {
        var out = ""
        for (idx, part) in parts.enumerated() {
            var p = part
            if idx > 0 {
                let prevRaw = raw?[idx - 1] ?? parts[idx - 1]
                let hard = prevRaw.hasSuffix("  ") || parts[idx - 1].hasSuffix("\\")
                if hard, out.hasSuffix("\\") { out.removeLast() }
                out += hard ? "\n" : " "
            }
            if idx == parts.count - 1, p.hasSuffix("\\"), !p.hasSuffix("\\\\") { p.removeLast() }
            out += p
        }
        return out
    }

    private func indentWidth(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    private func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    private func centeredBody(_ t: String) -> String? {
        guard t.hasPrefix("{center}"), t.hasSuffix("{/center}") else { return nil }
        let inner = String(t.dropFirst(8).dropLast(9))
        return inner.contains("{center}") ? nil : inner
    }

    private func parseHeading(_ s: String) -> (Int, String)? {
        guard s.hasPrefix("#") else { return nil }
        var n = 0
        for ch in s {
            if ch == "#" { n += 1 } else { break }
        }
        guard n >= 1, n <= 6 else { return nil }
        let rest = s.dropFirst(n)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var body = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing #s.
        while body.hasSuffix("#") { body.removeLast() }
        return (n, body.trimmingCharacters(in: .whitespaces))
    }

    private func parseListItem(_ s: String) -> (marker: String, text: String)? {
        for prefix in ["- ", "* ", "+ "] where s.hasPrefix(prefix) {
            return ("•", String(s.dropFirst(prefix.count)))
        }
        var i = s.startIndex
        var digits = ""
        while i < s.endIndex, s[i].isASCII, s[i].isNumber, digits.count < 9 {
            digits.append(s[i])
            i = s.index(after: i)
        }
        guard !digits.isEmpty, i < s.endIndex, s[i] == "." || s[i] == ")" else { return nil }
        let after = s.index(after: i)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return ("\(Int(digits) ?? 1).", String(s[s.index(after: after)...]))
    }

    // MARK: Inline rendering

    /// One wrapping `Text`: emotes and role icons are inline images inside the text run, so long
    /// lines wrap normally (separate image views in a flow layout made each text piece one
    /// unwrapped line, which ran off-screen).
    private func richLine(_ s: String, headingLevel: Int?, alignment: TextAlignment = .leading) -> some View {
        richText(s, headingLevel: headingLevel)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
            .onTapGesture { if s.contains("||") { spoilersRevealed.toggle() } }
    }

    private func richText(_ s: String, headingLevel: Int?) -> Text {
        var out = Text("")
        for part in umStrictEmoteParts(s) {
            switch part {
            case .emote(let info):
                let image = emoteCache.image(for: info.url)
                out = Text("\(out)\(Text(Image(uiImage: image)).baselineOffset(-4))")
            case .text(let t):
                for seg in styleSegments(t) {
                    var attr = styledInline(seg.text, headingLevel: headingLevel)
                    applyStyle(seg.style, to: &attr)
                    let piece = (roleGameType.map { umRoleMentionText(attr, gameType: $0) }) ?? Text(attr)
                    out = Text("\(out)\(piece)")
                }
            }
        }
        return out
    }

    private enum InlineStyle {
        case plain
        case color(Color)
        case size(CGFloat)
        case spoiler
        case mention
    }

    /// Splits the site's custom inline tokens: ||spoiler||, {color:#hex}…{/color},
    /// {size:N}…{/size}, inline {center}…{/center}, and @!Tag / @:User pings.
    private func styleSegments(_ s: String) -> [(text: String, style: InlineStyle)] {
        let pattern = #"\|\|(.+?)\|\||\{color:([^}]+)\}(.+?)\{/color\}|\{size:([^}]+)\}(.+?)\{/size\}|\{center\}(.+?)\{/center\}|@[!:]([\w-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [(s, .plain)] }
        let ns = s as NSString
        var out: [(String, InlineStyle)] = []
        var cursor = 0
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out.append((ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), .plain))
            }
            if let t = group(m, 1) {
                out.append((t, .spoiler))
            } else if let c = group(m, 2), let t = group(m, 3) {
                out.append((t, umHexColor(c.trimmingCharacters(in: .whitespaces)).map { .color($0) } ?? .plain))
            } else if let z = group(m, 4), let t = group(m, 5) {
                let n = Int(z.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: ""))
                out.append((t, n.map { .size(CGFloat(max(8, min(72, $0)))) } ?? .plain))
            } else if let t = group(m, 6) {
                out.append((t, .plain))
            } else if let name = group(m, 7) {
                out.append(("@" + name, .mention))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out.append((ns.substring(from: cursor), .plain)) }
        return out.isEmpty ? [(s, .plain)] : out
    }

    private func applyStyle(_ style: InlineStyle, to attr: inout AttributedString) {
        switch style {
        case .plain:
            break
        case .color(let c):
            for run in attr.runs where run.link == nil { attr[run.range].foregroundColor = c }
        case .size(let pt):
            attr.font = .system(size: pt)
        case .spoiler:
            if !spoilersRevealed {
                attr.foregroundColor = UMTheme.blood
                attr.backgroundColor = UMTheme.blood
            } else {
                attr.backgroundColor = Color.white.opacity(0.08)
            }
        case .mention:
            attr.inlinePresentationIntent = .stronglyEmphasized
            attr.foregroundColor = umLinkBlue
        }
    }

    private func styledInline(_ s: String, headingLevel: Int?) -> AttributedString {
        if let level = headingLevel {
            return headingMarkdown(s, level: level)
        }
        return inlineMarkdown(s)
    }

    private func headingMarkdown(_ s: String, level: Int) -> AttributedString {
        var attr = inlineMarkdown(s)
        let size: CGFloat
        switch level {
        case 1: size = 28
        case 2: size = 22
        case 3: size = 20
        case 4: size = 17
        default: size = 15
        }
        let font = Font.system(size: size, weight: .bold)
        let runs = Array(attr.runs)
        for run in runs {
            attr[run.range].font = font
        }
        return attr
    }

    private func inlineMarkdown(_ s: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let parsed: AttributedString
        if let attr = try? AttributedString(markdown: s, options: options) {
            parsed = attr
        } else {
            parsed = AttributedString(s)
        }
        return paint(parsed)
    }

    /// Normalizes incoming content: CRLF/CR newlines, tabs, zero-width/nbsp noise, and raw HTML.
    /// The site (react-markdown without rehype-raw) never renders HTML, so tags are dropped
    /// here; `<br>` becomes a line break and `<p>`/`<div>` boundaries become paragraph breaks.
    private func preprocess(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\u{FEFF}", with: "")
        t = umRegexReplace(t, #"(?i)<br\s*/?>"#, "  \n")
        t = umRegexReplace(t, #"(?i)</?(p|div)(\s[^>]*)?>"#, "\n\n")
        t = umRegexReplace(t, #"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>"#, "")
        t = umRegexReplace(t, #"<!--.*?-->"#, "")
        return t
    }

    private func paint(_ source: AttributedString) -> AttributedString {
        var out = source
        let runs = Array(out.runs)
        for run in runs {
            let range = run.range
            if let url = run.link {
                out[range].link = resolveUMURL(url)
                out[range].foregroundColor = umLinkBlue
                out[range].underlineStyle = .single
            } else if out[range].foregroundColor == nil {
                out[range].foregroundColor = .white
            }
        }
        return out
    }

    private func resolveUMURL(_ url: URL) -> URL {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "mailto" {
            return url
        }
        let base = URL(string: "\(UMConfig.site)/")!
        if let abs = URL(string: url.relativeString, relativeTo: base)?.absoluteURL {
            return abs
        }
        return url
    }

    private func absoluteUpload(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(string: "\(UMConfig.site)" + s) }
        return URL(string: "\(UMConfig.site)/" + s)
    }
}

private func umRegexReplace(_ source: String, _ pattern: String, _ template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return source
    }
    let range = NSRange(source.startIndex..., in: source)
    return re.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: template)
}

private func umDictInt(_ obj: [String: Any], _ key: String) -> Int {
    if let n = obj[key] as? Int { return n }
    if let n = obj[key] as? Double { return Int(n) }
    if let n = obj[key] as? NSNumber { return n.intValue }
    if let s = obj[key] as? String, let n = Int(s) { return n }
    return 0
}

private func umDictBool(_ obj: [String: Any], _ key: String) -> Bool {
    if let b = obj[key] as? Bool { return b }
    if let n = obj[key] as? NSNumber { return n.boolValue }
    if let s = obj[key] as? String { return s == "true" || s == "1" }
    return false
}

private func umDictString(_ obj: [String: Any], _ key: String) -> String {
    if let s = obj[key] as? String { return s }
    if let n = obj[key] as? NSNumber { return n.stringValue }
    return ""
}

private func umCommentId(_ comment: [String: Any]) -> String {
    umDictString(comment, "id")
}

struct ProfileCommentsView: View {
    var location: String
    @Environment(AppModel.self) private var app

    @State private var comments: [[String: Any]] = []
    @State private var page = 1
    @State private var maxPage = 1
    @State private var loading = true
    @State private var draft = ""
    @State private var error: String?
    @State private var posting = false

    private let emotes = ["👍", "😂", "❤️", "🔥", "💀", "👀", "🎉", "😢"]
    private let siteReact = [":)", ":(", "<3", ":star:", ":fufu:", ":doge:", ":bump:", ":rawr:", ":zzz:"]

    var body: some View {
        umBody.umKeyboardDismissBar()
    }

    @ViewBuilder private var umBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments")
                .font(.headline)
                .foregroundStyle(.white)
            if loading {
                ProgressView()
                    .tint(UMTheme.blood)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if comments.isEmpty {
                Text("No comments yet.")
                    .font(.subheadline)
                    .foregroundStyle(UMTheme.muted)
            } else {
                ForEach(Array(comments.enumerated()), id: \.offset) { index, comment in
                    commentCard(comment, index: index)
                }
            }
            if !loading, maxPage > 1 {
                HStack {
                    Button("Prev") {
                        Task { await load(page: page - 1) }
                    }
                    .disabled(page <= 1)
                    Spacer()
                    Text("Page \(page) of \(maxPage)")
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                    Spacer()
                    Button("Next") {
                        Task { await load(page: page + 1) }
                    }
                    .disabled(page >= maxPage)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(UMTheme.blood)
            }
            if app.isSignedIn {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Write a comment", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(8)
                        .background(UMTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                    Button("Post") {
                        Task { await post() }
                    }
                    .disabled(posting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(UMTheme.blood)
                    .font(.subheadline.weight(.semibold))
                }
            } else {
                Text("Sign in to comment.")
                    .font(.caption)
                    .foregroundStyle(UMTheme.muted)
            }
        }
        .task(id: location) { await load(page: 1) }
    }

    private func commentCard(_ comment: [String: Any], index: Int) -> some View {
        let author = comment["author"] as? [String: Any] ?? [:]
        let authorId = umDictString(author, "id")
        let vanity = umDictString(author, "vanityUrl")
        let authorName = {
            let n = umDictString(author, "name")
            return n.isEmpty ? "[deleted]" : n
        }()
        let navId = vanity.isEmpty ? authorId : vanity
        let vote = umDictInt(comment, "vote")
        let voteCount = umDictInt(comment, "voteCount")
        let deleted = umDictBool(comment, "deleted")
        let reactions = (comment["reactions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Button {
                    Task { await voteComment(index: index, direction: 1) }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(vote == 1 ? UMTheme.blood : UMTheme.muted)
                }
                .buttonStyle(.plain)
                Text("\(voteCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(vote == 1 ? UMTheme.blood : (vote == -1 ? UMTheme.muted : .white))
                Button {
                    Task { await voteComment(index: index, direction: -1) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(vote == -1 ? UMTheme.muted : Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    UMAvatarView(
                        userId: authorId.isEmpty ? nil : authorId,
                        hasAvatar: umDictBool(author, "avatar"),
                        name: authorName,
                        size: 28
                    )
                    Button(authorName) {
                        if !navId.isEmpty {
                            app.openProfile(id: navId, name: authorName)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    if let ago = relativeTime(comment["date"]) {
                        Text(ago)
                            .font(.caption)
                            .foregroundStyle(UMTheme.muted)
                    }
                }
                if deleted {
                    UMMarkdownView(text: "*deleted*")
                } else {
                    UMMarkdownView(text: umDictString(comment, "content"))
                }
                HStack(spacing: 6) {
                    ForEach(Array(reactions.enumerated()), id: \.offset) { _, row in
                        let emote = umDictString(row, "emote")
                        let count = umDictInt(row, "count")
                        let mine = umDictBool(row, "mine")
                        Button {
                            Task { await react(index: index, emote: emote, kind: umDictString(row, "emoteKind"), path: umDictString(row, "emotePath")) }
                        } label: {
                            HStack(spacing: 4) {
                                UMEmoteView(token: emote, kind: umDictString(row, "emoteKind"), path: umDictString(row, "emotePath"), size: 16)
                                Text("\(count)")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(mine ? UMTheme.blood.opacity(0.35) : UMTheme.elevated, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Menu {
                        ForEach(emotes, id: \.self) { emote in
                            Button(emote) {
                                Task { await react(index: index, emote: emote, kind: "unicode") }
                            }
                        }
                        Divider()
                        ForEach(siteReact, id: \.self) { emote in
                            Button(emote) {
                                Task { await react(index: index, emote: emote, kind: "site") }
                            }
                        }
                    } label: {
                        Text("+")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(UMTheme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(UMTheme.elevated, in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func load(page newPage: Int) async {
        let target = max(1, newPage)
        if comments.isEmpty { loading = true }
        error = nil
        do {
            let result = try await APIClient.shared.comments(location: location, page: target)
            comments = result.comments
            maxPage = result.maxPage
            page = result.page
        } catch {
            self.error = UMFriendlyError.message(for: error)
        }
        loading = false
    }

    private func post() async {
        let text = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !text.isEmpty else { return }
        posting = true
        error = nil
        do {
            try await APIClient.shared.postComment(content: text, location: location)
            draft = ""
            await load(page: 1)
        } catch {
            self.error = UMFriendlyError.message(for: error)
        }
        posting = false
    }

    private func voteComment(index: Int, direction: Int) async {
        guard comments.indices.contains(index) else { return }
        let id = umCommentId(comments[index])
        guard !id.isEmpty else { return }
        let old = umDictInt(comments[index], "vote")
        do {
            let newVote = try await APIClient.shared.voteItem(item: id, itemType: "comment", direction: direction)
            guard let idx = comments.firstIndex(where: { umCommentId($0) == id }) else { return }
            var row = comments[idx]
            var count = umDictInt(row, "voteCount")
            if old == 0 {
                count += direction
            } else if old == direction {
                count -= direction
            } else {
                count += 2 * direction
            }
            row["vote"] = newVote
            row["voteCount"] = count
            comments[idx] = row
        } catch {}
    }

    private func react(index: Int, emote: String, kind: String = "", path: String = "") async {
        guard comments.indices.contains(index) else { return }
        let id = umCommentId(comments[index])
        guard !id.isEmpty, !emote.isEmpty else { return }
        let resolvedKind: String = {
            if !kind.isEmpty { return kind }
            if UMEmotes.info(for: emote) != nil { return "site" }
            return "unicode"
        }()
        do {
            let reactions = try await APIClient.shared.reactItem(item: id, itemType: "comment", emote: emote, emoteKind: resolvedKind, emotePath: path)
            guard let idx = comments.firstIndex(where: { umCommentId($0) == id }) else { return }
            var row = comments[idx]
            row["reactions"] = reactions
            comments[idx] = row
        } catch {}
    }

    private func relativeTime(_ raw: Any?) -> String? {
        let ms: Double?
        if let n = raw as? Double { ms = n }
        else if let n = raw as? Int { ms = Double(n) }
        else if let n = raw as? NSNumber { ms = n.doubleValue }
        else if let s = raw as? String, let n = Double(s) { ms = n }
        else { ms = nil }
        guard let ms, ms > 0 else { return nil }
        let sec = ms > 10_000_000_000 ? ms / 1000 : ms
        let elapsed = max(0, Int(Date().timeIntervalSince(Date(timeIntervalSince1970: sec))))
        if elapsed < 60 { return "\(max(elapsed, 1))s ago" }
        let m = elapsed / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        if d < 7 { return "\(d)d ago" }
        let w = d / 7
        if w < 52 { return "\(w)w ago" }
        return "\(d / 365)y ago"
    }
}

struct ProfileMediaEmbed: View {
    var raw: String
    var autoplay: Bool

    var body: some View {
        if let id = youtubeId(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            #if canImport(WebKit)
            ProfileWebEmbed(html: youtubeHTML(id: id, autoplay: autoplay))
            #else
            if let url = URL(string: "https://www.youtube.com/embed/\(id)") {
                Link(url.absoluteString, destination: url)
            }
            #endif
        } else if let url = embedURL {
            #if canImport(WebKit)
            ProfileWebEmbed(url: url)
            #else
            Link(url.absoluteString, destination: url)
            #endif
        } else if let url = URL(string: raw), isDirect(url) {
            ProfileAudioBar(url: url)
        } else if let url = URL(string: raw) {
            Link("Open media", destination: url)
                .foregroundStyle(UMTheme.blood)
        }
    }

    private var embedURL: URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("open.spotify.com"), let u = URL(string: s.replacingOccurrences(of: "/track/", with: "/embed/track/").replacingOccurrences(of: "/album/", with: "/embed/album/").replacingOccurrences(of: "/playlist/", with: "/embed/playlist/")) {
            return u
        }
        if s.contains("soundcloud.com") {
            let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            return URL(string: "https://w.soundcloud.com/player/?url=\(enc)&visual=true")
        }
        if s.contains("vimeo.com") {
            let id = s.split(separator: "/").last.map(String.init) ?? ""
            if !id.isEmpty { return URL(string: "https://player.vimeo.com/video/\(id)?playsinline=1") }
        }
        return nil
    }

    private func isDirect(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "ogg", "wav", "m4a", "mp4", "webm"].contains(ext)
    }

    private func youtubeId(_ s: String) -> String? {
        let patterns = [
            #"youtu\.be/([A-Za-z0-9_-]{6,})"#,
            #"[?&]v=([A-Za-z0-9_-]{6,})"#,
            #"youtube\.com/embed/([A-Za-z0-9_-]{6,})"#,
            #"youtube\.com/shorts/([A-Za-z0-9_-]{6,})"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                return String(s[r])
            }
        }
        return nil
    }

    private func youtubeHTML(id: String, autoplay: Bool) -> String {
        // Desktop: autoplay=0|1 and mute=0. iOS often still starts muted; unmuted autoplay is not reliable.
        var src = "https://www.youtube.com/embed/\(id)?playsinline=1&rel=0&modestbranding=1&origin=\(UMConfig.site)"
        src += "&autoplay=\(autoplay ? 1 : 0)&mute=0"
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(src)"
          referrerpolicy="origin"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          allowfullscreen></iframe>
        </body></html>
        """
    }
}

private struct ProfileAudioBar: View {
    var url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                UMAudioSession.activatePlayback()   // mix with the user's own music
                player = AVPlayer(playerItem: AVPlayerItem(asset: UMAccess.asset(url)))
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

#if canImport(WebKit)
private struct ProfileWebEmbed: UMViewRepresentable {

    #if os(macOS)
    typealias NSViewType = WKWebView
    #endif
    var html: String? = nil
    var url: URL? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(macOS)
        let web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = .black
        #else
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #endif
        load(into: web, context: context)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        load(into: web, context: context)
    }

    private func load(into web: WKWebView, context: Context) {
        if let html {
            guard context.coordinator.lastHTML != html else { return }
            context.coordinator.lastHTML = html
            context.coordinator.lastURL = nil
            web.loadHTMLString(html, baseURL: URL(string: "\(UMConfig.site)/"))
        } else if let url {
            guard context.coordinator.lastURL != url else { return }
            context.coordinator.lastURL = url
            context.coordinator.lastHTML = nil
            var req = UMAccess.request(url)
            req.setValue("\(UMConfig.site)/", forHTTPHeaderField: "Referer")
            web.load(req)
        }
    }

    final class Coordinator {
        var lastHTML: String?
        var lastURL: URL?
    }
}
#endif

/// Hidden on Z's profile, shown only when Z is signed in (Debug and Release).
struct UMBackendSwitch: View {
    @Environment(AppModel.self) private var app
    @State private var pending: UMBackend?
    @State private var cfId = UMAccess.clientId ?? ""
    @State private var cfSecret = ""
    @State private var cfSaved = UMAccess.isSet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backend").font(.headline)
            ForEach(UMBackend.allCases) { b in
                Button { if b != UMConfig.backend { pending = b } } label: {
                    HStack {
                        Text(b.rawValue + (b == .com ? " (default)" : ""))
                        Spacer()
                        if b == UMConfig.backend { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            Text("Switching disconnects, keeps a separate session per host, and reloads.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Cloudflare Access (.gg only)").font(.subheadline.bold())
            TextField("CF-Access-Client-Id", text: $cfId)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
            SecureField("CF-Access-Client-Secret", text: $cfSecret)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
            HStack {
                Button("Save") { UMAccess.save(id: cfId, secret: cfSecret); cfSecret = ""; cfSaved = UMAccess.isSet }
                    .disabled(cfId.trimmingCharacters(in: .whitespaces).isEmpty || cfSecret.isEmpty)
                Button("Clear", role: .destructive) { UMAccess.clear(); cfId = ""; cfSecret = ""; cfSaved = false }
                    .disabled(!cfSaved)
                Spacer()
                Text(cfSaved ? "Saved in Keychain" : "Not set").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .confirmationDialog("Switch backend to \(pending?.rawValue ?? "")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Switch") { if let b = pending { Task { await app.switchBackend(b) } }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }
}

/// Small badge while on a non-.com backend: for Z, or on the sign-in screen (tap returns to .com).
struct UMBackendBadge: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if UMConfig.backend != .com, app.user == nil || app.user?.id == UMProfileCache.devUserId {
            Button {
                if app.user == nil { Task { await app.switchBackend(.com) } }
            } label: {
                Text(UMConfig.host + (app.user == nil ? "  \u{2715}" : ""))
                    .font(.caption2.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.85))).foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel("Backend \(UMConfig.host)")
        }
    }
}
