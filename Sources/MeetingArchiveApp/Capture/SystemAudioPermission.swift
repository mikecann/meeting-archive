import CoreMedia
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
