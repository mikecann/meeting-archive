// TEMPORARY: compile-only stand-ins for the capture and mic monitor being
// built on other branches. Delete before merging those branches.
import Foundation
import MeetingArchiveCore

struct CapturedMicrophone: Codable, Equatable, Sendable { var uid: String; var name: String }

struct AudioRecordingResult: Sendable {
    var tracks: [String: TrackProgress]
    var activitySeconds: [String: Double]
    var microphone: CapturedMicrophone?
    var error: Error?
}

final class AudioRecording: @unchecked Sendable {
    var onStarted: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var onWarning: (@Sendable (String) -> Void)?
    var hasCapturedSamples: Bool { false }
    func start(directory: URL) async throws {}
    func checkHealth() {}
    func stop() async -> AudioRecordingResult { AudioRecordingResult(tracks: [:], activitySeconds: [:], microphone: nil, error: nil) }
}

struct MicUsageSnapshot: Equatable, Sendable { var users: [MicUser]; var ignored: [MicUser]; var error: String? }

struct MicAppResolver {
    static let defaultIgnoredBundleIDs: Set<String> = ["com.mikerosoft.meeting-archive"]
}

@MainActor final class MicActivityMonitor {
    init(ignoredBundleIDs: @escaping @MainActor () -> Set<String> = { MicAppResolver.defaultIgnoredBundleIDs }, ownPID: pid_t = getpid()) {}
    func snapshot() -> MicUsageSnapshot { MicUsageSnapshot(users: [], ignored: [], error: nil) }
}
