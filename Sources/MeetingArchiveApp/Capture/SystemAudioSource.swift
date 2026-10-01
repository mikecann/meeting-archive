import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Everything the Mac plays except Meeting Archive itself, from a Core Audio
/// process tap (macOS 14.2+) read through a private aggregate device.
///
/// The aggregate holds only the tap, as in Apple's tap documentation, rather
/// than also taking the default output device as its clock as AudioCap does.
/// Measured on macOS 26.6 with that sub-device:
/// - with `tapautostart` the callback never runs while nothing is playing,
///   which a no-callback watchdog cannot tell apart from a dead tap;
/// - clocked by a 44.1 kHz output, buffers arrive at 44.1 kHz while the tap
///   and its stream both still report 48 kHz;
/// - a sub-device's input streams come before the tap's in the aggregate, so a
///   headset output would have its microphone opened (AirPods drop to call
///   quality) and its audio would arrive in the first buffer.
/// A tap-only aggregate runs its callback continuously in the tap's own
/// format, whether or not anything is playing.
///
/// The tap is rebuilt when the default output changes device or rate, when
/// its format changes, and when its callback stops for 3 s. AirPods switching
/// to call mode is known to stop a tap silently until it is rebuilt.
final class SystemAudioSource: @unchecked Sendable {
    var onWarning: (@Sendable (String) -> Void)?

    private let writer: AudioTrackWriter
    private let control = DispatchQueue(label: "com.mikerosoft.meeting-archive.system-audio")
    /// Core Audio calls the IO block synchronously on this queue from its IO
    /// thread, so nothing else may ever run on it.
    private let io = DispatchQueue(label: "com.mikerosoft.meeting-archive.system-audio.io", qos: .userInteractive)
    private let clock = DeliveryClock()
    // Everything below belongs to `control`.
    private var tap: ProcessTap?
    private var outputListener: AudioPropertyListener?
    private var outputRateListener: AudioPropertyListener?
    private var watchdog = SourceWatchdog()
    private var stopped = false
    private var rebuildPending = false

    init(writer: AudioTrackWriter) {
        self.writer = writer
    }

    /// Returns why the tap could not start, if it could not. It keeps
    /// following the output and retrying either way, until `stop`.
    func start() async -> Error? {
        await withCheckedContinuation { continuation in
            control.async {
                // A stop that overtook a slow start must not be undone by it.
                guard !self.stopped else {
                    continuation.resume(returning: CaptureFailure.message("The recording stopped before system audio started."))
                    return
                }
                self.clock.mark()
                self.followDefaultOutput()
                let error = self.open()
                if error != nil { self.watchdog.failedToStart(at: DeliveryClock.now) }
                continuation.resume(returning: error)
            }
        }
    }

    func checkHealth() {
        control.async {
            guard !self.stopped else { return }
            switch self.watchdog.check(now: DeliveryClock.now, lastDelivery: self.clock.seconds) {
            case .healthy:
                break
            case .recovered(let after):
                self.warn("System audio is back after \(Int(after.rounded())) s without audio.")
            case .restart(let quietFor, let newOutage):
                let error = self.open()
                if newOutage {
                    self.warn(error.map { "System audio stopped arriving and the tap could not be rebuilt (\($0.localizedDescription)). Trying again every 10 s." }
                        ?? "System audio stopped arriving for \(Int(quietFor)) s, so the tap was rebuilt.")
                } else if let error {
                    Log.capture.error("System audio retry failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            control.async {
                self.stopped = true
                self.outputListener?.cancel()
                self.outputListener = nil
                self.outputRateListener?.cancel()
                self.outputRateListener = nil
                self.tap?.invalidate()
                self.tap = nil
                continuation.resume()
            }
        }
    }

    /// Builds a new tap, tearing down any current one first.
    private func open() -> Error? {
        tap?.invalidate()
        tap = nil
        do {
            tap = try ProcessTap.open(writer: writer, clock: clock, io: io, control: control) { [weak self] in
                self?.scheduleRebuild("The system audio format changed")
            }
            return nil
        } catch {
            return error
        }
    }

    private func followDefaultOutput() {
        do {
            outputListener = try AudioPropertyListener(kAudioHardwarePropertyDefaultOutputDevice, of: AudioHAL.system, queue: control) { [weak self] in
                self?.followOutputRate()
                self?.scheduleRebuild("The sound output changed")
            }
        } catch {
            Log.capture.error("Cannot follow the sound output: \(error.localizedDescription, privacy: .public)")
        }
        followOutputRate()
    }

    /// AirPods switching to call mode stay the same output device but change
    /// its rate, which is known to stop a tap silently. Rebuilding on the rate
    /// change saves waiting for the watchdog.
    private func followOutputRate() {
        outputRateListener?.cancel()
        outputRateListener = nil
        guard !stopped, let device = try? AudioHAL.defaultOutputDevice(), device != kAudioObjectUnknown else { return }
        do {
            outputRateListener = try AudioPropertyListener(kAudioDevicePropertyNominalSampleRate, of: device, queue: control) { [weak self] in
                self?.scheduleRebuild("The sound output changed mode")
            }
        } catch {
            Log.capture.error("Cannot follow the sound output's rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleRebuild(_ reason: String) {
        control.async {
            guard !self.stopped, !self.rebuildPending else { return }
            self.rebuildPending = true
            // Device changes arrive in bursts, so let them settle first.
            self.control.asyncAfter(deadline: .now() + MicrophoneSource.settleDelay) {
                self.rebuildPending = false
                guard !self.stopped else { return }
                if let error = self.open() {
                    // Reported here, so the watchdog's retries stay quiet.
                    self.watchdog.failedToStart(at: DeliveryClock.now)
                    self.warn("\(reason), and the system audio tap could not be rebuilt (\(error.localizedDescription)). Trying again every 10 s.")
                } else {
                    self.watchdog.restarted(at: DeliveryClock.now)
                    self.warn("\(reason), so the system audio tap was rebuilt.")
                }
            }
        }
    }

    private func warn(_ message: String) {
        Log.capture.notice("\(message, privacy: .public)")
        onWarning?(message)
    }
}

/// One tap with its private aggregate device and IO callback. It is never
/// repaired in place; any change builds a new one.
private final class ProcessTap {
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let procID: AudioDeviceIOProcID
    private let receiver: TapReceiver
    private var formatListener: AudioPropertyListener?
    private var invalidated = false

    private init(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID, receiver: TapReceiver) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
        self.receiver = receiver
    }

    static func open(writer: AudioTrackWriter, clock: DeliveryClock, io: DispatchQueue, control: DispatchQueue,
                     onFormatChange: @escaping @Sendable () -> Void) throws -> ProcessTap {
        // The HAL knows this process once it has touched Core Audio. If it
        // somehow does not, excluding nothing is fine: the app plays no audio.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioHAL.processObject(for: getpid()).map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Meeting Archive incoming audio"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try AudioHALError.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var receiver: TapReceiver?
        do {
            let tapFormat = try AudioHAL.value(kAudioTapPropertyFormat, of: tapID, initial: AudioStreamBasicDescription())
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Archive incoming audio",
                kAudioAggregateDeviceUIDKey: "com.mikerosoft.meeting-archive.incoming.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
                ],
            ]
            try AudioHALError.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                                    "Creating the system audio device")
            let format = try streamFormat(tap: tapFormat, aggregate: aggregateID)
            let tapReceiver = TapReceiver(format: format, writer: writer, clock: clock)
            receiver = tapReceiver
            try AudioHALError.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, io) { _, input, inputTime, _, _ in
                tapReceiver.receive(input, at: inputTime)
            }, "Creating the system audio callback")
            guard let procID else { throw AudioHALError(status: kAudioHardwareUnspecifiedError, operation: "Creating the system audio callback") }
            try AudioHALError.check(AudioDeviceStart(aggregateID, procID), "Starting system audio")
            let tap = ProcessTap(tapID: tapID, aggregateID: aggregateID, procID: procID, receiver: tapReceiver)
            do {
                tap.formatListener = try AudioPropertyListener(kAudioTapPropertyFormat, of: tapID, queue: control, handler: onFormatChange)
            } catch {
                // The watchdog still catches a tap that stops after a change.
                Log.capture.error("Cannot follow the system audio format: \(error.localizedDescription, privacy: .public)")
            }
            Log.capture.notice("System audio tap started: \(AudioTrackWriter.describe(format), privacy: .public)")
            return tap
        } catch {
            receiver?.close()
            teardown(tapID: tapID, aggregateID: aggregateID, procID: procID)
            throw error
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        receiver.close()
        formatListener?.cancel()
        formatListener = nil
        Self.teardown(tapID: tapID, aggregateID: aggregateID, procID: procID)
    }

    /// In this order: a device must stop before its callback is destroyed,
    /// and the aggregate must go before the tap it contains.
    private static func teardown(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID?) {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        AudioHardwareDestroyProcessTap(tapID)
    }

    /// The tap's format says what the samples are. The aggregate's rate says
    /// how fast they come: an aggregate clocked by a hardware device runs at
    /// that device's rate whatever the tap reports, so the aggregate wins. For
    /// a tap-only aggregate the two agree.
    private static func streamFormat(tap: AudioStreamBasicDescription, aggregate: AudioObjectID) throws -> AVAudioFormat {
        var stream = tap
        if let rate = try? AudioHAL.value(kAudioDevicePropertyNominalSampleRate, of: aggregate, initial: Float64(0)),
           rate > 0, rate != stream.mSampleRate {
            Log.capture.notice("System audio runs at \(rate, privacy: .public) Hz although the tap reports \(stream.mSampleRate, privacy: .public) Hz")
            stream.mSampleRate = rate
        }
        guard stream.mFormatID == kAudioFormatLinearPCM, let format = AVAudioFormat(streamDescription: &stream) else {
            throw CaptureFailure.message("System audio arrives in a format that cannot be recorded.")
        }
        return format
    }
}

/// All the IO callback touches. It runs on Core Audio's IO thread, so it only
/// copies the buffer, stamps it and hands it to the writer's queue.
private final class TapReceiver: @unchecked Sendable {
    private let format: AVAudioFormat
    private let writer: AudioTrackWriter
    private let clock: DeliveryClock
    private let isOpen = Atomic<Bool>(true)

    init(format: AVAudioFormat, writer: AudioTrackWriter, clock: DeliveryClock) {
        self.format = format
        self.writer = writer
        self.clock = clock
    }

    func receive(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        // A buffer that does not match the format is skipped without marking
        // a delivery, so a silent format change still trips the watchdog.
        guard isOpen.load(ordering: .relaxed), let buffer = AVAudioPCMBuffer.copying(input, format: format) else { return }
        clock.mark()
        let stamp = time.pointee
        let hostTime = stamp.mFlags.contains(.hostTimeValid)
            ? CMClockMakeHostTimeFromSystemUnits(stamp.mHostTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        writer.append(buffer, at: hostTime)
    }

    /// Late callbacks from a tap being torn down are dropped.
    func close() {
        isOpen.store(false, ordering: .relaxed)
    }
}
