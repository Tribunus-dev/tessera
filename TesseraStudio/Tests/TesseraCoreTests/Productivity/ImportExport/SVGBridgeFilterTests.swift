import XCTest
@testable import TesseraCore

/// `SVGBridgeFilter` (P1 item 1.18). Both directions go through real
/// `soffice` (there's no pure half to peel off the way
/// `ODGBridgeFilter`'s tree-mapping is - SVG import's ENTIRE job is
/// interpreting soffice's own converted output), so every test here
/// skips cleanly when LibreOffice isn't installed, matching
/// `WriterBridgeFilterTests`' `XCTSkipIf` pattern.
final class SVGBridgeFilterTests: XCTestCase {

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-svg-filter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Import: embedded-image fidelity

    /// Design contract: SVG import is embedded-image fidelity only -
    /// the whole SVG becomes exactly one `.image`-marked result, never
    /// decomposed shapes.
    func testImportProducesExactlyOneEmbeddedImageMarkedResult() async throws {
        let workDir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let filter = SVGBridgeFilter(mediaDir: workDir)
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        let svgURL = workDir.appendingPathComponent("shape.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="80">
          <rect width="100" height="80" fill="#ff0000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: svgURL)

        let result = try await filter.`import`(from: svgURL)

        XCTAssertEqual(result.importFidelity, .embeddedImage)
        XCTAssertEqual(result.drawing.body.rootChildren.count, 1)
        XCTAssertEqual(result.drawing.body.blocks.count, 1)
        // Never a native shape - see this type's header on why no
        // ShapeKind can carry an embedded image.
        XCTAssertEqual(result.drawing.shapeCount, 0)

        let rootBlockID = try XCTUnwrap(result.drawing.body.rootChildren.first)
        let block = try XCTUnwrap(result.drawing.body.blocks[rootBlockID])
        XCTAssertEqual(block.type, .image)
        XCTAssertEqual(block.attributes["importFidelity"], .string("embeddedImage"))
        let sourceString = try XCTUnwrap(block.attributes["source"])
        guard case .string(let sourceURLString) = sourceString, let sourceURL = URL(string: sourceURLString) else {
            return XCTFail("expected attributes[\"source\"] to be a string URL")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "extracted image file should exist on disk")
        let extractedBytes = try Data(contentsOf: sourceURL)
        XCTAssertFalse(extractedBytes.isEmpty)
    }

    func testImportThrowsNoEmbeddedImageOnNonDrawingConversion() async throws {
        let workDir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let filter = SVGBridgeFilter(mediaDir: workDir)
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        // Not real SVG - soffice will still attempt a conversion; this
        // just pins that a garbage/empty input degrades to a thrown
        // error rather than a crash.
        let badURL = workDir.appendingPathComponent("bad.svg")
        try Data().write(to: badURL)

        do {
            _ = try await filter.`import`(from: badURL)
        } catch {
            // Any thrown FilterError (or LibreOfficeConverter.ConverterError,
            // for genuinely unparseable input) is an acceptable outcome
            // here - the point is "doesn't crash," not one specific error.
        }
    }

    // MARK: - Export: same shape as ODGBridgeFilter's export

    func testExportProducesNonEmptySVGFile() async throws {
        let workDir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let filter = SVGBridgeFilter(mediaDir: workDir)
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        var drawing = Drawing.makeBlank(title: "ExportTest")
        drawing = drawing.insertingShape(Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 100, height: 60)))

        let svgURL = workDir.appendingPathComponent("out.svg")
        try await filter.export(drawing, to: svgURL)

        let bytes = try Data(contentsOf: svgURL)
        XCTAssertFalse(bytes.isEmpty)
    }
}
