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
        XCTAssertEqual(AudioHardwareDestroyAggregateDevice(device), noErr, "The test's aggregate device was not destroyed.")
        // The device list has changed for certain now, so a listener that
        // hears nothing is broken rather than on a quiet machine.
        let deadline = Date().addingTimeInterval(5)
        while kept.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertGreaterThan(kept.value, 0, "The listener that was kept heard no device list change.")
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
