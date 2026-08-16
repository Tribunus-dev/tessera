import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - ShapePathTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md's
// "2.3 BezierPathController" section, whose own named test is quoted
// verbatim in this file's class-level test names: "ShapePath round-trips
// SVG path data losslessly." Also covers `boundingBox`/`rescaled(from:to:)`,
// the additive helpers `BezierPathController`/`ODGBridgeFilter` need
// (this cluster's brief: "evolve the ShapePath/ShapeSubpath/
// ShapePathSegment types additively if your controller needs more").

final class ShapePathTests: DoctrineTestCase {

    // MARK: - "ShapePath round-trips SVG path data losslessly"

    func testShapePathRoundTripsSVGPathDataLosslesslyForAllSegmentKinds() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 0)),
                    .quad(control: ShapePathPoint(x: 15, y: 5), end: ShapePathPoint(x: 10, y: 10)),
                    .cubic(
                        control1: ShapePathPoint(x: 8, y: 12),
                        control2: ShapePathPoint(x: 2, y: 12),
                        end: ShapePathPoint(x: 0, y: 10)
                    ),
                ],
                closed: true
            ),
        ])
        let encoded = path.pathData
        let decoded = ShapePath.parsingPathData(encoded)
        XCTAssertEqual(decoded, path)
    }

    func testShapePathRoundTripsMultipleSubpathsBothOpenAndClosed() {
        // "a letter 'O' is two subpaths: an outer ring and an inner
        // hole" (ShapePath.swift's own header comment) - exercised here
        // as an outer closed ring plus an unrelated trailing OPEN
        // subpath, so both closed-ness values are covered in one path.
        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 100, y: 0)),
                    .line(ShapePathPoint(x: 100, y: 100)),
                    .line(ShapePathPoint(x: 0, y: 100)),
                ],
                closed: true
            ),
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 20, y: 20)),
                    .line(ShapePathPoint(x: 80, y: 20)),
                    .line(ShapePathPoint(x: 80, y: 80)),
                    .line(ShapePathPoint(x: 20, y: 80)),
                ],
                closed: true
            ),
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 200, y: 200)),
                    .line(ShapePathPoint(x: 250, y: 225.5)),
                ],
                closed: false
            ),
        ])
        let decoded = ShapePath.parsingPathData(path.pathData)
        XCTAssertEqual(decoded, path)
        XCTAssertEqual(decoded.subpaths.map(\.closed), [true, true, false])
    }

    func testShapePathRoundTripsFractionalCoordinatesExactly() {
        // Swift's own Double description is the shortest string that
        // reads back to the exact same Double (pathData's own doc
        // comment) - pinned here against a value that is NOT exactly
        // representable in decimal (0.1) to catch a naive fixed-
        // precision formatter regression.
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0.1, y: -3.14159265358979)),
                .line(ShapePathPoint(x: 12.345678901234, y: 0)),
            ]),
        ])
        let decoded = ShapePath.parsingPathData(path.pathData)
        XCTAssertEqual(decoded, path)
    }

    func testShapePathParsingEmptyStringProducesEmptyPath() {
        XCTAssertEqual(ShapePath.parsingPathData(""), ShapePath())
    }

    // MARK: - Decoding real-world (non-self-authored) path data
    //
    // `parsingPathData(_:)` must also understand the vocabulary a REAL
    // `soffice` re-export actually uses (relative lowercase commands,
    // H/V shorthand, numbers packed without separators) - this is what
    // a live `ODGBridgeFilter.import(from:)` actually reads, not this
    // encoder's own output. Fixtures below are the exact strings
    // observed against LibreOffice 26.2.5.2 (probed 2026-08-15 - see
    // `ODGBezierPathWireFormatProbeTests.swift` for the live version of
    // this same contract).

    func testParsingPathDataUnderstandsRelativeHAndVShorthand() {
        // Verbatim fragment from a real draw:connector's own svg:d
        // (ODGBridgeFilter.connectorAttributes's own doc comment):
        // "M4000 2000h501l2998 7000h501" - move, then three relative
        // linetos packed with no separating space before each letter.
        let decoded = ShapePath.parsingPathData("M4000 2000h501l2998 7000h501")
        XCTAssertEqual(decoded.subpaths.count, 1)
        let segments = decoded.subpaths[0].segments
        XCTAssertEqual(segments.count, 4, "move + 3 implicit-repeat-free linetos (h, l, h)")
        XCTAssertEqual(segments[0].endPoint, ShapePathPoint(x: 4000, y: 2000))
        XCTAssertEqual(segments[1].endPoint, ShapePathPoint(x: 4501, y: 2000))
        XCTAssertEqual(segments[2].endPoint, ShapePathPoint(x: 7499, y: 9000))
        XCTAssertEqual(segments[3].endPoint, ShapePathPoint(x: 8000, y: 9000))
        for segment in segments.dropFirst() {
            guard case .line = segment else { return XCTFail("expected every non-move segment to decode as .line") }
        }
    }

    func testParsingPathDataUnderstandsRelativeCubicAndClose() {
        // Real soffice re-export of a hand-authored quadratic curve
        // (confirmed empirically 2026-08-15: soffice promotes .quad to
        // .cubic internally - see this item's findings file) - pinned
        // here as a REAL observed cubic wire fragment, not a guess.
        let decoded = ShapePath.parsingPathData("M0 0c1334 1000 2667 1000 4001 0v3001h-4001z")
        XCTAssertEqual(decoded.subpaths.count, 1)
        let subpath = decoded.subpaths[0]
        XCTAssertTrue(subpath.closed)
        XCTAssertEqual(subpath.segments.count, 4)
        guard case .cubic(let c1, let c2, let end) = subpath.segments[1] else {
            return XCTFail("expected segment[1] to decode as .cubic")
        }
        XCTAssertEqual(c1, ShapePathPoint(x: 1334, y: 1000))
        XCTAssertEqual(c2, ShapePathPoint(x: 2667, y: 1000))
        XCTAssertEqual(end, ShapePathPoint(x: 4001, y: 0))
        XCTAssertEqual(subpath.segments[2].endPoint, ShapePathPoint(x: 4001, y: 3001))
        XCTAssertEqual(subpath.segments[3].endPoint, ShapePathPoint(x: 0, y: 3001))
    }

    func testParsingPathDataHandlesImplicitCommandRepetition() {
        // "L10 10 20 20" is standard SVG grammar for two linetos, not
        // one lineto with 4 numbers - this codebase's own encoder never
        // emits this shape, but a foreign/real document may.
        let decoded = ShapePath.parsingPathData("M0 0 L10 10 20 20")
        XCTAssertEqual(decoded.subpaths.count, 1)
        let segments = decoded.subpaths[0].segments
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].endPoint, ShapePathPoint(x: 10, y: 10))
        XCTAssertEqual(segments[2].endPoint, ShapePathPoint(x: 20, y: 20))
    }

    func testParsingPathDataDegradesMalformedInputInsteadOfCrashing() {
        // No leading M, garbage characters, a truncated final command -
        // "malformed data degrades" (this codebase's own convention,
        // e.g. ODGBridgeFilter's import parsing) rather than throwing.
        XCTAssertNoThrow(ShapePath.parsingPathData("garbage !! not a path M10 10 L20"))
    }

    // MARK: - boundingBox

    func testBoundingBoxOfEmptySubpathIsZero() {
        XCTAssertEqual(ShapeSubpath(segments: []).boundingBox, .zero)
    }

    func testBoundingBoxIncludesControlPoints() {
        // A loose bound (this type's own doc comment) - the quad
        // control point (50, -20) sits outside the endpoints' own span,
        // so it must widen the box, not just track move/line/end points.
        let subpath = ShapeSubpath(segments: [
            .move(ShapePathPoint(x: 0, y: 0)),
            .quad(control: ShapePathPoint(x: 50, y: -20), end: ShapePathPoint(x: 10, y: 10)),
        ])
        let box = subpath.boundingBox
        XCTAssertEqual(box.minX, 0)
        XCTAssertEqual(box.maxX, 50)
        XCTAssertEqual(box.minY, -20)
        XCTAssertEqual(box.maxY, 10)
    }

    func testShapePathBoundingBoxUnionsEverySubpath() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 10))]),
            ShapeSubpath(segments: [.move(ShapePathPoint(x: -5, y: 30)), .line(ShapePathPoint(x: 40, y: 30))]),
        ])
        let box = path.boundingBox
        XCTAssertEqual(box.minX, -5)
        XCTAssertEqual(box.maxX, 40)
        XCTAssertEqual(box.minY, 0)
        XCTAssertEqual(box.maxY, 30)
    }

    // MARK: - rescaled(from:to:)

    func testRescaledMapsPointsProportionallyBetweenBoxes() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .line(ShapePathPoint(x: 400, y: 300)),
            ]),
        ])
        let rescaled = path.rescaled(
            from: CGRect(x: 0, y: 0, width: 400, height: 300),
            to: CGRect(x: 0, y: 0, width: 40, height: 30)
        )
        XCTAssertEqual(rescaled.subpaths[0].segments[0].endPoint, ShapePathPoint(x: 0, y: 0))
        XCTAssertEqual(rescaled.subpaths[0].segments[1].endPoint, ShapePathPoint(x: 40, y: 30))
    }

    func testRescaledIsIdentityWhenSourceAndTargetBoxesMatch() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 3, y: 4))])])
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(path.rescaled(from: box, to: box), path)
    }

    func testRescaledDegradesToIdentityOnDegenerateSourceBoxInsteadOfDividingByZero() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 3, y: 4))])])
        let zeroBox = CGRect(x: 0, y: 0, width: 0, height: 0)
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(path.rescaled(from: zeroBox, to: target), path)
    }
}
