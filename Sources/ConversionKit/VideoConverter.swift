import AVFoundation
import CoreMedia
import VideoToolbox

/// Thread-safe cancel switch, readable from AVFoundation's callback queues.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

enum VideoConverter {
    static func convert(_ src: URL, to dst: URL, format: OutputFormat, options: VideoOptions, info: MediaInfo,
                        cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        let fileType: AVFileType = format == .mov ? .mov : .mp4
        if options.quality == .original, options.maxShortSide == nil, info.canPassthrough(to: format) {
            try await passthrough(src, to: dst, fileType: fileType, dropAudio: options.removeAudio, cancel: cancel, progress: progress)
        } else {
            try await reencode(src, to: dst, fileType: fileType, codec: format == .mp4hevc ? .hevc : .h264,
                               options: options, info: info, cancel: cancel, progress: progress)
        }
    }

    /// The bitrate a re-encode will target, also used for the panel's size estimate.
    static func targetBitrate(info: MediaInfo, options: VideoOptions, format: OutputFormat) -> Double {
        let (w, h) = outputSize(info: info, maxShortSide: options.maxShortSide)
        var bpp = options.quality.bitsPerPixel
        // HEVC and VP9 need about two-thirds of H.264's bits for the same quality.
        if format == .mp4hevc || format == .webm { bpp *= 0.65 }
        let target = Double(w * h) * min(info.fps, 60) * bpp
        // Never spend more bits than the source had: it can't add quality, only size.
        return info.videoBitrate > 0 ? min(target, info.videoBitrate * 0.95) : target
    }

    static func outputSize(info: MediaInfo, maxShortSide: Int?) -> (Int, Int) {
        let scale = min(1, Double(maxShortSide ?? info.shortSide) / Double(max(info.shortSide, 1)))
        let even = { (v: Int) in max(2, Int((Double(v) * scale / 2).rounded()) * 2) }
        return (even(info.width), even(info.height))
    }

    // MARK: Passthrough

    private static func passthrough(_ src: URL, to dst: URL, fileType: AVFileType, dropAudio: Bool,
                                    cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        var asset: AVAsset = AVURLAsset(url: src)
        if dropAudio {
            // A composition holding just the video track, still copied without re-encoding.
            let comp = AVMutableComposition()
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  let compTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ConversionError.unreadable(src)
            }
            let (range, transform) = try await track.load(.timeRange, .preferredTransform)
            try compTrack.insertTimeRange(range, of: track, at: .zero)
            compTrack.preferredTransform = transform
            asset = comp
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.unreadable(src)
        }
        session.outputURL = dst
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                if cancel.isSet { session.cancelExport() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await session.export()
        poll.cancel()
        if session.status == .cancelled || cancel.isSet { throw CancellationError() }
        guard session.status == .completed else { throw session.error ?? ConversionError.encodeFailed(.mp4) }
    }

    // MARK: Re-encode

    private static func reencode(_ src: URL, to dst: URL, fileType: AVFileType, codec: AVVideoCodecType, options: VideoOptions,
                                 info: MediaInfo, cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.unreadable(src) }
        let (natural, transform, minFrame) = try await videoTrack.load(.naturalSize, .preferredTransform, .minFrameDuration)
        let duration = try await asset.load(.duration)

        // HEVC keeps HDR as HDR; H.264 is SDR-only, so the composition tone-maps it down.
        let keepHDR = info.isHDR && codec == .hevc
        let (outW, outH) = outputSize(info: info, maxShortSide: options.maxShortSide)

        // The video composition does rotation, scaling and colour conversion in one GPU pass.
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: outW, height: outH)
        composition.frameDuration = minFrame.isValid && minFrame.seconds > 0 ? minFrame : CMTime(value: 1, timescale: CMTimeScale(info.fps.rounded()))
        composition.colorPrimaries = keepHDR ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = keepHDR ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = keepHDR ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        // Some files rotate without translating back on-canvas; normalise so the frame sits at the origin.
        let rotated = CGRect(origin: .zero, size: natural).applying(transform)
        let upright = transform.concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
        let scale = Double(outW) / Double(max(abs(rotated.width), 1))
        layer.setTransform(upright.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: keepHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.videoComposition = composition

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate(info: info, options: options, format: codec == .hevc ? .mp4hevc : .mp4),
            AVVideoExpectedSourceFrameRateKey: info.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        if keepHDR { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: composition.colorPrimaries!,
                AVVideoTransferFunctionKey: composition.colorTransferFunction!,
                AVVideoYCbCrMatrixKey: composition.colorYCbCrMatrix!,
            ],
        ])

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOut, videoIn)]
        if !options.removeAudio, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            pairs.append(AudioConverter.aacPair(track: audioTrack, info: info, bitrate: 160_000))
        }
        try await ReaderWriter.run(asset: asset, to: dst, fileType: fileType, pairs: pairs, duration: duration.seconds, cancel: cancel, progress: progress)
    }
}

/// Moves samples from reader outputs into writer inputs, every track at once.
/// Feeding tracks one after another deadlocks: the writer waits to interleave them.
enum ReaderWriter {
    static func run(asset: AVAsset, to dst: URL, fileType: AVFileType, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
                    duration: Double, cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: dst, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        for (output, input) in pairs {
            output.alwaysCopiesSampleData = false
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw ConversionError.encodeFailed(.mp4) }
            reader.add(output)
            writer.add(input)
        }
        guard reader.startReading() else { throw reader.error ?? ConversionError.unreadable(dst) }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.encodeFailed(.mp4) }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (index, (output, input)) in pairs.enumerated() {
                group.addTask {
                    await pump(output, into: input, cancel: cancel) { sample in
                        // The first track (video, or the only audio track) drives progress.
                        guard index == 0, duration > 0 else { return }
                        progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                    }
                }
            }
        }

        if cancel.isSet || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            if cancel.isSet { throw CancellationError() }
            throw reader.error ?? ConversionError.unreadable(dst)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.encodeFailed(.mp4) }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, cancel: CancelFlag,
                             onSample: @escaping (CMSampleBuffer) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finished = CancelFlag()
            let finish = {
                input.markAsFinished()
                finished.set()
                done.resume()
            }
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "macconvert.pump")) {
                guard !finished.isSet else { return }
                while input.isReadyForMoreMediaData {
                    guard !cancel.isSet, let sample = output.copyNextSampleBuffer() else { return finish() }
                    onSample(sample)
                    if !input.append(sample) { return finish() }
                }
            }
        }
    }
}
