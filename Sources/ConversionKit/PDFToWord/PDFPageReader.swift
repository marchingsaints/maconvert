import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Everything on one PDF page that the Word converter cares about, in top-left coordinates
/// (y grows downward, like reading), in points.
struct PageContent {
    var size: CGSize
    var glyphs: [Glyph] = []
    var images: [PlacedImage] = []
    /// Thin horizontal/vertical strokes and hairline fills: table borders, rules, underlines.
    var hRules: [Rule] = []
    var vRules: [Rule] = []
    /// Solid non-white rectangles: cell shading, highlight boxes.
    var fills: [(rect: CGRect, color: String)] = []
    /// Curvy or complex vector art (charts, logos) that can't be expressed as text.
    var figures: [CGRect] = []
    /// Small round or square marks: list bullets drawn as shapes rather than characters.
    var dots: [(rect: CGRect, hollow: Bool)] = []
    var links: [(rect: CGRect, url: String)] = []
    /// True when the text came from OCR rather than the PDF's own text.
    var recognized = false
}

struct Glyph {
    var text: String
    var rect: CGRect
    var style: TextStyle
    var underline = false
    var link: String?
    var isSpace: Bool { text.allSatisfy(\.isWhitespace) }
}

struct TextStyle: Hashable {
    var font: String
    var size: CGFloat
    var bold: Bool
    var italic: Bool
    var color: String   // RRGGBB
}

struct Rule {
    var position: CGFloat   // y for horizontal, x for vertical
    var start: CGFloat
    var end: CGFloat
    var width: CGFloat
    var color: String
}

struct PlacedImage {
    var rect: CGRect
    var data: Data
    var ext: String         // "jpg" or "png"
}

enum PDFPageReader {
    static func read(_ page: PDFPage, ocrIfNeeded: Bool = true) -> PageContent {
        let box = page.bounds(for: .cropBox)
        // Page space → reading space: shift by the crop box, flip y, and undo /Rotate.
        let flip = displayTransform(box: box, rotation: page.rotation)
        let size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        var content = PageContent(size: size)

        content.glyphs = readGlyphs(page, flip)
        if let cgPage = page.pageRef {
            let scan = GraphicsScanner(page: cgPage, flip: flip)
            content.images = scan.images
            content.hRules = scan.hRules
            content.vRules = scan.vRules
            content.fills = scan.fills
            content.figures = scan.figures
            content.dots = scan.dots
            applyFontSpans(scan.spans, to: &content.glyphs)
        }
        for annotation in page.annotations where annotation.type == "Link" {
            if let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url {
                content.links.append((annotation.bounds.applying(flip).standardized, url.absoluteString))
            }
        }

        // A page with pictures but (almost) no text is a scan: read it with OCR.
        let textCount = content.glyphs.filter { !$0.isSpace }.count
        let pictureArea = content.images.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        if ocrIfNeeded, textCount < 20, pictureArea > size.width * size.height * 0.4 {
            var words = recognizeText(page, size: size)
            if words.count > 3 {
                content.recognized = true
                // Recognised sizes jitter; snap anything near the body size to it so only real headings stand out.
                let sizes = words.map(\.style.size).sorted()
                let body = sizes[sizes.count / 2]
                for k in words.indices where abs(words[k].style.size - body) < body * 0.22 { words[k].style.size = body }
                content.glyphs = words
                // The scan itself would duplicate the text we just recognised.
                content.images.removeAll { $0.rect.width * $0.rect.height > size.width * size.height * 0.4 }
            }
        }
        return content
    }

    static func displayTransform(box: CGRect, rotation: Int) -> CGAffineTransform {
        let toOrigin = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let w = box.width, h = box.height
        let rotate: CGAffineTransform
        switch ((rotation % 360) + 360) % 360 {
        case 90: rotate = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)            // (x, y) → (y, x), then flipped below
        case 180: rotate = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 270: rotate = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        default: rotate = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        }
        return toOrigin.concatenating(rotate)
    }

    // MARK: Text

    private static func readGlyphs(_ page: PDFPage, _ flip: CGAffineTransform) -> [Glyph] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        let text = attributed.string as NSString
        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(attributed.length)
        var styleCache: [ObjectIdentifier: TextStyle] = [:]
        // PDFKit's text can contain characters with no glyph of their own: accents split from
        // "é" (stored as one glyph), or line breaks it inserts. Each takes the next glyph's box
        // and every later box is off by one; `shift` undoes that.
        var shift = 0

        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let font = attrs[.font] as? NSFont
            let color = (attrs[.foregroundColor] as? NSColor) ?? .black
            let style: TextStyle
            if let font, let cached = styleCache[ObjectIdentifier(font)], cached.color == hex(color) {
                style = cached
            } else {
                style = textStyle(font: font, color: color)
                if let font { styleCache[ObjectIdentifier(font)] = style }
            }
            var i = range.location
            while i < NSMaxRange(range) {
                // Keep surrogate pairs (emoji, rare scripts) together.
                let r = text.rangeOfComposedCharacterSequence(at: i)
                let s = text.substring(with: r)
                i = NSMaxRange(r)
                if s == "\n" || s == "\r" {
                    // Same problem with line breaks PDFKit inserts (Chrome/Skia PDFs): a real one
                    // has a zero-width box, a phantom one has the next line's first letter's box.
                    if page.characterBounds(at: r.location - shift).width > 0.5 { shift += 1 }
                    continue
                }
                let bounds = page.characterBounds(at: r.location - shift)
                if r.length > 1, s.unicodeScalars.dropFirst().allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) {
                    // A real accent glyph overlaps its letter; a phantom one sits after it.
                    for k in 1..<r.length {
                        let mark = page.characterBounds(at: r.location + k - shift)
                        if mark.width > 0, mark.minX >= bounds.maxX - 0.5 || abs(mark.minY - bounds.minY) > bounds.height { shift += 1 }
                    }
                }
                guard bounds.width > 0 || s == " ", bounds.height > 0 else { continue }
                glyphs.append(Glyph(text: s, rect: bounds.applying(flip).standardized, style: style))
            }
        }
        return glyphs
    }

    static func textStyle(font: NSFont?, color: NSColor) -> TextStyle {
        let name = font?.fontName ?? "Helvetica"
        let lower = name.lowercased()
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let bold = traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demibold", "-demi"].contains { lower.contains($0) }
        let italic = traits.contains(.italic) || lower.contains("italic") || lower.contains("oblique")
        return TextStyle(font: family(of: font), size: ((font?.pointSize ?? 12) * 2).rounded() / 2, bold: bold, italic: italic, color: hex(color))
    }

    /// "ABCDEF+TimesNewRomanPS-BoldMT" → "Times New Roman".
    static func family(of font: NSFont?) -> String {
        guard let font else { return "Calibri" }
        var name = font.familyName ?? font.fontName
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { name = String(name[name.index(after: plus)...]) }
        if name.contains(" ") { return FontResolver.resolve(name, serif: false, mono: font.isFixedPitch) }
        // Embedded fonts often only carry a PostScript name.
        name = String(name.split(separator: "-").first ?? Substring(name))
        for suffix in ["PSMT", "MT", "PS", ",Bold", ",Italic"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        let known = ["TimesNewRoman": "Times New Roman", "CourierNew": "Courier New", "ArialNarrow": "Arial Narrow",
                     "SegoeUI": "Segoe UI", "CalibriLight": "Calibri Light", "BookAntiqua": "Book Antiqua",
                     "TrebuchetMS": "Trebuchet MS", "ComicSansMS": "Comic Sans MS", "PalatinoLinotype": "Palatino Linotype",
                     "HelveticaNeue": "Helvetica Neue", "SFPro": "SF Pro", "OpenSans": "Open Sans", "SourceSansPro": "Source Sans Pro"]
        return FontResolver.resolve(known[name] ?? name, serif: false, mono: font.isFixedPitch)
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "000000" }
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return String(format: "%02X%02X%02X", v[0], v[1], v[2])
    }

    // MARK: OCR

    private static func recognizeText(_ page: PDFPage, size: CGSize) -> [Glyph] {
        guard let image = PDFConverter.render(page, dpi: 300) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])

        var glyphs: [Glyph] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            // One glyph per word keeps spacing natural; Vision gives each word's box.
            var words: [(String, CGRect)] = []
            var index = line.startIndex
            for word in line.split(separator: " ", omittingEmptySubsequences: true) {
                guard let r = line.range(of: word, range: index..<line.endIndex) else { continue }
                index = r.upperBound
                guard let box = try? candidate.boundingBox(for: r)?.boundingBox else { continue }
                // Vision boxes are normalised with y up.
                let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                  width: box.width * size.width, height: box.height * size.height)
                words.append((String(word), rect))
            }
            // One size per line keeps sizes steady. The median word height is used because Vision
            // sometimes returns two lines as one box, and letter shapes make single words vary.
            let heights = words.map(\.1.height).sorted()
            guard !heights.isEmpty else { continue }
            let lineSize = max(6, (heights[heights.count / 2] / 1.2 * 2).rounded() / 2)
            for (word, rect) in words {
                let style = TextStyle(font: "Calibri", size: lineSize, bold: false, italic: false, color: "000000")
                glyphs.append(Glyph(text: word, rect: rect, style: style))
            }
        }
        return glyphs
    }
}

struct FontInfo {
    let family: String
    let bold: Bool
    let italic: Bool

    /// "ABCDEF+Fraunces-SemiBoldItalic" → family "Fraunces", bold, italic.
    init(postScriptName: String, flagsItalic: Bool, flagsBold: Bool, flagsSerif: Bool = false, flagsMono: Bool = false) {
        var name = postScriptName
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { name = String(name[name.index(after: plus)...]) }
        let parts = name.split(separator: "-", maxSplits: 1)
        let style = parts.count > 1 ? String(parts[1]).lowercased() : ""
        let lower = name.lowercased()
        bold = flagsBold || ["bold", "black", "heavy", "semibold", "demibold", "extrabold"].contains { style.contains($0) || lower.hasSuffix($0) }
        italic = flagsItalic || style.contains("italic") || style.contains("oblique")
        // Fonts named via NSFont when installed give the proper family name ("Times New Roman").
        if let installed = NSFont(name: name, size: 12)?.familyName {
            family = installed
        } else {
            var base = String(parts.first ?? Substring(name))
            for suffix in ["PSMT", "MT", "PS", ",Bold", ",Italic", "Variable", "VF"] where base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
            // CamelCase → spaced words ("OpenSans" → "Open Sans") so Word can match installed fonts.
            let spaced = base.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            family = FontResolver.resolve(spaced, serif: flagsSerif, mono: flagsMono)
        }
    }
}

/// Keeps a font's name when the reader will have it; otherwise picks a close, universal stand-in.
/// (Fonts embedded from web pages or brand kits exist nowhere else, and Word's fallback is Times.)
enum FontResolver {
    /// Fonts that Office, Pages or Google Docs provide even when this Mac lacks them.
    private static let widelyAvailable: Set<String> = [
        "Arial", "Helvetica", "Helvetica Neue", "Times New Roman", "Times", "Georgia", "Verdana", "Tahoma", "Trebuchet MS",
        "Courier New", "Courier", "Calibri", "Calibri Light", "Cambria", "Candara", "Consolas", "Constantia", "Corbel",
        "Aptos", "Segoe UI", "Garamond", "Book Antiqua", "Palatino", "Palatino Linotype", "Century Gothic", "Gill Sans",
        "Inter", "Roboto", "Open Sans", "Lato", "Montserrat", "Poppins", "Source Sans Pro", "Source Serif Pro", "Noto Sans",
        "Noto Serif", "Merriweather", "Playfair Display", "Lora", "Raleway", "Nunito", "Work Sans", "Fraunces", "DM Sans",
        "IBM Plex Sans", "IBM Plex Serif", "IBM Plex Mono", "Roboto Mono", "PT Sans", "PT Serif", "Oswald", "EB Garamond",
        "Libre Baskerville", "Crimson Text", "Rubik", "Manrope", "Space Grotesk", "Comic Sans MS", "Impact",
    ]
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func resolve(_ family: String, serif: Bool, mono: Bool) -> String {
        lock.withLock {
            if let hit = cache[family] { return hit }
            let installed = NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
            let lower = family.lowercased()
            let result: String
            if installed || widelyAvailable.contains(family) {
                result = family
            } else if mono || lower.contains("mono") || lower.contains("code") {
                result = "Courier New"
            } else if (serif || lower.contains("serif")) && !lower.contains("sans") {
                result = "Georgia"
            } else {
                result = "Arial"
            }
            cache[family] = result
            return result
        }
    }
}

struct FontSpan {
    let origin: CGPoint   // baseline start, reading space
    let size: CGFloat
    let font: FontInfo
}

/// Gives each glyph the real font of the text run it belongs to, and — where the PDF reports
/// tight ink boxes (commas sit low, "o" is short) — a uniform line box from the run's baseline.
private func applyFontSpans(_ spans: [FontSpan], to glyphs: inout [Glyph]) {
    guard !spans.isEmpty else { return }
    let inkBoxes = glyphs.filter { !$0.isSpace && $0.rect.height < $0.style.size * 0.85 }.count * 3 > glyphs.count
    // Index spans by rounded baseline for quick lookup.
    var byBaseline: [Int: [FontSpan]] = [:]
    for span in spans { byBaseline[Int(span.origin.y.rounded()), default: []].append(span) }
    for key in byBaseline.keys { byBaseline[key]!.sort { $0.origin.x < $1.origin.x } }

    for i in glyphs.indices {
        let g = glyphs[i]
        guard !g.isSpace else { continue }
        // The run whose baseline this glyph sits on, starting at or before it.
        var best: FontSpan?
        let tolerance = max(2, g.style.size * 0.45)
        for key in Int((g.rect.minY - 1).rounded(.down))...Int((g.rect.maxY + tolerance).rounded(.up)) {
            for span in byBaseline[key] ?? [] where span.origin.x <= g.rect.minX + 1.5
                && g.rect.minY < span.origin.y + 1 && g.rect.maxY > span.origin.y - span.size * 0.9 {
                if best == nil || span.origin.x > best!.origin.x || (span.origin.x == best!.origin.x && abs(span.origin.y - g.rect.maxY) < abs(best!.origin.y - g.rect.maxY)) { best = span }
            }
        }
        guard let span = best else { continue }
        glyphs[i].style.font = span.font.family
        glyphs[i].style.bold = span.font.bold
        glyphs[i].style.italic = span.font.italic
        if inkBoxes {
            let size = span.size > 1 ? span.size : g.style.size
            glyphs[i].rect = CGRect(x: g.rect.minX, y: span.origin.y - size * 0.8, width: g.rect.width, height: size)
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - Graphics

/// Walks a page's drawing operators to find images (with their pixels), rules,
/// filled boxes and vector figures, tracking the transformation matrix as it goes.
private final class GraphicsScanner {
    var images: [PlacedImage] = []
    var hRules: [Rule] = []
    var vRules: [Rule] = []
    var fills: [(rect: CGRect, color: String)] = []
    var figures: [CGRect] = []
    var dots: [(rect: CGRect, hollow: Bool)] = []
    /// Where each run of text starts, with the font the PDF actually uses for it.
    var spans: [FontSpan] = []

    fileprivate struct State {
        var ctm = CGAffineTransform.identity
        var fill = "000000"
        var stroke = "000000"
        var lineWidth: CGFloat = 1
        var font: FontInfo?
        var fontSize: CGFloat = 12
        var leading: CGFloat = 0
    }

    // Text matrices (reset by BT, not part of the q/Q state).
    private var tm = CGAffineTransform.identity
    private var tlm = CGAffineTransform.identity
    private var fontCache: [String: FontInfo] = [:]

    fileprivate var state = State()
    private var stack: [State] = []
    private var path: [[CGPoint]] = []     // subpaths, page space
    private var pathIsRect = true
    private var curves = 0
    private var contentStack: [CGPDFContentStreamRef] = []
    fileprivate let flip: CGAffineTransform

    init(page: CGPDFPage, flip: CGAffineTransform) {
        self.flip = flip
        scan(CGPDFContentStreamCreateWithPage(page))
    }

    private func scan(_ content: CGPDFContentStreamRef) {
        let table = CGPDFOperatorTableCreate()!
        func on(_ op: String, _ body: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, op, body) }
        func me(_ info: UnsafeMutableRawPointer?) -> GraphicsScanner { Unmanaged<GraphicsScanner>.fromOpaque(info!).takeUnretainedValue() }

        on("q") { _, i in let s = me(i); s.stack.append(s.state) }
        on("Q") { _, i in let s = me(i); if let last = s.stack.popLast() { s.state = last } }
        on("cm") { sc, i in
            let s = me(i)
            guard let v = popNumbers(sc, 6) else { return }
            s.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.state.ctm)
        }
        on("w") { sc, i in var w: CGPDFReal = 1; if CGPDFScannerPopNumber(sc, &w) { me(i).state.lineWidth = w } }
        for op in ["rg", "g", "k", "sc", "scn"] { on(op) { sc, i in if let c = popColor(sc) { me(i).state.fill = c } } }
        for op in ["RG", "G", "K", "SC", "SCN"] { on(op) { sc, i in if let c = popColor(sc) { me(i).state.stroke = c } } }

        on("m") { sc, i in let s = me(i); if let p = popPoint(sc, s) { s.path.append([p]) } }
        on("l") { sc, i in let s = me(i); if let p = popPoint(sc, s) { s.lineTo(p) } }
        on("c") { sc, i in let s = me(i); _ = popPoint(sc, s); _ = popPoint(sc, s); if let p = popPoint(sc, s) { s.curves += 1; s.lineTo(p) } }
        for op in ["v", "y"] { on(op) { sc, i in let s = me(i); _ = popPoint(sc, s); if let p = popPoint(sc, s) { s.curves += 1; s.lineTo(p) } } }
        on("h") { _, i in let s = me(i); if let first = s.path.last?.first { s.lineTo(first) } }
        on("re") { sc, i in
            let s = me(i)
            guard let v = popNumbers(sc, 4) else { return }
            let pts = [CGPoint(x: v[0], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1] + v[3]), CGPoint(x: v[0], y: v[1] + v[3])]
                .map { $0.applying(s.state.ctm).applying(s.flip) }
            s.path.append(pts + [pts[0]])
        }
        for op in ["S", "s"] { on(op) { _, i in me(i).paint(fill: false, stroke: true) } }
        for op in ["f", "F", "f*"] { on(op) { _, i in me(i).paint(fill: true, stroke: false) } }
        for op in ["B", "B*", "b", "b*"] { on(op) { _, i in me(i).paint(fill: true, stroke: true) } }
        on("n") { _, i in me(i).resetPath() }
        on("sh") { _, i in
            // Gradients usually fill a clipped area we can't see from here; treat as decoration.
            _ = me(i)
        }

        // Text state: enough to know which real font each run uses and where its baseline is.
        on("BT") { _, i in let s = me(i); s.tm = .identity; s.tlm = .identity }
        on("Tf") { sc, i in
            let s = me(i)
            var size: CGPDFReal = 12
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(sc, &size), CGPDFScannerPopName(sc, &name), let name else { return }
            s.state.fontSize = size
            s.state.font = s.font(named: String(cString: name))
        }
        on("TL") { sc, i in var v: CGPDFReal = 0; if CGPDFScannerPopNumber(sc, &v) { me(i).state.leading = v } }
        on("Tm") { sc, i in
            let s = me(i)
            guard let v = popNumbers(sc, 6) else { return }
            s.tlm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.tm = s.tlm
        }
        on("Td") { sc, i in let s = me(i); if let v = popNumbers(sc, 2) { s.moveLine(v[0], v[1]) } }
        on("TD") { sc, i in let s = me(i); if let v = popNumbers(sc, 2) { s.state.leading = -v[1]; s.moveLine(v[0], v[1]) } }
        on("T*") { _, i in let s = me(i); s.moveLine(0, -s.state.leading) }
        for op in ["Tj", "TJ"] { on(op) { _, i in me(i).recordSpan() } }
        on("'") { _, i in let s = me(i); s.moveLine(0, -s.state.leading); s.recordSpan() }
        on("\"") { _, i in let s = me(i); s.moveLine(0, -s.state.leading); s.recordSpan() }
        on("Do") { sc, i in
            let s = me(i)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(sc, &name), let name, let content = s.contentStack.last,
                  let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dict, "Subtype", &subtype)
            if subtype.map({ String(cString: $0) }) == "Image" {
                s.placeImage(stream, dict)
            } else if subtype.map({ String(cString: $0) }) == "Form" {
                let saved = s.state
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix {
                    var m = [CGPDFReal](repeating: 0, count: 6)
                    if (0..<6).allSatisfy({ CGPDFArrayGetNumber(matrix, $0, &m[$0]) }) {
                        s.state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(s.state.ctm)
                    }
                }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                s.scan(CGPDFContentStreamCreateWithStream(stream, resources ?? dict, content))
                s.state = saved
            }
        }

        contentStack.append(content)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        contentStack.removeLast()
    }

    private func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
        tm = tlm
    }

    private func recordSpan() {
        guard let font = state.font else { return }
        let t = tm.concatenating(state.ctm).concatenating(flip)
        let origin = CGPoint.zero.applying(t)
        // Effective size: the font size scaled by the text and page matrices.
        let size = state.fontSize * sqrt(abs(t.b * t.c - t.a * t.d))
        spans.append(FontSpan(origin: origin, size: size, font: font))
    }

    /// Reads a font resource's real name and style (PDFKit sometimes reports embedded fonts as Helvetica).
    private func font(named name: String) -> FontInfo? {
        if let cached = fontCache[name] { return cached }
        guard let content = contentStack.last, let object = CGPDFContentStreamGetResource(content, "Font", name) else { return nil }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { return nil }
        var base: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "BaseFont", &base)
        var descriptor: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor) {
            // Type0 fonts keep the descriptor on their descendant font.
            var descendants: CGPDFArrayRef?, child: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dict, "DescendantFonts", &descendants), let descendants, CGPDFArrayGetDictionary(descendants, 0, &child), let child {
                CGPDFDictionaryGetDictionary(child, "FontDescriptor", &descriptor)
            }
        }
        var flags: CGPDFInteger = 0, weight: CGPDFReal = 400, angle: CGPDFReal = 0
        if let descriptor {
            CGPDFDictionaryGetInteger(descriptor, "Flags", &flags)
            CGPDFDictionaryGetNumber(descriptor, "FontWeight", &weight)
            CGPDFDictionaryGetNumber(descriptor, "ItalicAngle", &angle)
        }
        guard let base else { return nil }
        let info = FontInfo(postScriptName: String(cString: base), flagsItalic: flags & 64 != 0 || abs(angle) > 1,
                            flagsBold: flags & (1 << 18) != 0 || weight >= 600, flagsSerif: flags & 2 != 0, flagsMono: flags & 1 != 0)
        fontCache[name] = info
        return info
    }

    private func lineTo(_ p: CGPoint) {
        if path.isEmpty { path.append([p]) } else { path[path.count - 1].append(p) }
        // A rectangle drawn with m/l/l/l/h counts as a rectangle too.
        if let sub = path.last, sub.count >= 2 {
            let a = sub[sub.count - 2]
            if abs(a.x - p.x) > 0.5 && abs(a.y - p.y) > 0.5 { pathIsRect = false }
        }
    }

    private func resetPath() {
        path = []
        pathIsRect = true
        curves = 0
    }

    private func paint(fill: Bool, stroke: Bool) {
        defer { resetPath() }
        let points = path.flatMap { $0 }
        guard points.count >= 2 else { return }
        let bounds = CGRect.bounding(points)
        let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
        let lineWidth = max(0.25, state.lineWidth * scale)

        if curves > 0 || !pathIsRect || path.count > 6 {
            // Anything curvy or irregular is artwork; tiny round marks are usually list bullets.
            if bounds.width * bounds.height > 150 || max(bounds.width, bounds.height) > 40 {
                figures.append(bounds)
            } else if bounds.width >= 1.5, bounds.width <= 9, abs(bounds.width - bounds.height) < 1.5 {
                dots.append((bounds, !fill))
            }
            return
        }
        if stroke {
            for sub in path {
                for (a, b) in zip(sub, sub.dropFirst()) { addRule(from: a, to: b, width: lineWidth, color: state.stroke) }
            }
        }
        if fill {
            if bounds.height <= 2.5, bounds.width > 3 {
                hRules.append(Rule(position: bounds.midY, start: bounds.minX, end: bounds.maxX, width: max(0.25, bounds.height), color: state.fill))
            } else if bounds.width <= 2.5, bounds.height > 3 {
                vRules.append(Rule(position: bounds.midX, start: bounds.minY, end: bounds.maxY, width: max(0.25, bounds.width), color: state.fill))
            } else if state.fill != "FFFFFF", bounds.width <= 7, abs(bounds.width - bounds.height) < 1 {
                dots.append((bounds, false))
            } else if state.fill != "FFFFFF", bounds.width > 3, bounds.height > 3 {
                fills.append((bounds, state.fill))
            }
        }
    }

    private func addRule(from a: CGPoint, to b: CGPoint, width: CGFloat, color: String) {
        if abs(a.y - b.y) < 1, abs(a.x - b.x) > 2 {
            hRules.append(Rule(position: (a.y + b.y) / 2, start: min(a.x, b.x), end: max(a.x, b.x), width: width, color: color))
        } else if abs(a.x - b.x) < 1, abs(a.y - b.y) > 2 {
            vRules.append(Rule(position: (a.x + b.x) / 2, start: min(a.y, b.y), end: max(a.y, b.y), width: width, color: color))
        }
    }

    private func placeImage(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef) {
        let t = state.ctm.concatenating(flip)
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(t).standardized
        guard rect.width > 2, rect.height > 2 else { return }
        var isMask = false
        CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask)
        if isMask { return }
        // Rotated or skewed placements are rare; keep the box upright.
        guard let extracted = ImageExtractor.extract(stream, dict) else { return }
        // In reading space an upright image has a positive x scale and a negative y scale.
        let mirror = t.a < 0, upsideDown = t.d > 0
        if !mirror, !upsideDown, let jpeg = extracted.originalJPEG {
            images.append(PlacedImage(rect: rect, data: jpeg, ext: "jpg"))
            return
        }
        var image = extracted.image
        if mirror { image = ImageExtractor.flipped(image, horizontally: true) ?? image }
        if upsideDown { image = ImageExtractor.flipped(image, horizontally: false) ?? image }
        guard let encoded = ImageExtractor.encode(image) else { return }
        // The same logo on every page only needs storing once; the writer dedupes by bytes.
        images.append(PlacedImage(rect: rect, data: encoded.data, ext: encoded.ext))
    }
}

private func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGFloat](repeating: 0, count: count)
    for k in (0..<count).reversed() {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &v) else { return nil }
        values[k] = v
    }
    return values
}

/// Pops an (x, y) operand pair and maps it into reading space.
private func popPoint(_ scanner: CGPDFScannerRef, _ s: GraphicsScanner) -> CGPoint? {
    guard let v = popNumbers(scanner, 2) else { return nil }
    return CGPoint(x: v[0], y: v[1]).applying(s.state.ctm).applying(s.flip)
}

/// Colours set with any operator; the operand count says which space it is.
private func popColor(_ scanner: CGPDFScannerRef) -> String? {
    var values: [CGFloat] = []
    var v: CGPDFReal = 0
    while values.count < 4, CGPDFScannerPopNumber(scanner, &v) { values.insert(v, at: 0) }
    // Pattern colours (scn /P0) leave a name; there's no single colour to report.
    var name: UnsafePointer<CChar>?
    if values.isEmpty, CGPDFScannerPopName(scanner, &name) { return nil }
    let rgb: [CGFloat]
    switch values.count {
    case 1: rgb = [values[0], values[0], values[0]]
    case 3: rgb = values
    case 4: rgb = [(1 - values[0]) * (1 - values[3]), (1 - values[1]) * (1 - values[3]), (1 - values[2]) * (1 - values[3])]
    default: return nil
    }
    let bytes = rgb.map { Int(($0 * 255).rounded()).clamped(0, 255) }
    return String(format: "%02X%02X%02X", bytes[0], bytes[1], bytes[2])
}

extension CGRect {
    static func bounding(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
