//===----------------------------------------------------------------------===//
//  SheetSolverTools.swift
//  Tessera Studio
//
//  The agent's access to ``SolverEngine`` (design contract 2.6):
//  sheet_goal_seek and sheet_solver_run. Both tools share ONE shape -
//  see the type header on each - a `apply: false` (default) PREVIEW call
//  that only computes and reports a proposal (no receipt, no
//  persistence), and an `apply: true` call meant to commit it as one
//  receipted mutation. The apply path is not wired to a live SheetStore
//  yet (SheetStore.swift is centrally owned this wave, not this track's
//  file - see the wave brief and this track's findings file) - it fails
//  closed with a clear message rather than mutating without a receipt or
//  silently no-op-ing. See the `// TODO(P2-A centralized wiring pass)`
//  markers below for exactly what the centralized pass replaces.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Shared parsing helpers

enum SheetSolverToolError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let s): return s
        }
    }
}

enum SheetSolverToolSupport {
    /// Read/write hooks over `engine` for `SolverEngine`. Mirrors
    /// `SheetWriteTool`'s literal-write path: a plain numeric write
    /// through `setValue`, which already routes through the landed
    /// evaluator's full recalculation (see `SheetEngine.setValue`'s doc
    /// comment) - the same requirement `SolverCellIO`'s doc comment
    /// states.
    static func cellIO(engine: SheetEngine, sheet: String?) -> SolverCellIO {
        SolverCellIO(
            read: { addr in engine.getValue(sheet: sheet, addr: addr).asNumber ?? .nan },
            write: { addr, value in engine.setValue(sheet: sheet, addr: addr, value: .number(value)) }
        )
    }

    static func parseCell(_ raw: String) throws -> CellAddr {
        do {
            return try AddressParser.parseCell(raw).addr
        } catch {
            throw SheetSolverToolError.invalid("Could not parse cell reference '\(raw)'.")
        }
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard let value, case .array(let items) = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    static func parseCellList(_ value: JSONValue?) throws -> [CellAddr] {
        try stringArray(value).map { try parseCell($0) }
    }

    static func parseDirection(_ raw: String) throws -> SolverDirection {
        guard let direction = SolverDirection(rawValue: raw) else {
            throw SheetSolverToolError.invalid("direction must be 'minimize' or 'maximize', got '\(raw)'.")
        }
        return direction
    }

    static func parseOperator(_ raw: String) -> SolverConstraintOperator? {
        switch raw {
        case "lte", "<=": return .lessThanOrEqual
        case "gte", ">=": return .greaterThanOrEqual
        case "eq", "=", "==": return .equal
        default: return nil
        }
    }

    /// Parses the `constraints` argument: a JSON array of
    /// `{lhs_cell, op, rhs}` objects. The tool schema documents this
    /// shape in prose (`SchemaProperty` has no nested `items`/`properties`
    /// vocabulary in this codebase - see `EscalateReasoningTool`'s
    /// `type: "array"` fields for the same precedent), but the ARGUMENT
    /// value itself is unrestricted JSON (`JSONValue.array`/`.object`),
    /// so nothing stops a caller from sending structured constraints.
    static func parseConstraints(_ value: JSONValue?) throws -> [SolverConstraint] {
        guard let value else { return [] }
        guard case .array(let items) = value else {
            throw SheetSolverToolError.invalid("constraints must be an array of {lhs_cell, op, rhs} objects.")
        }
        var result: [SolverConstraint] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard case .object(let obj) = item else {
                throw SheetSolverToolError.invalid("Each constraint must be an object with lhs_cell, op, rhs.")
            }
            guard let lhsRaw = obj["lhs_cell"]?.stringValue else {
                throw SheetSolverToolError.invalid("A constraint is missing 'lhs_cell'.")
            }
            guard let opRaw = obj["op"]?.stringValue, let op = parseOperator(opRaw) else {
                throw SheetSolverToolError.invalid("A constraint has a missing/unrecognized 'op' (use lte, gte, or eq).")
            }
            guard let rhs = obj["rhs"]?.numberValue else {
                throw SheetSolverToolError.invalid("A constraint is missing 'rhs'.")
            }
            let lhsCell = try parseCell(lhsRaw)
            result.append(SolverConstraint(lhsCell: lhsCell, op: op, rhs: rhs))
        }
        return result
    }
}

// MARK: - sheet_goal_seek

/// Agent tool: goal seek (design contract 2.6). Adjusts one input cell
/// until a formula cell reads a target value.
///
/// **Approval.** `tier1` per the design contract - `TesseraTier.tier1`
/// is "internal notes, draft creation, status flips on owned records"
/// (`Agent/TesseraTier.swift`), whose `displayName` is "Tier 1
/// (notify)"; this tool sets `defaultApprovalLevel` to the matching
/// `ApprovalLevel.notify` directly (existing Sheets tools set
/// `ApprovalLevel` straight from their own risk judgment rather than
/// routing through `TesseraTier` at the call site - see
/// `SheetReadTool`/`SheetWriteTool` - so this follows the same shape,
/// not a new one). The preview call (`apply: false`) never touches the
/// document; the apply call (`apply: true`) is a single-cell write once
/// wired, the same blast radius `sheet_write` already runs at `.notify`
/// or stricter for.
public struct SheetGoalSeekTool: TesseraTool {
    public let name = "sheet_goal_seek"
    public let description = """
        Find the value for variable_cell that makes formula_cell equal target_value, \
        via iterative root-finding (secant method, bisection fallback) against the \
        live workbook - not a symbolic solve, so it works for any formula, linear or \
        not. Call with apply left false (the default) to preview the solved value \
        with no change to the workbook; call again with apply: true once the preview \
        looks right to commit it as one mutation.
        """
    public let defaultApprovalLevel = ApprovalLevel.notify

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "formula_cell": SchemaProperty(
                type: "string",
                description: "The formula cell to drive to target_value, e.g. B4."
            ),
            "target_value": SchemaProperty(
                type: "number",
                description: "The value formula_cell should equal."
            ),
            "variable_cell": SchemaProperty(
                type: "string",
                description: "The input cell to adjust, e.g. A1."
            ),
            "tolerance": SchemaProperty(
                type: "number",
                description: "Convergence tolerance on |formula_cell - target_value|. Default 1e-7."
            ),
            "sheet": SchemaProperty(
                type: "string",
                description: "Sheet name. Defaults to the active sheet."
            ),
            "apply": SchemaProperty(
                type: "boolean",
                description: "false (default): preview only, no receipt, no persisted change. true: commit the solved value as one receipted mutation.",
                defaultValue: "false"
            ),
        ],
        required: ["formula_cell", "target_value", "variable_cell"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let formulaCellRaw = arguments["formula_cell"]?.stringValue else {
            return .fail("Missing 'formula_cell'.")
        }
        guard let targetValue = arguments["target_value"]?.numberValue else {
            return .fail("Missing 'target_value'.")
        }
        guard let variableCellRaw = arguments["variable_cell"]?.stringValue else {
            return .fail("Missing 'variable_cell'.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let apply = arguments["apply"]?.boolValue ?? false

        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }

        let formulaCell: CellAddr
        let variableCell: CellAddr
        do {
            formulaCell = try SheetSolverToolSupport.parseCell(formulaCellRaw)
            variableCell = try SheetSolverToolSupport.parseCell(variableCellRaw)
        } catch {
            return .fail(error.localizedDescription)
        }

        var request = GoalSeekRequest(formulaCell: formulaCell, targetValue: targetValue, variableCell: variableCell)
        if let tolerance = arguments["tolerance"]?.numberValue, tolerance > 0 {
            request.tolerance = tolerance
        }

        let io = SheetSolverToolSupport.cellIO(engine: engine, sheet: sheet)
        let result = SolverEngine.goalSeek(request, io: io)

        let data: [String: JSONValue] = [
            "formula_cell": .string(formulaCellRaw),
            "variable_cell": .string(variableCellRaw),
            "target_value": .number(targetValue),
            "resolved_value": .number(result.resolvedValue),
            "achieved_value": .number(result.achievedValue),
            "iterations": .number(Double(result.iterations)),
            "status": .string(result.status.rawValue),
            "applied": .bool(false),
        ]
        let convergedNote = result.status == .converged ? "converged" : "did NOT converge"
        let summary = "Goal seek \(convergedNote) after \(result.iterations) iteration(s): " +
            "\(variableCellRaw) = \(result.resolvedValue) makes \(formulaCellRaw) = \(result.achievedValue) " +
            "(target \(targetValue))."

        guard apply else {
            return .ok(summary + " Preview only - call again with apply: true to commit.", data: data)
        }

        guard let sheetStore = SheetToolContext.shared.sheetStore, let sheetID = SheetToolContext.shared.sheetID else {
            return .fail(
                "Goal seek apply is not wired to the Sheets store in this build yet " +
                "(see SheetStore.applyGoalSeek in the P2-A wiring notes). Use apply: false to preview."
            )
        }
        do {
            _ = try await sheetStore.applyGoalSeek(request, result: result, for: sheetID)
        } catch {
            return .fail("Goal seek apply failed: \(error.localizedDescription)")
        }
        var appliedData = data
        appliedData["applied"] = .bool(true)
        return .ok(summary + " Applied.", data: appliedData)
    }
}

// MARK: - sheet_solver_run

/// Agent tool: linear Solver (design contract 2.6). Optimizes an
/// objective cell over a set of variable cells subject to linear
/// constraints, via a dense-tableau simplex with Bland's rule.
///
/// A model that fails the linearity probe is refused (`SolverEngine`
/// throws `SolverLinearityError.nonlinear(cell:)`) rather than solved as
/// if it were linear - this tool surfaces that as a normal `.fail(...)`
/// naming the offending cell, not a crash or a silently-wrong answer.
/// An infeasible or unbounded model is a DEFINITE, successful
/// classification, not an error - `execute` returns `.ok(...)` for
/// `.infeasible`/`.unbounded`/`.iterationLimitExceeded` too, with
/// `status` in the data payload saying which. `apply: true` on anything
/// other than `.optimal` is refused before it would even reach the
/// not-yet-wired store call, since there is nothing to commit.
///
/// **Approval.** Same `tier1` -> `ApprovalLevel.notify` mapping as
/// ``SheetGoalSeekTool`` - see that type's doc comment.
public struct SheetSolverRunTool: TesseraTool {
    public let name = "sheet_solver_run"
    public let description = """
        Optimize objective_cell (minimize or maximize) by varying variable_cells, \
        subject to linear constraints, via a linear-programming simplex solver. \
        Every cell touched (objective + every constraint's lhs_cell) must be LINEAR \
        in the variable cells - a nonlinear model is refused, naming the offending \
        cell, rather than solved incorrectly. Call with apply left false (the \
        default) to preview the optimal values with no change to the workbook; call \
        again with apply: true once the preview looks right to commit it as one \
        mutation. Nonlinear models (DEPS/SCO-style solving) are out of scope - use \
        sheet_goal_seek for a single nonlinear target instead.
        """
    public let defaultApprovalLevel = ApprovalLevel.notify

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "objective_cell": SchemaProperty(
                type: "string",
                description: "The formula cell to optimize, e.g. C1."
            ),
            "direction": SchemaProperty(
                type: "string",
                description: "minimize or maximize.",
                enumValues: ["minimize", "maximize"]
            ),
            "variable_cells": SchemaProperty(
                type: "array",
                description: "Cell references for the decision variables, e.g. [\"A1\", \"A2\"]."
            ),
            "constraints": SchemaProperty(
                type: "array",
                description: "Array of {lhs_cell, op, rhs} objects. op is one of: lte, gte, eq. Example: [{\"lhs_cell\": \"B1\", \"op\": \"lte\", \"rhs\": 18}]."
            ),
            "assume_non_negative": SchemaProperty(
                type: "boolean",
                description: "Whether every variable is bounded >= 0 (the common default). Default true.",
                defaultValue: "true"
            ),
            "sheet": SchemaProperty(
                type: "string",
                description: "Sheet name. Defaults to the active sheet."
            ),
            "apply": SchemaProperty(
                type: "boolean",
                description: "false (default): preview only, no receipt, no persisted change. true: commit the optimal values as one receipted mutation (only when status is optimal).",
                defaultValue: "false"
            ),
        ],
        required: ["objective_cell", "direction", "variable_cells"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let objectiveCellRaw = arguments["objective_cell"]?.stringValue else {
            return .fail("Missing 'objective_cell'.")
        }
        guard let directionRaw = arguments["direction"]?.stringValue else {
            return .fail("Missing 'direction'.")
        }
        let variableCellsRaw = SheetSolverToolSupport.stringArray(arguments["variable_cells"])
        guard !variableCellsRaw.isEmpty else {
            return .fail("variable_cells must name at least one cell.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let apply = arguments["apply"]?.boolValue ?? false
        let assumeNonNegative = arguments["assume_non_negative"]?.boolValue ?? true

        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }

        let model: SolverModel
        do {
            let objectiveCell = try SheetSolverToolSupport.parseCell(objectiveCellRaw)
            let direction = try SheetSolverToolSupport.parseDirection(directionRaw)
            let variableCells = try SheetSolverToolSupport.parseCellList(arguments["variable_cells"])
            let constraints = try SheetSolverToolSupport.parseConstraints(arguments["constraints"])
            model = SolverModel(
                objectiveCell: objectiveCell,
                direction: direction,
                variableCells: variableCells,
                constraints: constraints,
                assumeNonNegative: assumeNonNegative
            )
        } catch {
            return .fail(error.localizedDescription)
        }

        let io = SheetSolverToolSupport.cellIO(engine: engine, sheet: sheet)
        let result: SolverResult
        do {
            result = try SolverEngine.solve(model, io: io)
        } catch let linearityError as SolverLinearityError {
            return .fail(linearityError.description)
        } catch {
            return .fail(error.localizedDescription)
        }

        let variableValuesJSON: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: result.variableValues.map { ($0.key.description, JSONValue.number($0.value)) }
        )
        let data: [String: JSONValue] = [
            "objective_cell": .string(objectiveCellRaw),
            "direction": .string(model.direction.rawValue),
            "objective_value": .number(result.objectiveValue),
            "iterations": .number(Double(result.iterations)),
            "status": .string(result.status.rawValue),
            "variable_values": .object(variableValuesJSON),
            "applied": .bool(false),
        ]
        let variablesText = result.variableValues
            .sorted { $0.key.description < $1.key.description }
            .map { "\($0.key.description) = \($0.value)" }
            .joined(separator: ", ")
        let summary: String
        switch result.status {
        case .optimal:
            summary = "Solver found an optimal solution after \(result.iterations) iteration(s): " +
                "objective (\(objectiveCellRaw)) = \(result.objectiveValue). \(variablesText)."
        case .infeasible:
            summary = "Solver classified this model as infeasible: no assignment of the variable cells satisfies every constraint."
        case .unbounded:
            summary = "Solver classified this model as unbounded: the objective can be improved without limit within the constraints."
        case .iterationLimitExceeded:
            summary = "Solver did not reach a conclusion within \(result.iterations) iteration(s); the model may be too large for the default budget."
        }

        guard apply else {
            return .ok(summary + " Preview only - call again with apply: true to commit.", data: data)
        }
        guard result.status == .optimal else {
            return .fail("Cannot apply: \(summary)")
        }

        guard let sheetStore = SheetToolContext.shared.sheetStore, let sheetID = SheetToolContext.shared.sheetID else {
            return .fail(
                "Solver apply is not wired to the Sheets store in this build yet " +
                "(see SheetStore.applySolverRun in the P2-A wiring notes). Use apply: false to preview."
            )
        }
        do {
            _ = try await sheetStore.applySolverRun(model, result: result, for: sheetID)
        } catch {
            return .fail("Solver apply failed: \(error.localizedDescription)")
        }
        var appliedData = data
        appliedData["applied"] = .bool(true)
        return .ok(summary + " Applied.", data: appliedData)
    }
}
