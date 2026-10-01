import Foundation
import Synchronization
import XCTest
@testable import MeetingArchiveCore

final class RecordingPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ids = SequentialIDs()
    private let zoom = MicUser(bundleIdentifier: "us.zoom.xos", displayName: "zoom.us")
    private let chrome = MicUser(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
    private let slack = MicUser(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")

    // MARK: Starting from the mic

    func testFirstMicUserStartsPartOneOfANewSeries() {
        var policy = makePolicy()

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(0))),
            [.startCapture(meetingID: id(2), trigger: .microphone(zoom), seriesID: id(1), part: 1)]
        )
        XCTAssertEqual(policy.state.active, ActiveRecording(
            meetingID: id(2),
            seriesID: id(1),
            part: 1,
            trigger: .microphone(zoom),
            startedAt: t(0),
            lastHeldAt: t(0),
            isCapturing: false,
            consecutiveFailures: 0
        ))
        XCTAssertNil(policy.state.pendingRestart)
    }

    func testNobodyOnTheMicStartsNothing() {
        var policy = makePolicy()

        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(0))), [])
        XCTAssertEqual(policy.state, RecordingPolicyState())
    }

    func testTheFirstAppInTheListIsRecordedWhenSeveralHoldTheMic() {
        var policy = makePolicy()

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [chrome, zoom], at: t(0))),
            [.startCapture(meetingID: id(2), trigger: .microphone(chrome), seriesID: id(1), part: 1)]
        )
    }

    func testHoldingTheMicKeepsThePartAndMovesLastHeldAt() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(10))), [])
        XCTAssertEqual(policy.state.active?.meetingID, id(2))
        XCTAssertEqual(policy.state.active?.lastHeldAt, t(10))
        XCTAssertEqual(policy.state.active?.startedAt, t(0))
    }

    // MARK: Letting go of the mic

    func testReleaseStopsOnlyOnceTheGracePeriodHasPassed() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.tick(micUsers: [zoom], at: t(10)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(11))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(39.999))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [], at: t(40))),
            [.stopCapture(meetingID: id(2), reason: .micReleased)]
        )
        XCTAssertNil(policy.state.active)
        XCTAssertNil(policy.state.pendingRestart)
        XCTAssertEqual(policy.state.suppressedBundleIDs, [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(41))), [])
    }

    func testTakingTheMicBackWithinTheGraceKeepsTheSamePart() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.tick(micUsers: [], at: t(1)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(29))), [])
        XCTAssertEqual(policy.state.active?.meetingID, id(2))

        // The grace starts again from the last tick it was held.
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(58))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [], at: t(59))),
            [.stopCapture(meetingID: id(2), reason: .micReleased)]
        )
    }

    func testTheSameAppTakingTheMicAfterItsRecordingEndedStartsANewSeries() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.tick(micUsers: [], at: t(30)))

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(31))),
            [.startCapture(meetingID: id(4), trigger: .microphone(zoom), seriesID: id(3), part: 1)]
        )
    }

    // MARK: Switching apps

    func testAnotherAppTakingOverStopsThisPartAndStartsANewSeriesAtOnce() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [chrome], at: t(5))),
            [
                .stopCapture(meetingID: id(2), reason: .switchedApp),
                .startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1),
            ]
        )
        XCTAssertEqual(policy.state.active?.trigger, .microphone(chrome))
        XCTAssertEqual(policy.state.active?.startedAt, t(5))
    }

    func testASwitchDuringTheGraceDoesNotWaitForIt() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.tick(micUsers: [], at: t(1)))

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [chrome], at: t(2))),
            [
                .stopCapture(meetingID: id(2), reason: .switchedApp),
                .startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1),
            ]
        )
    }

    func testASecondAppJoiningDoesNotTakeTheRecordingFromTheFirst() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom, chrome], at: t(1))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [chrome, zoom], at: t(2))), [])
        XCTAssertEqual(policy.state.active?.trigger, .microphone(zoom))
        XCTAssertEqual(policy.state.active?.lastHeldAt, t(2))
    }

    func testASuppressedAppIsNeverASwitchTarget() {
        var policy = makePolicy(state: RecordingPolicyState(suppressedBundleIDs: [slack.bundleIdentifier]))
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [slack, zoom], at: t(0))),
            [.startCapture(meetingID: id(2), trigger: .microphone(zoom), seriesID: id(1), part: 1)]
        )

        XCTAssertEqual(policy.handle(.tick(micUsers: [slack], at: t(1))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [slack], at: t(30))),
            [.stopCapture(meetingID: id(2), reason: .micReleased)]
        )
    }

    func testASwitchGoesToTheFirstUnsuppressedApp() {
        var policy = makePolicy(state: RecordingPolicyState(suppressedBundleIDs: [slack.bundleIdentifier]))
        policy.handle(.tick(micUsers: [slack, zoom], at: t(0)))

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [slack, chrome], at: t(1))),
            [
                .stopCapture(meetingID: id(2), reason: .switchedApp),
                .startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1),
            ]
        )
    }

    // MARK: Record now

    func testRecordNowStartsAManualSeriesThatIgnoresTheMic() {
        var policy = makePolicy()

        XCTAssertEqual(
            policy.handle(.manualStart(at: t(0))),
            [.startCapture(meetingID: id(2), trigger: .manual, seriesID: id(1), part: 1)]
        )
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(600))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(601))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [chrome], at: t(602))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(3600))), [])
        XCTAssertEqual(policy.state.active?.meetingID, id(2))
        XCTAssertEqual(
            policy.handle(.manualStop(at: t(3601))),
            [.stopCapture(meetingID: id(2), reason: .userStopped)]
        )
    }

    func testRecordNowPinsAMicRecordingSoLettingGoNoLongerEndsIt() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(policy.handle(.manualStart(at: t(1))), [])
        XCTAssertEqual(policy.state.active?.trigger, .manual)
        XCTAssertEqual(policy.state.active?.meetingID, id(2))
        XCTAssertEqual(policy.state.active?.seriesID, id(1))
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(100))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [chrome], at: t(101))), [])
        XCTAssertEqual(policy.state.active?.meetingID, id(2))
    }

    func testRecordNowDuringAManualRecordingChangesNothing() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))
        let before = policy.state

        XCTAssertEqual(policy.handle(.manualStart(at: t(1))), [])
        XCTAssertEqual(policy.state, before)
    }

    func testRecordNowWorksWhilePaused() {
        var policy = makePolicy()
        policy.handle(.setPaused(true, at: t(0)))

        XCTAssertEqual(
            policy.handle(.manualStart(at: t(1))),
            [.startCapture(meetingID: id(2), trigger: .manual, seriesID: id(1), part: 1)]
        )
    }

    // MARK: Stop, discard and suppression

    func testStopSuppressesTheAppUntilItLetsGoOfTheMic() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(
            policy.handle(.manualStop(at: t(10))),
            [.stopCapture(meetingID: id(2), reason: .userStopped)]
        )
        XCTAssertNil(policy.state.active)
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier])

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(11))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(500))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(501))), [])
        XCTAssertEqual(policy.state.suppressedBundleIDs, [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(502))),
            [.startCapture(meetingID: id(4), trigger: .microphone(zoom), seriesID: id(3), part: 1)]
        )
    }

    func testDiscardStopsAndSuppressesLikeStop() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(
            policy.handle(.discardCurrent(at: t(10))),
            [.stopCapture(meetingID: id(2), reason: .discarded)]
        )
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(11))), [])
    }

    func testStopSuppressesEveryAppOnTheMicSoNothingTakesOverStraightAway() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom, chrome], at: t(0)))

        XCTAssertEqual(
            policy.handle(.manualStop(at: t(5))),
            [.stopCapture(meetingID: id(2), reason: .userStopped)]
        )
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier, chrome.bundleIdentifier])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom, chrome], at: t(6))), [])

        // Chrome lets go, so its next session is a new one.
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(7))), [])
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom, chrome], at: t(8))),
            [.startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1)]
        )
    }

    func testStoppingAPinnedRecordingDoesNotRestartItsCall() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.manualStart(at: t(1)))

        XCTAssertEqual(
            policy.handle(.manualStop(at: t(2))),
            [.stopCapture(meetingID: id(2), reason: .userStopped)]
        )
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(3))), [])
    }

    func testStoppingAManualRecordingSuppressesAppsThatTookTheMicDuringIt() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))
        policy.handle(.tick(micUsers: [zoom], at: t(60)))

        XCTAssertEqual(
            policy.handle(.manualStop(at: t(120))),
            [.stopCapture(meetingID: id(2), reason: .userStopped)]
        )
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(121))), [])
    }

    func testStopOrDiscardWithNothingRecordingChangesNothing() {
        var policy = makePolicy()
        policy.handle(.setPaused(true, at: t(0)))
        policy.handle(.tick(micUsers: [zoom], at: t(1)))
        let before = policy.state

        XCTAssertEqual(policy.handle(.manualStop(at: t(2))), [])
        XCTAssertEqual(policy.handle(.discardCurrent(at: t(3))), [])
        XCTAssertEqual(policy.state, before)
    }

    func testStopWhileARestartWaitsCancelsItAndSuppressesItsApp() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(policy.handle(.manualStop(at: t(11))), [])
        XCTAssertNil(policy.state.pendingRestart)
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(20))), [])
    }

    func testDiscardWhileAManualRestartWaitsCancelsIt() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(5)))

        XCTAssertEqual(policy.handle(.discardCurrent(at: t(6))), [])
        XCTAssertNil(policy.state.pendingRestart)
        XCTAssertEqual(policy.state.suppressedBundleIDs, [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(10))), [])
        XCTAssertNil(policy.state.active)
    }

    func testSuppressionEndsWhenTheAppLetsGoEvenWhileAnotherAppIsRecorded() {
        var policy = makePolicy(state: RecordingPolicyState(suppressedBundleIDs: [zoom.bundleIdentifier]))
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom, chrome], at: t(0))),
            [.startCapture(meetingID: id(2), trigger: .microphone(chrome), seriesID: id(1), part: 1)]
        )

        XCTAssertEqual(policy.handle(.tick(micUsers: [chrome], at: t(1))), [])
        XCTAssertEqual(policy.state.suppressedBundleIDs, [])
    }

    // MARK: Pause

    func testPauseStopsAMicRecordingAndItsAppStaysSuppressedAfterResuming() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(
            policy.handle(.setPaused(true, at: t(5))),
            [.stopCapture(meetingID: id(2), reason: .paused)]
        )
        XCTAssertTrue(policy.state.isPaused)
        XCTAssertNil(policy.state.active)
        XCTAssertEqual(policy.state.suppressedBundleIDs, [zoom.bundleIdentifier])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom, chrome], at: t(6))), [])

        XCTAssertEqual(policy.handle(.setPaused(false, at: t(7))), [])
        XCTAssertFalse(policy.state.isPaused)
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(8))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom, chrome], at: t(9))),
            [.startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1)]
        )
    }

    func testNothingStartsFromTheMicWhilePaused() {
        var policy = makePolicy()

        XCTAssertEqual(policy.handle(.setPaused(true, at: t(0))), [])
        XCTAssertEqual(policy.handle(.setPaused(true, at: t(1))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(2))), [])
        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(600))), [])
        XCTAssertEqual(policy.handle(.setPaused(false, at: t(601))), [])

        // Zoom was never recorded, so resuming picks it up.
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(602))),
            [.startCapture(meetingID: id(2), trigger: .microphone(zoom), seriesID: id(1), part: 1)]
        )
    }

    func testPauseLeavesAManualRecordingRunningThroughFailures() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))

        XCTAssertEqual(policy.handle(.setPaused(true, at: t(1))), [])
        XCTAssertEqual(policy.state.active?.meetingID, id(2))
        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(100))), [])

        XCTAssertEqual(
            policy.handle(.captureFailed(meetingID: id(2), at: t(101))),
            [.stopCapture(meetingID: id(2), reason: .captureFailed)]
        )
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [], at: t(103))),
            [.startCapture(meetingID: id(3), trigger: .manual, seriesID: id(1), part: 2)]
        )
        XCTAssertEqual(
            policy.handle(.manualStop(at: t(200))),
            [.stopCapture(meetingID: id(3), reason: .userStopped)]
        )
    }

    func testPauseCancelsAMicRestartButNotAManualOne() {
        var mic = makePolicy()
        mic.handle(.tick(micUsers: [zoom], at: t(0)))
        mic.handle(.captureFailed(meetingID: id(2), at: t(1)))

        XCTAssertEqual(mic.handle(.setPaused(true, at: t(2))), [])
        XCTAssertNil(mic.state.pendingRestart)
        XCTAssertEqual(mic.state.suppressedBundleIDs, [zoom.bundleIdentifier])

        var manual = RecordingPolicy(makeID: SequentialIDs().next)
        manual.handle(.manualStart(at: t(0)))
        manual.handle(.captureFailed(meetingID: id(2), at: t(1)))

        XCTAssertEqual(manual.handle(.setPaused(true, at: t(2))), [])
        XCTAssertEqual(manual.state.pendingRestart?.trigger, .manual)
        XCTAssertEqual(
            manual.handle(.tick(micUsers: [], at: t(3))),
            [.startCapture(meetingID: id(3), trigger: .manual, seriesID: id(1), part: 2)]
        )
    }

    // MARK: Capture events

    func testCaptureStartedMarksOnlyTheActivePartAsCapturing() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))

        XCTAssertEqual(policy.handle(.captureStarted(meetingID: UUID(), at: t(1))), [])
        XCTAssertEqual(policy.state.active?.isCapturing, false)
        XCTAssertEqual(policy.handle(.captureStarted(meetingID: id(2), at: t(1))), [])
        XCTAssertEqual(policy.state.active?.isCapturing, true)
    }

    func testCaptureFailureStopsThePartAndRestartsTheSeriesAfterTheDelay() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureStarted(meetingID: id(2), at: t(0)))

        XCTAssertEqual(
            policy.handle(.captureFailed(meetingID: id(2), at: t(10))),
            [.stopCapture(meetingID: id(2), reason: .captureFailed)]
        )
        XCTAssertNil(policy.state.active)
        XCTAssertEqual(policy.state.pendingRestart, PendingRestart(
            trigger: .microphone(zoom),
            seriesID: id(1),
            nextPart: 2,
            notBefore: t(12),
            consecutiveFailures: 1
        ))

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(11))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(12))),
            [.startCapture(meetingID: id(3), trigger: .microphone(zoom), seriesID: id(1), part: 2)]
        )
        XCTAssertNil(policy.state.pendingRestart)
        XCTAssertEqual(policy.state.active?.part, 2)
        XCTAssertEqual(policy.state.active?.isCapturing, false)
        XCTAssertEqual(policy.state.active?.consecutiveFailures, 1)
    }

    func testAMicRestartIsDroppedIfTheAppHasLetGoByThen() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(12))), [])
        XCTAssertNil(policy.state.pendingRestart)
        XCTAssertNil(policy.state.active)
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(13))),
            [.startCapture(meetingID: id(4), trigger: .microphone(zoom), seriesID: id(3), part: 1)]
        )
    }

    func testADroppedRestartLetsAnotherAppStartOnTheSameTick() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [chrome], at: t(12))),
            [.startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1)]
        )
    }

    func testAManualRestartDoesNotNeedTheMic() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(11))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [], at: t(12))),
            [.startCapture(meetingID: id(3), trigger: .manual, seriesID: id(1), part: 2)]
        )
    }

    func testAnUnrelatedAppDoesNotWaitForAnotherAppsRestart() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [chrome], at: t(11))),
            [.startCapture(meetingID: id(4), trigger: .microphone(chrome), seriesID: id(3), part: 1)]
        )
        XCTAssertNil(policy.state.pendingRestart)
    }

    func testTheAppBeingRestartedKeepsItsTurnWhileItStillHoldsTheMic() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom, chrome], at: t(11))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [chrome, zoom], at: t(12))),
            [.startCapture(meetingID: id(3), trigger: .microphone(zoom), seriesID: id(1), part: 2)]
        )
    }

    func testAManualRestartKeepsMicAppsWaiting() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: t(11))), [])
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [zoom], at: t(12))),
            [.startCapture(meetingID: id(3), trigger: .manual, seriesID: id(1), part: 2)]
        )
    }

    func testRecordNowWhileARestartWaitsStartsAFreshManualSeries() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(10)))

        XCTAssertEqual(
            policy.handle(.manualStart(at: t(11))),
            [.startCapture(meetingID: id(4), trigger: .manual, seriesID: id(3), part: 1)]
        )
        XCTAssertNil(policy.state.pendingRestart)
    }

    func testFailuresBackOffAndTheLastDelayRepeats() throws {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        var clock = t(0)

        for (index, delay) in [2.0, 5, 15, 30, 60, 60, 60].enumerated() {
            let failure = index + 1
            let meetingID = try XCTUnwrap(policy.state.active?.meetingID)
            clock = clock.addingTimeInterval(1)
            XCTAssertEqual(
                policy.handle(.captureFailed(meetingID: meetingID, at: clock)),
                [.stopCapture(meetingID: meetingID, reason: .captureFailed)],
                "failure \(failure)"
            )
            XCTAssertEqual(policy.state.pendingRestart?.notBefore, clock.addingTimeInterval(delay), "failure \(failure)")
            XCTAssertEqual(policy.state.pendingRestart?.consecutiveFailures, failure)
            XCTAssertEqual(policy.state.pendingRestart?.nextPart, failure + 1)

            XCTAssertEqual(policy.handle(.tick(micUsers: [zoom], at: clock.addingTimeInterval(delay - 1))), [])
            clock = clock.addingTimeInterval(delay)
            XCTAssertEqual(
                policy.handle(.tick(micUsers: [zoom], at: clock)),
                [.startCapture(meetingID: id(failure + 2), trigger: .microphone(zoom), seriesID: id(1), part: failure + 1)]
            )
        }
    }

    func testAPartThatRecordsForAMinuteResetsTheBackoff() {
        var policy = partAfterTwoFailures()
        XCTAssertEqual(policy.state.active?.consecutiveFailures, 2)
        policy.handle(.captureStarted(meetingID: id(4), at: t(9)))

        policy.handle(.tick(micUsers: [zoom], at: t(68)))
        XCTAssertEqual(policy.state.active?.consecutiveFailures, 2)
        policy.handle(.tick(micUsers: [zoom], at: t(69)))
        XCTAssertEqual(policy.state.active?.consecutiveFailures, 0)

        policy.handle(.captureFailed(meetingID: id(4), at: t(100)))
        XCTAssertEqual(policy.state.pendingRestart?.notBefore, t(102))
        XCTAssertEqual(policy.state.pendingRestart?.consecutiveFailures, 1)
    }

    func testAPartThatFailsBeforeAMinuteKeepsTheBackoffGoing() {
        var policy = partAfterTwoFailures()
        policy.handle(.captureStarted(meetingID: id(4), at: t(9)))
        policy.handle(.tick(micUsers: [zoom], at: t(67)))

        policy.handle(.captureFailed(meetingID: id(4), at: t(68)))
        XCTAssertEqual(policy.state.pendingRestart?.notBefore, t(83))
        XCTAssertEqual(policy.state.pendingRestart?.consecutiveFailures, 3)
    }

    func testAPartThatNeverStartedCapturingDoesNotResetTheBackoff() {
        var policy = partAfterTwoFailures()
        policy.handle(.tick(micUsers: [zoom], at: t(300)))
        XCTAssertEqual(policy.state.active?.consecutiveFailures, 2)

        policy.handle(.captureFailed(meetingID: id(4), at: t(300)))
        XCTAssertEqual(policy.state.pendingRestart?.notBefore, t(315))
        XCTAssertEqual(policy.state.pendingRestart?.consecutiveFailures, 3)
    }

    func testAStableManualPartResetsTheBackoffEvenWithoutATick() {
        var policy = makePolicy()
        policy.handle(.manualStart(at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(1)))
        policy.handle(.tick(micUsers: [], at: t(3)))
        policy.handle(.captureStarted(meetingID: id(3), at: t(3)))

        policy.handle(.captureFailed(meetingID: id(3), at: t(63)))
        XCTAssertEqual(policy.state.pendingRestart?.notBefore, t(65))
        XCTAssertEqual(policy.state.pendingRestart?.consecutiveFailures, 1)
    }

    func testStaleCaptureEventsChangeNothing() {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(1)))
        let waiting = policy.state

        XCTAssertEqual(policy.handle(.captureFailed(meetingID: id(2), at: t(2))), [])
        XCTAssertEqual(policy.handle(.captureStarted(meetingID: id(2), at: t(2))), [])
        XCTAssertEqual(policy.state, waiting)

        policy.handle(.tick(micUsers: [zoom], at: t(3)))
        let recording = policy.state
        XCTAssertEqual(recording.active?.meetingID, id(3))

        XCTAssertEqual(policy.handle(.captureFailed(meetingID: id(2), at: t(4))), [])
        XCTAssertEqual(policy.handle(.captureStarted(meetingID: id(2), at: t(4))), [])
        XCTAssertEqual(policy.handle(.captureFailed(meetingID: UUID(), at: t(4))), [])
        XCTAssertEqual(policy.state, recording)

        policy.handle(.manualStop(at: t(5)))
        let stopped = policy.state
        XCTAssertEqual(policy.handle(.captureFailed(meetingID: id(3), at: t(6))), [])
        XCTAssertEqual(policy.handle(.captureStarted(meetingID: id(3), at: t(6))), [])
        XCTAssertEqual(policy.state, stopped)
    }

    // MARK: Restore after a relaunch

    func testRestoreTurnsTheActivePartIntoARestartThatIsDueNow() {
        let persisted = RecordingPolicyState(
            active: ActiveRecording(
                meetingID: id(50),
                seriesID: id(40),
                part: 3,
                trigger: .microphone(zoom),
                startedAt: t(0),
                lastHeldAt: t(100),
                isCapturing: true,
                consecutiveFailures: 2
            ),
            suppressedBundleIDs: [slack.bundleIdentifier]
        )

        var policy = RecordingPolicy(restoringPersistedState: persisted, now: t(500), makeID: ids.next)
        XCTAssertNil(policy.state.active)
        XCTAssertEqual(policy.state.pendingRestart, PendingRestart(
            trigger: .microphone(zoom),
            seriesID: id(40),
            nextPart: 4,
            notBefore: t(500),
            consecutiveFailures: 0
        ))
        XCTAssertEqual(policy.state.suppressedBundleIDs, [slack.bundleIdentifier])

        XCTAssertEqual(
            policy.handle(.tick(micUsers: [slack, zoom], at: t(501))),
            [.startCapture(meetingID: id(1), trigger: .microphone(zoom), seriesID: id(40), part: 4)]
        )
    }

    func testARestoredMicRestartIsDroppedIfTheAppIsGone() {
        let persisted = RecordingPolicyState(active: ActiveRecording(
            meetingID: id(50), seriesID: id(40), part: 1, trigger: .microphone(zoom),
            startedAt: t(0), lastHeldAt: t(0), isCapturing: true
        ))
        var policy = RecordingPolicy(restoringPersistedState: persisted, now: t(500), makeID: ids.next)

        XCTAssertEqual(policy.handle(.tick(micUsers: [], at: t(501))), [])
        XCTAssertEqual(policy.state, RecordingPolicyState())
    }

    func testARestoredManualRecordingCarriesOnWithoutTheMic() {
        let persisted = RecordingPolicyState(
            isPaused: true,
            active: ActiveRecording(
                meetingID: id(50), seriesID: id(40), part: 1, trigger: .manual,
                startedAt: t(0), lastHeldAt: t(0), isCapturing: true
            )
        )
        var policy = RecordingPolicy(restoringPersistedState: persisted, now: t(500), makeID: ids.next)

        XCTAssertTrue(policy.state.isPaused)
        XCTAssertEqual(
            policy.handle(.tick(micUsers: [], at: t(501))),
            [.startCapture(meetingID: id(1), trigger: .manual, seriesID: id(40), part: 2)]
        )
    }

    func testRestoreLeavesAWaitingRestartPauseAndSuppressionAlone() {
        let persisted = RecordingPolicyState(
            isPaused: true,
            pendingRestart: PendingRestart(trigger: .manual, seriesID: id(40), nextPart: 2, notBefore: t(30), consecutiveFailures: 3),
            suppressedBundleIDs: [zoom.bundleIdentifier, chrome.bundleIdentifier]
        )

        let policy = RecordingPolicy(restoringPersistedState: persisted, now: t(500), makeID: ids.next)
        XCTAssertEqual(policy.state, persisted)
    }

    func testCaptureEventsFromBeforeARelaunchAreIgnored() {
        let persisted = RecordingPolicyState(active: ActiveRecording(
            meetingID: id(50), seriesID: id(40), part: 1, trigger: .manual,
            startedAt: t(0), lastHeldAt: t(0), isCapturing: true
        ))
        var policy = RecordingPolicy(restoringPersistedState: persisted, now: t(500), makeID: ids.next)
        let restored = policy.state

        XCTAssertEqual(policy.handle(.captureFailed(meetingID: id(50), at: t(500))), [])
        XCTAssertEqual(policy.handle(.captureStarted(meetingID: id(50), at: t(500))), [])
        XCTAssertEqual(policy.state, restored)
    }

    // MARK: Persistence

    func testNewStateIsSchemaTwoUnpausedAndIdle() {
        let state = RecordingPolicyState()

        XCTAssertEqual(state.schemaVersion, 2)
        XCTAssertFalse(state.isPaused)
        XCTAssertNil(state.active)
        XCTAssertNil(state.pendingRestart)
        XCTAssertEqual(state.suppressedBundleIDs, [])
    }

    func testStateRoundTripsThroughTheModelCodec() throws {
        let recording = RecordingPolicyState(
            isPaused: true,
            active: ActiveRecording(
                meetingID: id(2), seriesID: id(1), part: 3, trigger: .microphone(zoom),
                startedAt: t(1), lastHeldAt: t(42), isCapturing: true, consecutiveFailures: 2
            ),
            suppressedBundleIDs: [chrome.bundleIdentifier]
        )
        let waiting = RecordingPolicyState(
            pendingRestart: PendingRestart(trigger: .manual, seriesID: id(1), nextPart: 4, notBefore: t(60), consecutiveFailures: 3)
        )

        for state in [recording, waiting, RecordingPolicyState()] {
            let data = try ModelCodec.encoder.encode(state)
            XCTAssertEqual(try ModelCodec.decoder.decode(RecordingPolicyState.self, from: data), state)
        }
    }

    func testTriggersAreStoredAsAKindPlusTheApp() throws {
        XCTAssertEqual(
            String(decoding: try ModelCodec.encoder.encode(RecordingTrigger.microphone(zoom)), as: UTF8.self),
            #"{"app":{"bundleIdentifier":"us.zoom.xos","displayName":"zoom.us"},"kind":"microphone"}"#
        )
        XCTAssertEqual(
            String(decoding: try ModelCodec.encoder.encode(RecordingTrigger.manual), as: UTF8.self),
            #"{"kind":"manual"}"#
        )
    }

    func testStopReasonsAreStoredInSnakeCase() {
        XCTAssertEqual(
            [RecordingStopReason.micReleased, .switchedApp, .userStopped, .discarded, .paused, .captureFailed, .appQuit]
                .map(\.rawValue),
            ["mic_released", "switched_app", "user_stopped", "discarded", "paused", "capture_failed", "app_quit"]
        )
    }

    // MARK: Keeping

    func testKeepPolicyDecisions() {
        let policy = KeepPolicy()
        let mic = RecordingTrigger.microphone(zoom)
        let cases: [(name: String, trigger: RecordingTrigger, reason: RecordingStopReason, part: Int,
                     duration: TimeInterval, incoming: TimeInterval, microphone: TimeInterval, expected: KeepDecision)] = [
            ("discarded call", mic, .discarded, 1, 3600, 900, 900, .discard(reason: "you discarded it")),
            ("discarded manual", .manual, .discarded, 1, 3600, 900, 900, .discard(reason: "you discarded it")),
            ("discarded later part", mic, .discarded, 2, 3600, 900, 900, .discard(reason: "you discarded it")),
            ("empty manual", .manual, .userStopped, 1, 0.5, 0, 0, .discard(reason: "nothing recorded")),
            ("empty restart", mic, .captureFailed, 2, 0.9, 0, 0, .discard(reason: "nothing recorded")),
            ("empty quit", mic, .appQuit, 1, 0, 0, 0, .discard(reason: "nothing recorded")),
            ("silent second of manual", .manual, .userStopped, 1, 1, 0, 0, .keep),
            ("short manual", .manual, .userStopped, 1, 5, 0, 1, .keep),
            ("long silent manual", .manual, .userStopped, 1, 3600, 0, 0, .keep),
            ("manual later part", .manual, .captureFailed, 3, 30, 0, 2, .keep),
            ("later part with any sound", mic, .micReleased, 2, 10, 0, 0.5, .keep),
            ("failed first part with sound", mic, .captureFailed, 1, 10, 0.1, 0, .keep),
            ("quit first part with sound", mic, .appQuit, 1, 10, 0, 2, .keep),
            ("silent later part", mic, .micReleased, 3, 600, 0, 0, .discard(reason: "nothing recorded")),
            ("silent failed part", mic, .captureFailed, 1, 600, 0, 0, .discard(reason: "nothing recorded")),
            ("call at both bars", mic, .micReleased, 1, 60, 5, 30, .keep),
            ("long call", mic, .switchedApp, 1, 3600, 900, 900, .keep),
            ("call stopped by the user", mic, .userStopped, 1, 120, 10, 10, .keep),
            ("call cut by pause", mic, .paused, 1, 120, 10, 10, .keep),
            ("just under a minute", mic, .micReleased, 1, 59.9, 30, 30, .discard(reason: "under a minute")),
            ("short and one-sided", mic, .userStopped, 1, 30, 0, 20, .discard(reason: "under a minute")),
            ("short pause", mic, .paused, 1, 20, 10, 10, .discard(reason: "under a minute")),
            ("voice memo", mic, .micReleased, 1, 600, 0, 300, .discard(reason: "nobody else spoke")),
            ("just under the incoming bar", mic, .micReleased, 1, 600, 4.9, 300, .discard(reason: "nobody else spoke")),
        ]

        for item in cases {
            XCTAssertEqual(
                policy.decide(
                    trigger: item.trigger,
                    stopReason: item.reason,
                    part: item.part,
                    duration: item.duration,
                    incomingActivity: item.incoming,
                    microphoneActivity: item.microphone
                ),
                item.expected,
                item.name
            )
        }
    }

    func testKeepPolicyReasonsFollowItsThresholds() {
        let mic = RecordingTrigger.microphone(zoom)
        let strict = KeepPolicy(minimumDuration: 120, minimumIncomingActivity: 30)

        XCTAssertEqual(
            strict.decide(trigger: mic, stopReason: .micReleased, part: 1, duration: 90, incomingActivity: 60, microphoneActivity: 60),
            .discard(reason: "under 2 minutes")
        )
        XCTAssertEqual(
            strict.decide(trigger: mic, stopReason: .micReleased, part: 1, duration: 150, incomingActivity: 20, microphoneActivity: 60),
            .discard(reason: "nobody else spoke")
        )
        XCTAssertEqual(
            KeepPolicy(minimumDuration: 45).decide(trigger: mic, stopReason: .micReleased, part: 1, duration: 30, incomingActivity: 20, microphoneActivity: 20),
            .discard(reason: "under 45 seconds")
        )
    }

    // MARK: Helpers

    private func makePolicy(state: RecordingPolicyState = .init()) -> RecordingPolicy {
        RecordingPolicy(state: state, makeID: ids.next)
    }

    /// Zoom's series, now on part 3 (meeting 4) after failing at 1 and 4
    /// seconds, so the next failure would wait 15 seconds.
    private func partAfterTwoFailures() -> RecordingPolicy {
        var policy = makePolicy()
        policy.handle(.tick(micUsers: [zoom], at: t(0)))
        policy.handle(.captureFailed(meetingID: id(2), at: t(1)))
        policy.handle(.tick(micUsers: [zoom], at: t(3)))
        policy.handle(.captureFailed(meetingID: id(3), at: t(4)))
        policy.handle(.tick(micUsers: [zoom], at: t(9)))
        XCTAssertEqual(policy.state.active?.meetingID, id(4))
        XCTAssertEqual(policy.state.active?.part, 3)
        return policy
    }

    private func t(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    private func id(_ number: Int) -> UUID {
        SequentialIDs.id(number)
    }
}

/// Hands out 00000000-0000-0000-0000-000000000001, then ...0002 and so on.
private final class SequentialIDs: Sendable {
    private let count = Mutex(0)

    func next() -> UUID {
        Self.id(count.withLock { value in
            value += 1
            return value
        })
    }

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}
