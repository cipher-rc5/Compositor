import AppKit

extension CanvasView {
    /// An invisible cursor, for tools that draw their own pointer on the canvas.
    static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    /// A symbol in white and in black, for a cursor that draws the one around the other so it reads on any image.
    /// Nil if this system lacks the symbol, and the cursor falls back to a standard one.
    private static func outlinedSymbol(_ name: String, description: String) -> (white: NSImage, black: NSImage)? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description),
              let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white])),
              let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black])) else { return nil }
        return (white, black)
    }
    /// Arrow with scissors: Cmd-dragging here cuts and moves the selected pixels.
    static let movePixelsCursor: NSCursor = {
        let base = NSCursor.arrow
        guard case let (white, black)? = outlinedSymbol("scissors", description: "Move pixels") else { return base }
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let glyph = CGRect(x: base.hotSpot.x + 9, y: base.hotSpot.y + 12, width: 11, height: 11)
            for step in 0..<12 {
                let angle = CGFloat(step) * .pi / 6
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.2, dy: sin(angle) * 1.2), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            black.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }()
    /// The pointer arrow as a vector path, tip at the origin (y down), about the system arrow's size.
    private static let arrowPath: NSBezierPath = {
        let arrow = NSBezierPath()
        for (index, point) in [(0, 0), (0, 16.5), (3.9, 12.8), (6.6, 19), (9.2, 17.9), (6.6, 11.8), (11.8, 11.8)].enumerated() {
            let point = NSPoint(x: point.0, y: point.1)
            if index == 0 { arrow.move(to: point) } else { arrow.line(to: point) }
        }
        arrow.close()
        arrow.lineJoinStyle = .round
        arrow.lineWidth = 2.2 // stroked under the fill, so about 1 pt of outline shows
        return arrow
    }()
    /// Shapes drawn back to front, outlined like the system cursors (each path's line width sets the
    /// outline, stroked under its fill), with a soft shadow. Coordinates are y-down.
    private static func outlinedCursor(size: NSSize, hotSpot: NSPoint,
                                       _ shapes: [(path: NSBezierPath, fill: NSColor, outline: NSColor)]) -> NSCursor {
        let image = NSImage(size: size, flipped: true) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            for shape in shapes {
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                shape.outline.setStroke()
                shape.path.stroke()
                NSGraphicsContext.restoreGraphicsState()
                shape.fill.setFill()
                shape.path.fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }
    /// Arrows drawn back to front, each offset down-right from the hot spot.
    private static func arrowCursor(_ arrows: [(offset: CGFloat, fill: NSColor, outline: NSColor)]) -> NSCursor {
        let tip = NSPoint(x: 4, y: 3)
        return outlinedCursor(size: NSSize(width: 28, height: 32), hotSpot: tip, arrows.map { arrow in
            let path = arrowPath.copy() as! NSBezierPath
            path.transform(using: AffineTransform(translationByX: tip.x + arrow.offset, byY: tip.y + arrow.offset))
            return (path, arrow.fill, arrow.outline)
        })
    }
    /// Photoshop's duplicate pointer: a black arrow over a white one offset behind it. Shown where a
    /// drag copies — Option-dragging a layer, Cmd-Option-dragging selected pixels.
    static let duplicateCursor = arrowCursor([(offset: 5, fill: .white, outline: .black), (offset: 0, fill: .black, outline: .white)])
    /// A white arrow over a transform handle that distorts when dragged (Cmd held, or already distorted).
    static let distortCursor = arrowCursor([(offset: 0, fill: .white, outline: .black)])
    /// Photoshop's Move pointer: the arrow with a small four-way arrow at its lower right. Shown wherever
    /// a press would drag a layer, away from the transform handles.
    static let moveCursor: NSCursor = {
        let base = NSCursor.arrow
        // Heads kept narrow and well apart, so the four arrows stay distinct at badge size.
        let badge = fourArrowPath(center: NSPoint(x: base.hotSpot.x + 14.5, y: base.hotSpot.y + 17.5),
                                  reach: 6.5, shaft: 0.75, head: 2, headLength: 2.5)
        badge.lineWidth = 1.6 // stroked under the fill, so about 0.8 pt of white outline shows
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            NSColor.white.setStroke()
            badge.stroke()
            NSColor.black.setFill()
            badge.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }()

    /// Four arrows around `center` (y-down): each reaches `reach` from the center along a shaft of
    /// half-width `shaft`, ending in a head `head` wide on each side and `headLength` long.
    private static func fourArrowPath(center: NSPoint, reach: CGFloat, shaft: CGFloat, head: CGFloat, headLength: CGFloat) -> NSBezierPath {
        // The top arrow, from the shaft on its left round the tip to the shaft on its right; turned a
        // quarter at a time ((x, y) → (−y, x)) it traces the other three arrows clockwise.
        let arm: [(CGFloat, CGFloat)] = [(-shaft, -reach + headLength), (-head, -reach + headLength), (0, -reach),
                                         (head, -reach + headLength), (shaft, -reach + headLength), (shaft, -shaft)]
        let path = NSBezierPath()
        for turn in 0..<4 {
            for var point in arm {
                for _ in 0..<turn { point = (-point.1, point.0) }
                let location = NSPoint(x: center.x + point.0, y: center.y + point.1)
                if path.isEmpty { path.move(to: location) } else { path.line(to: location) }
            }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
    /// Arrow with a small dashed box: dragging here moves the selection outline.
    static let moveSelectionCursor = selectionBadged(.arrow, boxAt: CGPoint(x: 9.5, y: 13.5))
    /// Pointing hand with a dashed box: Cmd-click a mask thumbnail to load it as a selection.
    static let loadSelectionCursor = selectionBadged(.pointingHand, boxAt: CGPoint(x: 11.5, y: 14.5))

    /// Adds a small dashed selection box to a system cursor, offset from its hot spot.
    static func selectionBadged(_ base: NSCursor, boxAt offset: CGPoint) -> NSCursor {
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let box = NSBezierPath(rect: NSRect(x: base.hotSpot.x + offset.x, y: base.hotSpot.y + offset.y, width: 8, height: 6))
            NSColor.white.setStroke()
            box.lineWidth = 2.5
            box.stroke()
            NSColor.black.setStroke()
            box.lineWidth = 1
            box.setLineDash([2, 1.5], count: 2, phase: 0)
            box.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }
    /// Which selection tool a crosshair names: the tool rail's icon, small, beneath and right of the crosshair.
    enum SelectionIcon: CaseIterable { case freehandLasso, polygonalLasso, rectangleMarquee, ellipseMarquee, objectSelection }

    /// Crosshair with the tool's icon, and a "+" (add) or "−" (subtract) beside the icon, as Photoshop shows.
    static let selectionCursors: [SelectionIcon: [SelectionMode: NSCursor]] = Dictionary(uniqueKeysWithValues:
        SelectionIcon.allCases.map { icon in
            (icon, Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { ($0, selectionCursor(icon, mode: $0)) }))
        })

    private static func selectionCursor(_ icon: SelectionIcon, mode: SelectionMode) -> NSCursor {
        let base = NSCursor.crosshair
        let hotSpot = base.hotSpot
        let image = NSImage(size: NSSize(width: 44, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let box = NSRect(x: hotSpot.x + 7, y: hotSpot.y + 7, width: 12, height: 12)
            drawSelectionIcon(icon, in: box)
            if mode != .replace {
                let center = CGPoint(x: box.maxX + 5, y: box.midY)
                let badge = NSBezierPath()
                // Same white-outlined black stroke and round ends as the system crosshair.
                badge.move(to: CGPoint(x: center.x - 3, y: center.y))
                badge.line(to: CGPoint(x: center.x + 3, y: center.y))
                if mode == .add {
                    badge.move(to: CGPoint(x: center.x, y: center.y - 3))
                    badge.line(to: CGPoint(x: center.x, y: center.y + 3))
                }
                badge.lineCapStyle = .round
                NSColor.white.setStroke()
                badge.lineWidth = 3.2
                badge.stroke()
                NSColor.black.setStroke()
                badge.lineWidth = 1.2
                badge.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    /// The tool rail's icon at cursor size: black with a thin white outline, so it reads on any image.
    private static func drawSelectionIcon(_ icon: SelectionIcon, in box: NSRect) {
        if icon == .polygonalLasso {
            // The rail's own drawing (see PolygonalLassoToolIcon), on its 18-unit grid.
            let unit = box.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
            let path = NSBezierPath()
            for (corners, closed) in [([point(1.2, 7.0), point(4.0, 2.4), point(11.8, 1.8), point(16.8, 5.2), point(15.6, 10.4), point(7.0, 11.6)], true),
                                      ([point(8.9, 10.9), point(13.3, 10.5), point(11.6, 14.5)], true),
                                      ([point(11.6, 14.5), point(12.9, 17.3)], false)] {
                path.move(to: corners[0])
                for corner in corners.dropFirst() { path.line(to: corner) }
                if closed { path.close() }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 1.4 * unit + 2
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.4 * unit
            path.stroke()
            return
        }
        if icon == .objectSelection {
            let unit = box.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
            let corners = NSBezierPath()
            for part in [[point(2, 6), point(2, 2), point(6, 2)], [point(12, 2), point(16, 2), point(16, 6)],
                         [point(16, 12), point(16, 16), point(12, 16)], [point(6, 16), point(2, 16), point(2, 12)]] {
                corners.move(to: part[0]); corners.line(to: part[1]); corners.line(to: part[2])
            }
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            NSColor.white.setStroke()
            corners.lineWidth = 1.6 * unit + 2
            corners.stroke()
            NSColor.black.setStroke()
            corners.lineWidth = 1.6 * unit
            corners.stroke()
            let cursor = NSBezierPath()
            for (index, p) in [point(7, 5), point(7, 14), point(9.6, 11.7), point(11.3, 15.3),
                               point(13.2, 14.4), point(11.5, 10.9), point(14.5, 10.9)].enumerated() {
                index == 0 ? cursor.move(to: p) : cursor.line(to: p)
            }
            cursor.close()
            cursor.lineJoinStyle = .round
            NSColor.white.setStroke()
            cursor.lineWidth = 2
            cursor.stroke()
            NSColor.black.setFill()
            cursor.fill()
            return
        }
        let name = icon == .freehandLasso ? "lasso" : icon == .ellipseMarquee ? "circle.dashed" : "rectangle.dashed"
        let size = NSImage.SymbolConfiguration(pointSize: box.height, weight: .semibold)
        guard let white = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [.white]))),
              let black = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [.black]))) else { return }
        // The symbol keeps its own shape, fitted in the box.
        let scale = min(box.width / black.size.width, box.height / black.size.height)
        let rect = NSRect(x: box.midX - black.size.width * scale / 2, y: box.midY - black.size.height * scale / 2,
                          width: black.size.width * scale, height: black.size.height * scale)
        for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7)] {
            white.draw(in: rect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        black.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    /// A wand whose sparkle is the hot spot, with the same "+" / "−" badges as the other selection tools.
    static let wandCursors: [SelectionMode: NSCursor] = Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { mode in
        let hotSpot = NSPoint(x: 7, y: 7)
        let image = NSImage(size: NSSize(width: 34, height: 34), flipped: true) { _ in
            let stick = NSBezierPath()
            stick.move(to: CGPoint(x: hotSpot.x + 6, y: hotSpot.y + 6))
            stick.line(to: CGPoint(x: hotSpot.x + 20, y: hotSpot.y + 20))
            let marks = NSBezierPath()
            for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
                marks.move(to: CGPoint(x: hotSpot.x + dx * 2.5, y: hotSpot.y + dy * 2.5))
                marks.line(to: CGPoint(x: hotSpot.x + dx * 6, y: hotSpot.y + dy * 6))
            }
            if mode != .replace {
                let center = CGPoint(x: hotSpot.x + 17, y: hotSpot.y + 5)
                marks.move(to: CGPoint(x: center.x - 3, y: center.y))
                marks.line(to: CGPoint(x: center.x + 3, y: center.y))
                if mode == .add {
                    marks.move(to: CGPoint(x: center.x, y: center.y - 3))
                    marks.line(to: CGPoint(x: center.x, y: center.y + 3))
                }
            }
            for path in [stick, marks] { path.lineCapStyle = .round }
            // White outlines first, so neither shape's outline covers the other's black line.
            NSColor.white.setStroke()
            stick.lineWidth = 5
            stick.stroke()
            marks.lineWidth = 3.2
            marks.stroke()
            NSColor.black.setStroke()
            stick.lineWidth = 2.4
            stick.stroke()
            marks.lineWidth = 1.2
            marks.stroke()
            return true
        }
        return (mode, NSCursor(image: image, hotSpot: hotSpot))
    })

    static let rotationCursor: NSCursor = {
        guard case let (white, black)? = outlinedSymbol("arrow.triangle.2.circlepath", description: "Rotate") else { return .crosshair }
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            // Expand the white silhouette, then draw the black symbol on top.
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            black.draw(in: glyph)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    static let eyedropperCursor: NSCursor = {
        guard case let (white, black)? = outlinedSymbol("eyedropper", description: "Sample color") else { return .crosshair }
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            black.draw(in: glyph)
            return true
        }
        // The dropper tip sits at the glyph's bottom-left.
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 21))
    }()

    /// The Zoom tool's cursors: a magnifier with a plus, or a minus while Option is held.
    private static func zoomCursor(out: Bool) -> NSCursor {
        guard case let (white, black)? = outlinedSymbol(out ? "minus.magnifyingglass" : "plus.magnifyingglass",
                                                  description: out ? "Zoom out" : "Zoom in") else { return .crosshair }
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            // The lens filled white, so the cursor reads on any image. Measured from the symbol: its lens sits at
            // 41% across and 40% down the glyph, with an inside radius of about 27% of it.
            let center = CGPoint(x: glyph.minX + glyph.width * 0.41, y: glyph.maxY - glyph.height * 0.40)
            let radius = glyph.width * 0.29
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            black.draw(in: glyph)
            return true
        }
        // The lens's center, toward the top-left of the glyph.
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
    static let zoomInCursor = zoomCursor(out: false)
    static let zoomOutCursor = zoomCursor(out: true)
}
