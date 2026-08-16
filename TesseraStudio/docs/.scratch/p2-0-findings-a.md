# P2-0 findings - Track A (Calc: fods migration, sortRange, CF/validation/hiddenRows wiring)

Track ownership: `CalcBridgeFilter.swift`, `SheetStore.swift`,
`SheetGridView.swift`, `SheetsViewModel.swift` (source), plus
`CalcBridgeFilterTests.swift` (new), `SheetStoreTests.swift` (extended),
`SheetStoreLogicShadowTests.swift` (extended, doctrine rule 11 pairing).
Items 1-7 of the P2-0 wave brief (fods migration, 1.21 @-prefixing,
sortRange hiddenRows, CF paint-path wiring, validation entry-path wiring,
hiddenRows grid wiring, comment lifecycle on SheetStore).

One row per suspected code bug, blocker, or scope note (not bugs, but
worth flagging).

---

## Blocker (item 2: 1.21 legacy-import @-prefixing) - detection shipped, marking withheld

**`CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource:)`
(CalcBridgeFilter.swift, "Legacy-import @-prefixing" extension) is the
detection half only. The actual `@`-prefix marking is NOT applied
anywhere, by design - it would corrupt every formula it touched.**

Verified by reading `Lexer.swift`'s `scanToken()`: there is no `case`
for `@` anywhere in the switch, so it falls to the `default` branch,
which throws `LexError(message: "Unexpected character '@'")` for ANY
input containing it. `Parser.swift`/`Evaluator.swift` likewise have no
`@`-prefix operator machinery (their existing "implicit intersection"
comments describe the automatic reduction Evaluator already applies to
a range used as an OPERAND - `evaluateScalarOperand` - which is a
different, already-working mechanism from the TOP-LEVEL `@`-prefix
operator Excel actually uses for this legacy-compat case). Inserting a
literal `@` into an imported formula's source text would therefore turn
a working formula into a hard parse error on every future evaluation of
that cell - strictly worse than the spilling behavior it was meant to
suppress.

This is independently corroborated by
`docs/p1-post-claim-audit-2026-08-15.md` line 75/96: "legacy-import
@-prefixing structurally blocked (CalcBridgeFilter fods migration NOT
done - still CSV/flattening)" - i.e. the audit already flagged this as
blocked pending the fods migration; having now DONE the fods migration
(item 1, this track), the remaining blocker is the missing `@`
operator itself, in `Lexer.swift`/`Parser.swift`/`Evaluator.swift` -
none of which are in track 0-A's file list this wave.

**What shipped instead:** `wouldSpillAsTopLevelResult(formulaSource:)`,
a pure, tested, read-only static function that reuses the existing
`FormulaParser`/`FormulaAST` (not a second formula grammar) to
determine whether a formula's TOP-LEVEL result would spill under
Tessera's modern dynamic-array semantics (a call to one of the five
`ArrayFunctions.swift` array-returning functions, or a bare multi-cell
range as the whole formula). It has no caller yet - the same "ready
infrastructure, not yet wired" shape `TokenArray.swift`'s own header
comment documents for itself. Full test coverage in
`CalcBridgeFilterTests.swift`.

**To finish this item:** a future wave (with `Lexer.swift`/`Parser.swift`
/`Evaluator.swift` in its file list) needs to (a) add an `@` token to
the lexer, (b) parse it as a formula-level prefix marker in the parser,
(c) route a `@`-marked top-level formula through the SAME
`implicitIntersection(_:at:sheet:engine:)` reduction `Evaluator`
already applies to operand-position ranges, then (d) `CalcBridgeFilter
.importWorkbook` can call `wouldSpillAsTopLevelResult` and prepend `@`
for a true positive. Steps (a)-(c) are the real work; (d) is a
one-line call site once they exist.

## Cross-track FYI (not a bug in my own files - `RoundTripCorpusTests.swift`
## / `Support/RoundTripCorpus.swift`, track 0-D's harness, untracked as
## of this writing)

`RoundTripScoring.sheetAxisScores` (`Support/RoundTripCorpus.swift`)
carries a doc comment that is now STALE post-fods-migration: "Counts,
never diffs formula source (CalcBridgeFilter's own doc comment: import
always flattens formulas to their last-computed value...)". That
CalcBridgeFilter behavior is exactly what item 1 in this track changed
- import no longer flattens a formula cell, it carries live source.

Worked through by hand whether this breaks that harness's byte-equality
scoring (`original.cellText(row:col:) == roundTripped.cellText(row:col:)`
for `sum-formula.ods`/`multi-column.ods`): it should NOT regress. Both
the first import (of the original fixture) and the second import (of
the CSV-round-tripped re-export) now go through the SAME
fods-based/formula-preserving path, so both produce "=SUM(A1:A2)"-style
text at that coordinate rather than both producing "12" as before - the
byte-equality check that scoring axis runs is satisfied either way, as
long as the conversion is deterministic (which it should be - same
soffice version, same relative cell positions, no restructuring
between the two imports). Not verified end-to-end against the real
fixtures myself (that file is track 0-D's, mid-flight and untracked
when I read it - editing it would be out of my file list even to fix a
stale comment). Flagging so whoever finishes/reviews that file updates
the doc comment and, ideally, adds a `.formulaSource` scoring axis now
that there is something real to measure there.

## Scope note: `CellValue.classify`'s bare-ISO-date gap is pre-existing,
## not introduced or fully fixed here

`CellValue.classify(_:columnType:)`'s `parseDate` uses
`ISO8601DateFormatter().date(from:)` under DEFAULT options, which
requires both a time-of-day AND a timezone designator - a bare
`"2026-08-15"` (what a user types, or what CSV import already carried
verbatim before this wave) fails to parse and silently falls through to
`.text`. This is a pre-existing characteristic of `CellValue.swift`
(not in this track's file list) that predates this wave and affects
every text-driven cell-classification path in the app, not just this
bridge.

What I DID do, entirely within `CalcBridgeFilter.swift`: added
`normalizedISO8601DateTime(_:)` so THIS bridge's own `office:date-value`
extraction (verified against a real soffice conversion this pass ran -
see `CalcBridgeFilterFodsProbeTests`'s probe-date comment) feeds
`CellValue.classify` a string its formatter actually accepts (appending
midnight/UTC when absent), so a fods-imported date cell round-trips as
`.date`, not silently degrading to `.text` the way it otherwise would
have. The underlying `CellValue.classify` gap itself (affecting typed
entry and any other date-bearing text) is unfixed and out of scope -
`CellValue.swift` belongs to the Sheets material's broader owner, not
this track's four files.

## Scope note: conditional-format paint-path wiring has no aggregate cache

`SheetGridView.cellView(row:col:)` calls
`viewModel.sheet.conditionalFormatOverlay(row:col:)` with no `cache:`
argument (item 4). Per that method's own doc comment this is a SAFE
default - `.top10`/`.aboveAverage`/`.uniqueValues`/`.duplicateValues`
rules simply don't match without an aggregate (documented fallback, not
a crash or wrong-cell-highlighted state) - but it does mean those four
rule kinds render inert on the grid today; only `.cellValue`/`.formula`/
`.text`/`.blanks`/`.errors` actually paint. Wiring a
`SheetConditionalFormatAggregateCache` with a real invalidation
lifecycle (on cell edit, sort, structural edit) is more than "call the
existing evaluator per cell" (item 4's literal ask); flagging as a
natural follow-up for whichever wave deepens Calc's CF surface, not a
defect in what shipped.

## Scope note: no dedicated test file for `SheetsViewModel`/`SheetGridView`
## (item 5, item 4/6 wiring)

Per the wave brief's own carve-out ("a UI-logic test is likely
impractical for SwiftUI view bodies... verify wiring by careful reading
and note that in your summary rather than fabricate a test that
doesn't test anything real"): `SheetStore` has no protocol seam over
`TesseraDataLayer` (confirmed by reading `SheetStore.swift`/
`SheetStoreTests.swift`'s own header comment before writing anything),
so `SheetEditorViewModel.commitEditingCell()`/`SheetsViewModel
.commitEditingCell()` cannot be unit-tested for "the rejected branch
never calls `store.setCell`" without either a live DB (making it a
`SheetStoreTests`-shaped test for a VIEW MODEL file, an awkward fit) or
a stub store (no seam exists to inject one). The validation DECISION
itself (`Sheet.applyingInteractiveEntry`) is already fully covered by
`SheetValidationRuleTests.swift` (pre-existing, not this track's file);
what this track added is purely the call-and-early-return wiring around
it, verified by reading both call sites (`SheetEditorViewModel
.commitEditingCell()` lines ~638-660, `SheetsViewModel.commitEditingCell()`
lines ~142-175 post-edit) rather than fabricated.

## Verified live against real soffice (not fabricated - see `CalcBridgeFilterTests.swift`'s
## `CalcBridgeFilterFodsProbeTests` probe-date comment for the full detail)

`soffice --version`: LibreOffice 26.2.5.2
(cd7284b4cbbfeb507e630c1aac019f4157393acb), present on this machine at
`/opt/homebrew/bin/soffice`. Ran a real `csv -> ods -> fods` conversion
by hand before writing `odfFormulaToTesseraSource(_:)`/
`cellSourceText(_:)`, confirming: the `of:=SUM([.A1:.A2])`
bracket-reference formula syntax (matches the pinned `sum-formula.fods`
fixture exactly); a bare cell reference emits `of:=[.B1]` (no `SUM`
wrapper); a plain date cell emits `office:value-type="date"
office:date-value="2026-08-15"` with NO time/timezone component
(motivating the `normalizedISO8601DateTime` fix above); a CSV-derived
ODS carries NO `table:number-rows-repeated`/`-columns-repeated`
anywhere (that padding is a native-.ods/.xls-specific characteristic
this probe's CSV source could not reproduce - the bounded defense
against it in `mapRows(of:)` is exercised by a hand-authored fixture
in `CalcBridgeFilterTests.swift` instead, not by a live probe).
