import CoreAudio
import XCTest
@testable import MeetingArchiveApp

final class AudioPropertyListenerTests: XCTestCase {
    func testACancelledOrReleasedListenerHearsNothingMore() throws {
        let queue = DispatchQueue(label: "audio-property-listener-test")
        let cancelled = Tally(), released = Tally(), kept = Tally()
        let first = try AudioPropertyListener(kAudioHardwarePropertyDevices, of: AudioHAL.system, queue: queue) { cancelled.add() }
        first.cancel()
        do {
            // Dropped without a cancel, so only deinit removes it.
            _ = try AudioPropertyListener(kAudioHardwarePropertyDevices, of: AudioHAL.system, queue: queue) { released.add() }
        }
        let listener = try AudioPropertyListener(kAudioHardwarePropertyDevices, of: AudioHAL.system, queue: queue) { kept.add() }
        defer { listener.cancel() }

        // A private, empty aggregate device changes the device list without
        // touching any hardware, and disappears with this process.
        var device = AudioObjectID(kAudioObjectUnknown)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Archive listener test",
            kAudioAggregateDeviceUIDKey: "com.mikerosoft.meeting-archive.listener-test.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        try XCTSkipUnless(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device) == noErr,
                          "This machine cannot create a private aggregate device.")
        AudioHardwareDestroyAggregateDevice(device)
        let deadline = Date().addingTimeInterval(2)
        while kept.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try XCTSkipIf(kept.value == 0, "This machine sent no device list notification.")
        // Every listener for the property hears the same change, so a stale
        // one would have fired by now.
        Thread.sleep(forTimeInterval: 0.2)
        queue.sync {}

        XCTAssertEqual(cancelled.value, 0)
        XCTAssertEqual(released.value, 0)
    }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
