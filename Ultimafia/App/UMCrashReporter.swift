import Foundation
import CryptoKit
import Observation
import SwiftUI
#if os(iOS)
import MetricKit
import UIKit
#endif

/// Crash and hang reports from Apple's MetricKit, kept on this device only (no upload, no SDK).
/// Each MXDiagnosticPayload that carries crash or hang diagnostics is saved as its
/// `jsonRepresentation()` under Application Support/CrashReports; the user shares them by hand.
nonisolated enum UMCrashStore {
    static let maxFiles = 10
    private static let seenKey = "um.crashReports.seen"

    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Newest first.
    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Saves one payload's JSON. Name: `<kind>-<yyyyMMdd-HHmmss>-v<version>-b<build>-<hash>.json`, so
    /// the newest sort first and the same payload (MetricKit re-delivers past ones) is stored once.
    @discardableResult
    static func save(json: Data, kind: String, version: String, build: String, date: Date) -> URL? {
        let hash = SHA256.hash(data: json).prefix(4).map { String(format: "%02x", $0) }.joined()
        if files().contains(where: { $0.lastPathComponent.contains("-\(hash).json") }) { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(kind)-\(f.string(from: date))-v\(safe(version))-b\(safe(build))-\(hash).json"
        let url = directory.appendingPathComponent(name)
        do {
            try json.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        prune()
        return url
    }

    static func prune() {
        for old in files().dropFirst(maxFiles) { try? FileManager.default.removeItem(at: old) }
    }

    static func clear() {
        for url in files() { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removeObject(forKey: seenKey)
    }

    static var seen: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    static func markSeen(_ urls: [URL]) {
        let names = seen.union(urls.map(\.lastPathComponent))
        // Only names that still exist, so the list never grows past the kept files.
        let present = Set(files().map(\.lastPathComponent))
        UserDefaults.standard.set(Array(names.intersection(present)), forKey: seenKey)
    }

    private static func safe(_ s: String) -> String {
        let out = s.filter { $0.isLetter || $0.isNumber || $0 == "." }
        return out.isEmpty ? "unknown" : out
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
}

#if os(iOS)
/// MetricKit delivers on a background queue, so the subscriber is nonisolated and only touches
/// the file store; the observable model refreshes on the main actor afterwards.
nonisolated final class UMCrashSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.store(Self.entries(payloads))
        Task { @MainActor in UMCrashReporter.shared.reload() }
    }

    /// What gets written for one payload, as plain values (safe to hand to another thread).
    struct Entry: Sendable {
        var json: Data, kind: String, version: String, build: String, date: Date
    }

    /// Only payloads with crash or hang diagnostics are kept.
    static func entries(_ payloads: [MXDiagnosticPayload]) -> [Entry] {
        payloads.compactMap { payload in
            let crashes = payload.crashDiagnostics ?? []
            let hangs = payload.hangDiagnostics ?? []
            guard !crashes.isEmpty || !hangs.isEmpty else { return nil }
            // Version/build of the run that crashed (not necessarily this one).
            let first: MXDiagnostic? = crashes.first ?? hangs.first
            return Entry(json: payload.jsonRepresentation(),
                         kind: crashes.isEmpty ? "hang" : "crash",
                         version: first?.applicationVersion ?? UMCrashStore.appVersion,
                         build: first?.metaData.applicationBuildVersion ?? UMCrashStore.appBuild,
                         date: payload.timeStampEnd)
        }
    }

    static func store(_ entries: [Entry]) {
        for e in entries {
            UMCrashStore.save(json: e.json, kind: e.kind, version: e.version, build: e.build, date: e.date)
        }
    }
}
#endif

@MainActor
@Observable
final class UMCrashReporter {
    static let shared = UMCrashReporter()

    private(set) var reports: [URL] = []
    /// One-time prompt on launch when there are reports the user hasn't been asked about.
    var showPrompt = false
    private var started = false
    #if os(iOS)
    @ObservationIgnored private let subscriber = UMCrashSubscriber()
    #endif

    var unseen: [URL] {
        let seen = UMCrashStore.seen
        return reports.filter { !seen.contains($0.lastPathComponent) }
    }

    /// Called once at launch: subscribe, collect anything MetricKit already has, then decide
    /// whether to ask. Reports that arrive later in the session wait for the next launch.
    func start() {
        guard !started else { return }
        started = true
        #if os(iOS)
        MXMetricManager.shared.add(subscriber)
        let past = UMCrashSubscriber.entries(MXMetricManager.shared.pastDiagnosticPayloads)
        let sample = Self.diagSample
        // Disk work off the main thread; the prompt decision comes back to it.
        Task.detached(priority: .utility) {
            UMCrashSubscriber.store(past)
            if let sample { Self.writeSample(sample) }
            await MainActor.run {
                UMCrashReporter.shared.reload()
                UMCrashReporter.shared.showPrompt = !UMCrashReporter.shared.unseen.isEmpty
            }
        }
        #endif
    }

    func reload() {
        reports = UMCrashStore.files()
    }

    func markAllSeen() {
        UMCrashStore.markSeen(reports)
        showPrompt = false
    }

    func clear() {
        UMCrashStore.clear()
        reload()
        showPrompt = false
    }

    /// Text that goes with the shared files.
    var shareSummary: String {
        #if os(iOS)
        let os = "iOS \(UIDevice.current.systemVersion)"
        #else
        let os = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        return "UltiMafia crash report: version \(UMCrashStore.appVersion) (build \(UMCrashStore.appBuild)), \(os), \(reports.count) report\(reports.count == 1 ? "" : "s")."
    }

    // MARK: DEBUG sample

    /// `-UMDiagCrash` writes one fake report (unseen, so the prompt shows); `-UMDiagCrash seen`
    /// writes it already seen (for the You-tab row without the sheet). DEBUG builds only.
    nonisolated private static var diagSample: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UMDiagCrash") else { return nil }
        return args.indices.contains(i + 1) && args[i + 1] == "seen" ? "seen" : "unseen"
        #else
        return nil
        #endif
    }

    nonisolated private static func writeSample(_ mode: String) {
        #if DEBUG
        let sample: [String: Any] = [
            "timeStampBegin": "2026-10-27 19:00:00", "timeStampEnd": "2026-10-27 19:13:00",
            "crashDiagnostics": [[
                "version": "1.0.0", "callStackTree": ["callStacks": [], "callStackPerThread": true],
                "diagnosticMetaData": ["appVersion": UMCrashStore.appVersion, "appBuildVersion": UMCrashStore.appBuild,
                                       "osVersion": "iPhone OS 26.6.2", "deviceType": "iPhone18,1",
                                       "exceptionType": 1, "exceptionCode": 0, "signal": 11,
                                       "terminationReason": "SAMPLE: -UMDiagCrash fake report"],
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]),
              let url = UMCrashStore.save(json: data, kind: "crash", version: UMCrashStore.appVersion,
                                          build: UMCrashStore.appBuild, date: Date())
                ?? UMCrashStore.files().first(where: { $0.lastPathComponent.hasPrefix("crash-") }) else { return }
        if mode == "seen" { UMCrashStore.markSeen([url]) }
        #endif
    }
}

/// "UltiMafia crashed last time" prompt: Share (the JSON files plus a version line) or Not Now.
/// Either way the reports are marked seen, so it only asks once per report.
struct UMCrashPromptSheet: View {
    var reporter: UMCrashReporter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(UMTheme.blood)
            Text("UltiMafia crashed last time")
                .font(.title3.weight(.bold))
            Text("Send the crash report to help fix it? It contains Apple's crash details for the app (no messages or account info) and goes only where you choose to share it.")
                .font(.subheadline)
                .foregroundStyle(UMTheme.muted)
                .multilineTextAlignment(.center)
            ShareLink(items: reporter.reports,
                      subject: Text("UltiMafia crash report"),
                      message: Text(reporter.shareSummary)) {
                Label("Share Report", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(UMTheme.blood, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .simultaneousGesture(TapGesture().onEnded { UMCrashStore.markSeen(reporter.reports) })
            Button("Not Now") { dismiss() }
                .font(.headline)
                .foregroundStyle(UMTheme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UMTheme.bg.ignoresSafeArea())
        .presentationDetents([.medium])
        .onDisappear { reporter.markAllSeen() }
    }
}

/// Settings > Diagnostics: count of saved reports, Share and Clear.
struct UMCrashReportsSection: View {
    var reporter = UMCrashReporter.shared
    @State private var confirmClear = false

    var body: some View {
        Section {
            if reporter.reports.isEmpty {
                Text("No crash reports")
                    .foregroundStyle(UMTheme.muted)
                    .listRowBackground(UMTheme.card)
            } else {
                HStack {
                    Text("Crash reports")
                    Spacer()
                    Text("\(reporter.reports.count)")
                        .foregroundStyle(UMTheme.muted)
                        .monospacedDigit()
                }
                .listRowBackground(UMTheme.card)
                ShareLink(items: reporter.reports,
                          subject: Text("UltiMafia crash report"),
                          message: Text(reporter.shareSummary)) {
                    Label("Share crash reports", systemImage: "square.and.arrow.up")
                }
                .listRowBackground(UMTheme.card)
                Button("Clear", role: .destructive) { confirmClear = true }
                    .listRowBackground(UMTheme.card)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Crash and hang reports from Apple's MetricKit, kept on this device (up to \(UMCrashStore.maxFiles)). Nothing is sent unless you share it.")
        }
        .id("um.crashReports")
        .onAppear { reporter.reload() }
        .confirmationDialog("Delete saved crash reports?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { reporter.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
