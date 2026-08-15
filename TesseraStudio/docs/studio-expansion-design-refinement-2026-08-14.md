# Studio Expansion Design Refinement (2026-08-14)

**Status:** RATIFIED by the architect 2026-08-14 (plan §8 rows 12-16; the
five open-question defaults adopted per row 16). Companion to
`studio-expansion-plan.md` (the plan's §6e names the three gates below; §6c.1
names the enterprise design-gate rule this doc discharges).
**Evidence:** five SOTA research reports in `docs/.scratch/`:
`sota-bridge-report.md`, `sota-calc-report.md`, `sota-canvas-charts-report.md`,
`sota-writer-slides-report.md`, `sota-enterprise-report.md`. Everything here
cites them; nothing here is asserted without a local probe or a source URL in
those files.
**Method:** the plan's own evidence-to-consolidation pattern (three explore
reports fed the original plan; five fed this refinement). Web claims were
researched 2026-08-14; local claims were verified against main
(post-P0, LibreOffice 26.2.5.2 installed).

What this doc does:

1. Discharges the three §6e P1 entry gates with concrete, evidence-backed
   proposals (Gate 1 includes empirical probes, not reasoning).
2. Gives every P1 component that lacked a design a concrete contract (type
   shape, file path, evolves/peer relationship, receipts, test contract).
3. Gives every §6c.1 enterprise item its design position, per the split rule.
4. Adds four P1 deliverables (1.0, 1.20, 1.21, 1.22) and settles ownership
   of the four unowned capability rows.
5. Proposes the §8 decisions-log rows that ratification will add.

Ratification model: each numbered GATE and DECISION below is a single
yes/no/amend for the architect. Everything else is the supporting design
record wave briefs will cite.

---

## 1. Gate 1 - bridge architecture: CLI + FlatODF (primary), scoped URP client (P2 fallback), LOK rejected

Full evidence: `sota-bridge-report.md` (empirical probes on this machine).

**Proposal.** Adopt **Option A: `LibreOfficeConverter` CLI + native Swift
flat-ODF readers/writers** as the structured-I/O architecture for 1.8, 1.18,
and 2.20. Adopt **Option C (URP socket client) only as a scoped P2 fallback**
for the two needs A cannot meet (2.6 Solver; optional SVG shape
decomposition). **Reject Option B (LibreOfficeKit)**.

Why, in one paragraph each:

- **A works today and carries everything.** Verified on this machine: fods
  carries live formulas (`table:formula="of:=..."` + cached values),
  number-format styles, multi-sheet, cell styles, named ranges; fodp carries
  master pages, placeholder classes with geometry, speaker notes, and
  transitions (smil attrs round-trip through PPTX); fodg carries layers,
  connectors with glue points, bezier `svg:d`, and custom-shape geometry.
  Tagged-PDF JSON filter options (`UseTaggedPDF`, `PDFUACompliance`)
  demonstrably toggle `/StructTreeRoot` + pdfuaid markers in the output
  bytes. Warm conversions run 2.1-2.5s; 4-way parallelism verified with
  isolated profiles. The flat XML IS the structured read; LO remains the
  filter engine for the format zoo, and Tessera parses exactly one
  documented, decades-stable schema.
- **B is empirically dead on macOS.** A C probe dlopened `libmergedlo.dylib`,
  found the LOK hooks, and crashed inside init: AppKit refuses window
  creation off the main thread, and the cask ships ONLY the Aqua VCL
  backend (no headless svp plugin, no LOK headers, no libsofficeapp).
  Upstream bug 145127 confirms: macOS LOK needs a VCL plugin that does not
  exist, unfunded. Choosing B means maintaining an LO fork.
- **C works server-side already** (the `--accept` URP acceptor came up
  headless in 4s, pure C++, no Python) but the client does not exist in any
  maintained non-Java form; a Swift URP client is thousands of lines. It is
  also a standing localhost code-execution endpoint (documented RCE class)
  that needs lifecycle supervision - a worse fit for the local-first,
  receipt-per-event posture than one-shot subprocess conversions. Build it
  only when a live UNO session is genuinely required, as a fresh
  `URPClient` peer of `LibreOfficeConverter`.

**Concrete P1 shape.**

- New components: `FlatODFReader.swift` + `FlatODFWriter.swift`
  (`TesseraCore/Productivity/ImportExport/`, peers of
  `LibreOfficeConverter`; streaming `XMLParser`, never DOM - a template
  fodp is already 2.7MB; `office:binary-data` blobs are externalized to
  asset storage on parse).
- 1.8 `LOBridgeDeckIO` = converter(odp/pptx -> fodp) + FlatODFReader ->
  `SlideDeck` AST; export = FlatODFWriter -> converter(fodp -> odp/pptx);
  PDF via `impress_pdf_Export` JSON options. **Speaker-notes PDF supported;
  handout-layout PDF is impossible in every architecture** (LO export
  filter has no handout path; print-subsystem only) - recorded as out of
  scope, not implied by "PDF deck export".
- 1.18 Draw I/O = same shape over fodg. **SVG import ships as
  embedded-image fidelity at P1** (verified: CLI SVG import produces one
  image frame, not shapes), marked as such in the AST; shape-level SVG
  import is either a P3 native parser or Option C's `.uno:Break`, decided
  at 1.18 scoping. SVG/PDF export verified working.
- `CalcBridgeFilter` migrates from the CSV intermediate to fods, which
  removes the documented P0 fidelity boundary (inbound formulas no longer
  flatten; multi-sheet and styles survive).
- Writer-side PDF export must route through the LO filter (some current
  paths use textutil/webkit) so 2.20's options apply.
- FlatODFWriter rules learned empirically: declare `xmlns:of` on formula
  documents; `draw:layer-set` lives in `office:master-styles` (misplaced,
  LO silently drops custom layers).
- Ops guardrails: keep the existing per-call isolated
  `-env:UserInstallation` profiles; add a 2-4 permit semaphore and a warmed
  profile-reuse path (cold start ~6s, warm ~2s); golden-file round-trip
  tests in CI, skipped when soffice is absent.

**Stranded-code disposition (part of this gate).** Delete
`EmbeddedPythonBridge.swift` (673 lines), `tessera_lo_service.py` (745),
`LibreOfficeBootstrap.swift` (174), and the `CPythonBridge` target + Python
3.14 framework link in `Package.swift`. The in-process-pyuno premise is dead
twice over (3.12/3.14 ABI mismatch; bundled interpreter hangs under
Gatekeeper even after the clean reinstall); nothing calls them. The
`LOEnvironment.Mode.processPool` stub is NOT the seed for Option C - a
future URP client is a fresh peer, not a revival of the Python stack.
`PythonSubprocessRunner.swift` and `TesseraFormatBridge`'s python-docx path
are unrelated (Homebrew Python subprocess, no LO linkage) and stay.

---

## 2. Gate 2 - NumberFormatEngine scope: ratify the landed scope, wire it, close two gap classes at P1

Evidence: `sota-calc-report.md` (incl. the ssf/ECMA corner-case study and
frequency ranking).

**Proposal.** Re-ratify §8 decision 4 as: *grammar-full format-code parser
in Swift; locale data delegated to Foundation/ICU; the five documented gaps
closed on a frequency-ordered schedule.* This is not a retreat from "full
parser" - svl's own locale tables bottom out in the same ICU/CLDR data
Foundation ships; hand-porting them duplicates data, not parity. What
changes is honesty plus a schedule:

- **P1 (with 1.11, high-frequency):** locale-ID currency tags (`[$EUR-407]`,
  `[$-F800]` system date, `[$-x-sysdate]`) - every UI "Long Date"/currency
  cell serializes them; and fill `*` / pad `_` directives - the stock
  Accounting formats (built-ins 41-44) contain both, so any
  accounting-styled sheet hits them. Degradation rules per SheetJS ssf
  precedent: width-less renderers drop `*` and emit one space for `_x` in
  plain-text contexts; the cell renderer, which HAS a width, implements
  them properly.
- **P2 (medium/low frequency):** elapsed-time formats (`[h]:mm:ss`,
  built-in 46; the accumulate-past-wrap math is specified) and fractions
  (`# ?/?` via continued-fraction approximation, `#/8` fixed-denominator);
  conditional sections (`[<=100]...`) last - custom-only, rarest, and even
  Excel mishandles the 3-condition case.
- **Wire the engine (P1, part of 1.11).** The landed engine has ZERO
  consumers - `SheetValueRenderer` still renders through the 8-case
  categorical `SheetNumberFormat`. 1.11 routes cell rendering through
  `NumberFormatEngine.format(...)`, with the categorical enum becoming a
  preset table of format codes (an evolution, not a parallel path). A
  parity claim for number formats is unverifiable until the engine is on
  the render path - this is a §11 claim-vs-evidence item.

---

## 3. Gate 3 - ChartRenderer staging: series-typed ChartSpec; P1a core six; honest 14-type reconciliation

Evidence: `sota-canvas-charts-report.md`.

**Proposal.**

- **Model:** a series-typed `ChartSpec` (OOXML/ODF-shaped: kind + series
  with roles + axes + legend), NOT a Vega-Lite-style mark/encoding grammar
  - office chart XML is a series list, and a grammar forces lossy inference
  in both round-trip directions. Adopt only Vega-Lite's defaults
  philosophy: an incomplete spec renders (inferred axes, auto legend when
  series > 1, palette, d3-style 1-2-5 nice()/ticks()).
  `Productivity/ChartSpec.swift` (peer of `Shape`);
  `Views/Renderers/ChartRenderer.swift`; `.chart` BlockType case using the
  landed `attributes["shape"]` bridge pattern. Axis `labelFormat` is a
  NumberFormatEngine code (Gate 2 dependency, deliberate).
- **Honest reconciliation of "14 LO types":** they map to ~10 renderer
  kinds + variants. Column/Bar (orientation flag), Pie/Donut/Exploded/
  Of-Pie (variants), Line/Area/XY (marker/fill/axis flags), Bubble
  (scatter + size role), Net (polar transform), Stock (OHLC glyphs, 4
  variants), Column-and-Line (two groups + secondary axis). The other 3 of
  14 are not renderer kinds: Pivot chart = PivotTableStore-fed data source
  (P2 2.2); Box plot = LO itself builds it as a stacked-column technique;
  Sparkline = a cell-sized no-chrome preset of the same renderer.
- **Staging:** P1a = column, bar, line, area, pie/donut, scatter - the
  dominant families, exercising the entire shared core (scales, ticks,
  legend, stacking, palette). P1b = bubble, net, stock, column-and-line,
  of-pie, sparkline preset - each adds exactly one orthogonal mechanism on
  an unchanged core, so deferral delays leaf drawing code only. One
  `ChartRenderer` component throughout; no architecture is deferred.
- Test contract: every (kind x stacking x variant) renders into an
  offscreen CGContext with no fallback path; ticks() yields 1-2-5 steps
  covering the niced domain.

---

## 4. P1 design definitions (the previously-undesigned components)

Full contracts with Swift sketches live in the scratch reports; this section
is the ratification index. Per component: file, relationship, the one
load-bearing design call, and its test contract.

### Calc cluster (evidence: sota-calc-report.md)

- **1.10 QueryEngine** (`Materials/Sheets/QueryEngine.swift`, peer of
  `SheetsViewModel`). Adopt the OOXML autoFilter criteria model: per-column
  criteria = one of {value set (OR), custom pair (2 predicates AND/OR),
  top10/percent, dynamic (dated buckets), color}; sort = ordered
  multi-key `sortCondition` list, stable (LO's explicit original-index
  tie-break), mixed-type order numbers < text < logical < error < blanks
  (blanks always last, both directions). Two lessons adopted as law:
  criteria are UI state, hidden rows are truth (they can disagree in
  imported files; never re-evaluate on load); wildcards ride equal/notEqual.
  Receipts: `sheet_sorted` / `sheet_filter_applied` / `sheet_filter_cleared`
  (one per user action). Test: multi-key stable sort matches the mixed-type
  order table; round-trip preserves criteria AND hidden-row state
  independently.
- **1.12 ConditionalFormat evaluation** (evolves the landed
  `SheetConditionalFormat` registry). Adopt cfRule semantics: integer
  `priority` (1 = highest, sheet-global), `stopIfTrue`, rule types staged
  (P1: cellIs, expression, text set, blanks/errors, top10, aboveAverage,
  uniqueValues/duplicateValues, colorScale, dataBar, iconSet with the
  documented cfvo math - dataBar length = minLength + (v-min)/(max-min) *
  (maxLength-minLength), colorScale per-channel linear interpolation,
  iconSet gte thresholds; timePeriod P2). Evaluation strategy per
  Excel/LO evidence: CF stays OUT of the dependency graph; evaluate lazily
  for the visible viewport at paint time; cache per-rule range aggregates
  (min/max/percentile/duplicate sets) with explicit invalidation on edit.
  Formula rules anchor to the range's top-left cell with relative-shift
  semantics. Test: priority/stopIfTrue winner matrix on overlapping rules;
  databar/colorScale/iconSet numeric fixtures match the documented math.
- **1.13 DataValidation evaluation** (evolves the landed
  `SheetValidationRule` registry). Adopt the industry enforcement model:
  validate at interactive entry (errorStyle stop/warning/info) + audit-after
  (an "invalid cells" query that circles violations); engine/agent/paste
  writes are RECORDED as invalid, never blocked - Excel itself lets
  paste/fill/macros bypass. Model `showDropDown` internally as
  `hideDropDown` (the OOXML attribute is inverted in practice). List
  sources: inline literals + same-workbook range refs at P1 (cross-sheet
  needs the x14 extension - bridge-side note). Test: typed entry violating
  a stop rule is rejected; agent-tool write of the same value lands and the
  audit query reports exactly that cell.
- **1.11 per-cell styles**: correction from local verification - the landed
  `SheetCellFormat` already applies per-CELL via block attributes (the
  plan's own "per-column" note was wrong in the other direction). 1.11 is
  therefore: NumberFormatEngine wiring (Gate 2), the format-code preset
  evolution of `SheetNumberFormat`, borders/alignment completion, and the
  dxf-subset needed by 1.12 - not a new storage model.
- **1.21 dynamic-array completion** (NEW deliverable; evolves
  `SheetEngine`/`Evaluator`). Spill already landed (`spillOrigin`,
  `SpillSize`, spilled-cell edit refusal - matrix row 21 was stale). The
  genuinely missing pieces: implicit intersection (`@`) with legacy-formula
  prefixing on import, `#SPILL!` obstruction semantics surfaced in the UI,
  and volatile-resize protection. **Drop `FunctionVolatility.array` (row
  20): the axis exists in no surveyed engine** - Excel models it as
  per-formula `ca`/`aca` persistence bits, LO as per-token-array
  `ScRecalcMode` bits (whose ONLOAD_* axes are worth adopting for
  import-time recalc correctness). Register OFFSET/INDIRECT as volatile
  (they are volatile-listed but unregistered today - a live correctness
  gap). Test: legacy CSE fixture imports with `@` prefixes; obstructed
  spill yields `#SPILL!` and clears when the obstruction is removed.
- **1.22 cell/slide comments** (NEW deliverable; evidence also in
  sota-writer-slides-report.md). One thread model: extend
  `Productivity/Comments.swift` with a polymorphic `CommentAnchor`
  (textRange | block | cell(sheetID,row,col) | slide) and a decode
  fallback for legacy anchors. Adopt the threaded-comments shape (person
  registry with GUID ids, flat list, parentId-to-root, UTC dT, done flag,
  plain text + mention offsets); the legacy-placeholder dual-part model is
  an XLSX export shim only. Receipts per surface
  (`sheet_comment_added`...). Test: legacy fixture decodes to `.textRange`;
  cell comments survive row/col insertion via anchor remap.

### Writer cluster (evidence: sota-writer-slides-report.md)

- **StyleRegistry (row 9)**: `Productivity/StyleRegistry.swift`;
  UUID-keyed `StyleDefinition` (family, basedOn, next, props) in
  `DocumentMeta.styles` (the `sections` registry precedent);
  `Block.attributes["styleRef"]` supersedes the string label; 4-layer
  resolution (docDefaults -> paragraph chain -> character chain -> run
  annotations), leaf-wins, cycle-guarded. Word's latentStyles/link/
  uiPriority machinery explicitly not adopted. OWNERSHIP: expansion owns
  the model + receipts + resolver; word-class Phase 3 consumes it (its
  AppKit-typed DocumentStyle sketch is superseded - it must not ship a
  second style type). Test: 3-deep basedOn chain matches OOXML
  leaf-override semantics; style deletion rebinds to parent, never dangles.
- **1.1 BlockType.field + FieldController**: `attributes["field"]` holds a
  Codable `FieldSpec` (kind: page/numPages | ref/sequence | date/time/
  author/title/docProperty + dirty flag); `content` holds the cached
  RESOLVED text as ordinary runs - so plainText()/export/agent context see
  real text, and the "LO computes layout-sensitive fields" stance is
  preserved: layout fields stay `dirty` with last-known text until a
  paginator context exists (P2). Field refresh is a receipted mutation
  (`doc_fields_refreshed`) or contentHash drifts silently. The fldChar
  begin/separate/end triple and MERGEFORMAT stay at the bridge boundary.
  `mergeField` (2.4) is a FieldSpec kind, not a tenth BlockType case.
  Test: refresh under a fixed clock is idempotent (no second receipt).
- **1.2 footnote/endnote**: `.footnote`/`.endnote` cases; note bodies are
  out-of-flow blocks registered in `DocumentMeta.notes` (the
  headerBlockID precedent); in-text reference =
  `InlineRun.Annotation.noteRef(UUID)` (one additive case); numbering
  DERIVED from reference order, never stored. v1 renders an endnotes
  section + popover; bottom-of-page placement waits for the paginator -
  TextKit 2 exclusion-path reservation is documented crash-prone and is
  explicitly not attempted. Test: reorder re-derives 1..n; old fixtures
  still decode.
- **1.14 RevisionController**
  (`Productivity/Editor/RevisionController.swift`): lifecycle over the
  existing trackInsertion/trackDeletion blocks; block UUID = revision ID;
  `attributes["revisionID"]` groups multi-block revisions (moves = paired
  ins+del sharing revisionID - no moveFrom/moveTo block types). Accept/
  reject semantics per OOXML; nested resolves innermost-first; grouped
  resolves atomically. Receipts `doc_revision_accepted/rejected` +
  batch summary; undo re-creates the block with the SAME id (receipts are
  append-only). Formatting-change tracking (rPrChange) deliberately
  dropped at P1. Test: B-deletes-inside-A-inserts resolves to the same
  contentHash in any order; accept-then-undo restores the prior hash.
- **DocumentSearchIndex (row 34)**
  (`Productivity/DocumentSearchIndex.swift`): index over depth-first block
  text sharing plainText()'s exact coordinates; per-block matching with
  explicit crossBlock opt-in; replace-all = ONE mutation + ONE
  `doc_find_replace` receipt, applied back-to-front. OWNERSHIP: expansion
  owns index + mutation + agent tool; word-class Phase 8 keeps the UI,
  repointed here (NSFindPanel-as-engine retired). Test: match offsets
  compose with plainText() to reproduce matched substrings exactly.
- **Row 10 (list levels)**: OWNERSHIP - word-class Phase 3 owns behavior
  (Enter/Tab logic, glyph rendering); level/numbering DATA lives in
  `.list`/`.listItem` attributes + list-family StyleDefinitions in the
  registry; Phase 3's literal-bullet-character approach is dropped.

### Slides cluster (evidence: sota-writer-slides-report.md + sota-canvas-charts-report.md)

- **1.5 Theme + ThemeStore**: adopt the OOXML 12-slot color vocabulary
  verbatim (dk1/lt1/dk2/lt2/accent1-6/hlink/folHlink) + major/minor fonts;
  skip fmtScheme (LO 7.6 shipped exactly this subset and round-trips). New
  `ColorRef` (.literal | .theme(slot, tint)) adopted by StyleDefinition,
  master backgrounds, and Shape fills - InlineRun colors stay literal at
  P1, so theme swaps never rewrite block bodies. Test: theme swap changes
  resolved colors while every block body's jsonData() is byte-identical.
- **1.9 MasterPageLayoutPicker**: extend `SlideLayoutSpec.builtins` with
  the LO AutoLayout catalog (~25) as DATA; add `idx: Int?` (+ optional
  `name`) to `SlideLayoutPlaceholder` (the OOXML lesson: placeholder
  identity must be explicit or re-binding is unstable); apply-layout is ONE
  receipted mutation matching blocks by idx then type, NEVER deleting
  unmatched content (PowerPoint orphan rule). Test: applying every catalog
  layout preserves the full block-ID set; re-applying is idempotent.
- **1.7 SlideDeckRenderer**: evolves BlockRenderer (mode-aware); per-slide
  single CGContext pass - layout placeholder frames (SlideLayoutSpec gains
  optional normalized `frameU` rects on placeholders, composing with the
  idx addition), text via BlockRenderer/CTFramesetter, shapes via
  ShapeRenderer in z order, charts via ChartRenderer. One substrate serves
  canvas, PNG/JPG, PDF. Test: deterministic bitmap for a title+content
  fixture slide.
- **1.6 TransitionSpec + TransitionStore**: JSON catalog (~34 presets:
  OOXML's 20 canonical + LO extras) with
  `engine: .tween | .mask | .gpu` and REQUIRED `fallbackID` on every gpu
  entry - gpu presets render their declared fallback honestly until 2.19
  lands (a wrong "cube" is worse than a declared fade). 2.19's
  CoreImage-vs-Metal split is an implementation detail INSIDE the gpu tier
  (one vocabulary, no second store). Test: catalog decodes; every gpu
  entry's fallback resolves; every OOXML p:transition child maps to
  exactly one catalog ID.
- **1.20 AnimationEffectList** (NEW numbered deliverable; was prose-only in
  6b.1): flat `[AnimationEffect]` (targetBlockID, presetID, trigger
  onClick/withPrevious/afterPrevious, durationMS, delayMS; order = play
  order). The list is provably the pre-order flattening of the SMIL
  two-level tree (mainSeq = click groups; group = onClick + followers), so
  the P2 constructor `SMILAnimationTree(flat:)` is total and
  `tree.flattened()` is its left inverse. REQUIRED at P1: the pinned
  fixture `animation-effect-list-p1.json` + byte-identical re-encode test
  + the (disabled until P2) round-trip test asserting the P2 API name. The
  fixture file must never be edited at P2 - load-compat IS the contract.

### Draw cluster (evidence: sota-canvas-charts-report.md)

- **1.15 LayerStore**: ordered named bands (`DrawLayer {id, name,
  isVisible, isLocked, isPrintable}`; `Drawing.layers` defaulting to [] =
  implicit layer; `Shape.layerID: UUID?`). Deliberately STRONGER than LO
  (layer order = paint order, the modern convention); ODG round-trip
  survives because ODF stores membership and order separately. Effective
  paint order = stable sort (band, zIndex); zIndex stays dense per layer;
  DrawingStore remains the only writer (LayerStore is pure logic, the
  ShapeZOrder precedent). Test: hiding a layer removes its shapes from the
  render list without mutating any zIndex.
- **1.17 SnapEngine**: pure + stateless; SnapContext built per
  gesture-begin (rotated-AABB edges/centers of visible unlocked
  non-selected shapes + page edges/center, viewport-pruned, ~256 cap);
  threshold = 8.0 / zoomScale (screen-space, the tldraw-evidenced
  standard); returns {dx, dy, guides} - guide DATA only, the view draws.
  Grid/page/object snap first; gap/equal-spacing guides second. Rotation
  snap: 15-degree multiples. No receipts (snapping shapes a PROPOSAL; the
  commit is the receipted event). Perf bound: <= 1ms per move at 1k
  shapes. Test: within-threshold proposals land EXACTLY on targets with
  the matching guide; outside threshold = identity.
- **1.16 TransformController**: 8 handles + dedicated rotation handle
  (LO/PowerPoint convention); rotated-resize via unrotate-resize-solve
  (opposite handle stays world-fixed); Option = center anchor, Shift =
  aspect; drag-past-opposite sets NEW `ShapeGeometry.flipH/flipV` fields
  (defaulted, old JSON decodes; flip-then-rotate order matches OOXML
  a:xfrm and ODF for field-level round-trip). Transient gesture anchors
  are NEVER written to the stored anchorX/anchorY (that is the ROTATION
  pivot contract). Zero store writes during drag; one commit per gesture,
  multi-select wrapped in `ReceiptUndoManager.group(_:)` - one Cmd-Z per
  gesture, no new receipt vocabulary. Test: opposite corner world-fixed to
  1e-9; one drag = one undo unit.
- **1.19 connector + shape text**: `ShapeKind.connector` + typed
  `Shape.connector: ConnectorInfo?` (start/end = attachedShapeID +
  gluePointID | free point; style straight/elbow/curved). Glue points:
  4 computed compass defaults indexed 0-3, mapping 1:1 onto OOXML stCxn
  id/idx AND ODF glue-point ids (custom glue points P2). Routing: derived
  at render time, escape-stub + 3-5 segment Manhattan elbow, detouring
  around only the two attached shapes (office behavior; libavoid-class
  avoidance stays behind the ConnectorRouter seam). Shape text: static
  render through BlockRenderer/CTFramesetter inside ShapeRenderer (one
  text stack); edit mode = overlay platform text view with
  first-responder handoff; one receipt per edit session. Group/ungroup UX
  (row 48) rides this cluster: selection -> group receipt setting
  parentGroupID + a shapeGroup block; TransformController recurses.
- **2.3 BezierPathController (P2, design locked now)**: classic subpath
  model (`ShapePath {subpaths: [move|line|quad|cubic, closed]}`) - NOT
  Figma vector networks (lossy against ODF/OOXML/SVG path formats, which
  are binding round-trip targets); the bend tool is the one network-era UX
  adopted. Enum-driven edit state machine; one receipt per completed
  operation. Test: ShapePath round-trips SVG path data losslessly.

---

## 5. Enterprise track design positions (2.13-2.21)

Evidence: `sota-enterprise-report.md`. Summary per item; the §6c.1 split
rule says these need ratification before any wave brief.

- **2.13 MacroCompatLayer - parse + preserve + agent-assisted rewrite;
  never execute.** Industry consensus (OnlyOffice converts VBA->JS, Google
  converts VBA->Apps Script, Microsoft web-Excel cannot run VBA; the only
  executor, Collabora, ships the LO runtime in a server container).
  Preserve `vbaProject.bin` byte-for-byte for round-trip (a shared
  `PreservedParts` mechanism, also used by 2.15); MS-OVBA decompress to
  read-only source; outline parse (signatures + API census, not a full
  grammar); `macro_translate` (tier1) drafts an agent-tool script. NO
  `macro_run` at any tier. Effort M; preservation-only slice is S. OPEN
  QUESTION for architect: translate output = stored playbook material
  (recommended) or one-shot chat plan?
- **2.14 StarMathEditor - LaTeX-first over SwiftMath.** `equation.latex`
  stays canonical; render via SwiftMath (maintained iosMath lineage, MIT,
  SPM); authoring = source editor + live preview + symbol palette (no
  WYSIWYG structure editor in v1); import maps ODF `StarMath 5.0`
  annotations and OMML to LaTeX, preserving originals for unedited
  round-trip. Effort M. OPEN QUESTION: equation numbering/cross-refs join
  FieldController (recommended) or stay out of v1?
- **2.15 Forms - content controls as Block attributes, not a material.**
  Adopt `w:sdt` (the corpus that exists), not XForms (dead) or a Forms
  material (violates the 3-foot rule). `ContentControl` payload attribute
  + inline annotation for inline SDTs; custom XML parts preserved +
  XPath-resolved; Calc scope v1 = the P1 DataValidation surface.
  `doc_form_fill` = tier1 schema-validated write. Effort M. OPEN QUESTION:
  on protected fill-in-only docs, form fill stays tier1 while other writes
  are denied - bless denial-by-protection as a tier interaction.
- **2.16 DatabaseConnector - local-file-engines-only; the doctrine wins by
  construction.** No network DSNs, no ODBC/JDBC/SDBC, no credentials,
  ever. SQLite via GRDB + DuckDB (official Swift package) over
  csv/parquet/json, engine-level read-only. `db_query` = tier0 read;
  materializing results into a sheet = tier1 receipt embedding source
  path + content hash + SQL + row count (full provenance). Enterprise
  live-DB workflows use upstream extracts - the consent boundary lives
  outside the app by design. Effort M. OPEN QUESTIONS: (a) bless the
  xlsx boundary (material files query via sheet tools; DuckDB touches
  only non-material files - avoids two xlsx readers); (b) iOS extension
  loading may drop xlsx from the v1 db path.
- **2.19 GPU transitions - reframed: the gpu engine tier of
  TransitionSpec.** OpenGL is dead on macOS; Keynote-class transitions
  ride CoreAnimation/Metal. Implementation split inside the gpu tier:
  CI transition filters (dissolve, ripple, flash...), CATransform3D
  perspective (cube, fall, turn, rochade, 3D venetian), and ~5 custom
  Metal/SwiftUI-Shader presets (vortex, glitter, honeycomb, newsflash,
  helix). Round-trip keeps the stored presetId even when playback
  approximates. Effort M (S if capped at CA+CI with declared fallbacks).
  The weakest promotion - an honest fallback ship is acceptable.
- **2.20 Tagged PDF - LO filter options through the Gate-1 converter +
  authoring preflight + veraPDF harness.** `UseTaggedPDF` +
  `PDFUACompliance` verified working end-to-end on 26.2.5.2 (Gate 1
  evidence). The real work is upstream of the flag: `AccessibilityPreflight`
  (alt text, heading order, title/lang) + a CI harness running
  `verapdf --flavour ua1` over corpus exports, asserting zero
  machine-checkable Matterhorn failures (87 of 136 are machine-decidable;
  the 47 judgment conditions get a manual checklist). Writer PDF must
  route through LO (not textutil/webkit) for the options to apply. Effort
  S for flags, M for the full slice. Highest procurement value per line of
  code in the batch.
- **2.21 Mail-merge wizard + 2.4 coordinator - coordinator-first stands;
  merge to documents, never to SMTP.** Single guided sheet (Gmail-style:
  source picker -> field chips -> preview record k -> run) over the same
  endpoint the agent calls; `merge_run` = tier2 (fan-out blast radius);
  output is documents/PDFs - the mail client owns sending (no-egress
  intact). Merge fields ride FieldController. Effort: 2.4 M, 2.21 S after.

---

## 6. P1 wave sub-sequencing (proposal)

Twenty-three P1 deliverables (19 original + 1.0 corpus harness + 1.20
animations + 1.21 dynamic arrays + 1.22 comments), sequenced by dependency,
not surface count:

1. **Wave P1-a (parallel-safe openers):** 1.0 corpus harness (everything
   else's primary metric); FlatODF reader/writer core (Gate 1); Calc
   cluster 1.10-1.13 + 1.21 (pure Swift on landed P0 infra); Draw cluster
   1.15-1.17 (pure Swift on landed data model).
2. **Wave P1-b (the Slides MVP):** 1.5 theme, 1.6 transitions, 1.7
   renderer, 1.9 picker, 1.20 animations, 1.3 ChartRenderer P1a set (charts
   land here because slides and sheets both embed them).
3. **Wave P1-c (I/O + Writer):** 1.8 deck I/O + 1.18 Draw I/O (on the
   FlatODF core), 1.1 fields, 1.2 footnotes, 1.14 revisions, 1.22
   comments, StyleRegistry, DocumentSearchIndex, 1.3 P1b chart families,
   1.19 connector + shape text.

Each wave runs under the restored §5d protocol (wave branches -> verifier
gate -> both §11 audit passes) with 6f measurement architecture per item.

## 7. Proposed §8 decisions-log rows (added on ratification)

- **12 - Bridge architecture (Gate 1):** CLI + FlatODF primary; scoped URP
  client only if/when 2.6 or SVG decomposition demands it; LOK rejected
  (empirical); stranded Python stack deleted; handout PDF recorded
  impossible; SVG import = embedded-image fidelity at P1.
- **13 - NumberFormatEngine scope (Gate 2):** grammar-full +
  Foundation-locale ratified; locale-tags + fill/pad close at P1 with the
  engine wired into rendering; elapsed + fractions P2; conditional
  sections last.
- **14 - ChartRenderer staging (Gate 3):** series-typed ChartSpec; P1a six
  core families, P1b five long-tail; pivot/box/sparkline reconciled as
  data-source/technique/preset of the same renderer.
- **15 - P1 scope additions:** 1.0/1.20/1.21/1.22 added (23 deliverables);
  FunctionVolatility.array dropped (row 20) in favor of per-formula recalc
  bits; ownership of rows 9/10/31/34/48 per this doc's table.
- **16 - Enterprise track designs (§6c.1):** positions 2.13-2.21 ratified
  as scoped here; the five open questions above answered by the architect
  inline.

## 8. Doc-sync checklist (applied with this refinement)

- `studio-expansion-plan.md`: §6e gate 1 resolution note, §6b table
  updates (new deliverables, bridge pointers, naming corrections), §7
  recap counts. [applied in the same working-tree change as this doc]
- `AGENTS.md` (repo root): expansion section still says "12 deliverables"
  at P2 and "3D + morph explicitly punted" - update to 12 core + 9
  design-gated and point at this doc. [applied]
- `docs/PROJECT-STATUS.md`: phased-rollout section same corrections; P0
  marked landed. [applied]
- Memory: the LO-bridge memory was corrected earlier today (in-process UNO
  dead; CLI converter shipped).
