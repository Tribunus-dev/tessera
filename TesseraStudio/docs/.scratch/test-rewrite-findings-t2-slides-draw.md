# Test-rewrite findings: cluster T2 (Slides / Draw / ImportExport / Renderers)

Cluster scope: `Tests/TesseraCoreTests/Productivity/Materials/Slides/`,
`Tests/TesseraCoreTests/Productivity/Materials/Draw/`,
`Tests/TesseraCoreTests/Productivity/ImportExport/`,
`Tests/TesseraCoreTests/Views/`, plus `ShapeTests.swift`/`ChartSpecTests.swift`.

Appended as work progresses, per doctrine bookkeeping section.

## XCTExpectFailure rows (suspected code bugs)

- **testRemoveLayerOfUnknownIDEmitsNoReceiptAndDoesNotPersist**,
  **testRenameLayerOfUnknownIDEmitsNoReceiptAndDoesNotPersist**,
  **testReorderLayersWithMismatchedOrderEmitsNoReceiptAndDoesNotPersist**,
  **testSetLayerVisibilityOfUnknownIDEmitsNoReceiptAndDoesNotPersist**,
  **testSetLayerLockOfUnknownIDEmitsNoReceiptAndDoesNotPersist**
  (Tests/TesseraCoreTests/Productivity/Materials/Draw/DrawingStoreTests.swift,
  DB-gated): SUSPECTED CODE BUG: `DrawingStore`'s layer-mutation methods
  upsert and emit a receipt unconditionally even when the underlying pure
  `Drawing` mutator (`removingLayer`/`renamingLayer`/`reorderingLayers`/
  `settingLayerVisibility`/`settingLayerLock`) no-op'd on an unknown/
  invalid id - violates doctrine rule 1 ("no receipt without a
  mutation"). Confirmed live at HEAD per
  docs/p1-post-claim-audit-2026-08-15.md Class A item 1 (`removeLayer`,
  DrawingStore.swift:334-341, still upserts + emits
  `drawing_layer_deleted` unconditionally on unknown ids at 2e49c1489).
  Not fixed here per the task brief - Wave P2-0's job.

- **testStylePropertiesTextColorAcceptsThemeReferencePerColorRefContract**
  (Tests/TesseraCoreTests/Productivity/Materials/Slides/ThemeTests.swift):
  SUSPECTED CODE BUG: `StyleProperties.textColorHex` (StyleRegistry.swift)
  is still a plain `String?` field, not `ColorRef`, so it cannot decode a
  theme color reference - contract: studio-expansion-design-refinement-
  2026-08-14.md section 4 "Slides cluster" item 1.5 ("`ColorRef`...
  adopted by StyleDefinition, master backgrounds, and Shape fills").
  Confirmed via docs/p1-post-claim-audit-2026-08-15.md item 1.5:
  "ColorRef adopted 1-of-3 (master backgrounds only; StyleDefinition +
  ShapeFill literal)".

- **testShapeFillColorAcceptsThemeReferencePerColorRefContract**
  (Tests/TesseraCoreTests/Productivity/Draw/ShapeTests.swift): SUSPECTED
  CODE BUG: `ShapeFill.colorHex` (Shape.swift) is still a plain `String`
  field, not `ColorRef` - same contract/audit citation as the
  StyleProperties row above.

- **testAllBuiltinSlideLayoutPlaceholdersHaveFrameU**
  (Tests/TesseraCoreTests/Productivity/Materials/Slides/SlideLayoutSpecTests.swift):
  SUSPECTED CODE BUG: no builtin `SlideLayoutSpec` placeholder carries a
  non-nil `frameU` - contract: refinement doc section 4 "Slides cluster"
  item 1.7 ("`SlideLayoutSpec` gains optional normalized `frameU` rects
  on placeholders"). Confirmed via
  docs/p1-post-claim-audit-2026-08-15.md item 1.7: "NO builtin layout
  currently carries frameU geometry - all multi-slot layouts render
  overlapping default bands".

- **testTitleContentSlideRendersNonOverlappingPlaceholderBands**
  (Tests/TesseraCoreTests/Views/Renderers/SlideDeckRendererTests.swift):
  SUSPECTED CODE BUG: same root cause as the frameU row above -
  `SlideDeckRenderer`'s title+content fixture slide paints its title and
  body placeholders in the SAME default band (no frameU data to
  differentiate them), overlapping. Same contract/audit citation.

## Contract not testable - symbol does not exist

- **Group/ungroup (refinement doc section 4, Draw cluster, item 1.19,
  "row 48")**: no `DrawingStore.group(...)`/`.ungroup(...)` API, no
  `DrawingReceiptType` case for it (DrawingReceiptType.swift's own doc
  comment: "`group`/`ungroup`/... have no corresponding `DrawingStore`
  method yet, so they're not cases here either"), and no
  `TransformController` group-recursion entry point. Per the task brief
  this is the doctrine's "contract not testable" path (not
  XCTExpectFailure, since there is no runtime call to make - the method
  does not exist to call). Written as a comment-only stub test in
  Tests/TesseraCoreTests/Productivity/Materials/Draw/GroupUngroupContractStubTests.swift
  citing docs/p1-post-claim-audit-2026-08-15.md item 1.19 verbatim. NOTE:
  `Shape.parentGroupID` and `BlockType.shapeGroup` DO already exist
  (vocabulary partially reserved, apparently landed after the audit was
  written) - only the store mutation + receipt + TransformController
  recursion are missing; documented precisely so this doesn't read as a
  blind copy of the audit's "not even vocabulary reserved" phrasing.

- **`ReceiptUndoManager.group(_:)` one-drag-one-undo wiring for Draw**
  (refinement doc 1.16): no Draw canvas gesture layer exists that calls
  `TransformController.resize`/`.rotate` and wraps the resulting
  `DrawingStore.setGeometry` receipts in `ReceiptUndoManager.group(_:)`
  - confirmed via docs/p1-post-claim-audit-2026-08-15.md item 1.16
  ("`ReceiptUndoManager.group` has ZERO callers; no gesture layer
  exists"). `TransformController`'s own pure-math contract (opposite
  corner stays world-fixed) IS tested directly
  (TransformControllerTests.swift) since that part of 1.16 has a
  concrete, callable symbol; the undo-grouping half is a wiring gap with
  no callable API to exercise, logged here rather than guessed at.

## Gaps / time-budget notes

Per this cluster's contract-hierarchy-fallback instructions ("write
what you can... list the ungrounded remainder" - matching T1's own
precedent in test-rewrite-findings-t1.md), the following in-scope files
were NOT reached this pass, given the size of the assigned surface
(Slides + Draw + ImportExport + Renderers is ~30 source files). None of
these were skipped because a contract could not be found - all have
clear contracts in the refinement doc / source doc comments - purely a
time-budget cut, prioritizing the explicitly-named contract items
(1.5, 1.6, 1.7, 1.9, 1.19, the DrawingStore no-op-receipt bug, the two
empirical re-probes) first, per the task brief's own ordering.

- **SlideDeck.swift**: no dedicated round-trip/legacy-fixture test file.
  Exercised only indirectly (via `SlideDeck.makeBlank()`/`makeEmpty()`/
  `insertingSlide`/`settingMasterPage`/`settingTheme` calls inside
  ThemeTests.swift, SlideLayoutSpecTests.swift, and
  SlideDeckRendererTests.swift) - no direct `SlideDeck` Codable
  round-trip + legacy-JSON-decode test (rule 2's triple) was written.
- **SlideStore.swift**: only the pure, `internal`
  `applyingLayout(_:atSlideIndex:to:)` slice is tested
  (SlideStoreLayoutApplicationTests.swift). The store's other mutation
  methods (insertSlide, deleteSlide, duplicateSlide (seen partially
  while reading, not tested), reorderSlides, setSlideTransition's own
  store-level wrapper, addComment, etc.) have no DB-gated receipts-law
  tests here - only DrawingStore (the cluster's explicitly-named known
  bug) got that treatment given the time budget.
- **MasterPageStore.swift**: not read/tested at all this pass.
- **SlideReceiptType.swift**: no dedicated vocabulary/guard test (rule
  5) - not read this pass.
- **ThemeStore.swift / TransitionStore.swift**: read for signatures
  (used by ThemeTests.swift/TransitionSpecTests.swift indirectly via
  the pure SlideDeck extensions they wrap) but have NO DB-gated
  receipts-law test of their own mutation methods
  (`defineTheme`/`setDeckTheme`/`setSlideTransition`).
- **DrawingReceiptType.swift**: no dedicated rule-5 vocabulary guard
  test (e.g. pinning the case set against `docs/agent-tools-surface.md`'s
  `drawing_*` prefix list, or asserting `group`/`ungroup`/`export`/
  `import`/`diff` are absent per that file's own doc comment) - only
  exercised indirectly via DrawingStoreTests.swift's payload assertions.
- **LOBridgeDeckIO.swift, SVGBridgeFilter.swift, PDFExportBridge.swift,
  WriterBridgeFilter.swift, CalcBridgeFilter.swift**: not read or
  tested this pass. `CalcBridgeFilter`'s CSV->fods migration status
  (per the refinement doc, "ratified... never executed" per the audit's
  Class B item 6) and the xmlns:of empirical rule's live-soffice pairing
  (FlatODFWriterTests.swift only covers it ungated) were both left
  unprobed live.
- **ChartRenderer.swift, ShapeRenderer.swift, DeckExportCoordinator.swift**:
  not read or tested this pass beyond what `SlideDeckRenderer`
  transitively calls (exercised as an implementation detail inside
  SlideDeckRendererTests.swift's rendering, never asserted on
  directly). No dedicated determinism/content/degenerate-input test
  files for any of the three.
- **SlidesGraphConnector.swift, SlidesViewModel.swift,
  DrawingsGraphConnector.swift, DrawingsViewModel.swift**: outside this
  cluster's given file list (not listed in the brief's ownership
  section) - correctly not touched, noted here only for completeness.

**Build risk flagged honestly (per the "no swift build" constraint):**
every signature this pass calls was read directly from its source file
before use, but the sheer number of new files (20) written under time
pressure means a transcription slip (a wrong label, an off-by-one on a
default parameter) is more likely than usual. The three spots with the
most hand-derived arithmetic (SnapEngineTests' hand-computed snap
fixtures, TransformControllerTests' rotated-resize fixtures, and the
DrawingStoreTests XCTExpectFailure precompute-then-assert restructuring
forced by `XCTExpectFailure`'s synchronous `failingBlock` signature) are
the ones most worth a close look in the centralized build pass.
