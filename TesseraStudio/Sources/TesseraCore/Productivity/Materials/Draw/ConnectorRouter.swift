//===----------------------------------------------------------------------===//
//  ConnectorRouter.swift
//  Tessera Studio
//
//  Pure Shape(.connector) -> CGPath routing (P1 item 1.19, design-
//  refinement doc section 4). Deliberately the seam the contract names:
//  today this is a deterministic escape-stub + Manhattan-elbow router
//  (office-suite behavior - LibreOffice Impress / PowerPoint's own
//  connector routing, not general obstacle avoidance), detouring
//  around only the two attached shapes. A P2 libavoid-class global
//  router replaces this file's `route(_:shapes:)` body without
//  touching `ConnectorInfo`, `Shape.connector`, or any caller - every
//  other type in this cluster is untouched by that future swap.
//
//  Routing is DERIVED AT RENDER TIME, never stored: a connector's
//  visible path always reflects its attached shapes' CURRENT frames,
//  so moving either attached shape re-routes for free, with nothing
//  to keep in sync.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

// MARK: - ConnectorRouter

public enum ConnectorRouter {

    // MARK: - Glue points

    /// The 4 default glue points on `shape`'s frame, compass-indexed
    /// 0=top, 1=right, 2=bottom, 3=left (clockwise from top) - the
    /// order `ConnectorEndpoint.attached(_:gluePointIndex:)` indexes
    /// into, chosen so `(shapeID, gluePointIndex)` maps 1:1 onto OOXML
    /// `stCxn`/`endCxn` `idx` and ODF glue-point ids per this item's
    /// design contract.
    ///
    /// Computed from `shape.geometry.frame`'s edge midpoints, NOT
    /// rotated by `shape.geometry.rotation` - a documented P1
    /// simplification (this item's report): a rotated attached
    /// shape's connector glues to its unrotated compass point.
    /// Rotation-aware glue points are a natural, small follow-up, not
    /// part of this contract's ask.
    public static func gluePoints(for shape: Shape) -> [CGPoint] {
        let f = shape.geometry.frame
        return [
            CGPoint(x: f.midX, y: f.minY), // 0 top
            CGPoint(x: f.maxX, y: f.midY), // 1 right
            CGPoint(x: f.midX, y: f.maxY), // 2 bottom
            CGPoint(x: f.minX, y: f.midY), // 3 left
        ]
    }

    public static func gluePoint(_ index: Int, for shape: Shape) -> CGPoint? {
        let points = gluePoints(for: shape)
        guard points.indices.contains(index) else { return nil }
        return points[index]
    }

    /// `gluePoints(for:)`'s outward-facing unit normal at the same
    /// index - the escape-stub direction a connector leaves along when
    /// glued to that point.
    private static let compassOutwardNormal: [CGVector] = [
        CGVector(dx: 0, dy: -1), // 0 top
        CGVector(dx: 1, dy: 0),  // 1 right
        CGVector(dx: 0, dy: 1),  // 2 bottom
        CGVector(dx: -1, dy: 0), // 3 left
    ]

    // MARK: - Endpoint resolution

    /// One `ConnectorEndpoint` resolved to a world-space point, plus
    /// (for an attached endpoint) the outward normal to escape along
    /// and the attached shape's frame to detour around. `nil` normal/
    /// box for a free endpoint - there is no shape edge to leave
    /// perpendicular to, or box to avoid, on that end.
    private struct Resolved {
        let point: CGPoint
        let outwardNormal: CGVector?
        let box: CGRect?
    }

    private static func resolve(_ endpoint: ConnectorEndpoint, shapes: [UUID: Shape]) -> Resolved? {
        switch endpoint {
        case .free(let x, let y):
            return Resolved(point: CGPoint(x: x, y: y), outwardNormal: nil, box: nil)
        case .attached(let shapeID, let index):
            guard let shape = shapes[shapeID],
                  compassOutwardNormal.indices.contains(index),
                  let point = gluePoint(index, for: shape)
            else { return nil }
            return Resolved(point: point, outwardNormal: compassOutwardNormal[index], box: shape.geometry.frame)
        }
    }

    // MARK: - Entry point

    /// `connector`'s path, resolved against `shapes` (keyed by
    /// `Shape.id`). `nil` when either endpoint can't resolve (an
    /// `.attached` endpoint whose `shapeID` isn't in `shapes`, or an
    /// out-of-range `gluePointIndex`) - malformed data degrades to
    /// "nothing drawn," matching `ShapeRenderer`'s existing "a data
    /// error doesn't crash the renderer" contract (see
    /// `kindIsFillable`'s doc comment there).
    public static func route(_ connector: ConnectorInfo, shapes: [UUID: Shape]) -> CGPath? {
        guard let start = resolve(connector.start, shapes: shapes),
              let end = resolve(connector.end, shapes: shapes)
        else { return nil }

        switch connector.style {
        case .straight:
            return straightPath(from: start.point, to: end.point)
        case .curved:
            return curvedPath(from: start, to: end)
        case .elbow:
            return elbowPath(from: start, to: end)
        }
    }

    // MARK: - Straight

    private static func straightPath(from: CGPoint, to: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    // MARK: - Curved

    private static let stubLength: CGFloat = 16

    /// A 2-control-point cubic bezier - "do not over-engineer" per
    /// this item's contract. Each control point sits `stubLength` out
    /// along its endpoint's escape normal, so the curve leaves each
    /// attached shape's edge roughly tangent to it; a free endpoint
    /// has no normal, so its control point is the endpoint itself and
    /// the curve degrades toward a straight approach on that end - the
    /// honest simple behavior for a point with no edge to be tangent to.
    private static func curvedPath(from start: Resolved, to end: Resolved) -> CGPath {
        let c1 = stubPoint(start)
        let c2 = stubPoint(end)
        let path = CGMutablePath()
        path.move(to: start.point)
        path.addCurve(to: end.point, control1: c1, control2: c2)
        return path
    }

    private static func stubPoint(_ endpoint: Resolved) -> CGPoint {
        guard let n = endpoint.outwardNormal else { return endpoint.point }
        return CGPoint(x: endpoint.point.x + n.dx * stubLength, y: endpoint.point.y + n.dy * stubLength)
    }

    // MARK: - Elbow

    /// Escape-stub + 3-5 segment Manhattan path, detouring around only
    /// `start`/`end`'s attached-shape boxes - not general obstacle
    /// avoidance (this file's header comment). Each endpoint's stub
    /// leaves perpendicular to its shape's edge (or is the point
    /// itself, for a free endpoint); the two stubs are then joined by
    /// a single-corner axis-aligned bend, escalated to a two-corner
    /// detour only if that corner's segments would cut through one of
    /// the two boxes.
    private static func elbowPath(from start: Resolved, to end: Resolved) -> CGPath {
        let stubStart = stubPoint(start)
        let stubEnd = stubPoint(end)
        let boxes = [start.box, end.box].compactMap { $0 }

        let bend = manhattanBend(from: stubStart, startNormal: start.outwardNormal, to: stubEnd, avoiding: boxes)

        var points: [CGPoint] = [start.point]
        if stubStart != start.point { points.append(stubStart) }
        points.append(contentsOf: bend)
        if stubEnd != end.point { points.append(stubEnd) }
        points.append(end.point)

        return polylinePath(points)
    }

    /// The interior bend point(s) connecting `from` to `to` with
    /// axis-aligned segments only: a single corner (the common case)
    /// unless that corner's two segments would cut through one of
    /// `avoiding`'s boxes, in which case the shared coordinate is
    /// pushed out past the far edge of BOTH boxes, in the direction
    /// `from` already escaped (`startNormal`) - so the detour
    /// continues monotonically away from `from`'s own box rather than
    /// crossing back through it - producing a two-corner detour whose
    /// middle segment is, by construction, outside both boxes' extent
    /// on the bend axis.
    ///
    /// Scope: only the two boxes named by `avoiding` are considered.
    /// This is the office-suite-typical case (the shapes' glue points
    /// reasonably facing each other); it is not a proof for
    /// arbitrary/adversarial shape placement - see this file's header.
    private static func manhattanBend(
        from: CGPoint,
        startNormal: CGVector?,
        to: CGPoint,
        avoiding boxes: [CGRect]
    ) -> [CGPoint] {
        let vertical = startNormal.map { $0.dx == 0 } ?? (abs(to.y - from.y) >= abs(to.x - from.x))
        let corner = vertical ? CGPoint(x: to.x, y: from.y) : CGPoint(x: from.x, y: to.y)

        let blocked = boxes.contains {
            $0.crossesAxisAlignedSegment(from, corner) || $0.crossesAxisAlignedSegment(corner, to)
        }
        guard blocked else { return [corner] }

        if vertical {
            let goingUp = (startNormal?.dy ?? (to.y - from.y)) < 0
            let clearY = goingUp
                ? (boxes.map(\.minY).min() ?? min(from.y, to.y)) - stubLength
                : (boxes.map(\.maxY).max() ?? max(from.y, to.y)) + stubLength
            return [CGPoint(x: from.x, y: clearY), CGPoint(x: to.x, y: clearY)]
        } else {
            let goingLeft = (startNormal?.dx ?? (to.x - from.x)) < 0
            let clearX = goingLeft
                ? (boxes.map(\.minX).min() ?? min(from.x, to.x)) - stubLength
                : (boxes.map(\.maxX).max() ?? max(from.x, to.x)) + stubLength
            return [CGPoint(x: clearX, y: from.y), CGPoint(x: clearX, y: to.y)]
        }
    }

    // MARK: - Path assembly

    /// Builds an open polyline through `rawPoints`, dropping
    /// consecutive exact duplicates (e.g. an endpoint with no stub, or
    /// a corner that coincides with a stub) so the path has no
    /// degenerate zero-length segments.
    private static func polylinePath(_ rawPoints: [CGPoint]) -> CGPath {
        var points: [CGPoint] = []
        for p in rawPoints {
            if let last = points.last, last == p { continue }
            points.append(p)
        }
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }
}

// MARK: - CGRect + segment crossing

private extension CGRect {
    /// True when the axis-aligned segment `a`-`b` (this router only
    /// ever builds horizontal or vertical segments) cuts through this
    /// rect's OPEN interior. An edge-touching segment does not count -
    /// only a genuine cut through the middle is what "detour around"
    /// needs to prevent, matching the escape-stub's own guarantee
    /// (a stub leaves exactly ON a shape's edge, by construction).
    func crossesAxisAlignedSegment(_ a: CGPoint, _ b: CGPoint) -> Bool {
        if a.y == b.y {
            guard a.y > minY, a.y < maxY else { return false }
            let lo = min(a.x, b.x), hi = max(a.x, b.x)
            return lo < maxX && hi > minX
        }
        if a.x == b.x {
            guard a.x > minX, a.x < maxX else { return false }
            let lo = min(a.y, b.y), hi = max(a.y, b.y)
            return lo < maxY && hi > minY
        }
        return false
    }
}
