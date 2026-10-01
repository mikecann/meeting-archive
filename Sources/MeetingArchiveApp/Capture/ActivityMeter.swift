import Accelerate
import AVFoundation

/// How much of a track has something in it. Audio is measured in fixed
/// 100 ms windows on the track's own timeline, and a window counts when its
/// loudest channel's RMS is above -50 dBFS. Room tone and a muted call sit well
/// below that; speech sits well above it. The controller uses the incoming
/// total to tell a real call from a one-sided recording.
struct ActivityMeter: Sendable {
    static let windowFrames = 4_800
    /// -50 dBFS as an RMS amplitude, where 1.0 is full scale.
    static let threshold = pow(10.0, -50.0 / 20.0)

    let sampleRate: Double
    let channels: Int
    private var sums: [Double]
    private var framesInWindow = 0
    private(set) var activeFrames: Int64 = 0

    init(sampleRate: Double = 48_000, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        sums = Array(repeating: 0, count: channels)
    }

    var activeSeconds: Double { Double(activeFrames) / sampleRate }

    /// Interleaved Float32 samples with this meter's channel count.
    mutating func add(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.format.isInterleaved || channels == 1,
              Int(buffer.format.channelCount) == channels else { return }
        let frames = Int(buffer.frameLength)
        var frame = 0
        while frame < frames {
            let take = min(frames - frame, Self.windowFrames - framesInWindow)
            for channel in 0..<channels {
                var sum: Float = 0
                vDSP_svesq(samples + frame * channels + channel, vDSP_Stride(channels), &sum, vDSP_Length(take))
                sums[channel] += Double(sum)
            }
            framesInWindow += take
            frame += take
            if framesInWindow == Self.windowFrames { closeWindow() }
        }
    }

    /// Silence only lengthens windows. Gaps can be minutes long, so this does
    /// not touch any samples.
    mutating func addSilence(frames: Int64) {
        var remaining = frames
        while remaining > 0 {
            let take = min(remaining, Int64(Self.windowFrames - framesInWindow))
            framesInWindow += Int(take)
            remaining -= take
            if framesInWindow == Self.windowFrames { closeWindow() }
        }
    }

    /// Counts a final partial window, so a short loud ending is not lost.
    mutating func finish() {
        if framesInWindow > 0 { closeWindow() }
    }

    private mutating func closeWindow() {
        let loudest = sums.map { ($0 / Double(framesInWindow)).squareRoot() }.max() ?? 0
        if loudest > Self.threshold { activeFrames += Int64(framesInWindow) }
        framesInWindow = 0
        for index in sums.indices { sums[index] = 0 }
    }
}
