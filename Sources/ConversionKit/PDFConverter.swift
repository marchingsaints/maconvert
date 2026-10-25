import ImageIO
import PDFKit
import Quartz

enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        if doc.isLocked { throw ConversionError.locked(url) }
        return doc
    }

    // MARK: Compress

    /// Re-saves every picture in the PDF at a lower resolution and JPEG quality.
    /// Text, vector drawings, links and bookmarks are untouched.
    static func compress(_ src: URL, to dst: URL, quality: PDFQuality) throws {
        let original = try open(src)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Quartz's filter re-encodes every image a page *lists*, not just the ones it draws.
        // Some PDFs (flipbooks, catalogues) list all their images on every page, so
        // filtering them directly multiplies the size. Redrawing first keeps only what's used.
        let pruned = tmp.appendingPathComponent("pruned.pdf")
        try redraw(src, to: pruned)

        // Two ways to shrink pictures; each wins on different PDFs, so try both and keep the smaller.
        // 1. Quartz's filter: great at downsampling big photos, but re-saves images it
        //    doesn't shrink losslessly (10× bigger for already-small JPEGs).
        // 2. Our rewriter: recompresses each JPEG in place at the target dpi and quality.
        // The plain redraw is the fallback, so a PDF that can't shrink never grows.
        var candidates: [URL] = [pruned]
        let filtered = tmp.appendingPathComponent("filtered.pdf")
        if let doc = PDFDocument(url: pruned) {
            let option = PDFDocumentWriteOption(rawValue: "QuartzFilter")
            if doc.write(to: filtered, withOptions: [option: try filter(for: quality)]) { candidates.append(filtered) }
        }
        let rewritten = tmp.appendingPathComponent("rewritten.pdf")
        if (try? PDFImageRewriter.rewrite(pruned, to: rewritten, quality: quality)) != nil { candidates.append(rewritten) }

        let best = candidates.min { BatchRunner.size(of: $0) < BatchRunner.size(of: $1) }
        guard let best, let doc = PDFDocument(url: best), doc.pageCount == original.pageCount else {
            throw ConversionError.encodeFailed(.pdf)
        }
        restoreStructure(from: original, to: doc)
        guard doc.write(to: dst) else { throw ConversionError.encodeFailed(.pdf) }
    }

    /// Draws each page into a fresh PDF. Quartz writes only the resources a page actually
    /// draws, and still writes shared ones (fonts, a logo on every page) once.
    private static func redraw(_ src: URL, to dst: URL) throws {
        guard let source = CGPDFDocument(src as CFURL) else { throw ConversionError.unreadable(src) }
        var box = CGRect.zero
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, nil) else { throw ConversionError.encodeFailed(.pdf) }
        for i in 1...max(source.numberOfPages, 1) {
            guard let page = source.page(at: i) else { continue }
            var media = page.getBoxRect(.mediaBox)
            ctx.beginPage(mediaBox: &media)
            ctx.drawPDFPage(page)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// A redraw keeps how pages look but not what PDFKit layers on top: rotation,
    /// crop, links, form fields, bookmarks and document info. Copy those back.
    private static func restoreStructure(from original: PDFDocument, to doc: PDFDocument) {
        func remap(_ dest: PDFDestination?) -> PDFDestination? {
            guard let dest, let page = dest.page, let target = doc.page(at: original.index(for: page)) else { return nil }
            return PDFDestination(page: target, at: dest.point)
        }

        for i in 0..<original.pageCount {
            guard let from = original.page(at: i), let to = doc.page(at: i) else { continue }
            to.rotation = from.rotation
            to.setBounds(from.bounds(for: .cropBox), for: .cropBox)
            for annotation in from.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else { continue }
                if let dest = remap(annotation.destination) { copy.destination = dest }
                if let goTo = annotation.action as? PDFActionGoTo, let dest = remap(goTo.destination) {
                    copy.action = PDFActionGoTo(destination: dest)
                }
                to.addAnnotation(copy)
            }
        }

        func copyOutline(_ from: PDFOutline) -> PDFOutline {
            let item = PDFOutline()
            item.label = from.label
            item.isOpen = from.isOpen
            if let dest = remap(from.destination) { item.destination = dest }
            if let goTo = from.action as? PDFActionGoTo, let dest = remap(goTo.destination) { item.action = PDFActionGoTo(destination: dest) }
            else if let action = from.action as? PDFActionURL { item.action = action }
            for i in 0..<from.numberOfChildren {
                if let child = from.child(at: i) { item.insertChild(copyOutline(child), at: item.numberOfChildren) }
            }
            return item
        }
        if let root = original.outlineRoot { doc.outlineRoot = copyOutline(root) }
        doc.documentAttributes = original.documentAttributes
    }

    /// Same structure as Preview's "Reduce File Size" filter, with gentler settings.
    private static func filter(for quality: PDFQuality) throws -> QuartzFilter {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacConvert-\(quality.rawValue).qfilter")
        let plist: NSDictionary = [
            "Name": "MacConvert \(quality.title)",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "ImageCompression": "ImageJPEGCompress",
                "Compression Quality": quality.jpegQuality,
                "ImageScaleSettings": [
                    "ImageResolution": quality.dpi,
                    "ImageScaleInterpolate": true,
                    "ImageSizeMax": 0,
                    "ImageSizeMin": 0,
                ],
            ]]],
        ]
        guard plist.write(to: url, atomically: true), let filter = QuartzFilter(url: url) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        return filter
    }

    // MARK: Pages → images

    /// One page writes a single image at `dst`; more write a folder of numbered images.
    static func renderPages(_ src: URL, to dst: URL, format: OutputFormat, dpi: Int, options: ImageOptions,
                            cancel: CancelFlag, progress: (Double) -> Void) throws {
        let doc = try open(src)
        let count = doc.pageCount
        let base = src.deletingPathExtension().lastPathComponent
        if count > 1 { try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true) }
        let digits = String(count).count

        for i in 0..<count {
            if cancel.isSet { throw CancellationError() }
            guard let page = doc.page(at: i), let image = render(page, dpi: dpi) else { throw ConversionError.unreadable(src) }
            let data = try ImageConverter.encode(image, as: format, options: options)
            let number = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
            let out = count == 1 ? dst : dst.appendingPathComponent("\(base)-\(number)").appendingPathExtension(format.fileExtension)
            try data.write(to: out)
            progress(Double(i + 1) / Double(count))
        }
    }

    static func render(_ page: PDFPage, dpi: Int) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        // Keep huge pages (posters, plans) under ~100 megapixels.
        let scale = min(CGFloat(dpi) / 72, 10_000 / max(size.width, size.height))
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: Text

    static func extractText(_ src: URL, to dst: URL) throws {
        let text = try open(src).string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw ConversionError.noText }
        try text.write(to: dst, atomically: true, encoding: .utf8)
    }

    // MARK: Combine

    /// Merges PDFs and images, in order, into one PDF. Images become pages.
    static func combine(_ files: [URL], to dst: URL, options: PDFOptions, image: ImageOptions,
                        cancel: CancelFlag, progress: (Double) -> Void) throws {
        let out = PDFDocument()
        // Copied pages still draw from their source documents, so keep those alive until written.
        var sources: [PDFDocument] = []
        for (i, file) in files.enumerated() {
            if cancel.isSet { throw CancellationError() }
            let doc = FormatCatalog.kind(of: file) == .pdf ? try open(file) : try imagePage(file, pageSize: options.pageSize, options: image)
            sources.append(doc)
            for p in 0..<doc.pageCount {
                if let page = doc.page(at: p)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
            }
            progress(Double(i + 1) / Double(files.count + 1))
        }
        out.documentAttributes = [PDFDocumentAttribute.titleAttribute: dst.deletingPathExtension().lastPathComponent]
        guard out.write(to: dst) else { throw ConversionError.encodeFailed(.pdf) }
        withExtendedLifetime(sources) {}
    }

    /// A one-page PDF holding the image, fitted to the page with a small margin.
    /// Photos are embedded as JPEG (PDF stores JPEG data as-is); transparent images stay lossless.
    static func imagePage(_ url: URL, pageSize: PageSize, options: ImageOptions) throws -> PDFDocument {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
              let decoded = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: min(options.maxDimension ?? max(pw, ph), max(pw, ph)),
              ] as CFDictionary) else { throw ConversionError.unreadable(url) }

        var embedded = decoded
        if !decoded.hasAlpha {
            let jpeg = try ImageConverter.encode(decoded, as: .jpeg, options: options)
            if let s = CGImageSourceCreateWithData(jpeg as CFData, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { embedded = img }
        }

        let imageSize = CGSize(width: decoded.width, height: decoded.height)
        var mediaBox: CGRect
        let imageRect: CGRect
        if let portrait = pageSize.points {
            // Landscape pictures get a landscape page.
            let page = imageSize.width > imageSize.height ? CGSize(width: portrait.height, height: portrait.width) : portrait
            mediaBox = CGRect(origin: .zero, size: page)
            let area = mediaBox.insetBy(dx: 28, dy: 28)
            let s = min(area.width / imageSize.width, area.height / imageSize.height)
            let fitted = CGSize(width: imageSize.width * s, height: imageSize.height * s)
            imageRect = CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        } else {
            let s = 842 / max(imageSize.width, imageSize.height)
            mediaBox = CGRect(x: 0, y: 0, width: imageSize.width * s, height: imageSize.height * s)
            imageRect = mediaBox
        }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw ConversionError.encodeFailed(.pdf) }
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(embedded, in: imageRect)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data) else { throw ConversionError.encodeFailed(.pdf) }
        return doc
    }
}
