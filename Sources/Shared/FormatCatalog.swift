import Foundation
import UniformTypeIdentifiers

/// Shared between the app and the Finder extension: which formats exist,
/// which files we can read, and how the extension hands work to the app.

enum MediaKind: String, Codable {
    case image, video, audio, pdf
    /// Word, Excel, PowerPoint, Pages, Keynote and Numbers documents.
    case office
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    // Images
    case webp, jpeg, png, heic, tiff, gif, bmp, pdf
    // Video
    case mp4, mp4hevc, mov, webm, mkv
    // Audio
    case mp3, m4a, wav, aiff, flac
    // From PDFs
    case txt, docx, pptx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .webp: "WebP"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .pdf: "PDF"
        case .mp4: "MP4"
        case .mp4hevc: "MP4 (HEVC)"
        case .mov: "MOV"
        case .webm: "WebM"
        case .mkv: "MKV"
        case .mp3: "MP3"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .txt: "Text"
        case .docx: "Word"
        case .pptx: "PowerPoint"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .mp4hevc: "mp4"
        default: rawValue
        }
    }

    /// What this format produces. GIF counts as an image even when made from a video.
    var kind: MediaKind {
        switch self {
        case .mp4, .mp4hevc, .mov, .webm, .mkv: .video
        case .mp3, .m4a, .wav, .aiff, .flac: .audio
        case .txt, .docx, .pptx: .pdf
        default: .image
        }
    }

    var utType: UTType {
        switch self {
        case .webp: .webP
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .pdf: .pdf
        case .mp4, .mp4hevc: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .webm: UTType("org.webmproject.webm") ?? .movie
        case .mkv: UTType("org.matroska.mkv") ?? .movie
        case .mp3: .mp3
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .aiff: .aiff
        case .flac: UTType("org.xiph.flac") ?? .audio
        case .txt: .plainText
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .pptx: UTType("org.openxmlformats.presentationml.presentation") ?? .data
        }
    }

    /// One-line hint shown under the format in the panel.
    var blurb: String {
        switch self {
        case .webp: "Smallest for the web, supported by all modern browsers"
        case .jpeg: "Universal, great for photos"
        case .png: "Lossless, keeps transparency"
        case .heic: "Apple's compact photo format"
        case .tiff: "Lossless, for print and archiving"
        case .gif: "Animated, plays everywhere, but files get big"
        case .bmp: "Uncompressed bitmap"
        case .pdf: "Image as a PDF page"
        case .mp4: "H.264, plays on every device and website"
        case .mp4hevc: "About half the size of H.264, for newer devices"
        case .mov: "QuickTime, best for editing on a Mac"
        case .webm: "Open web video (VP9), for websites and Android"
        case .mkv: "Holds any video, audio and subtitles together"
        case .mp3: "Plays everywhere"
        case .m4a: "AAC, smaller than MP3 at the same quality"
        case .wav: "Uncompressed, for editing"
        case .aiff: "Uncompressed, Apple's take on WAV"
        case .flac: "Lossless and about half the size of WAV"
        case .txt: "Just the words, for copying or searching"
        case .docx: "Editable document for Word, Pages and Google Docs"
        case .pptx: "One slide per page, for PowerPoint, Keynote and Google Slides"
        }
    }

    var isLossy: Bool { self == .webp || self == .jpeg || self == .heic }
    var supportsTransparency: Bool { self == .webp || self == .png || self == .heic || self == .tiff || self == .gif || self == .pdf }
    var isLossyAudio: Bool { self == .mp3 || self == .m4a }

    /// The output format a file already is, if any.
    static func from(_ type: UTType) -> OutputFormat? {
        // Audio first: M4A also conforms to public.mpeg-4.
        if type.conforms(to: .audio) { return allCases.first { $0.kind == .audio && type.conforms(to: $0.utType) } }
        if type.conforms(to: .quickTimeMovie) { return .mov }
        if let webm = UTType("org.webmproject.webm"), type.conforms(to: webm) { return .webm }
        if let mkv = UTType("org.matroska.mkv"), type.conforms(to: mkv) { return .mkv }
        if type.conforms(to: .mpeg4Movie) { return .mp4 }
        return allCases.first { $0.kind == .image && type.conforms(to: $0.utType) }
    }
}

enum FormatCatalog {
    /// Kept as extensions so the sandboxed Finder extension never needs to touch the file.
    static let extensionsByKind: [MediaKind: Set<String>] = [
        .image: ["jpg", "jpeg", "jpe", "png", "heic", "heif", "webp", "tif", "tiff", "gif",
                 "bmp", "avif", "jp2", "tga", "psd", "ico", "icns", "dng", "cr2", "cr3",
                 "nef", "arw", "raf", "orf", "rw2", "exr"],
        .video: ["mov", "mp4", "m4v", "3gp", "mkv", "webm", "avi", "wmv", "flv", "f4v", "mpg", "mpeg", "m2v",
                 "ts", "mts", "m2ts", "ogv", "vob", "divx", "asf", "3g2"],
        .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "m4b", "ogg", "oga", "opus",
                 "wma", "ac3", "amr", "ape", "mka", "wv"],
        .pdf: ["pdf"],
        .office: ["doc", "docx", "dotx", "rtf", "odt", "pages", "ppt", "pptx", "pps", "ppsx", "odp", "key",
                  "xls", "xlsx", "xlsm", "ods", "numbers"],
    ]

    static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        return extensionsByKind.first { $0.value.contains(ext) }?.key
    }

    static func isConvertible(_ url: URL) -> Bool { kind(of: url) != nil }

    /// Containers macOS reads natively; everything else goes through the bundled FFmpeg.
    private static let nativeMedia: Set<String> = ["mov", "mp4", "m4v", "3gp", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "m4b"]

    static func needsFFmpeg(_ url: URL) -> Bool {
        guard let kind = kind(of: url), kind == .video || kind == .audio else { return false }
        return !nativeMedia.contains(url.pathExtension.lowercased())
    }

    /// The single kind a selection shares, or nil when it's mixed.
    static func sharedKind(of urls: [URL]) -> MediaKind? {
        let kinds = Set(urls.compactMap(kind(of:)))
        return kinds.count == 1 ? kinds.first : nil
    }

    static func targets(for kind: MediaKind) -> [OutputFormat] {
        switch kind {
        case .image: [.webp, .jpeg, .png, .heic, .pdf, .tiff, .gif, .bmp]
        case .video: [.mp4, .mp4hevc, .webm, .gif, .mov, .mkv, .mp3, .m4a, .wav]
        case .audio: [.mp3, .m4a, .wav, .flac, .aiff]
        case .pdf: [.docx, .pptx, .png, .jpeg, .webp, .heic, .tiff, .txt]
        case .office: [.pdf]
        }
    }

    /// Output choices for a selection, excluding the format the files already
    /// share (re-encoding PNG as PNG belongs under Optimize, not Convert).
    static func conversionTargets(for urls: [URL]) -> [OutputFormat] {
        guard let kind = sharedKind(of: urls) else { return [] }
        let sources = Set(urls.compactMap { UTType(filenameExtension: $0.pathExtension).flatMap(OutputFormat.from) })
        guard sources.count == 1, let only = sources.first else { return targets(for: kind) }
        return targets(for: kind).filter { $0 != only }
    }

    /// The Finder menu's second item, if this kind of file has one.
    static func optimizeTitle(for kind: MediaKind) -> String? {
        switch kind {
        case .image: "Optimize for Web…"
        case .video: "Compress Video…"
        case .pdf: "Compress PDF…"
        case .audio, .office: nil
        }
    }

    /// Two or more images and/or PDFs can be merged into one PDF.
    static func combineTitle(for urls: [URL]) -> String? {
        let kinds = urls.compactMap(kind(of:))
        guard urls.count >= 2, kinds.count == urls.count, kinds.allSatisfy({ $0 == .image || $0 == .pdf }) else { return nil }
        return kinds.allSatisfy { $0 == .image } ? "Combine into PDF…" : "Combine into One PDF…"
    }
}

/// The URL the Finder extension opens to wake the app:
/// macconvert://run?mode=convert&format=webp&file=/a.png&file=/b.png
enum Handoff {
    static let scheme = "macconvert"

    enum Mode: String { case convert, optimize, combine }

    static func url(mode: Mode, format: OutputFormat?, files: [URL]) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "run"
        var items = [URLQueryItem(name: "mode", value: mode.rawValue)]
        if let format { items.append(URLQueryItem(name: "format", value: format.rawValue)) }
        items += files.map { URLQueryItem(name: "file", value: $0.path) }
        c.queryItems = items
        return c.url
    }

    static func parse(_ url: URL) -> (mode: Mode, format: OutputFormat?, files: [URL])? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mode = items.first(where: { $0.name == "mode" })?.value.flatMap(Mode.init) else { return nil }
        let format = items.first(where: { $0.name == "format" })?.value.flatMap(OutputFormat.init)
        let files = items.filter { $0.name == "file" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
        return (mode, format, files)
    }
}
