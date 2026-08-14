import XCTest
@testable import TesseraCore

/// Tests for the SheetEngine workbook engine.
final class SheetEngineTests: XCTestCase {

    var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
    }

    // MARK: - Cell Values

    func testSetValue_getValue() {
        let addr = CellAddr(col: 0, row: 0)  // A1
        engine.setValue(sheet: nil, addr: addr, value: .number(42))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(42))
    }

    func testSetValue_nullClearsCell() {
        let addr = CellAddr(col: 2, row: 1)  // C2
        engine.setValue(sheet: nil, addr: addr, value: .string("hello"))
        engine.setValue(sheet: nil, addr: addr, value: .null)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .null)
    }

    func testGetValue_emptyCell_returnsNull() {
        let addr = CellAddr(col: 5, row: 10)  // F11
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .null)
    }

    func testHasFormula_noFormula_returnsFalse() {
        let addr = CellAddr(col: 0, row: 0)
        XCTAssertFalse(engine.hasFormula(sheet: nil, addr: addr))
    }

    // MARK: - Formulas

    func testSetFormula_simpleNumber() throws {
        let addr = CellAddr(col: 0, row: 0)  // A1
        let dirty = try engine.setFormula(sheet: nil, addr: addr, source: "=42")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(42))
        XCTAssertEqual(engine.getFormula(sheet: nil, addr: addr), "=42")
        XCTAssertFalse(dirty.isEmpty)
    }

    func testSetFormula_arithmetic() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        engine.setValue(sheet: nil, addr: a1, value: .number(10))
        engine.setValue(sheet: nil, addr: a2, value: .number(3))

        let result = try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=A1+A2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(13))
    }

    func testSetFormula_multiplication() throws {
        let addr = CellAddr(col: 0, row: 0)
        let result = try engine.setFormula(sheet: nil, addr: addr, source: "=6*7")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(42))
    }

    func testSetFormula_division() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=20/4")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(5))
    }

    func testSetFormula_divisionByZero_returnsError() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=1/0")
        if case .error(let e) = engine.getValue(sheet: nil, addr: addr) {
            XCTAssertEqual(e, .divisionByZero)
        } else {
            XCTFail("Expected division-by-zero error")
        }
    }

    func testSetFormula_nestedFunction() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        let a3 = CellAddr(col: 0, row: 2)
        engine.setValue(sheet: nil, addr: a1, value: .number(1))
        engine.setValue(sheet: nil, addr: a2, value: .number(2))
        engine.setValue(sheet: nil, addr: a3, value: .number(3))

        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=SUM(A1:A3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(6))
    }

    func testSetFormula_average() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        engine.setValue(sheet: nil, addr: a1, value: .number(2))
        engine.setValue(sheet: nil, addr: a2, value: .number(4))

        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=AVERAGE(A1:A2)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(3))
    }

    func testSetFormula_count() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        let a3 = CellAddr(col: 0, row: 2)
        engine.setValue(sheet: nil, addr: a1, value: .number(5))
        engine.setValue(sheet: nil, addr: a2, value: .number(10))
        engine.setValue(sheet: nil, addr: a3, value: .string("text"))

        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=COUNT(A1:A3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(2))
    }

    func testSetFormula_circularReference_throws() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)

        // A1 reads A2; closing the loop with A2 reading A1 must throw.
        // (The setup used to be written twice, so the first pair threw
        // outside the do-block and the assertion never ran.)
        try engine.setFormula(sheet: nil, addr: a1, source: "=A2+1")

        do {
            try engine.setFormula(sheet: nil, addr: a2, source: "=A1+1")
            XCTFail("Expected CycleError")
        } catch is CycleError {
            // Expected
        }
    }

    func testSetFormula_incrementalRecalculation() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        let sum = CellAddr(col: 1, row: 0)

        try engine.setFormula(sheet: nil, addr: sum, source: "=A1+A2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: sum), .number(0))  // A1=A2=0

        engine.setValue(sheet: nil, addr: a1, value: .number(10))
        engine.setValue(sheet: nil, addr: a2, value: .number(5))
        engine.recalculateIncremental(from: a1)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: sum), .number(15))
    }

    func testSetFormula_constantsDoNotTrackDependencies() throws {
        // `=42` IS a formula cell (Excel shows it in the formula bar, and
        // testSetFormula_simpleNumber / testDeleteCell_removesFromGraph
        // both rely on that). What a constant must not do is create
        // dependency edges - it reads no cells, so nothing depends on it.
        let addr = CellAddr(col: 0, row: 0)
        let dirty = try engine.setFormula(sheet: nil, addr: addr, source: "=42")
        // Only the cell itself is recalculated; it has no dependents.
        XCTAssertEqual(dirty, [addr])
        XCTAssertTrue(engine.graph.allDependents(of: addr).subtracting([addr]).isEmpty)
    }

    // MARK: - Named Ranges

    func testDefineName() throws {
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 1, row: 1))
        let ok = engine.defineName("MyRange", range: range, sheet: nil)
        XCTAssertTrue(ok)

        // Re-defining fails
        let dup = engine.defineName("MyRange", range: range, sheet: nil)
        XCTAssertFalse(dup)
    }

    func testUndefineName() {
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 1, row: 1))
        engine.defineName("TempRange", range: range, sheet: nil)
        engine.undefineName("TempRange")
        XCTAssertNil(engine.namedRanges["TempRange"])
    }

    func testNamedRanges_list() throws {
        let r1 = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0))
        let r2 = RangeRef(topLeft: CellAddr(col: 1, row: 0), bottomRight: CellAddr(col: 1, row: 0))
        engine.defineName("Rate", range: r1, sheet: nil)
        engine.defineName("Base", range: r2, sheet: nil)
        XCTAssertEqual(engine.namedRanges.keys.sorted(), ["Base", "Rate"])
    }

    // MARK: - Sheets

    func testCreateSheet() {
        let ok = engine.createSheet(name: "Data")
        XCTAssertNotNil(ok)
        XCTAssertTrue(engine.sheetNames.contains("Data"))
    }

    func testCreateSheet_duplicateReturnsNil() {
        engine.createSheet(name: "Dup")
        let dup = engine.createSheet(name: "Dup")
        XCTAssertNil(dup)
    }

    func testDeleteSheet_lastSheetFails() {
        // Engine starts with Sheet1, can delete it (has more than 1)
        engine.createSheet(name: "Extra")
        engine.deleteSheet("Extra")
        XCTAssertFalse(engine.sheetNames.contains("Extra"))
    }

    /// A formula elsewhere that references the deleted sheet must
    /// become `#REF!`, the same treatment a reference into a deleted
    /// row or column already gets - not silently keep reading null off
    /// a sheet that no longer exists.
    func testDeleteSheet_referencingFormulaBecomesRefError() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)
        engine.setValue(sheet: "Data", addr: a1, value: .number(7))
        try engine.setFormula(sheet: "Sheet1", addr: b1, source: "='Data'!A1+1")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(8))

        engine.deleteSheet("Data")

        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: b1), "=#REF!+1")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .error(.referenceInvalid))
    }

    /// An unqualified reference is untouched by deleting some OTHER
    /// sheet - "same sheet as this formula" must never become #REF!
    /// just because an unrelated sheet was removed.
    func testDeleteSheet_leavesUnqualifiedReferencesAlone() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)
        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(9))
        try engine.setFormula(sheet: "Sheet1", addr: b1, source: "=A1*3")

        engine.deleteSheet("Data")

        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: b1), "=A1*3")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(27))
    }

    /// A cross-sheet RANGE reference into the deleted sheet must also
    /// become #REF!, not just a single-cell reference.
    func testDeleteSheet_referencingRangeBecomesRefError() throws {
        engine.createSheet(name: "Data")
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 0), value: .number(1))
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 1), value: .number(2))
        let total = CellAddr(col: 1, row: 0)
        try engine.setFormula(sheet: "Sheet1", addr: total, source: "=SUM('Data'!A1:A2)")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: total), .number(3))

        engine.deleteSheet("Data")

        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: total), "=SUM(#REF!)")
    }

    func testRenameSheet() {
        engine.createSheet(name: "Old")
        let ok = engine.renameSheet(from: "Old", to: "New")
        XCTAssertTrue(ok)
        XCTAssertTrue(engine.sheetNames.contains("New"))
        XCTAssertFalse(engine.sheetNames.contains("Old"))
    }

    func testRenameSheet_conflictFails() {
        engine.createSheet(name: "A")
        engine.createSheet(name: "B")
        let ok = engine.renameSheet(from: "A", to: "B")
        XCTAssertFalse(ok)
    }

    func testSetActiveSheet() {
        engine.createSheet(name: "Data")
        engine.setActiveSheet("Data")
        XCTAssertEqual(engine.activeSheet, "Data")
    }

    func testGetValue_crossSheet() throws {
        engine.createSheet(name: "Sheet2")
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(99))
        engine.setValue(sheet: "Sheet2", addr: CellAddr(col: 0, row: 0), value: .number(1))

        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0)), .number(99))
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: CellAddr(col: 0, row: 0)), .number(1))
    }

    /// Same (col, row) on two different sheets used to collide in the
    /// dependency graph - `CellAddr` alone was the graph's node key, with
    /// no sheet dimension. A formula on Sheet2 reading its own A1 would
    /// register a precedent edge indistinguishable from a Sheet1!A1
    /// formula's edge. This is the regression test for that collision:
    /// both sheets hold a same-address formula, and each must track its
    /// OWN precedent, not the other's.
    func testFormulaDependency_doesNotCollideAcrossSheetsAtTheSameAddress() throws {
        engine.createSheet(name: "Sheet2")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)

        try engine.setFormula(sheet: "Sheet1", addr: b1, source: "=A1*10")
        try engine.setFormula(sheet: "Sheet2", addr: b1, source: "=A1*1000")

        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(1))
        engine.setValue(sheet: "Sheet2", addr: a1, value: .number(1))

        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(10),
                        "Sheet1!B1 must use Sheet1's formula and Sheet1's A1")
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: b1), .number(1000),
                        "Sheet2!B1 must use Sheet2's formula and Sheet2's A1, not Sheet1's")

        // Editing Sheet1!A1 must not dirty Sheet2!B1 - they are unrelated
        // cells that happen to share a (col, row).
        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(5))
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(50))
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: b1), .number(1000),
                        "editing Sheet1!A1 must not recompute Sheet2!B1")
    }

    /// A formula that explicitly qualifies another sheet
    /// (`='Sheet1'!A1*2`) must read and track that sheet - not silently
    /// resolve against whichever sheet is active when it recalculates.
    ///
    /// Quoted here, though bare (`=Sheet1!A1*2`) now parses identically
    /// too (see `LexerSheetQualifierTests`) - at the time this test was
    /// written, `scanIdentifier` never looked ahead for `!` after a bare
    /// name, so an unquoted sheet-qualified reference silently became a
    /// named-range lookup that dropped everything after the `!`, or
    /// threw inside a function call. Kept quoted here since that is
    /// what every other test in this file already uses.
    func testFormulaDependency_explicitCrossSheetReferenceTracksTheNamedSheet() throws {
        engine.createSheet(name: "Sheet2")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)

        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(3))
        try engine.setFormula(sheet: "Sheet2", addr: b1, source: "='Sheet1'!A1*2")
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: b1), .number(6))

        // Sheet1 is not active; recalculating Sheet2!B1 must still read
        // Sheet1!A1, not whatever Sheet2!A1 (the active sheet's A1) holds.
        engine.setActiveSheet("Sheet1")
        engine.setValue(sheet: "Sheet2", addr: a1, value: .number(999))
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: b1), .number(6),
                        "Sheet2!A1 changing must not affect a formula that reads Sheet1!A1")

        // Changing the cell the formula ACTUALLY reads must dirty it,
        // even though Sheet1 (not Sheet2) is the active sheet.
        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(10))
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: b1), .number(20),
                        "editing Sheet1!A1 must recompute the Sheet2 formula that reads it")
    }

    /// Renaming a sheet must preserve every cell on it. A prior version
    /// removed the old `WorkbookSheet` and immediately replaced it with a
    /// fresh, empty one under the new name - discarding every cell the
    /// sheet held.
    func testRenameSheet_preservesCellData() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)
        engine.setValue(sheet: "Data", addr: a1, value: .number(42))
        try engine.setFormula(sheet: "Data", addr: b1, source: "=A1+1")

        XCTAssertTrue(engine.renameSheet(from: "Data", to: "Renamed"))

        XCTAssertEqual(engine.getValue(sheet: "Renamed", addr: a1), .number(42),
                        "the renamed sheet must keep its literal value")
        XCTAssertEqual(engine.getValue(sheet: "Renamed", addr: b1), .number(43),
                        "the renamed sheet must keep its formula and its computed result")
    }

    /// A formula elsewhere that references the renamed sheet by its OLD
    /// name must follow the rename - both structurally (the graph edge
    /// still triggers recalculation) and in its stored TEXT (so
    /// evaluating it doesn't resolve against a sheet name that no
    /// longer exists).
    func testRenameSheet_updatesCrossSheetFormulaReferences() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)
        engine.setValue(sheet: "Data", addr: a1, value: .number(7))
        try engine.setFormula(sheet: "Sheet1", addr: b1, source: "='Data'!A1*2")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(14))

        XCTAssertTrue(engine.renameSheet(from: "Data", to: "Renamed"))

        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: b1), "='Renamed'!A1*2",
                        "the formula's own stored text must follow the rename")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(14),
                        "and it must still evaluate correctly right after the rename")

        // The graph edge must have followed the rename too: editing the
        // renamed sheet's A1 still dirties the referencing formula.
        engine.setValue(sheet: "Renamed", addr: a1, value: .number(100))
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(200),
                        "editing Renamed!A1 must recompute the formula that reads it")
    }

    /// A formula ON the renamed sheet that references its OWN sheet by
    /// name (`=ThisSheet!A1`, unusual but legal) must also follow.
    func testRenameSheet_updatesSelfReferencingFormulaText() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)
        engine.setValue(sheet: "Data", addr: a1, value: .number(5))
        try engine.setFormula(sheet: "Data", addr: b1, source: "='Data'!A1+1")

        XCTAssertTrue(engine.renameSheet(from: "Data", to: "Renamed"))

        XCTAssertEqual(engine.getFormula(sheet: "Renamed", addr: b1), "='Renamed'!A1+1")
        XCTAssertEqual(engine.getValue(sheet: "Renamed", addr: b1), .number(6))
    }

    /// An UNQUALIFIED reference must never be touched by a rename of some
    /// OTHER sheet - "same sheet as this formula" must not turn into a
    /// pointer at the renamed sheet just because the names happened to
    /// land in the same rewrite pass.
    func testRenameSheet_leavesUnqualifiedReferencesAlone() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        let b1 = CellAddr(col: 1, row: 0)
        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(9))
        try engine.setFormula(sheet: "Sheet1", addr: b1, source: "=A1*3")

        XCTAssertTrue(engine.renameSheet(from: "Data", to: "Renamed"))

        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: b1), "=A1*3")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: b1), .number(27))
    }

    /// The whole rename cascade - however many formulas reference the
    /// renamed sheet - must collapse into ONE undo step, not one per
    /// affected formula.
    func testRenameSheet_cascadingRewritesAreOneUndoStep() throws {
        engine.createSheet(name: "Data")
        let a1 = CellAddr(col: 0, row: 0)
        engine.setValue(sheet: "Data", addr: a1, value: .number(1))
        try engine.setFormula(sheet: "Sheet1", addr: CellAddr(col: 1, row: 0), source: "='Data'!A1+1")
        try engine.setFormula(sheet: "Sheet1", addr: CellAddr(col: 2, row: 0), source: "='Data'!A1+2")
        try engine.setFormula(sheet: "Sheet1", addr: CellAddr(col: 3, row: 0), source: "='Data'!A1+3")

        XCTAssertTrue(engine.renameSheet(from: "Data", to: "Renamed"))
        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: CellAddr(col: 3, row: 0)), "='Renamed'!A1+3")

        // One undo call reverts every rewritten formula's text at once.
        _ = engine.undo()
        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: CellAddr(col: 1, row: 0)), "='Data'!A1+1")
        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: CellAddr(col: 2, row: 0)), "='Data'!A1+2")
        XCTAssertEqual(engine.getFormula(sheet: "Sheet1", addr: CellAddr(col: 3, row: 0)), "='Data'!A1+3")
    }

    /// A cross-sheet RANGE reference must track the range's own sheet
    /// for every cell it expands to - not just the range node itself.
    /// `FormulaAST.collectCells()`'s `.range` case used to drop the
    /// range's sheet when expanding it into individual `CellRef`s
    /// (defaulting to nil = "current sheet"), which was harmless while
    /// the graph collapsed sheet+address into one bare `CellAddr`
    /// anyway, but produced bogus same-sheet precedent edges once the
    /// graph became sheet-aware: `=SUM('Data'!A1:A3)` on Sheet1 would
    /// wrongly also depend on Sheet1's own A1:A3.
    func testFormulaDependency_crossSheetRangeTracksTheRangesOwnSheet() throws {
        engine.createSheet(name: "Data")
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 0), value: .number(1))
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 1), value: .number(2))
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 2), value: .number(3))
        // Sheet1's OWN A1:A3 holds different numbers - if the range
        // expansion wrongly lands on Sheet1 instead of Data, this total
        // would silently come out as 60 (10+20+30), not 6.
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(10))
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 1), value: .number(20))
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 2), value: .number(30))

        let total = CellAddr(col: 1, row: 0)
        try engine.setFormula(sheet: "Sheet1", addr: total, source: "=SUM('Data'!A1:A3)")
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: total), .number(6))

        // Editing Sheet1's own A1 (same coordinate, wrong sheet) must
        // NOT dirty the SUM - it only depends on Data's A1:A3.
        engine.setValue(sheet: "Sheet1", addr: CellAddr(col: 0, row: 0), value: .number(999))
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: total), .number(6),
                        "the SUM must not depend on Sheet1's own A1:A3")

        // Editing Data's A2 (the range it actually reads) must dirty it.
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 1), value: .number(200))
        XCTAssertEqual(engine.getValue(sheet: "Sheet1", addr: total), .number(204))
    }

    /// A named range with no explicit sheet restriction must resolve
    /// against the CALLING FORMULA's own sheet, not the workbook's
    /// active tab - the same "which sheet" defect this whole fix exists
    /// to close, surviving in the named-range path via
    /// `resolveNamedRangeUnlocked`'s old `_activeSheet` fallback.
    func testNamedRange_unscoped_resolvesAgainstTheCallingFormulasSheet() throws {
        engine.createSheet(name: "Sheet2")
        let a1 = CellAddr(col: 0, row: 0)
        engine.setValue(sheet: "Sheet1", addr: a1, value: .number(1))
        engine.setValue(sheet: "Sheet2", addr: a1, value: .number(2))
        XCTAssertTrue(engine.defineName("MyCell", range: RangeRef(topLeft: a1, bottomRight: a1)))

        let b1 = CellAddr(col: 1, row: 0)
        try engine.setFormula(sheet: "Sheet2", addr: b1, source: "=MyCell*10")

        engine.setActiveSheet("Sheet1")
        XCTAssertEqual(engine.getValue(sheet: "Sheet2", addr: b1), .number(20),
                        "MyCell in a Sheet2 formula must read Sheet2!A1 (2), not the active Sheet1!A1 (1)")
    }

    // MARK: - Ranges

    func testGetRange() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 1, row: 1)
        engine.setValue(sheet: nil, addr: a1, value: .number(1))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(3))
        engine.setValue(sheet: nil, addr: a2, value: .number(4))

        let range = RangeRef(topLeft: a1, bottomRight: a2)
        let rows: [[Value]] = engine.getRange(sheet: nil, range: range)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[0][0], .number(1))
        XCTAssertEqual(rows[0][1], .number(2))
        XCTAssertEqual(rows[1][0], .number(3))
        XCTAssertEqual(rows[1][1], .number(4))
    }

    func testGetColumnSlice() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(1))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 2), value: .string("three"))

        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 2))
        let slice = engine.getColumnSlice(sheet: nil, range: range)
        XCTAssertEqual(slice.count, 3)
        XCTAssertEqual(slice.numbers[0], 1)
        XCTAssertEqual(slice.numbers[1], 2)
        XCTAssertEqual(slice.numbers[2], nil)
        XCTAssertEqual(slice.strings[2], "three")
    }

    // MARK: - Undo/Redo

    func testUndo_valueChange() throws {
        let addr = CellAddr(col: 0, row: 0)
        engine.setValue(sheet: nil, addr: addr, value: .number(10))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(10))

        engine.setValue(sheet: nil, addr: addr, value: .number(20))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(20))

        let undone = engine.undo()
        XCTAssertNotNil(undone)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(10))
    }

    func testRedo() throws {
        let addr = CellAddr(col: 0, row: 0)
        engine.setValue(sheet: nil, addr: addr, value: .number(5))
        engine.setValue(sheet: nil, addr: addr, value: .number(15))
        engine.undo()
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(5))

        let redone = engine.redo()
        XCTAssertNotNil(redone)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(15))
    }

    func testUndo_formulaChange() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=10")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(10))

        try engine.setFormula(sheet: nil, addr: addr, source: "=20")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(20))

        engine.undo()
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .number(10))
    }

    func testUndo_grouped() throws {
        let addr1 = CellAddr(col: 0, row: 0)
        let addr2 = CellAddr(col: 0, row: 1)
        engine.beginEditGroup()
        engine.setValue(sheet: nil, addr: addr1, value: .number(1))
        engine.setValue(sheet: nil, addr: addr2, value: .number(2))
        engine.endEditGroup()

        engine.undo()  // Should undo both as one step
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr1), .null)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr2), .null)
    }

    /// Undo availability is read off `undoStack`; the engine forwards the
    /// verbs (`undo()`/`redo()`) but not the predicates.
    func testCanUndo_canRedo() throws {
        XCTAssertFalse(engine.undoStack.canUndo)
        XCTAssertFalse(engine.undoStack.canRedo)

        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(1))
        XCTAssertTrue(engine.undoStack.canUndo)
        XCTAssertFalse(engine.undoStack.canRedo)

        _ = engine.undo()
        XCTAssertFalse(engine.undoStack.canUndo)
        XCTAssertTrue(engine.undoStack.canRedo)
    }

    // MARK: - Serialization

    func testSerialize_workbookState() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(42))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=A1*2")
        engine.defineName("MyName", range: RangeRef(
            topLeft: CellAddr(col: 0, row: 0),
            bottomRight: CellAddr(col: 0, row: 0)
        ), sheet: nil)

        let state = engine.serialize()
        XCTAssertEqual(state.activeSheet, "Sheet1")
        XCTAssertEqual(state.sheets.count, 1)
        XCTAssertEqual(state.namedRanges.keys.first, "MyName")
    }

    // MARK: - Error Propagation

    func testErrorInPrecedent_propagates() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        let a3 = CellAddr(col: 0, row: 2)

        try engine.setFormula(sheet: nil, addr: a1, source: "=1/0")
        try engine.setFormula(sheet: nil, addr: a2, source: "=A1+1")
        try engine.setFormula(sheet: nil, addr: a3, source: "=A2*2")

        XCTAssertEqual(engine.getValue(sheet: nil, addr: a1), .error(.divisionByZero))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: a2), .error(.divisionByZero))
        XCTAssertEqual(engine.getValue(sheet: nil, addr: a3), .error(.divisionByZero))
    }

    // MARK: - String Functions

    func testConcatenate() throws {
        let a1 = CellAddr(col: 0, row: 0)
        let a2 = CellAddr(col: 0, row: 1)
        engine.setValue(sheet: nil, addr: a1, value: .string("Hello"))
        engine.setValue(sheet: nil, addr: a2, value: .string("World"))

        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=A1&\" \"&A2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .string("Hello World"))
    }

    func testLen() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .string("hello"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=LEN(A1)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(5))
    }

    func testLeft() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .string("Hello"))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=LEFT(A1,4)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .string("Hell"))
    }

    func testTrim() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .string("  hello   world  "))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=TRIM(A1)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .string("hello world"))
    }

    // MARK: - Logical Functions

    func testIF_trueBranch() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(10))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=IF(A1>5,\"big\",\"small\")")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .string("big"))
    }

    func testIF_falseBranch() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(3))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=IF(A1>5,\"big\",\"small\")")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .string("small"))
    }

    func testIFERROR() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=1/0")
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=IFERROR(A1,\"fallback\")")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .string("fallback"))
    }

    func testAND() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .bool(true))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .bool(false))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=AND(A1,A2)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .bool(false))
    }

    func testOR() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .bool(false))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .bool(true))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=OR(A1,A2)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .bool(true))
    }

    // MARK: - Math Functions

    func testABS() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(-42))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=ABS(A1)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(42))
    }

    func testROUND() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(3.14159))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=ROUND(A1,2)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(3.14))
    }

    func testSQRT() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=SQRT(16)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 0, row: 0)), .number(4))
    }

    func testMOD() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=MOD(17,5)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 0, row: 0)), .number(2))
    }

    func testPOWER() throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 0, row: 0), source: "=POWER(2,3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 0, row: 0)), .number(8))
    }

    func testINT() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(3.9))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=INT(A1)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(3))
    }

    func testSUM() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(1))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 2), value: .number(3))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=SUM(A1:A3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(6))
    }

    func testPRODUCT() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(3))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 2), value: .number(4))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=PRODUCT(A1:A3)")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(24))
    }

    // MARK: - Comparison Operators

    func testComparison_lessThan() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(3))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(5))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=A1<A2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .bool(true))
    }

    func testComparison_greaterOrEqual() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(5))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(5))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=A1>=A2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .bool(true))
    }

    // MARK: - Clear / Delete

    func testClearCell() throws {
        let addr = CellAddr(col: 0, row: 0)
        engine.setValue(sheet: nil, addr: addr, value: .number(99))
        engine.clearCell(sheet: nil, addr: addr)
        XCTAssertEqual(engine.getValue(sheet: nil, addr: addr), .null)
    }

    func testDeleteCell_removesFromGraph() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=42")
        XCTAssertFalse(engine.graph.formulaCells.isEmpty)
        engine.deleteCell(sheet: nil, addr: addr)
        XCTAssertTrue(engine.graph.formulaCells.isEmpty)
    }

    // MARK: - Recalculation

    func testRecalculate_allDirty() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(5))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(3))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 0), source: "=A1*A2")
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(15))

        // Force mark as dirty without changing values
        _ = engine.markDirty(addr: CellAddr(col: 0, row: 0))
        engine.recalculate()
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 1, row: 0)), .number(15))
    }

    // MARK: - Volatile Functions

    func testVolatileCell_markedInGraph() throws {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=NOW()")
        XCTAssertTrue(engine.graph.isVolatile(addr))
        XCTAssertTrue(engine.graph.volatile.contains(addr))
    }

    func testNonVolatileCell_notMarkedVolatile() throws {
        // A1 must not sum a range containing A1 - that is a genuine
        // circular reference (Excel reports one too), and the engine
        // correctly throws. Sum a different column.
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=SUM(B1:B10)")
        XCTAssertFalse(engine.graph.isVolatile(addr))
    }
}
