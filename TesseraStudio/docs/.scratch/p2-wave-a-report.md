# Wave P2-A report (2026-08-15) - Calc core

**Scope:** pivot tables (2.2a), subtotals (2.7), solver (2.6), statistics
agent tools (2.8), track-changes reviewer panel (2.9). Branch
`scratch/studio-p2/wave-a`, 7 commits (`653e290ae` wave opener through
`c4fde454f`), starting tip `7ded96d1f` (the P2-0 gate). 4-agent Workflow
dispatch (A1 pivot, A2 subtotals, A3 solver, A4 stats+reviewer) on
disjoint pure-engine/tool files, followed by a dedicated centralized
wiring pass (SheetStore.swift + TesseraToolRegistry.swift were withheld
from all 4 agents specifically to avoid a 3-track collision) and a
final verification pass.

## 1. Per-item verdicts

| Item | Track | Verdict | Note |
|---|---|---|---|
| 2.2a PivotTableStore | A1 | DONE (P2a slice) | Full compute pipeline: page filtering, group-key sort, 12 aggregations, grand totals. sort/autoShow/reference/group fields, outline/compact layout, per-field subtotals, fods round-trip explicitly deferred to P2b (a later wave) per the design contract's own slicing |
| 2.7 Subtotals engine | A2 | DONE | Group-boundary detection, row-insertion plan, outline-level assignment, all tested against the design contract's own named 2-level-nesting fixture |
| 2.7 SUBTOTAL formula function | A2 | PARTIAL | The pure function_num 1-11/101-111 aggregation law is complete, correct, and fully tested in isolation; making it LIVE for a real `=SUBTOTAL(...)` formula needs Evaluator.swift special-casing (same treatment OFFSET/INDIRECT already got) - not done this wave, real gap |
| 2.6 Solver (goal seek + simplex) | A3 | DONE | ~500-line two-phase simplex with Bland's rule, secant+bisection goal seek, deterministic linearity probe. Nonlinear DEPS/SCO engines correctly out of scope |
| 2.8 Statistics agent tools | A4 | DONE (contract stub) | 18 tools derived and shipped; no design doc names an exhaustive list, so this is a contract stub recorded for architect ratification, not a spec implementation |
| 2.9 Track-changes reviewer panel | A4 | DONE | Writer-only per the design contract's own scope correction; zero new receipt types, mirrors ActionAuditLogPanel's architecture exactly |
| SheetStore wiring (8 methods) | centralized | DONE | definePivot/removePivot/refreshPivot, applySubtotals/removeSubtotals/toggleOutline, applyGoalSeek/applySolverRun - all receipt-law compliant, all tested |
| Tool registry (20 entries) | centralized | DONE | 2 solver + 18 stats tools live in `TesseraToolRegistry.default` |

## 2. Bugs found and fixed during centralized verification

Three classes, escalating in how load-bearing they were:

1. **Compile errors in 3 of the parallel agents' own test files** (found
   by the wiring agent while building against their code for the first
   time - none of the 4 tracks were allowed to run `swift build`
   themselves this wave, by design, to avoid concurrent-build
   contention): a `@Sendable`-closure `self.` requirement in
   `SolverEngineTests.swift`, a broken-generic-inference force-unwrap in
   `SheetStatisticsToolsTests.swift`, and a missing `@MainActor` on 3
   `RevisionReviewStoreTests.swift` methods (this codebase already has
   the exact precedent in `ActionAuditLogPanelTests.swift`). All fixed,
   none changed the tests' actual assertions.
2. **A test-authoring typo**: `SheetPivotDefinitionTests.swift`'s legacy-
   fixture-synthesis test asserted `fields.count == 5` while its own
   comment said "2 row + 1 column + 2 data + 1 filter field" (= 6), and
   the very next assertion already expected 6 field names. Fixed the
   literal.
3. **A real, measured doctrine violation, not caused by any single
   track**: the corpus harness test's own wall-clock cost (already
   ~200-270s as of the P2-0 report, itself flagged there as "worth a
   future wave's attention") grew to ~400s over the course of this
   session and, combined with P2-A's ~130 new tests, pushed the default
   `swift test` suite to 6m28s - well past the 5-minute budget (rule
   13). Fixed by gating the corpus test behind an explicit
   `TESSERA_CORPUS_HARNESS=1` opt-in, the same pattern
   `TESSERA_DB_INTEGRATION` already established - it's now its own
   separately-timed gate pass rather than default-suite tax. Default
   suite is back to ~21s.

No receipts-law violations survived the gate - the 20 new SheetStore
tests all pass, including every no-op path each of the 3 new mutation
groups defines.

## 3. Known gaps (real, documented, not hidden)

- **SUBTOTAL's live-formula wiring** (item above) - the pure aggregation
  law works, a real spreadsheet formula doesn't see hidden-row/nested-
  marker state yet. Needs Evaluator.swift + 2 new SheetEngineCore query
  methods. There is currently no persisted "manually hidden row" concept
  ANYWHERE in the Sheets material distinct from autofilter's
  `SheetFilterState.hiddenRows` - `toggleOutline`'s new
  `Sheet.manuallyHiddenRows` field (this wave) is the first one, and
  SUBTOTAL's live wiring would need to read it too.
- **2.2a's own explicit deferrals to P2b**: pivot sort/autoShow/
  reference/group fields, outline/compact layout modes, per-field
  subtotal rows, fods round-trip. All named in the P2-A design contract
  itself as a later slice, not a gap this wave introduced.
- **2.8's 18-item list is a derived contract stub**, not an architect-
  ratified spec - flagged in both the source file header and
  `docs/.scratch/p2-a-findings-4.md` for async ratification.
- **2.9's receipt-id chip is best-effort**: `DocStore.acceptRevision`/
  `rejectRevision` don't return the receipt id they persist, so the
  panel does a post-hoc lookup that can miss. Clean fix is an additive
  return-type change on those two methods - not done this wave, named
  for a future one.
- **Two SOTA-report-level subtotal tests deliberately deferred**: an
  LO-produced fods outline fixture (needs UNO macro scripting to
  reproduce) and the apply-then-remove contentHash invariant (this one
  WAS actually delivered - it needed SheetStore, which didn't exist
  until the centralized pass, so it landed in the wiring commit instead
  of A2's own).

## 4. Gate

- **Default suite:** 1962 tests, 204 skipped, **0 failures**, ~21s (down
  from a transient 6m28s before the corpus-gate fix - see §2 item 3).
- **`TESSERA_DB_INTEGRATION=1`:** 1962 tests, 2 skipped, **0 failures**,
  ~26s.
- **`TESSERA_CORPUS_HARNESS=1` (its own pass, per the new gating):** 1
  test, **0 failures**, ~209s. Scoreboard regenerated at
  `docs/.scratch/p2-0-corpus-scoreboard.json` (unchanged this wave - no
  P2-A track touched the round-trip bridges the corpus harness exercises).
- **One pre-existing, unrelated flake observed and confirmed transient**:
  `ODGConnectorWireFormatProbeTests.testCustomLayerSurvivesARealSofficeRoundTripThroughODGBridgeFilter`
  failed once at 64.4s (near its 120s per-call ceiling) under full-suite
  load, passed twice at ~5s each in isolation immediately after - same
  soffice-under-load signature already documented for the corpus test in
  the P2-0 report, not a P2-A regression (nothing in this wave touches
  Draw/ODG).
- **Audit Class A (correctness/integrity):** empty. All 20 new
  SheetStore tests pass, including every no-op path.

## 5. Sequence from here

Per the plan: commit this report (done, same commit as this file), then
cut `scratch/studio-p2/wave-b` from this tip for Wave P2-B (Slides/Draw
deep + pivot I/O), which now also carries the 10 P2-0 known-gap items
the architect folded in after reviewing the P2-0 report.
