# P2-B findings - Track B4 (2.2b pivot P2b + CF aggregate cache wiring + @ operator)

Track ownership: `SheetPivotDefinition.swift`, `PivotTableStore.swift`,
`CalcBridgeFilter.swift`, `SheetsViewModel.swift`, `SheetGridView.swift`,
`Lexer.swift`/`Parser.swift`/`Evaluator.swift`, plus new test files
`PivotTableStoreP2bTests.swift`, `CalcBridgeFilterPivotAndSpillGuardTests.swift`,
`ImplicitIntersectionOperatorTests.swift`,
`SheetConditionalFormatAggregateCacheWiringTests.swift`.

One row per design decision, scope call, or blocker worth flagging -
not necessarily bugs. Several of this track's sub-items had no fully
specified contract (the design contract's own text for `reference`
names only the LO source field, not a mode list; fods pivot round-trip
has no prior probe corpus to verify attribute spelling against) - each
such call is recorded below per doctrine's "derive a stub, record it,
test against it" protocol, for architect ratification.

---

## Design decision: subtotal rows and `.outline`/`.compact` are ROW-AXIS ONLY

`PivotTableStore`'s per-field subtotal-row insertion (item c) and the
`.outline`/`.compact` layout distinction (item b) apply to ROW fields
only. Column fields never grow subtotal COLUMNS, and `.compact`'s
header-collapse only touches row-header columns.

Reasoning: the design contract's own field-literal sketch
(`ScDPSaveDimension` per-dimension: `layoutInfo`, `subtotal funcs`)
technically allows either axis to carry these, and a fully symmetric
implementation (subtotal COLUMNS mirroring subtotal ROWS) is
mechanically straightforward given the recursive combo-builder already
used for both axes - but it roughly doubles the body-construction
surface (column-axis splicing needs its own recursive insert pass
across CELLS within each row, not whole rows) for a feature real-world
pivots use far less often than row grouping + row subtotals. Bounded to
rows for this pass; a symmetric column-subtotal pass is a clean,
additive follow-up (same recursive-splice technique, transposed).

## Design decision: `.compact` is a table-wide effective mode, read off `rowFields.first`

`SheetPivotFieldLayout.mode` is a PER-FIELD property (matching the real
`ScDPSaveDimension.layoutInfo` shape), so the model technically permits
mixing `.compact` on one row field and `.tabular` on another. There is
no coherent single-grid rendering for that mix (compact collapses ALL
row-header levels into one column; a per-level column can't coexist
with a collapsed one in the same grid). `PivotTableStore.build` reads
`rowFields.first?.layout?.mode` as the TABLE-WIDE effective row-header
mode - the outermost field is the natural stand-in for "which Report
Layout button the user clicked" in a real UI. If a future UI needs
genuinely mixed per-level layouts, this read point is the one place to
revisit.

## Design decision: `.outline`/`.compact` do not reproduce Excel's "outer group gets its own dedicated row" behavior

Real Excel's Outline/Compact forms give the outer group's label its OWN
row (with no data on it unless a subtotal is also shown), rather than
sharing a row with the first inner data row the way Tabular form does.
Reproducing that exactly would mean restructuring which COMBO produces
which OUTPUT ROW (not just how the label is displayed), a materially
bigger change than the label-placement + subtotal-row work already
shipped. This pass keeps P2a's "one data row per full-depth combo"
invariant unconditionally; `.outline`/`.compact` change only (a) where
the label appears (own column vs. collapsed) and (b) whether subtotal
rows exist - not the row-per-combo structure itself. Documented in
`PivotTableStore`'s own type-header doc comment; flagged here for
ratification since it is a real, user-visible simplification of the
real feature, not just an implementation detail.

## Design decision: `sort(mode: .data)` ranks by a SINGLE data field's own aggregate, not a joint multi-level aggregate

For a nested row-field hierarchy, "sort by data value" in this pass
ranks each level's own distinct values using ONLY the rows that
produced that specific value at that level (not a full multi-level
joint aggregate spanning the whole tree). This matches the common case
(sort the outer field's groups by their own total) and is what the
recursive `combosForLevel` naturally computes per level. A more exotic
"sort by a value computed jointly across sibling levels" is out of
scope. Documented on `SheetPivotFieldSort`'s own doc comment.

## Design decision: `SheetPivotReferenceMode` ships 4 of LO/Excel's "show values as" modes

The design contract names this field only as `referenceValue
(show-data-as)` (SOTA evidence line, `ScDPSaveDimension`'s own field
name) with no enumerated mode list - genuinely under-specified, same
class of gap the wave brief calls out generically for 2.17. LO/Excel's
real vocabulary (difference-from, %-of, running-total-in, rank,
index - each needing a caller-chosen BASE FIELD and often a BASE ITEM
too, with real edge cases like "no previous item") is a materially
larger feature than the rest of this item's budget affords.

Call made: ship the four modes needing NO base-field/base-item
selection - `.normal` (no-op, P2a behavior), `.percentOfGrandTotal`,
`.percentOfRowTotal`, `.percentOfColumnTotal` - the same "grand total /
row total / column total" concepts `columnGrand`/`rowGrand` already
compute, expressed as a ratio. The remaining modes are a natural,
additive follow-up (new `SheetPivotReferenceMode` cases + a
`baseField`/`baseItem` pair on `SheetPivotField`, no breaking change to
what's shipped here).

## Design decision: fods `table:data-pilot-table` round-trip - real ODF element names, `tessera:`-namespaced attributes where unverified

`CalcBridgeFilter.dataPilotTableElement(for:)`/`pivotDefinition(from:)`
use real ODF 1.2 §9.3 element names throughout
(`table:data-pilot-table`, `table:source-cell-range`,
`table:data-pilot-field`, `table:orientation`, `table:function`,
`table:data-pilot-level`, `table:data-pilot-subtotals`/`-subtotal`,
`table:data-pilot-members`/`-member`, `table:data-pilot-groups`/
`-group`/`-group-member`). Unlike the P2-0 fods cell/formula migration,
this pass had NO opportunity to probe a real soffice-authored pivot
fods (building one needs UNO macro scripting to script LO into
actually creating a pivot table, out of this track's scope/time) - so
several attribute-level details are `tessera:`-namespaced EXTENSIONS
rather than guessed-at real-ODF spelling:

- `tessera:id` - ODF has no concept of Tessera's internal definition
  UUID at all; needed for this bridge's own round-trip identity.
- `tessera:sort-mode` on `table:data-pilot-sort-info`, and the whole
  `table:data-pilot-display-info`/`table:data-pilot-field-reference`
  attribute sets - the ELEMENT names are spec-named
  (`ScDPSaveDimension`'s `sortInfo`/`autoShowInfo`/`referenceValue`),
  attribute spelling is this bridge's own choice.
- `tessera:group-by`/`tessera:date-intervals` on `table:data-pilot-
  groups` - the element name is real ODF; distinguishing numeric-vs-
  date grouping and spelling the multi-select date-interval list is
  this bridge's own convention.
- `tessera:subtotal-auto`/`tessera:repeat-item-labels` on
  `table:data-pilot-field` - `SheetPivotField.subtotalAuto`/
  `.repeatItemLabels` needed SOME attribute to round-trip through and
  the real ODF spelling was not locatable without a live sample.

**This is internally self-consistent** (encode's own output round-trips
through decode correctly - proven by
`CalcBridgeFilterPivotAndSpillGuardTests`'s direct encode -> real
`FlatODFWriter` serialize -> real `FlatODFReader` parse -> decode
test, not just an in-memory tree comparison) but is **NOT yet verified
against a real soffice-authored pivot fods** the way this file's
cell/formula mapping is (that mapping's `of:=SUM([.A1:.A2])` bracket
syntax etc. WAS verified against a real conversion in P2-0). A
soffice-probe-gated test (doctrine rule 10, `CalcBridgeFilterFodsProbeTests`'s
own pattern) is the natural follow-up once someone scripts a real pivot
fods fixture into existence - at that point the `tessera:`-prefixed
attributes above are exactly the places to check against real ODF
spelling and correct if they diverge.

## Design decision: fods pivot ENCODE has no live export-path caller (same class of blocker as the P2-0 `@`-prefixing item)

The DECODE half (`pivotDefinition(from:)`) is wired into the real
import path (`sheet(fromFlatODS:title:)`): an imported ODS/XLS with
pivot tables now populates `Sheet.pivotDefinitions` for real. The
ENCODE half (`dataPilotTableElement(for:)`) is a real, tested, pure
function with **no caller in the live byte-producing export path** -
`CalcBridgeFilter.exportWorkbook` still exports via `Sheet -> CSV ->
soffice --convert-to`, and CSV structurally cannot carry a pivot
definition at all. Wiring the encode function into a real export means
building a `Sheet -> fods` serializer through `FlatODFWriter` first - a
separate, materially larger surface (this file's own OWN doc comment,
written at the P2-0 fods migration: "a Sheet -> fods serializer... is a
real additional surface, not a trivial win") than this one item's
budget, and not something a single item within a P2b-effort-M track
should build as a side effect. Same shape this file's own
`wouldSpillAsTopLevelResult` shipped in P2-0: ready infrastructure,
wired on the read side, waiting for its write-side caller once that
larger Sheet-\>fods surface exists.

## Design decision: `@` implemented as a general prefix operator (any operand position), not restricted to the formula's leading token

Initial design attempt: special-case a leading `@` only in
`Parser.parse()`'s top-level entry point (matching the literal framing
"a leading '@' as the implicit-intersection prefix operator"). This
turned out to be WRONG once precedence was traced through by hand:
`parse()` has no general "keep consuming trailing binary operators"
loop the way `parseExpression()`'s own internal loop does - a top-level
special case would silently DROP any tokens following `@`'s own
tightly-bound operand (e.g. `=@A1:A10+1` would parse `@A1:A10` and then
throw away `+1` entirely, since nothing would ever try to consume it).

Corrected design (what shipped): `@` is a real PREFIX operator handled
inside `Parser.parseUnary()`, the exact same place `-`/`+`/`%` already
live, with the same `minPrec: 10` tight-binding convention (so
`@A1:A10+1` parses as `(@A1:A10)+1`, not `@(A1:A10+1)` - `.colon`'s
range-operator branch has no `minPrec` gate, so `@` still consumes a
full `A1:A10` range as one operand before yielding back). Because
`parseUnary()` is called from EVERY `parseExpression()` recursion, `@`
is usable at any operand position (`=@A1:A10`, `=SUM(@A1:A10)`,
`=@A1:A10+1`), not only the formula's very first token - this is also
what real modern Excel's `@` operator actually does (a user CAN type
`@` before any reference deliberately), and it is what this track's own
wave brief's test list asks for ("'@' lexes/parses/evaluates correctly
on a range reference in VARIOUS POSITIONS"). The "legacy-import marks
the WHOLE formula" use case (`CalcBridgeFilter.legacySpillGuarded`) is
just this same general operator applied at the top level - not a
separate grammar position needing its own parser branch.

## Scope note: `TokenArray.swift`'s RPN evaluator does not get real `@` range-reduction

`TokenArray.swift` (dynamic-array RPN stack machine, not in this
track's file list) emits `@`'s AST node opaquely as `.unaryOp(.implicitIntersection)`
onto its token stack (`TokenArrayBuilder.emit`'s existing generic
`.unary` case, unchanged). `TokenArrayEvaluator` reuses
`UnaryEvaluator.apply` (`TypeSystem.swift`) for every unary op; for
`.implicitIntersection` that function's own fallback is a documented
IDENTITY pass-through (see its doc comment) - it CANNOT do the real
cell-position-aware reduction `Evaluator.evalUnary`'s special case does,
since `UnaryEvaluator.apply` only ever sees an already-scalar `Value`,
never the AST + cell address the real reduction needs. Net effect: an
`@`-prefixed range inside a TokenArray-eligible formula degrades to a
no-op rather than reducing correctly. This mirrors this codebase's own
existing precedent (`TokenArray.swift`'s OFFSET/INDIRECT exclusion,
same file, same "not every formula feature is TokenArray-eligible"
shape) - flagged for whichever future track owns `TokenArray.swift` to
either exclude `@`-prefixed formulas from the TokenArray-eligible path
entirely (matching the OFFSET/INDIRECT precedent) or teach the RPN
machine real position-aware reduction. Not fixed here - out of this
track's file list.

## Design decision: CF aggregate cache lives on `SheetEditorViewModel`, not `SheetsViewModel`

The wave brief named `SheetsViewModel.swift` (the FILE) for gap item a;
that file contains THREE classes (`SheetsViewModel`, `SheetEditorViewModel`,
`SheetGridViewModel`). `SheetGridView` (the actual paint-path consumer
at line 201) binds `@ObservedObject public var viewModel:
SheetEditorViewModel` - NOT `SheetsViewModel`. The cache
(`conditionalFormatAggregateCache`) is therefore an owned property on
`SheetEditorViewModel`, matching "viewmodel-scoped lifetime" against
the class that's actually per-open-sheet and actually renders the
grid. `SheetsViewModel`'s OWN separate `commitEditingCell()`/
`applyAgentEdit()` (used by a lighter list-view grid) already funnel
through `editor?.refresh(with: updated)` at their own end, so hooking
invalidation into `SheetEditorViewModel.refresh(with:)` covers those
call sites for free without duplicating the invalidate call in
`SheetsViewModel` itself.

Invalidation is BLANKET (`invalidateAll()`) at every cell-value-mutating
call site (`commitEditingCell`, `insertRow`/`deleteRow`/`insertColumn`/
`deleteColumn`, `persistBody` (covers `commitBody`/`flushBody`),
`refresh(with:)`, `switchActiveSheet(to:)`, `recoverFromBackup()`) -
not range-precise invalidation keyed to which rules actually cover the
edited cell. The cache class's own doc comment explicitly sanctions
this for bulk edits ("cheaper to blanket-invalidate than to diff
range-by-range"); applying it uniformly avoids building a second
range-containment matcher and is trivially, obviously correct (a
superset invalidation can never leave a stale hit) at the cost of
recomputing on the next paint after ANY edit rather than only edits
inside a CF rule's own range. If profiling ever shows this matters, a
precise version is a pure optimization on top of the current, correct
behavior - not a correctness fix.

## Aggregation/grouping conventions worth knowing (no ambiguity, documenting the choice)

- Numeric grouping's out-of-range buckets: a value below `start` labels
  `"< start"`; a value >= `end` labels `"end+"` - matches Excel's own
  numeric-grouping convention of the first/last bucket absorbing
  everything beyond the declared span.
- Date grouping combines every selected `PivotDateGroupInterval` into
  ONE label per row (coarsest to finest: year, quarter, month name,
  day, hour, minute, second), using fixed non-locale formatting so the
  label is deterministic. Real Excel/LO's multi-select date-grouping UI
  can also synthesize SEPARATE column/row levels per selected interval
  (one level for Years, another for Months) rather than one combined
  label - that richer behavior is out of this pass's scope; the current
  shape covers the common "group by Year+Month into one bucket" case.
- `.members` grouping: a raw value matching none of the declared groups
  passes through UNGROUPED at its own raw value (grouped and ungrouped
  items coexist), matching Excel/LO.

## Status per item

- (a) new `SheetPivotField` properties (`sort`/`autoShow`/`reference`/
  `group`) + `PivotGroupSpec`: DONE.
- (b) outline/compact layout modes: DONE, with the two scope calls
  above (table-wide effective mode; no dedicated-row nuance).
- (c) per-field subtotal row insertion: DONE, row-axis only (scope
  call above).
- (d) sort/autoShow reusing `QueryEngine`'s landed top-N cutoff: DONE
  (`autoShow` literally constructs a `SheetFilterCriteria(kind: .top,
  ...)` and calls its existing `rowsFailing(in:)` - no second
  top-N implementation).
- (e) reference (show-data-as) modes: DONE for the 4 modes in scope
  (call above); the base-field/base-item family is an explicitly
  recorded follow-up.
- (f) fods round-trip: DECODE wired into the real import path and
  tested end-to-end; ENCODE is a real tested pure function with no
  live export-path caller yet (blocker recorded above, same class as
  the pre-existing P2-0 `@`-prefixing blocker this same track then
  unblocked in a DIFFERENT file). Reported as PARTIAL for this reason.
- gap item a (CF aggregate cache wiring): DONE.
- gap item b (`@` operator + legacy-import marking): DONE, including
  the CalcBridgeFilter wiring step. TokenArray.swift's own (out-of-file-list)
  limitation recorded above as a scope note, not a defect in what
  shipped.

wiringNotes (repeated from structured result for this file's own
completeness): none of this track's work touches `SheetStore.swift` or
`DrawingStore.swift`. `PivotTableStore.build(sheet:definition:)`'s
signature is unchanged; `SheetStore.definePivot`/`refreshPivot` already
call it generically and need no new wiring. `SheetGridView.swift:201`'s
`cache:` parameter (already existed, unused before this track) is now
passed `viewModel.conditionalFormatAggregateCache` - a one-line
argument addition, no new call site shape.
