# Tessera Studio Expansion Plan: LibreOffice Capability Parity

**Status:** architect-approved (2026-08-13), Draw scope added 2026-08-13. Open questions resolved; see §8 decisions log. **P0 landed on main 2026-08-14** (16/16 deliverables; see §2.1 status refresh and the §6a execution addendum). **Refinement pass 2026-08-14**: post-P0 corrections, P1 entry gates (§6e), and per-component design definitions in `studio-expansion-design-refinement-2026-08-14.md` (companion doc; SOTA evidence in `docs/.scratch/sota-*-report.md`).
**Date:** 2026-08-13 (initial), 2026-08-13 (Draw scope added), 2026-08-14 (P0 landed + refinement pass)
**Author:** Mavis (orchestrator), with capability inventories from three explore agents
**Scope:** documents (Writer), spreadsheets (Calc), presentations (Impress), drawings (Draw) - all to LibreOffice-class capability parity within tesseracore
**Out of scope:** Base as a separate database product surface, legacy `.ppt` write, and the reduced §6d list. (2026-08-14: nine former out-of-scope items - VBA/Basic macro compat, StarMath editor, forms, database connectivity, Draw 3D, Draw morph, GPU transitions, tagged PDF, mail-merge wizard - were promoted to P2 as 2.13-2.21; see §6c.1.)

> **Architect decisions (2026-08-13).** Bridge for DOCX import. Keep the
> `SheetWorkbook` name. `BlockType` case growth is fine. **Full** number-format
> parser in Swift (not the 80% subset). **Full** master-pages layout picker
> UI in P1. Chart engine on **CoreGraphics** long-term (not Swift Charts).
> Animations **evolve to SMIL tree** (not flat list). Pivot tables **Swift
> with full UNO parity** (not a simplified model). **Draw as a first-class
> peer surface** (not folded into SlideDeck); 2D vector full parity, 3D +
> morph explicitly punted. See §8 for the full decisions log.

---

## TL;DR

Tessera Studio already has a credible, agent-native document/spreadsheet/slides surface
(`Doc`, `SheetWorkbook`/`Sheet`, `SlideDeck`/`Slide`, a 16-case `BlockType` AST, a
recursive-formula `FormulaEngine`, an in-process `LibreOfficeBootstrap` + UNO bridge, and
a `DocumentExporter` for DOCX/PDF/ODT). The path to LibreOffice parity is to **evolve
the existing primitives**, not to fork a v2 surface or import LO as a dependency.

Three parallel explore agents inventoried the LO modules (`sw/`, `sc/`, `sd/`) against
the current tesseracore. The detailed reports are at:

- `docs/.scratch/lo-writer-report.md` - 19 capability rows
- `docs/.scratch/lo-calc-report.md` - 27 capability rows
- `docs/.scratch/lo-impress-report.md` - 27 capability rows

This plan summarizes the consolidated findings, names the reusable components, and
proposes a four-phase rollout. **Phase 0 (P0) was the MVP**: sixteen deliverables
(the "ten components" phrasing predates the Draw scope) that close the largest gaps
and unlock Word-class / Calc-class / Impress-class file round-trips. P0 landed on
main 2026-08-14; §2.1 maps each capability row to its landing commit, and the §6a
addendum records the one substitution (the LO bridge shipped as CLI conversion, not
in-process UNO).

The no-versioned-implementations rule is binding: every new component either
**evolves an existing type** (e.g. extend `BlockType`, `SheetWorkbook`, `SlideLayout`,
`FormulaEngine.Evaluator`) or **sits next to it as a peer** (e.g. `MasterPageStore`
next to `SlideStore`). Nothing is `_v2`-suffixed, nothing is left alongside its
predecessor in the same tree.

---

## 1. What tesseracore has today

The expansion evolves this surface. Recap of what already exists (paths relative to
`TesseraStudio/Sources/TesseraCore/`):

### 1a. Document model (shared by Doc, Sheet, Slide)

- `Productivity/Block.swift` - `BlockType` enum (16 cases: heading, paragraph, list,
  listItem, table, tableCell, image, codeBlock, callout, divider, quote, toggle,
  equation, comment, trackInsertion, trackDeletion), `InlineRun` with annotation tags,
  `DocumentPageLayout` (page geometry + columnCount + headerBlockID/footerBlockID).
- `Productivity/Block.swift` `DocumentAST` - the canonical body value type referenced
  by every material.

### 1b. Longform documents (Writer side)

- `Productivity/Materials/Docs/Doc.swift` - first-class `Doc` material (id, title,
  body, cover, tags).
- `Productivity/Materials/Docs/DocStore.swift` - receipt-backed mutation store.
- `Productivity/Materials/Docs/DocsViewModel.swift` - SwiftUI binding.
- `Editor/TesseraTextContentManager.swift`, `TesseraTextElement.swift` - TextKit 2
  binding to `DocumentAST`.
- `Editor/BlockRenderer.swift`, `EditorMode.swift`, `EditorCursorState.swift`,
  `EditorCoalescer.swift`, `TextEditReducer.swift` - editor surface.

### 1c. Spreadsheets (Calc side)

- `Productivity/Materials/Sheets/Sheet.swift`, `SheetWorkbook.swift`,
  `SheetColumn.swift` (with `SheetColumnType: text | number | date | checkbox`).
- `Productivity/Materials/Sheets/SheetStore.swift`, `SheetsViewModel.swift`,
  `SheetReceiptType.swift`, `SheetsGraphConnector.swift`.
- `FormulaEngine/` - `Lexer.swift`, `Parser.swift`, `Evaluator.swift`,
  `FormulaAST.swift`, `DependencyGraph.swift`, `TypeSystem.swift`,
  `UndoRedoStack.swift`, `SheetEngine.swift`, `FormulaReferenceAdjuster.swift`,
  `ColumnSlice.swift`, `CellAddr.swift`, plus `Functions/{Date,Statistics,Array,
  Lookup,Financial,Criteria}Functions.swift` + `FunctionRegistry.swift`.
- `Tools/SheetTools.swift` - agent tool surface for sheets.

### 1d. Slides (Impress side)

- `Productivity/Materials/Slides/SlideDeck.swift` (453 lines) - durable row; the deck
  carries a `body: DocumentAST` and a `slideMeta` map; each `Slide` is a derived
  view (`id, title, body, index, layout: SlideLayout, notes`).
- `Productivity/Materials/Slides/SlideLayout` - 4-case enum (`title`, `titleAndContent`,
  `image`, `blank`). Comment at `SlideDeck.swift:9` punts master layouts, transitions,
  animations.
- `Productivity/Materials/Slides/SlideStore.swift` (571 lines),
  `SlidesViewModel.swift` (618 lines), `SlideReceiptType.swift`,
  `SlidesGraphConnector.swift`.

### 1e. Drawings (Draw side)

**Scope decision (2026-08-13):** Draw is a separate tesseracore surface, NOT
a feature of `SlideDeck`. The two share the `sd/` binary in LO but the
user-facing semantics are distinct: a deck is a sequence of slides; a
drawing is a single page of vector graphics. The existing slide comments
that say "Draw is bundled inside the same `sd/` binary but lives mostly in
`sd/source/ui/func/fu*.cxx`" are correct about the upstream layout, but the
Tessera product split is one surface per material (a la the existing
Doc / Sheet / Slide split).

The existing tesseracore surface has:

- **No `Drawing` material yet.** This is a green-field add. New module
  `TesseraCore/Productivity/Materials/Draw/` containing `Drawing.swift`
  (durable `graph_entity` row, `id`, `title`, `body: DocumentAST`,
  `canvasSize: CanvasSize`, `canvasBackground: ShapeFill?`,
  `gridEnabled: Bool`), `DrawingStore.swift`, `DrawingsViewModel.swift`,
  `DrawingReceiptType.swift`, `DrawingsGraphConnector.swift`. All peers of
  the existing `*Store` / `*ViewModel` / `*ReceiptType` / `*GraphConnector`
  pattern in Doc / Sheet / SlideDeck.
- **No `Shape` value type yet.** New value type at
  `TesseraCore/Productivity/Shape.swift` peer of `Block.swift`. Carries
  `id`, `kind: ShapeKind` (rect, ellipse, line, arrow, polygon, star,
  freeform - the P0 set; P1 adds connector, P2 adds bezier/cad paths),
  `geometry: ShapeGeometry` (x, y, width, height, rotation, anchor),
  `fill: ShapeFill?`, `stroke: ShapeStroke?`, `text: ShapeText?`
  (optional text-on-shape), `zIndex: Int`, `parentGroupID: UUID?`
  (for P1 group support).
- **No shape rendering.** `BlockRenderer.swift` is text-focused; we add
  `ShapeRenderer.swift` peer of `BlockRenderer` (CoreGraphics; consistent
  with the architect decision on chart engine). `Drawing` body is
  `DocumentAST` of `BlockType.shape` cases (see §3 - the new `.shape` /
  `.shapeGroup` cases that the original plan already approved as P1
  `BlockType` evolutions now move to P0 because Draw needs them).
- **No shape catalog.** `ShapeCatalog` at
  `TesseraCore/Productivity/Materials/Draw/ShapeCatalog.swift` - the
  authoritative list of shape kinds + their default geometry. Shared
  by Draw (canvas) and Impress (free shapes on a slide).

### 1f. Import/Export + the LibreOffice bridge

- `Productivity/DocumentExporter.swift` - exports `DocumentAST` to DOCX (textutil),
  PDF (NSPrintOperation), ODT (textutil). Comments note native ODF writer is
  Phase 2 target.
- `Productivity/ImportExport/{TesseraImporter,TesseraExporter}.swift` - Python
  subprocess pipeline.
- `Productivity/ImportExport/SpreadsheetDigester.swift` - csv/tsv digest path only;
  `digest(fileAt:)` throws `.unsupportedFormat` for xlsx today ("XLSX goes through
  the import pipeline" - i.e. the Python bridge below, not this native path). No
  native XLS-binary or ODS reader exists in Swift anywhere in the tree.
- `DocumentProcessing/LibreOffice/LibreOfficeBootstrap.swift` (174 lines) - LO
  bundle discovery (`.app`/system install) and in-process UNO bootstrap.
- `DocumentProcessing/LibreOffice/EmbeddedPythonBridge.swift` (673 lines) -
  CPython lifecycle and URE bootstrap.
- `DocumentProcessing/LibreOffice/tessera_lo_service.py` (745 lines) - in-process
  UNO service. Further along than earlier drafts of this plan assumed: it
  already exposes `writer_get_text`, `writer_get_paragraphs`,
  `writer_set_paragraph_style`, `writer_insert_text`, the format-agnostic
  `open_document` / `save_document`, AND `calc_get_sheet_names`,
  `calc_read_cells`, `calc_write_cell`, `impress_get_slides`,
  `bridge_calc_get_cells`, `bridge_impress_get_slides` - all landed together
  in the same commit (5ef6b0961). The Writer/Calc/Impress bridge functions
  exist; `CalcBridgeFilter`/`LOBridgeDeckIO` (P0/P1 below) still need to be
  built on top of them, but the raw UNO calls are not the missing piece.

### 1g. Already-merged adjacent plans (read before writing the next evolution)

- `TesseraStudio/docs/word-class-document-processor-implementation-plan.md` - 772-
  line, 12-phase plan for the Writer side, locked in pre-LO-study.
- `TesseraStudio/docs/phase12-hig-review-sheets-slides-code.md` - HIG sweep of
  current sheets/slides views, 10 must-fix items (that doc's own prose summary
  line says 9; its own table two lines below says 10 and is the one that
  matches direct enumeration - the 9 was a miscount in that doc, not here).
- `TesseraStudio/docs/phase11-integration-plan.md` - 4-agent parallel execution
  plan; defines the `GhostTextProvider` / `DiffProvider` interface contracts the
  editor surface consumes.

The Writer plan above is the *de facto* design contract for the doc side; this
expansion plan is **complementary**, not contradictory. Where the writer plan
proposes an evolution (e.g. `DocumentMetadata.trackChangesEnabled = false`), this
plan does not relitigate it.

---

## 2. The consolidated capability matrix

Below is the unified view across Writer + Calc + Impress. The rows are a
**deduplicated rollup** of the three sibling reports; full per-source-path detail
is in the scratch reports.

| # | Capability | Surface | LO today | Tessera today | Phase |
|---|---|---|---|---|---|
| 1 | Block-level section / multi-column | Writer | covered | **gap** - no `BlockType.section`, no frame | P0 |
| 2 | Block-level field (page #, cross-ref, formula, user) | Writer | covered | **absent** - no `BlockType.field` | P1 |
| 3 | Block-level footnote / endnote | Writer | covered | **gap** - no `BlockType.footnote`/`.endnote`; `DocumentPageLayout.headerBlockID/footerBlockID` exist but are empty | P1 |
| 4 | Block-level shape (frame, anchored object) | Writer | covered | **gap** - only `BlockType.image`; no text frame, no group | P1 |
| 5 | Block-level shape (catalog) | Impress | covered | **gap** - no `ShapeCatalog`; only the 6 block primitives slide reuses | P1 |
| 6 | Block-level chart | Calc + Impress | covered | **gap** - no `BlockType.chart` | P1 |
| 7 | Block-level media (audio/video) | Impress | covered | **absent** - no `BlockType.media`; no `avmedia` wrapper | P1 |
| 8 | Table with rowspan/colspan, nested, repeating header | Writer + Calc | covered | **partial** - flat `<table><tr><td>`; spans dropped by `DocumentExporter.swift:235-242` | P0 |
| 9 | Style registry (paragraph/character/page/list/table) | Writer | covered | **gap** - `Block.attributes["style"]` is a string label, not a UUID | P1 |
| 10 | List level hierarchy + outline + bullet glyphs | Writer | covered | **partial** - 3 styles only, no level | P1 |
| 11 | Master page + per-slide layout picker | Impress | covered (25+ AutoLayouts) | **gap** - 4-case enum only | P0 |
| 12 | Slide transition | Impress | covered (30+ presets) | **absent** (punted) | P1 |
| 13 | Per-shape animation (entrance/emphasis/exit/motion) | Impress | covered (SMIL tree) | **absent** (punted) | P2 |
| 14 | Theme (palette, fonts, background) | Impress + Writer | covered | **absent** | P1 |
| 15 | Multi-sheet workbook model | Calc | covered | **partial** - `SheetWorkbook` is a single-sheet proxy | P0 |
| 16 | Cell types: numeric/string/boolean/date/formula/error + merged/shared/array | Calc | covered | **partial** - `SheetColumnType` is 4 cases; no merged/shared/array | P0 |
| 17 | Formula engine: TokenArray IR + shared formula groups | Calc | covered (RPN) | **gap** - AST-only; no shared-formula path; no TokenArray | P0 |
| 18 | Recalc state machine + dirty-cone scheduler | Calc | covered | **partial** - `DependencyGraph` has graph, no state enum | P0 |
| 19 | Name resolution in compiler, not evaluator | Calc | covered | **gap** - `engine.resolveNamedRange` is per-eval | P0 |
| 20 | Volatile + array volatility | Calc | covered | **partial** - scalar volatility only; no `FunctionVolatility.array` | P1 |
| 21 | Array / matrix formulas (CSE, dynamic arrays) | Calc | covered | **gap** - no `Spilled` semantics, no implicit intersection | P1 |
| 22 | Named ranges (workbook + sheet scoped) | Calc | covered | **partial** - workbook-scoped only, not persisted | P0 |
| 23 | Number formats (locale-aware) | Calc | covered (~60K LoC upstream) | **gap** - no per-cell `nFormat`; no `NumberFormatParser` | P0 |
| 24 | Cell styles, fonts, borders, alignment | Calc | covered | **gap** - block-AST run formatting, no per-cell | P1 |
| 25 | Charts (embedded + chart sheet) | Calc + Impress | covered | **gap** - no Swift chart primitive | P1 |
| 26 | Pivot tables / DataPilot | Calc | covered | **gap** - no pivot, no data pilot | P2 |
| 27 | Data validation | Calc | covered | **gap** - no per-range rule | P1 |
| 28 | Conditional formatting (rules + databars + color scales + icon sets) | Calc | covered | **gap** - no rule list, no databar | P1 |
| 29 | Solver (LP, nonlinear) | Calc | covered | **gap** - no native solver | P2 |
| 30 | Sort / filter (standard, advanced, autofilter) + subtotals | Calc | covered | **gap** - no sort, no filter, no `QueryParam` | P1 (P2 for subtotals) |
| 31 | Cell-level comments / threaded notes | Calc | covered | **gap** - no per-cell `Note` | P1 |
| 32 | Sheet protection | Calc | covered | **gap** - no `SheetProtection` | P1 |
| 33 | Statistics wizards (18 dialogs) | Calc | covered | **gap** - functions present, no wizard UI | P1 (agent-tool surface) |
| 34 | Find / replace (with regex) | Writer | covered | **gap** - no `DocumentSearchIndex` | P1 |
| 35 | Mail merge | Writer | covered | **absent** | P2 |
| 36 | ToC / index / bibliography | Writer | covered | **gap** | P2 |
| 37 | Track changes accept/reject | Writer | covered | **partial** - block types exist; no accept/reject lifecycle | P1 |
| 38 | ODT / DOCX / RTF / HTML / MD / EPUB / TXT reader | Writer | covered | **partial** - Python subprocess pipeline; UNO bridge has the right hooks but is not wired for full import | P0 |
| 39 | ODP / PPTX import + export | Impress | covered | **absent** - `DocumentExporter` has no deck formats | P1 |
| 40 | PDF export for slide deck (with master chrome, 16:9, notes) | Impress | covered | **gap** - `DocumentExporter` is `DocumentAST`-shaped only | P1 |
| 41 | Image export (PNG/JPG/SVG) | Impress | covered | **absent** | P1 |
| 42 | Auto-correct, spell-check, grammar | Writer | covered | **absent** - use macOS native spell APIs | P2 |
| 43 | Document session recovery + auto-save + version history | Writer | covered (Word-class) | **partial** - `DocStore.commitBody` exists, no recovery/versions | P1 (part of writer plan) |
| 44 | 2D vector shape catalog (rect, ellipse, line, arrow, polygon, star, freeform) | Draw + Impress | covered | **gap** - no `Shape` value type, no `BlockType.shape` case, no `ShapeCatalog` | P0 |
| 45 | Shape geometry + z-order + basic fill/stroke | Draw | covered | **gap** - no `ShapeGeometry`, no `ShapeFill`/`ShapeStroke` | P0 |
| 46 | Z-order control (bring forward, send back, to front, to back) | Draw | covered | **gap** - no z-order on the block primitive | P0 |
| 47 | Text on shape (text frame) | Draw + Impress | covered | **gap** - no text-on-shape; only `BlockType.image` for picture shapes | P1 |
| 48 | Group / ungroup of shapes | Draw | covered | **gap** - no `BlockType.shapeGroup`, no parent group on `Shape` | P1 |
| 49 | Connector shapes (straight, elbow, curved, with arrow heads) | Draw | covered | **gap** - connector is a separate `ShapeKind` not in P0 | P1 |
| 50 | Layers (add/delete/hide/lock/reorder) | Draw | covered | **gap** - no `Layer` value type, no `LayerStore` | P1 |
| 51 | Snap to grid + snap to object + alignment helpers | Draw | covered | **gap** - no `SnapEngine`; canvas is unsnapped | P1 |
| 52 | Transform / rotate / flip / scale | Draw | covered | **gap** - `ShapeGeometry` has `rotation` but no UI or undo for it | P1 |
| 53 | Custom geometry paths (bezier curves) | Draw | covered | **gap** - freeform paths are out of P0; needs a path-edit mode | P2 |
| 54 | Bullet/numbered lists inside text frames | Draw | covered | **gap** - shape text is a single `InlineRun` array | P2 |
| 55 | Draw tables (Draw-side table primitive) | Draw | covered | **gap** - reused `BlockType.table` works; needs the canvas binding | P2 |
| 56 | Annotations (reviewer notes) | Draw | covered | **gap** - distinct from `BlockType.comment`; LO uses `sd/source/core/annotations/Annotation.cxx` | P2 |
| 57 | Measure (dimension lines) | Draw | covered | **gap** - no measure shape | P2 |
| 58 | ODG import + export (Draw) | Draw | covered | **absent** - no native ODG reader/writer; bridge is the path | P1 |
| 59 | SVG import + export (Draw) | Draw | covered | **absent** - bridge is the path; native SVG is a P3 stretch | P1 |
| 60 | PNG/JPG export for drawing | Draw | covered | **absent** - `ShapeRenderer` + `UIGraphicsImageRenderer` is a pure-Swift path | P1 |
| 61 | PDF export for drawing | Draw | covered | **absent** - bridge is the path (LO `sdpdffilter` handles ODG-as-PDF) | P1 |
| 62 | 3D objects (extrusion, lathe, sphere, cube) | Draw | covered | **punt** - `fucon3d.cxx`; 3D on a productivity surface is unusual | out of scope (P3+ or never) |
| 63 | Morph (shape-to-shape interpolation) | Draw | covered | **punt** - `fumorph.cxx`; uncommon in the productivity use case | out of scope (P3+ or never) |

(63 rows. The phase column is the consolidated verdict; the three sibling reports
break the per-source path evidence per row. Rows 44-63 are the Draw scope added
2026-08-13: 17 new rows, 2 explicitly punted (3D + morph).)

### 2.1 Post-P0 status refresh (2026-08-14)

The matrix above is preserved as approved; this table layers the P0 outcome on
top of it. "Closed (data model)" means the value types + store + tests landed;
UI and format round-trip depth are tracked by the P1 items that consume them.

| Row(s) | Status after P0 | Landing commit |
|---|---|---|
| 1 (section/frame) | closed (data model) - `.section`/`.frame` cases | `f9c901bba` |
| 8 (table spans) | closed (data model) - rowSpans/colSpans/nested children | `a5ecb5f45` |
| 11 (master pages) | closed (data model) - `MasterPageStore` + `SlideLayoutSpec`; picker UI is P1 1.9 | `b87b83f93` |
| 15 (multi-sheet) | closed - `SheetWorkbook.sheets` + sheetOrder | `e0dc7326a` |
| 16 (cell types) | largely closed - `CellValue` landed; merged-cell semantics ride the P1 style work | `3b3075a27` |
| 17 (TokenArray IR) | closed | `e56431d3a` |
| 18 (recalc states) | closed - `RecalcState` + dirty-cone landed INSIDE `DependencyGraph`/`SheetEngine` (legal under "evolves DependencyGraph"; there is no `RecalcScheduler.swift` file - wave briefs must cite the real seam) | `9d00cf877` |
| 22 (named ranges) | closed (registry) | `ec3a5d246` |
| 23 (number formats) | partial - `NumberFormatEngine` landed grammar-full with documented gaps (fractions, elapsed time, fill/pad directives, locale-ID currency tags); see §6e gate 2 | `2140af305` |
| 26 (pivot) | definition type landed early (`SheetPivotDefinition`); `PivotTableStore` remains P2 2.2 | `517beb58c` |
| 27/28 (validation/CF) | registries landed at P0 (ahead of plan); P1 1.12/1.13 are evaluation + UI on top, not green-field | `50c0bc924`, `648341741` |
| 32 (protection) | closed at P0 (the row's P1 label was stale) | `ef2e02dcb` |
| 38 (Writer readers) | partial via SUBSTITUTED architecture - `LibreOfficeConverter` CLI + `WriterBridgeFilter` (ODT/RTF via DOCX); see §6a addendum | `ef605c4dc` |
| 44/45/46 (shapes/z-order) | closed (data model) - `Shape`, `ShapeCatalog`, `ShapeRenderer`, Draw quartet, z-order | `7234d1e92`, `5efccdf2a`, `731369cc0` |

Stale-row corrections found in the 2026-08-14 refinement pass:

- **Row 21 (array/dynamic arrays) is stale**: `SheetEngine` already implements
  spill semantics (`spillOrigin`/`SpillSize`, spilled cells refuse edits). The
  residual P1 work is implicit intersection / `@`, array volatility (row 20),
  and `#SPILL!` surfacing - scoped as P1 1.21 in §6b, sized by the calc SOTA
  report.
- **Row 30/33 contradiction resolved**: subtotals and statistics wizards are
  P2 (2.7, 2.8), matching the rollout; the matrix rows' P1 labels were stale.
- **Row 16 of §1f was corrected on 2026-08-13** (SpreadsheetDigester is
  csv/tsv-only); the Calc import path through the CLI converter flattens
  formulas on ODS/XLS import and carries a single sheet - the fidelity
  boundary is documented in `CalcBridgeFilter.swift` and its closure is part
  of the §6e bridge decision.

---

## 3. The unified tesseracore component catalog (priority-ordered)

Below are the **24 reusable components** that, together, close the bulk of the
matrix. Each is named with its concrete file path, its existing peer / parent
type, and a one-line test contract. The "evolve" vs "new peer" column is the
no-versioned-implementations check.

| Pri | Component | Path | Evolves / peer of | Phase |
|---|---|---|---|---|
| 1 | `SheetWorkbook` multi-sheet model | `TesseraCore/Productivity/Materials/Sheets/SheetWorkbook.swift` | **evolves** `SheetWorkbook` (adds `sheets: [SheetID: SheetSnapshot]`, workbook-wide named ranges, validation/CF registries, pivot list). Name stays per architect decision. | P0 |
| 2 | `RecalcScheduler` | `TesseraCore/FormulaEngine/RecalcScheduler.swift` | **evolves** `DependencyGraph` (adds cell-level `RecalcState`, dirty-cone plan, shared-formula group cache) | P0 |
| 3 | `TokenArray` IR | `TesseraCore/FormulaEngine/TokenArray.swift` | **peer of** `FormulaAST` (canonical IR for `DependencyGraph` + shared formula groups; AST stays the authoring surface) | P0 |
| 4 | `CellValue` + `CellFormat` + per-cell `NumberFormat` | `TesseraCore/Productivity/Materials/Sheets/{CellValue,CellFormat}.swift` | **evolves** `SheetColumn` / `SheetColumnType` (no v2 column type). **Update (session of 2026-08-13, after this row was written):** `SheetCellFormat.swift` already shipped, covering number format (general/number/comma/currency/percent/scientific/date/text), decimals, bold/italic, fill, borders, alignment - most of what "CellFormat" was scoped to do here. Do not build a second `CellFormat` type; either rename the plan's target to `SheetCellFormat` or evolve the shipped type in place. `CellValue` (a typed cell value, distinct from the format) and the full locale-aware `NumberFormatEngine` (row 5 below) are still unbuilt and still needed - `SheetCellFormat.numberFormat` is a categorical enum, not `svl/source/numbers/`-parity parsing. | P0 |
| 5 | `NumberFormatEngine` (full parser, locale-aware) | `TesseraCore/FormulaEngine/NumberFormatEngine.swift` | **peer of** `FunctionRegistry` (full parity with `svl/source/numbers/zforlist.cxx` + `zformat.cxx`; not the 80% subset. Owns its own per-locale token table) | P0 |
| 6 | `BlockType` evolutions: `.section`, `.frame`, `.field`, `.footnote`, `.endnote`, `.shape`, `.shapeGroup`, `.chart`, `.media` | `TesseraCore/Productivity/Block.swift` | **evolves** `BlockType` enum (adds cases; no v2 enum). `.shape` and `.shapeGroup` move to P0 because Draw needs them; the rest stay where the original plan put them. | P0 (section, frame, shape, shapeGroup) / P1 (field, footnote, endnote, chart, media) |
| 7 | `MasterPageStore` | `TesseraCore/Productivity/Materials/Slides/MasterPageStore.swift` | **peer of** `SlideStore`; lives next to it (not in v2) | P0 |
| 8 | `SlideLayoutSpec` (value type) | `TesseraCore/Productivity/Materials/Slides/SlideLayoutSpec.swift` | **evolves** `SlideLayout` enum (the 4 cases become defaults; the enum re-exports `caseIterable`) | P0 |
| 9 | `WriterBridgeFilter` (UNO-bridge-backed reader) | `TesseraCore/Productivity/Filters/WriterBridgeFilter.swift` | **peer of** `TesseraImporter` (subprocess path stays; UNO path is the architect-chosen DOCX import strategy) | P0 |
| 10 | `CalcBridgeFilter` (UNO-bridge-backed reader/writer) | `TesseraCore/Productivity/Filters/CalcBridgeFilter.swift` | **peer of** `SpreadsheetDigester` (CSV/TSV/XLSX digest stays; this is the UNO path for ODS/XLS) | P0 |
| 11 | `Shape` value type | `TesseraCore/Productivity/Shape.swift` | **peer of** `Block` (the 2D vector primitive; carries `id`, `kind: ShapeKind`, `geometry`, `fill`, `stroke`, `text?`, `zIndex`, `parentGroupID?`) | P0 |
| 12 | `ShapeCatalog` | `TesseraCore/Productivity/Materials/Draw/ShapeCatalog.swift` | **peer of** `SlideLayoutSpec`; the authoritative list of shape kinds + default geometry. Shared by Draw (canvas) and Impress (free shapes on a slide). | P0 |
| 13 | `ShapeRenderer` (CoreGraphics) | `TesseraCore/Productivity/Materials/Draw/ShapeRenderer.swift` | **peer of** `BlockRenderer`; renders a `Shape` to a `CGContext` or a `SwiftUI.Canvas` | P0 |
| 14 | `Drawing` material (full peer) | `TesseraCore/Productivity/Materials/Draw/Drawing.swift` | **peer of** `SlideDeck`; the durable `graph_entity` row for a single-page vector drawing | P0 |
| 15 | `DrawingStore` + `DrawingsViewModel` + `DrawingReceiptType` + `DrawingsGraphConnector` | `TesseraCore/Productivity/Materials/Draw/*` | **peer of** `SlideStore` + `SlidesViewModel` + `SlideReceiptType` + `SlidesGraphConnector`; same `*Store`/`*ViewModel`/`*ReceiptType`/`*GraphConnector` quartet | P0 |
| 16 | `MasterPageLayoutPicker` (full UI surface) | `TesseraCore/Productivity/Materials/Slides/MasterPageLayoutPicker.swift` | **peer of** the existing `SlideDetailView` slides surface; consumes `MasterPageStore`. **Full picker UI** per architect decision, not data-only. | P1 |
| 17 | `Theme` + `ThemeStore` | `TesseraCore/Productivity/Materials/Slides/Theme.swift` + `ThemeStore.swift` | **peer of** `SlideStore`/`DocStore` (no theme in v1) | P1 |
| 18 | `LOBridgeDeckIO` (ODP/PPTX import+export, PDF deck export) | `TesseraCore/DocumentProcessing/LibreOffice/LOBridgeDeckIO.swift` | **evolves** `EmbeddedPythonBridge` (adds two methods; no v2 bridge) | P1 |
| 19 | `SlideDeckRenderer` (Core Graphics) | `TesseraCore/Productivity/Materials/Slides/SlideDeckRenderer.swift` | **evolves** `BlockRenderer` (mode-aware: `EditorMode.document` vs `EditorMode.slideCanvas`) | P1 |
| 20 | `ChartRenderer` (Core Graphics, full LO chart type parity) | `TesseraCore/Views/Renderers/ChartRenderer.swift` | **peer of** the other `Views/Renderers/*` (no v2 renderer base). **Core Graphics** per architect decision, not Swift Charts. | P1 |
| 21 | `QueryEngine` (sort / filter / subtotals) | `TesseraCore/Productivity/Materials/Sheets/QueryEngine.swift` | **peer of** `SheetsViewModel` (subscribes to the same `DependencyGraph`) | P1 |
| 22 | `FieldController` + `RevisionController` | `TesseraCore/Productivity/Editor/{FieldController,RevisionController}.swift` | **evolves** `BlockType.field` and the existing `trackInsertion`/`trackDeletion` types (adds the accept/reject lifecycle, the per-revision ID) | P1 |
| 23 | `LayerStore` + `TransformController` + `SnapEngine` (Draw UI) | `TesseraCore/Productivity/Materials/Draw/{LayerStore,TransformController,SnapEngine}.swift` | **peers of** `DrawingStore` / `ShapeRenderer`; consume the landed `Shape` geometry + z-order | P1 |
| 24 | `ODGBridgeFilter` + `SVGBridgeFilter` + `PDFExportBridge` (Draw I/O) | `TesseraCore/Productivity/ImportExport/{ODGBridgeFilter,SVGBridgeFilter,PDFExportBridge}.swift` | **peers of** `WriterBridgeFilter` / `CalcBridgeFilter`; architecture is gated on the §6e bridge decision | P1 |

(Renumbered 2026-08-14: the original table reused priorities 12-16 across the
P0 and P1 blocks after the Draw splice, which made §7's "#13" citation
ambiguous, and omitted rows 23-24 entirely. 24 rows now match the "24
reusable components" claim; P0 = rows 1-15, P1 = rows 16-24.)

Plus, at P2, three substantial pieces of work whose design the architect
has already chosen:

- **`SMILAnimationTree`** — full evolution to the `XAnimationNode` tree from
  `sd/source/core/CustomAnimationEffect.cxx` (3,461 LoC). NOT a flat
  `[AnimationEffect]` list. Includes `ParallelTimeContainer`,
  `SequenceTimeContainer`, `Animate`, `AnimateMotion`, `AnimateColor`,
  `AnimateTransform`, `Audio`, `Command`, `IterateContainer`, `Event`.
  Lives at `TesseraCore/Productivity/Materials/Slides/SMILAnimationTree.swift`,
  peer of `SlideStore`. Phase 2.
- **`PivotTableStore`** with **full UNO parity** to `ScDPObject` — NOT the
  simplified row/col/data/filter model. Includes the
  `DataPilotFieldOrientation` matrix, page/row/column/data/filter bins,
  `PivotTableStyleInfo`, layout properties, output properties, save/load
  (`dpsave.hxx` / `dpdimsave.hxx`). Lives at
  `TesseraCore/Productivity/Materials/Sheets/PivotTableStore.swift`. Phase 2.
- **`BezierPathController`** - the Draw custom-geometry piece (the bezier
  curve edit mode; the P0 freeform becomes a full vector path tool). Lives
  at `TesseraCore/Productivity/Materials/Draw/BezierPathController.swift`,
  peer of `ShapeRenderer`. Phase 2. (Added to this list 2026-08-14; §6c row
  2.3 always carried it - the "three pieces" sentence below previously
  listed only two.)

24 components at P0+P1, three substantial design-locked pieces at P2. The
"evolve" column is the binding constraint: every new component either adds
cases/fields to an existing type, or sits as a peer file next to its sibling.
Nothing paralleled; nothing v2.

---

## 4. Bridge strategy: when to call UNO, when to re-implement

The `LibreOfficeBootstrap` + `EmbeddedPythonBridge` + `tessera_lo_service.py`
stack is a working UNO gateway. The right division of labor is:

> **2026-08-14:** "the bridge" in this section now means the Gate-1
> architecture (CLI `LibreOfficeConverter` + FlatODF readers/writers, with
> a scoped URP client as the only live-UNO fallback) - NOT in-process UNO,
> which died at P0 (§6a addendum). The division-of-labor logic below
> stands; the transport changed. See §6e gate 1.

### 4a. Call UNO (drive the bridge) for:

| Capability | Why |
|---|---|
| ODT / DOCX / RTF / HTML / MD / EPUB / TXT **reader** (Writer) | LO has 30+ years of edge-case handling; the bridge can walk `XText` and emit `DocumentAST` directly. Re-implementing is 20K+ LoC for marginal gain. |
| ODS / XLS / XLSX / CSV / dBASE / DIF **reader + writer** (Calc) | Same logic. The 50+ years of filter edge cases in `sc/source/filter/{excel,oox,xml}/` are not worth duplicating in Swift. |
| ODP / PPTX import (Impress) | UNO `XDrawPagesSupplier` -> `SlideDeck` is mechanical. PPTX fidelity is deep; we trust `oox/source/ppt/pptimport.cxx`. |
| ODG / SVG import + export (Draw) | Same logic. `xmloff/source/drawing/` + `oox/source/export/shapes.cxx` + `filter/source/svg/` are deep enough that bridge is the right call. Pure-Swift SVG is a P3 stretch. |
| PDF export for a slide deck or drawing | `sd/source/filter/pdf/sdpdffilter.cxx` includes 16:9, master chrome, notes/handout for Impress; the ODG path handles Draw. Native Core Graphics + PDFContext is 6+ months of parity work. |
| Presenter console (dual display, presenter notes, timer) | `sd/source/console/` is 70 files. Re-implementing is a separate product. The bridge spawns `soffice --show`; SwiftUI just hosts. |
| Solver (LP, nonlinear) | UNO `com.sun.star.sheet.Solver` is the right call. The native port (`scaddins/source/solver/`) is 1000+ lines and ports would diverge. |
| Layout-sensitive features: ToC, page-number fields, cross-references, index | LO computes them. We serialize the resolved text. |

### 4b. Re-implement in Swift (don't use the bridge) for:

| Capability | Why |
|---|---|
| Formula engine, dependency graph, recalc, named-range resolution, function registry | These are the load-bearing primitives for the agent tool surface (`SheetTools.swift`), the receipts pipeline, and the undo stack. UNO per-edit would be too slow and would not compose with `ReceiptsCoordinator`. |
| Block / cell rendering (Writer, Calc, Impress views) | The SwiftUI surface is the product. UNO's view layer is irrelevant. |
| Document / cell / slide edit operations (insert, delete, mutate) | Mutations are constitutional; the receipt backbone is non-negotiable. |
| Spell-check, autocorrect, grammar | macOS-native `NSSpellChecker` + Apple Intelligence over LO's; smaller, faster, local. |
| Chart rendering (Core Graphics, full LO chart type parity) | Architect decision: CoreGraphics, not Swift Charts. LO chart objects don't render into `SwiftUI.View`; the full chart type set is part of parity. `ChartRenderer` consumes a `ChartSpec` JSON and draws with `CGContext`. |
| Number formats (full parser, locale-aware) | Architect decision: full parser in Swift, peer of the upstream `svl/source/numbers/` (60K LoC). Token table per locale, full `nf_*` code coverage, not the 80% subset. Rides `NumberFormatEngine` peer of `FunctionRegistry`. |
| Cell styles, data validation, conditional formatting, sort / filter, sheet protection, cell comments | Receipt + SwiftUI surface; the bridge round-trip is too slow for live editing. |
| Animations (full SMIL tree evolution) | Architect decision: evolve to the `XAnimationNode` tree from `CustomAnimationEffect.cxx` (3,461 LoC) at P2, NOT a flat `[AnimationEffect]` list. P2 ships `ParallelTimeContainer`, `SequenceTimeContainer`, `Animate`, `AnimateMotion`, `AnimateColor`, `AnimateTransform`, `Audio`, `Command`, `IterateContainer`, `Event`. Runtime playback is still SwiftUI tween; the tree is the authoring + round-trip surface. |
| Pivot tables (Swift, full UNO parity) | Architect decision: Swift `PivotTableStore` with full `ScDPObject` schema parity, not the simplified row/col/data/filter model. Includes `DataPilotFieldOrientation`, page/row/column/data/filter bins, `PivotTableStyleInfo`, layout + output properties, save/load via `dpsave.hxx` / `dpdimsave.hxx`. Reuses `QueryEngine` infrastructure. |
| Auto-save / session recovery / version history | This is a *product* feature, not a *format* feature. Drive it from `DocStore`/`SheetStore`/`SlideStore`/`DrawingStore` and the receipt log. |
| Image export (PNG/JPG/SVG) for **Slides** | `UIGraphicsImageRenderer` over a `Slide` AST is a pure-Swift path. No UNO needed. |
| Image export (PNG/JPG) for **Drawings** | `UIGraphicsImageRenderer` over a `Drawing` AST rendered by `ShapeRenderer` is a pure-Swift path. |
| Shape catalog, geometry, fill/stroke, z-order, layers, snap, transform, group | Receipt + SwiftUI surface; the bridge round-trip is too slow for live editing. `ShapeRenderer` + `ShapeCatalog` + `LayerStore` + `TransformController` + `SnapEngine` are all Swift. |
| Text frames + bullet lists inside shapes | Swift. `Shape.text: ShapeText` carries the `InlineRun` array; bullet rendering is a SwiftUI tween. |

### 4c. The 3-foot-rule for new components

Before adding any new tesseracore component, ask:

1. Is there an existing primitive I can extend instead of adding a peer? (Per
   the no-versioned-implementations rule.) Examples: `BlockType` cases,
   `SheetColumnType` cases, `SlideLayout` cases, `DocumentPageLayout` fields.
2. If a peer is the right answer, does the peer follow the same `*Store` +
   `*ViewModel` + `*ReceiptType` pattern as `DocStore`/`SheetStore`/`SlideStore`?
3. Does the component ride the receipt backbone? If not, why not?

---

## 5. Cross-cutting themes

These bind all three suites together; they are not per-capability.

### 5a. Receipts are universal

Every mutation - insertion, deletion, accept/reject, recalc, sort, filter,
apply-layout, set-transition - must go through `ReceiptsCoordinator`. The
explore reports on Writer (`RevisionController.swift` design) and Calc
(`ChangeTracker.swift` design) and Impress (`MasterPageStore.swift` design)
all converge on this. There is no parallel mutation log; the receipt log IS
the mutation log, the audit log, and the change-track viewer.

### 5b. The AST is the source of truth

`DocumentAST` is the authoring surface for every material (Doc, Sheet, SlideDeck,
future MasterPage). Block / cell / slide / master diffs are all `DocumentAST`
diffs. The exporter (`DocumentExporter.swift`) is a projection; the bridge
(`LibreOfficeBootstrap` + `tessera_lo_service.py`) is another projection; the
chart renderer, the slide renderer, the printer, the email-export - all
projections of the same `DocumentAST`. The temptation to add a parallel
internal model for "the rendered page" is the standard way these products
balloon; we reject it.

### 5c. Per-suite data, one document model

The four materials look different in the UI, but the `body: DocumentAST` is
identical. `MasterPage.body` will be the same `DocumentAST` (a new
`masterOnly: true` flag on root children handles chrome vs slide-content
distinction in the canvas). `SheetWorkbook.sheets[i].body` is the same
`DocumentAST` with a `BlockType.table` root. The cell grid for sheets is
also a `DocumentAST` of `BlockType.tableCell`s. `Drawing.body` is the same
`DocumentAST` interpreted as a list of `BlockType.shape` /
`BlockType.shapeGroup` cases (the `Shape` value type is the per-block
carrier; the AST is the document-shaped body). This is the right shape: one
copy / paste engine, one undo stack, one find/replace, one receipt vocabulary.

### 5d. AGENTS.md is the conductor

The four named capabilities (`alphaevolve`, `tessera-analyst`, `findings-
curator`, `verifier`) do not change with this expansion. The phase 0 / 1 / 2
work rolls in under `tessera-analyst` for design study, `worker` for
implementation, and `verifier` for the review gate before each promotion to
main. The branch namespaces (`scratch/<feature>/agent-X`, `evolve-review/...`,
`champions/<id>`, `evolve-baseline/wN`) carry through unchanged.

**Process record (2026-08-14):** P0 did NOT follow this section. It executed
as ~28 sequential worker commits directly on `main` (via the
`tessera-docwork` worktree) - no wave branches, no `evolve-review`, no
`verifier` gate, no alphaevolve run registration. The execution quality was
good (candid scope notes, empirical blocker verification, 27 new test
files), but the divergence was silent. P1 is UI-heavy and bridge-risky -
exactly where the wave + verifier + post-claim-audit machinery earns its
cost - so P1 restores this protocol as written unless the architect
explicitly amends it. A P1 wave that ships without the verifier gate and
both §11 audit passes is unverified by this plan's own definition.

**Architect amendment (2026-08-14, for the P1 implementation run):** the
architect authorized an aggressive implementation pass on a scratch branch
with MILESTONE COMMITS and MINIMAL verification (build + targeted tests
per milestone; machine-strain constraints on the 16GB host), explicitly
DEFERRING the verifier gate + both §11 audit passes to a review pass that
runs BEFORE any merge of that branch to main. The gate is deferred, not
waived; the branch does not merge without it.

### 5e. The agent-ux-fatigue rules still apply

The Phase-1 audit shipped 12 units (tier policy, notification budget,
citation/uncertainty, inline stop, audit log side panel, etc.). This expansion
must respect:

- **Tier policy** - import/export that mutates a user's file is at least `tier2`;
  layout-sensitive features (column changes, theme swaps) are `tier1` per the
  risk-only policy.
- **Notification budget** - the cross-suite auto-save notification rides
  `TesseraNotificationBudget`. No "format converted" push.
- **Inline stop** - long imports (`loadComponentFromURL` for a 500-page DOCX)
  must wire to `TesseraAgentLoop.stop(reason:)`.
- **Audit log** - all `WriterBridgeFilter.import(URL)` and
  `CalcBridgeFilter.import(URL)` calls log a receipt; the side panel surfaces
  them.

---

## 6. The phased rollout

The 63 capability rows roll up into a four-phase plan. Each phase is a
**shippable milestone**, not a "we'll get to it eventually" tickbox.

### 6a. Phase 0 - MVP (the 16 things that close the largest gaps)

| # | Deliverable | Surface |
|---|---|---|
| 0.1 | `SheetWorkbook` multi-sheet model (multi-sheet identity, workbook-wide named ranges, validation + CF registries, pivot list, protection) | Calc |
| 0.2 | `RecalcScheduler` + `TokenArray` IR + shared formula groups (cell-level `RecalcState`, dirty-cone plan) | Calc |
| 0.3 | `CellValue` + `CellFormat` + per-cell `NumberFormat` index (extends `SheetColumn`; no v2) - see §3 row 4's note: `SheetCellFormat.swift` already shipped, reconcile before building a second type | Calc |
| 0.4 | `NumberFormatEngine` (full locale-aware parser, parity with `svl/source/numbers/`) | Calc |
| 0.5 | `BlockType.section` + `BlockType.frame` (the 2 new cases that unblock real-world DOCX import) | Writer |
| 0.6 | `BlockType.table` extension: `rowSpans`, `colSpans`, nested `children` | Writer + Calc |
| 0.7 | `MasterPageStore` + `SlideLayoutSpec` (the 4-case `SlideLayout` becomes defaults; no v2 enum) | Impress |
| 0.8 | `WriterBridgeFilter` (UNO bridge for ODT/DOCX/RTF/HTML import - architect-chosen strategy) | Writer |
| 0.9 | `CalcBridgeFilter` (UNO bridge for ODS/XLS/XLSX import + export) | Calc |
| 0.10 | `SheetProtection` + sheet-level protection flags | Calc |
| 0.11 | Update the `tessera_lo_service.py` schema with the Writer / Calc filter functions the bridge needs | Bridge |
| 0.12 | `BlockType.shape` + `BlockType.shapeGroup` (Draw needs them at P0; Impress uses at P1 for free shapes) | Draw + Impress |
| 0.13 | `Shape` value type + `ShapeCatalog` (rect, ellipse, line, arrow, polygon, star, freeform - P0 set) | Draw + Impress |
| 0.14 | `ShapeRenderer` (CoreGraphics; renders `Shape` to a `CGContext` or a `SwiftUI.Canvas`) | Draw + Impress |
| 0.15 | `Drawing` material + `DrawingStore` + `DrawingsViewModel` + `DrawingReceiptType` + `DrawingsGraphConnector` (full peer of Slide quartet; data model only, no full UI yet) | Draw |
| 0.16 | Z-order control on `Shape` (bring forward, send back, to front, to back - sort on `zIndex`) | Draw |

P0 = the MVP that lets a user open a Word document and a Calc workbook and
not lose the table, the columns, the styles, the formulas, the multi-sheet
structure, the number formats, or the page layout; plus the **Draw data
model** (canvas + basic shapes + z-order) ready for the P1 UI wave. **No
slides MVP at P0** because Impress is inherently a richer surface; the
slides MVP is at P1.

**Known blocker - 0.8/0.9/0.11 (the LO UNO bridge), confirmed 2026-08-14:**
`EmbeddedPythonBridge`'s in-process embedding is not currently viable, on top
of the "architecturally suspect... zero callers, zero tests" flag this plan
already carried. Two independent, empirically-verified problems, not a
static-reasoning guess:

1. **Python version mismatch, confirmed by reading the two hard-coded
   sources of truth.** `Package.swift`'s `CPythonBridge` target links
   Homebrew's `Python.framework` at a version pinned by `let pythonVersion =
   "3.14"` (confirmed present: `/opt/homebrew/opt/python@3.14` -> Python
   3.14.6). `LibreOfficeBootstrap.pythonHome(for:)` points
   `PYTHONHOME`/`PYTHONPATH` at LibreOffice's own bundled interpreter, which
   is a *different, separately-built* Python: `LibreOfficePython.framework/
   Versions/3.12` (confirmed present on this machine, version 3.12). The
   interpreter actually mapped into the process is fixed at link time by
   `.linkedFramework("Python")` (3.14) - setting `PYTHONHOME` at runtime to a
   3.12 tree does not change which `libpython` is running. `pyuno.so` (the
   UNO bridge extension LO ships, found at `Contents/Frameworks/pyuno.so`)
   was built against CPython 3.12's C API, which is not ABI-stable across
   minor versions. Loading a 3.12-targeted extension into a 3.14 interpreter
   is undefined behavior (crash or memory corruption), not a clean import
   error - too risky to attempt in-process without first re-pinning
   `CPythonBridge` to 3.12.
2. **Even bypassing the version question and invoking LibreOffice's own
   matching `python3.12` binary directly and in isolation (a safe subprocess
   probe, no shared process state) hangs indefinitely** - `timeout 20 ...
   python3.12 -c "print(...)"` never produces output, killed only by the
   timeout, reproduced 3x (bare env, `-S`, with the bridge's real env vars).
   `xattr -l` on that binary shows `com.apple.quarantine` set, and `spctl -a
   -v` rejects it ("the code is valid but does not seem to be an app").
   Gatekeeper's assessment of a quarantined, non-app Mach-O binary invoked
   directly (not via LaunchServices) appears to hang rather than fail fast
   in this non-interactive environment. Clearing quarantine on an installed
   application's internals is a system/security-setting change outside this
   project's scope to make unilaterally, so this was not attempted.

Recommendation: this is exactly the risk the original readiness check
flagged - do not build `CalcBridgeFilter`/`WriterBridgeFilter`/the
`tessera_lo_service.py` schema update (0.8/0.9/0.11) on top of
`EmbeddedPythonBridge` as-is. The two fixes are independent: re-pinning
`CPythonBridge` to Python 3.12 addresses point 1 but not point 2,
which needs a human to clear the quarantine flag (or a signed/notarized
LibreOffice install) before any in-process embedding can even start up.
Until then, `LOEnvironment.Mode.processPool` (soffice subprocess + UNO
socket, LO's own documented approach, already stubbed as an enum case) is
the lower-risk path and matches what the earlier readiness assessment
suspected should have been used from the start. 0.8/0.9/0.11 stay **blocked,
not implemented**, pending that architecture decision.

**Resolved 2026-08-14, same day, different shape than recommended above.**
The user reinstalled LibreOffice cleanly (`brew reinstall --cask
libreoffice`), which fixed the OUTER `.app` bundle's code signature
(`spctl -a -v` now reports `accepted, source=Notarized Developer ID`,
previously "a sealed resource is missing or invalid"). Point 2 above was
re-verified AFTER that reinstall, not assumed fixed by association: LO's
bundled `python3.12` binary specifically still hangs (`timeout 10 ...
python3.12 --version` still had to be SIGKILLed) - the app-level reinstall
did not touch whatever is wrong with that inner binary's quarantine state.
Point 1 (the 3.14-vs-3.12 ABI mismatch) is architecturally independent of
either fix and still stands on its own.

Rather than build the recommended `processPool` (soffice `--accept` + UNO
socket + hand-rolled URP client) architecture, the actual implementation
uses `soffice --headless --convert-to <format> --outdir <dir> <file>` -
LibreOffice's own well-supported, synchronous, one-shot CLI conversion mode
(`LibreOfficeConverter.swift`, `Sources/TesseraCore/Productivity/
ImportExport/`). This sidesteps BOTH blocking problems at once: it never
touches `python3.12` (only the main `soffice` executable, which now passes
Gatekeeper), and it never links `pyuno.so` into any Tessera process at all,
so the 3.14/3.12 ABI question doesn't arise. `-env:UserInstallation=` gives
every call an isolated profile dir, avoiding the well-known "second headless
soffice hangs waiting for the first one's profile lock" failure mode
(verified empirically: two concurrent conversions with distinct profile
dirs both completed cleanly).

`WriterBridgeFilter.swift` covers the two Writer formats `TesseraFormatBridge`
has no reader for (ODT, RTF) by converting them to DOCX first, then handing
the result to `TesseraFormatBridge`'s existing python-docx path.
`CalcBridgeFilter.swift` covers ODS and legacy XLS (import AND export, per
0.9) by round-tripping through CSV, reusing `SpreadsheetDigester`'s existing
live-formula-aware CSV pipeline instead of writing a second spreadsheet
parser - see that file's doc comment for the resulting fidelity boundary
(formulas survive Tessera -> ODS/XLS; ODS/XLS -> Tessera flattens any
formula already in the source file to its last-computed value, since LO's
CSV export only ever writes computed values).

**0.11 was deliberately NOT done as originally scoped.** Updating
`tessera_lo_service.py`'s schema only makes sense if something calls into
it, and nothing does anymore - that file's entire premise (in-process UNO
via the embedded Python interpreter) is the path this resolution avoids for
the two confirmed reasons above. It is left untouched rather than partially
updated to describe a schema its own bootstrap path can't safely serve.

### 6b. Phase 1 - the second wave (23 deliverables; 19 original + 4 added by the 2026-08-14 refinement)

Design contracts for every row live in
`studio-expansion-design-refinement-2026-08-14.md` (§4); wave briefs cite
that doc, not just this table.

| # | Deliverable | Surface |
|---|---|---|
| 1.0 | Round-trip fixture corpus harness (added 2026-08-14; see §6f) - lands BEFORE any parity claim; the primary-metric source for every P1/P2 item | All |
| 1.1 | `BlockType.field` + `FieldController` (page #, cross-ref, formula, user, date) | Writer |
| 1.2 | `BlockType.footnote` / `.endnote` (with `DocumentPageLayout` header/footer body) | Writer |
| 1.3 | `BlockType.chart` + `ChartRenderer` (CoreGraphics, full LO chart type parity - not Swift Charts). Staged per §6e gate 3: series-typed `ChartSpec`; P1a = column/bar/line/area/pie/scatter, P1b = bubble/net/stock/column-and-line/of-pie; pivot/box/sparkline reconcile as data-source/technique/preset of the same renderer | Calc + Impress |
| 1.4 | `BlockType.media` + `MediaBlock` (audio/video via AVFoundation) | Impress |
| 1.5 | `Theme` + `ThemeStore` | Impress + Writer |
| 1.6 | `TransitionSpec` + `TransitionStore` (LO has 30+ presets; ship a JSON catalog) | Impress |
| 1.7 | `SlideDeckRenderer` (Core Graphics) + `DeckExportCoordinator` (PNG/JPG export) | Impress |
| 1.8 | `LOBridgeDeckIO` (ODP/PPTX import + export, PDF deck export). Architecture per §6e gate 1: CLI converter + `FlatODFReader/Writer` over fodp (verified: masters, placeholders, notes, transitions all round-trip); speaker-notes PDF supported, handout-layout PDF impossible in any architecture (recorded out of scope) | Impress |
| 1.9 | `MasterPageLayoutPicker` (full UI surface, architect-chosen) | Impress |
| 1.10 | `QueryEngine` (sort, filter, autofilter) | Calc |
| 1.11 | Per-cell style completion. NAMING CORRECTION (2026-08-14): the shipped type is `SheetCellFormat` and it already applies per-cell via block attributes - do NOT introduce a `CellStyle` type. Scope = wire `NumberFormatEngine` into `SheetValueRenderer` (it has zero consumers today), evolve `SheetNumberFormat` cases into format-code presets, complete borders/alignment, and the dxf subset 1.12 needs | Calc |
| 1.12 | `ConditionalFormat` registry (rules, databars, color scales, icon sets) | Calc |
| 1.13 | `DataValidation` (per-range rule) | Calc |
| 1.14 | `RevisionController` (accept/reject lifecycle for track-changes; rides receipts) | Writer |
| 1.15 | `LayerStore` (add/delete/hide/lock/reorder layers; per-Drawing; rides receipts) | Draw |
| 1.16 | `TransformController` (rotate/flip/scale handles; geometry mutation with undo) | Draw |
| 1.17 | `SnapEngine` (snap to grid + snap to object + alignment helpers) | Draw |
| 1.18 | `ODGBridgeFilter` + `SVGBridgeFilter` + `PDFExportBridge` (Draw format I/O - "via UNO" superseded by §6e gate 1: CLI converter + fodg, verified carrying layers/connectors/glue points/beziers/custom shapes); PNG/JPG export is **native** (`UIGraphicsImageRenderer` over `ShapeRenderer`). SVG IMPORT ships as embedded-image fidelity at P1 (verified CLI limitation), marked as such in the AST; shape-level SVG import = P3 native parser or a future URP `.uno:Break`, decided at scoping | Draw |
| 1.19 | Text frames on shapes (`Shape.text: ShapeText?` lives at P0; P1 adds the canvas editing UX and the connector `ShapeKind` with computed glue points + elbow routing; group/ungroup UX from row 48 rides this cluster; bullet lists inside shape text stay P2 per 2.12) | Draw + Impress |
| 1.20 | `AnimationEffectList` flat interim (numbered 2026-08-14; was prose-only in §6b.1) + the REQUIRED pinned serialization-contract fixture proving the list is a pre-order flattening of the future SMIL tree | Impress |
| 1.21 | Dynamic-array completion (added 2026-08-14): implicit intersection `@` + legacy-import prefixing, `#SPILL!` surfacing, volatile-resize protection, register OFFSET/INDIRECT as volatile. Spill itself already landed (matrix row 21 was stale). `FunctionVolatility.array` (row 20) is DROPPED - the axis exists in no surveyed engine; per-formula recalc bits (LO `ScRecalcMode` ONLOAD axes) are the adopted model | Calc |
| 1.22 | Cell + slide comment anchors (added 2026-08-14; rows 31): polymorphic `CommentAnchor` on the shared `Comments.swift` model (no per-surface fork); threaded-comments shape; legacy-placeholder dual parts are an export shim only | Calc + Impress |

P1 = the full P0 + the second-tier features that make the MVP feel like a
real product. **Phase 1 is the milestone that hits Word-class / Calc-class /
Impress-class / Draw-class parity at the consumer-Word / consumer-Excel /
consumer-PowerPoint / consumer-Visio level**. Note that `PivotTableStore`,
`SMILAnimationTree`, and `BezierPathController` are NOT in P1; they are P2
(see §6c) because their architect-locked designs need their own dedicated
waves.

### 6b.1 Phase 1 animation milestone - the flat-list interim

The architect's call is to evolve to the SMIL tree at P2. To not block
P1 deck delivery, P1 ships a **flat `[AnimationEffect]` list as a P1
interim** that the SMIL tree at P2 *evolves* (per the no-versioned-
implementations rule: the flat list becomes a serializable flat
projection of the tree; existing P1 animations still load at P2, the
tree is the authoritative source). The flat list is `TesseraCore/
Productivity/Materials/Slides/AnimationEffectList.swift`; P2
introduces `SMILAnimationTree.swift` and the list moves to be a
serialization of the tree.

(2026-08-14: this milestone is now numbered deliverable 1.20, with the
pinned-fixture serialization-contract test spelled out in the refinement
doc §4 - the fixture is committed at P1 and never edited at P2; load-compat
IS the contract.)

### 6c. Phase 2 core - the advanced features (12 deliverables)

| # | Deliverable | Surface |
|---|---|---|
| 2.1 | `SMILAnimationTree` - **full evolution** to the `XAnimationNode` tree from `CustomAnimationEffect.cxx`. Includes `ParallelTimeContainer`, `SequenceTimeContainer`, `Animate`, `AnimateMotion`, `AnimateColor`, `AnimateTransform`, `Audio`, `Command`, `IterateContainer`, `Event`. Replaces the P1 flat `AnimationEffectList` (which becomes a serialization of the tree). | Impress |
| 2.2 | `PivotTableStore` - **full UNO parity** to `ScDPObject`. Includes `DataPilotFieldOrientation` matrix, page/row/column/data/filter bins, `PivotTableStyleInfo`, layout + output properties, save/load via `dpsave.hxx` / `dpdimsave.hxx`. Reuses `QueryEngine` infrastructure. | Calc |
| 2.3 | `BezierPathController` - the P2 piece for Draw that lands **full custom-geometry paths** (the bezier curve edit mode, the P0 freeform becomes a full vector path tool). Lives at `TesseraCore/Productivity/Materials/Draw/BezierPathController.swift`, peer of `ShapeRenderer`. | Draw |
| 2.4 | Mail merge (`MailMergeCoordinator`, driven by `Doc.linkedEntityIDs`) | Writer |
| 2.5 | ToC / index / bibliography (`BlockType.toc`) | Writer |
| 2.6 | Solver (UNO call; thin Swift wrapper) | Calc |
| 2.7 | Subtotals (extend `QueryEngine` with `SubtotalDescriptor`) | Calc |
| 2.8 | Statistics wizards (18 agent-tool wrappers) | Calc |
| 2.9 | Track-changes reviewer UI (reads existing receipts; no parallel log) | Calc + Writer |
| 2.10 | Custom shows (data only, no UI) | Impress |
| 2.11 | Master documents (uses `Doc.linkedEntityIDs` + a new `MasterDoc` material) | Writer |
| 2.12 | Draw advanced (annotations, measure/dimension lines, Draw-side tables, bullet lists inside shape text) | Draw |

P2 core = the long tail of the parity plan. Features a power user expects
and that round-trip real-world files, but that are not day-one must-haves.
2.1, 2.2, and 2.3 are architect-locked substantial pieces (3-5K LoC each,
per the upstream references in the sibling reports); the rest are smaller.
2.6 (solver) is additionally gated on the §6e bridge decision - it was
specced as a UNO call.

### 6c.1 Phase 2 enterprise track (9 deliverables, design-gated)

The nine items below were promoted from §6d's out-of-scope table on
2026-08-14 (decision 11, commit `9623b4017`) for corporate-adoption
reasons. They are a different KIND of work than 6c: each was originally
excluded for an architectural reason that still applies, so each carries
its promoted-with note. **Split rule (2026-08-14 refinement): an
enterprise-track item cannot enter a wave brief until its design position
in `studio-expansion-design-refinement-2026-08-14.md` is
architect-ratified.** 2.13, 2.15, and 2.16 carry genuinely open design
questions (2.16 additionally conflicts with the no-egress doctrine as
written); the others have recommended positions ready to ratify.
**(Gate discharged 2026-08-14: all nine design positions were ratified as
§8 row 16, with the open-question defaults recorded there.)**

| # | Deliverable | Surface |
|---|---|---|
| 2.13 | `MacroCompatLayer` (VBA/Basic macro read + limited execution) - promoted from out-of-scope 2026-08-14 for corporate-adoption reasons; the original objection stands as a real constraint, not just a priority call: `basic/source/comp/*` is a separate language and runtime, embedding it balloons the binary. Needs its own design pass before implementation - most likely a read-and-flag-for-agent-tool-rewrite path rather than a real VBA interpreter, not a small addition. | Writer + Calc + Impress |
| 2.14 | `StarMathEditor` (equation authoring/editing UI over a real equation engine) - promoted from out-of-scope 2026-08-14. `starmath/` is its own sibling module with a custom TeX-like engine; `BlockType.equation`'s `latex` string already covers read/round-trip (shipped), this adds the authoring UI + engine on top. | Writer |
| 2.15 | Form controls (new material or `BlockType` addition - design TBD) - promoted from out-of-scope 2026-08-14. Ties into the XForms / UNO control hierarchy; Tessera materials are document-shaped today, not form-shaped, so this is the "Tessera Forms" track the original plan deferred, now pulled into P2 scope rather than left as a someday idea. | Writer + Calc |
| 2.16 | Database connectivity (`DatabaseConnector` - design TBD) - promoted from out-of-scope 2026-08-14. `connectivity/` + SDBC + ODBC + JDBC; the original objection ("the no-egress doctrine says no SDBC") is a policy conflict, not a complexity one - this needs an explicit decision on how egress/credentials/audit are handled before implementation starts, not just a Swift wrapper around SDBC. | Calc |
| 2.17 | Draw 3D objects (extrusion, lathe, sphere, cube - `fucon3d.cxx`) - promoted from out-of-scope 2026-08-14. | Draw |
| 2.18 | Draw morph (shape-to-shape interpolation - `fumorph.cxx`) - promoted from out-of-scope 2026-08-14. | Draw |
| 2.19 | OpenGL transition effects (`slideshow/source/engine/opengl/`) - promoted from out-of-scope 2026-08-14. The P1 `TransitionStore` catalog (SwiftUI tween) already covers the preset-transition case; this adds true OpenGL-rendered transitions on top of it. | Impress |
| 2.20 | Tagged PDF / Section 508 / PDF-UA export (`EnhancedPDFExportHelper.cxx` parity) - promoted from out-of-scope 2026-08-14 for corporate/government compliance reasons (can be a hard procurement blocker, not a nice-to-have, for public-sector or publicly-traded customers). A distinct code path from plain PDF export, not an extension of it. | Writer + Calc + Impress |
| 2.21 | Mail-merge wizard UI (`mailmergewizard.cxx`-equivalent guided flow) - promoted from out-of-scope 2026-08-14. Layers a guided UI on top of 2.4's `MailMergeCoordinator` single-submit endpoint, which stays the underlying engine either way. | Writer |

Enterprise-track sizing and design positions (per item: recommended
architecture, effort class, tier mapping for new agent tools, and the open
question the architect must answer, if any) live in the refinement doc.
2.19 is reframed there: LO's "OpenGL transitions" are an anachronism on
macOS - the item is GPU-rendered transitions via Metal/CoreAnimation.
2.20 has a candidate cheap path: LO's own tagged-PDF export driven
through the already-shipped CLI converter's filter options, validated by
an external PDF/UA checker in the corpus harness.

### 6d. Out of scope (P3+ / never)

**2026-08-14: nine items moved from this table to P2** (§6c, 2.13-2.21) -
VBA/Basic macro compatibility, the StarMath equation editor, form controls,
database connectivity, Draw 3D objects, Draw morph, OpenGL transitions,
Section 508/tagged-PDF export, and the mail-merge wizard UI - on the
reasoning that several of these are genuine corporate-adoption blockers
(VBA and DB connectivity for enterprise Excel/Access workflows; tagged PDF
for government/public-company compliance procurement) rather than pure
nice-to-haves, even though the underlying implementation challenges each
was excluded for still apply. Legacy `.ppt` write stays out of scope below
- LO's own import path already covers reading it, and there's no
compelling reason to ever write back to a legacy binary format tessera
didn't originate.

| Item | Why |
|---|---|
| Full chart wizard (14 chart types, trendlines, 100+ formatting properties) | Ship all 14 chart types via `ChartRenderer` CoreGraphics; full formatting properties at P2 if real demand surfaces. |
| Solved-style scenario manager | `dpshttab.hxx`; rarely used in modern spreadsheets. |
| PPT (legacy binary) round-trip | One-way import through LO; never write `.ppt` from tessera. |
| Auto-text / glossary blocks | `sw/source/core/swg/SwXMLTextBlocks{,1}.cxx`; `Doc.tags` + the document search index subsume most uses. |
| Scenarios UI | `scenwnd.cxx`; rare in modern spreadsheets. |

### 6e. P1 entry gates (added 2026-08-14)

**All three gates were RATIFIED 2026-08-14** (§8 rows 12-14); P1 wave
briefs are unblocked. The gate texts below are kept as the decision record.
The full proposals with SOTA evidence are in
`studio-expansion-design-refinement-2026-08-14.md`.

**Gate 1 - bridge architecture for structured I/O.** The in-process UNO
path died empirically at P0 (pyuno 3.12 vs linked Python 3.14 ABI; LO's
bundled python3.12 hangs under Gatekeeper even after a clean reinstall -
see the §6a addendum). The shipped `LibreOfficeConverter` CLI covers
whole-file conversion only. P1 items 1.8 and 1.18 (and P2 2.6 solver, and
the 2.20 tagged-PDF path) need a ratified architecture for STRUCTURED
reads before their wave briefs can be written. Candidates: (a) CLI +
flat-ODF Swift readers, (b) LibreOfficeKit C ABI in-process, (c) URP
socket process pool. The refinement doc carries the comparison and a
recommendation; the decision also settles the disposition of the stranded
`EmbeddedPythonBridge.swift` + `tessera_lo_service.py` (~1.4K lines dead
on the abandoned path, plus the linked Python 3.14 framework).

**Proposal on file (2026-08-14, empirically probed):** (a) CLI + FlatODF
primary - flat ODF verifiably carries formulas/number styles/multi-sheet
(fods), masters/placeholders/notes/transitions (fodp), and layers/
connectors/glue points/beziers (fodg), and the tagged-PDF filter options
work end to end on the installed 26.2.5.2; (b) REJECTED - a LOK probe
hard-crashes at init on the stock cask (AppKit main-thread violation; no
headless VCL plugin exists on macOS, upstream-confirmed unfunded); (c)
fallback only, at P2, if 2.6 or SVG shape decomposition demands a live UNO
session (the `--accept` acceptor verifiably starts headless; only the
Swift client side is missing). Stranded Python stack: delete. Full
evidence: `.scratch/sota-bridge-report.md`; proposal text: refinement doc
§1. Ratification adds §8 row 12.

**Gate 2 - NumberFormatEngine scope ratification.** The landed engine
(`FormulaEngine/NumberFormatEngine.swift`, commit `2140af305`) is
grammar-full but delegates locale data to Foundation and documents five
gaps in its own header (fractions, elapsed-time formats, fill `*` / pad
`_` directives, locale-ID currency tags). That is a defensible engineering
position - svl's locale tables bottom out in the same ICU/CLDR data
Foundation carries - but it is NOT the §8 decision-4 "full parity with
svl/source/numbers" as written. Either the architect re-ratifies the
landed scope (recommended; the refinement doc sizes each gap so the
residual can be scheduled deliberately), or a completion deliverable joins
P1. P1 items 1.11/1.12/1.13 render through this engine; the claim and the
code must agree before they ship.

**Gate 3 - ChartRenderer staged type coverage.** Decision 6 says
CoreGraphics with parity across all 14 LO chart types "long-term". Item
1.3 as written prices 14-type parity as one row among nineteen. The gate:
ratify a staged split (P1a core families, P1b/P2 long-tail families, one
`ChartRenderer` component throughout - staging type coverage does not
violate the no-versioned-implementations rule) with the cut line taken
from the canvas/charts SOTA report.

### 6f. Measurement architecture for P1+ (added 2026-08-14)

The agent-ux-fatigue measurement rule (AGENTS.md: one primary + one trust
+ one anti-metric per shipped move, with a real deadline) binds every P1
and P2 unit. P0 shipped without it; P1 does not. Two mechanics make it
cheap:

- **Deliverable 1.0 - round-trip fixture corpus harness** (new; lands
  before any other P1 item claims parity). A checked-in corpus of real
  documents (target: 20+ DOCX, 10+ ODS/XLSX, 10+ PPTX/ODP, 5+ ODG/SVG,
  including files with tables, footnotes, charts, themes, master layouts,
  conditional formats) plus a test target that imports each, exports it,
  and scores survival per feature axis (blocks, cells, formulas, styles,
  shapes, layouts). The harness IS the primary-metric source for every
  parity claim, and it satisfies the §11 post-claim-audit "metrics
  runnable" requirement by construction - the 2026-08-13 audit found 42
  unrunnable metrics precisely because measurement was bolted on after
  the claims.
- **Per-item metric template.** Each P1 wave brief states, before
  implementation: primary = corpus survival percentage on the axes the
  item owns (direction + target + week); trust = import failure / crash
  rate on the corpus (must not regress); anti = one of import latency,
  binary size, or memory (the metric that catches over-correction). Example
  for 1.12: primary "conditional-format rules surviving ODS round-trip
  >= 90 percent by week 2"; trust "corpus import failures stay at 0";
  anti "recalc p95 latency on the 10K-cell fixture regresses < 10
  percent".

---

## 7. Top reusable components to build first (the action list)

The architect-approved rollout order is the priority column of section 3
above, run in three waves:

- **P0 (16 items, MVP)**: SheetWorkbook multi-sheet, RecalcScheduler,
  TokenArray, CellValue/CellFormat/NumberFormat index, NumberFormatEngine
  (full parser), BlockType evolutions (P0 cases including `.shape` /
  `.shapeGroup` for Draw), MasterPageStore, SlideLayoutSpec,
  WriterBridgeFilter, CalcBridgeFilter, SheetProtection, **Shape value
  type, ShapeCatalog, ShapeRenderer, Drawing material quartet, z-order**.
- **P1 (23 items after the 2026-08-14 refinement: 19 original + 1.0
  corpus harness + 1.20 animation interim + 1.21 dynamic-array completion
  + 1.22 comment anchors; parity milestone)**: BlockType evolutions (P1 cases),
  FieldController, Footnote/Endnote, ChartRenderer (CoreGraphics),
  MediaBlock, Theme/ThemeStore, TransitionStore, SlideDeckRenderer,
  LOBridgeDeckIO, MasterPageLayoutPicker, QueryEngine, CellStyle extension,
  ConditionalFormat, DataValidation, RevisionController, **LayerStore,
  TransformController, SnapEngine, ODG/SVG/PDF-export bridge filters,
  text frames on shapes**. Plus the flat `AnimationEffectList` as a SMIL
  interim.
- **P2 (12 core items + 9 design-gated enterprise items, see §6c/6c.1)**:
  SMILAnimationTree (full XAnimationNode tree, 3-5K LoC),
  PivotTableStore (full ScDPObject schema, 4-6K LoC),
  **BezierPathController (Draw custom-geometry paths)**, mail merge,
  ToC/index, solver, subtotals, statistics wizards, change-track reviewer
  UI, custom shows, master documents, **Draw advanced (annotations,
  measure, Draw tables, bullet lists inside shape text)**. Promoted
  2026-08-14 from out-of-scope: **MacroCompatLayer (VBA/Basic macros),
  StarMathEditor, form controls, database connectivity, Draw 3D objects,
  Draw morph, OpenGL transitions, tagged-PDF/Section 508 export, and the
  mail-merge wizard UI** - MacroCompatLayer, form controls, and database
  connectivity still need their own design pass before implementation
  (see §6c.1's 2.13/2.15/2.16 notes and the split rule there).

The ordering is by:

1. **Coverage** - how many capability rows does the component close?
2. **Surface reach** - does the component unlock one suite or all four?
3. **Risk** - is the bridge path proven, or do we need to land a Swift
   primitive first?

The single highest-value component is **`RecalcScheduler`** (priority #2 in
section 3). Without it, the formula engine re-walks the entire dependent cone
on every edit. With it, a 100-cell sheet with `=A1*ROW()` recalcs in O(1) on
no-op edits and in O(depth) on real edits. This is also the single largest
delta between the Swift AST evaluator and the LO RPN model, so landing it
early is a load-bearing prerequisite for the formula engine parity claim.

The single highest-value cross-suite component is **`BlockType` evolution**
(priority #6 in section 3). Nine new cases (`.section`, `.frame`, `.field`,
`.footnote`, `.endnote`, `.shape`, `.shapeGroup`, `.chart`, `.media`) plus
a handful of attribute extensions on existing cases (`.table`
rowSpans/colSpans/nested children, `.list` level/bulletGlyph) close 14 of
the 63 capability rows. Each case is a small diff; the *test* contract
per case is the load-bearing artifact.

The single highest-risk P0 deliverable is **`NumberFormatEngine`** (priority
#5). The architect chose the full parser (not the 80% subset); the upstream
is `svl/source/numbers/zforlist.cxx` + `zformat.cxx` (~60K LoC), ported
cleanly into Swift. The risk is scope, not design: we have to commit to the
full token table, all `nf_*` codes, full locale support. Land early in P0
so downstream components (cell-style, conditional-format, data-validation)
can build on it without rework.

The single highest-value P0 Draw deliverable is the **`Shape` value type +
`Shape` renderer pair** (priorities #11 and #13 in section 3). Without
these, the entire Draw surface has no first-class primitive; everything
upstream (Drawing material, ShapeCatalog, the Impress free-shape uses) is
built on this pair. Land early in P0 so the P1 Draw UI wave has a solid
data-model foundation.

---

## 8. Architect decisions log (2026-08-13, Draw added 2026-08-13)

All eight original questions resolved, plus two new Draw-scope decisions
added 2026-08-13. These are the binding calls for the rollout. Future
waves cite this section; the wave briefs do not re-ask.

| # | Question | Decision | Implication |
|---|---|---|---|
| 1 | DOCX import: bridge or native? | **Bridge** (`WriterBridgeFilter` via UNO). | The pure-Swift ODT/DOCX reader is out of scope. Bridge gets 95% of round-trip fidelity for 2-3 weeks of work. Markdown / plain text remain Swift-native. |
| 2 | Rename `SheetWorkbook` to `Workbook`? | **Keep the name.** | Per the no-versioned-implementations rule. The single-sheet proxy case is a workbook with one sheet, not a different type. |
| 3 | `BlockType` enum growth (16 -> 25 over P0-P1)? | **Approved.** | New cases are surface-specific (`.field` Writer, `.chart` Calc+Impress, `.media` Impress, `.shape`/`.shapeGroup` Draw+Impress). `BlockType` is the union; per-material surface checks for the cases it cares about. Corrected from an original "~24": §3 row 6 and §6a/6b enumerate exactly 9 new cases (`.section`, `.frame`, `.field`, `.footnote`, `.endnote`, `.shape`, `.shapeGroup`, `.chart`, `.media`); 16+9=25. The ~24 estimate was never reconciled against the case list it's approving. |
| 4 | Number formats: 80% parser or full? | **Full parser** (`NumberFormatEngine`, parity with `svl/source/numbers/`). | Token table per locale, full `nf_*` code coverage. Bigger P0 deliverable but the only path to round-trip parity for XLSX/ODS files with locale-specific number formats. |
| 5 | Master pages: data-only or full picker UI? | **Full picker UI** (`MasterPageLayoutPicker` at P1). | The SwiftUI surface consumes `MasterPageStore` and exposes LO's full layout catalog (25+ AutoLayouts from `sd/source/core/sdpage.cxx:1397`). Wired into `SlideDetailView` per the phase12 HIG review. |
| 6 | Chart engine: Swift Charts or CoreGraphics? | **CoreGraphics, long-term.** | `ChartRenderer` draws with `CGContext`; parity with all 14 LO chart types. Per the architect: ages better than Swift Charts for the long-term document parity goal. |
| 7 | Animations: flat list or SMIL tree? | **Evolve to SMIL tree** at P2. | `SMILAnimationTree` is a faithful port of `CustomAnimationEffect.cxx` (3,461 LoC). Includes `ParallelTimeContainer`, `SequenceTimeContainer`, `Animate`, `AnimateMotion`, `AnimateColor`, `AnimateTransform`, `Audio`, `Command`, `IterateContainer`, `Event`. P1 ships a flat `AnimationEffectList` as an interim; P2 evolves it (the list becomes a serialization of the tree, not a parallel v2). |
| 8 | Pivot tables: Swift or UNO? | **Swift with full UNO parity.** | `PivotTableStore` ships the full `ScDPObject` schema: `DataPilotFieldOrientation` matrix, page/row/column/data/filter bins, `PivotTableStyleInfo`, layout + output properties, save/load via `dpsave.hxx` / `dpdimsave.hxx`. Reuses `QueryEngine` infrastructure. |
| 9 | **Draw: separate surface or feature of Impress?** | **Separate surface.** Draw is a first-class peer of Impress with its own `Drawing` material at `Materials/Draw/`. A deck is a sequence of slides; a drawing is a single page of vector graphics. The shared `sd/` upstream binary is a single source-of-truth for the *implementation* (UNO bridge), but the *product* surfaces are distinct. | New `Drawing` material + `*Store` + `*ViewModel` + `*ReceiptType` + `*GraphConnector` quartet. New `Shape` value type peer of `Block`. `ShapeCatalog`, `ShapeRenderer` are peers of `SlideLayoutSpec`, `BlockRenderer`. |
| 10 | **Draw: 3D objects + morph in scope?** | **3D + morph out of scope.** The 2D capability set is in scope (shape catalog, geometry, fill/stroke, z-order, layers, snap, transform, group, connector, text frame, ODG/SVG/PDF I/O). 3D objects (`fucon3d.cxx`) and morph (`fumorph.cxx`) are explicitly punted. **Superseded on the scope point by decision 11 (2026-08-14).** | The Draw surface delivers a full 2D vector graphics app. If a future "Tessera 3D" or "Tessera Morph" track is greenlit, it would land in a separate wave; the existing 2D primitives are the foundation. |
| 11 | **2026-08-14 product decision: re-open nine out-of-scope items?** | **Promoted to P2 as 2.13-2.21** (commit `9623b4017`): VBA/Basic macro compat, StarMath editor, form controls, database connectivity, Draw 3D, Draw morph, GPU transitions, tagged-PDF/508 export, mail-merge wizard UI. Rationale: several are corporate-adoption blockers (VBA + DB for enterprise Excel/Access workflows; tagged PDF for government/public-company procurement), not nice-to-haves. Legacy `.ppt` write stays out per explicit instruction. | Partially supersedes decisions 7 (OpenGL transitions row) and 10 (3D/morph scope). The original architectural objections are preserved as notes on each item; 2.13/2.15/2.16 are DESIGN-GATED - they cannot enter a wave brief until their design pass is ratified (see §6c.1). 2.16 carries an unresolved no-egress policy conflict that only the architect can settle. |
| 12 | Bridge architecture for structured I/O (gate 1)? | **CLI + FlatODF primary; LOK rejected; URP client only as a scoped P2 fallback.** Ratified 2026-08-14 on empirical probes (LOK init crash on the stock cask; flat-ODF coverage verified; tagged-PDF filter options verified). | `FlatODFReader/Writer` land at P1; stranded `EmbeddedPythonBridge.swift` + `tessera_lo_service.py` + `LibreOfficeBootstrap.swift` + the `CPythonBridge` target are DELETED; `CalcBridgeFilter` migrates CSV -> fods; handout PDF recorded out of scope; SVG import = embedded-image fidelity at P1. |
| 13 | NumberFormatEngine: landed scope vs full svl parity (gate 2)? | **Landed scope ratified: grammar-full parser, locale data via Foundation/ICU; gaps closed by frequency** - locale tags + fill/pad at P1 (with the engine WIRED into rendering at 1.11; it has zero consumers today), elapsed + fractions at P2, conditional sections last. Architect note on record: prefer the 95% now; do not spend weeks chasing 100%. | Supersedes the "full parity with svl" reading of decision 4; 1.11 wave briefs cite this row. |
| 14 | ChartRenderer staging (gate 3)? | **Series-typed `ChartSpec`; one component; P1a = column/bar/line/area/pie/scatter, P1b = bubble/net/stock/column-and-line/of-pie inside the P1 wave.** Pivot chart = data source, box plot = stacked-column technique, sparkline = chrome-less preset. | No grammar model; axis `labelFormat` rides NumberFormatEngine; staging is type coverage, not architecture. |
| 15 | P1 scope additions + row-20 drop + ownership? | **Ratified**: 1.0 corpus harness, 1.20 AnimationEffectList (+ pinned fixture), 1.21 dynamic-array completion, 1.22 comment anchors; `FunctionVolatility.array` dropped (phantom axis); ownership per the refinement doc (style registry / search index / comment anchors = expansion; list-level behavior + find & comment UIs = word-class plan). | P1 = 23 deliverables; §6f measurement architecture binds each. |
| 16 | Enterprise-track designs 2.13-2.21? | **Ratified as scoped in the refinement doc**: never-execute VBA (parse + preserve + agent rewrite), LaTeX-first equations over SwiftMath, `w:sdt` content controls as Block attributes, local-file-only `DatabaseConnector` (no network DSNs ever), CI/Metal transition tier (S-scope with declared fallbacks acceptable), CLI tagged-PDF + veraPDF harness, document-only mail merge. Open-question defaults adopted: stored playbook for `macro_translate`; equation numbering joins `FieldController`; forms denial-by-protection routed through `TesseraSafetyDecision`; DuckDB xlsx boundary blessed (material files query via sheet tools only); xlsx dropped from the v1 db path if iOS linking is awkward. | The §6c.1 design gate is discharged; 2.13-2.21 may enter wave briefs. Any adopted default can be re-opened inline if implementation surfaces a conflict. |

**Refinement pass 2026-08-14:** decisions 12-16 above were drafted in
`studio-expansion-design-refinement-2026-08-14.md` and RATIFIED by the
architect the same day (chat approval). The five §6c.1 open-question
defaults are adopted as recorded in row 16.

**Decision 17 (RATIFIED 2026-08-15, chat approval):** the P2 execution
package in `studio-p2-implementation-plan-2026-08-15.md` §6 - the eight
new design contracts in `.scratch/sota-p2-core-report.md` (incl. 2.6 =
native Swift goal-seek + linear simplex with nonlinear engines out of
scope; 2.9 = Writer-first; 2.11 = data-only assembly manifest); Wave P2-0
as a blocking gap-closure wave scoped by
`p1-post-claim-audit-2026-08-15.md` §3; the P2-A..D wave structure and
standing rules; the "no receipt without a mutation" standing rule; and
per-wave audits replacing a single deferred audit.

The remaining open questions (no longer blocking the rollout, but worth
tracking):

- **Power-user Basic compatibility** - any future Tessera scripting surface
  will be a Tessera-native agent tool surface, NOT a Basic dialect.
- **Multi-user coediting / CRDT layer** - the receipt backbone is the
  audit log, but real-time coediting is a different design conversation.
  Out of scope for this expansion.
- **Draw 3D + morph** - re-opened by decision 11 (2026-08-14) as 2.17/2.18;
  both need the design position in the refinement doc before any wave
  picks them up.
- **Draw star/polygon + complex preset shapes** - the P0 set covers rect,
  ellipse, line, arrow, polygon, star, freeform. The full LO preset shape
  catalog (`oox/source/ppt/pptshape.cxx` has 200+ entries) is a P2+
  extension.

---

## 9. Where this lives in the repo

- **This document**: `TesseraStudio/docs/studio-expansion-plan.md`
- **Detail per suite**: `TesseraStudio/docs/.scratch/lo-{writer,calc,impress}-report.md`
- **Existing Writer plan (still valid)**: `TesseraStudio/docs/word-class-document-processor-implementation-plan.md`
- **Existing slides HIG review**: `TesseraStudio/docs/phase12-hig-review-sheets-slides-code.md`
- **Existing agent surface (4 capabilities)**: `docs/AGENT-UX-FATIGUE-REVIEW.md` + `AGENTS.md` "Program Routing"

The three sibling scratch reports are kept as evidence; the consolidated
matrix, component catalog, and phased rollout in this document are the
proposal. The architect approved the proposal (2026-08-13) and added the
Draw scope (also 2026-08-13); the alphaevolve + tessera-analyst +
findings-curator + verifier capabilities carry the work into the wave
loop (`scratch/<feature>/agent-X` -> `evolve-review/...` -> `champions/<id>`
-> `evolve-baseline/wN`).

**Note on Draw evidence:** the original Impress scratch report
(`docs/.scratch/lo-impress-report.md`) covers the Draw-specific subsections
of `sd/` (the Draw rows in §2 of that report, the Draw-only notes in §8).
For a dedicated Draw capability study, dispatch a fresh `explore` agent with
scope `sd/source/ui/func/fu*.cxx` (the `fuconbez`, `fucon3d`, `fulink`,
`fuconnct`, `fusnapln`, `fumorph`, `futransf`, `fugrou*.cxx`, `futext`,
`fubullet`, `fuinsert`, `fupoor`, `fumeasur`, `undolayer` files) plus
`xmloff/source/drawing/` and `oox/source/export/shapes.cxx`. The
high-level capability inventory is already in §2 of this document (rows
44-63); a Draw-only scratch report would refine the per-source path evidence
but is not required to start the rollout.

## 10. Agent tools surface

The expansion is the *architecture* (capability map, components, phased
rollout). The *agent-facing surface* is the tools the agent loop can call
on top of that architecture. The full sketch is at
`docs/agent-tools-surface.md` (companion to this doc, 2026-08-13).

Headline shape:

- **~65 tools total**, organized by prefix:
  - `doc_*` (Doc / Writer, ~18), `sheet_*` (Sheet / Calc, ~14),
    `slide_*` (SlideDeck / Impress, ~12), `drawing_*` (Drawing / Draw, ~12),
    `materials_*` (cross-cutting, ~6), `lifecycle_*` (lifecycle, ~3).
- **One tool file per material**, peer of the existing `Tools/SheetTools.swift`:
  `Tools/DocTools.swift`, `Tools/SlideTools.swift`, `Tools/DrawingTools.swift`,
  `Tools/MaterialsTools.swift`, `Tools/LifecycleTools.swift`. No `_v2`; no
  parallel implementations.
- **The existing `TesseraTool` protocol** (`TesseraCore/Agent/TesseraTool.swift:182`)
  is the binding contract. `name` (snake_case), `description`,
  `defaultApprovalLevel` (`ApprovalLevel`), `parameters: JSONSchema`,
  `execute(arguments:) async throws -> ToolResult`. No new tool shape.
- **Tier mapping** (§7 of the tools doc) maps `ApprovalLevel` to the new
  `TesseraTier` enum (audit Wave 1). Read tools = `tier0`; per-entity
  writes = `tier1`; import / export = `tier2`; non-empty trash = `tier3`.
- **Receipt semantics** (§10 of the tools doc) ride the existing
  `ReceiptsCoordinator` and the per-material receipt vocabularies. Every
  mutating tool emits exactly one receipt per call (or one per affected
  entity in a cascade). Read tools do not emit receipts.
- **Citation + uncertainty** (§12 of the tools doc) ride the audit Wave
  2-3 work: every `ToolResult` carries `sources: [Citation]` and
  `confidenceBand: ConfidenceBand?`. Numeric confidence percentages are
  forbidden.
- **Inline stop + notification budget** (§13) bind: long-running tools
  wire to `TesseraAgentLoop.stop(reason:)`; no tool posts a user-facing
  push (the budget's 3-per-UTC-day cap is hard; no `force:` override); the
  audit log is pull, not push.

The wave loop ships a tesseracore component + its tools in the same wave
(the tool is the agent-facing half of the component). The
`tools/agent-tools-surface.md` doc is the source of truth for the tool
API; the per-wave briefs enumerate the specific tools that land in that
wave.

## 11. Skill refinements (post-claim audit)

The user performed an independent post-claim audit of the agent-ux-fatigue
sprint on 2026-08-13 and surfaced intent-vs-outcome gaps that the
existing `superpowers:verification-before-completion` and `code-review`
skills do not cover. The refinement patches are at
`docs/skill-refinement-patches-2026-08-13.md` (companion to this doc and
the agent-tools-surface doc).

Headline:

- **`verification-before-completion` gains a "Post-claim audit"
  section** — the system-level integrity check (build green at the
  moment of the claim? test target compiled? metrics runnable?
  provenance real?).
- **`code-review` gains a "Claim-vs-evidence pass" section** — the
  per-unit integrity check (surface instantiated? open path real? call
  from agent real? chip reachable?).
- The two refinements form a closed loop: pre-claim verify
  (existing) -> claim -> post-claim audit (new in
  verification-before-completion) -> per-unit claim-vs-evidence pass
  (new in code-review) -> per-scope defect review (existing in
  code-review) -> integrity verdict.

Both skills are built-in (immutable at runtime per the skill-refiner
procedure). The patches ship via MR to the upstream Mavis skill
source; the doc carries the exact text to add and the application path.

**The next wave uses these.** Every wave's review gate runs the
post-claim audit on the previous wave's claims and the per-unit
claim-vs-evidence pass on each new component. A wave that ships
without both passes is unverified.
