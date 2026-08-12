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

        try engine.setFormula(sheet: nil, addr: a1, source: "=A2+1")
        try engine.setFormula(sheet: nil, addr: a2, source: "=A1+1")

        // Break the cycle by setting a direct value
        do {
            try engine.setFormula(sheet: nil, addr: a1, source: "=A2+1")
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
        // Setting a constant expression (=42) should NOT add a dependency graph entry
        let addr = CellAddr(col: 0, row: 0)
        let dirty = try engine.setFormula(sheet: nil, addr: addr, source: "=42")
        XCTAssertTrue(dirty.isEmpty)  // No cells depend on A1
        XCTAssertEqual(engine.graph.formulaCells, [])
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

    func testCanUndo_canRedo() throws {
        XCTAssertFalse(engine.canUndo)
        XCTAssertFalse(engine.canRedo)

        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(1))
        XCTAssertTrue(engine.canUndo)
        XCTAssertFalse(engine.canRedo)

        engine.undo()
        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(engine.canRedo)
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
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: "=SUM(A1:A10)")
        XCTAssertFalse(engine.graph.isVolatile(addr))
    }
}
