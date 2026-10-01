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
