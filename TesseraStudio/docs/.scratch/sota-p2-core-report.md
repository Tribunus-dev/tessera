# SOTA evidence: P2-core design contracts (2.1, 2.2, 2.4-2.7, 2.9-2.11)

Prepared 2026-08-15 by the P2 planning research agent. Evidence input to
`../studio-p2-implementation-plan-2026-08-15.md`. Peer of the other
`sota-*-report.md` files. Items already designed and ratified (2.3 bezier,
2.13-2.21 enterprise incl. 2.17/2.18/2.19) are not redone here.

## Local evidence

- `Materials/Sheets/SheetPivotDefinition.swift` (143 lines, P0):
  `SheetPivotAggregation` (9 cases), `SheetPivotDataField`,
  `SheetPivotDefinition` {id, name, source range, rowFields/columnFields/
  filterFields, dataFields, output anchor}. Header says `PivotTableStore`
  "is what it will read from and eventually replace". Stored as
  `Sheet.pivotDefinitions?` with the effective* nil-means-none convention.
- `Materials/Slides/AnimationEffectList.swift` (96 lines): typealias to
  `[AnimationEffect]`; header pins the grouping rule, the constructor name
  `SMILAnimationTree(flat:)`, `flattened()` as left inverse, and the
  disabled test name.
- `Tests/.../Fixtures/animation-effect-list-p1.json`: 5 effects, 3 click
  groups; must never be edited (load-compat contract).
- `Materials/Sheets/QueryEngine.swift` (821 lines, landed): full autoFilter
  criteria model; criteria/hiddenRows independent. No subtotal or outline
  code today.
- `Editor/RevisionController.swift` (288 lines, landed): pure controller;
  receipts `doc_revision_accepted/rejected` exist.
- `Editor/FieldController.swift` (194 lines): `FieldKind` with a header
  note reserving `mergeField` as a later case on this same enum.
- `Agent/ActionAuditLogPanel.swift` (861 lines): the pull-not-push panel
  pattern to reuse for 2.9.
- `Block.swift`: BlockType currently 25 cases; `DocumentMeta {pageLayout,
  sections, notes, styles}` with decodeIfPresent-defaults - the precedent
  every additive registry below follows.
- `SlideDeck.swift`: `SlideMeta {layout, notes, masterPageID?,
  transitionID?}`. No custom-show or animation storage yet.
- `ImportExport/FlatODFReader.swift`: no anim/smil parsing today - 2.1's
  fodp import section is greenfield.
- `Doc.linkedEntityIDs: [UUID]` is ordered - usable for 2.11 without a
  schema change.
- Receipt naming convention: `{surface}_{noun}_{verbed}` snake case.

## Findings per item

**2.1 SMIL / OOXML timing model.** `p:timing` is a tree of time nodes;
every node is a `p:cTn` carried by a container (par/seq/excl) or a
behavior. `cTn@nodeType` (ST_TLTimeNodeType) has exactly 9 values: tmRoot,
mainSeq, interactiveSeq, clickPar, withGroup, afterGroup, clickEffect,
withEffect, afterEffect (note: "clickGroup" is spelled clickPar in spec).
https://c-rex.net/samples/ooxml/e1/Part4/OOXML_P4_DOCX_ST_TLTimeNodeType_topic_ID0EQ4PIB.html
`p:childTnLst` admits 13 children: par/seq/excl + anim, animClr,
animEffect, animMotion, animRot, animScale, audio, video, cmd, set.
http://www.datypic.com/sc/ooxml/e-p_childTnLst-1.html
Canonical shape: tmRoot par > mainSeq seq > one par per click group >
inner pars clickEffect/withEffect/afterEffect > behaviors.
https://learn.microsoft.com/en-us/office/open-xml/presentation/structure-of-a-presentationml-document
Iteration = cTn/iterate; event conditions (p:cond evt="onClick" + tgtEl)
drive interactiveSeq. ODF equivalent: anim:par/seq/iterate with
presentation:node-type = timing-root/main-sequence/interactive-sequence/
on-click/with-previous/after-previous, presentation:preset-class/-id,
behaviors anim:animate|set|animateMotion|animateColor|animateTransform|
transitionFilter|audio|command, targets via smil:targetElement.
http://www.datypic.com/sc/odf/e-anim_seq.html
https://www.w3.org/TR/SMIL3/smil-timing.html

**2.2 ScDPObject/ScDPSaveData.** Per-dimension (ScDPSaveDimension):
orientation (hidden/column/row/page/data), function, usedHierarchy,
showEmpty, repeatItemLabels, subtotal funcs + subtotalDefault, layoutName,
referenceValue (show-data-as), sortInfo, autoShowInfo (top-N), layoutInfo
(tabular/outline), member map. Whole-table (ScDPSaveData): dimension list,
columnGrand/rowGrand, ignoreEmptyRows, repeatIfEmpty, filterButton,
drillDown, grandTotalName, plus ScDPDimensionSaveData for group dimensions
(numeric/date/member groups). https://docs.libreoffice.org/sc/html/dpsave_8hxx_source.html
OOXML background: pivotCacheDefinition + pivotCacheRecords +
pivotTableDefinition. Per decision 12, Tessera's round-trip surface is the
fods `table:data-pilot-table` element - never the xlsx parts directly.
https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/working-with-pivottables

**2.6 Solver.** Swift ecosystem: NO maintained LP package (SwiftOptimizer
dormant ~2015; Simplex-Swift toy; forums confirm the gap).
https://github.com/haginile/SwiftOptimizer
https://forums.swift.org/t/linear-programming-library-recommendations/47799
A dense-tableau simplex with Bland's rule + variable bounds is a
well-understood 500-1K line port. Headless macro precedent exists
(soffice --headless "macro:///..." documented working) BUT the nonlinear
DEPS/SCO engines require a Java runtime - dead on stock macOS; the macro
path buys only CoinMP/lpsolve LP, which a native simplex replaces.
https://wiki.openoffice.org/wiki/NLPSolver
GoalSeek is separate and simpler (iterative root finding, no engine).

**2.5 ToC.** Word: { TOC \o "1-3" \h \z \u \t "Style,Level" }.
https://support.microsoft.com/en-US/Word/field-codes-toc-table-of-contents-field
ODF: text:table-of-content + text:table-of-content-source (outline-level +
additional styles), carried by fodt.

**2.7 SUBTOTAL + outline.** function_num 1-11 include manually-hidden
rows; 101-111 exclude them; filter-hidden rows excluded by BOTH; hidden
columns never excluded horizontally; nested SUBTOTALs ignored by the outer
call. https://support.microsoft.com/en-us/office/subtotal-function-7b027003-f060-4ade-9040-e478765b9939
Outline model: per-row outlineLevel (max 7), outlinePr@summaryBelow.
https://xlsxwriter.readthedocs.io/working_with_outlines.html

**2.10 Custom shows.** OOXML p:custShowLst > p:custShow @name @id >
p:sldLst of r:id refs. ODF: presentation:show {name, pages} (comma list of
page NAMES) inside presentation:settings.
http://www.datypic.com/sc/odf/e-presentation_show.html

**2.11 Master documents.** Consensus is unambiguous: Word master documents
corrupt structurally (canonical MVP page); 2025 guidance treats the
feature as safe only for temporary print/PDF assembly; current MS Q&A
steers users away. LO global docs (.odm) same idea, niche. Evidence
supports data-only assembly, no live subdocument editing, no .odm.
https://wordmvp.com/FAQs/General/WhyMasterDocsCorrupt.htm
https://office-watch.com/2025/word-master-documents-safely/

## Design contracts

### 2.1 SMILAnimationTree - Impress, effort L (architect-locked)

- File: `Materials/Slides/SMILAnimationTree.swift` (new); fodp import in
  the FlatODFReader slides section. Evolves AnimationEffectList (stays as
  the tree's serialization/projection per decision 7).
- Type sketch (recursive enum; SE-0295 Codable synthesis; value type):

```swift
public struct SMILAnimationTree: Codable, Sendable, Hashable {
  public var root: SMILNode            // par, nodeType == .tmRoot
  public init(flat: AnimationEffectList)   // TOTAL
  public func flattened() -> AnimationEffectList  // left inverse on legal lists
}
public indirect enum SMILNode: Codable, Sendable, Hashable {
  case par(SMILTimingProps, children: [SMILNode])
  case seq(SMILTimingProps, children: [SMILNode])
  case iterate(SMILTimingProps, IterateSpec, children: [SMILNode])
  case behavior(SMILTimingProps, target: AnimationTarget, SMILBehavior)
}
// SMILTimingProps: nodeType (9-value enum), begin: [SMILCondition],
//   durationMS?, repeatCount?, autoReverse, accelerate, decelerate,
//   fill, restart, presetClass?, presetID?
// SMILBehavior: animate/set/animateMotion(svgPath)/animateColor/
//   animateTransform/animateEffect/audio/video/command
// AnimationTarget: {blockID, paragraphIndex?}
```

- Storage: `SlideMeta.animationTree: SMILAnimationTree?` (additive)
  alongside the flat field; encode writes BOTH tree and flat projection;
  decode prefers tree, else lifts flat via init(flat:). Agent context
  keeps reading the flat projection.
- P2 subset beyond flat reconstruction: full node-type vocabulary;
  interactiveSeq + event conditions; iterate (paragraph builds); the 9
  behaviors with real parameters; accel/decel/autoReverse/repeat. excl:
  parse-and-preserve as flagged par. Totality: illegal leading
  with/after opens an implicit group - constructor never fails;
  flattened(init(flat:)) is identity on legal lists.
- Receipts: `slide_animation_effects_changed`,
  `slide_animation_effect_removed`.
- Tests: (1) pinned fixture decodes, lifts, re-flattens, re-encodes
  byte-identical - fixture untouched; (2) enable the disabled 1.20 test;
  (3) property test: random legal flat lists round-trip; (4) fodp fixture
  with on-click/with/after + iterate + interactive trigger imports to the
  expected tree; (5) iterate-bearing tree encode/decode round-trip.

### 2.2 PivotTableStore - Calc, effort XL total; staged P2a (L) + P2b (M)

- Files: EVOLVE `SheetPivotDefinition.swift` in place (persisted model);
  new `Materials/Sheets/PivotTableStore.swift` (compute engine + output
  writer, peer of QueryEngine); fods round-trip in FlatODF sheets
  sections.
- Evolution (all additive; custom decode keeps legacy JSON; pin fixture
  `sheet-pivot-definition-p0.json` NOW):
  1. `SheetPivotField {fieldName, orientation row|column|page|data|hidden,
     function?, subtotals, subtotalAuto, showEmpty, repeatItemLabels,
     sort?, autoShow?, layout?, reference?, group?, members}` - decode
     fallback synthesizes fields from legacy arrays; encode writes both
     forms until P3.
  2. SheetPivotAggregation gains median, stdDevP, varianceP.
  3. Table-level: columnGrand/rowGrand (default true), ignoreEmptyRows,
     repeatIfEmpty, filterButton, drillDown, grandTotalName?, styleInfo?.
  4. `PivotGroupSpec`: .numeric(start:end:step:) | .date(by:
     seconds...years) | .members(groups).
- Pipeline: source range -> column vectors -> page filtering -> group-key
  derivation (member sort via QueryEngine mixed-type order; autoShow
  reuses landed top-N cutoffs) -> row x column lattice -> per-data-field
  aggregation -> subtotal/grand rows per layout -> PivotResultGrid -> one
  receipted mutation writing the output range. Store pure; SheetStore the
  only writer.
- Receipts: sheet_pivot_defined/updated/removed/refreshed (payload: id,
  source hash, output range, counts). Identical-grid refresh = no-op, no
  receipt.
- Slices: P2a = steps 1-3 + pipeline + tabular layout + grand totals.
  P2b = groups (step 4), sort/autoShow/reference modes, outline/compact +
  styleInfo, fods table:data-pilot-table round-trip both directions.
- Tests: legacy P0 JSON fixture decodes to identical semantics;
  aggregation matrix (12 functions) vs hand-computed grid; date grouping;
  fods round-trip; refresh idempotence (zero receipts); QueryEngine reuse
  via shared mixed-type-order vectors.

### 2.6 Solver - Calc, effort M. RECOMMENDATION: native Swift

Goal-seek + native linear simplex; punt the nonlinear engines. Rationale:
the macro path's useful engines (DEPS/SCO) are Java-only = dead on stock
macOS, so it buys only LP, which a 500-1K line owned simplex replaces
without subprocess/profile/macro-security machinery; the URP client stays
thousands of lines for the same payoff (decision 12 keeps it last-resort).
"Solver parity" for Tessera = GoalSeek + linear Solver (min/max, linear
constraints, non-negative option) == LO's default linear-solver
experience; DEPS/SCO recorded out of scope like handout-PDF.

- File: `Materials/Sheets/SolverEngine.swift` (pure logic peer of
  QueryEngine: goal seek + simplex + linearity probe). Agent tools
  `sheet_goal_seek` / `sheet_solver_run` (tier1).
- Types: `GoalSeekRequest {formulaCell, targetValue, variableCell}`
  (secant + bisection fallback over the landed evaluator); `SolverModel
  {objectiveCell, direction, variableCells, constraints (lhsCell, op,
  rhs), assumeNonNegative}`; linearity by probing (base + unit
  perturbations, affinity check at random points) - nonlinear models
  refuse with a typed error naming the offending cell.
- Receipts: preview = proposal (no receipt); apply = one mutation,
  `sheet_goal_seek_applied` / `sheet_solver_applied` (objective value,
  iterations, status, model hash).
- Tests: textbook LP fixtures incl. degenerate tie (Bland terminates);
  infeasible + unbounded classified; goal seek quadratic within
  tolerance, idempotent re-apply; nonlinear refused; one apply = one
  receipt = one undo unit.

### 2.5 ToC - Writer, effort M

- Files: Block.swift (+ `.toc` case - BlockType case 26, needs the
  decision-3 ledger note), new `Editor/TocController.swift` (peer of
  FieldController). Alphabetical index = stretch on same machinery;
  bibliography punted to P3 (needs a citation-source material).
- Model: `.toc` block; attributes["toc"] = `TocSpec {fromLevel, toLevel,
  includeOutlineLevels (\u), hyperlink (\h), extraStyles [styleRefUUID:
  level] (\t), tabLeader}` - StyleRegistry-native. Children = generated
  entry paragraphs, each with attributes["tocEntry"] = {targetBlockID,
  level, pageText, pageDirty}. Collection = document-order blocks whose
  resolved style chain reaches a heading-family StyleDefinition in range
  + .heading intrinsic levels + outline-level attrs when \u.
- Page numbers: exactly the FieldSpec.page stance - pageText cached,
  pageDirty until a paginator exists; export serializes a real
  text:table-of-content / TOC field so LO/Word recompute (plan 4a stance
  preserved); import populates children from LO's resolved text.
- Receipts: regenerate = ONE mutation + `doc_toc_regenerated` (entry
  count, dirty-page count).
- Tests: regenerate idempotent (second call: no mutation, no receipt);
  adding a Heading-2 adds exactly one level-2 entry with resolving
  targetBlockID; \u fixture picks up outline-level paragraphs; fodt
  round-trip preserves levels + extraStyles.

### 2.7 Subtotals - Calc, effort M

- Files: QueryEngine.swift gains `SubtotalDescriptor`; insertion/outline
  logic in new `Materials/Sheets/SubtotalEngine.swift`; SUBTOTAL in the
  FormulaEngine function set; Sheet gains `rowOutlineLevels: [Int: Int]?`
  + `outlineSummaryBelow: Bool?`.
- Model: `SubtotalDescriptor {groupByColumn, perColumnFunctions [(column,
  aggregation)], replaceExisting, summaryBelow}`; nesting produces outline
  levels 1..7.
- The law: 1-11 include manually-hidden rows, 101-111 exclude; filter-
  hidden rows excluded by BOTH (SheetFilterState.hiddenRows is truth);
  hidden columns never excluded horizontally; nested SUBTOTAL ignored by
  outer. Evaluation context gains manuallyHiddenRows + filterHiddenRows
  sets + a subtotal-cell marker.
- Pipeline: descriptor -> group boundaries (display-text equality) ->
  insert real =SUBTOTAL(fn, range) rows -> assign outline levels -> ONE
  mutation + `sheet_subtotals_applied`; removal inverse
  `sheet_subtotals_removed`; collapse = hidden-row mutation
  `sheet_outline_toggled`.
- Tests: 9 vs 109 diverge exactly on a manually-hidden fixture; both
  exclude filter-hidden; nested ignored; apply-then-remove restores
  contentHash; outline levels match an LO-produced fods fixture.

### 2.9 Track-changes reviewer UI - Writer, effort S

- File: `Editor/RevisionReviewPanel.swift` (SwiftUI, peer of
  RevisionController). Zero new data model - pure scan of the AST grouped
  by revisionID (isMove pairs = one "moved" row).
- Surface (ActionAuditLogPanel patterns): pull-not-push side panel;
  compact rows (author, time, kind chip, excerpt); author + pending-only
  filters; search; receipt-id chip routes to the receipts drawer. Accept/
  Reject call the landed controller through the existing mutation path ->
  existing receipts. Accept-all / per-author = loop wrapped in
  ReceiptUndoManager.group (one Cmd-Z).
- SCOPE NOTE (honesty): plan row says "Calc + Writer" but no Calc
  revision model exists (1.14 is Doc-side). Ship Writer-first; the Calc
  half is satisfied by the receipts drawer until a Calc revision model is
  ever ratified. Recorded in the wave brief, not silently.
- Tests: each revisionID listed exactly once (move = one row);
  accept-from-panel matches controller contentHash + receipt; author
  filter partitions exactly; accept-all = one undo unit.

### 2.10 Custom shows - Impress, effort S (data only)

- Files: SlideDeck.swift (+ `customShows: [CustomShow]?` +
  `effectiveCustomShows` pruning dangling IDs on read), SlideReceiptType
  (+3 cases). No UI; agent tool `deck_custom_show_set` (tier1).
- Type: `CustomShow {id: UUID, name: String, slideIDs: [UUID]}`.
- I/O: fodp presentation:show name/pages maps via the slide-name/index
  table; OOXML custShowLst r:ids are the bridge's concern.
- Receipts: slide_custom_show_defined/updated/removed.
- Tests: legacy deck JSON decodes; deleting a slide leaves stored list
  untouched but effective list pruned; fodp round-trip of two shows
  preserves order + membership.

### 2.11 Master documents - Writer, effort S (data-only; evidence-backed)

- Recommendation: a build manifest, not a live editing surface - the
  corruption literature + one-DocumentAST doctrine both argue against
  live subdocument editing or .odm round-trip. NOT a material quartet -
  a spec on Doc (the 2.15 3-foot-rule precedent).
- Files: `Materials/Docs/MasterDocSpec.swift` + an assembly walk in
  DocumentExporter/TesseraExporter.
- Type: `MasterDocSpec {parts: [UUID], continuousNumbering: Bool,
  partBreak: .pageBreak|.sectionBreak}` on Doc (additive optional); parts
  mirrored into Doc.linkedEntityIDs (ordered) for the graph. Parts stay
  independent Docs; master body = optional front matter. Export =
  concatenate part ASTs with breaks, merge StyleRegistries (master wins
  on name collision), re-derive note/sequence numbering, through the
  EXISTING exporters. No sync-back, no live transclusion, no .odm.
- Receipts: `doc_master_parts_changed`; export rides existing export
  receipts with per-part contentHash provenance.
- Tests: assembled plainText == parts joined with breaks; continuous
  numbering re-derives 1..n; dangling part UUID skipped and named in the
  receipt payload; absent-spec decode unchanged.

### 2.4 MailMergeCoordinator - restatement (ratified; decision row 16)

Single coordinator endpoint over linkedEntityIDs-referenced data sources;
`mergeField` joins the existing FieldKind enum (reserved by name - not a
new BlockType); `merge_run` tier2, fans one template + record set out to
documents/PDFs - never SMTP; receipts carry source hash + record count;
the 2.21 wizard (S, after 2.4) is a guided sheet over this same endpoint.

## Proposed P2 waves

Ground rules carried from P1: 3-4 agents per wave on disjoint file sets;
single build at a time (16GB); shared-enum hotspots (SheetReceiptType,
SlideReceiptType, DocReceiptType, tool registry) get ALL of a wave's
additive cases pre-landed in a one-commit wave opener; Package.swift has
exactly one owner per wave. New: the wave-B opener mechanically splits
FlatODFReader/Writer into per-surface extension files
(FlatODFReader+Sheets/+Slides/+Draw) so I/O work parallelizes without
merge collisions.

**Wave P2-A - Calc core (pure Swift on landed infra; no new deps).**
- A1: 2.2a pivot compute/render - owns SheetPivotDefinition.swift, new
  PivotTableStore.swift, pivot fixtures.
- A2: 2.7 subtotals - owns QueryEngine.swift, new SubtotalEngine.swift,
  FormulaEngine SUBTOTAL, Sheet.swift outline fields.
- A3: 2.6 solver - owns new SolverEngine.swift + its two agent tools.
- A4: 2.8 statistics wizards (18 tool wrappers; enumerative) + 2.9
  reviewer panel (Writer files - zero Calc overlap).

**Wave P2-B - Slides/Draw deep pieces + pivot I/O.**
- B1: 2.1 SMILAnimationTree + 2.10 custom shows - sole owner of
  SlideDeck.swift/SlideMeta, new SMILAnimationTree.swift,
  FlatODFReader+Slides (shared-file items deliberately one agent).
- B2: 2.19 GPU transitions + 2.17 Draw 3D (both ratified) - Metal/CA
  skillset pairing; owns new Views/Transitions/* + Draw/ThreeD/*,
  TransitionStore fallback wiring.
- B3: 2.3 BezierPathController (design locked) - owns
  Draw/BezierPathController.swift, Shape.swift ShapePath.
- B4: 2.2b pivot grouping/styles/round-trip - continues A1's model; owns
  FlatODFReader+Sheets/FlatODFWriter+Sheets.

**Wave P2-C - Writer track + Draw finish.**
- C1: 2.5 ToC + 2.11 master documents - owns Block.swift (.toc), new
  TocController.swift, MasterDocSpec.swift, exporter assembly.
- C2: 2.4 MailMergeCoordinator then 2.21 wizard - sole owner of
  FieldController.swift this wave (adds .mergeField).
- C3: 2.14 StarMathEditor (ratified) - this wave's Package.swift owner
  (SwiftMath dep); equation numbering consumes existing
  FieldKind.sequence, no FieldController edits.
- C4: 2.12 Draw advanced + 2.18 morph (ratified) - both consume 2.3
  (landed in B); Draw files only.

**Wave P2-D - enterprise/compliance.**
- D1: 2.13 MacroCompatLayer - opens the wave with the shared
  PreservedParts mechanism (the 2.13/2.15 dependency), then MS-OVBA
  parse/outline.
- D2: 2.15 forms/content controls - sdt/ContentControl model first,
  PreservedParts integration after D1's opener.
- D3: 2.16 DatabaseConnector - this wave's Package.swift owner (GRDB +
  DuckDB; heaviest deps isolated in the last wave).
- D4: 2.20 tagged PDF full slice - AccessibilityPreflight + veraPDF
  corpus-harness lane + Writer-PDF-through-LO routing.

Sequencing rationale: A is dependency-free on landed P0/P1 infra; B needs
A1's evolved pivot model (B4) and groups the GPU/geometry specialists; C
consumes B's bezier; D carries the two remaining integration risks
(PreservedParts, big deps) after the core surfaces are stable, and 2.20
last means every exporter it preflights already exists.
