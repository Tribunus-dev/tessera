import XCTest
@testable import TesseraCore

/// Time-value-of-money and cash-flow functions.
///
/// Expected values are Excel's own documented examples, so a pass here
/// means a model built in Excel produces the same numbers in Tessera.
/// Sign convention matters as much as magnitude: money paid out is
/// negative, money received is positive.
final class FinancialFunctionsTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
    }

    /// Evaluate a formula in A1 and return the numeric result.
    private func eval(_ formula: String, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: formula)
        let value = engine.getValue(sheet: nil, addr: addr)
        guard case .number(let n) = value else {
            XCTFail("expected a number from \(formula), got \(value)", file: file, line: line)
            return .nan
        }
        return n
    }

    // MARK: - Annuity family

    /// Excel: PMT(8%/12, 10, 10000) = -1037.03. Negative because it is
    /// money leaving the borrower.
    func testPMTMatchesExcel() throws {
        let pmt = try eval("=PMT(0.08/12, 10, 10000)")
        XCTAssertEqual(pmt, -1037.0320893, accuracy: 1e-5)
    }

    /// A zero-rate loan is just the principal split evenly.
    func testPMTWithZeroRate() throws {
        let pmt = try eval("=PMT(0, 10, 10000)")
        XCTAssertEqual(pmt, -1000, accuracy: 1e-9)
    }

    /// Excel: PV(8%/12, 12*20, 500) = -59777.15.
    func testPVMatchesExcel() throws {
        let pv = try eval("=PV(0.08/12, 240, 500)")
        XCTAssertEqual(pv, -59777.1458511, accuracy: 1e-4)
    }

    /// Excel: FV(6%/12, 10, -200, -500, 1) = 2581.40.
    func testFVMatchesExcel() throws {
        let fv = try eval("=FV(0.06/12, 10, -200, -500, 1)")
        XCTAssertEqual(fv, 2581.4033741, accuracy: 1e-4)
    }

    /// Excel: NPER(12%/12, -100, -1000, 10000, 1) = 59.67.
    func testNPERMatchesExcel() throws {
        let nper = try eval("=NPER(0.01, -100, -1000, 10000, 1)")
        XCTAssertEqual(nper, 59.6738656, accuracy: 1e-5)
    }

    /// Excel: RATE(48, -200, 8000) = 0.0077 per month.
    func testRATEMatchesExcel() throws {
        let rate = try eval("=RATE(48, -200, 8000)")
        XCTAssertEqual(rate, 0.0077014, accuracy: 1e-6)
    }

    /// PMT and PV must invert each other: borrowing the PV of a payment
    /// stream reproduces that payment.
    func testPVAndPMTAreInverses() throws {
        let pv = try eval("=PV(0.05/12, 36, -300)")
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=PMT(0.05/12, 36, \(pv))")
        guard case .number(let pmt) = engine.getValue(sheet: nil, addr: addr) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(pmt, -300, accuracy: 1e-6)
    }

    // MARK: - Cash-flow family

    /// Excel: NPV(10%, -10000, 3000, 4200, 6800) = 1188.44. Note Excel
    /// discounts the FIRST value by one full period.
    func testNPVMatchesExcel() throws {
        let npv = try eval("=NPV(0.1, -10000, 3000, 4200, 6800)")
        XCTAssertEqual(npv, 1188.4434123, accuracy: 1e-5)
    }

    /// NPV over a range must equal NPV over the same values listed out.
    func testNPVOverRangeEqualsInlineArguments() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(-10000))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 1), value: .number(3000))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 2), value: .number(4200))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 3), value: .number(6800))
        let ranged = try eval("=NPV(0.1, B1:B4)")
        XCTAssertEqual(ranged, 1188.4434123, accuracy: 1e-5)
    }

    /// Excel: IRR({-70000,12000,15000,18000,21000,26000}) = 0.0866.
    func testIRRMatchesExcel() throws {
        for (row, amount) in [-70000.0, 12000, 15000, 18000, 21000, 26000].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(amount))
        }
        let irr = try eval("=IRR(B1:B6)")
        XCTAssertEqual(irr, 0.0866309, accuracy: 1e-6)
    }

    /// Discounting the cash flows at the IRR must give a zero NPV. This
    /// is the definition, and it catches an off-by-one in the exponent
    /// that a single expected value might not.
    func testIRRIsTheRateWhereNPVIsZero() throws {
        let flows: [Double] = [-70000, 12000, 15000, 18000, 21000, 26000]
        for (row, amount) in flows.enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(amount))
        }
        let irr = try eval("=IRR(B1:B6)")
        var npv = 0.0
        for (i, flow) in flows.enumerated() {
            npv += flow / pow(1 + irr, Double(i))
        }
        XCTAssertEqual(npv, 0, accuracy: 1e-4)
    }

    /// IRR needs a sign change to have a root at all.
    func testIRRWithoutSignChangeIsNumError() throws {
        for (row, amount) in [100.0, 200, 300].enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(amount))
        }
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=IRR(B1:B3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .error(.numberInvalid))
    }

    /// Excel: XIRR over the documented irregular schedule = 0.373362535.
    func testXIRRMatchesExcel() throws {
        let flows: [Double] = [-10000, 2750, 4250, 3250, 2750]
        // Excel serial dates: 2008-01-01, 03-01, 10-30, 2009-02-15, 04-01.
        let dates: [Double] = [39448, 39508, 39751, 39859, 39904]
        for (row, amount) in flows.enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(amount))
            engine.setValue(sheet: nil, addr: CellAddr(col: 2, row: row), value: .number(dates[row]))
        }
        let xirr = try eval("=XIRR(B1:B5, C1:C5)")
        XCTAssertEqual(xirr, 0.3733625, accuracy: 1e-5)
    }

    /// XNPV at the XIRR must be zero, same definitional check as IRR.
    func testXNPVAtXIRRIsZero() throws {
        let flows: [Double] = [-10000, 2750, 4250, 3250, 2750]
        let dates: [Double] = [39448, 39508, 39751, 39859, 39904]
        for (row, amount) in flows.enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(amount))
            engine.setValue(sheet: nil, addr: CellAddr(col: 2, row: row), value: .number(dates[row]))
        }
        let xirr = try eval("=XIRR(B1:B5, C1:C5)")
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=XNPV(\(xirr), B1:B5, C1:C5)")
        guard case .number(let xnpv) = engine.getValue(sheet: nil, addr: addr) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(xnpv, 0, accuracy: 1e-4)
    }

    // MARK: - Error handling

    /// A precedent's error must surface, not be replaced by #NUM!.
    func testErrorInPrecedentPropagates() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(0))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 1), source: "=1/B1")
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=PMT(B2, 10, 1000)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .error(.divisionByZero))
    }

    /// Text where a rate belongs is not silently treated as zero.
    func testNonNumericArgumentIsAnError() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=PMT(\"abc\", 10, 1000)")
        if case .number = engine.getValue(sheet: nil, addr: addr) {
            XCTFail("text should not coerce to a rate")
        }
    }
}
