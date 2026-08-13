import XCTest
@testable import TesseraCore

/// Dispersion, order statistics and correlation.
///
/// The sample/population split is the thing to get right: STDEV divides
/// by n-1 and STDEVP by n, and picking the wrong one produces a
/// plausible number rather than an obvious error.
final class StatisticsFunctionsTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
        // B1:B5 = 2, 4, 4, 4, 5.
        // Mean 3.8; deviations -1.8, .2, .2, .2, 1.2; squares sum to 4.8.
        // So population variance is 4.8/5 = 0.96 and sample variance is
        // 4.8/4 = 1.2. Every expectation below is derived from those.
        for (row, n) in [2.0, 4, 4, 4, 5].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(n))
        }
    }

    private func value(_ formula: String) throws -> Value {
        let addr = CellAddr(col: 0, row: 0)
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

    // MARK: - Dispersion

    /// Population: 4.8 / 5.
    func testStdevpIsPopulationStandardDeviation() throws {
        XCTAssertEqual(try number("=STDEVP(B1:B5)"), sqrt(0.96), accuracy: 1e-9)
    }

    /// Sample divides by n-1, giving a larger value than the population.
    func testStdevIsSampleStandardDeviation() throws {
        XCTAssertEqual(try number("=STDEV(B1:B5)"), sqrt(1.2), accuracy: 1e-9)
        XCTAssertGreaterThan(try number("=STDEV(B1:B5)"), try number("=STDEVP(B1:B5)"))
    }

    func testVarpIsPopulationVariance() throws {
        XCTAssertEqual(try number("=VARP(B1:B5)"), 0.96, accuracy: 1e-9)
    }

    func testVarIsSampleVariance() throws {
        XCTAssertEqual(try number("=VAR(B1:B5)"), 1.2, accuracy: 1e-9)
    }

    /// The sample statistics are undefined for a single value.
    func testSampleVarianceOfOneValueIsNumError() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: 0), value: .number(7))
        XCTAssertEqual(try value("=VAR(D1)"), .error(.numberInvalid))
    }

    /// The population statistics are fine with one value.
    func testPopulationVarianceOfOneValueIsZero() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: 0), value: .number(7))
        XCTAssertEqual(try number("=VARP(D1)"), 0, accuracy: 1e-9)
    }

    // MARK: - MEDIAN

    func testMedianOddCount() throws {
        XCTAssertEqual(try number("=MEDIAN(B1:B5)"), 4, accuracy: 1e-9)
    }

    /// An even count averages the two middle values.
    func testMedianEvenCount() throws {
        for (row, n) in [1.0, 2, 3, 4].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(n))
        }
        XCTAssertEqual(try number("=MEDIAN(D1:D4)"), 2.5, accuracy: 1e-9)
    }

    /// The median does not depend on input order.
    func testMedianIgnoresOrder() throws {
        for (row, n) in [5.0, 1, 3].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(n))
        }
        XCTAssertEqual(try number("=MEDIAN(D1:D3)"), 3, accuracy: 1e-9)
    }

    // MARK: - Order statistics

    func testPercentileEndpoints() throws {
        XCTAssertEqual(try number("=PERCENTILE(B1:B5, 0)"), 2, accuracy: 1e-9)
        XCTAssertEqual(try number("=PERCENTILE(B1:B5, 1)"), 5, accuracy: 1e-9)
    }

    /// The median is the 50th percentile.
    func testPercentileMidpointMatchesMedian() throws {
        XCTAssertEqual(try number("=PERCENTILE(B1:B5, 0.5)"), try number("=MEDIAN(B1:B5)"), accuracy: 1e-9)
    }

    /// Interpolates between ranks: over 1..5, the 25th percentile is 2.
    func testPercentileInterpolates() throws {
        for (row, n) in [1.0, 2, 3, 4, 5].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(n))
        }
        XCTAssertEqual(try number("=PERCENTILE(D1:D5, 0.25)"), 2, accuracy: 1e-9)
        XCTAssertEqual(try number("=PERCENTILE(D1:D5, 0.125)"), 1.5, accuracy: 1e-9)
    }

    func testPercentileRejectsOutOfRangeK() throws {
        XCTAssertEqual(try value("=PERCENTILE(B1:B5, 1.5)"), .error(.numberInvalid))
    }

    func testLargeAndSmall() throws {
        XCTAssertEqual(try number("=LARGE(B1:B5, 1)"), 5, accuracy: 1e-9)
        XCTAssertEqual(try number("=LARGE(B1:B5, 2)"), 4, accuracy: 1e-9)
        XCTAssertEqual(try number("=SMALL(B1:B5, 1)"), 2, accuracy: 1e-9)
    }

    func testLargeRejectsRankBeyondTheData() throws {
        XCTAssertEqual(try value("=LARGE(B1:B5, 99)"), .error(.numberInvalid))
    }

    // MARK: - CORREL

    /// A perfect positive linear relationship is 1.
    func testCorrelPerfectPositive() throws {
        for (row, n) in [1.0, 2, 3, 4].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(n))
            engine.setValue(sheet: nil, addr: CellAddr(col: 4, row: row), value: .number(n * 3 + 1))
        }
        XCTAssertEqual(try number("=CORREL(D1:D4, E1:E4)"), 1.0, accuracy: 1e-9)
    }

    /// A perfect inverse relationship is -1.
    func testCorrelPerfectNegative() throws {
        for (row, n) in [1.0, 2, 3, 4].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(n))
            engine.setValue(sheet: nil, addr: CellAddr(col: 4, row: row), value: .number(-n))
        }
        XCTAssertEqual(try number("=CORREL(D1:D4, E1:E4)"), -1.0, accuracy: 1e-9)
    }

    /// A constant series has no variance, so there is nothing to correlate.
    func testCorrelWithConstantSeriesIsDivisionByZero() throws {
        for row in 0..<4 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: row), value: .number(Double(row)))
            engine.setValue(sheet: nil, addr: CellAddr(col: 4, row: row), value: .number(5))
        }
        XCTAssertEqual(try value("=CORREL(D1:D4, E1:E4)"), .error(.divisionByZero))
    }

    func testCorrelMismatchedLengthsIsNotAvailable() throws {
        XCTAssertEqual(try value("=CORREL(B1:B5, B1:B2)"), .error(.notAvailable))
    }

    // MARK: - Errors

    func testErrorPropagatesThroughStatistics() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 5, row: 0), value: .number(0))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 5, row: 1), source: "=1/F1")
        XCTAssertEqual(try value("=STDEV(F2)"), .error(.divisionByZero))
    }
}
