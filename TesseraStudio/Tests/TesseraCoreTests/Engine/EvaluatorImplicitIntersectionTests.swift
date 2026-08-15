import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.21 dynamic-array completion": "Test
// the genuinely-new pieces: implicit intersection (@) - a formula
// referencing a multi-cell range without an array context implicitly
// intersects to the current row/column." sota-calc-report.md's
// "Excel dynamic arrays" evidence section confirms the mechanism name
// (`@`, auto-prefixed on legacy-formula import) and its scope (a
// non-array-context reference to a range reduces to the single cell at
// the intersection of that range and the formula's own row/column).
//
// Uses `StubSheetEngineCore` (Support/StubSheetEngineCore.swift) rather
// than a full `SheetEngine`, since `Evaluator` only needs the
// `SheetEngineCore` protocol - this is the ungated, in-memory seam for
// the evaluator itself (doctrine rule 11 does not even apply here: there
// is no DB dependency in this path at all).
final class EvaluatorImplicitIntersectionTests: DoctrineTestCase {

    private func makeEngine() -> StubSheetEngineCore {
        let engine = StubSheetEngineCore()
        engine.setCell(CellAddr(col: 0, row: 0), .number(1))  // A1
        engine.setCell(CellAddr(col: 0, row: 1), .number(2))  // A2
        engine.setCell(CellAddr(col: 0, row: 2), .number(3))  // A3
        engine.setCell(CellAddr(col: 1, row: 0), .number(10)) // B1
        engine.setCell(CellAddr(col: 2, row: 0), .number(20)) // C1
        return engine
    }

    // MARK: - Single-column range, arithmetic operand

    func testSingleColumnRangeIntersectsToFormulasOwnRow() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=A1:A3+100")

        // Anchor at row index 1 (row 2): intersects A1:A3 at A2 (= 2).
        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 1, row: 1), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .number(102))
    }

    func testSingleColumnRangeOutsideFormulasRowProducesNotAvailable() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=A1:A3+100")

        // Anchor at row index 5 (row 6): outside A1:A3's rows 0...2.
        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 1, row: 5), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .error(.notAvailable))
    }

    // MARK: - Single-row range, arithmetic operand

    func testSingleRowRangeIntersectsToFormulasOwnColumn() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=A1:C1+1")

        // Anchor at col index 1 (col B): intersects A1:C1 at B1 (= 10).
        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 1, row: 5), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .number(11))
    }

    // MARK: - 2D range, arithmetic operand

    func testTwoDimensionalRangeAtAnchorInsideRangeIntersectsToAnchorsOwnCell() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=A1:C3+1000")

        // The formula lives AT A1 (col 0, row 0), which is inside A1:C3.
        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 0, row: 0), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .number(1001)) // A1 = 1
    }

    func testTwoDimensionalRangeAtAnchorOutsideRangeProducesNotAvailable() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=A1:B2+1")

        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 9, row: 9), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .error(.notAvailable))
    }

    // MARK: - Cross-sheet range never intersects

    func testCrossSheetRangeNeverIntersectsEvenWhenRowMatches() throws {
        let engine = makeEngine()
        engine.setCell(CellAddr(col: 0, row: 1), sheet: "Other", .number(999))
        let evaluator = Evaluator()
        let formula = try parseFormula("=Other!A1:A3+1")

        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 1, row: 1), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .error(.notAvailable))
    }

    // MARK: - Per-parameter intersection: a function argument whose
    // parameter does not accept a range implicitly intersects too, even
    // though the whole call is not itself a bare arithmetic operand.
    // CHOOSE's `index_num` parameter is declared `acceptsRange: false`
    // in FunctionRegistry.swift - that field exists specifically to
    // drive this reduction (see `Evaluator.parameterAcceptsRange`'s own
    // doc comment).

    func testFunctionParameterDeclaredNotAcceptingRangeIntersectsItsRangeArgument() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=CHOOSE(A1:A3,\"x\",\"y\",\"z\")")

        // Anchor at row index 1: A1:A3 intersects to A2 (= 2), so
        // CHOOSE picks its 2nd value, "y".
        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 5, row: 1), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .string("y"))
    }

    // MARK: - Non-range operands are unaffected

    func testPlainCellReferenceIsNotSubjectToIntersectionReduction() throws {
        let engine = makeEngine()
        let evaluator = Evaluator()
        let formula = try parseFormula("=A1+1")

        let result = try evaluator.evaluate(
            formula.ast, at: CellAddr(col: 9, row: 9), sheet: "Sheet1", engine: engine
        )
        XCTAssertEqual(result, .number(2)) // unaffected by anchor position
    }
}
