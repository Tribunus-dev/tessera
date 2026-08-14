import XCTest
@testable import TesseraCore

/// ``SheetProtection`` itself and its plumbing through ``Sheet``. The
/// store-level enforcement (``SheetStore/setCell`` refusing a locked
/// sheet) needs a live data layer and is exercised by the DB-gated
/// integration test alongside the rest of ``SheetStoreTests``; this
/// file covers what's testable without one.
final class SheetProtectionTests: XCTestCase {

    func testUnprotectedIsTheDefault() {
        XCTAssertFalse(SheetProtection.unprotected.isLocked)
        XCTAssertNil(SheetProtection.unprotected.reason)
        XCTAssertEqual(SheetProtection(), .unprotected)
    }

    func testEquality() {
        XCTAssertEqual(SheetProtection(isLocked: true, reason: "x"), SheetProtection(isLocked: true, reason: "x"))
        XCTAssertNotEqual(SheetProtection(isLocked: true), SheetProtection(isLocked: false))
        XCTAssertNotEqual(
            SheetProtection(isLocked: true, reason: "x"),
            SheetProtection(isLocked: true, reason: "y")
        )
    }

    // MARK: - Sheet.effectiveProtection

    private func blankSheet() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 2, cols: 2)
    }

    /// A sheet written before `protection` existed - or any sheet
    /// nobody has locked - must read as unprotected, not as "unknown."
    func testMissingProtectionReadsAsUnprotected() {
        var sheet = blankSheet()
        XCTAssertNil(sheet.protection)
        XCTAssertEqual(sheet.effectiveProtection, .unprotected)

        sheet.protection = SheetProtection(isLocked: true, reason: "published")
        XCTAssertEqual(sheet.effectiveProtection.isLocked, true)
        XCTAssertEqual(sheet.effectiveProtection.reason, "published")
    }

    /// A sheet's protection state survives the document's own
    /// serialization - the only way it actually persists.
    func testProtectionSurvivesDocumentRoundTrip() throws {
        var sheet = blankSheet()
        sheet.protection = SheetProtection(isLocked: true, reason: "Q4 close")
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        XCTAssertEqual(restored.protection, sheet.protection)
        XCTAssertTrue(restored.effectiveProtection.isLocked)
    }

    /// Codable round-trip at the bare struct level, independent of
    /// `Sheet`.
    func testProtectionJSONRoundTrip() throws {
        let original = SheetProtection(isLocked: true, reason: "locked for review")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetProtection.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
