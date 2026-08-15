//===----------------------------------------------------------------------===//
//  SnapEngine.swift
//  Tessera Studio
//
//  Snap to grid + snap to object + alignment helpers (P1 item 1.17,
//  studio-expansion-plan.md row 1.17). Pure and stateless, matching
//  ShapeZOrder/LayerStore's shape - no store dependency, no receipts.
//  Snapping adjusts a PROPOSED geometry before a gesture commits; the
//  commit itself (TransformController -> DrawingStore.setGeometry) is
//  the receipted event, so this type only ever proposes an {dx, dy}
//  adjustment plus the guide DATA a canvas view would draw - it never
//  mutates a `Shape` or touches `DrawingStore`.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

// MARK: - SnapPoint

/// A world-space point, decoupled from CoreGraphics the way
/// `ShapeGeometry` itself is (Shape.swift: "Plain Double fields
/// throughout... decoupled from the rendering layer's types").
public struct SnapPoint: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - SnapAxis

/// Position snapping resolves x and y independently (a proposed move
/// can snap on one axis without the other) - `dx`/`dy` in
/// `SnapResult` are the two axes' answers, computed separately.
public enum SnapAxis: Sendable, Equatable, Hashable {
    case x
    case y
}

// MARK: - SnapGuide

/// Guide DATA only - describes what a proposed move snapped to. The
/// canvas view is the one that turns this into a drawn line/dot;
/// `SnapEngine` never draws anything itself.
public enum SnapGuide: Sendable, Equatable {
    /// Snapped to a grid line, a page edge/center, or another shape's
    /// edge/center, along `axis`. `position` is the world-space
    /// coordinate landed on (an x for `.x`, a y for `.y`).
    /// `throughPoints` are the two points the guide line runs through -
    /// the dragged shape's own snapped point and the matched target's
    /// corresponding point - so a view can draw the guide's actual
    /// span instead of an unbounded line. `matchedShapeID` is nil for
    /// a page-edge/center match; non-nil names the other shape.
    case alignment(axis: SnapAxis, position: Double, throughPoints: [SnapPoint], matchedShapeID: UUID?)
    /// The dragged shape sits an equal gap from two neighbors along
    /// `axis` (a la Figma/Sketch smart guides); `gapSize` is the
    /// shared gap distance, `between` the two neighbor shape ids.
    case gap(axis: SnapAxis, gapSize: Double, between: [UUID])
    /// Snapped to a grid line along `axis`; `position` is the grid
    /// coordinate landed on.
    case grid(axis: SnapAxis, position: Double)
    /// Rotation snapped to a 15-degree multiple; `degrees` is the
    /// resulting angle (see `SnapEngine.snapRotation`).
    case rotation(degrees: Double)
}

// MARK: - SnapResult

/// `SnapEngine.snap`'s output: the adjustment a caller should add to
/// the proposed geometry's x/y, plus the guides that justify it.
/// `.identity` (0, 0, no guides) is what "nothing within threshold"
/// returns - callers never need to special-case "did it snap".
public struct SnapResult: Sendable, Equatable {
    public var dx: Double
    public var dy: Double
    public var guides: [SnapGuide]

    public init(dx: Double, dy: Double, guides: [SnapGuide]) {
        self.dx = dx
        self.dy = dy
        self.guides = guides
    }

    public static let identity = SnapResult(dx: 0, dy: 0, guides: [])
}

// MARK: - SnapViewport

/// An optional world-space rect `SnapContext.build` prunes candidate
/// shapes against (plus a margin) before the ~256 cap. Only the
/// candidate SHAPES are pruned - the page/grid targets are cheap and
/// always included regardless of viewport.
public struct SnapViewport: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

// MARK: - SnapTarget / SnapNeighbor (internal plumbing)

/// One coordinate a proposed move can land on, on a single axis.
/// `crossCenter` is the source's own center on the OTHER axis - the
/// second point an `.alignment` guide's `throughPoints` needs to draw
/// a real line segment rather than a bare coordinate. `shapeID` is nil
/// for a page edge/center target.
struct SnapTarget: Sendable {
    let value: Double
    let crossCenter: Double
    let shapeID: UUID?
}

/// A candidate shape's rotated-AABB, kept whole (not flattened into
/// `SnapTarget`s) for the gap/equal-spacing tier, which needs both
/// edges of a neighbor on both axes at once.
struct SnapNeighbor: Sendable {
    let id: UUID
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
}

// MARK: - SnapContext

/// Everything `SnapEngine.snap` needs to answer one gesture's worth of
/// moves: the rotated-AABB edges/centers of every visible, unlocked,
/// non-selected shape, plus the page's own edges/center, plus an
/// optional grid spacing. Built ONCE per gesture-begin via ``build``
/// and reused for every move in that gesture - never recomputed per
/// frame, the perf-critical invariant the whole type exists to
/// enforce. `zoomScale` is deliberately NOT stored here: it is cheap
/// to pass at each `snap` call and can legitimately change mid-gesture
/// (pinch-zoom while dragging) without invalidating the expensive
/// AABB work above.
///
/// No public initializer - ``build`` is the only construction path,
/// so "built once per gesture-begin" isn't just a doc comment, it's
/// the only way to get one of these.
public struct SnapContext: Sendable {
    let xTargets: [SnapTarget]
    let yTargets: [SnapTarget]
    let neighbors: [SnapNeighbor]
    let gridSpacing: Double?
    let canvasSize: CanvasSize

    /// - Parameters:
    ///   - shapes: every shape in the drawing; visibility/lock/
    ///     selection filtering happens here, callers pass the raw set.
    ///   - selectedShapeIDs: excluded from candidates - a shape never
    ///     snaps to itself or to the rest of its own multi-selection.
    ///   - layers: resolves each shape's visible/locked state via its
    ///     `layerID`, same lookup `LayerStore` uses. A shape naming a
    ///     layer no longer present bands with the implicit base layer -
    ///     always visible, never locked - matching `LayerStore`'s own
    ///     documented handling of that case.
    ///   - viewport: prunes candidates to those whose rotated-AABB
    ///     intersects `viewport` (expanded by `viewportMargin`). `nil`
    ///     skips pruning entirely - there is no real viewport to prune
    ///     against outside a live canvas - and `maxCandidates` alone
    ///     enforces the cap, as a plain truncation.
    ///   - maxCandidates: the ~256 cap from the design contract.
    public static func build(
        shapes: [Shape],
        selectedShapeIDs: Set<UUID>,
        layers: [DrawLayer],
        canvasSize: CanvasSize,
        gridSpacing: Double? = nil,
        viewport: SnapViewport? = nil,
        viewportMargin: Double = 64,
        maxCandidates: Int = 256
    ) -> SnapContext {
        let layersByID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })

        var candidates = shapes.filter { shape in
            guard !selectedShapeIDs.contains(shape.id) else { return false }
            guard let layerID = shape.layerID, let layer = layersByID[layerID] else {
                return true
            }
            return layer.isVisible && !layer.isLocked
        }

        if let viewport {
            let minX = viewport.minX - viewportMargin
            let minY = viewport.minY - viewportMargin
            let maxX = viewport.maxX + viewportMargin
            let maxY = viewport.maxY + viewportMargin
            candidates = candidates.filter { shape in
                let box = rotatedAABB(of: shape.geometry)
                return box.maxX >= minX && box.minX <= maxX && box.maxY >= minY && box.minY <= maxY
            }
        }

        if candidates.count > maxCandidates {
            candidates = Array(candidates.prefix(maxCandidates))
        }

        var xTargets: [SnapTarget] = [
            SnapTarget(value: 0, crossCenter: canvasSize.height / 2, shapeID: nil),
            SnapTarget(value: canvasSize.width / 2, crossCenter: canvasSize.height / 2, shapeID: nil),
            SnapTarget(value: canvasSize.width, crossCenter: canvasSize.height / 2, shapeID: nil),
        ]
        var yTargets: [SnapTarget] = [
            SnapTarget(value: 0, crossCenter: canvasSize.width / 2, shapeID: nil),
            SnapTarget(value: canvasSize.height / 2, crossCenter: canvasSize.width / 2, shapeID: nil),
            SnapTarget(value: canvasSize.height, crossCenter: canvasSize.width / 2, shapeID: nil),
        ]
        var neighbors: [SnapNeighbor] = []
        neighbors.reserveCapacity(candidates.count)

        for shape in candidates {
            let box = rotatedAABB(of: shape.geometry)
            let centerX = (box.minX + box.maxX) / 2
            let centerY = (box.minY + box.maxY) / 2
            xTargets.append(SnapTarget(value: box.minX, crossCenter: centerY, shapeID: shape.id))
            xTargets.append(SnapTarget(value: centerX, crossCenter: centerY, shapeID: shape.id))
            xTargets.append(SnapTarget(value: box.maxX, crossCenter: centerY, shapeID: shape.id))
            yTargets.append(SnapTarget(value: box.minY, crossCenter: centerX, shapeID: shape.id))
            yTargets.append(SnapTarget(value: centerY, crossCenter: centerX, shapeID: shape.id))
            yTargets.append(SnapTarget(value: box.maxY, crossCenter: centerX, shapeID: shape.id))
            neighbors.append(SnapNeighbor(id: shape.id, minX: box.minX, maxX: box.maxX, minY: box.minY, maxY: box.maxY))
        }

        return SnapContext(
            xTargets: xTargets,
            yTargets: yTargets,
            neighbors: neighbors,
            gridSpacing: gridSpacing,
            canvasSize: canvasSize
        )
    }
}

// MARK: - Rotated-AABB (shared by SnapContext.build and SnapEngine.snap)

/// Axis-aligned bounding box of a rotated shape, in world space.
/// `fileprivate` free function (not nested in either `SnapContext` or
/// `SnapEngine`) so both types can call it without one having to be an
/// extension of the other.
fileprivate struct SnapAABB {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
}

fileprivate func rotatedAABB(of geometry: ShapeGeometry) -> SnapAABB {
    guard geometry.rotation != 0 else {
        return SnapAABB(minX: geometry.x, maxX: geometry.x + geometry.width, minY: geometry.y, maxY: geometry.y + geometry.height)
    }

    let pivotX = geometry.x + Double(geometry.anchorPoint.x)
    let pivotY = geometry.y + Double(geometry.anchorPoint.y)
    let radians = geometry.rotation * Double.pi / 180
    let cosA = cos(radians)
    let sinA = sin(radians)

    let corners = [
        (geometry.x, geometry.y),
        (geometry.x + geometry.width, geometry.y),
        (geometry.x + geometry.width, geometry.y + geometry.height),
        (geometry.x, geometry.y + geometry.height),
    ]

    var minX = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude

    for (x, y) in corners {
        let dx = x - pivotX
        let dy = y - pivotY
        // Matches CGAffineTransform(rotationAngle:)'s convention, the
        // same one ShapeRenderer.applyRotation hands to
        // CGContext.rotate(by:) - so this AABB agrees with what
        // actually paints on screen for the same `rotation` value.
        let rx = dx * cosA - dy * sinA + pivotX
        let ry = dx * sinA + dy * cosA + pivotY
        minX = min(minX, rx)
        maxX = max(maxX, rx)
        minY = min(minY, ry)
        maxY = max(maxY, ry)
    }

    return SnapAABB(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
}

// MARK: - SnapEngine

public enum SnapEngine {

    // MARK: Position snap

    /// Threshold-8 screen pixels, converted to world space via
    /// `zoomScale` - the tldraw-evidenced screen-space-constant model,
    /// so the same finger/pointer precision snaps regardless of zoom
    /// level. Grid, page, and object edge/center snap are evaluated
    /// together as one tier (nearest candidate under threshold wins,
    /// per axis, independent of which of the three produced it);
    /// gap/equal-spacing guides are a second, lower-priority tier,
    /// only computed for an axis the first tier left unresolved.
    ///
    /// `proposedGeometry` is the dragged shape's own candidate
    /// geometry for this move (already offset by the raw drag delta,
    /// before any snap adjustment). The dragged shape does not need to
    /// be excluded here - `SnapContext.build`'s `selectedShapeIDs`
    /// filter already kept it out of `context`'s targets/neighbors.
    public static func snap(context: SnapContext, proposedGeometry: ShapeGeometry, zoomScale: Double) -> SnapResult {
        // Guards a degenerate (zero or negative) zoom from producing an
        // infinite or negative threshold.
        let threshold = 8.0 / max(zoomScale, 0.0001)
        let box = rotatedAABB(of: proposedGeometry)
        let centerX = (box.minX + box.maxX) / 2
        let centerY = (box.minY + box.maxY) / 2

        let xResolved = resolveAxis(
            axis: .x,
            draggedValues: [box.minX, centerX, box.maxX],
            draggedCrossCenter: centerY,
            targets: context.xTargets,
            gridSpacing: context.gridSpacing,
            threshold: threshold
        )
        let yResolved = resolveAxis(
            axis: .y,
            draggedValues: [box.minY, centerY, box.maxY],
            draggedCrossCenter: centerX,
            targets: context.yTargets,
            gridSpacing: context.gridSpacing,
            threshold: threshold
        )

        var dx = xResolved.delta
        var dy = yResolved.delta
        var guides: [SnapGuide] = [xResolved.guide, yResolved.guide].compactMap { $0 }

        if xResolved.guide == nil,
           let gap = resolveGap(
               axis: .x,
               draggedMin: box.minX, draggedMax: box.maxX,
               draggedCrossMin: box.minY, draggedCrossMax: box.maxY,
               neighbors: context.neighbors,
               threshold: threshold
           ) {
            dx = gap.delta
            guides.append(.gap(axis: .x, gapSize: gap.gapSize, between: [gap.leftID, gap.rightID]))
        }

        if yResolved.guide == nil,
           let gap = resolveGap(
               axis: .y,
               draggedMin: box.minY, draggedMax: box.maxY,
               draggedCrossMin: box.minX, draggedCrossMax: box.maxX,
               neighbors: context.neighbors,
               threshold: threshold
           ) {
            dy = gap.delta
            guides.append(.gap(axis: .y, gapSize: gap.gapSize, between: [gap.leftID, gap.rightID]))
        }

        return SnapResult(dx: dx, dy: dy, guides: guides)
    }

    /// Tier 1: grid + page + object edge/center, considered together
    /// - nearest candidate under `threshold` wins, across all three of
    /// the dragged shape's own edge/center points on this axis.
    /// Returns `(0, nil)` (identity) when nothing is within threshold.
    private static func resolveAxis(
        axis: SnapAxis,
        draggedValues: [Double],
        draggedCrossCenter: Double,
        targets: [SnapTarget],
        gridSpacing: Double?,
        threshold: Double
    ) -> (delta: Double, guide: SnapGuide?) {
        var bestDelta = 0.0
        var bestGuide: SnapGuide?
        var bestMagnitude = Double.infinity

        for dragged in draggedValues {
            for target in targets {
                let delta = target.value - dragged
                let magnitude = abs(delta)
                guard magnitude <= threshold, magnitude < bestMagnitude else { continue }
                bestMagnitude = magnitude
                bestDelta = delta
                let snappedPoint = point(axis: axis, position: target.value, cross: draggedCrossCenter)
                let targetPoint = point(axis: axis, position: target.value, cross: target.crossCenter)
                bestGuide = .alignment(axis: axis, position: target.value, throughPoints: [snappedPoint, targetPoint], matchedShapeID: target.shapeID)
            }

            if let spacing = gridSpacing, spacing > 0 {
                let gridValue = (dragged / spacing).rounded() * spacing
                let delta = gridValue - dragged
                let magnitude = abs(delta)
                if magnitude <= threshold, magnitude < bestMagnitude {
                    bestMagnitude = magnitude
                    bestDelta = delta
                    bestGuide = .grid(axis: axis, position: gridValue)
                }
            }
        }

        return bestGuide == nil ? (0, nil) : (bestDelta, bestGuide)
    }

    private static func point(axis: SnapAxis, position: Double, cross: Double) -> SnapPoint {
        switch axis {
        case .x: return SnapPoint(x: position, y: cross)
        case .y: return SnapPoint(x: cross, y: position)
        }
    }

    /// Tier 2: does the dragged shape sit between two neighbors (one
    /// on each side, on `draggedMin`/`draggedMax`'s axis, overlapping
    /// the dragged shape on the cross axis - the same "same row/
    /// column" restriction every smart-guide implementation applies)
    /// with near-equal gaps? Returns the delta that makes the two gaps
    /// EXACTLY equal, only when that delta is itself within
    /// `threshold` - mirrors tier 1's "the required adjustment must be
    /// small" semantics rather than bounding the gap mismatch instead.
    private static func resolveGap(
        axis: SnapAxis,
        draggedMin: Double,
        draggedMax: Double,
        draggedCrossMin: Double,
        draggedCrossMax: Double,
        neighbors: [SnapNeighbor],
        threshold: Double
    ) -> (delta: Double, gapSize: Double, leftID: UUID, rightID: UUID)? {
        // A neighbor's own extent on this axis, and on the cross axis -
        // local, not a stored property, since which of a SnapNeighbor's
        // four coordinates plays which role depends on `axis`.
        func primary(_ n: SnapNeighbor) -> (min: Double, max: Double) {
            axis == .x ? (n.minX, n.maxX) : (n.minY, n.maxY)
        }
        func cross(_ n: SnapNeighbor) -> (min: Double, max: Double) {
            axis == .x ? (n.minY, n.maxY) : (n.minX, n.maxX)
        }

        let overlapping = neighbors.filter { n in
            let c = cross(n)
            return c.max >= draggedCrossMin && c.min <= draggedCrossMax
        }
        let left = overlapping.filter { primary($0).max <= draggedMin }
        let right = overlapping.filter { primary($0).min >= draggedMax }
        guard !left.isEmpty, !right.isEmpty else { return nil }

        var best: (delta: Double, gapSize: Double, leftID: UUID, rightID: UUID, magnitude: Double)?
        for l in left {
            let gapLeft = draggedMin - primary(l).max
            for r in right {
                let gapRight = primary(r).min - draggedMax
                let delta = (gapRight - gapLeft) / 2
                let magnitude = abs(delta)
                guard magnitude <= threshold else { continue }
                if best == nil || magnitude < best!.magnitude {
                    best = (delta, (gapLeft + gapRight) / 2, l.id, r.id, magnitude)
                }
            }
        }

        guard let result = best else { return nil }
        return (result.delta, result.gapSize, result.leftID, result.rightID)
    }

    // MARK: Rotation snap

    /// The dragged shape's rotation snapped to the nearest 15-degree
    /// multiple, plus a guide when it did. Outside threshold, `degrees`
    /// comes back unchanged (this axis's identity) and `guide` is nil.
    public struct RotationSnapResult: Sendable, Equatable {
        public var degrees: Double
        public var guide: SnapGuide?

        public init(degrees: Double, guide: SnapGuide?) {
            self.degrees = degrees
            self.guide = guide
        }
    }

    /// The linear `8.0 / zoomScale` threshold is a screen-space
    /// DISTANCE; rotation has no distance of its own to compare it
    /// against, so the linear formula does not apply as-is. Converting
    /// it requires a length scale, and the only honest one available
    /// is the rotation gesture's own arm: `handleDistance` is the
    /// world-space distance from the rotation pivot to the point being
    /// dragged (TransformController's rotation handle, mid-gesture).
    /// At that radius, an angular error of `theta` sweeps a screen-
    /// space arc of approximately `handleDistance * theta`, the exact
    /// quantity the linear threshold already bounds - so solving
    /// `handleDistance * theta = linearThreshold` for `theta` via
    /// `atan` (not the small-angle `linearThreshold / handleDistance`,
    /// so the result stays a sane angle instead of diverging as
    /// `handleDistance` shrinks toward the pivot) gives the angular
    /// threshold in radians.
    public static func snapRotation(_ degrees: Double, handleDistance: Double, zoomScale: Double) -> RotationSnapResult {
        let linearThreshold = 8.0 / max(zoomScale, 0.0001)
        let angularThresholdDegrees = atan(linearThreshold / max(handleDistance, 0.0001)) * 180 / .pi

        let nearest = (degrees / 15.0).rounded() * 15.0
        let delta = nearest - degrees
        guard abs(delta) <= angularThresholdDegrees else {
            return RotationSnapResult(degrees: degrees, guide: nil)
        }
        return RotationSnapResult(degrees: nearest, guide: .rotation(degrees: nearest))
    }
}
