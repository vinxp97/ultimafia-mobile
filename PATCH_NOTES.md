# UltiMafia iOS — Patch Notes

## Release merge — 2026-11-16

Everything new on `main` since the build-15-era main (`088994c`, Liquid Glass wide header,
which was already in that build). Taken from `git log 088994c..main`.

### New
- **Leaderboard page.** A new 5th tab (also in the sidebar) with two views:
  - **Skill**: the Hall of Fame skill rating with tiers and your own rank when signed in.
  - **Competitive**: Seasons and Rounds in one list with a Season / Round toggle (Season on
    the left). The current round shows full standings; past rounds highlight 1st, 2nd and 3rd;
    seasons rank by Fortune. If a round's games have expired, or it has no game data, only
    the season view is shown.
  - Standings are a plain player list (no charts), and switching rounds doesn't animate.
- **Post-game Kudos.** After a game, vote for the standout player on each alignment (or
  "No one"), on iPhone, Duo and iPad. A locked row collapses to a one-line summary, the Act
  pane lists "Kudos Awarded:", and awarded players get a badge. Spectators can't vote.
- **Push notifications.** Game ready/start, DMs, chat and forum pings, friend requests, and
  pokes. Settings → "Push Notifications" is its own list: a master switch hides every
  per-type row when off, and turning it on turns them all on. Settings are per device and
  sync through iCloud (they come back after a reinstall). The app asks for permission on
  first launch. Signing out removes this device from push.
- **iOS badge in games.** Players connected from the iOS app show an Apple icon (hidden in
  anonymous games). App Attest proves the app is genuine; if attest fails or isn't available
  the player still joins, just without the icon.
- **Universal links.** ultimafia.com links (games, DMs, chat, profiles, Hall of Fame, lobby)
  open in the app; other pages open in the in-app browser.

### Fixed
- **Chat quotes** now read top to bottom: "Name on Phase:" on its own line, then the
  quoted text full width and left-aligned below it (no more blank space on the left and
  squeezed, right-side text).
- **Lobby Watch** now always joins as a spectator. Before, tapping Watch on an open pregame
  game could seat you at the table.

### Removed
- The Leaderboard chart button next to Host in the lobby (the Leaderboard tab replaces it).

### Needs before release
- **APNs key on the server:** `APNS_KEY_P8` / `APNS_KEY_ID` (the Sign in with Apple key,
  with APNs enabled) must be set as secret env vars, on dev first and then prod.
- **Backend:** Pranay's push + App Attest work (Gitea PR #92) is on **dev only**. Prod needs
  Vinman's okay before deploy. Until then, push registration and attest get 404s, which
  the app ignores (no push, no Apple icon).
- **Entitlements:** the file says `aps-environment = development` and App Attest
  `development`. With automatic signing that's correct for Xcode/Debug installs. When you
  archive and distribute (TestFlight / App Store), Xcode signs with the distribution
  profile, which sets `aps-environment` to `production`, and Apple always uses the
  **production** App Attest environment for TestFlight/App Store builds whatever the
  entitlement says. No file change is needed, but:
  - The App ID must have Push Notifications and App Attest enabled in the Developer portal.
  - The server must use the production APNs host for TestFlight/App Store tokens (the app
    reports `env: production` for Release builds and `sandbox` for Debug) and must accept
    production attestations (AAGUID `appattest`, not `appattestdevelop`).
- **Untested live:** push delivery and App Attest have only been tested offline and in unit
  tests. They still need an end-to-end test on a real device against dev.
- **Build number:** set it in Xcode before archiving (this branch keeps main's value).

### TestFlight "What to Test"
New Leaderboard tab: check the Skill rankings and the Competitive Season/Round toggle,
including past rounds. After a game, try Kudos voting (spectators shouldn't see it). Quotes
in chat should read "Name on Phase:" with the text below it. In the lobby, Watch on an open
game should make you a spectator, never seat you. Allow notifications on first launch and
try the per-type switches under Settings → Push Notifications. Tap ultimafia.com game and
profile links to see them open in the app. Look for the Apple icon next to iOS players in
games.
