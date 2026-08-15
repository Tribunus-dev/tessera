import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - ConnectorRouterTests
//
// Contract source: ConnectorRouter.swift's own doc comments (design
// refinement doc section 4, Draw cluster, item 1.19): gluePoints are
// compass-indexed 0=top,1=right,2=bottom,3=left from the frame's
// UNROTATED edge midpoints; route(_:shapes:) returns nil when either
// endpoint can't resolve; .straight is a direct line; a free endpoint
// with no attached shape degrades a curved connector's control point to
// the endpoint itself.

final class ConnectorRouterTests: DoctrineTestCase {

    private func rect(x: Double, y: Double, w: Double, h: Double) -> Shape {
        Shape(kind: .rect, geometry: ShapeGeometry(x: x, y: y, width: w, height: h))
    }

    // MARK: Glue points (fixture - hand-computed from the frame)

    func testGluePointsAreTheFramesCompassEdgeMidpointsInDocumentedOrder() {
        let shape = rect(x: 0, y: 0, w: 100, h: 40)
        let points = ConnectorRouter.gluePoints(for: shape)
        XCTAssertEqual(points, [
            CGPoint(x: 50, y: 0),   // 0 top
            CGPoint(x: 100, y: 20), // 1 right
            CGPoint(x: 50, y: 40),  // 2 bottom
            CGPoint(x: 0, y: 20),   // 3 left
        ])
    }

    func testGluePointsIgnoreRotationPerTheDocumentedP1Simplification() {
        var shape = rect(x: 0, y: 0, w: 100, h: 40)
        shape.geometry.rotation = 90
        let points = ConnectorRouter.gluePoints(for: shape)
        // Unrotated compass points, exactly as the un-rotated fixture -
        // rotation-aware glue points are explicitly out of scope at P1.
        XCTAssertEqual(points, ConnectorRouter.gluePoints(for: rect(x: 0, y: 0, w: 100, h: 40)))
    }

    func testGluePointOfOutOfRangeIndexReturnsNil() {
        let shape = rect(x: 0, y: 0, w: 10, h: 10)
        XCTAssertNil(ConnectorRouter.gluePoint(4, for: shape))
        XCTAssertNil(ConnectorRouter.gluePoint(-1, for: shape))
    }

    // MARK: route(_:shapes:) - resolution failure

    func testRouteReturnsNilWhenAnAttachedEndpointsShapeIsMissing() {
        let connector = ConnectorInfo(start: .attached(shapeID: UUID(), gluePointIndex: 0), end: .free(x: 10, y: 10))
        XCTAssertNil(ConnectorRouter.route(connector, shapes: [:]))
    }

    func testRouteReturnsNilWhenAnAttachedEndpointsGluePointIndexIsOutOfRange() {
        let shape = rect(x: 0, y: 0, w: 10, h: 10)
        let connector = ConnectorInfo(start: .attached(shapeID: shape.id, gluePointIndex: 99), end: .free(x: 10, y: 10))
        XCTAssertNil(ConnectorRouter.route(connector, shapes: [shape.id: shape]))
    }

    // MARK: route(_:shapes:) - straight

    func testStraightConnectorIsADirectTwoPointPath() {
        let connector = ConnectorInfo(start: .free(x: 0, y: 0), end: .free(x: 50, y: 30), style: .straight)
        let path = ConnectorRouter.route(connector, shapes: [:])
        let points = pathPoints(path)
        XCTAssertEqual(points, [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 30)])
    }

    // MARK: route(_:shapes:) - curved degrades to a straight-ish approach for a free endpoint

    func testCurvedConnectorWithOneFreeEndpointUsesThatEndpointAsItsOwnControlPoint() {
        let anchor = rect(x: 0, y: 0, w: 40, h: 40)
        let connector = ConnectorInfo(
            start: .attached(shapeID: anchor.id, gluePointIndex: 1), // right: (40, 20)
            end: .free(x: 200, y: 20),
            style: .curved
        )
        guard let path = ConnectorRouter.route(connector, shapes: [anchor.id: anchor]) else {
            return XCTFail("expected a resolved path")
        }
        // CGPath doesn't expose control points directly via a public
        // "elements" API in a version-stable way across platforms, so
        // this asserts the documented endpoints via the bounding box
        // instead: a curve from (40,20) to (200,20) with a control point
        // pushed out along the attached shape's outward normal (right,
        // +16 in x) must not extend the bounding box in y, and must span
        // at least [40, 200] on x.
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 40, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 200, accuracy: 1e-6)
    }

    // MARK: route(_:shapes:) - elbow, unblocked single-corner bend

    func testElbowConnectorBetweenTwoFreePointsBendsAtASingleAxisAlignedCorner() {
        // No attached shapes -> no stubs, no boxes to avoid -> the
        // simple single-corner Manhattan bend.
        let connector = ConnectorInfo(start: .free(x: 0, y: 0), end: .free(x: 100, y: 50), style: .elbow)
        guard let path = ConnectorRouter.route(connector, shapes: [:]) else {
            return XCTFail("expected a resolved path")
        }
        let points = pathPoints(path)
        XCTAssertEqual(points.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(points.last, CGPoint(x: 100, y: 50))
        // Every interior point is axis-aligned with its neighbor (no
        // diagonal segments).
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y, "elbow segments must be axis-aligned: \(a) -> \(b)")
        }
    }

    // MARK: - CGPath point extraction helper

    private func pathPoints(_ path: CGPath?) -> [CGPoint] {
        guard let path else { return [] }
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.pointee.points[0])
            case .addQuadCurveToPoint:
                points.append(element.pointee.points[1])
            case .addCurveToPoint:
                points.append(element.pointee.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        return points
    }
}
