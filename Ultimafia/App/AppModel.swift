import Foundation
import Observation

@Observable
final class AppModel {
    var user: UserInfo? {
        didSet {
            UMViewerPrefs.shared.apply(user: user)
            UMProfileCache.activeUserId.withLock { $0 = user?.id }
        }
    }
    var isRestoring = true
    var isBusy = false
    var errorMessage: String?
    /// A refused action, shown once as an alert in the signed-in shell. `errorMessage` stays for
    /// inline surfaces (the sign-in screen); this one is for "you can't do that right now".
    var alertMessage: String?
    /// The lobby list shows every lobby; the web API treats "All" as no lobby filter.
    let lobby = "All"
    var openGames: [GameSummary] = []
    var inProgressGames: [GameSummary] = []
    var finishedGames: [GameSummary] = []
    var finishedHasMore = true
    /// Finished-game replay. Kept apart from `game` so it never counts as seated.
    /// Closing a review drops its in-memory game and its pinned images (UMImageCache).
    var reviewSession: GameSession? {
        didSet { if let old = oldValue, old !== reviewSession { UMImageCache.shared.unpin(scope: old.assetScope) } }
    }
    /// Pings received while seated but away from the game screen; shown on the Game tab.
    var mentionCount = 0
    /// Live game screen actually on screen (set by GameView appear/disappear, covers tab switches).
    var isViewingGame = false
    @ObservationIgnored private var finishedCursor: Double?
    @ObservationIgnored private var loadingFinished = false
    /// The Play section's stack: lobby, profiles, families, finished-game reviews.
    var path: [Route] = []
    /// The Game section's own stack: the live game and anything pushed from it.
    var gamePath: [Route] = []
    /// Leaving / detaching / a new game drops the old session's pinned images.
    var game: GameSession? {
        didSet { if let old = oldValue, old !== game { UMImageCache.shared.unpin(scope: old.assetScope) } }
    }
    /// Bumped whenever the user returns to the Lobby; LobbyView scrolls to the top on change.
    var lobbyScrollToTop = 0
    /// The signed-in user's own custom emotes/stickers (`:name:` -> media path), loaded once per session.
    var myCustomEmotes: [String: String] = [:]
    var myCustomStickers: [String: String] = [:]
    var showLeaveConfirm = false
    var onlineUsers: [OnlineUser] = []
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    /// Email to prefill on the sign-in screen (saved account whose session expired).
    var loginPrefillEmail: String?

    /// Which section is showing (`UMAppSection`, a standalone value type).
    var section: UMAppSection = .play

    enum Route: Hashable {
        case profile(id: String, name: String)
        case family(id: String, name: String)
        case review(String)
        /// The host flow, pushed from the lobby: hosting is part of the lobby, not a section.
        case host
    }

    /// True while the Game section is showing.
    var isOnGameScreen: Bool { section == .game }

    /// The app bar is hidden in exactly one situation: a live game is on screen. Nothing else
    /// hides it — not the Host flow, not the keyboard — and this single derived property owns
    /// the decision, so the bar cannot disagree with the rest of the app about where you are.
    var showsAppTabs: Bool { !(section == .game && game != nil) }

    /// Lobby: show the Play section at its root. A seated player keeps their live game — this is
    /// navigation, not leaving.
    func goToLobby() {
        section = .play
        path.removeAll()
        lobbyScrollToTop += 1
    }

    /// Tab selection. Selecting the visible section again pops it to its root, the way the system
    /// tab bar behaves; switching sections leaves every stack as it was.
    func select(_ target: UMAppSection) {
        if section == target { popToRoot(target) } else { section = target }
    }

    func popToRoot(_ target: UMAppSection) {
        switch target {
        case .play: goToLobby()
        case .game: gamePath.removeAll()
        case .messages: break
        case .you: youPath.removeAll()
        }
    }

    var mentionBadge: Int {
        (seatedGameId != nil && game != nil && !isViewingGame) ? mentionCount : 0
    }

    var isSignedIn: Bool { user?.id != nil }

    var seatedGameId: String? {
        user?.inGameId ?? game?.gameId
    }

    /// Any current game session: pregame or started, seated or spectating, until it's actually left
    /// (game = nil) or finished. Reads the live session the shell keeps across the back arrow
    /// (goToLobby keeps `game`), so it flips the moment a session attaches, not when the game starts.
    /// With no session attached yet (relaunch before resume), the server's inGameId decides.
    var hasCurrentGame: Bool {
        if let g = game, !g.isReview { return !g.finished }
        return user?.inGameId != nil
    }

    var seatedGameSummary: GameSummary? {
        guard let id = seatedGameId else { return nil }
        return (openGames + inProgressGames).first { $0.id == id }
    }

    var seatedSetupName: String {
        if let name = game?.setupName, !name.isEmpty { return name }
        return seatedGameSummary?.setup?.name ?? "Game"
    }

    var seatedPhaseLabel: String {
        if let g = game {
            let n = g.stateName
            if n != "Connecting", !n.isEmpty {
                if let d = g.dayCount, n == "Day" || n == "Night" {
                    return "\(n) \(d)"
                }
                return n
            }
        }
        if let s = seatedGameSummary?.gameState, !s.isEmpty { return s }
        return "In progress"
    }

    var seatedPlayerLabel: String? {
        if let summary = seatedGameSummary, summary.setupTotal > 0 {
            return "\(summary.playerCount)/\(summary.setupTotal)"
        }
        if let g = game, !g.players.isEmpty {
            return "\(g.players.count) players"
        }
        return nil
    }

    var isOnLobbyWhileSeated: Bool {
        seatedGameId != nil && path.isEmpty
    }

    func bootstrap() async {
        #if DEBUG
        // `-UMNoSession`: diag/screenshot runs stay signed out (never resume a saved session or
        // reconnect to a seated game).
        if ProcessInfo.processInfo.arguments.contains("-UMNoSession") { return }
        #endif
        isRestoring = true
        defer { isRestoring = false }
        _ = DeviceIdentity.installId
        do {
            let info = try await APIClient.shared.userInfo()
            if info.id != nil {
                await didSignIn(info, email: nil)
            }
        } catch {
            user = nil
        }
    }

    func signIn(email: String, password: String) async {
        await run {
            try await self.authenticate(email: email, password: password)
        }
    }

    /// Firebase idToken -> POST /auth (sets cookie) -> GET /user/info (csrf).
    private func authenticate(email: String, password: String) async throws {
        AccountStore.clearCookies()
        let token = try await FirebaseAuth.signIn(email: email, password: password)
        try await APIClient.shared.establishSession(idToken: token)
        let info = try await APIClient.shared.userInfo()
        guard let id = info.id else { throw UMError.message("Check your email to verify the account, then sign in.") }
        AccountStore.shared.savePassword(password, for: id)
        RememberedLogin.clear()
        await didSignIn(info, email: email)
    }

    /// Shared tail of every successful sign-in / restore / account switch.
    private func didSignIn(_ info: UserInfo, email: String?) async {
        guard let id = info.id else { return }
        user = info
        loginPrefillEmail = nil
        AccountStore.shared.upsert(info, email: email)
        AccountStore.shared.saveSession(for: id)
        DeviceIdentity.recordSignIn(userId: id)
        startPresence()
        Task { await self.loadMyCustomMedia() }
        await refreshLobby()
        resumeIfSeated()
    }

    /// Drop everything tied to the active account's session (keeps on-disk asset caches).
    /// Clears only per-account in-memory state. Device-wide caches (UMCustomAssetCache,
    /// UMImageCache, name fonts, role icons, sounds) are intentionally left alone.
    private func resetSessionState() {
        stopPresence()
        game?.disconnectWithoutLeaving()
        game = nil
        // A review is a spectator session on someone else's game: tearing it down must not send
        // a leave (/game/leave carries no id, so it would leave whatever game the session is on).
        reviewSession?.disconnectWithoutLeaving()
        reviewSession = nil
        APIClient.shared.csrf = nil
        user = nil
        path = []
        gamePath = []
        youPath = []
        section = .play
        isViewingGame = false
        showLeaveConfirm = false
        mentionCount = 0
        myCustomEmotes = [:]
        myCustomStickers = [:]
        onlineUsers = []
        openGames = []
        inProgressGames = []
        finishedGames = []
        finishedCursor = nil
        finishedHasMore = true
        errorMessage = nil
    }

    /// You tab: keep this account's session saved, go offline, and show sign-in for another account.
    /// The site has no explicit offline call; stopping the /user/online heartbeat lets it time out.
    func addAnotherAccount() {
        guard seatedGameId == nil else { return }
        if let id = user?.id { AccountStore.shared.saveSession(for: id) }
        resetSessionState()
        AccountStore.clearCookies()
    }

    /// Sign-in switcher: restore the saved cookie, verify with /user/info; else re-auth with the
    /// Keychain password; else prefill the email and ask for the password.
    /// A definite rejection (401/403, Firebase bad credentials, /user/info not logged in) of what
    /// was saved, including a session synced from another device, drops the saved account and its
    /// Keychain items. Network errors keep everything and ask to retry.
    func switchToAccount(_ account: SavedAccount) async {
        if let current = user?.id {
            if current == account.id { return }
            await UMPush.unregister()
            AccountStore.shared.saveSession(for: current)
        }
        UMPush.signedIn = false
        UMChatStore.shared.stop()
        resetSessionState()
        await run {
            var hadSaved = false
            var rejected = false
            if AccountStore.shared.restoreSession(for: account.id) {
                hadSaved = true
                do {
                    let info = try await APIClient.shared.userInfo()
                    if info.id == account.id {
                        await self.didSignIn(info, email: nil)
                        return
                    }
                    rejected = true // not logged in, or the cookie belongs to someone else
                } catch is UMAuthRejected {
                    rejected = true
                } catch {
                    AccountStore.clearCookies()
                    throw Self.retryError(error)
                }
                AccountStore.shared.clearSession(account.id)
                AccountStore.clearCookies()
            }
            if let email = account.email, let password = AccountStore.shared.password(for: account.id) {
                hadSaved = true
                do {
                    try await self.authenticate(email: email, password: password)
                    return
                } catch is UMAuthRejected {
                    rejected = true
                } catch {
                    // Couldn't check the password (offline, server error): keep everything.
                    AccountStore.clearCookies()
                    throw Self.retryError(error)
                }
            }
            self.loginPrefillEmail = account.email ?? ""
            if hadSaved && rejected {
                AccountStore.shared.remove(account.id)
                throw UMError.message("Your saved sign-in for \(account.name) expired. Please sign in again.")
            }
            throw UMError.message("Enter the password for \(account.name) to sign back in.")
        }
    }

    /// Network failures get a retry hint; other non-auth errors pass through unchanged.
    private static func retryError(_ error: Error) -> Error {
        guard error is URLError else { return error }
        return UMError.message("Couldn't reach Ultimafia (\(error.localizedDescription)). Check your connection and tap the account to try again.")
    }

    func removeSavedAccount(_ id: String) {
        AccountStore.shared.remove(id)
    }

    /// GET user/settings/data returns `customEmotes` / `customStickers` keyed by `:name:`.
    func loadMyCustomMedia() async {
        guard let data = try? await APIClient.shared.request("GET", path: "user/settings/data", query: [:], body: nil),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func map(_ any: Any?) -> [String: String] {
            guard let dict = any as? [String: Any] else { return [:] }
            var out: [String: String] = [:]
            for (key, value) in dict {
                if let path = (value as? [String: Any])?["path"] as? String { out[key.lowercased()] = path }
            }
            return out
        }
        myCustomEmotes = map(obj["customEmotes"])
        myCustomStickers = map(obj["customStickers"])
    }

    func signUp(email: String, password: String) async {
        await run {
            _ = try await FirebaseAuth.signUp(email: email, password: password)
            self.errorMessage = "Account created. Verify the email we sent, then sign in."
        }
    }

    /// Signs out only the active account: its session and stored password are removed, but its
    /// row stays in the switcher (tapping it asks for the password). Other accounts are untouched.
    /// Z-only backend switch: keep this host's session, tear everything down, point every URL at the
    /// new host, restore that host's saved session for the same account if any, then reconnect.
    func switchBackend(_ b: UMBackend) async {
        guard b != UMConfig.backend else { return }
        let id = user?.id
        if let id { AccountStore.shared.saveSession(for: id) }
        await UMPush.unregister()           // DELETE from the old host while its session is valid
        UMPush.signedIn = false
        UMChatStore.shared.stop()
        if seatedGameId != nil { game?.disconnectWithoutLeaving() }
        resetSessionState()
        AccountStore.clearCookies()
        UMBackend.set(b)
        UMProfileCache.clearAll()
        UMDiag.log("backend", "switched to \(b.rawValue)")
        if let id { _ = AccountStore.shared.restoreSession(for: id) }
        await bootstrap()                   // signed in -> MainTabs re-registers push on the new host
    }

    func signOut() async {
        let id = user?.id
        let email = id.flatMap { uid in AccountStore.shared.accounts.first { $0.id == uid }?.email }
        if seatedGameId != nil { game?.leave() }
        stopPresence()
        await UMPush.unregister()
        UMPush.signedIn = false
        UMChatStore.shared.stop()
        await APIClient.shared.logout()
        if let id {
            AccountStore.shared.clearSession(id)
            AccountStore.shared.clearPassword(id)
        }
        resetSessionState()
        loginPrefillEmail = email
    }

    func refreshLobby() async {
        do {
            async let open = APIClient.shared.gameList(list: "open", lobby: lobby)
            async let progress = APIClient.shared.gameList(list: "in progress", lobby: lobby)
            async let online = APIClient.shared.onlineUsers()
            let me = user?.id
            openGames = (try await open).filter { $0.isOpen && $0.isReviewVisible(to: me) && !hostIsBlocked($0) }
            inProgressGames = (try await progress).filter { $0.isReviewVisible(to: me) && !hostIsBlocked($0) }
            onlineUsers = (try? await online) ?? onlineUsers
            await loadFinished(reset: true)
        } catch {
            errorMessage = UMFriendlyError.message(for: error)
        }
    }

    func loadFinished(reset: Bool) async {
        guard !loadingFinished else { return }
        loadingFinished = true
        defer { loadingFinished = false }
        do {
            // A page can be all non-reviewable types; keep paging (bounded) so the
            // spinner row doesn't sit visible with nothing new to trigger it again.
            var attempts = 0
            repeat {
                attempts += 1
                let rows = try await APIClient.shared.finishedGames(before: reset ? nil : finishedCursor)
                // Cursor from the raw page so filtered-out game types don't stall paging.
                if let oldest = rows.compactMap(\.endTime).min() { finishedCursor = oldest }
                let kept = rows.filter { UMGameTypes.reviewable.contains($0.type ?? "") && $0.isReviewVisible(to: user?.id) }
                if reset && attempts == 1 {
                    finishedGames = kept
                } else {
                    let known = Set(finishedGames.map(\.id))
                    finishedGames += kept.filter { !known.contains($0.id) }
                }
                finishedHasMore = !rows.isEmpty
                if !kept.isEmpty { break }
            } while finishedHasMore && attempts < 4 && !reset
        } catch {
            if reset { finishedGames = [] }
            finishedHasMore = false
        }
    }

    func openReview(_ id: String) {
        let session = GameSession(gameId: id, spectate: true, review: true)
        reviewSession = session
        session.onReviewUnavailable = { [weak self] in self?.hideUnreviewable(id) }
        path.append(.review(id))
        Task { await session.start() }
    }

    /// Safety net for the list-side filter: drop a game whose review the server refused.
    func hideUnreviewable(_ id: String) {
        finishedGames.removeAll { $0.id == id }
        inProgressGames.removeAll { $0.id == id }
        openGames.removeAll { $0.id == id }
    }

    func closeReview() {
        reviewSession = nil
        if case .review = path.last { path.removeLast() }
    }

    /// Blocker side: hide games hosted by someone on your blockedUsers (GET user/info).
    /// The blockee side needs a server field (no blockedBy exists yet).
    func hostIsBlocked(_ summary: GameSummary) -> Bool {
        isBlocked(summary.hostId)
    }

    /// Re-apply the block filter after a block/unblock without refetching.
    func applyBlockFilterToLobby() {
        openGames.removeAll { hostIsBlocked($0) }
        inProgressGames.removeAll { hostIsBlocked($0) }
    }

    func openGame(_ summary: GameSummary, spectate: Bool = false) {
        guard !hostIsBlocked(summary) else {
            alertMessage = "You blocked this game's host."
            return
        }
        resumeGame(summary.id, spectate: spectate)
    }

    func resumeSeatedGame() {
        guard let id = seatedGameId else { return }
        resumeGame(id)
    }

    func resumeIfSeated() {
        guard let id = user?.inGameId else { return }
        resumeGame(id)
    }

    func resumeGame(_ id: String, spectate: Bool = false) {
        // Being seated is server state, and every entry point (join, spectate, host, resume)
        // funnels through here, so this is the one place that can refuse to start a second game
        // over a live one. Leaving is an explicit, confirmed action and is never a side effect.
        if let seated = seatedGameId, seated != id {
            alertMessage = spectate
                ? "You're already in a game. Leave it before spectating another."
                : "You're already in a game. Leave it before joining or hosting another."
            return
        }
        if let session = game, session.gameId == id, session.spectate == spectate {
            gamePath.removeAll()
            section = .game
            if !session.connected, !session.finished {
                Task { await session.start() }
            }
            return
        }
        // Never `stop()` here: that sends "leave" for the session we're replacing, which would
        // leave a ranked game on the player's behalf. Only the explicit Leave action does that.
        game?.disconnectWithoutLeaving()
        let session = GameSession(gameId: id, spectate: spectate)
        session.onMention = { [weak self] in
            guard let self, !self.isViewingGame else { return }
            self.mentionCount += 1
        }
        mentionCount = 0
        game = session
        gamePath.removeAll()
        section = .game
        Task { await session.start() }
    }

    /// Re-read GET user/info (coins, hearts, …); keeps the current user on failure.
    func refreshUserInfo() async {
        guard isSignedIn, let info = try? await APIClient.shared.userInfo(), info.id != nil else { return }
        user = info
    }

    func detachFromGame() {
        game?.disconnectWithoutLeaving()
        game = nil
        gamePath.removeAll()
        section = .play
        Task {
            if let info = try? await APIClient.shared.userInfo() {
                user = info
            }
            await refreshLobby()
        }
    }

    /// Leaving is an action on the game screen, so its toolbar owns it. Games where
    /// participation is still required confirm first; the overlay belongs to the shell.
    func requestLeave() {
        // No connected session yet (seated per /user/info): leaving still has to work.
        guard let session = game else { return leaveActiveGame() }
        if session.leaveNeedsConfirm { showLeaveConfirm = true } else { leaveActiveGame() }
    }

    func leaveActiveGame() {
        game?.leave()
        game = nil
        gamePath.removeAll()
        section = .play
        if var info = user {
            info.inGame = nil
            user = info
        }
        Task {
            if let info = try? await APIClient.shared.userInfo() {
                user = info
            }
            await refreshLobby()
        }
    }

    func startPresence() {
        guard isSignedIn else { return }
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSignedIn else { break }
                await APIClient.shared.pingOnline()
                if let users = try? await APIClient.shared.onlineUsers() {
                    self.onlineUsers = users
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopPresence() {
        presenceTask?.cancel()
        presenceTask = nil
    }

    /// The You section's own stack (profiles pushed from the You page).
    var youPath: [Route] = []

    /// Pushes onto the stack of the section that's showing, so a profile opened from the You page
    /// stays in the You section and back pops it there.
    func openProfile(id: String, name: String) {
        push(.profile(id: id, name: name))
    }

    func openFamily(id: String, name: String) {
        push(.family(id: id, name: name))
    }

    /// Hosting is a screen inside the lobby, matching the website, so it pushes onto the Play
    /// stack and the bar stays exactly where it is.
    func openHost() {
        push(.host)
    }

    private func push(_ route: Route) {
        switch section {
        case .play, .messages: path.append(route)
        case .game: gamePath.append(route)
        case .you: youPath.append(route)
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await work() }
        catch { errorMessage = UMFriendlyError.message(for: error) }
    }
}
