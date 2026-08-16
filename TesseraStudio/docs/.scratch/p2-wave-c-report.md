# Wave P2-C report (2026-08-15) - Writer + Draw finish

**Scope:** Table of contents (2.5) + master documents (2.11); mail
merge coordinator (2.4) + wizard (2.21); StarMath equation authoring
(2.14, LaTeX-first over SwiftMath); Draw advanced (2.12: callouts,
dimension lines, Draw-side tables, bullet lists in shape text) + morph
(2.18). Branch `scratch/studio-p2/wave-c`, 6 commits (`2565a32b7` wave
opener through `b671747e3` wiring), starting tip `a481c8a2a` (the P2-B
merge to main). 4-agent Workflow dispatch (C1-C4) on disjoint files,
followed by a centralized DocStore/Doc.swift/BlockRenderer.swift/
TesseraToolRegistry.swift wiring pass (withheld from all 4 tracks the
same way DrawingStore/SheetStore were withheld in Waves P2-A/P2-B) and
verification.

## 1. Per-item verdicts

| Item | Track | Verdict | Note |
|---|---|---|---|
| 2.5 TocController | C1 | DONE | Full 4-source collection algorithm, idempotent, renamed-heading relabel bug caught and fixed during self-review |
| 2.11 Master documents | C1 | DONE | Build-manifest-only assembly (no live transclusion), style-merge + continuous numbering, feeds the existing DocumentExporter unmodified |
| ToC export/import wire shape | C1 | DEFERRED | Design note only - no I/O files in this track's scope; real ODF/Word field serialization recorded for a future wave |
| 2.4 MailMergeCoordinator | C2 | DONE | Sheet-source v1 scope, fans one template + record set to N merged Docs via the existing DocStore.upsert/DocumentExporter.export |
| 2.21 Merge wizard | C2 | DONE | Single-flow SwiftUI sheet over the same coordinator endpoint the agent tool calls |
| 2.14 StarMathEditor | C3 | DONE | Real SwiftMath rendering replacing the literal `$latex$` stub, StarMath/OMML import mapping, equation numbering via the existing FieldKind.sequence |
| 2.12 Draw advanced | C4 | 3 DONE, 1 PARTIAL | Callouts/dimension-lines/bullet-lists shipped in full; Draw-side tables ship creation + per-cell editing, row/column insert-delete deferred |
| 2.18 Morph | C4 | DONE | Pure id-matched interpolation; id mismatch throws by design, bezier paths degrade to geometry-only on a segment-shape mismatch |
| DocStore wiring (regenerateToc/setMasterDocSpec/recordMailMerge) | wiring | DONE | Each with the standard no-op-guard-before-persist-and-receipt shape, except recordMailMerge (contract is "the run happened", not "something changed") |

## 2. Bugs found and fixed during centralized verification

The first real build/test pass over all 4 tracks' work together (~9,600
lines of new/changed code across a ToC/master-doc engine, a mail-merge
pipeline, a SwiftMath integration, and a Draw feature set) surfaced 3
real bugs, all fixed and disclosed in their owning track's commit:

1. **`MailMergeTools.execute()` checked for an installed coordinator
   before validating arguments.** This track's own tests name the
   contract explicitly ("denial path: malformed arguments - fails
   before touching the coordinator"), but the first draft's guard order
   meant a malformed `output_format` failed with "no coordinator"
   instead of naming the allowed formats. Reordered: arguments validate
   first, coordinator is checked last, right before use - verified this
   doesn't break the OTHER test that specifically wants the
   no-coordinator failure (it still gets it, since its own arguments
   are valid).
2. **The "Fraction" StarMath palette snippet, `\frac{}{}`, rasterized to
   a genuine zero-size image.** Confirmed empirically (debug
   instrumentation, reverted before commit): SwiftMath's own error
   channel reports no parse error, but a fraction with both slots empty
   collapses to a `(0, 0)` image, unlike `\sqrt{}`, whose radical glyph
   has its own inherent size even when empty. `renderLaTeX`'s
   width/height>0 guard correctly flagged this as unrenderable - the
   real fix was giving the snippet placeholder content (`\frac{a}{b}`),
   matching every other template entry's own convention.
3. **`DocumentExporter`'s PDF export called `textutil -convert pdf`,
   which does not exist** - confirmed against `textutil -help`'s own
   format list (txt/rtf/rtfd/doc/docx/odt/webarchive, never pdf). This
   predates the wave entirely (the file's own header comment even
   described a DIFFERENT, never-actually-built mechanism -
   `NSAttributedString` + `NSPrintOperation`) and was simply never
   exercised by a real test until this wave's new mail-merge PDF-export
   coverage. Fixed by routing PDF through `LibreOfficeConverter`
   (`soffice --convert-to pdf`), the same CLI conversion mechanism
   `PDFExportBridge` already uses for Draw's own PDF export.

Two tracks also caught real bugs in their own work before it ever
shipped:
- C1 found a `derived-never-stored` violation during self-review: a
  first draft's `changed` signal compared only structural `TocEntry`
  fields, so renaming a heading with no other change would leave the
  ToC's stale cached label in place forever. Fixed by also comparing
  each entry's cached display text.
- C3 found and fixed a real operator-precedence bug in its own StarMath
  `over` parser (a formula like `"x = {a} over {b}"` was splitting the
  whole preceding term instead of binding to just the adjacent factor)
  while hand-tracing fixtures against the parser.

## 3. Known gaps (real, documented, not hidden)

- **ToC export/import wire format is a design note only** - no I/O
  (fods/OOXML bridge) files were in this track's scope this wave; the
  exact `text:table-of-content`/Word `{ TOC }` field shape needed is
  recorded in `docs/.scratch/p2-c-findings-1.md` for a future I/O wave.
- **Master-document style merge doesn't rewrite a kept part style's
  `basedOn` pointing at a dropped sibling** - degrades silently via
  `StyleRegistry.chain`'s own fail-soft dangling-ref behavior rather
  than crashing, but the inheritance is wrong in that specific
  colliding-and-inherited-from combination. No test in this wave's
  required list exercises it.
- **Mail merge v1 data source is Sheet only** - other
  `linkedEntityIDs`-referenced material types (Contacts, other Docs)
  aren't supported yet; documented scope choice, not an oversight.
- **Draw-side table row/column insert/delete is deferred** - creation
  and per-cell content editing shipped; whole-table resize already
  works for free via the existing `setGeometry`, but redistributing
  `columnWidths`/`rowHeights` on a row/column mutation does not exist
  yet.
- **Callout/table ODG round-trip is box-only** - both new `ShapeKind`
  cases degrade to a plain `draw:rect` on export (no leader-line
  `svg:d`, no `table:table`-in-`draw:frame`), matching `.freeform`'s
  existing precedent. `draw:name`'s kind marker still recovers the
  exact kind on a Tessera-authored round trip.
- **`BlockRenderer`'s ToC-entry leader/page-number layout uses a fixed
  default content width** (`DocumentPageLayout`'s own 451pt A4 default),
  not the document's real page layout or `TocSpec.tabLeader` - the
  renderer is per-block by design (see `renderListItem`'s own
  documented limitation) and has no access to either.
- Several design-judgment calls were made where no doc answered the
  question (heading-family style detection via a "Heading N" naming
  convention, master-doc break-block representation, callout-as-new-
  ShapeKind vs. orthogonal-field, morph's id-mismatch-throws policy) -
  all implemented, tested, and recorded in each track's findings file
  for architect ratification, not silently guessed.

## 4. Gate

- **Default suite:** 2381 tests, **0 failures**, ~4m36s.
- **`TESSERA_DB_INTEGRATION=1`:** 2381 tests, **0 failures**, ~4m42s.
- **`TESSERA_CORPUS_HARNESS=1` (its own explicit pass):** **0 failures**,
  ~8m11s.
- One transient parallel-execution flake observed on the first default-
  suite run (`TesseraNotificationBudgetTests.testLogRecordsAPostedEventWhenTelemetryIsEnabled`,
  a file untouched by this wave) - passed cleanly in isolation and on
  the full re-run; consistent with the known class of `swift test
  --parallel` ordering flakes documented in prior wave reports, not
  investigated further.
- **Audit Class A (correctness/integrity):** empty. Every new
  DrawingStore/DocStore method carries a proper no-op guard from the
  start (no repeat of the historical "DrawingStore no-op-receipt
  defect" this doctrine document is named after) - `recordMailMerge`'s
  unconditional-append is an intentional exception, documented as such
  (its contract is "the run happened," not "something changed").

## 5. Sequence from here

Per the plan: commit this report, then cut `scratch/studio-p2/wave-d`
from this tip for Wave P2-D (Enterprise/compliance: macros, forms,
database connector, tagged PDF) - the final wave of the P2
implementation campaign. Per the architect's standing instruction, the
merge to `main` happens once, at the end of the whole campaign, if that
merge is clean.
