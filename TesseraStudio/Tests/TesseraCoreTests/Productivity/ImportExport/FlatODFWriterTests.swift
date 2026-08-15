import XCTest
import Foundation
@testable import TesseraCore

// MARK: - FlatODFWriterTests
//
// Ungated coverage of FlatODFWriter's two empirically-learned rules
// (its own doc comment, sourced from sota-bridge-report.md): rule 1
// (xmlns:of declared on the root when any table:formula attribute is
// present anywhere in the tree) and rule 2 (draw:layer-set must be a
// child of office:master-styles). This is the rule-11 ungated shadow of
// ODGConnectorWireFormatProbeTests.swift's live-soffice rule-2
// re-verification, and stands alone (no live-soffice pairing exists
// yet for rule 1 in this cluster's file list, since rule 1 is a
// Calc/fods concern - CalcBridgeFilter is in this cluster's ownership
// but a dedicated formula-namespace probe was not reached this pass;
// logged in the findings file) - both exercised here directly against
// the real `FlatODFWriter.write(_:binaryDataResolver:)` production
// code, not a reimplementation of its rules.

/// Free function, not a bound instance method: `write(_:binaryDataResolver:)`
/// requires an `@Sendable` closure, and a bound method reference to an
/// `XCTestCase` instance would implicitly capture `self` (not provably
/// `Sendable`) - matching the inline-closure-literal convention every
/// production call site in this codebase already uses for this same
/// parameter (e.g. `ODGBridgeFilter.export`'s `{ referenced in throw ... }`).
private func noBinaryData(_ url: URL) throws -> Data {
    throw FlatODFWriter.WriterError.binaryDataUnavailable(url: url, underlying: "no binary data in this fixture")
}

final class FlatODFWriterTests: DoctrineTestCase {

    // MARK: - Rule 1: xmlns:of on formula documents

    func testWriteDeclaresXmlnsOfOnRootWhenATableFormulaAttributeIsPresentAnywhere() async throws {
        let cell = FlatODFElement(name: "table:table-cell", attributes: ["table:formula": "of:=SUM(A1:A2)"])
        let row = FlatODFElement(name: "table:table-row", children: [.element(cell)])
        let table = FlatODFElement(name: "table:table", children: [.element(row)])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])

        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let xml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(xml.contains("xmlns:of=\"urn:oasis:names:tc:opendocument:xmlns:of:1.2\""), "root must declare xmlns:of when any table:formula attribute is present in the tree")
    }

    func testWriteDoesNotDeclareXmlnsOfWhenNoFormulaIsPresent() async throws {
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [
            .element(FlatODFElement(name: "office:body")),
        ])
        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let xml = String(data: data, encoding: .utf8)!
        XCTAssertFalse(xml.contains("xmlns:of="))
    }

    func testWriteDoesNotOverwriteAnExplicitlyPresentXmlnsOfDeclaration() async throws {
        let cell = FlatODFElement(name: "table:table-cell", attributes: ["table:formula": "of:=SUM(A1:A2)"])
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["xmlns:of": "urn:custom:already-present"],
            children: [.element(FlatODFElement(name: "office:body", children: [.element(cell)]))]
        )
        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let xml = String(data: data, encoding: .utf8)!
        XCTAssertTrue(xml.contains("xmlns:of=\"urn:custom:already-present\""))
    }

    // MARK: - Rule 2: draw:layer-set under office:master-styles

    func testWriteRelocatesALayerSetFoundUnderOfficeBodyToOfficeMasterStyles() async throws {
        // normalizeLayerSetPlacement only relocates INTO an
        // office:master-styles element that already exists somewhere in
        // the tree ("no master-styles container at all... out of scope
        // to synthesize a whole container" - the function's own doc
        // comment) - so this fixture includes an (empty) master-styles
        // sibling alongside the misplaced layer-set, matching the shape
        // a real imported/hand-assembled tree would actually have.
        let layerSet = FlatODFElement(name: "draw:layer-set", children: [
            .element(FlatODFElement(name: "draw:layer", attributes: ["draw:name": "Misplaced"])),
        ])
        let drawingElement = FlatODFElement(name: "office:drawing", children: [.element(layerSet)])
        let body = FlatODFElement(name: "office:body", children: [.element(drawingElement)])
        let emptyMasterStyles = FlatODFElement(name: "office:master-styles")
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.graphics"],
            children: [.element(emptyMasterStyles), .element(body)]
        )

        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let xml = String(data: data, encoding: .utf8)!

        // Must appear inside office:master-styles, not office:body.
        XCTAssertTrue(xml.contains("<office:master-styles><draw:layer-set>"), "a misplaced draw:layer-set must be relocated under office:master-styles")
        XCTAssertFalse(xml.contains("<office:drawing><draw:layer-set>"), "draw:layer-set must not remain a child of office:drawing/office:body")
    }

    func testWriteLeavesAMisplacedLayerSetUntouchedWhenNoMasterStylesContainerExistsAnywhere() async throws {
        // SUSPECTED GAP, not wrapped as XCTExpectFailure: this is the
        // function's OWN documented, deliberate scope limit ("out of
        // scope to synthesize a whole container"), not a contract
        // violation - ODGBridgeFilter.flatODFTree(for:) never exercises
        // this path because it always constructs office:master-styles
        // itself up front when a drawing has layers (see
        // ODGBridgeFilterTests.testFlatODFTreePlacesLayerSetUnderOfficeMasterStylesWhenDrawingHasLayers).
        // Documented here so the boundary is pinned, not assumed.
        let layerSet = FlatODFElement(name: "draw:layer-set", children: [
            .element(FlatODFElement(name: "draw:layer", attributes: ["draw:name": "Stranded"])),
        ])
        let drawingElement = FlatODFElement(name: "office:drawing", children: [.element(layerSet)])
        let body = FlatODFElement(name: "office:body", children: [.element(drawingElement)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.graphics"], children: [.element(body)])

        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let xml = String(data: data, encoding: .utf8)!

        XCTAssertFalse(xml.contains("office:master-styles"), "no master-styles container is synthesized when none exists in the input tree")
        XCTAssertTrue(xml.contains("<office:drawing><draw:layer-set>"), "with no legal home to move it to, the layer-set is left exactly where it was")
    }

    func testWritePreservesALayerSetAlreadyCorrectlyPlaced() async throws {
        let layerSet = FlatODFElement(name: "draw:layer-set", children: [
            .element(FlatODFElement(name: "draw:layer", attributes: ["draw:name": "Correct"])),
        ])
        let masterStyles = FlatODFElement(name: "office:master-styles", children: [.element(layerSet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.graphics"], children: [
            .element(masterStyles),
            .element(FlatODFElement(name: "office:body")),
        ])

        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let xml = String(data: data, encoding: .utf8)!
        XCTAssertTrue(xml.contains("<office:master-styles><draw:layer-set><draw:layer draw:name=\"Correct\"/></draw:layer-set></office:master-styles>"))
    }

    // MARK: - Round trip through FlatODFReader (write then re-parse)

    func testWrittenTreeReparsesToTheSameStructureThroughFlatODFReader() async throws {
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.graphics", "office:version": "1.3"],
            children: [.element(FlatODFElement(name: "office:body", children: [
                .element(FlatODFElement(name: "office:drawing", children: [
                    .element(FlatODFElement(name: "draw:page", attributes: ["draw:name": "page1"])),
                ])),
            ]))]
        )

        let data = try await FlatODFWriter().write(root, binaryDataResolver: noBinaryData)
        let parsed = try await FlatODFReader().parse(data: data) { _ in URL(fileURLWithPath: "/dev/null") }

        XCTAssertEqual(parsed.contentType, .drawing)
        XCTAssertNotNil(parsed.root.firstElementChild(named: "office:body")?.firstElementChild(named: "office:drawing")?.firstElementChild(named: "draw:page"))
    }
}
