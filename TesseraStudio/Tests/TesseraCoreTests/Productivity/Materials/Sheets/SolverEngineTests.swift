import XCTest
@testable import TesseraCore

// MARK: - SolverEngineTests
//
// Contract source: docs/.scratch/sota-p2-core-report.md design contract
// 2.6 ("Solver - Calc, effort M") - GoalSeekRequest solved via secant +
// bisection fallback over the landed evaluator; SolverModel solved via a
// dense-tableau simplex with Bland's rule and variable bounds; a
// linearity probe (base + unit perturbations + affinity check at FIXED
// points) that refuses a nonlinear model naming the offending cell
// rather than solving it as if it were linear. Test list per the design
// contract and this track's brief: textbook LP fixtures including one
// with a degenerate tie (confirming Bland's rule terminates rather than
// cycling); an infeasible model classified correctly; an unbounded model
// classified correctly; goal seek on a quadratic converges within a
// stated tolerance and is idempotent on re-apply; a genuinely nonlinear
// model is refused, not silently solved wrong.
//
// `SolverEngine` takes `SolverCellIO` (read/write closures), not a
// `SheetEngine` - every test here uses a synthetic in-memory function
// standing in for a workbook (the same shape `QueryEngineTests` uses for
// `QueryEngine`'s `cellValue` closure), so these are pure/ungated per
// testing-doctrine.md rule 9 ("math gets fixtures AND properties").
final class SolverEngineTests: DoctrineTestCase {

    // MARK: - Synthetic workbook helper

    /// A tiny in-memory cell store: `formulas[addr]` cells are computed
    /// from the current `values` snapshot on every read (mirroring how a
    /// real `SheetEngine.getValue` reflects the latest `setValue`); every
    /// other cell is a plain stored value, defaulting to 0.
    private func makeIO(formulas: [CellAddr: @Sendable ([CellAddr: Double]) -> Double] = [:]) -> SolverCellIO {
        var values: [CellAddr: Double] = [:]
        return SolverCellIO(
            read: { addr in
                if let formula = formulas[addr] { return formula(values) }
                return values[addr] ?? 0
            },
            write: { addr, v in values[addr] = v }
        )
    }

    private let A1 = CellAddr(col: 0, row: 0)
    private let B1 = CellAddr(col: 1, row: 0)
    private let C1 = CellAddr(col: 2, row: 0)
    private let D1 = CellAddr(col: 3, row: 0)
    private let E1 = CellAddr(col: 4, row: 0)

    // MARK: - Goal seek: quadratic, within tolerance

    /// B1 = A1^2, target 16. Starting the search from A1 = 5 (to the
    /// right of both roots +-4), secant's early steps have a positive
    /// residual with a positive local slope, so the sequence heads
    /// toward the nearer positive root, +4.
    func testGoalSeekConvergesOnQuadraticWithinTolerance() {
        let io = makeIO(formulas: [B1: { values in let x = values[self.A1] ?? 0; return x * x }])
        io.write(A1, 5.0)
        let request = GoalSeekRequest(formulaCell: B1, targetValue: 16, variableCell: A1, tolerance: 1e-6, maxIterations: 100)
        let result = SolverEngine.goalSeek(request, io: io)
        XCTAssertEqual(result.status, .converged)
        XCTAssertEqual(result.resolvedValue, 4.0, accuracy: 1e-3)
        XCTAssertEqual(result.achievedValue, 16.0, accuracy: 1e-3)
        XCTAssertGreaterThan(result.iterations, 0)
    }

    /// Re-running goal seek starting from the just-converged value must
    /// land on (approximately) the same value in very few iterations -
    /// the residual is already within tolerance, or one secant step away
    /// from it. This is the "idempotent on re-apply" contract line.
    func testGoalSeekIsIdempotentOnReapply() {
        let io = makeIO(formulas: [B1: { values in let x = values[self.A1] ?? 0; return x * x }])
        io.write(A1, 5.0)
        let request = GoalSeekRequest(formulaCell: B1, targetValue: 16, variableCell: A1, tolerance: 1e-6, maxIterations: 100)
        let first = SolverEngine.goalSeek(request, io: io)
        XCTAssertEqual(first.status, .converged)

        // `io`'s underlying value for A1 is now `first.resolvedValue` -
        // re-running from there is the "re-apply" case.
        let second = SolverEngine.goalSeek(request, io: io)
        XCTAssertEqual(second.status, .converged)
        XCTAssertEqual(second.resolvedValue, first.resolvedValue, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(second.iterations, 2, "already at the root - should converge in at most one secant probe")
    }

    /// B1 = 2*A1 + 1, target 7 - a linear fixture with a hand-obvious
    /// root (A1 = 3), included per testing-doctrine.md rule 9 ("fixtures
    /// AND properties") alongside the quadratic case above.
    func testGoalSeekSolvesALinearFormulaExactly() {
        let io = makeIO(formulas: [B1: { values in 2 * (values[self.A1] ?? 0) + 1 }])
        let request = GoalSeekRequest(formulaCell: B1, targetValue: 7, variableCell: A1)
        let result = SolverEngine.goalSeek(request, io: io)
        XCTAssertEqual(result.status, .converged)
        XCTAssertEqual(result.resolvedValue, 3.0, accuracy: 1e-6)
    }

    // MARK: - Solver: textbook LP (Wyndor Glass Co., Hillier & Lieberman)

    /// Maximize 3x+5y s.t. x<=4, 2y<=12, 3x+2y<=18, x,y>=0. The canonical
    /// intro-OR simplex example - optimum at x=2, y=6, Z=36, reached by a
    /// hand-traced 3-pivot path from the origin (Bland's rule: enter x
    /// first at pivot 1 despite y's more-negative reduced cost, since
    /// entering-column selection is smallest-index, not most-negative;
    /// x re-enters at pivot 3 after y's pivot pushes its reduced cost
    /// negative again).
    func testTextbookLPMaximizesCorrectly() throws {
        let io = makeIO(formulas: [
            C1: { values in 3 * (values[self.A1] ?? 0) + 5 * (values[self.B1] ?? 0) }, // objective: 3x + 5y
            D1: { values in 2 * (values[self.B1] ?? 0) },                        // 2y
            E1: { values in 3 * (values[self.A1] ?? 0) + 2 * (values[self.B1] ?? 0) }, // 3x + 2y
        ])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .maximize,
            variableCells: [A1, B1],
            constraints: [
                SolverConstraint(lhsCell: A1, op: .lessThanOrEqual, rhs: 4),
                SolverConstraint(lhsCell: D1, op: .lessThanOrEqual, rhs: 12),
                SolverConstraint(lhsCell: E1, op: .lessThanOrEqual, rhs: 18),
            ]
        )
        let result = try SolverEngine.solve(model, io: io)
        XCTAssertEqual(result.status, .optimal)
        XCTAssertEqual(result.objectiveValue, 36, accuracy: 1e-6)
        XCTAssertEqual(result.variableValues[A1] ?? .nan, 2, accuracy: 1e-6)
        XCTAssertEqual(result.variableValues[B1] ?? .nan, 6, accuracy: 1e-6)
        XCTAssertEqual(result.iterations, 3)
    }

    // MARK: - Solver: degenerate tie (Bland's rule anti-cycling)

    /// Maximize x1+x2 s.t. x1<=4, x2<=4, x1+x2<=8, x1,x2>=0. Both
    /// resource caps sum to exactly the combined cap, so the optimum
    /// (x1=4, x2=4, Z=8) makes all three constraints simultaneously
    /// tight - textbook primal degeneracy. Hand-traced: pivot 1 enters
    /// x1 (ratio 4 vs 8, no tie); pivot 2 enters x2, where the ratio
    /// test TIES EXACTLY between the x1<=4 row (already pivoted out) and
    /// x2<=4/x1+x2<=8's rows - Bland's rule breaks the tie toward the
    /// row whose basic variable has the smaller column index. A
    /// tie-break that picked the other row, or a largest-coefficient
    /// entering rule with no tie-break at all, is exactly the scenario
    /// this test exists to catch: confirms termination (not cycling) at
    /// the correct vertex.
    func testDegenerateTieLPTerminatesViaBlandsRule() throws {
        let io = makeIO(formulas: [
            C1: { values in (values[self.A1] ?? 0) + (values[self.B1] ?? 0) }, // objective: x1 + x2
            D1: { values in (values[self.A1] ?? 0) + (values[self.B1] ?? 0) }, // x1 + x2 (constraint LHS)
        ])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .maximize,
            variableCells: [A1, B1],
            constraints: [
                SolverConstraint(lhsCell: A1, op: .lessThanOrEqual, rhs: 4),
                SolverConstraint(lhsCell: B1, op: .lessThanOrEqual, rhs: 4),
                SolverConstraint(lhsCell: D1, op: .lessThanOrEqual, rhs: 8),
            ]
        )
        let result = try SolverEngine.solve(model, io: io, maxIterations: 30)
        XCTAssertEqual(result.status, .optimal, "Bland's rule must terminate at the optimum, not cycle or exhaust the iteration budget")
        XCTAssertEqual(result.objectiveValue, 8, accuracy: 1e-6)
        XCTAssertEqual(result.variableValues[A1] ?? .nan, 4, accuracy: 1e-6)
        XCTAssertEqual(result.variableValues[B1] ?? .nan, 4, accuracy: 1e-6)
        XCTAssertEqual(result.iterations, 2)
    }

    // MARK: - Solver: infeasible

    /// x >= 5 and x <= 2 cannot both hold - phase 1 cannot drive the
    /// artificial variable to 0 (the residual gap is exactly 5-2=3).
    func testInfeasibleModelIsClassifiedCorrectly() throws {
        let io = makeIO(formulas: [C1: { values in values[self.A1] ?? 0 }])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .maximize,
            variableCells: [A1],
            constraints: [
                SolverConstraint(lhsCell: A1, op: .greaterThanOrEqual, rhs: 5),
                SolverConstraint(lhsCell: A1, op: .lessThanOrEqual, rhs: 2),
            ]
        )
        let result = try SolverEngine.solve(model, io: io)
        XCTAssertEqual(result.status, .infeasible)
    }

    // MARK: - Solver: unbounded

    /// Maximize x with no constraints at all (only the implicit x >= 0)
    /// - nothing bounds x above.
    func testUnboundedModelIsClassifiedCorrectly() throws {
        let io = makeIO(formulas: [C1: { values in values[self.A1] ?? 0 }])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .maximize,
            variableCells: [A1],
            constraints: []
        )
        let result = try SolverEngine.solve(model, io: io)
        XCTAssertEqual(result.status, .unbounded)
    }

    // MARK: - Solver: assumeNonNegative == false (free variable split)

    /// Minimize x subject to x >= -5, with `assumeNonNegative: false` -
    /// x is allowed to go negative (represented internally as u - v,
    /// u,v >= 0). Optimum: x = -5.
    func testFreeVariableModelSolvesWithoutNonNegativeAssumption() throws {
        let io = makeIO(formulas: [C1: { values in values[self.A1] ?? 0 }])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .minimize,
            variableCells: [A1],
            constraints: [
                SolverConstraint(lhsCell: A1, op: .greaterThanOrEqual, rhs: -5),
            ],
            assumeNonNegative: false
        )
        let result = try SolverEngine.solve(model, io: io)
        XCTAssertEqual(result.status, .optimal)
        XCTAssertEqual(result.objectiveValue, -5, accuracy: 1e-6)
        XCTAssertEqual(result.variableValues[A1] ?? .nan, -5, accuracy: 1e-6)
    }

    // MARK: - Nonlinear refusal

    /// C1 = A1 * B1 (bilinear). Both single-variable unit perturbations
    /// from the all-zero base are individually 0 (multiplying by the
    /// other, still-zero, factor) - only the multi-variable affinity
    /// check at a joint probe point exposes the cross term, which is
    /// exactly why that check exists (see `probeLinearity`'s doc
    /// comment). Refused naming the objective cell, not silently solved.
    func testNonlinearObjectiveIsRefusedNamingTheCell() {
        let io = makeIO(formulas: [C1: { values in (values[self.A1] ?? 0) * (values[self.B1] ?? 0) }])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .maximize,
            variableCells: [A1, B1],
            constraints: []
        )
        XCTAssertThrowsError(try SolverEngine.solve(model, io: io)) { error in
            guard case SolverLinearityError.nonlinear(let cell) = error else {
                return XCTFail("expected .nonlinear, got \(error)")
            }
            XCTAssertEqual(cell, self.C1)
        }
    }

    /// The objective (A1+B1) is linear and passes; the SECOND cell
    /// probed - the constraint's lhs (D1 = A1^2) - is not, and must be
    /// named instead of the (innocent) objective cell. Confirms the
    /// probe checks every touched cell, not only the objective.
    func testNonlinearConstraintIsRefusedNamingTheConstraintCellNotTheObjective() {
        let io = makeIO(formulas: [
            C1: { values in (values[self.A1] ?? 0) + (values[self.B1] ?? 0) }, // linear objective
            D1: { values in let x = values[self.A1] ?? 0; return x * x }, // nonlinear constraint LHS
        ])
        let model = SolverModel(
            objectiveCell: C1,
            direction: .maximize,
            variableCells: [A1, B1],
            constraints: [
                SolverConstraint(lhsCell: D1, op: .lessThanOrEqual, rhs: 10),
            ]
        )
        XCTAssertThrowsError(try SolverEngine.solve(model, io: io)) { error in
            guard case SolverLinearityError.nonlinear(let cell) = error else {
                return XCTFail("expected .nonlinear, got \(error)")
            }
            XCTAssertEqual(cell, self.D1)
        }
    }

    // MARK: - Linearity probe (direct)

    func testProbeLinearityComputesBaseAndCoefficientsForALinearModel() throws {
        let io = makeIO(formulas: [
            C1: { values in 3 * (values[self.A1] ?? 0) + 5 * (values[self.B1] ?? 0) + 7 },
        ])
        let model = SolverModel(objectiveCell: C1, direction: .maximize, variableCells: [A1, B1], constraints: [])
        let linear = try SolverEngine.probeLinearity(model: model, io: io)
        XCTAssertEqual(linear.baseValues[C1] ?? .nan, 7, accuracy: 1e-9)
        XCTAssertEqual(linear.coefficients[C1]?[A1] ?? .nan, 3, accuracy: 1e-9)
        XCTAssertEqual(linear.coefficients[C1]?[B1] ?? .nan, 5, accuracy: 1e-9)
    }

    // MARK: - Model hash (receipt payload identity)

    func testGoalSeekRequestModelHashIsStableAndDistinguishesDifferentRequests() {
        let r1 = GoalSeekRequest(formulaCell: B1, targetValue: 16, variableCell: A1)
        let r1Again = GoalSeekRequest(formulaCell: B1, targetValue: 16, variableCell: A1)
        let r2 = GoalSeekRequest(formulaCell: B1, targetValue: 17, variableCell: A1)
        XCTAssertEqual(r1.modelHash, r1Again.modelHash)
        XCTAssertNotEqual(r1.modelHash, r2.modelHash)
    }

    func testSolverModelHashIsStableAndDistinguishesDifferentModels() {
        let base = SolverModel(
            objectiveCell: C1, direction: .maximize, variableCells: [A1, B1],
            constraints: [SolverConstraint(lhsCell: A1, op: .lessThanOrEqual, rhs: 4)]
        )
        let same = SolverModel(
            objectiveCell: C1, direction: .maximize, variableCells: [A1, B1],
            constraints: [SolverConstraint(lhsCell: A1, op: .lessThanOrEqual, rhs: 4)]
        )
        let different = SolverModel(
            objectiveCell: C1, direction: .maximize, variableCells: [A1, B1],
            constraints: [SolverConstraint(lhsCell: A1, op: .lessThanOrEqual, rhs: 5)]
        )
        XCTAssertEqual(base.modelHash, same.modelHash)
        XCTAssertNotEqual(base.modelHash, different.modelHash)
    }

    // MARK: - Receipt payload shape (design contract: objective value, iterations, status, model hash)

    func testGoalSeekReceiptPayloadCarriesDesignContractKeys() {
        let request = GoalSeekRequest(formulaCell: B1, targetValue: 16, variableCell: A1)
        let result = GoalSeekResult(status: .converged, resolvedValue: 4, achievedValue: 16, iterations: 5)
        let outcome = SolverEngine.goalSeekReceiptPayload(request: request, result: result)
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.applyGoalSeek.rawValue)
        XCTAssertEqual(outcome.payload["resolvedValue"]?.numberValue, 4)
        XCTAssertEqual(outcome.payload["objectiveValue"]?.numberValue, 16)
        XCTAssertEqual(outcome.payload["iterations"]?.numberValue, 5)
        XCTAssertEqual(outcome.payload["status"]?.stringValue, "converged")
        XCTAssertEqual(outcome.payload["modelHash"]?.stringValue, request.modelHash)
    }

    func testSolverReceiptPayloadCarriesDesignContractKeys() {
        let model = SolverModel(objectiveCell: C1, direction: .maximize, variableCells: [A1, B1], constraints: [])
        let result = SolverResult(status: .optimal, objectiveValue: 36, variableValues: [A1: 2, B1: 6], iterations: 3)
        let outcome = SolverEngine.solverReceiptPayload(model: model, result: result)
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.applySolverRun.rawValue)
        XCTAssertEqual(outcome.payload["objectiveValue"]?.numberValue, 36)
        XCTAssertEqual(outcome.payload["iterations"]?.numberValue, 3)
        XCTAssertEqual(outcome.payload["status"]?.stringValue, "optimal")
        XCTAssertEqual(outcome.payload["modelHash"]?.stringValue, model.modelHash)
        if case .object(let vars)? = outcome.payload["variableValues"] {
            XCTAssertEqual(vars[A1.description]?.numberValue, 2)
            XCTAssertEqual(vars[B1.description]?.numberValue, 6)
        } else {
            XCTFail("expected variableValues to be a JSON object")
        }
    }
}
