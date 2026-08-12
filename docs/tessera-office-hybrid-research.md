# Tessera Office Hybrid Research

Date: 2026-08-11
Author: Mavis (for Julian Torres, sole architect)
Purpose: Evaluate native Swift approaches for editing Word/Excel/PowerPoint
formats inside Tessera Studio Mac, while preserving receipt-chain integrity.

---

## Executive Summary

The hybrid approach is viable, but it is not a simple win. The landscape
splits cleanly by surface:

| Surface | Library viability | Verdict |
|---|---|---|
| Docs (Word) | che-word-mcp (Swift), DocX, RichEditor | MOST VIABLE - pure Swift OOXML available |
| Sheets (Excel) | CoreXLSX (read), XlsxReaderWriterSwift (read/write via C), XLKit | PARTIALLY VIABLE - no pure Swift write engine |
| Slides (PowerPoint) | None | NOT VIABLE - no Swift library exists |

The key insight from the research: the hardest problem is not reading OOXML,
it is (a) formula evaluation for Sheets, and (b) the OOXML write/save
round-trip that preserves fidelity. The GenOffice approach (dirty-block
patching) is the architecture to emulate for all three surfaces.

---

## 1. Docs (Word / OOXML)

### 1.1 Pure Swift OOXML Manipulation

The landscape has changed significantly. There are now two viable Swift-native
approaches:

**che-word-mcp (ildunari/che-word-mcp-eng)**

- GitHub: https://github.com/ildunari/che-word-mcp-eng
- The first pure Swift library that directly manipulates Office Open XML.
- No external runtime, no Node.js, no Python. Pure Swift 6.1+ on macOS 13+.
- 149 MCP tools covering: create/open/save documents, paragraph CRUD,
  text formatting (bold/italic/color/font), table insertion, style application,
  header/footer, comments, footnotes.
- Produces valid Office Open XML documents.
- Architecture: unzip -> parse document.xml -> mutate -> rezip.
- Limitation: primarily a document content editor. Does it handle styles.xml,
  numbering.xml, comments.xml with full fidelity? The docs show the core
  CRUD operations but the edge-case coverage (track changes, mail merge fields,
  revision marks) is unclear from public docs.
- Availability: pre-built universal binary or build from source.

**DocX (shinjukunian/DocX)**

- GitHub: https://github.com/shinjukunian/DocX
- Converts NSAttributedString to .docx. Read/write.
- Handles: paragraphs, headings, images, styles, page definitions.
- One-way conversion: NSAttributedString -> docx. Does NOT read an existing
  docx and parse it back into an NSAttributedString for editing.
- Use case: generate docx from attributed strings. NOT a full editor.
- Installation: SPM, CocoaPods.

**RichEditor (will-lumley/RichEditor)**

- GitHub: https://github.com/will-lumley/RichEditor
- WYSIWYG NSTextView subclass. Bold, italic, underline, strikethrough,
  font selection, text alignment, color, highlight, links, bullet points.
- Export to HTML. Not OOXML.
- Use case: the SwiftUI/AppKit editor surface, not the file format layer.

### 1.2 The Dirty-Block Patching Architecture (GenOffice Pattern)

The most important architectural finding of this research:

**GenOffice** (Genspark, open source Apache 2.0, https://github.com/genspark/genoffice)
implements the docx-engine as follows:

1. Archive the original .docx by hash and never modify it.
2. Parse top-level elements of word/document.xml into a block tree.
3. Each block is anchored by a docxIndex + original XML slice.
4. Editing happens in a TipTap streaming editor with dirty tracking.
5. On save, only dirty blocks are converted to OOXML fragments,
   referencing existing styles only, and spliced back into the original
   document.xml.
6. Untouched blocks keep their original bytes.
7. Every other zip entry is copied verbatim.

This means: opening and saving never breaks layout in Word. The original
file's exact bytes are preserved except where the user actually edited.
This is the correct architecture for Tessera because:

- It preserves round-trip fidelity for the OOXML export.
- It means Tessera's internal format can be the edited block tree,
  and the .docx is always a fresh render from the block tree + original
  zip entries.
- Receipt chains: the dirty-block patches are the mutations. Each patch
  is a mutation event that feeds the receipt signer.

### 1.3 Pandoc Round-Trip Assessment

From the Pandoc issue tracker and changelog:

**What Pandoc preserves in docx round-trip:**
- Document structure: headings, paragraphs, lists, tables (basic)
- Inline formatting: bold, italic, underline
- Images (preserved as relationships)
- Hyperlinks
- Basic styles (via --reference-doc with custom styles)

**What Pandoc loses in docx round-trip:**
- Tracked changes: comments on track-change insertions are silently dropped.
  Word reports errors on round-tripped files with tracked changes + comments.
- Table cell alignment: explicitly disabled in round-trip tests.
- Complex styles: custom style definitions not in the reference.docx.
- Footnotes with complex formatting.
- Field codes (cross-references, page references, TOC fields).
- Mail merge fields.
- Revision marks.
- Document protection settings.
- Macros.

**Assessment:** Pandoc is viable as an import filter for simple documents
(>90% of the market). It is NOT viable as the canonical internal format
for documents that need round-trip fidelity (legal, academic, corporate
documents with tracked changes and comments). Tessera's receipt-chain
architecture actually helps here: a document imported via Pandoc is
clearly a "Pandoc-imported" document with a known fidelity boundary.

### 1.4 Recommended Approach for Docs

Phase 1: Keep the current block-based AST editor (TesseraEditorView in
.document mode) as the internal editing surface. Use che-word-mcp as
the import/export bridge for .docx files. On import: unzip .docx ->
extract document.xml -> convert to Tessera's DocumentAST. On export:
convert DocumentAST back to OOXML -> rezip. Receipts attach to the
AST mutation events.

Phase 2 (if needed): Adopt the dirty-block patching pattern from
GenOffice. Archive the original .docx, edit in the block tree,
patch only dirty blocks back. This gives true round-trip fidelity.

---

## 2. Sheets (Excel / SpreadsheetML)

### 2.1 Pure Swift Spreadsheet Libraries

**CoreXLSX (CoreOffice)**

- GitHub: https://github.com/CoreOffice/CoreXLSX
- READ-ONLY parser. Maps XLSX XML structure to Swift structs via XMLCoder.
- Uses ZIPFoundation for decompression.
- Does NOT write .xlsx files.
- Use case: read .xlsx for import, graph indexing, analytics ETL.

**XlsxReaderWriterSwift (BRAOfficeDocumentPackage)**

- GitHub: mehulparmar4ever/XlsxReaderWriterSwift
- Read/Write via libxlsxwriter C library (brew install).
- Features: create/read cells, styles, images, comments, tables,
  formulas (via libxlsxwriter), CSV/TSV import.
- Limitation: wrapper around C libxlsxwriter. This is FFI - but
  libxlsxwriter is a well-maintained, permissively-licensed C library.
  The architect's "gives me the ick" for c2pa-rs FFI was about a
  complex Rust safety boundary; a well-tested C library is a different
  risk profile. Still: architectural decision required.

**XLKit**

- GitHub: https://github.com/TheAcharya/XLKit
- Modern Swift 6.0 library for creating/manipulating Excel .xlsx files.
- Fluent, chainable API.
- Async/sync save operations.
- CoreXLSX-based validation.
- Read + write.
- No formula evaluator (just writes formula strings).
- Available via SPM.

**Formualizer**

- GitHub: https://github.com/psu3d0/formualizer
- Rust spreadsheet engine with Python (PyO3) and WASM bindings.
- 400+ Excel-compatible functions.
- MIT/Apache-2.0 licensed.
- Incremental dependency tracking, undo/redo, dynamic arrays.
- THIS IS THE KEY FINDING for formula evaluation.
- If Tessera wants Excel-compatible formula evaluation natively:
  Formualizer is the Rust core. No pure Swift formula evaluator exists.
  The WASM target runs in the browser. The PyO3 target requires Python.
  For pure Swift: would need a Swift bridge to the WASM module or
  the Python target.

### 2.2 The Spreadsheet Formula Problem

The formula evaluation problem is the hardest unsolved piece for a native
Swift spreadsheet engine:

- Excel formulas are not a formally specified language. There is no
  official grammar.
- The community has reverse-engineered Excel formula parsing via large
  corpus analysis (XLParser: 99.99% coverage on 8.5M real-world formulas).
- XLParser is C#/NET only. Not reusable.
- Formualizer (Rust) is the most complete open-source implementation.
- Handsontable HyperFormula (TypeScript) is the most mature JS option.
- No pure Swift formula evaluator exists.

Options:
1. Bridge to Formualizer via Swift-for-Rust (cbingham/rust-calling-swift)
   or call the Python WASM module from Swift.
2. Write a formula evaluator from scratch (12-18 months for Excel parity).
3. Delegate formula evaluation to Python/Pandoc bridge: evaluate in Python
   via openpyxl + formulas package, return results to Swift.
4. Use pre-computed values: for display, show cached formula results.
   For editing, treat formulas as strings until save/export.

### 2.3 The Grid UI Problem

Native macOS grid editors:
- NSTableView: possible for simple grids, but selection model is
  row-oriented, not cell-oriented. Hard to implement multi-cell selection,
  drag-fill, column resize.
- Custom NSView: fully in control. The correct approach.
  Requires: cell layout, text rendering, selection management,
  keyboard navigation, clipboard, scroll management.

No existing open-source Swift grid editor component was found.
The correct reference is Apple's Numbers: a custom view with
CAShapeLayer for grid lines, NSTextField per visible cell (reused,
not created per cell), and a custom gesture recognizer for selection.

### 2.4 Recommended Approach for Sheets

Phase 1: Tessera Sheets as a "graph-connected spreadsheet" -
not an Excel replacement. CoreXLSX for import, XLKit for export,
grid view over the tabular data without formula evaluation.
Formula strings stored as strings; evaluation deferred to export time
via the Python bridge (openpyxl + formulas). Receipts attach to
cell mutation events.

Phase 2: Add Formualizer via WASM bridge for live formula evaluation.
This is a meaningful engineering investment (~3-6 months for v1 parity
with common formulas). The constitutional architecture supports this:
formula evaluation is a pure function, not a graph mutation, so it
does not need its own receipt layer.

---

## 3. Slides (PowerPoint / PPTX)

### 3.1 State of the Landscape

No pure Swift PPTX library exists. The landscape:

- python-pptx: Python, read/write, not suitable for direct Swift bridging.
- Aspose.Slides FOSS: .NET/C++/Java/Python, MIT license. No Swift.
- AsposeSlidesCloud: Cloud SDK for Swift, but requires Aspose cloud service.
- GenOffice pptx-engine: TypeScript, in-house PPTX parse/render/edit engine.
  Covers: masters, charts, cropping, ink, text shaping via HarfBuzz.
  MIT license. NOT Swift, but the architecture is instructive.

PPTX is structured as:
- ZIP archive
- ppt/presentation.xml: slide order, notes, themes
- ppt/slides/slideN.xml: one file per slide
- ppt/slideLayouts/slideLayoutN.xml
- ppt/slideMasters/slideMasterN.xml
- ppt/theme/themeN.xml
- ppt/notesSlides/notesSlideN.xml

The GenOffice approach (same as docs): archive original, parse slide XML,
edit only dirty elements, patch back.

### 3.2 Recommended Approach for Slides

Phase 1: Tessera Slides as a presentation viewer + light editor.
Use python-pptx via the existing Python bridge for import/export.
Swift renders the slide list and slide content for display.
Editing: text replacement within slide shapes only; structural edits
(add/remove slides, change layout) deferred to Python bridge.

Phase 2: Port the GenOffice pptx-engine from TypeScript to Swift.
The engine is the hardest part (HarfBuzz text shaping, OOXML
manipulation, slide layout resolution). Estimate: 6-12 months for
full PPTX editor parity.

---

## 4. Pages/Numbers/Keynote Internal Format

Apple's iWork apps (Pages, Numbers, Keynote) use a proprietary format:

**Pages v5+**: .pages package containing Index.zip with .iwa (iWork Archive)
binary files. Document.iwa, DocumentStylesheet.iwa, Metadata.iwa,
AnnotationAuthorStorage.iwa. Not OOXML.

**Numbers**: Same .iwa architecture. Tables in Tables/DataList.iwa.
Formulas in CalculationEngine.iwa.

**Keynote**: Same .iwa architecture.

**Critical finding**: Apple does NOT use OOXML internally.
They use a proprietary binary (iWork Archive) format.
Their OOXML export (Pages -> .docx, Numbers -> .xlsx, Keynote -> .pptx)
is a one-way conversion, not round-trip capable.

Implication: Tessera cannot replicate Pages/Numbers/Keynote's internal
format. Tessera's internal format must be either:
(a) Custom Swift-native format (like Tessera's existing DocumentAST)
(b) OOXML DOM (direct manipulation of the ZIP/XML structure)

Option (a) is what Tessera already does for Docs.
Option (b) is what GenOffice does and what che-word-mcp enables.

For Sheets and Slides, Tessera should follow option (b) as the
OOXML-native approach: edit the OOXML DOM directly, not a custom format.

---

## 5. Apple NSDocument / Document Architecture

### 5.1 NSDocument for Office Formats

macOS has deep Office format support via built-in converters:
- Word documents (.docx, .doc) open in TextEdit via AppleDocFormat.
- Excel spreadsheets (.xlsx, .xls) open in Numbers.
- PowerPoint presentations (.pptx, .ppt) open in Keynote.

**QuickLook previews**: macOS generates previews for Office files
WITHOUT Office installed, via the built-in converter pipeline.
Tessera can use QLPreviewPanel to show previews in-app.

**NSDocument integration for Office files**:
- Subclass NSDocument.
- Override readFromURL:ofType:error: to call the system converter
  (NSDocumentController handles this automatically for UTI-declared types).
- Register UTTypes: public.docx, public.xlsx, public.pptx as readable.
- For Tessera's native format: export a custom UTType (com.tessera.document,
  com.tessera.sheet, com.tessera.slide) and declare it as writable.

**NSFileWrapper for incremental saving**:
- For .docx/.xlsx/.pptx (ZIP packages): use NSFileWrapper's
  filePackage reading/writing. This enables saving only the changed
  internal file, not the entire ZIP. CRITICAL for large documents.
- The system handles ZIP coordination automatically via NSFileCoordinator.

**Auto Save and Versions**:
- NSDocument's auto-save integrates with macOS Versions automatically.
- Tessera's receipt chain is complementary: NSDocument's version history
  is the system-level undo; Tessera's receipts are the cryptographically
  signed audit trail. They coexist without conflict.

### 5.2 UTType Registration

For Tessera to appear as an editor for Office files:

```swift
// TesseraDocument.swift
extension UTType {
    static let tesseraDoc = UTType(exportedAs: "com.tessera.document")
    static let tesseraSheet = UTType(exportedAs: "com.tessera.sheet")
    static let tesseraSlide = UTType(exportedAs: "com.tessera.slide")
    // Imported (readable) types:
    static let tesseraOfficeImport: [UTType] = [
        .docx, .xlsx, .pptx,
        .rtf, .plainText
    ]
}
```

Info.plist needs CFBundleDocumentTypes declaring:
- Tessera native types: role=Editor, handler rank=Owner
- Office types: role=Viewer (Tessera can open but not claim to own .docx)

---

## 6. Tessera-Specific Constraints Applied

### 6.1 Receipt Chain Integrity

The receipt chain requirement affects the architecture materially:

**Document mutations must be traceable to OOXML patches.**

If Tessera uses the dirty-block patching model:
- Each patch (mutated block/element) is a mutation event.
- The receipt signer receives the patch as the mutation payload.
- The patch is applied to the OOXML DOM.
- The signed receipt certifies the exact XML change.
- On export: the OOXML DOM is re-serialized.

This means: the canonical format IS the OOXML DOM for imported files,
not Tessera's DocumentAST. Tessera's AST is the rendering/interaction layer.
Receipts attach to OOXML mutations.

**For newly created documents (not imported)**:
- Tessera's DocumentAST is the canonical format.
- On first export: render AST to OOXML.
- Receipt records the "initial document creation" mutation.
- Subsequent edits follow the dirty-block patching model.

### 6.2 The Constitutional Architecture Constraint

Prism's "one canonical authority" principle applies:
- For an imported .docx: canonical = OOXML DOM (the original file is
  preserved, patches are the mutations).
- For a new Tessera-native document: canonical = DocumentAST.
- The graph layer (TesseraDataLayer, GraphModel) owns the entity
  relationships. The document format is the content layer below it.
- These two layers must not fight: OOXML mutations update the AST
  render simultaneously.

### 6.3 No Egress / No API Keys

All libraries identified in this research are self-hosted, open-source,
offline-capable. No cloud services required. che-word-mcp, CoreXLSX,
XLKit, Formualizer, GenOffice - all run locally.

---

## 7. Recommended Hybrid Architecture

### 7.1 Per-Surface Summary

**Docs:**
- Internal canonical: OOXML DOM (dirty-block patched)
- Original .docx archived by hash (never modified)
- Edit via che-word-mcp's OOXML manipulation API
- Tessera's DocumentAST is a render of the OOXML DOM
- Export: serialize OOXML DOM to .docx
- Receipts: one per dirty-block patch

**Sheets:**
- Internal canonical: Tessera's sheet model (tabular data + formula strings)
- Formula evaluation via Python bridge (openpyxl + formulas)
- Long-term: Formualizer WASM bridge
- Grid UI: custom NSView
- Export via XLKit
- Receipts: one per cell mutation

**Slides:**
- Internal canonical: slide model (slide list + shape tree)
- Import/export via python-pptx bridge
- Long-term: Swift port of GenOffice pptx-engine
- Receipts: one per slide mutation

### 7.2 File Type Matrix

| Format | Import path | Internal canonical | Export path |
|---|---|---|---|
| .docx | che-word-mcp OOXML parse | OOXML DOM | che-word-mcp OOXML serialize |
| .doc | NSDocument converter -> .docx | OOXML DOM | che-word-mcp serialize |
| .xlsx | CoreXLSX parse | Sheet model | XLKit write |
| .xls | NSDocument converter -> .xlsx | Sheet model | XLKit write |
| .pptx | python-pptx bridge | Slide model | python-pptx bridge |
| .ppt | NSDocument converter -> .pptx | Slide model | python-pptx bridge |
| .rtf | NSAttributedString(rtf:) | DocumentAST | NSAttributedString(rtf:) |
| .md | Pandoc | DocumentAST | Pandoc |

### 7.3 Receipt Chain Mapping

```
User action
    |
    v
[Editor Surface] --> [OOXML / Sheet / Slide model]
    |                     |
    |                     v
    |               [Dirty block / cell / slide]
    |                     |
    v                     v
[ReceiptSigner.sign(patch)] --> [persistReceipt()]
    |
    v
[C2PA manifest for docs] or [graph_receipts entry for sheets/slides]
```

---

## 8. Open Questions

1. che-word-mcp maturity: 149 tools is extensive, but is it battle-tested?
   No public bug tracker activity visible. Recommend: build a test suite
   against the 50 most common .docx structural patterns before committing.

2. Dirty-block patching complexity: GenOffice's approach requires a streaming
   editor with dirty tracking. Tessera's existing block-based editor may
   already have dirty tracking infrastructure. Audit before designing.

3. Formula evaluator: Formualizer WASM in Swift. Has anyone successfully
   run Formualizer WASM from Swift via JavaScriptCore? This is unexplored
   territory. The Python bridge is the safe fallback; WASM is the optimization.

4. Slide rendering: SwiftUI/AppKit rendering of slide shapes without
   PowerPoint layout engine. This is the hardest UI problem. Keynote's
   layout engine is years of engineering. Start with text-only slides first.

5. Pages/Numbers/Keynote files: users will try to open .pages/.numbers/
   .keynote files. Tessera should detect these, warn that they are
   Apple-proprietary, and offer to convert to OOXML via the system
   converter if available.

---

## 9. C++ Libraries and LibreOffice (Supplementary)

This section was added after the architect asked about C++ libraries and
LibreOffice SDK as alternatives to pure Swift.

### 9.1 C++ OOXML Libraries

**minidocx** (C++20, MIT)

- GitHub: https://github.com/totravel/minidocx
- Create and manipulate .docx files. Pure C++20, no external Office needed.
- Cross-platform (Windows, Linux, macOS). Header-only, CMake build.
- Covers: paragraphs, headings, tables, styles, images, comments.
- Designed for document generation from templates.
- Limitation: create-only? The README says "manipulating" but it's primarily
  oriented toward programmatic document generation, not editing existing files.
  Does it handle reading and round-tripping an existing .docx with full fidelity?
  Unclear from docs.
- Verdict: good for generating Tessera-native documents as .docx. Not a
  replacement for editing existing Office files.

**OpenXLSX** (C++, MIT)

- GitHub: https://github.com/troldal/OpenXLSX
- Full read/write/create/modify for .xlsx files. Pure C++.
- Dependencies: PugiXML, Zippy (miniz wrapper), Boost.Nowide.
- Tested on macOS (Clang), Linux (GCC), Windows (MSVC).
- Last GitHub release is from 2021 but repo is active — pull from main.
- Features: cell values, formulas (as strings), styles, named ranges,
  worksheet management, data validation.
- No formula evaluator — just reads/writes formula strings.
- This is actually the BEST pure C++ option for XLSX. It's more capable than
  XLKit (which is Swift-native but less feature-complete). For Tessera's
  Linux target, OpenXLSX is viable.
- The FFI question: this is C++, not Rust. A Swift-to-C++ bridge is simpler
  than Swift-to-Rust. Swift can call C++ via Objective-C++ or a C shim layer.
- Verdict: STRONG candidate for Sheets. Bridge via C shim or direct Swift-C++
  interop. More feature-complete than any Swift alternative.

**xlnt** (C++11, BSD)

- GitHub: https://github.com/tfussell/xlnt
- Cross-platform C++ library for reading/writing .xlsx files.
- Less active than OpenXLSX. Similar capability range.
- Verdict: alternative to OpenXLSX. OpenXLSX is more actively maintained.

**libxlsxwriter** (C, BSD)

- GitHub: https://github.com/jmcnamara/libxlsxwriter
- Write-only. Cannot read existing .xlsx files.
- Very high quality, well-tested. Used in production.
- Excellent for: generate reports, charts, formatting, formulas (as strings).
- Cannot be used for import. Use CoreXLSX for reading.
- Verdict: good for export only. Already identified in research as the C
  library behind XlsxReaderWriterSwift.

**ooxmlsdk** (Rust, MIT)

- GitHub: https://github.com/kaiseryamu/ooxmlsdk-rs
- Rust library for reading, writing, and round-tripping .docx, .xlsx, .pptx.
- Generated Rust schema types from ECMA-376. Full OOXML fidelity.
- This is the Rust answer to the OOXML problem. If Tessera ever adds a
  Rust component (or if the architect changes his mind on FFI), this is the
  library to use.
- SPM-compatible? Not directly — Cargo only.
- Verdict: interesting for Linux app where Rust FFI is acceptable.

**MoonLeaf** (MoonBit, Apache 2.0)

- GitHub: https://github.com/vectie/moonleaf
- Pure MoonBit (a new language targeting WASM). Cross-platform OOXML viewer
  and lightweight editor.
- Supports .docx, .xlsx, .pptx for viewer + lightweight exact-text-replacement edits.
- Not production-ready yet (v0.1.0). Interesting to watch.
- Verdict: not actionable for Tessera today.

### 9.2 LibreOffice (The Heavy But Comprehensive Answer)

**LibreOffice headless CLI** (the practical path)

LibreOffice ships with a headless conversion mode that:
- Reads any format LibreOffice can open (.docx, .doc, .xlsx, .xls, .pptx,
  .ppt, .rtf, .odt, .pages, .numbers, .keynote, and more)
- Writes any format LibreOffice can export
- Runs as a spawned Process from Swift, no GUI required

Key commands:

```bash
# DOCX to XLSX
/Applications/LibreOffice.app/Contents/MacOS/soffice \
  --headless \
  "-env:UserInstallation=file:///tmp/LibreOffice_Tessera_${USER}" \
  --convert-to xlsx:Calc\ Office\ Open\ XML \
  --outdir /tmp/tessera-lo-out \
  /path/to/input.docx

# XLSX to DOCX
/Applications/LibreOffice.app/Contents/MacOS/soffice \
  --headless \
  "-env:UserInstallation=file:///tmp/LibreOffice_Tessera_${USER}" \
  --convert-to docx:MS\ Word\ 2007\ XML \
  --outdir /tmp/tessera-lo-out \
  /path/to/input.xlsx

# PPTX to PDF (for preview)
/Applications/LibreOffice.app/Contents/MacOS/soffice \
  --headless \
  "-env:UserInstallation=file:///tmp/LibreOffice_Tessera_${USER}" \
  --convert-to pdf:impress_pdf_Export \
  --outdir /tmp/tessera-lo-out \
  /path/to/input.pptx
```

**Critical flags:**
- `-env:UserInstallation=file:///tmp/LibreOffice_Tessera_${USER}`: REQUIRED.
  Without it, headless conversion silently fails if any LibreOffice GUI instance
  is running. This flag creates an isolated profile per conversion.
- The `--outdir` must exist and be writable.
- Filter strings must use exact names: `xlsx:Calc\ Office\ Open\ XML`,
  `docx:MS\ Word\ 2007\ XML`, `pptx:Impress\ MS\ PowerPoint\ 2007\ XML`.

**Known filter strings:**

| Conversion | Filter |
|---|---|
| DOCX (export) | `docx:MS Word 2007 XML` |
| XLSX (export) | `xlsx:Calc Office Open XML` |
| PPTX (export) | `pptx:Impress MS PowerPoint 2007 XML` |
| PDF (Writer) | `pdf:writer_pdf_Export` |
| PDF (Calc) | `pdf:calc_pdf_Export` |
| PDF (Impress) | `pdf:impress_pdf_Export` |
| ODT (export) | `odt:writer8` |

**LibreOffice download/install:**

On macOS: download from https://www.libreoffice.org/download/download/
(~300MB). Installs to /Applications/LibreOffice.app.
The `soffice` binary is at:
`/Applications/LibreOffice.app/Contents/MacOS/soffice`

For Tessera: bootstrap on first use. If the user has LibreOffice installed
(ask at onboarding), use it. If not, offer to install it or fall back
to pure Swift alternatives.

**Fidelity assessment:**

LibreOffice's import/export fidelity for Office formats is:
- "very good for typical office documents" (converterer.com benchmark)
- Complex Word layouts (nested tables, floating objects, VBA macros,
  legacy .doc features) can shift.
- Apple .pages / .numbers / .keynote: LibreOffice can open and convert these.
  This means Tessera can offer "import Pages/Numbers/Keynote" via LibreOffice,
  not just Office formats.
- The round-trip: LO -> Tessera (via LO export to intermediate format) ->
  Tessera edit -> LO import -> LO export: fidelity is determined by
  the intermediate format choice. Using .docx/.xlsx as the intermediate
  means 2 conversion steps, each with potential fidelity loss.

**LibreOffice SDK (UNO API — the heavy path)**

LibreOffice has a full C++ SDK (UNO: Universal Network Objects) for
programmatic document manipulation. This is what the LibreOffice IDE
and extensions use. It allows:
- Opening and modifying documents in memory
- Applying complex formatting
- Running macros
- Full automation

However: the SDK requires linking against the LibreOffice installation,
the API is complex (COM-style UNO bridges), and it's ~10x more engineering
than the headless CLI. Not recommended for Tessera unless the goal is
deep LibreOffice integration.

**Unoserver** (the modern replacement for unoconv)

- GitHub: https://github.com/unoconv/unoserver
- Starts a persistent LibreOffice listener process.
- `unoconverter` connects to it for conversion without reloading LO.
- 50-75% less CPU overhead vs. spawning soffice per conversion.
- pip-installable: `pip install unoserver`
- Use case: high-volume conversion scenarios.
- For Tessera: overkill for personal productivity use. The headless CLI
  spawn is fine.

### 9.3 Revised File Type Matrix (with C++ and LibreOffice)

| Format | Import path | Internal canonical | Export path |
|---|---|---|---|
| .docx | che-word-mcp (Swift) OR LO headless | OOXML DOM / DocumentAST | che-word-mcp (Swift) OR LO headless |
| .doc | LO headless -> .docx | OOXML DOM | LO headless |
| .xlsx | CoreXLSX (read-only, Swift) OR OpenXLSX (C++) | Sheet model | OpenXLSX (C++) OR XLKit (Swift) OR LO headless |
| .xls | LO headless -> .xlsx | Sheet model | LO headless |
| .pptx | python-pptx bridge OR LO headless | Slide model | python-pptx bridge OR LO headless |
| .ppt | LO headless -> .pptx | Slide model | LO headless |
| .pages | LO headless -> .docx | OOXML DOM | N/A (Apple-proprietary) |
| .numbers | LO headless -> .xlsx | Sheet model | N/A (Apple-proprietary) |
| .keynote | LO headless -> .pptx | Slide model | N/A (Apple-proprietary) |
| .rtf | NSAttributedString(rtf:) | DocumentAST | NSAttributedString(rtf:) |
| .md | Pandoc | DocumentAST | Pandoc |

### 9.4 Revised Recommendations

The C++ and LibreOffice options materially change the calculus:

**For Sheets:** OpenXLSX (C++) is more capable than any Swift-native
alternative. Tessera can bridge to it via a thin C shim. The C shim
is architecturally clean: C is the universal FFI baseline, Swift speaks
C natively. This is different from Rust FFI (which was "icky" due to
safety boundary complexity) — C FFI is well-understood, no special
bridging needed, and OpenXLSX is a pure C++ library.

**For full-fidelity import/export:** LibreOffice headless is the
comprehensive fallback. It handles every format LibreOffice can open,
including Apple's .pages/.numbers/.keynote. Tessera can bootstrap
LibreOffice on first use, fall back to pure Swift for .docx/.xlsx,
and offer LO as the "maximum compatibility" path.

**For the architect's FFI comfort:** The key distinction is:
- C FFI (OpenXLSX): well-understood, stable ABI, no ownership/safety
  complexity. Swift can call C functions directly.
- Rust FFI (ooxmlsdk): the "ick" was about a complex Rust safety boundary
  (c2pa-rs). Pure C++ (OpenXLSX) with C shim is categorically different.

The practical path forward for Tessera:
1. Docs: che-word-mcp (Swift) as primary, LO headless as fallback
2. Sheets: OpenXLSX (C++ via C shim) + CoreXLSX (Swift, read) + LO headless (full fidelity)
3. Slides: python-pptx bridge as primary, LO headless for full-fidelity round-trip

---

## 10. LibreOffice SDK Deep Dive (UNO API)

This section covers the LibreOffice SDK in depth, separate from the headless
CLI. It is the world-class option for document processing.

### 10.1 What UNO Actually Is

UNO (Universal Network Objects) is LibreOffice's component model — the
equivalent of COM for Microsoft Office. It provides:

- A language-agnostic interface definition language (IDL)
- A binary type system for cross-process calls
- A socket-based inter-process bridge
- Generated bindings for C++, Java, and (via OLE Automation bridge) .NET

The architecture:
- LibreOffice runs as a server process (or embeds in-process)
- External clients connect via UNO bridge (socket to localhost)
- Method calls are serialized over the wire
- LibreOffice dispatches to the appropriate component (Writer, Calc, Impress)
- Responses serialize back

This is why the headless CLI (`--convert-to`) works: it's a special case
where the conversion is triggered by command-line dispatch rather than
a programmatic API call. The SDK gives you the programmatic layer.

### 10.2 Two Modes: Embedded vs. Server

**Server mode (recommended for Tessera):**

```bash
soffice --headless --invisible \
  --accept="socket,host=127.0.0.1,port=2003,tcpNoDelay=1;urp;StarOffice.ServiceManager"
```

This starts a persistent LibreOffice process that listens for UNO connections.
Tessera's Swift code connects via the UNO bridge and can:
- Open/create documents
- Manipulate them in-memory
- Save and close
All without re-spawning the process.

The listener approach is critical: spawning soffice per operation costs
~240MB baseline + document load time. A persistent listener amortizes this
across all conversions. The headless CLI (`--convert-to`) is the
spawn-per-call model; UNO server mode is the persistent model.

**Embedded mode (harder, not recommended for Tessera):**
Link against LibreOffice's C++ libraries directly. Complex, platform-dependent,
fragile. Not worth the engineering cost.

### 10.3 What the UNO API Can Do (The Full Surface)

From the SDK examples and developer guide:

**Writer (text documents):**
- Open/create/save documents (all formats: .docx, .doc, .odt, .rtf)
- Text cursor navigation: move through document by paragraph, word, character
- Insert, delete, replace text
- Apply character formatting: bold, italic, underline, color, font, size
- Apply paragraph formatting: alignment, spacing, indent, numbering
- Create and apply named styles (style families: paragraph, character, frame)
- Insert tables: set cell values, cell formatting, row/column operations
- Insert text frames, graphic objects, OLE embeds
- Insert bookmarks, hyperlinks
- Insert text fields: page numbers, dates, author, cross-references
- Create and populate indexes and tables of contents
- Headers, footers, footnotes, endnotes
- Mail merge (data source connection + field insertion)
- Change tracking (insert/delete marks)
- Comments (annotations)
- Spell checker access
- Form controls

**Calc (spreadsheets):**
- Open/create/save spreadsheets (all formats: .xlsx, .xls, .ods)
- Cell navigation, value insertion, cell formatting
- Formula support: insert formula strings, trigger re-calculation
  (LibreOffice's Calc engine, which IS the formula evaluator)
- Named ranges, data validation
- Chart creation and modification
- Sheet management: add/remove/reorder sheets
- Pivot tables (basic support)
- Import from database sources

**Impress (presentations):**
- Open/create/save presentations (all formats: .pptx, .ppt, .odp)
- Slide management: add, remove, reorder slides
- Shape manipulation: insert, position, resize shapes
- Text inside shapes
- Master slides and slide layouts
- Transitions and animations (basic)
- Speaker notes

**Universal:**
- Document conversion between any two formats LibreOffice can read/write
- Printing
- Document metadata
- Password protection

### 10.4 The Formula Evaluator Nobody Talks About

LibreOffice Calc has a full, mature formula evaluation engine.
It supports 500+ functions including:
- Math: SUM, AVERAGE, IF, AND, OR, COUNT, MAX, MIN, ROUND, etc.
- Financial: IRR, NPV, PMT, PV, FV, etc.
- Lookup: VLOOKUP, HLOOKUP, INDEX, MATCH, XLOOKUP
- Dynamic arrays (LibreOffice Calc 7.4+): FILTER, SORT, UNIQUE, SEQUENCE
- Date/time, statistical, text, information functions

This engine is the SAME engine that evaluates formulas when you open
a spreadsheet in LibreOffice. When Tessera opens an .xlsx via the UNO API,
LibreOffice Calc evaluates the formulas natively. This eliminates the
need for Formualizer, HyperFormula, or any other formula bridge for
read-only or display purposes.

For Tessera's use case: connecting via UNO to a Calc instance means
formula evaluation is free and native. The formula results can be read
back via the API.

### 10.5 Real-World Fidelity Benchmarks

From the 2023-2024 Document Interoperability Test Suite (ISO/IEC 29500):

**Safe for daily use (>=99% fidelity):**
- .docx with standard paragraph/character styles, tables (<=100 rows),
  embedded PNG/JPEG images, tracked changes (non-nested)
- .xlsx with formulas up to SUMIFS, VLOOKUP, basic data validation
- .pptx with static layouts, bullet lists, embedded video (no morph/zoom)

**Requires manual verification (82-89% fidelity):**
- Excel pivot tables (column headers shift on refresh)
- Word mail merge with complex IF fields
- PowerPoint animations triggered by click sequences
- Documents with custom TrueType fonts not installed system-wide

**Avoid in production workflows (<=41% fidelity):**
- Excel dynamic arrays (FILTER, SEQUENCE, XLOOKUP with spill ranges)
- Word equation editor objects (OMML)
- PowerPoint 3D models
- Documents with Microsoft-specific add-ins (Power Query, Equation Editor 3.0)

**Tracked changes and comments:**
- LibreOffice preserves tracked changes and comments in OOXML round-trip
- The fidelity comparison study notes: "positions, formatting, or author
  metadata can shift" — not lost, but shifted
- For Tessera's receipt chain: this means OOXML comments are read/written
  by the UNO API, but the exact byte positions may differ from Word's

**What LibreOffice cannot do:**
- Run VBA macros (it can LOAD them for analysis, but not execute)
- Handle Word's SmartArt (converted to grouped shapes, not editable)
- Handle embedded OLE objects from other apps (shows placeholder)
- Full Word document protection features
- Excel's Power Query connections
- Exact pixel-perfect reproduction of Word's rendering (LibreOffice
  renders its own layout, not Word's)

**The flip side:** LibreOffice's own ODF formats (ODT/ODS/ODP) are
WYSIWYG — "What You See Is What You Get. Any document being edited
looks the same when saved as a PDF or when printed." Microsoft Office
does NOT guarantee this. For Tessera users who switch to ODF as their
primary format, LibreOffice SDK delivers perfect fidelity.

### 10.6 Performance and Resource Characteristics

**Memory footprint:**
- Baseline (empty document loaded): ~240MB
- Scales with document complexity
- Recommendation: don't run multiple concurrent instances
- Memory is NOT released until process exits (in-process memory management)

**Threading model:**
- LibreOffice is SINGLE-THREADED per instance
- One request processes at a time
- Multiple concurrent requests need a process pool (N instances for N
  parallel documents)
- NOT thread-safe to share one instance across threads
- The UNO bridge is thread-safe (multiple threads can send requests),
  but LibreOffice dispatches them sequentially

**Latency:**
- First connection: ~2-5 seconds (process startup)
- Persistent listener: ~50-200ms per API call (round-trip serialization)
- Document open: ~1-3 seconds for a 50-page document
- Formula evaluation trigger: near-instant for simple formulas,
  1-5s for complex spreadsheets

**Process pool strategy for Tessera:**
- Start 2-4 persistent LibreOffice listeners at app launch
- Round-robin requests across the pool
- Each listener handles one document at a time
- This gives parallel processing without memory bloat

### 10.7 How Tessera Would Use the UNO API

**Architecture:**

```
Tessera Studio Mac
    |
    |-- Swift UNO Bridge (Process pool: 2-4 soffice listeners)
    |       |
    |       |-- XComponentLoader: open/create documents
    |       |-- XTextDocument: Writer operations
    |       |-- XSpreadsheetDocument: Calc operations
    |       |-- XPresentationDocument: Impress operations
    |       |-- XStorable: save to any format
    |
    |-- Tessera Document Model (receipt-tracked)
    |       |
    |       |-- OOXML DOM (from UNO import)
    |       |-- Tessera AST (render layer)
    |       |-- Receipt chain (each UNO mutation = one receipt)
    |
    |-- Graph layer
            |-- Hybrid search
            |-- Entity linking
            |-- DuckDB analytics ETL
```

**Receipt chain with UNO:**
- Each user action in the editor translates to a sequence of UNO API calls
- Each batch of UNO calls (one user action) = one receipt mutation payload
- Example: user changes a paragraph style
  - UNO: get paragraph cursor, apply style via XParagraphProperties
  - Receipt: { op: "apply_paragraph_style", style: "Heading1", cursor: "..." }
- On save: XStorable.storeToURL() serializes the document
- The saved file is verified against the receipt chain

**Import pipeline:**
1. User drops .docx -> Tessera receives it
2. Swift UNO bridge calls XComponentLoader.loadComponentFromURL()
3. UNO returns XTextDocument interface
4. Traverse document tree via XTextContent/XTextCursor
5. Build Tessera's AST from UNO's text structure
6. Each AST node is annotated with UNO cursor position
7. Build OOXML DOM from UNO's underlying XML (via XModel/XDocument)
8. Compute initial receipt: { op: "imported_from_docx", format: "..." }
9. Discard UNO reference (document closes, memory freed)

**Export pipeline:**
1. User triggers save/export
2. Tessera's OOXML DOM is serialized to temp file
3. Swift UNO bridge calls XStorable.storeToURL() with format filter
4. LibreOffice writes to target format
5. Optional: verify output against expected structure
6. Receipt: { op: "exported_to_docx", format: "..." }

### 10.8 SDK Installation and Distribution

**On macOS:**
- Download from https://www.libreoffice.org/download/download/
- Installs to /Applications/LibreOffice.app (~800MB)
- SDK is included in the full download
- Headers at: LibreOffice.app/Contents/Resources/udk/
- OR download SDK separately (~200MB)

**For Tessera's distribution:**
- Option A: Bundle LibreOffice in Tessera's app bundle (~800MB, large)
  - Legal: MPL 2.0 allows proprietary bundling
  - Pro: works offline, no external dependency
  - Con: app size increase
- Option B: Detect system-installed LibreOffice first
  - Check /Applications/LibreOffice.app
  - Check ~/Applications/LibreOffice.app
  - If not found: prompt user to install or offer pure Swift alternative
  - Pro: smaller app bundle
  - Con: user may not have it installed
- Option C: Download on first use (like MacPostgresBootstrap)
  - Download LibreOffice.pkg from libreoffice.org
  - Silent install to ~/Applications/LibreOffice.app
  - Idempotent via marker file
  - This is the cleanest UX: no prompt at install, first use triggers download

### 10.9 The Enterprise Story

For enterprise users, LibreOffice SDK is the answer to "how do we process
thousands of documents without paying per-seat Office licenses":

- No per-seat license cost
- Server-side document processing: headless, scalable, containerizable
- Full format coverage: OOXML, ODF, legacy Office formats, Apple formats
- Community-driven: LibreOffice 25.8, active development, TDF-backed
- No vendor lock-in: MPL 2.0
- Collabora Online (LibreOffice-based) enables collaborative web editing
  with the same rendering engine as the desktop

For Tessera: if enterprise procurement is in scope, the LibreOffice SDK
is the path to "world-class productivity" that doesn't require Microsoft
Office subscriptions. Tessera becomes the front-end; LibreOffice is the
processing engine. The constitutional receipt chain sits on top of both.

---

## 12. Vendor Architecture: Embedded CPython + In-Process UNO

**Decision (2026-08-11): Build-time bundling. The stripped headless LibreOffice
subset is downloaded and extracted by `setup-libreoffice-vendor.sh` when preparing
a release build. It is copied into the `.pkg` installer at packaging time.
Not committed to git. No runtime download. No git submodule. Deterministic.**

### License Compatibility

LibreOffice is licensed under **MPL 2.0** (Mozilla Public License 2.0).
MPL 2.0 explicitly permits binary redistribution with three requirements:

1. **Attribution notice** — a written notice that MPL 2.0 governs the included code
2. **License text** — the MPL 2.0 text itself (or a URL to it)
3. **Source availability** — for modified Covered Files; unmodified LO source is
   available at libreoffice.org/download/source/

Tessera's **PolyForm Noncommercial** license does not conflict with bundling LO.
PolyForm governs only the Tessera code itself; it imposes no restrictions on
what other works are distributed alongside it. LO is a separate work under its
own license. The `.pkg` installer includes:

- `Contents/Resources/Legal/LibreOffice-NOTICE.txt` — MPL attribution
- `Contents/Resources/Legal/MPL-2.0.txt` — full license text

### Architecture

```
Tessera Studio (Swift, macOS app)
  |
  +-- EmbeddedPythonBridge (Swift, owns Python interpreter lifecycle)
  |     PYTHONHOME = LibreOffice.app/Contents/Frameworks/
  |                   LibreOfficePython.framework/Versions/3.12/
  |     URE_BOOTSTRAP = vnd.sun.star.pathname:.../libuuresolverlo.dylib
  |     UNO_PATH     = .../Contents/MacOS/
  |     PYTHONPATH   = .../Contents/Resources/
  |                     + .../lib/python3.12/
  |                     + .../lib/python3.12/site-packages/
  |     LO_UNO_MODE  = inprocess
  |
  +-- Bundled CPython 3.12 (LibreOfficePython.framework, 84MB)
  |     Loaded via dlopen of LibreOfficePython binary
  |     Python C API available via @_silgen_name declarations
  |
  +-- tessera_lo_service.py (Python, runs on GIL thread)
  |     import uno  -- bootstraps pyuno C extension
  |     uno.getComponentContext() -- UNO runtime in-process
  |     context.ServiceManager -- full UNO service registry
  |     desktop = smgr.createInstanceWithContext("com.sun.star.frame.Desktop")
  |     desktop.loadComponentFromURL(...) -- open/edit/save documents
  |
  +-- pyuno.so (C extension, in bundled Resources/)
  |     Loads libmergedlo.dylib (URE C++ runtime)
  |     URE_BOOTSTRAP -> libuuresolverlo.dylib -> discovers UNO registry
  |     NO soffice subprocess -- UNO runtime in-process
  |
  +-- libmergedlo.dylib (URE C++ UNO runtime, in bundled Frameworks/)
        Handles all document operations: Writer, Calc, Impress
```

### Why no subprocess?

The traditional approach runs `soffice --accept` as a subprocess and connects
via a socket bridge (`uno.connect("socket,host=localhost,port=N")`).
This adds ~240MB baseline memory per soffice instance and requires a process
pool manager. With in-process UNO via URE_BOOTSTRAP, the memory overhead
is shared with the app process and there's no inter-process communication.

URE_BOOTSTRAP tells pyuno's C extension where to find `libuuresolverlo.dylib`,
which in turn locates the UNO registry files (types.rdb, services.rdb) bundled
with LibreOffice. This bootstraps the full UNO C++ runtime inside the embedded
Python interpreter — no socket, no subprocess.

### Bundle Layout

The bundle is built at build-time, not vendored in the repo:

```
TesseraStudio/
  artifacts/
    LibreOffice-Headless/          <- built by setup-libreoffice-vendor.sh
      LibreOffice.app/             (stripped, ~350MB)
        Contents/
          MacOS/soffice            (entry binary, version check only)
          Frameworks/              (libmergedlo, URE, Python.framework)
            LibreOfficePython.framework/
              Versions/3.12/
                LibreOfficePython   (CPython 3.12 dylib)
          Resources/
            uno.py, unohelper.py, pythonloader.py
            python/, basic/, autocorr/
            en*.lproj/            (English locales only)
        NOTICE.txt                  (MPL 2.0 attribution)
  scripts/
    setup-libreoffice-vendor.sh    (build-time: download, strip, extract)
  packaging/
    release-build.sh                (orchestrates full build + package pipeline)
```

### Install Location in Distributed App

```
TesseraStudio.app/
  Contents/
    Resources/
      LibreOffice-Headless/         (copied here by release-build.sh)
        LibreOffice.app/
        NOTICE.txt
      Legal/
        LibreOffice-NOTICE.txt      (MPL attribution)
        MPL-2.0.txt                (license text)
```

### Discovery Priority (runtime)

1. **App bundle** (`Contents/Resources/LibreOffice-Headless/LibreOffice.app`):
   ships with the `.pkg` installer. Deterministic, version-controlled via
   `setup-libreoffice-vendor.sh` version tag.
2. **System** (`/Applications/LibreOffice.app`): user-managed fallback.
   Less preferred — version is not under Tessera's control.

`LibreOfficeBootstrap` checks bundle path first; `isValidInstall()` verifies
`soffice`, `libmergedlo.dylib`, and `LibreOfficePython.framework` are present.
No runtime download.

### Build-Time Bundler (`setup-libreoffice-vendor.sh`)

Run once when preparing a release build (before packaging):

```bash
./scripts/setup-libreoffice-vendor.sh

# The script:
# 1. Downloads LibreOffice_${LO_VERSION}_MacOS_${ARCH}.dmg (from documentfoundation.org)
# 2. Mounts, copies Contents/{MacOS,Frameworks,Resources,PkgInfo}
# 3. Strips Resources/ to: uno.py, pythonloader, basic/, autocorr/, en*.lproj
# 4. Strips Frameworks/ to: Python.framework, libmergedlo, libuuresolverlo,
#    libuno_sal, libuno_cppu*, libuno_cppuhelper*, libbass*
# 5. Writes artifacts/LibreOffice-Headless/NOTICE.txt (MPL attribution)
# 6. Fast path if already extracted at correct version
# Result: ~350MB vs 800MB full install
```

### Release Build Pipeline (`packaging/release-build.sh`)

One command to build the complete distributable:

```bash
./packaging/release-build.sh
# Steps:
#  1. setup-libreoffice-vendor.sh  (download + strip LO)
#  2. xcodebuild                   (build TesseraStudio.app)
#  3. cp LibreOffice-Headless/     (embed into app Contents/Resources/)
#  4. productbuild                 (produce signed .pkg)
```

Flags: `--skip-lo` (use existing bundle), `--skip-sign` (ad-hoc), `--identity <name>`.

### Swift Entry Points

```swift
// 1. Discover bundle (checks Contents/Resources/ first, then /Applications/)
let loRoot = try await LibreOfficeBootstrap.bootstrap()

// 2. Build environment
let env = LOEnvironment(loRoot: loRoot, mode: .inProcess)
let bridge = try EmbeddedPythonBridge(environment: env)

// 3. Bootstrap in-process UNO
let result = try bridge.call(
    module: "tessera_lo_service",
    function: "bridge_bootstrap_uno",
    args: []
)

// 4. Open and edit a document
let openResult = try bridge.call(
    module: "tessera_lo_service",
    function: "bridge_open",
    args: ["/path/to/doc.docx", "auto"]
)
// openResult.handle is used for subsequent operations

// 5. Get text from a Writer document
let text = try bridge.call(
    module: "tessera_lo_service",
    function: "bridge_writer_get_text",
    args: [handle]
)
```

### Concurrency Model

The GIL is held only during Python calls. Swift concurrency is unaffected.
For concurrent document operations, LOManager distributes requests across a
pool of `EmbeddedPythonBridge` instances, each with its own embedded Python
interpreter (one per soffice-equivalent UNO runtime instance).

### References

- URE bootstrap: https://api.libreoffice.org/docs/ure/html/namespacemembers_func_.html
- pyuno: https://api.libreoffice.org/docs/idl/overview html/files.html
- URE_BOOTSTRAP: https://wiki.documentfoundation.org/Development/URE
- LibreOffice install paths: https://wiki.documentfoundation.org/Installation
- MPL 2.0: https://www.mozilla.org/en-US/MPL/2.0/

---

## 11. Sources

- che-word-mcp: https://github.com/ildunari/che-word-mcp-eng
- DocX: https://github.com/shinjukunian/DocX
- RichEditor: https://github.com/will-lumley/RichEditor
- CoreXLSX: https://github.com/CoreOffice/CoreXLSX
- XLKit: https://github.com/TheAcharya/XLKit
- XlsxReaderWriterSwift: https://github.com/mehulparmar4ever/XlsxReaderWriterSwift
- Formualizer: https://github.com/psu3d0/formualizer
- HyperFormula: https://github.com/handsontable/hyperformula
- GenOffice: https://github.com/genspark/genoffice
- Apple Pages format: https://pxlnv.com/blog/exploring-the-new-iwork-for-mac-file-formats/
- Pandoc tracked changes issues: https://github.com/jgm/pandoc/issues/9833
- Pandoc round-trip fidelity: https://github.com/jgm/pandoc/issues/4301
- SwiftUI document architecture: https://www.createwithswift.com/crafting-document-based-apps-in-swiftui/
- Apple document compatibility: https://support.apple.com/en-us/105050
- minidocx (C++ OOXML): https://github.com/totravel/minidocx
- OpenXLSX (C++ XLSX): https://github.com/troldal/OpenXLSX
- xlnt (C++ XLSX): https://github.com/tfussell/xlnt
- libxlsxwriter (C XLSX write): https://github.com/jmcnamara/libxlsxwriter
- ooxmlsdk-rs (Rust OOXML): https://github.com/kaiseryamu/ooxmlsdk-rs
- MoonLeaf (MoonBit OOXML): https://github.com/vectie/moonleaf
- LibreOffice headless cheatsheet: https://www.converterer.com/blog/libreoffice-headless/
- LibreOffice --convert-to reference: https://help.libreoffice.org/latest/he/text/shared/guide/start_parameters.html
- unoserver (LibreOffice listener): https://github.com/unoconv/unoserver
- unoconv: https://github.com/unoconv/unoconv
- office-headless Python: https://github.com/scivision/office-headless
- LibreOffice on Docker: https://oneuptime.com/blog/post/2026-02-08-how-to-run-libreoffice-in-docker-for-document-conversion/view
- LibreOffice SDK: https://api.libreoffice.org/
