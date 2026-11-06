import ActivityKit
import SwiftUI
import WidgetKit

private let blood = Color(red: 0.78, green: 0.13, blue: 0.13)
private let kickRed = Color(red: 0.93, green: 0.2, blue: 0.2)
private let dayGold = Color(red: 0.98, green: 0.78, blue: 0.25)
private let readyGreen = Color(red: 0.3, green: 0.85, blue: 0.4)
private let nightBlue = Color(red: 0.55, green: 0.65, blue: 1.0)

struct GameLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UMGameActivityAttributes.self) { context in
            GameActivityLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseLabel(state: s).font(.headline).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.isPregame {
                        PregameCount(state: s).font(.headline).padding(.trailing, 4)
                    } else {
                        ClockRing(state: s, lineWidth: 4)
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.setupName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !s.isPregame {
                    HStack {
                        if s.atKicks {
                            Label("At kicks", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(kickRed)
                        }
                        Spacer()
                        CountdownText(state: s)
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(s.atKicks ? kickRed : .white)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 6)
                    }
                }
            } compactLeading: {
                PhaseIcon(state: s)
            } compactTrailing: {
                if s.isPregame {
                    PregameCount(state: s)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    // Prefer countdown+ring; if the trailing slot is too narrow (Duo vertical
                    // island), drop the ring before the digits so "m:ss" / "mm:ss" stay readable.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            CountdownText(state: s)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(s.atKicks ? kickRed : .white)
                            ClockRing(state: s, lineWidth: 2.5)
                                .frame(width: 14, height: 14)
                                .fixedSize()
                        }
                        CountdownText(state: s)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(s.atKicks ? kickRed : .white)
                    }
                }
            } minimal: {
                if s.isPregame || s.isReadyCheck {
                    PhaseIcon(state: s)
                } else {
                    ClockRing(state: s, lineWidth: 2.5).padding(2)
                }
            }
            .keylineTint(s.atKicks ? kickRed : blood)
        }
    }
}

struct GameActivityLockScreenView: View {
    let attributes: UMGameActivityAttributes
    let state: UMGameActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            if state.isPregame {
                // Ultimafia hat (copied from the app's AppLogo; widgets can't read the app's assets).
                Image("HatLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
            } else {
                ClockRing(state: state, lineWidth: 5)
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 2) {
                PhaseLabel(state: state).font(.headline)
                Text(attributes.setupName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if state.atKicks {
                    Text("At kicks")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(kickRed)
                }
            }
            Spacer()
            if state.isPregame {
                PregameCount(state: state).font(.title.weight(.semibold))
            } else {
                CountdownText(state: state)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.atKicks ? kickRed : .white)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .padding(16)
    }
}

private struct PhaseIcon: View {
    let state: UMGameActivityAttributes.ContentState
    var body: some View {
        if state.isReadyCheck {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .foregroundStyle(readyGreen)
                .symbolEffect(.wiggle, options: .repeating)
        } else if state.isPregame {
            Image(systemName: "house.fill")
                .foregroundStyle(.white)
        } else {
            Image(systemName: state.isNight ? "moon.fill" : "sun.max.fill")
                .foregroundStyle(state.isNight ? nightBlue : dayGold)
        }
    }
}

/// Pregame: players in the lobby out of required, e.g. "5/7" (phaseName carries it).
private struct PregameCount: View {
    let state: UMGameActivityAttributes.ContentState
    var body: some View {
        Text(state.phaseName).monospacedDigit().foregroundStyle(.white)
    }
}

private struct PhaseLabel: View {
    let state: UMGameActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 6) {
            PhaseIcon(state: state)
            Text(state.isPregame ? "Pregame" : state.phaseName).foregroundStyle(.white)
        }
    }
}

/// Counts down by itself from the phase end date.
/// Always a single line: a narrow Dynamic Island trailing slot (Duo vertical island) used to wrap
/// "7:26" into stacked digits ("7" / "6") when multiline was allowed inside a tiny maxWidth.
private struct CountdownText: View {
    let state: UMGameActivityAttributes.ContentState
    var body: some View {
        Group {
            if let end = state.clockEnd, end > Date() {
                Text(timerInterval: (state.clockStart ?? Date())...end, countsDown: true)
            } else {
                Text("--:--")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
    }
}

/// Circular time-remaining ring; dotted red at kicks.
private struct ClockRing: View {
    let state: UMGameActivityAttributes.ContentState
    var lineWidth: CGFloat

    var body: some View {
        let color = state.atKicks ? kickRed
            : state.isReadyCheck ? readyGreen
            : state.isPregame ? Color.white
            : (state.isNight ? nightBlue : dayGold)
        ZStack {
            Circle()
                .stroke(color.opacity(state.atKicks ? 0.9 : 0.25),
                        style: StrokeStyle(lineWidth: lineWidth, dash: state.atKicks ? [2, 3] : []))
            if let end = state.clockEnd, let start = state.clockStart, end > Date(), start < end {
                ProgressView(timerInterval: start...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(color)
            }
        }
    }
}

private enum LAPreviewClock {
    /// Shared anchor so "7:26" / "0:09" / "12:05" are exact at preview open.
    static let now = Date()
    static func end(minutes: Int, seconds: Int) -> Date {
        now.addingTimeInterval(TimeInterval(minutes * 60 + seconds))
    }
}

#Preview("Lock Screen", as: .content, using: UMGameActivityAttributes(gameId: "x", setupName: "Classic 7")) {
    GameLiveActivity()
} contentStates: {
    UMGameActivityAttributes.ContentState(phaseName: "Day 2", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 7, seconds: 26), atKicks: false)
    UMGameActivityAttributes.ContentState(phaseName: "Day 3", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 0, seconds: 45), atKicks: true)
    UMGameActivityAttributes.ContentState(phaseName: "Night 1", isNight: true,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 12, seconds: 5), atKicks: false)
    UMGameActivityAttributes.ContentState(phaseName: "5/12", isNight: false,
                                          clockStart: nil, clockEnd: nil, atKicks: false, stage: "pregame")
}

#Preview("Island Compact 7:26", as: .dynamicIsland(.compact), using: UMGameActivityAttributes(gameId: "x", setupName: "Classic 7")) {
    GameLiveActivity()
} contentStates: {
    UMGameActivityAttributes.ContentState(phaseName: "Day 1", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 7, seconds: 26), atKicks: false)
}

#Preview("Island Compact narrow digits", as: .dynamicIsland(.compact), using: UMGameActivityAttributes(gameId: "x", setupName: "Classic 7")) {
    GameLiveActivity()
} contentStates: {
    UMGameActivityAttributes.ContentState(phaseName: "Day 1", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 0, seconds: 9), atKicks: false)
    UMGameActivityAttributes.ContentState(phaseName: "Night 2", isNight: true,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 59, seconds: 59), atKicks: false)
    UMGameActivityAttributes.ContentState(phaseName: "Day 3", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: nil, atKicks: false)
}

#Preview("Island Minimal", as: .dynamicIsland(.minimal), using: UMGameActivityAttributes(gameId: "x", setupName: "Classic 7")) {
    GameLiveActivity()
} contentStates: {
    UMGameActivityAttributes.ContentState(phaseName: "Day 1", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 7, seconds: 26), atKicks: false)
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: UMGameActivityAttributes(gameId: "x", setupName: "Classic 7")) {
    GameLiveActivity()
} contentStates: {
    UMGameActivityAttributes.ContentState(phaseName: "Day 1", isNight: false,
                                          clockStart: LAPreviewClock.now, clockEnd: LAPreviewClock.end(minutes: 7, seconds: 26), atKicks: false)
}
