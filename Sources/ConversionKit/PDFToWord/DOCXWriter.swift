import CryptoKit
import Foundation

/// DocModel → .docx (WordprocessingML), readable by Word, Pages and Google Docs.
struct DOCXWriter {
    private let model: DocModel
    private let lists: [ListDefinition]
    private var media: [(name: String, data: Data)] = []
    private var mediaByHash: [String: String] = [:]
    private var rels: [(id: String, type: String, target: String, external: Bool)] = []
    private var drawingID = 1

    static func write(_ model: DocModel, lists: [ListDefinition], to url: URL) throws {
        var writer = DOCXWriter(model: model, lists: lists)
        try writer.package().write(to: url)
    }

    private init(model: DocModel, lists: [ListDefinition]) {
        self.model = model
        self.lists = lists
    }

    private mutating func package() -> Data {
        rels = [
            ("rId1", "styles", "styles.xml", false),
            ("rId2", "settings", "settings.xml", false),
            ("rId3", "numbering", "numbering.xml", false),
            ("rId4", "fontTable", "fontTable.xml", false),
        ]
        let headerXML = model.header.isEmpty ? nil : part("hdr", model.header)
        let footerXML = model.footer.isEmpty ? nil : part("ftr", model.footer)
        if headerXML != nil { rels.append(("rIdHeader", "header", "header1.xml", false)) }
        if footerXML != nil { rels.append(("rIdFooter", "footer", "footer1.xml", false)) }
        let body = document()

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes(header: headerXML != nil, footer: footerXML != nil))
        zip.add("_rels/.rels", PPTXWriter.rels([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", "word/document.xml"),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
            ("rId3", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties", "docProps/app.xml"),
        ]))
        zip.add("docProps/core.xml", OOXML.coreProperties(title: model.title))
        zip.add("docProps/app.xml", OOXML.appProperties)
        zip.add("word/document.xml", body)
        zip.add("word/styles.xml", styles())
        zip.add("word/settings.xml", settings)
        zip.add("word/numbering.xml", numbering())
        zip.add("word/fontTable.xml", fontTable)
        if let headerXML { zip.add("word/header1.xml", headerXML) }
        if let footerXML { zip.add("word/footer1.xml", footerXML) }
        for m in media { zip.add("word/media/\(m.name)", m.data, compress: false) }
        zip.add("word/_rels/document.xml.rels", relationships())
        return zip.finish()
    }

    // MARK: Body

    private mutating func document() -> String {
        var xml = ""
        for (i, block) in model.blocks.enumerated() {
            switch block {
            case .paragraph(let p):
                xml += paragraph(p)
            case .table(let t):
                xml += table(t)
                // Word needs a paragraph between two tables, and after a final table.
                if i + 1 == model.blocks.count || { if case .table = model.blocks[i + 1] { return true }; return false }() {
                    xml += "<w:p/>"
                }
            case .sectionBreak(let columns, let spacing):
                // A section's properties live in a paragraph that closes it.
                xml += "<w:p><w:pPr>\(sectionProperties(columns: columns, spacing: spacing, continuous: true))</w:pPr></w:p>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(Self.namespaces)><w:body>\(xml)\(sectionProperties(columns: 1, spacing: 0, continuous: false))</w:body></w:document>
        """
    }

    private func sectionProperties(columns: Int, spacing: CGFloat, continuous: Bool) -> String {
        let m = model.margins
        var refs = ""
        if !model.header.isEmpty { refs += "<w:headerReference w:type=\"default\" r:id=\"rIdHeader\"/>" }
        if !model.footer.isEmpty { refs += "<w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/>" }
        let orient = model.pageSize.width > model.pageSize.height ? " w:orient=\"landscape\"" : ""
        return "<w:sectPr>\(refs)\(continuous ? "<w:type w:val=\"continuous\"/>" : "")"
            + "<w:pgSz w:w=\(tw(model.pageSize.width)) w:h=\(tw(model.pageSize.height))\(orient)/>"
            + "<w:pgMar w:top=\(tw(m.top)) w:right=\(tw(m.right)) w:bottom=\(tw(m.bottom)) w:left=\(tw(m.left)) w:header=\(tw(min(36, m.top / 2))) w:footer=\(tw(min(36, m.bottom / 2))) w:gutter=\"0\"/>"
            + "<w:cols w:num=\"\(columns)\" w:space=\(tw(max(spacing, 12)))/></w:sectPr>"
    }

    private mutating func paragraph(_ p: DocParagraph) -> String {
        var ppr = ""
        if let level = p.headingLevel { ppr += "<w:pStyle w:val=\"Heading\(level)\"/>" } else if p.list != nil { ppr += "<w:pStyle w:val=\"ListParagraph\"/>" }
        if p.pageBreakBefore { ppr += "<w:pageBreakBefore/>" }
        if let list = p.list { ppr += "<w:numPr><w:ilvl w:val=\"\(list.level)\"/><w:numId w:val=\"\(list.numId)\"/></w:numPr>" }
        if let border = p.bottomBorder {
            ppr += "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"\(Int((border.width * 8).rounded()).clamped(2, 96))\" w:space=\"1\" w:color=\"\(border.color)\"/></w:pBdr>"
        }
        if let shading = p.shading { ppr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(shading)\"/>" }
        let lineRule = p.exactLineHeight.map { "w:line=\(tw($0)) w:lineRule=\"exact\"" } ?? "w:line=\"\(Int((240 * p.lineSpacing).rounded()))\" w:lineRule=\"auto\""
        ppr += "<w:spacing w:before=\(tw(p.spaceBefore)) w:after=\(tw(p.spaceAfter)) \(lineRule)/>"
        if p.leftIndent > 0.5 || abs(p.firstLineIndent) > 0.5 {
            let first = p.firstLineIndent < 0 ? "w:hanging=\(tw(-p.firstLineIndent))" : "w:firstLine=\(tw(p.firstLineIndent))"
            ppr += "<w:ind w:left=\(tw(p.leftIndent)) \(first)/>"
        }
        if p.alignment != .left { ppr += "<w:jc w:val=\"\(p.alignment.rawValue)\"/>" }

        var body = ""
        var openLink: String?
        for run in p.runs {
            if run.link != openLink {
                if openLink != nil { body += "</w:hyperlink>" }
                if let link = run.link { body += "<w:hyperlink r:id=\"\(hyperlink(link))\" w:history=\"1\">" }
                openLink = run.link
            }
            body += self.run(run)
        }
        if openLink != nil { body += "</w:hyperlink>" }
        return "<w:p><w:pPr>\(ppr)</w:pPr>\(body)</w:p>"
    }

    private mutating func run(_ r: DocRun) -> String {
        let rpr = runProperties(r)
        if let image = r.image { return "<w:r>\(rpr)\(drawing(image))</w:r>" }
        if r.lineBreak { return "<w:r>\(rpr)<w:br/></w:r>" }
        if r.columnBreak { return "<w:r><w:br w:type=\"column\"/></w:r>" + (r.text.isEmpty ? "" : textRun(r.text, rpr)) }
        if r.pageField {
            return "<w:r>\(rpr)<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>\(rpr)<w:instrText xml:space=\"preserve\"> PAGE </w:instrText></w:r>"
                + "<w:r>\(rpr)<w:fldChar w:fldCharType=\"separate\"/></w:r><w:r>\(rpr)<w:t>\(r.text.trimmingCharacters(in: .whitespaces).xmlEscaped)</w:t></w:r>"
                + "<w:r>\(rpr)<w:fldChar w:fldCharType=\"end\"/></w:r>"
        }
        return textRun(r.text, rpr)
    }

    /// Tabs become real Word tabs; everything else is literal text.
    private func textRun(_ text: String, _ rpr: String) -> String {
        guard !text.isEmpty else { return "" }
        let parts = text.components(separatedBy: "\t")
        var out = "<w:r>\(rpr)"
        for (i, part) in parts.enumerated() {
            if i > 0 { out += "<w:tab/>" }
            if !part.isEmpty { out += "<w:t xml:space=\"preserve\">\(part.xmlEscaped)</w:t>" }
        }
        return out + "</w:r>"
    }

    private func runProperties(_ r: DocRun) -> String {
        let s = r.style
        var x = "<w:rFonts w:ascii=\"\(s.font.xmlEscaped)\" w:hAnsi=\"\(s.font.xmlEscaped)\" w:cs=\"\(s.font.xmlEscaped)\" w:eastAsia=\"\(s.font.xmlEscaped)\"/>"
        if s.bold { x += "<w:b/><w:bCs/>" }
        if s.italic { x += "<w:i/><w:iCs/>" }
        if s.color != "000000" { x += "<w:color w:val=\"\(s.color)\"/>" }
        let half = Int((s.size * 2).rounded()).clamped(2, 3276)
        x += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        if r.underline || r.link != nil && r.underline { x += "<w:u w:val=\"single\"/>" }
        switch r.script {
        case .superscript: x += "<w:vertAlign w:val=\"superscript\"/>"
        case .`subscript`: x += "<w:vertAlign w:val=\"subscript\"/>"
        case .normal: break
        }
        return "<w:rPr>\(x)</w:rPr>"
    }

    // MARK: Tables

    private mutating func table(_ t: DocTable) -> String {
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\(tw(t.columnWidths.reduce(0, +))) w:type=\"dxa\"/>"
        if t.indent > 0.5 { xml += "<w:tblInd w:w=\(tw(t.indent)) w:type=\"dxa\"/>" }
        let pad = Int((t.cellPadding * 20).rounded())
        xml += "<w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"\(pad)\" w:type=\"dxa\"/><w:right w:w=\"\(pad)\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        xml += t.columnWidths.map { "<w:gridCol w:w=\(tw($0))/>" }.joined() + "</w:tblGrid>"
        for row in t.rows {
            xml += "<w:tr><w:trPr><w:trHeight w:val=\(tw(row.height)) w:hRule=\"atLeast\"/></w:trPr>"
            var col = 0
            for cell in row.cells {
                let width = t.columnWidths[col..<min(col + cell.span, t.columnWidths.count)].reduce(0, +)
                col += cell.span
                var tcpr = "<w:tcW w:w=\(tw(width)) w:type=\"dxa\"/>"
                if cell.span > 1 { tcpr += "<w:gridSpan w:val=\"\(cell.span)\"/>" }
                switch cell.vMerge {
                case .restart: tcpr += "<w:vMerge w:val=\"restart\"/>"
                case .continue: tcpr += "<w:vMerge/>"
                case .none: break
                }
                tcpr += "<w:tcBorders>" + DocCell.Edge.allCases.map { edge in
                    guard let b = cell.borders[edge] else { return "<w:\(edge.rawValue) w:val=\"nil\"/>" }
                    return "<w:\(edge.rawValue) w:val=\"single\" w:sz=\"\(Int((b.width * 8).rounded()).clamped(2, 96))\" w:space=\"0\" w:color=\"\(b.color)\"/>"
                }.joined() + "</w:tcBorders>"
                if let shading = cell.shading { tcpr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(shading)\"/>" }
                tcpr += "<w:vAlign w:val=\"center\"/>"
                var content = cell.paragraphs.map { p -> String in
                    var p = p
                    if p.spaceBefore > 0, p.runs.first?.image == nil { p.spaceBefore = min(p.spaceBefore, 6) }
                    return paragraph(p)
                }.joined()
                if content.isEmpty { content = "<w:p/>" }
                xml += "<w:tc><w:tcPr>\(tcpr)</w:tcPr>\(content)</w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    // MARK: Images and links

    private mutating func drawing(_ image: DocImage) -> String {
        let hash = SHA256.hash(data: image.data).description
        let rid: String
        if let existing = mediaByHash[hash] {
            rid = existing
        } else {
            let name = "image\(media.count + 1).\(image.ext)"
            media.append((name, image.data))
            rid = "rIdImg\(media.count)"
            rels.append((rid, "image", "media/\(name)", false))
            mediaByHash[hash] = rid
        }
        let cx = emu(image.size.width), cy = emu(image.size.height)
        let id = drawingID
        drawingID += 1
        let graphic = """
        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(id)" name="Picture \(id)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>
        """
        if let at = image.behindAt {
            return """
            <w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="\(id)" behindDoc="1" locked="0" layoutInCell="1" allowOverlap="1">\
            <wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>\(emu(at.x))</wp:posOffset></wp:positionH>\
            <wp:positionV relativeFrom="page"><wp:posOffset>\(emu(at.y))</wp:posOffset></wp:positionV><wp:extent cx="\(cx)" cy="\(cy)"/>\
            <wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/><wp:docPr id="\(id)" name="Picture \(id)"/><wp:cNvGraphicFramePr/>\(graphic)</wp:anchor></w:drawing>
            """
        }
        return """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>\
        <wp:docPr id="\(id)" name="Picture \(id)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>\(graphic)</wp:inline></w:drawing>
        """
    }

    private mutating func hyperlink(_ url: String) -> String {
        if let existing = rels.first(where: { $0.external && $0.target == url }) { return existing.id }
        let id = "rIdLink\(rels.count + 1)"
        rels.append((id, "hyperlink", url, true))
        return id
    }

    // MARK: Parts

    private mutating func part(_ tag: String, _ paragraphs: [DocParagraph]) -> String {
        let body = paragraphs.map { paragraph($0) }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:\(tag) \(Self.namespaces)>\(body)</w:\(tag)>"
    }

    private func relationships() -> String {
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let items = rels.map { r in
            "<Relationship Id=\"\(r.id)\" Type=\"\(base)\(r.type)\" Target=\"\(r.target.xmlEscaped)\"\(r.external ? " TargetMode=\"External\"" : "")/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(items)</Relationships>"
    }

    private func contentTypes(header: Bool, footer: Bool) -> String {
        let main = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        var overrides = [
            ("/word/document.xml", "\(main).document.main+xml"),
            ("/word/styles.xml", "\(main).styles+xml"),
            ("/word/settings.xml", "\(main).settings+xml"),
            ("/word/numbering.xml", "\(main).numbering+xml"),
            ("/word/fontTable.xml", "\(main).fontTable+xml"),
            ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
            ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
        ]
        if header { overrides.append(("/word/header1.xml", "\(main).header+xml")) }
        if footer { overrides.append(("/word/footer1.xml", "\(main).footer+xml")) }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/>\
        <Default Extension="png" ContentType="image/png"/>\
        \(overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined())</Types>
        """
    }

    private func styles() -> String {
        let font = model.bodyFont.xmlEscaped
        let size = Int((model.bodySize * 2).rounded()).clamped(8, 96)
        // Headings carry outline levels (navigation pane, Google Docs outline); their look
        // comes from the runs, so the styles add no formatting of their own.
        let headings = (1...4).map { level in
            """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
            <w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:outlineLvl w:val="\(level - 1)"/></w:pPr></w:style>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles \(Self.namespaces)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\(font)" w:hAnsi="\(font)" w:cs="\(font)" w:eastAsia="\(font)"/>\
        <w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\(headings)\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/></w:style>\
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>\
        <w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        </w:styles>
        """
    }

    private func numbering() -> String {
        // One abstract definition per list (so each can restart), three levels each.
        var abstracts = "", nums = ""
        for (i, list) in lists.enumerated() {
            let levels = (0..<3).map { level -> String in
                let indent = 360 * (level + 1) + 360
                if list.kind == .bullet {
                    let symbol = ["•", "◦", "▪"][level]
                    return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(symbol)\"/><w:lvlJc w:val=\"left\"/>"
                        + "<w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/></w:rPr></w:lvl>"
                }
                let format = level == 0 ? list.kind.rawValue : level == 1 ? "lowerLetter" : "lowerRoman"
                let suffix = list.kind == .decimal || level > 0 ? "." : ")"
                return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"\(level == 0 ? list.start : 1)\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"%\(level + 1)\(suffix)\"/>"
                    + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
            abstracts += "<w:abstractNum w:abstractNumId=\"\(i)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels)</w:abstractNum>"
            nums += "<w:num w:numId=\"\(i + 1)\"><w:abstractNumId w:val=\"\(i)\"/></w:num>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering \(Self.namespaces)>\(abstracts)\(nums)</w:numbering>"
    }

    private let settings = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/>\
    <w:characterSpacingControl w:val="doNotCompress"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
    """

    private let fontTable = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:fonts xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
    """

    static let namespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
    """

    // MARK: Units

    /// Points → twentieths of a point, quoted for an attribute.
    private func tw(_ points: CGFloat) -> String { "\"\(Int((points * 20).rounded()))\"" }
    private func emu(_ points: CGFloat) -> Int { Int((points * 12_700).rounded()) }
}

/// PDF → Word: read every page, rebuild the structure, write a .docx.
enum PDFToWord {
    static func convert(_ src: URL, to dst: URL, cancel: CancelFlag, progress: (Double) -> Void) throws {
        let doc = try PDFConverter.open(src)
        var pages: [PageContent] = []
        for i in 0..<doc.pageCount {
            if cancel.isSet { throw CancellationError() }
            guard let page = doc.page(at: i) else { continue }
            pages.append(PDFPageReader.read(page))
            progress(Double(i + 1) / Double(doc.pageCount) * 0.8)
        }
        let analyzer = LayoutAnalyzer(pages: pages, pdf: doc, title: src.deletingPathExtension().lastPathComponent)
        let model = analyzer.build()
        progress(0.9)
        try DOCXWriter.write(model, lists: analyzer.lists, to: dst)
        progress(1)
    }
}
