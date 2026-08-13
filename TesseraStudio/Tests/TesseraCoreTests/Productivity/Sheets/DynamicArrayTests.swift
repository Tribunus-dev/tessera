import XCTest
@testable import TesseraCore

/// Dynamic arrays: one formula writing a block of cells it does not own.
///
/// This is an engine capability, not a function-library addition. The
/// invariants that matter are: the anchor owns the block, the block is
/// rewritten (not appended to) on every recalculation, an obstruction
/// produces `#SPILL!` instead of silently overwriting, and nobody can
/// edit part of someone else's result.
final class DynamicArrayTests: XCTestCase {

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

    // MARK: - Spilling

    /// A column array fills the cells below the anchor.
    func testSequenceSpillsDownColumn() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 0), .number(1))
        XCTAssertEqual(at(0, 1), .number(2))
        XCTAssertEqual(at(0, 2), .number(3))
    }

    /// A 2D result fills a rectangle, row-major.
    func testSequenceSpillsTwoDimensions() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(2,3)")
        XCTAssertEqual(at(0, 0), .number(1))
        XCTAssertEqual(at(1, 0), .number(2))
        XCTAssertEqual(at(2, 0), .number(3))
        XCTAssertEqual(at(0, 1), .number(4))
        XCTAssertEqual(at(2, 1), .number(6))
    }

    /// A 1x1 result is an ordinary scalar, not a one-cell spill.
    func testSingleElementResultIsScalar() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(1)")
        XCTAssertEqual(at(0, 0), .number(1))
        XCTAssertEqual(at(0, 1), .null)
    }

    /// Only the anchor carries the formula; spilled cells are results.
    func testOnlyAnchorHasFormula() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertTrue(engine.hasFormula(sheet: nil, addr: CellAddr(col: 0, row: 0)))
        XCTAssertFalse(engine.hasFormula(sheet: nil, addr: CellAddr(col: 0, row: 1)))
    }

    // MARK: - Obstruction

    /// Something in the way blocks the whole spill and reports #SPILL!.
    func testObstructionProducesSpillError() throws {
        put(0, 2, .string("in the way"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 0), .error(.spill))
    }

    /// The blocking cell is left untouched so the user can see the cause.
    func testObstructionIsNotOverwritten() throws {
        put(0, 2, .string("in the way"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 2), .string("in the way"))
    }

    /// Nothing partial is written when the spill is blocked.
    func testBlockedSpillWritesNothingElse() throws {
        put(0, 2, .string("in the way"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 1), .null)
    }

    /// Clearing the obstruction and recalculating lets the spill land.
    func testSpillRecoversAfterObstructionCleared() throws {
        put(0, 2, .string("in the way"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 0), .error(.spill))
        put(0, 2, .null)
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        XCTAssertEqual(at(0, 0), .number(1))
        XCTAssertEqual(at(0, 2), .number(3))
    }

    // MARK: - Reshaping

    /// A smaller result must clear the cells the previous one used, not
    /// leave stale values behind.
    func testShrinkingSpillClearsStaleCells() throws {
        let anchor = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: anchor, source: "=SEQUENCE(4)")
        XCTAssertEqual(at(0, 3), .number(4))
        try engine.setFormula(sheet: nil, addr: anchor, source: "=SEQUENCE(2)")
        XCTAssertEqual(at(0, 1), .number(2))
        XCTAssertEqual(at(0, 3), .null, "the old tail must be cleared")
    }

    /// Replacing the formula with a plain value drops the whole block.
    func testOverwritingAnchorWithValueClearsSpill() throws {
        let anchor = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: anchor, source: "=SEQUENCE(3)")
        put(0, 0, .number(99))
        XCTAssertEqual(at(0, 0), .number(99))
        XCTAssertEqual(at(0, 1), .null)
        XCTAssertEqual(at(0, 2), .null)
    }

    /// Deleting the anchor takes the block with it.
    func testDeletingAnchorClearsSpill() throws {
        let anchor = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: anchor, source: "=SEQUENCE(3)")
        engine.deleteCell(sheet: nil, addr: anchor)
        XCTAssertEqual(at(0, 1), .null)
        XCTAssertEqual(at(0, 2), .null)
    }

    // MARK: - Ownership

    /// You cannot change part of an array.
    func testWritingIntoSpilledCellIsRefused() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        put(0, 1, .number(42))
        XCTAssertEqual(at(0, 1), .number(2), "the spilled value must survive")
    }

    // MARK: - Downstream reads

    /// A cell reading a spilled address sees the spilled value.
    func testFormulaCanReadASpilledCell() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(3)")
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 0), source: "=A2*10")
        XCTAssertEqual(at(2, 0), .number(20))
    }

    /// Aggregates work over a spilled block.
    func testSumOverSpilledRange() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SEQUENCE(4)")
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 0), source: "=SUM(A1:A4)")
        XCTAssertEqual(at(2, 0), .number(10))
    }

    // MARK: - The array functions

    func testTransposeFlipsOrientation() throws {
        put(1, 0, .number(1))
        put(1, 1, .number(2))
        put(1, 2, .number(3))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 4, row: 0), source: "=TRANSPOSE(B1:B3)")
        XCTAssertEqual(at(4, 0), .number(1))
        XCTAssertEqual(at(5, 0), .number(2))
        XCTAssertEqual(at(6, 0), .number(3))
    }

    func testUniqueRemovesDuplicatesPreservingOrder() throws {
        for (row, n) in [3.0, 1, 3, 2, 1].enumerated() {
            put(1, row, .number(n))
        }
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 4, row: 0), source: "=UNIQUE(B1:B5)")
        XCTAssertEqual(at(4, 0), .number(3))
        XCTAssertEqual(at(4, 1), .number(1))
        XCTAssertEqual(at(4, 2), .number(2))
        XCTAssertEqual(at(4, 3), .null)
    }

    func testSortAscendingAndDescending() throws {
        for (row, n) in [3.0, 1, 2].enumerated() {
            put(1, row, .number(n))
        }
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 4, row: 0), source: "=SORT(B1:B3)")
        XCTAssertEqual(at(4, 0), .number(1))
        XCTAssertEqual(at(4, 2), .number(3))

        try engine.setFormula(sheet: nil, addr: CellAddr(col: 6, row: 0), source: "=SORT(B1:B3, 1, -1)")
        XCTAssertEqual(at(6, 0), .number(3))
        XCTAssertEqual(at(6, 2), .number(1))
    }

    /// FILTER keeps whole rows, so a record stays intact.
    func testFilterKeepsMatchingRows() throws {
        for (row, n) in [10.0, 20, 30].enumerated() {
            put(1, row, .number(n))
            put(2, row, .bool(n >= 20))
        }
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 4, row: 0), source: "=FILTER(B1:B3, C1:C3)")
        XCTAssertEqual(at(4, 0), .number(20))
        XCTAssertEqual(at(4, 1), .number(30))
        XCTAssertEqual(at(4, 2), .null)
    }

    /// A filter matching nothing returns the caller's fallback.
    func testFilterWithNoMatchesReturnsIfEmpty() throws {
        for (row, n) in [10.0, 20].enumerated() {
            put(1, row, .number(n))
            put(2, row, .bool(false))
        }
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 4, row: 0), source: "=FILTER(B1:B2, C1:C2, \"none\")")
        XCTAssertEqual(at(4, 0), .string("none"))
    }

    /// A shrinking FILTER result must clear its old tail on recalc - the
    /// case where a stale row would otherwise look like real data.
    func testFilterShrinksOnRecalculation() throws {
        for (row, n) in [10.0, 20, 30].enumerated() {
            put(1, row, .number(n))
            put(2, row, .bool(true))
        }
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 4, row: 0), source: "=FILTER(B1:B3, C1:C3)")
        XCTAssertEqual(at(4, 2), .number(30))

        put(2, 2, .bool(false))
        XCTAssertEqual(at(4, 0), .number(10))
        XCTAssertEqual(at(4, 1), .number(20))
        XCTAssertEqual(at(4, 2), .null, "the dropped row must not linger")
    }
}
