import AppKit

/// The butterfly-and-sparkle silhouette from the app icon, as a template image for the
/// menu bar (macOS tints it to match light or dark menu bars).
enum MenuBarIcon {
    static let image: NSImage = {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // Shapes are drawn on a 100-unit grid, y down; the artwork spans x 6–94, y 4–88.
            let scale = size / 92
            let transform = NSAffineTransform()
            transform.translateX(by: size / 2 - 50 * scale, yBy: size / 2 - 46 * scale)
            transform.scale(by: scale)
            transform.concat()
            NSColor.black.setFill()
            for path in shapes { path.fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacConvert"
        return image
    }()

    private static var shapes: [NSBezierPath] {
        [
            // Upper wings: teardrops reaching up to the corners.
            path([(47, 54)], [(40, 36, 26, 16, 13, 15), (5, 15, 6, 28, 11, 39), (18, 52, 32, 58, 47, 57)]),
            path([(53, 54)], [(60, 36, 74, 16, 87, 15), (95, 15, 94, 28, 89, 39), (82, 52, 68, 58, 53, 57)]),
            // Lower wings: rounded.
            path([(47, 59)], [(38, 57, 24, 58, 20, 70), (17, 80, 25, 88, 35, 86), (44, 84, 48, 74, 47, 59)]),
            path([(53, 59)], [(62, 57, 76, 58, 80, 70), (83, 80, 75, 88, 65, 86), (56, 84, 52, 74, 53, 59)]),
            // Four-point sparkle above.
            path([(50, 4)], [(51.2, 12, 53, 14, 61, 15.5), (53, 17, 51.2, 19, 50, 27), (48.8, 19, 47, 17, 39, 15.5), (47, 14, 48.8, 12, 50, 4)]),
        ]
    }

    /// A closed path from a start point and cubic segments (control 1, control 2, end).
    private static func path(_ start: [(CGFloat, CGFloat)], _ curves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: start[0].0, y: start[0].1))
        for c in curves {
            p.curve(to: NSPoint(x: c.4, y: c.5), controlPoint1: NSPoint(x: c.0, y: c.1), controlPoint2: NSPoint(x: c.2, y: c.3))
        }
        p.close()
        return p
    }
}
