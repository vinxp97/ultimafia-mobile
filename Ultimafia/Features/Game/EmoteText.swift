import SwiftUI

struct FlowWrap: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (sub, item) in zip(subviews, result.items) {
            sub.place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private struct Item {
        var origin: CGPoint
        var size: CGSize
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, items: [Item]) {
        let width = maxWidth > 0 ? maxWidth : .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxX: CGFloat = 0
        var items: [Item] = []
        var rowStart = 0
        func centerRow() {
            for i in rowStart..<items.count { items[i].origin.y = y + (rowH - items[i].size.height) / 2 }
        }
        for sub in subviews {
            let available = width.isFinite ? max(width - x, 0) : .infinity
            // Natural (single-line) width decides the row: proposing only the leftover width
            // made text wrap inside a narrow column beside the previous piece.
            let ideal = sub.sizeThatFits(.unspecified)
            var size = sub.sizeThatFits(ProposedViewSize(width: available, height: nil))
            if x > 0, width.isFinite, ideal.width > available + 0.5 {
                centerRow()
                rowStart = items.count
                y += rowH + spacing
                x = 0
                rowH = 0
                size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            items.append(Item(origin: CGPoint(x: x, y: y), size: size))
            maxX = max(maxX, x + size.width)
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        centerRow()
        let usedWidth = width.isFinite ? width : maxX
        return (CGSize(width: usedWidth, height: y + rowH), items)
    }
}

struct EmoteText: View {
    let text: String
    var color: Color = .white
    var italic: Bool = false
    var customEmotes: [String: String] = [:]
    var customStickers: [String: String] = [:]
    var system: Bool = false
    var emoteSize: CGFloat = 20
    var players: [GamePlayer] = []
    var gameType: String = ""
    var otherRoles: [String] = []
    var roleColor: Color = UMTheme.roleMention
    /// Body font override (reply previews draw the original line smaller); nil = .body.
    var textFont: Font? = nil
    private var baseFont: Font { italic ? (textFont ?? .body).italic() : (textFont ?? .body) }

    @State private var selectedRole: MentionedRole?
    @State private var selectedTerm: UMTerminology.Term?
    @AppStorage("um.hideTerminology") private var hideTerminology = false

    private struct MentionedRole: Identifiable {
        var id: String { name }
        var name: String
    }

    private struct Piece: Identifiable {
        let id: Int
        let text: String?
        let url: URL?
        let large: Bool
        var sticker: Bool = false
        let player: GamePlayer?
        let role: String?
    }

    var body: some View {
        let catalog = RoleCatalog.shared
        let _ = catalog.isReady
        let _ = UMTerminology.shared.version
        let segments = Self.segments(tokenize())
        FlowWrap(spacing: 3) {
            ForEach(segments) { seg in
                if seg.pieces.count == 1, seg.pieces[0].text == nil || seg.pieces[0].player != nil {
                    pieceView(seg.pieces[0])
                } else {
                    runText(seg.pieces)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            let key = (url.host(percentEncoded: false) ?? url.host ?? "")
            let name = key.removingPercentEncoding ?? key
            if url.scheme == UMTermSheet.scheme, let term = UMTerminology.shared.term(name) {
                selectedTerm = term
                return .handled
            }
            if url.scheme == UMRoleMentionItem.scheme, !name.isEmpty {
                selectedRole = MentionedRole(name: name)
                return .handled
            }
            return .systemAction
        })
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .sheet(item: $selectedTerm) { term in
            UMTermSheet(term: term)
        }
        .sheet(item: $selectedRole) { mention in
            RoleDetailsSheet(
                roleRaw: mention.name,
                gameType: gameType.isEmpty ? "Mafia" : gameType,
                otherRoles: otherRoles
            )
        }
    }

    /// Consecutive text and role pieces render as ONE Text so a message wraps as a single
    /// paragraph; only avatars, emotes and stickers stay separate views in the flow.
    private struct Segment: Identifiable {
        let id: Int
        var pieces: [Piece]
    }

    private static func segments(_ pieces: [Piece]) -> [Segment] {
        var out: [Segment] = []
        var run: [Piece] = []
        func flush() {
            if !run.isEmpty { out.append(Segment(id: out.count, pieces: run)); run = [] }
        }
        for p in pieces {
            if p.player == nil, p.url == nil {
                run.append(p)
            } else {
                flush()
                out.append(Segment(id: out.count, pieces: [p]))
            }
        }
        flush()
        return out
    }

    private func runText(_ pieces: [Piece]) -> Text {
        let type = gameType.isEmpty ? "Mafia" : gameType
        let base: Font = baseFont
        var out = Text("")
        for p in pieces {
            if let role = p.role {
                if let icon = umRoleIconImage(role, gameType: type, side: max(14, emoteSize - 2)) {
                    out = Text("\(out)\(Text(Image(uiImage: icon)).baselineOffset(-3))\u{00A0}")
                }
                var attr = AttributedString(p.text ?? role)
                let encoded = role.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? role
                attr.link = URL(string: "\(UMRoleMentionItem.scheme)://\(encoded)")
                attr.foregroundColor = roleColor
                out = Text("\(out)\(Text(attr).font(base.weight(.semibold)).foregroundColor(roleColor))")
            } else {
                out = Text("\(out)\(termText(p.text ?? "").font(base).foregroundColor(color))")
            }
        }
        return out
    }

    @ViewBuilder
    private func pieceView(_ piece: Piece) -> some View {
        if let player = piece.player {
            UMAvatarView(player: player, size: emoteSize)
                .offset(y: -1)
        } else if let role = piece.role {
            Button {
                selectedRole = MentionedRole(name: role)
            } label: {
                HStack(spacing: 3) {
                    RoleIconView(role: role, gameType: gameType.isEmpty ? "Mafia" : gameType, size: max(14, emoteSize - 2))
                    Text(piece.text ?? role)
                        .font(baseFont.weight(.semibold))
                        .foregroundStyle(roleColor)
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
        } else if let url = piece.url {
            AnimatedWebPView(url: url, showsPlaceholder: false, fitHeight: piece.sticker ? Self.stickerHeight : (piece.large ? 28 : emoteSize))
                .fixedSize()
        } else {
            termText(piece.text ?? "")
                .font(baseFont)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == UMTermSheet.scheme,
                          let key = url.host(percentEncoded: false) ?? url.host,
                          let term = UMTerminology.shared.term(key.removingPercentEncoding ?? key) else { return .systemAction }
                    selectedTerm = term
                    return .handled
                })
        }
    }

    /// Chat text with game terms dotted-underlined and tappable (web slangify: player chat only,
    /// so system/newspaper text is left alone). Player names and links are never matched.
    private func termText(_ s: String) -> Text {
        guard !system, !hideTerminology else { return Text(s) }
        let names = Set(players.map { $0.name.lowercased() })
        let hits = UMTerminology.shared.matches(in: s, excluded: names)
        guard !hits.isEmpty else { return Text(s) }
        var attr = AttributedString(s)
        for hit in hits {
            guard let lo = AttributedString.Index(hit.range.lowerBound, within: attr),
                  let hi = AttributedString.Index(hit.range.upperBound, within: attr) else { continue }
            let encoded = hit.key.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? hit.key
            attr[lo..<hi].link = URL(string: "\(UMTermSheet.scheme)://\(encoded)")
            attr[lo..<hi].underlineStyle = Text.LineStyle(pattern: .dot, color: nil)
            attr[lo..<hi].foregroundColor = color
        }
        return Text(attr)
    }

    private func tokenize() -> [Piece] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let emoteOnly = !words.isEmpty && words.allSatisfy { $0.isEmpty || mediaURL(for: $0) != nil }
        var out: [Piece] = []
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            appendText(buffer, to: &out)
            buffer = ""
        }
        for (i, word) in words.enumerated() {
            if word.isEmpty {
                buffer += (i == words.count - 1 ? "" : " ")
                continue
            }
            if let player = percentPlayer(for: word) {
                flush()
                out.append(Piece(id: out.count, text: nil, url: nil, large: false, player: player, role: nil))
            } else if let url = mediaURL(for: word) {
                flush()
                out.append(Piece(id: out.count, text: nil, url: url, large: emoteOnly, sticker: isSticker(word), player: nil, role: nil))
            } else {
                if !buffer.isEmpty { buffer += " " }
                buffer += word
            }
        }
        flush()
        return out
    }

    private func appendText(_ s: String, to out: inout [Piece]) {
        let type = gameType.isEmpty ? "Mafia" : gameType
        let hits = RoleCatalog.shared.mentions(in: s, gameType: type)
        if hits.isEmpty {
            out.append(Piece(id: out.count, text: s, url: nil, large: false, player: nil, role: nil))
            return
        }
        var cursor = s.startIndex
        for hit in hits {
            if cursor < hit.range.lowerBound {
                out.append(Piece(id: out.count, text: String(s[cursor..<hit.range.lowerBound]), url: nil, large: false, player: nil, role: nil))
            }
            out.append(Piece(id: out.count, text: String(s[hit.range]), url: nil, large: false, player: nil, role: hit.name))
            cursor = hit.range.upperBound
        }
        if cursor < s.endIndex {
            out.append(Piece(id: out.count, text: String(s[cursor...]), url: nil, large: false, player: nil, role: nil))
        }
    }

    private func percentPlayer(for word: String) -> GamePlayer? {
        guard word.count > 1, word.hasPrefix("%") else { return nil }
        let name = String(word.dropFirst())
        if let exact = players.first(where: { $0.name == name }) { return exact }
        let lower = name.lowercased()
        let hits = players.filter { $0.name.lowercased() == lower }
        return hits.count == 1 ? hits[0] : nil
    }

    /// About four lines of chat body text.
    static var stickerHeight: CGFloat {
        #if canImport(UIKit)
        return (UIFont.preferredFont(forTextStyle: .body).lineHeight * 4).rounded()
        #else
        return 80
        #endif
    }

    /// Site emotes win over stickers (matches web), so only a non-site token found in stickers counts.
    private func isSticker(_ word: String) -> Bool {
        let token = word.lowercased()
        return !system && UMSiteEmote.url(forToken: token) == nil && customStickers[token] != nil
    }

    private func mediaURL(for word: String) -> URL? {
        let token = word.lowercased()
        if let url = UMSiteEmote.url(forToken: token) { return url }
        if system { return nil }
        if let path = customStickers[token] ?? customEmotes[token] {
            return UMMediaURL.resolve(path)
        }
        return nil
    }
}

extension UMTerminology.Term: Identifiable { var id: String { key } }

struct UMTermSheet: View {
    static let scheme = "umterm"
    let term: UMTerminology.Term
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(term.definition)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(UMTheme.bg.ignoresSafeArea())
            .navigationTitle(term.key)
            .umInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.fraction(0.3), .medium])
    }
}
