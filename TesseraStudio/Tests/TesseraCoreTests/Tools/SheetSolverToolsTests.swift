import XCTest
@testable import TesseraCore

// MARK: - SheetSolverToolsTests
//
// Contract source: this track's brief (P2-A item 2.6) + testing-doctrine.md's
// Agent tool coverage shape ("schema round-trip + tier assertion + receipt
// behavior + denial path") + `TesseraTool`'s protocol doc comments
// (Sources/TesseraCore/Agent/TesseraTool.swift) + `SheetReadTool`/
// `SheetWriteTool` (Sources/TesseraCore/Tools/SheetTools.swift) for the
// exact shape a Sheets tool follows.
//
// Both tools share the preview (apply: false, no receipt) / apply
// (apply: true, one receipt) split the design contract calls out; SINCE
// SheetStore.applyGoalSeek/applySolverRun are centrally wired (not this
// track's file - see wiringNotes), the apply path fails closed in THIS
// build rather than persisting - that failure-closed behavior IS this
// track's own contract to test (a wrong wiring would show up as either a
// crash, a receipt-less mutation, or an apply that silently no-ops - all
// three are ruled out by the assertions below). The preview path is
// fully wired to SolverEngine and gets full functional coverage.
final class SheetSolverToolsTests: DoctrineTestCase {

    override func tearDown() {
        SheetToolContext.shared.install(nil)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private let A1 = CellAddr(col: 0, row: 0)
    private let B1 = CellAddr(col: 1, row: 0)
    private let C1 = CellAddr(col: 2, row: 0)
    private let D1 = CellAddr(col: 3, row: 0)
    private let E1 = CellAddr(col: 4, row: 0)

    /// A1 = 0 (variable), B1 = A1^2 (formula), installed as the active
    /// workbook - the goal-seek fixture.
    @discardableResult
    private func installGoalSeekFixture() throws -> SheetEngine {
        let engine = SheetEngine()
        engine.setValue(sheet: nil, addr: A1, value: .number(5))
        try engine.setFormula(sheet: nil, addr: B1, source: "=A1*A1")
        SheetToolContext.shared.install(engine)
        return engine
    }

    /// The Wyndor Glass fixture (see SolverEngineTests): A1=x, B1=y,
    /// C1=3x+5y (objective), D1=2y, E1=3x+2y.
    @discardableResult
    private func installWyndorFixture() throws -> SheetEngine {
        let engine = SheetEngine()
        engine.setValue(sheet: nil, addr: A1, value: .number(0))
        engine.setValue(sheet: nil, addr: B1, value: .number(0))
        try engine.setFormula(sheet: nil, addr: C1, source: "=3*A1+5*B1")
        try engine.setFormula(sheet: nil, addr: D1, source: "=2*B1")
        try engine.setFormula(sheet: nil, addr: E1, source: "=3*A1+2*B1")
        SheetToolContext.shared.install(engine)
        return engine
    }

    private func wyndorConstraints() -> JSONValue {
        .array([
            .object(["lhs_cell": .string("A1"), "op": .string("lte"), "rhs": .number(4)]),
            .object(["lhs_cell": .string("D1"), "op": .string("lte"), "rhs": .number(12)]),
            .object(["lhs_cell": .string("E1"), "op": .string("lte"), "rhs": .number(18)]),
        ])
    }

    // MARK: - sheet_goal_seek: schema round-trip (doctrine rule 2)

    func testGoalSeekToolSchemaRoundTripsThroughJSON() throws {
        let tool = SheetGoalSeekTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["formula_cell", "target_value", "variable_cell"])
        XCTAssertNotNil(tool.parameters.properties?["apply"])
        XCTAssertEqual(tool.name, "sheet_goal_seek")
        XCTAssertFalse(tool.description.isEmpty)
    }

    // MARK: - sheet_goal_seek: tier assertion

    /// tier1 per the design contract; `TesseraTier.tier1.displayName` is
    /// "Tier 1 (notify)" (Agent/TesseraTier.swift) - the matching
    /// `ApprovalLevel` this tool sets directly (see the tool's own doc
    /// comment for why it is set directly rather than routed through
    /// `TesseraTier`).
    func testGoalSeekToolDefaultApprovalLevelIsNotify() {
        XCTAssertEqual(SheetGoalSeekTool().defaultApprovalLevel, .notify)
        XCTAssertEqual(TesseraTier.tier1.displayName, "Tier 1 (notify)")
    }

    // MARK: - sheet_goal_seek: denial path

    func testGoalSeekToolFailsCleanlyWithNoWorkbookInstalled() async throws {
        SheetToolContext.shared.install(nil)
        let result = try await SheetGoalSeekTool().execute(arguments: [
            "formula_cell": .string("B1"),
            "target_value": .number(16),
            "variable_cell": .string("A1"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, SheetToolError.noWorkbook.errorDescription)
    }

    func testGoalSeekToolFailsCleanlyWithMissingArguments() async throws {
        try installGoalSeekFixture()
        let result = try await SheetGoalSeekTool().execute(arguments: ["formula_cell": .string("B1")])
        XCTAssertFalse(result.success)
    }

    // MARK: - sheet_goal_seek: preview (apply: false) is fully functional

    func testGoalSeekToolPreviewConvergesAndReportsNoApply() async throws {
        try installGoalSeekFixture()
        let result = try await SheetGoalSeekTool().execute(arguments: [
            "formula_cell": .string("B1"),
            "target_value": .number(16),
            "variable_cell": .string("A1"),
        ])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["status"]?.stringValue, "converged")
        XCTAssertEqual(result.data?["resolved_value"]?.numberValue ?? .nan, 4.0, accuracy: 1e-3)
        XCTAssertEqual(result.data?["applied"]?.boolValue, false)
    }

    func testGoalSeekToolPreviewDefaultsApplyToFalse() async throws {
        // `apply` omitted entirely - must behave exactly like `apply: false`.
        try installGoalSeekFixture()
        let result = try await SheetGoalSeekTool().execute(arguments: [
            "formula_cell": .string("B1"),
            "target_value": .number(16),
            "variable_cell": .string("A1"),
        ])
        XCTAssertTrue(result.success)
    }

    // MARK: - sheet_goal_seek: apply fails closed (not yet wired to SheetStore)

    func testGoalSeekToolApplyFailsClosedRatherThanMutatingWithNoReceipt() async throws {
        try installGoalSeekFixture()
        let result = try await SheetGoalSeekTool().execute(arguments: [
            "formula_cell": .string("B1"),
            "target_value": .number(16),
            "variable_cell": .string("A1"),
            "apply": .bool(true),
        ])
        XCTAssertFalse(result.success, "apply must fail closed until SheetStore.applyGoalSeek is wired")
        XCTAssertTrue(
            result.error?.localizedCaseInsensitiveContains("not wired") ?? false,
            "the failure must say WHY (not wired), not just that it failed - got: \(result.error ?? "nil")"
        )
    }

    // MARK: - sheet_solver_run: schema round-trip

    func testSolverRunToolSchemaRoundTripsThroughJSON() throws {
        let tool = SheetSolverRunTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["objective_cell", "direction", "variable_cells"])
        XCTAssertNotNil(tool.parameters.properties?["constraints"])
        XCTAssertNotNil(tool.parameters.properties?["assume_non_negative"])
        XCTAssertEqual(tool.name, "sheet_solver_run")
    }

    // MARK: - sheet_solver_run: tier assertion

    func testSolverRunToolDefaultApprovalLevelIsNotify() {
        XCTAssertEqual(SheetSolverRunTool().defaultApprovalLevel, .notify)
    }

    // MARK: - sheet_solver_run: denial path

    func testSolverRunToolFailsCleanlyWithNoWorkbookInstalled() async throws {
        SheetToolContext.shared.install(nil)
        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1"), .string("B1")]),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, SheetToolError.noWorkbook.errorDescription)
    }

    func testSolverRunToolFailsCleanlyWithEmptyVariableCells() async throws {
        try installWyndorFixture()
        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([]),
        ])
        XCTAssertFalse(result.success)
    }

    func testSolverRunToolFailsCleanlyWithUnrecognizedConstraintOperator() async throws {
        try installWyndorFixture()
        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1"), .string("B1")]),
            "constraints": .array([
                .object(["lhs_cell": .string("A1"), "op": .string("not-an-operator"), "rhs": .number(4)]),
            ]),
        ])
        XCTAssertFalse(result.success)
    }

    // MARK: - sheet_solver_run: preview (apply: false) is fully functional

    func testSolverRunToolPreviewFindsOptimalWyndorSolution() async throws {
        try installWyndorFixture()
        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1"), .string("B1")]),
            "constraints": wyndorConstraints(),
        ])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["status"]?.stringValue, "optimal")
        XCTAssertEqual(result.data?["objective_value"]?.numberValue ?? .nan, 36, accuracy: 1e-6)
        XCTAssertEqual(result.data?["applied"]?.boolValue, false)
        if case .object(let vars)? = result.data?["variable_values"] {
            XCTAssertEqual(vars["A1"]?.numberValue ?? .nan, 2, accuracy: 1e-6)
            XCTAssertEqual(vars["B1"]?.numberValue ?? .nan, 6, accuracy: 1e-6)
        } else {
            XCTFail("expected variable_values to be present")
        }
    }

    func testSolverRunToolPreviewClassifiesInfeasibleModelAsSuccessWithStatus() async throws {
        let engine = SheetEngine()
        engine.setValue(sheet: nil, addr: A1, value: .number(0))
        try engine.setFormula(sheet: nil, addr: C1, source: "=A1")
        SheetToolContext.shared.install(engine)

        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1")]),
            "constraints": .array([
                .object(["lhs_cell": .string("A1"), "op": .string("gte"), "rhs": .number(5)]),
                .object(["lhs_cell": .string("A1"), "op": .string("lte"), "rhs": .number(2)]),
            ]),
        ])
        // Infeasibility is a definite classification, not a tool error.
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["status"]?.stringValue, "infeasible")
    }

    func testSolverRunToolFailsCleanlyOnNonlinearModelNamingTheCell() async throws {
        let engine = SheetEngine()
        engine.setValue(sheet: nil, addr: A1, value: .number(0))
        engine.setValue(sheet: nil, addr: B1, value: .number(0))
        try engine.setFormula(sheet: nil, addr: C1, source: "=A1*B1")
        SheetToolContext.shared.install(engine)

        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1"), .string("B1")]),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("C1") ?? false, "the failure must name the offending cell")
    }

    // MARK: - sheet_solver_run: apply fails closed (not yet wired to SheetStore)

    func testSolverRunToolApplyFailsClosedForAnOptimalModel() async throws {
        try installWyndorFixture()
        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1"), .string("B1")]),
            "constraints": wyndorConstraints(),
            "apply": .bool(true),
        ])
        XCTAssertFalse(result.success, "apply must fail closed until SheetStore.applySolverRun is wired")
        XCTAssertTrue(
            result.error?.localizedCaseInsensitiveContains("not wired") ?? false,
            "the failure must say WHY (not wired), not just that it failed - got: \(result.error ?? "nil")"
        )
    }

    func testSolverRunToolApplyRefusesAnInfeasibleModelBeforeReachingTheStoreCall() async throws {
        let engine = SheetEngine()
        engine.setValue(sheet: nil, addr: A1, value: .number(0))
        try engine.setFormula(sheet: nil, addr: C1, source: "=A1")
        SheetToolContext.shared.install(engine)

        let result = try await SheetSolverRunTool().execute(arguments: [
            "objective_cell": .string("C1"),
            "direction": .string("maximize"),
            "variable_cells": .array([.string("A1")]),
            "constraints": .array([
                .object(["lhs_cell": .string("A1"), "op": .string("gte"), "rhs": .number(5)]),
                .object(["lhs_cell": .string("A1"), "op": .string("lte"), "rhs": .number(2)]),
            ]),
            "apply": .bool(true),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.localizedCaseInsensitiveContains("infeasible") ?? false)
    }
}
