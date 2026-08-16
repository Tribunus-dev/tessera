import XCTest
@testable import TesseraCore

// MARK: - ImplicitIntersectionOperatorTests
//
// New test file/directory (gap item b - no FormulaEngine test coverage
// existed before this track; the pre-doctrine suite that once covered
// this area was deleted 2026-08-15 per testing-doctrine.md).
//
// Contract: docs/.scratch/p2-0-findings-a.md's own "To finish this
// item" list - (a) add an `@` token to the lexer, (b) parse it as a
// formula-level prefix marker, (c) route a `@`-marked formula through
// the SAME `implicitIntersection(_:at:sheet:engine:)` reduction
// `Evaluator` already applies to operand-position ranges - plus this
// track's wave brief: "'@' lexes/parses/evaluates correctly on a range
// reference in various positions".

final class ImplicitIntersectionOperatorTests: DoctrineTestCase {

    // MARK: - Lexer

    func testLexerTokenizesAtAsItsOwnToken() throws {
        let tokens = try Lexer(source: "@A1:A10").tokenize()
        XCTAssertEqual(tokens.first, .at)
    }

    func testLexerNoLongerThrowsOnAt() throws {
        // Confirms the P2-0 finding's own failure mode
        // ("LexError('Unexpected character @')") is fixed - not just
        // that tokenize() doesn't throw, but that it produces the
        // token, checked separately above.
        XCTAssertNoThrow(try Lexer(source: "@A1").tokenize())
    }

    // MARK: - Parser: various positions

    func testParserParsesALeadingAtAsThePrefixOperatorOnATopLevelRange() throws {
        let formula = try FormulaParser(source: "=@A1:A10").parseFormula()
        guard case .unary(let op, let operand) = formula.ast else {
            return XCTFail("expected .unary at the top level, got \(formula.ast)")
        }
        XCTAssertEqual(op, .implicitIntersection)
        guard case .range = operand else {
            return XCTFail("expected the operand to be the range A1:A10, got \(operand)")
        }
    }

    func testParserBindsAtTightlyLeavingTrailingArithmeticOutsideItsOperand() throws {
        // `@A1:A10+1` must parse as `(@A1:A10)+1`, not `@(A1:A10+1)` -
        // matching `-`/`+` unary's own `minPrec: 10` tight-binding
        // convention (Parser.parseUnary's own doc comment).
        let formula = try FormulaParser(source: "=@A1:A10+1").parseFormula()
        guard case .binary(let op, let left, let right) = formula.ast else {
            return XCTFail("expected the top-level node to be the '+' binary op, got \(formula.ast)")
        }
        XCTAssertEqual(op, .add)
        guard case .unary(let unaryOp, let operand) = left else {
            return XCTFail("expected the LEFT side to be @'s unary node, got \(left)")
        }
        XCTAssertEqual(unaryOp, .implicitIntersection)
        guard case .range = operand else {
            return XCTFail("expected @'s operand to be the range alone, got \(operand)")
        }
        guard case .number(1) = right else {
            return XCTFail("expected the RIGHT side to be the literal 1, got \(right)")
        }
    }

    func testParserAcceptsAtInsideAFunctionArgumentPosition() throws {
        let formula = try FormulaParser(source: "=SUM(@A1:A10)").parseFormula()
        guard case .function(let name, let args) = formula.ast, name == "SUM", args.count == 1 else {
            return XCTFail("expected SUM(...) with one argument, got \(formula.ast)")
        }
        guard case .unary(let op, _) = args[0] else {
            return XCTFail("expected the argument to be @'s unary node, got \(args[0])")
        }
        XCTAssertEqual(op, .implicitIntersection)
    }

    // MARK: - Evaluator: routes through the SAME implicitIntersection reduction

    private func makeEngine() -> SheetEngine {
        let engine = SheetEngine()
        engine.createSheet(name: "Sheet1")
        return engine
    }

    func testEvaluatorReducesAtOnASingleColumnRangeToTheCellOnTheFormulasOwnRow() throws {
        let engine = makeEngine()
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(10)) // A1
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 1), value: .number(20)) // A2

        let formula = try FormulaParser(source: "=@A1:A2").parseFormula()
        // Evaluated as if written in B1 (row 0): picks A1.
        let atRow0 = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 1, row: 0), sheet: "Sheet1", engine: engine)
        XCTAssertEqual(atRow0.asNumber, 10)
        // Evaluated as if written in B2 (row 1): picks A2 - proves the
        // reduction is genuinely position-dependent, not just "first
        // cell of the range".
        let atRow1 = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 1, row: 1), sheet: "Sheet1", engine: engine)
        XCTAssertEqual(atRow1.asNumber, 20)
    }

    func testEvaluatorReducesAtOnASingleRowRangeToTheCellOnTheFormulasOwnColumn() throws {
        let engine = makeEngine()
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(100)) // A1
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 1, row: 0), value: .number(200)) // B1

        let formula = try FormulaParser(source: "=@A1:B1").parseFormula()
        // Evaluated as if written in A5 (col 0): picks A1.
        let atColA = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 0, row: 4), sheet: "Sheet1", engine: engine)
        XCTAssertEqual(atColA.asNumber, 100)
        let atColB = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 1, row: 4), sheet: "Sheet1", engine: engine)
        XCTAssertEqual(atColB.asNumber, 200)
    }

    func testEvaluatorReducesAtOnATwoDimensionalRangeOnlyWhenTheFormulasOwnCellFallsInsideIt() throws {
        let engine = makeEngine()
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(1)) // A1
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 1, row: 1), value: .number(2)) // B2

        let formula = try FormulaParser(source: "=@A1:B2").parseFormula()
        let inside = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 1, row: 1), sheet: "Sheet1", engine: engine)
        XCTAssertEqual(inside.asNumber, 2, "the formula's own cell (B2) falls inside the range - picks itself")

        let outside = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 5, row: 5), sheet: "Sheet1", engine: engine)
        guard case .error = outside else {
            return XCTFail("expected an error for a formula cell OUTSIDE a genuinely 2D range, got \(outside)")
        }
    }

    func testEvaluatorLeavesAtOnAnAlreadyScalarCellReferenceUnchanged() throws {
        // @ on a plain cell reference (no range to reduce) evaluates
        // normally - `evaluateScalarOperand`'s own documented behavior
        // for "anything else" besides a literal `.range`.
        let engine = makeEngine()
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(42)) // A1

        let formula = try FormulaParser(source: "=@A1").parseFormula()
        let result = try Evaluator().evaluate(formula.ast, at: CellAddr(col: 5, row: 5), sheet: "Sheet1", engine: engine)
        XCTAssertEqual(result.asNumber, 42)
    }
}
