import Foundation
import MeetingArchiveCore
import XCTest
@testable import MeetingArchiveApp

final class CaptureLifecycleCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRapidOffOnDefersNextCaptureWhilePreviousMeetingFinalizes() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = CaptureLifecycleCoordinator()

        XCTAssertEqual(coordinator.requestStart(old), .start(old))
        XCTAssertEqual(
            coordinator.requestStop(meetingID: old.meetingID, reason: .cameraOff),
            .finalize(.init(meetingID: old.meetingID, reason: .cameraOff))
        )
        XCTAssertEqual(coordinator.requestStart(next), .deferred)
        XCTAssertEqual(coordinator.deferredStart, next)
    }

    func testSkipWhileStartIsDeferredPreventsItFromStartingAfterFinalization() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)
        let state = recorderState(for: next.session, phase: .suppressed(.skipped))

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: state,
            safeWindow: .init(sessionID: next.session.id, windowID: next.windowID)
        ))
        XCTAssertNil(coordinator.deferredStart)
    }

    func testCameraOffWhileStartIsDeferredPreventsItFromStartingAfterFinalization() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: RecorderState(),
            safeWindow: nil
        ))
        XCTAssertNil(coordinator.deferredStart)
    }

    func testStaleStopForOldMeetingCannotFinalizeNewWriter() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)
        let start = try XCTUnwrap(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: next.session, phase: .startRequested),
            safeWindow: .init(sessionID: next.session.id, windowID: next.windowID)
        ))

        XCTAssertEqual(start, next)
        XCTAssertEqual(coordinator.requestStop(meetingID: old.meetingID, reason: .cameraOff), .ignored)
        XCTAssertEqual(coordinator.activeStart, next)
    }

    func testLateStartupCallbackCannotStopMeetingPromotedAfterAbort() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = CaptureLifecycleCoordinator()
        _ = coordinator.requestStart(old)
        XCTAssertEqual(coordinator.requestStart(next), .deferred)

        let start = try XCTUnwrap(coordinator.startAborted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: next.session, phase: .startRequested),
            safeWindow: .init(sessionID: next.session.id, windowID: next.windowID)
        ))

        XCTAssertEqual(start, next)
        XCTAssertEqual(coordinator.requestStop(meetingID: old.meetingID, reason: .interrupted), .ignored)
        XCTAssertEqual(coordinator.activeStart, next)
    }

    func testMatchingDeferredStartUsesCurrentSafeWindowAfterPreviousFinalizes() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        let start = try XCTUnwrap(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: next.session, phase: .startRequested),
            safeWindow: .init(sessionID: next.session.id, windowID: 21)
        ))

        XCTAssertEqual(start.session, next.session)
        XCTAssertEqual(start.meetingID, next.meetingID)
        XCTAssertEqual(start.windowID, 21)
        XCTAssertEqual(coordinator.activeStart, start)
    }

    func testUnsafeWindowAtFinalizationRetriesAndStartsOnceWhenItBecomesSafe() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        let state = recorderState(for: next.session, phase: .startRequested)
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: state,
            safeWindow: nil
        ))
        XCTAssertEqual(coordinator.deferredStart, next)

        let start = try XCTUnwrap(coordinator.retryDeferredStart(
            recorderState: state,
            safeWindow: .init(sessionID: next.session.id, windowID: 21)
        ))
        XCTAssertEqual(start.windowID, 21)
        XCTAssertNil(coordinator.deferredStart)
        XCTAssertNil(coordinator.retryDeferredStart(
            recorderState: state,
            safeWindow: .init(sessionID: next.session.id, windowID: 21)
        ))
    }

    func testDeferredStartRequiresTheExactRequestedSession() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        let replacement = session(id: "replacement")
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: replacement, phase: .startRequested),
            safeWindow: .init(sessionID: replacement.id, windowID: 30)
        ))
    }

    func testAllAutomaticStopReasonsKeepTheRecordedPortion() {
        for reason in [CaptureStopReason.cameraOff, .skipped, .paused, .interrupted, .startFailed] {
            let request = CaptureFinalizationRequest(meetingID: UUID(), reason: reason)
            XCTAssertFalse(request.discardAfterFinalization, "\(reason) should keep captured media")
        }
    }

    func testOnlyAFailedStartIsSavedWithoutAskingForATitle() {
        for reason in [CaptureStopReason.cameraOff, .skipped, .paused, .interrupted] {
            XCTAssertTrue(CaptureFinalizationRequest(meetingID: UUID(), reason: reason).asksForTitle, "\(reason)")
        }
        XCTAssertFalse(CaptureFinalizationRequest(meetingID: UUID(), reason: .startFailed).asksForTitle)
    }

    func testRetryOfTheSameSessionWaitsForTheFailedStartToFinalize() throws {
        let failed = request(sessionID: "call", meetingID: UUID(), windowID: 10)
        let retry = CaptureStartRequest(session: failed.session, meetingID: UUID(), windowID: 10)
        var coordinator = CaptureLifecycleCoordinator()
        _ = coordinator.requestStart(failed)

        XCTAssertEqual(
            coordinator.requestStop(meetingID: failed.meetingID, reason: .startFailed),
            .finalize(.init(meetingID: failed.meetingID, reason: .startFailed))
        )
        XCTAssertEqual(coordinator.requestStart(retry), .deferred)

        let start = try XCTUnwrap(coordinator.finalizationCompleted(
            meetingID: failed.meetingID,
            recorderState: recorderState(for: failed.session, phase: .startRequested),
            safeWindow: .init(sessionID: failed.session.id, windowID: 11)
        ))
        XCTAssertEqual(start.meetingID, retry.meetingID)
        XCTAssertEqual(start.windowID, 11)
        XCTAssertEqual(coordinator.requestStop(meetingID: failed.meetingID, reason: .startFailed), .ignored)
        XCTAssertEqual(coordinator.activeStart, start)
    }

    func testStartThatFailedWithoutAWriterFreesTheWriterForItsRetry() {
        let failed = request(sessionID: "call", meetingID: UUID(), windowID: 10)
        let retry = CaptureStartRequest(session: failed.session, meetingID: UUID(), windowID: 10)
        var coordinator = CaptureLifecycleCoordinator()
        _ = coordinator.requestStart(failed)

        XCTAssertNil(coordinator.startAborted(
            meetingID: failed.meetingID,
            recorderState: recorderState(for: failed.session, phase: .retryScheduled(at: now.addingTimeInterval(10))),
            safeWindow: nil
        ))
        XCTAssertNil(coordinator.activeStart)
        XCTAssertEqual(coordinator.requestStart(retry), .start(retry))
    }

    func testInterruptedRecordingSaysItStoppedEarlyAndWhy() {
        let notice = CaptureNotice.saved(
            reason: .interrupted,
            meetingTitle: "All hands",
            detail: "The video encoder stopped accepting frames. The partial recording has been preserved."
        )

        XCTAssertEqual(notice.title, "Recording stopped early")
        XCTAssertEqual(
            notice.body,
            "The video encoder stopped accepting frames. The partial recording has been preserved. "
                + "Saving All hands. You can rename or discard it in the brief window."
        )
    }

    func testMeetingThatEndedStillSaysTheRecordingFinished() {
        for reason in [CaptureStopReason.cameraOff, .skipped, .paused] {
            let notice = CaptureNotice.saved(reason: reason, meetingTitle: "All hands", detail: "Not shown")
            XCTAssertEqual(notice.title, "Recording finished", "\(reason)")
            XCTAssertEqual(notice.body, "Saving All hands. You can rename or discard it in the brief window.", "\(reason)")
        }
    }

    func testFailedStartNotifiesWhenItFirstHappensAndWhenItGivesUp() throws {
        let detail = "Capture did not produce both meeting video and microphone audio within 15 seconds."

        let first = try XCTUnwrap(CaptureNotice.startFailed(failedStarts: 1, retryIn: 10, detail: detail))
        XCTAssertEqual(first.title, "Recording didn't start")
        XCTAssertEqual(first.body, "\(detail) Trying again in 10 seconds.")

        // Retries in between only update the menu, so a stubborn failure
        // cannot post every 15 seconds.
        XCTAssertNil(CaptureNotice.startFailed(failedStarts: 2, retryIn: 30, detail: detail))
        XCTAssertNil(CaptureNotice.startFailed(failedStarts: 3, retryIn: 60, detail: detail))

        let last = try XCTUnwrap(CaptureNotice.startFailed(failedStarts: 4, retryIn: nil, detail: detail))
        XCTAssertEqual(last.title, "Couldn't record this meeting")
        XCTAssertEqual(
            last.body,
            "\(detail) Gave up after 4 tries. To try again, turn your camera off for about 30 seconds, then back on."
        )
        XCTAssertEqual(
            CaptureNotice.gaveUpWarning(failedStarts: 4, detail: detail),
            "Couldn't record this meeting after 4 tries. \(detail)"
        )
    }

    func testRetryStatusCountsDownToTheNextTry() {
        XCTAssertEqual(
            CaptureNotice.retryStatus(until: now.addingTimeInterval(8), now: now),
            "Recording didn't start • trying again in 8s"
        )
        XCTAssertEqual(
            CaptureNotice.retryStatus(until: now.addingTimeInterval(0.2), now: now),
            "Recording didn't start • trying again in 1s"
        )
        XCTAssertEqual(CaptureNotice.retryStatus(until: now, now: now), "Recording didn't start • trying again")
    }

    func testCaptureNoticesUseNoDashes() throws {
        let detail = "Capture did not produce both meeting video and microphone audio within 15 seconds."
        var text = [
            CaptureNotice.retryStatus(until: now.addingTimeInterval(8), now: now),
            CaptureNotice.retryStatus(until: now, now: now),
            CaptureNotice.gaveUpWarning(failedStarts: 4, detail: detail),
        ]
        for reason in [CaptureStopReason.cameraOff, .skipped, .paused, .interrupted] {
            let notice = CaptureNotice.saved(reason: reason, meetingTitle: "All hands", detail: detail)
            text += [notice.title, notice.body]
        }
        for (failedStarts, retryIn) in [(1, Optional(10)), (4, nil)] {
            let notice = try XCTUnwrap(CaptureNotice.startFailed(failedStarts: failedStarts, retryIn: retryIn, detail: detail))
            text += [notice.title, notice.body]
        }

        for line in text {
            XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
        }
    }

    private func finalizingCoordinator(
        old: CaptureStartRequest,
        deferred: CaptureStartRequest
    ) -> CaptureLifecycleCoordinator {
        var coordinator = CaptureLifecycleCoordinator()
        _ = coordinator.requestStart(old)
        _ = coordinator.requestStop(meetingID: old.meetingID, reason: .cameraOff)
        _ = coordinator.requestStart(deferred)
        return coordinator
    }

    private func recorderState(
        for session: MeetingSessionDescriptor,
        phase: ActiveSessionPhase
    ) -> RecorderState {
        RecorderState(currentSession: ActiveMeetingSession(
            descriptor: session,
            phase: phase,
            firstObservedAt: now,
            meetingID: nil
        ))
    }

    private func request(sessionID: String, meetingID: UUID, windowID: UInt32) -> CaptureStartRequest {
        CaptureStartRequest(session: session(id: sessionID), meetingID: meetingID, windowID: windowID)
    }

    private func session(id: String) -> MeetingSessionDescriptor {
        MeetingSessionDescriptor(
            id: id,
            sourceApplication: .init(
                bundleIdentifier: "com.google.Chrome",
                displayName: "Google Chrome",
                kind: .googleMeet
            ),
            surface: .init(id: "cg-window-\(id)", title: "Meeting", kind: .meeting),
            attribution: .positive
        )
    }
}
