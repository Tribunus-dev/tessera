import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - ODGBezierPathWireFormatProbeTests
//
// QUARANTINED EMPIRICAL PROBE (doctrine rule 10). Shells out to a real
// `soffice` to verify item 2.3's `draw:path` wire-format mapping end to
// end (Drawing -> fodg -> soffice odg -> soffice fodg -> Drawing),
// through TESSERA'S OWN `ODGBridgeFilter.export`/`.import` code path -
// same shape as `ODGConnectorWireFormatProbeTests.swift`, which this
// file otherwise mirrors exactly.
//
// PROBE DATE / TOOL VERSION (this run, not copied from ODGBridgeFilter's
// doc comments - doctrine rule 10 requires re-running, not trusting a
// prior comment):
//   - Probed: 2026-08-15
//   - `soffice --version`: LibreOffice 26.2.5.2
//     (cd7284b4cbbfeb507e630c1aac019f4157393acb)
//
// FINDINGS from this probe (both confirmed via a hand-authored fodg with
// a draw:path element, converted fodg->odg->fodg through this machine's
// real soffice and diffed, immediately before writing this file - see
// this wave's findings file for the full write-up):
//
//   1. QUAD -> CUBIC PROMOTION. soffice's internal path model only
//      stores cubic bezier curves; a hand-authored `.quad` command in
//      `svg:d` round-trips back out as an EQUIVALENT `.cubic` (the
//      standard quadratic-to-cubic degree-elevation formula). This is
//      an accepted, documented loss - like `ODGBridgeFilter.lineAttributes`'s
//      own documented height loss for `.line`/`.arrow` - not a bug. The
//      PURE `ShapePath.pathData`/`parsingPathData(_:)` codec (tested in
//      `ShapePathTests.swift`) is NOT lossy for `.quad`; only a REAL
//      external soffice round trip is, which is exactly why this probe
//      (not the pure test) is where it is pinned.
//   2. CURVE-FREE CLOSED SHAPE DEMOTED TO draw:polygon. A `.bezier`
//      shape whose every subpath is CLOSED and built only from straight
//      `.line` segments comes back from a real round trip as a plain
//      `draw:polygon`, not `draw:path` - soffice's own internal
//      PolyPolygon model simplifies a curve-free closed outline on
//      export. `ODGBridgeFilter.shapePath(for:boxGeometry:)` reads
//      whichever of the two elements the shape actually landed on (its
//      `"ts-kind:bezier"` `draw:name` marker survives regardless).
//   3. `draw:id` IS DROPPED for a shape nothing else in the same
//      document references (confirmed for BOTH a plain `draw:rect` and
//      a `draw:path` in isolation - NOT specific to `.bezier`; the
//      existing connector probe's shapes keep their `draw:id` only
//      because `draw:connector`'s own `draw:start-shape`/`draw:end-
//      shape` attributes reference them). `ODGBridgeFilter`'s import
//      already handles an unrecognized/missing `draw:id` by minting a
//      fresh `UUID` (`uuid(fromDrawID:)`'s own fallback), so this does
//      not break re-import - a `.bezier` shape's OWN Tessera-side
//      identity simply does not survive a round trip through a real
//      ODG package unless something else references it, exactly like
//      every other unreferenced shape kind.
//
// Skips cleanly when soffice is absent (`ODGBridgeFilter().isAvailable`).
// 120s allowance (DoctrineTimeout.probe) per rule 12. Rule 11's ungated
// shadow of this same draw:path/draw:polygon <-> ShapePath contract
// lives in `ODGBridgeFilterTests.swift` (hand-authored fodg fixtures,
// no soffice).

final class ODGBezierPathWireFormatProbeTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func skipIfSofficeUnavailable(_ filter: ODGBridgeFilter) throws {
        guard filter.isAvailable else {
            throw XCTSkip("soffice not found on this machine - skipping live ODG bezier-path wire-format probe.")
        }
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("odg-bezier-probe-\(UUID().uuidString)-\(name)")
    }

    // MARK: - A curved, closed .bezier survives (as draw:path; quad -> cubic)

    func testACurvedClosedBezierShapeSurvivesARealSofficeRoundTripThroughODGBridgeFilter() async throws {
        let filter = ODGBridgeFilter()
        try skipIfSofficeUnavailable(filter)

        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .quad(control: ShapePathPoint(x: 20, y: 15), end: ShapePathPoint(x: 40, y: 0)),
                    .line(ShapePathPoint(x: 40, y: 30)),
                    .line(ShapePathPoint(x: 0, y: 30)),
                ],
                closed: true
            ),
        ])
        let shape = Shape(kind: .bezier, geometry: ShapeGeometry(x: 10, y: 10, width: 40, height: 30), path: path)
        let drawing = Drawing.makeBlank(title: "Bezier Probe").insertingShape(shape)

        let odgURL = tempURL("curved.odg")
        defer { try? FileManager.default.removeItem(at: odgURL) }

        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.export(drawing, to: odgURL)
        }
        let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.import(from: odgURL)
        }

        guard let decoded = roundTripped.shapes.first(where: { $0.kind == .bezier }) else {
            return XCTFail("expected a .bezier shape to survive the round trip")
        }
        guard let decodedPath = decoded.path, let subpath = decodedPath.subpaths.first else {
            return XCTFail("expected a decoded ShapePath with at least one subpath")
        }
        XCTAssertTrue(subpath.closed, "the closed subpath must stay closed")
        XCTAssertGreaterThanOrEqual(subpath.segments.count, 3, "move + at least a curve + the two closing lines")

        // Finding 1: the .quad segment comes back as .cubic (soffice's
        // own internal model only stores cubic curves) - assert a curve
        // segment survived as SOME curve kind, and that it is in fact
        // .cubic, not silently dropped to a straight line.
        let curveSegments = subpath.segments.filter {
            if case .quad = $0 { return true }
            if case .cubic = $0 { return true }
            return false
        }
        XCTAssertEqual(curveSegments.count, 1, "exactly one curve segment must survive")
        guard case .cubic = curveSegments.first else {
            return XCTFail("the surviving curve segment must have been promoted to .cubic")
        }

        // Endpoint of the curve segment should land near (40, 0) in the
        // shape's own local space (soffice's hundredths-of-mm rounding
        // plus this bridge's own sub-micron cm rounding bounds the
        // error well under 1 point).
        if let curveEnd = curveSegments.first?.endPoint {
            XCTAssertEqual(curveEnd.x, 40, accuracy: 1.0)
            XCTAssertEqual(curveEnd.y, 0, accuracy: 1.0)
        }
    }

    // MARK: - A curve-free, closed .bezier survives even when demoted to draw:polygon

    func testAStraightOnlyClosedBezierShapeSurvivesEvenWhenSofficeDemotesItToDrawPolygon() async throws {
        let filter = ODGBridgeFilter()
        try skipIfSofficeUnavailable(filter)

        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 40, y: 0)),
                    .line(ShapePathPoint(x: 40, y: 30)),
                    .line(ShapePathPoint(x: 0, y: 30)),
                ],
                closed: true
            ),
        ])
        let shape = Shape(kind: .bezier, geometry: ShapeGeometry(x: 10, y: 10, width: 40, height: 30), path: path)
        let drawing = Drawing.makeBlank(title: "Bezier Polygon-Demotion Probe").insertingShape(shape)

        let odgURL = tempURL("straight.odg")
        defer { try? FileManager.default.removeItem(at: odgURL) }

        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.export(drawing, to: odgURL)
        }
        let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.import(from: odgURL)
        }

        guard let decoded = roundTripped.shapes.first(where: { $0.kind == .bezier }) else {
            return XCTFail("the ts-kind:bezier marker must still resolve .bezier even when soffice demoted the element to draw:polygon")
        }
        guard let decodedPath = decoded.path, let subpath = decodedPath.subpaths.first else {
            return XCTFail("expected a decoded ShapePath with at least one subpath")
        }
        XCTAssertTrue(subpath.closed)
        XCTAssertEqual(subpath.segments.count, 4, "move + 3 corners")
        for segment in subpath.segments.dropFirst() {
            guard case .line = segment else {
                return XCTFail("a demoted draw:polygon's points must decode as straight .line segments")
            }
        }
    }
}
