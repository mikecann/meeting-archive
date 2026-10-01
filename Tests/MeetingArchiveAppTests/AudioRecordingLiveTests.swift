import AVFoundation
import XCTest
@testable import MeetingArchiveApp

/// Records 5 s from the real default microphone and system audio. Opt in with
/// MEETING_ARCHIVE_LIVE_AUDIO=1, and add MEETING_ARCHIVE_LIVE_AUDIO_KEEP=1 to
/// keep the files. The test runner is not the signed app: it needs microphone
/// access of its own, and macOS gives an unsigned tap silence.
final class AudioRecordingLiveTests: XCTestCase {
    func testRecordsFiveSecondsFromTheMicrophoneAndSystemAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MEETING_ARCHIVE_LIVE_AUDIO"] == "1",
                          "Set MEETING_ARCHIVE_LIVE_AUDIO=1 to record 5 s from the real microphone and system audio.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-archive-live-\(UUID().uuidString)")
        defer {
            if environment["MEETING_ARCHIVE_LIVE_AUDIO_KEEP"] == "1" {
                print("[live audio] kept \(directory.path)")
            } else {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let events = Events()
        let recording = AudioRecording()
        recording.onStarted = { events.add("started") }
        recording.onWarning = { events.add("warning: \($0)") }
        recording.onFailure = { events.add("failure: \($0)") }

        let startedAt = Date()
        try await recording.start(directory: directory)
        print("[live audio] start took \(String(format: "%.3f", Date().timeIntervalSince(startedAt))) s")
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            recording.checkHealth()
        }
        let result = await recording.stop()

        for name in ["microphone.m4a", "incoming.m4a"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[live audio] \(name): not written")
                continue
            }
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            let file = try AVAudioFile(forReading: url)
            print("[live audio] \(name): \(String(format: "%.3f", duration)) s, \(size) bytes, "
                + "\(Int(file.fileFormat.sampleRate)) Hz x\(file.fileFormat.channelCount), level \(try level(file))")
        }
        for (track, progress) in result.tracks.sorted(by: { $0.key < $1.key }) {
            print("[live audio] track \(track): first \(progress.firstOffset) s, end \(String(format: "%.3f", progress.endOffset)) s, \(progress.sampleCount) buffers")
        }
        print("[live audio] activity: \(result.activitySeconds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) s" }.joined(separator: ", "))")
        print("[live audio] microphone: \(result.microphone.map { "\($0.name) (\($0.uid))" } ?? "none")")
        print("[live audio] error: \(result.error?.localizedDescription ?? "none")")
        print("[live audio] events: \(events.all.joined(separator: " | "))")

        XCTAssertTrue(recording.hasCapturedSamples)
        XCTAssertNil(result.error)
    }

    /// Overall RMS of the first channel, in dBFS.
    private func level(_ file: AVAudioFile) throws -> String {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        guard !samples.isEmpty else { return "empty" }
        let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
        return rms > 0 ? String(format: "%.1f dBFS RMS", 20 * log10(rms)) : "digital silence"
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var all: [String] { lock.withLock { events } }
    func add(_ event: String) { lock.withLock { events.append(event) } }
}
