import XCTest
@testable import TesseraCore

/// `LibreOfficeConverter` (P0 0.8/0.9): real integration tests against
/// an actual `soffice` binary - skipped gracefully when LibreOffice
/// isn't installed (matching `GitReadOnlyTests`' `gitAvailable()`
/// pattern for the same reason: this is what a dev machine with the
/// dependency verifies, not something to fake with a stub).
final class LibreOfficeConverterTests: XCTestCase {

    func testResolveSofficePathFindsAnExecutable() {
        // Not gated on isAvailable - this assertion should hold
        // regardless (it just checks the resolver returns SOME path
        // string, even the not-installed fallback).
        XCTAssertFalse(LibreOfficeConverter.resolveSofficePath().isEmpty)
    }

    func testConvertHTMLToODT() async throws {
        let converter = LibreOfficeConverter()
        try await XCTSkipIf(!converter.isAvailable, "soffice not installed")

        let html = Data("<html><body><h1>Hello Bridge</h1></body></html>".utf8)
        let odt = try await converter.convert(data: html, sourceExtension: "html", targetExtension: "odt")
        XCTAssertGreaterThan(odt.count, 0)
        // An .odt is a ZIP; the local file header magic bytes confirm
        // we got a real archive back, not an error page or empty file.
        XCTAssertEqual(odt.prefix(2), Data([0x50, 0x4B]))
    }

    func testConvertRoundTripODTToDocxToODT() async throws {
        let converter = LibreOfficeConverter()
        try await XCTSkipIf(!converter.isAvailable, "soffice not installed")

        let html = Data("<html><body><p>Round trip</p></body></html>".utf8)
        let odt = try await converter.convert(data: html, sourceExtension: "html", targetExtension: "odt")
        let docx = try await converter.convert(data: odt, sourceExtension: "odt", targetExtension: "docx")
        XCTAssertGreaterThan(docx.count, 0)
        XCTAssertEqual(docx.prefix(2), Data([0x50, 0x4B]), "docx is also a ZIP container")
    }

    /// Proves the claim its name makes, rather than just checking the
    /// output looks like a valid archive: converts the .ods BACK to
    /// CSV and checks Calc computed a number, not the literal text
    /// `=A1*2` - LibreOffice only does that for a cell it actually
    /// treated as a live formula on the way in. No header row (a
    /// single data row, A1/B1 only) to avoid an earlier mistake in
    /// this same investigation: a formula referencing a header cell's
    /// TEXT computes `#VALUE!`, which would make this test pass for
    /// the wrong reason (any non-literal output "looks like" a formula
    /// ran, even a broken one).
    func testConvertCSVToODSPreservesFormulaAsLiveFormula() async throws {
        let converter = LibreOfficeConverter()
        try await XCTSkipIf(!converter.isAvailable, "soffice not installed")

        let csv = Data("10,=A1*2\n".utf8)
        let ods = try await converter.convert(data: csv, sourceExtension: "csv", targetExtension: "ods")
        XCTAssertEqual(ods.prefix(2), Data([0x50, 0x4B]))

        let roundTripped = try await converter.convert(data: ods, sourceExtension: "ods", targetExtension: "csv")
        let text = String(data: roundTripped, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("20"), "expected A1*2 (10*2) to have computed to 20, got: \(text)")
        XCTAssertFalse(text.contains("A1*2"), "the formula's literal text must not survive if it was treated as live")
    }

    func testUnsupportedConversionThrowsRatherThanHanging() async throws {
        let converter = LibreOfficeConverter()
        try await XCTSkipIf(!converter.isAvailable, "soffice not installed")

        // A Writer document has no sensible spreadsheet export - LO
        // itself refuses this (confirmed empirically), which should
        // surface as a thrown error, not a hang or a silently empty file.
        let html = Data("<html><body><p>Not a spreadsheet</p></body></html>".utf8)
        let odt = try await converter.convert(data: html, sourceExtension: "html", targetExtension: "odt")
        do {
            _ = try await converter.convert(data: odt, sourceExtension: "odt", targetExtension: "xlsx")
            XCTFail("expected a conversion error for Writer -> Calc format")
        } catch {
            // Any thrown error is acceptable here - the point is it
            // doesn't hang and doesn't silently succeed.
        }
    }
}
