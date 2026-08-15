import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.21 dynamic-array completion":
// "Spill already landed (spillOrigin, SpillSize, spilled-cell edit
// refusal); ... obstructed spill yields #SPILL! and clears when the
// obstruction is removed." sota-calc-report.md's "Excel dynamic arrays"
// evidence: "spill anchor owns the formula; spilled cells are
// ghosted/read-only ... #SPILL! causes enumerated (obstruction, ...)".
//
// Exercised against the real `SheetEngine` directly - an entirely
// in-memory, ungated seam with no `TesseraDataLayer`/Postgres
// dependency at all (this is the FormulaEngine's own workbook engine,
// distinct from the product-layer `SheetStore`/`Sheet`), so doctrine
// rule 11's gating concern does not apply to this file.
final class SheetEngineDynamicArrayTests: DoctrineTestCase {

    private func makeEngineWithColumn() -> SheetEngine {
        let engine = SheetEngine()
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(10)) // A1
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(20)) // A2
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 2), value: .number(30)) // A3
        return engine
    }

    private let b1 = CellAddr(col: 1, row: 0)
    private let c1 = CellAddr(col: 2, row: 0)
    private let d1 = CellAddr(col: 3, row: 0)

    // MARK: - Happy path: an unobstructed array formula spills

    func testUnobstructedArrayFormulaSpillsIntoFollowingCells() throws {
        let engine = makeEngineWithColumn()
        try engine.setFormula(sheet: nil, addr: b1, source: "=TRANSPOSE(A1:A3)")

        XCTAssertEqual(engine.getValue(sheet: nil, addr: b1), .number(10))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: c1), .number(20))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: d1), .number(30))
    }

    func testSpilledCellCarriesNoFormulaOfItsOwn() throws {
        let engine = makeEngineWithColumn()
        try engine.setFormula(sheet: nil, addr: b1, source: "=TRANSPOSE(A1:A3)")

        XCTAssertTrue(engine.hasFormula(sheet: nil, addr: b1))
        XCTAssertFalse(engine.hasFormula(sheet: nil, addr: c1), "a spilled cell has no formula of its own - the anchor owns the whole block")
        XCTAssertFalse(engine.hasFormula(sheet: nil, addr: d1))
    }

    /// "spilled-cell edit refusal" - named in the contract as already
    /// landed; still a regression worth pinning since it is exactly what
    /// makes a spilled block behave as one unit.
    func testDirectEditOfASpilledCellIsRefused() throws {
        let engine = makeEngineWithColumn()
        try engine.setFormula(sheet: nil, addr: b1, source: "=TRANSPOSE(A1:A3)")

        let dirty = engine.setValue(sheet: nil, addr: c1, value: .number(999))
        XCTAssertTrue(dirty.isEmpty, "an edit to a spilled (non-anchor) cell must be refused entirely")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: c1), .number(20), "the spilled value must be unchanged")
    }

    /// Deleting the anchor clears the whole block it spilled - the
    /// counterpart of "spilled cells are ghosted/read-only": nothing
    /// should be left behind that no longer has an owner.
    func testDeletingTheAnchorClearsEveryCellItSpilled() throws {
        let engine = makeEngineWithColumn()
        try engine.setFormula(sheet: nil, addr: b1, source: "=TRANSPOSE(A1:A3)")

        engine.deleteCell(sheet: nil, addr: b1)

        XCTAssertEqual(engine.getValue(sheet: nil, addr: b1), .null)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: c1), .null)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: d1), .null)
    }

    // MARK: - Obstruction -> #SPILL!

    func testObstructedSpillYieldsSpillErrorAndLeavesObstructionUntouched() throws {
        let engine = makeEngineWithColumn()
        // Pre-occupy C1 - one of the two cells TRANSPOSE(A1:A3) would
        // need to spill into.
        engine.setValue(sheet: nil, addr: c1, value: .number(12345))

        try engine.setFormula(sheet: nil, addr: b1, source: "=TRANSPOSE(A1:A3)")

        XCTAssertEqual(engine.getValue(sheet: nil, addr: b1), .error(.spill))
        XCTAssertEqual(
            engine.getValue(sheet: nil, addr: c1), .number(12345),
            "the blocking cell must be left untouched so the user can see what is in the way"
        )
        XCTAssertEqual(engine.getValue(sheet: nil, addr: d1), .null, "nothing partial should be written past the block either")
    }

    /// The other half of the same contract sentence: once the
    /// obstruction is gone, the SAME formula spills successfully. A
    /// recalculation pass is what actually retries the write (the
    /// engine has no standing "cells with #SPILL! errors" watch list -
    /// see SheetEngine.swift's writeResult/evaluateCell) - `recalculate()`
    /// is the public API for "re-evaluate everything", and is what
    /// removing an obstruction and refreshing the sheet corresponds to.
    func testObstructedSpillSucceedsOnceTheObstructionIsRemoved() throws {
        let engine = makeEngineWithColumn()
        engine.setValue(sheet: nil, addr: c1, value: .number(12345))
        try engine.setFormula(sheet: nil, addr: b1, source: "=TRANSPOSE(A1:A3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: b1), .error(.spill), "sanity: the obstruction must still be blocking at this point")

        engine.clearCell(sheet: nil, addr: c1)
        engine.recalculate()

        XCTAssertEqual(engine.getValue(sheet: nil, addr: b1), .number(10))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: c1), .number(20))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: d1), .number(30))
    }
}
