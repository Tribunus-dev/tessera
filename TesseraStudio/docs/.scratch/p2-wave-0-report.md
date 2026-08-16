# Wave P2-0 report (2026-08-15) - P1 gap closure

**Scope:** the updated P2-0 item list from the architect's wave-0 launch
prompt (superseding `studio-p2-implementation-plan-2026-08-15.md` section
1's original list). Branch `scratch/studio-p1/agent-a`, 6 commits
(`97b826a95` wave opener through `82ef9fd5e` 0-D), starting tip
`f5f1d7730`. 4-agent Workflow dispatch (0-A Calc, 0-B Slides+Draw, 0-C
Writer, 0-D Infrastructure) on disjoint files, followed by a centralized
build/fix/test/commit pass.

## 1. Per-item verdicts

| Item | Track | Verdict | Note |
|---|---|---|---|
| CalcBridgeFilter CSV -> fods migration | 0-A | DONE | Import path only, verified against real soffice 26.2.5.2; export intentionally unchanged |
| 1.21 @-prefixing | 0-A | BLOCKED (detection shipped) | Marking half needs a Lexer '@' token that doesn't exist; wouldSpillAsTopLevelResult ships tested, unwired |
| sortRange hiddenRows remap (audit A4) | 0-A | DONE | Verified against a real DB round trip after a test-authoring fix (see 4) |
| CF overlay -> paint path | 0-A | DONE (partial coverage) | cellValue/formula/text/blanks/errors paint; top10/aboveAverage/unique/duplicate need an aggregate cache not yet threaded through (documented safe fallback, not a crash) |
| DataValidation -> editor entry path | 0-A | DONE | Both commitEditingCell() implementations gate on applyingInteractiveEntry |
| hiddenRows -> grid view | 0-A | DONE | Row loop filters via a new visibleRows property |
| Sheet comment reply/resolve/delete | 0-A | DONE | |
| 1.20 deck storage + mutations + receipts | 0-B | DONE | SlideMeta.animations wired end to end |
| 1.4 media write path + receipt + AVKit | 0-B | DONE | MediaBlock model unchanged per instruction |
| Draw canvas gesture layer | 0-B | DONE | New DrawCanvasView/DrawDetailView (no Draw view existed before); one-drag-one-undo via new DrawingStore.setGeometries + ReceiptUndoManager.group |
| Group/ungroup (row 48) | 0-B | DONE | Translate-only group delta; group-relative resize/rotate is a follow-up |
| Slide comment reply/resolve/delete | 0-B | DONE | |
| Theme/SlideMasterPage .sortedKeys audit | 0-D | DONE | jsonEncoder + the actually-flaky test's own encoder both fixed |
| 1.2 note insert/delete lifecycle + receipts | 0-C | DONE | New NoteController peer-controller; derived numbering, never persisted |
| Endnote-section/popover rendering | 0-C | DONE (bounded) | Document-flow-granularity, not true glyph-anchored (needs paginator work, out of file scope) |
| Full DocStore comment lifecycle | 0-C | DONE | Doc had zero comment support before this wave; block-tree model, distinct from Sheet/Slide's flat array |
| DB migration bugs (body jsonb, 0013 DROP FUNCTION) | 0-D | DONE | Verified against a truly fresh Postgres 17 apply, zero errors; 0-D also found+fixed an unparenthesized `body->>'x'` bug in 0005/0006 |
| Injectable DocumentStore signing key | 0-D | DONE | Closes the 2-test Keychain gap from 3 waves ago |
| In-memory DataLayer seam (rule 11) | 0-D | DONE (DocumentStore + ReceiptExportService) | DocStore's own seam stayed with 0-C (file ownership); Doc-store-specific seam not built this wave - real gap, not silently dropped |
| Corpus harness rebuilt for real | 0-D | PARTIAL | Real 20-file soffice-derived seed corpus, scoring works end to end; well short of 6f's full target counts (stated in-file) |
| Not-reached coverage lane | 0-D | PARTIAL (by design) | 1 suite landed (DateFunctions); explicitly allowed to continue into P2-A per its own wording |
| Contract stubs (LookupFunctions/tool roster/destructiveVerbs/RecurrenceRule) | 0-D | DONE/DONE/DONE/PARTIAL | First 3 already done in a prior wave (confirmed by reading); RecurrenceRule stub written, untested |

## 2. Two real source bugs found during centralized verification

Both were **pre-existing**, both were invisible until this wave's own
fixes let the code reach them for the first time - not regressions this
wave introduced, but real defects this wave's own work exposed:

1. **`TesseraDataStore.upsertEntity`'s INSERT bound `body` as plain text
   with no cast.** Worked fine against the OLD `text` column; broke the
   instant 0-D's own migration fix changed the column to `jsonb`
   ("column body is of type jsonb but expression is of type text").
   Fixed with the same `::jsonb` cast pattern the query already used for
   `embeddingText::vector`. This one bug was the root cause of ~149
   DB-integration failures across every store, gated and ungated alike -
   not 149 separate defects.
2. **`DocumentStore.encodeReceiptPayload`'s `convert(obj) as? [String:
   JSONValue]` could never succeed** - `convert` returns a `JSONValue`
   enum case (`.object(...)`), never a raw dictionary, so the cast
   silently fell through to `?? [:]` on every single call. Every receipt
   `DocumentStore` ever persisted had an empty `{}` payload in
   `graph_receipts`; `history()`'s decode then silently dropped it via
   `try?`. This explains why `testApplyInsertBlockPersistsAndEmitsExactlyOneReceipt`
   /`testHistoryReturnsReceiptsOldestFirst` failed differently before vs.
   after 0-D's signer-injection fix: before, they never got past
   signing (the Keychain gap); after, they reached this bug for the
   first time in this branch's history. Fixed by unwrapping `.object`
   instead of force-casting.

Both are the kind of "receipts law" and "silent-failure" defects this
session has repeatedly found and fixed elsewhere (`try?`/blind casts
masking real errors) - not new failure classes.

## 3. Test-construction bugs fixed during centralized verification

Same "tests come from contracts, fix the test when its own construction
is wrong" pattern this session has applied consistently:

- **SheetStoreTests' sortRange test had inverted filter semantics.**
  `SheetFilterCriteria(kind: .valueSet, values: ["b"])` SHOWS rows
  matching "b" and hides everything else (`QueryEngine.matchesValueSet`
  - not in doubt, independently verified against the engine's own
  source) - the test asserted the opposite (that "b" itself would be
  hidden). Corrected the assertions; the sortRange remap fix itself was
  already correct.
- **SlideStoreTests' 5 new no-op-receipt tests raced `SlideStore.upsert`'s
  fire-and-forget material-receipt `Task`** - the identical class of bug
  fixed in `SheetStoreTests` earlier this session, just in a brand-new
  test file that didn't yet have the equivalent filtering helper. Added
  `slideReceipts(_:forDeck:)` (mirrors `sheetReceipts(_:forSheet:)`
  exactly) and switched all 20 call sites. Not a source bug - `SlideStore`'s
  own no-op guards were already correct.
- **`DocReceiptTypeTests`' independently-pinned totality guard** (doctrine
  rule 7) wasn't updated for the 6 new `DocReceiptType` cases the wave
  opener pre-landed - added them to the pinned oracle list.
- **`RoundTripCorpusTests`' scoreboard path had an off-by-one
  `deletingLastPathComponent()` count**, writing to
  `TesseraStudio/Tests/docs/` instead of `TesseraStudio/docs/`. Fixed;
  the misplaced directory was removed, the scoreboard now regenerates at
  the correct path.
- **`RoundTripCorpusTests`' whole-test watchdog reused the same 120s
  constant as each individual soffice call inside it** - with up to ~27
  sequential probe-scale calls per run, the outer watchdog fired on
  ordinary cumulative wall-clock time with nothing hung. Added a
  distinct `DoctrineTimeout.corpusProbe` (900s) and a bounded 2-retry
  wrapper per fixture for transient soffice-under-load timeouts
  (confirmed empirically: a *different* fixture timed out on each retry
  across three separate runs - the signature of load, not a defect).
- **`TransformControllerTests`' new group-delta assertions compared
  `Double?` against `Double` inside `XCTAssertEqual(..., accuracy:)`**,
  which has no Optional overload and would not have compiled - unwrapped
  with `?? .nan` (fails loudly on a real nil rather than crashing the
  build).

## 4. Known, not fixed this wave (real gaps, documented not hidden)

- **1.21 @-prefixing's marking half** - needs a Lexer/Parser/Evaluator
  change outside track 0-A's file list (`docs/.scratch/p2-0-findings-a.md`).
- **`ReceiptUndoManager.group(_:)`'s undo() pops one receipt per call**,
  not the whole group in one Cmd-Z, despite its own doc comment's promise
  - found by 0-B, does not affect this wave's own correctness
  (`docs/.scratch/p2-0-findings-b.md`).
- **`DocumentAST.plainText()` has no type exclusions** (leaks
  comment/reply/track-change text into agent chat context) - pre-existing,
  more reachable now that DocStore has a first-class comment API
  (`docs/.scratch/p2-0-findings-c.md`).
- **DocStore's own in-memory `TesseraDataLayer` seam (rule 11)** was not
  built this wave - stayed with track 0-C by file ownership, 0-C's time
  went to the note/comment lifecycle instead. `DocumentStore`/
  `ReceiptExportService` seams ARE done (0-D). Real, named gap.
- **Corpus harness is a 20-file seed**, well short of 6f's 20+/10+/10+/5+
  targets; charts/themes/conditionalFormats have no round-trip code path
  at all yet, independent of corpus size (`docs/.scratch/p2-0-findings-d.md`).
- **Not-reached test-coverage lane** continues into P2-A per its own
  explicit allowance (full remaining list in `docs/.scratch/p2-0-findings-d.md`).
- **RecurrenceRule RRULE grammar contract stub** written, not yet pinned
  with a test.
- **Corpus test's own wall-clock cost** (~200-270s within the DB-gate
  run) means the default suite's runtime is now dominated by one
  quarantined probe; still inside the doctrine's 5-minute budget on this
  machine (166s ungated / 268s DB-gated total), but the margin is
  thinner than before this wave - worth a future wave's attention if it
  starts tipping over.

## 5. Gate

- **Default suite:** 1794 tests, 182 skipped, **0 failures**, 166.1s.
- **`TESSERA_DB_INTEGRATION=1`:** 1794 tests, 1 skipped, **0 failures**,
  268.1s, against a freshly-`DROP DATABASE`-and-reapplied Postgres 17
  (all 14 migrations, zero workarounds, zero manual casts needed at the
  psql layer - confirming 0-D's migration fixes for real, not just
  against the old ad-hoc-patched dev database from an earlier wave).
- **Corpus scoreboard:** `docs/.scratch/p2-0-corpus-scoreboard.json`
  written and populated with real per-fixture, per-axis scores (e.g.
  `basic-cells.ods` cellValues 4/4 survived; `title-slide.odp` slideCount
  1/1 survived, slideTitles 0/1 - a genuine, un-massaged partial-survival
  finding, not fabricated). This is the wave's primary-metric artifact
  future waves should read, not re-derive.
- **soffice:** exercised for real throughout (CalcBridgeFilter's fods
  probe, the corpus harness, pre-existing ODG probes) - LibreOffice
  26.2.5.2 confirmed installed and working.
- **Audit Class A (correctness/integrity):** empty. No receipt-on-no-op
  regressions survived the gate; the two genuinely NEW instances found
  (SlideStoreTests' apparent no-op failures) were test-timing artifacts,
  not real violations, and are now fixed at the test level.

## 6. Sequence from here

Per the architect's prompt: commit this report (done, same commit as
this file), then cut `scratch/studio-p2/wave-a` from this tip for Wave
P2-A (Calc core: pivot, subtotals, solver, stats + reviewer panel).
