// TEMPORARY: compile-only stand-ins for RecordingPolicy while it is built on
// another branch. Delete before merging that branch.
import Foundation

public struct MicUser: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String
    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public enum RecordingTrigger: Codable, Equatable, Sendable { case microphone(MicUser), manual }

public enum RecordingStopReason: String, Codable, Sendable {
    case micReleased = "mic_released", switchedApp = "switched_app", userStopped = "user_stopped"
    case discarded, paused, captureFailed = "capture_failed", appQuit = "app_quit"
}

public struct ActiveRecording: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var seriesID: UUID
    public var part: Int
    public var trigger: RecordingTrigger
    public var startedAt: Date
    public var lastHeldAt: Date
    public var isCapturing: Bool
}

public struct RecordingPolicyState: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var isPaused = false
    public var active: ActiveRecording?
    public var suppressedBundleIDs: [String] = []
    public init() {}
}

public enum RecordingEvent: Equatable, Sendable {
    case tick(micUsers: [MicUser], at: Date)
    case manualStart(at: Date)
    case manualStop(at: Date)
    case discardCurrent(at: Date)
    case setPaused(Bool, at: Date)
    case captureStarted(meetingID: UUID, at: Date)
    case captureFailed(meetingID: UUID, at: Date)
}

public enum RecordingEffect: Equatable, Sendable {
    case startCapture(meetingID: UUID, trigger: RecordingTrigger, seriesID: UUID, part: Int)
    case stopCapture(meetingID: UUID, reason: RecordingStopReason)
}

public struct RecordingPolicy: Sendable {
    public private(set) var state = RecordingPolicyState()
    public init() {}
    public init(restoringPersistedState: RecordingPolicyState, now: Date) { state = restoringPersistedState }
    public mutating func handle(_ event: RecordingEvent) -> [RecordingEffect] { [] }
}

public enum KeepDecision: Equatable, Sendable { case keep, discard(reason: String) }

public struct KeepPolicy: Equatable, Sendable {
    public init() {}
    public func decide(trigger: RecordingTrigger, stopReason: RecordingStopReason, part: Int,
                       duration: TimeInterval, incomingActivity: TimeInterval, microphoneActivity: TimeInterval) -> KeepDecision { .keep }
}
