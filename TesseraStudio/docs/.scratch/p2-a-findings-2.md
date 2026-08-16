# P2-A findings - Track A2 (2.7 Subtotals)

Track ownership: `QueryEngine.swift` (additive: `SubtotalDescriptor` +
friends), new `SubtotalEngine.swift`, `Sheet.swift` (additive:
`rowOutlineLevels`/`outlineSummaryBelow`), new
`FormulaEngine/Functions/SubtotalFunctions.swift` + one line in
`FunctionRegistry.registerAll()`, plus new test files
`SubtotalEngineTests.swift` / `SubtotalFunctionsTests.swift`.

One row per blocker, scope note, or design decision worth flagging -
not necessarily bugs.

---

## Blocker (item 3: SUBTOTAL function) - pure aggregation shipped; live sheet-context wiring is structurally out of this track's file list

**`SubtotalAggregator.evaluate(functionNum:rows:)` (SubtotalFunctions.swift)
implements the FULL function_num law exactly and is fully tested against
hand-built row contexts. `FunctionRegistry.registerSubtotal()` registers
`SUBTOTAL` and dispatches through it correctly for the CONTEXT-FREE case
(no manually-hidden rows, no active filter, no nested SUBTOTAL cells in
the referenced range). What is NOT live: a real `=SUBTOTAL(...)` formula
evaluated through `Evaluator`/`SheetEngine` today cannot actually see
manually-hidden-row state, filter-hidden-row state, or a nested-SUBTOTAL
marker, so those three divergences never trigger in production yet.**

Root cause: `BuiltInFunction.call: ([Value]) throws -> Value` (the
generic dispatch every ordinary function goes through) receives ONLY
already-evaluated `Value`s - no sheet, no engine, no row-hidden state.
The only mechanism this FormulaEngine has for a function that genuinely
needs live sheet context is what `Evaluator.swift` already does for
OFFSET/INDIRECT: special-case the function BY NAME before the generic
dispatch (`evalFunction`'s `if upper == "OFFSET" { ... }` block) and let
it query `SheetEngineCore` directly. SUBTOTAL needs the identical
treatment - and `SheetEngineCore` would additionally need to grow two
new query methods (manually-hidden rows, filter-hidden rows) plus a way
to ask "is the formula at this cell itself a top-level SUBTOTAL call"
(for the nested-exclusion marker; the simplest implementation is almost
certainly a check on the cell's own parsed `FormulaAST` root, no new
per-cell stored flag needed).

Both `Evaluator.swift` and `SheetEngineCore` (`Evaluator.swift`'s
protocol) are SHARED files this wave (not in track A2's file list, and
not one of the two files - SheetStore.swift/TesseraToolRegistry.swift -
this wave's brief explicitly pre-negotiated as "wire centrally"). Rather
than reach into a file outside this track's lane, or invent a parallel
context-passing mechanism, the pure math + the same-shape registration
OFFSET/INDIRECT themselves carry are what shipped; the Evaluator-side
interception is left as a precise, actionable follow-up (see
`wiringNotes` in this track's structured result for the exact shape:
`evalSubtotal(args:at:sheet:depth:engine:env:)` mirroring `evalOffset`,
plus the two `SheetEngineCore` additions).

**Verify by reading:** `Evaluator.swift`'s "OFFSET / INDIRECT" section
(lines ~195-275) for the precedent; `SubtotalFunctions.swift`'s own file
header, which documents this exact gap inline (not hidden in a comment
buried elsewhere).

---

## Scope note: "manually hidden rows" has no persisted home yet

The design contract's law needs a `manuallyHiddenRows` set distinct from
`SheetFilterState.hiddenRows` (autofilter-hidden - already truth per the
contract: "SheetFilterState.hiddenRows is truth"). No such field exists
anywhere in the Sheets material today (confirmed by grep across
`Materials/Sheets/*.swift` for `rowHeight`/`RowFormat`/`hidden` before
writing this track's code - only `SheetFilterState.hiddenRows` exists).

The natural source for it is exactly this item's own outline-collapse
mechanism: collapsing an outline group is a "manual hide," not a filter
hide (`sheet_outline_toggled`'s own doc comment in
`SheetReceiptType.swift`, pre-landed this wave's opener commit, already
calls it "a hidden-row mutation, not a structural change"). But
persisting collapsed/hidden state needs a THIRD additive field on
`Sheet` (e.g. `manuallyHiddenRows: [Int]?`/`Set<Int>?`), and this
track's brief named exactly two fields to add to `Sheet.swift`
(`rowOutlineLevels`, `outlineSummaryBelow`) with an explicit "do not
touch anything else in this file." Adding a third field myself would
have been scope creep past what was negotiated for this shared file
this wave.

**Recommendation for whoever wires `toggleOutline`:** add
`Sheet.manuallyHiddenRows: Set<Int>?` (nil means none, same convention
as every other optional field in that file) alongside the SheetStore
wiring pass, and have `toggleOutline` write to it directly - it is the
row-visibility half of collapsing a group; `rowOutlineLevels` alone only
says HOW nested a row is, not whether it is currently shown.

---

## Scope note: two of the SOTA report's named tests for 2.7 are deferred, not silently dropped

`sota-p2-core-report.md`'s own test list for 2.7 (the design contract,
distinct from this track's narrower item-4 test list) also names
"apply-then-remove restores contentHash" and "outline levels match an
LO-produced fods fixture." Neither is in this track's own dispatched
test list, and both are structurally SheetStore-level or empirical-probe
concerns this track's engine-only scope cannot exercise honestly today:

- **apply-then-remove restores contentHash** needs `SheetStore
  .applySubtotals`/`.removeSubtotals` to exist (they don't - this wave's
  wiring pass adds them; see this track's `wiringNotes`, which asks the
  centralized pass to add this exact test alongside the wiring, per this
  wave's own instructions for a design contract that "calls for a
  SheetStore-level test contract").
- **LO-produced fods fixture** needs a real LibreOffice-generated ODS
  with Data > Subtotal + outline grouping applied, then this engine's
  outline-level NUMBERING CONVENTION (this track chose: summary rows at
  the shallower/lower level, detail rows one level deeper, capped at 7 -
  see `SubtotalPlan`'s doc comment in `SubtotalEngine.swift` for the
  full rule and worked example) checked against LO's own
  `table:outline-level` attributes on the same shape of input. `soffice`
  IS present in this environment (`/opt/homebrew/bin/soffice`,
  LibreOffice.app installed) so this is buildable, but producing a
  correctly-grouped Subtotal fixture needs UNO/Basic macro scripting
  (Data > Subtotal is not reachable through a plain `--convert-to`), which
  is a distinct, nontrivial side task past this item's effort-M budget
  and this track's own file list (fixture-probe test files would live
  beside `RoundTrip/*.fods`, a shared fixtures directory, and the
  probe-test file itself would need the doctrine rule-10 quarantine
  shape - `DoctrineTimeout.probe`, skip-cleanly-when-absent). Flagged
  here rather than skipped silently; a follow-up wave with soffice-probe
  time budgeted should own it.

---

## Design decision (not a bug): grand total row is unconditional

`SubtotalEngine.plan` always appends a grand-total insertion, even when
the descriptor's grouping produces exactly one group (in which case its
range is identical to that lone group's own summary row - a real, if
visually redundant, second row). This matches Excel/LO's own Data >
Subtotal dialog, which adds a grand total unconditionally whenever
"Add subtotal" is checked, not only when there is more than one group.
Documented in `SubtotalPlan`'s own header; flagged here so a reviewer
does not mistake the redundant-looking single-group case for a bug.
