import Foundation
import SwiftUI
import UserNotifications
import AVFoundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif


/// Box so a player can cross from the audio queue back to the main actor.
nonisolated final class UMPlayerBox: @unchecked Sendable {
    let players: [AVAudioPlayer]
    init(_ players: [AVAudioPlayer]) { self.players = players }
}

/// All AVAudioSession and AVAudioPlayer create/prepare/play/stop work runs on one serial queue,
/// never the main thread. Starting a player on main implicitly activates the session there
/// ("AVAudioSession Hang Risk"), which on device can stall the UI (and the socket, whose delegate
/// queue is main) for seconds, e.g. bell + music change + death sound at a phase change.
nonisolated enum UMAudioSession {
    static let queue = DispatchQueue(label: "com.ultimafia.audiosession", qos: .userInitiated)
    private nonisolated(unsafe) static var active = false
    private nonisolated(unsafe) static var observing = false

    /// Fire-and-forget, off the main thread. Always `.playback` + `.mixWithOthers` so Spotify /
    /// Apple Music keep playing under game sounds; never deactivated.
    static func activatePlayback() {
        queue.async { ensureActive() }
    }

    /// Queue only. Activates once; interruptions / media-server resets make the next call re-activate.
    /// Dictation: switch to playAndRecord (ducking other apps) on the audio queue.
    static func beginRecording() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
                    try session.setActive(true)
                    active = false
                    cont.resume(returning: true)
                } catch {
                    UMDiag.log("audio", "record session failed: \(error.localizedDescription)")
                    cont.resume(returning: false)
                }
                #else
                cont.resume(returning: true)
                #endif
            }
        }
    }

    /// Back to `.playback` + `.mixWithOthers` after dictation (unducks other apps).
    static func endRecording() {
        queue.async {
            active = false
            ensureActive()
        }
    }

    private static func ensureActive() {
        #if os(iOS)
        if UMDictationAudio.active { return }
        let session = AVAudioSession.sharedInstance()
        if !observing {
            observing = true
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                    queue.async { active = false }
                }
            }
        }
        if active, session.category == .playback, session.categoryOptions.contains(.mixWithOthers) { return }
        let t0 = CACurrentMediaTime()
        if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
            do { try session.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
            catch { UMDiag.log("audio", "setCategory failed: \(error.localizedDescription)") }
        }
        do { try session.setActive(true); active = true }
        catch { UMDiag.log("audio", "setActive failed: \(error.localizedDescription)") }
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        if ms >= 50 { UMDiag.log("audio", "session activation \(ms)ms (audio queue)") }
        #endif
    }

    /// Creates, prepares and starts a player on the audio queue; returns it on the caller once playing.
    static func startPlayer(_ label: String, volume: Float, loops: Int = 0,
                            make: @escaping @Sendable () throws -> AVAudioPlayer) async -> AVAudioPlayer? {
        let box: UMPlayerBox? = await withCheckedContinuation { cont in
            queue.async {
                ensureActive()
                let t0 = CACurrentMediaTime()
                do {
                    let p = try make()
                    p.numberOfLoops = loops
                    p.volume = volume
                    p.prepareToPlay()
                    p.play()
                    let ms = Int((CACurrentMediaTime() - t0) * 1000)
                    if ms >= 50 { UMDiag.log("audio", "start \(label) \(ms)ms (audio queue)") }
                    cont.resume(returning: UMPlayerBox([p]))
                } catch {
                    UMDiag.log("audio", "player error \(label): \(error.localizedDescription)")
                    cont.resume(returning: nil)
                }
            }
        }
        return box?.players.first
    }

    /// Stops players on the audio queue (AVAudioPlayer.stop can block too).
    static func stop(_ players: [AVAudioPlayer]) {
        guard !players.isEmpty else { return }
        let box = UMPlayerBox(players)
        queue.async { box.players.forEach { $0.stop() } }
    }
}

enum ReadyBell {
    private static var player: AVAudioPlayer?
    private static var loadTask: Task<Void, Never>?

    static func start() {
        if player?.isPlaying == true { return }
        loadTask?.cancel()
        loadTask = Task { await play() }
    }

    static func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let player { UMAudioSession.stop([player]) }
        player = nil
    }

    static func applyVolume() {
        player?.volume = GameAudio.alert
    }

    @MainActor
    private static func play() async {
        activateSession()
        guard let url = await fileURL() else { return }
        guard !Task.isCancelled else { return }
        guard let next = await UMAudioSession.startPlayer("urgent", volume: GameAudio.alert, loops: -1, make: {
            try AVAudioPlayer(contentsOf: url)
        }) else { return }
        if Task.isCancelled { UMAudioSession.stop([next]); return }
        player = next
    }

    private static func activateSession() {
        UMAudioSession.activatePlayback()
    }

    private static func fileURL() async -> URL? {
        let dest = UMCacheLocation.sounds
            .appendingPathComponent("um-urgent.mp3")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let remote = URL(string: "\(UMConfig.site)/audio/urgent.mp3") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: UMAccess.request(remote))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }
}


enum GameAudio {
    static let sfxKey = "um.sfxVolume"
    static let deathKey = "um.deathSoundVolume"
    static let musicKey = "um.musicVolume"
    /// Web settings.pregameMusicVolume: "music/Pregame*" tracks.
    static let pregameMusicKey = "um.pregameMusicVolume"
    /// Web settings.importantVolume ("Alert Volume"): bell, urgent (ready check), vegPing.
    static let alertKey = "um.alertVolume"
    static let alertSounds: Set<String> = ["bell", "urgent", "vegPing"]

    static func volume(_ key: String) -> Float {
        guard UserDefaults.standard.object(forKey: key) != nil else { return 1 }
        return Float(min(1, max(0, UserDefaults.standard.double(forKey: key))))
    }

    static var sfx: Float { volume(sfxKey) }
    static var death: Float { volume(deathKey) }
    static var music: Float { volume(musicKey) }
    static var pregameMusic: Float { volume(pregameMusicKey) }
    static var alert: Float { volume(alertKey) }
}

enum GameSFX {
    private static var playing: [AVAudioPlayer] = []
    private static var alertPlayers = Set<ObjectIdentifier>()
    private static var deathPlaying: [AVAudioPlayer] = []
    private static let localNames: Set<String> = ["bell", "gunshot", "ping", "readyCheck", "ghostAsk"]

    static func applyVolume() {
        playing.forEach { $0.volume = alertPlayers.contains(ObjectIdentifier($0)) ? GameAudio.alert : GameAudio.sfx }
    }

    static func applyDeathVolume() {
        deathPlaying.forEach { $0.volume = GameAudio.death }
    }

    static func stopNonImportant() {
        UMAudioSession.stop(playing + deathPlaying)
        playing.removeAll()
        deathPlaying.removeAll()
    }

    static func warm(_ name: String) {
        Task { _ = await fileURL(name) }
    }

    static func play(_ name: String) {
        if UMDictationAudio.active { return }
        let alert = GameAudio.alertSounds.contains(name)
        if let url = bundledURL(name) {
            Task { @MainActor in await playFile(url, alert: alert) }
            return
        }
        Task { @MainActor in
            guard let url = await fileURL(name) else { return }
            await playFile(url, alert: alert)
        }
    }

    static func playRemoteQueue(_ raws: [String]) {
        if UMDictationAudio.active { return }
        let urls = raws.compactMap(makeRemoteURL)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls {
                await playRemoteOnce(url)
            }
        }
    }

    @MainActor
    private static func playFile(_ url: URL, alert: Bool = false) async {
        guard let next = await UMAudioSession.startPlayer(url.lastPathComponent,
                                                          volume: alert ? GameAudio.alert : GameAudio.sfx,
                                                          make: { try AVAudioPlayer(contentsOf: url) }) else { return }
        playing.removeAll { !$0.isPlaying }
        alertPlayers = alertPlayers.filter { id in playing.contains { ObjectIdentifier($0) == id } }
        if alert { alertPlayers.insert(ObjectIdentifier(next)) }
        playing.append(next)
    }

    @MainActor
    private static func playRemoteOnce(_ url: URL) async {
        activateSession()
        do {
            let (data, response) = try await URLSession.shared.data(for: UMAccess.request(url))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return }
            guard let next = await UMAudioSession.startPlayer(url.lastPathComponent, volume: GameAudio.death, make: {
                try AVAudioPlayer(data: data)
            }) else { return }
            deathPlaying.removeAll { !$0.isPlaying }
            deathPlaying.append(next)
            let wait = min(next.duration, 6)
            if wait > 0.05 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        } catch { UMDiag.log("audio", "player error: \(error.localizedDescription)") }
    }

    private static func activateSession() {
        UMAudioSession.activatePlayback()
    }

    private static func bundledURL(_ name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        if let url = Bundle.main.url(forResource: safe, withExtension: "mp3") { return url }
        if let url = Bundle.main.url(forResource: safe, withExtension: "mp3", subdirectory: "Sounds") { return url }
        return nil
    }

    private static func supportURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ultimafia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safe).mp3")
    }

    private static func fileURL(_ name: String) async -> URL? {
        if let bundled = bundledURL(name) { return bundled }
        let dest = supportURL(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard localNames.contains(name) else { return nil }
        guard let remote = URL(string: "\(UMConfig.site)/audio/\(name).mp3") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: UMAccess.request(remote))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    nonisolated private static func makeRemoteURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(string: "\(UMConfig.site)" + s) }
        return URL(string: "\(UMConfig.site)/" + s)
    }
}



enum GameMusic {
    private static var player: AVAudioPlayer?
    private static var current: String?
    private static var loadTask: Task<Void, Never>?

    static func handlePhase(_ name: String) {
        let n = name.lowercased()
        if n.contains("pregame") {
            playLoop("music/PregameSandbox")
        } else if n.hasPrefix("give clue") || n == "dawn" || n.contains("night") {
            playLoop("music/NightGeneric")
        } else if n.contains("post") {
            return
        } else {
            stop()
        }
    }

    static func playLoop(_ path: String) {
        if current == path, player?.isPlaying == true {
            applyVolume()
            return
        }
        current = path
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            await start(path)
        }
    }

    static func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let player { UMAudioSession.stop([player]) }
        player = nil
        current = nil
    }

    static func applyVolume() {
        player?.volume = volume(for: current)
    }

    private static func volume(for path: String?) -> Float {
        if UMDictationAudio.active { return 0 }
        return (path ?? "").hasPrefix("music/Pregame") ? GameAudio.pregameMusic : GameAudio.music
    }

    @MainActor
    private static func start(_ path: String) async {
        activateSession()
        guard let url = await fileURL(path) else { return }
        guard !Task.isCancelled, current == path else { return }
        guard let next = await UMAudioSession.startPlayer(path, volume: volume(for: path), loops: -1, make: {
            try AVAudioPlayer(contentsOf: url)
        }) else { return }
        guard !Task.isCancelled, current == path else { UMAudioSession.stop([next]); return }
        if let player { UMAudioSession.stop([player]) }
        player = next
    }

    private static func activateSession() {
        UMAudioSession.activatePlayback()
    }

    private static func fileURL(_ path: String) async -> URL? {
        let safe = path.replacingOccurrences(of: "/", with: "-")
        let dest = UMCacheLocation.sounds
            .appendingPathComponent("um-\(safe).mp3")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let remote = URL(string: "\(UMConfig.site)/audio/\(path).mp3") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: UMAccess.request(remote))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }
}

enum ReadyNotifications {
    static let id = "ultimafia.readyCheck"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().delegate = ReadyNotificationDelegate.shared
    }

    static func notifyIfBackgrounded() {
        guard UMNotifyMaster.isOn, !isAppActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ultimafia"
        content.body = "Your game is starting! Accept ready check!"
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    static var isAppActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }
}

enum GameAlerts {
    static let mentionId = "ultimafia.mention"
    static let kicksId = "ultimafia.kicks"

    static func notifyMention() {
        post(id: mentionId, body: "Someone mentioned you! Come back!")
    }

    static let yourTurnId = "ultimafia.ldTurn"
    /// Liars Dice: it became your turn to bid while the app is in the background.
    static func notifyYourTurn() {
        post(id: yourTurnId, body: "Your turn to bid")
    }

    static func notifyKicks() {
        post(id: kicksId, body: "You are about to veg! The game is at kicks!")
    }

    private static func post(id: String, body: String) {
        guard UMNotifyMaster.isOn, !ReadyNotifications.isAppActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ultimafia"
        content.body = body
        content.sound = UMDictationAudio.active ? nil : .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class ReadyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReadyNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        UMDMNotify.foregroundOptions(for: notification)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { UMDMNotify.handleTap(info) }
    }
}

enum GameBackgroundHold {
    #if os(iOS)
    private static var task: UIBackgroundTaskIdentifier = .invalid
    #endif

    static func start() {
        #if os(iOS)
        end()
        task = UIApplication.shared.beginBackgroundTask(withName: "um-socket") {
            end()
        }
        #endif
    }

    static func end() {
        #if os(iOS)
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        #endif
    }
}

struct ReadyCheckOverlay: View {
    var session: GameSession
    var onLeave: () -> Void

    var body: some View {
        if session.needsReadyConfirm {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Ready Up?")
                        .font(.title2.weight(.bold))
                    Text("The game is starting! Please confirm you are here.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                    TimelineView(.periodic(from: .now, by: 0.2)) { context in
                        let left = max(0, session.readyEndTime.timeIntervalSince(context.date))
                        Text("\(Int(left.rounded(.up)))s")
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(left < 10 ? UMTheme.mafia : .white)
                    }
                    Text("Failure to ready up will result in being kicked.")
                        .font(.caption)
                        .foregroundStyle(UMTheme.muted)
                    HStack(spacing: 12) {
                        Button("Leave Game", role: .destructive) {
                            ReadyBell.stop()
                            onLeave()
                        }
                            .buttonStyle(.bordered)
                        Button("I am Ready") {
                            ReadyBell.stop()
                            session.verifyReady()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(UMTheme.village)
                        .background {
                            // Hardware Return/Enter accepts (listed in the Cmd-hold overlay).
                            Button("Accept Ready Check") { session.acceptReadyCheck() }
                                .keyboardShortcut(.return, modifiers: [])
                                .opacity(0)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: 360)
                .background(UMTheme.card, in: RoundedRectangle(cornerRadius: 18))
                .padding(28)
            }
            .onAppear { ReadyBell.start() }
            .onDisappear { ReadyBell.stop() }
        }
    }
}
