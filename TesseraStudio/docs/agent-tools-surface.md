# Tessera Studio Agent Tools Surface

**Status:** sketch for architect review (2026-08-13)
**Author:** Mavis (orchestrator)
**Companion to:** `studio-expansion-plan.md` (architecture / capability map)
**Scope:** the agent's tool API across Doc, Sheet, SlideDeck, Drawing, and cross-cutting surfaces
**Out of scope:** tool *implementations* (those land in waves); tool *registry mechanics* (already shipped at `TesseraCore/Agent/TesseraToolRegistry.swift` and `TesseraTool.swift`)

---

## TL;DR

Tessera Studio already has a working tool contract (`TesseraTool` protocol, `JSONValue`, `JSONSchema`, `ToolResult`, `ApprovalLevel`) and one shipped material-surface tool file: `SheetTools.swift` (3 tools; `Tools/` also holds ~41 other `TesseraTool` conformers for the calibration/harness/learning side of the agent, unrelated to the four product materials). The expansion adds the parallel surfaces for **Document**, **SlideDeck**, **Drawing**, and the cross-cutting / lifecycle / pipeline tools. Original target was ~65 tools; as drafted, the per-surface tables in §4-9 enumerate 79 (see the corrected count in §2) — reconcile before wave-splitting. No versioned implementations, every tool follows the same protocol.

The agent-ux-fatigue audit rules bind every new tool: tier policy, notification budget, inline stop, audit log, citation + uncertainty. There are no new "tool shapes" being introduced; this is an *enumeration* of what the existing shape means for the four product surfaces.

The plan this doc serves: a single source-of-truth for the tool API. Each wave picks a batch, lands it on top of the corresponding tesseracore component, and registers it in `TesseraToolRegistry`. No new tool protocol surface; no `_v2` tools; no parallel implementations.

---

## 1. The tool contract (recap)

The `TesseraTool` protocol at `TesseraCore/Agent/TesseraTool.swift:182` is the contract every tool conforms to. The five fields:

```swift
public protocol TesseraTool: Sendable {
    var name: String { get }                                       // snake_case verb_object
    var description: String { get }                                // one-paragraph natural-language doc
    var defaultApprovalLevel: ApprovalLevel { get }                // .auto (read) or .prompt (mutate)
    var parameters: JSONSchema { get }                             // JSON Schema for the args
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult
}
```

`ToolResult` is the return shape (`TesseraTool.swift:140`) — corrected against the actual struct, which does not match an earlier draft of this doc:

```swift
public struct ToolResult: Sendable {
    public let success: Bool
    public let output: String         // human-readable summary for the chat
    public let data: [String: JSONValue]?  // structured result the model can use
    public let error: String?
    public let confidenceBand: ConfidenceBand?  // audit 2D wire field; real, present today
}
```

There is no `sources: [Citation]` field on `ToolResult` today. `Citation` and `sources` exist on `ToolResultPayload` (`Models/ChatMessage.swift`, the chat-layer wrapper), not on the tool-layer return type — so a tool implementation cannot attach a citation directly yet. Either the per-tool code below should read citations off `ToolResultPayload` at the call site that wraps a `ToolResult`, or `ToolResult` needs a `sources` field added as part of this wave; that's an open question for whoever lands the first `doc_*`/`slide_*` read tool, not yet decided here.

`ApprovalLevel` is a 4-state enum (`.auto`, `.notify`, `.prompt`, `.denied` — `TesseraApprovalEngine.swift:5`), not the two-state `.auto`/`.prompt` split this doc assumed elsewhere. The new `TesseraTier` enum (4-state, from the agent-ux-fatigue audit Wave 1) is *orthogonal* to `ApprovalLevel` regardless of that correction — `ApprovalLevel` is the *call-site* default that the agent loop reads; `TesseraTier` is the *risk-rating* the user (or the policy) has assigned. The mapping is in §11 (misnumbered §7 in an earlier draft of this doc).

Existing reference implementation: `Tools/SheetTools.swift`. Read it once; every new tool follows the same shape.

## 2. Categorization

Five categories. The categorization is the binding structure; tools within a category share a naming prefix and a tier default.

| Prefix | Category | Surface | Default tier | Approximate count |
|---|---|---|---|---|
| `doc_*` | Document tools | Writer (Doc material) | read = auto, write = prompt, export = prompt | 19 (§4a 8 + §4b 8 + §4c 3) |
| `sheet_*` | Spreadsheet tools | Calc (SheetWorkbook material) | read = auto, write = prompt, export = prompt | 19 (§5a 8 + §5b 8 + §5c 3; 3 existing + 16 new, not "+11" as §5's body text originally said) |
| `slide_*` | Slides tools | Impress (SlideDeck material) | read = auto, write = prompt, export = prompt | 15 (§6a 4 + §6b 8 + §6c 3) |
| `drawing_*` | Drawing tools | Draw (Drawing material) | read = auto, write = prompt, export = prompt | 17 (§7a 4 + §7b 10 + §7c 3) |
| `materials_*` | Cross-cutting | All materials + audit log | read = auto, write = prompt | 6 |
| `lifecycle_*` | Material lifecycle | Create / archive / trash / favorite | prompt (all are mutating) | 3 |
| **Total** | | | | **79** |

Corrected count: the per-surface tables in §4-9 enumerate 79 tools, not the ~65 originally estimated in the TL;DR — the estimate was made before the tables were drafted out and never reconciled against them. 79 is itself an upper bound before pruning: some tools compose others and the wave-level work should err toward fewer tools with broader arguments, not more narrow tools. Treat 79 as "what's enumerated," not a target; the final per-wave count is still a wave-level decision.

## 3. Naming convention

- **snake_case** for `name`. The existing `SheetTools` uses `sheet_read` / `sheet_write` / `sheet_describe`.
- **verb_object** is the canonical form. Read = `*_read` or `*_describe`; write = `*_write` or `*_set_*`; transform = `*_apply_*` or `*_convert_*`; export = `*_export`; diff = `*_diff`; list = `*_list`.
- **No version suffix.** No `*_v2`, no `*_new`, no `*_enhanced`. Per the no-versioned-implementations rule, the tool extends or replaces an existing tool in place.
- **No material prefix duplication.** A tool that operates on the *currently active* material omits the prefix: `read` / `write` / `diff` / `export` / `list` work via the active-material context. The `materials_*` tools resolve ambiguity (e.g. `materials_pick` switches the active material).
- **`_*_by_*` suffix for parameterized variants.** `slide_list_by_master` lists slides under a master page; `doc_search_by_style` searches within a named style. Avoids the alternative of `*_v2` and `*_extended`.

## 4. Document tools (Writer surface, ~18 tools)

Prefix: `doc_*`. The Doc material is at `Productivity/Materials/Docs/Doc.swift`; the body is `DocumentAST` (see `Productivity/Block.swift`).

### 4a. Read tools (auto)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `doc_read` | `reference: blockID?` | `DocumentAST` slice | Read a block by id; if omitted, return the outline + headings |
| `doc_describe` | none | metadata + block count + receipt id | The existing `SheetDescribeTool` analog for docs |
| `doc_outline` | `maxDepth: Int?` | `[Heading]` (depth, text, blockID) | For TOC and section detection |
| `doc_table_of_contents` | `style: String?` | `[TocEntry]` | Returns the resolved TOC; LO computes, we serialize |
| `doc_count` | none | `wordCount`, `charCount`, `blockCount`, `headingCount` | Cheap; no body read |
| `doc_search` | `query: String`, `regex: Bool?`, `scope: blockID?` | `[Match]` (blockID, range, snippet) | The new `DocumentSearchIndex` consumer |
| `doc_styles_list` | `kind: paragraph \| character \| list \| table` | `[StyleRef]` | The new `StyleRegistry` consumer |
| `doc_receipts` | `limit: Int?` | `[Receipt]` | The audit-log side-panel consumer (per Wave 3 of the audit) |

### 4b. Write / mutate tools (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `doc_write` | `blockID`, `inlineRuns: [InlineRun]` | the new block | Single-block inline write; composed for paragraphs / headings |
| `doc_insert_block` | `parent: blockID`, `index: Int`, `block: Block` | the inserted block id | Once the planned `BlockType.section` / `.frame` / `.field` / `.footnote` / `.shape` / `.chart` cases land (studio-expansion-plan.md §8 decision #3 — none exist on `BlockType` today; it is still the original 16-case enum) they route through this tool |
| `doc_delete_block` | `blockID` | the deleted block id | Cascades to children; one receipt per cascade |
| `doc_set_style` | `blockIDs: [blockID]`, `styleRef: UUID` | the affected block ids | The new `StyleRegistry` consumer |
| `doc_set_section` | `range: [blockID]`, `section: Section` | the new section id | The new `Section` consumer; multi-column lives here |
| `doc_set_field` | `blockID`, `field: Field` | the new field id | The new `FieldController` consumer; page #, cross-ref, formula |
| `doc_set_track_changes` | `enabled: Bool` | the new `DocumentMetadata.trackChangesEnabled` | The new `RevisionController` consumer |
| `doc_redline` | `range`, `kind: insertion \| deletion \| format`, `author` | the new revision id | Pairs with `doc_set_track_changes` |

### 4c. Export / import (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `doc_export` | `format: docx \| pdf \| odt \| html \| rtf \| txt`, `path: URL` | the export receipt id | Calls `DocumentExporter` (existing) or the new `WriterBridgeFilter` |
| `doc_import` | `path: URL`, `format: auto` | the new `Doc` material id | The new `WriterBridgeFilter` (UNO) consumer |
| `doc_diff` | `against: docID`, `asOf: Date?` | `[Diff]` (blockID, kind, before, after) | The new receipt-log diff consumer |

## 5. Spreadsheet tools (Calc surface, ~14 tools)

Prefix: `sheet_*`. `SheetTools.swift` ships `SheetReadTool`, `SheetWriteTool`, `SheetDescribeTool`; the expansion adds 16 more (see the corrected §2 count). `SheetWorkbook` (`Productivity/Materials/Sheets/SheetWorkbook.swift`) is single-sheet today — one `engine: SheetEngine` and one `sheetID: UUID?`, `hydrate(from:)` replaces the whole engine per load. It WILL carry the multi-sheet identity once the P0 evolution (`sheets: [SheetID: SheetSnapshot]`) lands, but that has not been built; `sheet_list_sheets`/`sheet_pick_sheet` below are not callable against anything today.

Note also: `SheetCellFormat` (number format, decimals, bold/italic, fill, borders, alignment) already shipped this session at `Productivity/Materials/Sheets/SheetCellFormat.swift`, ahead of this plan's P0 item #4 (`CellValue` + `CellFormat`, studio-expansion-plan.md). `sheet_format`'s `cellFormat: CellFormat` argument below should bind to `SheetCellFormat` — building a separate `CellFormat` type would be exactly the parallel-implementation this doc's naming rules forbid. Reconcile before P0 work starts on cell formatting; see the note added to studio-expansion-plan.md's component table.

### 5a. Read tools (auto)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `sheet_read` | (existing) | TSV grid | Unchanged |
| `sheet_describe` | (existing) | metadata | Unchanged; extended to multi-sheet |
| `sheet_list_sheets` | none | `[SheetInfo]` (id, name, role) | The new `SheetWorkbook` consumer |
| `sheet_pick_sheet` | `sheet: String` | the new active sheet id | Switches the workbook focus; one tool = no `_v2` |
| `sheet_named_ranges_list` | `scope: workbook \| sheet(name)?` | `[NamedRange]` | The new `NamedRangeRegistry` consumer |
| `sheet_named_range_resolve` | `name: String` | the resolved range + value | The new `Parser` name-resolution consumer |
| `sheet_formula_parse` | `expr: String` | the AST | The new `Parser` consumer; for "what does this formula do?" queries |
| `sheet_receipts` | `limit: Int?` | `[Receipt]` | Same shape as `doc_receipts`; the audit-log consumer |

### 5b. Write / mutate tools (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `sheet_write` | (existing) | the cell receipts | Unchanged |
| `sheet_set_formula` | `reference`, `formula: String` | the new cell value | Aliases `sheet_write` with `value` starting with `=`; the explicit form is the safer pattern |
| `sheet_format` | `range`, `cellFormat: CellFormat` | the formatted range | The new `CellFormat` consumer (font, fill, border, alignment, numberFormat) |
| `sheet_set_validation` | `range`, `rule: ValidationRule` | the rule id | The new `DataValidation` consumer |
| `sheet_set_conditional_format` | `range`, `rule: CFRule` | the rule id | The new `ConditionalFormat` consumer |
| `sheet_insert_chart` | `range`, `spec: ChartSpec` | the new chart block id | The new `ChartRenderer` (CoreGraphics) consumer |
| `sheet_pivot_create` | `sourceRange`, `pivot: PivotDescriptor` | the new pivot id | The new `PivotTableStore` (P2) consumer |
| `sheet_query` | `range`, `query: QueryParam` | the filtered range | The new `QueryEngine` consumer (sort, filter, autofilter) |

### 5c. Export / import (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `sheet_export` | `format: csv \| ods \| xlsx \| xls \| pdf`, `path: URL` | the export receipt id | The new `CalcBridgeFilter` (UNO) consumer; CSV stays native via `SpreadsheetDigester` |
| `sheet_import` | `path: URL`, `format: auto` | the new `SheetWorkbook` material id | The new `CalcBridgeFilter` consumer |
| `sheet_diff` | `against: sheetID`, `asOf: Date?` | `[Diff]` (cell, kind, before, after) | Receipt-log diff |

## 6. Slides tools (Impress surface, ~12 tools)

Prefix: `slide_*`. The SlideDeck material at `Productivity/Materials/Slides/SlideDeck.swift` is the durable `graph_entity` row; `Slide` is a derived view.

### 6a. Read tools (auto)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `slide_read` | `slideIndex: Int?` | the `Slide` (body + notes + layout + masterPageID + transition) | Null = active slide |
| `slide_describe` | none | deck metadata (slide count, master count, transition set) | Mirror of `doc_describe` |
| `slide_outline` | `maxDepth: Int?` | `[OutlineEntry]` (slideIndex, title, level) | Heading-rooted outline |
| `slide_receipts` | `limit: Int?` | `[Receipt]` | Same shape as the other materials |

### 6b. Write / mutate tools (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `slide_insert` | `index: Int?`, `layout: SlideLayout?` | the new slide id | `null` index = append |
| `slide_delete` | `slideIndex: Int` | the deleted slide id | Receipts cascade to body + notes |
| `slide_reorder` | `from: Int`, `to: Int` | the new slide order | |
| `slide_set_layout` | `slideIndex: Int`, `layout: SlideLayoutSpec` | the new layout id | The new `SlideLayoutSpec` consumer |
| `slide_set_master` | `slideIndex: Int? \| all`, `masterPageID: UUID` | the affected slide ids | The new `MasterPageStore` consumer |
| `slide_set_transition` | `slideIndex: Int`, `transition: TransitionSpec` | the new transition id | The new `TransitionStore` consumer |
| `slide_set_animation` | `slideIndex: Int`, `target: shapeID?`, `effect: AnimationEffect` | the new animation id | P1 flat list; P2 SMIL tree |
| `slide_set_notes` | `slideIndex: Int`, `notes: String` | the updated notes | The existing `Slide.notes` consumer |

### 6c. Export / import (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `slide_export` | `format: odp \| pptx \| pdf \| png \| jpg`, `path: URL`, `slideIndices: [Int]?` | the export receipt id | The new `LOBridgeDeckIO` (UNO) consumer for ODP / PPTX / PDF; `SlideDeckRenderer` (CoreGraphics) for PNG / JPG |
| `slide_import` | `path: URL`, `format: auto` | the new `SlideDeck` material id | The new `LOBridgeDeckIO` consumer |
| `slide_diff` | `against: deckID`, `asOf: Date?` | `[Diff]` (slideIndex, kind) | Receipt-log diff |

## 7. Drawing tools (Draw surface, ~12 tools)

Prefix: `drawing_*`. Entirely planned, not built: `Materials/Draw/` does not exist, and neither does `Productivity/Shape.swift`. This whole section describes the P0 Draw quartet from studio-expansion-plan.md (the `Drawing` material as the durable `graph_entity` row for a single-page vector graphic; `Shape`, peer of `Block`, as the per-shape value type) before any of it lands — every tool below is a proposal, not a wrapper around existing code.

### 7a. Read tools (auto)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `drawing_read` | `shapeID: UUID?` | the `Shape` (or the full list) | The new `Shape` consumer |
| `drawing_describe` | none | drawing metadata (canvas size, layer list, shape count) | Mirror of `doc_describe` |
| `drawing_list_shapes` | `layer: UUID?`, `kind: ShapeKind?` | `[ShapeRef]` (id, kind, zIndex, layer) | The new `ShapeCatalog` consumer |
| `drawing_receipts` | `limit: Int?` | `[Receipt]` | Same shape as the other materials |

### 7b. Write / mutate tools (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `drawing_insert_shape` | `kind: ShapeKind`, `geometry: ShapeGeometry`, `fill?`, `stroke?` | the new shape id | The new `Shape` + `ShapeRenderer` consumer |
| `drawing_delete_shape` | `shapeID: UUID` | the deleted shape id | Cascades to children of `shapeGroup` |
| `drawing_set_geometry` | `shapeID`, `geometry: ShapeGeometry` | the updated shape | The new `TransformController` consumer |
| `drawing_set_fill` | `shapeID`, `fill: ShapeFill?` | the updated shape | |
| `drawing_set_stroke` | `shapeID`, `stroke: ShapeStroke?` | the updated shape | |
| `drawing_set_text` | `shapeID`, `runs: [InlineRun]` | the updated shape | Text-on-shape; the bullet list inside shape text comes at P2 |
| `drawing_set_z_order` | `shapeID`, `z: Int \| bringForward \| sendBackward \| toFront \| toBack` | the updated zIndex | The P0 z-order consumer |
| `drawing_group` | `shapeIDs: [UUID]`, `name: String?` | the new group id | P1; the `BlockType.shapeGroup` consumer |
| `drawing_ungroup` | `groupID: UUID` | the ungrouped shape ids | P1 |
| `drawing_set_layer` | `shapeID`, `layerID: UUID` | the new layer id | P1; the new `LayerStore` consumer |

### 7c. Export / import (prompt)

| Tool | Arguments | Result | Notes |
|---|---|---|---|
| `drawing_export` | `format: odg \| svg \| pdf \| png \| jpg`, `path: URL` | the export receipt id | The new `ODGBridgeFilter` / `SVGBridgeFilter` / `PDFExportBridge` (UNO) for ODG / SVG / PDF; `UIGraphicsImageRenderer` over `ShapeRenderer` for PNG / JPG |
| `drawing_import` | `path: URL`, `format: auto` | the new `Drawing` material id | The bridge consumer |
| `drawing_diff` | `against: drawingID`, `asOf: Date?` | `[Diff]` (shapeID, kind) | Receipt-log diff |

## 8. Cross-cutting tools (~6 tools)

Prefix: `materials_*`. The cross-cutting layer does not own a material; it orchestrates across all of them.

| Tool | Arguments | Result | Tier | Notes |
|---|---|---|---|---|
| `materials_list` | `kind: doc \| sheet \| slide \| drawing \| code \| task \| contact \| all?` | `[MaterialRef]` (id, kind, title, updatedAt) | auto | The "what does the user have?" tool. Used by the agent to discover context. |
| `materials_pick` | `materialID: UUID` | the new active material id | prompt | Sets the active material; the unprefixed tools (`read` / `write` / `diff` / `export`) operate on the active one |
| `materials_search` | `query: String`, `kind: MaterialKind?`, `limit: Int?` | `[SearchHit]` (materialID, snippet, blockID) | auto | Cross-material full-text search via the new `DocumentSearchIndex` (per-material) and a thin per-material `*SearchIndex` consumer |
| `materials_link` | `from: materialID`, `to: materialID`, `kind: refersTo \| derivedFrom \| embeddedIn` | the new link id | prompt | The existing `linkedEntityIDs` consumer across all materials |
| `materials_diff` | `a: materialID`, `b: materialID`, `asOf: Date?` | the diff tree | prompt | The receipt-log diff consumer; cross-material diff is `Doc ↔ Doc` not `Doc ↔ Sheet` (returns an error) |
| `materials_receipts` | `materialID: UUID?`, `limit: Int?` | `[Receipt]` | auto | Audit-log consumer; the `materialID` filter scopes the query |

## 9. Lifecycle tools (~3 tools)

Prefix: `lifecycle_*`. These are the "create / archive / trash" tools. Most materials already have CRUD inside their `*Store`; the lifecycle tool is the public agent-facing API.

| Tool | Arguments | Result | Tier | Notes |
|---|---|---|---|---|
| `lifecycle_new` | `kind: doc \| sheet \| slide \| drawing`, `title: String?`, `templateID: UUID?` | the new material id | prompt | The Doc / Sheet / SlideDeck / Drawing factory |
| `lifecycle_archive` | `materialID: UUID` | the archived material id | prompt | Soft-archive; reversible via `lifecycle_unarchive` |
| `lifecycle_trash` | `materialID: UUID` | the trashed material id | prompt (default), `tier2` if a confirmation panel requires it | The existing `DocStore` / `SheetStore` / `SlideStore` archive / trash paths |

(`favorite`, `tag`, and other DocStore-level mutators land under `lifecycle_*` too but are out of the P0 scope; they ride the existing per-material mutator pattern when needed.)

## 10. Receipt semantics

Every mutating tool (`prompt` tier) emits exactly **one receipt** per call (or one per affected entity, in the case of a cascade). The receipt is the constitutional mutation record. The pattern is identical to the existing `DocStore` / `SheetStore` / `SlideStore` receipt vocabulary.

| Tool family | Receipt type | Payload |
|---|---|---|
| `doc_*` | `DocReceiptType.{write, insertBlock, deleteBlock, setStyle, setSection, setField, setTrackChanges, redline, export, import, diff}` | block id(s), the diff (before / after), the new content |
| `sheet_*` | `SheetReceiptType.{write, setFormula, format, setValidation, setConditionalFormat, insertChart, pivotCreate, query, export, import, diff}` | cell / range / sheet, the diff, the new content |
| `slide_*` | `SlideReceiptType.{insert, delete, reorder, setLayout, setMaster, setTransition, setAnimation, setNotes, export, import, diff}` | slide index, the diff, the new content |
| `drawing_*` | `DrawingReceiptType.{insertShape, deleteShape, setGeometry, setFill, setStroke, setText, setZOrder, group, ungroup, setLayer, export, import, diff}` | shape id(s), the diff, the new content |
| `materials_*` | `MaterialReceiptType.{pick, link, diff}` | material id(s), the diff, the new link |
| `lifecycle_*` | `MaterialReceiptType.{new, archive, trash, unarchive}` | new material id, the kind |

Read tools (`auto` tier) do **not** emit receipts; the audit log only carries mutations. (This is consistent with the existing tool pattern: `sheet_read` does not emit a receipt; `sheet_write` does.)

The `materials_diff` and `materials_receipts` tools are read-shaped; they do not mutate and do not emit receipts. They are the agent's read API into the audit log itself.

## 11. Tier mapping

The new `TesseraTier` enum (audit Wave 1, `TesseraCore/Agent/TesseraTier.swift`) is the 4-state risk rating. `ApprovalLevel` is a separate 4-state call-site default (see §1's correction) — the two enums are orthogonal in purpose, not in cardinality. The mapping is:

| `ApprovalLevel` (call-site default) | `TesseraTier` (risk rating, post-mitigation) | Examples |
|---|---|---|
| `.auto` | `tier0` | All read tools. Reading a workbook is reversible and zero-blast-radius. |
| `.prompt` | `tier1` (default) | All write tools that mutate one block / cell / shape. Single receipt per call. |
| `.prompt` | `tier2` (when import / export is the action) | `doc_import`, `doc_export`, `sheet_import`, `sheet_export`, `slide_import`, `slide_export`, `drawing_import`, `drawing_export`, `lifecycle_trash`. Importing a file overwrites the user's local view; the `ConfirmationPanel` surfaces this with a tier label. |
| `.prompt` | `tier3` (when a confirmable destructive action is queued) | `lifecycle_trash` on a non-empty material (this is the audit's paradox-1 / paradox-5 concern). |

`TesseraSafetyDecision.tier(forActionClass:)` (`TesseraCore/Agent/TesseraSafetyDecision.swift:113-115`) is a 3-line delegate to `TesseraTier.compute(risk:irreversible:)` (`TesseraTier.swift:69-95`) — the actual mapping logic, and the single auditable surface per that type's own doc comment. Neither function today special-cases on the action-verb strings ("import"/"export"/"lifecycle_trash") this table uses; the import/export -> tier2 and non-empty-trash -> tier3 rules exist only as the prose above, not as code yet. Implementing this table is itself P0-adjacent work. The architect-approved rule from the audit Wave 1 still holds regardless: the only path that lowers a tier is `TesseraTier.revoke()`; direct reassignment is tier-boundary drift and fails review.

## 12. Citation + uncertainty

Per the audit Wave 2-3 (`docs/AGENT-UX-FATIGUE-REVIEW.md`):

- `ToolResultPayload.sources: [Citation]` (item 3A) — every tool result carries a `sources: [Citation]` field. Read tools that surface a path into the underlying file (e.g. `slide_read` returning a shape attribute) attach a `Citation` per referenced block. The chat row renders the first 3 as inline chips and expands on tap.
- `ToolResultPayload.confidenceBand: ConfidenceBand?` (item 2D) — every tool result carries a categorical `low | medium | high` band. The split is the Tian Pan 2026-04-12 calibration curve: "the agent was uncertain and said so" vs. "the agent was confident and was wrong". Numeric percentages are forbidden per the audit.

For the new tools: read tools default to `medium` (the data was retrieved; the agent still has to reason about it). Write tools default to `high` (the action was performed). `materials_search` and `materials_diff` are the highest-uncertainty tools (the agent is acting on a similarity or diff score) and default to `low`. The agent can override the band on a per-call basis; the architect approves a new enum case at the call site if a future use case genuinely warrants it.

## 13. Inline stop + notification budget

- **Inline stop**: any tool that runs a long-lived operation (e.g. `doc_import` of a 500-page DOCX, `slide_import` of a 200-slide ODP, `sheet_recalculate` on a workbook with 10K dependent cells) wires its `execute` body to `TesseraAgentLoop.stop(reason:)` via a `Task.checkCancellation()` poll or an `AsyncStream` subscription. The agent-ux-fatigue rule holds: a `stop(reason: .userRequest)` halts the operation; the loop does not auto-resume. The `AgentInlineStopButton` (Wave 3C) is the user-facing affordance.
- **Notification budget**: no tool posts a user-facing push notification. All "import complete" / "export complete" / "diff generated" signals ride the `TesseraNotificationBudget` (3-per-UTC-day hard cap) and prefer the in-app receipts side panel. The budget is enforced via `TesseraNotificationCategory.{workflow, training, adaptation, assessment, covert, wipeReport, reminder}` (Wave 1D); tools pick the appropriate category. There is no `force:` override; the cap is a hard cap.
- **Audit log**: every mutating tool call logs to `ActionAuditLogStore` (Wave 3D) with the tier label, the time, and the receipt id. The side panel renders the chronological list; the head chip on the diff overlay (Wave 1C) is the headline. Pull, not push.

## 14. Composition patterns

The agent composes multiple tools in a single conversational turn. The common patterns:

- **Discover -> Read -> Write**. `materials_list` -> `sheet_pick_sheet` -> `sheet_read` -> `sheet_write`. The agent's standard "find the workbook, find the sheet, look at the cells, change them" loop.
- **Import -> Read -> Transform -> Export**. `doc_import` -> `doc_read` -> `doc_set_style` -> `doc_export`. The standard "open this file, change its formatting, save it back" loop.
- **Diff -> Apply**. `materials_diff` (against a previous version) -> `doc_write` (apply a single fix). The "review and accept" loop.
- **Search -> Open -> Edit**. `materials_search` (full-text) -> `materials_pick` -> `doc_read` (the matched block) -> `doc_write` (the fix). The "find and replace" loop, generalized.
- **Aggregate**. The agent can fan out: `sheet_describe` (every workbook) -> `materials_list` (every doc with a matching tag) -> a single summary in the chat. Fan-out is bounded by the existing agent loop's per-turn token budget; tools do not enforce it.

The composition is mediated by the agent loop (`TesseraAgentLoop`, Wave 3C inline stop + the existing `TesseraAgentLoop.stop(reason:)`). The tool layer does not know about the agent loop; the agent loop owns the conversational state and the inline-stop wiring.

## 15. Where the tools live

All new tools land under `TesseraCore/Tools/`, peer of the existing `SheetTools.swift`:

```
TesseraCore/Tools/
  SheetTools.swift                (existing — 3 tools, sheet_read / sheet_write / sheet_describe)
  DocTools.swift                  (new — ~18 tools, doc_*)
  SlideTools.swift                (new — ~12 tools, slide_*)
  DrawingTools.swift              (new — ~12 tools, drawing_*)
  MaterialsTools.swift            (new — ~6 tools, materials_*)
  LifecycleTools.swift            (new — ~3 tools, lifecycle_*)
  Harness/                        (existing — BashTool.swift, FileTool.swift)
  InspectSidecarTool.swift        (existing — a sibling of Harness/, not inside it)
  PythonTools/                    (existing — Python-driven calibration tools)
  Learning/                       (existing — record-outcome / playbook / escalate tools)
  QuantizeTool.swift              (existing)
  ConvertTool.swift               (existing)
  EvaluateTool.swift              (existing)
  EvolveTool.swift                (existing)
  ...
```

The split per material (one file per `*Tools.swift`) follows the existing per-material convention (`SheetTools` already does this; `DocTools`, `SlideTools`, `DrawingTools` extend it). The cross-cutting tools get their own files (`MaterialsTools`, `LifecycleTools`) so the tool surface is one-file-per-concern.

The per-material files are the natural landing point for the per-material P0/P1/P2 components: `DocTools` lands alongside `SectionStore` + `FieldController` + `RevisionController`; `SlideTools` lands alongside `MasterPageStore` + `TransitionStore` + `AnimationStore`; `DrawingTools` lands alongside `LayerStore` + `TransformController` + `SnapEngine`. The wave loop can ship a component + its tools in the same wave (the tool is the agent-facing half of the component).

## 16. Open questions for the architect

These are the items I'd like the architect's call on before the rollout begins. None are blocking the capability map; they shape the tool surface.

1. **Tool count budget per wave.** A 16-tool `DocTools` file is a lot for one PR. The recommendation is a per-phase split: P0 lands 4-5 read tools, P1 lands the write tools, P2 lands the advanced. The architect's call: split per phase, or ship per material in a single wave?
2. **Cross-material diff.** `materials_diff` between a Doc and a Sheet is fundamentally not a thing. Should the tool fail with a clear error, or hide the cross-kind cases from the agent? Recommendation: fail with a clear error; the agent is then prompted to pick two materials of the same kind.
3. **`lifecycle_trash` tier.** A `tier2` confirmation is the audit's default for destructive actions. A non-empty Doc / Sheet / SlideDeck / Drawing being trashed is a `tier3` event per the audit's paradox-1. The architect's call: `tier2` for all trash, or `tier3` for non-empty materials?
4. **Tool result size cap.** A 500-slide deck read by `slide_read` (no filter) is a multi-MB payload. The existing `ToolResult` has no size cap. The architect's call: cap at, say, 1 MB with a `?limit` parameter; or trust the agent loop's token budget to truncate?
5. **Custom tools.** Some users will want to add their own tools (per the existing harness pattern at `Tools/Harness/`). Should the cross-cutting `materials_*` tools be extensible by users, or is the surface closed? Recommendation: closed surface; users add their own tools via the existing harness.
6. **Receipt query API.** `materials_receipts(materialID:, limit:)` is the simple read. A more complex query (filter by tool name, by tier, by date range) is a separate tool. The architect's call: ship the simple read first, or design the full query API up front?

## 17. What this doc is NOT

- **Not an implementation guide.** The doc sketches the *shape* of the tool API. The implementation lands in waves alongside the corresponding tesseracore components (per the expansion plan's P0/P1/P2 list).
- **Not a replacement for `studio-expansion-plan.md`.** The expansion plan is the architecture / capability map; this doc is the agent-facing API on top of that architecture. They are read together.
- **Not a final word on every tool.** The doc enumerates ~65 tools at the *categorization* level. Each wave adds the per-tool arguments + result shape + test contract in a wave brief.
- **Not a backwards-compatibility story.** `SheetTools.swift` is the only existing tool file under `Productivity/Materials/` (the four product-material surfaces this doc extends); there is nothing THERE to be backwards-compatible with, even though ~41 other `TesseraTool` conformers already exist elsewhere in the tree for calibration/harness/learning. The plan is to evolve `SheetTools` in place (no `_v2`); the existing 3 tools stay; the new 16 (corrected count, §2) ride the same `TesseraTool` protocol.
