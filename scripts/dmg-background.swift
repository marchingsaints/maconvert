// Draws the DMG window background: swift scripts/dmg-background.swift out.png scale
// The window is 600×380 points; icon centres sit at (150, 185) and (450, 185), measured from the top.
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = NSSize(width: 600 * scale, height: 380 * scale)
let image = NSImage(size: size)
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: scale, y: scale)

// Soft light gradient, so the default black icon labels stay readable.
let gradient = NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1)])!
gradient.draw(in: NSRect(x: 0, y: 0, width: 600, height: 380), angle: -90)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
    (s as NSString).draw(in: NSRect(x: 0, y: y, width: 600, height: size * 1.6), withAttributes: attrs)
}

// Coordinates here are y-up; Finder's icon positions are y-down from the top.
text("Install MacConvert", size: 22, weight: .semibold, color: NSColor(white: 0.12, alpha: 1), y: 318)
text("Drag the app onto the Applications folder", size: 13, weight: .regular, color: NSColor(white: 0.4, alpha: 1), y: 294)

// Arrow from the app to Applications.
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 232, y: 195))
arrow.line(to: NSPoint(x: 360, y: 195))
NSColor(red: 0.36, green: 0.42, blue: 1, alpha: 0.85).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: 348, y: 207))
head.line(to: NSPoint(x: 364, y: 195))
head.line(to: NSPoint(x: 348, y: 183))
head.stroke()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: 600, height: 380)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
