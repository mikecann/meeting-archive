import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedCalendarIDs: Set<String> { didSet { defaults.set(Array(selectedCalendarIDs), forKey: "calendarIDs") } }
    @Published var archiveHost: String { didSet { defaults.set(archiveHost, forKey: "archiveHost") } }
    @Published var archiveRoot: String { didSet { defaults.set(archiveRoot, forKey: "archiveRoot") } }
    /// Bruce's playback viewer behind Tailscale Serve. It streams video with
    /// range requests and shows the transcript, so nothing is copied locally.
    @Published var viewerURL: String { didSet { defaults.set(viewerURL, forKey: "viewerURL") } }
    // Enable only after checking that this directory is included in Bruce's
    // existing backup. A network transfer is not evidence of backup coverage.
    @Published var backupCoverageVerified: Bool { didSet { defaults.set(backupCoverageVerified, forKey: "backupCoverageVerified") } }
    /// Changes to the built-in ignore list are stored as differences, so apps
    /// added to the defaults in a later version are still ignored.
    @Published private(set) var extraIgnoredBundleIDs: Set<String> { didSet { defaults.set(Array(extraIgnoredBundleIDs), forKey: "extraIgnoredBundleIDs") } }
    @Published private(set) var recordedDefaultBundleIDs: Set<String> { didSet { defaults.set(Array(recordedDefaultBundleIDs), forKey: "recordedDefaultBundleIDs") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedCalendarIDs = Set(defaults.stringArray(forKey: "calendarIDs") ?? [])
        archiveHost = defaults.string(forKey: "archiveHost") ?? "bruce"
        archiveRoot = defaults.string(forKey: "archiveRoot") ?? "/Volumes/CannMedia/MeetingArchive"
        viewerURL = defaults.string(forKey: "viewerURL") ?? "https://bruce.tail9ef766.ts.net:10443"
        backupCoverageVerified = defaults.bool(forKey: "backupCoverageVerified")
        extraIgnoredBundleIDs = Set(defaults.stringArray(forKey: "extraIgnoredBundleIDs") ?? [])
        recordedDefaultBundleIDs = Set(defaults.stringArray(forKey: "recordedDefaultBundleIDs") ?? [])
    }

    /// Apps whose use of the mic never starts a recording.
    var ignoredBundleIDs: Set<String> {
        AppSettings.ignoredBundleIDs(defaults: MicAppResolver.defaultIgnoredBundleIDs, extra: extraIgnoredBundleIDs, recordedDefaults: recordedDefaultBundleIDs)
    }

    /// Whatever the case, as the mic monitor matches it.
    func isIgnored(_ bundleIdentifier: String) -> Bool {
        ignoredBundleIDs.contains { Self.same($0, bundleIdentifier) }
    }

    func ignore(_ bundleIdentifier: String) {
        guard !isIgnored(bundleIdentifier) else { return }
        if MicAppResolver.defaultIgnoredBundleIDs.contains(where: { Self.same($0, bundleIdentifier) }) {
            recordedDefaultBundleIDs = recordedDefaultBundleIDs.filter { !Self.same($0, bundleIdentifier) }
        } else {
            extraIgnoredBundleIDs.insert(bundleIdentifier)
        }
    }

    func stopIgnoring(_ bundleIdentifier: String) {
        guard !Self.isMeetingArchive(bundleIdentifier) else { return }
        // An app ignored in Settings before a later version made it a
        // default is in both lists, so clear both.
        extraIgnoredBundleIDs = extraIgnoredBundleIDs.filter { !Self.same($0, bundleIdentifier) }
        recordedDefaultBundleIDs.formUnion(MicAppResolver.defaultIgnoredBundleIDs.filter { Self.same($0, bundleIdentifier) })
    }

    nonisolated static func ignoredBundleIDs(defaults: Set<String>, extra: Set<String>, recordedDefaults: Set<String>) -> Set<String> {
        defaults.subtracting(recordedDefaults).union(extra)
    }

    /// Meeting Archive hearing itself would start a recording of a recording.
    /// This doesn't go by `Bundle.main`, which has no identifier when the app
    /// runs straight from SwiftPM.
    nonisolated static func isMeetingArchive(_ bundleIdentifier: String) -> Bool {
        same(bundleIdentifier, MicAppResolver.meetingArchiveBundleID)
    }

    private nonisolated static func same(_ first: String, _ second: String) -> Bool {
        first.lowercased() == second.lowercased()
    }
}

enum AppPaths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["MEETING_ARCHIVE_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Meeting Archive", isDirectory: true)
    }
    static var spool: URL { root.appendingPathComponent("spool", isDirectory: true) }
    static var index: URL { root.appendingPathComponent("index", isDirectory: true) }
    static func meeting(_ id: UUID) -> URL { spool.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
}
