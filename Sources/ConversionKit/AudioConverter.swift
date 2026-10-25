import AudioToolbox
import AVFoundation
import CoreMedia

/// Audio out of any audio or video file: M4A, WAV and AIFF through AVAssetWriter,
/// FLAC through Core Audio, MP3 through LAME (macOS has no MP3 encoder).
enum AudioConverter {
    static func convert(_ src: URL, to dst: URL, format: OutputFormat, options: AudioOptions, info: MediaInfo,
                        cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudio }
        let duration = try await asset.load(.duration).seconds

        switch format {
        case .m4a:
            try await ReaderWriter.run(asset: asset, to: dst, fileType: .m4a,
                                       pairs: [aacPair(track: track, info: info, bitrate: options.bitrateKbps * 1000)],
                                       duration: duration, cancel: cancel, progress: progress)
        case .wav, .aiff:
            let pcm = pcmSettings(info: info, bigEndian: format == .aiff)
            let pair = (AVAssetReaderTrackOutput(track: track, outputSettings: pcm) as AVAssetReaderOutput,
                        AVAssetWriterInput(mediaType: .audio, outputSettings: pcm))
            try await ReaderWriter.run(asset: asset, to: dst, fileType: format == .wav ? .wav : .aiff,
                                       pairs: [pair], duration: duration, cancel: cancel, progress: progress)
        case .flac:
            try readPCM(asset: asset, track: track, info: info, duration: duration, cancel: cancel, progress: progress,
                        sink: try FLACSink(url: dst, info: info))
        case .mp3:
            try readPCM(asset: asset, track: track, info: info, duration: duration, cancel: cancel, progress: progress,
                        sink: try MP3Sink(url: dst, info: info, bitrateKbps: options.bitrateKbps))
        default:
            throw ConversionError.encodeFailed(format)
        }
    }

    /// Stereo (or mono) at no more than 48 kHz: what MP3 and AAC expect, and plenty for listening.
    static func outputLayout(_ info: MediaInfo) -> (sampleRate: Double, channels: Int) {
        (min(info.sampleRate, 48_000), min(max(info.channels, 1), 2))
    }

    static func pcmSettings(info: MediaInfo, bigEndian: Bool = false) -> [String: Any] {
        let (rate, channels) = outputLayout(info)
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func aacPair(track: AVAssetTrack, info: MediaInfo, bitrate: Int) -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let (rate, channels) = outputLayout(info)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(info: info))
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
        ])
        return (output, input)
    }

    /// Decodes to 16-bit interleaved PCM and hands each chunk to `sink`. No writer
    /// is involved, so a plain loop is fine here.
    private static func readPCM(asset: AVAsset, track: AVAssetTrack, info: MediaInfo, duration: Double,
                                cancel: CancelFlag, progress: (Double) -> Void, sink: PCMSink) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(info: info))
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConversionError.noAudio }

        while let sample = output.copyNextSampleBuffer() {
            if cancel.isSet {
                reader.cancelReading()
                sink.abort()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            if CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
                try UnsafeRawPointer(pointer).withMemoryRebound(to: Int16.self, capacity: length / 2) { try sink.write($0, frames: frames) }
            } else {
                // Sample buffers can be split across chunks; flatten those first.
                var data = Data(count: length)
                try data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                    try sink.write(raw.bindMemory(to: Int16.self).baseAddress!, frames: frames)
                }
            }
            if duration > 0 { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)) }
        }
        guard reader.status == .completed else {
            sink.abort()
            throw reader.error ?? ConversionError.noAudio
        }
        try sink.finish()
    }
}

private protocol PCMSink {
    func write(_ samples: UnsafePointer<Int16>, frames: Int) throws
    func finish() throws
    func abort()
}

/// Core Audio's ExtAudioFile encodes FLAC natively.
private final class FLACSink: PCMSink {
    private var file: ExtAudioFileRef?
    private let channels: UInt32

    init(url: URL, info: MediaInfo) throws {
        let (rate, ch) = AudioConverter.outputLayout(info)
        channels = UInt32(ch)
        var flac = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatFLAC, mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
                                               mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0,
                                               mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr else {
            throw ConversionError.encodeFailed(.flac)
        }
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client)
    }

    func write(_ samples: UnsafePointer<Int16>, frames: Int) throws {
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: channels, mDataByteSize: UInt32(frames) * 2 * channels, mData: UnsafeMutableRawPointer(mutating: samples)))
        guard ExtAudioFileWrite(file!, UInt32(frames), &list) == noErr else { throw ConversionError.encodeFailed(.flac) }
    }

    func finish() throws {
        guard ExtAudioFileDispose(file!) == noErr else { throw ConversionError.encodeFailed(.flac) }
        file = nil
    }

    func abort() {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}

private final class MP3Sink: PCMSink {
    private let lame: OpaquePointer
    private let handle: FileHandle
    private let channels: Int
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)

    init(url: URL, info: MediaInfo, bitrateKbps: Int) throws {
        let (rate, ch) = AudioConverter.outputLayout(info)
        channels = ch
        guard let lame = lame_init() else { throw ConversionError.encodeFailed(.mp3) }
        self.lame = lame
        lame_set_in_samplerate(lame, Int32(rate))
        lame_set_num_channels(lame, Int32(ch))
        lame_set_mode(lame, ch == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(lame, Int32(bitrateKbps))
        lame_set_quality(lame, 2) // near-best psychoacoustics, still fast
        guard lame_init_params(lame) >= 0, FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            lame_close(lame)
            throw ConversionError.encodeFailed(.mp3)
        }
        self.handle = handle
    }

    func write(_ samples: UnsafePointer<Int16>, frames: Int) throws {
        let needed = Int(1.25 * Double(frames)) + 7200 // LAME's documented worst case
        if buffer.count < needed { buffer = [UInt8](repeating: 0, count: needed) }
        let written = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
            let pcm = UnsafeMutablePointer(mutating: samples)
            return channels == 2
                ? lame_encode_buffer_interleaved(lame, pcm, Int32(frames), out.baseAddress, Int32(out.count))
                : lame_encode_buffer(lame, pcm, pcm, Int32(frames), out.baseAddress, Int32(out.count))
        }
        guard written >= 0 else { throw ConversionError.encodeFailed(.mp3) }
        try handle.write(contentsOf: buffer[0..<Int(written)])
    }

    func finish() throws {
        let written = buffer.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32($0.count)) }
        if written > 0 { try handle.write(contentsOf: buffer[0..<Int(written)]) }
        try handle.close()
        lame_close(lame)
    }

    func abort() {
        try? handle.close()
        lame_close(lame)
    }
}
