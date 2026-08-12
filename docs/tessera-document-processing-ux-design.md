# Tessera Studio: World-Class Document Processing
## Architecture & UX Design

Date: 2026-08-11
Author: Mavis (for Julian Torres, sole architect)
Purpose: Close the UX gap between Tessera's world-class engine and a world-class editing experience. Evaluate libraries, define the editing UX for Docs/Sheets/Slides, and produce an implementation roadmap.

---

## 1. Where We Stand

### Engine (world-class)
- In-process UNO via `EmbeddedPythonBridge` + `tessera_lo_service.py`
- TextKit 2 block AST editor for internal format
- Knowledge graph + hybrid search + receipt chains
- C2PA signing for document receipts
- Build-time bundled LibreOffice (~350MB stripped)

### Editing UX (Phase 2 — gaps)
| Surface | Status | Gap |
|---|---|---|
| Docs (internal) | Block AST editor — solid | No `.docx` native editing |
| Docs (OOXML) | LO import/export only | Format conversion on open/save; fidelity loss |
| Sheets | Grid UI — functional | No formula engine |
| Slides | Empty canvas | No editor at all |
| Linking | UUID-paste v1 | No graph-context panel |
| Tables | Placeholder | Phase 3 |

**The core problem:** Users open a `.docx`, it gets converted to the block AST, they edit in a different format than what they saved. The format boundary is the UX cliff.

---

## 2. Library Landscape

### Docs (Word)

| Library | Language | License | Key capability | Fit |
|---|---|---|---|---|
| che-word-mcp | Swift | MIT | 233 OOXML tools, byte-preserving save, dirty tracking | BEST FIT |
| ooxml-swift | Swift | MIT | Typed OOXML model, dirty overlay save, preserve-by-default | Powers che-word-mcp |
| DocX | Swift | MIT | Read/create .docx, basic formatting | Read-only for complex docs |
| SwiftDocX | Swift | MIT | Basic read/write, new files | Lacks track changes, styles |
| python-docx | Python | MIT | Full Python ecosystem | Requires Python runtime |
| python-docx-template | Python | MIT | Template-based | Requires Python runtime |

**Decision: che-word-mcp (MIT) + ooxml-swift (MIT).** Pure Swift, no external runtime, byte-preserving round-trip (document survives where it was untouched), 233 tools cover every Word feature. Powers 233 MCP tools — the same API surface maps directly to Tessera's document operations.

### Sheets (Excel)

| Library | Language | License | Key capability | Fit |
|---|---|---|---|---|
| **Formularizer** | Rust/PyO3/WASM | MIT/Apache-2.0 | 400+ functions, Arrow-backed, incremental dep graph, undo/redo | BEST FIT |
| HyperFormula | TypeScript | GPLv3 (copyleft!) | 400+ functions, headless spreadsheet | GPLv3 blocks Tessera (PolyForm NC + copyleft incompatibility) |
| SoulverCore | Swift | Commercial | Natural language math | Paid, no XLSX I/O |
| Expression | Swift | MIT | Math expression parser | No functions, no XLSX |
| Formualizer (PyO3) | Rust/Python | MIT/Apache-2.0 | Same engine as above, Python wheels | Tessera embeds CPython 3.12 already |

**Decision: Formularizer (MIT/Apache-2.0).** MIT/Apache-2.0 is compatible with Tessera's PolyForm Noncommercial distribution. Three runtimes — Rust, Python (PyO3), WASM. Tessera's embedded CPython 3.12 can drive it via `pip install formualizer`, or via Rust CGO. Incremental dependency graph means single-cell edits don't recompute everything. Deterministic mode (injectable clock/RNG) is perfect for receipt-traceable agent operations.

**Avoid: HyperFormula (GPLv3).** Copyleft GPLv3 is incompatible with distributing Tessera as a closed-source product. Even "free for non-commercial" doesn't help — Tessera is commercial.

### Slides (PowerPoint)

| Library | Language | License | Key capability | Fit |
|---|---|---|---|---|
| python-pptx | Python | MIT | Full PPTX creation/editing | Requires Python runtime |
| pptx-templates | Python | MIT | Template-based PPTX | Requires Python runtime |
| SwiftPptx | Swift | MIT | Basic PPTX read/write | Limited feature set |

**Decision: Extend `tessera_lo_service.py` + SwiftPptx hybrid.**
For editing: `python-pptx` via embedded Python (already available). For reading: SwiftPptx or the LO bridge. Impress/OOXML slides are shape-tree documents — the dirty-block pattern from Docs doesn't map well here without significant engineering. Pragmatic path: use the existing LO Python bridge for full PPTX editing, add a Swift surface layer.

### Tables (OOXML embedded tables, not spreadsheets)

OOXML tables are already handled by `ooxml-swift`'s table tools. No additional library needed.

### Formula rendering in Docs

Math equations: LibreOffice Math (via `tessera_lo_service.py`) or pure Swift via `mmarkdown` / `Down` with MathJax/KaTeX rendering in WebKit.

---

## 3. The Editing Architecture

### Three modes

```
User opens a document
    |
    +-- .tessera file (internal block AST)
    |       Direct edit in block AST editor
    |       Save = write block AST to disk
    |
    +-- .docx file (OOXML)
    |       Open: che-word-mcp reads OOXML -> block AST
    |       Edit: block AST editor (same UX as .tessera)
    |       Save: che-word-mcp writes dirty changes back to OOXML (byte-preserving)
    |
    +-- .xlsx file (OOXML)
            Open: Formularizer parses XLSX -> grid model
            Edit: SheetGridView + Formularizer formula engine
            Save: Formularizer writes XLSX (preserves formulas, formats)
```

The key insight: the block AST editor is the *universal editing surface*. `.docx`, `.tessera`, and eventually `.md` all flow through the same editor. The library layer (che-word-mcp, Formularizer) handles format translation at the seam — it is invisible to the user.

### che-word-mcp integration pattern

```
TesseraEditorView (block AST editor)
    |
    +-- DocEditorViewModel (owns DocumentAST)
            |
            +-- OODocumentSession (wraps che-word-mcp session)
                    |
                    +-- Session lifecycle: open -> edit -> dirty-track -> save
                    +-- Two sub-modes:
                    |   1. IMPORT mode: .docx -> block AST (read-only mirror)
                    |   2. SYNC mode: bidirectional edits (che-word-mcp dirty tracking)
                    |
                    +-- On save: che-word-mcp writes OOXML, block AST is the working copy
```

`oodocument_session` from che-word-mcp v1.17.0 gives you:
- `open_document(path)` — opens and tracks session state
- `get_document_session_state` — dirty tracking (what cells changed)
- `finalize_document` — flush dirty changes back to file
- `shutdown` — clean close

This is the exact dirty-block pattern from the research doc, implemented.

### Formularizer integration pattern

```
SheetGridView (SwiftUI grid)
    |
    +-- SheetEditorViewModel (owns grid data + Formularizer workbook)
            |
            +-- Formularizer workbook (Rust engine via PyO3)
            |   |
            |   +-- Cell values (Arrow-backed)
            |   +-- Formula AST (dependency graph)
            |   +-- Undo/redo changelog
            |   |
            |   +-- on cell edit: set_value() -> incremental recompute
            |   +-- on formula change: set_formula() -> dirty propagation
            |
            +-- Persists to .xlsx via Formularizer I/O
            +-- Receives .xlsx via Formularizer load
```

### Slides integration pattern

```
SlidesListView -> SlideCanvasView (SwiftUI)
    |
    +-- SlideEditorViewModel (owns slide deck)
            |
            +-- tessera_lo_service.py (Impress bridge via embedded Python)
            |   |
            |   +-- impress_get_slides() -> slide metadata + shapes
            |   +-- Per-shape: read content, edit, write back
            |
            +-- python-pptx for full PPTX editing via embedded Python
            +-- SwiftPptx for Swift-native slide metadata editing
```

---

## 4. UX User Journey

### Opening a document

```
1. User opens file picker (Cmd+O)
   → Supported: .tessera, .docx, .xlsx, .pptx, .md, .txt

2. File type detected by extension
   → .tessera: direct load to DocumentAST
   → .docx:   che-word-mcp import -> DocumentAST (with session tracking)
   → .xlsx:   Formularizer load -> Sheet model
   → .pptx:   LO bridge import -> SlideDeck model
   → .md/.txt: parse to DocumentAST

3. Edit in the same editor surface regardless of file type

4. Save (Cmd+S)
   → .tessera: write DocumentAST
   → .docx:   che-word-mcp finalize_document() -> OOXML write
   → .xlsx:   Formularizer save -> XLSX write
   → .pptx:   python-pptx save via embedded Python
```

**The promise to the user:** "Open anything, edit everything, save back to the format you opened." No format awareness required from the user.

### The graph context panel (linking v2)

While editing any document, a right-side panel shows:
- **Backlinks**: other documents that link to this one
- **Forward links**: things this document links to
- **Material receipts**: the operation log for this document
- **Graph neighbors**: documents with shared entities/people/topics

This is what bridges the Notion/Obsidian gap — editing in a polished surface while the graph works invisibly in the background.

```
+--[Doc Editor]-------------------------+--[Graph Panel]--+
|                                       | BACKLINKS (3)    |
| # My Document                         |  → Project Plan  |
|                                       |  → Meeting Notes |
| This connects to [[Project Plan]]     |                  |
| and [[Q3 Budget]]                     | FORWARD LINKS    |
|                                       |  → Q3 Budget     |
| [block content...]                    |                  |
|                                       | MATERIAL RECEIPTS|
| [block content...]                    |  ✓ Opened 9:41am |
|                                       |  ✓ Edit block    |
+---------------------------------------+-- Save: 9:58am  |
```

### Sheets specific UX

- **Formula bar**: shows the formula for the selected cell (e.g. `=SUM(A1:A10)`)
- **Auto-complete**: function name autocomplete as user types `=`
- **Dependency highlight**: click a cell, highlight all cells it depends on (blue) and all cells depending on it (green)
- **Error states**: `#DIV/0!`, `#REF!` shown inline with red background
- **Named ranges**: visible in a sidebar, auto-complete in formula bar

### Slides specific UX

- **Slide thumbnail strip**: left rail, click to select
- **Canvas**: WYSIWYG shape/text editor on the selected slide
- **Slide master**: per-deck style defaults (fonts, colors)
- **Presenter notes**: bottom drawer per slide

---

## 5. Implementation Roadmap

### Phase A: Docs native editing (che-word-mcp integration)
**Priority: HIGH — this is the biggest UX cliff**

1. Add `che-word-mcp` as a Swift Package Manager dependency
   - Clone `github.com/PsychQuant/che-word-mcp` (MIT)
   - Build as a local SPM package
   - OR: vendor the OOXML core (`ooxml-swift`) directly — che-word-mcp is the MCP wrapper around it

2. Create `OODocumentSession.swift`
   - Wraps che-word-mcp session lifecycle
   - `importOOXML(path)` -> DocumentAST (che-word-mcp reads -> convert to blocks)
   - `exportOOXML(ast, path)` -> che-word-mcp writes from blocks
   - Dirty tracking: diff block AST changes -> che-word-mcp apply changes

3. Wire into `DocEditorViewModel`
   - If file extension is `.docx`: use OODocumentSession
   - Else: use existing direct DocumentAST load/save

4. **Verification**: Open a complex `.docx` (with tables, track changes, headers), edit in block editor, save, re-open — verify no content lost.

### Phase B: Sheets formula engine (Formularizer)
**Priority: HIGH — turns a placeholder grid into a real spreadsheet**

1. Embed Formularizer via Python (PyO3 wheels)
   - `pip install formualizer` inside the embedded CPython env
   - OR: Rust CGO via a separate Swift <-> Rust bridge
   - Pre-bake the pip install into `setup-libreoffice-vendor.sh` step

2. Create `FormularizerBridge.swift`
   - Wraps `formualizer` Python API
   - `loadWorkbook(path)` -> grid model
   - `setCell(sheet, row, col, value/formula)` -> incremental recompute
   - `evaluateCell(sheet, row, col)` -> computed value
   - `saveWorkbook(path)` -> XLSX write

3. Wire into `SheetEditorViewModel`
   - Replace current cell storage with Formularizer workbook
   - Formula bar reads/writes Formularizer formula strings
   - Dependency highlighting via Formularizer's `collect_references()`

4. **Verification**: Load an XLSX with SUMIFS, VLOOKUP, XLOOKUP formulas, edit input cells, verify outputs recompute correctly.

### Phase C: Graph context panel (linking v2)
**Priority: MEDIUM — closes the Notion/Obsidian gap**

1. `GraphContextPanel` SwiftUI view
2. `HybridSearchConnector` wired to panel — backlinks + forward links per document UUID
3. `MaterialReceiptPanel` — last N receipts for this document, collapsible
4. Slide-in from right edge (Cmd+\), toggle with toolbar button

### Phase D: Slides full editor
**Priority: MEDIUM — completes the Office surface**

1. Extend `tessera_lo_service.py` with Impress operations
   - `impress_get_slide_content(handle, slideIndex)` -> shapes + text
   - `impress_set_slide_content(handle, slideIndex, shapes)` -> write back
   - `impress_insert_slide(handle, index, layout)` -> new slide
   - `impress_delete_slide(handle, index)` -> remove slide

2. Create `SlideEditorViewModel` + `SlideCanvasView`
   - Shape-based canvas (rectangles, ellipses, text, images)
   - Per-shape editing via double-click
   - Slide master editor

3. PPTX save via `python-pptx` in embedded Python

### Phase E: Tables and equations (Phase 3 completion)
**Priority: LOW — already handled by ooxml-swift tools**

1. Wire `insert_table`, `render_table_placeholder` in DocEditorView
2. Math equation rendering via WebKit + KaTeX

---

## 6. Build-Time Dependency Wiring

All new dependencies are bundled at build time — no runtime downloads, no API keys.

```
setup-libreoffice-vendor.sh (existing)
  + downloads LO DMG
  + strips to ~350MB

NEW: setup-document-deps.sh
  + pip install formualizer (into embedded Python env)
  + pip install python-pptx (into embedded Python env)
  + clone/checkout che-word-mcp (build as local SPM package)
  + ooxml-swift (build as local SPM package)

packaging/release-build.sh (existing)
  + Step 1a: setup-document-deps.sh
  + Step 1b: setup-libreoffice-vendor.sh
  + ...
```

For Formularizer + python-pptx: extend the embedded Python's `site-packages` with a pre-baked wheel directory. This avoids the pip download step at build time — wheels are cached locally.

---

## 7. License Compliance Summary

| Dependency | License | Used by | Compatible? |
|---|---|---|---|
| che-word-mcp | MIT | Docs OOXML editing | YES |
| ooxml-swift | MIT | Powers che-word-mcp | YES |
| Formularizer | MIT/Apache-2.0 | Sheets formula engine | YES |
| python-pptx | MIT | Slides PPTX editing | YES |
| HyperFormula | GPLv3 | NOT USED (copyleft conflict) | NO |
| LibreOffice | MPL 2.0 | Engine (existing) | YES (MPL binary redistribution) |

---

## 8. Key Decisions

1. **Block AST is the universal editing surface.** All file types (.tessera, .docx, .xlsx, .pptx) flow through the same editor. Format translation happens at the open/save seam, invisible to the user.

2. **che-word-mcp for Docs (MIT).** Pure Swift, byte-preserving OOXML round-trip, dirty tracking, 233 tools cover every Word feature. The `oodocument_session` API gives us the exact session model we need.

3. **Formularizer for Sheets (MIT/Apache-2.0).** Arrow-backed, 400+ functions, incremental dependency graph, MIT/Apache-2.0. **HyperFormula (GPLv3) is rejected** — copyleft is incompatible with commercial distribution. Formularizer's Python wheels run in Tessera's existing embedded CPython env.

4. **python-pptx via embedded Python for Slides.** Pragmatic — Impress/OOXML slides are complex shape trees. python-pptx gives full editing capability without building a Swift-native shape engine. Swift surface wraps the Python layer.

5. **Graph context panel closes the Notion/Obsidian gap.** Inline editing in a polished surface + graph context panel gives Notion's editing experience with Obsidian's graph intelligence. This is the "world-class" differentiator.

6. **Everything bundled at build time.** formualizer, python-pptx as pre-baked wheels. che-word-mcp/ooxml-swift as local SPM packages. No runtime pip install, no network on first launch.
