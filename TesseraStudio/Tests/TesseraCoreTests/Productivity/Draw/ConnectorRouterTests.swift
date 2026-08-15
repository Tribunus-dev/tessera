import XCTest
import CoreGraphics
@testable import TesseraCore

/// Black-box: decodes the returned `CGPath` back into its vertex list
/// via `applyWithBlock` and checks geometric properties (axis
/// alignment, non-crossing) independently of `ConnectorRouter`'s own
/// internals, matching `ShapeRendererTests`' "read the real output
/// back" style rather than exposing private routing helpers to the
/// test target.
final class ConnectorRouterTests: XCTestCase {

    // MARK: - Helpers

    private func makeShape(_ id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double) -> Shape {
        Shape(id: id, kind: .rect, geometry: ShapeGeometry(x: x, y: y, width: width, height: height))
    }

    /// The "through" points of `path` in order - the endpoint of every
    /// move/line/curve element, skipping control points, so this is
    /// exactly the polyline vertex list `ConnectorRouter` built (for a
    /// straight/elbow path) or the [start, end] pair (for a curved
    /// one, since a cubic's control points aren't "through" points).
    private func throughPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        return points
    }

    /// True when the axis-aligned segment `a`-`b` cuts through `rect`'s
    /// OPEN interior. A non-axis-aligned segment is treated as a hit
    /// (conservatively) rather than silently passing - this test only
    /// ever expects Manhattan segments from the elbow router.
    private func segmentCrossesInterior(_ a: CGPoint, _ b: CGPoint, of rect: CGRect) -> Bool {
        if a.y == b.y {
            guard a.y > rect.minY, a.y < rect.maxY else { return false }
            let lo = min(a.x, b.x), hi = max(a.x, b.x)
            return lo < rect.maxX && hi > rect.minX
        }
        if a.x == b.x {
            guard a.x > rect.minX, a.x < rect.maxX else { return false }
            let lo = min(a.y, b.y), hi = max(a.y, b.y)
            return lo < rect.maxY && hi > rect.minY
        }
        return rect.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
    }

    // MARK: - Glue points

    func testGluePointsAreTheFourCompassMidpoints() {
        let shape = makeShape(x: 10, y: 20, width: 100, height: 50)
        let points = ConnectorRouter.gluePoints(for: shape)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[0], CGPoint(x: 60, y: 20), "0 = top-center")
        XCTAssertEqual(points[1], CGPoint(x: 110, y: 45), "1 = right-center")
        XCTAssertEqual(points[2], CGPoint(x: 60, y: 70), "2 = bottom-center")
        XCTAssertEqual(points[3], CGPoint(x: 10, y: 45), "3 = left-center")
    }

    func testGluePointOutOfRangeReturnsNil() {
        let shape = makeShape(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(ConnectorRouter.gluePoint(4, for: shape))
        XCTAssertNil(ConnectorRouter.gluePoint(-1, for: shape))
    }

    // MARK: - Resolution failures

    func testRouteReturnsNilWhenAttachedShapeIsMissing() {
        let info = ConnectorInfo(start: .attached(shapeID: UUID(), gluePointIndex: 0), end: .free(x: 10, y: 10), style: .straight)
        XCTAssertNil(ConnectorRouter.route(info, shapes: [:]))
    }

    func testRouteReturnsNilForOutOfRangeGluePointIndex() {
        let shape = makeShape(x: 0, y: 0, width: 10, height: 10)
        let info = ConnectorInfo(start: .attached(shapeID: shape.id, gluePointIndex: 9), end: .free(x: 10, y: 10), style: .straight)
        XCTAssertNil(ConnectorRouter.route(info, shapes: [shape.id: shape]))
    }

    // MARK: - Straight

    func testStraightPathConnectsTheTwoResolvedFreePoints() {
        let info = ConnectorInfo(start: .free(x: 0, y: 0), end: .free(x: 100, y: 50), style: .straight)
        guard let path = ConnectorRouter.route(info, shapes: [:]) else {
            return XCTFail("expected a resolved path")
        }
        XCTAssertFalse(path.isEmpty)
        let points = throughPoints(path)
        XCTAssertEqual(points, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)])
    }

    // MARK: - Curved

    func testCurvedPathIsNonEmptyAndSpansTheResolvedEndpoints() {
        let a = makeShape(x: 0, y: 0, width: 100, height: 60)
        let b = makeShape(x: 200, y: 150, width: 100, height: 60)
        let info = ConnectorInfo(
            start: .attached(shapeID: a.id, gluePointIndex: 2), // bottom
            end: .attached(shapeID: b.id, gluePointIndex: 0),   // top
            style: .curved
        )
        guard let path = ConnectorRouter.route(info, shapes: [a.id: a, b.id: b]) else {
            return XCTFail("expected a resolved path")
        }
        XCTAssertFalse(path.isEmpty)
        let points = throughPoints(path)
        XCTAssertEqual(points.first, CGPoint(x: 50, y: 60), "starts at A's bottom glue point")
        XCTAssertEqual(points.last, CGPoint(x: 250, y: 150), "ends at B's top glue point")
    }

    // MARK: - Elbow

    /// Two well-separated, non-overlapping shapes with glue points
    /// facing each other (A's bottom -> B's top, B down-and-right of
    /// A) - the canonical office-diagram case this item's test
    /// contract names.
    func testElbowRouteBetweenTwoShapesIsAxisAlignedAndAvoidsBothFrames() {
        let a = makeShape(x: 0, y: 0, width: 100, height: 60)
        let b = makeShape(x: 200, y: 150, width: 100, height: 60)
        let info = ConnectorInfo(
            start: .attached(shapeID: a.id, gluePointIndex: 2), // bottom
            end: .attached(shapeID: b.id, gluePointIndex: 0),   // top
            style: .elbow
        )
        guard let path = ConnectorRouter.route(info, shapes: [a.id: a, b.id: b]) else {
            return XCTFail("expected a resolved path")
        }
        let points = throughPoints(path)
        XCTAssertGreaterThanOrEqual(points.count, 3, "escape stub + at least one bend + arrival")
        XCTAssertEqual(points.first, CGPoint(x: 50, y: 60))
        XCTAssertEqual(points.last, CGPoint(x: 250, y: 150))

        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertTrue(p.x == q.x || p.y == q.y, "segment \(p) -> \(q) is not axis-aligned")
        }
        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertFalse(segmentCrossesInterior(p, q, of: a.geometry.frame), "\(p) -> \(q) crosses A's frame")
            XCTAssertFalse(segmentCrossesInterior(p, q, of: b.geometry.frame), "\(p) -> \(q) crosses B's frame")
        }
    }

    /// Two shapes stacked directly above/below each other (shared glue
    /// x) - the escape stubs already line up, so the router should
    /// collapse to a straight run between them rather than adding a
    /// pointless jog.
    func testElbowRouteCollapsesToAStraightRunWhenAlreadyAligned() {
        let a = makeShape(x: 0, y: 0, width: 100, height: 60)
        let b = makeShape(x: 0, y: 150, width: 100, height: 60)
        let info = ConnectorInfo(
            start: .attached(shapeID: a.id, gluePointIndex: 2), // bottom
            end: .attached(shapeID: b.id, gluePointIndex: 0),   // top
            style: .elbow
        )
        guard let path = ConnectorRouter.route(info, shapes: [a.id: a, b.id: b]) else {
            return XCTFail("expected a resolved path")
        }
        let points = throughPoints(path)
        XCTAssertTrue(points.allSatisfy { $0.x == points[0].x }, "every vertex stays on the shared centerline: \(points)")
        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertFalse(segmentCrossesInterior(p, q, of: a.geometry.frame))
            XCTAssertFalse(segmentCrossesInterior(p, q, of: b.geometry.frame))
        }
    }

    func testElbowRouteBetweenTwoFreePointsIsAxisAligned() {
        let info = ConnectorInfo(start: .free(x: 0, y: 0), end: .free(x: 80, y: 40), style: .elbow)
        guard let path = ConnectorRouter.route(info, shapes: [:]) else {
            return XCTFail("expected a resolved path")
        }
        let points = throughPoints(path)
        XCTAssertGreaterThanOrEqual(points.count, 2)
        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertTrue(p.x == q.x || p.y == q.y, "segment \(p) -> \(q) is not axis-aligned")
        }
    }
}
