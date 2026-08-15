import XCTest
@testable import TesseraCore

/// `PDFExportBridge` (P1 item 1.18). Export-only, real `soffice`
/// integration test, skipped when LibreOffice isn't installed -
/// matching `WriterBridgeFilterTests`' `XCTSkipIf` pattern.
final class PDFExportBridgeTests: XCTestCase {

    func testFilterErrorDescriptionIncludesDetail() {
        let error = PDFExportBridge.FilterError.malformedDocument("boom")
        XCTAssertEqual(error.errorDescription, "PDFExportBridge: boom")
    }

    func testExportProducesNonEmptyPDFFile() async throws {
        let bridge = PDFExportBridge()
        try await XCTSkipIf(!bridge.isAvailable, "soffice not installed")

        var drawing = Drawing.makeBlank(title: "PDFExportTest")
        drawing = drawing.insertingShape(Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 200, height: 100)))
        drawing = drawing.insertingShape(Shape(kind: .ellipse, geometry: ShapeGeometry(x: 20, y: 20, width: 80, height: 80)))

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-pdf-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let pdfURL = workDir.appendingPathComponent("out.pdf")

        try await bridge.export(drawing, to: pdfURL)

        let bytes = try Data(contentsOf: pdfURL)
        XCTAssertFalse(bytes.isEmpty)
        // A real PDF - not required by this item's test contract
        // (just "produces a non-empty file"), but cheap to check and
        // catches a soffice mis-conversion that produces garbage.
        XCTAssertTrue(bytes.starts(with: Data("%PDF-".utf8)))
    }

    func testExportOfEmptyDrawingStillProducesAValidPDF() async throws {
        let bridge = PDFExportBridge()
        try await XCTSkipIf(!bridge.isAvailable, "soffice not installed")

        let drawing = Drawing.makeBlank(title: "Empty")
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-pdf-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let pdfURL = workDir.appendingPathComponent("empty.pdf")

        try await bridge.export(drawing, to: pdfURL)

        let bytes = try Data(contentsOf: pdfURL)
        XCTAssertFalse(bytes.isEmpty)
    }
}
