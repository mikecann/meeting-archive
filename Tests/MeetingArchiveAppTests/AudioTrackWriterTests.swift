import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingArchiveApp

final class AudioTrackWriterTests: XCTestCase {
    private let origin = CMTime(seconds: 5_000, preferredTimescale: 1_000_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-track-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testA44kStereoInputBecomesA48kMonoFileOfTheSameLength() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 44_100, channels: 2)
        // Through the sample-buffer path, which is how the microphone delivers.
        for (time, buffer) in signal(input, from: 0, seconds: 3, value: sine(440, amplitude: 0.1)) {
            writer.append(try XCTUnwrap(buffer.sampleBuffer(at: time)))
        }

        let summary = await writer.finish()

        let file = try ReadBack(writer.url)
        XCTAssertEqual(file.sampleRate, 48_000)
        XCTAssertEqual(file.channels, 1)
        XCTAssertEqual(file.duration, 3, accuracy: 0.05)
        // Both channels carried the tone, so the downmix keeps its level.
        XCTAssertEqual(file.rms(from: 0.5, to: 2.5), 0.1 / 2.squareRoot(), accuracy: 0.01)
        let progress = try XCTUnwrap(summary.progress)
        XCTAssertEqual(progress.firstOffset, 0)
        XCTAssertEqual(progress.endOffset, 3, accuracy: 0.05)
        XCTAssertNil(summary.error)
    }

    func testAGapInTheInputIsFilledWithSilenceSoLaterAudioKeepsItsPlace() async throws {
        let writer = AudioTrackWriter.incoming(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 2)
        feed(writer, signal(input, from: 0, seconds: 1, value: sine(440, amplitude: 0.1)))
        // The source stops for 2 s, as when the tap is rebuilt.
        feed(writer, signal(input, from: 3, seconds: 1, value: sine(440, amplitude: 0.3)))

        let summary = await writer.finish()

        let file = try ReadBack(writer.url)
        XCTAssertEqual(file.channels, 2)
        XCTAssertEqual(file.duration, 4, accuracy: 0.05)
        XCTAssertLessThan(file.rms(from: 1.1, to: 2.9), 0.0001)
        XCTAssertEqual(file.rms(from: 3.1, to: 3.9), 0.3 / 2.squareRoot(), accuracy: 0.02)
        let progress = try XCTUnwrap(summary.progress)
        XCTAssertEqual(progress.firstOffset, 0)
        XCTAssertEqual(progress.endOffset, 4, accuracy: 0.05)
    }

    func testOverlappingInputIsTrimmedNotWrittenTwice() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 1)
        feed(writer, signal(input, from: 0, seconds: 2, value: sine(440, amplitude: 0.1)))
        // A restarted source replays from 1 s, overlapping the last second.
        feed(writer, signal(input, from: 1, seconds: 2, value: sine(440, amplitude: 0.3)))

        let summary = await writer.finish()

        let file = try ReadBack(writer.url)
        XCTAssertEqual(file.duration, 3, accuracy: 0.05)
        XCTAssertEqual(file.rms(from: 0.1, to: 1.9), 0.1 / 2.squareRoot(), accuracy: 0.01)
        // Only the replay's new second remains after the original audio.
        XCTAssertEqual(file.rms(from: 2.1, to: 2.9), 0.3 / 2.squareRoot(), accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(summary.progress).endOffset, 3, accuracy: 0.05)
    }

    func testActivityCountsAToneAtMinus20dBFSButNotNoiseAtMinus70dBFS() async throws {
        let writer = AudioTrackWriter.incoming(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 2)
        feed(writer, signal(input, from: 0, seconds: 2, value: sine(1_000, amplitude: 0.1)))
        feed(writer, signal(input, from: 2, seconds: 2, value: noise(rms: pow(10, -70.0 / 20))))

        let summary = await writer.finish()

        XCTAssertEqual(summary.activitySeconds, 2, accuracy: 0.11)
        XCTAssertEqual(try ReadBack(writer.url).duration, 4, accuracy: 0.05)
        XCTAssertEqual(summary.peakLevel, 0.1 / 2.squareRoot(), accuracy: 0.01)
    }

    /// A tap without the System Audio permission hands over pure zeros, which
    /// the controller tells apart from a quiet call by the peak level.
    func testPureDigitalSilenceHasAZeroPeakButQuietNoiseDoesNot() async throws {
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 2)
        let silent = AudioTrackWriter.incoming(directory: directory, origin: origin)
        feed(silent, signal(input, from: 0, seconds: 2, value: { _ in 0 }))
        let quietDirectory = directory.appendingPathComponent("quiet", isDirectory: true)
        try FileManager.default.createDirectory(at: quietDirectory, withIntermediateDirectories: true)
        let quiet = AudioTrackWriter.incoming(directory: quietDirectory, origin: origin)
        feed(quiet, signal(input, from: 0, seconds: 2, value: noise(rms: pow(10, -70.0 / 20))))

        let silentSummary = await silent.finish()
        let quietSummary = await quiet.finish()

        XCTAssertEqual(silentSummary.peakLevel, 0)
        XCTAssertGreaterThan(quietSummary.peakLevel, 0)
        XCTAssertEqual(quietSummary.activitySeconds, 0)
    }

    func testAFormatChangeMidStreamCarriesOnInTheSameFile() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        // A Yeti delivers 48 kHz stereo Int16; AirPods in call mode 16 kHz mono.
        let yeti = try format(.pcmFormatInt16, rate: 48_000, channels: 2)
        let airPods = try format(.pcmFormatFloat32, rate: 16_000, channels: 1)
        feed(writer, signal(yeti, from: 0, seconds: 2, value: sine(440, amplitude: 0.1)))
        feed(writer, signal(airPods, from: 2, seconds: 2, value: sine(440, amplitude: 0.3)))

        let summary = await writer.finish()

        let file = try ReadBack(writer.url)
        XCTAssertEqual(file.sampleRate, 48_000)
        XCTAssertEqual(file.channels, 1)
        XCTAssertEqual(file.duration, 4, accuracy: 0.05)
        XCTAssertEqual(file.rms(from: 0.2, to: 1.8), 0.1 / 2.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(file.rms(from: 2.2, to: 3.8), 0.3 / 2.squareRoot(), accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(summary.progress).endOffset, 4, accuracy: 0.05)
    }

    func testAStereoMicrophoneWithSoundOnOneSideIsStillRecorded() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 2)
        let chunks = signal(input, from: 0, seconds: 1, value: sine(440, amplitude: 0.2))
        for (_, buffer) in chunks {
            // Silence the left channel, as on an interface with the mic on input 2.
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame * 2] = 0 }
        }
        feed(writer, chunks)

        _ = await writer.finish()

        // Mixed down rather than taking the left channel alone.
        XCTAssertEqual(try ReadBack(writer.url).rms(from: 0.1, to: 0.9), 0.1 / 2.squareRoot(), accuracy: 0.01)
    }

    func testATrackStartsAtTheSharedOriginEvenWhenItsSourceStartsLate() async throws {
        let writer = AudioTrackWriter.incoming(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 2)
        feed(writer, signal(input, from: 0.5, seconds: 1, value: sine(440, amplitude: 0.1)))

        let summary = await writer.finish()

        // Leading silence means both files begin at the origin and line up
        // directly; tracks.json records that with a zero first offset.
        let file = try ReadBack(writer.url)
        XCTAssertEqual(file.duration, 1.5, accuracy: 0.05)
        XCTAssertLessThan(file.rms(from: 0, to: 0.45), 0.0001)
        let progress = try XCTUnwrap(summary.progress)
        XCTAssertEqual(progress.firstOffset, 0)
        XCTAssertEqual(progress.endOffset, 1.5, accuracy: 0.05)
    }

    func testJitterIsWrittenAsItComesWithoutPaddingOrTrimming() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 1)
        var generator = SystemRandomNumberGenerator()
        for (time, buffer) in signal(input, from: 0, seconds: 3, value: sine(440, amplitude: 0.1)) {
            // Up to 30 ms either way, inside the 50 ms tolerance.
            let jitter = CMTime(seconds: Double.random(in: -0.03...0.03, using: &generator), preferredTimescale: 1_000_000_000)
            writer.append(buffer, at: CMTimeAdd(time, jitter))
        }

        let summary = await writer.finish()

        XCTAssertEqual(try ReadBack(writer.url).duration, 3, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(summary.progress).endOffset, 3, accuracy: 0.002)
    }

    func testABusyEncoderGetsSilenceInPlaceOfItsBacklogAfterTwoSeconds() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let encoder = FakeEncoder()
        writer.encoderIsBusy = { encoder.busy }
        writer.uptime = { encoder.uptime }
        let warnings = Messages()
        writer.onWarning = { warnings.add($0) }
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 1)

        encoder.busy = true
        feed(writer, signal(input, from: 0, seconds: 1, value: sine(440, amplitude: 0.3)))
        await writer.sync()
        encoder.uptime = 2.5
        feed(writer, signal(input, from: 1, seconds: 0.5, value: sine(440, amplitude: 0.3)))
        await writer.sync()
        encoder.busy = false
        feed(writer, signal(input, from: 1.5, seconds: 0.5, value: sine(440, amplitude: 0.1)))
        let summary = await writer.finish()

        // The held audio is gone, but what follows is still in its place.
        let file = try ReadBack(writer.url)
        XCTAssertEqual(file.duration, 2, accuracy: 0.05)
        XCTAssertLessThan(file.rms(from: 0.05, to: 1.45), 0.0001)
        XCTAssertEqual(file.rms(from: 1.55, to: 1.95), 0.1 / 2.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(summary.activitySeconds, 0.5, accuracy: 0.11)
        XCTAssertEqual(warnings.all.count, 1)
    }

    func testADeviceClockThatDriftsStaysWithinToleranceOfTheHostClock() async throws {
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 1)
        // 0.1% either way over two minutes, far worse than a real device, so
        // trimming (fast clock) and padding (slow clock) both happen often.
        for drift in [0.001, -0.001] {
            let folder = directory.appendingPathComponent("\(drift)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writer = AudioTrackWriter.microphone(directory: folder, origin: origin)
            let chunkSeconds = 0.1 / (1 + drift)
            for index in 0..<1_200 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
                buffer.frameLength = 4_800
                memset(buffer.floatChannelData![0], 0, 4_800 * MemoryLayout<Float>.size)
                writer.append(buffer, at: CMTimeAdd(origin, CMTime(seconds: Double(index) * chunkSeconds, preferredTimescale: 1_000_000_000)))
            }

            let summary = await writer.finish()

            let hostSeconds = 1_200 * chunkSeconds
            XCTAssertEqual(try XCTUnwrap(summary.progress).endOffset, hostSeconds, accuracy: AudioTrackWriter.tolerance + 0.01, "drift \(drift)")
            XCTAssertEqual(try ReadBack(writer.url).duration, hostSeconds, accuracy: AudioTrackWriter.tolerance + 0.01, "drift \(drift)")
        }
    }

    func testATrackThatNeverHearsAnythingLeavesNoFile() async throws {
        let writer = AudioTrackWriter.incoming(directory: directory, origin: origin)

        let summary = await writer.finish()

        XCTAssertFalse(writer.hasSamples)
        XCTAssertNil(summary.progress)
        XCTAssertEqual(summary.activitySeconds, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
    }

    func testTheFirstSampleIsAnnouncedOnceAndFinishingTwiceGivesTheSameSummary() async throws {
        let writer = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let announcements = Counter()
        writer.onFirstSample = { announcements.increment() }
        let input = try format(.pcmFormatFloat32, rate: 48_000, channels: 1)
        feed(writer, signal(input, from: 0, seconds: 1, value: sine(440, amplitude: 0.1)))

        let first = await writer.finish()
        let second = await writer.finish()

        XCTAssertTrue(writer.hasSamples)
        XCTAssertEqual(announcements.value, 1)
        XCTAssertEqual(first.progress?.endOffset, second.progress?.endOffset)
        XCTAssertEqual(first.activitySeconds, second.activitySeconds)
    }

    // MARK: - Helpers

    private func format(_ common: AVAudioCommonFormat, rate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels, interleaved: true))
    }

    /// Consecutive 512-frame chunks stamped on the host clock from `start`
    /// seconds after the origin. Every channel carries the same signal.
    private func signal(_ format: AVAudioFormat, from start: Double, seconds: Double,
                        value: (Double) -> Float) -> [(CMTime, AVAudioPCMBuffer)] {
        let rate = format.sampleRate
        let total = Int((seconds * rate).rounded())
        let channels = Int(format.channelCount)
        var chunks: [(CMTime, AVAudioPCMBuffer)] = []
        var frame = 0
        while frame < total {
            let count = min(512, total - frame)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let sample = value(Double(frame + index) / rate)
                for channel in 0..<channels {
                    if let data = buffer.floatChannelData?[0] {
                        data[index * channels + channel] = sample
                    } else if let data = buffer.int16ChannelData?[0] {
                        data[index * channels + channel] = Int16((sample * 32_767).rounded())
                    }
                }
            }
            let time = CMTimeAdd(origin, CMTime(seconds: start + Double(frame) / rate, preferredTimescale: 1_000_000_000))
            chunks.append((time, buffer))
            frame += count
        }
        return chunks
    }

    private func feed(_ writer: AudioTrackWriter, _ chunks: [(CMTime, AVAudioPCMBuffer)]) {
        for (time, buffer) in chunks { writer.append(buffer, at: time) }
    }

    private func sine(_ frequency: Double, amplitude: Float) -> (Double) -> Float {
        { time in amplitude * Float(sin(2 * Double.pi * frequency * time)) }
    }

    /// Uniform noise with the given RMS.
    private func noise(rms: Double) -> (Double) -> Float {
        let peak = Float(rms * 3.squareRoot())
        return { _ in Float.random(in: -peak...peak) }
    }
}

/// A finished file decoded back to PCM, as the worker would read it.
private struct ReadBack {
    let sampleRate: Double
    let channels: Int
    let samples: [Float]

    init(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        sampleRate = file.fileFormat.sampleRate
        channels = Int(file.fileFormat.channelCount)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    var duration: Double { Double(samples.count) / sampleRate }

    /// Zero for any part of the range past the end of the file.
    func rms(from start: Double, to end: Double) -> Double {
        let lower = min(samples.count, Int(start * sampleRate))
        let range = lower..<max(lower, min(samples.count, Int(end * sampleRate)))
        guard !range.isEmpty else { return 0 }
        let sum = range.reduce(0.0) { $0 + Double(samples[$1]) * Double(samples[$1]) }
        return (sum / Double(range.count)).squareRoot()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var all: [String] { lock.withLock { messages } }
    func add(_ message: String) { lock.withLock { messages.append(message) } }
}

/// An encoder that can be held busy, and a clock that moves only when told.
private final class FakeEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false
    private var now: TimeInterval = 0
    var busy: Bool {
        get { lock.withLock { isBusy } }
        set { lock.withLock { isBusy = newValue } }
    }
    var uptime: TimeInterval {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }
}
