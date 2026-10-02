import Foundation

/// An app using the microphone. Helper processes are traced back to the app
/// that owns them, so a Meet call in Chrome is Google Chrome, never a helper.
public struct MicUser: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// What a recording follows. A microphone recording ends once its app lets go
/// of the mic. A manual one runs until the user stops it.
public enum RecordingTrigger: Codable, Equatable, Sendable {
    case microphone(MicUser)
    case manual

    var micUser: MicUser? {
        if case .microphone(let user) = self { return user }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, app }
    private enum Kind: String, Codable { case microphone, manual }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .microphone: self = .microphone(try container.decode(MicUser.self, forKey: .app))
        case .manual: self = .manual
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .microphone(let user):
            try container.encode(Kind.microphone, forKey: .kind)
            try container.encode(user, forKey: .app)
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        }
    }
}

public enum RecordingStopReason: String, Codable, Sendable {
    /// The app let go of the mic for the grace period.
    case micReleased = "mic_released"
    /// The app let go and a different app now holds the mic.
    case switchedApp = "switched_app"
    case userStopped = "user_stopped"
    case discarded
    case paused
    /// Capture broke. A new part starts while the trigger still holds.
    case captureFailed = "capture_failed"
    /// Meeting Archive quit mid-recording. The controller gives this to the
    /// parts it recovers on relaunch; the policy never emits it.
    case appQuit = "app_quit"
}

public struct RecordingPolicyConfiguration: Equatable, Sendable {
    /// How long a microphone recording waits for its app to take the mic back.
    public var releaseGrace: TimeInterval
    /// The wait before each restart after a capture failure. The last one
    /// repeats for as long as capture keeps failing.
    public var retryDelays: [TimeInterval]
    /// A part that records this long resets the failure count.
    public var stableRecordingResetsFailures: TimeInterval

    public init(releaseGrace: TimeInterval, retryDelays: [TimeInterval], stableRecordingResetsFailures: TimeInterval) {
        self.releaseGrace = releaseGrace
        self.retryDelays = retryDelays
        self.stableRecordingResetsFailures = stableRecordingResetsFailures
    }

    public static let standard = RecordingPolicyConfiguration(
        releaseGrace: 30,
        retryDelays: [2, 5, 15, 30, 60],
        stableRecordingResetsFailures: 60
    )

    func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard !retryDelays.isEmpty else { return 0 }
        return retryDelays[min(max(failures, 0), retryDelays.count - 1)]
    }
}

/// The part being recorded now. Every part has its own meeting ID; the parts
/// of one call share a series.
public struct ActiveRecording: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var seriesID: UUID
    /// 1-based.
    public var part: Int
    public var trigger: RecordingTrigger
    public var startedAt: Date
    /// The last tick the trigger app held the mic.
    public var lastHeldAt: Date
    /// False until capture reports it started.
    public var isCapturing: Bool
    /// Capture failures in a row before this part. It sets the wait if this
    /// part fails too, and a part that records long enough clears it.
    public var consecutiveFailures: Int

    public init(
        meetingID: UUID,
        seriesID: UUID,
        part: Int,
        trigger: RecordingTrigger,
        startedAt: Date,
        lastHeldAt: Date,
        isCapturing: Bool = false,
        consecutiveFailures: Int = 0
    ) {
        self.meetingID = meetingID
        self.seriesID = seriesID
        self.part = part
        self.trigger = trigger
        self.startedAt = startedAt
        self.lastHeldAt = lastHeldAt
        self.isCapturing = isCapturing
        self.consecutiveFailures = consecutiveFailures
    }
}

/// The next part of a series, waiting out its delay after a failure or a
/// relaunch. Nothing is recording while it waits.
public struct PendingRestart: Codable, Equatable, Sendable {
    public var trigger: RecordingTrigger
    public var seriesID: UUID
    public var nextPart: Int
    public var notBefore: Date
    public var consecutiveFailures: Int

    public init(trigger: RecordingTrigger, seriesID: UUID, nextPart: Int, notBefore: Date, consecutiveFailures: Int) {
        self.trigger = trigger
        self.seriesID = seriesID
        self.nextPart = nextPart
        self.notBefore = notBefore
        self.consecutiveFailures = consecutiveFailures
    }
}

public struct RecordingPolicyState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var isPaused: Bool
    public var active: ActiveRecording?
    /// Only set while nothing is active.
    public var pendingRestart: PendingRestart?
    /// Apps the user stopped, discarded or paused. Each stays unrecorded until
    /// it has let go of the mic for the release grace.
    public var suppressedBundleIDs: [String]
    /// When each suppressed app was last seen letting go of the mic.
    public var suppressionReleasedAt: [String: Date]

    public init(
        schemaVersion: Int = 2,
        isPaused: Bool = false,
        active: ActiveRecording? = nil,
        pendingRestart: PendingRestart? = nil,
        suppressedBundleIDs: [String] = [],
        suppressionReleasedAt: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.isPaused = isPaused
        self.active = active
        self.pendingRestart = pendingRestart
        self.suppressedBundleIDs = suppressedBundleIDs
        self.suppressionReleasedAt = suppressionReleasedAt
    }
}

public enum RecordingEvent: Equatable, Sendable {
    /// Sent every second. `micUsers` already leaves out ignored apps and is in
    /// the order each app took the mic.
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

/// Decides when to record from who holds the mic and what the user asks for.
/// It records first and leaves keeping to `KeepPolicy`.
public struct RecordingPolicy: Sendable {
    public private(set) var state: RecordingPolicyState
    private let configuration: RecordingPolicyConfiguration
    private let makeID: @Sendable () -> UUID
    /// Who held the mic at the last tick. Stop and Discard suppress all of
    /// them, so stopping never hands the recorder straight to another app or
    /// restarts a pinned call. It is not persisted; the next tick refills it.
    private var micUsersAtLastTick: [MicUser] = []

    /// A new series takes its series ID from `makeID` first, then its first
    /// part's meeting ID.
    public init(
        state: RecordingPolicyState = .init(),
        configuration: RecordingPolicyConfiguration = .standard,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.state = state
        self.configuration = configuration
        self.makeID = makeID
    }

    /// The writer died with the old process, so an active part cannot still
    /// be recording. It becomes a restart that is due now, with a clean
    /// failure count; the controller recovers the old part's files itself.
    /// Pause and suppression carry over as they were.
    public init(
        restoringPersistedState persisted: RecordingPolicyState,
        now: Date,
        configuration: RecordingPolicyConfiguration = .standard,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        var state = persisted
        if let active = state.active {
            state.pendingRestart = PendingRestart(
                trigger: active.trigger,
                seriesID: active.seriesID,
                nextPart: active.part + 1,
                notBefore: now,
                consecutiveFailures: 0
            )
            state.active = nil
        }
        self.init(state: state, configuration: configuration, makeID: makeID)
    }

    @discardableResult
    public mutating func handle(_ event: RecordingEvent) -> [RecordingEffect] {
        switch event {
        case .tick(let micUsers, let date):
            return tick(micUsers, at: date)
        case .manualStart(let date):
            return manualStart(at: date)
        case .manualStop:
            return stopForUser(reason: .userStopped)
        case .discardCurrent:
            return stopForUser(reason: .discarded)
        case .setPaused(let paused, _):
            return setPaused(paused)
        case .captureStarted(let meetingID, _):
            return captureStarted(meetingID: meetingID)
        case .captureFailed(let meetingID, let date):
            return captureFailed(meetingID: meetingID, at: date)
        }
    }

    private mutating func tick(_ users: [MicUser], at date: Date) -> [RecordingEffect] {
        micUsersAtLastTick = users
        endSuppressionsOnceReleased(users, at: date)
        return state.active == nil ? idleTick(users, at: date) : activeTick(users, at: date)
    }

    /// Letting go of the mic ends a suppression, even while another app is
    /// being recorded, but only once it has stayed off for the release grace.
    /// An app that drops the mic for a moment, say while switching devices,
    /// is still on the same call and must not restart a recording the user
    /// stopped.
    private mutating func endSuppressionsOnceReleased(_ users: [MicUser], at date: Date) {
        for id in state.suppressedBundleIDs {
            if users.contains(where: { $0.bundleIdentifier == id }) {
                state.suppressionReleasedAt[id] = nil
            } else if let released = state.suppressionReleasedAt[id] {
                guard date.timeIntervalSince(released) >= configuration.releaseGrace else { continue }
                state.suppressedBundleIDs.removeAll { $0 == id }
                state.suppressionReleasedAt[id] = nil
            } else {
                state.suppressionReleasedAt[id] = date
            }
        }
    }

    private mutating func activeTick(_ users: [MicUser], at date: Date) -> [RecordingEffect] {
        guard var active = state.active else { return [] }
        clearFailuresIfStable(&active, at: date)
        state.active = active

        // A manual recording only ends when the user stops it or capture fails.
        guard case .microphone(let app) = active.trigger else { return [] }

        if holds(app, users) {
            state.active?.lastHeldAt = date
            return []
        }
        if let next = firstCandidate(in: users) {
            state.active = nil
            return [
                .stopCapture(meetingID: active.meetingID, reason: .switchedApp),
                startSeries(.microphone(next), at: date),
            ]
        }
        guard date.timeIntervalSince(active.lastHeldAt) >= configuration.releaseGrace else { return [] }
        state.active = nil
        return [.stopCapture(meetingID: active.meetingID, reason: .micReleased)]
    }

    private mutating func idleTick(_ users: [MicUser], at date: Date) -> [RecordingEffect] {
        if let pending = state.pendingRestart {
            switch pending.trigger {
            case .manual:
                // A manual series keeps the recorder while it waits to restart.
                return date >= pending.notBefore ? [startNextPart(of: pending, at: date)] : []
            case .microphone(let app):
                let stillHeld = holds(app, users)
                if date >= pending.notBefore {
                    // Pause holds back the mic, and that includes a restart.
                    if stillHeld, !state.isPaused { return [startNextPart(of: pending, at: date)] }
                    state.pendingRestart = nil
                } else if stillHeld {
                    // The app is still on its call, so its own restart comes
                    // first. Only an unrelated app skips the wait.
                    return []
                }
            }
        }
        guard let user = firstCandidate(in: users) else { return [] }
        return [startSeries(.microphone(user), at: date)]
    }

    private mutating func manualStart(at date: Date) -> [RecordingEffect] {
        guard state.active != nil else { return [startSeries(.manual, at: date)] }
        // Pin the recording so letting go of the mic no longer ends it.
        state.active?.trigger = .manual
        return []
    }

    private mutating func stopForUser(reason: RecordingStopReason) -> [RecordingEffect] {
        var effects: [RecordingEffect] = []
        let trigger: RecordingTrigger
        if let active = state.active {
            effects.append(.stopCapture(meetingID: active.meetingID, reason: reason))
            trigger = active.trigger
        } else if let pending = state.pendingRestart {
            trigger = pending.trigger
        } else {
            return []
        }
        state.active = nil
        state.pendingRestart = nil

        // Stop means stop: the app that started it, and every app on the mic
        // right now, waits until it lets go before it is recorded again.
        if let app = trigger.micUser { suppress(app.bundleIdentifier) }
        for user in micUsersAtLastTick { suppress(user.bundleIdentifier) }
        return effects
    }

    private mutating func setPaused(_ paused: Bool) -> [RecordingEffect] {
        state.isPaused = paused
        guard paused else { return [] }

        var effects: [RecordingEffect] = []
        // A manual recording keeps going; pause only holds back the mic.
        if let active = state.active, let app = active.trigger.micUser {
            effects.append(.stopCapture(meetingID: active.meetingID, reason: .paused))
            suppress(app.bundleIdentifier)
            state.active = nil
        }
        if let pending = state.pendingRestart, let app = pending.trigger.micUser {
            suppress(app.bundleIdentifier)
            state.pendingRestart = nil
        }
        return effects
    }

    private mutating func captureStarted(meetingID: UUID) -> [RecordingEffect] {
        guard state.active?.meetingID == meetingID else { return [] }
        state.active?.isCapturing = true
        return []
    }

    /// The failed part is stopped so the controller can save it, and the
    /// series carries on with the next part once the backoff has passed.
    private mutating func captureFailed(meetingID: UUID, at date: Date) -> [RecordingEffect] {
        guard var active = state.active, active.meetingID == meetingID else { return [] }
        clearFailuresIfStable(&active, at: date)
        let failures = active.consecutiveFailures
        state.active = nil
        state.pendingRestart = PendingRestart(
            trigger: active.trigger,
            seriesID: active.seriesID,
            nextPart: active.part + 1,
            notBefore: date.addingTimeInterval(configuration.retryDelay(afterFailures: failures)),
            consecutiveFailures: failures + 1
        )
        return [.stopCapture(meetingID: meetingID, reason: .captureFailed)]
    }

    private mutating func startSeries(_ trigger: RecordingTrigger, at date: Date) -> RecordingEffect {
        let seriesID = makeID()
        return begin(ActiveRecording(
            meetingID: makeID(),
            seriesID: seriesID,
            part: 1,
            trigger: trigger,
            startedAt: date,
            lastHeldAt: date
        ))
    }

    private mutating func startNextPart(of pending: PendingRestart, at date: Date) -> RecordingEffect {
        begin(ActiveRecording(
            meetingID: makeID(),
            seriesID: pending.seriesID,
            part: pending.nextPart,
            trigger: pending.trigger,
            startedAt: date,
            lastHeldAt: date,
            consecutiveFailures: pending.consecutiveFailures
        ))
    }

    private mutating func begin(_ recording: ActiveRecording) -> RecordingEffect {
        state.active = recording
        state.pendingRestart = nil
        return .startCapture(
            meetingID: recording.meetingID,
            trigger: recording.trigger,
            seriesID: recording.seriesID,
            part: recording.part
        )
    }

    private func clearFailuresIfStable(_ active: inout ActiveRecording, at date: Date) {
        guard active.isCapturing,
              date.timeIntervalSince(active.startedAt) >= configuration.stableRecordingResetsFailures else { return }
        active.consecutiveFailures = 0
    }

    private func firstCandidate(in users: [MicUser]) -> MicUser? {
        guard !state.isPaused else { return nil }
        return users.first { !state.suppressedBundleIDs.contains($0.bundleIdentifier) }
    }

    private func holds(_ app: MicUser, _ users: [MicUser]) -> Bool {
        users.contains { $0.bundleIdentifier == app.bundleIdentifier }
    }

    private mutating func suppress(_ bundleID: String) {
        state.suppressionReleasedAt[bundleID] = nil
        guard !state.suppressedBundleIDs.contains(bundleID) else { return }
        state.suppressedBundleIDs.append(bundleID)
    }
}

public enum KeepDecision: Equatable, Sendable {
    case keep
    case discard(reason: String)
}

/// Whether a finished part is worth keeping. Recording starts as soon as an
/// app takes the mic, so this is where brief or silent mic grabs are dropped.
///
/// A call only has to be heard on one side. Without the System Audio
/// Recording permission the incoming track is pure silence, and deleting
/// every call then would lose exactly what this app exists to keep.
public struct KeepPolicy: Equatable, Sendable {
    public var minimumDuration: TimeInterval = 60
    /// Seconds of audio from the other end of the call.
    public var minimumIncomingActivity: TimeInterval = 5
    /// Seconds of the user talking that keep a call on their side alone.
    public var minimumMicrophoneActivity: TimeInterval = 30

    public init(minimumDuration: TimeInterval = 60, minimumIncomingActivity: TimeInterval = 5, minimumMicrophoneActivity: TimeInterval = 30) {
        self.minimumDuration = minimumDuration
        self.minimumIncomingActivity = minimumIncomingActivity
        self.minimumMicrophoneActivity = minimumMicrophoneActivity
    }

    /// Activity is seconds of sound on each track.
    public func decide(
        trigger: RecordingTrigger,
        stopReason: RecordingStopReason,
        part: Int,
        duration: TimeInterval,
        incomingActivity: TimeInterval,
        microphoneActivity: TimeInterval
    ) -> KeepDecision {
        if stopReason == .discarded { return .discard(reason: "you discarded it") }

        let heardAnything = incomingActivity > 0 || microphoneActivity > 0
        if !heardAnything, duration < 1 { return .discard(reason: "nothing recorded") }
        if trigger == .manual { return .keep }

        // A piece of a call cut short by a failure or a quit is kept on any
        // sound, since the call itself may well have passed the bar. So is a
        // call the user stopped, because the menu says "Stop and save".
        if part > 1 || stopReason == .captureFailed || stopReason == .appQuit || stopReason == .userStopped {
            return heardAnything ? .keep : .discard(reason: "nothing recorded")
        }

        if duration < minimumDuration { return .discard(reason: underMinimumDuration) }
        if incomingActivity < minimumIncomingActivity, microphoneActivity < minimumMicrophoneActivity {
            return .discard(reason: "nobody spoke")
        }
        return .keep
    }

    /// Rounded up, so a discarded part is always under the bar it names.
    private var underMinimumDuration: String {
        let seconds = Int(minimumDuration.rounded(.up))
        if seconds == 60 { return "under a minute" }
        if seconds > 60, seconds % 60 == 0 { return "under \(seconds / 60) minutes" }
        return "under \(seconds) seconds"
    }
}
