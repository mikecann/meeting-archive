import AVFoundation
import XCTest
@testable import MeetingArchiveApp

final class ActivityMeterTests: XCTestCase {
    func testALoudWindowCountsAsExactlyATenthOfASecond() {
        var meter = ActivityMeter(channels: 1)
        meter.add(buffer(channels: 1, frames: 4_800) { _, _ in 0.1 })
        meter.addSilence(frames: 48_000)
        meter.finish()

        XCTAssertEqual(meter.activeSeconds, 0.1, accuracy: 0.000_001)
    }

    func testOnlyWindowsAboveMinus50dBFSCount() {
        var meter = ActivityMeter(channels: 1)
        // A constant level's RMS is the level itself.
        meter.add(buffer(channels: 1, frames: 4_800) { _, _ in Float(pow(10, -49.0 / 20)) })
        meter.add(buffer(channels: 1, frames: 4_800) { _, _ in Float(pow(10, -51.0 / 20)) })
        meter.finish()

        XCTAssertEqual(meter.activeSeconds, 0.1, accuracy: 0.000_001)
    }

    func testAShortLoudEndingStillCounts() {
        var meter = ActivityMeter(channels: 1)
        meter.addSilence(frames: 9_600)
        meter.add(buffer(channels: 1, frames: 1_200) { _, _ in 0.1 })
        meter.finish()

        XCTAssertEqual(meter.activeSeconds, 0.025, accuracy: 0.000_001)
    }

    func testSilenceDilutesTheWindowItShares() {
        var meter = ActivityMeter(channels: 1)
        // 10% of the window at -30 dBFS, the rest silence: about -40 dBFS overall.
        meter.add(buffer(channels: 1, frames: 480) { _, _ in Float(pow(10, -30.0 / 20)) })
        meter.addSilence(frames: 4_320)
        // Just under 1% at -30 dBFS comes to just under -50 dBFS, so it does not count.
        meter.add(buffer(channels: 1, frames: 47) { _, _ in Float(pow(10, -30.0 / 20)) })
        meter.addSilence(frames: 4_753)
        meter.finish()

        XCTAssertEqual(meter.activeSeconds, 0.1, accuracy: 0.000_001)
    }

    func testTheLoudestChannelDecides() {
        var meter = ActivityMeter(channels: 2)
        // Sound on the right only, as from a one-sided stereo source.
        meter.add(buffer(channels: 2, frames: 4_800) { _, channel in channel == 1 ? 0.1 : 0 })
        meter.finish()

        XCTAssertEqual(meter.activeSeconds, 0.1, accuracy: 0.000_001)
    }

    private func buffer(channels: AVAudioChannelCount, frames: Int, value: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<frames {
            for channel in 0..<Int(channels) { samples[frame * Int(channels) + channel] = value(frame, channel) }
        }
        return buffer
    }
}
