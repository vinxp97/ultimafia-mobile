@main
struct NativeTabItemTests {
    static func main() {
        let sections = UMAppSection.allCases
        precondition(sections == [.play, .leaderboard, .messages, .game, .you],
                     "Sections are fixed and ordered: nothing may be added, removed or reordered")
        print("PASS: five sections, always present, always in the same order")

        precondition(sections.map(\.title) == ["Lobby", "Leaderboard", "Messages", "Game", "You"],
                     "One short label per tab")
        precondition(Set(sections.map(\.title)).count == sections.count, "Tab labels are unique")
        print("PASS: one short, unique label per section")

        precondition(sections.map(\.symbol) == ["list.bullet.rectangle", "chart.bar.xaxis", "bubble.left.and.bubble.right", "gamecontroller", "person"],
                     "Every section names an SF Symbol")
        print("PASS: every section names an SF Symbol for its tab item")

        precondition(Set(sections.map(\.rawValue)).count == sections.count, "Raw values are unique")
        precondition(UMAppSection(rawValue: "leave") == nil, "Leave is an action, not a section")
        precondition(UMAppSection(rawValue: "back") == nil, "Back is navigation, not a section")
        precondition(UMAppSection(rawValue: "host") == nil, "Hosting is a lobby route, not a section")
        print("PASS: raw values are unique and no action can be selected as a section")
    }
}
