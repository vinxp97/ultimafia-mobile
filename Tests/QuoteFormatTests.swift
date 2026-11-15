// swiftc -parse-as-library Tests/QuoteFormatTests.swift Ultimafia/Features/Game/QuoteFormat.swift
import Foundation

@main
struct QuoteFormatTests {
    static var failures = 0
    static func equal(_ got: String, _ expected: String, _ what: String) {
        if got != expected { failures += 1; print("FAIL:", what, "(got \(got.debugDescription), expected \(expected.debugDescription))") }
    }

    static func main() {
        equal(QuoteFormat.header(name: "Z", phase: "Day 2"), "Z on Day 2:", "header with phase")
        equal(QuoteFormat.header(name: "User", phase: "pregame"), "User on pregame:", "pregame header")
        equal(QuoteFormat.header(name: "Z", phase: ""), "Z:", "empty phase")
        equal(QuoteFormat.header(name: nil, phase: "Night 1"), "Anonymous on Night 1:", "anonymous")
        equal(QuoteFormat.header(name: "", phase: nil), "Anonymous:", "empty name")
        equal(QuoteFormat.body("hello"), "hello \u{201D}", "closing mark")
        equal(QuoteFormat.body("  hi there \n"), "hi there \u{201D}", "trims edges")
        equal(QuoteFormat.body("one\ntwo\nthree"), "one\ntwo\nthree \u{201D}", "keeps line breaks")
        equal(QuoteFormat.body("look :gun:"), "look :gun: \u{201D}", "trailing emote stays its own word")
        equal(QuoteFormat.body(""), "\u{201D}", "empty")
        if failures == 0 { print("QuoteFormatTests: all passed") } else { print("QuoteFormatTests: \(failures) failed"); exit(1) }
    }
}
