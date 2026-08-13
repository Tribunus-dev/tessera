import XCTest
@testable import TesseraCore

/// Operator precedence and associativity.
///
/// These are the most basic guarantees a formula engine makes, and they
/// had no coverage: the precedence table was transcribed from Excel's
/// documentation, which numbers 1 as the TIGHTEST binding, while the
/// Pratt parser treats the highest number as tightest. Every
/// relationship was inverted, so `=1+2*3` returned 9.
final class OperatorPrecedenceTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
    }

    private func number(_ formula: String, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: formula)
        let v = engine.getValue(sheet: nil, addr: addr)
        guard case .number(let n) = v else {
            XCTFail("expected a number from \(formula), got \(v)", file: file, line: line)
            return .nan
        }
        return n
    }

    // MARK: - Precedence

    func testMultiplicationBindsTighterThanAddition() throws {
        XCTAssertEqual(try number("=1+2*3"), 7, accuracy: 1e-9)
    }

    func testMultiplicationBindsTighterOnTheLeftToo() throws {
        XCTAssertEqual(try number("=2*3+1"), 7, accuracy: 1e-9)
    }

    func testDivisionBindsTighterThanSubtraction() throws {
        XCTAssertEqual(try number("=10-6/2"), 7, accuracy: 1e-9)
    }

    func testPowerBindsTighterThanMultiplication() throws {
        XCTAssertEqual(try number("=2*3^2"), 18, accuracy: 1e-9)
    }

    func testParenthesesOverridePrecedence() throws {
        XCTAssertEqual(try number("=(1+2)*3"), 9, accuracy: 1e-9)
    }

    /// The exact shape that exposed the bug: a division followed by an
    /// addition, where the addition was being pulled into the divisor.
    func testDivisionFollowedByAddition() throws {
        XCTAssertEqual(try number("=10/4+10"), 12.5, accuracy: 1e-9)
    }

    // MARK: - Associativity

    func testSubtractionIsLeftAssociative() throws {
        XCTAssertEqual(try number("=10-4-3"), 3, accuracy: 1e-9)
    }

    func testDivisionIsLeftAssociative() throws {
        XCTAssertEqual(try number("=100/10/2"), 5, accuracy: 1e-9)
    }

    /// Excel's `^` groups right to left: 2^(3^2) = 2^9 = 512.
    func testPowerIsRightAssociative() throws {
        XCTAssertEqual(try number("=2^3^2"), 512, accuracy: 1e-9)
    }

    // MARK: - Comparison and concatenation

    /// Arithmetic binds tighter than comparison.
    func testArithmeticBindsTighterThanComparison() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=1+1=2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .bool(true))
    }

    /// Arithmetic binds tighter than concatenation, so the numbers add
    /// before they are joined as text.
    func testArithmeticBindsTighterThanConcat() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=\"n=\"&1+2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .string("n=3"))
    }

    // MARK: - With cells

    func testPrecedenceHoldsAcrossCellReferences() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 1), value: .number(3))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 2), value: .number(4))
        XCTAssertEqual(try number("=B1+B2*B3"), 14, accuracy: 1e-9)
    }
}
