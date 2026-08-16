import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ODGBridgeFilterTests
//
// Ungated coverage of ODGBridgeFilter's PURE mapping halves
// (`flatODFTree(for:)` for export, `drawing(fromFodgData:reader:)` for
// import) - neither touches `soffice`. This is the doctrine rule 11
// "ungated shadow" of ODGConnectorWireFormatProbeTests.swift's live
// round trip: the exact same draw:type <-> ConnectorStyle mapping
// contract, exercised here against hand-authored fixtures / direct tree
// inspection so a plain `swift test` covers the wiring logic even
// without LibreOffice installed.
//
// Contract source: ODGBridgeFilter.swift's own doc comments
// (design-refinement doc section 4, Draw cluster, item 1.18) plus the
// empirically-confirmed draw:type vocabulary documented on
// `connectorAttributes`/`drawType(for:)`/`connectorStyle(fromDrawType:)`
// - re-verified live in ODGConnectorWireFormatProbeTests.swift.

final class ODGBridgeFilterTests: DoctrineTestCase {

    // MARK: - Export mapping (flatODFTree) - connector draw:type

    private func rect(id: UUID = UUID(), x: Double = 0, y: Double = 0) -> Shape {
        Shape(id: id, kind: .rect, geometry: ShapeGeometry(x: x, y: y, width: 20, height: 20))
    }

    func testFlatODFTreeWritesLinesForStraightConnector() {
        let a = rect(), b = rect(x: 100)
        var connector = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        connector.connector = ConnectorInfo(start: .attached(shapeID: a.id, gluePointIndex: 1), end: .attached(shapeID: b.id, gluePointIndex: 3), style: .straight)
        let drawing = Drawing.makeBlank().insertingShape(a).insertingShape(b).insertingShape(connector)

        let element = connectorElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertEqual(element?.attributes["draw:type"], "lines")
    }

    func testFlatODFTreeWritesCurveForCurvedConnector() {
        let a = rect(), b = rect(x: 100)
        var connector = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        connector.connector = ConnectorInfo(start: .attached(shapeID: a.id, gluePointIndex: 1), end: .attached(shapeID: b.id, gluePointIndex: 3), style: .curved)
        let drawing = Drawing.makeBlank().insertingShape(a).insertingShape(b).insertingShape(connector)

        let element = connectorElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertEqual(element?.attributes["draw:type"], "curve")
    }

    func testFlatODFTreeWritesStandardExplicitlyForElbowConnector() {
        let a = rect(), b = rect(x: 100)
        var connector = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        connector.connector = ConnectorInfo(start: .attached(shapeID: a.id, gluePointIndex: 1), end: .attached(shapeID: b.id, gluePointIndex: 3), style: .elbow)
        let drawing = Drawing.makeBlank().insertingShape(a).insertingShape(b).insertingShape(connector)

        let element = connectorElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertEqual(element?.attributes["draw:type"], "standard")
    }

    // MARK: - Export mapping - layer-set placement (the FlatODFWriter rule 2 contract)

    func testFlatODFTreePlacesLayerSetUnderOfficeMasterStylesWhenDrawingHasLayers() {
        let drawing = Drawing.makeBlank().addingLayer(DrawLayer(name: "Background"))
        let root = ODGBridgeFilter.flatODFTree(for: drawing)
        let layerSet = root.firstElementChild(named: "office:master-styles")?.firstElementChild(named: "draw:layer-set")
        XCTAssertNotNil(layerSet, "draw:layer-set must be a child of office:master-styles per the empirically-confirmed FlatODFWriter rule")
        XCTAssertEqual(layerSet?.elementChildren.first?.attributes["draw:name"], "Background")
    }

    func testFlatODFTreeOmitsLayerSetEntirelyWhenDrawingHasNoLayers() {
        let drawing = Drawing.makeBlank()
        let root = ODGBridgeFilter.flatODFTree(for: drawing)
        XCTAssertNil(root.firstElementChild(named: "office:master-styles"))
    }

    // MARK: - Import mapping (drawing(fromFodgData:reader:)) - draw:type -> ConnectorStyle
    //
    // Hand-authored fodg fixtures mirroring exactly the values
    // ODGConnectorWireFormatProbeTests.swift's live soffice round trip
    // re-confirmed today: "lines" -> .straight, "curve" -> .curved,
    // "standard" or a MISSING attribute -> .elbow (the schema default).

    private func fodgFixture(connectorDrawTypeAttribute: String?) -> Data {
        let typeAttr = connectorDrawTypeAttribute.map { " draw:type=\"\($0)\"" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.graphics">
        <office:body><office:drawing><draw:page draw:name="page1">
        <draw:rect draw:id="id1" svg:x="0cm" svg:y="0cm" svg:width="2cm" svg:height="2cm"/>
        <draw:rect draw:id="id2" svg:x="5cm" svg:y="5cm" svg:width="2cm" svg:height="2cm"/>
        <draw:connector draw:id="id3"\(typeAttr) draw:start-shape="id1" draw:start-glue-point="1" draw:end-shape="id2" draw:end-glue-point="3" svg:x1="2cm" svg:y1="1cm" svg:x2="5cm" svg:y2="6cm"/>
        </draw:page></office:drawing></office:body>
        </office:document>
        """
        return xml.data(using: .utf8)!
    }

    func testImportMapsLinesDrawTypeToStraightConnectorStyle() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fodgFixture(connectorDrawTypeAttribute: "lines"), reader: FlatODFReader())
        let connector = drawing.shapes.first { $0.kind == .connector }
        XCTAssertEqual(connector?.connector?.style, .straight)
    }

    func testImportMapsCurveDrawTypeToCurvedConnectorStyle() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fodgFixture(connectorDrawTypeAttribute: "curve"), reader: FlatODFReader())
        let connector = drawing.shapes.first { $0.kind == .connector }
        XCTAssertEqual(connector?.connector?.style, .curved)
    }

    func testImportMapsMissingDrawTypeToElbowConnectorStyle() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fodgFixture(connectorDrawTypeAttribute: nil), reader: FlatODFReader())
        let connector = drawing.shapes.first { $0.kind == .connector }
        XCTAssertEqual(connector?.connector?.style, .elbow)
    }

    func testImportMapsStandardDrawTypeToElbowConnectorStyle() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fodgFixture(connectorDrawTypeAttribute: "standard"), reader: FlatODFReader())
        let connector = drawing.shapes.first { $0.kind == .connector }
        XCTAssertEqual(connector?.connector?.style, .elbow)
    }

    func testImportMapsAnUnrecognizedDrawTypeToElbowConnectorStyleRatherThanThrowing() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fodgFixture(connectorDrawTypeAttribute: "bogus"), reader: FlatODFReader())
        let connector = drawing.shapes.first { $0.kind == .connector }
        XCTAssertEqual(connector?.connector?.style, .elbow)
    }

    // MARK: - Helper

    private func connectorElement(in root: FlatODFElement) -> FlatODFElement? {
        root.firstElementChild(named: "office:body")?
            .firstElementChild(named: "office:drawing")?
            .firstElementChild(named: "draw:page")?
            .elementChildren.first { $0.name == "draw:connector" }
    }

    // MARK: - .bezier export mapping (flatODFTree) - item 2.3
    //
    // Ungated shadow (doctrine rule 11) of
    // ODGBezierPathWireFormatProbeTests.swift's live soffice round trip -
    // exercises the PURE `flatODFTree`/`drawing(fromFodgData:)` halves
    // directly, no soffice involved.

    private func pathElement(in root: FlatODFElement) -> FlatODFElement? {
        root.firstElementChild(named: "office:body")?
            .firstElementChild(named: "office:drawing")?
            .firstElementChild(named: "draw:page")?
            .elementChildren.first { $0.name == "draw:path" }
    }

    private func bezierShape(_ path: ShapePath, width: Double = 40, height: Double = 30) -> Shape {
        Shape(kind: .bezier, geometry: ShapeGeometry(x: 10, y: 10, width: width, height: height), path: path)
    }

    func testFlatODFTreeWritesADrawPathElementForABezierShape() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 40, y: 30))], closed: false),
        ])
        let drawing = Drawing.makeBlank().insertingShape(bezierShape(path))
        let element = pathElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertNotNil(element, "a .bezier shape must export as a real draw:path element, not draw:rect")
    }

    func testFlatODFTreeWritesSvgDMatchingThePathsOwnPathData() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 40, y: 30))], closed: false),
        ])
        let drawing = Drawing.makeBlank().insertingShape(bezierShape(path))
        let element = pathElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertEqual(element?.attributes["svg:d"], path.pathData)
    }

    func testFlatODFTreeWritesAViewBoxMatchingTheShapesOwnGeometryExtent() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0))])])
        let drawing = Drawing.makeBlank().insertingShape(bezierShape(path, width: 40, height: 30))
        let element = pathElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertEqual(element?.attributes["svg:viewBox"], "0 0 40.0 30.0")
    }

    func testFlatODFTreePreservesTheKindMarkerForABezierShape() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0))])])
        let drawing = Drawing.makeBlank().insertingShape(bezierShape(path))
        let element = pathElement(in: ODGBridgeFilter.flatODFTree(for: drawing))
        XCTAssertEqual(element?.attributes["draw:name"], "ts-kind:bezier")
    }

    // MARK: - .bezier import mapping (drawing(fromFodgData:)) - item 2.3

    private func fodgFixture(pathElement: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.graphics">
        <office:body><office:drawing><draw:page draw:name="page1">
        \(pathElement)
        </draw:page></office:drawing></office:body>
        </office:document>
        """
        return xml.data(using: .utf8)!
    }

    func testImportReadsARealDrawPathElementIntoAShapePath() async throws {
        let fixture = fodgFixture(pathElement: """
        <draw:path draw:id="id1" draw:name="ts-kind:bezier" svg:x="0cm" svg:y="0cm" svg:width="4cm" svg:height="3cm" svg:viewBox="0 0 400 300" svg:d="M0 0 L400 0 L400 300 Z"/>
        """)
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fixture, reader: FlatODFReader())
        let shape = drawing.shapes.first { $0.kind == .bezier }
        XCTAssertNotNil(shape?.path)
        XCTAssertEqual(shape?.path?.subpaths.first?.segments.count, 3)
    }

    func testImportRescalesPathDataFromTheElementsOwnViewBoxIntoLocalGeometrySpace() async throws {
        // viewBox (0 0 4001 3001) does NOT match svg:width/height (4cm/3cm,
        // which parseLength converts to ~113.4/85.0 points) - the import
        // must rescale svg:d's raw numbers into that LOCAL point space,
        // not read them verbatim (this is exactly the fix-up a real
        // soffice round trip needs - see ShapePath.rescaled(from:to:)).
        let fixture = fodgFixture(pathElement: """
        <draw:path draw:id="id1" draw:name="ts-kind:bezier" svg:x="0cm" svg:y="0cm" svg:width="4cm" svg:height="3cm" svg:viewBox="0 0 4001 3001" svg:d="M0 0 L4001 3001"/>
        """)
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fixture, reader: FlatODFReader())
        let shape = drawing.shapes.first { $0.kind == .bezier }
        guard let end = shape?.path?.subpaths.first?.segments.last?.endPoint else {
            return XCTFail("expected a decoded end point")
        }
        // Rescaled endpoint should land at exactly (geometry.width, geometry.height).
        XCTAssertEqual(end.x, shape!.geometry.width, accuracy: 0.01)
        XCTAssertEqual(end.y, shape!.geometry.height, accuracy: 0.01)
    }

    func testImportRecoversABezierShapeDemotedToDrawPolygonViaItsKindMarker() async throws {
        // The soffice-demotion fallback (confirmed empirically - see
        // ODGBezierPathWireFormatProbeTests.swift): a closed, curve-free
        // .bezier can come back as draw:polygon instead of draw:path.
        // draw:name's marker still resolves the KIND; draw:points is
        // read as a closed straight-line subpath.
        let fixture = fodgFixture(pathElement: """
        <draw:polygon draw:id="id1" draw:name="ts-kind:bezier" svg:x="0cm" svg:y="0cm" svg:width="4cm" svg:height="3cm" svg:viewBox="0 0 4001 3001" draw:points="0,0 4001,0 4001,3001 0,3001"/>
        """)
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fixture, reader: FlatODFReader())
        let shape = drawing.shapes.first { $0.kind == .bezier }
        XCTAssertNotNil(shape, "the marker must still resolve .bezier even though the element is draw:polygon")
        XCTAssertEqual(shape?.path?.subpaths.count, 1)
        XCTAssertTrue(shape?.path?.subpaths.first?.closed ?? false)
        XCTAssertEqual(shape?.path?.subpaths.first?.segments.count, 4)
        for segment in shape?.path?.subpaths.first?.segments.dropFirst() ?? [] {
            guard case .line = segment else { return XCTFail("demoted polygon points must decode as straight .line segments") }
        }
    }

    func testForeignDrawPathWithoutAKindMarkerStructurallyInfersBezier() async throws {
        // A real (non-Tessera-authored) document's own draw:path, with
        // no "ts-kind:" marker - structural inference (shapeKind(for:)'s
        // fallback) must still recover .bezier rather than silently
        // dropping the shape, matching this file's "malformed/foreign
        // data degrades" convention for every other structurally-
        // inferable kind.
        let fixture = fodgFixture(pathElement: """
        <draw:path draw:id="id1" svg:x="0cm" svg:y="0cm" svg:width="4cm" svg:height="3cm" svg:viewBox="0 0 400 300" svg:d="M0 0 L400 300"/>
        """)
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: fixture, reader: FlatODFReader())
        XCTAssertEqual(drawing.shapes.first?.kind, .bezier)
    }

    func testBezierRoundTripsThroughTheFilterPurePairWithoutSoffice() async throws {
        // export -> parse (via flatODFTree + drawing(fromFodgData:), no
        // soffice conversion) - the pure half of the bridge, matching
        // this file's own header comment's "PURE mapping halves" scope.
        //
        // Tolerance-based, NOT bit-exact: `boxAttributes`/`geometry(for:
        // kind:)` round-trip `Shape.geometry` through `formatLength`'s
        // own documented "4 decimal places, sub-micron precision" cm
        // conversion (an existing, deliberate trade-off shared by EVERY
        // shape kind in this bridge, not something new to `.bezier`) -
        // `svg:viewBox`'s own numbers stay exact, but the LOCAL target
        // box `shapePath(for:boxGeometry:)` rescales into is built from
        // that re-parsed (sub-micron-off) geometry, so the decoded path
        // carries the same sub-micron-scale error. A tight tolerance
        // (0.01pt, ~30x the documented sub-micron bound) still catches
        // any REAL mapping bug while tolerating this known rounding.
        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 40, y: 0)),
                    .cubic(control1: ShapePathPoint(x: 40, y: 15), control2: ShapePathPoint(x: 20, y: 30), end: ShapePathPoint(x: 0, y: 30)),
                ],
                closed: true
            ),
        ])
        let original = Drawing.makeBlank().insertingShape(bezierShape(path))
        let root = ODGBridgeFilter.flatODFTree(for: original)
        let fodgData = try await FlatODFWriter().write(root) { url in
            throw ODGBridgeFilter.FilterError.malformedDocument("unexpected binary reference: \(url)")
        }
        let roundTripped = try await ODGBridgeFilter.drawing(fromFodgData: fodgData, reader: FlatODFReader())
        guard let decoded = roundTripped.shapes.first(where: { $0.kind == .bezier })?.path else {
            return XCTFail("expected a decoded .bezier shape with a path")
        }
        XCTAssertEqual(decoded.subpaths.count, path.subpaths.count)
        XCTAssertEqual(decoded.subpaths.first?.closed, path.subpaths.first?.closed)
        XCTAssertEqual(decoded.subpaths.first?.segments.count, path.subpaths.first?.segments.count)
        for (decodedSegment, originalSegment) in zip(decoded.subpaths.first?.segments ?? [], path.subpaths.first?.segments ?? []) {
            XCTAssertEqual(decodedSegment.endPoint.x, originalSegment.endPoint.x, accuracy: 0.01)
            XCTAssertEqual(decodedSegment.endPoint.y, originalSegment.endPoint.y, accuracy: 0.01)
        }
    }
}
