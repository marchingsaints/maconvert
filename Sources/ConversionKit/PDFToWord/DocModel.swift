import CoreGraphics
import Foundation

/// A flow document rebuilt from a PDF: what the DOCX writer turns into Word XML.
struct DocModel {
    var pageSize: CGSize
    var margins: (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat)
    var bodyFont: String
    var bodySize: CGFloat
    var header: [DocParagraph] = []
    var footer: [DocParagraph] = []
    var blocks: [DocBlock] = []
    var title: String
}

enum DocBlock {
    case paragraph(DocParagraph)
    case table(DocTable)
    /// Ends the current section; `columns` describes the section that just ended.
    case sectionBreak(columns: Int, spacing: CGFloat)
}

struct DocRun {
    var text: String
    var style: TextStyle
    var underline = false
    var link: String?
    var script: Script = .normal
    /// Stands for the current page number (used in footers).
    var pageField = false
    var image: DocImage?
    var lineBreak = false
    var columnBreak = false

    enum Script { case normal, superscript, `subscript` }
}

struct DocImage {
    var data: Data
    var ext: String
    var size: CGSize
    /// Behind the text at a fixed page position (backgrounds, full-bleed art).
    var behindAt: CGPoint?
}

struct DocParagraph {
    var runs: [DocRun] = []
    var headingLevel: Int?
    var list: (numId: Int, level: Int)?
    /// The marker as printed ("1.", "•"), kept in case the paragraph turns out to be a numbered heading.
    var markerText: String?
    var alignment: Alignment = .left
    var leftIndent: CGFloat = 0
    /// Negative for a hanging indent.
    var firstLineIndent: CGFloat = 0
    var spaceBefore: CGFloat = 0
    var spaceAfter: CGFloat = 0
    /// Line height as a multiple of single spacing.
    var lineSpacing: CGFloat = 1
    /// Exact line pitch in points, when the PDF showed several lines (keeps pagination faithful).
    var exactLineHeight: CGFloat?
    var pageBreakBefore = false
    var shading: String?
    var bottomBorder: (width: CGFloat, color: String)?

    enum Alignment: String { case left, center, right, both }

    var plainText: String { runs.map(\.text).joined() }
}

struct DocTable {
    var columnWidths: [CGFloat]
    var indent: CGFloat
    var rows: [DocRow]
    /// Left/right padding inside each cell, in points. Borderless layouts had none.
    var cellPadding: CGFloat = 3.6
}

struct DocRow {
    var height: CGFloat
    var cells: [DocCell]
}

struct DocCell {
    var span = 1
    var vMerge: VMerge = .none
    var paragraphs: [DocParagraph] = []
    var shading: String?
    /// top, left, bottom, right
    var borders: [Edge: (width: CGFloat, color: String)] = [:]

    enum VMerge { case none, restart, `continue` }
    enum Edge: String, CaseIterable { case top, left, bottom, right }
}

/// List definitions the writer emits in numbering.xml.
struct ListDefinition {
    enum Kind: String { case bullet, decimal, lowerLetter, upperLetter, lowerRoman, upperRoman }
    var kind: Kind
    var start: Int
}
