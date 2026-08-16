import Foundation

// MARK: - SolverEngine
//
// Pure logic peer of ``QueryEngine`` (sota-p2-core-report.md design
// contract 2.6): goal seek (secant + bisection fallback) and a linear
// Solver (dense-tableau simplex, Bland's rule, variable bounds). Neither
// half builds a second formula evaluator - both drive the ALREADY-LANDED
// one through the ``SolverCellIO`` closures a caller supplies (typically
// thin wrappers around ``SheetEngine/setValue(sheet:addr:value:)`` /
// ``SheetEngine/getValue(sheet:addr:)``, which already recalculate the
// whole downstream graph on every write - see those methods' doc
// comments). This mirrors why ``QueryEngine``'s own mutation methods take
// a `cellValue` closure instead of a `SheetEngine` reference: the engine
// stays trivially unit-testable with a synthetic function, and has no
// compile-time dependency on `SheetEngine` at all.
//
// **Receipt-emission boundary** (same boundary QueryEngine documents,
// same reason): this type never appends a receipt and never persists
// anything. `goalSeek`/`solve` compute a proposal; a caller that wants to
// COMMIT one calls `goalSeekReceiptPayload`/`solverReceiptPayload` to get
// the receipt-shaped outcome, then does its own persistence + a single
// `appendReceipt` call at the site that already owns write access to the
// document (`SheetStore.applyGoalSeek`/`applySolverRun`, per this wave's
// wiring notes - not implemented in this file). A caller that only wants
// to PREVIEW never calls those payload builders at all, so "preview =
// no receipt" falls straight out of which functions get called rather
// than needing a `dryRun` flag anywhere in this file.

// MARK: - Cell IO seam

/// Read/write hooks over whatever workbook is live. Kept as plain
/// closures (not a protocol, not a `SheetEngine` reference) for the same
/// reason ``QueryEngine/sortedRowOrder(rowCount:conditions:cellValue:)``
/// takes a `cellValue` closure: this engine has zero compile-time
/// dependency on `SheetEngine` and is fully testable with a synthetic
/// function standing in for a workbook.
///
/// `write` MUST cause `read` of any dependent formula cell to reflect the
/// new value on the next call - i.e. the caller is expected to route
/// this through the landed evaluator's normal recalculation path (see
/// the type header), not a shadow/detached copy.
public struct SolverCellIO: Sendable {
    public var read: @Sendable (CellAddr) -> Double
    public var write: @Sendable (CellAddr, Double) -> Void

    public init(
        read: @escaping @Sendable (CellAddr) -> Double,
        write: @escaping @Sendable (CellAddr, Double) -> Void
    ) {
        self.read = read
        self.write = write
    }
}

/// The receipt-shaped result of a would-be SolverEngine mutation,
/// mirroring ``QueryEngineOutcome``'s shape (deliberately NOT the same
/// type - each pure engine owns its own outcome type; see
/// `RevisionController`'s `mirrors QueryEngineOutcome` precedent, which
/// made the same choice for the same reason: no cross-material coupling
/// between two otherwise-unrelated pure engines).
public struct SolverEngineOutcome: Sendable, Equatable {
    public var receiptType: String
    public var payload: [String: JSONValue]

    public init(receiptType: String, payload: [String: JSONValue]) {
        self.receiptType = receiptType
        self.payload = payload
    }
}

// MARK: - Goal seek

/// One goal-seek request: adjust `variableCell` until `formulaCell`
/// reads `targetValue`.
public struct GoalSeekRequest: Sendable, Equatable {
    public var formulaCell: CellAddr
    public var targetValue: Double
    public var variableCell: CellAddr
    /// Convergence tolerance on `|formulaCell - targetValue|`.
    public var tolerance: Double
    public var maxIterations: Int

    public init(
        formulaCell: CellAddr,
        targetValue: Double,
        variableCell: CellAddr,
        tolerance: Double = 1e-7,
        maxIterations: Int = 100
    ) {
        self.formulaCell = formulaCell
        self.targetValue = targetValue
        self.variableCell = variableCell
        self.tolerance = tolerance
        self.maxIterations = maxIterations
    }

    /// A process-independent identity hash for this request, used as the
    /// `applyGoalSeek` receipt's `modelHash` payload field (per the
    /// design contract). Deliberately NOT `Hashable`'s `hashValue`: Swift
    /// randomizes that seed per process launch, so two runs of the exact
    /// same request would disagree - useless for an audit trail meant to
    /// answer "did this apply solve the same model as that one" across
    /// sessions. See ``SolverModelHash/stable(_:)``.
    public var modelHash: String {
        SolverModelHash.stable("goalSeek|\(formulaCell.description)|\(SolverModelHash.canonical(targetValue))|\(variableCell.description)|\(SolverModelHash.canonical(tolerance))")
    }
}

public enum GoalSeekStatus: String, Sendable, Equatable {
    case converged
    case notConverged
}

public struct GoalSeekResult: Sendable, Equatable {
    public var status: GoalSeekStatus
    /// The value `variableCell` was left holding.
    public var resolvedValue: Double
    /// `formulaCell`'s value at `resolvedValue`.
    public var achievedValue: Double
    public var iterations: Int

    public init(status: GoalSeekStatus, resolvedValue: Double, achievedValue: Double, iterations: Int) {
        self.status = status
        self.resolvedValue = resolvedValue
        self.achievedValue = achievedValue
        self.iterations = iterations
    }
}

// MARK: - Solver model

public enum SolverDirection: String, Sendable, Equatable {
    case minimize
    case maximize
}

public enum SolverConstraintOperator: String, Sendable, Equatable {
    case lessThanOrEqual
    case greaterThanOrEqual
    case equal
}

public struct SolverConstraint: Sendable, Equatable {
    public var lhsCell: CellAddr
    public var op: SolverConstraintOperator
    public var rhs: Double

    public init(lhsCell: CellAddr, op: SolverConstraintOperator, rhs: Double) {
        self.lhsCell = lhsCell
        self.op = op
        self.rhs = rhs
    }
}

/// A linear-programming model: an objective cell to optimize by varying
/// `variableCells`, subject to `constraints`. Solved by
/// ``SolverEngine/solve(_:io:maxIterations:)`` ONLY if
/// ``SolverEngine/probeLinearity(model:io:)`` confirms every cell the
/// model touches is actually linear in the variables - see that
/// function's doc comment. Nonlinear DEPS/SCO-style solving is
/// explicitly out of scope (design contract 2.6 recommendation).
public struct SolverModel: Sendable, Equatable {
    public var objectiveCell: CellAddr
    public var direction: SolverDirection
    public var variableCells: [CellAddr]
    public var constraints: [SolverConstraint]
    /// When true, every variable is bounded `>= 0` (the common Excel/LO
    /// Solver default). When false, variables are unbounded in sign
    /// (represented internally as the difference of two non-negative
    /// variables - see ``SolverEngine/solve(_:io:maxIterations:)``).
    public var assumeNonNegative: Bool

    public init(
        objectiveCell: CellAddr,
        direction: SolverDirection,
        variableCells: [CellAddr],
        constraints: [SolverConstraint],
        assumeNonNegative: Bool = true
    ) {
        self.objectiveCell = objectiveCell
        self.direction = direction
        self.variableCells = variableCells
        self.constraints = constraints
        self.assumeNonNegative = assumeNonNegative
    }

    /// Identity hash for the `applySolverRun` receipt's `modelHash`
    /// payload field. See ``GoalSeekRequest/modelHash``.
    public var modelHash: String {
        var parts = ["solve", objectiveCell.description, direction.rawValue]
        parts.append(contentsOf: variableCells.map { $0.description })
        for c in constraints {
            parts.append("\(c.lhsCell.description)\(c.op.rawValue)\(SolverModelHash.canonical(c.rhs))")
        }
        parts.append(assumeNonNegative ? "nonneg" : "free")
        return SolverModelHash.stable(parts.joined(separator: "|"))
    }
}

public enum SolverStatus: String, Sendable, Equatable {
    case optimal
    case infeasible
    case unbounded
    /// The pivot loop exhausted its iteration budget without reaching
    /// optimality. Bland's rule guarantees termination in a FINITE
    /// number of pivots for any well-formed model, so this status
    /// signals a budget too small for the model's size, not cycling -
    /// distinguished from `.infeasible`/`.unbounded` so a caller never
    /// mistakes "ran out of iterations" for a real classification.
    case iterationLimitExceeded
}

public struct SolverResult: Sendable, Equatable {
    public var status: SolverStatus
    public var objectiveValue: Double
    public var variableValues: [CellAddr: Double]
    public var iterations: Int

    public init(status: SolverStatus, objectiveValue: Double, variableValues: [CellAddr: Double], iterations: Int) {
        self.status = status
        self.objectiveValue = objectiveValue
        self.variableValues = variableValues
        self.iterations = iterations
    }
}

/// Thrown by ``SolverEngine/probeLinearity(model:io:)`` when a cell the
/// model depends on fails the affinity check - the model is refused
/// rather than silently solved as if it were linear (design contract
/// 2.6: "a model that fails the probe refuses with a typed error naming
/// the offending cell").
public enum SolverLinearityError: Error, Equatable, CustomStringConvertible {
    case nonlinear(cell: CellAddr)

    public var description: String {
        switch self {
        case .nonlinear(let cell):
            return "Cell \(cell.description) is not linear in the solver's variable cells; the linear Solver cannot be used for this model."
        }
    }
}

// MARK: - SolverEngine

public enum SolverEngine {

    /// The two receipt-type strings an APPLY caller uses (see the type
    /// header's receipt-emission boundary note). Sourced from the
    /// pre-landed ``SheetReceiptType`` cases rather than duplicated as
    /// string literals, so a future rename of those cases breaks this
    /// file at compile time instead of drifting silently.
    public enum ReceiptType {
        public static let goalSeekApplied = SheetReceiptType.applyGoalSeek.rawValue
        public static let solverApplied = SheetReceiptType.applySolverRun.rawValue
    }

    private static let epsilon = 1e-9
    /// Relative tolerance for the linearity affinity check. Deliberately
    /// looser than `epsilon`: floating-point evaluation of an actually
    /// linear formula (e.g. involving SUM over many cells) can drift by
    /// more than 1e-9 through the evaluator's own arithmetic, and this
    /// check must not false-positive a linear model as nonlinear.
    private static let linearityRelativeTolerance = 1e-6
    /// Fixed (NOT `Double.random`) probe multipliers for the affinity
    /// check, per the design contract: "use a FIXED seed / fixed sample
    /// points, NOT Swift's true random, so the probe is deterministic
    /// and testable". Three points is enough to catch any nonlinear term
    /// a unit-perturbation-only check would miss (e.g. a bilinear cross
    /// term like `x*y`, whose unit perturbations from an all-zero base
    /// are individually zero - see ``probeLinearity(model:io:)``).
    private static let probeMultipliers: [Double] = [2.0, -1.0, 3.5]

    // MARK: - Goal seek

    /// Solves `request` by adjusting `request.variableCell` until
    /// `request.formulaCell` reads `request.targetValue` within
    /// `request.tolerance`, or `request.maxIterations` is exhausted.
    ///
    /// Secant method (superlinear convergence for a smooth root, no
    /// derivative needed - the underlying formula is arbitrary, so there
    /// is no closed-form derivative to exploit) with a bisection
    /// fallback: if the secant step's denominator collapses (two
    /// successive residuals equal, or non-finite - e.g. the formula hit
    /// a `#DIV/0!`) or the secant sequence stalls without converging,
    /// this expands outward from the current best point to bracket a
    /// sign change and bisects to convergence. `io.write` is called on
    /// every trial (goal seek IS iterated evaluation against the live
    /// evaluator, per the type header) - the sheet is left holding
    /// whichever value this call last tried, which on return is always
    /// `result.resolvedValue`.
    public static func goalSeek(_ request: GoalSeekRequest, io: SolverCellIO) -> GoalSeekResult {
        func residual(_ x: Double) -> Double {
            io.write(request.variableCell, x)
            return io.read(request.formulaCell) - request.targetValue
        }

        var x0 = io.read(request.variableCell)
        if !x0.isFinite { x0 = 0 }
        let x1 = x0 == 0 ? 1.0 : x0 * 1.0001
        var f0 = residual(x0)
        var xCur = x1
        var fCur = residual(x1)
        var iterations = 0
        var converged = abs(fCur) <= request.tolerance

        while !converged && iterations < request.maxIterations {
            iterations += 1
            let denom = fCur - f0
            guard abs(denom) > 1e-14, denom.isFinite else { break }
            let xNext = xCur - fCur * (xCur - x0) / denom
            guard xNext.isFinite else { break }
            x0 = xCur
            f0 = fCur
            xCur = xNext
            fCur = residual(xCur)
            guard fCur.isFinite else { break }
            converged = abs(fCur) <= request.tolerance
        }

        if !converged {
            if let bracket = findBracket(start: xCur, residual: residual, maxExpansions: 60) {
                var (a, b, fa, _) = bracket
                iterations = 0
                while iterations < request.maxIterations {
                    iterations += 1
                    let mid = (a + b) / 2
                    let fm = residual(mid)
                    xCur = mid
                    fCur = fm
                    if abs(fm) <= request.tolerance {
                        converged = true
                        break
                    }
                    if (fa < 0) == (fm < 0) {
                        a = mid
                        fa = fm
                    } else {
                        b = mid
                    }
                }
            }
        }

        io.write(request.variableCell, xCur)
        return GoalSeekResult(
            status: converged ? .converged : .notConverged,
            resolvedValue: xCur,
            achievedValue: fCur + request.targetValue,
            iterations: iterations
        )
    }

    /// Expands outward from `start` (step `0.1 * max(|start|, 1)`,
    /// growing by 1.6x each try) until `residual` changes sign, then
    /// returns the bracketing pair. `nil` if no sign change is found
    /// within `maxExpansions` steps (the root-finding equivalent of
    /// `QueryEngine`'s no-op guards: "no bracket found" is a defined,
    /// non-crashing outcome, not an error).
    private static func findBracket(
        start: Double,
        residual: (Double) -> Double,
        maxExpansions: Int
    ) -> (a: Double, b: Double, fa: Double, fb: Double)? {
        var a = start
        var fa = residual(a)
        if abs(fa) <= 0 { return (a, a, fa, fa) }
        var step = max(abs(start), 1.0) * 0.1
        var b = a + step
        var fb = residual(b)
        var expansions = 0
        while (fa < 0) == (fb < 0), expansions < maxExpansions {
            step *= 1.6
            a = b
            fa = fb
            b = a + step
            fb = residual(b)
            expansions += 1
        }
        guard (fa < 0) != (fb < 0) else { return nil }
        return (a, b, fa, fb)
    }

    /// The receipt-shaped payload for an APPLIED goal seek (design
    /// contract: "objective value, iterations, status, model hash" -
    /// `formulaCell`'s achieved value stands in for "objective value"
    /// here, goal seek having no separate objective concept of its own).
    /// See the type header's receipt-emission boundary note: this
    /// function computes nothing and persists nothing, it only shapes
    /// what a caller that HAS decided to apply should append.
    public static func goalSeekReceiptPayload(request: GoalSeekRequest, result: GoalSeekResult) -> SolverEngineOutcome {
        SolverEngineOutcome(
            receiptType: ReceiptType.goalSeekApplied,
            payload: [
                "formulaCell": .string(request.formulaCell.description),
                "variableCell": .string(request.variableCell.description),
                "targetValue": .number(request.targetValue),
                "resolvedValue": .number(result.resolvedValue),
                "objectiveValue": .number(result.achievedValue),
                "iterations": .number(Double(result.iterations)),
                "status": .string(result.status.rawValue),
                "modelHash": .string(request.modelHash),
            ]
        )
    }

    // MARK: - Linearity probe

    /// A first-order affine approximation of every cell the solver
    /// touches, built by numeric probing (never symbolic parsing - the
    /// underlying formula is arbitrary): `baseValues[cell]` at all
    /// variables `== 0`, `coefficients[cell][variable]` the unit-step
    /// delta `f(unit_variable) - f(base)`. Only meaningful once
    /// ``SolverEngine/probeLinearity(model:io:)`` has confirmed affinity.
    struct LinearModel {
        var baseValues: [CellAddr: Double]
        var coefficients: [CellAddr: [CellAddr: Double]]
    }

    /// Probes `model`'s objective and every constraint's LHS cell for
    /// linearity in `model.variableCells`, throwing
    /// ``SolverLinearityError/nonlinear(cell:)`` naming the FIRST
    /// offending cell (objective checked before constraints, constraints
    /// in list order, deterministic) rather than silently treating a
    /// nonlinear model as linear.
    ///
    /// Method: evaluate every checked cell at the all-zero base point and
    /// at each single-variable unit perturbation to build a candidate
    /// affine model (``LinearModel``), then evaluate at a few FIXED
    /// (non-random - see ``probeMultipliers``) multi-variable points and
    /// compare the actual value against the affine model's prediction.
    /// The multi-variable check is load-bearing: a bilinear term like
    /// `x*y` has BOTH single-variable unit perturbations equal to the
    /// base value (multiplying by zero in either factor), so a
    /// unit-perturbation-only check would misclassify it as linear with
    /// zero coefficients - only a joint, non-axis-aligned probe point
    /// exposes the cross term.
    static func probeLinearity(model: SolverModel, io: SolverCellIO) throws -> LinearModel {
        let cellsToCheck = [model.objectiveCell] + model.constraints.map(\.lhsCell)
        let variables = model.variableCells

        func evaluate(_ target: CellAddr, at point: [CellAddr: Double]) -> Double {
            for v in variables { io.write(v, point[v] ?? 0) }
            return io.read(target)
        }

        // `uniquingKeysWith` (not `uniqueKeysWithValues`) defensively: a
        // caller-supplied `variableCells` list with an accidental
        // duplicate cell must not crash the probe - the duplicate simply
        // collapses to one entry, same as it would in the effective-var
        // list built later.
        let base: [CellAddr: Double] = Dictionary(variables.map { ($0, 0.0) }, uniquingKeysWith: { a, _ in a })
        var baseValues: [CellAddr: Double] = [:]
        for cell in cellsToCheck {
            baseValues[cell] = evaluate(cell, at: base)
        }

        var coefficients: [CellAddr: [CellAddr: Double]] = [:]
        for cell in cellsToCheck { coefficients[cell] = [:] }
        for variable in variables {
            var point = base
            point[variable] = 1.0
            for cell in cellsToCheck {
                let value = evaluate(cell, at: point)
                coefficients[cell]?[variable] = value - (baseValues[cell] ?? 0)
            }
        }

        for (probeIndex, multiplier) in probeMultipliers.enumerated() {
            var point: [CellAddr: Double] = [:]
            for (varIndex, variable) in variables.enumerated() {
                point[variable] = multiplier + Double(varIndex) * 0.37 + Double(probeIndex) * 0.11
            }
            for cell in cellsToCheck {
                let actual = evaluate(cell, at: point)
                var predicted = baseValues[cell] ?? 0
                for variable in variables {
                    predicted += (coefficients[cell]?[variable] ?? 0) * (point[variable] ?? 0)
                }
                let scale = max(1.0, abs(actual), abs(predicted))
                if abs(actual - predicted) > linearityRelativeTolerance * scale {
                    // Reset variables to the base point before refusing -
                    // a refused model must not leave the sheet sitting at
                    // an arbitrary mid-probe value.
                    for v in variables { io.write(v, 0) }
                    throw SolverLinearityError.nonlinear(cell: cell)
                }
            }
        }

        for v in variables { io.write(v, 0) }
        return LinearModel(baseValues: baseValues, coefficients: coefficients)
    }

    // MARK: - Simplex

    /// One structural column of the standard-form tableau: either a
    /// model variable directly (`assumeNonNegative == true`) or one half
    /// of a free variable split into `u - v`, `u, v >= 0`
    /// (`assumeNonNegative == false`).
    private struct EffectiveVariable {
        var cell: CellAddr
        var sign: Double
    }

    private static func effectiveVariables(for model: SolverModel) -> [EffectiveVariable] {
        if model.assumeNonNegative {
            return model.variableCells.map { EffectiveVariable(cell: $0, sign: 1) }
        }
        return model.variableCells.flatMap {
            [EffectiveVariable(cell: $0, sign: 1), EffectiveVariable(cell: $0, sign: -1)]
        }
    }

    private struct StandardForm {
        var tableau: [[Double]]
        var basis: [Int]
        var numCols: Int
        /// Entering-column search upper bound for phase 2: excludes the
        /// trailing block of artificial columns (they are placed LAST in
        /// column order for exactly this reason) so a phase-1 artificial
        /// can never be reintroduced by phase 2's pivot search, without
        /// needing a separate per-column "forbidden" flag.
        var entranceLimitPhase2: Int
        var hasArtificials: Bool
    }

    /// Builds the standard-form tableau: `[structural | slack | surplus
    /// | artificial | RHS]` columns, one row per constraint plus a
    /// trailing objective row (installed by the caller - see
    /// `solve(_:io:maxIterations:)`). Every constraint is normalized to
    /// `RHS >= 0` first (flipping <=/>= and negating the row when the
    /// probed RHS is negative; `=` is unaffected by the sign flip),
    /// which is what lets every row start with a natural non-negative
    /// basic feasible value (slack = RHS, or artificial = RHS).
    private static func buildStandardForm(
        model: SolverModel,
        linear: LinearModel,
        effectiveVars: [EffectiveVariable]
    ) -> StandardForm {
        struct Normalized {
            var coefficients: [Double]
            var rhs: Double
            var op: SolverConstraintOperator
        }

        let n = effectiveVars.count
        var normalized: [Normalized] = []
        normalized.reserveCapacity(model.constraints.count)
        for c in model.constraints {
            let coefRow = linear.coefficients[c.lhsCell] ?? [:]
            var row = effectiveVars.map { (coefRow[$0.cell] ?? 0) * $0.sign }
            var rhs = c.rhs - (linear.baseValues[c.lhsCell] ?? 0)
            var op = c.op
            if rhs < 0 {
                row = row.map { -$0 }
                rhs = -rhs
                switch op {
                case .lessThanOrEqual: op = .greaterThanOrEqual
                case .greaterThanOrEqual: op = .lessThanOrEqual
                case .equal: op = .equal
                }
            }
            normalized.append(Normalized(coefficients: row, rhs: rhs, op: op))
        }

        let slackCount = normalized.filter { $0.op == .lessThanOrEqual }.count
        let surplusCount = normalized.filter { $0.op == .greaterThanOrEqual }.count
        let artificialCount = normalized.filter { $0.op != .lessThanOrEqual }.count

        let slackStart = n
        let surplusStart = slackStart + slackCount
        let artificialStart = surplusStart + surplusCount
        let numCols = artificialStart + artificialCount
        let m = normalized.count

        var tableau = Array(repeating: Array(repeating: 0.0, count: numCols + 1), count: m + 1)
        var basis = Array(repeating: 0, count: m)

        var slackIdx = slackStart
        var surplusIdx = surplusStart
        var artificialIdx = artificialStart

        for (i, nc) in normalized.enumerated() {
            for j in 0..<n { tableau[i][j] = nc.coefficients[j] }
            tableau[i][numCols] = nc.rhs
            switch nc.op {
            case .lessThanOrEqual:
                tableau[i][slackIdx] = 1
                basis[i] = slackIdx
                slackIdx += 1
            case .greaterThanOrEqual:
                tableau[i][surplusIdx] = -1
                surplusIdx += 1
                tableau[i][artificialIdx] = 1
                basis[i] = artificialIdx
                artificialIdx += 1
            case .equal:
                tableau[i][artificialIdx] = 1
                basis[i] = artificialIdx
                artificialIdx += 1
            }
        }

        let hasArtificials = artificialCount > 0
        if hasArtificials {
            // Phase 1: maximize -sum(artificials), i.e. c' = -1 on every
            // artificial column, 0 elsewhere. Objective row init rule is
            // row[j] = -c'_j, so artificial columns start at +1.
            for col in artificialStart..<numCols {
                tableau[m][col] = 1
            }
            reduceObjectiveRow(&tableau, basis: basis, objectiveRow: m)
        }

        return StandardForm(
            tableau: tableau,
            basis: basis,
            numCols: numCols,
            entranceLimitPhase2: artificialStart,
            hasArtificials: hasArtificials
        )
    }

    /// Zeroes the objective row at every currently-basic column (the
    /// tableau invariant "a basic variable's own column reads 0 in the
    /// objective row") by subtracting the appropriate multiple of that
    /// column's row - the same elimination step a pivot performs,
    /// applied here to make a freshly-installed objective row consistent
    /// with a basis it did not itself compute (phase-1 init, and
    /// phase-2's objective swap onto phase-1's final basis).
    private static func reduceObjectiveRow(_ tableau: inout [[Double]], basis: [Int], objectiveRow: Int) {
        let numCols = tableau[objectiveRow].count - 1
        for (row, col) in basis.enumerated() {
            let factor = tableau[objectiveRow][col]
            guard abs(factor) > epsilon else { continue }
            for j in 0...numCols {
                tableau[objectiveRow][j] -= factor * tableau[row][j]
            }
        }
    }

    private static func installPhase2Objective(
        tableau: inout [[Double]],
        basis: [Int],
        model: SolverModel,
        linear: LinearModel,
        effectiveVars: [EffectiveVariable],
        numCols: Int
    ) {
        let objectiveRow = tableau.count - 1
        let objCoef = linear.coefficients[model.objectiveCell] ?? [:]
        let sense: Double = model.direction == .maximize ? 1 : -1
        var row = [Double](repeating: 0, count: numCols + 1)
        for (idx, ev) in effectiveVars.enumerated() {
            let c = (objCoef[ev.cell] ?? 0) * ev.sign * sense
            row[idx] = -c
        }
        tableau[objectiveRow] = row
        reduceObjectiveRow(&tableau, basis: basis, objectiveRow: objectiveRow)
    }

    private enum PivotOutcome {
        case optimal(iterations: Int)
        case unbounded
        case iterationLimit(iterations: Int)
    }

    /// The single dense-tableau pivot loop shared by phase 1 and phase
    /// 2. Bland's rule throughout (design contract: "Bland's rule
    /// (anti-cycling)"), both halves of it:
    ///  - entering column: the SMALLEST-index column (within
    ///    `0..<entranceLimit`) whose objective-row entry is negative
    ///    (an improving direction exists).
    ///  - leaving row: the min-ratio-test winner; ties broken by the
    ///    SMALLEST basic-variable index among the tied rows.
    /// Both tie-break rules are required together - either alone still
    /// permits cycling on a pathological (degenerate) model; Bland's
    /// 1977 result is that this exact combination guarantees termination
    /// in a finite number of pivots for any input.
    private static func runSimplex(
        tableau: inout [[Double]],
        basis: inout [Int],
        entranceLimit: Int,
        maxIterations: Int
    ) -> PivotOutcome {
        let objectiveRow = tableau.count - 1
        let numCols = tableau[objectiveRow].count - 1
        var iterations = 0

        while true {
            guard let enter = (0..<entranceLimit).first(where: { tableau[objectiveRow][$0] < -epsilon }) else {
                return .optimal(iterations: iterations)
            }
            guard iterations < maxIterations else {
                return .iterationLimit(iterations: iterations)
            }
            iterations += 1

            var leaveRow: Int? = nil
            var bestRatio = Double.infinity
            for r in 0..<objectiveRow {
                let coeff = tableau[r][enter]
                guard coeff > epsilon else { continue }
                let ratio = tableau[r][numCols] / coeff
                if ratio < bestRatio - epsilon {
                    bestRatio = ratio
                    leaveRow = r
                } else if abs(ratio - bestRatio) <= epsilon {
                    if let currentLeave = leaveRow {
                        if basis[r] < basis[currentLeave] { leaveRow = r }
                    } else {
                        leaveRow = r
                        bestRatio = ratio
                    }
                }
            }
            guard let pivotRow = leaveRow else {
                return .unbounded
            }

            let pivotValue = tableau[pivotRow][enter]
            for j in 0...numCols { tableau[pivotRow][j] /= pivotValue }
            for r in 0..<tableau.count where r != pivotRow {
                let factor = tableau[r][enter]
                guard abs(factor) > epsilon else { continue }
                for j in 0...numCols { tableau[r][j] -= factor * tableau[pivotRow][j] }
            }
            basis[pivotRow] = enter
        }
    }

    /// Solves `model` via a two-phase dense-tableau simplex.
    ///
    /// 1. ``probeLinearity(model:io:)`` - throws if any touched cell is
    ///    nonlinear in `model.variableCells` (see that function).
    /// 2. Standard-form tableau construction (``buildStandardForm``).
    /// 3. Phase 1 (only if the model needed artificial variables -
    ///    i.e. any `>=`/`=` constraint): minimize the sum of artificials.
    ///    A final value below `-epsilon` (in this maximize-internal
    ///    convention, `> epsilon` in ordinary terms) means no feasible
    ///    point exists - `.infeasible`.
    /// 4. Phase 2: the real objective (sign-flipped internally to always
    ///    maximize; restored on the way out), starting from phase 1's
    ///    feasible basis. An entering column with no positive entry in
    ///    any row means the objective is unbounded in that direction -
    ///    `.unbounded`.
    /// 5. On `.optimal`, every variable's resolved value is written back
    ///    via `io.write` (goal seek does the same - see that function's
    ///    doc comment) and the model's `objectiveCell` will read the
    ///    achieved objective value in the caller's live workbook.
    public static func solve(_ model: SolverModel, io: SolverCellIO, maxIterations: Int = 500) throws -> SolverResult {
        let linear = try probeLinearity(model: model, io: io)
        let effectiveVars = effectiveVariables(for: model)
        let form = buildStandardForm(model: model, linear: linear, effectiveVars: effectiveVars)

        var tableau = form.tableau
        var basis = form.basis

        if form.hasArtificials {
            let phase1 = runSimplex(tableau: &tableau, basis: &basis, entranceLimit: form.numCols, maxIterations: maxIterations)
            switch phase1 {
            case .unbounded:
                // Minimizing a sum of non-negative artificials is bounded
                // below by 0 by construction; this branch is defensive,
                // not reachable by a correctly-built standard form.
                return SolverResult(status: .infeasible, objectiveValue: 0, variableValues: [:], iterations: 0)
            case .iterationLimit(let n):
                return SolverResult(status: .iterationLimitExceeded, objectiveValue: 0, variableValues: [:], iterations: n)
            case .optimal:
                let phase1Objective = tableau[tableau.count - 1][form.numCols]
                if phase1Objective < -1e-6 {
                    return SolverResult(status: .infeasible, objectiveValue: 0, variableValues: [:], iterations: 0)
                }
            }
        }

        installPhase2Objective(
            tableau: &tableau, basis: basis, model: model,
            linear: linear, effectiveVars: effectiveVars, numCols: form.numCols
        )
        let phase2 = runSimplex(tableau: &tableau, basis: &basis, entranceLimit: form.entranceLimitPhase2, maxIterations: maxIterations)

        switch phase2 {
        case .unbounded:
            return SolverResult(status: .unbounded, objectiveValue: 0, variableValues: [:], iterations: 0)
        case .iterationLimit(let n):
            return SolverResult(status: .iterationLimitExceeded, objectiveValue: 0, variableValues: [:], iterations: n)
        case .optimal(let n):
            var effectiveValues = [Double](repeating: 0, count: effectiveVars.count)
            for (row, col) in basis.enumerated() where col < effectiveVars.count {
                effectiveValues[col] = tableau[row][form.numCols]
            }
            var variableValues: [CellAddr: Double] = [:]
            for v in model.variableCells { variableValues[v] = 0 }
            for (idx, ev) in effectiveVars.enumerated() {
                variableValues[ev.cell, default: 0] += ev.sign * effectiveValues[idx]
            }
            let internalObjective = tableau[tableau.count - 1][form.numCols]
            let sense: Double = model.direction == .maximize ? 1 : -1
            let objectiveValue = (linear.baseValues[model.objectiveCell] ?? 0) + sense * internalObjective

            for v in model.variableCells { io.write(v, variableValues[v] ?? 0) }

            return SolverResult(status: .optimal, objectiveValue: objectiveValue, variableValues: variableValues, iterations: n)
        }
    }

    /// The receipt-shaped payload for an APPLIED solver run (design
    /// contract: "objective value, iterations, status, model hash"; also
    /// carries the resolved variable values, since an apply that changed
    /// N cells without naming them in its own receipt would force a
    /// reader to diff the sheet to find out what happened).
    public static func solverReceiptPayload(model: SolverModel, result: SolverResult) -> SolverEngineOutcome {
        SolverEngineOutcome(
            receiptType: ReceiptType.solverApplied,
            payload: [
                "objectiveCell": .string(model.objectiveCell.description),
                "direction": .string(model.direction.rawValue),
                "objectiveValue": .number(result.objectiveValue),
                "iterations": .number(Double(result.iterations)),
                "status": .string(result.status.rawValue),
                "modelHash": .string(model.modelHash),
                "variableValues": .object(
                    Dictionary(uniqueKeysWithValues: result.variableValues.map { ($0.key.description, JSONValue.number($0.value)) })
                ),
            ]
        )
    }
}

// MARK: - SolverModelHash

/// A process-independent (stable across launches, unlike Swift's
/// randomized `Hashable`) hash used for solver/goal-seek receipt
/// payloads' `modelHash` field - see ``GoalSeekRequest/modelHash`` and
/// ``SolverModel/modelHash``.
enum SolverModelHash {
    /// FNV-1a 64-bit over the UTF-8 bytes of `s`, returned as lowercase
    /// hex. Not cryptographic - this is an audit-trail identity tag
    /// ("did these two applies solve the same model"), not a security
    /// boundary.
    static func stable(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// A canonical, platform-stable textual form for a `Double` used in
    /// a hash's input string. `Double.description` is already stable
    /// (Swift's shortest-round-trip formatting is deterministic, not
    /// locale- or platform-dependent), but routing every call site
    /// through this function documents that the choice is deliberate
    /// and gives a single place to change it if that assumption is ever
    /// found to not hold.
    static func canonical(_ value: Double) -> String {
        value.description
    }
}
