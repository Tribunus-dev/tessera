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
