import CoreAudio
import Darwin
import Foundation
import MeetingArchiveCore

struct MicUsageSnapshot: Equatable, Sendable {
    /// Apps holding the mic, in the order each one took it, without ignored apps.
    var users: [MicUser]
    /// Ignored apps holding the mic, in the same order.
    var ignored: [MicUser]
    /// Set when Core Audio could not be read. Both lists are empty then, which
    /// does not mean everyone let go of the mic.
    var error: String?
}

/// A process capturing audio input, as Core Audio reports it.
struct AudioInputProcess: Equatable, Sendable {
    var pid: pid_t
    /// The process's own bundle ID, which for a helper is the helper's.
    var bundleID: String?
    var executablePath: String?
    /// Nil when Core Audio couldn't say whether it is capturing.
    var isRunningInput: Bool? = true
}

@MainActor
protocol AudioInputReading {
    /// Whether any input device is running in some process, or nil if it can't tell.
    func anyInputDeviceRunning() -> Bool?
    /// Every process capturing input right now, plus any that Core Audio
    /// couldn't say about.
    func runningInputProcesses() throws -> [AudioInputProcess]
}

/// Reports which apps are using the microphone. Reading this needs no
/// permission. Per-process listeners are reported not to fire reliably, so the
/// controller polls `snapshot()` once a second instead.
@MainActor
final class MicActivityMonitor {
    private let ignoredBundleIDs: @MainActor () -> Set<String>
    private let ownPID: pid_t
    private let reader: any AudioInputReading
    private let resolve: @MainActor (AudioInputProcess) -> MicUser?
    private let fullScanInterval: Int
    /// Bundle IDs of the apps holding the mic, in the order they took it.
    private var holdOrder: [String] = []
    /// Processes capturing at the last scan. One that Core Audio can't read
    /// keeps doing what it was, so a failed read is never an app letting go
    /// of the mic, nor taking it.
    private var capturingPIDs: Set<pid_t> = []
    private var scanEveryPoll = true
    private var pollsSinceScan = 0

    convenience init(
        ignoredBundleIDs: @escaping @MainActor () -> Set<String> = { MicAppResolver.defaultIgnoredBundleIDs },
        ownPID: pid_t = getpid()
    ) {
        self.init(
            ignoredBundleIDs: ignoredBundleIDs,
            ownPID: ownPID,
            reader: CoreAudioInputReader(),
            resolve: { MicAppResolver.owningApp(processBundleID: $0.bundleID, executablePath: $0.executablePath, pid: $0.pid) }
        )
    }

    init(
        ignoredBundleIDs: @escaping @MainActor () -> Set<String>,
        ownPID: pid_t,
        reader: any AudioInputReading,
        resolve: @escaping @MainActor (AudioInputProcess) -> MicUser?,
        fullScanInterval: Int = 5
    ) {
        self.ignoredBundleIDs = ignoredBundleIDs
        self.ownPID = ownPID
        self.reader = reader
        self.resolve = resolve
        self.fullScanInterval = fullScanInterval
    }

    func snapshot() -> MicUsageSnapshot {
        guard shouldScan() else { return MicUsageSnapshot(users: [], ignored: [], error: nil) }

        let processes: [AudioInputProcess]
        do {
            processes = try reader.runningInputProcesses()
        } catch {
            scanEveryPoll = true
            return MicUsageSnapshot(users: [], ignored: [], error: String(describing: error))
        }
        pollsSinceScan = 0
        let capturing = processes.filter { $0.isRunningInput ?? capturingPIDs.contains($0.pid) }
        capturingPIDs = Set(capturing.map(\.pid))

        var owners: [MicUser] = []
        for process in capturing where process.pid != ownPID {
            guard let owner = resolve(process),
                  !owners.contains(where: { $0.bundleIdentifier == owner.bundleIdentifier }) else { continue }
            owners.append(owner)
        }
        scanEveryPoll = !owners.isEmpty

        let present = Set(owners.map(\.bundleIdentifier))
        holdOrder.removeAll { !present.contains($0) }
        holdOrder += owners.map(\.bundleIdentifier).filter { !holdOrder.contains($0) }
        let rank = Dictionary(uniqueKeysWithValues: holdOrder.enumerated().map { ($1, $0) })
        owners.sort { rank[$0.bundleIdentifier, default: .max] < rank[$1.bundleIdentifier, default: .max] }

        let ignored = Set(ignoredBundleIDs().map { $0.lowercased() })
        let isIgnored = { (user: MicUser) in ignored.contains(user.bundleIdentifier.lowercased()) }
        return MicUsageSnapshot(users: owners.filter { !isIgnored($0) }, ignored: owners.filter(isIgnored), error: nil)
    }

    /// Checking a process costs a round trip to coreaudiod. A scan of the 45
    /// audio clients on Mike's Mac takes 12 to 15 ms, or 22 to 25 ms while
    /// something is capturing, so a poll first asks whether any input device
    /// is running, which takes under a millisecond. Every poll scans while an
    /// app holds the mic, and every few polls scan anyway in case a device
    /// never reports running. Bluetooth mics reportedly don't, which would
    /// otherwise miss AirPods calls.
    private func shouldScan() -> Bool {
        pollsSinceScan += 1
        if scanEveryPoll || pollsSinceScan >= fullScanInterval { return true }
        return reader.anyInputDeviceRunning() != false
    }
}

/// Reads input activity from the Core Audio process objects (macOS 14 and later).
struct CoreAudioInputReader: AudioInputReading {
    func anyInputDeviceRunning() -> Bool? {
        guard let devices = try? CoreAudioProperty.objectIDs(kAudioHardwarePropertyDevices, of: AudioObjectID(kAudioObjectSystemObject)) else {
            return nil
        }
        for device in devices where CoreAudioProperty.hasInputStreams(device) {
            guard let running = try? CoreAudioProperty.uint32(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device) else { return nil }
            if running != 0 { return true }
        }
        return false
    }

    func runningInputProcesses() throws -> [AudioInputProcess] {
        let objects = try CoreAudioProperty.objectIDs(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID(kAudioObjectSystemObject))
        return objects.compactMap { object in
            // A failed read is reported as unknown, not as letting go. A
            // process that quits between the list and these reads is skipped,
            // since its PID can't be read either.
            let isRunning = (try? CoreAudioProperty.uint32(kAudioProcessPropertyIsRunningInput, of: object)).map { $0 != 0 }
            guard isRunning != false, let pid = try? CoreAudioProperty.pid(of: object) else { return nil }
            let bundleID = try? CoreAudioProperty.string(kAudioProcessPropertyBundleID, of: object)
            return AudioInputProcess(
                pid: pid,
                bundleID: bundleID?.isEmpty == false ? bundleID : nil,
                executablePath: MicAppResolver.executablePath(ofPID: pid),
                isRunningInput: isRunning
            )
        }
    }
}

struct CoreAudioReadError: Error, CustomStringConvertible {
    var selector: AudioObjectPropertySelector
    var status: OSStatus

    var description: String {
        "Couldn't read \(Self.fourCharacters(selector)) from Core Audio (\(Self.fourCharacters(UInt32(bitPattern: status))))"
    }

    private static func fourCharacters(_ value: UInt32) -> String {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(Int32(bitPattern: value)) }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}

private enum CoreAudioProperty {
    static func objectIDs(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> [AudioObjectID] {
        var address = globalAddress(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), selector)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids), selector)
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func uint32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> UInt32 {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), selector)
        return value
    }

    static func pid(of object: AudioObjectID) throws -> pid_t {
        var address = globalAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), kAudioProcessPropertyPID)
        return value
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        try check(status, selector)
        return value?.takeRetainedValue() as String?
    }

    static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ selector: AudioObjectPropertySelector) throws {
        guard status == noErr else { throw CoreAudioReadError(selector: selector, status: status) }
    }
}
