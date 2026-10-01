import CoreAudio
import Foundation

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

/// A Core Audio property listener that can be removed again. The HAL removes
/// a listener block by identity, and Swift makes a new block each time a
/// closure is passed, so this keeps the one block it registered.
final class AudioPropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var registered = false

    init(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) throws {
        self.object = object
        self.queue = queue
        var address = AudioHAL.address(selector)
        self.address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = block
        try AudioHALError.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
                                "Listening for \(AudioHALError.code(selector))")
        registered = true
    }

    func cancel() {
        let wasRegistered = lock.withLock {
            defer { registered = false }
            return registered
        }
        guard wasRegistered else { return }
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { cancel() }
}
