import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingArchiveApp

final class AudioBuffersTests: XCTestCase {
    private let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    func testTheTapsStreamIsCopiedWhenASubDevicesInputComesFirst() throws {
        // An aggregate with an input-capable sub-device lists that device's
        // stream before the tap's, as measured on macOS 26.6.
        let microphone = [Float](repeating: 0.9, count: 4)
        let tap: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        let copy = try withBufferList([(1, microphone), (2, tap)]) { list in
            try XCTUnwrap(AVAudioPCMBuffer.copying(list, format: tapFormat))
        }

        XCTAssertEqual(copy.frameLength, 4)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: copy.floatChannelData![0], count: 8)), tap)
    }

    func testABufferThatDoesNotMatchTheTapFormatIsRefused() throws {
        let mono = try withBufferList([(1, [Float](repeating: 0.5, count: 4))]) { list in
            AVAudioPCMBuffer.copying(list, format: tapFormat)
        }
        let ragged = try withBufferList([(2, [Float](repeating: 0.5, count: 7))]) { list in
            AVAudioPCMBuffer.copying(list, format: tapFormat)
        }

        XCTAssertNil(mono)
        XCTAssertNil(ragged)
    }

    func testDroppingFramesKeepsTheTail() throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: 4))
        buffer.frameLength = 4
        for index in 0..<8 { buffer.floatChannelData![0][index] = Float(index) }

        let tail = try XCTUnwrap(buffer.dropping(frames: 3))

        XCTAssertEqual(tail.frameLength, 1)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: tail.floatChannelData![0], count: 2)), [6, 7])
        XCTAssertNil(buffer.dropping(frames: 4))
    }

    func testOnlyARealChangeOfLayoutCountsAsANewFormat() throws {
        var stereo = tapFormat.streamDescription.pointee
        let withLayout = AVAudioFormat(streamDescription: &stereo, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!)
        let sameWithLayout = try XCTUnwrap(withLayout)
        let slower = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true))
        let int16 = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))

        XCTAssertTrue(tapFormat.hasSameLayout(as: sameWithLayout))
        XCTAssertFalse(tapFormat.hasSameLayout(as: slower))
        XCTAssertFalse(tapFormat.hasSameLayout(as: int16))
    }

    /// An AudioBufferList like an IO callback's, one buffer per entry.
    private func withBufferList<T>(_ buffers: [(channels: UInt32, samples: [Float])], _ body: (UnsafePointer<AudioBufferList>) throws -> T) rethrows -> T {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        let samples = buffers.map { buffer in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: buffer.samples.count)
            pointer.initialize(from: buffer.samples, count: buffer.samples.count)
            return pointer
        }
        defer {
            samples.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, buffer) in buffers.enumerated() {
            list[index] = AudioBuffer(mNumberChannels: buffer.channels,
                                      mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                                      mData: samples[index])
        }
        return try body(UnsafePointer(list.unsafePointer))
    }
}
