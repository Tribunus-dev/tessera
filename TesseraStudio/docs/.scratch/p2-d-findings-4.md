# P2-D findings - Track D4 (2.20 Tagged PDF / PDF-UA)

Author: track D4 (this session). Scope: filter-options plumbing through
every PDF export path, `AccessibilityPreflight.swift`, `doc_accessibility_check`
agent tool, veraPDF CI harness. Not shared with other tracks - this is
the track's own findings file per the wave brief.

## HEADLINE FINDING (read first): LibreOffice 26.2.5.2 CLI ignores explicit
## FilterData on every `*_pdf_Export` filter - the opt-in flag currently
## makes output WORSE (untagged), not better, on this dev machine

**Severity: high. Affects item 1's core deliverable. Needs architect
awareness before this is treated as "done and working."**

Empirically probed 2026-08-16 against `soffice --version`: LibreOffice
26.2.5.2 (cd7284b4cbbfeb507e630c1aac019f4157393acb), the exact version
installed in this dev environment and the one the design contract's own
consolidation note cites as clearing every version floor.

**Reproduction** (hand `soffice` invocations, plus re-confirmed through
Tessera's own production code in
`PDFAccessibilityFilterOptionsProbeTests.swift`, gated, soffice-only):

```
# Baseline: NO FilterData at all
soffice --headless -env:UserInstallation=file://<fresh> \
  --convert-to pdf --outdir out1 test.fodt
=> pdfinfo out1/test.pdf: Tagged: yes   (LO's own bare-filter default)

# Explicit, exactly what this wave ships
soffice --headless -env:UserInstallation=file://<fresh> \
  --convert-to 'pdf:writer_pdf_Export:{"UseTaggedPDF":true,"PDFUACompliance":true}' \
  --outdir out2 test.fodt
=> pdfinfo out2/test.pdf: Tagged: no
```

Confirmed reproducible and NOT about `UseTaggedPDF` specifically:

- Any explicit FilterData at all disables the default tagging, even a
  single UNRELATED key (`{"ExportBookmarks":true}` alone -> untagged).
- Boolean encoding made no difference (`true`, `1`, `"true"` all
  produce the same untagged result).
- Reproduced across `writer_pdf_Export` (fodt source), `writer_web_pdf_Export`
  (html source - the filter this pipeline's Writer PDF path actually
  uses), and `calc_pdf_Export` (csv source).
- The bare filter name with NO `:{...}` suffix at all (e.g.
  `'pdf:writer_pdf_Export'`, no FilterData) still produces `Tagged: yes`
  - it is specifically the PRESENCE of an explicit FilterData JSON
    object that flips the default, not the choice of filter name.
- Neither the tagged-by-default baseline NOR the explicit-flag output
  carries a PDF/UA XMP identity claim (`pdfuaid:part`) - so even the
  "good" (tagged) baseline case is not itself a genuine PDF/UA-1
  document, just a tagged one. Confirmed via raw-byte grep for
  `pdfuaid`/`PDF/UA` in both outputs - absent in both.
- A plausible-but-wrong bare filter name (`'pdf:pdf_Export:{...}'` -
  literally what the sota-enterprise-report.md 2.20 section's own prose
  example writes) errors outright: `Error: Please verify input
  parameters... (SfxBaseModel::impl_store ... failed: 0x81a)`. The
  report's own filter-name example is imprecise; the real filter names
  need the app-specific prefix (`writer_pdf_Export`/`writer_web_pdf_Export`/
  `calc_pdf_Export`/`impress_pdf_Export`/`draw_pdf_Export`), matching the
  precedent `LOBridgeDeckIO.swift` already established with
  `impress_pdf_Export:{"ExportNotesPages":true}`.

**External corroboration**: this matches a previously reported
LibreOffice CLI issue -
https://ask.libreoffice.org/t/der-filter-writer-pdf-export-ignoriert-alle-argumente-aus-den-mitgegebenen-filterdata-properties/68343
("Der Filter writer_pdf_Export ignoriert alle Argumente aus den
mitgegebenen FilterData-Properties" - "the filter writer_pdf_Export
ignores all arguments from the given FilterData properties"). This
reads as a genuine, previously-known LibreOffice defect in the
`--convert-to` CLI's FilterData handling, not something specific to
this probe's methodology.

**What this means for the wave:**

1. **Item 1's plumbing is implemented exactly as the design contract
   specifies** (`UseTaggedPDF`/`PDFUACompliance` threaded through
   `filterOptions`, LO's own documented API, verbatim). "Get the flag
   plumbing right" is satisfied at the code level - the moment a future
   LO patch fixes the CLI defect above, tagged/UA PDF export starts
   working with ZERO Tessera code changes, because the plumbing is
   already correct.
2. **On THIS environment, right now, calling `accessibility: .pdfUA`
   produces a WORSE result than the pre-2.20 default** (`accessibility:
   .off`, which builds `filterOptions: nil` and therefore rides
   soffice's own bare-filter default - the one path that is actually
   tagged today). This is counterintuitive and worth flagging loudly to
   anyone about to wire a UI toggle for this: as of today, the honest
   guidance is "leave it off; you get more accessible output for free."
3. All 4 production PDF export paths (`DocumentExporter.renderPDF`,
   `PDFExportBridge.export`, `LOBridgeDeckIO.exportDeck`,
   `CalcBridgeFilter.exportPDF`) are affected identically - this is a
   property of the LO CLI itself, not any one call site.
4. Tests reflect this honestly: `PDFAccessibilityFilterOptionsProbeTests.swift`
   (gated, soffice-only) asserts each production path ACCEPTS the
   filter-options string and produces a non-empty PDF (strong,
   real, passing verification of the plumbing itself), then wraps the
   "is it actually tagged" assertion in `XCTExpectFailure` with a
   `SUSPECTED LIBREOFFICE CLI BUG (not Tessera code)` note, per
   testing-doctrine.md's suspected-bug protocol applied to a
   third-party-tool defect rather than a Tessera code bug. A control
   test (`accessibility: .off`) asserts the pre-2.20 default REMAINS
   tagged, so a future regression in the DEFAULT path (not the opt-in
   flag) would still be caught as a hard failure.
5. `VeraPDFHarnessTests.swift` (item 5) is built the same way -
   see its own section below.

**Suggested next step for the architect** (not attempted this wave -
would need either a different LO build/version to test against, or
digging into `filter/source/pdf/pdfexport.cxx` upstream, both out of
this wave's effort budget): confirm whether a NEWER or OLDER LO minor
version lacks this defect, and/or file/find the upstream bug report.

---

## Item 1: filter-options plumbing - DONE

Shared types in the new `AccessibilityPreflight.swift`:

- `PDFAccessibilityOptions` (struct: `useTaggedPDF: Bool`,
  `pdfUACompliance: Bool`, statics `.off`/`.pdfUA`) - the "your call on
  the exact parameter shape" decision: an options struct, not a bare
  bool, because LO's own two keys are independently meaningful (a
  tagged-but-not-UA-claiming PDF is legal LO output) even though this
  wave's own callers only ever construct the paired `.pdfUA` case.
- `PDFFilterOptions.build(filterName:fragments:)` - the single shared
  string-construction helper every call site uses, so the
  `"filterName:{...}"` syntax is built in exactly one place.

Threaded as `accessibility: PDFAccessibilityOptions = .off` (default
preserves every pre-2.20 caller's exact behavior - verified: `.off`
builds `filterOptions: nil`, byte-identical to what each of these
methods already passed) through:

- `DocumentExporter.export(_:to:destination:accessibility:)` ->
  `renderPDF` -> filter `writer_web_pdf_Export` (see item 2 below for
  why this is the correct name, not `writer_pdf_Export`).
- `PDFExportBridge.export(_:to:accessibility:)` -> filter
  `draw_pdf_Export`.
- `LOBridgeDeckIO.exportDeck(_:to:format:accessibility:)` -> filter
  `impress_pdf_Export`, fragments MERGED with the existing
  `ExportNotesPages` fragment into one filter-data object (per the
  brief's own instruction: "extend that same string, don't build a
  second mechanism").
- `CalcBridgeFilter.exportPDF(_:accessibility:)` -> filter
  `calc_pdf_Export`. **This method did not exist before this wave** -
  see item 1's Calc note below.

All four filter names were individually empirically verified against
real soffice (accepted, produced a non-empty PDF) - see the headline
finding above for the one that ISN'T working as hoped (tagging itself).

### Calc's PDF export path (the "locate this yourself" instruction)

Confirmed: **Calc had no PDF export path at all before this wave.**
`CalcBridgeFilter.exportWorkbook(_:format:)` only ever covered
`supportedExportFormats = ["ods", "xls"]`; passing `"pdf"` would have
thrown `FilterError.unsupportedFormat`. Added a new, separate method
(`exportPDF(_:accessibility:)`) rather than folding `"pdf"` into
`exportWorkbook`/`supportedExportFormats`, since those names are
specifically the ODS/XLS round-trip-parity surface (a `Sheet` read back
in later) and PDF is a one-way print target - the same distinction
`DocumentExporter.ExportFormat` and `LOBridgeDeckIO.DeckExportFormat`
each already draw between their round-trippable formats and `.pdf`.
Same CSV intermediate as the existing ODS/XLS export path, with the
same stated limitation (cell text only, no per-cell formatting).

---

## Item 2: Writer's PDF export - scoping decision

**Decision: mostly already (a), the "PREFERRED" upgrade path - on
inspection, most of it was ALREADY TRUE before this wave touched the
file.** `DocumentExporter.htmlFromDocument`/`renderBlock` already
emitted:

- Real `<h1>`-`<h6>` for headings (not a styled `<div>`).
- A real `<title>` from `Doc.displayTitle`.
- A real `alt="..."` attribute on every `<img>` (falls back to the
  literal text `"image"` when the source block has no alt attribute -
  this fallback is why `AccessibilityPreflight`'s alt-text check reads
  the source `Block` data directly, not the rendered HTML - see item 3).

The one PREFERRED-path item genuinely NOT done, and explicitly punted
per the contract's own conditional wording ("real `<th>` for table
header rows/cells IF `BlockType.table` has header-row/column
metadata"): **it does not.** Confirmed against `TableLayout.swift` and
`Block.swift`: `.table`'s only attributes are `rows`/`cols`; there is
no header-row/column concept anywhere in the Block model. Every table
cell renders `<td>` regardless of position, unchanged by this wave.
Adding that concept would mean a new `Block`/`BlockType` attribute -
out of `DocumentExporter.swift`'s own scope, not named as its own item
in this wave's contract, and `Block.swift` was actively being edited by
a concurrent parallel track (2.13/2.15/2.16) for the entire duration of
this session - touching it was avoided on that basis too. Recorded here
for architect ratification: a future item should add
`headerRows`/`headerCols` (or similar) to `.table`'s attributes if real
`<th>` semantics become a priority.

`lang="en"` is the "sensible default" half of the same scoping note:
confirmed neither `Doc` nor `DocumentMeta` carries a language/locale
concept anywhere (`Productivity/Block.swift`). Deliberately did NOT add
one to `Doc`/`DocumentMeta` this wave - `Block.swift` is outside this
track's owned file list and was under concurrent edit by another track;
the contract's own wording explicitly allows "a sensible default" when
no such concept exists. See item 3 for how `AccessibilityPreflight`'s
`missingLanguage` check handles the same gap.

**Filter name correction (empirically required, not optional):** the
design contract's own open question flagged that "Writer-side PDF
export currently bypasses LO on some paths" and that routing through
the LO filter "is part of the wave" - confirmed and done, but the
correct filter name for THIS pipeline's HTML source is
`writer_web_pdf_Export`, not `writer_pdf_Export`. Verified empirically:
soffice's own debug output for an HTML source reads `"...as a
Writer/Web document -> ... using filter : writer_web_pdf_Export"`.
Using the plain-Writer filter name here would name a filter that never
actually runs against this pipeline's own source format (HTML always
opens as Writer/Web, never plain Writer).

---

## Item 3: AccessibilityPreflight.swift - DONE, one design-judgment call

New `TesseraCore/DocumentProcessing/AccessibilityPreflight.swift`.
`AccessibilityPreflight.run(_ doc: Doc, language: String? = nil) ->
[AccessibilityIssue]` - pure, no soffice, no I/O. Four checks, each
mapped to a specific Matterhorn Protocol 1.1 checkpoint number in its
own doc comment (06-001 title, 11-001 language, 14-002 heading jumps,
13-004 alt text):

1. **Missing title** - well-formed when `doc.title` is non-blank OR the
   body's first heading is non-blank (mirrors `Doc.displayTitle`'s own
   fallback chain).
2. **Missing language** - see design-judgment call below.
3. **Heading-level jumps** - walks `DocumentAST.depthFirstOrder()` (so
   a heading nested inside `.toggle`/`.section`/`.frame` still
   participates in the one document-wide sequence); flags the OFFENDING
   (later) heading when its level is more than 1 greater than the
   immediately preceding heading. The first heading never triggers this
   regardless of its own level (no preceding heading to jump from) -
   the contract's own example is specifically about a SKIP between two
   headings, not about the starting level.
4. **Missing alt text** - walks every `.image` block; absent, empty, or
   whitespace-only `attributes["alt"]` all count as missing. Reads the
   source `Block` data directly (not `DocumentExporter`'s rendered
   HTML), so it is not fooled by that exporter's own `"image"` text
   fallback (see item 2).

### Design-judgment call: `missingLanguage` takes a `language: String?`
### parameter, not a `Doc` field - recorded for architect ratification

No `language`/`locale` concept exists anywhere in `Doc`/`DocumentMeta`
today (confirmed by inspection of `Productivity/Block.swift`). Adding
one was considered and REJECTED for this wave, for two independent
reasons: (a) `Block.swift` is outside this track's owned file list, and
was under active concurrent edit by another P2-D track for this
session's entire duration - touching it risked a real collision; (b)
the item 2 CRITICAL SCOPING NOTE's own wording ("`<html lang="...">`
from whatever document-language concept exists, OR A SENSIBLE DEFAULT")
reads as explicit permission to NOT invent one.

Instead, `AccessibilityPreflight.run`'s `language` parameter is an
ordinary caller-supplied value (`nil` means "not tracked", reported as
`.missingLanguage` - the HONEST current state of every Tessera document
today, not a placeholder that can never fire). `doc_accessibility_check`
exposes this as an optional `language` tool argument (item 4). **This is
a real, deliberate design call, not an oversight** - recorded here per
the wave brief's own instruction to record judgment calls for
ratification. If a future wave adds a real per-document language field
(recommended: `DocumentMeta.language: String?`, following the exact
`decodeIfPresent`-with-nil-fallback pattern `sections`/`notes`/`styles`
already established on that same type), `checkLanguage` should read it
directly and `DocumentExporter`'s `<html lang="en">` should too, closing
this gap for real.

All four checks + a full totality-guard-adjacent well-formed-fixture
test suite are ungated, pure Swift - see
`AccessibilityPreflightTests.swift`.

---

## Item 4: agent tool scoping - DONE, as pre-authorized by the wave brief,
## recorded here anyway per its own instruction

Built ONLY `doc_accessibility_check` (tier0/`ApprovalLevel.auto`,
read-only, no receipt) in a NEW file, `Tools/AccessibilityTools.swift`,
with its own `DocAccessibilityToolContext` (same
install/shared/NSLock-protected shape as `MailMergeToolContext`/
`SheetToolContext`). Deliberately did NOT build `doc_export`/
`sheet_export`/`slide_export` agent tools - they do not exist anywhere
in this codebase (export today is a SwiftUI-level user action only),
and building three new full export tools from scratch is a much bigger
scope than "add a parameter," not named as its own item anywhere in
this wave's contract. This scoping is explicitly pre-authorized by the
wave brief's own item 4 text; this section exists to satisfy the
brief's "document this scoping decision explicitly... for architect
ratification" instruction, not because the call itself was in doubt.

**Own file, not `Tools/DocTools.swift`.** That file is item 2.15's own
new file (its `DocToolContext`, `doc_form_fields_list`/`doc_form_fill`
tools), being written concurrently by a parallel track for this
session's entire duration (confirmed via `git status` showing it as a
freshly-created untracked file throughout). Touching it risked a real
collision and has nothing to do with accessibility; the "own file per
material's agent surface" shape (`MailMergeTools.swift`/`SheetTools.swift`)
already established the right precedent to follow instead.

---

## Item 5: veraPDF CI harness - BUILT, NEVER ACTUALLY RUN (honest status)

New `Tests/TesseraCoreTests/Productivity/ImportExport/VeraPDFHarnessTests.swift`.
Gated behind `TESSERA_VERAPDF_HARNESS=1` (mirrors
`TESSERA_DB_INTEGRATION=1`/`TESSERA_CORPUS_HARNESS=1`). Independently
checks for `verapdf` (common install paths + `which verapdf`) and for
`soffice`, skipping cleanly with a named reason for either absence,
regardless of the env-var gate.

**veraPDF status in this environment, checked directly:** confirmed
ABSENT. `which verapdf` -> not found; checked
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and a few other
plausible install roots - nothing found anywhere. Java IS present
(`java version "22.0.1"`), but that alone does not make veraPDF
available. **This harness has therefore never actually executed against
real veraPDF output.** Its exit-code convention (0 = compliant,
non-zero otherwise - the one behavior documented with confidence at
docs.verapdf.org/validation) is implemented but UNVERIFIED against a
real run; a first execution on a machine with veraPDF installed is the
moment to confirm it and remove this caveat.

The harness DOES export a real 4-material fixture corpus (Writer/Draw/
Impress/Calc, each via the real production export method with
`accessibility: .pdfUA`) using real `soffice` - that half was exercised
directly (soffice is present). Given the headline finding above, the
compliance assertion is wrapped in `XCTExpectFailure` with the same
`SUSPECTED LIBREOFFICE CLI BUG` note as the probe test - the harness is
EXPECTED to report non-compliance today (untagged output), for the
identical upstream reason, not because Tessera's own filter-options
plumbing is wrong.

A `manualMatterhornChecklistNote` static string documents the 47
human-judgment Matterhorn conditions this harness cannot automate
(reading-order sensibility, alt-text descriptiveness vs. mere presence,
etc.) - a documentation anchor, not executable, per the item's own "47
human-judgment conditions get a documented manual checklist" text.

**Fixture corpus source - design-judgment call, recorded for
ratification:** built directly via each material's own Swift factory
(`Doc`, `Sheet.makeBlank`, `Drawing.makeBlank`, `SlideDeck.makeBlank`)
rather than routing through the existing
`Tests/TesseraCoreTests/Fixtures/RoundTrip/*.fodt` corpus. Those
fixtures are hand-authored ODF XML for `FlatODFReader`/`FlatODFWriter`
wire-format pinning (a different test suite's contract) - not
`Doc`/`Sheet`/`Drawing`/`SlideDeck` values this item's own export
methods take. Routing through them would need an ODF->Doc/Sheet/Drawing
import bridge this track does not own or build. The exact same small
fixture shapes are shared between the probe test file and this harness
(one fixture definition, not two).

---

## Item 6: tests - summary

- `AccessibilityPreflightTests.swift` (ungated, pure): all four checks,
  hand-built fixture ASTs, both directions (catches the issue / does
  NOT false-positive on a well-formed fixture), determinism, degenerate
  (empty document) input. Plus `PDFAccessibilityOptionsTests` in the
  same file: `filterDataFragments`/`PDFFilterOptions.build` pure-logic
  coverage, and one pinned test per PDF export path's exact filter name
  (mirrors the literal each production call site passes, so a rename in
  one place without the other shows up as a diff here).
- `AccessibilityToolsTests.swift`: schema round-trip, tier assertion
  (tier0/`.auto`), two ungated denial paths (malformed doc_id, no store
  installed), and three `TESSERA_DB_INTEGRATION=1`-gated fixture-based
  content tests against a REAL persisted `Doc` through a REAL `DocStore`
  (no in-memory seam exists for `DocStore` - same documented exception
  `DocStoreTests.swift` already carries).
- `PDFAccessibilityFilterOptionsProbeTests.swift` (quarantined empirical
  probe, doctrine rule 10, soffice-gated): all four production export
  paths, each proven to ACCEPT the exact filter-options string this
  wave builds and produce a non-empty PDF; the "is it tagged" half is
  `XCTExpectFailure`-wrapped per the headline finding, plus one control
  test proving the pre-2.20 default path remains tagged.
- `VeraPDFHarnessTests.swift`: see item 5.

---

## wiringNotes (TesseraToolRegistry.swift is withheld from this track)

**1. `TesseraToolRegistry.default` array entry.** Add one line inside
the array literal at `Sources/TesseraCore/Agent/TesseraToolRegistry.swift`
(near the other productivity-material tools, e.g. beside
`MailMergeRunTool()`):

```swift
DocAccessibilityCheckTool(),
```

- Name: `"doc_accessibility_check"`.
- Params: `doc_id` (string, required, UUID), `language` (string,
  optional, BCP-47 tag).
- Return/data shape: `ToolResult.data` carries `"issues"` (a JSON array
  of `{"kind": string, "severity": string, "message": string, "blockID":
  string-or-null}` objects, one per `AccessibilityIssue`) and
  `"issue_count"` (number).
- Tier: `ApprovalLevel.auto` (tier0). No receipt - this tool never
  persists anything.
- No-op/empty condition: an empty `issues` array (and `issue_count: 0`)
  when the document has no findings; `ToolResult.output` is the literal
  string `"No accessibility issues found."` in that case.
- Denial paths: malformed/missing `doc_id` -> `.fail("doc_id must be a
  UUID")`; no store installed -> `.fail(...)` with
  `DocAccessibilityToolError.noStore.errorDescription`; unknown
  `doc_id` -> `.fail("no document with id <id>")`.

**2. `DocAccessibilityToolContext.shared.install(docStore)` app-level
wiring.** This tool resolves its `DocStore` through
`DocAccessibilityToolContext.shared` (own type, own file -
`Tools/AccessibilityTools.swift` - deliberately NOT `Tools/DocTools.swift`'s
`DocToolContext`, see item 4 above). Whoever owns the Docs surface's
app-level bootstrap (`TesseraStudioMac/App/ProductivityBootstraps.swift`'s
`DocsSurfaceBootstrap`, the same place `MailMergeToolContext.shared
.install(...)` already happens - see that file's existing `init()`)
should add, alongside the existing `MailMergeToolContext` install line:

```swift
DocAccessibilityToolContext.shared.install(store)
```

(where `store` is the SAME `DocStore` instance `DocsSurfaceBootstrap`
already constructs for its own `viewModel`). NOT done in this session -
`ProductivityBootstraps.swift` is outside this track's owned file list,
and per the wave's own "the real risk this wave is DocStore.swift and
TesseraToolRegistry.swift being touched by MULTIPLE tracks at once"
note, the safer choice was to leave app-level wiring to the centralized
wiring pass, matching how prior waves handled the exact same
`MailMergeToolContext` install (per that file's own comment: "Installed
eagerly... see MailMergeToolContext's own doc comment").

---

## Status per item (see structured output for the canonical table)

1. Filter-options plumbing: DONE, all 4 paths, verified against real
   soffice (accepts the syntax) - see headline finding for the
   tagging-itself caveat.
2. Writer HTML scoping: DONE - (a) was mostly already true; `<th>`
   punted per the contract's own conditional; filter name corrected to
   `writer_web_pdf_Export`.
3. AccessibilityPreflight.swift: DONE, 4 checks, one recorded
   design-judgment call (language as a parameter, not a `Doc` field).
4. Agent tool scoping: DONE, `doc_accessibility_check` only, as
   pre-authorized.
5. veraPDF harness: BUILT, gated, degrades cleanly - but NEVER ACTUALLY
   EXECUTED against real veraPDF (confirmed absent on this machine).
   soffice half (fixture corpus generation) was exercised directly.
6. Tests: DONE - see item 6 above for the full breakdown.
