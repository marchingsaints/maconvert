import AppKit
import Combine
import Foundation
import PDFKit

enum Preset: String, CaseIterable, Identifiable {
    case web, small, high, custom
    var id: String { rawValue }

    func title(for kind: MediaKind) -> String {
        switch self {
        case .web: "Web"
        case .small: kind == .image ? "Email" : "Small"
        case .high: "High"
        case .custom: "Custom"
        }
    }

    func apply(to s: inout ConversionSettings, kind: MediaKind) {
        if kind == .video {
            switch self {
            case .web: s.video.maxShortSide = 1080; s.video.quality = .medium
            case .small: s.video.maxShortSide = 720; s.video.quality = .small
            case .high: s.video.maxShortSide = nil; s.video.quality = .high
            case .custom: break
            }
            return
        }
        switch self {
        case .web: s.image.quality = 0.78; s.image.maxDimension = 2560; s.image.stripMetadata = true; s.image.lossless = false
        case .small: s.image.quality = 0.70; s.image.maxDimension = 1600; s.image.stripMetadata = true; s.image.lossless = false
        case .high: s.image.quality = 0.90; s.image.maxDimension = nil; s.image.stripMetadata = false
        case .custom: break
        }
    }
}

@MainActor
final class ConvertModel: ObservableObject {
    enum Phase: Equatable {
        case editing
        case running(Double)
        case finished(Summary)
    }

    struct Summary: Equatable {
        let written: [URL]
        let inputBytes: Int64
        let outputBytes: Int64
        let skipped: Int
        let failures: [String]
    }

    let files: [URL]
    let mode: Handoff.Mode
    let kind: MediaKind
    let totalBytes: Int64
    /// What the source files are, when they all share one output format.
    let sourceFormat: OutputFormat?
    let imageInfo: ImageInfo?
    /// Page counts for PDFs (an image counts as one page when combining).
    let pageCounts: [URL: Int]

    /// Combine: the order pages go in. Drag to reorder in the panel.
    @Published var order: [URL]
    @Published private(set) var mediaInfos: [URL: MediaInfo] = [:]
    @Published private(set) var thumbnail: NSImage?
    @Published var settings: ConversionSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var preset: Preset = .web
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var estimate: Int64?
    @Published private(set) var estimating = false

    var onBusyChange: ((Bool) -> Void)?
    /// False once the panel is closed or hidden; the job carries on and notifies when done.
    var isPresented = true
    /// True while the folder picker is up, so the panel doesn't take it for clicking away.
    private(set) var isChoosingFolder = false
    private var jobID: UUID?
    private var estimateTask: Task<Void, Never>?
    private var adjusting = false
    private let hadSavedSettings: Bool
    private let cancelFlag = CancelFlag()

    init(files: [URL], mode: Handoff.Mode, format: OutputFormat?) {
        // Finder doesn't report click order, so combining starts alphabetical (Finder-style "2" before "10").
        let files = mode == .combine ? files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } : files
        self.files = files
        self.mode = mode
        order = files
        let kinds = Set(files.compactMap(FormatCatalog.kind(of:)))
        let kind = FormatCatalog.sharedKind(of: files) ?? (kinds.contains(.pdf) ? .pdf : .image)
        self.kind = kind
        totalBytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        imageInfo = FormatCatalog.kind(of: files[0]) == .image ? ImageConverter.info(for: files[0]) : nil
        pageCounts = Dictionary(uniqueKeysWithValues: files.map { f in
            (f, FormatCatalog.kind(of: f) == .pdf ? PDFDocument(url: f)?.pageCount ?? 0 : 1)
        })
        switch FormatCatalog.kind(of: files[0]) {
        case .image:
            thumbnail = ImageConverter.thumbnail(for: files[0], maxPixels: 160).map { NSImage(cgImage: $0, size: .zero) }
        case .pdf:
            thumbnail = PDFDocument(url: files[0])?.page(at: 0)?.thumbnail(of: NSSize(width: 88, height: 88), for: .cropBox)
        default:
            break
        }
        let sources = Set(files.compactMap(UTTypeLookup.format(of:)))
        let sourceFormat = sources.count == 1 ? sources.first : nil
        self.sourceFormat = sourceFormat

        let targets = FormatCatalog.conversionTargets(for: files)
        let chosen: OutputFormat = format ?? {
            if mode == .combine { return .pdf }
            if mode == .optimize { return kind == .video ? .mp4 : kind == .pdf ? .pdf : (sourceFormat ?? .jpeg) }
            return Self.lastFormat(for: kind).flatMap { targets.contains($0) ? $0 : nil } ?? targets.first ?? .jpeg
        }()

        let saved = Self.saved(mode: mode, kind: kind, format: chosen)
        hadSavedSettings = saved != nil
        var s = saved ?? ConversionSettings(format: chosen)
        if saved == nil {
            // First run: optimizing starts on the Web preset; converting favours quality.
            if mode == .optimize { Preset.web.apply(to: &s, kind: kind) } else { s.image.quality = 0.9; s.video.quality = .high }
            // Photos in PDFs: ~200 dpi on a full page is plenty and keeps files sensible.
            if chosen == .pdf { s.image.quality = 0.82; s.image.maxDimension = 2560 }
        }
        s.pdf.outputName = ""
        settings = s
        if kind == .image { clampSizes() }
        preset = mode == .optimize ? (saved == nil ? .web : Self.savedPreset(for: kind) ?? .custom) : .custom

        if kind == .video || kind == .audio { loadMedia() } else if kind != .office { refreshEstimate() }
    }

    // MARK: Derived

    var formatChoices: [OutputFormat] {
        if mode == .combine { return [.pdf] }
        if mode == .optimize {
            if kind == .pdf { return [.pdf] }
            if kind == .video { return [.mp4, .mp4hevc] }
            // "Keep <format>" first, then the web-friendly alternatives.
            let keep = sourceFormat.map { [$0] } ?? []
            return keep + [.webp, .jpeg].filter { $0 != sourceFormat }
        }
        return FormatCatalog.conversionTargets(for: files)
    }

    /// First file's media info, once probed.
    var info: MediaInfo? { mediaInfos[files[0]] }

    /// Copying the stream untouched: only when converting, at full size, into a compatible container.
    var offersOriginalQuality: Bool { mode == .convert && canPassthrough && settings.video.maxShortSide == nil }

    var isGIFFromVideo: Bool { kind == .video && settings.format == .gif }

    var canPassthrough: Bool {
        !files.isEmpty && files.allSatisfy { mediaInfos[$0]?.canPassthrough(to: settings.format) ?? false }
    }

    var totalPages: Int { pageCounts.values.reduce(0, +) }

    var title: String {
        if mode == .combine { return "Combine \(files.count) files" }
        if files.count == 1 { return files[0].lastPathComponent }
        switch kind {
        case .image: return "\(files.count) images"
        case .video: return "\(files.count) videos"
        case .audio: return "\(files.count) audio files"
        case .pdf: return "\(files.count) PDFs"
        case .office: return "\(files.count) documents"
        }
    }

    var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pages = totalPages == 1 ? "1 page" : "\(totalPages) pages"
        if mode == .combine || (kind == .pdf && files.count > 1) { return "\(pages) · \(size)" }
        guard files.count == 1 else { return "\(size) total" }
        switch kind {
        case .image:
            if let i = imageInfo { return "\(i.pixelWidth) × \(i.pixelHeight) · \(size)" }
        case .video:
            if let i = info { return "\(i.width) × \(i.height) · \(Self.clock(i.duration)) · \(size)" }
        case .audio:
            if let i = info { return "\(Self.clock(i.duration)) · \(String(format: "%g", i.sampleRate / 1000)) kHz · \(size)" }
        case .pdf:
            return "\(pages) · \(size)"
        case .office:
            break
        }
        return size
    }

    var actionTitle: String {
        switch mode {
        case .convert: "Convert"
        case .combine: "Combine"
        case .optimize: kind == .image ? "Optimize" : "Compress"
        }
    }

    /// Optimizing can't make this file any smaller (measured, so only for single images and PDFs).
    var isAlreadyCompact: Bool {
        guard mode == .optimize, files.count == 1, kind == .image || kind == .pdf, let estimate else { return false }
        return estimate >= totalBytes
    }

    /// A quiet note about what will happen (not a warning).
    var hint: String? {
        if kind == .office {
            let apps = Set(files.compactMap { OfficeConverter.engine(for: $0)?.name }).sorted()
            return apps.isEmpty ? nil : "\(apps.joined(separator: " and ")) will open briefly in the background to make the PDF, exactly as File ▸ Export would."
        }
        if kind == .pdf, mode == .convert {
            switch settings.format {
            case .docx: return "Rebuilds headings, paragraphs, lists, tables and pictures so you can edit it. Scanned pages are read with text recognition."
            case .pptx: return "Each page becomes a slide, as a picture of the page."
            case .txt: break
            default: if totalPages > files.count { return "Each page becomes an image, saved together in a new folder." }
            }
        }
        if isAlreadyCompact {
            return settings.format == .pdf && settings.pdf.quality != .small || settings.format != .pdf && preset != .small
                ? "This file is already well compressed. A smaller setting may still help."
                : "This file is already well compressed, so there's nothing left to squeeze out without visibly hurting quality."
        }
        return nil
    }

    var warning: String? {
        switch kind {
        case .image:
            if let i = imageInfo, i.hasAlpha, !settings.format.supportsTransparency { return "Transparent areas will become white" }
        case .video:
            guard let i = info else { return nil }
            if isGIFFromVideo, i.duration > 15 { return "Long GIFs get huge. MP4 is usually 10× smaller." }
            if settings.format.kind == .audio, !i.hasAudio { return "This video has no sound" }
            if settings.format == .mp4, i.isHDR, !(settings.video.quality == .original && canPassthrough) {
                return "HDR will be converted to standard range. Choose HEVC to keep it."
            }
        case .audio, .pdf:
            break
        case .office:
            if files.contains(where: { OfficeConverter.engine(for: $0) == nil }) {
                return "Needs Microsoft Office, or Pages, Keynote or Numbers, to make the PDF"
            }
        }
        return nil
    }

    // MARK: Changes

    func selectPreset(_ p: Preset) {
        preset = p
        guard p != .custom else { return }
        adjusting = true
        p.apply(to: &settings, kind: kind)
        adjusting = false
    }

    private func settingsChanged(from old: ConversionSettings) {
        if old.format != settings.format, mode == .convert, let saved = Self.saved(mode: mode, kind: kind, format: settings.format) {
            settings = saved
        }
        // Touching a setting by hand means you're no longer on a preset.
        if !adjusting, mode == .optimize, old.format == settings.format, old != settings, preset != .custom { preset = .custom }
        clampSizes()
        // "Original" only exists when the stream can be copied as-is.
        if settings.video.quality == .original, !mediaInfos.isEmpty, !offersOriginalQuality {
            settings.video.quality = .high
        }
        refreshEstimate()
    }

    /// A preset's "1080p" on a 1080p video, or 2560 px on a small photo, means "keep the size".
    private func clampSizes() {
        guard files.count == 1 else { return }
        adjusting = true
        defer { adjusting = false }
        if let max = settings.image.maxDimension, let i = imageInfo, max >= Swift.max(i.pixelWidth, i.pixelHeight) {
            settings.image.maxDimension = nil
        }
        if let short = settings.video.maxShortSide, let i = info, short >= i.shortSide {
            settings.video.maxShortSide = nil
        }
    }

    private func loadMedia() {
        Task {
            var infos: [URL: MediaInfo] = [:]
            for file in files { infos[file] = try? await MediaProbe.best(file) }
            mediaInfos = infos
            if kind == .video, let cg = await MediaProbe.bestThumbnail(for: files[0], info: infos[files[0]], maxPixels: 160) {
                thumbnail = NSImage(cgImage: cg, size: .zero)
            }
            clampSizes()
            // Changing just the container? Default to an instant, lossless copy.
            if !hadSavedSettings, mode == .convert, kind == .video, canPassthrough { settings.video.quality = .original }
            refreshEstimate()
        }
    }

    private func refreshEstimate() {
        estimateTask?.cancel()
        if kind == .video || kind == .audio {
            estimate = mediaInfos.isEmpty ? nil : files.compactMap { mediaInfos[$0] }.reduce(0) { $0 + mediaEstimate($1) }
            return
        }
        // Combining just stacks pages; the footer shows the page count instead.
        if mode == .combine { estimate = nil; return }
        // Images and PDFs: really convert the first file in memory, then scale for batches.
        let file = files[0], s = settings, count = files.count, total = totalBytes
        let firstBytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        estimating = true
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .userInitiated) { Self.measure(file, settings: s) }.value
            guard !Task.isCancelled, let self else { return }
            if let bytes {
                let ratio = firstBytes > 0 ? Double(bytes) / Double(firstBytes) : 1
                self.estimate = count == 1 ? Int64(bytes) : Int64(Double(total) * ratio)
            } else {
                self.estimate = nil
            }
            self.estimating = false
        }
    }

    /// The real output size for one image or PDF with these settings.
    nonisolated private static func measure(_ file: URL, settings s: ConversionSettings) -> Int? {
        guard FormatCatalog.kind(of: file) == .pdf else {
            // A photo inside a PDF is stored as the JPEG we'd make anyway.
            return try? ImageConverter.encode(file, as: s.format == .pdf ? .jpeg : s.format, options: s.image).count
        }
        switch s.format {
        case .docx, .pptx:
            return nil
        case .pdf:
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? PDFConverter.compress(file, to: tmp, quality: s.pdf.quality)) != nil else { return nil }
            return Int(BatchRunner.size(of: tmp))
        case .txt:
            return PDFDocument(url: file)?.string?.utf8.count
        default:
            guard let doc = PDFDocument(url: file), let page = doc.page(at: 0),
                  let image = PDFConverter.render(page, dpi: s.pdf.dpi),
                  let data = try? ImageConverter.encode(image, as: s.format, options: s.image) else { return nil }
            return data.count * doc.pageCount
        }
    }

    private func mediaEstimate(_ i: MediaInfo) -> Int64 {
        let f = settings.format
        let (rate, channels) = AudioConverter.outputLayout(i)
        let pcm = rate * Double(channels) * 2 * i.duration
        switch f.kind {
        case .image, .pdf, .office:
            return GIFMaker.estimatedBytes(info: i, options: settings.gif)
        case .audio:
            if f.isLossyAudio { return Int64(Double(settings.audio.bitrateKbps) * 1000 / 8 * i.duration) }
            return Int64(f == .flac ? pcm * 0.55 : pcm)
        case .video:
            let audio = settings.video.removeAudio || !i.hasAudio ? 0 : 160_000.0
            if settings.video.quality == .original, i.canPassthrough(to: f) {
                return settings.video.removeAudio ? Int64(i.videoBitrate / 8 * i.duration) : i.byteCount
            }
            return Int64((VideoConverter.targetBitrate(info: i, options: settings.video, format: f) + audio) / 8 * i.duration)
        }
    }

    // MARK: Running

    func run() {
        guard phase == .editing else { return }
        // "Ask every time" shows a folder picker; cancelling it cancels the conversion.
        isChoosingFolder = true
        let choice = Preferences.outputFolder()
        isChoosingFolder = false
        guard let folder = choice else { return }
        estimateTask?.cancel()
        save()
        phase = .running(0)
        onBusyChange?(true)

        let s = settings, files = order, mode = mode, flag = cancelFlag
        let id = JobCenter.shared.start(title)
        jobID = id
        Task {
            let results = await BatchRunner.run(files, settings: s, mode: mode, cancel: flag, outputFolder: folder) { p in
                Task { @MainActor [weak self] in
                    if case .running = self?.phase { self?.phase = .running(p) }
                    JobCenter.shared.update(id, progress: p)
                }
            }
            onBusyChange?(false)
            guard !flag.isSet else { JobCenter.shared.cancelled(id); return }
            let ok = results.filter { $0.error == nil }
            let summary = Summary(
                written: files.compactMap { f in results.first { $0.source == f }?.output },
                inputBytes: ok.reduce(0) { $0 + $1.inputBytes },
                outputBytes: ok.reduce(0) { $0 + $1.outputBytes },
                skipped: results.filter(\.skippedNoGain).count,
                failures: results.compactMap { r in r.error.map { "\(r.source.lastPathComponent): \($0.localizedDescription)" } }
            )
            phase = .finished(summary)
            JobCenter.shared.finish(id, written: summary.written, headline: summary.headline, detail: summary.detail, panelVisible: isPresented)
        }
    }

    /// Stops a running job; the runner discards anything half-written.
    func cancel() {
        cancelFlag.set()
        onBusyChange?(false)
        if let jobID { JobCenter.shared.cancelled(jobID) }
    }

    func revealOutputs() {
        guard case .finished(let s) = phase, !s.written.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(s.written)
    }

    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Remembered choices

    private static func lastFormat(for kind: MediaKind) -> OutputFormat? {
        UserDefaults.standard.string(forKey: "lastFormat.\(kind.rawValue)").flatMap(OutputFormat.init)
    }

    private static func savedPreset(for kind: MediaKind) -> Preset? {
        UserDefaults.standard.string(forKey: "lastPreset.\(kind.rawValue)").flatMap(Preset.init)
    }

    private static func saved(mode: Handoff.Mode, kind: MediaKind, format: OutputFormat) -> ConversionSettings? {
        guard let data = UserDefaults.standard.data(forKey: "settings.\(mode.rawValue).\(kind.rawValue).\(format.rawValue)") else { return nil }
        return try? JSONDecoder().decode(ConversionSettings.self, from: data)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(settings), forKey: "settings.\(mode.rawValue).\(kind.rawValue).\(settings.format.rawValue)")
        if mode == .convert { d.set(settings.format.rawValue, forKey: "lastFormat.\(kind.rawValue)") }
        else { d.set(preset.rawValue, forKey: "lastPreset.\(kind.rawValue)") }
    }
}

extension ConvertModel.Summary {
    var headline: String {
        let n = written.count
        if n == 0 { return failures.isEmpty ? "Nothing to save" : "Couldn't convert" }
        return n == 1 ? "Saved \(written[0].lastPathComponent)" : "Saved \(n) files"
    }

    var detail: String? {
        guard !written.isEmpty else { return nil }
        let out = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
        let delta = inputBytes - outputBytes
        guard delta > 0, inputBytes > 0 else { return out }
        let pct = Int((Double(delta) / Double(inputBytes) * 100).rounded())
        return "\(out) · \(ByteCountFormatter.string(fromByteCount: delta, countStyle: .file)) smaller (\(pct)%)"
    }
}

enum UTTypeLookup {
    static func format(of url: URL) -> OutputFormat? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType).flatMap(OutputFormat.from)
    }
}
