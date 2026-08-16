//===----------------------------------------------------------------------===//
//  ShapeMorphEngine.swift
//  Tessera Studio
//
//  Item 2.18 (Draw morph, ratified minimal design: id-matched
//  interpolation - AGENTS.md's "Tessera Studio product-surface
//  expansion" section, decision 11). Given two `Shape` VALUES sharing
//  the same `Shape.id` (two keyframes of "the same shape" - on two
//  slides, or two points on an authored transition - `Shape.id`
//  equality is confirmed the only identity concept this codebase has;
//  no separate "morph key" type), produce the shape interpolated to
//  `progress`.
//
//  PURE, like `TransformController`/`SnapEngine`/`BezierPathController`
//  in this same directory: no `DrawingStore`, no receipt, ever - a
//  morph is a RENDER-TIME interpolation for a transition/animation
//  PREVIEW, never a stored mutation of any shape (this item's own
//  ratified scope). A caller feeds `interpolate(from:to:progress:)`
//  the two keyframe shapes plus the current transition progress on
//  every frame; nothing here is called from `DrawingStore`.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

// MARK: - ShapeMorphEngine

public enum ShapeMorphEngine {

    // MARK: - MorphError

    public enum MorphError: Error, Equatable, Sendable {
        /// `from.id != to.id` - a caller bug, not a legitimate runtime
        /// race (unlike, say, `BezierPathController`'s "a command
        /// references an index the path no longer has," which degrades
        /// silently because it can legitimately happen mid-gesture).
        /// "id-matched interpolation" IS the ratified design; two
        /// keyframes that do not share an identity are not a
        /// degradable edge case of that design, they are a violation
        /// of its own precondition - THROWN rather than silently
        /// degraded so the bug surfaces immediately instead of
        /// quietly rendering a nonsense cross-fade between two
        /// unrelated shapes. See this wave's findings file for the
        /// full reasoning (both options were explicitly open per this
        /// item's own test-contract wording).
        case idMismatch(from: UUID, to: UUID)
    }

    // MARK: - interpolate

    /// The interpolated `Shape` at `progress` (clamped to `0...1`)
    /// between `from` (progress 0) and `to` (progress 1). Throws
    /// `MorphError.idMismatch` when `from.id != to.id`.
    ///
    /// GEOMETRY (`ShapeGeometry`) is always linearly interpolated -
    /// "geometry lerp is straightforward" per this item's own
    /// contract - see `interpolatedGeometry` below for the one
    /// deliberate exception (`flipH`/`flipV`, which are discrete).
    ///
    /// PATH (`.bezier` shapes' `Shape.path`) is interpolated subpath-
    /// by-subpath, segment-by-segment BY INDEX only when `from.path`
    /// and `to.path` both exist and have the identical subpath count
    /// AND, per subpath, the identical segment count AND per-segment
    /// CASE (both `.line`, both `.cubic`, etc. - a `.line` cannot
    /// meaningfully lerp against a `.cubic`'s extra control points);
    /// any mismatch degrades the RESULT'S path to `nil` (a plain
    /// geometry-only lerp, no path interpolation - this item's own
    /// documented fallback), which `ShapeRenderer`'s existing `.bezier`
    /// case already renders as the honest bounding-rect placeholder it
    /// uses for any other nil `path`, matching every other "malformed
    /// data degrades" convention in this directory.
    ///
    /// EVERY OTHER FIELD (`kind`, `fill`, `stroke`, `text`,
    /// `connector`, `extrusion`, `table`, `calloutAnchor`,
    /// `dimensionInfo`, `zIndex`, `parentGroupID`, `layerID`) is
    /// discrete - there is no meaningful "halfway between a rect and
    /// an ellipse" - so the whole `Shape` value starts as a copy of
    /// whichever keyframe `progress` is nearer to (`from` for
    /// `progress < 0.5`, `to` otherwise, a single threshold cross-fade
    /// covering every discrete field at once instead of hand-listing
    /// each one), with `geometry` and `path` then overridden by the
    /// real interpolation above.
    public static func interpolate(from: Shape, to: Shape, progress: Double) throws -> Shape {
        guard from.id == to.id else {
            throw MorphError.idMismatch(from: from.id, to: to.id)
        }
        let p = min(max(progress, 0), 1)
        var result = p < 0.5 ? from : to
        result.geometry = interpolatedGeometry(from.geometry, to.geometry, p)
        result.path = interpolatedPath(from.path, to.path, p)
        return result
    }

    // MARK: - Geometry lerp

    static func interpolatedGeometry(_ a: ShapeGeometry, _ b: ShapeGeometry, _ p: Double) -> ShapeGeometry {
        var anchorX: Double?
        var anchorY: Double?
        // Both nil (the "default center" pivot) needs no explicit
        // interpolated value: linearity means the interpolated
        // width/height's own default center already equals the lerp
        // of each keyframe's own default center, exactly (see this
        // function's own header note in ShapeMorphEngine's file
        // comment / findings file for the proof). Only resolve and
        // lerp an explicit value when at least one keyframe actually
        // set one.
        if a.anchorX != nil || a.anchorY != nil || b.anchorX != nil || b.anchorY != nil {
            let pa = a.anchorPoint, pb = b.anchorPoint
            anchorX = lerp(Double(pa.x), Double(pb.x), p)
            anchorY = lerp(Double(pa.y), Double(pb.y), p)
        }
        return ShapeGeometry(
            x: lerp(a.x, b.x, p),
            y: lerp(a.y, b.y, p),
            width: lerp(a.width, b.width, p),
            height: lerp(a.height, b.height, p),
            rotation: lerp(a.rotation, b.rotation, p),
            anchorX: anchorX,
            anchorY: anchorY,
            // Discrete, like every other non-geometry field - crossed
            // over at the same p < 0.5 threshold `interpolate(from:
            // to:progress:)` uses for the rest of the shape, so a
            // shape's flip state changes at the same instant every
            // other discrete field does.
            flipH: p < 0.5 ? a.flipH : b.flipH,
            flipV: p < 0.5 ? a.flipV : b.flipV
        )
    }

    private static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double {
        a + (b - a) * p
    }

    // MARK: - Path lerp

    /// `nil` (geometry-only degrade) when either path is missing, the
    /// subpath counts differ, or any corresponding subpath pair's
    /// segment counts or per-segment shape differ. Otherwise the
    /// index-matched interpolation described on `interpolate(from:
    /// to:progress:)`.
    static func interpolatedPath(_ a: ShapePath?, _ b: ShapePath?, _ p: Double) -> ShapePath? {
        guard let a, let b, a.subpaths.count == b.subpaths.count else { return nil }
        var subpaths: [ShapeSubpath] = []
        subpaths.reserveCapacity(a.subpaths.count)
        for (subA, subB) in zip(a.subpaths, b.subpaths) {
            guard subA.segments.count == subB.segments.count else { return nil }
            var segments: [ShapePathSegment] = []
            segments.reserveCapacity(subA.segments.count)
            for (segA, segB) in zip(subA.segments, subB.segments) {
                guard let segment = interpolatedSegment(segA, segB, p) else { return nil }
                segments.append(segment)
            }
            subpaths.append(ShapeSubpath(segments: segments, closed: p < 0.5 ? subA.closed : subB.closed))
        }
        return ShapePath(subpaths: subpaths)
    }

    /// `nil` when `a`/`b` are different `ShapePathSegment` cases (a
    /// `.line` cannot lerp against a `.quad`/`.cubic`'s extra control
    /// points without inventing control points that were never
    /// authored) - the signal `interpolatedPath` uses to degrade the
    /// WHOLE path to `nil`, not just this one segment.
    private static func interpolatedSegment(_ a: ShapePathSegment, _ b: ShapePathSegment, _ p: Double) -> ShapePathSegment? {
        switch (a, b) {
        case (.move(let pa), .move(let pb)):
            return .move(lerpPoint(pa, pb, p))
        case (.line(let pa), .line(let pb)):
            return .line(lerpPoint(pa, pb, p))
        case (.quad(let ca, let ea), .quad(let cb, let eb)):
            return .quad(control: lerpPoint(ca, cb, p), end: lerpPoint(ea, eb, p))
        case (.cubic(let c1a, let c2a, let ea), .cubic(let c1b, let c2b, let eb)):
            return .cubic(control1: lerpPoint(c1a, c1b, p), control2: lerpPoint(c2a, c2b, p), end: lerpPoint(ea, eb, p))
        default:
            return nil
        }
    }

    private static func lerpPoint(_ a: ShapePathPoint, _ b: ShapePathPoint, _ p: Double) -> ShapePathPoint {
        ShapePathPoint(x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p))
    }
}
