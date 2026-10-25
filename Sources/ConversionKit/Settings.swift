import Foundation

/// Everything the panel can set. Only the part matching the output format is used.
struct ConversionSettings: Equatable, Codable {
    var format: OutputFormat
    var image = ImageOptions()
    var video = VideoOptions()
    var audio = AudioOptions()
    var gif = GIFOptions()
    var pdf = PDFOptions()
}

struct ImageOptions: Equatable, Codable {
    /// 0...1, used by lossy formats.
    var quality: Double = 0.82
    /// Longest edge in pixels; nil keeps the original size. Never upscales.
    var maxDimension: Int? = nil
    var stripMetadata: Bool = false
    /// WebP only: lossless mode.
    var lossless: Bool = false
}

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    /// Copy the video stream as-is: instant and lossless, only the container changes.
    case original, high, medium, small
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .high: "High"
        case .medium: "Medium"
        case .small: "Small"
        }
    }

    /// Bits per pixel per frame for H.264; HEVC needs about two-thirds of this.
    var bitsPerPixel: Double {
        switch self {
        case .original, .high: 0.14
        case .medium: 0.09
        case .small: 0.05
        }
    }
}

struct VideoOptions: Equatable, Codable {
    /// Shorter side in pixels (1080 = "1080p" for landscape and portrait alike); nil keeps the source size.
    var maxShortSide: Int? = nil
    var quality: VideoQuality = .medium
    var removeAudio = false
}

struct AudioOptions: Equatable, Codable {
    /// MP3 and M4A only.
    var bitrateKbps = 192
}

struct GIFOptions: Equatable, Codable {
    var width = 480
    var fps = 15
}

enum PDFQuality: String, CaseIterable, Identifiable, Codable {
    case high, medium, small
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Images inside the PDF are resampled to this and re-saved as JPEG.
    var dpi: Int {
        switch self {
        case .high: 200
        case .medium: 150
        case .small: 110
        }
    }

    var jpegQuality: Double {
        switch self {
        case .high: 0.8
        case .medium: 0.65
        case .small: 0.5
        }
    }
}

enum PageSize: String, CaseIterable, Identifiable, Codable {
    case a4, letter, image
    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "Letter"
        case .image: "Fit image"
        }
    }

    /// Portrait size in points; nil means "shaped like the image".
    var points: CGSize? {
        switch self {
        case .a4: CGSize(width: 595, height: 842)
        case .letter: CGSize(width: 612, height: 792)
        case .image: nil
        }
    }

    static var local: PageSize { Locale.current.measurementSystem == .us ? .letter : .a4 }
}

struct PDFOptions: Equatable, Codable {
    /// Compress PDF.
    var quality: PDFQuality = .medium
    /// PDF → image resolution.
    var dpi = 150
    /// Image → PDF page.
    var pageSize: PageSize = .local
    /// Combine: the new file's name, without extension.
    var outputName = ""
}
