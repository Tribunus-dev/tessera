import XCTest
@testable import TesseraCore

/// P1 item 1.21 (dynamic-array completion): implicit intersection,
/// OFFSET/INDIRECT, volatile-resize protection, and the
/// `FunctionVolatility` axis decision. Spill itself (spillOrigin,
/// SpillSize, #SPILL! blocking) is `DynamicArrayTests`' - this file
/// covers only what that one does not.
final class DynamicArrayCompletionTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
    }

    private func at(_ col: Int, _ row: Int) -> Value {
        engine.getValue(sheet: nil, addr: CellAddr(col: col, row: row))
    }

    private func put(_ col: Int, _ row: Int, _ value: Value) {
        engine.setValue(sheet: nil, addr: CellAddr(col: col, row: row), value: value)
    }

    // MARK: - FunctionVolatility axis (refinement doc row 20: dropped)

    /// The refinement doc's decision: no `.array` volatility case (Excel
    /// models per-formula persistence bits, LO per-token-array
    /// `ScRecalcMode` bits - neither surveyed engine has this axis).
    /// Exhaustive switch, no `default:` - a future edit that adds
    /// `FunctionVolatility.array` stops this compiling instead of
    /// silently drifting from that decision.
    func testFunctionVolatilityHasExactlyVolatileAndNotVolatileCases() {
        func classify(_ v: FunctionVolatility) -> String {
            switch v {
            case .notVolatile: return "notVolatile"
            case .volatile: return "volatile"
            }
        }
        XCTAssertEqual(classify(.notVolatile), "notVolatile")
        XCTAssertEqual(classify(.volatile), "volatile")
    }

    // MARK: - Implicit intersection (@) - arithmetic/unary operands

    /// A single-column range used as an arithmetic operand reduces to
    /// the cell on the formula's own row.
    func testColumnRangeInArithmeticReducesToCurrentRow() throws {
        put(0, 0, .number(10))
        put(0, 1, .number(20))
        put(0, 2, .number(30))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 1), source: "=A1:A3+1")
        XCTAssertEqual(at(1, 1), .number(21), "row 1 intersects A2 (20), not the whole column")
    }

    /// A single-row range used as an arithmetic operand reduces to the
    /// cell on the formula's own column.
    func testRowRangeInArithmeticReducesToCurrentColumn() throws {
        put(0, 0, .number(10))
        put(1, 0, .number(20))
        put(2, 0, .number(30))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 3), source: "=A1:C1+1")
        XCTAssertEqual(at(1, 3), .number(21), "column 1 intersects B1 (20), not the whole row")
    }

    /// A unary operand reduces the same way a binary one does.
    func testColumnRangeInUnaryReducesToCurrentRow() throws {
        put(0, 0, .number(10))
        put(0, 1, .number(20))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 1), source: "=-A1:A2")
        XCTAssertEqual(at(1, 1), .number(-20))
    }

    /// The formula's row falls outside the range entirely - no cell to
    /// intersect, so the reduction fails rather than guessing.
    func testColumnRangeInArithmeticWithNoIntersectionErrors() throws {
        put(0, 0, .number(10))
        put(0, 1, .number(20))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 5), source: "=A1:A2+1")
        XCTAssertEqual(at(2, 5), .error(.notAvailable))
    }

    // MARK: - Implicit intersection - function arguments

    /// A function whose parameter declares `acceptsRange: false` (MATCH's
    /// `lookup_value`) reduces a literal range argument the same way an
    /// arithmetic operand does; MATCH's `lookup_array` parameter (the
    /// default `acceptsRange: true`) is unaffected and still sees the
    /// full range.
    func testFunctionParameterNotAcceptingRangeReducesViaIntersection() throws {
        for (row, n) in [10.0, 20, 30, 40, 50].enumerated() {
            put(0, row, .number(n))
        }
        // Row 2 (0-based) intersects A3 = 30, the third element of A1:A5.
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 2), source: "=MATCH(A1:A5, A1:A5, 0)")
        XCTAssertEqual(at(2, 2), .number(3))
    }

    /// A function whose parameter DOES accept a range (SUM) still sees
    /// the whole array - the reduction only fires for parameters that
    /// declared they cannot take one.
    func testFunctionParameterAcceptingRangeIsNotReduced() throws {
        for (row, n) in [1.0, 2, 3].enumerated() {
            put(0, row, .number(n))
        }
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 0), source: "=SUM(A1:A3)")
        XCTAssertEqual(at(2, 0), .number(6))
    }

    // MARK: - OFFSET

    func testOffsetReadsTheShiftedCell() throws {
        put(0, 0, .number(1)) // A1
        put(1, 0, .number(2)) // B1
        put(0, 1, .number(3)) // A2
        put(1, 1, .number(4)) // B2
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 3, row: 0), source: "=OFFSET(A1,1,1)")
        XCTAssertEqual(at(3, 0), .number(4))
    }

    /// height/width default to the reference's own dimensions, but an
    /// explicit height/width returns a whole block SUM can reduce.
    func testOffsetWithExplicitDimensionsReturnsABlock() throws {
        put(0, 0, .number(1)) // A1
        put(1, 0, .number(2)) // B1
        put(0, 1, .number(3)) // A2
        put(1, 1, .number(4)) // B2
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 3, row: 0), source: "=SUM(OFFSET(A1,0,0,2,2))")
        XCTAssertEqual(at(3, 0), .number(10))
    }

    /// Shifting off the top/left edge of the sheet is `#REF!`, matching
    /// Excel - `CellAddr` itself cannot represent a negative coordinate.
    func testOffsetPastTheSheetEdgeErrors() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 3, row: 0), source: "=OFFSET(A1,-1,0)")
        XCTAssertEqual(at(3, 0), .error(.referenceInvalid))
    }

    /// OFFSET is volatile (`FormulaAST.containsVolatileFunction` already
    /// listed it by name), which is load-bearing here: the dependency
    /// graph's own precedent scan only sees OFFSET's literal `reference`
    /// argument (A1), never the cell it actually reads (B2) - that
    /// address is resolved at evaluation time. Without the volatility
    /// flag forcing a recalculation on every pass, a direct edit to B2
    /// (with A1 untouched) would leave the OFFSET cell silently stale.
    func testOffsetRecalculatesWhenItsComputedTargetChangesDirectly() throws {
        put(1, 1, .number(4)) // B2
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 3, row: 0), source: "=OFFSET(A1,1,1)")
        XCTAssertEqual(at(3, 0), .number(4))

        put(1, 1, .number(99)) // change B2; A1 (the only tracked precedent) is untouched
        XCTAssertEqual(at(3, 0), .number(99))
    }

    // MARK: - INDIRECT

    func testIndirectReadsALiteralCellReference() throws {
        put(0, 0, .number(42))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=INDIRECT(\"A1\")")
        XCTAssertEqual(at(1, 0), .number(42))
    }

    func testIndirectReadsARangeReference() throws {
        put(0, 0, .number(1))
        put(0, 1, .number(2))
        put(0, 2, .number(3))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=SUM(INDIRECT(\"A1:A3\"))")
        XCTAssertEqual(at(1, 0), .number(6))
    }

    /// The ref_text is itself a formula result, not a literal string -
    /// the case a purely static (parse-time) dependency scan can never
    /// resolve, which is exactly why INDIRECT has to be volatile too.
    func testIndirectResolvesADynamicallyComputedRefText() throws {
        put(1, 0, .string("A1")) // B1 holds the reference text
        put(0, 0, .number(7))    // A1
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 0), source: "=INDIRECT(B1)")
        XCTAssertEqual(at(2, 0), .number(7))
    }

    func testIndirectWithUnparseableTextErrors() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=INDIRECT(\"not a reference\")")
        XCTAssertEqual(at(1, 0), .error(.referenceInvalid))
    }

    // MARK: - #SPILL! obstruction: publicly queryable, and clears

    /// The obstruction is a plain cell value (`.error(.spill)`) reachable
    /// through the same public `getValue` every other cell read goes
    /// through - not a private detail a future UI item would need engine
    /// changes to reach.
    func testSpillObstructionIsQueryableThroughThePublicValueAPI() throws {
        put(0, 2, .string("in the way"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 0, row: 0)), .error(.spill))
    }

    func testObstructedSpillClearsWhenTheBlockingCellIsCleared() throws {
        put(0, 2, .string("in the way"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 0), .error(.spill))

        engine.clearCell(sheet: nil, addr: CellAddr(col: 0, row: 2))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 0), .number(1))
        XCTAssertEqual(at(0, 2), .number(3))
    }

    // MARK: - Volatile-resize protection

    /// Two formulas dirtied by the SAME edit in the same recalculation
    /// pass: B1's array grows to cover B3's own address, an unrelated
    /// formula that just happens to sit there. Regardless of which of
    /// the two `graph.evaluationOrder` happens to schedule first this
    /// pass, B1 must report `#SPILL!` rather than silently claiming
    /// B3's cell, and B3 must keep its own correctly-computed value.
    ///
    /// This already holds today - see the "volatile-resize protection"
    /// finding in the 1.21 report: `writeResult`'s collision check
    /// works off each cell's currently-STORED data, and "dirty" is
    /// orthogonal to "blank" in this engine (`setValue`/
    /// `setFormulaUnlocked` always write a cell's new value synchronously
    /// before anything downstream is marked dirty), so a formula cell
    /// that has not yet had its own turn this pass still holds its real
    /// last-computed value, not a gap the collision check would miss.
    /// This test pins that property as a regression guard for BOTH
    /// orderings, since only one of them exercised the pre-existing
    /// spill-vs-spill collision path before this item added OFFSET/
    /// INDIRECT (dynamic references the static dependency graph cannot
    /// see through, which is what actually motivates re-checking this).
    func testSpillDoesNotClobberAnotherFormulaScheduledInTheSamePass() throws {
        put(0, 0, .number(2)) // A1: SEQUENCE's row count
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=SEQUENCE(A1)") // B1, spills B1:B2 for now
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 2), source: "=A1*100") // B3, independent of B1's spill

        XCTAssertEqual(at(1, 2), .number(200), "sanity: B3 computed correctly before any collision")

        // Growing A1 to 3 makes B1 want to spill into B1:B3, landing
        // exactly on B3 - and B1, B3 are BOTH direct dependents of A1,
        // so both are dirtied by this one edit and recalculated in the
        // same pass.
        put(0, 0, .number(3))

        XCTAssertEqual(at(1, 0), .error(.spill), "B1 must not silently claim B3's address")
        XCTAssertEqual(at(1, 2), .number(300), "B3's own formula result must survive, not a stray spilled 3")
    }
}
