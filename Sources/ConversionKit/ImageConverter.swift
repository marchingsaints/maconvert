import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageInfo {
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let hasAlpha: Bool
}

enum ConversionError: LocalizedError {
    case unreadable(URL)
    case encodeFailed(OutputFormat)
    case noAudio
    case locked(URL)
    case noText
    case missingTool(String)
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Couldn't read \(url.lastPathComponent)"
        case .encodeFailed(let format): "Couldn't encode \(format.displayName)"
        case .noAudio: "This file has no sound to extract"
        case .locked(let url): "\(url.lastPathComponent) is password-protected"
        case .noText: "No text found. It may be a scan, which is just pictures of pages."
        case .missingTool(let tool): "\(tool) is missing from the app"
        case .toolFailed(let tool, let reason): "\(tool) couldn't convert this: \(reason)"
        }
    }
}

enum ImageConverter {
    static func info(for url: URL) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Orientations 5–8 are rotated 90°, so width and height swap on screen.
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ImageInfo(pixelWidth: w, pixelHeight: h, byteCount: size,
                         hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false)
    }

    static func thumbnail(for url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// Encodes `url` with `options` and returns the bytes without writing anything,
    /// so the panel can show the real output size before you commit.
    static func encode(_ url: URL, as format: OutputFormat, options: ImageOptions) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { throw ConversionError.unreadable(url) }

        let longest = max(w, h)
        let target = min(options.maxDimension ?? longest, longest)
        // The thumbnail API decodes, rotates to upright, and downsamples in one fast pass.
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw ConversionError.unreadable(url) }

        return try encode(image, as: format, options: options, sourceProperties: props)
    }

    /// Encodes an already-decoded, upright image (also used for rendered PDF pages).
    static func encode(_ image: CGImage, as format: OutputFormat, options: ImageOptions, sourceProperties: [CFString: Any] = [:]) throws -> Data {
        var image = image
        if !format.supportsTransparency, image.hasAlpha {
            image = flattened(image) ?? image
        }
        if format == .webp {
            return try WebPEncoder.encode(image, quality: options.quality, lossless: options.lossless)
        }
        return try imageIOEncode(image, as: format, sourceProperties: sourceProperties, options: options)
    }

    private static func imageIOEncode(_ image: CGImage, as format: OutputFormat, sourceProperties: [CFString: Any], options: ImageOptions) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.encodeFailed(format)
        }
        var props: [CFString: Any] = [:]
        if !options.stripMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let v = sourceProperties[key] { props[key] = v }
            }
            // Pixels are already upright, so the orientation tag must say so.
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        props[kCGImagePropertyOrientation] = 1
        if format.isLossy {
            props[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.encodeFailed(format) }
        return data as Data
    }

    /// Composites onto white, for formats without transparency (JPEG, BMP).
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
