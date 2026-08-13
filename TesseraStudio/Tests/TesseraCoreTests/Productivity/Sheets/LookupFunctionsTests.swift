import XCTest
@testable import TesseraCore

/// MATCH / VLOOKUP / HLOOKUP / XLOOKUP / CHOOSE.
///
/// The lookup pair is what turns a grid into a model: without MATCH,
/// INDEX cannot address anything by key. These tests use the small
/// price table below, laid out so both the vertical and horizontal
/// forms read from the same data.
final class LookupFunctionsTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
        // B1:D4 - ascending keys in column B, labels in C, prices in D.
        let table: [[Value]] = [
            [.number(10), .string("Widget"), .number(1.50)],
            [.number(20), .string("Gadget"), .number(3.25)],
            [.number(30), .string("Doohickey"), .number(7.00)],
            [.number(40), .string("Thing"), .number(9.99)],
        ]
        for (row, cells) in table.enumerated() {
            for (col, value) in cells.enumerated() {
                engine.setValue(sheet: nil, addr: CellAddr(col: 1 + col, row: row), value: value)
            }
        }
    }

    private func value(_ formula: String) throws -> Value {
        let addr = CellAddr(col: 0, row: 6)
        try engine.setFormula(sheet: nil, addr: addr, source: formula)
        return engine.getValue(sheet: nil, addr: addr)
    }

    private func number(_ formula: String, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let v = try value(formula)
        guard case .number(let n) = v else {
            XCTFail("expected a number from \(formula), got \(v)", file: file, line: line)
            return .nan
        }
        return n
    }

    // MARK: - MATCH

    func testMatchExactFindsPosition() throws {
        XCTAssertEqual(try number("=MATCH(30, B1:B4, 0)"), 3, accuracy: 1e-9)
    }

    func testMatchExactOnTextIsCaseInsensitive() throws {
        XCTAssertEqual(try number("=MATCH(\"gadget\", C1:C4, 0)"), 2, accuracy: 1e-9)
    }

    /// Exact mode reports #N/A rather than silently returning a neighbour.
    func testMatchExactMissingIsNotAvailable() throws {
        XCTAssertEqual(try value("=MATCH(25, B1:B4, 0)"), .error(.notAvailable))
    }

    /// Approximate mode (the default) returns the largest key <= needle.
    func testMatchApproximateReturnsLargestNotExceeding() throws {
        XCTAssertEqual(try number("=MATCH(25, B1:B4, 1)"), 2, accuracy: 1e-9)
    }

    /// A needle below every key has no match at all.
    func testMatchApproximateBelowRangeIsNotAvailable() throws {
        XCTAssertEqual(try value("=MATCH(5, B1:B4, 1)"), .error(.notAvailable))
    }

    /// INDEX+MATCH is the pairing this batch exists to enable.
    func testIndexMatchReadsByKey() throws {
        XCTAssertEqual(try number("=INDEX(D1:D4, MATCH(30, B1:B4, 0))"), 7.00, accuracy: 1e-9)
    }

    // MARK: - VLOOKUP

    func testVLookupExactReturnsColumn() throws {
        XCTAssertEqual(try number("=VLOOKUP(20, B1:D4, 3, FALSE)"), 3.25, accuracy: 1e-9)
    }

    func testVLookupExactMissingIsNotAvailable() throws {
        XCTAssertEqual(try value("=VLOOKUP(25, B1:D4, 3, FALSE)"), .error(.notAvailable))
    }

    /// Approximate is the DEFAULT in Excel, and rounds the key down.
    func testVLookupDefaultsToApproximate() throws {
        XCTAssertEqual(try number("=VLOOKUP(25, B1:D4, 3)"), 3.25, accuracy: 1e-9)
    }

    func testVLookupColumnOutOfRangeIsRefError() throws {
        XCTAssertEqual(try value("=VLOOKUP(20, B1:D4, 9, FALSE)"), .error(.referenceInvalid))
    }

    func testVLookupReturnsTextColumn() throws {
        XCTAssertEqual(try value("=VLOOKUP(30, B1:D4, 2, FALSE)"), .string("Doohickey"))
    }

    // MARK: - HLOOKUP

    /// Its own horizontal strip: F1:H1 are the keys, F2:H2 the values.
    /// (Reusing the vertical table here would search B1:D1 - a row of
    /// mixed key/label/price - which is a meaningless lookup.)
    func testHLookupReadsAcrossRows() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 5, row: 0), value: .number(1))
        engine.setValue(sheet: nil, addr: CellAddr(col: 6, row: 0), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 7, row: 0), value: .number(3))
        engine.setValue(sheet: nil, addr: CellAddr(col: 5, row: 1), value: .string("one"))
        engine.setValue(sheet: nil, addr: CellAddr(col: 6, row: 1), value: .string("two"))
        engine.setValue(sheet: nil, addr: CellAddr(col: 7, row: 1), value: .string("three"))
        XCTAssertEqual(try value("=HLOOKUP(2, F1:H2, 2, FALSE)"), .string("two"))
    }

    // MARK: - XLOOKUP

    func testXLookupExactMatch() throws {
        XCTAssertEqual(try number("=XLOOKUP(30, B1:B4, D1:D4)"), 7.00, accuracy: 1e-9)
    }

    /// XLOOKUP defaults to EXACT - the headline improvement over VLOOKUP.
    func testXLookupDefaultsToExactNotApproximate() throws {
        XCTAssertEqual(try value("=XLOOKUP(25, B1:B4, D1:D4)"), .error(.notAvailable))
    }

    func testXLookupIfNotFoundIsReturned() throws {
        XCTAssertEqual(try value("=XLOOKUP(25, B1:B4, D1:D4, \"missing\")"), .string("missing"))
    }

    /// match_mode -1 falls back to the next smaller key.
    func testXLookupNextSmaller() throws {
        XCTAssertEqual(try number("=XLOOKUP(25, B1:B4, D1:D4, 0, -1)"), 3.25, accuracy: 1e-9)
    }

    /// match_mode 1 falls back to the next larger key.
    func testXLookupNextLarger() throws {
        XCTAssertEqual(try number("=XLOOKUP(25, B1:B4, D1:D4, 0, 1)"), 7.00, accuracy: 1e-9)
    }

    /// match_mode 2 is wildcard matching.
    func testXLookupWildcard() throws {
        XCTAssertEqual(try number("=XLOOKUP(\"Doo*\", C1:C4, D1:D4, 0, 2)"), 7.00, accuracy: 1e-9)
    }

    /// Mismatched lookup/return lengths are a modelling error.
    func testXLookupMismatchedArraysIsNotAvailable() throws {
        XCTAssertEqual(try value("=XLOOKUP(30, B1:B4, D1:D2)"), .error(.notAvailable))
    }

    // MARK: - CHOOSE

    func testChooseSelectsByPosition() throws {
        XCTAssertEqual(try value("=CHOOSE(2, \"a\", \"b\", \"c\")"), .string("b"))
    }

    /// Excel truncates a fractional index toward zero.
    func testChooseTruncatesFractionalIndex() throws {
        XCTAssertEqual(try value("=CHOOSE(2.9, \"a\", \"b\", \"c\")"), .string("b"))
    }

    func testChooseOutOfRangeIsNumError() throws {
        XCTAssertEqual(try value("=CHOOSE(5, \"a\", \"b\")"), .error(.numberInvalid))
    }

    // MARK: - Error handling

    /// A precedent error must reach the caller unchanged.
    func testErrorPropagatesThroughLookup() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 5, row: 0), value: .number(0))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 5, row: 1), source: "=1/F1")
        XCTAssertEqual(try value("=VLOOKUP(F2, B1:D4, 3, FALSE)"), .error(.divisionByZero))
    }
}
