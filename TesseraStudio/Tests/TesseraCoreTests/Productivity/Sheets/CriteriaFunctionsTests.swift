import XCTest
@testable import TesseraCore

/// Multi-criteria aggregates and SUMPRODUCT, over a small ledger:
/// B = region, C = product, D = amount.
final class CriteriaFunctionsTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
        let rows: [(String, String, Double)] = [
            ("North", "Widget", 100),
            ("South", "Widget", 200),
            ("North", "Gadget", 300),
            ("South", "Gadget", 400),
            ("North", "Widget", 500),
        ]
        for (row, entry) in rows.enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .string(entry.0))
            engine.setValue(sheet: nil, addr: CellAddr(col: 2, row: row), value: .string(entry.1))
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(entry.2))
        }
    }

    private func value(_ formula: String) throws -> Value {
        let addr = CellAddr(col: 0, row: 8)
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

    // MARK: - SUMIFS

    func testSumifsSingleCriterion() throws {
        XCTAssertEqual(try number("=SUMIFS(D1:D5, B1:B5, \"North\")"), 900, accuracy: 1e-9)
    }

    /// The point of the IFS family: every condition must hold.
    func testSumifsTwoCriteriaAreAnded() throws {
        XCTAssertEqual(try number("=SUMIFS(D1:D5, B1:B5, \"North\", C1:C5, \"Widget\")"), 600, accuracy: 1e-9)
    }

    func testSumifsComparisonCriterion() throws {
        XCTAssertEqual(try number("=SUMIFS(D1:D5, D1:D5, \">250\")"), 1200, accuracy: 1e-9)
    }

    /// Excel criteria are case-insensitive.
    func testSumifsIsCaseInsensitive() throws {
        XCTAssertEqual(try number("=SUMIFS(D1:D5, B1:B5, \"north\")"), 900, accuracy: 1e-9)
    }

    func testSumifsNoMatchesIsZero() throws {
        XCTAssertEqual(try number("=SUMIFS(D1:D5, B1:B5, \"East\")"), 0, accuracy: 1e-9)
    }

    /// A criteria range of the wrong length is a modelling error.
    func testSumifsMismatchedRangeLengthIsNotAvailable() throws {
        XCTAssertEqual(try value("=SUMIFS(D1:D5, B1:B3, \"North\")"), .error(.notAvailable))
    }

    // MARK: - COUNTIFS / AVERAGEIFS

    func testCountifsCountsMatchingRows() throws {
        XCTAssertEqual(try number("=COUNTIFS(B1:B5, \"North\", C1:C5, \"Widget\")"), 2, accuracy: 1e-9)
    }

    func testAverageifsAveragesMatchingRows() throws {
        XCTAssertEqual(try number("=AVERAGEIFS(D1:D5, B1:B5, \"North\")"), 300, accuracy: 1e-9)
    }

    /// Averaging an empty selection is a division by zero, not 0.
    func testAverageifsNoMatchesIsDivisionByZero() throws {
        XCTAssertEqual(try value("=AVERAGEIFS(D1:D5, B1:B5, \"East\")"), .error(.divisionByZero))
    }

    // MARK: - Wildcards

    func testCriteriaSupportsStarWildcard() throws {
        XCTAssertEqual(try number("=SUMIFS(D1:D5, C1:C5, \"Wid*\")"), 800, accuracy: 1e-9)
    }

    func testCriteriaSupportsQuestionMarkWildcard() throws {
        // "?adget" matches Gadget but not Widget.
        XCTAssertEqual(try number("=SUMIFS(D1:D5, C1:C5, \"?adget\")"), 700, accuracy: 1e-9)
    }

    // MARK: - SUMPRODUCT

    func testSumproductMultipliesElementwise() throws {
        // 100*1 + 200*2 + 300*3 + 400*4 + 500*5 = 5500
        for row in 0..<5 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 4, row: row), value: .number(Double(row + 1)))
        }
        XCTAssertEqual(try number("=SUMPRODUCT(D1:D5, E1:E5)"), 5500, accuracy: 1e-9)
    }

    /// A single array is just its sum.
    func testSumproductWithOneArrayIsASum() throws {
        XCTAssertEqual(try number("=SUMPRODUCT(D1:D5)"), 1500, accuracy: 1e-9)
    }

    func testSumproductMismatchedLengthsIsNotAvailable() throws {
        XCTAssertEqual(try value("=SUMPRODUCT(D1:D5, B1:B3)"), .error(.notAvailable))
    }

    /// Text entries count as zero rather than poisoning the result.
    func testSumproductTreatsTextAsZero() throws {
        XCTAssertEqual(try number("=SUMPRODUCT(D1:D5, B1:B5)"), 0, accuracy: 1e-9)
    }
}
