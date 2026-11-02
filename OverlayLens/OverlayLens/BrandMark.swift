import AppKit
import SwiftUI

/// OverlayLens wears the Claude Code mascot. Redrawn here as vector rects on a
/// unit grid rather than shipped as a bitmap, so the same sprite serves the
/// 15pt menu bar template, the lens header status light, and a 1024px app
/// icon without ever going soft. Hard corners on purpose — it's pixel art.
enum Brand {
    /// The mascot's own clay, also used for the lens's "translating" state.
    static let clay = Color(red: 0.784, green: 0.451, blue: 0.337)
    static let clayNS = NSColor(srgbRed: 0.784, green: 0.451, blue: 0.337, alpha: 1)
    static let cream = NSColor(srgbRed: 0.965, green: 0.949, blue: 0.925, alpha: 1)

    // MARK: - Sprite geometry (unit cells, y measured downward)

    private static let bodyW: CGFloat = 8
    private static let bodyH: CGFloat = 5
    private static let legH: CGFloat = 1.3
    static let spanX: ClosedRange<CGFloat> = -1...9
    static let spanY: ClosedRange<CGFloat> = 0...(bodyH + legH)
    /// Sprite is wider than tall; callers size by height and let width follow.
    static let aspect: CGFloat = (spanX.upperBound - spanX.lowerBound) / (spanY.upperBound - spanY.lowerBound)

    private static let bodyParts: [CGRect] = [
        CGRect(x: 0, y: 0, width: bodyW, height: bodyH),
        CGRect(x: -1, y: 2.2, width: 1, height: 1.4),
        CGRect(x: 8, y: 1.7, width: 1, height: 1.4),
        CGRect(x: 1.3, y: bodyH, width: 0.6, height: legH),
        CGRect(x: 2.6, y: bodyH, width: 0.6, height: legH),
        CGRect(x: 5.0, y: bodyH, width: 0.6, height: legH),
        CGRect(x: 6.3, y: bodyH, width: 0.6, height: legH),
    ]

    private static let eyes: [CGRect] = [
        CGRect(x: 2.0, y: 1.0, width: 0.75, height: 2.0),
        CGRect(x: 5.6, y: 1.0, width: 0.75, height: 2.0),
    ]

    /// All cells, eyes included — fill with the even-odd rule so the eyes punch
    /// through as holes and the sprite works as a single-colour template.
    static func mascotCells() -> [CGRect] {
        bodyParts + eyes
    }

    static func size(unit: CGFloat) -> CGSize {
        CGSize(width: (spanX.upperBound - spanX.lowerBound) * unit,
               height: (spanY.upperBound - spanY.lowerBound) * unit)
    }

    /// AppKit path, y flipped, optionally tilted like the reference art.
    static func mascotPath(unit: CGFloat, origin: NSPoint, tilt: CGFloat = 0) -> NSBezierPath {
        let path = NSBezierPath()
        for cell in mascotCells() {
            path.appendRect(NSRect(
                x: cell.minX * unit,
                y: (spanY.upperBound - cell.maxY) * unit,
                width: cell.width * unit,
                height: cell.height * unit
            ))
        }
        path.windingRule = .evenOdd

        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        if tilt != 0 {
            let box = size(unit: unit)
            transform.translateX(by: box.width / 2, yBy: box.height / 2)
            transform.rotate(byDegrees: tilt)
            transform.translateX(by: -box.width / 2, yBy: -box.height / 2)
        }
        transform.translateX(by: -spanX.lowerBound * unit, yBy: 0)
        path.transform(using: transform as AffineTransform)
        return path
    }

    /// Menu bar icon: sized by height (the bar's constraint) and drawn as a
    /// template so macOS tints it for light/dark.
    static func menuBarMark(height: CGFloat = 15) -> NSImage {
        let unit = height / (spanY.upperBound - spanY.lowerBound)
        let box = size(unit: unit)
        let image = NSImage(size: NSSize(width: ceil(box.width), height: ceil(box.height)), flipped: false) { _ in
            NSColor.black.setFill()
            mascotPath(unit: unit, origin: .zero).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// SwiftUI twin of the sprite, aspect-fitted into whatever frame it's given.
/// Fill it with `FillStyle(eoFill: true)` or the eyes fill in solid.
struct MascotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(
            rect.width / (Brand.spanX.upperBound - Brand.spanX.lowerBound),
            rect.height / (Brand.spanY.upperBound - Brand.spanY.lowerBound)
        )
        let box = Brand.size(unit: unit)
        let dx = rect.minX + (rect.width - box.width) / 2 - Brand.spanX.lowerBound * unit
        let dy = rect.minY + (rect.height - box.height) / 2

        var path = Path()
        for cell in Brand.mascotCells() {
            path.addRect(CGRect(
                x: dx + cell.minX * unit,
                y: dy + cell.minY * unit,
                width: cell.width * unit,
                height: cell.height * unit
            ))
        }
        return path
    }
}
