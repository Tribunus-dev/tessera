import XCTest
@testable import TesseraCore

/// LET and LAMBDA.
///
/// Both bind NAMES rather than values, so neither can be an ordinary
/// registry entry: their arguments must reach the evaluator unevaluated.
/// LET names an intermediate result so a long formula computes it once;
/// LAMBDA turns an expression into a reusable function.
final class LetLambdaTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
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

    // MARK: - LET

    func testLetBindsASingleName() throws {
        XCTAssertEqual(try number("=LET(x, 5, x*2)"), 10, accuracy: 1e-9)
    }

    func testLetBindsSeveralNames() throws {
        XCTAssertEqual(try number("=LET(x, 5, y, 3, x*y)"), 15, accuracy: 1e-9)
    }

    /// A later binding can use an earlier one - that is the whole point
    /// of naming intermediate steps.
    func testLetBindingCanReferToAnEarlierBinding() throws {
        XCTAssertEqual(try number("=LET(x, 5, y, x+1, y*2)"), 12, accuracy: 1e-9)
    }

    func testLetBindingCanReferenceCells() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(7))
        XCTAssertEqual(try number("=LET(v, B1, v*3)"), 21, accuracy: 1e-9)
    }

    /// Names are case-insensitive, as everything else in a formula is.
    func testLetNamesAreCaseInsensitive() throws {
        XCTAssertEqual(try number("=LET(Rate, 0.1, RATE*100)"), 10, accuracy: 1e-9)
    }

    func testLetCanBindARange() throws {
        for row in 0..<4 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(Double(row + 1)))
        }
        XCTAssertEqual(try number("=LET(data, B1:B4, SUM(data))"), 10, accuracy: 1e-9)
    }

    /// An even argument count means a binding has no value, or the
    /// calculation is missing.
    func testLetWithoutCalculationIsAnError() throws {
        XCTAssertEqual(try value("=LET(x, 5)"), .error(.notAvailable))
    }

    /// A binding name that is really a cell reference is rejected, as it
    /// would be ambiguous.
    func testLetRejectsCellReferenceAsName() throws {
        XCTAssertEqual(try value("=LET(A2, 5, A2*2)"), .error(.nameInvalid))
    }

    /// A LET binding shadows a workbook named range of the same name.
    func testLetShadowsANamedRange() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(100))
        _ = engine.defineName(
            "Total",
            range: RangeRef(sheet: nil, topLeft: CellAddr(col: 1, row: 0), bottomRight: CellAddr(col: 1, row: 0)),
            sheet: nil
        )
        XCTAssertEqual(try number("=LET(Total, 5, Total*2)"), 10, accuracy: 1e-9)
    }

    // MARK: - LAMBDA

    /// A LAMBDA bound by LET is callable by that name.
    func testLambdaBoundByLetIsCallable() throws {
        XCTAssertEqual(try number("=LET(dbl, LAMBDA(x, x*2), dbl(21))"), 42, accuracy: 1e-9)
    }

    func testLambdaWithTwoParameters() throws {
        XCTAssertEqual(try number("=LET(add, LAMBDA(a, b, a+b), add(2, 3))"), 5, accuracy: 1e-9)
    }

    /// Arguments are evaluated in the caller's scope before binding.
    func testLambdaArgumentsAreEvaluatedAtTheCallSite() throws {
        XCTAssertEqual(try number("=LET(n, 4, sq, LAMBDA(x, x*x), sq(n+1))"), 25, accuracy: 1e-9)
    }

    func testLambdaCanReadCells() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(6))
        XCTAssertEqual(try number("=LET(f, LAMBDA(x, x+B1), f(4))"), 10, accuracy: 1e-9)
    }

    /// Calling with the wrong number of arguments is an error, not a
    /// silently-defaulted parameter.
    func testLambdaArityMismatchIsAnError() throws {
        XCTAssertEqual(try value("=LET(add, LAMBDA(a, b, a+b), add(1))"), .error(.notAvailable))
    }

    /// A parameter shadows an outer binding of the same name.
    func testLambdaParameterShadowsOuterBinding() throws {
        XCTAssertEqual(try number("=LET(x, 1, f, LAMBDA(x, x*10), f(5))"), 50, accuracy: 1e-9)
    }

    /// A LAMBDA left as a cell's result is not a number; it has no
    /// meaningful cell rendering.
    func testBareLambdaIsNotANumber() throws {
        if case .number = try value("=LAMBDA(x, x*2)") {
            XCTFail("a bare LAMBDA should not evaluate to a number")
        }
    }

    /// Unbounded self-recursion must terminate via the depth limit
    /// rather than hang the process.
    func testRunawayRecursionTerminates() throws {
        let result = try value("=LET(f, LAMBDA(x, f(x)), f(1))")
        if case .number = result {
            XCTFail("runaway recursion should not produce a number")
        }
    }

    // MARK: - Composition

    /// The realistic use: name an intermediate, reuse it several times.
    func testLetAvoidsRecomputingAnIntermediate() throws {
        for row in 0..<4 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: row), value: .number(Double(row + 1)))
        }
        // total = 10; the calculation uses it twice.
        XCTAssertEqual(try number("=LET(total, SUM(B1:B4), total/COUNT(B1:B4) + total)"), 12.5, accuracy: 1e-9)
    }

    /// LET composes with the dynamic-array functions.
    func testLetWithDynamicArrayFunction() throws {
        XCTAssertEqual(try number("=LET(s, SEQUENCE(4), SUM(s))"), 10, accuracy: 1e-9)
    }
}
