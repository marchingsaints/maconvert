import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// The bundled FFmpeg (LGPL build): reads what AVFoundation can't (MKV, WebM, AVI, …),
/// writes WebM/MKV, and makes high-quality palette GIFs.
enum FFmpeg {
    static var binary: URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") { return bundled }
        // Tools and tests run outside the app bundle.
        return ProcessInfo.processInfo.environment["MACCONVERT_FFMPEG"].map(URL.init(fileURLWithPath:))
    }

    // MARK: Probe

    static func probe(_ url: URL) async throws -> MediaInfo {
        let output = try await run(["-hide_banner", "-i", url.path], expectFailure: true).stderr
        func first(_ pattern: String, in text: String = output) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
        guard let d = first(#"Duration: (\d+):(\d+):([\d.]+)"#) else { throw ConversionError.unreadable(url) }
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var info = MediaInfo(duration: Double(d[1])! * 3600 + Double(d[2])! * 60 + Double(d[3])!, byteCount: bytes)
        info.viaFFmpeg = true

        if let line = first(#"Stream #\d+:\d+[^\n]*: Video: [^\n]*"#)?[0], !line.contains("attached pic") {
            let codec = first(#"Video: (\w+)"#, in: line)?[1] ?? "unknown"
            info.videoCodecName = codec
            info.videoCodec = codec == "h264" ? kCMVideoCodecType_H264 : codec == "hevc" ? kCMVideoCodecType_HEVC : FourCC.other
            if let size = first(#", (\d{2,5})x(\d{2,5})"#, in: line) { info.width = Int(size[1])!; info.height = Int(size[2])! }
            if let fps = first(#"([\d.]+) fps"#, in: line) { info.fps = Double(fps[1]) ?? 30 }
            if let rate = first(#"(\d+) kb/s"#, in: line) { info.videoBitrate = Double(rate[1])! * 1000 }
            else if let total = first(#"bitrate: (\d+) kb/s"#) { info.videoBitrate = Double(total[1])! * 1000 * 0.9 }
            info.isHDR = line.contains("arib-std-b67") || line.contains("smpte2084")
            // Phone videos store rotation as metadata; FFmpeg applies it when decoding.
            if let r = first(#"rotation of (-?[\d.]+)"#), abs(abs(Double(r[1]) ?? 0) - 90) < 1 { swap(&info.width, &info.height) }
        }
        if let line = first(#"Stream #\d+:\d+[^\n]*: Audio: [^\n]*"#)?[0] {
            let codec = first(#"Audio: (\w+)"#, in: line)?[1] ?? "unknown"
            info.audioCodecName = codec
            info.audioCodec = codec == "aac" ? kAudioFormatMPEG4AAC : FourCC.other
            if let hz = first(#"(\d+) Hz"#, in: line) { info.sampleRate = Double(hz[1])! }
            if let layout = first(#"Hz, ([^,]+),"#, in: line)?[1] {
                info.channels = layout == "mono" ? 1 : layout == "stereo" ? 2 : Int(layout.prefix(1)).map { $0 + 1 } ?? 2
            }
        }
        return info
    }

    static func thumbnail(for url: URL, maxPixels: Int) async -> CGImage? {
        guard let result = try? await run(["-v", "error", "-ss", "0.5", "-i", url.path, "-frames:v", "1",
                                           "-vf", "scale=\(maxPixels):-2", "-f", "image2pipe", "-c:v", "png", "-"]),
              let source = CGImageSourceCreateWithData(result.stdout as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Convert

    static func convert(_ src: URL, to dst: URL, settings: ConversionSettings, info: MediaInfo,
                        cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        let format = settings.format
        if format == .mp3 {
            // FFmpeg has no MP3 encoder in an LGPL build; decode to WAV, then use LAME.
            let wav = dst.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await transcode(["-i", src.path, "-vn", "-c:a", "pcm_s16le", wav.path], duration: info.duration, cancel: cancel) { progress($0 * 0.5) }
            var wavInfo = info
            wavInfo.audioCodec = kAudioFormatLinearPCM
            try await AudioConverter.convert(wav, to: dst, format: .mp3, options: settings.audio, info: wavInfo, cancel: cancel) { progress(0.5 + $0 * 0.5) }
            return
        }
        try await transcode(["-i", src.path] + arguments(for: settings, info: info) + [dst.path],
                            duration: info.duration, cancel: cancel, progress: progress)
    }

    static func arguments(for s: ConversionSettings, info: MediaInfo) -> [String] {
        let format = s.format
        switch format.kind {
        case .audio:
            let kbps = "\(s.audio.bitrateKbps)k"
            switch format {
            case .m4a: return ["-vn", "-c:a", "aac_at", "-b:a", kbps]
            case .wav: return ["-vn", "-c:a", "pcm_s16le"]
            case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
            case .flac: return ["-vn", "-c:a", "flac"]
            default: return ["-vn"]
            }
        case .image:
            // Two-pass palette: far better colour than a fixed 256-colour table.
            let filter = "fps=\(s.gif.fps),scale=\(s.gif.width):-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
            return ["-vf", filter, "-loop", "0"]
        default:
            break
        }

        var args: [String] = ["-map_metadata", "0"]
        let copy = s.video.quality == .original && s.video.maxShortSide == nil && info.canPassthrough(to: format)
        // MKV holds anything (subtitles too); the others take one video and one audio track.
        args += format == .mkv && copy ? ["-map", "0"] : ["-map", "0:v:0", "-map", "0:a:0?"]
        if s.video.removeAudio { args += ["-an"] }

        if copy {
            args += ["-c", "copy"]
        } else {
            let bitrate = String(Int(VideoConverter.targetBitrate(info: info, options: s.video, format: format)))
            switch format {
            case .webm:
                args += ["-c:v", "libvpx-vp9", "-b:v", bitrate, "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-pix_fmt", "yuv420p"]
            case .mp4hevc:
                args += ["-c:v", "hevc_videotoolbox", "-b:v", bitrate, "-pix_fmt", "yuv420p"]
            default:
                args += ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-profile:v", "high", "-pix_fmt", "yuv420p"]
            }
            let (w, h) = VideoConverter.outputSize(info: info, maxShortSide: s.video.maxShortSide)
            if w != info.width || h != info.height { args += ["-vf", "scale=\(w):\(h):flags=lanczos"] }
            if !s.video.removeAudio {
                args += format == .webm ? ["-c:a", "libopus", "-b:a", "128k"] : ["-c:a", "aac_at", "-b:a", "160k"]
            }
        }
        if format == .mp4hevc || (copy && info.videoCodecName == "hevc" && format != .mkv && format != .webm) { args += ["-tag:v", "hvc1"] }
        if format == .mp4 || format == .mp4hevc || format == .mov { args += ["-movflags", "+faststart"] }
        return args
    }

    // MARK: Process plumbing

    /// Runs an encode, reporting progress from FFmpeg's machine-readable progress stream.
    private static func transcode(_ args: [String], duration: Double, cancel: CancelFlag, progress: @escaping (Double) -> Void) async throws {
        _ = try await run(["-hide_banner", "-v", "error", "-y", "-nostats", "-progress", "pipe:1"] + args, cancel: cancel) { line in
            if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                progress(min(1, max(0, us / 1_000_000 / duration)))
            }
        }
    }

    @discardableResult
    private static func run(_ args: [String], expectFailure: Bool = false, cancel: CancelFlag? = nil,
                            onLine: ((Substring) -> Void)? = nil) async throws -> (stdout: Data, stderr: String) {
        guard let binary else { throw ConversionError.missingTool("FFmpeg") }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = Collector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.append(stdout: chunk, onLine: onLine)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.append(stderr: chunk) }
        }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume(throwing: error) }
            if let cancel {
                Task.detached {
                    while process.isRunning {
                        if cancel.isSet { process.terminate(); return }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(stdout: out.fileHandleForReading.readDataToEndOfFile(), onLine: onLine)
        collected.append(stderr: err.fileHandleForReading.readDataToEndOfFile())

        if cancel?.isSet == true { throw CancellationError() }
        let result = collected.result
        if process.terminationStatus != 0, !expectFailure {
            let reason = result.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw ConversionError.toolFailed("FFmpeg", reason)
        }
        return result
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var pending = ""

        func append(stdout chunk: Data, onLine: ((Substring) -> Void)?) {
            lock.withLock {
                stdout.append(chunk)
                guard let onLine else { return }
                pending += String(decoding: chunk, as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    onLine(pending[..<newline])
                    pending.removeSubrange(...newline)
                }
            }
        }

        func append(stderr chunk: Data) { lock.withLock { stderr.append(chunk) } }

        var result: (stdout: Data, stderr: String) { lock.withLock { (stdout, String(decoding: stderr, as: UTF8.self)) } }
    }
}

enum FourCC {
    /// Marks a stream AVFoundation doesn't have a code for (VP9, Opus, …).
    static let other: UInt32 = 0x3F3F_3F3F // "????"
}
