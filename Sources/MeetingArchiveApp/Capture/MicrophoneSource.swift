import AVFoundation
import CoreAudio
import Foundation

/// The system default input, recorded through AVCaptureSession with no voice
/// processing, so the track is the microphone as it is. It follows the
/// default: when the default input changes or the device disappears, the
/// session is rebuilt on whatever is default now, and the writer fills the
/// hole with silence. A microphone that stops delivering (the Yeti stalls) is
/// restarted by the watchdog.
final class MicrophoneSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Device changes arrive in bursts (connecting AirPods changes the default
    /// input and output), so a rebuild waits for them to settle.
    static let settleDelay: TimeInterval = 0.3

    var onWarning: (@Sendable (String) -> Void)?

    /// The device of the newest session, kept after it closes.
    var device: CapturedMicrophone? { lock.withLock { lastDevice } }

    private let writer: AudioTrackWriter
    private let control = DispatchQueue(label: "com.mikerosoft.meeting-archive.microphone")
    private let delivery = DispatchQueue(label: "com.mikerosoft.meeting-archive.microphone.samples", qos: .userInteractive)
    private let clock = DeliveryClock()
    private let lock = NSLock()
    // Guarded by `lock`; sample buffers from any other output are stale.
    private var liveOutput: AVCaptureAudioDataOutput?
    private var lastDevice: CapturedMicrophone?
    // Everything below belongs to `control`.
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private var defaultInputListener: AudioPropertyListener?
    private var watchdog = SourceWatchdog()
    private var stopped = false
    private var rebuildPending = false

    init(writer: AudioTrackWriter) {
        self.writer = writer
        super.init()
    }

    /// Returns why the microphone could not start, if it could not. It keeps
    /// following the default input and retrying either way, until `stop`.
    func start() async -> Error? {
        // Only asks when macOS has never asked; the signed app already has access.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return await withCheckedContinuation { continuation in
            control.async {
                // A stop that overtook a slow start must not be undone by it.
                guard !self.stopped else {
                    continuation.resume(returning: CaptureFailure.message("The recording stopped before the microphone started."))
                    return
                }
                self.clock.mark()
                self.followDefaultInput()
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
                self.warn("The microphone is back after \(Int(after.rounded())) s without audio.")
            case .restart(let quietFor, let newOutage):
                let error = self.open()
                if newOutage {
                    self.warn(error.map { "The microphone stopped sending audio and could not restart (\($0.localizedDescription)). Trying again every 10 s." }
                        ?? "The microphone stopped sending audio for \(Int(quietFor)) s, so it was restarted.")
                } else if let error {
                    Log.capture.error("Microphone retry failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            control.async {
                self.stopped = true
                self.defaultInputListener?.cancel()
                self.defaultInputListener = nil
                self.closeSession()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard lock.withLock({ output === liveOutput }) else { return }
        clock.mark()
        // AVCaptureSession stamps audio on the host clock, the same clock as
        // the recording's origin and the tap's timestamps.
        writer.append(sampleBuffer)
    }

    // MARK: - Sessions

    /// Opens a session on the current default input, replacing any open one.
    private func open() -> Error? {
        closeSession()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return CaptureFailure.message("Microphone access is off for Meeting Archive. Turn it on in System Settings, Privacy & Security, Microphone.")
        }
        guard let device = Self.defaultDevice() else {
            return CaptureFailure.message("No microphone is connected.")
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw CaptureFailure.message("\(device.localizedName) cannot be recorded.")
            }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            return error
        }
        output.setSampleBufferDelegate(self, queue: delivery)
        lock.withLock { liveOutput = output }
        self.session = session
        observe(session, device: device)
        session.startRunning()
        guard session.isRunning else {
            closeSession()
            return CaptureFailure.message("\(device.localizedName) did not start.")
        }
        lock.withLock { lastDevice = CapturedMicrophone(uid: device.uniqueID, name: device.localizedName) }
        Log.capture.notice("Microphone capture started on \(device.localizedName, privacy: .public)")
        return nil
    }

    private func closeSession() {
        lock.withLock { liveOutput = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let session else { return }
        self.session = nil
        session.stopRunning()
    }

    /// Core Audio's default input is the device the user picked. Its capture
    /// device has the same unique ID.
    private static func defaultDevice() -> AVCaptureDevice? {
        if let uid = try? AudioHAL.deviceUID(AudioHAL.defaultInputDevice()), let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func observe(_ session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        let name = device.localizedName
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                self?.scheduleRebuild("The microphone stopped with an error")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.scheduleRebuild("\(name) was disconnected")
            },
        ]
    }

    private func followDefaultInput() {
        do {
            defaultInputListener = try AudioPropertyListener(kAudioHardwarePropertyDefaultInputDevice, of: AudioHAL.system, queue: control) { [weak self] in
                self?.defaultInputChanged()
            }
        } catch {
            Log.capture.error("Cannot follow the default microphone: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func defaultInputChanged() {
        guard !stopped else { return }
        if session?.isRunning == true, let uid = try? AudioHAL.deviceUID(AudioHAL.defaultInputDevice()), uid == device?.uid {
            return
        }
        scheduleRebuild("The default microphone changed")
    }

    private func scheduleRebuild(_ reason: String) {
        control.async {
            guard !self.stopped, !self.rebuildPending else { return }
            self.rebuildPending = true
            self.control.asyncAfter(deadline: .now() + Self.settleDelay) {
                self.rebuildPending = false
                guard !self.stopped else { return }
                if let error = self.open() {
                    // Reported here, so the watchdog's retries stay quiet.
                    self.watchdog.failedToStart(at: DeliveryClock.now)
                    self.warn("\(reason), and the microphone could not restart (\(error.localizedDescription)). Trying again every 10 s.")
                } else {
                    self.watchdog.restarted(at: DeliveryClock.now)
                    self.warn("\(reason), so recording continues from \(self.device?.name ?? "the default microphone").")
                }
            }
        }
    }

    private func warn(_ message: String) {
        Log.capture.notice("\(message, privacy: .public)")
        onWarning?(message)
    }
}
