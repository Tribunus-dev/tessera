# Phase 4 — Importers and Exporters for the Tessera productivity surface

## Context

Tessera Studio is a privacy-first macOS + iOS app. Phase 1 of the productivity surface is on `feat/prod-foundations` (committed, tests pass). It shipped the Block AST, Mutation API, Receipt infrastructure, ReceiptUndoManager, two-cursor data model, chat queue data model, and `DocumentStore`.

The full productivity spec is at `docs/tessera-productivity-design.md` (1115 lines, on branch `feat/productivity-spec`). Sections §10 (Importers) and §11 (Exporters) are the canonical source. **Read them first.**

Your job is Phase 4: the importer/exporter pipeline. Files in (DOCX, XLSX, PPTX, PDF, EML/MSG, MBOX, HTML, MD, anything via Pandoc) → Block AST → graph_entity. And reverse: Block AST → files out, plus integration with the system share sheet (NSSharingServicePicker on macOS, UIActivityViewController on iOS).

## Working environment

- Main checkout: `/Users/user/Developer/GitHub/tessera`
- Branch off `feat/prod-foundations`: `git fetch . && git worktree add worktrees/prod-import-export -b feat/prod-import-export feat/prod-foundations`
- New Python code under `tools/tessera/importers/` and `tools/tessera/exporters/`
- New Swift code under `TesseraStudio/Sources/TesseraCore/Productivity/ImportExport/`
- Tests under `tools/tessera/tests/test_importers.py`, `tools/tessera/tests/test_exporters.py`, and `TesseraStudio/Tests/TesseraCoreTests/Productivity/ImportExport/`
- Per AGENTS.md: no push, no PR. `Assisted-by: MiniMax`.

## Phase 4 deliverables

### 1. The importer pipeline (Python)

A Python CLI (`tessera import <file>`) that converts external files into the Block AST (JSON), emits a `graph_entity`, and appends a `graph_receipt`.

#### Format support (v1)

| Format | Library | Notes |
|---|---|---|
| `.docx` | `python-docx` | Paragraphs, headings, lists, tables, images, footnotes |
| `.xlsx` | `openpyxl` | Cell values, formulas (as text), basic formatting, sheets as separate ASTs |
| `.pptx` | `python-pptx` | Slides as separate ASTs, text frames, basic shapes |
| `.pdf` | `weasyprint` (render) + `pdftotext` (extract) | Two-pass |
| `.eml`, `.msg` | `mailbox` stdlib + `email` stdlib | Headers + body + attachments |
| `.mbox` | `mailbox` stdlib | Apple Mail export, multiple messages per file |
| `.html`, `.mhtml` | `beautifulsoup4` | Cleaned HTML |
| `.md` | `markdown-it-py` | CommonMark + GFM |
| Any other | **Pandoc** | Swiss-army bridge |

#### Architecture

```
tools/tessera/importers/
  __init__.py
  cli.py                    - CLI entry point
  pipeline.py               - orchestration
  format_detector.py        - extension + magic bytes
  parsers/
    docx.py
    xlsx.py
    pptx.py
    pdf.py
    email.py                - .eml, .msg, .mbox
    html.py
    markdown.py
    pandoc.py               - for everything else
  ast_builder.py            - intermediate JSON → Block AST
  data_layer_client.py      - HTTP client to data layer
  receipt_emitter.py        - graph_receipt + graph_entity + ast
  tests/
    test_docx.py
    ...
    fixtures/
      sample.docx
      sample.xlsx
      sample.pptx
      sample.pdf
      sample.eml
      sample.mbox
      sample.html
      sample.md
```

Pipeline: `format_detector.detect(path)` → `parsers.<format>.parse(path)` (intermediate JSON) → `ast_builder.build()` (Block AST) → `data_layer_client.create_entity()` (graph_entity) → `receipt_emitter.append_receipt()` (graph_receipt, logs the import). Each step is idempotent and emits its own receipt.

**Tests:** for each format — parse fixture → intermediate JSON → AST → validate schema; emit entity + receipt; round-trip parse → build → parse; batch import (`tessera import <dir>`); failed parses logged, no entity created.

### 2. The exporter pipeline (Python)

CLI: `tessera export <entity_id> --format <fmt>`.

| Format | Method |
|---|---|
| `.pdf` | PDFKit (macOS, via Swift shim) or weasyprint (cross-platform) |
| `.docx` | Pandoc |
| `.xlsx` | openpyxl |
| `.pptx` | python-pptx |
| `.html` | Pandoc |
| `.md` | markdown-it-py |
| `.eml` | mailbox stdlib |

Architecture mirrors the importer: `tools/tessera/exporters/` with `cli.py`, `pipeline.py`, `builders/<format>.py`, `ast_to_intermediate.py`, `data_layer_client.py`, `receipt_emitter.py`. Export goes through `TesseraEgressGuard` and logs as a `receipt_type = 'export'`.

**Tests:** for each format — load AST fixture → intermediate → file → validate; expected output fixture; byte-for-byte match for deterministic formats; structural match for DOCX/XLSX/PPTX.

### 3. Swift-side integration

```swift
public actor TesseraImporter {
    public init(pythonExecutable: URL = TesseraCLIPath.default)
    public func importFile(at url: URL) async throws -> UUID
    public func importDirectory(at url: URL) async throws -> [UUID]
    public func importDragAndDrop(urls: [URL]) async throws -> [UUID]
}

public actor TesseraExporter {
    public init(pythonExecutable: URL = TesseraCLIPath.default)
    public func export(entityID: UUID, to format: ExportFormat, outputURL: URL) async throws
    public func export(entityID: UUID, shareWith: ShareTarget) async throws
}
```

Spawns the Python CLI as a subprocess, streams stdout/stderr. Uses existing `TesseraCLIPath` resolver.

**Tests:** spawn Python CLI for known fixture, parse stdout for entity ID; failure modes (Python not found, file not found) handled.

### 4. System share sheet (NSSharingServicePicker / UIActivityViewController)

```swift
public struct ShareTarget {
    public var name: String
    public var icon: NSImage?
    public var accepts: Set<ExportFormat>
    public var handler: (URL) -> Void
}

public actor ShareSheetCoordinator {
    public func presentShareSheet(for entityID: UUID, from view: NSView) async throws
    public func availableShareTargets() -> [ShareTarget]
}

public struct SlackExportTarget {
    public var webhookURL: URL
    public var channel: String?
    public var username: String?
    public func post(document: TesseraDocument) async throws
}
```

Webhook URL stored in Keychain. Slack target posts as mrkdwn.

**Tests:** presentShareSheet invokes the right system API (mocked); Slack post formats mrkdwn and POSTs (mocked); webhook URL in Keychain, not UserDefaults.

### 5. Data layer integration via HTTP API

The Python CLI talks to a small HTTP API exposed by the Swift app. Add:

- `TesseraStudio/Sources/TesseraStudioMac/API/ImportExportAPI.swift` — `/v1/import` and `/v1/export` endpoints
- `TesseraStudio/Sources/TesseraStudioMac/API/DataLayerHTTPClient.swift` — reusable HTTP client

The Python side uses `httpx` (async, modern, drop-in for `requests`).

**Tests:** HTTP API accepts import request with file, calls Python CLI, returns entity ID; HTTP API accepts export request with entity ID and format, returns file.

### 6. Library survey

| Need | Library | Decision |
|---|---|---|
| DOCX parsing | `python-docx` | Adopt |
| XLSX parsing | `openpyxl` | Adopt |
| PPTX parsing | `python-pptx` | Adopt |
| PDF rendering | `weasyprint` | Adopt |
| PDF text extraction | `pdftotext` (poppler-utils) | Adopt |
| HTML parsing | `beautifulsoup4` | Adopt |
| Email parsing | `mailbox` + `email` stdlib | Adopt |
| Markdown parsing | `markdown-it-py` | Adopt |
| Format conversion (swiss-army) | `Pandoc` | Adopt |
| Slack mrkdwn | none | Build (it's just markdown-like) |
| System share sheet (macOS) | `NSSharingServicePicker` | Adopt |
| System share sheet (iOS) | `UIActivityViewController` | Adopt |
| HTTP client (Swift) | `URLSession` | Adopt |
| HTTP client (Python) | `httpx` | Adopt |

Document any deviation in the design doc §11.

### 7. Design doc

Write `docs/tessera-productivity-import-export-design.md` (matching format). Sections: 1) Problem, 2) Why this design, 3) Importer pipeline, 4) Exporter pipeline, 5) Swift-side integration, 6) System share sheet, 7) Slack webhook, 8) HTTP API, 9) Library survey, 10) Test strategy, 11) Out of scope.

### 8. Fixture data

Commit small test fixtures to the worktree: a simple DOCX (heading + paragraph + list), XLSX (one sheet, 3x3), PPTX (one slide, one text frame), PDF (one page, two paragraphs), EML (one From + Subject + body), MBOX (two messages), HTML (h1 + p + ul), Markdown (# heading + paragraph + list).

## Hard constraints

- No SaaS, no API keys for the core (only for the opt-in Slack webhook).
- No raw SQL in Python (Python talks to data layer via HTTP).
- Apple Silicon native, macOS + Linux compatible.
- 619 existing tests stay green.
- `Assisted-by: MiniMax`, no push, no PR.

## Out of scope

- Phase 2: editor view
- Phase 3: chat panel + receipt drawer
- Phase 5: per-Materials-surface wrappers
- Phase 6: Contacts + Graph viz
- OCR for scanned PDFs (v2), password-protected import (v2), email replies (v2), real-time collab (v2)

## Worker report

Files touched (with line counts); new tests (with pass/fail); performance numbers (import a 1MB DOCX, how long?); library survey decisions; punts; "how to use"; sample output (screenshot/diff of imported + re-exported document).

Branch: `feat/prod-import-export`. Worktree: `worktrees/prod-import-export/`. No push, no PR.
