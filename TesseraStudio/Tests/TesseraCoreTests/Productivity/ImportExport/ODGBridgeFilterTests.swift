import XCTest
@testable import TesseraCore

/// `ODGBridgeFilter` (P1 item 1.18). The fodg <-> `Drawing` mapping is
/// pure (`ODGBridgeFilter.drawing(fromFodgData:reader:)` /
/// `ODGBridgeFilter.flatODFTree(for:)`) and tested directly, without
/// `soffice`, the same way `CalcBridgeFilterTests` tests its CSV
/// serializer; the actual .odg <-> .fodg conversion is a real
/// integration test, skipped when LibreOffice isn't installed -
/// matching `WriterBridgeFilterTests`' `XCTSkipIf` pattern exactly.
final class ODGBridgeFilterTests: XCTestCase {

    // MARK: - Fixtures

    /// One plain `draw:rect` (no `draw:name` marker - exercises
    /// `shapeKind(for:)`'s structural-inference fallback for a foreign
    /// document), on a named layer.
    static let fodgFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
                      xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.graphics">
      <office:master-styles>
        <draw:layer-set>
          <draw:layer draw:name="layout"/>
          <draw:layer draw:name="annotations"/>
        </draw:layer-set>
      </office:master-styles>
      <office:body>
        <office:drawing>
          <draw:page draw:name="page1">
            <draw:rect draw:layer="annotations" svg:x="1cm" svg:y="2cm" svg:width="4cm" svg:height="3cm"/>
            <draw:ellipse svg:x="0cm" svg:y="0cm" svg:width="2cm" svg:height="2cm"/>
          </draw:page>
        </office:drawing>
      </office:body>
    </office:document>
    """

    /// A `ts-kind:` marker recovering `.arrow` from a `draw:line`
    /// element, which by structural inference alone would map to
    /// `.line` - exercises the marker-first branch of `shapeKind(for:)`.
    static let markedArrowFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
                      xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.graphics">
      <office:body>
        <office:drawing>
          <draw:page draw:name="page1">
            <draw:line draw:name="ts-kind:arrow" svg:x1="0cm" svg:y1="1cm" svg:x2="2cm" svg:y2="1cm"/>
          </draw:page>
        </office:drawing>
      </office:body>
    </office:document>
    """

    /// Two rects plus a connector referencing them by `draw:id`, one of
    /// them a FORWARD reference (the connector names "shapeB" before
    /// shapeB appears in document order) - exercises the two-pass
    /// draw:id -> Shape.id resolution.
    static let connectorFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
                      xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.graphics">
      <office:body>
        <office:drawing>
          <draw:page draw:name="page1">
            <draw:rect draw:id="shapeA" svg:x="0cm" svg:y="0cm" svg:width="2cm" svg:height="2cm"/>
            <draw:connector draw:start-shape="shapeA" draw:start-glue-point="1"
                             draw:end-shape="shapeB" draw:end-glue-point="3"/>
            <draw:rect draw:id="shapeB" svg:x="5cm" svg:y="5cm" svg:width="2cm" svg:height="2cm"/>
          </draw:page>
        </office:drawing>
      </office:body>
    </office:document>
    """

    private func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    // MARK: - Import (pure, no soffice)

    func testDrawingFromFodgDataMapsShapesByElementNameAndLayer() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: data(Self.fodgFixture), reader: FlatODFReader())

        XCTAssertEqual(drawing.shapeCount, 2)
        XCTAssertEqual(drawing.layers.map(\.name), ["layout", "annotations"])

        let rect = try XCTUnwrap(drawing.shapes.first { $0.kind == .rect })
        XCTAssertEqual(rect.geometry.x, 1 * 72.0 / 2.54, accuracy: 0.01)
        XCTAssertEqual(rect.geometry.y, 2 * 72.0 / 2.54, accuracy: 0.01)
        XCTAssertEqual(rect.geometry.width, 4 * 72.0 / 2.54, accuracy: 0.01)
        XCTAssertEqual(rect.geometry.height, 3 * 72.0 / 2.54, accuracy: 0.01)
        let annotationsLayer = try XCTUnwrap(drawing.layers.first { $0.name == "annotations" })
        XCTAssertEqual(rect.layerID, annotationsLayer.id)

        let ellipse = try XCTUnwrap(drawing.shapes.first { $0.kind == .ellipse })
        XCTAssertNil(ellipse.layerID)
    }

    func testDrawingFromFodgDataRecoversMarkedKindViaDrawName() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: data(Self.markedArrowFixture), reader: FlatODFReader())

        XCTAssertEqual(drawing.shapeCount, 1)
        let arrow = try XCTUnwrap(drawing.shapes.first)
        XCTAssertEqual(arrow.kind, .arrow)
        // A horizontal line (y1 == y2) reconstructs with height 0 - see
        // `ODGBridgeFilter.lineAttributes`'s doc comment.
        XCTAssertEqual(arrow.geometry.height, 0, accuracy: 0.001)
        XCTAssertEqual(arrow.geometry.width, 2 * 72.0 / 2.54, accuracy: 0.01)
    }

    func testDrawingFromFodgDataResolvesConnectorAcrossForwardReference() async throws {
        let drawing = try await ODGBridgeFilter.drawing(fromFodgData: data(Self.connectorFixture), reader: FlatODFReader())

        XCTAssertEqual(drawing.shapeCount, 3)
        let shapeA = try XCTUnwrap(drawing.shapes.first { $0.geometry.x == 0 })
        let shapeB = try XCTUnwrap(drawing.shapes.first { $0.geometry.x > 100 })
        let connector = try XCTUnwrap(drawing.shapes.first { $0.kind == .connector })

        XCTAssertEqual(connector.connector?.start, .attached(shapeID: shapeA.id, gluePointIndex: 1))
        XCTAssertEqual(connector.connector?.end, .attached(shapeID: shapeB.id, gluePointIndex: 3))
    }

    func testDrawingFromFodgDataThrowsOnNonDrawingContentType() async throws {
        let notDrawing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                          office:version="1.3"
                          office:mimetype="application/vnd.oasis.opendocument.text">
          <office:body>
            <office:text><text:p>Not a drawing</text:p></office:text>
          </office:body>
        </office:document>
        """
        do {
            _ = try await ODGBridgeFilter.drawing(fromFodgData: data(notDrawing), reader: FlatODFReader())
            XCTFail("expected malformedDocument")
        } catch ODGBridgeFilter.FilterError.malformedDocument {
            // expected
        }
    }

    func testDrawingFromFodgDataThrowsOnMissingDrawPage() async throws {
        let noPage = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                          xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
                          office:version="1.3"
                          office:mimetype="application/vnd.oasis.opendocument.graphics">
          <office:body>
            <office:drawing/>
          </office:body>
        </office:document>
        """
        do {
            _ = try await ODGBridgeFilter.drawing(fromFodgData: data(noPage), reader: FlatODFReader())
            XCTFail("expected malformedDocument")
        } catch ODGBridgeFilter.FilterError.malformedDocument {
            // expected
        }
    }

    // MARK: - Export tree (pure, no soffice)

    func testFlatODFTreeMarksKindAndWritesGeometryAndLayer() throws {
        let layer = DrawLayer(name: "front")
        let shape = Shape(
            kind: .star,
            geometry: ShapeGeometry(x: 10, y: 20, width: 30, height: 40),
            layerID: layer.id
        )
        var drawing = Drawing(title: "T", layers: [layer])
        drawing = drawing.insertingShape(shape)

        let root = ODGBridgeFilter.flatODFTree(for: drawing)
        XCTAssertEqual(root.name, "office:document")

        let layerSet = try XCTUnwrap(root.firstElementChild(named: "office:master-styles")?.firstElementChild(named: "draw:layer-set"))
        XCTAssertEqual(layerSet.elementChildren.map { $0.attributes["draw:name"] }, ["front"])

        let page = try XCTUnwrap(
            root.firstElementChild(named: "office:body")?
                .firstElementChild(named: "office:drawing")?
                .firstElementChild(named: "draw:page")
        )
        XCTAssertEqual(page.elementChildren.count, 1)
        let element = try XCTUnwrap(page.elementChildren.first)
        XCTAssertEqual(element.name, "draw:polygon")
        XCTAssertEqual(element.attributes["draw:name"], "ts-kind:star")
        XCTAssertEqual(element.attributes["draw:layer"], "front")
        XCTAssertEqual(ODGBridgeFilter.parseLength(element.attributes["svg:x"]) ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(ODGBridgeFilter.parseLength(element.attributes["svg:width"]) ?? -1, 30, accuracy: 0.01)
    }

    func testFlatODFTreeOmitsMasterStylesWhenNoLayers() {
        let drawing = Drawing.makeBlank(title: "T")
        let root = ODGBridgeFilter.flatODFTree(for: drawing)
        XCTAssertNil(root.firstElementChild(named: "office:master-styles"))
    }

    // MARK: - Round trip (real soffice, skipped when unavailable)

    func testExportThenImportRoundTripsShapeCountAndKind() async throws {
        let filter = ODGBridgeFilter()
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        var drawing = Drawing.makeBlank(title: "RoundTrip")
        drawing = drawing.insertingShape(Shape(kind: .rect, geometry: ShapeGeometry(x: 10, y: 10, width: 100, height: 50)))
        drawing = drawing.insertingShape(Shape(kind: .ellipse, geometry: ShapeGeometry(x: 20, y: 20, width: 60, height: 60)))

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-odg-filter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let odgURL = workDir.appendingPathComponent("drawing.odg")

        try await filter.export(drawing, to: odgURL)
        let reimported = try await filter.`import`(from: odgURL)

        XCTAssertEqual(reimported.shapeCount, drawing.shapeCount)
        XCTAssertEqual(Set(reimported.shapes.map(\.kind)), Set(drawing.shapes.map(\.kind)))
    }

    /// `draw:type`'s real ODF enumeration only has three values -
    /// "standard" (the schema default), "lines", and "curve" - confirmed
    /// empirically against real soffice output (see `connectorAttributes`'s
    /// doc comment). This asserts the non-default cases actually survive
    /// a real `soffice` round trip rather than every imported connector
    /// silently degrading to `.elbow`.
    func testExportThenImportRoundTripsConnectorStyle() async throws {
        let filter = ODGBridgeFilter()
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        let rectA = Shape(kind: .rect, geometry: ShapeGeometry(x: 10, y: 10, width: 100, height: 50))
        let rectB = Shape(kind: .rect, geometry: ShapeGeometry(x: 200, y: 200, width: 100, height: 50))
        let curvedConnector = Shape(
            kind: .connector,
            geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0),
            connector: ConnectorInfo(
                start: .attached(shapeID: rectA.id, gluePointIndex: 1),
                end: .attached(shapeID: rectB.id, gluePointIndex: 3),
                style: .curved
            )
        )
        let straightConnector = Shape(
            kind: .connector,
            geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0),
            connector: ConnectorInfo(start: .free(x: 5, y: 5), end: .free(x: 60, y: 90), style: .straight)
        )
        var drawing = Drawing.makeBlank(title: "ConnectorStyleRoundTrip")
        drawing = drawing.insertingShape(rectA)
        drawing = drawing.insertingShape(rectB)
        drawing = drawing.insertingShape(curvedConnector)
        drawing = drawing.insertingShape(straightConnector)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-odg-filter-connector-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let odgURL = workDir.appendingPathComponent("connectors.odg")

        try await filter.export(drawing, to: odgURL)
        let reimported = try await filter.`import`(from: odgURL)

        let reimportedConnectors = reimported.shapes.filter { $0.kind == .connector }
        XCTAssertEqual(reimportedConnectors.count, 2)
        XCTAssertTrue(reimportedConnectors.contains { $0.connector?.style == .curved })
        XCTAssertTrue(reimportedConnectors.contains { $0.connector?.style == .straight })
    }
}
