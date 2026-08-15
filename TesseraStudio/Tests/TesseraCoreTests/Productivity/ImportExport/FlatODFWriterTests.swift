import XCTest
@testable import TesseraCore

/// `FlatODFWriter` (P1 Gate 1). Covers the two empirically-learned rules
/// from `docs/.scratch/sota-bridge-report.md` (xmlns:of on formula
/// documents; draw:layer-set relocated under office:master-styles) plus
/// structural round-trip fidelity through `FlatODFReader`. Fixtures are
/// this file's own small inline flat-XML literals (no dependency on the
/// shared `Fixtures/RoundTrip` corpus another agent owns this batch);
/// `BinaryDataCollector` is `FlatODFReaderTests`'s helper, reused here
/// rather than redeclared since both files are this item's own delivery.
final class FlatODFWriterTests: XCTestCase {

    // MARK: - Fixtures

    static let fodsFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                      xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.spreadsheet">
      <office:body>
        <office:spreadsheet>
          <table:named-range table:name="Total" table:cell-range-address="$Sheet1.$B$2"/>
          <table:table table:name="Sheet1">
            <table:table-row>
              <table:table-cell table:formula="of:=SUM([.A1:.A2])" office:value-type="float" office:value="30"/>
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
        </draw:layer-set>
      </office:master-styles>
      <office:body>
        <office:drawing>
          <draw:page draw:name="page1">
            <draw:frame svg:x="0cm" svg:y="0cm" svg:width="2cm" svg:height="2cm">
              <draw:image>
                <office:binary-data>ZmxhdC1vZGY=</office:binary-data>
              </draw:image>
            </draw:frame>
          </draw:page>
        </office:drawing>
      </office:body>
    </office:document>
    """

    private func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    private func failIfCalledBinaryDataResolver() -> @Sendable (URL) throws -> Data {
        { _ in
            XCTFail("no binary data expected")
            return Data()
        }
    }

    // MARK: - Rule 1: xmlns:of on formula documents

    func testInjectsXmlnsOfWhenFormulaPresentAndDeclarationMissing() async throws {
        let root = FlatODFElement(
            name: "office:document",
            attributes: [
                "office:mimetype": "application/vnd.oasis.opendocument.spreadsheet",
                "xmlns:office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
                "xmlns:table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
            ],
            children: [.element(FlatODFElement(
                name: "office:body",
                children: [.element(FlatODFElement(
                    name: "office:spreadsheet",
                    children: [.element(FlatODFElement(
                        name: "table:table",
                        children: [.element(FlatODFElement(
                            name: "table:table-row",
                            children: [.element(FlatODFElement(
                                name: "table:table-cell",
                                attributes: [
                                    "table:formula": "of:=SUM([.A1:.A2])",
                                    "office:value-type": "float",
                                    "office:value": "3",
                                ]
                            ))]
                        ))]
                    ))]
                ))]
            ))]
        )

        let writer = FlatODFWriter()
        let bytes = try await writer.write(root, binaryDataResolver: failIfCalledBinaryDataResolver())
        let reparsed = try await FlatODFReader().parse(
            data: bytes,
            binaryDataHandler: { _ in URL(fileURLWithPath: "/dev/null") }
        )

        XCTAssertEqual(reparsed.root.attributes["xmlns:of"], "urn:oasis:names:tc:opendocument:xmlns:of:1.2")
    }

    func testDoesNotOverwriteAnAlreadyDeclaredXmlnsOf() async throws {
        let root = FlatODFElement(
            name: "office:document",
            attributes: [
                "office:mimetype": "application/vnd.oasis.opendocument.spreadsheet",
                "xmlns:of": "urn:oasis:names:tc:opendocument:xmlns:of:1.2",
            ],
            children: [.element(FlatODFElement(
                name: "office:body",
                children: [.element(FlatODFElement(
                    name: "office:spreadsheet",
                    children: [.element(FlatODFElement(
                        name: "table:table",
                        attributes: ["table:formula-placeholder": "unused"],
                        children: [.element(FlatODFElement(
                            name: "table:table-row",
                            children: [.element(FlatODFElement(
                                name: "table:table-cell",
                                attributes: ["table:formula": "of:=1+1"]
                            ))]
                        ))]
                    ))]
                ))]
            ))]
        )

        let writer = FlatODFWriter()
        let bytes = try await writer.write(root, binaryDataResolver: failIfCalledBinaryDataResolver())
        let reparsed = try await FlatODFReader().parse(
            data: bytes,
            binaryDataHandler: { _ in URL(fileURLWithPath: "/dev/null") }
        )

        XCTAssertEqual(reparsed.root.attributes["xmlns:of"], "urn:oasis:names:tc:opendocument:xmlns:of:1.2")
    }

    // MARK: - Rule 2: draw:layer-set under office:master-styles

    func testRelocatesMisplacedLayerSetIntoMasterStyles() async throws {
        let misplacedLayerSet = FlatODFElement(
            name: "draw:layer-set",
            children: [.element(FlatODFElement(name: "draw:layer", attributes: ["draw:name": "annotations"]))]
        )
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.graphics"],
            children: [
                .element(FlatODFElement(name: "office:master-styles")),
                .element(FlatODFElement(
                    name: "office:body",
                    children: [.element(FlatODFElement(
                        name: "office:drawing",
                        children: [.element(FlatODFElement(
                            name: "draw:page",
                            children: [.element(misplacedLayerSet)]
                        ))]
                    ))]
                )),
            ]
        )

        let writer = FlatODFWriter()
        let bytes = try await writer.write(root, binaryDataResolver: failIfCalledBinaryDataResolver())
        let reparsed = try await FlatODFReader().parse(
            data: bytes,
            binaryDataHandler: { _ in URL(fileURLWithPath: "/dev/null") }
        )

        let relocated = try XCTUnwrap(
            reparsed.root.firstElementChild(named: "office:master-styles")?.firstElementChild(named: "draw:layer-set")
        )
        XCTAssertEqual(relocated.elementChildren.first?.attributes["draw:name"], "annotations")

        let stillUnderBody = reparsed.bodyChildren.first?
            .firstElementChild(named: "draw:page")?
            .firstElementChild(named: "draw:layer-set")
        XCTAssertNil(stillUnderBody, "layer-set must be moved, not duplicated, out of office:body")
    }

    func testLeavesCorrectlyPlacedLayerSetUntouched() async throws {
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.graphics"],
            children: [
                .element(FlatODFElement(
                    name: "office:master-styles",
                    children: [.element(FlatODFElement(
                        name: "draw:layer-set",
                        children: [.element(FlatODFElement(name: "draw:layer", attributes: ["draw:name": "layout"]))]
                    ))]
                )),
                .element(FlatODFElement(name: "office:body", children: [.element(FlatODFElement(name: "office:drawing"))])),
            ]
        )

        let writer = FlatODFWriter()
        let bytes = try await writer.write(root, binaryDataResolver: failIfCalledBinaryDataResolver())
        let reparsed = try await FlatODFReader().parse(
            data: bytes,
            binaryDataHandler: { _ in URL(fileURLWithPath: "/dev/null") }
        )

        let masterStyles = try XCTUnwrap(reparsed.root.firstElementChild(named: "office:master-styles"))
        XCTAssertEqual(masterStyles.elementChildren.filter { $0.name == "draw:layer-set" }.count, 1)
    }

    // MARK: - Structural round trip through FlatODFReader

    func testRoundTripsFodsFixtureStructurally() async throws {
        let reader = FlatODFReader()
        let writer = FlatODFWriter()
        let parsed = try await reader.parse(data: data(Self.fodsFixture), binaryDataHandler: { _ in
            XCTFail("no binary data in this fixture")
            return URL(fileURLWithPath: "/dev/null")
        })

        let bytes = try await writer.write(parsed.root, binaryDataResolver: failIfCalledBinaryDataResolver())
        let reparsed = try await reader.parse(data: bytes, binaryDataHandler: { _ in
            XCTFail("no binary data in this fixture")
            return URL(fileURLWithPath: "/dev/null")
        })

        XCTAssertEqual(reparsed.root, parsed.root, "no element or attribute should be dropped or altered by a passthrough round trip")
    }

    /// The externalized-blob `URL` is a freshly minted UUID on every
    /// parse, so it's excluded from the tree comparison and checked
    /// separately by resolving each side's URL back to bytes.
    func testRoundTripsFodgFixtureStructurallyIncludingBinaryData() async throws {
        let reader = FlatODFReader()
        let writer = FlatODFWriter()
        let firstPassCollector = BinaryDataCollector()
        let parsed = try await reader.parse(data: data(Self.fodgFixture), binaryDataHandler: firstPassCollector.handle)

        let bytes = try await writer.write(parsed.root, binaryDataResolver: { url in
            guard let resolved = firstPassCollector.stored[url] else {
                throw FlatODFWriterTests.ResolverTestError.missing(url)
            }
            return resolved
        })

        let secondPassCollector = BinaryDataCollector()
        let reparsed = try await reader.parse(data: bytes, binaryDataHandler: secondPassCollector.handle)

        XCTAssertEqual(
            Self.strippingExternalizedHrefs(from: parsed.root),
            Self.strippingExternalizedHrefs(from: reparsed.root),
            "no element or attribute should be dropped or altered (aside from the externalized-blob URL itself)"
        )

        let originalHref = try XCTUnwrap(Self.firstBinaryDataHref(in: parsed.root))
        let roundTrippedHref = try XCTUnwrap(Self.firstBinaryDataHref(in: reparsed.root))
        let originalURL = try XCTUnwrap(URL(string: originalHref))
        let roundTrippedURL = try XCTUnwrap(URL(string: roundTrippedHref))
        let originalBytes = try XCTUnwrap(firstPassCollector.stored[originalURL])
        let roundTrippedBytes = try XCTUnwrap(secondPassCollector.stored[roundTrippedURL])
        XCTAssertEqual(originalBytes, roundTrippedBytes)
    }

    func testBinaryDataResolverFailureSurfacesAsWriterError() async throws {
        let reader = FlatODFReader()
        let writer = FlatODFWriter()
        let collector = BinaryDataCollector()
        let parsed = try await reader.parse(data: data(Self.fodgFixture), binaryDataHandler: collector.handle)

        do {
            _ = try await writer.write(parsed.root, binaryDataResolver: { url in
                throw FlatODFWriterTests.ResolverTestError.missing(url)
            })
            XCTFail("expected binaryDataUnavailable")
        } catch FlatODFWriter.WriterError.binaryDataUnavailable {
            // expected
        }
    }

    // MARK: - Test support

    private enum ResolverTestError: Error {
        case missing(URL)
    }

    private static func strippingExternalizedHrefs(from element: FlatODFElement) -> FlatODFElement {
        var element = element
        element.attributes.removeValue(forKey: FlatODFElement.externalizedBinaryDataKey)
        element.children = element.children.map { node in
            guard case .element(let child) = node else { return node }
            return .element(strippingExternalizedHrefs(from: child))
        }
        return element
    }

    private static func firstBinaryDataHref(in element: FlatODFElement) -> String? {
        if element.name == "office:binary-data", let href = element.attributes[FlatODFElement.externalizedBinaryDataKey] {
            return href
        }
        for child in element.elementChildren {
            if let found = firstBinaryDataHref(in: child) { return found }
        }
        return nil
    }
}
