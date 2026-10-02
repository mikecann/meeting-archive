import UserNotifications
import XCTest
@testable import MeetingArchiveApp
import MeetingArchiveCore

final class RecordingNoticeTests: XCTestCase {
    func testAResumedCallSaysItIsRecordingAgain() {
        XCTAssertEqual(CaptureNotice.started(source: "Google Chrome", resumed: false).title, "Recording Google Chrome")
        XCTAssertEqual(CaptureNotice.started(source: "Google Chrome", resumed: true).title, "Recording Google Chrome again")
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

    func testNotificationButtonsMapToActionsForTheirOwnCall() {
        let series = UUID()
        XCTAssertEqual(NotificationRouter.action(identifier: "stop", userInfo: ["seriesID": series.uuidString]), .stopRecording(seriesID: series))
        XCTAssertEqual(NotificationRouter.action(identifier: "discard", userInfo: ["seriesID": series.uuidString]), .discardRecording(seriesID: series))
        let id = UUID()
        XCTAssertEqual(NotificationRouter.action(identifier: "discard-saved", userInfo: ["meetingID": id.uuidString]), .discardSaved(id))
        // Without knowing which call, there is nothing safe to stop or discard.
        XCTAssertNil(NotificationRouter.action(identifier: "stop", userInfo: [:]))
        XCTAssertNil(NotificationRouter.action(identifier: "discard", userInfo: [:]))
        XCTAssertNil(NotificationRouter.action(identifier: "discard-saved", userInfo: [:]))
        // Clicking the banner itself is not a decision.
        XCTAssertNil(NotificationRouter.action(identifier: UNNotificationDefaultActionIdentifier, userInfo: [:]))
    }

    /// macOS may stop an app it woke for a button once the response is
    /// marked handled, so that only happens after the button has done its work.
    @MainActor
    func testAButtonIsMarkedHandledOnlyAfterItsActionRuns() async {
        let router = NotificationRouter()
        let steps = Steps()
        router.handler = { _ in steps.add("acted") }
        let handled = expectation(description: "response handled")

        router.respond(to: .discardSaved(UUID())) {
            steps.add("handled")
            handled.fulfill()
        }

        await fulfillment(of: [handled], timeout: 5)
        XCTAssertEqual(steps.all, ["acted", "handled"])
    }

    @MainActor
    func testClickingTheBannerItselfIsStillMarkedHandled() async {
        let router = NotificationRouter()
        let handled = expectation(description: "response handled")

        router.respond(to: nil) { handled.fulfill() }

        await fulfillment(of: [handled], timeout: 5)
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

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    var all: [String] { lock.withLock { steps } }
    func add(_ step: String) { lock.withLock { steps.append(step) } }
}
