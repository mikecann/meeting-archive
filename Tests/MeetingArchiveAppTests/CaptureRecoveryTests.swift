import AVFoundation
import CoreMedia
import MeetingArchiveCore
import XCTest
@testable import MeetingArchiveApp

/// A part cut off by a crash is measured from its files and kept by the same
/// rule as a part saved on quit: anything heard keeps it.
final class CaptureRecoveryTests: XCTestCase {
    private let origin = CMTime(seconds: 5_000, preferredTimescale: 1_000_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A crash in the first seconds of a call used to delete its opening.
    func testAShortInterruptedPartThatHeardSomethingIsKept() async throws {
        let recorded = try await record(.incoming, seconds: 4, soundFrom: 1, to: 3)

        let part = try await RecoveredPart.measure(directory)

        XCTAssertEqual(part.duration, 4, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(part.incomingActivity), recorded.activitySeconds, accuracy: 0.11)
        XCTAssertEqual(part.microphoneActivity, 0, "a microphone that never started heard nothing")
        XCTAssertEqual(part.keepDecision(for: journal(part: 1)), .keep)
    }

    /// A mic grab nobody spoke into isn't a call, however it ended.
    func testAnInterruptedPartThatHeardNothingIsNotKept() async throws {
        _ = try await record(.microphone, seconds: 8)
        _ = try await record(.incoming, seconds: 8)

        let part = try await RecoveredPart.measure(directory)

        XCTAssertEqual(part.duration, 8, accuracy: 0.1)
        XCTAssertEqual(part.incomingActivity, 0)
        XCTAssertEqual(part.microphoneActivity, 0)
        XCTAssertEqual(part.keepDecision(for: journal(part: 2)), .discard(reason: "nothing recorded"))
        XCTAssertEqual(part.keepDecision(for: journal(part: 1, trigger: .manual)), .keep, "Record now always keeps")
    }

    /// Silence only counts once a track has been read to the end.
    func testATrackThatCouldNotBeReadKeepsThePart() {
        let part = RecoveredPart(duration: 600, incomingActivity: nil, microphoneActivity: 0)

        XCTAssertEqual(part.keepDecision(for: journal(part: 1)), .keep)
    }

    private func journal(part: Int, trigger: RecordingTrigger = .microphone(MicUser(bundleIdentifier: "us.zoom.xos", displayName: "zoom.us"))) -> CaptureJournal {
        CaptureJournal(
            id: UUID(), seriesID: UUID(), part: part, trigger: trigger,
            sourceApplication: SourceApplicationDescriptor(bundleIdentifier: "us.zoom.xos", displayName: "zoom.us", kind: .zoom),
            startedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// Writes a track the way a recording does: a 1 kHz tone at -20 dBFS
    /// between the given seconds, and digital silence elsewhere.
    private func record(_ track: MediaTrack, seconds: Double, soundFrom start: Double = 0, to end: Double = 0) async throws -> AudioTrackWriter.Summary {
        let writer = track == .incoming
            ? AudioTrackWriter.incoming(directory: directory, origin: origin)
            : AudioTrackWriter.microphone(directory: directory, origin: origin)
        let channels = track == .incoming ? 2 : 1
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true))
        let total = Int(seconds * 48_000)
        var frame = 0
        while frame < total {
            let count = min(4_800, total - frame)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<count {
                let time = Double(frame + index) / 48_000
                let value: Float = time >= start && time < end ? 0.1 * Float(sin(2 * Double.pi * 1_000 * time)) : 0
                for channel in 0..<channels { samples[index * channels + channel] = value }
            }
            writer.append(buffer, at: CMTimeAdd(origin, CMTime(value: CMTimeValue(frame), timescale: 48_000)))
            frame += count
        }
        return await writer.finish()
    }
}
