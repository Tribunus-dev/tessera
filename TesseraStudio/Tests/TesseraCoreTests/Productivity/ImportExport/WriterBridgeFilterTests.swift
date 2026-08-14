import XCTest
@testable import TesseraCore

/// `WriterBridgeFilter` (P0 0.8). Real integration tests, skipped when
/// LibreOffice isn't installed - see `LibreOfficeConverterTests`.
final class WriterBridgeFilterTests: XCTestCase {

    func testSupportedImportFormatsExcludesFormatsTesseraFormatBridgeAlreadyHandles() {
        XCTAssertEqual(Set(WriterBridgeFilter.supportedImportFormats), ["odt", "rtf"])
        XCTAssertFalse(WriterBridgeFilter.supportedImportFormats.contains("docx"))
        XCTAssertFalse(WriterBridgeFilter.supportedImportFormats.contains("html"))
    }

    func testUnsupportedFormatThrowsWithoutTouchingSoffice() async throws {
        let filter = WriterBridgeFilter()
        do {
            _ = try await filter.importDocument(data: Data(), format: "pptx")
            XCTFail("expected unsupportedFormat")
        } catch WriterBridgeFilter.FilterError.unsupportedFormat(let format) {
            XCTAssertEqual(format, "pptx")
        }
    }

    /// The odt->docx conversion half is this type's own deliverable
    /// and is asserted directly; the docx->DocumentAST half delegates
    /// to `TesseraFormatBridge`'s pre-existing python-docx path, which
    /// this test environment may not have fully provisioned (missing
    /// `python-docx` and/or its own `lxml` dependency) - a real but
    /// separate gap, not a WriterBridgeFilter defect, so any failure
    /// that looks like a missing Python module is treated as a skip
    /// rather than a failure. `TesseraFormatBridge` only classifies
    /// SOME missing-library messages as `.missingLibrary` (matching on
    /// "no converter"/"not found"/"not installed"); a raw
    /// `ModuleNotFoundError` traceback like "No module named 'lxml'"
    /// doesn't match those substrings and surfaces as a generic
    /// `.subprocessError` instead - both are checked here.
    func testImportODTProducesADocumentAST() async throws {
        let filter = WriterBridgeFilter()
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        let converter = LibreOfficeConverter()
        let html = Data("<html><body><h1>Bridge Test</h1><p>Some body text.</p></body></html>".utf8)
        let odt = try await converter.convert(data: html, sourceExtension: "html", targetExtension: "odt")

        do {
            let ast = try await filter.importDocument(data: odt, format: "odt")
            XCTAssertFalse(ast.blocks.isEmpty, "expected at least one block from the converted document")
        } catch TesseraFormatBridge.FormatBridgeError.missingLibrary(let detail) {
            throw XCTSkip("TesseraFormatBridge's docx importer is missing a dependency in this environment: \(detail)")
        } catch TesseraFormatBridge.FormatBridgeError.pythonNotFound {
            throw XCTSkip("python3 not found for TesseraFormatBridge in this environment")
        } catch TesseraFormatBridge.FormatBridgeError.subprocessError(_, let stderr) where stderr.contains("No module named") {
            throw XCTSkip("TesseraFormatBridge's docx importer is missing a dependency in this environment: \(stderr)")
        }
    }
}
