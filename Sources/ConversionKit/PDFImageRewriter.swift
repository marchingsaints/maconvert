import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Recompresses the JPEG images inside a PDF in place, leaving everything else byte-for-byte.
///
/// Quartz's own "reduce size" filter only JPEG-compresses images it downsamples; images
/// already at or below the target resolution come out *losslessly* re-encoded, often 10×
/// larger. This handles those. It only accepts the classic layout Quartz writes
/// (numbered objects, direct stream lengths, an xref table), and is fed Quartz output.
enum PDFImageRewriter {
    static func rewrite(_ src: URL, to dst: URL, quality: PDFQuality) throws {
        let data = try Data(contentsOf: src)
        guard let pdf = CGPDFDocument(src as CFURL) else { throw ConversionError.unreadable(src) }
        let usage = DrawnSizes.measure(pdf)

        var objects = try parseObjects(data)
        var changed = false
        for i in objects.indices {
            guard let stream = objects[i].stream, has(objects[i].dict, #"/Subtype\s*/Image\b"#),
                  let maxDrawn = usage[SHA256.hash(data: data[stream]).description],
                  let replacement = recompress(data[stream], dict: objects[i].dict, drawnInches: maxDrawn, quality: quality) else { continue }
            objects[i].replacement = replacement
            changed = true
        }
        guard changed else { throw ConversionError.encodeFailed(.pdf) }
        try assemble(data, objects: objects).write(to: dst)
    }

    // MARK: Image recompression

    /// A smaller JPEG for this image stream, or nil to leave it untouched.
    private static func recompress(_ jpeg: Data, dict: String, drawnInches: CGSize, quality: PDFQuality) -> (dict: String, data: Data)? {
        // Plain 8-bit JPEGs only: no masks-as-images, decode arrays, filter chains or CMYK.
        guard has(dict, #"/Filter\s*/DCTDecode\b"#), !has(dict, #"/Decode\s*\["#),
              !has(dict, #"/ImageMask\s+true"#), has(dict, #"/BitsPerComponent\s+8\b"#),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = image.colorSpace, space.numberOfComponents == 1 || space.numberOfComponents == 3 else { return nil }

        // Enough pixels for the target dpi at the largest size the image is drawn; never upscale.
        // Masked images keep their size so the mask still lines up.
        let need = max(drawnInches.width, drawnInches.height) * CGFloat(quality.dpi)
        let longest = CGFloat(max(image.width, image.height))
        let scale = has(dict, #"/SMask\b"#) ? 1 : min(1, need / longest)
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))

        // Re-tag as device colour so ImageIO doesn't embed an ICC profile per image:
        // the PDF's /ColorSpace already says how to read these values.
        let gray = space.numberOfComponents == 1
        let device = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: device,
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
              let retagged = image.copy(colorSpace: device) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(retagged, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, pixels, [kCGImageDestinationLossyCompressionQuality: quality.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length < jpeg.count * 9 / 10 else { return nil }

        var newDict = dict.replacingOccurrences(of: #"/Length\s+\d+"#, with: "/Length \(out.length)", options: .regularExpression)
        if w != image.width || h != image.height {
            newDict = newDict.replacingOccurrences(of: #"/Width\s+\d+"#, with: "/Width \(w)", options: .regularExpression)
                .replacingOccurrences(of: #"/Height\s+\d+"#, with: "/Height \(h)", options: .regularExpression)
        }
        return (newDict, out as Data)
    }

    private static func has(_ dict: String, _ pattern: String) -> Bool {
        dict.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Parsing and writing

    private struct Object {
        let number: Int
        let range: Range<Int>      // "N 0 obj" … "endobj"
        let dict: String
        let stream: Range<Int>?
        var replacement: (dict: String, data: Data)?
    }

    private static func parseObjects(_ data: Data) throws -> [Object] {
        let bytes = [UInt8](data)
        var objects: [Object] = []
        var i = 0
        func find(_ s: String, from: Int) -> Int? {
            let needle = Array(s.utf8)
            guard needle.count <= bytes.count else { return nil }
            var j = from
            while j <= bytes.count - needle.count {
                if bytes[j] == needle[0], Array(bytes[j..<j + needle.count]) == needle { return j }
                j += 1
            }
            return nil
        }
        let header = try NSRegularExpression(pattern: #"^(\d+) 0 obj\s*"#, options: .anchorsMatchLines)

        while let objStart = find(" 0 obj", from: i) {
            // Walk back to the start of the object number on this line.
            var start = objStart
            while start > 0, bytes[start - 1] >= 0x30, bytes[start - 1] <= 0x39 { start -= 1 }
            let lineEnd = min(bytes.count, objStart + 6)
            guard let headerText = String(bytes: bytes[start..<lineEnd], encoding: .ascii),
                  let m = header.firstMatch(in: headerText, range: NSRange(headerText.startIndex..., in: headerText)),
                  let number = Int((headerText as NSString).substring(with: m.range(at: 1))) else { i = objStart + 6; continue }

            let body = objStart + 6
            let streamKeyword = find("stream", from: body)
            let endObj = find("endobj", from: body)
            guard let endObjFirst = endObj else { throw ConversionError.unreadable(URL(fileURLWithPath: "pdf")) }

            var dict = ""
            var stream: Range<Int>?
            var end = endObjFirst
            // A real stream keyword follows the dictionary's closing ">>"; the word inside a string doesn't.
            if let s = streamKeyword, s < endObjFirst,
               String(decoding: bytes[body..<s], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(">>") {
                dict = String(decoding: bytes[body..<s], as: UTF8.self)
                // PDF allows any whitespace between key and value; an indirect "/Length 12 0 R" isn't ours.
                guard let lengthText = dict.range(of: #"/Length\s+\d+\b(?!\s+\d+\s+R)"#, options: .regularExpression),
                      let length = Int(dict[lengthText].dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw ConversionError.unreadable(URL(fileURLWithPath: "pdf"))
                }
                var dataStart = s + 6
                if bytes[dataStart] == 0x0D { dataStart += 1 }
                if bytes[dataStart] == 0x0A { dataStart += 1 }
                stream = dataStart..<(dataStart + length)
                guard let e = find("endobj", from: dataStart + length) else { throw ConversionError.unreadable(URL(fileURLWithPath: "pdf")) }
                end = e
            } else {
                dict = String(decoding: bytes[body..<endObjFirst], as: UTF8.self)
            }
            objects.append(Object(number: number, range: start..<(end + 6), dict: dict, stream: stream))
            i = end + 6
        }
        guard !objects.isEmpty, find("xref", from: objects.last!.range.upperBound) != nil else {
            // Cross-reference streams or other layouts: not ours to rewrite.
            throw ConversionError.unreadable(URL(fileURLWithPath: "pdf"))
        }
        return objects
    }

    /// Writes the objects back with a fresh xref table and the original trailer.
    private static func assemble(_ data: Data, objects: [Object]) throws -> Data {
        let bytes = [UInt8](data)
        guard let trailerStart = String(decoding: bytes[objects.last!.range.upperBound...], as: UTF8.self).range(of: "trailer"),
              let tail = Optional(String(decoding: bytes[objects.last!.range.upperBound...], as: UTF8.self)),
              let startxref = tail.range(of: "startxref") else { throw ConversionError.unreadable(URL(fileURLWithPath: "pdf")) }
        let trailer = String(tail[trailerStart.lowerBound..<startxref.lowerBound])

        var out = Data(bytes[0..<objects[0].range.lowerBound])
        var offsets: [Int: Int] = [:]
        for object in objects {
            offsets[object.number] = out.count
            if let replacement = object.replacement {
                out.append(Data("\(object.number) 0 obj\n\(replacement.dict.trimmingCharacters(in: .whitespacesAndNewlines))\nstream\n".utf8))
                out.append(replacement.data)
                out.append(Data("\nendstream\nendobj\n".utf8))
            } else {
                out.append(Data(bytes[object.range]))
                out.append(0x0A)
            }
        }
        let size = (offsets.keys.max() ?? 0) + 1
        let xrefOffset = out.count
        var xref = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size {
            xref += offsets[n].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 65535 f \n"
        }
        out.append(Data(xref.utf8))
        out.append(Data(trailer.utf8))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }
}

/// Finds the largest size (in inches) each image is drawn at, keyed by a hash of its
/// stream bytes so it can be matched to the raw object later.
private final class DrawnSizes {
    var sizes: [String: CGSize] = [:]
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var streams: [CGPDFContentStreamRef] = []

    static func measure(_ pdf: CGPDFDocument) -> [String: CGSize] {
        let state = DrawnSizes()
        guard pdf.numberOfPages > 0 else { return [:] }
        for i in 1...pdf.numberOfPages {
            guard let page = pdf.page(at: i) else { continue }
            state.ctm = .identity
            state.stack = []
            state.scan(CGPDFContentStreamCreateWithPage(page))
        }
        return state.sizes
    }

    func scan(_ content: CGPDFContentStreamRef) {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = Unmanaged<DrawnSizes>.fromOpaque(info!).takeUnretainedValue()
            s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = Unmanaged<DrawnSizes>.fromOpaque(info!).takeUnretainedValue()
            if let last = s.stack.popLast() { s.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = Unmanaged<DrawnSizes>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for k in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[k]) else { return } }
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = Unmanaged<DrawnSizes>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, let content = s.streams.last,
                  let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dict, "Subtype", &subtype)
            switch subtype.map({ String(cString: $0) }) {
            case "Image":
                // The image fills the unit square under the CTM.
                let w = hypot(s.ctm.a, s.ctm.b) / 72, h = hypot(s.ctm.c, s.ctm.d) / 72
                var format = CGPDFDataFormat.raw
                guard let raw = CGPDFStreamCopyData(stream, &format) else { return }
                let key = SHA256.hash(data: raw as Data).description
                let old = s.sizes[key] ?? .zero
                s.sizes[key] = CGSize(width: max(old.width, w), height: max(old.height, h))
            case "Form":
                var matrix: CGPDFArrayRef?
                var m = [CGPDFReal](repeating: 0, count: 6)
                let saved = s.ctm
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, (0..<6).allSatisfy({ CGPDFArrayGetNumber(matrix, $0, &m[$0]) }) {
                    s.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(s.ctm)
                }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                // Forms without their own resources inherit the page's through `parent`.
                s.scan(CGPDFContentStreamCreateWithStream(stream, resources ?? dict, content))
                s.ctm = saved
            default:
                break
            }
        }
        streams.append(content)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        streams.removeLast()
    }
}
