import Foundation
import PDFKit

struct FileResult {
    let source: URL
    let output: URL?
    let inputBytes: Int64
    let outputBytes: Int64
    /// Optimizing produced nothing smaller, so no file was written.
    let skippedNoGain: Bool
    let error: Error?

    var wasCancelled: Bool { error is CancellationError }
}

enum BatchRunner {
    /// Converts every file and writes results beside the originals. Images run in
    /// parallel; video and audio run one at a time since each already saturates the
    /// hardware encoder. Never overwrites: clashes become "clip-compressed 2.mp4", …
    /// `outputFolder` nil saves beside each original.
    static func run(_ files: [URL], settings: ConversionSettings, mode: Handoff.Mode, cancel: CancelFlag, outputFolder: URL? = nil,
                    progress: @escaping @Sendable (Double) -> Void) async -> [FileResult] {
        let compresses = settings.format.kind == .video || settings.format == .pdf
        let suffix = mode == .convert ? "converted" : compresses ? "compressed" : "optimized"
        let job = Job(settings: settings, suffix: suffix, onlyIfSmaller: mode == .optimize, cancel: cancel, outputFolder: outputFolder)

        if mode == .combine {
            return [await job.combine(files, progress: progress)]
        }
        if files.allSatisfy({ FormatCatalog.kind(of: $0) == .image }) {
            return await runImages(files, job: job, progress: progress)
        }
        var results: [FileResult] = []
        for (i, file) in files.enumerated() {
            let step = { (p: Double) in progress((Double(i) + p) / Double(files.count)) }
            let result: FileResult
            switch FormatCatalog.kind(of: file) {
            case .pdf: result = await job.convertPDF(file, progress: step)
            case .office: result = await job.convertOffice(file)
            default: result = await job.convertMedia(file, progress: step)
            }
            results.append(result)
            if result.wasCancelled { break }
        }
        return results
    }

    private static func runImages(_ files: [URL], job: Job, progress: @escaping @Sendable (Double) -> Void) async -> [FileResult] {
        await withTaskGroup(of: FileResult.self) { group in
            var results: [FileResult] = []
            var pending = files.makeIterator()
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)

            func addNext() -> Bool {
                guard let file = pending.next() else { return false }
                group.addTask { await job.convertImage(file) }
                return true
            }
            for _ in 0..<width where addNext() {}
            for await result in group {
                results.append(result)
                progress(Double(results.count) / Double(files.count))
                _ = addNext()
            }
            return results
        }
    }

    /// A file's size, or the total of a folder's files.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
        return items.reduce(0) { $0 + size(of: $1) }
    }

    /// The suffix is only added when the output would otherwise share the source's
    /// name and format (photo.png → photo-optimized.png, but photo.png → photo.webp).
    static func availableURL(beside file: URL, ext: String, suffix: String?, in folder: URL? = nil) -> URL {
        let dir = folder ?? file.deletingLastPathComponent()
        // Folders (empty ext) keep their whole name, dots included.
        var base = ext.isEmpty ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
        let normalize = { (e: String) in ["jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "aif": "aiff"][e.lowercased()] ?? e.lowercased() }
        if let suffix, normalize(file.pathExtension) == normalize(ext) { base += "-\(suffix)" }
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

private struct Job: Sendable {
    let settings: ConversionSettings
    let suffix: String
    let onlyIfSmaller: Bool
    let cancel: CancelFlag
    let outputFolder: URL?

    func convertImage(_ file: URL) async -> FileResult {
        let inBytes = ImageConverter.info(for: file)?.byteCount ?? 0
        if settings.format == .pdf {
            return await produce(file, inBytes: inBytes, ext: "pdf") { tmp in
                try PDFConverter.combine([file], to: tmp, options: settings.pdf, image: settings.image, cancel: cancel) { _ in }
            }
        }
        do {
            if cancel.isSet { throw CancellationError() }
            let data = try ImageConverter.encode(file, as: settings.format, options: settings.image)
            if onlyIfSmaller, Int64(data.count) >= inBytes { return skipped(file, inBytes) }
            let sameFolder = outputFolder == nil || outputFolder!.standardizedFileURL == file.deletingLastPathComponent().standardizedFileURL
            let out = BatchRunner.availableURL(beside: file, ext: settings.format.fileExtension, suffix: sameFolder ? suffix : nil, in: outputFolder)
            try data.write(to: out, options: .withoutOverwriting)
            return FileResult(source: file, output: out, inputBytes: inBytes, outputBytes: Int64(data.count), skippedNoGain: false, error: nil)
        } catch {
            return FileResult(source: file, output: nil, inputBytes: inBytes, outputBytes: 0, skippedNoGain: false, error: error)
        }
    }

    func convertMedia(_ file: URL, progress: @escaping (Double) -> Void) async -> FileResult {
        let format = settings.format
        guard let info = try? await MediaProbe.best(file) else {
            return FileResult(source: file, output: nil, inputBytes: 0, outputBytes: 0, skippedNoGain: false, error: ConversionError.unreadable(file))
        }
        // FFmpeg for what AVFoundation can't read or write, and for palette GIFs.
        let useFFmpeg = info.viaFFmpeg || format == .webm || format == .mkv || format == .gif
        return await produce(file, inBytes: info.byteCount, ext: format.fileExtension) { tmp in
            if useFFmpeg {
                return try await FFmpeg.convert(file, to: tmp, settings: settings, info: info, cancel: cancel, progress: progress)
            }
            switch format.kind {
            case .video:
                try await VideoConverter.convert(file, to: tmp, format: format, options: settings.video, info: info, cancel: cancel, progress: progress)
            case .audio:
                try await AudioConverter.convert(file, to: tmp, format: format, options: settings.audio, info: info, cancel: cancel, progress: progress)
            default:
                throw ConversionError.encodeFailed(format)
            }
        }
    }

    func convertPDF(_ file: URL, progress: @escaping (Double) -> Void) async -> FileResult {
        let format = settings.format
        let inBytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        switch format {
        case .pdf:
            return await produce(file, inBytes: inBytes, ext: "pdf") { tmp in
                try PDFConverter.compress(file, to: tmp, quality: settings.pdf.quality)
            }
        case .txt:
            return await produce(file, inBytes: inBytes, ext: "txt") { tmp in try PDFConverter.extractText(file, to: tmp) }
        case .docx:
            return await produce(file, inBytes: inBytes, ext: "docx") { tmp in
                try PDFToWord.convert(file, to: tmp, cancel: cancel, progress: progress)
            }
        case .pptx:
            return await produce(file, inBytes: inBytes, ext: "pptx") { tmp in
                try PPTXWriter.convert(file, to: tmp, cancel: cancel, progress: progress)
            }
        default:
            // Several pages become a folder of images.
            let pages = PDFDocument(url: file)?.pageCount ?? 1
            return await produce(file, inBytes: inBytes, ext: format.fileExtension, folderName: pages > 1 ? "\(file.deletingPathExtension().lastPathComponent) pages" : nil) { tmp in
                try PDFConverter.renderPages(file, to: tmp, format: format, dpi: settings.pdf.dpi, options: settings.image, cancel: cancel, progress: progress)
            }
        }
    }

    func convertOffice(_ file: URL) async -> FileResult {
        let inBytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return await produce(file, inBytes: inBytes, ext: "pdf") { tmp in
            try await OfficeConverter.convert(file, to: tmp, cancel: cancel)
        }
    }

    func combine(_ files: [URL], progress: @escaping (Double) -> Void) async -> FileResult {
        let inBytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let name = settings.pdf.outputName.trimmingCharacters(in: .whitespaces)
        let named = (outputFolder ?? files[0].deletingLastPathComponent()).appendingPathComponent(name.isEmpty ? "Combined" : name).appendingPathExtension("pdf")
        let result = await produce(named, inBytes: inBytes, ext: "pdf", noSuffix: true) { tmp in
            try PDFConverter.combine(files, to: tmp, options: settings.pdf, image: settings.image, cancel: cancel, progress: progress)
        }
        return FileResult(source: files[0], output: result.output, inputBytes: result.inputBytes, outputBytes: result.outputBytes,
                          skippedNoGain: false, error: result.error)
    }

    /// Runs `work` into a scratch folder on the same volume, then moves the finished
    /// file (or folder) beside the source, so a cancelled or failed job never leaves
    /// a partial file behind.
    private func produce(_ file: URL, inBytes: Int64, ext: String, folderName: String? = nil, noSuffix: Bool = false,
                         work: (URL) async throws -> Void) async -> FileResult {
        do {
            return try await produceThrowing(file, inBytes: inBytes, ext: ext, folderName: folderName, noSuffix: noSuffix, work: work)
        } catch {
            return FileResult(source: file, output: nil, inputBytes: inBytes, outputBytes: 0, skippedNoGain: false, error: error)
        }
    }

    private func produceThrowing(_ file: URL, inBytes: Int64, ext: String, folderName: String?, noSuffix: Bool,
                                 work: (URL) async throws -> Void) async throws -> FileResult {
        let (scratch, tmp) = try scratchURL(for: file, ext: ext, folderName: folderName, noSuffix: noSuffix)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await work(tmp)
        return try finish(file, tmp: tmp, inBytes: inBytes, ext: ext, folderName: folderName, noSuffix: noSuffix)
    }

    private func destination(for file: URL, ext: String, folderName: String?, noSuffix: Bool) -> URL {
        let folder = outputFolder ?? file.deletingLastPathComponent()
        if let folderName { return BatchRunner.availableURL(beside: folder.appendingPathComponent(folderName), ext: "", suffix: nil) }
        // In another folder the original isn't next to it, so the name needs no "-optimized".
        let sameFolder = outputFolder == nil || outputFolder!.standardizedFileURL == file.deletingLastPathComponent().standardizedFileURL
        return BatchRunner.availableURL(beside: file, ext: ext, suffix: noSuffix || !sameFolder ? nil : suffix, in: folder)
    }

    private func scratchURL(for file: URL, ext: String, folderName: String?, noSuffix: Bool) throws -> (URL, URL) {
        let out = destination(for: file, ext: ext, folderName: folderName, noSuffix: noSuffix)
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: out, create: true)
        return (scratch, scratch.appendingPathComponent(out.lastPathComponent))
    }

    private func finish(_ file: URL, tmp: URL, inBytes: Int64, ext: String, folderName: String?, noSuffix: Bool) throws -> FileResult {
        let outBytes = BatchRunner.size(of: tmp)
        if onlyIfSmaller, outBytes >= inBytes { return skipped(file, inBytes) }
        // Pick the name now: another job may have taken the earlier choice while this one ran.
        let final = destination(for: file, ext: ext, folderName: folderName, noSuffix: noSuffix)
        try FileManager.default.moveItem(at: tmp, to: final)
        return FileResult(source: file, output: final, inputBytes: inBytes, outputBytes: outBytes, skippedNoGain: false, error: nil)
    }

    private func skipped(_ file: URL, _ bytes: Int64) -> FileResult {
        FileResult(source: file, output: nil, inputBytes: bytes, outputBytes: bytes, skippedNoGain: true, error: nil)
    }
}
