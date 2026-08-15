import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.21 dynamic-array completion":
// "Register OFFSET/INDIRECT as volatile ... and separately (this is the
// KNOWN, gap-closure-committed fix) assert that a formula containing
// OFFSET or INDIRECT FAILS to compile via TokenArrayCompiler (falls back
// to AST evaluation) rather than compiling to a token stream - this was
// a real, fixed bug ... and deserves a permanent regression test, written
// from the contract (OFFSET/INDIRECT need live-engine context a flat
// token stack cannot represent), not by reading the fix and copying its
// shape."
//
// Also grounded in `TokenArray.swift`'s own file-header doc comment,
// which is itself the shipped scope statement for this compiler (not an
// implementation detail): OFFSET/INDIRECT, LET/LAMBDA, and array
// literals are documented as unsupported constructs that must fall back
// to AST evaluation, and `TokenArrayEvaluator`'s own doc comment commits
// to "produces the same Value Evaluator.evaluate would for the AST this
// TokenArray was compiled from" for whatever DOES compile - the
// RPN/AST-equivalence property test below is exactly that commitment.
final class TokenArrayCompilerTests: DoctrineTestCase {

    private let anchor = CellAddr(col: 2, row: 2) // C3

    // MARK: - OFFSET/INDIRECT exclusion (the permanent regression test)

    func testCompileFormulaContainingOFFSETReturnsNilAndFallsBackToAST() throws {
        let formula = try parseFormula("=OFFSET(A1,1,1)")
        XCTAssertNil(
            TokenArrayCompiler.compile(formula.ast, anchor: anchor),
            "OFFSET needs live-engine reference resolution at evaluation time; a flat RPN " +
            "stream of already-relativized refs cannot represent that, so this formula must " +
            "stay on the AST evaluation path."
        )
    }

    func testCompileFormulaContainingINDIRECTReturnsNilAndFallsBackToAST() throws {
        let formula = try parseFormula("=INDIRECT(\"A1\")")
        XCTAssertNil(
            TokenArrayCompiler.compile(formula.ast, anchor: anchor),
            "INDIRECT resolves a reference from live text at evaluation time; TokenArray " +
            "compiles references ahead of time, so this formula must stay on the AST path."
        )
    }

    func testCompileFormulaWithOFFSETNestedInsideArithmeticStillReturnsNil() throws {
        // The exclusion has to propagate through the whole tree, not just
        // trigger when OFFSET is the top-level call.
        let formula = try parseFormula("=1+OFFSET(A1,0,1)")
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: anchor))
    }

    // MARK: - Positive control: exclusion is targeted, not a blanket failure

    func testCompileFormulaWithoutOFFSETOrINDIRECTSucceeds() throws {
        let formula = try parseFormula("=SUM(A1:A3)+B1")
        XCTAssertNotNil(
            TokenArrayCompiler.compile(formula.ast, anchor: anchor),
            "a formula with no OFFSET/INDIRECT/LET/LAMBDA/array-literal must still compile - " +
            "the exclusion is specific to those constructs, not a general compiler failure."
        )
    }

    // MARK: - Other constructs the file header documents as excluded

    func testCompileFormulaContainingLETReturnsNil() throws {
        let formula = try parseFormula("=LET(x,1,x+1)")
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: anchor))
    }

    func testCompileFormulaContainingLAMBDAReturnsNil() throws {
        let formula = try parseFormula("=LAMBDA(x,x*2)")
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: anchor))
    }

    // MARK: - Relative-offset compilation shape

    func testCompileRelativeCellReferenceOffsetsFromAnchor() throws {
        // "=A1" at anchor C3 (col 2, row 2): A1 is col 0, row 0, so its
        // relative offset is (-2, -2).
        let formula = try parseFormula("=A1")
        guard let compiled = TokenArrayCompiler.compile(formula.ast, anchor: anchor) else {
            return XCTFail("plain cell reference must compile")
        }
        XCTAssertEqual(compiled.tokens.count, 1)
        guard case .cellRef(let ref) = compiled.tokens[0] else {
            return XCTFail("expected a single .cellRef token, got \(compiled.tokens)")
        }
        XCTAssertEqual(ref.col, .relative(offset: -2))
        XCTAssertEqual(ref.row, .relative(offset: -2))
    }

    func testCompileAbsoluteCellReferenceDoesNotOffsetFromAnchor() throws {
        let formula = try parseFormula("=$A$1")
        guard let compiled = TokenArrayCompiler.compile(formula.ast, anchor: anchor) else {
            return XCTFail("absolute cell reference must compile")
        }
        guard case .cellRef(let ref) = compiled.tokens[0] else {
            return XCTFail("expected a single .cellRef token")
        }
        XCTAssertEqual(ref.col, .absolute(0))
        XCTAssertEqual(ref.row, .absolute(0))
    }

    /// The file header's own claim: "=A1+B1 at B2 and =A2+B2 at B3 both
    /// compile to the identical token stream" - the property that makes
    /// shared-formula-group interning possible at all.
    func testTwoFormulasWithSameShapeAtDifferentAnchorsCompileToIdenticalTokens() throws {
        let formulaAtB2 = try parseFormula("=A1+B1")
        let formulaAtB3 = try parseFormula("=A2+B2")
        let anchorB2 = CellAddr(col: 1, row: 1)
        let anchorB3 = CellAddr(col: 1, row: 2)

        guard let compiledB2 = TokenArrayCompiler.compile(formulaAtB2.ast, anchor: anchorB2),
              let compiledB3 = TokenArrayCompiler.compile(formulaAtB3.ast, anchor: anchorB3) else {
            return XCTFail("both formulas must compile")
        }
        XCTAssertEqual(compiledB2.tokens, compiledB3.tokens)
        XCTAssertEqual(compiledB2.groupKey, compiledB3.groupKey)
    }

    // MARK: - RPN/AST evaluation equivalence (rule 9: property test)

    /// `TokenArray.swift`'s own doc comment on `TokenArrayEvaluator`
    /// commits to this: "produces the same Value Evaluator.evaluate
    /// would for the AST this TokenArray was compiled from". A battery
    /// of real formulas, evaluated both ways against the same stub
    /// engine, must agree.
    func testTokenArrayEvaluationAgreesWithASTEvaluationAcrossFormulaBattery() throws {
        let engine = StubSheetEngineCore()
        engine.setCell(CellAddr(col: 0, row: 0), .number(10))   // A1
        engine.setCell(CellAddr(col: 1, row: 0), .number(5))    // B1
        engine.setCell(CellAddr(col: 0, row: 1), .string("hi"))   // A2
        engine.setCell(CellAddr(col: 1, row: 1), .bool(true))   // B2
        engine.setCell(CellAddr(col: 0, row: 2), .number(3))    // A3
        engine.setCell(CellAddr(col: 1, row: 2), .number(4))    // B3

        let battery = [
            "=A1+B1",
            "=A1-B1*2",
            "=(A1+B1)/2",
            "=SUM(A1:B1)",
            "=SUM(A1:A3)",
            "=A1>B1",
            "=A2&B1",
            "=-A1",
            "=A1^2",
        ]

        let evaluator = Evaluator()
        let anchor = CellAddr(col: 4, row: 4)

        for source in battery {
            let formula = try parseFormula(source)
            let astResult = try evaluator.evaluate(formula.ast, at: anchor, sheet: "Sheet1", engine: engine)

            guard let compiled = TokenArrayCompiler.compile(formula.ast, anchor: anchor) else {
                return XCTFail("\(source) was expected to compile for this equivalence check")
            }
            let rpnResult = try TokenArrayEvaluator.evaluate(
                compiled, anchor: anchor, sheet: "Sheet1",
                functions: FunctionRegistry.shared, engine: engine
            )
            XCTAssertEqual(rpnResult, astResult, "AST and RPN evaluation diverged for \(source)")
        }
    }
}
