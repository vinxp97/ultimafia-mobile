import Foundation

/// Text for a quoted chat line, laid out as a header line ("Name on Day 2:") above the quoted text.
enum QuoteFormat {
    /// "Name on Phase:" or "Name:" (web: `${senderName} on ${fromStateName}: `).
    static func header(name: String?, phase: String?) -> String {
        let who = (name?.isEmpty == false) ? name! : "Anonymous"
        if let phase, !phase.isEmpty { return "\(who) on \(phase):" }
        return "\(who):"
    }

    /// Quoted text with the closing mark after its last word, like the web's inline
    /// fa-quote-right. A plain space keeps a trailing emote, sticker, link or mention its own
    /// token for EmoteText. Inner newlines are kept so multi-line quotes stay line after line.
    static func body(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\u{201D}" : trimmed + " \u{201D}"
    }
}
