import Foundation
import AVFoundation
import CoreMedia

/// Turns whatever audio we get (ReplayKit sample buffers, mic taps) into mono Float32 buffers.
enum AudioConvert {

    /// ReplayKit app audio arrives as interleaved Int16, sometimes big-endian. Parse it by hand.
    static func monoBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0 else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let bytesPerSample = max(bits / 8, 1)
        guard bits == 16 || bits == 32 else { return nil }

        let maxBuffers = isNonInterleaved ? channels : 1
        let bufferList = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(bufferList.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maxBuffers),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: asbd.mSampleRate,
                                         channels: 1,
                                         interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0] else { return nil }

        func sample(_ base: UnsafeRawPointer, _ index: Int) -> Float {
            if bits == 16 {
                var raw = base.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                if isBigEndian { raw = UInt16(bigEndian: raw) }
                return Float(Int16(bitPattern: raw)) / 32768.0
            }
            var raw = base.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
            if isBigEndian { raw = UInt32(bigEndian: raw) }
            if isFloat { return Float(bitPattern: raw) }
            return Float(Int32(bitPattern: raw)) / 2147483648.0
        }

        var written = 0
        withExtendedLifetime(blockBuffer) {
            if isNonInterleaved {
                let count = min(bufferList.count, channels)
                guard count > 0 else { return }
                for i in 0..<frames { destination[i] = 0 }
                var usable = frames
                for c in 0..<count {
                    guard let data = bufferList[c].mData else { continue }
                    let available = Int(bufferList[c].mDataByteSize) / bytesPerSample
                    let n = min(frames, available)
                    usable = min(usable, n)
                    let base = UnsafeRawPointer(data)
                    for i in 0..<n { destination[i] += sample(base, i) }
                }
                let scale = 1 / Float(count)
                for i in 0..<usable { destination[i] *= scale }
                written = usable
            } else {
                guard bufferList.count > 0, let data = bufferList[0].mData else { return }
                let available = Int(bufferList[0].mDataByteSize) / (bytesPerSample * channels)
                let n = min(frames, available)
                let base = UnsafeRawPointer(data)
                let scale = 1 / Float(channels)
                for i in 0..<n {
                    var sum: Float = 0
                    for c in 0..<channels { sum += sample(base, i * channels + c) }
                    destination[i] = sum * scale
                }
                written = n
            }
        }
        guard written > 0 else { return nil }
        output.frameLength = AVAudioFrameCount(written)
        return output
    }

    /// Fresh mono copy of a mic tap buffer (tap buffers may be reused by the engine).
    static func monoCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let source = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0] else { return nil }

        let channels = max(Int(buffer.format.channelCount), 1)
        let scale = 1 / Float(channels)
        if buffer.format.isInterleaved {
            let data = source[0]
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[i * channels + c] }
                destination[i] = sum * scale
            }
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += source[c][i] }
                destination[i] = sum * scale
            }
        }
        output.frameLength = AVAudioFrameCount(frames)
        return output
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return (sum / Float(n)).squareRoot()
    }

    /// Maps RMS to a 0...1 meter value (roughly -55 dB ... -10 dB).
    static func meterLevel(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 0.000_001))
        return min(max((db + 55) / 45, 0), 1)
    }
}
