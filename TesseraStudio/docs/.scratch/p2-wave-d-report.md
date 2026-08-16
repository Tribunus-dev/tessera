# Wave P2-D report (2026-08-16) - Enterprise/compliance (final P2 wave)

**Scope:** MacroCompatLayer (2.13, parse + preserve + agent-assisted
rewrite, never execute); Forms/ContentControl (2.15, DOCX w:sdt model
as Block attributes); DatabaseConnector (2.16, local-file-engines-only
GRDB+DuckDB); Tagged PDF / PDF-UA (2.20, LO filter-options + native
preflight + veraPDF CI harness). Branch `scratch/studio-p2/wave-d`, 6
commits (`3e15573c4` wave opener through `5a1d6cb44` wiring), starting
tip `d6a9ab416` (the P2-C gate report). 4-agent Workflow dispatch
(D1-D4) on disjoint files, followed by a centralized DocStore/Doc.swift/
TesseraToolRegistry.swift/ProductivityBootstraps.swift wiring pass.
This is the **last wave of the P2 implementation campaign** - every
item in the original plan is now landed.

**Note on this wave's commit history:** the D2 (Forms/ContentControl)
commit was swept into a concurrently-running, unrelated session's own
commit (`666f1bb78`, "docs: revise 19e - native C++ multi-platform
trainer") when its `git commit` landed in the narrow window between
this session's `git add` and `git commit` for D2 - another process is
independently active on this same branch/working tree. The CODE itself
is intact and correctly reviewed/tested/wired (verified via `git show
--stat 666f1bb78`, which lists exactly D2's own files alongside the
other session's unrelated docs files); only the commit message/grouping
is misleading for that one slice. Not rewritten (amending shared,
concurrently-touched history is exactly the kind of destructive
operation to avoid without explicit direction) - flagged here instead
for the record. Every other commit this wave was verified immediately
after creation to contain exactly its intended files.

## 1. Per-item verdicts

| Item | Track | Verdict | Note |
|---|---|---|---|
| 2.13 MacroCompatLayer | D1 | DONE | Preserve+decompress+outline+translate pipeline, including a from-scratch CFBF (compound file) reader beyond the original 3-file scope - never executes, enforced by explicit canary-file tests |
| 2.15 Forms/ContentControl | D2 | DONE | Content controls as Block attributes on a judgment-call eligible-type set (not one BlockType); FormBindingResolver's documented minimal XPath subset |
| 2.16 DatabaseConnector | D3 | DONE | GRDB (readonly)/DuckDB local-file-only, write rejection proven at the engine level in tests, not just absent write code |
| 2.20 Tagged PDF / PDF-UA | D4 | DONE (plumbing); PARTIAL (verified compliance) | Filter-options wired through all 4 export paths; a real LibreOffice CLI defect on this machine currently produces untagged output regardless - documented, not hidden |
| DocStore wiring (translateMacro/fillForm) | wiring | DONE | Standard no-op-guard shape for fillForm; translateMacro always emits (matches recordMailMerge's "the run happened" precedent) |

## 2. Bugs found and fixed during centralized verification

The first real build/test pass over all 4 tracks' work together
(~11,400 lines of new/changed code spanning a binary-format parser, a
content-control model, two new database engine integrations, and a
PDF export pipeline touched in 4 places) surfaced one real bug:

1. **A Swift compiler diagnostic-generation crash in
   `DatabaseConnector.swift`.** `(0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }`
   over a DuckDB `Float`/`Double` column produced `error: failed to
   produce diagnostic for expression; please submit a bug report` -
   the bare `String.init` function reference is ambiguous enough
   across `String`'s many floating-point-adjacent initializers that
   the type checker couldn't even generate a normal error message for
   it. The structurally identical lines for every OTHER numeric type
   (Int8 through UInt64) compiled fine - only `Float`/`Double`
   triggered it. Fixed by replacing the bare function reference with
   an explicit typed closure (`{ (value: Float) -> String in
   String(value) }`), which resolves the ambiguity outright. Not a
   logic bug - the intended behavior was always correct - purely a
   compiler-diagnostic pathology this fix sidesteps.

Three tracks also caught real bugs in their own work before it ever
shipped:
- D1 (macros) caught two: a called-API census regex that required a
  trailing `(` and missed VBA's common parens-less call form
  (`Shell "cmd.exe"`), and a test-fixture-builder bug that routed an
  oversized module's content through the wrong CFBF storage mechanism
  (regular FAT vs. the mini-stream) - both found via a standalone
  round-trip verification script run before any of the binary-format
  code was committed to the real test suite.
- D4 (tagged PDF) discovered - rather than a code bug - a genuine
  third-party defect: on this environment's soffice 26.2.5.2, passing
  ANY explicit `FilterData` to a `*_pdf_Export` filter currently
  produces an UNTAGGED PDF, while the pre-2.20 default (no
  `FilterData` at all) is already tagged by soffice's own built-in
  default. Corroborated by a prior public LibreOffice forum report.
  Handled via the same `XCTExpectFailure("SUSPECTED CODE BUG: ...")`
  discipline testing-doctrine.md prescribes for suspected bugs in
  code this session doesn't own - here applied to a suspected bug in
  a third-party binary rather than in Tessera's own source, the same
  honest-non-silent treatment either way.

## 3. Known gaps (real, documented, not hidden)

- **The vbaProject.bin -> `PreservedParts` extraction hook at import
  time does not exist yet.** `DocStore.importFromFile` (withheld this
  wave) needs to open a `.docm`/`.xlsm`/`.pptm` package's zip, extract
  the VBA binary, and set `doc.preservedParts` before upsert - D1's
  own pipeline is host-agnostic and fully tested against constructed
  fixtures, but nothing in this wave wires it to a REAL import yet.
  Two implementation strategies (extend the Python format-bridge
  script vs. a Swift-side zip reader) are recorded in
  `docs/.scratch/p2-d-findings-1.md` for a future wave.
- **Macro tooling only reaches Word documents end to end.**
  `Doc.preservedParts`/`Doc.macroPlaybooks` exist; `Sheet`/`SlideDeck`
  have no equivalent fields yet, so `.xlsm`/`.pptm` macro preservation
  has no storage target even once the import hook above lands.
- **Form-field protection semantics are a design note only.** A
  protected fill-in-only document's OTHER writes should resolve to
  `TesseraSafetyCheck.reject` while `doc_form_fill` stays tier1 - real
  surface-area work across many existing `DocStore` methods, correctly
  scoped out of this wave and recorded for a future one.
- **Tagged-PDF compliance is unverified end to end on this machine** -
  both because of the LibreOffice filter-data defect above and because
  `veraPDF` itself is confirmed absent here, so the CI harness has
  never actually run against real veraPDF output (it degrades cleanly
  via `XCTSkip` rather than failing or silently passing).
- **Writer's real `<th>` table-header export for PDF/UA is punted** -
  `BlockType.table` carries no header-row/column metadata, and adding
  that concept would touch `Block.swift`, which was under concurrent
  edit by track D2 all session.
- Several design-judgment calls were made where no doc answered the
  question (the CFBF module-boundary heuristic, `ContentControl`'s
  eligible-block-type set, DuckDB's read-only-mode architecture via a
  permanently-empty on-disk scratch catalog, `db_attach`/`db_detach`
  emitting no `GraphReceipt`) - all implemented, tested, and recorded
  in each track's findings file for architect ratification.

## 4. Gate

- **Default suite:** 2629 tests, **0 failures**, ~5m11s.
- **`TESSERA_DB_INTEGRATION=1`:** 2629 tests, **0 failures**, ~5m13s.
- **`TESSERA_CORPUS_HARNESS=1`:** **0 failures**, ~7m13s (isolated
  retry). The full-suite run under this gate hit one transient
  timeout on `layered-shapes.odg` (Draw) - the same known class of
  soffice-under-load flake documented in every prior wave's report,
  plausibly sharper here given a second concurrent session's own
  build/test activity on this machine throughout this wave (see the
  commit-history note above). Confirmed non-reproducing: retried in
  isolation immediately after, passed cleanly in 433s.
- **`TESSERA_VERAPDF_HARNESS=1`:** not separately run - the harness's
  own `XCTSkip` gate already executes (and skips cleanly, verapdf
  confirmed absent via `which verapdf`) as part of the default suite
  above, so its 0-failure status is already covered by that number.
- **Audit Class A (correctness/integrity):** empty. `fillForm`/
  `translateMacro`/`importFromDatabase` all carry proper no-op-or-
  always-fires guards matching their own documented contracts from
  the start.

## 5. Sequence from here

This is the last wave of the P2 implementation plan campaign. Per the
architect's standing instruction ("finish the campaign, do milestone
commits, and at the end of the campaign if it's a clean merge just
merge to main and push to remote"): next is checking whether
`scratch/studio-p2/wave-d`'s tip merges cleanly into `main`, and if so,
merging and pushing.
