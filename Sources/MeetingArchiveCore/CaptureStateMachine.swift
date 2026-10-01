import Foundation

public enum CaptureStopReason: String, Codable, Equatable, Sendable {
    case cameraOff = "camera_off"
    case skipped
    case paused
    case interrupted
    /// Capture stopped before it produced both meeting video and microphone
    /// audio, so the recording never really began.
    case startFailed = "start_failed"
}

public enum CaptureEvent: Equatable, Sendable {
    case cameraOn(MeetingSessionDescriptor, at: Date)
    case cameraOff(sessionID: String, at: Date)
    case captureStarted(sessionID: String, meetingID: UUID, at: Date)
    case captureInterrupted(sessionID: String, at: Date)
    /// Capture could not open, or stopped before it produced both meeting
    /// video and microphone audio.
    case captureStartFailed(sessionID: String, at: Date)
    case skipCurrent(at: Date)
    case setPaused(Bool, at: Date)
    case applicationObserved(bundleIdentifier: String, at: Date)
}

public enum CaptureEffect: Equatable, Sendable {
    case startCapture(MeetingSessionDescriptor)
    case stopCapture(meetingID: UUID, reason: CaptureStopReason)
    case sessionSkipped(sessionID: String)
    case retryScheduled(sessionID: String, at: Date)
    /// Every retry failed. The session stays suppressed until its camera
    /// session ends, like any other interruption.
    case retriesExhausted(sessionID: String)
}

/// How long a camera session waits before trying to start capture again
/// after a failed start. A recording that had been running is never retried.
public struct CaptureRetryPolicy: Equatable, Sendable {
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval]) {
        self.delays = delays
    }

    /// Four tries in all, then the session needs attention.
    public static let standard = CaptureRetryPolicy(delays: [10, 30, 60])

    /// The wait after this many failed starts, or nil once none are left.
    public func delay(afterFailedStarts count: Int) -> TimeInterval? {
        guard count >= 1, count <= delays.count else { return nil }
        return delays[count - 1]
    }
}

public struct CaptureStateMachine: Sendable {
    public private(set) var state: RecorderState
    private let retryPolicy: CaptureRetryPolicy

    public init(state: RecorderState = RecorderState(), retryPolicy: CaptureRetryPolicy = .standard) {
        self.state = state
        self.retryPolicy = retryPolicy
    }

    public init(restoringPersistedState state: RecorderState, retryPolicy: CaptureRetryPolicy = .standard) {
        self.state = state.restoredAfterProcessRestart()
        self.retryPolicy = retryPolicy
    }

    @discardableResult
    public mutating func handle(_ event: CaptureEvent) -> [CaptureEffect] {
        switch event {
        case .cameraOn(let descriptor, let date):
            return cameraOn(descriptor, at: date)
        case .cameraOff(let sessionID, _):
            return cameraOff(sessionID: sessionID)
        case .captureStarted(let sessionID, let meetingID, _):
            return captureStarted(sessionID: sessionID, meetingID: meetingID)
        case .captureInterrupted(let sessionID, _):
            return captureInterrupted(sessionID: sessionID)
        case .captureStartFailed(let sessionID, let date):
            return captureStartFailed(sessionID: sessionID, at: date)
        case .skipCurrent:
            return skipCurrent()
        case .setPaused(let paused, _):
            return setPaused(paused)
        case .applicationObserved:
            // Seeing an application stay open is not a camera-session transition.
            return []
        }
    }

    private mutating func cameraOn(_ descriptor: MeetingSessionDescriptor, at date: Date) -> [CaptureEffect] {
        guard descriptor.isEligibleForCapture else { return [] }
        guard !state.completedSessionIDs.contains(descriptor.id) else { return [] }
        if var current = state.currentSession {
            // The same camera session, still on and eligible, gets its retry
            // once it is due. Anything else waits for this session to end.
            guard current.descriptor.id == descriptor.id,
                  case .retryScheduled(let retryAt) = current.phase,
                  date >= retryAt, !state.isPaused else { return [] }
            current.phase = .startRequested
            current.meetingID = nil
            state.currentSession = current
            return [.startCapture(current.descriptor)]
        }

        let phase: ActiveSessionPhase = state.isPaused ? .suppressed(.paused) : .startRequested
        state.currentSession = ActiveMeetingSession(
            descriptor: descriptor,
            phase: phase,
            firstObservedAt: date,
            meetingID: nil
        )
        return state.isPaused ? [] : [.startCapture(descriptor)]
    }

    private mutating func cameraOff(sessionID: String) -> [CaptureEffect] {
        guard let current = state.currentSession, current.descriptor.id == sessionID else { return [] }
        rememberCompleted(sessionID)
        state.currentSession = nil

        guard current.phase == .recording, let meetingID = current.meetingID else { return [] }
        return [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
    }

    private mutating func captureStarted(sessionID: String, meetingID: UUID) -> [CaptureEffect] {
        guard var current = state.currentSession, current.descriptor.id == sessionID else {
            if state.completedSessionIDs.contains(sessionID) {
                return [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
            }
            return []
        }

        switch current.phase {
        case .startRequested:
            current.phase = .recording
            current.meetingID = meetingID
            state.currentSession = current
            return []
        case .retryScheduled:
            // A writer registered after its own start had already failed.
            return [.stopCapture(meetingID: meetingID, reason: .startFailed)]
        case .suppressed(let reason):
            let stopReason: CaptureStopReason = switch reason {
            case .skipped: .skipped
            case .paused: .paused
            case .interrupted: .interrupted
            }
            return [.stopCapture(meetingID: meetingID, reason: stopReason)]
        case .recording:
            return []
        }
    }

    private mutating func captureInterrupted(sessionID: String) -> [CaptureEffect] {
        guard var current = state.currentSession, current.descriptor.id == sessionID else { return [] }

        switch current.phase {
        case .startRequested:
            current.phase = .suppressed(.interrupted)
            state.currentSession = current
            return []
        case .recording:
            current.phase = .suppressed(.interrupted)
            state.currentSession = current
            guard let meetingID = current.meetingID else { return [] }
            return [.stopCapture(meetingID: meetingID, reason: .interrupted)]
        case .retryScheduled, .suppressed:
            return []
        }
    }

    /// Each try gets its own meeting ID from the controller, so the failed
    /// writer is finalized under its ID while this session waits for the
    /// next. Only a camera-off completes the session.
    private mutating func captureStartFailed(sessionID: String, at date: Date) -> [CaptureEffect] {
        guard var current = state.currentSession, current.descriptor.id == sessionID else { return [] }

        var effects: [CaptureEffect] = []
        switch current.phase {
        case .startRequested:
            break
        case .recording:
            if let meetingID = current.meetingID {
                effects.append(.stopCapture(meetingID: meetingID, reason: .startFailed))
            }
        case .retryScheduled, .suppressed:
            // Nothing is starting, so there is no try to count.
            return []
        }

        current.failedStarts += 1
        if let delay = retryPolicy.delay(afterFailedStarts: current.failedStarts) {
            let retryAt = date.addingTimeInterval(delay)
            current.phase = .retryScheduled(at: retryAt)
            effects.append(.retryScheduled(sessionID: sessionID, at: retryAt))
        } else {
            current.phase = .suppressed(.interrupted)
            effects.append(.retriesExhausted(sessionID: sessionID))
        }
        state.currentSession = current
        return effects
    }

    private mutating func skipCurrent() -> [CaptureEffect] {
        guard var current = state.currentSession else { return [] }
        if case .suppressed(.skipped) = current.phase { return [] }

        var effects: [CaptureEffect] = []
        if current.phase == .recording, let meetingID = current.meetingID {
            effects.append(.stopCapture(meetingID: meetingID, reason: .skipped))
        }
        current.phase = .suppressed(.skipped)
        state.currentSession = current
        effects.append(.sessionSkipped(sessionID: current.descriptor.id))
        return effects
    }

    private mutating func setPaused(_ paused: Bool) -> [CaptureEffect] {
        guard state.isPaused != paused else { return [] }
        state.isPaused = paused
        guard paused, var current = state.currentSession else { return [] }

        var effects: [CaptureEffect] = []
        if current.phase == .recording, let meetingID = current.meetingID {
            effects.append(.stopCapture(meetingID: meetingID, reason: .paused))
        }
        current.phase = .suppressed(.paused)
        state.currentSession = current
        return effects
    }

    private mutating func rememberCompleted(_ sessionID: String) {
        state.completedSessionIDs.removeAll { $0 == sessionID }
        state.completedSessionIDs.append(sessionID)
        if state.completedSessionIDs.count > 128 {
            state.completedSessionIDs.removeFirst(state.completedSessionIDs.count - 128)
        }
    }
}
