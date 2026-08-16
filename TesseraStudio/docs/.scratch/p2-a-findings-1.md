# P2-A findings - Track A1 (2.2a PivotTableStore)

Track ownership: `SheetPivotDefinition.swift` (evolved in place), new
`PivotTableStore.swift`, new `SheetPivotDefinitionTests.swift` /
`PivotTableStoreTests.swift`, new pinned fixture
`sheet-pivot-definition-p0.json`.

One row per blocker, scope note, or design decision worth flagging -
not necessarily bugs.

---

## Design decision: `sort`/`autoShow`/`reference`/`group` are NOT fields on `SheetPivotField` yet

The design contract's step 1 field literal (`sota-p2-core-report.md`
#2.2) lists `SheetPivotField {..., sort?, autoShow?, layout?,
reference?, group?, members}` as part of "steps 1-3" (P2a scope). But
the SAME section's own "Slices" line says "P2b = groups (step 4),
sort/autoShow/reference modes, ..." - and the wave brief's TRACK line
says "groups/sort/autoShow/outline/fods round-trip are P2b ... out of
scope here." Those two more-specific statements read as authoritative
over the step-1 field literal for these four names specifically:

- `group` needs `PivotGroupSpec` (design contract step 4), which is
  explicitly its own deferred step - I did not invent a placeholder
  type for it (unlike `styleInfo`, its rough shape - three concrete
  cases - IS already sketched in the design contract, so a placeholder
  risked being wrong in a way that costs P2b real rework rather than
  saving it any).
- `sort`/`autoShow`/`reference` are each named as a P2b "mode" whose
  real vocabulary isn't sketched anywhere in the design contract (unlike
  `group`). Adding empty struct placeholders for these felt like more
  invented surface than the contract asked for.

Resolution: none of the four are fields on `SheetPivotField` at P2a.
Adding each later is a pure-additive `Optional` property (or, for
`group`, an additive `[String: ...]`-free single field) - decoding a
P2a-written JSON simply reads it as absent, no migration. `layout` IS
present (with only `.tabular` in `SheetPivotFieldLayoutMode` today) -
its P2a portion ("tabular layout") is unambiguously in scope in both
readings, and `.outline`/`.compact` grow the enum additively later
exactly like `SheetPivotAggregation` grew 9 -> 12.

If the architect reads step 1's literal field list as binding regardless
of the Slices/TRACK-line carve-out, this is a one-line fix per field
(add the `Optional` property) with no fixture or pipeline rework needed.

## Design decision: `SheetPivotTableStyleInfo` placeholder shape

Used the license the design contract explicitly grants ("styleInfo can
be a minimal placeholder type"): `{ styleName: String? }`. P2b (fods
`table:data-pilot-table` round-trip + outline/compact styling) will
almost certainly need more (border/banding flags at minimum, matching
`PivotTableStyleInfo`'s real LO shape) - this is a placeholder, not a
final design.

## Design decision: which P2a-scope fields the pipeline actually interprets vs. round-trips only

Several fields decode/encode/persist correctly at P2a but are NOT yet
read by `PivotTableStore.build`, because their real behavior is closer
to P2b's outline/compact/declared-membership work than to "tabular
layout + grand totals":

- `SheetPivotField.subtotals` / `.subtotalAuto` (per-field subtotal
  rows between groups - not the same as the grand total row, which IS
  implemented).
- `SheetPivotField.showEmpty` (declaring a member with no matching data
  should still show as a blank row/column - has no mechanism to hook
  into without declared membership, which is P2b/`PivotGroupSpec`
  territory).
- `SheetPivotField.members` on `.row`/`.column` orientation fields (only
  `.page`-oriented `members` is live - see `PivotTableStore`'s
  page-filtering stage; `.row`/`.column` `members` round-trips only).
- `SheetPivotDefinition.repeatIfEmpty`.
- `SheetPivotDefinition.filterButton` / `.drillDown` (UI-only by design
  - a pure compute engine has no reason to ever read these).

`SheetPivotField.repeatItemLabels` is the one exception that IS fully
implemented at P2a (group-header blanking on continuation rows/columns)
- see `PivotTableStoreTests.testRepeatItemLabelsDefaultsToFalseAnd...`
and its `true` counterpart.

## Design decision: per-field subtotal rows are out of P2a's pipeline

The design contract's pipeline sentence says "subtotal/grand rows per
layout." I implemented grand rows/columns only. Per-field subtotal rows
(one extra row after each outer-group in a multi-level row-field
layout, using `subtotals`/`subtotalAuto`) are visually and
structurally closer to outline/compact rendering, which is explicitly
P2b, and are not named in the wave brief's own P2a slice ("tabular
layout + grand totals" - subtotal rows are absent from that list, grand
totals are present). No required test in the track brief exercises
them either. Flagging this explicitly since the design contract's
prose is not 100% unambiguous about it - a reasonable alternate reading
puts basic per-field subtotals in P2a too.

## Cross-track note (not fixed here - file not in this track's list): stale comment in `QueryEngine.swift`

`QueryEngine.swift` (around the `SubtotalAggregationFunction` doc
comment added by the parallel Track A2 / 2.7 Subtotals track) says:
"Deliberately its OWN vocabulary, not a reuse of `SheetPivotAggregation`
... the pivot engine's simplified 9-case set is missing exactly those
three [countA, stdDevP, varianceP]." After this track's change,
`SheetPivotAggregation` is a 12-case set that DOES include `stdDevP`
and `varianceP` (only `countA`/COUNTA-style semantics remain genuinely
absent - `SheetPivotAggregation.count` counts non-empty cells of any
type, which is closer to COUNTA already, and `.countNumbers` is the
numeric-only counterpart). The comment's core conclusion (SUBTOTAL needs
its own vocabulary, not a reuse of the pivot enum) still holds, but the
"missing exactly those three" claim is now stale in a minor way. Not
edited here - `QueryEngine.swift` is not in this track's file list and
Track A2 is actively working in it this same wave; noting it for the
centralized pass or Track A2 to reconcile in one line.

## Aggregation conventions worth knowing (no ambiguity, just documenting the choice for the next reader)

- Numeric coercion for `.sum`/`.average`/`.min`/`.max`/`.product`/
  `.median`/`.stdDev`/`.variance`/`.stdDevP`/`.varianceP` accepts only
  `.number`/`.date` (a date's numeric key is its Unix timestamp) -
  matches `QueryEngine.numericSortKey`'s existing convention exactly,
  reused rather than reinvented. `.checkbox` is excluded from all of
  these (it counts under `.count` only), also matching that file's
  precedent (`QueryEngine.sortRank` buckets `.checkbox` separately from
  `.number`).
- `.stdDev`/`.variance` (sample, n-1 denominator) on exactly one numeric
  value returns `CellValue.error("#DIV/0!")`, matching Excel's
  STDEV/VAR on a single-cell range. The population variants
  (`.stdDevP`/`.varianceP`) have no such degenerate case.
- A group with zero numeric values returns `CellValue.empty` (genuinely
  "no data"), never `.number(0)`, for every function except
  `.count`/`.countNumbers` (which correctly answer `0`).
