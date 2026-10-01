import Foundation
import XCTest
@testable import MeetingArchiveCore

final class CaptureStateMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPositiveMeetingStartsExactlyOnceAndStopsAtFirstOffSignal() throws {
        let session = meetingSession(id: "meet-1")
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.handle(.cameraOn(session, at: now)), [.startCapture(session)])
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(1))), [])

        let meetingID = UUID()
        XCTAssertEqual(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now.addingTimeInterval(2))),
            []
        )
        XCTAssertEqual(
            machine.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(3))),
            [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
        )
        XCTAssertEqual(machine.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(4))), [])
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(5))), [])
    }

    func testUnknownAndPreviewSessionsAreExcluded() {
        var machine = CaptureStateMachine()
        let unknown = MeetingSessionDescriptor(
            id: "unknown",
            sourceApplication: .init(bundleIdentifier: "com.example.unknown", displayName: "Unknown", kind: .other),
            surface: .init(id: "window-1", title: nil, kind: .unknown),
            attribution: .unknown
        )
        let preview = MeetingSessionDescriptor(
            id: "preview",
            sourceApplication: .init(bundleIdentifier: "com.apple.PhotoBooth", displayName: "Preview", kind: .cameraPreview),
            surface: .init(id: "window-2", title: nil, kind: .cameraPreview),
            attribution: .positive
        )

        XCTAssertEqual(machine.handle(.cameraOn(unknown, at: now)), [])
        XCTAssertEqual(machine.handle(.cameraOn(preview, at: now)), [])
        XCTAssertNil(machine.state.currentSession)
    }

    func testSkipSurvivesPersistenceAndSuppressesRestOfSameSession() throws {
        let session = meetingSession(id: "meet-skip")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))

        XCTAssertEqual(
            machine.handle(.skipCurrent(at: now.addingTimeInterval(1))),
            [
                .stopCapture(meetingID: meetingID, reason: .skipped),
                .sessionSkipped(sessionID: session.id),
            ]
        )

        let encoded = try ModelCodec.encoder.encode(machine.state)
        let restoredState = try ModelCodec.decoder.decode(RecorderState.self, from: encoded)
        var restored = CaptureStateMachine(state: restoredState)

        XCTAssertEqual(restored.handle(.cameraOn(session, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(restored.handle(.applicationObserved(bundleIdentifier: session.sourceApplication.bundleIdentifier, at: now.addingTimeInterval(3))), [])
        XCTAssertEqual(restored.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(4))), [])

        let next = meetingSession(id: "meet-next")
        XCTAssertEqual(restored.handle(.cameraOn(next, at: now.addingTimeInterval(5))), [.startCapture(next)])
    }

    func testPersistentPauseStopsCurrentCaptureAndResumeDoesNotRestartIt() throws {
        let session = meetingSession(id: "meet-pause")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))

        XCTAssertEqual(
            machine.handle(.setPaused(true, at: now.addingTimeInterval(1))),
            [.stopCapture(meetingID: meetingID, reason: .paused)]
        )
        XCTAssertTrue(machine.state.isPaused)

        let data = try ModelCodec.encoder.encode(machine.state)
        var restored = CaptureStateMachine(state: try ModelCodec.decoder.decode(RecorderState.self, from: data))
        XCTAssertEqual(restored.handle(.setPaused(false, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(restored.handle(.applicationObserved(bundleIdentifier: session.sourceApplication.bundleIdentifier, at: now.addingTimeInterval(3))), [])
        XCTAssertEqual(restored.handle(.cameraOn(session, at: now.addingTimeInterval(4))), [])
    }

    func testRestartDoesNotTreatPersistedWriterAsAliveOrRestartOpenSession() {
        let session = meetingSession(id: "meet-crash")
        let persisted = RecorderState(
            currentSession: ActiveMeetingSession(
                descriptor: session,
                phase: .recording,
                firstObservedAt: now,
                meetingID: UUID()
            )
        )

        var restored = CaptureStateMachine(restoringPersistedState: persisted)
        XCTAssertEqual(restored.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(restored.handle(.applicationObserved(bundleIdentifier: "com.google.Chrome", at: now)), [])
        XCTAssertEqual(restored.handle(.cameraOn(session, at: now)), [])
    }

    func testCaptureErrorBeforeStartCompletesSuppressesSessionAndStopsLateCallback() {
        let session = meetingSession(id: "meet-start-error")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))

        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(1))),
            []
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now.addingTimeInterval(2))),
            [.stopCapture(meetingID: meetingID, reason: .interrupted)]
        )
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(3))), [])
    }

    func testCaptureErrorAfterRecordingStopsPartialAndIsIdempotent() {
        let session = meetingSession(id: "meet-recording-error")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))

        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(1))),
            [.stopCapture(meetingID: meetingID, reason: .interrupted)]
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(2))),
            []
        )
    }

    func testCaptureErrorForUnrelatedSessionIsIgnored() {
        let active = meetingSession(id: "active")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(active, at: now))

        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: "unrelated", at: now.addingTimeInterval(1))),
            []
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .startRequested)
    }

    func testConfirmedOffAfterInterruptionAllowsNewSessionIDToStart() {
        let interrupted = meetingSession(id: "interrupted")
        let next = meetingSession(id: "after-off")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(interrupted, at: now))
        _ = machine.handle(.captureInterrupted(sessionID: interrupted.id, at: now.addingTimeInterval(1)))

        XCTAssertEqual(machine.handle(.cameraOff(sessionID: interrupted.id, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(machine.handle(.cameraOn(next, at: now.addingTimeInterval(3))), [.startCapture(next)])
    }

    func testOverlappingSessionDoesNotReplaceActiveMeeting() {
        let first = meetingSession(id: "first")
        let second = meetingSession(id: "second")
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.handle(.cameraOn(first, at: now)), [.startCapture(first)])
        XCTAssertEqual(machine.handle(.cameraOn(second, at: now)), [])
        XCTAssertEqual(machine.state.currentSession?.descriptor.id, first.id)
    }

    func testFailedStartRetriesTheSameSessionWithANewCaptureAfterTenSeconds() {
        let session = meetingSession(id: "meet-start-failed")
        let failedID = UUID()
        let retryID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: failedID, at: now))

        // The writer opened, but capture never produced both sources.
        let failedAt = now.addingTimeInterval(15)
        let retryAt = failedAt.addingTimeInterval(10)
        XCTAssertEqual(
            machine.handle(.captureStartFailed(sessionID: session.id, at: failedAt)),
            [
                .stopCapture(meetingID: failedID, reason: .startFailed),
                .retryScheduled(sessionID: session.id, at: retryAt),
            ]
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .retryScheduled(at: retryAt))
        XCTAssertEqual(machine.state.currentSession?.failedStarts, 1)

        XCTAssertEqual(machine.handle(.cameraOn(session, at: retryAt.addingTimeInterval(-1))), [])
        XCTAssertEqual(machine.handle(.cameraOn(session, at: retryAt)), [.startCapture(session)])
        XCTAssertEqual(machine.state.currentSession?.phase, .startRequested)
        XCTAssertNil(machine.state.currentSession?.meetingID)

        XCTAssertEqual(machine.handle(.captureStarted(sessionID: session.id, meetingID: retryID, at: retryAt)), [])
        XCTAssertEqual(machine.state.currentSession?.phase, .recording)
        XCTAssertEqual(machine.state.currentSession?.meetingID, retryID)
        XCTAssertFalse(machine.state.completedSessionIDs.contains(session.id))
        XCTAssertEqual(
            machine.handle(.cameraOff(sessionID: session.id, at: retryAt.addingTimeInterval(60))),
            [.stopCapture(meetingID: retryID, reason: .cameraOff)]
        )
    }

    func testStartThatFailsBeforeItsWriterRegistersSchedulesARetryWithoutAStop() {
        let session = meetingSession(id: "meet-open-failed")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))

        XCTAssertEqual(
            machine.handle(.captureStartFailed(sessionID: session.id, at: now)),
            [.retryScheduled(sessionID: session.id, at: now.addingTimeInterval(10))]
        )
    }

    func testRetriesBackOffThenGiveUpOnceUntilTheCameraSessionEnds() {
        let session = meetingSession(id: "meet-stubborn")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        var clock = now

        for (attempt, delay) in [10.0, 30, 60].enumerated() {
            let meetingID = UUID()
            _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: clock))
            clock = clock.addingTimeInterval(15)
            XCTAssertEqual(
                machine.handle(.captureStartFailed(sessionID: session.id, at: clock)),
                [
                    .stopCapture(meetingID: meetingID, reason: .startFailed),
                    .retryScheduled(sessionID: session.id, at: clock.addingTimeInterval(delay)),
                ],
                "failed start \(attempt + 1)"
            )
            clock = clock.addingTimeInterval(delay)
            XCTAssertEqual(machine.handle(.cameraOn(session, at: clock)), [.startCapture(session)])
        }

        let lastID = UUID()
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: lastID, at: clock))
        clock = clock.addingTimeInterval(15)
        XCTAssertEqual(
            machine.handle(.captureStartFailed(sessionID: session.id, at: clock)),
            [.stopCapture(meetingID: lastID, reason: .startFailed), .retriesExhausted(sessionID: session.id)]
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(machine.state.currentSession?.failedStarts, 4)
        XCTAssertEqual(machine.handle(.cameraOn(session, at: clock.addingTimeInterval(3600))), [])
        XCTAssertEqual(machine.handle(.captureStartFailed(sessionID: session.id, at: clock.addingTimeInterval(3601))), [])

        // The next camera session gets its own tries.
        XCTAssertEqual(machine.handle(.cameraOff(sessionID: session.id, at: clock.addingTimeInterval(3602))), [])
        let next = meetingSession(id: "meet-after-stubborn")
        XCTAssertEqual(machine.handle(.cameraOn(next, at: clock.addingTimeInterval(3603))), [.startCapture(next)])
        XCTAssertEqual(machine.state.currentSession?.failedStarts, 0)
    }

    func testCameraOffWhileARetryWaitsCompletesTheSessionWithoutRetrying() {
        let session = meetingSession(id: "meet-left")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStartFailed(sessionID: session.id, at: now))

        XCTAssertEqual(machine.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(5))), [])
        XCTAssertTrue(machine.state.completedSessionIDs.contains(session.id))
        XCTAssertNil(machine.state.currentSession)
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(60))), [])
    }

    func testSkipOrPauseWhileARetryWaitsCancelsIt() {
        let skipped = meetingSession(id: "meet-skip-retry")
        var skipping = CaptureStateMachine()
        _ = skipping.handle(.cameraOn(skipped, at: now))
        _ = skipping.handle(.captureStartFailed(sessionID: skipped.id, at: now))

        XCTAssertEqual(skipping.handle(.skipCurrent(at: now.addingTimeInterval(1))), [.sessionSkipped(sessionID: skipped.id)])
        XCTAssertEqual(skipping.handle(.cameraOn(skipped, at: now.addingTimeInterval(60))), [])

        let paused = meetingSession(id: "meet-pause-retry")
        var pausing = CaptureStateMachine()
        _ = pausing.handle(.cameraOn(paused, at: now))
        _ = pausing.handle(.captureStartFailed(sessionID: paused.id, at: now))

        XCTAssertEqual(pausing.handle(.setPaused(true, at: now.addingTimeInterval(1))), [])
        XCTAssertEqual(pausing.state.currentSession?.phase, .suppressed(.paused))
        XCTAssertEqual(pausing.handle(.setPaused(false, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(pausing.handle(.cameraOn(paused, at: now.addingTimeInterval(60))), [])
    }

    func testLateWriterFromAFailedStartIsStoppedWhileTheRetryWaits() {
        let session = meetingSession(id: "meet-late-writer")
        let lateID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStartFailed(sessionID: session.id, at: now))

        XCTAssertEqual(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: lateID, at: now.addingTimeInterval(1))),
            [.stopCapture(meetingID: lateID, reason: .startFailed)]
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .retryScheduled(at: now.addingTimeInterval(10)))

        // Nothing is running while the retry waits, so a stray report does
        // not use up a try.
        XCTAssertEqual(machine.handle(.captureStartFailed(sessionID: session.id, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(machine.state.currentSession?.failedStarts, 1)
    }

    func testFailedStartAfterSkipOrForAnotherSessionIsIgnored() {
        let session = meetingSession(id: "meet-skip-then-fail")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.skipCurrent(at: now))

        XCTAssertEqual(machine.handle(.captureStartFailed(sessionID: session.id, at: now)), [])
        XCTAssertEqual(machine.state.currentSession?.phase, .suppressed(.skipped))
        XCTAssertEqual(machine.handle(.captureStartFailed(sessionID: "unrelated", at: now)), [])
        XCTAssertEqual(machine.state.currentSession?.failedStarts, 0)
    }

    func testInterruptedRecordingIsNotRetried() {
        let session = meetingSession(id: "meet-interrupted-recording")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))
        _ = machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(600)))

        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(3600))), [])
        XCTAssertEqual(machine.state.currentSession?.failedStarts, 0)
    }

    func testPendingRetrySurvivesARestartWithItsFailedStartCount() throws {
        let session = meetingSession(id: "meet-retry-restart")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStartFailed(sessionID: session.id, at: now))

        let data = try ModelCodec.encoder.encode(machine.state)
        var restored = CaptureStateMachine(
            restoringPersistedState: try ModelCodec.decoder.decode(RecorderState.self, from: data)
        )

        let retryAt = now.addingTimeInterval(10)
        XCTAssertEqual(restored.state.currentSession?.phase, .retryScheduled(at: retryAt))
        XCTAssertEqual(restored.state.currentSession?.failedStarts, 1)
        XCTAssertEqual(restored.handle(.cameraOn(session, at: retryAt)), [.startCapture(session)])
        // The count carries on, so the next failure waits 30 seconds.
        XCTAssertEqual(
            restored.handle(.captureStartFailed(sessionID: session.id, at: retryAt)),
            [.retryScheduled(sessionID: session.id, at: retryAt.addingTimeInterval(30))]
        )
    }

    func testRestartDuringARetriedStartSuppressesTheSessionAndKeepsItsCount() {
        let session = meetingSession(id: "meet-retry-crash")
        let persisted = RecorderState(currentSession: ActiveMeetingSession(
            descriptor: session,
            phase: .startRequested,
            firstObservedAt: now,
            meetingID: nil,
            failedStarts: 2
        ))

        var restored = CaptureStateMachine(restoringPersistedState: persisted)
        XCTAssertEqual(restored.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(restored.state.currentSession?.failedStarts, 2)
        XCTAssertEqual(restored.handle(.cameraOn(session, at: now.addingTimeInterval(3600))), [])
    }

    func testPendingRetryIsStoredSoABuildWithoutRetriesReadsItAsInterrupted() throws {
        let retryAt = now.addingTimeInterval(10)
        let encoded = try ModelCodec.encoder.encode(ActiveSessionPhase.retryScheduled(at: retryAt))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])

        XCTAssertEqual(fields["status"], "suppressed")
        XCTAssertEqual(fields["reason"], "interrupted")
        XCTAssertNotNil(fields["retry_at"])
        XCTAssertEqual(try ModelCodec.decoder.decode(ActiveSessionPhase.self, from: encoded), .retryScheduled(at: retryAt))
    }

    func testSessionSavedBeforeRetriesExistedHasNoFailedStarts() throws {
        let saved = Data("""
        {"descriptor":{"attribution":"positive","id":"saved","sourceApplication":{"bundleIdentifier":"us.zoom.xos",\
        "displayName":"zoom.us","kind":"zoom"},"surface":{"id":"cg-window:1","kind":"meeting","title":"Zoom Meeting"}},\
        "firstObservedAt":"2026-09-30T20:59:31.146Z","meetingID":"6F1D3C8A-2B7E-4F10-9A55-0C3E8D2B4A61",\
        "phase":{"reason":"interrupted","status":"suppressed"}}
        """.utf8)

        let session = try ModelCodec.decoder.decode(ActiveMeetingSession.self, from: saved)
        XCTAssertEqual(session.phase, .suppressed(.interrupted))
        XCTAssertEqual(session.failedStarts, 0)
    }

    private func meetingSession(id: String) -> MeetingSessionDescriptor {
        MeetingSessionDescriptor(
            id: id,
            sourceApplication: .init(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome", kind: .googleMeet),
            surface: .init(id: "window-\(id)", title: "Meeting", kind: .meeting),
            attribution: .positive
        )
    }
}
