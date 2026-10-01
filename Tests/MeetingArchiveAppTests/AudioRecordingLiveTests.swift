import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingArchiveApp

/// Records from the real default microphone and system audio. Opt in with
/// MEETING_ARCHIVE_LIVE_AUDIO=1, and add MEETING_ARCHIVE_LIVE_AUDIO_KEEP=1 to
/// keep the files. The test runner is not the signed app: it needs microphone
/// access of its own, and macOS gives an unsigned tap silence.
final class AudioRecordingLiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEETING_ARCHIVE_LIVE_AUDIO"] == "1",
                          "Set MEETING_ARCHIVE_LIVE_AUDIO=1 to record from the real microphone and system audio.")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-archive-live-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        guard let directory else { return }
        if ProcessInfo.processInfo.environment["MEETING_ARCHIVE_LIVE_AUDIO_KEEP"] == "1" {
            print("[live audio] kept \(directory.path)")
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testRecordsFiveSecondsFromTheMicrophoneAndSystemAudio() async throws {
        let before = Hardware.snapshot()
        let events = Events()
        let recording = AudioRecording()
        recording.onStarted = { events.add("started") }
        recording.onWarning = { events.add("warning: \($0)") }
        recording.onFailure = { events.add("failure: \($0)") }

        let startedAt = Date()
        try await recording.start(directory: directory)
        print("[live audio] start took \(String(format: "%.3f", Date().timeIntervalSince(startedAt))) s")
        print("[live audio] while recording: \(Hardware.snapshot().description(comparedWith: before))")
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            recording.checkHealth()
        }
        let result = await recording.stop()
        try await Task.sleep(for: .milliseconds(500))
        let after = Hardware.snapshot()

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
        print("[live audio] after stop: \(after.description(comparedWith: before))")

        XCTAssertTrue(recording.hasCapturedSamples)
        XCTAssertNil(result.error)
        after.assertNothingLeftRunning(comparedWith: before)
    }

    func testStoppingWhileStartingLeavesNothingRunning() async throws {
        let before = Hardware.snapshot()
        // Stops landing before, during and after the sources start.
        for delay in [0, 20, 80, 250] {
            let recording = AudioRecording()
            let folder = directory.appendingPathComponent("\(delay)ms")
            let starting = Task { try await recording.start(directory: folder) }
            try await Task.sleep(for: .milliseconds(delay))
            let result = await recording.stop()
            try await starting.value
            // Anything a late start opened would still be running by now.
            try await Task.sleep(for: .milliseconds(500))
            let after = Hardware.snapshot()
            print("[live audio] stop after \(delay) ms: tracks \(result.tracks.keys.sorted()), \(after.description(comparedWith: before))")
            after.assertNothingLeftRunning(comparedWith: before)
        }
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

/// What this process can see of the audio hardware: its taps and aggregate
/// devices are visible to it even though they are private.
private struct Hardware {
    let taps: Set<AudioObjectID>
    let devices: Set<AudioObjectID>
    let inputRunning: Bool

    static func snapshot() -> Hardware {
        let input = try? AudioHAL.defaultInputDevice()
        let running = input.flatMap { try? AudioHAL.value(kAudioDevicePropertyDeviceIsRunningSomewhere, of: $0, initial: UInt32(0)) } ?? 0
        return Hardware(taps: objects(kAudioHardwarePropertyTapList), devices: objects(kAudioHardwarePropertyDevices), inputRunning: running != 0)
    }

    func description(comparedWith before: Hardware) -> String {
        "\(taps.subtracting(before.taps).count) extra taps, \(devices.subtracting(before.devices).count) extra devices, default input \(inputRunning ? "running" : "idle")"
    }

    func assertNothingLeftRunning(comparedWith before: Hardware, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(taps, before.taps, "a tap was left behind", file: file, line: line)
        XCTAssertEqual(devices, before.devices, "an aggregate device was left behind", file: file, line: line)
        // Another app may be using the microphone; only a change is ours.
        if !before.inputRunning {
            XCTAssertFalse(inputRunning, "the microphone was left running", file: file, line: line)
        }
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> Set<AudioObjectID> {
        var address = AudioHAL.address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioHAL.system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioHAL.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids)
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var all: [String] { lock.withLock { events } }
    func add(_ event: String) { lock.withLock { events.append(event) } }
}
