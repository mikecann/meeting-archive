import Accelerate
import AVFoundation
import CoreMedia

/// Copies that let an audio callback return straight away. Capture hands over
/// buffers it reuses as soon as the callback ends, so the writer's queue must
/// get its own copy. These are plain memory copies with no conversion; the
/// writer's queue does the expensive work.
extension AVAudioPCMBuffer {
    /// A copy of a capture sample buffer's PCM, in the format it arrived in.
    static func copying(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: copy.mutableAudioBufferList
        ) == noErr else { return nil }
        return copy
    }

    /// A copy of the stream an IO callback received for `format`. In an
    /// aggregate device a tap's streams come after any sub-device's input
    /// streams, so the tap's buffers are the last ones in the list. Anything
    /// that does not match the format exactly is refused rather than guessed.
    static func copying(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let needed = format.isInterleaved ? 1 : Int(format.channelCount)
        guard bytesPerFrame > 0, source.count >= needed else { return nil }
        let first = source.count - needed
        let bytes = Int(source[first].mDataByteSize)
        guard bytes > 0, bytes % bytesPerFrame == 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes / bytesPerFrame)) else { return nil }
        copy.frameLength = AVAudioFrameCount(bytes / bytesPerFrame)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard target.count == needed else { return nil }
        for index in 0..<needed {
            let from = source[first + index]
            guard from.mNumberChannels == target[index].mNumberChannels, Int(from.mDataByteSize) == bytes,
                  let data = from.mData, let destination = target[index].mData else { return nil }
            memcpy(destination, data, bytes)
        }
        return copy
    }

    /// Every channel averaged into one Float32 channel at the same rate.
    /// AVAudioConverter's downmix has no rule for an unknown or discrete
    /// layout of more than two channels and can return silence, so a
    /// multichannel interface is mixed here instead.
    func averagedToMono() -> AVAudioPCMBuffer? {
        // Packed 24-bit or Float64 samples become Float32 first, same channels.
        if floatChannelData == nil, int16ChannelData == nil, int32ChannelData == nil {
            return asFloat32()?.averagedToMono()
        }
        let channels = Int(format.channelCount)
        let frames = vDSP_Length(frameLength)
        guard channels > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameLength),
              let sum = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = frameLength
        sum.update(repeating: 0, count: Int(frameLength))
        let stride = vDSP_Stride(format.isInterleaved ? channels : 1)
        var scratch = [Float](repeating: 0, count: Int(frameLength))
        for channel in 0..<channels {
            if let data = floatChannelData {
                vDSP_vadd(sum, 1, format.isInterleaved ? data[0] + channel : data[channel], stride, sum, 1, frames)
            } else if let data = int16ChannelData {
                vDSP_vflt16(format.isInterleaved ? data[0] + channel : data[channel], stride, &scratch, 1, frames)
                var scale = Float(1) / 32_768
                vDSP_vsma(scratch, 1, &scale, sum, 1, sum, 1, frames)
            } else if let data = int32ChannelData {
                vDSP_vflt32(format.isInterleaved ? data[0] + channel : data[channel], stride, &scratch, 1, frames)
                var scale = Float(1) / 2_147_483_648
                vDSP_vsma(scratch, 1, &scale, sum, 1, sum, 1, frames)
            }
        }
        var count = Float(channels)
        vDSP_vsdiv(sum, 1, &count, sum, 1, frames)
        return mono
    }

    private func asFloat32() -> AVAudioPCMBuffer? {
        let floatFormat = format.channelLayout.map {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: false, channelLayout: $0)
        } ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false)
        guard let floatFormat, let converter = AVAudioConverter(from: format, to: floatFormat),
              let converted = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frameLength) else { return nil }
        do { try converter.convert(to: converted, from: self) } catch { return nil }
        return converted.floatChannelData == nil ? nil : converted
    }

    /// The frames after the first `count`, as a new buffer.
    func dropping(frames count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count < frameLength,
              let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength - count) else { return nil }
        tail.frameLength = frameLength - count
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(tail.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let data = from.mData, let destination = to.mData else { return nil }
            memcpy(destination, data + Int(count) * bytesPerFrame, Int(tail.frameLength) * bytesPerFrame)
        }
        return tail
    }

    /// A sample buffer for an AVAssetWriterInput, stamped at `time`. The
    /// samples are copied, so this buffer can be reused afterwards.
    func sampleBuffer(at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: CMItemCount(frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: audioBufferList
        ) == noErr else { return nil }
        return sample
    }
}

extension AVAudioFormat {
    /// Same sample layout, ignoring channel layout tags. Two capture buffers
    /// from one device can carry equal data with differently built formats,
    /// and treating that as a device change would restart the resampler.
    func hasSameLayout(as other: AVAudioFormat) -> Bool {
        let a = streamDescription.pointee, b = other.streamDescription.pointee
        return a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }
}
