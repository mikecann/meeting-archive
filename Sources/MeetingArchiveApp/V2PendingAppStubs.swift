// TEMPORARY: compile-only stand-ins for the audio capture being built on
// another branch. Delete before merging that branch.
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
