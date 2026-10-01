import CoreMedia
import Darwin
import Foundation

/// macOS asks for System Audio Recording the first time a tap is read, and
/// offers no way to ask or check beforehand. A second of throwaway recording
/// brings that prompt up from Settings instead of in the middle of a call.
enum SystemAudioPermission {
    static func request() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-archive-permission-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Log.capture.error("Could not prepare the system audio check: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AudioTrackWriter.incoming(directory: directory, origin: CMClockGetTime(CMClockGetHostTimeClock()))
        let source = SystemAudioSource(writer: writer)
        if let error = await source.start() {
            Log.capture.error("System audio check could not start: \(error.localizedDescription, privacy: .public)")
        }
        try? await Task.sleep(for: .seconds(1))
        await source.stop()
        _ = await writer.finish()
    }
}

extension SystemAudioPermission {
    /// macOS has no public way to read this permission. TCC's own preflight
    /// call answers it, the same way AudioCap does. It is private, so it is
    /// looked up at runtime, and nil means the answer isn't available.
    static func status() -> AppSystemAuthorizationStatus? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        let preflight = unsafeBitCast(symbol, to: Preflight.self)
        return status(preflightResult: preflight("kTCCServiceAudioCapture" as CFString, nil))
    }

    static func status(preflightResult: Int32) -> AppSystemAuthorizationStatus {
        switch preflightResult {
        case 0: .granted
        case 1: .denied
        default: .notDetermined
        }
    }
}
