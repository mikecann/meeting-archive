import UserNotifications
import XCTest
@testable import MeetingArchiveApp
import MeetingArchiveCore

final class RecordingNoticeTests: XCTestCase {
    func testOnlyTheFirstPartOfACallAnnouncesItself() {
        XCTAssertEqual(CaptureNotice.started(source: "Google Chrome", part: 1)?.title, "Recording Google Chrome")
        XCTAssertNil(CaptureNotice.started(source: "Google Chrome", part: 2))
    }

    func testLaterPartsSayWhichPartTheyAre() {
        let start = Date(timeIntervalSince1970: 1_790_830_000)
        let first = CaptureNotice.defaultTitle(source: "zoom.us", startedAt: start, part: 1)
        let second = CaptureNotice.defaultTitle(source: "zoom.us", startedAt: start, part: 2)
        XCTAssertTrue(first.hasPrefix("zoom.us call "))
        XCTAssertFalse(first.contains("part"))
        XCTAssertEqual(second, first + " (part 2)")
    }

    func testManualRecordingsAreNamedAsSuch() {
        XCTAssertEqual(CaptureNotice.sourceName(.manual), "Manual recording")
        XCTAssertEqual(CaptureNotice.sourceName(.microphone(MicUser(bundleIdentifier: "com.hnc.Discord", displayName: "Discord"))), "Discord")
    }

    func testNotificationButtonsMapToActions() {
        XCTAssertEqual(NotificationRouter.action(identifier: "stop", userInfo: [:]), .stopRecording)
        XCTAssertEqual(NotificationRouter.action(identifier: "discard", userInfo: [:]), .discardRecording)
        let id = UUID()
        XCTAssertEqual(NotificationRouter.action(identifier: "discard-saved", userInfo: ["meetingID": id.uuidString]), .discardSaved(id))
        // Without a meeting there is nothing safe to discard.
        XCTAssertNil(NotificationRouter.action(identifier: "discard-saved", userInfo: [:]))
        // Clicking the banner itself is not a decision.
        XCTAssertNil(NotificationRouter.action(identifier: UNNotificationDefaultActionIdentifier, userInfo: [:]))
    }

    func testIgnoreListChangesSurviveNewDefaults() {
        let defaults: Set<String> = ["com.mikerosoft.voice-type", "com.apple.VoiceMemos"]
        let ignored = AppSettings.ignoredBundleIDs(defaults: defaults, extra: ["com.hnc.Discord"], recordedDefaults: ["com.apple.VoiceMemos"])
        XCTAssertEqual(ignored, ["com.mikerosoft.voice-type", "com.hnc.Discord"])
        // A default added in a later version is ignored without anyone opting in.
        let grown = AppSettings.ignoredBundleIDs(defaults: defaults.union(["com.example.new-dictation"]), extra: [], recordedDefaults: [])
        XCTAssertTrue(grown.contains("com.example.new-dictation"))
    }
}
