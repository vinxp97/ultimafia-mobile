import Foundation
import QuartzCore
import os
import Observation

struct GamePlayer: Identifiable, Hashable {
    var id: String
    var name: String
    var userId: String?
    var avatar: Bool = false
    /// Anonymous deck avatar path ("/decks/<profileId>.webp"); the server sends it in `avatar`
    /// as a string instead of a bool (Player.makeAnonymous).
    var deckAvatarPath: String? = nil
    /// Deck profile id for anonymous players (web uses it as avatarId).
    var anonId: String? = nil
    var left: Bool = false
    var textColorHex: String?
    var nameColorHex: String?
    var nameFont: String?
    /// In-game avatar shape (web PR #3051). Server sends top-level `avatarShape` ("square"/"circle").
    var squareAvatar: Bool = false
    var animatedNameColor: String?
    var nameGradientColorA: String?
    var nameGradientColorB: String?
    var nameGradientColorC: String?
    /// Finite numeric `playerListPosition` only. String indexes from ArrayHash are ignored (desktop Number.isFinite("0") is false).
    var playerListPosition: Double? = nil
    var customEmotes: [String: String] = [:]
    var customStickers: [String: String] = [:]
}

/// Game-screen hardware keyboard shortcuts (Option+arrows).
enum UMGameShortcut: CaseIterable {
    case previousPhase, nextPhase, chatTop, chatBottom

    var title: String {
        switch self {
        case .previousPhase: "Previous Phase"
        case .nextPhase: "Next Phase"
        case .chatTop: "Jump to Top of Chat"
        case .chatBottom: "Jump to Latest Message"
        }
    }
}

struct ChatLine: Identifiable, Hashable {
    var id: String
    var senderId: String
    var senderName: String
    var content: String
    var time: Date
    var isServer: Bool
    var meetingId: String?
    var prefix: String?
    var customEmotes: [String: String] = [:]
    var customStickers: [String: String] = [:]
    var isQuote: Bool = false
    var quotable: Bool = true
    var fromState: Int?
    var quotedFromStateName: String?
    var quotedMessageId: String?
    var quotedSenderId: String?
    var quotedSenderName: String?
    var quotedTime: Date?
    var senderWasDead: Bool = false
    /// Message carried its own `alive` flag (so senderWasDead isn't a fallback guess).
    var aliveFlagKnown: Bool = false
    var newspaper: NewspaperIssue? = nil

    var isVoteLog: Bool { senderId == "vote" || id.hasPrefix("votehist:") }
}

struct VoteMember: Hashable {
    var id: String
    var canVote: Bool
    var canUpdateVote: Bool
}

struct VoteMeeting: Identifiable, Hashable {
    var id: String
    var name: String
    var actionName: String
    var canVote: Bool
    var canUnvote: Bool = true
    var targets: [String]
    var votes: [String: [String]]
    var hiddenVoterIds: Set<String> = []
    var inputType: String
    var amMember: Bool = true
    var displayVoteCounter: Bool = false
    var noOneDisplayName: String?
    var anonymous: Bool = false
    var anonymousVotes: Bool = false
    var votesInvisible: Bool = false
    var multi: Bool = false
    var members: [VoteMember] = []
    var itemName: String?
    /// Server `itemIsTrueItem`: web lists these (Gun, Knife, …) after the regular actions.
    var itemIsTrueItem: Bool = false
    /// Web useAction: instant (unless instantButChangeable) or noUnvote meetings lock after voting.
    var instant: Bool = false
    var instantButChangeable: Bool = false
    var noUnvote: Bool = false
    var playerHasVoted: Bool = false

    /// Web `notClickable` lock-after-vote clause.
    func lockedAfterVote(selfId: String?) -> Bool {
        ((instant && !instantButChangeable) || noUnvote) && !selections(of: selfId).isEmpty
    }

    var isVoteKick: Bool { name == "Vote Kick" }

    func selections(of voterId: String?) -> [String] {
        guard let voterId else { return [] }
        return votes[voterId] ?? []
    }

    func count(for target: String) -> Int {
        VoteTally(votes: votes, hiddenVoterIds: hiddenVoterIds).count(for: target)
    }

    var ballot: [(voter: String, targets: [String])] {
        votes.keys.sorted().compactMap { key in
            let t = votes[key] ?? []
            guard !t.isEmpty else { return nil }
            return (key, t)
        }
    }
}

struct GamePhase: Identifiable, Hashable {
    var id: Int
    var name: String
    var dayCount: Int?
    var messages: [ChatLine] = []
    var meetings: [VoteMeeting] = []
}

struct SpeechChannel: Identifiable, Hashable {
    var id: String
    var name: String
    var canTalk: Bool
    var abilities: [SpeechAbility]
}

struct SpeechAbility: Hashable {
    var name: String
    var verb: String
    var targetType: String
    var targets: [String]
}

struct SpeechOption: Identifiable, Hashable {
    var id: String
    var label: String
    var placeholder: String
    var abilityName: String?
    var abilityTarget: String?
    var menuTitle: String { placeholder.isEmpty ? label : "\(label) \(placeholder)" }
}

struct GameClock {
    var name: String
    var delayMs: Double
    var lastSyncElapsedMs: Double
    var lastSyncAt: Date

    func remainingMs(at now: Date) -> Double {
        let elapsed = lastSyncElapsedMs + now.timeIntervalSince(lastSyncAt) * 1000
        return max(0, delayMs - elapsed)
    }
}

enum ClockKind {
    case normal, secondary, vegKickCountdown, vegKick
}

enum GuessTapResult {
    case didCycle
    case needsRolePick
}

@Observable
final class GameSession {
    /// Chat scroll state kept across leaving the game screen (lobby round-trip).
    @ObservationIgnored var chatSeenLineIds: Set<String> = []
    @ObservationIgnored var chatAnchorId: String?
    /// Per-phase chat position: first visible line id in each phase that has been viewed.
    /// A phase with no entry opens at its top (the live phase keeps following the bottom).
    @ObservationIgnored var phaseScrollAnchors: [Int: String] = [:]
    /// Pinned-to-latest state per phase when it was left (only matters for the live phase).
    @ObservationIgnored var phasePinned: [Int: Bool] = [:]
    /// Keyboard shortcut requests for the chat pane (Option+Up / Option+Down).
    var chatJumpTopTick = 0
    var chatJumpBottomTick = 0

    func performShortcut(_ shortcut: UMGameShortcut) {
        switch shortcut {
        case .previousPhase: viewAdjacentPhase(delta: -1)
        case .nextPhase: viewAdjacentPhase(delta: 1)
        case .chatTop: chatJumpTopTick &+= 1
        case .chatBottom: chatJumpBottomTick &+= 1
        }
    }
    @ObservationIgnored var chatPinnedToBottom = true
    @ObservationIgnored var chatHasOpened = false
    let gameId: String
    /// Watching rather than seated. Starts as the connect mode; the server's `isSpectator` flips it
    /// (pregame Spectate moves a seated player to spectators on the same socket).
    private(set) var spectate: Bool
    /// Read-only replay of a finished game from `/game/:id/review/data`: no socket, no sounds.
    let isReview: Bool
    /// Sound/notification side effects are muted while replaying history or reviewing.
    private var isQuiet: Bool { ingestingHistory || isReview }

    var connected = false
    var loaded = false
    var errorMessage: String?
    /// Review mode: called when review/data fails (private/locked, broken, not found).
    @ObservationIgnored var onReviewUnavailable: (() -> Void)?
    var gameType: String?
    var setupName: String?
    var stateName = "Connecting"
    var dayCount: Int?
    var selfId: String?
    var hostId: String?
    var finished = false {
        didSet { if finished { isolating = false; isolatedIds = [] } }
    }
    /// Village "Isolate messages": checked players stay prominent, everyone else's chat dims.
    /// In memory per session; cleared when the game ends (and dropped with the session on leave).
    var isolating = false
    var isolatedIds: Set<String> = []
    /// Active game only (started, not finished, not a review).
    var canIsolate: Bool { !isReview && !finished && currentPhaseId >= 0 }
    func dimsInChat(_ line: ChatLine) -> Bool {
        guard !isolatedIds.isEmpty, line.newspaper == nil, !line.isServer,
              line.senderId != "vote", line.senderId != "server" else { return false }
        return !isolatedIds.contains(line.senderId)
    }
    /// Anonymous decks in this game (options.anonymousDeck ids); their profiles are cached on disk.
    var anonymousDeckIds: [String] = []
    var rankedGame = false
    var competitiveGame = false
    /// options.spectating: the lobby allows spectators (web shows the pregame Spectate button only then).
    var spectatingAllowed = false
    /// "spectate" sent, waiting for `isSpectator` or `spectateFailed`.
    var spectateRequestPending = false
    /// Why the server refused a pregame Spectate (`spectateFailed`), shown as an alert; the seat is kept.
    var spectateFailure: String?
    /// "takeSeat" sent from the pregame Join bar, waiting for `isSpectator` false or `takeSeatFailed`.
    var takeSeatPending = false
    /// Why the server refused Join open seat (`takeSeatFailed`), shown as an alert.
    var takeSeatFailure: String?
    /// Server `spectatorCount` broadcast (Game.js broadcastSpectators / player join); header eye chip.
    var spectatorCount: Int?
    /// Server `omniscientSpectator` (dev / omniscient spectate): sees every meeting. Header "Dev view".
    var omniscientSpectator = false
    var graveyardParticipation = false

    /// Mirrors web Game.jsx: dialog only when participating in a live (non-pregame/postgame) game.
    var leaveNeedsConfirm: Bool {
        !isReview && !spectate && !finished && currentPhaseId >= 0 && players.contains { $0.id == selfId }
    }
    var participationRequired: Bool {
        guard let id = selfId else { return false }
        return !deadIds.contains(id) || graveyardParticipation
    }
    var players: [GamePlayer] = [] {
        didSet { for p in players { knownPlayers[p.id] = p } }
    }
    /// Everyone ever seen this game, by player id. Survives playerLeave / players refreshes so a
    /// departed player's chat rows, newspaper, vote log etc. keep their name + avatar.
    @ObservationIgnored private var knownPlayers: [String: GamePlayer] = [:]
    var messages: [ChatLine] = []
    var meetings: [VoteMeeting] = []
    var speechChannels: [SpeechChannel] = []

    var meetingsForViewing: [VoteMeeting] {
        if isViewingLive { return meetings }
        return phases.first(where: { $0.id == viewingPhaseId })?.meetings ?? []
    }
    var selectedSpeechMeetingId: String?
    var selectedSpeechOptionId = "Say"
    var canTalk = false
    var selectedPanel = 0
    var readyCheckActive = false
    var readyEndTime = Date()
    var readyPlayerIds: Set<String> = []
    var phases: [GamePhase] = [GamePhase(id: -1, name: "Pregame")]
    var currentPhaseId: Int = -1 {
        didSet {
            // Web copies the previous state's dead map into each new state; keep a snapshot of the
            // phase we're leaving so viewing it later shows who was dead then.
            if oldValue != currentPhaseId, !ingestingHistory, deadByPhase[oldValue] == nil {
                deadByPhase[oldValue] = deadIds
            }
        }
    }
    /// Per-state dead set (web history.states[id].dead), from history / review data.
    var deadByPhase: [Int: Set<String>] = [:]
    var viewingPhaseId: Int = -1
    var followLive = true
    var showRoleReveal = false
    var selfRoleName: String?
    var selfRoleCategory: String?
    var selfRoleModifiers: [String] = []
    var knownRoles: [String: String] = [:]
    var teammateIds: Set<String> = []
    var deadIds: Set<String> = []
    var typingPlayerIds: [String] = []
    var speakCooldownUntil: Date?
    var speakCooldownMeetingId: String?
    var clocks: [String: GameClock] = [:]
    var setupId: String?
    var setupGameType = "Mafia"
    /// Liars Dice table per state id (from each state's extraInfo; reviews use history).
    var ldByPhase: [Int: LDState] = [:]
    /// Dice tab bet log: "Prior rounds" disclosure, per game (in memory).
    var ldShowPriorRounds = false
    var isLiarsDice: Bool { (gameType ?? setupGameType) == "Liars Dice" }
    var ldViewing: LDState? {
        let id = isViewingLive ? currentPhaseId : viewingPhaseId
        return ldByPhase[id] ?? (id == -2 ? ldByPhase.filter { $0.key >= 0 }.max { $0.key < $1.key }?.value : nil)
    }
    var setupClosed = false
    var setupUseRoleGroups = false
    var setupRoles: [SetupRole] = []
    var setupRolesets: [[SetupRole]] = []
    var setupRolesetIndex = 0
    var setupBanished: [SetupRole] = []
    var setupBanishedPerSet: [[SetupRole]] = []
    var setupEvents: [SetupRole] = []
    var setupEventsPerSet: [[SetupRole]] = []
    var setupGrouped = false
    var setupGroupSizes: [Int] = []
    /// setup.gameSettings["Whispers"] / ["Whisper Leak Chance"] (web getSetupGameSetting).
    var setupWhispers = false
    var setupWhisperLeakChance: Double = 0
    /// Web "Leak Whispers" checkbox: whispers are sent with forceLeak.
    var whisperForceLeak = false
    var roleGuesses: [String: RoleGuess] = [:]

    var isSimpleMulti: Bool {
        !setupClosed && !setupUseRoleGroups && setupRolesets.count > 1
    }

    var guessableRoles: [SetupRole] {
        var seen = Set<String>()
        var out: [SetupRole] = []
        for set in setupRolesets {
            for role in set where seen.insert(role.raw).inserted {
                out.append(role)
            }
        }
        for role in setupBanished where seen.insert(role.raw).inserted {
            out.append(role)
        }
        return out
    }

    func cycleSetupRoleset() {
        guard isSimpleMulti else { return }
        setupRolesetIndex = (setupRolesetIndex + 1) % setupRolesets.count
        setupRoles = setupRolesets[setupRolesetIndex]
    }
    var newspapers: [Int: [String: NewspaperIssue]] = [:]
    /// Roles the server announced for a player after their death (the public death reveal:
    /// `death`, then the `reveal` broadcast, then `obituaries`; in history, a role that first
    /// appears in the state where the player died). Fills a paper whose obituary came without
    /// a revealMessage, now or when the reveal arrives later. Private reveals (teammates, your
    /// own role) happen while alive and never land here.
    private(set) var deathRevealedRoles: [String: String] = [:]

    /// The paper as it is now (a chat line holds the paper from when it arrived; reveals that
    /// come later are merged into `newspapers`).
    func currentIssue(_ issue: NewspaperIssue) -> NewspaperIssue {
        newspapers[issue.phaseId]?[issue.source] ?? issue
    }
    private var newspaperEpoch: Date?
    private var newspaperEpochDayCount: Int?

    var socketForCommands: GameSocket { socket }
    private let socket = GameSocket()
    private var token: String?
    private var didJoin = false
    private var leftByServer = false
    private var isStarting = false
    private var expectDisconnect = false
    private var weInitiatedLeave = false
    var displaced = false
    private var typingIn: String?
    /// Set once the draft starts with "/"; no typing indicator is sent until a normal message goes out.
    var typingSuppressed = false
    /// The next phase switch should open the chat at the top of that phase, not at the saved
    /// position or the end: set when a review opens and by the phase swipe (and its VoiceOver /
    /// trackpad equivalents). Consumed by the chat's phase-change handler.
    var reviewScrollTopPending = false
    /// Brief inline hint for an invalid slash command (shown above the composer).
    var slashHint: String?
    private var typingIdleTask: Task<Void, Never>?
    private var typingExpireTasks: [String: Task<Void, Never>] = [:]
    /// Desktop `activity.typing[playerId] = meetingId`.
    private var typingByPlayerId: [String: String] = [:]
    private var typingOrder: [String] = []
    private var seenMessageIds = Set<String>()
    private var lastSpeakCooldownSentAt: Double = 0
    private var ingestBuffer: [ChatLine] = []
    private var ingestingHistory = false
    private var playBell = false
    private var kickWindowNotified = false
    private var lastTalkMeetingId: String?

    init(gameId: String, spectate: Bool, review: Bool = false) {
        self.gameId = gameId
        self.spectate = spectate || review
        self.isReview = review
        socket.onEvent = { [weak self] name, data in
            self?.handle(name, data)
        }
        socket.onDisconnect = { [weak self] in
            self?.connected = false
        }
        restoreRoleMarks()
    }

    var speechMeetingId: String? { selectedSpeechMeetingId }

    var speechOptions: [SpeechOption] {
        var opts = [SpeechOption(id: "Say", label: "Say", placeholder: "to everyone", abilityName: nil, abilityTarget: nil)]
        let channel = speechChannels.first(where: { $0.id == selectedSpeechMeetingId })
        for ability in channel?.abilities ?? [] {
            if ability.name == "Whisper" && !setupWhispers { continue }
            if ability.targets.isEmpty {
                opts.append(SpeechOption(
                    id: ability.name,
                    label: ability.name,
                    placeholder: ability.verb,
                    abilityName: ability.name,
                    abilityTarget: nil
                ))
                continue
            }
            for target in ability.targets {
                let display = ability.targetType == "player" ? displayName(for: target) : target
                opts.append(SpeechOption(
                    id: "\(ability.name):\(target)",
                    label: ability.name,
                    placeholder: "\(ability.verb) \(display)",
                    abilityName: ability.name,
                    abilityTarget: target
                ))
            }
        }
        return opts
    }

    var currentSpeechOption: SpeechOption {
        speechOptions.first(where: { $0.id == selectedSpeechOptionId }) ?? speechOptions[0]
    }

    var speechLabel: String { currentSpeechOption.label }

    var isSpeakCoolingDown: Bool {
        guard let until = speakCooldownUntil else { return false }
        return until > Date()
    }

    var speakCooldownSecondsLeft: Int {
        guard let until = speakCooldownUntil else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
    }

    var speechPlaceholder: String {
        if isDraftOnly { return "Draft a message for day…" }
        if isSpeakCoolingDown {
            return "Please do not spam! \(speakCooldownSecondsLeft)s"
        }
        if speakTargetIsSpectatorChat { return "Say to spectators…" }
        let extra = currentSpeechOption.placeholder
        if extra.isEmpty { return "Say…" }
        return "Say \(extra)…"
    }

    var showComposer: Bool {
        // Spectators talk in Pregame before the start and in the Spectator Meeting (Spectator.js
        // canSpeakIn); canTalk encodes that. No spectator chat once the game is over.
        guard !isReview, isViewingLive else { return false }
        if spectate && (finished || currentPhaseId == -2) { return false }
        return canTalk || speechChannels.contains(where: { $0.canTalk }) || isDraftOnly
    }

    /// Spectator.canSpeakIn: the Spectator Meeting, or Pregame while the game hasn't started.
    nonisolated static func spectatorMayTalk(in meetingName: String, pregame: Bool) -> Bool {
        meetingName == "Spectator Meeting" || (meetingName == "Pregame" && pregame)
    }

    /// The meeting `speak` would send to right now (selected channel if you can talk there, else
    /// the first one you can talk in).
    var speakTargetId: String? {
        speechChannels.first(where: { $0.id == selectedSpeechMeetingId && $0.canTalk })?.id
            ?? speechChannels.first(where: { $0.canTalk })?.id
    }

    /// Composer target is the Spectator Meeting (web placeholder "Say to spectators...").
    var speakTargetIsSpectatorChat: Bool {
        guard spectate, let id = speakTargetId else { return false }
        return spectatorMeetingIds.contains(id)
    }

    /// Seated player in a running game with no meeting they can speak in right now (e.g. town at
    /// night): the composer stays up so they can prepare a message, but nothing is sent and no
    /// typing events go out. The draft lives in the game view, so it survives into the next phase.
    var isDraftOnly: Bool {
        guard !isReview, isViewingLive, !spectate, isGameInProgress, !finished,
              let me = selfId, players.contains(where: { $0.id == me }) else { return false }
        return !(canTalk || speechChannels.contains(where: { $0.canTalk }))
    }


    var isViewingLive: Bool { viewingPhaseId == currentPhaseId }

    var activeClockName: String {
        if clocks["pregameCountdown"] == nil, clocks["pregameWait"] != nil {
            return "pregameWait"
        }
        if currentPhaseId == -1 { return "pregameCountdown" }
        if currentPhaseId == -2 { return "postgame" }
        if clocks["secondary"] != nil { return "secondary" }
        if clocks["vegKick"] != nil { return "vegKick" }
        if clocks["vegKickCountdown"] != nil { return "vegKickCountdown" }
        return "main"
    }

    var clockKind: ClockKind {
        switch activeClockName {
        case "vegKick": return .vegKick
        case "vegKickCountdown": return .vegKickCountdown
        case "secondary": return .secondary
        default: return .normal
        }
    }

    func clockRemainingMs(at now: Date = Date()) -> Double? {
        let name = activeClockName
        guard clocks[name] != nil else { return nil }
        var left = clocks[name]!.remainingMs(at: now)
        if name == "secondary", clocks["main"] != nil {
            left = min(left, clocks["main"]!.remainingMs(at: now))
        }
        return left
    }

    var isGameInProgress: Bool { currentPhaseId >= 0 && !finished }

    func isDead(_ id: String) -> Bool { deadIds.contains(id) }

    private func deadWhenSent(senderId: String, alive: Any?) -> Bool {
        if senderId == "server" || senderId == "vote" { return false }
        if alive == nil || alive is NSNull {
            return isDead(senderId)
        }
        return !boolValue(alive)
    }

    /// Dead set for the phase being viewed (web PlayerList uses history.states[stateViewing].dead).
    /// Live phase uses the running set; past phases (and every review phase) use the history map.
    var viewedDeadIds: Set<String> {
        if !isReview && isViewingLive { return deadIds }
        return deadByPhase[viewingPhaseId] ?? deadIds
    }

    /// " (dead)" suffix: reviews show it to everyone; live games only to dead viewers.
    /// Uses the message's own alive flag (same as the red line); falls back to the
    /// dead set of the message's phase only when the flag is missing.
    /// Line sent in the Postgame phase (live: phase -2; history/review: its stored state).
    func isPostgameLine(_ line: ChatLine) -> Bool {
        (line.fromState ?? (isReview ? nil : currentPhaseId)) == -2
    }

    /// Dead-chat styling (red name/body). Postgame lines use the sender's own colors; earlier-phase
    /// dead lines keep their historical red.
    func deadStyled(_ line: ChatLine) -> Bool {
        line.senderWasDead && !isPostgameLine(line)
    }

    func showsDeadSuffix(_ line: ChatLine) -> Bool {
        if isPostgameLine(line) { return false }
        if !isReview {
            guard let me = selfId, deadIds.contains(me) else { return false }
        }
        if line.aliveFlagKnown { return line.senderWasDead }
        guard let phase = line.fromState ?? (isReview ? nil : currentPhaseId), phase >= 0 || phase == -2 else { return false }
        if !isReview && phase == currentPhaseId { return deadIds.contains(line.senderId) }
        return deadByPhase[phase]?.contains(line.senderId) ?? false
    }

    /// Web PlayerList: every section filters `!p.left`. The server's "players" payload also carries
    /// `playersGone` (people who left pregame, flagged in `left[]`), so they must be dropped in every phase.
    var villagePlayers: [GamePlayer] {
        let ordered = orderedPlayers(players).filter { !$0.left }
        if currentPhaseId < 0, !finished { return ordered }
        let dead = viewedDeadIds
        return ordered.filter { !dead.contains($0.id) }
    }

    var graveyardPlayers: [GamePlayer] {
        guard isGameInProgress || finished else { return [] }
        let dead = viewedDeadIds
        return orderedPlayers(players).filter { !$0.left && dead.contains($0.id) }
    }

    /// Same as desktop `getOrderedPlayers`. Do not sort by name.
    func orderedPlayers(_ list: [GamePlayer]) -> [GamePlayer] {
        list.enumerated().sorted { a, b in
            let aPos = a.element.playerListPosition
            let bPos = b.element.playerListPosition
            let aHas = aPos != nil
            let bHas = bPos != nil
            if aHas, bHas, aPos != bPos { return aPos! < bPos! }
            if aHas != bHas { return aHas }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func markDead(_ id: String, dead: Bool = true) {
        if dead {
            deadIds = deadIds.union([id])
            dropTyper(id)
        } else {
            deadIds = deadIds.subtracting([id])
            publishVisibleTypers()
        }
    }

    var isLobbyPhase: Bool {
        if finished { return false }
        if currentPhaseId < 0 { return true }
        let name = stateName.lowercased()
        return name.contains("pregame") || name.contains("lobby")
    }

    var sortedPhases: [GamePhase] {
        phases.sorted { a, b in
            func rank(_ id: Int) -> Int {
                if id == -1 { return -1000 }
                if id == -2 { return 10_000 }
                return id
            }
            return rank(a.id) < rank(b.id)
        }
    }

    var displayedMessages: [ChatLine] {
        // Liars Dice has no phase switcher (one state per turn): show the whole game's chat.
        if isLiarsDice { return phases.sorted { rank($0.id) < rank($1.id) }.flatMap(\.messages) }
        return phases.first(where: { $0.id == viewingPhaseId })?.messages ?? messages
    }

    private func rank(_ id: Int) -> Int { id == -2 ? Int.max : id }

    var viewingNewspaper: NewspaperIssue? {
        viewingNewspapers.first
    }

    var viewingNewspapers: [NewspaperIssue] {
        let name = (phases.first(where: { $0.id == viewingPhaseId })?.name ?? "").lowercased()
        if name.contains("post") || viewingPhaseId == -2 {
            let bag = newspapers[viewingPhaseId] ?? newspapers[-2] ?? [:]
            var out: [NewspaperIssue] = []
            if let w = bag["Winners"] { out.append(w) }
            if let p = bag["Postgame"] { out.append(p) }
            for (key, issue) in bag where key != "Winners" && key != "Postgame" {
                out.append(issue)
            }
            return out
        }
        if name.contains("night") {
            return deathPapers(on: viewingPhaseId, preferring: "Day")
                ?? deathPapersOnPrevious(named: "day", preferring: "Day")
                ?? []
        }
        if name.contains("day") {
            return deathPapers(on: viewingPhaseId, preferring: "Night")
                ?? deathPapersOnPrevious(named: "night", preferring: "Night")
                ?? []
        }
        return []
    }

    private func deathPapers(on phaseId: Int, preferring source: String) -> [NewspaperIssue]? {
        guard let bag = newspapers[phaseId] else { return nil }
        if let preferred = bag[source], !preferred.isWin { return [preferred] }
        return nil
    }

    private func deathPapersOnPrevious(named needle: String, preferring source: String) -> [NewspaperIssue]? {
        guard let prev = sortedPhases.last(where: {
            $0.id < viewingPhaseId && $0.name.lowercased().contains(needle)
        }) else { return nil }
        return deathPapers(on: prev.id, preferring: source)
    }

    func newspaperDateLine(for issue: NewspaperIssue) -> String {
        NewspaperDate.line(
            epoch: newspaperEpoch ?? issue.time,
            epochDayCount: newspaperEpochDayCount ?? issue.dayCount,
            dayCount: issue.dayCount
        )
    }

    var teammates: [GamePlayer] {
        players.filter { teammateIds.contains($0.id) && $0.id != selfId }
    }

    var selfPlayer: GamePlayer? {
        guard let selfId else { return nil }
        return players.first(where: { $0.id == selfId })
    }

    var typingPlayers: [GamePlayer] {
        typingPlayerIds.compactMap { id in players.first(where: { $0.id == id }) }
    }

    /// Same as tapping "I am Ready" (keyboard Return while the prompt is up).
    func acceptReadyCheck() {
        guard needsReadyConfirm else { return }
        ReadyBell.stop()
        verifyReady()
    }

    var needsReadyConfirm: Bool {
        guard readyCheckActive, !spectate else { return false }
        if let selfId { return !readyPlayerIds.contains(selfId) }
        return true
    }

    var readySecondsLeft: Int {
        max(0, Int(readyEndTime.timeIntervalSinceNow.rounded(.up)))
    }

    func cycleSpeechOption() {
        let opts = speechOptions
        guard opts.count > 1 else { return }
        if let i = opts.firstIndex(where: { $0.id == selectedSpeechOptionId }) {
            selectedSpeechOptionId = opts[(i + 1) % opts.count].id
        } else {
            selectedSpeechOptionId = opts[0].id
        }
    }

    func selectSpeechOption(_ id: String) {
        selectedSpeechOptionId = id
    }

    func completePlayerName(_ draft: String) -> String? {
        var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let word = words.popLast(), !word.isEmpty else { return nil }
        var seedStart = word.endIndex
        while seedStart > word.startIndex {
            let prev = word.index(before: seedStart)
            let ch = word[prev]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                seedStart = prev
            } else {
                break
            }
        }
        let seed = String(word[seedStart...])
        let prefix = String(word[..<seedStart])
        let seedLower = seed.lowercased()
        if seedLower.isEmpty {
            let lower = word.lowercased()
            if !lower.isEmpty, "@everyone".hasPrefix(lower), lower != "@everyone" {
                words.append("@everyone" + UMChatPrefs.completionSuffix)
                return words.joined(separator: " ")
            }
            return nil
        }
        let matched = players.map { $0.name }.filter { name in
            name.lowercased().prefix(seedLower.count) == seedLower
        }
        if matched.count == 1 {
            // Trailing space after a completed name / %avatar unless "Space after autocomplete" is off
            // (the word is always last, so none follows).
            words.append(prefix + matched[0] + UMChatPrefs.completionSuffix)
            return words.joined(separator: " ")
        }
        if matched.count > 1 {
            let first = matched[0]
            let minLen = matched.map { $0.count }.min() ?? 0
            var n = 0
            while n < minLen {
                let ch = first[first.index(first.startIndex, offsetBy: n)]
                if matched.contains(where: { $0[$0.index($0.startIndex, offsetBy: n)] != ch }) {
                    break
                }
                n += 1
            }
            if n > seed.count {
                words.append(prefix + String(first.prefix(n)))
                return words.joined(separator: " ")
            }
            return nil
        }
        if "@everyone".hasPrefix(word.lowercased()), word.lowercased() != "@everyone" {
            words.append("@everyone" + UMChatPrefs.completionSuffix)
            return words.joined(separator: " ")
        }
        return nil
    }

    func playerNamed(_ name: String) -> GamePlayer? {
        if let exact = players.first(where: { $0.name == name }) { return exact }
        let lower = name.lowercased()
        let hits = players.filter { $0.name.lowercased() == lower }
        return hits.count == 1 ? hits[0] : nil
    }

    func start() async {
        if isReview { await loadReview(); return }
        guard !leftByServer else { return }
        guard !connected, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil
        do {
            let info = try await APIClient.shared.connect(gameId: gameId, spectate: spectate)
            gameType = info.type
            hostId = info.hostId
            token = info.token
            socket.connect(port: info.port.value)
        } catch {
            errorMessage = UMFriendlyError.message(for: error)
        }
    }

    /// Mirrors web Game.jsx review mode: feed the stored game through the same handlers the
    /// socket uses (setup, options, players, history), then mark it finished.
    private func loadReview() async {
        guard !loaded else { return }
        do {
            let data = try await APIClient.shared.request("GET", path: "game/\(gameId)/review/data", query: [:], body: nil)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UMError.message("Could not read this game.")
            }
            if boolValue(obj["broken"]) { throw UMError.message("Game not found.") }
            gameType = obj["type"] as? String
            if let setup = obj["setup"] { handle("setup", setup) }
            handle("options", [
                "lobby": obj["lobby"] ?? NSNull(),
                "ranked": obj["ranked"] ?? false,
                "competitive": obj["competitive"] ?? false,
                "spectating": obj["spectating"] ?? false,
                "anonymousGame": obj["anonymousGame"] ?? false,
                "graveyardParticipation": obj["graveyardParticipation"] ?? false,
            ])
            let ids = obj["players"] as? [String] ?? []
            let names = obj["names"] as? [Any] ?? []
            let users = obj["users"] as? [Any] ?? []
            let left = Set(obj["left"] as? [String] ?? [])
            let anon = boolValue(obj["anonymousGame"])
            // playerIdMap (seat id -> user id) is authoritative when present; users[] can be misaligned.
            let idMap: [String: String] = {
                if let m = obj["playerIdMap"] as? [String: String] { return m }
                if let s = obj["playerIdMap"] as? String,
                   let m = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String] { return m }
                return [:]
            }()
            var blobs: [[String: Any]] = []
            for (i, id) in ids.enumerated() {
                let user = users.indices.contains(i) ? users[i] as? [String: Any] : nil
                var settings = user?["settings"] as? [String: Any] ?? [:]
                if anon { settings["gameAvatarShape"] = "circle" }
                var blob: [String: Any] = [
                    "id": id,
                    "name": (names.indices.contains(i) ? names[i] as? String : nil) ?? "Player",
                    "avatar": user?["avatar"] ?? false,
                    "settings": settings,
                    "left": left.contains(id),
                ]
                if let uid = idMap[id] ?? (user?["id"] as? String) { blob["userId"] = uid }
                blobs.append(blob)
            }
            handle("players", blobs)
            if let raw = obj["history"] as? String,
               let hist = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
                handle("history", hist)
            } else if let hist = obj["history"] {
                handle("history", hist)
            }
            finished = true
            stateName = "Review"
            loaded = true
            // Open on the first phase after pregame (Day 1 / Night 1), chat scrolled to its top.
            if let first = sortedPhases.first(where: { $0.id >= 0 }) ?? sortedPhases.first {
                reviewScrollTopPending = true
                viewPhase(first.id)
            }
        } catch {
            errorMessage = UMFriendlyError.message(for: error)
            onReviewUnavailable?()
        }
    }

    func disconnectWithoutLeaving() {
        expectDisconnect = true
        stopTyping()
        GameMusic.stop()
        GameWinMusic.stop()
        socket.disconnect()
        connected = false
        isStarting = false
    }

    func stop() {
        weInitiatedLeave = true
        expectDisconnect = true
        stopTyping()
        GameMusic.stop()
        GameWinMusic.stop()
        socket.send("leave")
        socket.disconnect()
        connected = false
        RoleMarkStore.clear(gameId: gameId)
        Task { await APIClient.shared.leaveGame() }
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        guard !isSpeakCoolingDown, !isDraftOnly else { return false }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(UMConfig.maxChatLength))
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("/") {
            switch runSlashCommand(trimmed) {
            case .handled:
                slashHint = nil
                return true
            case .error(let hint):
                slashHint = hint
                return false
            case .passThrough:
                break // server-parsed command (/me, /role, /help…): send as speak, server handles it
            }
        } else {
            typingSuppressed = false
            slashHint = nil
        }
        if spectate && (finished || currentPhaseId == -2) { return false }
        // Spectators only ever send to a meeting they can speak in (Spectator.canSpeakIn).
        let meetingId = spectate ? speakTargetId : (speakTargetId
            ?? selectedSpeechMeetingId
            ?? speechChannels.first?.id
            ?? lastTalkMeetingId)
        guard let meetingId else { return false }
        lastTalkMeetingId = meetingId
        var payload: [String: Any] = [
            "content": trimmed,
            "meetingId": meetingId,
        ]
        if let name = currentSpeechOption.abilityName {
            payload["abilityName"] = name
            if let target = currentSpeechOption.abilityTarget {
                payload["abilityTarget"] = target
            }
            if name == "Whisper" && whisperForceLeak { payload["forceLeak"] = true }
        }
        socket.send("speak", object: payload)
        #if DEBUG
        debugSendHook?("speak", payload)
        #endif
        stopTyping()
        return true
    }

    func noteTyping() {
        guard !typingSuppressed, !isDraftOnly else { return }
        guard isViewingLive, !spectate, canTalk else { return }
        guard currentSpeechOption.abilityName == nil else { return }
        let selected = speechChannels.first(where: { $0.id == selectedSpeechMeetingId && $0.canTalk })?.id
        let meetingId = selected
            ?? speechChannels.first(where: { $0.canTalk })?.id
            ?? selectedSpeechMeetingId
            ?? speechChannels.first?.id
        guard let meetingId else { return }
        if typingIn != meetingId {
            if let prev = typingIn {
                socket.send("typing", object: ["meetingId": prev, "isTyping": false])
            }
            typingIn = meetingId
            socket.send("typing", object: ["meetingId": meetingId, "isTyping": true])
        }
        typingIdleTask?.cancel()
        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopTyping()
        }
    }

    func stopTyping() {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        if let meetingId = typingIn {
            socket.send("typing", object: ["meetingId": meetingId, "isTyping": false])
        }
        typingIn = nil
    }

    func vote(meetingId: String, selection: String) {
        if !isViewingLive { viewLivePhase() }
        let meeting = meetings.first(where: { $0.id == meetingId })
        let already = meeting?.selections(of: selfId).contains(selection) == true
        // Server `targets` is authoritative (Meeting.generateTargets / getMeetingInfo); text input is free-form.
        if let meeting, meeting.inputType != "text", !already, !meeting.targets.contains(selection) { return }
        if already, meeting?.canUnvote != false {
            socket.send("unvote", object: [
                "meetingId": meetingId,
                "selection": selection,
            ])
        } else {
            socket.send("vote", object: [
                "meetingId": meetingId,
                "selection": selection,
            ])
        }
    }

    /// Whether a double tap would actually quote this line. The haptic fires on the same answer, so
    /// a tap that would do nothing stays silent.
    func canQuote(_ line: ChatLine) -> Bool {
        guard !line.isServer, !line.isQuote, line.quotable else { return false }
        // Spectators quote into a meeting they can speak in (Spectator.js "quote" -> canSpeakIn).
        if spectate { return showComposer && speakTargetId != nil }
        return true
    }

    func quote(_ line: ChatLine) {
        guard canQuote(line) else { return }
        if !isViewingLive {
            viewLivePhase()
        }
        let to = (spectate ? speakTargetId : nil)
            ?? selectedSpeechMeetingId
            ?? speechChannels.first(where: { $0.canTalk })?.id
            ?? speechChannels.first?.id
            ?? line.meetingId
        guard let to, !to.isEmpty else { return }
        let payload: [String: Any] = [
            "messageId": line.id,
            "toMeetingId": to,
            "fromMeetingId": line.meetingId ?? to,
            "fromState": line.fromState ?? viewingPhaseId,
            "messageContent": line.content,
        ]
        socket.send("quote", object: payload)
        #if DEBUG
        debugSendHook?("quote", payload)
        #endif
    }

    func viewPhase(_ id: Int) {
        guard phases.contains(where: { $0.id == id }) else { return }
        viewingPhaseId = id
        followLive = id == currentPhaseId
        publishVisibleTypers()
    }

    /// Key for this session's pinned images in UMImageCache (one per session object, so a review
    /// and a live seat on the same game never share or clear each other's).
    var assetScope: String { "session-\(ObjectIdentifier(self).hashValue)" }

    /// Every image a game screen can draw that is known up front: each player's avatar, every
    /// role (and modifier badge) in the setup, and the players' custom emotes / stickers.
    var assetURLs: [URL] {
        var urls: [URL] = []
        for p in players {
            if let path = p.deckAvatarPath, let u = UMAvatarURL.deck(path: path) { urls.append(u) }
            else if p.avatar, let id = p.userId, !id.isEmpty, let u = UMAvatarURL.live(userId: id) { urls.append(u) }
            urls += (Array(p.customEmotes.values) + Array(p.customStickers.values)).compactMap(UMMediaURL.resolve)
        }
        let type = setupGameType
        for role in setupRolesets.flatMap({ $0 }) + setupBanished + setupEvents {
            let parts = role.raw.split(separator: ":", maxSplits: 1)
            if let u = RoleArt.roleURL(gameType: type, name: role.name) { urls.append(u) }
            if parts.count > 1 {
                let mods = parts[1].split(separator: "/").map(String.init).filter { !$0.isEmpty }
                if mods.count == 1, let u = RoleArt.modifierURL(gameType: type, name: mods[0]) { urls.append(u) }
                else if mods.count > 1, let u = RoleArt.badgeURL(modifierCount: mods.count) { urls.append(u) }
            }
        }
        return urls
    }

    /// Whether there is a phase `delta` steps from the one being viewed (swipe / arrows / a11y).
    func hasAdjacentPhase(delta: Int) -> Bool {
        let ids = sortedPhases.map(\.id)
        guard let i = ids.firstIndex(of: viewingPhaseId) else { return false }
        return ids.indices.contains(i + delta)
    }

    /// Phase swipe: the neighbouring phase, opened at its first message (live phase included;
    /// following the newest message resumes only once the reader scrolls to the bottom).
    func swipeToAdjacentPhase(delta: Int) {
        guard hasAdjacentPhase(delta: delta) else { return }
        reviewScrollTopPending = true
        viewAdjacentPhase(delta: delta)
    }

    func viewAdjacentPhase(delta: Int) {
        let ids = sortedPhases.map(\.id)
        guard let i = ids.firstIndex(of: viewingPhaseId) else { return }
        let next = i + delta
        guard ids.indices.contains(next) else { return }
        viewPhase(ids[next])
    }

    func viewLivePhase() {
        viewPhase(currentPhaseId)
    }

    func leave() {
        stop()
    }

    /// Web PregameSeatActions (shared/pregameSeatAction.js): pregame, live, seated, and the lobby
    /// allows spectating. The server still decides (only-player, limit, tutorial) and answers
    /// `spectateFailed` with the reason.
    var canSwitchToSpectate: Bool {
        !isReview && !spectate && !finished && connected && isPregame && spectatingAllowed
            && players.contains { $0.id == selfId }
    }

    /// Web pregameSeatAction "join": a spectator on the live pregame (server takeSeat checks for a
    /// free seat, bans, ranked rules and answers `takeSeatFailed` with the reason).
    var canTakeSeat: Bool {
        !isReview && spectate && !finished && connected && isPregame
    }

    func takeSeat() {
        guard canTakeSeat, !takeSeatPending else { return }
        takeSeatPending = true
        socket.send("takeSeat")
        #if DEBUG
        debugSendHook?("takeSeat", [:])
        #endif
    }

    /// Give up the seat and watch (server `spectate` event, Player.js; the app's /spectate).
    func switchToSpectate() {
        guard canSwitchToSpectate, !spectateRequestPending else { return }
        spectateRequestPending = true
        socket.send("spectate")
    }

    func verifyReady() {
        guard needsReadyConfirm else { return }
        socket.send("readyCheck verify")
        if let selfId, readyPlayerIds.insert(selfId).inserted {
            GameSFX.play("readyCheck")
        }
    }

    func clearReadyCheck() {
        readyCheckActive = false
        readyPlayerIds = []
        ReadyNotifications.clear()
        ReadyBell.stop()
    }

    func player(for senderId: String) -> GamePlayer? {
        players.first(where: { $0.id == senderId }) ?? knownPlayers[senderId] ?? spectatorPlayers[senderId]
    }

    /// Spectators (incl. you when spectating), from the server's `spectators` broadcast:
    /// seat id -> the same player-info shape as `players` (name, avatar, colors, emotes).
    var spectatorPlayers: [String: GamePlayer] = [:]
    /// Every seat id ever seen as a player (incl. ones that left pregame), never listed as spectators.
    @ObservationIgnored private var formerPlayerIds: Set<String> = []
    /// Ids of "Spectator Meeting" chats (only spectators are members, so only they get its lines).
    @ObservationIgnored private var spectatorMeetingIds: Set<String> = []

    /// Server order of the `spectators` payload (spectators, then spectatorsOld = join order).
    @ObservationIgnored private var spectatorOrder: [String] = []

    /// One entry per person: a re-joining spectator gets a new seat id each time (and old ones stay
    /// in spectatorsOld), so dedupe by account id (name if absent), keeping the current seat.
    /// `spectatorPlayers` keeps every id, so chat lines from older seats still resolve.
    var spectatorList: [GamePlayer] {
        let ordered = spectatorOrder.compactMap { spectatorPlayers[$0] }
            + spectatorPlayers.values.filter { !spectatorOrder.contains($0.id) }
        var latest: [String: GamePlayer] = [:]
        for s in ordered {
            let key = (s.userId?.isEmpty == false ? s.userId! : "name:" + s.name.lowercased())
            // Payload lists current spectators first, then spectatorsOld (JS keeps first insertion
            // position), so the first seat per person is the one that's here now if any.
            if latest[key] == nil { latest[key] = s }
        }
        return latest.values
            .filter { s in !formerPlayerIds.contains(s.id) && !players.contains { $0.id == s.id } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Seat ids the server marks `watching: false` (pregame-only speakers; getSpectatorInfoFor).
    @ObservationIgnored private var notWatchingIds: Set<String> = []

    /// Watching spectators for the Spectators list (web pregameSpectatorList filters `watching`).
    var watchingSpectators: [GamePlayer] {
        spectatorList.filter { !notWatchingIds.contains($0.id) }
    }

    /// Web pregameSpectatorList: spectators always see the list; players only on the live pregame.
    var showsSpectatorList: Bool {
        guard !isReview else { return false }
        return spectate || (currentPhaseId == -1 && viewingPhaseId == -1)
    }

    /// Line in a Spectator Meeting (web mergeSpectatorChat): tagged "Spectator", grey border, dimmed.
    func isSpectatorChatLine(_ line: ChatLine) -> Bool {
        guard !line.isServer, let m = line.meetingId else { return false }
        return spectatorMeetingIds.contains(m)
    }

    /// Written by a spectator seat (e.g. pregame chat): eye next to the name, no tag.
    func isSpectatorSender(_ line: ChatLine) -> Bool {
        guard !line.isServer, !line.isQuote else { return false }
        return spectatorPlayers[line.senderId] != nil && !players.contains { $0.id == line.senderId }
    }

    /// Line written by a spectator (in the Spectator Meeting, or by a known spectator seat).
    func isSpectatorLine(_ line: ChatLine) -> Bool {
        isSpectatorChatLine(line) || isSpectatorSender(line)
    }

    private func applyIncomingTyping(_ data: Any?) {
        guard let obj = data as? [String: Any] else { return }
        guard let playerId = obj["playerId"] as? String else { return }
        if playerId == selfId { return }
        let meetingId: String?
        if obj["meetingId"] is NSNull {
            meetingId = nil
        } else if let s = obj["meetingId"] as? String, !s.isEmpty {
            meetingId = s
        } else {
            meetingId = nil
        }
        setTyping(playerId: playerId, meetingId: meetingId)
    }

    private func setTyping(playerId: String, meetingId: String?) {
        typingExpireTasks[playerId]?.cancel()
        typingExpireTasks[playerId] = nil
        if let meetingId {
            typingByPlayerId[playerId] = meetingId
            if !typingOrder.contains(playerId) {
                typingOrder.append(playerId)
            }
            typingExpireTasks[playerId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                self?.dropTyper(playerId)
            }
        } else {
            typingByPlayerId.removeValue(forKey: playerId)
            typingOrder.removeAll { $0 == playerId }
        }
        publishVisibleTypers()
    }

    private func dropTyper(_ playerId: String) {
        typingExpireTasks[playerId]?.cancel()
        typingExpireTasks[playerId] = nil
        typingByPlayerId.removeValue(forKey: playerId)
        typingOrder.removeAll { $0 == playerId }
        publishVisibleTypers()
    }

    private func clearAllTyping() {
        for task in typingExpireTasks.values { task.cancel() }
        typingExpireTasks.removeAll()
        typingByPlayerId.removeAll()
        typingOrder.removeAll()
        if !typingPlayerIds.isEmpty {
            typingPlayerIds = []
        }
    }

    /// Desktop PlayerRows: selTab match AND same alive/dead section as viewer.
    /// Village `speakDead` still delivers dead typing to living members; drop those.
    private func publishVisibleTypers() {
        let next: [String]
        if spectate || !isViewingLive {
            next = []
        } else if let selTab = selectedSpeechMeetingId {
            let viewerDead = selfId.map { deadIds.contains($0) } ?? false
            next = typingOrder.filter { id in
                guard typingByPlayerId[id] == selTab else { return false }
                return deadIds.contains(id) == viewerDead
            }
        } else {
            next = []
        }
        if next != typingPlayerIds {
            typingPlayerIds = next
        }
    }

    private func pruneTypingToVisibleMeetings() {
        let visible = Set(speechChannels.map(\.id))
        let stale = typingOrder.filter { id in
            guard let meetingId = typingByPlayerId[id] else { return true }
            return !visible.contains(meetingId)
        }
        for id in stale {
            typingExpireTasks[id]?.cancel()
            typingExpireTasks[id] = nil
            typingByPlayerId.removeValue(forKey: id)
        }
        if !stale.isEmpty {
            typingOrder.removeAll { stale.contains($0) }
        }
        publishVisibleTypers()
    }

    private func displaceToLobby() {
        guard !displaced, !weInitiatedLeave else { return }
        leftByServer = true
        displaced = true
        connected = false
        expectDisconnect = true
        socket.disconnect()
    }

    #if DEBUG
    /// DiagReplay: feed a synthetic socket event through the real handler.
    func debugFeed(_ event: String, _ data: Any?) { handle(event, data) }
    /// DiagReplay: sees what speak / quote / takeSeat would send, to fake the server's answer.
    @ObservationIgnored var debugSendHook: ((String, [String: Any]) -> Void)?
    #endif

    private func handle(_ event: String, _ data: Any?) {
        switch event {
        case "connected":
            connected = true
            if let token, !token.isEmpty {
                socket.send("auth", object: token)
            } else {
                join()
            }
        case "authSuccess":
            join()
        case "loaded":
            loaded = true
            GameWinMusic.unlockSession()
            GameSFX.warm("bell")
            GameSFX.warm("gunshot")
            GameSFX.warm("readyCheck")
            GameWinMusic.warmCommon()
        case "self":
            if let id = stringValue(data) {
                selfId = id
                adoptKnownRolesForSelf()
            }
        case "options":
            if let o = data as? [String: Any] {
                rankedGame = (o["ranked"] as? Bool) ?? false
                if let decks = o["anonymousDeck"] as? [Any], !decks.isEmpty {
                    UMDeckCache.store(decks)
                    anonymousDeckIds = decks.compactMap { ($0 as? [String: Any])?["id"] as? String }
                }
                competitiveGame = (o["competitive"] as? Bool) ?? false
                // Web settingIsTrueValue: true or "true".
                spectatingAllowed = (o["spectating"] as? Bool) ?? ((o["spectating"] as? String) == "true")
                graveyardParticipation = (o["graveyardParticipation"] as? Bool) ?? false
            }
        case "setup":
            applySetup(data)
        case "players":
            players = parsePlayers(data, keyOrder: umJSONTopLevelKeys(socket.lastObjectJSON))
            formerPlayerIds.formUnion(players.map(\.id))
        case "spectators":
            var next: [String: GamePlayer] = [:]
            // Server getAllSpectatorInfo also sends spectatorsOld, which includes players who left
            // pregame (createPlayerGoneObj); those seats are never spectators.
            var order: [String] = []
            for p in parsePlayers(data, keyOrder: umJSONTopLevelKeys(socket.lastObjectJSON)) where !formerPlayerIds.contains(p.id) {
                next[p.id] = p
                order.append(p.id)
            }
            var notWatching: Set<String> = []
            if let obj = data as? [String: Any] {
                for (id, v) in obj {
                    if let info = v as? [String: Any], let w = info["watching"] as? Bool, !w { notWatching.insert(id) }
                }
            }
            notWatchingIds = notWatching
            spectatorOrder = order
            spectatorPlayers = next
        case "spectatorCount":
            if let n = intValue(data) { spectatorCount = max(0, n) }
        case "omniscientSpectator":
            omniscientSpectator = true
        case "takeSeatFailed":
            takeSeatPending = false
            takeSeatFailure = stringValue(data) ?? "You can't take a seat right now."

        case "playerJoin":
            if let p = parsePlayer(data) {
                formerPlayerIds.insert(p.id)
                spectatorPlayers[p.id] = nil
                players.removeAll { $0.id == p.id }
                players.append(p)
                players = orderedPlayers(players)
            }
        case "playerLeave":
            if let id = stringValue(data) {
                formerPlayerIds.insert(id)
                spectatorPlayers[id] = nil
                players.removeAll { $0.id == id }
                dropTyper(id)
            }
        case "state":
            applyState(data)
        case "diceRoll", "diceRoll2":
            // Liars Dice new round: play the file the event names, once.
            if !isQuiet { GameSFX.play(event) }
        case "history":
            ingestHistory(data)
        case "message":
            if var line = parseMessage(data) {
                line.fromState = currentPhaseId
                let isNew = !seenMessageIds.contains(line.id)
                if isNew, !isQuiet { UMDiag.messageReceived(line.id) }
                appendLine(line)
                if isNew, !isQuiet, mentionsSelf(line) {
                    GameSFX.play("ping")
                    onMention?()
                }
            }
        case "quote":
            if var line = parseQuote(data) {
                line.fromState = currentPhaseId
                appendLine(line)
            }
        case "speakCooldown":
            applySpeakCooldown(data)
        case "timerInfo":
            applyTimerInfo(data)
        case "clearTimer":
            if let name = stringValue(data) {
                clocks.removeValue(forKey: name)
            }
        case "time":
            applyTimerSync(data)
        case "meeting":
            refreshMeetings(from: data, replaceAll: false)
        case "meetings":
            refreshMeetings(from: data, replaceAll: true)
        case "leftMeeting":
            let id = stringValue(data)
                ?? (data as? [String: Any])?["meetingId"] as? String
                ?? (data as? [String: Any])?["id"] as? String
            removeMeeting(id)
        case "members":
            break
        case "vote", "unvote":
            applyVote(data, unvote: event == "unvote")
        case "finished":
            finished = true
            stateName = "Finished"
        case "left":
            connected = false
            if weInitiatedLeave {
                leftByServer = true
            } else {
                displaceToLobby()
            }
            expectDisconnect = true
            socket.disconnect()
        case "disconnected":
            connected = false
            if !expectDisconnect, !weInitiatedLeave, !finished {
                displaceToLobby()
            }
        case "error":
            errorMessage = stringValue(data) ?? "Game error"
        case "isSpectator":
            // Server: sendSelf on a spectator sends it bare (true); takeSeat sends false.
            spectateRequestPending = false
            takeSeatPending = false
            if !isReview { spectate = (data as? Bool) != false }
            if !spectate { omniscientSpectator = false }
        case "spectateFailed":
            spectateRequestPending = false
            spectateFailure = stringValue(data) ?? "You can't move to spectators right now."
        case "banned":
            errorMessage = "Banned from this game."
            weInitiatedLeave = true
            leftByServer = true
        case "p":
            break
        case "typing":
            applyIncomingTyping(data)
        case "roleReveal":
            applyRoleReveal(data)
        case "reveal":
            applyReveal(data)
        case "gunshot":
            if !isQuiet { GameSFX.play("gunshot") }
        case "audio":
            if !isQuiet, let name = stringValue(data), name == "gunshot" {
                GameSFX.play("gunshot")
            }
        case "death":
            if let id = stringValue(data) { markDead(id, dead: true) }
        case "deathSounds":
            // Site: "Ignore all Death Sounds" skips every custom death sound (default SFX unaffected).
            if !isQuiet, !UMViewerPrefs.shared.ignoreDeathSounds {
                GameSFX.playRemoteQueue(stringList(data))
            }
        case "revival":
            if let id = stringValue(data) { markDead(id, dead: false) }
        case "obituaries":
            applyObituaries(data)
        case "winners":
            applyWinners(data)
        case "readyCheck init":
            applyReadyCheckInit(data)
        case "readyCheck cancel", "readyCheck success":
            clearReadyCheck()
        case "readyCheck update":
            if let obj = data as? [String: Any], let id = obj["playerId"] as? String,
               readyPlayerIds.insert(id).inserted, !isQuiet {
                // Web Game.jsx: playAudio("readyCheck") on every "readyCheck update".
                GameSFX.play("readyCheck")
            }
        default:
            break
        }
    }

    private func join() {
        guard !didJoin else { return }
        didJoin = true
        socket.send("join", object: [
            "gameId": gameId,
            "isBot": false,
        ])
    }

    private func ingestHistory(_ data: Any?) {
        ingestingHistory = true
        defer { ingestingHistory = false }
        guard let states = data as? [String: Any] else { return }
        // Web order: Pregame (-1), 0, 1, …, then Postgame (-2) last (its dead map includes the final lynch).
        func rank(_ k: String) -> Int { let i = Int(k) ?? 0; return i == -2 ? Int.max : i }
        let keys = states.keys.sorted { rank($0) < rank($1) }
        var lines: [ChatLine] = []
        for key in keys {
            guard let state = states[key] as? [String: Any] else { continue }
            if let name = state["name"] as? String, key == keys.last {
                stateName = name
            }
            let phaseId = Int(key) ?? 0
            let phaseName = (state["name"] as? String) ?? (key == "-1" ? "Pregame" : "State")
            var phaseDay: Int?
            if let d = state["dayCount"] as? Int { phaseDay = d }
            if let d = state["dayCount"] as? Double { phaseDay = Int(d) }
            ensurePhase(id: phaseId, name: phaseName, dayCount: phaseDay)
            if let ld = LDState(state["extraInfo"]) { ldByPhase[phaseId] = ld }
            applyDeadMap(state["dead"])
            deadByPhase[phaseId] = Self.deadSet(state["dead"])
            let rolesBefore = knownRoles
            applyKnownRolesMap(state["roles"])
            let deadNow = Self.deadSet(state["dead"])
            if let roles = state["roles"] as? [String: Any] {
                for (pid, val) in roles {
                    guard let role = val as? String, !role.isEmpty, deadNow.contains(pid),
                          rolesBefore[pid] != role else { continue }
                    deathRevealedRoles[pid] = role
                }
            }
            if key == keys.last {
                currentPhaseId = phaseId
                viewingPhaseId = phaseId
                followLive = true
            }
            if let winners = state["winners"] {
                applyWinners(winners, phaseId: phaseId)
            }
            if let obits = state["obituaries"] as? [String: Any] {
                for (_, val) in obits {
                    if let line = applyObituaries(val, phaseId: phaseId) {
                        lines.append(line)
                    }
                }
            } else if let obits = state["obituaries"] as? [Any] {
                for val in obits {
                    if let line = applyObituaries(val, phaseId: phaseId) {
                        lines.append(line)
                    }
                }
            }
            if let alerts = state["alerts"] as? [Any] {
                for alert in alerts {
                    if var line = parseMessage(alert) {
                        line.fromState = phaseId
                        lines.append(line)
                    }
                }
            }
            if let meetings = state["meetings"] as? [String: Any] {
                if key == keys.last {
                    refreshMeetings(from: meetings, replaceAll: true)
                } else if let i = phases.firstIndex(where: { $0.id == phaseId }) {
                    phases[i].meetings = extractVoteMeetings(from: meetings)
                }
                var quotes: [Any] = []
                for (mid, mval) in meetings {
                    guard let meeting = mval as? [String: Any] else { continue }
                    if (meeting["name"] as? String) == "Spectator Meeting" { spectatorMeetingIds.insert(mid) }
                    if let msgs = meeting["messages"] as? [Any] {
                        for msg in msgs {
                            if boolValue((msg as? [String: Any])?["isQuote"]) {
                                quotes.append(msg)
                                continue
                            }
                            if var line = parseMessage(msg) {
                                line.fromState = phaseId
                                lines.append(line)
                                ingestBuffer.append(line)
                            }
                        }
                    }
                    if let recs = meeting["voteRecord"] as? [Any] {
                        for rec in recs {
                            if let line = parseVoteRecord(rec, phaseId: phaseId) {
                                lines.append(line)
                            }
                        }
                    }
                }
                for msg in quotes {
                    if var line = parseQuote(msg) {
                        line.fromState = phaseId
                        lines.append(line)
                    }
                }
            }
        }
        lines.sort { $0.time < $1.time }
        ingestBuffer = lines
        for line in lines { appendLine(line) }
        ingestBuffer = []
        messages.sort { $0.time < $1.time }
        adoptKnownRolesForSelf()
        persistRoleMarks()
        fillPaperReveals()
    }

    /// Papers whose obituary had no reveal take the role (or alignment) the server broadcast for
    /// that player at their death. Never invents one: no death reveal, nothing shown.
    private func fillPaperReveals() {
        guard !deathRevealedRoles.isEmpty else { return }
        for (phase, bag) in newspapers {
            var updated = bag
            var changed = false
            for (source, issue) in bag {
                var paper = issue
                for i in paper.deaths.indices {
                    let d = paper.deaths[i]
                    guard d.revealRoleRaw == nil, d.revealLine == nil else { continue }
                    let pid = d.playerId
                        ?? players.first(where: { $0.name == d.name })?.id
                        ?? players.first(where: { $0.userId != nil && $0.userId == d.userId })?.id
                    guard let pid, let role = deathRevealedRoles[pid],
                          let reveal = NewspaperCopy.reveal(fromRole: role, playerName: d.name) else { continue }
                    paper.deaths[i].revealLine = reveal.line
                    paper.deaths[i].revealRoleRaw = reveal.roleRaw
                    paper.deaths[i].revealSuffix = reveal.suffix
                    changed = true
                }
                updated[source] = paper
            }
            if changed { newspapers[phase] = updated }
        }
    }

    /// Fired for each live chat message that pings this player (see `mentionsSelf`).
    @ObservationIgnored var onMention: (() -> Void)?

    /// Web Game.jsx rule: tokens matching /@[\w-]*/ in a live "message" event; a ping is an
    /// exact (case-sensitive) "@<my in-game name>" or any token starting with "@every".
    /// Only seated players get pings. Unlike web, the app ignores the user's own messages.
    private func mentionsSelf(_ line: ChatLine) -> Bool {
        guard !line.isServer, let selfId, line.senderId != selfId,
              let me = players.first(where: { $0.id == selfId }) else { return false }
        guard let re = try? NSRegularExpression(pattern: "@[\\w-]*") else { return false }
        let text = line.content as NSString
        let tokens = re.matches(in: line.content, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range) }
        return tokens.contains("@" + me.name) || tokens.contains { $0.hasPrefix("@every") }
    }

    private func appendLine(_ line: ChatLine) {
        if seenMessageIds.contains(line.id) { return }
        seenMessageIds.insert(line.id)
        messages.append(line)
        let phaseId = line.fromState ?? currentPhaseId
        if let i = phases.firstIndex(where: { $0.id == phaseId }) {
            phases[i].messages.append(line)
        } else {
            ensurePhase(id: phaseId, name: stateName, dayCount: dayCount)
            if let i = phases.firstIndex(where: { $0.id == phaseId }) {
                phases[i].messages.append(line)
            }
        }
        if messages.count > 800 {
            let dropped = messages.prefix(messages.count - 800)
            for old in dropped { seenMessageIds.remove(old.id) }
            messages.removeFirst(messages.count - 800)
        }
        if !ingestingHistory {
            maybeNotifyMention(line)
        }
    }

    private func maybeNotifyMention(_ line: ChatLine) {
        guard isLobbyPhase, !spectate else { return }
        guard !line.isServer, !line.isQuote else { return }
        if let selfId, line.senderId == selfId { return }
        guard let me = selfPlayer?.name, !me.isEmpty else { return }
        let tokens = pingTokens(in: line.content)
        let needle = "@" + me
        if tokens.contains(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
            GameAlerts.notifyMention()
        }
    }

    private func pingTokens(in text: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "@" {
                var j = i + 1
                while j < chars.count {
                    let c = chars[j]
                    if c.isLetter || c.isNumber || c == "_" || c == "-" {
                        j += 1
                    } else {
                        break
                    }
                }
                tokens.append(String(chars[i..<j]))
                i = j
            } else {
                i += 1
            }
        }
        return tokens
    }

    /// Desktop `Number.isFinite(playerListPosition)`. Strings like "0" do not count.
    private func umFiniteListPosition(_ any: Any?) -> Double? {
        if any == nil || any is NSNull { return nil }
        if any is String { return nil }
        if any is Bool { return nil }
        if let d = any as? Double, d.isFinite { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        return nil
    }

    private func parsePlayers(_ data: Any?, keyOrder: [String] = []) -> [GamePlayer] {
        if let obj = data as? [String: Any], let ids = obj["players"] as? [Any], let names = obj["names"] as? [Any] {
            let users = obj["users"] as? [Any] ?? []
            let leftIds: Set<String> = {
                if let arr = obj["left"] as? [String] { return Set(arr) }
                if let arr = obj["left"] as? [Any] { return Set(arr.compactMap { $0 as? String }) }
                return []
            }()
            var result: [GamePlayer] = []
            for i in 0..<ids.count {
                guard let id = ids[i] as? String else { continue }
                var blob: [String: Any] = ["id": id, "name": (names[i] as? String) ?? "Player"]
                if i < users.count, let user = users[i] as? [String: Any] {
                    blob["userId"] = user["id"]
                    blob["avatar"] = user["avatar"]
                    blob["settings"] = user["settings"]
                }
                blob["left"] = leftIds.contains(id)
                if let p = parsePlayer(blob) { result.append(p) }
            }
            return orderedPlayers(result)
        }
        if let dict = data as? [String: Any] {
            let looksLikePlayerMap = dict.values.contains { $0 is [String: Any] }
            if looksLikePlayerMap {
                var result: [GamePlayer] = []
                let keys = keyOrder.isEmpty ? Array(dict.keys) : keyOrder
                for key in keys {
                    guard let val = dict[key] else { continue }
                    var blob = val as? [String: Any] ?? [:]
                    if blob["id"] == nil { blob["id"] = key }
                    if let p = parsePlayer(blob) { result.append(p) }
                }
                if result.isEmpty {
                    result = dict.values.compactMap(parsePlayer)
                }
                return orderedPlayers(result)
            }
        }
        if let arr = data as? [Any] {
            return orderedPlayers(arr.compactMap(parsePlayer))
        }
        return players
    }

    private func parsePlayer(_ data: Any?) -> GamePlayer? {
        guard let obj = data as? [String: Any], let id = obj["id"] as? String else { return nil }
        let settings = (obj["settings"] as? [String: Any]) ?? obj
        let rawAvatar = obj["avatar"] ?? (obj["user"] as? [String: Any])?["avatar"]
        let deckPath = UMAvatarURL.deckPath(rawAvatar)
        let anonId: String? = {
            if let s = obj["anonId"] as? String { return s }
            if let n = obj["anonId"] as? NSNumber { return n.stringValue }
            return nil
        }()
        return GamePlayer(
            id: id,
            name: obj["name"] as? String ?? "Player",
            userId: (obj["userId"] as? String) ?? (obj["user"] as? [String: Any])?["id"] as? String,
            avatar: deckPath != nil || boolValue(obj["avatar"]) || boolValue((obj["user"] as? [String: Any])?["avatar"]),
            deckAvatarPath: deckPath,
            anonId: anonId,
            left: boolValue(obj["left"]),
            textColorHex: umColorString(settings["textColor"]),
            nameColorHex: umColorString(settings["nameColor"]),
            nameFont: settings["nameFont"] as? String,
            squareAvatar: ((obj["avatarShape"] as? String) ?? (settings["gameAvatarShape"] as? String)) == "square",
            animatedNameColor: settings["animatedNameColor"] as? String,
            nameGradientColorA: umColorString(settings["nameGradientColorA"]),
            nameGradientColorB: umColorString(settings["nameGradientColorB"]),
            nameGradientColorC: umColorString(settings["nameGradientColorC"]),
            playerListPosition: umFiniteListPosition(obj["playerListPosition"]),
            customEmotes: mediaMap(settings["customEmotes"] ?? obj["customEmotes"]),
            customStickers: mediaMap(settings["customStickers"] ?? obj["customStickers"])
        )
    }

    private func mediaMap(_ any: Any?) -> [String: String] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let obj = value as? [String: Any] {
                if let path = obj["path"] as? String { out[key.lowercased()] = path }
                else if let url = obj["url"] as? String { out[key.lowercased()] = url }
            } else if let s = value as? String {
                out[key.lowercased()] = s
            }
        }
        return out
    }

    private func parseMessage(_ data: Any?) -> ChatLine? {
        guard let obj = data as? [String: Any] else { return nil }
        let content: String
        if let s = obj["content"] as? String, !s.isEmpty { content = s }
        else if let s = obj["messageContent"] as? String, !s.isEmpty { content = s }
        else if let s = obj["text"] as? String, !s.isEmpty { content = s }
        else { return nil }
        let senderId = obj["senderId"] as? String ?? "server"
        let time: Date
        if let t = obj["time"] as? Double {
            time = Date(timeIntervalSince1970: t > 10_000_000_000 ? t / 1000 : t)
        } else if let t = obj["time"] as? Int {
            let v = Double(t)
            time = Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        } else {
            time = Date()
        }
        let name: String
        if senderId == "server" { name = "Server" }
        else if senderId == "vote" { name = "Vote" }
        else if senderId == "anonymous" { name = "Anonymous" }
        else { name = players.first(where: { $0.id == senderId })?.name ?? spectatorPlayers[senderId]?.name ?? (obj["senderName"] as? String) ?? "Player" }
        let isQuote = boolValue(obj["isQuote"])
        return ChatLine(
            id: (obj["id"] as? String) ?? UUID().uuidString,
            senderId: senderId,
            senderName: name,
            content: content,
            time: time,
            isServer: senderId == "server" || senderId == "vote",
            meetingId: obj["meetingId"] as? String ?? obj["toMeetingId"] as? String,
            prefix: obj["prefix"] as? String,
            customEmotes: mediaMap(obj["customEmotes"]),
            customStickers: mediaMap(obj["customStickers"]),
            isQuote: isQuote,
            quotable: !isQuote && senderId != "server" && senderId != "vote",
            fromState: intValue(obj["fromState"]),
            senderWasDead: deadWhenSent(senderId: senderId, alive: obj["alive"]),
            aliveFlagKnown: !(obj["alive"] == nil || obj["alive"] is NSNull)
        )
    }

    private func removeMeeting(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        meetings.removeAll { $0.id == id }
        snapshotLiveMeetings()
        speechChannels.removeAll { $0.id == id }
        if selectedSpeechMeetingId == id {
            selectedSpeechMeetingId = speechChannels.first(where: { $0.canTalk })?.id ?? speechChannels.first?.id
            canTalk = speechChannels.first(where: { $0.id == selectedSpeechMeetingId })?.canTalk ?? false
        }
        pruneTypingToVisibleMeetings()
    }

    private func sortedVoteTargets(_ targets: [String]) -> [String] {
        let specials = ["*", "*magus"]
        return targets.filter { !specials.contains($0) } + specials.filter { targets.contains($0) }
    }

    private func refreshMeetings(from data: Any?, replaceAll: Bool) {
        var nextVotes = replaceAll ? [] : meetings
        var nextSpeech = replaceAll ? [] : speechChannels
        let blobs: [[String: Any]]
        if let obj = data as? [String: Any] {
            if obj["id"] != nil {
                blobs = [obj]
            } else {
                blobs = obj.values.compactMap { $0 as? [String: Any] }
            }
        } else if let arr = data as? [Any] {
            blobs = arr.compactMap { $0 as? [String: Any] }
        } else {
            return
        }
        for obj in blobs {
            guard let id = obj["id"] as? String else { continue }
            let speech = boolValue(obj["speech"])
            if speech {
                let amMember = obj["amMember"] as? Bool ?? true
                let can = obj["canTalk"] as? Bool ?? true
                let abilities = parseAbilities(obj["speechAbilities"])
                let meetingName = (obj["name"] as? String) ?? "Chat"
                let channel = SpeechChannel(
                    id: id,
                    name: meetingName,
                    canTalk: can && amMember && (!spectate || Self.spectatorMayTalk(in: meetingName, pregame: isPregame)),
                    abilities: abilities
                )
                nextSpeech.removeAll { $0.id == id }
                if channel.name == "Spectator Meeting" { spectatorMeetingIds.insert(id) }
                if amMember || spectate {
                    nextSpeech.append(channel)
                }
                if amMember && (selectedSpeechMeetingId == nil || can) {
                    if channel.name != "Spectator Meeting" || nextSpeech.count == 1 {
                        selectedSpeechMeetingId = id
                        canTalk = channel.canTalk
                    }
                }
                // Village day is one meeting with speech AND voting. Fall through so Act gets the vote.
                if !boolValue(obj["voting"]) {
                    continue
                }
            }
            let voting = boolValue(obj["voting"])
            if !voting {
                nextVotes.removeAll { $0.id == id }
                continue
            }
            let targets = sortedVoteTargets((obj["targets"] as? [Any] ?? []).compactMap { $0 as? String })
            let votes = parseBallot(obj["votes"])
            let hiddenVoters = parseHiddenVoterIds(obj["votes"])
            let memberList = parseMembers(obj["members"])
            var amMember = obj["amMember"] as? Bool ?? true
            var can = obj["canVote"] as? Bool
            if let selfId, let me = memberList.first(where: { $0.id == selfId }) {
                amMember = true
                if can == nil { can = me.canVote }
            }
            let canVote = (can ?? (amMember && voting)) && amMember && !spectate
            let name = (obj["name"] as? String) ?? "Vote"
            let canUnvote = obj["canUnvote"] as? Bool ?? !boolValue(obj["noUnvote"])
            let meeting = VoteMeeting(
                id: id,
                name: name,
                actionName: (obj["actionName"] as? String) ?? name,
                canVote: canVote,
                canUnvote: canUnvote,
                targets: targets,
                votes: votes,
                hiddenVoterIds: hiddenVoters,
                inputType: obj["inputType"] as? String ?? "player",
                amMember: amMember,
                displayVoteCounter: boolValue(obj["displayVoteCounter"]),
                noOneDisplayName: obj["noOneDisplayName"] as? String,
                anonymous: boolValue(obj["anonymous"]),
                anonymousVotes: boolValue(obj["anonymousVotes"]),
                votesInvisible: boolValue(obj["votesInvisible"]),
                multi: boolValue(obj["multi"]),
                members: memberList,
                itemName: obj["itemName"] as? String,
                itemIsTrueItem: boolValue(obj["itemIsTrueItem"]),
                instant: boolValue(obj["instant"]),
                instantButChangeable: boolValue(obj["instantButChangeable"]),
                noUnvote: boolValue(obj["noUnvote"]),
                playerHasVoted: boolValue(obj["playerHasVoted"])
            )
            let meetingName = name.lowercased()
            if meetingName.contains("mafia") || meetingName.contains("cult") {
                for member in memberList where member.id != selfId {
                    teammateIds.insert(member.id)
                }
            }
            nextVotes.removeAll { $0.id == id }
            nextVotes.append(meeting)
        }
        // JSON objects decode unordered; keep meetings where they already were so the Act tab
        // switcher order doesn't shuffle between updates (new meetings go last).
        let prior = Dictionary(meetings.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        meetings = nextVotes.enumerated().sorted { a, b in
            switch (prior[a.element.id], prior[b.element.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        snapshotLiveMeetings()
        maybeNotifyKicks(nextVotes)
        speechChannels = nextSpeech.filter { $0.name != "Spectator Meeting" || spectate }
        // Re-pick when the selection is gone OR can't talk while another channel can. Spectators get
        // the village (amMember false, canTalk false) and the Spectator Meeting as separate `meeting`
        // events; the village arrived first and stayed selected, so speak went to a meeting the
        // server silently ignores (Meeting.speak: not a member) and their own lines never echoed.
        let selectedCanTalk = speechChannels.first(where: { $0.id == selectedSpeechMeetingId })?.canTalk
        if selectedSpeechMeetingId == nil || selectedCanTalk == nil
            || (selectedCanTalk == false && speechChannels.contains(where: { $0.canTalk })) {
            selectedSpeechMeetingId = speechChannels.first(where: { $0.canTalk })?.id ?? speechChannels.first?.id
        }
        if let id = selectedSpeechMeetingId, let ch = speechChannels.first(where: { $0.id == id }) {
            canTalk = ch.canTalk
            if ch.canTalk { lastTalkMeetingId = id }
        } else if let talk = speechChannels.first(where: { $0.canTalk }) {
            lastTalkMeetingId = talk.id
        }
        if !speechOptions.contains(where: { $0.id == selectedSpeechOptionId }) {
            selectedSpeechOptionId = "Say"
        }
        pruneTypingToVisibleMeetings()
    }

    private func snapshotLiveMeetings() {
        guard let i = phases.firstIndex(where: { $0.id == currentPhaseId }) else { return }
        phases[i].meetings = meetings
    }

    private func meetingBlobs(_ data: Any?) -> [[String: Any]] {
        if let obj = data as? [String: Any] {
            if obj["id"] != nil { return [obj] }
            return obj.values.compactMap { $0 as? [String: Any] }
        }
        if let arr = data as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private func extractVoteMeetings(from data: Any?) -> [VoteMeeting] {
        var nextVotes: [VoteMeeting] = []
        for obj in meetingBlobs(data) {
            guard let id = obj["id"] as? String, boolValue(obj["voting"]) else { continue }
            let targets = sortedVoteTargets((obj["targets"] as? [Any] ?? []).compactMap { $0 as? String })
            let votes = parseBallot(obj["votes"])
            let hiddenVoters = parseHiddenVoterIds(obj["votes"])
            let memberList = parseMembers(obj["members"])
            var amMember = obj["amMember"] as? Bool ?? true
            var can = obj["canVote"] as? Bool
            if let selfId, let me = memberList.first(where: { $0.id == selfId }) {
                amMember = true
                if can == nil { can = me.canVote }
            }
            let name = (obj["name"] as? String) ?? "Vote"
            nextVotes.append(VoteMeeting(
                id: id,
                name: name,
                actionName: (obj["actionName"] as? String) ?? name,
                canVote: (can ?? amMember) && amMember && !spectate,
                canUnvote: obj["canUnvote"] as? Bool ?? !boolValue(obj["noUnvote"]),
                targets: targets,
                votes: votes,
                hiddenVoterIds: hiddenVoters,
                inputType: obj["inputType"] as? String ?? "player",
                amMember: amMember,
                displayVoteCounter: boolValue(obj["displayVoteCounter"]),
                noOneDisplayName: obj["noOneDisplayName"] as? String,
                anonymous: boolValue(obj["anonymous"]),
                anonymousVotes: boolValue(obj["anonymousVotes"]),
                votesInvisible: boolValue(obj["votesInvisible"]),
                multi: boolValue(obj["multi"]),
                members: memberList,
                itemName: obj["itemName"] as? String,
                itemIsTrueItem: boolValue(obj["itemIsTrueItem"]),
                instant: boolValue(obj["instant"]),
                instantButChangeable: boolValue(obj["instantButChangeable"]),
                noUnvote: boolValue(obj["noUnvote"]),
                playerHasVoted: boolValue(obj["playerHasVoted"])
            ))
        }
        return nextVotes
    }

    private func parseAbilities(_ data: Any?) -> [SpeechAbility] {
        guard let arr = data as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let obj = item as? [String: Any], let name = obj["name"] as? String else { return nil }
            let targets = (obj["targets"] as? [Any] ?? []).compactMap { $0 as? String }
            return SpeechAbility(
                name: name,
                verb: (obj["verb"] as? String) ?? "to",
                targetType: (obj["targetType"] as? String) ?? "player",
                targets: targets
            )
        }
    }

    private func parseBallot(_ raw: Any?) -> [String: [String]] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (key, val) in dict {
            if val is NSNull { continue }
            if let s = val as? String { out[key] = [s]; continue }
            if let arr = val as? [Any] {
                let sel = arr.compactMap { $0 as? String }
                if !sel.isEmpty { out[key] = sel }
            }
        }
        return out
    }

    private func parseHiddenVoterIds(_ raw: Any?) -> Set<String> {
        guard let dict = raw as? [String: Any] else { return [] }
        return Set(dict.compactMap { key, value in value is NSNull ? key : nil })
    }

    private func parseMembers(_ raw: Any?) -> [VoteMember] {
        if let arr = raw as? [Any] {
            return arr.compactMap { item in
                if let obj = item as? [String: Any], let id = obj["id"] as? String {
                    return VoteMember(
                        id: id,
                        canVote: boolValue(obj["canVote"]),
                        canUpdateVote: obj["canUpdateVote"] as? Bool ?? true
                    )
                }
                if let id = item as? String {
                    return VoteMember(id: id, canVote: true, canUpdateVote: true)
                }
                return nil
            }
        }
        if let dict = raw as? [String: Any] {
            return dict.keys.sorted().map { key in
                if let obj = dict[key] as? [String: Any] {
                    return VoteMember(
                        id: (obj["id"] as? String) ?? key,
                        canVote: boolValue(obj["canVote"]),
                        canUpdateVote: obj["canUpdateVote"] as? Bool ?? true
                    )
                }
                return VoteMember(id: key, canVote: true, canUpdateVote: true)
            }
        }
        return []
    }

    private func applyVote(_ data: Any?, unvote: Bool) {
        guard let obj = data as? [String: Any] else { return }
        let meetingId = obj["meetingId"] as? String
        let voter = obj["voterId"] as? String
        let target = obj["target"] as? String
        if let meetingId, let voter, let idx = meetings.firstIndex(where: { $0.id == meetingId }) {
            if unvote {
                meetings[idx].hiddenVoterIds.remove(voter)
                if meetings[idx].multi, let target {
                    meetings[idx].votes[voter]?.removeAll { $0 == target }
                    if meetings[idx].votes[voter]?.isEmpty == true {
                        meetings[idx].votes[voter] = nil
                    }
                } else {
                    meetings[idx].votes[voter] = nil
                }
            } else if let target {
                meetings[idx].hiddenVoterIds.remove(voter)
                if meetings[idx].multi {
                    var cur = meetings[idx].votes[voter] ?? []
                    if !cur.contains(target) { cur.append(target) }
                    meetings[idx].votes[voter] = cur
                } else {
                    meetings[idx].votes[voter] = [target]
                }
            } else if voter != selfId {
                meetings[idx].hiddenVoterIds.insert(voter)
                if meetings[idx].votes[voter] == nil {
                    meetings[idx].votes[voter] = ["*unknown"]
                }
            }
        }
        snapshotLiveMeetings()
        if boolValue(obj["noLog"]) { return }
        guard let voter else { return }
        let voterName = displayName(for: voter)
        let content: String
        if unvote {
            content = "\(voterName) unvotes"
        } else {
            content = "\(voterName) votes \(displayName(for: target ?? ""))"
        }
        appendLine(ChatLine(
            id: "vote:\(voter):\(target ?? "unvote"):\(Date().timeIntervalSince1970)",
            senderId: "vote",
            senderName: "Vote",
            content: content,
            time: Date(),
            isServer: true,
            meetingId: meetingId,
            prefix: nil,
            isQuote: false,
            quotable: false,
            fromState: currentPhaseId
        ))
    }

    private func stringValue(_ data: Any?) -> String? {
        if let s = data as? String { return s }
        if let n = data as? NSNumber { return n.stringValue }
        return nil
    }

    private func stringList(_ data: Any?) -> [String] {
        if let arr = data as? [String] { return arr }
        if let arr = data as? [Any] { return arr.compactMap(stringValue) }
        if let s = stringValue(data) { return [s] }
        return []
    }

    private func boolValue(_ data: Any?) -> Bool {
        if let b = data as? Bool { return b }
        if let n = data as? NSNumber { return n.boolValue }
        if let s = data as? String { return s == "true" || s == "1" }
        return false
    }

    private func applyReadyCheckInit(_ data: Any?) {
        let obj = data as? [String: Any]
        readyCheckActive = true
        readyPlayerIds = []
        if let arr = obj?["readyPlayers"] as? [Any] {
            for item in arr {
                if let id = item as? String { readyPlayerIds.insert(id) }
            }
        }
        if let end = dateFromMillis(obj?["endTime"]) {
            readyEndTime = end
        } else {
            readyEndTime = Date().addingTimeInterval(30)
        }
        ReadyNotifications.notifyIfBackgrounded()
        if needsReadyConfirm, !isReview { ReadyBell.start() }
    }

    private func dateFromMillis(_ any: Any?) -> Date? {
        let n: Double
        if let d = any as? Double { n = d }
        else if let i = any as? Int { n = Double(i) }
        else if let num = any as? NSNumber { n = num.doubleValue }
        else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }

    private func applyState(_ data: Any?) {
        guard let obj = data as? [String: Any] else { return }
        let name = obj["name"] as? String ?? stateName
        var id: Int = currentPhaseId + 1
        if let n = intValue(obj["id"]) { id = n }
        var day: Int? = dayCount
        if let d = obj["dayCount"] as? Int { day = d }
        if let d = obj["dayCount"] as? Double { day = Int(d) }
        let phaseChanged = id != currentPhaseId
        if phaseChanged {
            UMDiag.log("phase", "start \(currentPhaseId) -> \(id) \(name)")
            let started = CACurrentMediaTime()
            let spID = UMDiag.signposter.makeSignpostID()
            let sp = UMDiag.signposter.beginInterval("phaseChange", id: spID)
            DispatchQueue.main.async {
                UMDiag.signposter.endInterval("phaseChange", sp)
                UMDiag.log("phase", "end \(id) after \(Int((CACurrentMediaTime() - started) * 1000))ms (next runloop)")
            }
        }
        stateName = name
        dayCount = day
        ensurePhase(id: id, name: name, dayCount: day)
        currentPhaseId = id
        if let ld = LDState(obj["extraInfo"]) {
            let old = ldByPhase.filter { $0.key >= 0 && $0.key < id }.max { $0.key < $1.key }?.value ?? ldByPhase[id]
            ldByPhase[id] = ld
            if !isQuiet, phaseChanged || old != ld { LDEvents.handle(old: old, new: ld, selfId: selfId) }
        }
        if followLive {
            viewingPhaseId = id
        }
        if name.lowercased() == "postgame" || id == -2 {
            finished = true
        }
        // Official client only empties meetings when the state id is new.
        // Re-sent pregame/current state must keep Village chat or speak has no meetingId.
        if phaseChanged {
            snapshotLiveMeetings()
            meetings = []
            speechChannels = []
            selectedSpeechMeetingId = nil
            canTalk = false
            clearAllTyping()
        }
        if !isQuiet {
            // Liars Dice: every turn is a new state; desktop plays only ping (handled by LDEvents).
            let skipBell = name.lowercased().hasPrefix("give clue") || isLiarsDice
            if playBell, !skipBell, phaseChanged {
                GameSFX.play("bell")
            }
            playBell = true
            if phaseChanged, !isLiarsDice {
                GameMusic.handlePhase(name)
            }
        }
    }

    private func ensurePhase(id: Int, name: String, dayCount: Int?) {
        if let i = phases.firstIndex(where: { $0.id == id }) {
            phases[i].name = name
            if let dayCount { phases[i].dayCount = dayCount }
            return
        }
        phases.append(GamePhase(id: id, name: name, dayCount: dayCount))
    }

    private func applyRoleReveal(_ data: Any?) {
        guard let obj = data as? [String: Any] else { return }
        let playerId = obj["playerId"] as? String
        let role = obj["role"] as? String
        if let playerId, let role {
            knownRoles[playerId] = role
        }
        if playerId == selfId || (selfId == nil && playerId != nil) {
            if let roleData = obj["roleData"] as? [String: Any] {
                selfRoleName = roleData["roleName"] as? String ?? role?.split(separator: ":").first.map(String.init)
                selfRoleCategory = roleData["category"] as? String
                if let mods = roleData["modifiers"] as? [Any] {
                    selfRoleModifiers = mods.compactMap { $0 as? String }
                } else if let mods = roleData["modifiers"] as? String {
                    selfRoleModifiers = mods.split(separator: "/").map(String.init)
                }
            } else if let role {
                let parts = role.split(separator: ":").map(String.init)
                selfRoleName = parts.first
                if parts.count > 1 {
                    selfRoleModifiers = parts[1].split(separator: "/").map(String.init)
                }
            }
            if selfRoleName != nil {
                showRoleReveal = true
            }
            if isFaction(selfRoleCategory) || isFactionRole(selfRoleName) {
                for (pid, r) in knownRoles where pid != selfId {
                    if isFactionRole(r) {
                        teammateIds.insert(pid)
                        lockGuess(playerId: pid, role: r)
                    }
                }
            }
        } else if let playerId {
            if (isFaction(selfRoleCategory) || isFactionRole(selfRoleName)), isFactionRole(role) {
                teammateIds.insert(playerId)
                if let role { lockGuess(playerId: playerId, role: role) }
            }
        }
        if !ingestingHistory { persistRoleMarks() }
    }

    private func applyReveal(_ data: Any?) {
        guard let obj = data as? [String: Any] else { return }
        guard let playerId = obj["playerId"] as? String else { return }
        let role = obj["role"] as? String
        if let role { knownRoles[playerId] = role }
        // `death` comes before the death reveal, so a reveal for a dead player is that reveal.
        if let role, !role.isEmpty, deadIds.contains(playerId), !ingestingHistory {
            deathRevealedRoles[playerId] = role
            fillPaperReveals()
        }
        if playerId == selfId {
            if selfRoleName == nil, let role {
                selfRoleName = role.split(separator: ":").first.map(String.init)
            }
            return
        }
        if (isFaction(selfRoleCategory) || isFactionRole(selfRoleName)), isFactionRole(role) {
            teammateIds.insert(playerId)
            if let role { lockGuess(playerId: playerId, role: role) }
        }
        if !ingestingHistory { persistRoleMarks() }
    }

    private func isFaction(_ category: String?) -> Bool {
        guard let c = category?.lowercased() else { return false }
        return c.contains("mafia") || c.contains("cult")
    }

    private func isFactionRole(_ role: String?) -> Bool {
        guard let r = role?.lowercased() else { return false }
        return r.contains("mafia") || r.contains("goon") || r.contains("cult") || r == "mafioso"
    }

    private func findOriginalLine(_ id: String) -> ChatLine? {
        if let line = ingestBuffer.first(where: { $0.id == id && !$0.isQuote }) { return line }
        if let line = messages.first(where: { $0.id == id && !$0.isQuote }) { return line }
        for phase in phases {
            if let line = phase.messages.first(where: { $0.id == id && !$0.isQuote }) { return line }
        }
        return nil
    }

    private func applySpeakCooldown(_ data: Any?) {
        guard let obj = data as? [String: Any] else { return }
        let meetingId = obj["meetingId"] as? String
        if let meetingId, let selected = selectedSpeechMeetingId, meetingId != selected {
            return
        }
        let sentAt: Double
        if let d = obj["sentAt"] as? Double { sentAt = d }
        else if let i = obj["sentAt"] as? Int { sentAt = Double(i) }
        else if let n = obj["sentAt"] as? NSNumber { sentAt = n.doubleValue }
        else { sentAt = Date().timeIntervalSince1970 * 1000 }
        if sentAt > 0, sentAt < lastSpeakCooldownSentAt { return }
        lastSpeakCooldownSentAt = sentAt
        let cooldownMs: Double
        if let d = obj["cooldownMs"] as? Double { cooldownMs = d }
        else if let i = obj["cooldownMs"] as? Int { cooldownMs = Double(i) }
        else if let n = obj["cooldownMs"] as? NSNumber { cooldownMs = n.doubleValue }
        else { return }
        guard cooldownMs > 0 else { return }
        let prevMs = max(0, (speakCooldownUntil?.timeIntervalSinceNow ?? 0) * 1000)
        let wait = max(prevMs, cooldownMs)
        speakCooldownMeetingId = meetingId
        speakCooldownUntil = Date().addingTimeInterval(wait / 1000)
    }

    private func parseQuote(_ data: Any?) -> ChatLine? {
        guard let obj = data as? [String: Any] else { return nil }
        let messageId = obj["messageId"] as? String
        let original = messageId.flatMap { findOriginalLine($0) }
        let content: String
        if let original, !original.content.isEmpty {
            content = original.content
        } else if let s = obj["messageContent"] as? String, !s.isEmpty {
            content = s
        } else if let s = obj["content"] as? String, !s.isEmpty {
            content = s
        } else {
            return nil
        }
        let quoterId = obj["senderId"] as? String ?? selfId ?? "anonymous"
        let quoterName: String
        if quoterId == "anonymous" {
            quoterName = "Anonymous"
        } else if let p = player(for: quoterId) {
            quoterName = p.name
        } else {
            quoterName = (obj["senderName"] as? String) ?? "Player"
        }
        let quotedId = original?.senderId ?? "anonymous"
        let quotedName: String
        if let original {
            quotedName = original.senderName
        } else if quotedId == "anonymous" {
            quotedName = "Anonymous"
        } else {
            quotedName = player(for: quotedId)?.name ?? "Anonymous"
        }
        let senderId = quoterId
        let name = quoterName
        let time: Date
        if let t = obj["time"] as? Double {
            time = Date(timeIntervalSince1970: t > 10_000_000_000 ? t / 1000 : t)
        } else if let t = obj["time"] as? Int {
            let v = Double(t)
            time = Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        } else if let original {
            time = original.time
        } else {
            time = Date()
        }
        let fromState = intValue(obj["fromState"]) ?? original?.fromState
        let fromName = fromState.flatMap { phaseLabel($0) }
            ?? original.flatMap { line in line.fromState.flatMap { phaseLabel($0) } }
            ?? original?.quotedFromStateName
        let toMeeting = obj["toMeetingId"] as? String ?? obj["meetingId"] as? String
        let stamp: String
        if let t = obj["time"] {
            stamp = "\(t)"
        } else {
            stamp = "\(Int(time.timeIntervalSince1970 * 1000))"
        }
        let quoteId: String
        if let id = obj["id"] as? String, !id.isEmpty {
            quoteId = id.hasPrefix("quote:") ? id : "quote:\(id)"
        } else {
            quoteId = "quote:\(messageId ?? "x"):\(toMeeting ?? ""):\(stamp)"
        }
        return ChatLine(
            id: quoteId,
            senderId: senderId,
            senderName: name,
            content: content,
            time: time,
            isServer: false,
            meetingId: toMeeting,
            prefix: nil,
            customEmotes: original?.customEmotes ?? mediaMap(obj["customEmotes"]),
            customStickers: original?.customStickers ?? mediaMap(obj["customStickers"]),
            isQuote: true,
            quotable: false,
            fromState: fromState,
            quotedFromStateName: fromName,
            quotedMessageId: messageId,
            quotedSenderId: quotedId,
            quotedSenderName: quotedName,
            quotedTime: original?.time,
            senderWasDead: deadWhenSent(senderId: senderId, alive: obj["alive"]),
            aliveFlagKnown: !(obj["alive"] == nil || obj["alive"] is NSNull)
        )
    }

    private func phaseLabel(_ id: Int) -> String? {
        guard let phase = phases.first(where: { $0.id == id }) else { return nil }
        if let day = phase.dayCount, phase.name == "Day" || phase.name == "Night" {
            return "\(phase.name) \(day)"
        }
        return phase.name
    }

    private func intValue(_ data: Any?) -> Int? {
        if let i = data as? Int { return i }
        if let d = data as? Double { return Int(d) }
        if let n = data as? NSNumber { return n.intValue }
        if let s = data as? String { return Int(s) }
        return nil
    }

    private func applyTimerInfo(_ data: Any?) {
        guard let obj = data as? [String: Any], let name = obj["name"] as? String, !name.isEmpty else { return }
        let delay = doubleValue(obj["delay"]) ?? 0
        clocks[name] = GameClock(
            name: name,
            delayMs: delay,
            lastSyncElapsedMs: 0,
            lastSyncAt: Date()
        )
    }

    private func applyTimerSync(_ data: Any?) {
        guard let obj = data as? [String: Any], let name = obj["name"] as? String, !name.isEmpty else { return }
        let elapsed = doubleValue(obj["time"]) ?? 0
        if var clock = clocks[name] {
            clock.lastSyncElapsedMs = elapsed
            clock.lastSyncAt = Date()
            clocks[name] = clock
        } else {
            clocks[name] = GameClock(
                name: name,
                delayMs: elapsed,
                lastSyncElapsedMs: elapsed,
                lastSyncAt: Date()
            )
        }
    }

    private func doubleValue(_ data: Any?) -> Double? {
        if let d = data as? Double { return d }
        if let i = data as? Int { return Double(i) }
        if let n = data as? NSNumber { return n.doubleValue }
        if let s = data as? String { return Double(s) }
        return nil
    }

    private func parseVoteRecord(_ data: Any?, phaseId: Int) -> ChatLine? {
        guard let obj = data as? [String: Any] else { return nil }
        let voter = obj["voterId"] as? String ?? ""
        let unvote = (obj["type"] as? String) == "unvote"
        let target = obj["target"] as? String
        let voterName = displayName(for: voter)
        let content: String
        if unvote {
            content = "\(voterName) unvotes"
        } else {
            content = "\(voterName) votes \(displayName(for: target ?? ""))"
        }
        let time: Date
        if let t = obj["time"] as? Double {
            time = Date(timeIntervalSince1970: t > 10_000_000_000 ? t / 1000 : t)
        } else if let t = obj["time"] as? Int {
            let v = Double(t)
            time = Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        } else {
            time = Date()
        }
        return ChatLine(
            id: "votehist:\(voter):\(target ?? ""):\(obj["time"] ?? "")",
            senderId: "vote",
            senderName: "Vote",
            content: content,
            time: time,
            isServer: true,
            meetingId: nil,
            prefix: nil,
            isQuote: false,
            quotable: false,
            fromState: phaseId
        )
    }

    private static func deadSet(_ any: Any?) -> Set<String> {
        if let dict = any as? [String: Any] {
            return Set(dict.compactMap { k, v in
                switch v {
                case let b as Bool: return b ? k : nil
                case let n as NSNumber: return n.boolValue ? k : nil
                default: return nil
                }
            })
        }
        if let arr = any as? [Any] { return Set(arr.compactMap { $0 as? String }) }
        return []
    }

    private func applyDeadMap(_ any: Any?) {
        if let dict = any as? [String: Any] {
            for (id, val) in dict {
                markDead(id, dead: boolValue(val))
            }
        } else if let arr = any as? [String] {
            for id in arr { markDead(id, dead: true) }
        } else if let arr = any as? [Any] {
            for id in arr.compactMap({ $0 as? String }) { markDead(id, dead: true) }
        }
    }

    @discardableResult
    private func applyObituaries(_ data: Any?, phaseId: Int? = nil) -> ChatLine? {
        guard let obj = data as? [String: Any] else { return nil }
        let source = obj["source"] as? String ?? ""
        let count = intValue(obj["dayCount"]) ?? dayCount ?? 0
        let time = dateFromMillis(obj["time"]) ?? Date()
        let pid = phaseId ?? currentPhaseId
        var deaths: [NewspaperDeath] = []
        let rows: [Any]
        if let arr = obj["obituaries"] as? [Any] {
            rows = arr
        } else {
            rows = []
        }
        for item in rows {
            guard let ob = item as? [String: Any] else { continue }
            let info = ob["playerInfo"] as? [String: Any] ?? ob
            let snippets = ob["snippets"] as? [String: Any] ?? [:]
            let name = info["name"] as? String ?? "Unknown"
            let userId = (info["userId"] as? String) ?? (info["id"] as? String)
            let matched = players.first(where: { $0.name == name })
                ?? players.first(where: { $0.userId == userId })
            if let pid = matched?.id ?? (info["id"] as? String) {
                markDead(pid, dead: true)
            }
            let deathMessage = (snippets["deathMessage"] as? String)
                ?? (ob["deathMessage"] as? String)
                ?? ""
            let revealRaw = (snippets["revealMessage"] as? String) ?? (ob["revealMessage"] as? String)
            let will = (snippets["lastWill"] as? String) ?? (ob["lastWill"] as? String)
            let id = userId ?? matched?.id ?? name
            let reveal = NewspaperCopy.reveal(from: revealRaw, playerName: name)
            deaths.append(NewspaperDeath(
                id: id,
                playerId: matched?.id ?? (info["id"] as? String) ?? (ob["id"] as? String),
                name: name,
                userId: matched?.userId ?? userId,
                avatar: matched?.avatar ?? boolValue(info["avatar"]),
                deathMessage: deathMessage,
                revealLine: reveal?.line,
                revealRoleRaw: reveal?.roleRaw,
                revealSuffix: reveal?.suffix,
                lastWill: will
            ))
        }
        if newspaperEpoch == nil || count < (newspaperEpochDayCount ?? count) {
            newspaperEpoch = time
            newspaperEpochDayCount = count
        }
        let issue = NewspaperIssue(
            id: "\(pid):\(source.isEmpty ? "Night" : source)",
            title: NewspaperCopy.title(source: source.isEmpty ? "Night" : source),
            source: source.isEmpty ? "Night" : source,
            phaseId: pid,
            dayCount: count,
            time: time,
            deaths: deaths
        )
        var bag = newspapers[pid] ?? [:]
        bag[issue.source] = issue
        newspapers[pid] = bag
        if !ingestingHistory { fillPaperReveals() }
        if issue.source.hasPrefix("instant") {
            let line = newspaperChatLine(for: issue)
            if ingestingHistory { return line }
            appendLine(line)
            return line
        }
        return nil
    }

    private func newspaperChatLine(for issue: NewspaperIssue) -> ChatLine {
        ChatLine(
            id: "newspaper:\(issue.id)",
            senderId: "server",
            senderName: "Newspaper",
            content: "",
            time: issue.time,
            isServer: true,
            meetingId: nil,
            prefix: nil,
            isQuote: false,
            quotable: false,
            fromState: issue.phaseId,
            newspaper: issue
        )
    }

    private func applyWinners(_ data: Any?, phaseId: Int? = nil) {
        guard let obj = data as? [String: Any] else { return }
        let info = (obj["winners"] as? [String: Any]) ?? obj
        let groups = (info["groups"] as? [Any])?.compactMap { $0 as? String } ?? []
        let messages = (info["messages"] as? [Any])?.compactMap { $0 as? String } ?? []
        let byGroup = (info["playersByGroup"] as? [String: Any])
            ?? (info["players"] as? [String: Any])
            ?? [:]
        var names = groups
        if names.isEmpty { names = Array(byGroup.keys).sorted() }
        var wins: [NewspaperWin] = []
        for (index, group) in names.enumerated() {
            let raw = byGroup[group]
            var people: [NewspaperPerson] = []
            if let arr = raw as? [Any] {
                people = arr.compactMap { resolveNewspaperPerson($0) }
            }
            let message = index < messages.count ? messages[index] : "\(group) has won."
            wins.append(NewspaperWin(group: group, message: message, players: people))
        }
        guard !wins.isEmpty else { return }
        let pid = phaseId ?? (currentPhaseId == -2 ? -2 : currentPhaseId)
        let count = intValue(info["dayCount"]) ?? intValue(obj["dayCount"]) ?? dayCount ?? newspaperEpochDayCount ?? 0
        let time = dateFromMillis(info["time"]) ?? dateFromMillis(obj["time"]) ?? Date()
        let issue = NewspaperIssue(
            id: "\(pid):Winners",
            title: NewspaperCopy.title(source: "Winners"),
            source: "Winners",
            phaseId: pid,
            dayCount: count,
            time: time,
            deaths: [],
            wins: wins
        )
        var bag = newspapers[pid] ?? [:]
        bag["Winners"] = issue
        newspapers[pid] = bag
        if pid != -2 {
            var post = newspapers[-2] ?? [:]
            post["Winners"] = issue
            newspapers[-2] = post
        }
        playWinnerMusic(groups)
    }

    private func playWinnerMusic(_ groups: [String]) {
        guard !isQuiet else { return }
        let type = (gameType ?? setupGameType).trimmingCharacters(in: .whitespacesAndNewlines)
        guard type.compare("Mafia", options: .caseInsensitive) == .orderedSame else { return }
        GameWinMusic.unlockSession()
        GameWinMusic.playWinners(groups)
    }

    private func resolveNewspaperPerson(_ any: Any) -> NewspaperPerson? {
        if let s = any as? String {
            if let p = players.first(where: { $0.id == s || $0.userId == s }) {
                return NewspaperPerson(id: p.id, name: p.name, userId: p.userId, avatar: p.avatar)
            }
            return NewspaperPerson(id: s, name: displayName(for: s), userId: nil, avatar: false)
        }
        guard let obj = any as? [String: Any] else { return nil }
        let pid = obj["id"] as? String
        let userId = obj["userId"] as? String
        let name = obj["name"] as? String
        let p = players.first(where: { $0.id == pid || $0.userId == userId || $0.name == name })
        return NewspaperPerson(
            id: pid ?? userId ?? p?.id ?? name ?? "unknown",
            name: name ?? p?.name ?? "Unknown",
            userId: p?.userId ?? userId,
            avatar: p?.avatar ?? boolValue(obj["avatar"])
        )
    }

    private func applySetup(_ data: Any?) {
        guard let obj = data as? [String: Any] else { return }
        setupName = obj["name"] as? String ?? setupName
        if let id = obj["id"] as? String { setupId = id }
        if let t = obj["gameType"] as? String, !t.isEmpty { setupGameType = t }
        else if let t = gameType, !t.isEmpty { setupGameType = t }
        setupClosed = boolValue(obj["closed"])
        setupUseRoleGroups = boolValue(obj["useRoleGroups"])
        let bundle = parseSetupBundle(obj)
        setupRolesets = bundle.rolesets
        setupRolesetIndex = 0
        setupRoles = bundle.rolesets.first ?? []
        setupBanished = bundle.banished
        setupBanishedPerSet = bundle.banishedPerSet
        setupEvents = bundle.events
        setupEventsPerSet = bundle.eventsPerSet
        setupGrouped = bundle.grouped
        setupGroupSizes = bundle.groupSizes
        let settings = obj["gameSettings"] as? [String: Any] ?? [:]
        setupWhispers = Self.truthySetting(settings["Whispers"])
        setupWhisperLeakChance = setupWhispers ? Self.numberSetting(settings["Whisper Leak Chance"]) : 0
        if !setupWhispers { whisperForceLeak = false }
    }

    nonisolated static func truthySetting(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue != 0
        case let s as String: return !s.isEmpty && s != "0" && s.lowercased() != "false"
        case let a as [Any]: return !a.isEmpty
        default: return false
        }
    }

    nonisolated static func numberSetting(_ v: Any?) -> Double {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    private func parseSetupBundle(_ obj: [String: Any]) -> SetupRoleParse.Bundle {
        let sizes: [Int] = (obj["roleGroupSizes"] as? [Any] ?? []).map { ($0 as? NSNumber)?.intValue ?? Int("\($0)") ?? 0 }
        return SetupRoleParse.parse(
            rolesBlob: obj["roles"],
            closed: setupClosed,
            useRoleGroups: setupUseRoleGroups,
            count: obj["count"] as? [String: Any],
            gameType: setupGameType,
            roleGroupSizes: sizes
        )
    }

    func displayedGuess(for playerId: String) -> RoleGuess {
        if playerId == selfId, let role = selfRoleName, !role.isEmpty {
            if !selfRoleModifiers.isEmpty {
                return .sure("\(role):\(selfRoleModifiers.joined(separator: "/"))")
            }
            return .sure(role)
        }
        if let known = knownRoles[playerId], !known.isEmpty {
            return .sure(known)
        }
        if let locked = roleGuesses[playerId] {
            return locked
        }
        return .unknown
    }

    @discardableResult
    func cycleRoleGuess(playerId: String) -> GuessTapResult {
        guard playerId != selfId, isGameInProgress else { return .didCycle }
        if knownRoles[playerId] != nil { return .didCycle }
        switch displayedGuess(for: playerId) {
        case .unknown:
            return .needsRolePick
        case .maybe(let role):
            roleGuesses[playerId] = .sure(role)
            persistRoleMarks()
            return .didCycle
        case .sure:
            roleGuesses[playerId] = nil
            persistRoleMarks()
            return .didCycle
        }
    }

    func pickRoleGuess(playerId: String, role: String) {
        guard playerId != selfId else { return }
        roleGuesses[playerId] = .maybe(role)
        persistRoleMarks()
    }

    func lockGuess(playerId: String, role: String) {
        roleGuesses[playerId] = .sure(role)
        if !ingestingHistory { persistRoleMarks() }
    }

    private func restoreRoleMarks() {
        guard let snap = RoleMarkStore.load(gameId: gameId) else { return }
        roleGuesses = snap.guesses
        if knownRoles.isEmpty { knownRoles = snap.known }
        if teammateIds.isEmpty { teammateIds = Set(snap.teammates) }
        if selfRoleName == nil {
            selfRoleName = snap.selfRoleName
            selfRoleCategory = snap.selfRoleCategory
            selfRoleModifiers = snap.selfRoleModifiers
        }
    }

    private func persistRoleMarks() {
        let guesses = roleGuesses.filter {
            if case .unknown = $0.value { return false }
            return true
        }
        RoleMarkStore.save(
            gameId: gameId,
            snapshot: RoleMarkSnapshot(
                guesses: guesses,
                known: knownRoles,
                teammates: Array(teammateIds),
                selfRoleName: selfRoleName,
                selfRoleCategory: selfRoleCategory,
                selfRoleModifiers: selfRoleModifiers
            )
        )
    }

    private func applyKnownRolesMap(_ any: Any?) {
        guard let dict = any as? [String: Any] else { return }
        for (pid, val) in dict {
            guard let role = val as? String, !role.isEmpty else { continue }
            knownRoles[pid] = role
        }
    }

    private func adoptKnownRolesForSelf() {
        if let selfId, selfRoleName == nil, let role = knownRoles[selfId], !role.isEmpty {
            let parts = role.split(separator: ":").map(String.init)
            selfRoleName = parts.first
            if parts.count > 1 {
                selfRoleModifiers = parts[1].split(separator: "/").map(String.init)
            }
        }
        relockFactionTeammates()
    }

    private func relockFactionTeammates() {
        guard isFaction(selfRoleCategory) || isFactionRole(selfRoleName) else { return }
        for (pid, role) in knownRoles where pid != selfId {
            if isFactionRole(role) {
                teammateIds.insert(pid)
                roleGuesses[pid] = .sure(role)
            }
        }
    }

    private func isVegKickMeeting(_ meeting: VoteMeeting) -> Bool {
        meeting.isVoteKick
    }

    private func maybeNotifyKicks(_ meetings: [VoteMeeting]) {
        let atKicks = meetings.contains { isVegKickMeeting($0) }
        if atKicks {
            if !kickWindowNotified, !spectate {
                kickWindowNotified = true
                GameAlerts.notifyKicks()
            }
        } else {
            kickWindowNotified = false
        }
    }

    func displayName(for target: String) -> String {
        voteLabel(target, meeting: nil)
    }

    func voteLabel(_ target: String, meeting: VoteMeeting?) -> String {
        switch target {
        case "*":
            // Web G:5326-5340: boolean -> "No", non-player inputs -> "None".
            if let type = meeting?.inputType, type != "player" {
                return type == "boolean" ? "No" : "None"
            }
            let custom = meeting?.noOneDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return custom.isEmpty ? "no one" : custom
        case "*magus":
            return "Declare Magus Game"
        case "*unknown":
            return "???"
        default:
            if let p = players.first(where: { $0.id == target }) { return p.name }
            if meeting?.anonymous == true || meeting?.anonymousVotes == true {
                return "Anonymous"
            }
            return target
        }
    }

    func displayVoter(_ voterId: String, meeting: VoteMeeting) -> String {
        if voterId == selfId, let me = players.first(where: { $0.id == voterId }) {
            return me.name
        }
        if let p = players.first(where: { $0.id == voterId }) { return p.name }
        if meeting.anonymous || meeting.anonymousVotes { return "Anonymous" }
        return voterId
    }
}
