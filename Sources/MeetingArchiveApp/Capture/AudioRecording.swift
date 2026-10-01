import AVFoundation
import CoreMedia
import Foundation

struct CapturedMicrophone: Codable, Equatable, Sendable {
    var uid: String
    var name: String
}

/// Stopping always yields the timeline and activity, even after an error, so
/// `tracks.json` and the keep-or-discard decision are never lost with it.
struct AudioRecordingResult: Sendable {
    /// Keyed "microphone" and "incoming", with offsets from the shared origin.
    /// Each file starts at the origin, so `firstOffset` is 0 for every track.
    var tracks: [String: TrackProgress]
    /// Per track, the seconds of 100 ms windows louder than -50 dBFS.
    var activitySeconds: [String: Double]
    /// Per track, the loudest 100 ms window's RMS. 0 is pure digital silence.
    var peakLevels: [String: Double] = [:]
    /// The last input device used.
    var microphone: CapturedMicrophone?
    /// The first error that stopped a file, if any.
    var error: Error?
}

/// One part of a meeting: `microphone.m4a` from the system default input and
/// `incoming.m4a` from a tap of everything the Mac plays. Both files share one
/// host-clock origin and keep their place on it through source restarts.
///
/// The two sources fail independently. One that cannot start, or stops
/// mid-recording, is retried by its watchdog while the other carries on, and
/// that is only ever a warning. `onFailure` means a file cannot be written,
/// so this part cannot continue. Each instance records once: start, then stop.
final class AudioRecording: @unchecked Sendable {
    /// The first audio reached either file. Called once.
    var onStarted: (@Sendable () -> Void)?
    /// A file cannot continue, for example because the disk is full. Called once.
    var onFailure: (@Sendable (String) -> Void)?
    /// A source restarted, could not start, or went quiet. Informational.
    var onWarning: (@Sendable (String) -> Void)?

    var hasCapturedSamples: Bool {
        lock.withLock { writers }.contains { $0.hasSamples }
    }

    private enum Phase { case idle, starting, running, stopped }

    private let lock = NSLock()
    private var phase = Phase.idle
    private var writers: [AudioTrackWriter] = []
    private var microphone: MicrophoneSource?
    private var systemAudio: SystemAudioSource?
    private var announcedStart = false
    private var failure: Error?

    /// Creates the directory and starts both sources. Throws only when
    /// neither can start; otherwise a source that could not start is a warning.
    /// A `stop` while this is still starting wins, and this returns quietly.
    func start(directory: URL) async throws {
        let previous = lock.withLock {
            defer { if phase == .idle { phase = .starting } }
            return phase
        }
        switch previous {
        case .idle: break
        case .stopped: return
        case .starting, .running: throw CaptureFailure.message("This recording has already been started.")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            lock.withLock { phase = .stopped }
            throw error
        }
        // One origin for both files, so tracks.json offsets mean what they did in v1.
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        let microphoneWriter = AudioTrackWriter.microphone(directory: directory, origin: origin)
        let incomingWriter = AudioTrackWriter.incoming(directory: directory, origin: origin)
        for writer in [microphoneWriter, incomingWriter] {
            writer.onFirstSample = { [weak self] in self?.announceStart() }
            writer.onWarning = { [weak self] in self?.warn($0) }
            writer.onFailure = { [weak self] in self?.fail($0) }
        }
        let microphone = MicrophoneSource(writer: microphoneWriter)
        let systemAudio = SystemAudioSource(writer: incomingWriter)
        microphone.onWarning = { [weak self] in self?.warn($0) }
        systemAudio.onWarning = { [weak self] in self?.warn($0) }
        // Stored before starting, so a stop from here on finds and stops them.
        let stillStarting = lock.withLock {
            guard phase == .starting else { return false }
            writers = [microphoneWriter, incomingWriter]
            self.microphone = microphone
            self.systemAudio = systemAudio
            return true
        }
        guard stillStarting else { return }
        Log.capture.notice("Starting audio recording in \(directory.lastPathComponent, privacy: .public)")
        async let microphoneError = microphone.start()
        async let systemAudioError = systemAudio.start()
        let errors = await (microphoneError, systemAudioError)
        // A stop during start wins, and what the sources said is moot.
        guard lock.withLock({ phase == .starting }) else { return }
        switch errors {
        case (nil, nil):
            break
        case let (microphoneFailure?, systemAudioFailure?):
            await microphone.stop()
            await systemAudio.stop()
            _ = await microphoneWriter.finish()
            _ = await incomingWriter.finish()
            lock.withLock { phase = .stopped }
            throw CaptureFailure.message("Neither the microphone nor system audio could start. "
                + "Microphone: \(microphoneFailure.localizedDescription) System audio: \(systemAudioFailure.localizedDescription)")
        case let (microphoneFailure?, nil):
            warn("The microphone could not start (\(microphoneFailure.localizedDescription)). Recording system audio, and trying the microphone again every 10 s.")
        case let (nil, systemAudioFailure?):
            warn("System audio could not start (\(systemAudioFailure.localizedDescription)). Recording the microphone, and trying system audio again every 10 s.")
        }
        lock.withLock { if phase == .starting { phase = .running } }
    }

    /// The controller calls this every second to run the sources' watchdogs.
    func checkHealth() {
        let sources = lock.withLock { phase == .running ? (microphone, systemAudio) : (nil, nil) }
        sources.0?.checkHealth()
        sources.1?.checkHealth()
    }

    func stop() async -> AudioRecordingResult {
        let (microphone, systemAudio, writers) = lock.withLock {
            phase = .stopped
            return (self.microphone, self.systemAudio, self.writers)
        }
        // Sources first, so nothing new reaches the writers while they close.
        await microphone?.stop()
        await systemAudio?.stop()
        let summaries = await withTaskGroup(of: (MediaTrack, AudioTrackWriter.Summary).self) { group in
            for writer in writers {
                group.addTask { (writer.track, await writer.finish()) }
            }
            var summaries: [MediaTrack: AudioTrackWriter.Summary] = [:]
            for await (track, summary) in group { summaries[track] = summary }
            return summaries
        }
        var tracks: [String: TrackProgress] = [:]
        var activity: [String: Double] = [:]
        var peaks: [String: Double] = [:]
        for (track, summary) in summaries {
            activity[track.rawValue] = summary.activitySeconds
            peaks[track.rawValue] = summary.peakLevel
            if let progress = summary.progress { tracks[track.rawValue] = progress }
        }
        let finishError = [MediaTrack.microphone, .incoming].lazy.compactMap { summaries[$0]?.error }.first
        let error = lock.withLock { failure } ?? finishError
        let result = AudioRecordingResult(tracks: tracks, activitySeconds: activity, peakLevels: peaks, microphone: microphone?.device, error: error)
        Log.capture.notice("Audio recording stopped; tracks: \(tracks.keys.sorted().joined(separator: ","), privacy: .public); activity: \(activity.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value))s" }.joined(separator: ", "), privacy: .public); error: \(error?.localizedDescription ?? "none", privacy: .public)")
        return result
    }

    private func announceStart() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !announcedStart else { return nil }
            announcedStart = true
            return onStarted
        }
        callback?()
    }

    private func fail(_ error: Error) {
        let callback = lock.withLock { () -> (@Sendable (String) -> Void)? in
            guard failure == nil else { return nil }
            failure = error
            // A file that fails while stopping goes into the result instead.
            return phase == .stopped ? nil : onFailure
        }
        callback?(error.localizedDescription)
    }

    private func warn(_ message: String) {
        lock.withLock { onWarning }?(message)
    }
}
