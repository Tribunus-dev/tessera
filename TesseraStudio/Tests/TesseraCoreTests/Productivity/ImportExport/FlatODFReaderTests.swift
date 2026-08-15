import XCTest
@testable import TesseraCore

/// `FlatODFReader` (P1 Gate 1). Fixtures are small hand-written flat-XML
/// literals shaped to match the verified element shapes in
/// `docs/.scratch/sota-bridge-report.md` (table:formula + cached value for
/// Calc; draw:layer-set + office:binary-data for Draw; mixed-content
/// text:p for Writer) - deliberately NOT read from the shared
/// `Fixtures/RoundTrip` corpus another agent owns in this same batch, so
/// this file has no build-order dependency on it landing.
final class FlatODFReaderTests: XCTestCase {

    // MARK: - Fixtures

    static let fodsFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                      xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                      xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.spreadsheet">
      <office:body>
        <office:spreadsheet>
          <table:table table:name="Sheet1">
            <table:table-row>
              <table:table-cell table:formula="of:=[.A1]*2" office:value-type="float" office:value="20">
                <text:p>20</text:p>
              </table:table-cell>
            </table:table-row>
          </table:table>
        </office:spreadsheet>
      </office:body>
    </office:document>
    """

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
            <draw:rect draw:layer="annotations" svg:x="1cm" svg:y="1cm" svg:width="4cm" svg:height="2cm"/>
            <draw:frame svg:x="0cm" svg:y="0cm" svg:width="1cm" svg:height="1cm">
              <draw:image>
                <office:binary-data>aGVsbG8td29ybGQ=</office:binary-data>
              </draw:image>
            </draw:frame>
          </draw:page>
        </office:drawing>
      </office:body>
    </office:document>
    """

    static let fodtFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.text">
      <office:body>
        <office:text>
          <text:p>Hello <text:span text:style-name="Bold">World</text:span>!</text:p>
        </office:text>
      </office:body>
    </office:document>
    """

    private func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    // MARK: - Content type + attribute fidelity

    func testParsesSpreadsheetContentTypeAndLiveFormula() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.fodsFixture), binaryDataHandler: { _ in
            XCTFail("no binary data in this fixture")
            return URL(fileURLWithPath: "/dev/null")
        })

        XCTAssertEqual(result.contentType, .spreadsheet)
        XCTAssertEqual(result.root.name, "office:document")
        XCTAssertEqual(result.bodyChildren.map(\.name), ["office:spreadsheet"])

        let cell = try XCTUnwrap(
            result.bodyChildren.first?
                .firstElementChild(named: "table:table")?
                .firstElementChild(named: "table:table-row")?
                .firstElementChild(named: "table:table-cell")
        )
        XCTAssertEqual(cell.attributes["table:formula"], "of:=[.A1]*2")
        XCTAssertEqual(cell.attributes["office:value-type"], "float")
        XCTAssertEqual(cell.attributes["office:value"], "20")
        // The root's own xmlns:of declaration round-trips as a plain
        // attribute like any other - no special-cased namespace layer.
        XCTAssertEqual(result.root.attributes["xmlns:of"], "urn:oasis:names:tc:opendocument:xmlns:of:1.2")
    }

    func testParsesDrawingContentTypeAndCorrectlyPlacedLayerSet() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.fodgFixture), binaryDataHandler: { _ in
            URL(string: "tessera-test://blob/1")!
        })

        XCTAssertEqual(result.contentType, .drawing)
        let layerSet = try XCTUnwrap(
            result.root.firstElementChild(named: "office:master-styles")?.firstElementChild(named: "draw:layer-set")
        )
        XCTAssertEqual(layerSet.elementChildren.map { $0.attributes["draw:name"] }, ["layout", "annotations"])

        let rect = try XCTUnwrap(
            result.bodyChildren.first?
                .firstElementChild(named: "draw:page")?
                .firstElementChild(named: "draw:rect")
        )
        XCTAssertEqual(rect.attributes["draw:layer"], "annotations")
    }

    func testParsesTextContentTypeAndPreservesMixedContentOrder() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.fodtFixture), binaryDataHandler: { _ in
            XCTFail("no binary data in this fixture")
            return URL(fileURLWithPath: "/dev/null")
        })

        XCTAssertEqual(result.contentType, .text)
        let paragraph = try XCTUnwrap(
            result.bodyChildren.first?.firstElementChild(named: "text:p")
        )
        // "Hello " (text) then <text:span>World</text:span> (element)
        // then "!" (text) - order must survive, not just the set of parts.
        guard paragraph.children.count == 3 else {
            return XCTFail("expected 3 children, got \(paragraph.children.count): \(paragraph.children)")
        }
        guard case .text("Hello ") = paragraph.children[0] else {
            return XCTFail("expected leading text node, got \(paragraph.children[0])")
        }
        guard case .element(let span) = paragraph.children[1] else {
            return XCTFail("expected text:span element, got \(paragraph.children[1])")
        }
        XCTAssertEqual(span.name, "text:span")
        XCTAssertEqual(span.attributes["text:style-name"], "Bold")
        guard case .text("World") = span.children.first else {
            return XCTFail("expected text:span's text child")
        }
        guard case .text("!") = paragraph.children[2] else {
            return XCTFail("expected trailing text node, got \(paragraph.children[2])")
        }
    }

    // MARK: - Binary data externalization

    func testBinaryDataIsExternalizedNotHeldInTree() async throws {
        let reader = FlatODFReader()
        let collector = BinaryDataCollector()
        let result = try await reader.parse(data: data(Self.fodgFixture), binaryDataHandler: collector.handle)

        let binaryDataElement = try XCTUnwrap(
            result.bodyChildren.first?
                .firstElementChild(named: "draw:page")?
                .firstElementChild(named: "draw:frame")?
                .firstElementChild(named: "draw:image")?
                .firstElementChild(named: "office:binary-data")
        )

        // The base64 body must not survive as a text child of the tree...
        XCTAssertTrue(binaryDataElement.children.isEmpty)
        // ...it must instead be reachable only via the externalized URL.
        let href = try XCTUnwrap(binaryDataElement.attributes[FlatODFElement.externalizedBinaryDataKey])
        let url = try XCTUnwrap(URL(string: href))
        let bytes = try XCTUnwrap(collector.stored[url])
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello-world")
    }

    // MARK: - Errors

    func testMalformedXMLThrowsReaderError() async throws {
        let reader = FlatODFReader()
        do {
            _ = try await reader.parse(data: Data("<office:document><unterminated>".utf8), binaryDataHandler: { _ in
                URL(fileURLWithPath: "/dev/null")
            })
            XCTFail("expected malformedXML")
        } catch FlatODFReader.ReaderError.malformedXML {
            // expected
        }
    }
}

// MARK: - Test support

/// Collects externalized binary blobs under synthetic URLs so a test
/// can assert on what the reader decoded without pulling in any real
/// asset-storage subsystem. `@unchecked Sendable`: accessed serially
/// from a single `XCTest` method awaiting one actor call at a time.
final class BinaryDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data] = [:]

    var stored: [URL: Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func handle(_ data: Data) -> URL {
        let url = URL(string: "tessera-test://blob/\(UUID().uuidString)")!
        lock.lock()
        storage[url] = data
        lock.unlock()
        return url
    }
}
