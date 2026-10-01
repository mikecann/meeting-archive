import AVFoundation
import CoreMedia
import Foundation

/// One track of a recording: a single AAC file whose timeline never stretches
/// or shrinks. Every output sample sits at `origin + samplesWritten / 48 kHz`,
/// so the offsets in `tracks.json` stay true however often the source behind
/// the track restarts, pauses or changes device.
///
/// Input can arrive in any PCM format, and the format can change mid-recording
/// (a Yeti at 48 kHz stereo, then AirPods at 16 kHz mono). It is converted to
/// one fixed format before the encoder, and placed by its host-clock timestamp:
/// a chunk that starts noticeably late leaves a gap that is filled with
/// silence, one that starts noticeably early overlaps audio already written
/// and is trimmed, and anything closer is jitter and is appended as it comes.
/// AVAssetWriter itself would close any gap by sliding the later audio
/// earlier, which is exactly the drift this prevents.
///
/// Callers hand over buffers from capture callbacks and return straight away.
/// Conversion, metering and encoding all happen on this writer's queue.
final class AudioTrackWriter: @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// How far a chunk may land from where the track expects it before it
    /// counts as a gap or an overlap rather than jitter.
    static let tolerance = 0.05
    /// How long audio is held for an encoder that is not ready before it is
    /// replaced with silence, which keeps the timeline but bounds memory.
    static let encoderPatience: TimeInterval = 2
    /// How long `finish` waits for a busy encoder to take the last audio.
    static let finishPatience: TimeInterval = 5

    struct Summary: Sendable {
        var progress: TrackProgress?
        var activitySeconds: Double
        /// The loudest 100 ms window's RMS, 0 for pure silence.
        var peakLevel: Double = 0
        var error: Error?
    }

    let track: MediaTrack
    let url: URL
    let origin: CMTime
    /// The first audio reached the file. Called once.
    var onFirstSample: (@Sendable () -> Void)?
    var onWarning: (@Sendable (String) -> Void)?
    /// The file cannot continue, for example because the disk is full.
    /// Called once; nothing more is written after it.
    var onFailure: (@Sendable (Error) -> Void)?

    var hasSamples: Bool { lock.withLock { wroteSamples } }

    // Stand-ins for tests, set before the first append. The app leaves them
    // alone: the encoder says when it is busy, and stalls are timed by uptime.
    var encoderIsBusy: (@Sendable () -> Bool)?
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var wroteSamples = false
    private let format: AVAudioFormat
    private let bitRate: Int
    private let name: String
    private let originSeconds: Double
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var converter: AVAudioConverter?
    /// Host seconds where the current converter's input began, and how many
    /// input frames it has taken since. Expected times come from the input
    /// side, so the resampler's few held-back frames never look like drift.
    private var segmentStart = 0.0
    private var segmentFrames: Int64 = 0
    /// Output frames placed on the timeline, and how many of those the
    /// encoder has taken. The difference is waiting in `pending`.
    private var scheduledFrames: Int64 = 0
    private var writtenFrames: Int64 = 0
    private var pending: [Pending] = []
    private var silenceBuffer: AVAudioPCMBuffer?
    private var stalledSince: TimeInterval?
    private var silencedFrames: Int64 = 0
    private var meter: ActivityMeter
    private var timeline: CaptureTimeline
    private var failure: Error?
    private var finishing = false
    private var finishWaiters: [@Sendable (Summary) -> Void] = []
    private var finalSummary: Summary?
    private var warned = Set<String>()

    static func microphone(directory: URL, origin: CMTime) -> AudioTrackWriter {
        AudioTrackWriter(track: .microphone, url: directory.appendingPathComponent("microphone.m4a"),
                         channels: 1, bitRate: 96_000, name: "microphone", origin: origin)
    }

    static func incoming(directory: URL, origin: CMTime) -> AudioTrackWriter {
        AudioTrackWriter(track: .incoming, url: directory.appendingPathComponent("incoming.m4a"),
                         channels: 2, bitRate: 128_000, name: "system audio", origin: origin)
    }

    private init(track: MediaTrack, url: URL, channels: AVAudioChannelCount, bitRate: Int, name: String, origin: CMTime) {
        self.track = track
        self.url = url
        self.origin = origin
        self.bitRate = bitRate
        self.name = name
        originSeconds = origin.seconds
        // Interleaved Float32 is one buffer per chunk, which keeps the sample
        // buffers handed to the encoder simple.
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: channels, interleaved: true)!
        meter = ActivityMeter(sampleRate: Self.sampleRate, channels: Int(channels))
        timeline = CaptureTimeline(origin: origin.seconds)
        queue = DispatchQueue(label: "com.mikerosoft.meeting-archive.writer.\(track.rawValue)")
    }

    /// Takes ownership of `buffer`; the caller must not touch it again.
    /// `time` is the host-clock time of its first frame.
    func append(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        let chunk = Chunk(buffer: buffer, time: time)
        queue.async { self.process(chunk) }
    }

    /// Copies the samples out, so a capture callback can reuse its buffer.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let copy = AVAudioPCMBuffer.copying(sampleBuffer) else {
            queue.async { self.warnOnce("unreadable", "Some \(self.name) audio could not be read and was skipped.") }
            return
        }
        append(copy, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Writes what is left and closes the file. A track that never received
    /// audio leaves no file behind. Calling this again returns the same summary.
    func finish() async -> Summary {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finish { continuation.resume(returning: $0) }
            }
        }
    }

    /// Returns once everything appended so far has been handled.
    func sync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Placing input on the timeline

    private func process(_ chunk: Chunk) {
        guard failure == nil, !finishing else { return }
        let buffer = chunk.buffer
        let frames = Int64(buffer.frameLength)
        guard frames > 0 else { return }
        let rate = buffer.format.sampleRate
        let start: Double? = chunk.time.isNumeric ? chunk.time.seconds : nil
        if let converter, !converter.inputFormat.hasSameLayout(as: buffer.format) {
            // A new device or rate. Drain the old resampler so its last few
            // milliseconds are kept, then start again for the new format.
            endSegment()
        }
        var skip: Int64 = 0
        if converter != nil, let start {
            let drift = start - (segmentStart + Double(segmentFrames) / rate)
            if drift > Self.tolerance {
                endSegment()
            } else if drift < -Self.tolerance {
                skip = Int64((-drift * rate).rounded())
            }
        }
        if converter == nil {
            if let start {
                let offset = start - seconds(at: scheduledFrames)
                if offset > Self.tolerance {
                    // The first audio, or a source that came back after a
                    // restart. Silence keeps everything after it in place.
                    schedule(.silence(Int64((offset * Self.sampleRate).rounded())))
                } else if offset < -Self.tolerance {
                    skip = Int64((-offset * rate).rounded())
                }
            }
            guard skip < frames, failure == nil, beginSegment(for: buffer.format) else { return }
            segmentStart = seconds(at: scheduledFrames)
            segmentFrames = 0
        }
        // Audio this track already has, for example replayed by a restarted
        // source, is trimmed rather than written twice.
        guard skip < frames,
              let input = skip > 0 ? buffer.dropping(frames: AVAudioFrameCount(skip)) : buffer else { return }
        segmentFrames += frames - skip
        convert(input)
    }

    private func seconds(at frames: Int64) -> Double {
        originSeconds + Double(frames) / Self.sampleRate
    }

    private func beginSegment(for inputFormat: AVAudioFormat) -> Bool {
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            warnOnce("format \(Self.describe(inputFormat))",
                     "The \(name) sent audio as \(Self.describe(inputFormat)), which could not be converted, so it was skipped.")
            return false
        }
        // Without this a stereo microphone keeps only its left channel.
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        return true
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount((Double(input.frameLength) * Self.sampleRate / input.format.sampleRate).rounded(.up)) + 64
        var supplied = false
        while failure == nil {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if output.frameLength > 0 { schedule(.audio(output)) }
            switch status {
            case .haveData:
                continue
            case .error:
                // Start the next chunk with a fresh converter. If that leaves
                // a hole, it is filled with silence like any other gap.
                self.converter = nil
                warnOnce("conversion", "Some \(name) audio could not be converted: \(error?.localizedDescription ?? "unknown error").")
                return
            default:
                return
            }
        }
    }

    /// Drains the resampler's last frames into the track and drops it.
    private func endSegment() {
        guard let converter else { return }
        self.converter = nil
        while failure == nil {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0 { schedule(.audio(output)) }
            guard status == .haveData else { return }
        }
    }

    // MARK: - Encoding

    private func schedule(_ item: Pending) {
        guard item.frames > 0, failure == nil else { return }
        scheduledFrames += item.frames
        if case .silence(let more) = item, case .silence(let earlier)? = pending.last {
            pending[pending.count - 1] = .silence(earlier + more)
        } else {
            pending.append(item)
        }
        drain()
    }

    private func drain() {
        guard failure == nil, !pending.isEmpty, let input = openIfNeeded() else { return }
        while let item = pending.first {
            guard input.isReadyForMoreMediaData, encoderIsBusy?() != true else {
                encoderBusy()
                return
            }
            if stalledSince != nil {
                stalledSince = nil
                if silencedFrames > 0 {
                    Log.capture.notice("The \(self.name, privacy: .public) encoder caught up; \(Double(self.silencedFrames) / Self.sampleRate, privacy: .public)s of audio became silence")
                    silencedFrames = 0
                }
            }
            switch item {
            case .audio(let buffer):
                guard write(buffer, silent: false) else { return }
                pending.removeFirst()
            case .silence(let frames):
                // A second at a time, so a long gap never needs a long buffer.
                let count = min(frames, Int64(Self.sampleRate))
                guard let silence = silence(frames: AVAudioFrameCount(count)), write(silence, silent: true) else { return }
                if count == frames { pending.removeFirst() } else { pending[0] = .silence(frames - count) }
            }
        }
    }

    /// Real time means the encoder is almost always ready. When it is not,
    /// audio waits; after `encoderPatience` the backlog becomes silence of the
    /// same length, so the track keeps its place and memory stays bounded.
    private func encoderBusy() {
        let now = uptime()
        guard let since = stalledSince else {
            stalledSince = now
            return
        }
        guard now - since > Self.encoderPatience else { return }
        var replaced: [Pending] = []
        var dropped: Int64 = 0
        for item in pending {
            if case .audio = item { dropped += item.frames }
            if case .silence(let earlier)? = replaced.last {
                replaced[replaced.count - 1] = .silence(earlier + item.frames)
            } else {
                replaced.append(.silence(item.frames))
            }
        }
        pending = replaced
        guard dropped > 0 else { return }
        if silencedFrames == 0 {
            warn("The \(name) encoder fell behind, so some audio is being replaced with silence until it catches up.")
        }
        silencedFrames += dropped
    }

    private func write(_ buffer: AVAudioPCMBuffer, silent: Bool) -> Bool {
        guard let writer, let input else { return false }
        let time = CMTimeAdd(origin, CMTime(value: writtenFrames, timescale: CMTimeScale(Self.sampleRate)))
        guard let sample = buffer.sampleBuffer(at: time) else {
            fail(CaptureFailure.message("Could not prepare \(name) audio for the encoder."))
            return false
        }
        guard input.append(sample) else {
            fail(writer.error ?? CaptureFailure.message("The encoder refused \(name) audio."))
            return false
        }
        let frames = Int64(buffer.frameLength)
        if silent { meter.addSilence(frames: frames) } else { meter.add(buffer) }
        do {
            // Offsets are computed from the frame count, not the CMTime, so
            // the first one is exactly zero.
            try timeline.accept(track: track, timestamp: seconds(at: writtenFrames), duration: Double(frames) / Self.sampleRate)
        } catch {
            Log.capture.error("The \(self.name, privacy: .public) timeline refused a sample: \(error.localizedDescription, privacy: .public)")
        }
        writtenFrames += frames
        if writtenFrames == frames {
            lock.withLock { wroteSamples = true }
            onFirstSample?()
        }
        return true
    }

    private func silence(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if silenceBuffer == nil, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.sampleRate)) {
            buffer.frameLength = buffer.frameCapacity
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
            silenceBuffer = buffer
        }
        // The encoder copies the samples, so one zeroed buffer serves every gap.
        silenceBuffer?.frameLength = min(frames, AVAudioFrameCount(Self.sampleRate))
        return silenceBuffer
    }

    /// The writer starts with the first audio, not with the recording, so a
    /// source that never delivers leaves no empty file. The bundle refuses
    /// empty media files.
    private func openIfNeeded() -> AVAssetWriterInput? {
        if let input { return input }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: bitRate,
            ], sourceFormatHint: format.formatDescription)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureFailure.message("The \(name) encoder is unavailable.") }
            writer.add(input)
            // A crash then leaves a file that plays up to its last 2 s fragment.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            guard writer.startWriting() else {
                throw writer.error ?? CaptureFailure.message("Could not start \(url.lastPathComponent).")
            }
            writer.startSession(atSourceTime: origin)
            self.writer = writer
            self.input = input
            return input
        } catch {
            fail(error)
            return nil
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        let failure = CaptureFailure.message("\(url.lastPathComponent) could not be written: \(error.localizedDescription)")
        self.failure = failure
        pending.removeAll()
        converter = nil
        Log.capture.error("\(failure.localizedDescription, privacy: .public)")
        onFailure?(failure)
    }

    // MARK: - Finishing

    private func finish(_ completion: @escaping @Sendable (Summary) -> Void) {
        if let finalSummary {
            completion(finalSummary)
            return
        }
        finishWaiters.append(completion)
        guard !finishing else { return }
        finishing = true
        endSegment()
        drainForFinish(until: ProcessInfo.processInfo.systemUptime + Self.finishPatience)
    }

    private func drainForFinish(until deadline: TimeInterval) {
        drain()
        if failure == nil, !pending.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            queue.asyncAfter(deadline: .now() + .milliseconds(20)) { self.drainForFinish(until: deadline) }
            return
        }
        if !pending.isEmpty {
            let lost = Double(pending.reduce(0) { $0 + $1.frames }) / Self.sampleRate
            Log.capture.error("The \(self.name, privacy: .public) encoder never caught up; the last \(lost, privacy: .public)s were not written")
            pending.removeAll()
        }
        close()
    }

    private func close() {
        meter.finish()
        guard let writer, let input else { return complete() }
        guard writtenFrames > 0 else {
            // Nothing reached the file, so remove it rather than leave it empty.
            writer.cancelWriting()
            return complete()
        }
        guard writer.status == .writing else {
            // A failed writer keeps whatever fragments reached the disk.
            record(writer.error ?? CaptureFailure.message("\(url.lastPathComponent) stopped early."))
            return complete()
        }
        writer.endSession(atSourceTime: CMTimeAdd(origin, CMTime(value: writtenFrames, timescale: CMTimeScale(Self.sampleRate))))
        input.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                if let writer = self.writer, writer.status != .completed {
                    self.record(writer.error ?? CaptureFailure.message("\(self.url.lastPathComponent) could not be finalized."))
                }
                self.complete()
            }
        }
    }

    /// Errors at the end of a recording go into the summary. The recording is
    /// already stopping, so there is nothing for `onFailure` to interrupt.
    private func record(_ error: Error) {
        guard failure == nil else { return }
        failure = CaptureFailure.message("\(url.lastPathComponent) could not be finished: \(error.localizedDescription)")
        Log.capture.error("\(self.failure?.localizedDescription ?? "", privacy: .public)")
    }

    private func complete() {
        let summary = Summary(progress: timeline.tracks[track], activitySeconds: meter.activeSeconds, peakLevel: meter.peak, error: failure)
        finalSummary = summary
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter(summary) }
    }

    // MARK: - Messages

    private func warn(_ message: String) {
        Log.capture.notice("\(message, privacy: .public)")
        onWarning?(message)
    }

    private func warnOnce(_ key: String, _ message: String) {
        guard warned.insert(key).inserted else { return }
        warn(message)
    }

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz \(format.channelCount == 1 ? "mono" : "\(format.channelCount) channels")"
    }
}

/// A buffer on its way from a capture callback to the writer's queue. The
/// caller gives the buffer up, so nothing else touches it during the hop.
private struct Chunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: CMTime
}

private enum Pending {
    case audio(AVAudioPCMBuffer)
    case silence(Int64)

    var frames: Int64 {
        switch self {
        case .audio(let buffer): Int64(buffer.frameLength)
        case .silence(let frames): frames
        }
    }
}
