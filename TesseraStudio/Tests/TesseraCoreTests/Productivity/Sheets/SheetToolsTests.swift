import XCTest
@testable import TesseraCore

/// The agent's sheet tools.
///
/// Before these existed the agent could quantize a model and search the
/// web but could not read a cell. The invariants worth holding: reads
/// never mutate, writes are gated by the safety spine, and a tool with
/// no workbook installed says so rather than inventing one.
final class SheetToolsTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
        // B1:C3 - a small labelled table.
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .string("Widget"))
        engine.setValue(sheet: nil, addr: CellAddr(col: 2, row: 0), value: .number(10))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 1), value: .string("Gadget"))
        engine.setValue(sheet: nil, addr: CellAddr(col: 2, row: 1), value: .number(20))
        SheetToolContext.shared.install(engine)
    }

    override func tearDown() {
        SheetToolContext.shared.install(nil)
        engine = nil
        super.tearDown()
    }

    // MARK: - sheet_read

    func testReadSingleCell() async throws {
        let result = try await SheetReadTool().execute(arguments: ["reference": .string("C1")])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "10")
    }

    /// A range comes back as TSV so rows and columns are unambiguous.
    func testReadRangeAsTSV() async throws {
        let result = try await SheetReadTool().execute(arguments: ["reference": .string("B1:C2")])
        XCTAssertEqual(result.output, "Widget\t10\nGadget\t20")
    }

    /// A formula reads as its computed value, not its source text.
    func testReadReturnsComputedValue() async throws {
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 2), source: "=SUM(C1:C2)")
        let result = try await SheetReadTool().execute(arguments: ["reference": .string("C3")])
        XCTAssertEqual(result.output, "30")
    }

    func testReadRejectsUnparseableReference() async throws {
        let result = try await SheetReadTool().execute(arguments: ["reference": .string("not a ref")])
        XCTAssertFalse(result.success)
    }

    func testReadRequiresReference() async throws {
        let result = try await SheetReadTool().execute(arguments: [:])
        XCTAssertFalse(result.success)
    }

    // MARK: - sheet_write

    func testWriteLiteralNumberIsTyped() async throws {
        let result = try await SheetWriteTool().execute(arguments: [
            "reference": .string("C3"), "value": .string("42"),
        ])
        XCTAssertTrue(result.success)
        // Stored as a number, so it aggregates rather than sitting as text.
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 2, row: 2)), .number(42))
    }

    func testWriteFormulaIsStoredAsFormula() async throws {
        _ = try await SheetWriteTool().execute(arguments: [
            "reference": .string("C3"), "value": .string("=SUM(C1:C2)"),
        ])
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 2, row: 2)), .number(30))
        XCTAssertTrue(engine.hasFormula(sheet: nil, addr: CellAddr(col: 2, row: 2)))
    }

    /// The response echoes the computed result, so the agent sees what
    /// the write produced rather than what it sent.
    func testWriteEchoesComputedResult() async throws {
        let result = try await SheetWriteTool().execute(arguments: [
            "reference": .string("C3"), "value": .string("=C1*2"),
        ])
        XCTAssertTrue(result.output.contains("20"))
    }

    func testWriteRangeRepeatsValue() async throws {
        let result = try await SheetWriteTool().execute(arguments: [
            "reference": .string("E1:E3"), "value": .string("7"),
        ])
        XCTAssertTrue(result.success)
        for row in 0..<3 {
            XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 4, row: row)), .number(7))
        }
    }

    func testWriteBooleanIsTyped() async throws {
        _ = try await SheetWriteTool().execute(arguments: [
            "reference": .string("E1"), "value": .string("TRUE"),
        ])
        XCTAssertEqual(engine.getValue(sheet: nil, addr: CellAddr(col: 4, row: 0)), .bool(true))
    }

    /// A circular reference names the offending cell instead of failing
    /// with a bare message.
    func testWriteReportsTheCellThatFailed() async throws {
        let result = try await SheetWriteTool().execute(arguments: [
            "reference": .string("E1"), "value": .string("=E1+1"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("E1") == true, "error should name the cell: \(result.error ?? "")")
    }

    // MARK: - Gating

    /// Writes must be gated; reads must not be. This is what routes a
    /// cell change through the approval sheet.
    func testWriteIsPromptedAndReadsAreNot() {
        XCTAssertEqual(SheetWriteTool().defaultApprovalLevel, .prompt)
        XCTAssertEqual(SheetReadTool().defaultApprovalLevel, .auto)
        XCTAssertEqual(SheetDescribeTool().defaultApprovalLevel, .auto)
    }

    /// The safety spine must rate a sheet write as needing the user,
    /// even with the tool set to auto - the gate is what makes an agent
    /// edit to someone's model recoverable.
    func testSafetySpineAsksBeforeASheetWrite() {
        let decision = TesseraSafetyDecision(
            approvalPolicy: .auto,
            permissionProfile: .standard,
            sandboxEnforceable: true,
            actionRisk: (try? TesseraActionVerifier.ruleBasedRisk(
                for: PendingAction(toolName: "sheet_write", arguments: [:])
            )) ?? .medium
        )
        XCTAssertEqual(decision.check, .askUser)
    }

    // MARK: - sheet_describe

    func testDescribeListsSheetsAndExtent() async throws {
        let result = try await SheetDescribeTool().execute(arguments: [:])
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Sheet1"))
        // The data occupies B1:C2.
        XCTAssertTrue(result.output.contains("B1:C2"), result.output)
    }

    func testUsedExtentIsNilForAnEmptySheet() {
        let empty = SheetEngine()
        XCTAssertNil(empty.usedExtent(sheet: nil))
    }

    // MARK: - No workbook

    /// With nothing open the tools say so rather than inventing a
    /// workbook or crashing.
    func testToolsReportWhenNoWorkbookIsOpen() async throws {
        SheetToolContext.shared.install(nil)
        let read = try await SheetReadTool().execute(arguments: ["reference": .string("A1")])
        let write = try await SheetWriteTool().execute(arguments: [
            "reference": .string("A1"), "value": .string("1"),
        ])
        let describe = try await SheetDescribeTool().execute(arguments: [:])
        XCTAssertFalse(read.success)
        XCTAssertFalse(write.success)
        XCTAssertFalse(describe.success)
        XCTAssertTrue(read.error?.contains("No workbook") == true)
    }

    // MARK: - Persistence

    /// With a surface open, a tool write goes through its persistence
    /// path rather than only changing in-memory calculation. Otherwise
    /// an agent edit would vanish on reload and never reach the receipt
    /// chain - the opposite of an auditable edit.
    func testWriteUsesTheInstalledWriter() async throws {
        let recorder = WriteRecorder()
        SheetToolContext.shared.install(engine) { row, col, text in
            await recorder.record(row: row, col: col, text: text)
        }
        defer { SheetToolContext.shared.install(engine) }

        let result = try await SheetWriteTool().execute(arguments: [
            "reference": .string("C3"), "value": .string("=SUM(C1:C2)"),
        ])
        XCTAssertTrue(result.success)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.text, "=SUM(C1:C2)")
        XCTAssertEqual(result.data?["persisted"], .bool(true))
    }

    /// With no surface wired the write still calculates, but the
    /// response says it was not saved rather than implying it was.
    func testWriteWithoutAWriterSaysItWasNotSaved() async throws {
        // setUp installed the engine with no writer.
        let result = try await SheetWriteTool().execute(arguments: [
            "reference": .string("C3"), "value": .string("5"),
        ])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["persisted"], .bool(false))
        XCTAssertTrue(result.output.contains("not saved"), result.output)
    }

    /// A range write persists every cell it covers.
    func testRangeWritePersistsEachCell() async throws {
        let recorder = WriteRecorder()
        SheetToolContext.shared.install(engine) { row, col, text in
            await recorder.record(row: row, col: col, text: text)
        }
        defer { SheetToolContext.shared.install(engine) }

        _ = try await SheetWriteTool().execute(arguments: [
            "reference": .string("E1:E3"), "value": .string("7"),
        ])
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
    }

    /// Records the writes a tool routes through the surface.
    private actor WriteRecorder {
        private(set) var calls: [(row: Int, col: Int, text: String)] = []
        func record(row: Int, col: Int, text: String) {
            calls.append((row, col, text))
        }
    }

    // MARK: - Registration

    /// The tools have to be in the default registry or the agent never
    /// sees them.
    func testSheetToolsAreRegistered() {
        for name in ["sheet_read", "sheet_write", "sheet_describe"] {
            XCTAssertNotNil(TesseraToolRegistry.default.tool(named: name), "\(name) is not registered")
        }
    }
}
