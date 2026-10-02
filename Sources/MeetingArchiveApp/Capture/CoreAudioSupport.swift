import CoreAudio
import Foundation
import Synchronization

/// Typed reads of Core Audio hardware (HAL) properties.
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size value, such as an object ID, a sample rate or a stream format.
    static func value<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, initial: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try AudioHALError.check(status, "Reading \(AudioHALError.code(selector))")
        return value
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try AudioHALError.check(status, "Reading \(AudioHALError.code(selector))")
        guard let value else { throw AudioHALError(status: kAudioHardwareUnspecifiedError, operation: "Reading \(AudioHALError.code(selector))") }
        return value.takeRetainedValue() as String
    }

    static func defaultInputDevice() throws -> AudioObjectID {
        try value(kAudioHardwarePropertyDefaultInputDevice, of: system, initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try value(kAudioHardwarePropertyDefaultOutputDevice, of: system, initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        try string(kAudioDevicePropertyDeviceUID, of: device)
    }

    /// The HAL's object for a process, or nil if it has none.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

struct AudioHALError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? { "\(operation) failed with Core Audio error \(Self.code(UInt32(bitPattern: status)))." }

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw AudioHALError(status: status, operation: operation()) }
    }

    /// Core Audio codes are mostly four characters, such as 'who?' or '!dev'.
    static func code(_ value: UInt32) -> String {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(Int32(bitPattern: value))" }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}

/// A Core Audio property listener that can be removed again. It uses the
/// function-pointer API: removing a Swift listener block never matched the
/// block that was added, even a stored one, so cancelled listeners kept
/// firing (measured on macOS 26.6), and the remove call still succeeded.
///
/// Core Audio is handed a number that is never reused rather than a pointer,
/// and the callback looks it up among the live listeners. A notification
/// that arrives after `cancel`, even from a registration Core Audio failed
/// to remove, finds nothing instead of freed memory.
final class AudioPropertyListener: @unchecked Sendable {
    /// What the shared C callback finds for a live listener's number.
    fileprivate final class Target: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: @Sendable () -> Void
        let isLive = Atomic<Bool>(true)

        init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
            self.queue = queue
            self.handler = handler
        }
    }

    fileprivate static let live = Mutex<[UInt: Target]>([:])
    private static let lastToken = Atomic<UInt>(0)

    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let token: UInt
    private let target: Target

    init(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) throws {
        self.object = object
        address = AudioHAL.address(selector)
        let target = Target(queue: queue, handler: handler)
        let token = Self.lastToken.wrappingAdd(1, ordering: .relaxed).newValue
        self.target = target
        self.token = token
        Self.live.withLock { $0[token] = target }
        var address = address
        let status = AudioObjectAddPropertyListener(object, &address, audioPropertyChanged, Self.context(token))
        guard status == noErr else {
            Self.live.withLock { $0[token] = nil }
            throw AudioHALError(status: status, operation: "Listening for \(AudioHALError.code(selector))")
        }
    }

    func cancel() {
        // Only the first cancel still finds the listener live.
        guard Self.live.withLock({ $0.removeValue(forKey: token) }) != nil else { return }
        target.isLive.store(false, ordering: .relaxed)
        var address = address
        AudioObjectRemovePropertyListener(object, &address, audioPropertyChanged, Self.context(token))
    }

    deinit { cancel() }

    fileprivate static func context(_ token: UInt) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: token)
    }
}

/// The one callback every listener shares. Core Audio calls it on its own
/// notification thread, where a brief lock is fine, and it only hops to the
/// listener's queue.
private func audioPropertyChanged(_ object: AudioObjectID, _ count: UInt32,
                                  _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                  _ context: UnsafeMutableRawPointer?) -> OSStatus {
    let token = UInt(bitPattern: context)
    guard let target = AudioPropertyListener.live.withLock({ $0[token] }) else { return noErr }
    // A cancel between the lookup and the hop is caught on the queue.
    target.queue.async {
        if target.isLive.load(ordering: .relaxed) { target.handler() }
    }
    return noErr
}
