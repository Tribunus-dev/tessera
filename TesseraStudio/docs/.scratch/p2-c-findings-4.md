# P2-C findings - Track C4 (2.12 Draw advanced + 2.18 morph)

Track ownership: `Shape.swift`, `Materials/Draw/DrawingStore.swift`,
`Materials/Draw/DrawingReceiptType.swift`, `Materials/Draw/ShapeRenderer.swift`,
new `Materials/Draw/DrawTable.swift`, new `Materials/Draw/ShapeMorphEngine.swift`,
plus new/extended test files (`ShapeTests.swift`, `DrawTableTests.swift`,
`ShapeMorphEngineTests.swift`, `DrawingStoreTests.swift`, `DrawingTests.swift`,
`ShapeRendererTests.swift`).

NO DESIGN DOC beyond a one-line table description exists for 2.12's 4
sub-features (per the wave brief). Every contract below is a stub
derived from this file's own reading of the established `Shape.swift`/
`DrawingStore.swift`/`ShapeRenderer.swift` conventions (item 2.3/2.17's
own precedent, `ConnectorEndpoint`'s identity model, the receipts-law
discipline testing-doctrine.md makes non-negotiable), recorded here for
architect ratification per doctrine's "derive a stub, record it, test
against it" protocol.

---

## Design decision: item 1 (callout) is a NEW `ShapeKind.callout` case, not an orthogonal field

Considered both options the brief named. `ShapeKind.extrusion`'s own
precedent (no new case, an orthogonal field) argues for treating a
callout the same way - but real office formats do NOT: OOXML models a
callout as its own preset geometry family (`wedgeRectCallout` and
siblings under `prstGeom`), and ODF's own callout custom-shape types
are likewise their own shape family, not a property layered onto an
arbitrary shape. Extrusion genuinely IS orthogonal in both formats
(`sp3d`/an extrusion element attaches to any shape); a callout is not.
Chose `.callout` + `Shape.calloutAnchor: ConnectorEndpoint?` (the
EXISTING type, not a second attachment model, per the brief's own
instruction) to match the real-format precedent and keep future ODG/
OOXML round-trip fidelity honest. `Shape.calloutAnchor` deliberately
reuses `ConnectorEndpoint` verbatim; UNLIKE `.connector`, a callout's
own `geometry` IS its body's source of truth (only the leader line's
far end comes from `calloutAnchor`) - documented on both the new enum
case and the new field.

**Consequence needing centralized follow-up** (see the ODGBridgeFilter/
ShapeCatalog section below): this choice ripples into two files outside
this track's owned list.

## Design decision: item 2 (dimension line) reuses `ShapeKind.line` + orthogonal `Shape.dimensionInfo`

No new `ShapeKind` case - `ShapeRenderer.linePath`'s existing
horizontal-midline construction (`(x, midY)` to `(x+width, midY)`) is
already exactly a dimension line's own two endpoints; `ShapeDimensionInfo`
(units, precision, manual-override text) is a pure annotation
orthogonal to that geometry, matching `ShapeExtrusion`'s own "property
of an existing 2D shape" convention directly (there is no real-format
callout-style pull toward a distinct shape family here - LO's own
`fucon3d`-adjacent `SdrMeasureObj` is itself just a specialized `SdrObj`
subtype, not a different primitive family at the ODF/OOXML wire level
either). `measuredLength(for:)` reads `geometry.width` directly (a
`.line`'s stored length pre-rotation/flip, neither of which changes a
segment's LENGTH) - no trigonometry needed. No new files touched
outside this track's list for this item.

## Design decision: item 3 (Draw table) is `ShapeKind.table` + `Shape.table: DrawTable?`, NOT a separate `Drawing.tables` top-level entity

Seriously considered the alternative (`DrawTable` as its own top-level
array in `Drawing.swift`, like `layers`) specifically because it would
have avoided the ODGBridgeFilter/ShapeCatalog ripple entirely. Rejected
because a table needs the SAME positioning/z-order/layer-membership/
group/snap/transform behavior every other shape already gets for free
through `Drawing`'s `[Shape]`-based machinery
(`DrawingStore.setGeometry`/`.setZOrder`, `LayerStore`, `SnapEngine`,
`TransformController`, `group`/`ungroup`) - a parallel top-level entity
would mean duplicating every one of those subsystems for tables too,
exactly the "invasive change that adds a new subsystem" AGENTS.md warns
against, and each of those subsystems is ALREADY implemented and tested
against `[Shape]`. Piggybacking on `Shape` costs one enum case (plus
the two-file follow-up below); building a parallel subsystem would cost
far more. Full reasoning is on `DrawTable.swift`'s own header comment.

**Scope cut inside item 3** (recorded per the brief's own "even
'deferred, here's why' is fine" allowance): this wave ships table
CREATION (`DrawingStore.insertTable`) and per-cell CONTENT editing
(`DrawingStore.setTableCell`) - the core mutation surface named in the
brief. Row/column INSERT/DELETE (grid reflow, not just content) is
DEFERRED - real additional surface that does not fit this wave's
remaining budget alongside items 1/2/4 + morph. `DrawTable.swift`'s own
header comment records the exact follow-up shape (pure `DrawTable`
mutators + their own `DrawingStore` wrappers, the identical pattern
every method in this file already uses - no new subsystem needed
there either). Whole-table RESIZE already works for free via the
existing `setGeometry`/`setGeometries` (resizing `geometry` does not by
itself redistribute `columnWidths`/`rowHeights` - a known, documented
gap on `DrawTable`'s own header, not silently swept under).

## Design decision: item 4 (bullet lists) evolves `ShapeText` additively with `listItems`/`listStyle`, `runs` untouched

`ShapeText` gains `listItems: [ShapeTextListItem]?` and
`listStyle: ShapeTextListStyle?`, both `nil`-default so every P0/P1
shape's `ShapeText` (plain-paragraph `runs`) is unaffected and decodes
unchanged (Swift's synthesized `Optional` decoding handles this
automatically - no custom `Codable` needed, unlike `ShapeGeometry`'s
`flipH`/`flipV`, which predates this and needed one for other reasons).
`ShapeText.plainText` is extended to read `listItems` when active
(derived, matching this codebase's "no second stored copy" convention
for anything with a "plain view"). `setListItems` does NOT clear `runs`
when list mode is set - the field simply isn't what the renderer reads
while list mode is active, so no data is destroyed by toggling between
the two.

`ShapeRenderer.renderShapeTextList` reuses the exact
`BlockRenderer`->`CTFramesetter` stack `renderShapeText` already uses
(one text stack, per this file's own header), building each item's own
marker from the SAME three-way glyph vocabulary
`BlockRenderer.renderListContainer`/`.renderListItem` already
established ("*" bullet / "N." ordinal / task checkbox) rather than a
second convention, per the brief's own instruction to reuse that
plumbing. Indent level renders as 4 spaces per level (no design doc
specifies an exact indent width; a plain, easily-changed constant).

## Design decision: item 5 (morph) - id mismatch THROWS, not a silent geometry-only degrade

Both options were explicitly left open by the brief's own test-contract
wording. Chose THROW (`ShapeMorphEngine.MorphError.idMismatch`) because
"id-matched interpolation" IS the entire ratified design (AGENTS.md
decision 11) - two keyframes that do not share an identity are not a
degradable EDGE CASE of that design the way, say, `BezierPathController`'s
"a command references an index the path no longer has" is (a
legitimate temporal race against an async gesture, which that file
correctly degrades). An id mismatch here is a CALLER BUG: nothing about
this codebase's data model produces two keyframes claiming to be "the
same shape" with different `Shape.id`s except a caller passing the
wrong pair. Throwing surfaces that immediately; silently rendering a
nonsense cross-fade between two unrelated shapes would hide it. Every
OTHER genuinely-degradable case (mismatched bezier segment counts/
shapes, a missing path on either side) DOES degrade silently to a
geometry-only lerp, per the brief's own explicit instruction for that
case specifically.

**Discrete-field cross-fade, a design call not explicitly in the
brief**: every non-geometry/non-path field (`kind`, `fill`, `stroke`,
`text`, `connector`, `extrusion`, `table`, `calloutAnchor`,
`dimensionInfo`, `zIndex`, `parentGroupID`, `layerID`, and
`ShapeGeometry`'s own `flipH`/`flipV`) has no meaningful continuous
interpolation ("halfway between a rect and an ellipse" is not a thing).
Rather than hand-listing a threshold rule per field, `interpolate`
starts the WHOLE result as a copy of whichever keyframe `progress` is
nearer to (`from` for `< 0.5`, `to` otherwise) and then overrides only
`geometry` (always lerped) and `path` (lerped when index-matched, else
`nil`). This is a single, uniform, easily-stated rule covering every
present AND future discrete field on `Shape` with no per-field code to
maintain or forget to update. `anchorX`/`anchorY`: when BOTH keyframes
leave it `nil` (the default-center pivot), the result also stays `nil`
- this is exact, not an approximation, because the interpolated
width/height's own default center equals the lerp of each keyframe's
own default center (linearity: `lerp(w1,w2,p)/2 == lerp(w1/2,w2/2,p)`).
Only resolves and lerps an explicit value when at least one keyframe
actually set one.

## FOLLOW-UP NEEDED (centralized pass or a future wave): `ODGBridgeFilter.swift` / `ShapeCatalog.swift`

Both files are OUTSIDE this track's owned file list (not `.callout`/
`.table`-Draw-material files this brief names, unlike the withheld-file
category it does name) and were deliberately NOT touched, per "stick
strictly to your file list." Adding `ShapeKind.callout`/`.table`
affects them as follows:

**`ODGBridgeFilter.swift` - REQUIRED, or the file will not compile.**
Two EXHAUSTIVE `switch shape.kind`/`switch kind` statements (no
`default:`) need new arms:

- `shapeElement(_:layerNameByID:allShapes:)`'s `switch shape.kind` at
  (originally) line 251: add `case .callout: attributes.merge(boxAttributes(shape.geometry)) { _, new in new }`
  (a callout's body is a plain box, same as `.rect`/`.freeform`/
  `.ellipse` - no `svg:d`/leader-line export this wave, an accepted,
  documented loss matching `.extrusion`'s own current non-round-trip
  status) and `case .table: attributes.merge(boxAttributes(shape.geometry)) { _, new in new }`
  (same - the outer box only; no `table:table`-inside-`draw:frame`
  export this wave).
- `elementName(for:)` at (originally) line 286: add
  `case .callout: return "draw:rect"` and `case .table: return "draw:rect"`
  (both map onto the nearest real ODF primitive, same as `.freeform`
  already does - `draw:name`'s kind marker, `kindMarker(for:)`, already
  recovers the exact `ShapeKind` on re-import regardless of which
  bare element name was used, so this loses nothing beyond what
  `.freeform` already loses today).
- `shapeKind(for:)` (import direction) and `geometry(for:element:kind:)`
  both already have a `default:`/non-exhaustive shape and need NO
  change to compile; a callout/table imported from a foreign (non-
  Tessera) ODG simply won't recover its exact kind without the
  `ts-kind:` marker, same limitation `.bezier`/`.connector` already
  have for foreign files.

**`ShapeCatalog.swift` - NOT required to compile** (its `byKind`
dictionary literal has no compiler-enforced exhaustiveness - the file's
own doc comment already documents this, `entry(for:)` force-unwraps and
is contractually "never call this with .connector"). `.callout`/
`.table` simply join `.bezier`/`.connector` as kinds with NO catalog
entry (neither is a generic "drag from the shape palette" primitive -
a callout needs an anchor target and a table needs row/column counts at
creation time, both requiring a dedicated creation flow, not
`ShapeCatalog.makeShape`'s single-size-and-go convenience). `ShapeCatalogTests
.testCatalogHasExactlyOneEntryPerPalettableShapeKind` uses its OWN
hardcoded `palettableKinds` list (rule 7, independent oracle) that does
NOT reference `ShapeKind.allCases`, so it is unaffected either way -
verified by reading that test file directly, not merely asserted.

If a future wave wants callout/table ODG round-trip fidelity (a real
`svg:d`+leader-line export for callouts; a real `table:table`-in-
`draw:frame` export for tables), both are natural, additive follow-ups
in `ODGBridgeFilter.swift` alone - nothing here forecloses them.

## Testing approach note: every new store method got a pure `applying*` shadow (stronger than the `setExtrusion`/`setPath` precedent)

`DrawingStore.setExtrusion`/`.setPath` (P2-B, item 2.17/2.3) do their
no-op-guard + mutate inline, with no extracted pure function - so
neither currently has ANY test coverage (verified: no
`setExtrusion`/`setPath` reference anywhere under `Tests/`). This
track's four new methods (`setCalloutAnchor`/`setDimensionInfo`/
`setListItems`/`setTableCell`) instead each delegate to a `static`
`applying*(...)  -> (drawing: Drawing, changed: Bool)?` pure function
(mirroring `applyingGroup`/`applyingUngroup`'s existing "kept internal,
not private, so it is directly testable without a live
`TesseraDataLayer`" pattern - testing-doctrine.md rule 11), so every one
of the four has a genuine ungated shadow in `DrawingTests.swift` in
addition to its DB-gated receipt/persistence test in
`DrawingStoreTests.swift`. Flagging as a positive deviation worth
applying to `setExtrusion`/`setPath` too in a future pass (same
mechanical extraction, no design questions involved).

## Status per item

1. Callout (annotations/callouts): DONE. `ShapeKind.callout` +
   `Shape.calloutAnchor: ConnectorEndpoint?`; `DrawingStore
   .setCalloutAnchor` (receipt + persistence + no-op + error path,
   pure shadow); `ShapeRenderer` draws the body (existing fill/stroke/
   text path, reusing `.rect`'s bounding-box path) plus a dedicated
   leader line (`drawCalloutLeader`, resolves `.attached` via the
   EXISTING `ConnectorRouter.gluePoint`, no second glue-point
   implementation). ODGBridgeFilter follow-up documented above (not
   implemented - outside this track's file list).
2. Measure/dimension lines: DONE. `ShapeDimensionInfo` (units,
   precision, manual override) + `Shape.dimensionInfo`, reusing
   `.line`; `DrawingStore.setDimensionInfo` (full quartet + pure
   shadow); `ShapeRenderer.drawDimensionAnnotation` draws arrowheads at
   BOTH endpoints (a new general `arrowheadPath(tip:direction:...)`
   helper, `.arrow`'s own single-tip `drawArrowhead` refactored onto
   it with no behavior change) plus the auto-computed/overridable label
   at the midpoint.
3. Draw-side tables: DONE for the scope cut recorded above (creation +
   per-cell content editing). `DrawTable`/`DrawTableCell` (new file,
   row-major flat cell list matching `BlockType.table`'s own
   convention); `ShapeKind.table` + `Shape.table`; `DrawingStore
   .insertTable` (thin wrapper reusing the existing `insertShape`
   receipt - a table's creation is not a distinct kind of mutation) +
   `.setTableCell` (full quartet + pure shadow); `ShapeRenderer
   .renderTable` draws per-cell fills, the internal grid, then per-cell
   text (list-aware) in three passes. Row/column insert/delete/resize
   deferred (recorded above). ODGBridgeFilter follow-up documented
   above (not implemented).
4. Bullet lists inside shape text: DONE. `ShapeText.listItems`/
   `.listStyle` (additive, `runs` preserved); `ShapeTextListItem`
   (runs + indent level); `DrawingStore.setListItems` (full quartet +
   pure shadow, creates `ShapeText()` when `shape.text` was nil);
   `ShapeRenderer.renderShapeTextList` reuses `BlockRenderer`'s own
   glyph vocabulary. Wired into BOTH plain shapes (`render(_:in:
   allShapes:)`) and Draw-table cells (`renderTable`), one code path
   for both.
5. Morph (2.18): DONE. `ShapeMorphEngine.interpolate(from:to:progress:)`
   (new file, pure, no `DrawingStore`/receipt involvement per the
   ratified scope). Id mismatch throws (design decision above);
   geometry always lerps (fixture-tested at 0/0.5/1); `.bezier` path
   interpolates by matching index when subpath/segment COUNT AND
   per-segment CASE all match, else degrades to `nil` (geometry-only,
   never a wrong-shaped path); every other field cross-fades at the
   `progress < 0.5` threshold as one uniform rule (design decision
   above).
6. Tests: DONE across all 5 items - value-type round-trip identity +
   legacy-JSON back-compat (`ShapeTests.swift`, `DrawTableTests.swift`),
   DB-gated store-method receipt/persistence/no-op/error-path quartets
   (`DrawingStoreTests.swift`) each paired with an ungated pure-function
   shadow (`DrawingTests.swift`), renderer content assertions via
   offscreen-bitmap pixel sampling - not survival-only
   (`ShapeRendererTests.swift`), and morph's own fixture-derived
   geometry/path property tests (`ShapeMorphEngineTests.swift`).

wiringNotes: not applicable per the wave brief (this track owns every
file it needs directly) - EXCEPT the `ODGBridgeFilter.swift` compile
requirement documented above, which is a genuine cross-file dependency
this track's own `ShapeKind` additions create but cannot resolve
without touching a file outside its list. That section is written
precisely enough (exact case names, exact return values, exact
reasoning) that whoever runs the centralized pass does not need to
re-read this track's source to apply it.
