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
}
