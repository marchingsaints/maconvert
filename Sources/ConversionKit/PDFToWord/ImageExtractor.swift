import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a PDF image XObject back into a picture file, without re-rendering the page
/// (so text drawn on top of a photo doesn't end up baked into it).
enum ImageExtractor {
    struct Extracted {
        let image: CGImage
        /// The untouched JPEG when the PDF stored one that Word can use as-is.
        let originalJPEG: Data?
    }

    static func extract(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef) -> Extracted? {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cfData as Data

        switch format {
        case .jpegEncoded, .JPEG2000:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let components = image.colorSpace?.numberOfComponents ?? 0
            // CMYK JPEGs and JPEG 2000 display unreliably in Word and Google Docs; re-encode those.
            let usable = format == .jpegEncoded && (components == 1 || components == 3) && !hasSoftMask(dict)
            if hasSoftMask(dict), let masked = applySoftMask(image, dict) { return Extracted(image: masked, originalJPEG: nil) }
            return Extracted(image: image, originalJPEG: usable ? data : nil)
        default:
            guard let image = decodeRaw(data, dict) else { return nil }
            return Extracted(image: applySoftMask(image, dict) ?? image, originalJPEG: nil)
        }
    }

    // MARK: Raw samples

    private static func decodeRaw(_ data: Data, _ dict: CGPDFDictionaryRef) -> CGImage? {
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h), w > 0, h > 0 else { return nil }
        CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)
        guard let space = colorSpace(dict) else { return nil }

        switch space {
        case .device(let cs):
            let n = cs.numberOfComponents
            let bytesPerRow = (Int(w) * n * Int(bpc) + 7) / 8
            guard data.count >= bytesPerRow * Int(h), let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: Int(w), height: Int(h), bitsPerComponent: Int(bpc), bitsPerPixel: n * Int(bpc), bytesPerRow: bytesPerRow,
                           space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .indexed(let palette, let baseComponents):
            // Expand palette indices to RGB (or grey) samples.
            let count = Int(w) * Int(h)
            let bytesPerRow = (Int(w) * Int(bpc) + 7) / 8
            guard data.count >= bytesPerRow * Int(h), [1, 2, 4, 8].contains(Int(bpc)) else { return nil }
            var out = [UInt8](repeating: 0, count: count * 3)
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0..<Int(h) {
                    for x in 0..<Int(w) {
                        let bit = x * Int(bpc)
                        let byte = src[y * bytesPerRow + bit / 8]
                        let index = Int(byte >> (8 - Int(bpc) - bit % 8)) & ((1 << Int(bpc)) - 1)
                        let o = (y * Int(w) + x) * 3
                        for c in 0..<3 {
                            let p = index * baseComponents + (baseComponents == 1 ? 0 : c)
                            out[o + c] = p < palette.count ? palette[p] : 0
                        }
                    }
                }
            }
            guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
            return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: Int(w) * 3,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    private enum Space {
        case device(CGColorSpace)
        case indexed(palette: [UInt8], baseComponents: Int)
    }

    private static func colorSpace(_ dict: CGPDFDictionaryRef) -> Space? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let name { return device(String(cString: name), components: nil) }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "ColorSpace", &array), let array else {
            // Some images only say BitsPerComponent 1 (stencil-like); treat as grey.
            return .device(CGColorSpaceCreateDeviceGray())
        }
        return space(from: array)
    }

    private static func space(from array: CGPDFArrayRef) -> Space? {
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            var n: CGPDFInteger = 3
            if CGPDFArrayGetStream(array, 1, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) { CGPDFDictionaryGetInteger(d, "N", &n) }
            return device(nil, components: Int(n))
        case "CalRGB", "Lab": return .device(CGColorSpaceCreateDeviceRGB())
        case "CalGray": return .device(CGColorSpaceCreateDeviceGray())
        case "Indexed":
            var baseComponents = 3
            var baseName: UnsafePointer<CChar>?
            var baseArray: CGPDFArrayRef?
            if CGPDFArrayGetName(array, 1, &baseName), let baseName {
                baseComponents = String(cString: baseName) == "DeviceGray" ? 1 : String(cString: baseName) == "DeviceCMYK" ? 4 : 3
            } else if CGPDFArrayGetArray(array, 1, &baseArray), let baseArray, case .device(let cs)? = space(from: baseArray) {
                baseComponents = cs.numberOfComponents
            }
            guard baseComponents != 4 else { return nil } // CMYK palettes: leave to the page renderer
            var lookup: [UInt8] = []
            var string: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                lookup = Array(UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(string)))
            } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
                var f = CGPDFDataFormat.raw
                if let d = CGPDFStreamCopyData(stream, &f) { lookup = [UInt8](d as Data) }
            }
            return .indexed(palette: lookup, baseComponents: baseComponents)
        default:
            return nil
        }
    }

    private static func device(_ name: String?, components: Int?) -> Space? {
        switch name ?? (components == 1 ? "DeviceGray" : components == 4 ? "DeviceCMYK" : "DeviceRGB") {
        case "DeviceGray", "G": return .device(CGColorSpaceCreateDeviceGray())
        case "DeviceRGB", "RGB": return .device(CGColorSpaceCreateDeviceRGB())
        case "DeviceCMYK", "CMYK": return .device(CGColorSpaceCreateDeviceCMYK())
        default: return nil
        }
    }

    // MARK: Transparency

    private static func hasSoftMask(_ dict: CGPDFDictionaryRef) -> Bool {
        var stream: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(dict, "SMask", &stream)
    }

    /// Combines the image with its /SMask (a greyscale alpha channel) into an RGBA image.
    private static func applySoftMask(_ image: CGImage, _ dict: CGPDFDictionaryRef) -> CGImage? {
        var maskStream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dict, "SMask", &maskStream), let maskStream, let maskDict = CGPDFStreamGetDictionary(maskStream),
              let mask = extract(maskStream, maskDict)?.image else { return nil }
        let w = image.width, h = image.height
        // Resample the mask to the image's size.
        var alpha = [UInt8](repeating: 255, count: w * h)
        guard let maskCtx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        maskCtx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<(w * h) {
            let a = UInt16(alpha[i])
            for c in 0..<3 { rgba[i * 4 + c] = UInt8(UInt16(rgba[i * 4 + c]) * a / 255) }
            rgba[i * 4 + 3] = UInt8(a)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Output

    static func flipped(_ image: CGImage, horizontally: Bool) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if horizontally {
            ctx.translateBy(x: CGFloat(image.width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(image.height))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// PNG keeps line art and transparency crisp; big opaque photos go to JPEG to keep the .docx small.
    static func encode(_ image: CGImage) -> (data: Data, ext: String)? {
        let photo = !image.hasAlpha && image.width * image.height > 400_000
        let format: OutputFormat = photo ? .jpeg : .png
        guard let data = try? ImageConverter.encode(image, as: format, options: ImageOptions(quality: 0.9, stripMetadata: true)) else { return nil }
        return (data, photo ? "jpg" : "png")
    }
}
