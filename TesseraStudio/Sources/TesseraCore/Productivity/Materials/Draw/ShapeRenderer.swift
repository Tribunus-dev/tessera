//===----------------------------------------------------------------------===//
//  ShapeRenderer.swift
//  Tessera Studio
//
//  Pure function Shape -> CGContext drawing commands - peer of
//  BlockRenderer the way Shape is a peer of Block. CoreGraphics, not
//  Swift Charts or SwiftUI.Canvas-only drawing, per the architect's
//  chart-engine decision extended to the rest of the vector-drawing
//  surface: CGContext is the one drawing substrate every rendering
//  target (an on-screen SwiftUI.Canvas, an offscreen CGImage for
//  export, a PDF context) already knows how to consume.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics
import CoreText

// MARK: - ShapeRenderer

/// Stateless and side-effect-free, matching `BlockRenderer`: every
/// shape renders independently of every other, so a canvas redraw can
/// touch just the shapes that changed.
public struct ShapeRenderer: Sendable {

    /// Draws `shape.text` (when present) via the same
    /// `NSAttributedString` -> `CTFramesetter` stack `SlideDeckRenderer`
    /// uses for placeholder text - "one text stack, ever."
    private let blockRenderer: BlockRenderer

    public init() {
        self.blockRenderer = BlockRenderer()
    }

    /// Render one shape's fill, stroke, and text into `context`. The
    /// context's current transform is saved and restored, so callers
    /// can render a whole z-ordered list in a loop without resetting
    /// state between shapes themselves.
    ///
    /// `allShapes` is only consulted for a `.connector` shape whose
    /// `connector` has an `.attached` endpoint - `ConnectorRouter`
    /// looks up that endpoint's glue point from this list. Every other
    /// kind ignores it, and it defaults to `[]` so existing call sites
    /// that render non-connector shapes are unaffected.
    public func render(_ shape: Shape, in context: CGContext, allShapes: [Shape] = []) {
        context.saveGState()
        defer { context.restoreGState() }

        applyFlip(shape.geometry, in: context)
        applyRotation(shape.geometry, in: context)

        let path = path(for: shape, allShapes: allShapes)

        if let fill = shape.fill, kindIsFillable(shape.kind) {
            context.setFillColor(resolveColor(hex(for: fill.colorHex), opacity: fill.opacity))
            context.addPath(path)
            context.fillPath()
        }

        if let stroke = shape.stroke {
            context.setStrokeColor(resolveColor(stroke.colorHex, opacity: 1))
            context.setLineWidth(CGFloat(stroke.width))
            if !stroke.dashPattern.isEmpty {
                context.setLineDash(phase: 0, lengths: stroke.dashPattern.map { CGFloat($0) })
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.addPath(path)
            context.strokePath()
        }

        if shape.kind == .arrow, let stroke = shape.stroke {
            drawArrowhead(shape.geometry, colorHex: stroke.colorHex, in: context)
        }

        if let text = shape.text {
            renderShapeText(text, in: shape.geometry.frame, context: context)
        }
    }

    /// Whether a fill is meaningful for this kind. A line, arrow, or
    /// connector has no interior - filling it would silently do
    /// nothing useful, so callers that set `fill` on one anyway (a
    /// data error, not a crash) simply see it ignored rather than
    /// drawing a degenerate zero-area fill.
    ///
    /// `.bezier` DELIBERATELY stays fillable at the KIND level
    /// regardless of any individual subpath's own `closed` flag (item
    /// 2.3's own review point - reconsidered here, not changed): SVG's
    /// painting model fills an OPEN subpath by treating it as implicitly
    /// closed FOR THE FILL COMPUTATION ONLY, never for stroking -
    /// exactly what `context.fillPath()` already does to any open
    /// subpath in the `CGPath` `bezierPath(_:origin:)` below builds
    /// (CoreGraphics' fill operator auto-closes every subpath, the same
    /// PDF/PostScript imaging-model convention SVG's own spec follows),
    /// while `context.strokePath()` correctly does NOT draw that
    /// implicit closing edge, since `bezierPath` only calls
    /// `.closeSubpath()` when `subpath.closed` is actually `true`. So
    /// the SVG/ODF-correct "open subpaths still fill, but don't grow a
    /// phantom stroke edge" behavior falls out of the existing
    /// fill/stroke split for free - per-subpath openness need not (and
    /// should not) gate fillability at the whole-shape level the way
    /// `kindIsFillable` operates.
    private func kindIsFillable(_ kind: ShapeKind) -> Bool {
        switch kind {
        case .line, .arrow, .connector: return false
        case .rect, .ellipse, .polygon, .star, .freeform, .bezier: return true
        }
    }

    // MARK: - Shape text

    /// Draws `text` inside `rect` via `CTFramesetter` - mirrors
    /// `SlideDeckRenderer.drawAttributedString`'s exact technique
    /// (CoreText's glyph space is y-up; `context` is y-down, so the
    /// flip is scoped to `rect` via a save/restore pair rather than
    /// touching the context's persistent state). `ShapeText.runs` go
    /// through a transient `.paragraph` `Block` so the SAME
    /// `BlockRenderer` -> attributed-string pipeline every other block
    /// type uses produces the text, rather than a shape-text-specific
    /// second stack.
    private func renderShapeText(_ text: ShapeText, in rect: CGRect, context: CGContext) {
        guard !text.plainText.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let block = Block(type: .paragraph, content: text.runs)
        let attributed = blockRenderer.render(block, in: .document)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func applyRotation(_ geometry: ShapeGeometry, in context: CGContext) {
        guard geometry.rotation != 0 else { return }
        let pivot = CGPoint(x: geometry.x + geometry.anchorPoint.x, y: geometry.y + geometry.anchorPoint.y)
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: CGFloat(geometry.rotation) * .pi / 180)
        context.translateBy(x: -pivot.x, y: -pivot.y)
    }

    /// Mirrors the shape around its own frame CENTER, not
    /// `anchorPoint` (the rotation pivot - a different point in
    /// general). Runs before `applyRotation` at the call site so the
    /// two CTM pushes compose as flip-then-rotate, matching OOXML
    /// `a:xfrm`'s order per `ShapeGeometry.flipH`/`flipV`'s doc
    /// comment.
    private func applyFlip(_ geometry: ShapeGeometry, in context: CGContext) {
        guard geometry.flipH || geometry.flipV else { return }
        let center = CGPoint(x: geometry.x + geometry.width / 2, y: geometry.y + geometry.height / 2)
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: geometry.flipH ? -1 : 1, y: geometry.flipV ? -1 : 1)
        context.translateBy(x: -center.x, y: -center.y)
    }

    // Explicit deviceRGB, not the CGColor(red:green:blue:alpha:)
    // convenience initializer: that initializer builds the color in a
    // different implicit color space (sRGB), so filling a deviceRGB
    // bitmap context (what an offscreen render target actually is)
    // silently color-matches/shifts the hex value instead of passing
    // its bytes through untouched - a hex color's R/G/B channels are
    // not fixed points of that conversion in general, so this is not
    // just a gray/white-point rounding difference. See
    // SlideDeckRenderer.parseHex's identical fix and comment.
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    /// No `Theme` reaches this pure `Shape` renderer (nothing about
    /// `render(_:in:allShapes:)`'s signature threads one through) - a
    /// `.theme` ref falls back to `Theme.builtinDefault(for:)`, the
    /// same neutral default `SlideDeckRenderer.drawBackground` uses
    /// with no active theme.
    private func hex(for ref: ColorRef) -> String {
        switch ref {
        case .literal(let hex): return hex
        case .theme(let slot, _): return Theme.builtinDefault(for: slot)
        }
    }

    private func resolveColor(_ hex: String, opacity: Double) -> CGColor {
        guard let rgba = Self.parseHex(hex) else {
            return CGColor(colorSpace: Self.deviceRGB, components: [0, 0, 0, CGFloat(opacity)])!
        }
        return CGColor(
            colorSpace: Self.deviceRGB,
            components: [rgba.r, rgba.g, rgba.b, rgba.a * CGFloat(opacity)]
        )!
    }

    /// `#RRGGBB` or `#RRGGBBAA`, matching `SheetCellFormat`'s hex
    /// convention. A small local parser rather than importing the
    /// AppKit/UIKit-only `Color(hex:)` extension (`ColorHex.swift`) -
    /// this renderer works directly in `CGColor`, one layer below
    /// `SwiftUI.Color`, and stays platform-agnostic by not depending on
    /// either UI framework.
    private static func parseHex(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        guard let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return (
                CGFloat((value >> 16) & 0xFF) / 255,
                CGFloat((value >> 8) & 0xFF) / 255,
                CGFloat(value & 0xFF) / 255,
                1
            )
        }
        return (
            CGFloat((value >> 24) & 0xFF) / 255,
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }

    // MARK: - Paths

    /// Widened from `private` to module-internal (P2-B item 2.17,
    /// ShapeExtrusionRenderer) so the SceneKit extrusion renderer can
    /// build an `SCNShape` from the SAME 2D outline this renderer draws,
    /// instead of duplicating the per-`ShapeKind` path construction - the
    /// design contract's own instruction ("reuse ShapeRenderer's existing
    /// path(for:) construction, don't duplicate it"). No behavior change;
    /// still file-private to `render(_:in:allShapes:)`'s own call site in
    /// spirit, just reachable from elsewhere in `TesseraCore`.
    func path(for shape: Shape, allShapes: [Shape] = []) -> CGPath {
        switch shape.kind {
        case .rect:      return rectPath(shape.geometry)
        case .ellipse:   return CGPath(ellipseIn: shape.geometry.frame, transform: nil)
        case .line:      return linePath(shape.geometry)
        case .arrow:     return linePath(shape.geometry)
        case .polygon:   return polygonPath(shape.geometry, sides: 5)
        case .star:      return starPath(shape.geometry, points: 5, innerRatio: 0.45)
        case .freeform:
            // No stored path-point data yet (P2's BezierPathController
            // owns custom-geometry authoring); the bounding rect is the
            // honest P0 placeholder rather than pretending a real
            // freeform outline exists.
            return rectPath(shape.geometry)
        case .bezier:
            // Item 2.3's own render path. `shape.path` is nil only for
            // malformed data (a `.bezier` shape that was never actually
            // given geometry) - the bounding rect is the same honest
            // placeholder `.freeform` uses above, not a crash.
            guard let shapePath = shape.path else { return rectPath(shape.geometry) }
            return bezierPath(shapePath, origin: CGPoint(x: shape.geometry.x, y: shape.geometry.y))
        case .connector:
            return connectorPath(shape, allShapes: allShapes)
        }
    }

    /// Builds the real `CGPath` for a `.bezier` shape by walking
    /// `shapePath.subpaths`' segments.
    ///
    /// COORDINATE SPACE (a design call this item's own contract left
    /// open - recorded here and in the P2-B findings file for architect
    /// ratification): `ShapePath`'s points are the shape's own LOCAL
    /// coordinates (0...`geometry.width`, 0...`geometry.height`) -
    /// matching `ShapeGeometry.anchorPoint`'s own documented convention
    /// ("in the shape's own UNROTATED local coordinates... not canvas
    /// coordinates"), which `ShapePath.swift`'s header comment
    /// explicitly cross-references. `origin` (the shape's `geometry.x`/
    /// `.y`) is added back here, exactly the way `regularStarPath`/
    /// `polygonPath` above compute `center = g.x + g.width / 2` rather
    /// than drawing at a local (width/2, height/2) origin - NEITHER
    /// `render(_:in:allShapes:)` nor any sibling `*Path` function in
    /// this file establishes a "shape-local" CTM translate, so every
    /// path this type hands to `context.addPath` must already be in the
    /// same canvas-absolute, unrotated space `g.frame` itself is; local
    /// `ShapePath` points otherwise would silently render at the wrong
    /// canvas position. This also matches ODF/SVG's own `draw:path`
    /// convention directly (`svg:d`'s coordinates are relative to the
    /// element's own `svg:viewBox`, not the page) - see
    /// `ODGBridgeFilter`'s `.bezier` export/import, which passes
    /// `shape.path`'s points straight through with no offset for
    /// exactly this reason.
    private func bezierPath(_ shapePath: ShapePath, origin: CGPoint) -> CGPath {
        let mutablePath = CGMutablePath()
        func point(_ p: ShapePathPoint) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(p.x), y: origin.y + CGFloat(p.y))
        }
        for subpath in shapePath.subpaths {
            guard !subpath.segments.isEmpty else { continue }
            for (index, segment) in subpath.segments.enumerated() {
                switch segment {
                case .move(let p):
                    mutablePath.move(to: point(p))
                case .line(let p):
                    // A `.line`/`.quad`/`.cubic` at index 0 (malformed -
                    // `ShapePathSegment`'s own doc comment says a
                    // subpath's first segment "may only legally" be
                    // `.move`) degrades to an implicit move to that
                    // segment's own endpoint, so one malformed subpath
                    // never corrupts every subpath after it in the same
                    // `CGMutablePath`.
                    if index == 0 { mutablePath.move(to: point(p)) } else { mutablePath.addLine(to: point(p)) }
                case .quad(let control, let end):
                    if index == 0 {
                        mutablePath.move(to: point(end))
                    } else {
                        mutablePath.addQuadCurve(to: point(end), control: point(control))
                    }
                case .cubic(let control1, let control2, let end):
                    if index == 0 {
                        mutablePath.move(to: point(end))
                    } else {
                        mutablePath.addCurve(to: point(end), control1: point(control1), control2: point(control2))
                    }
                }
            }
            if subpath.closed { mutablePath.closeSubpath() }
        }
        return mutablePath
    }

    /// Resolved via `ConnectorRouter`, using `allShapes` to look up any
    /// `.attached` endpoint's glue point - NOT `shape.geometry`, which
    /// a connector does not use as its path's source of truth (see
    /// `Shape.connector`'s doc comment). A missing `shape.connector`,
    /// or an endpoint whose attached shape isn't in `allShapes`,
    /// degrades to an empty path rather than crashing - the same
    /// "malformed data doesn't crash the renderer" contract
    /// `kindIsFillable`'s doc comment describes for a stray fill on a
    /// line/arrow.
    private func connectorPath(_ shape: Shape, allShapes: [Shape]) -> CGPath {
        guard let info = shape.connector else { return CGMutablePath() }
        var byID: [UUID: Shape] = Dictionary(minimumCapacity: allShapes.count)
        for s in allShapes { byID[s.id] = s }
        return ConnectorRouter.route(info, shapes: byID) ?? CGMutablePath()
    }

    private func rectPath(_ g: ShapeGeometry) -> CGPath {
        CGPath(rect: g.frame, transform: nil)
    }

    private func linePath(_ g: ShapeGeometry) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: g.x, y: g.y + g.height / 2))
        path.addLine(to: CGPoint(x: g.x + g.width, y: g.y + g.height / 2))
        return path
    }

    /// A regular N-gon inscribed in `g.frame`, first vertex at the top
    /// (12 o'clock) - the conventional orientation for "insert a
    /// polygon" in every mainstream drawing tool.
    private func polygonPath(_ g: ShapeGeometry, sides: Int) -> CGPath {
        regularStarPath(g, points: sides, innerRatio: 1)
    }

    private func starPath(_ g: ShapeGeometry, points: Int, innerRatio: Double) -> CGPath {
        regularStarPath(g, points: points, innerRatio: innerRatio)
    }

    /// Shared vertex math for both the plain N-gon (`innerRatio == 1`,
    /// every vertex on the outer radius) and the star (`innerRatio <
    /// 1`, alternating outer/inner vertices).
    private func regularStarPath(_ g: ShapeGeometry, points: Int, innerRatio: Double) -> CGPath {
        let path = CGMutablePath()
        guard points >= 3 else { return path }
        let center = CGPoint(x: g.x + g.width / 2, y: g.y + g.height / 2)
        let outerR = min(g.width, g.height) / 2
        let innerR = outerR * innerRatio
        let vertexCount = innerRatio < 1 ? points * 2 : points
        let angleStep = (2 * Double.pi) / Double(vertexCount)

        for i in 0..<vertexCount {
            let r = (innerRatio < 1 && i % 2 == 1) ? innerR : outerR
            // -pi/2 so the first vertex points straight up.
            let angle = angleStep * Double(i) - .pi / 2
            let point = CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A simple filled-triangle arrowhead at the line's end point,
    /// oriented along the line's own direction - correct for a
    /// rotated arrow too, since `render(_:in:)` has already applied
    /// the geometry's rotation to the context before this runs.
    private func drawArrowhead(_ g: ShapeGeometry, colorHex: String, in context: CGContext) {
        let tip = CGPoint(x: g.x + g.width, y: g.y + g.height / 2)
        let headLength: CGFloat = min(CGFloat(g.width) * 0.2, 12)
        let headWidth: CGFloat = headLength * 0.8

        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - headLength, y: tip.y - headWidth / 2))
        path.addLine(to: CGPoint(x: tip.x - headLength, y: tip.y + headWidth / 2))
        path.closeSubpath()

        context.setFillColor(resolveColor(colorHex, opacity: 1))
        context.addPath(path)
        context.fillPath()
    }
}
