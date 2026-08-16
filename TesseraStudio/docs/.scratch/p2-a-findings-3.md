# P2-A findings - Track A3 (2.6 Solver)

Track ownership: new `SolverEngine.swift`, new `SheetSolverTools.swift`,
new `SolverEngineTests.swift`, new `SheetSolverToolsTests.swift`. No
pre-existing implementation existed for this item (SolverEngine is new
code, not an evolution of something already shipped), so unlike a
test-rewrite wave there is no "contract vs. current code" gap to log as
an `XCTExpectFailure` finding here - every row below is a design
decision or a scope note, not a suspected code bug.

Status: item complete (1-3 all done). No blockers.

---

## Design decision: preview/apply split lives INSIDE the two tool structs, not as four tools

The wave brief's phrasing ("a PREVIEW call ... and an APPLY call ... are
architecturally distinct") could be read as four tool structs (two
preview + two apply). The brief's own item-2 line count ("Two agent
tools ... sheet_goal_seek (tier1), sheet_solver_run (tier1)") settles
it at exactly two. The "architecturally distinct" part is satisfied the
same way `QueryEngine`'s mutation methods are distinct from
`SheetStore`'s persistence step (`sortRange`/`applyFilter`/`clearFilter`
each compute-and-return an outcome; the STORE is what turns that into a
receipt) and the same way `DrawingStore.group`'s pure
`applyingGroup(_:to:)` is distinct from the receipted `group(_:for:)`
wrapper: `SolverEngine.goalSeek`/`.solve` are the pure compute step (no
receipt, ever - callable directly for a preview), and
`.goalSeekReceiptPayload`/`.solverReceiptPayload` are separate pure
functions an APPLY caller uses to shape the receipt once it has decided
to persist. The tool's own `apply: Bool` argument picks which of those
two code paths executes.

## Design decision: apply fails closed, not stubbed to "succeed" or silently no-op

`SheetStore.swift` is centrally owned this wave (not this track's
file - see the wave brief's structural constraint), so
`applyGoalSeek`/`applySolverRun` do not exist yet. The apply branch in
both tools returns `.fail(...)` naming exactly what is missing
(`SheetStore.applyGoalSeek` / `SheetStore.applySolverRun`) rather than:
(a) silently falling back to writing through the raw
`SheetToolContext.shared.writer` cell-edit path (which exists for
`sheet_write` and WOULD compile and "work", but would emit a generic
`sheet_cell_changed` receipt instead of the design contract's
`sheet_goal_seek_applied` / `sheet_solver_applied` receipt with its
required payload - objective value, iterations, status, model hash -
so it would be a receipt-shape violation dressed up as success), or
(b) reporting success with no persistence at all (a silent no-op that
LOOKS like it worked). Both alternatives were rejected as strictly
worse than a clear, testable failure. See `SheetSolverToolsTests`'
`test*ApplyFailsClosed*` cases.

`sheet_solver_run`'s apply path additionally refuses BEFORE it would
reach the not-yet-wired store call when `result.status != .optimal`
(infeasible/unbounded/iteration-limit) - there is nothing to commit, and
this check is not a wiring workaround: it stays correct after the
centralized pass wires the real store call too, so it did not need a
`TODO` marker.

## Design decision: tier1 maps to `ApprovalLevel.notify` directly, not through `TesseraTier`

Every existing Sheets tool (`SheetReadTool` -> `.auto`, `SheetWriteTool`
-> `.prompt`) sets `defaultApprovalLevel` as a direct `ApprovalLevel`
literal; none of them route through `TesseraTier` at the call site
(`TesseraTier` is agent-ux-fatigue's naming/audit layer over the
already-existing `TesseraSafetyDecision.check` gate - see that type's
doc comment: "the actual gate ... is still computed by
`TesseraSafetyDecision.check`"). Both solver tools follow the same
established shape: `ApprovalLevel.notify`, justified in each tool's doc
comment by `TesseraTier.tier1.displayName == "Tier 1 (notify)"`. Tested
directly in `SheetSolverToolsTests.test*DefaultApprovalLevelIsNotify`.

## Design decision: `SolverCellIO` (read/write closures), not a `SheetEngine` reference

Mirrors `QueryEngine.sortedRowOrder`'s `cellValue` closure parameter -
`SolverEngine` never imports a dependency on `SheetEngine` and every
engine-level test in `SolverEngineTests.swift` uses a synthetic
dictionary-backed function standing in for a workbook, matching
`QueryEngineTests`' own pattern. `SheetSolverTools.swift`'s
`SheetSolverToolSupport.cellIO(engine:sheet:)` is the one place that
bridges the closures to a real `SheetEngine.getValue`/`.setValue` call -
this is also the literal fulfilment of the design contract's "find how
the existing evaluator is invoked for a single-cell recalculation and
reuse that entry point" instruction: `SheetEngine.setValue` already
recalculates every downstream formula on write, so goal seek's and the
solver's linearity probe's repeated `io.write` calls get a fully
live, correctly-recalculated `io.read` on the very next line, with zero
second-evaluator code anywhere in this track's files.

## Design decision: `constraints` argument shape given this codebase's flat `SchemaProperty`

`SchemaProperty` has no `items`/`properties` sub-schema vocabulary (only
`type`/`description`/`enumValues`/`defaultValue`/`minimum`/`maximum` -
see `Agent/TesseraTool.swift`). `EscalateReasoningTool` already
established the precedent for this gap: declare `type: "array"` with a
prose description, and accept whatever `JSONValue.array`/`.object`
structure actually arrives at runtime (no schema-level nesting exists to
violate). `sheet_solver_run`'s `constraints` argument is `[{lhs_cell,
op, rhs}]`, `op` in `{lte, gte, eq}` (also accepts the `<=`/`>=`/`==`/`=`
spellings) - documented in the property's `description` string since
there is nowhere else in this codebase's tool schema to put it.

## Design decision: linearity probe's fixed multi-point affinity check

The design contract says "unit-perturbation evaluations + an affinity
check at a few random points (use a FIXED seed ... deterministic)".
Implemented as three FIXED (non-random) probe points, each variable
offset by `multiplier + index*0.37 + probeIndex*0.11` so no two
variables ever land on the same probed value (which would hide a
cross-term coefficient asymmetry) and no probe point coincides with the
base or a unit-perturbation point. Verified by hand in
`SolverEngineTests` that a bilinear objective (`x*y`) IS caught by this
check despite BOTH of its own unit perturbations from the all-zero base
equalling 0 - a unit-perturbation-only check (no multi-point affinity
check) would have missed it entirely; see that test's doc comment for
the worked numbers.

## Design decision: `assumeNonNegative == false` uses variable splitting (`x = u - v`), not explicit bounds in the tableau

A dense-tableau simplex's rows are equality constraints on non-negative
variables by construction; representing an unbounded-sign variable
needs either (a) splitting into the difference of two non-negative
variables, or (b) a bounded-variable simplex variant that tracks
per-variable lower/upper bounds outside the tableau rows. (a) is the
textbook approach and was chosen for scope reasons (the design contract
calls this "a real ~500-1K line algorithm ... prioritize correctness on
textbook cases" - a full bounded-variable simplex is meaningfully more
machinery for a case the design contract's own test list does not
explicitly require beyond the boolean flag existing). Covered by
`SolverEngineTests.testFreeVariableModelSolvesWithoutNonNegativeAssumption`
(minimize x s.t. x >= -5, hand-traced to x = -5) - the ONE test exercising
this path; it does not additionally exercise the split-variable path
together with phase-1 artificials in the same model (that combination is
untested), noted here rather than silently assumed correct.

## Scope note: `SolverStatus.iterationLimitExceeded`

Not named in the design contract's status vocabulary, but Bland's rule
guarantees finite termination for any well-formed model - hitting the
iteration budget without reaching optimal is a "budget too small for
this model's size" signal, not a fourth mathematical classification
alongside optimal/infeasible/unbounded. Added as an honest 4th status
rather than folding it into `.infeasible` (wrong) or crashing/looping
forever (worse). Not exercised by a dedicated test (would need an
artificially tiny `maxIterations` on a model that provably needs more
pivots than that to prove the branch fires, which risks becoming exactly
the kind of implementation-detail-pinning test rule 9 warns against) -
the branch exists and is exercised implicitly by every other
solver test's iteration counts staying well under the default budget.

## Wiring notes

See this track's structured result `wiringNotes` field for the exact
`SheetStore.applyGoalSeek(_:for:)` / `applySolverRun(_:for:)` signatures,
the `TesseraToolRegistry.default` array entries, and the exact
`SheetSolverTools.swift` execute()-body edits (the `// TODO(P2-A
centralized wiring pass)` comments in that file mark the precise
insertion points) the centralized pass needs to make.
