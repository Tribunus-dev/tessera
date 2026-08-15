import XCTest
@testable import TesseraCore

/// Gap-closure: OFFSET/INDIRECT were added to the formula engine (see
/// `DynamicArrayCompletionTests`) in a later wave than `TokenArray`'s
/// original LET/LAMBDA exclusion, and never got added to that same
/// exclusion. Both need the formula's own AST/reference-literal shape
/// plus live-engine resolution at evaluation time (`Evaluator.evalOffset`/
/// `evalIndirect`), exactly the "lexical scope a flat stack machine
/// doesn't model" category LET/LAMBDA are already excluded for - see
/// `TokenArrayCompiler.emit`'s `.function` case and the file header.
/// Without the exclusion, compiling one of these into a `TokenArray`
/// silently produced a token stream that evaluates to the wrong
/// `.error(.referenceInvalid)` instead of being correctly excluded.
///
/// `TokenArrayTests` (Productivity/Sheets/) owns the broader compiler/
/// evaluator equivalence battery and its own LET/LAMBDA/array-literal
/// compile-failure tests; this file covers only the OFFSET/INDIRECT gap.
final class TokenArrayCompilerTests: XCTestCase {

    func testOffsetDoesNotCompile() throws {
        let result = try FormulaParser(source: "=OFFSET(A1,1,1)").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    func testIndirectDoesNotCompile() throws {
        let result = try FormulaParser(source: "=INDIRECT(\"A1\")").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    /// OFFSET/INDIRECT nested inside another function's arguments must
    /// still sink the whole compile, the same way a nested LET/LAMBDA
    /// would - `emit` propagates a `false` from any argument up through
    /// its caller.
    func testOffsetNestedInAnotherFunctionStillFailsToCompile() throws {
        let result = try FormulaParser(source: "=SUM(OFFSET(A1,0,0,2,2))").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    /// Regression check: the new guard conditions must not reject
    /// ordinary formulas that merely mention "OFFSET"/"INDIRECT"-like
    /// substrings or unrelated functions.
    func testOrdinaryFunctionStillCompiles() throws {
        let result = try FormulaParser(source: "=SUM(A1:A3)").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNotNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    func testArithmeticWithCellReferencesStillCompiles() throws {
        let result = try FormulaParser(source: "=A1+B1*2").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNotNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 5, row: 5)))
    }
}
