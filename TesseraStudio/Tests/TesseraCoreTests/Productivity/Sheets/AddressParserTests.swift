import XCTest
@testable import TesseraCore

/// ``AddressParser`` turns an A1-style string into a typed reference.
/// It is the fallback the formula parser uses to tell a bare cell
/// reference from a named range, so when it rejects everything, every
/// `A1` in a formula is treated as a named range instead.
final class AddressParserTests: XCTestCase {

    func testParsesPlainCell() throws {
        let ref = try AddressParser.parseCell("A1")
        XCTAssertEqual(ref.addr.col, 0)
        XCTAssertEqual(ref.addr.row, 0)
        XCTAssertNil(ref.sheet)
    }

    func testParsesMultiLetterColumnAndMultiDigitRow() throws {
        let ref = try AddressParser.parseCell("AB12")
        XCTAssertEqual(ref.addr.col, CellAddr.colNumber(for: "AB"))
        XCTAssertEqual(ref.addr.row, 11)
    }

    func testParsesAbsoluteReference() throws {
        let ref = try AddressParser.parseCell("$A$1")
        XCTAssertEqual(ref.addr.col, 0)
        XCTAssertEqual(ref.addr.row, 0)
        XCTAssertTrue(ref.colAbsolute)
        XCTAssertTrue(ref.rowAbsolute)
    }

    /// A bare, non-absolute reference must NOT come back marked
    /// absolute. The `($?)` capture group always participates in a
    /// successful match (it can match zero characters), so checking
    /// only whether the group had a position in the match - rather
    /// than whether it actually captured a "$" - marked every parsed
    /// cell absolute, "A1" included.
    func testPlainReferenceIsNotMarkedAbsolute() throws {
        let ref = try AddressParser.parseCell("A1")
        XCTAssertFalse(ref.colAbsolute, "A1 has no $ on the column")
        XCTAssertFalse(ref.rowAbsolute, "A1 has no $ on the row")
    }

    /// The two dollar signs are independent - each must reflect only
    /// its own presence, not "some $ appeared somewhere in the string."
    func testMixedAbsoluteReferenceTracksEachDollarIndependently() throws {
        let colOnly = try AddressParser.parseCell("$A1")
        XCTAssertTrue(colOnly.colAbsolute)
        XCTAssertFalse(colOnly.rowAbsolute)

        let rowOnly = try AddressParser.parseCell("A$1")
        XCTAssertFalse(rowOnly.colAbsolute)
        XCTAssertTrue(rowOnly.rowAbsolute)
    }

    /// A sheet-qualified reference with no `$` must be just as
    /// unabsolute as an unqualified one - the sheet prefix and the
    /// absolute flags are unrelated parts of the grammar.
    func testSheetQualifiedPlainReferenceIsNotMarkedAbsolute() throws {
        let ref = try AddressParser.parseCell("Sheet2!C3")
        XCTAssertFalse(ref.colAbsolute)
        XCTAssertFalse(ref.rowAbsolute)
    }

    func testParsesSheetQualifiedReference() throws {
        let ref = try AddressParser.parseCell("Sheet2!C3")
        XCTAssertEqual(ref.sheet, "Sheet2")
        XCTAssertEqual(ref.addr.col, 2)
        XCTAssertEqual(ref.addr.row, 2)
    }

    func testRejectsNonCellName() {
        // A genuine named range must NOT parse as a cell, or the formula
        // parser would never route it to named-range resolution.
        XCTAssertThrowsError(try AddressParser.parseCell("TotalRevenue"))
    }

    func testParsesRange() throws {
        let range = try AddressParser.parseRange("A1:B5")
        XCTAssertEqual(range.topLeft.col, 0)
        XCTAssertEqual(range.topLeft.row, 0)
        XCTAssertEqual(range.bottomRight.col, 1)
        XCTAssertEqual(range.bottomRight.row, 4)
    }
}
