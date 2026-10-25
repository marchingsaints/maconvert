import AVFoundation
import CoreMedia

struct MediaInfo: Equatable {
    var duration: Double
    var byteCount: Int64
    /// As displayed, i.e. with rotation applied (portrait phone video is taller than wide).
    var width = 0
    var height = 0
    var fps: Double = 30
    /// Bits per second of the video track alone.
    var videoBitrate: Double = 0
    var videoCodec: CMVideoCodecType?
    var isHDR = false
    var audioCodec: AudioFormatID?
    var sampleRate: Double = 44_100
    var channels = 2

    /// Read through FFmpeg rather than AVFoundation (MKV, WebM, AVI, …).
    var viaFFmpeg = false
    /// FFmpeg-style codec names ("h264", "vp9", "aac", "opus"), for deciding what can be copied as-is.
    var videoCodecName: String?
    var audioCodecName: String?

    var hasVideo: Bool { videoCodec != nil }
    var hasAudio: Bool { audioCodec != nil }
    var shortSide: Int { min(width, height) }

    /// Whether the video stream can be copied untouched into `format` (instant, lossless).
    func canPassthrough(to format: OutputFormat) -> Bool {
        guard hasVideo else { return false }
        let video = videoCodecName ?? "", audio = audioCodecName
        switch format {
        case .mkv:
            return true // Matroska holds any codec.
        case .webm:
            return ["vp8", "vp9", "av1"].contains(video) && (audio == nil || ["opus", "vorbis"].contains(audio!))
        case .mp4, .mov, .mp4hevc:
            let audioOK = audio == nil || audio == "aac" || (viaFFmpeg && audio == "mp3")
            return audioOK && (format == .mp4hevc ? video == "hevc" : video == "h264" || video == "hevc")
        default:
            return false
        }
    }
}

enum MediaProbe {
    /// AVFoundation for the formats it knows, FFmpeg for the rest (or when AVFoundation can't decode a file).
    static func best(_ url: URL) async throws -> MediaInfo {
        if !FormatCatalog.needsFFmpeg(url), let info = try? await probe(url), info.hasVideo || info.hasAudio, info.duration > 0 {
            return info
        }
        return try await FFmpeg.probe(url)
    }

    static func bestThumbnail(for url: URL, info: MediaInfo?, maxPixels: Int) async -> CGImage? {
        if info?.viaFFmpeg == true || FormatCatalog.needsFFmpeg(url) { return await FFmpeg.thumbnail(for: url, maxPixels: maxPixels) }
        return await thumbnail(for: url, maxPixels: maxPixels)
    }

    static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var info = MediaInfo(duration: try await asset.load(.duration).seconds, byteCount: bytes)

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, fps, rate, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            info.width = Int(abs(shown.width).rounded())
            info.height = Int(abs(shown.height).rounded())
            info.fps = fps > 0 ? Double(fps) : 30
            info.videoBitrate = Double(rate)
            if let format = formats.first {
                let codec = CMFormatDescriptionGetMediaSubType(format)
                info.videoCodec = codec
                info.videoCodecName = [kCMVideoCodecType_H264: "h264", kCMVideoCodecType_HEVC: "hevc"][codec] ?? "other"
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                info.isHDR = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
        }

        if let track = try await asset.loadTracks(withMediaType: .audio).first,
           let format = try await track.load(.formatDescriptions).first {
            info.audioCodec = CMFormatDescriptionGetMediaSubType(format)
            info.audioCodecName = info.audioCodec == kAudioFormatMPEG4AAC ? "aac" : "other"
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                info.sampleRate = asbd.mSampleRate
                info.channels = Int(asbd.mChannelsPerFrame)
            }
        }
        return info
    }

    static func thumbnail(for url: URL, maxPixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        // A frame a little way in is more representative than a black first frame.
        return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }
}
