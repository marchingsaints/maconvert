import Accelerate
import CoreGraphics
import Foundation

/// WebP via Google's libwebp (linked statically); macOS can read WebP but not write it.
enum WebPEncoder {
    static func encode(_ image: CGImage, quality: Double, lossless: Bool) throws -> Data {
        let width = image.width, height = image.height
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)

        // Draw into an sRGB RGBA buffer, then un-premultiply: libwebp wants straight alpha.
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var v = vImage_Buffer(data: buf.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
            vImageUnpremultiplyData_RGBA8888(&v, &v, vImage_Flags(kvImageNoFlags))
            return true
        }
        guard drawn else { throw ConversionError.encodeFailed(.webp) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw ConversionError.encodeFailed(.webp) }
        config.quality = Float(quality * 100)
        config.method = 4          // speed/size balance; 6 is ~2x slower for ~2% smaller
        config.use_sharp_yuv = 1   // keeps colour edges crisp at lower quality
        if lossless {
            config.lossless = 1
            config.exact = 0
        }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ConversionError.encodeFailed(.webp) }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = lossless ? 1 : 0

        let hasAlpha = image.hasAlpha
        let imported = pixels.withUnsafeBufferPointer { p in
            hasAlpha ? WebPPictureImportRGBA(&picture, p.baseAddress, Int32(stride))
                     : WebPPictureImportRGBX(&picture, p.baseAddress, Int32(stride))
        }
        guard imported != 0 else { throw ConversionError.encodeFailed(.webp) }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }

        let ok = withUnsafeMutablePointer(to: &writer) { w -> Int32 in
            picture.writer = { data, size, pic in WebPMemoryWrite(data, size, pic) }
            picture.custom_ptr = UnsafeMutableRawPointer(w)
            return WebPEncode(&config, &picture)
        }
        guard ok != 0, let mem = writer.mem else { throw ConversionError.encodeFailed(.webp) }
        return Data(bytes: mem, count: writer.size)
    }
}
