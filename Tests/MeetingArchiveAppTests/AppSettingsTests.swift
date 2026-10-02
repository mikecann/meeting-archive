import XCTest
@testable import MeetingArchiveApp

/// Each test gets an empty defaults domain of its own, never the app's.
@MainActor
final class AppSettingsTests: XCTestCase {
    private let voiceMemos = "com.apple.VoiceMemos"

    func testRecordItWorksForAnAppIgnoredBeforeItWasBuiltIn() {
        let defaults = emptyDefaults()
        // Saved by a version that didn't ignore Voice Memos by default yet.
        defaults.set([voiceMemos], forKey: "extraIgnoredBundleIDs")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.ignoredBundleIDs.contains(voiceMemos))

        settings.stopIgnoring(voiceMemos)
        XCTAssertFalse(settings.ignoredBundleIDs.contains(voiceMemos))
        XCTAssertFalse(AppSettings(defaults: defaults).ignoredBundleIDs.contains(voiceMemos), "after a relaunch too")
    }

    func testMeetingArchiveCannotBeRecorded() {
        let settings = AppSettings(defaults: emptyDefaults())

        settings.stopIgnoring("com.mikerosoft.meeting-archive")
        settings.stopIgnoring("COM.MIKEROSOFT.MEETING-ARCHIVE")
        XCTAssertTrue(settings.ignoredBundleIDs.contains("com.mikerosoft.meeting-archive"))
        XCTAssertTrue(AppSettings.isMeetingArchive("Com.Mikerosoft.Meeting-Archive"))
        XCTAssertFalse(AppSettings.isMeetingArchive("com.mikerosoft.voice-type"))
    }

    func testABuiltInIgnoreMatchesWhateverTheCase() {
        let defaults = emptyDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.stopIgnoring("COM.APPLE.VOICEMEMOS")
        XCTAssertFalse(settings.isIgnored(voiceMemos))
        XCTAssertFalse(settings.ignoredBundleIDs.contains { $0.lowercased() == voiceMemos.lowercased() })

        settings.ignore("com.apple.voicememos")
        XCTAssertTrue(settings.isIgnored(voiceMemos))
        // Ignoring it again undoes "Record it" rather than adding a copy.
        XCTAssertEqual(defaults.stringArray(forKey: "extraIgnoredBundleIDs") ?? [], [])
        XCTAssertEqual(defaults.stringArray(forKey: "recordedDefaultBundleIDs") ?? [], [])
    }

    func testOtherAppsAreIgnoredAndRecordedWhateverTheCase() {
        let settings = AppSettings(defaults: emptyDefaults())

        settings.ignore("com.example.Chatter")
        XCTAssertTrue(settings.isIgnored("COM.EXAMPLE.CHATTER"))
        settings.ignore("com.example.chatter")
        XCTAssertEqual(settings.ignoredBundleIDs.filter { $0.lowercased() == "com.example.chatter" }.count, 1)

        settings.stopIgnoring("COM.EXAMPLE.CHATTER")
        XCTAssertFalse(settings.isIgnored("com.example.Chatter"))
    }

    private func emptyDefaults() -> UserDefaults {
        let name = "MeetingArchiveAppSettingsTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }
}
