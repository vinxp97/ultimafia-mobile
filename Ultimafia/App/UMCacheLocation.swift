import Foundation

/// One device-wide cache folder shared by every account: Application Support/UMCache.
/// Unlike Caches/, iOS doesn't purge it under storage pressure; only the You-tab clear button
/// empties it. Excluded from iCloud/device backups. Never holds logins, settings or order data.
nonisolated enum UMCacheLocation {
    static let root: URL = {
        let fm = FileManager.default
        var url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UMCache", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        migrateFromCachesOnce(into: url)
        return url
    }()

    static func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var customAssets: URL { dir("UMCustomAssets") }
    static var images: URL { root.appendingPathComponent("UMImages", isDirectory: true) }
    static var nameFonts: URL { dir("UMNameFonts") }
    static var sounds: URL { dir("Sounds") }
    static var anonDecks: URL { dir("AnonDecks") }

    /// Move the old Caches/ folders and sound files here once, then remove the leftovers.
    ///
    /// Done marker is a file, not a UserDefaults write: this runs inside `root`'s one-time
    /// initialiser, and a defaults write posts didChange synchronously to SwiftUI's @AppStorage
    /// observers, which wait for SwiftUI's update lock. If the main thread is in a view update
    /// that reads `root` at that moment (the You tab's cache size), each waits on the other and
    /// the app freezes. Seen on a fresh install: UMTerminology.load hit `root` first in the
    /// background while the You tab opened. Installs that already have the old key skip as before.
    private static func migrateFromCachesOnce(into root: URL) {
        let legacyKey = "um.cache.movedToAppSupport.v1"
        let fm = FileManager.default
        let marker = root.appendingPathComponent(".movedToAppSupport.v1")
        guard !UserDefaults.standard.bool(forKey: legacyKey), !fm.fileExists(atPath: marker.path) else { return }
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["UMCustomAssets", "UMNameFonts", "UMImages"] {
            let old = caches.appendingPathComponent(name, isDirectory: true)
            let new = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: old.path) else { continue }
            if !fm.fileExists(atPath: new.path), (try? fm.moveItem(at: old, to: new)) != nil { continue }
            try? fm.removeItem(at: old)
        }
        let sounds = root.appendingPathComponent("Sounds", isDirectory: true)
        try? fm.createDirectory(at: sounds, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("um-") && file.pathExtension == "mp3" {
            let dest = sounds.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) || (try? fm.moveItem(at: file, to: dest)) == nil {
                try? fm.removeItem(at: file)
            }
        }
        fm.createFile(atPath: marker.path, contents: nil)
    }

    static func bytes() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var sum: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: Set(keys))
            sum += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return sum
    }
}
