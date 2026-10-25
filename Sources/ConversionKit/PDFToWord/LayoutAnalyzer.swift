import CoreGraphics
import Foundation
import PDFKit

/// Rebuilds document structure (reading order, columns, paragraphs, lists, headings,
/// tables, headers/footers) from the positioned text and graphics of each page.
final class LayoutAnalyzer {
    private let pages: [PageContent]
    private let pdf: PDFDocument
    private let title: String
    private(set) var lists: [ListDefinition] = []

    init(pages: [PageContent], pdf: PDFDocument, title: String) {
        self.pages = pages
        self.pdf = pdf
        self.title = title
    }

    // MARK: Building blocks

    /// One line of text (or one cell of a row): glyphs left to right.
    struct Line {
        var glyphs: [Glyph]
        var rect: CGRect
        var marker: Marker?
        var page: Int

        var style: TextStyle { Line.dominant(glyphs) }
        var size: CGFloat { style.size }
        var allBold: Bool { glyphs.allSatisfy { $0.style.bold || $0.isSpace } }
        var text: String { Line.text(glyphs) }

        static func dominant(_ glyphs: [Glyph]) -> TextStyle {
            var counts: [TextStyle: Int] = [:]
            for g in glyphs where !g.isSpace { counts[g.style, default: 0] += g.text.count }
            return counts.max { $0.value < $1.value }?.key ?? glyphs.first?.style ?? TextStyle(font: "Calibri", size: 11, bold: false, italic: false, color: "000000")
        }

        static func text(_ glyphs: [Glyph]) -> String {
            var out = ""
            for (a, b) in zip([Glyph?.none] + glyphs.map { $0 }, glyphs) {
                if let a, needsSpace(a, b) { out += " " }
                out += b.text
            }
            return out
        }

        static func needsSpace(_ a: Glyph, _ b: Glyph) -> Bool {
            guard !a.isSpace, !b.isSpace, a.text != "\t", b.text != "\t" else { return false }
            let gap = b.rect.minX - a.rect.maxX
            // Recognised (OCR) text arrives a word at a time: any real gap is a space.
            if a.text.count > 2 || b.text.count > 2 { return gap > 0.5 }
            return gap > 0.12 * max(a.style.size, b.style.size)
        }
    }

    struct Marker {
        var kind: ListDefinition.Kind
        var value: Int
        var x: CGFloat
        var textX: CGFloat
        var text: String
    }

    enum Item {
        case line(Line)
        case table(DocTable, CGRect)
        case image(PlacedImage)
        case rule(Rule)

        var rect: CGRect {
            switch self {
            case .line(let l): l.rect
            case .table(_, let r): r
            case .image(let i): i.rect
            case .rule(let r): CGRect(x: r.start, y: r.position - r.width / 2, width: r.end - r.start, height: max(r.width, 0.5))
            }
        }

        var line: Line? { if case .line(let l) = self { l } else { nil } }
    }

    // MARK: Entry point

    func build() -> DocModel {
        var pageLines: [[Line]] = []
        var pageExtras: [[Item]] = []
        var pageFills: [[(rect: CGRect, color: String)]] = []

        for (index, page) in pages.enumerated() {
            var content = page
            let figureImages = renderFigures(&content, pageIndex: index)
            markUnderlinesAndLinks(&content)
            var lines = Self.attachDrawnBullets(segments(rows(content.glyphs), page: index), dots: content.dots)
            var extras: [Item] = []
            // Ruled tables claim their text before anything else looks at it.
            for (table, rect) in tables(content, lines: &lines, pageIndex: index) { extras.append(.table(table, rect)) }
            extras += (content.images + figureImages).map { Item.image($0) }
            extras += standaloneRules(content, lines: lines, tables: extras).map { Item.rule($0) }
            pageLines.append(lines)
            pageExtras.append(extras)
            pageFills.append(content.fills)
        }

        let (header, footer) = extractHeaderFooter(&pageLines)
        let allLines = pageLines.flatMap { $0 }
        let bodyStyle = Line.dominant(allLines.flatMap(\.glyphs))
        let size = pages.first?.size ?? CGSize(width: 612, height: 792)

        // Margins: where the body content sits across all pages.
        let bodyRects = pageLines.flatMap { $0.map(\.rect) } + pageExtras.flatMap { $0.map(\.rect) }.filter { $0.width < size.width * 0.95 }
        let union = bodyRects.reduce(CGRect.null) { $0.union($1) }
        var margins: (CGFloat, CGFloat, CGFloat, CGFloat) = (72, 72, 72, 72)
        if !union.isNull {
            // The first line's box in Word starts above its glyphs.
            let firstLine = pageLines.first?.min { $0.rect.minY < $1.rect.minY }
            let top = union.minY - (firstLine.map { max(0, $0.size * 1.17 - $0.rect.height) } ?? 0)
            // Only pages that are full show where the bottom margin is; a short last page doesn't.
            let fullPageBottoms = pageLines.dropLast().enumerated().compactMap { i, lines -> CGFloat? in
                let bottoms = lines.map(\.rect.maxY) + pageExtras[i].map(\.rect.maxY)
                return bottoms.max().map { size.height - $0 }
            }
            let bottom = fullPageBottoms.min() ?? top
            margins = (top.clamped(18, 144), (size.width - union.maxX).clamped(18, 144),
                       bottom.clamped(18, 144), union.minX.clamped(18, 144))
        }
        let body = CGRect(x: margins.3, y: margins.0, width: size.width - margins.1 - margins.3, height: size.height - margins.0 - margins.2)

        var blocks: [DocBlock] = []
        for index in pages.indices {
            let items = pageLines[index].map { Item.line($0) } + pageExtras[index]
            let tree = cut(items, region: body, depth: 0)
            var pageBlocks = flow(tree, container: body, page: index, fills: pageFills[index])
            attachBackgrounds(&pageBlocks, page: index, lines: pageLines[index])
            let previousBottom = index > 0 ? (pageLines[index - 1].map(\.rect.maxY) + pageExtras[index - 1].map(\.rect.maxY)).max() : nil
            join(&blocks, with: &pageBlocks, previousPage: index - 1, previousBottom: previousBottom, pageHeight: size.height)
        }
        assignHeadings(&blocks, body: bodyStyle.size)
        if blocks.isEmpty { blocks = [.paragraph(DocParagraph())] }

        return DocModel(pageSize: size, margins: margins, bodyFont: bodyStyle.font, bodySize: bodyStyle.size,
                        header: header, footer: footer, blocks: blocks, title: title)
    }

    // MARK: Figures, underlines, links

    /// Vector art (charts, diagrams, logos) becomes a picture; text inside it goes with it.
    private func renderFigures(_ content: inout PageContent, pageIndex: Int) -> [PlacedImage] {
        let regions = Self.mergeRects(content.figures, margin: 6).filter { $0.width * $0.height > 1500 }
        guard !regions.isEmpty, let page = pdf.page(at: pageIndex) else { return [] }
        var keep: [CGRect] = []
        for region in regions {
            let inside = content.glyphs.filter { region.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }.count
            // Lots of text on a shape means it's a decorative box behind text, not a chart.
            if inside <= 250, region.width * region.height < content.size.width * content.size.height * 0.85 { keep.append(region) }
        }
        guard !keep.isEmpty, let rendered = PDFConverter.render(page, dpi: 200) else { return [] }
        let scale = CGFloat(rendered.width) / content.size.width
        var images: [PlacedImage] = []
        for region in keep {
            let r = region.insetBy(dx: -3, dy: -3).intersection(CGRect(origin: .zero, size: content.size))
            let crop = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
            guard let cg = rendered.cropping(to: crop), let png = ImageExtractor.encode(cg) else { continue }
            images.append(PlacedImage(rect: r, data: png.data, ext: png.ext))
            content.glyphs.removeAll { r.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            // Pictures fully inside the figure are part of it.
            content.images.removeAll { r.insetBy(dx: -2, dy: -2).contains($0.rect) }
        }
        return images
    }

    private func markUnderlinesAndLinks(_ content: inout PageContent) {
        for i in content.glyphs.indices {
            let g = content.glyphs[i]
            let center = CGPoint(x: g.rect.midX, y: g.rect.midY)
            if let link = content.links.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(center) }) { content.glyphs[i].link = link.url }
        }
        var used: [Int] = []
        for (ri, rule) in content.hRules.enumerated() where rule.width < 2.5 {
            // Table borders also run under text; they meet vertical borders, underlines don't.
            let joinsBorder = content.vRules.contains { v in
                v.position >= rule.start - 2 && v.position <= rule.end + 2 && rule.position >= v.start - 2 && rule.position <= v.end + 2
            }
            if joinsBorder { continue }
            // An underline sits just under the baseline (the bottom of the glyph box is the descent).
            let hits = content.glyphs.indices.filter { i in
                let g = content.glyphs[i], s = g.style.size
                return !g.isSpace && g.rect.midX >= rule.start - 1 && g.rect.midX <= rule.end + 1
                    && rule.position > g.rect.maxY - 0.35 * s && rule.position < g.rect.maxY + 0.15 * s
            }
            // …and is about as long as the text above it.
            let covered = hits.reduce(CGFloat(0)) { $0 + content.glyphs[$1].rect.width }
            guard !hits.isEmpty, covered >= (rule.end - rule.start) * 0.6 else { continue }
            for i in hits { content.glyphs[i].underline = true }
            used.append(ri)
        }
        for i in used.reversed() { content.hRules.remove(at: i) }
    }

    // MARK: Rows and segments

    private func rows(_ glyphs: [Glyph]) -> [[Glyph]] {
        let sorted = glyphs.filter { !$0.isSpace }.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [(core: ClosedRange<CGFloat>, glyphs: [Glyph])] = []
        for g in sorted {
            var best = -1
            var bestOverlap: CGFloat = 0
            for r in rows.indices.suffix(12) {
                let core = rows[r].core
                let overlap = min(g.rect.maxY, core.upperBound) - max(g.rect.minY, core.lowerBound)
                let need = 0.5 * min(g.rect.height, core.upperBound - core.lowerBound)
                if overlap >= need, overlap > bestOverlap { best = r; bestOverlap = overlap }
            }
            if best >= 0 { rows[best].glyphs.append(g) } else { rows.append((g.rect.minY...g.rect.maxY, [g])) }
        }
        return rows.map { $0.glyphs.sorted { $0.rect.minX < $1.rect.minX } }
    }

    private func segments(_ rows: [[Glyph]], page: Int) -> [Line] {
        var lines: [Line] = []
        for row in rows {
            var pieces: [[Glyph]] = [[]]
            for g in row {
                if let last = pieces[pieces.count - 1].last {
                    let gap = g.rect.minX - last.rect.maxX
                    if gap > max(1.2 * max(g.style.size, last.style.size), 8) { pieces.append([]) }
                }
                pieces[pieces.count - 1].append(g)
            }
            var rowLines = pieces.filter { !$0.isEmpty }.map { Line(glyphs: $0, rect: Self.bounds($0), marker: nil, page: page) }
            // A list marker set apart by a tab ("1.   Text") belongs to the text after it.
            var i = 0
            while i < rowLines.count {
                // Set apart by a tab, a bare "1" is a marker too.
                // …but only when words follow it ("2   $800" is a quantity, not a list).
                let wordsFollow = i + 1 < rowLines.count && rowLines[i + 1].text.first?.isLetter == true
                if i + 1 < rowLines.count, let kind = Self.marker(rowLines[i].text, bareNumbers: wordsFollow), rowLines[i].rect.width < 40,
                   rowLines[i + 1].rect.minX - rowLines[i].rect.maxX < 72 {
                    var merged = rowLines[i + 1]
                    merged.marker = Marker(kind: kind.0, value: kind.1, x: rowLines[i].rect.minX, textX: merged.rect.minX, text: rowLines[i].text)
                    merged.rect = merged.rect.union(rowLines[i].rect)
                    rowLines[i] = merged
                    rowLines.remove(at: i + 1)
                } else if rowLines[i].marker == nil {
                    rowLines[i] = Self.inlineMarker(rowLines[i])
                }
                i += 1
            }
            lines += rowLines
        }
        return lines
    }

    /// Bullets drawn as little shapes (Chrome, many design tools) instead of "•" characters.
    static func attachDrawnBullets(_ lines: [Line], dots: [(rect: CGRect, hollow: Bool)]) -> [Line] {
        guard !dots.isEmpty else { return lines }
        return lines.map { line in
            guard line.marker == nil else { return line }
            let size = line.size
            guard let dot = dots.first(where: { d in
                d.rect.maxX <= line.rect.minX + 1 && line.rect.minX - d.rect.maxX < max(25, size * 2.2)
                    && abs(d.rect.midY - line.rect.midY) < size * 0.5 && d.rect.width < size * 0.75
            }) else { return line }
            var out = line
            out.marker = Marker(kind: .bullet, value: 1, x: dot.rect.minX, textX: line.rect.minX, text: dot.hollow ? "◦" : "•")
            out.rect = out.rect.union(dot.rect)
            return out
        }
    }

    /// "• Text" or "3. Text" within one segment.
    private static func inlineMarker(_ line: Line) -> Line {
        let g = line.glyphs
        guard g.count >= 2 else { return line }
        // Collect the leading token up to the first word gap.
        var end = 0
        while end + 1 < g.count, !Line.needsSpace(g[end], g[end + 1]) { end += 1 }
        guard end + 1 < g.count, end < 5 else { return line }
        let token = g[0...end].map(\.text).joined()
        guard let kind = marker(token) else { return line }
        var out = line
        out.glyphs = Array(g[(end + 1)...])
        out.marker = Marker(kind: kind.0, value: kind.1, x: g[0].rect.minX, textX: g[end + 1].rect.minX, text: token)
        return out
    }

    private static let bullets: Set<String> = ["•", "◦", "▪", "■", "●", "○", "►", "▸", "–", "-", "*", "✓", "✔", "➢", "➤", "", "", "·", "‣", "⁃", "□", "❖", "♦", "◆", "‐"]

    static func marker(_ token: String, bareNumbers: Bool = false) -> (ListDefinition.Kind, Int)? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if bullets.contains(t) { return (.bullet, 1) }
        if bareNumbers, t.count <= 2, let v = Int(t) { return (.decimal, v) }
        func match(_ pattern: String) -> String? {
            guard let r = t.range(of: pattern, options: .regularExpression), r == t.startIndex..<t.endIndex else { return nil }
            return String(t.trimmingCharacters(in: CharacterSet(charactersIn: "().")))
        }
        if let n = match(#"^\(?\d{1,3}[.)]$"#), let v = Int(n) { return (.decimal, v) }
        if let r = match(#"^\(?[ivx]{1,5}[.)]$"#), let v = roman(r) { return (.lowerRoman, v) }
        if let r = match(#"^\(?[IVX]{1,5}[.)]$"#), let v = roman(r.lowercased()) { return (.upperRoman, v) }
        if let c = match(#"^\(?[a-z][.)]$"#)?.unicodeScalars.first { return (.lowerLetter, Int(c.value) - 96) }
        if let c = match(#"^\(?[A-Z][.)]$"#)?.unicodeScalars.first { return (.upperLetter, Int(c.value) - 64) }
        return nil
    }

    private static func roman(_ s: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10]
        var total = 0, prev = 0
        for c in s.reversed() {
            guard let v = values[c] else { return nil }
            total += v < prev ? -v : v
            prev = max(prev, v)
        }
        return total > 0 ? total : nil
    }

    static func bounds(_ glyphs: [Glyph]) -> CGRect { glyphs.reduce(CGRect.null) { $0.union($1.rect) } }

    // MARK: Headers and footers

    /// Lines repeated at the top or bottom of most pages (titles, page numbers) become
    /// the Word header/footer instead of repeating in the text.
    private func extractHeaderFooter(_ pageLines: inout [[Line]]) -> ([DocParagraph], [DocParagraph]) {
        guard pages.count >= 2 else { return ([], []) }
        func key(_ line: Line, _ page: Int) -> String? {
            let h = pages[page].size.height
            let band = line.rect.maxY < h * 0.1 ? "top" : line.rect.minY > h * 0.9 ? "bottom" : nil
            guard let band else { return nil }
            let normalized = line.text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            return band + "|" + normalized.trimmingCharacters(in: .whitespaces)
        }
        var counts: [String: Set<Int>] = [:]
        for (p, lines) in pageLines.enumerated() {
            for line in lines { if let k = key(line, p) { counts[k, default: []].insert(p) } }
        }
        let needed = max(2, Int((Double(pages.count) * 0.5).rounded(.up)))
        let repeated = Set(counts.filter { $0.value.count >= needed }.keys)
        guard !repeated.isEmpty else { return ([], []) }

        var header: [DocParagraph] = [], footer: [DocParagraph] = []
        // Take the wording from the page that shows the most of it (cover pages often omit headers).
        let source = pageLines.indices.max { a, b in
            pageLines[a].filter { key($0, a).map(repeated.contains) ?? false }.count < pageLines[b].filter { key($0, b).map(repeated.contains) ?? false }.count
        } ?? 0
        let width = pages[source].size.width
        for line in pageLines[source].sorted(by: { $0.rect.minY < $1.rect.minY }) {
            guard let k = key(line, source), repeated.contains(k) else { continue }
            var paragraph = DocParagraph()
            paragraph.runs = runs(for: [line], pageNumber: source + 1)
            paragraph.alignment = abs(line.rect.midX - width / 2) < width * 0.1 ? .center : line.rect.minX > width * 0.55 ? .right : .left
            if k.hasPrefix("top") { header.append(paragraph) } else { footer.append(paragraph) }
        }
        for p in pageLines.indices { pageLines[p].removeAll { key($0, p).map(repeated.contains) ?? false } }
        return (header, footer)
    }

    // MARK: Tables

    private func tables(_ content: PageContent, lines: inout [Line], pageIndex: Int) -> [(DocTable, CGRect)] {
        let h = Self.mergeRules(content.hRules)
        let v = Self.mergeRules(content.vRules)
        guard h.count >= 2, v.count >= 2 else { return [] }

        // Group rules that touch into separate tables.
        var parent = Array(0..<(h.count + v.count))
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, hr) in h.enumerated() {
            for (j, vr) in v.enumerated() where vr.position >= hr.start - 3 && vr.position <= hr.end + 3 && hr.position >= vr.start - 3 && hr.position <= vr.end + 3 {
                parent[find(i)] = find(h.count + j)
            }
        }
        var groups: [Int: (h: [Rule], v: [Rule])] = [:]
        for (i, r) in h.enumerated() { groups[find(i), default: ([], [])].h.append(r) }
        for (j, r) in v.enumerated() { groups[find(h.count + j), default: ([], [])].v.append(r) }

        var result: [(DocTable, CGRect)] = []
        for (_, group) in groups where group.h.count >= 2 && group.v.count >= 2 {
            let xs = Self.cluster(group.v.map(\.position) + group.h.flatMap { [$0.start, $0.end] })
            let ys = Self.cluster(group.h.map(\.position) + group.v.flatMap { [$0.start, $0.end] })
            guard xs.count >= 2, ys.count >= 2 else { continue }
            let rect = CGRect(x: xs.first!, y: ys.first!, width: xs.last! - xs.first!, height: ys.last! - ys.first!)
            guard rect.width > 30, rect.height > 10 else { continue }
            let inside = lines.filter { rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            guard !inside.isEmpty else { continue }
            let table = buildGrid(xs: xs, ys: ys, h: group.h, v: group.v, lines: inside, fills: content.fills, tableRect: rect)
            lines.removeAll { rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            result.append((table, rect))
        }
        return result
    }

    private func buildGrid(xs: [CGFloat], ys: [CGFloat], h: [Rule], v: [Rule], lines: [Line],
                           fills: [(rect: CGRect, color: String)], tableRect: CGRect) -> DocTable {
        let rows = ys.count - 1, cols = xs.count - 1
        func coverage(_ rules: [Rule], at pos: CGFloat, from a: CGFloat, to b: CGFloat) -> Rule? {
            let hits = rules.filter { abs($0.position - pos) <= 2.5 }
            let covered = hits.reduce(CGFloat(0)) { $0 + max(0, min($1.end, b) - max($1.start, a)) }
            return covered >= (b - a) * 0.6 ? hits.first : nil
        }
        // Union cells not separated by a rule.
        var owner = Array(0..<(rows * cols))
        func find(_ i: Int) -> Int { var i = i; while owner[i] != i { owner[i] = owner[owner[i]]; i = owner[i] }; return i }
        for r in 0..<rows {
            for c in 0..<cols {
                if c + 1 < cols, coverage(v, at: xs[c + 1], from: ys[r], to: ys[r + 1]) == nil { owner[find(r * cols + c + 1)] = find(r * cols + c) }
                if r + 1 < rows, coverage(h, at: ys[r + 1], from: xs[c], to: xs[c + 1]) == nil { owner[find((r + 1) * cols + c)] = find(r * cols + c) }
            }
        }
        // Each merged group becomes one cell spanning its bounding grid rectangle.
        var spans: [Int: (r0: Int, c0: Int, r1: Int, c1: Int)] = [:]
        for r in 0..<rows {
            for c in 0..<cols {
                let k = find(r * cols + c)
                let s = spans[k] ?? (r, c, r, c)
                spans[k] = (min(s.r0, r), min(s.c0, c), max(s.r1, r), max(s.c1, c))
            }
        }

        var table = DocTable(columnWidths: (0..<cols).map { xs[$0 + 1] - xs[$0] }, indent: 0, rows: [])
        for r in 0..<rows {
            var row = DocRow(height: ys[r + 1] - ys[r], cells: [])
            var c = 0
            while c < cols {
                let s = spans[find(r * cols + c)]!
                // Non-rectangular merges fall back to single cells.
                let rect = CGRect(x: xs[s.c0], y: ys[s.r0], width: xs[s.c1 + 1] - xs[s.c0], height: ys[s.r1 + 1] - ys[s.r0])
                var cell = DocCell()
                cell.span = s.c0 == c ? s.c1 - s.c0 + 1 : 1
                if s.r1 > s.r0 { cell.vMerge = r == s.r0 ? .restart : .continue }
                if cell.vMerge != .continue {
                    // Split lines at cell edges: closely set cells can read as one line.
                    let cellLines = lines.compactMap { line -> Line? in
                        let inside = line.glyphs.filter { rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                        guard !inside.isEmpty else { return nil }
                        let keepsMarker = line.marker.map { rect.contains(CGPoint(x: $0.x + 1, y: line.rect.midY)) } ?? false
                        return Line(glyphs: inside, rect: Self.bounds(inside), marker: keepsMarker ? line.marker : nil, page: line.page)
                    }
                    cell.paragraphs = paragraphs(from: cellLines, container: rect.insetBy(dx: 3, dy: 0), fills: [])
                }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                cell.shading = fills.filter { $0.rect.insetBy(dx: -1, dy: -1).contains(center) }
                    .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.color
                let cr = CGRect(x: xs[c], y: ys[r], width: xs[c + cell.span] - xs[c], height: ys[r + 1] - ys[r])
                if let t = coverage(h, at: cr.minY, from: cr.minX, to: cr.maxX) { cell.borders[.top] = (t.width, t.color) }
                if let b = coverage(h, at: cr.maxY, from: cr.minX, to: cr.maxX) { cell.borders[.bottom] = (b.width, b.color) }
                if let l = coverage(v, at: cr.minX, from: cr.minY, to: cr.maxY) { cell.borders[.left] = (l.width, l.color) }
                if let rr = coverage(v, at: cr.maxX, from: cr.minY, to: cr.maxY) { cell.borders[.right] = (rr.width, rr.color) }
                row.cells.append(cell)
                c += cell.span
            }
            table.rows.append(row)
        }
        return table
    }

    static func mergeRules(_ rules: [Rule]) -> [Rule] {
        var out: [Rule] = []
        for r in rules.sorted(by: { ($0.position, $0.start) < ($1.position, $1.start) }) {
            if let i = out.lastIndex(where: { abs($0.position - r.position) <= 1.5 && r.start <= $0.end + 3 }) {
                out[i].end = max(out[i].end, r.end)
                out[i].width = max(out[i].width, r.width)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func cluster(_ values: [CGFloat], tolerance: CGFloat = 2.5) -> [CGFloat] {
        var groups: [[CGFloat]] = []
        for v in values.sorted() {
            if let last = groups.last?.last, v - last <= tolerance { groups[groups.count - 1].append(v) } else { groups.append([v]) }
        }
        return groups.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    /// Long horizontal rules that aren't table borders or underlines: section dividers.
    private func standaloneRules(_ content: PageContent, lines: [Line], tables: [Item]) -> [Rule] {
        let tableRects = tables.map(\.rect)
        return Self.mergeRules(content.hRules).filter { r in
            r.end - r.start > content.size.width * 0.25
                && !tableRects.contains { $0.insetBy(dx: -3, dy: -3).contains(CGPoint(x: (r.start + r.end) / 2, y: r.position)) }
        }
    }

    // MARK: Reading order (recursive XY cut)

    indirect enum Node {
        case leaf([Item])
        case stack([Node])
        case columns([Node], rects: [CGRect], gutter: CGFloat, isText: Bool)
        case grid(DocTable, CGRect)
    }

    private func cut(_ items: [Item], region: CGRect, depth: Int) -> Node {
        guard items.count > 1, depth < 60 else { return .leaf(items.sorted { $0.rect.minY < $1.rect.minY }) }
        // Pieces of a single row ("Total      $120") stay one line, not two columns.
        if items.allSatisfy({ $0.line != nil }), (items.map(\.rect.minY).max() ?? 0) < (items.map(\.rect.maxY).min() ?? 0) {
            return .leaf(items.sorted { $0.rect.minX < $1.rect.minX })
        }
        // A big empty band right across the region (title above a table, details above line items) wins.
        let lineHeights = items.compactMap { $0.line?.rect.height }.sorted()
        let typical = lineHeights.isEmpty ? 12 : lineHeights[lineHeights.count / 2]
        if let band = Self.largestGap(items.map { ($0.rect.minY, $0.rect.maxY) }, minimum: typical * 1.3) {
            let top = items.filter { $0.rect.midY < band.mid }, bottom = items.filter { $0.rect.midY >= band.mid }
            var nodes: [Node] = []
            for part in [cut(top, region: Self.union(top), depth: depth + 1), cut(bottom, region: Self.union(bottom), depth: depth + 1)] {
                if case .stack(let inner) = part { nodes += inner } else { nodes.append(part) }
            }
            return .stack(nodes)
        }
        // Rules (a line under a header row) don't define columns, so they can't block a gutter.
        let solid = items.filter { if case .rule = $0 { false } else { true } }
        if let gap = Self.largestGap(solid.map { ($0.rect.minX, $0.rect.maxX) }, minimum: 9),
           Self.sideBySide(items.filter { $0.rect.midX < gap.mid }, items.filter { $0.rect.midX >= gap.mid }) {
            if let grid = textGrid(items) { return .grid(grid.0, grid.1) }
            let left = items.filter { $0.rect.midX < gap.mid }
            let right = items.filter { $0.rect.midX >= gap.mid }
            let lr = Self.union(left), rr = Self.union(right)
            let isText = [left, right].allSatisfy { side in
                let lines = side.compactMap(\.line)
                return lines.count >= 3 && Double(lines.count) >= Double(side.count) * 0.7
            } && max(lr.width, rr.width) / max(1, min(lr.width, rr.width)) < 2.2
            let leftNode = cut(left, region: lr, depth: depth + 1)
            let rightNode = cut(right, region: rr, depth: depth + 1)
            // Flatten nested column splits into one multi-column node.
            var nodes: [Node] = [], rects: [CGRect] = []
            for (n, r) in [(leftNode, lr), (rightNode, rr)] {
                if case .columns(let inner, let innerRects, _, let innerText) = n, innerText == isText { nodes += inner; rects += innerRects } else { nodes.append(n); rects.append(r) }
            }
            return .columns(nodes, rects: rects, gutter: gap.width, isText: isText)
        }
        if let gap = Self.largestGap(items.map { ($0.rect.minY, $0.rect.maxY) }, minimum: 0.5) {
            let top = items.filter { $0.rect.midY < gap.mid }, bottom = items.filter { $0.rect.midY >= gap.mid }
            var nodes: [Node] = []
            for part in [cut(top, region: Self.union(top), depth: depth + 1), cut(bottom, region: Self.union(bottom), depth: depth + 1)] {
                if case .stack(let inner) = part { nodes += inner } else { nodes.append(part) }
            }
            return .stack(nodes)
        }
        return .leaf(items.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) })
    }

    static func largestGap(_ spans: [(CGFloat, CGFloat)], minimum: CGFloat) -> (mid: CGFloat, width: CGFloat)? {
        let sorted = spans.sorted { $0.0 < $1.0 }
        guard var end = sorted.first?.1 else { return nil }
        var best: (mid: CGFloat, width: CGFloat)?
        for s in sorted.dropFirst() {
            if s.0 > end, s.0 - end >= minimum, s.0 - end > (best?.width ?? 0) { best = ((s.0 + end) / 2, s.0 - end) }
            end = max(end, s.1)
        }
        return best
    }

    /// A real gutter has content facing content across it. A gap between a centred
    /// heading and left-aligned text further down is just whitespace, not columns.
    static func sideBySide(_ a: [Item], _ b: [Item]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        let facing = small.filter { item in
            let slack = max(4, item.rect.height * 0.5)
            return large.contains { $0.rect.maxY > item.rect.minY - slack && $0.rect.minY < item.rect.maxY + slack }
        }.count
        return Double(facing) >= Double(small.count) * 0.5
    }

    static func union(_ items: [Item]) -> CGRect { items.reduce(CGRect.null) { $0.union($1.rect) } }

    static func mergeRects(_ rects: [CGRect], margin: CGFloat) -> [CGRect] {
        var out = rects
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i && out[i].insetBy(dx: -margin, dy: -margin).intersects(out[j]) {
                    out[i] = out[i].union(out[j])
                    out.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return out
    }

    /// Side-by-side text whose rows line up (forms, invoices, borderless tables) reads
    /// row by row, not column by column: rebuild it as a table without borders.
    private func textGrid(_ items: [Item]) -> (DocTable, CGRect)? {
        let lines = items.compactMap(\.line)
        // Rules inside a borderless table (under the header row, above the total) become row borders.
        let rules: [Rule] = items.compactMap { if case .rule(let r) = $0 { r } else { nil } }
        guard lines.count + rules.count == items.count, lines.count >= 4, lines.filter({ $0.marker != nil }).count * 3 < lines.count else { return nil }
        // Column boundaries: every vertical gap across the region.
        var bounds: [CGFloat] = []
        var spans = lines.map { ($0.rect.minX, $0.rect.maxX) }.sorted { $0.0 < $1.0 }
        var end = spans.removeFirst().1
        for s in spans {
            // Inside a table, right-aligned numbers can sit close to the next column's heading.
            if s.0 - end >= 5 { bounds.append((s.0 + end) / 2) }
            end = max(end, s.1)
        }
        let region = lines.reduce(CGRect.null) { $0.union($1.rect) }
        var edges = [region.minX] + bounds + [region.maxX]

        var rowGroups: [[Line]] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rowGroups.last?.first, abs(last.rect.midY - line.rect.midY) < 0.5 * min(last.rect.height, line.rect.height) {
                rowGroups[rowGroups.count - 1].append(line)
            } else {
                rowGroups.append([line])
            }
        }
        // Neighbouring columns that never share a row are one column whose heading is aligned
        // differently from its values (a left-aligned "Rate" over right-aligned amounts).
        var merged = true
        while merged, edges.count > 3 {
            merged = false
            let occupancy = (0..<(edges.count - 1)).map { c in Set(rowGroups.indices.filter { r in rowGroups[r].contains { col(of: $0, edges) == c } }) }
            for c in 0..<(occupancy.count - 1) where occupancy[c].isDisjoint(with: occupancy[c + 1]) {
                edges.remove(at: c + 1)
                merged = true
                break
            }
        }
        let cols = edges.count - 1
        guard cols >= 2, cols <= 12 else { return nil }
        let multi = rowGroups.filter { Set($0.map { col(of: $0, edges) }).count >= 2 }.count
        guard rowGroups.count >= 2, Double(multi) >= Double(rowGroups.count) * 0.6 else { return nil }
        // Running text in columns fills its column width; table cells mostly don't.
        let fill = lines.map { l -> CGFloat in
            let c = col(of: l, edges)
            return l.rect.width / max(1, edges[c + 1] - edges[c])
        }.reduce(0, +) / CGFloat(lines.count)
        if fill > 0.72, rowGroups.count > 4 { return nil }

        var table = DocTable(columnWidths: (0..<cols).map { edges[$0 + 1] - edges[$0] }, indent: 0, rows: [])
        table.cellPadding = 0
        // A little slack on the last column absorbs font-metric differences in Word.
        table.columnWidths[cols - 1] += 8
        for (r, group) in rowGroups.enumerated() {
            // Rows keep their original pitch (top to next top), so spacing matches.
            let top = group.map(\.rect.minY).min() ?? 0
            let nextRowTop = r + 1 < rowGroups.count ? rowGroups[r + 1].map(\.rect.minY).min() : nil
            var row = DocRow(height: nextRowTop.map { $0 - top } ?? Self.bounds(group.flatMap(\.glyphs)).height + 4, cells: [])
            let rowBottom = group.map(\.rect.maxY).max() ?? 0
            let nextTop = r + 1 < rowGroups.count ? (rowGroups[r + 1].map(\.rect.minY).min() ?? .infinity) : rowBottom + 20
            let border = rules.first { $0.position >= rowBottom - 1 && $0.position <= nextTop + 1 }
            for c in 0..<cols {
                let cellLines = group.filter { col(of: $0, edges) == c }.sorted { $0.rect.minX < $1.rect.minX }
                var cell = DocCell()
                cell.paragraphs = cellLines.isEmpty ? [] : [paragraph(lines: cellLines, container: CGRect(x: edges[c], y: 0, width: edges[c + 1] - edges[c], height: 1), sameRow: true)]
                // Numbers set flush right in their column stay right-aligned.
                if let l = cellLines.last, edges[c + 1] - l.rect.maxX < 12, l.rect.minX - edges[c] > 12 { cell.paragraphs[0].alignment = .right; cell.paragraphs[0].leftIndent = 0 }
                if let border { cell.borders[.bottom] = (border.width, border.color) }
                row.cells.append(cell)
            }
            table.rows.append(row)
        }
        return (table, region)
    }

    private func col(of line: Line, _ edges: [CGFloat]) -> Int {
        let x = line.rect.minX + 1
        return max(0, min(edges.count - 2, (edges.lastIndex { $0 <= x } ?? 0)))
    }

    // MARK: Flow

    private func flow(_ node: Node, container: CGRect, page: Int, fills: [(rect: CGRect, color: String)]) -> [DocBlock] {
        switch node {
        case .leaf(let items):
            return blocks(items, container: container, fills: fills)
        case .stack(let nodes):
            // Consecutive leaves share a container, so paragraphs can span cut lines.
            var items: [Item] = []
            var out: [DocBlock] = []
            for n in nodes {
                if case .leaf(let leafItems) = n { items += leafItems; continue }
                out += blocks(items, container: container, fills: fills)
                items = []
                out += flow(n, container: container, page: page, fills: fills)
            }
            out += blocks(items, container: container, fills: fills)
            return out
        case .grid(let table, let rect):
            var t = table
            t.indent = max(0, rect.minX - container.minX)
            return [.table(t)]
        case .columns(let nodes, let rects, let gutter, let isText):
            if isText {
                // Real text columns: a Word section with columns, a column break between each.
                var out: [DocBlock] = [.sectionBreak(columns: 1, spacing: 0)]
                for (i, n) in nodes.enumerated() {
                    var part = flow(n, container: rects[i], page: page, fills: fills)
                    if i > 0, case .paragraph(var first)? = part.first {
                        first.runs.insert(DocRun(text: "", style: first.runs.first?.style ?? defaultStyle, columnBreak: true), at: 0)
                        part[0] = .paragraph(first)
                    }
                    out += part
                }
                out.append(.sectionBreak(columns: nodes.count, spacing: gutter))
                return out
            }
            // Side-by-side bits that aren't columns (a picture beside text): read left to right.
            return nodes.enumerated().flatMap { flow($0.element, container: rects[$0.offset], page: page, fills: fills) }
        }
    }

    private var defaultStyle: TextStyle { TextStyle(font: "Calibri", size: 11, bold: false, italic: false, color: "000000") }

    /// Lines, images, tables and rules in reading order → Word blocks.
    private func blocks(_ items: [Item], container: CGRect, fills: [(rect: CGRect, color: String)]) -> [DocBlock] {
        var out: [DocBlock] = []
        var pending: [Line] = []
        var lastBottom: CGFloat?
        func flush() {
            guard !pending.isEmpty else { return }
            var ps = paragraphs(from: pending, container: container, fills: fills)
            if let lastBottom, !ps.isEmpty { ps[0].spaceBefore = Self.gap(above: pending[0], from: lastBottom) }
            out += ps.map { .paragraph($0) }
            lastBottom = pending.last?.rect.maxY
            pending = []
        }
        for item in items {
            switch item {
            case .line(let l):
                pending.append(l)
            case .table(var t, let rect):
                flush()
                // Word can't put space above a table, so the paragraph before it carries the gap.
                if let lastBottom, case .paragraph(var before)? = out.last {
                    before.spaceAfter = max(0, rect.minY - lastBottom).clamped(0, 48)
                    out[out.count - 1] = .paragraph(before)
                }
                t.indent = max(0, rect.minX - container.minX)
                out.append(.table(t))
                lastBottom = rect.maxY
            case .image(let img):
                flush()
                var p = DocParagraph()
                let width = min(img.rect.width, container.width)
                let scale = width / img.rect.width
                p.runs = [DocRun(text: "", style: defaultStyle, image: DocImage(data: img.data, ext: img.ext, size: CGSize(width: width, height: img.rect.height * scale)))]
                p.alignment = abs(img.rect.midX - container.midX) < container.width * 0.08 && img.rect.width < container.width * 0.9 ? .center
                    : img.rect.minX > container.midX ? .right : .left
                if p.alignment == .left { p.leftIndent = max(0, img.rect.minX - container.minX) }
                if let lastBottom { p.spaceBefore = max(0, img.rect.minY - lastBottom).clamped(0, 48) }
                out.append(.paragraph(p))
                lastBottom = img.rect.maxY
            case .rule(let r):
                flush()
                var p = DocParagraph()
                p.bottomBorder = (r.width, r.color)
                p.leftIndent = max(0, r.start - container.minX)
                p.runs = [DocRun(text: "", style: TextStyle(font: defaultStyle.font, size: 2, bold: false, italic: false, color: "000000"))]
                out.append(.paragraph(p))
                lastBottom = r.position
            }
        }
        flush()
        return out
    }

    // MARK: Paragraphs

    private func paragraphs(from input: [Line], container: CGRect, fills: [(rect: CGRect, color: String)]) -> [DocParagraph] {
        // Pieces of the same row (split by wide justified gaps) rejoin first.
        var lines: [Line] = []
        for line in input {
            if var last = lines.last, abs(last.rect.midY - line.rect.midY) < 0.4 * min(last.rect.height, line.rect.height), line.rect.minX > last.rect.maxX - 2 {
                // A wide gap was a tab in the original ("Label      Value").
                if line.rect.minX - last.rect.maxX > 2 * line.size, let style = last.glyphs.last?.style {
                    last.glyphs.append(Glyph(text: "\t", rect: CGRect(x: last.rect.maxX, y: last.rect.minY, width: 0, height: last.rect.height), style: style))
                }
                last.glyphs += line.glyphs
                last.rect = last.rect.union(line.rect)
                lines[lines.count - 1] = last
            } else {
                lines.append(line)
            }
        }

        var groups: [[Line]] = []
        for line in lines {
            guard let prev = groups.last?.last else { groups.append([line]); continue }
            if startsNewParagraph(prev: prev, line: line, group: groups[groups.count - 1], container: container) {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        var out: [DocParagraph] = []
        var listRun: (kind: ListDefinition.Kind, numId: Int, next: Int, levels: [CGFloat])?
        var previousBottom: CGFloat?
        for group in groups {
            var p = paragraph(lines: group, container: container, sameRow: false)
            if let previousBottom { p.spaceBefore = Self.gap(above: group[0], from: previousBottom) }
            previousBottom = group.last?.rect.maxY
            if let marker = group[0].marker {
                // Continue the current list when the numbering carries on; otherwise start one.
                if listRun == nil || listRun!.kind != marker.kind || (marker.kind != .bullet && marker.value != listRun!.next && marker.value == 1) {
                    lists.append(ListDefinition(kind: marker.kind, start: marker.value))
                    listRun = (marker.kind, lists.count, marker.value + 1, [])
                } else {
                    listRun!.next = marker.value + 1
                }
                var levels = listRun!.levels
                if !levels.contains(where: { abs($0 - marker.x) < 6 }) { levels.append(marker.x); levels.sort() }
                listRun!.levels = levels
                let level = levels.firstIndex { abs($0 - marker.x) < 6 } ?? 0
                p.list = (listRun!.numId, min(level, 2))
                p.markerText = marker.text
                p.alignment = .left
                p.leftIndent = max(0, marker.textX - container.minX)
                p.firstLineIndent = -(marker.textX - marker.x)
            } else if p.runs.count > 0, !out.isEmpty, out.last?.list == nil {
                listRun = nil
            }
            let center = CGPoint(x: Self.bounds(group.flatMap(\.glyphs)).midX, y: Self.bounds(group.flatMap(\.glyphs)).midY)
            p.shading = fills.first { $0.rect.contains(center) && $0.rect.width < 2000 }?.color
            out.append(p)
        }
        return out
    }

    /// Space above a line in Word terms. Word's single line is taller than the glyph box for
    /// some fonts (Helvetica's box is exactly its size), so that extra comes out of the gap.
    static func gap(above line: Line, from bottom: CGFloat) -> CGFloat {
        let extra = max(0, line.size * 1.17 - line.rect.height)
        return max(0, line.rect.minY - bottom - extra).clamped(0, 48)
    }

    private func startsNewParagraph(prev: Line, line: Line, group: [Line], container: CGRect) -> Bool {
        let size = max(prev.size, 1)
        if line.marker != nil { return true }
        if abs(line.size - prev.size) > 0.12 * size { return true }
        if prev.allBold != line.allBold, group.count == 1 || line.allBold { return true }
        let gap = line.rect.minY - prev.rect.maxY
        if gap > 0.55 * size { return true }
        if gap < -0.5 * size { return true } // went back up: different flow
        let first = group[0]
        // List items continue on lines aligned with their text, not their marker.
        if let marker = first.marker { return abs(line.rect.minX - marker.textX) > 0.6 * size && line.rect.minX < marker.textX - 2 }
        let width = container.width
        let prevShort = prev.rect.maxX < container.maxX - max(2.5 * size, width * 0.12)
        if prevShort, let last = prev.text.last, ".!?:;\"”)".contains(last) { return true }
        if line.rect.minX > prev.rect.minX + 0.8 * size, group.count > 1 || prevShort { return true }
        if isCentered(prev, container) != isCentered(line, container), group.count == 1 { return true }
        return false
    }

    private func isCentered(_ line: Line, _ container: CGRect) -> Bool {
        abs(line.rect.midX - container.midX) < container.width * 0.04 && line.rect.width < container.width * 0.85
            && line.rect.minX > container.minX + container.width * 0.06
    }

    private func paragraph(lines: [Line], container: CGRect, sameRow: Bool) -> DocParagraph {
        var p = DocParagraph()
        let first = lines[0]
        // Short left-aligned lines with no running prose (addresses, poems) keep their breaks.
        let keepBreaks = !sameRow && lines.count >= 2 && lines.allSatisfy { $0.rect.width < container.width * 0.55 }
            && lines.dropLast().allSatisfy { !($0.text.last.map { ".,;".contains($0) } ?? false) }
        var runsOut: [DocRun] = []
        for (i, line) in lines.enumerated() {
            var lineRuns = runs(for: [line], pageNumber: nil)
            if i > 0, !lineRuns.isEmpty {
                if sameRow || !keepBreaks {
                    // Join wrapped lines; rejoin words hyphenated at the line end.
                    if let last = runsOut.last, last.text.hasSuffix("-"), last.text.dropLast().last?.isLowercase == true,
                       lineRuns[0].text.first?.isLowercase == true {
                        runsOut[runsOut.count - 1].text.removeLast()
                    } else if let last = runsOut.last, !last.text.hasSuffix(" "), !last.text.hasSuffix("-") || sameRow {
                        runsOut[runsOut.count - 1].text += " "
                    }
                } else {
                    runsOut.append(DocRun(text: "", style: lineRuns[0].style, lineBreak: true))
                }
            }
            runsOut += lineRuns
            lineRuns = []
        }
        p.runs = Self.coalesce(runsOut)

        let lefts = lines.map(\.rect.minX)
        let rest = lines.count > 1 ? Array(lefts.dropFirst()) : lefts
        let left = rest.min() ?? first.rect.minX
        p.leftIndent = max(0, left - container.minX)
        p.firstLineIndent = first.rect.minX - left
        if abs(p.firstLineIndent) < 2 { p.firstLineIndent = 0 }

        if lines.allSatisfy({ isCentered($0, container) }) {
            p.alignment = .center
            p.leftIndent = 0
            p.firstLineIndent = 0
        } else if lines.allSatisfy({ abs($0.rect.maxX - container.maxX) < 4 }) && lines.contains(where: { $0.rect.minX > container.minX + container.width * 0.3 }) {
            p.alignment = .right
            p.leftIndent = 0
            p.firstLineIndent = 0
        } else if lines.count >= 3, lines.dropLast().allSatisfy({ abs($0.rect.maxX - container.maxX) < 3 }) {
            p.alignment = .both
        }

        if lines.count >= 2, !sameRow {
            let pitches = zip(lines, lines.dropFirst()).map { $1.rect.midY - $0.rect.midY }.sorted()
            let pitch = pitches[pitches.count / 2]
            // Exact pitch: Word's idea of "single" varies by font, the PDF's spacing doesn't.
            if pitch > first.size * 0.9, pitch < first.size * 3 { p.exactLineHeight = pitch }
        }
        return p
    }

    /// Glyphs → styled runs, with spaces, links, underline and super/subscripts.
    private func runs(for lines: [Line], pageNumber: Int?) -> [DocRun] {
        var out: [DocRun] = []
        for line in lines {
            let main = line.style
            let bottoms = line.glyphs.filter { $0.style.size == main.size }.map(\.rect.maxY).sorted()
            let baseline = bottoms.isEmpty ? line.rect.maxY : bottoms[bottoms.count / 2]
            for (i, g) in line.glyphs.enumerated() {
                var script = DocRun.Script.normal
                if g.style.size < main.size * 0.85 {
                    if g.rect.maxY < baseline - 0.2 * main.size { script = .superscript } else if g.rect.maxY > baseline + 0.1 * main.size { script = .`subscript` }
                }
                let space = i > 0 && Line.needsSpace(line.glyphs[i - 1], g) ? " " : ""
                var style = g.style
                // Word shrinks super/subscript itself, so give it the surrounding size.
                if script != .normal { style.size = main.size }
                var run = DocRun(text: space + g.text, style: style, underline: g.underline, link: g.link, script: script)
                if let pageNumber, g.text.allSatisfy(\.isNumber), Int(Self.digits(line.glyphs, around: i)) == pageNumber {
                    run.pageField = true
                }
                out.append(run)
            }
        }
        var merged = Self.coalesce(out)
        // A page number in a header/footer becomes one PAGE field.
        if pageNumber != nil {
            var collapsed: [DocRun] = []
            for r in merged {
                if r.pageField, let last = collapsed.last, last.pageField { continue }
                if r.pageField {
                    let lead = r.text.prefix { $0 == " " }
                    if !lead.isEmpty { collapsed.append(DocRun(text: String(lead), style: r.style)) }
                }
                collapsed.append(r)
            }
            merged = collapsed
        }
        return merged
    }

    private static func digits(_ glyphs: [Glyph], around i: Int) -> String {
        var lo = i, hi = i
        while lo > 0, glyphs[lo - 1].text.allSatisfy(\.isNumber), !Line.needsSpace(glyphs[lo - 1], glyphs[lo]) { lo -= 1 }
        while hi + 1 < glyphs.count, glyphs[hi + 1].text.allSatisfy(\.isNumber), !Line.needsSpace(glyphs[hi], glyphs[hi + 1]) { hi += 1 }
        return glyphs[lo...hi].map(\.text).joined()
    }

    /// Adjacent runs with identical formatting become one.
    static func coalesce(_ runs: [DocRun]) -> [DocRun] {
        var out: [DocRun] = []
        for r in runs {
            if var last = out.last, r.image == nil, last.image == nil, !r.lineBreak, !last.lineBreak, !r.columnBreak, !last.columnBreak,
               last.style == r.style, last.underline == r.underline, last.link == r.link, last.script == r.script, last.pageField == r.pageField {
                last.text += r.text
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: Pages, backgrounds, headings

    /// Big pictures with text printed over them sit behind the text, where they were.
    private func attachBackgrounds(_ blocks: inout [DocBlock], page: Int, lines: [Line]) {
        let area = pages[page].size.width * pages[page].size.height
        for i in blocks.indices {
            guard case .paragraph(var p) = blocks[i], p.runs.count == 1, var image = p.runs[0].image else { continue }
            guard let source = (pages[page].images.first { $0.data == image.data }), source.rect.width * source.rect.height > area * 0.45 else { continue }
            let covered = lines.filter { source.rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }.count
            guard covered >= 2 else { continue }
            image.behindAt = source.rect.origin
            image.size = source.rect.size
            p.runs[0].image = image
            // Behind-text images take no space in the flow; hang it off an empty paragraph.
            p.spaceBefore = 0
            p.alignment = .left
            p.leftIndent = 0
            blocks[i] = .paragraph(p)
        }
    }

    /// Adds one page's blocks, continuing a paragraph that runs over the page break.
    private func join(_ blocks: inout [DocBlock], with page: inout [DocBlock], previousPage: Int, previousBottom: CGFloat?, pageHeight: CGFloat) {
        defer { blocks += page }
        guard previousPage >= 0, !page.isEmpty else { return }
        if case .paragraph(let last)? = blocks.last, case .paragraph(let next) = page[0],
           last.list == nil, next.list == nil, !last.runs.isEmpty, !next.runs.isEmpty, last.runs.last?.image == nil, next.runs.first?.image == nil,
           let lastStyle = last.runs.last?.style, let nextStyle = next.runs.first?.style, lastStyle.size == nextStyle.size, lastStyle.bold == nextStyle.bold,
           let end = last.plainText.trimmingCharacters(in: .whitespaces).last, !".!?:”\"".contains(end) {
            var merged = last
            if merged.plainText.hasSuffix("-"), next.plainText.first?.isLowercase == true {
                merged.runs[merged.runs.count - 1].text.removeLast()
            } else {
                merged.runs[merged.runs.count - 1].text += " "
            }
            merged.runs = Self.coalesce(merged.runs + next.runs)
            blocks[blocks.count - 1] = .paragraph(merged)
            page.removeFirst()
            return
        }
        // A page that ended well short of the bottom was broken on purpose; keep that break.
        // Otherwise let text flow, so Word's own pagination (headings kept with text) works.
        guard let previousBottom, previousBottom < pageHeight * 0.72 else { return }
        if case .paragraph(var first) = page[0] {
            first.pageBreakBefore = true
            first.spaceBefore = 0
            page[0] = .paragraph(first)
        } else {
            var p = DocParagraph()
            p.pageBreakBefore = true
            p.runs = [DocRun(text: "", style: TextStyle(font: "Calibri", size: 2, bold: false, italic: false, color: "000000"))]
            page.insert(.paragraph(p), at: 0)
        }
    }

    /// Bigger-than-body text becomes Heading 1–3 (by size); short bold lines at body size, Heading 4.
    private func assignHeadings(_ blocks: inout [DocBlock], body: CGFloat) {
        func info(_ p: DocParagraph) -> (size: CGFloat, bold: Bool, text: String)? {
            let text = p.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            // List items only qualify when their text is clearly heading-sized.
            guard !text.isEmpty, p.runs.allSatisfy({ $0.image == nil }) else { return nil }
            var counts: [CGFloat: Int] = [:]
            for r in p.runs { counts[r.style.size, default: 0] += r.text.count }
            let size = counts.max { $0.value < $1.value }!.key
            return (size, p.runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy(\.style.bold), text)
        }
        var sizes = Set<CGFloat>()
        for case .paragraph(let p) in blocks {
            if let i = info(p), i.size >= body * 1.18, i.text.count < 200 { sizes.insert(i.size) }
        }
        func isList(_ p: DocParagraph) -> Bool { p.list != nil }
        let ranked = sizes.sorted(by: >)
        for k in blocks.indices {
            guard case .paragraph(var p) = blocks[k], let i = info(p) else { continue }
            if let level = ranked.firstIndex(of: i.size), i.text.count < 200 {
                p.headingLevel = min(level + 1, 3)
                // "1. Introduction" is a numbered heading, not a one-item list.
                if p.list != nil, let marker = p.markerText, let style = p.runs.first?.style {
                    p.list = nil
                    p.runs.insert(DocRun(text: marker + " ", style: style), at: 0)
                    p.leftIndent = max(0, p.leftIndent + p.firstLineIndent)
                    p.firstLineIndent = 0
                    p.runs = Self.coalesce(p.runs)
                }
            } else if !isList(p), i.bold, abs(i.size - body) < 1, i.text.count < 90, !i.text.hasSuffix("."), !i.text.hasSuffix(","), i.text.split(separator: " ").count <= 12 {
                p.headingLevel = min(ranked.count + 1, 4)
            }
            blocks[k] = .paragraph(p)
        }
    }
}
