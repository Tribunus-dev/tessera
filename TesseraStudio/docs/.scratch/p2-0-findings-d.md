# P2-0 Track D findings (Infrastructure + coverage)

Author: agent D, wave P2-0. Branch `scratch/studio-p1/agent-a` (shared
checkout, 4 parallel agents). No `swift build`/`swift test` run by this
agent per the wave's centralized-build constraint - every claim below
that needed empirical verification used a tool OTHER than the Swift
toolchain (a scratch local Postgres for item 1, direct `soffice` CLI
probes for item 4) and says so explicitly.

## Item 1: DB migration bugs

**Status: DONE, verified against a real fresh Postgres.**

(a) `graph_entities.body` was `text` in `0001_init.sql` but 0004-0012 all
use the jsonb `->>'` operator on it directly. Fixed by changing the
column to `jsonb` in `0001_init.sql`, matching every later migration's
actual usage (same precedent as the session's earlier graph_receipts FK
fix - direct edit to 0001, not a new incremental migration).

Fixing the column type alone was not sufficient to keep 0001
self-consistent: the `search_tsv` GENERATED column did
`to_tsvector('english', coalesce(body, ''))`, which requires `body` to
be text-typed. With `body` now `jsonb`, `coalesce(body, '')` fails
Postgres's type resolution (the empty-string literal is not valid JSON
input for the jsonb cast Postgres attempts). Fixed by casting
`body::text` in that expression (`0001_init.sql`, `search_tsv` comment
explains why: `to_tsvector('english', jsonb)` would index every JSON key
name too, not just the values we want ranked).

(b) `0013_document_subtype_hybrid.sql`'s `CREATE OR REPLACE FUNCTION
hybrid_search(...)` adds a `subtype` output column, which Postgres
rejects without a preceding `DROP FUNCTION` (different `RETURNS TABLE`
row shape). Fixed by adding `DROP FUNCTION IF EXISTS
hybrid_search(uuid, text, vector(1536), int);` immediately before 0013's
`CREATE OR REPLACE FUNCTION`.

**Additional real bug found while verifying (a)+(b), in files this
track owns (0005/0006), fixed in the same pass:**
`0005_reminders.sql` and `0006_calendar.sql` both wrote
`ON graph_entities (entity_type, body->>'triggerAt')` /
`(entity_type, body->>'startAt')` as `CREATE INDEX` column lists -
Postgres requires a parenthesized expression for anything beyond a bare
column reference in that position (`... (entity_type, (body->>'triggerAt'))`
- compare 0004/0008/0009, which already parenthesize correctly). Without
the parens this is a hard `ERROR: syntax error at or near "->>"` -
migrations 0001-0004 apply cleanly and then 0005 fails outright, so this
was blocking "fresh apply, zero errors" independent of bugs (a)/(b).
Fixed by adding the missing parens in both files.

**Verification (real, not simulated):** this machine has Postgres 17.10
(Homebrew) + pgvector 0.8.6 + pg_trgm + pgcrypto installed locally.
Initialized a scratch cluster in the scratchpad dir (short-path Unix
socket at `/tmp/p20d_sock` - the scratchpad's own path is too long for a
Postgres socket path's 103-byte limit), started it, created a fresh
database, ran all 14 migration files in numeric/lexical order
(`0001_init.sql` ... `0014_graph_checkpoints.sql`) via `psql -v
ON_ERROR_STOP=1`. **All 14 applied with zero errors** on the first
attempt after the fixes above (confirmed by rerunning from a dropped
database after the fixes, not just incrementally patching a
partially-migrated one). Also ran a functional smoke test: inserted a
`reminder` row and a `document` row with real `jsonb` bodies, confirmed
`body->>'triggerAt'` extraction works, confirmed the `search_tsv`
generated column populates for both rows, and confirmed
`hybrid_search(...)` (0013's version, with the `subtype` column) runs
without error. Cluster torn down after verification; no residue left in
the repo checkout.

Files touched: `tools/tessera/db/migrations/0001_init.sql`,
`0005_reminders.sql`, `0006_calendar.sql`,
`0013_document_subtype_hybrid.sql`.

## Item 2: Injectable signing key for DocumentStore

**Status: DONE.**

`DocumentStore.init` gained a `signer: ReceiptSigner = ReceiptSigner()`
parameter (default preserves the real-Keychain behavior for every
existing call site - grepped all 5 non-test `DocumentStore(dataLayer:`
call sites, none pass a second argument, so none needed changes). The
hardcoded `let signer = ReceiptSigner()` inside `applyBatch` now reads
`let signer = self.signer`.

`DocumentStoreTests.makeStore()` now injects
`ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())`, the same
pattern `ReceiptExportServiceTests.makeService()` already uses.

**DB gate NOT removed from any of the 4 DocumentStoreTests tests.**
Verified why: `makeStore()` calls `TesseraDataLayer().start()` against
the DEFAULT `TesseraDataLayer.Configuration` - `start()`'s own doc
comment says "Postgres is required (the data layer can't exist without
it)" and `loadDocument`/`saveDocument`/`history` all go straight through
`dataLayer.getEntity`/`.upsertEntity`/`.receiptChain`, no seam. All 4
tests need a real Postgres regardless of the signing-key fix, so the
gate stays per the item's own instruction ("if they need a real DB for
other reasons, leave the DB gate"). Cross-checked which 2 of the 4 were
actually Keychain-affected: `testApplyBatchWithAnInvalidMutationPersists
NothingAndAppendsNoReceipt` and `testApplyBatchOnEmptyMutationListThrows
WithoutPersistingOrAppending` both throw BEFORE `applyBatch` ever
reaches `signer.sign(...)` (one from `MutationEngine.apply` on a
not-found block, one from the `!mutations.isEmpty` guard), so they were
never Keychain-sensitive - only `testApplyInsertBlockPersistsAndEmits
ExactlyOneReceipt` and `testHistoryReturnsReceiptsOldestFirst` (both
reach a successful `store.apply(...)`) were the actual 2 named in the
dispatch brief. The injected signer fixes exactly those 2's Keychain
dependency; the DB dependency (all 4) is addressed by item 3's ungated
shadow instead.

Files touched: `TesseraStudio/Sources/TesseraCore/Productivity/
DocumentStore.swift`, `TesseraStudio/Tests/TesseraCoreTests/
Productivity/DocumentStoreTests.swift`.

## Item 3: In-memory DataLayer seam

**Status: DONE for both named stores.**

- `DocumentStoring` protocol (new file, `Sources/.../Productivity/
  DocumentStoring.swift`) declares `DocumentStore`'s full public
  surface (load/save AST, apply/applyBatch, history, chat-queue
  read/write). `extension DocumentStore: DocumentStoring {}` -
  declaration only, no wrapper, exactly the `CalendarStoring` precedent
  (`extension CalendarStore: CalendarStoring {}` in
  `CalendarChatHandler.swift`).
- `InMemoryDocumentStore` (new file, `Tests/.../Productivity/
  DocumentStoreTestSupport.swift`) is an independent in-memory
  reimplementation (not a wrapper around the real store), matching the
  `InMemoryReminderStore` precedent's own shape. It reuses the exact
  same pure decision-makers the real store does (`MutationEngine`,
  `DocumentAST.contentHash()`, `ReceiptSigner`) so mutation/receipt
  semantics are identical; only the persistence substrate (a dictionary
  instead of `TesseraDataLayer`) differs.
- `DocumentStoringContractTests.swift` (new file, same directory as
  `DocumentStoreTests.swift`) is the ungated shadow, mirroring
  `ReminderStoringContractTests.swift`'s naming/shape exactly: the SAME
  4 contracts `DocumentStoreTests.swift` pins under
  `TESSERA_DB_INTEGRATION=1` (insert->1 receipt, batch atomicity on a
  bad mutation, empty-batch throws-without-side-effects, history
  oldest-first), run against `InMemoryDocumentStore` with no gate, plus
  a couple of doctrine-shape additions (unseeded-document returns empty
  AST rather than throwing; chat-queue round trip; forced-error denial
  path).

- `ReceiptExportServicing` protocol (new file, `Sources/.../Productivity/
  Receipts/ReceiptExportServicing.swift`) declares `ReceiptExportService`
  's one load-bearing async entry point, `export(...)`. The pure
  formatting helpers (`buildMarkdownSummary` etc.) need no I/O and
  already have direct ungated coverage in `ReceiptExportServiceTests
  .swift`, so they're deliberately NOT on this protocol.
  `extension ReceiptExportService: ReceiptExportServicing {}`.
- `InMemoryReceiptExportService` (new file, `Tests/.../Productivity/
  Receipts/ReceiptExportServiceTestSupport.swift`) is an independent
  reimplementation of `export`'s GATING/WIRING contract (userConfirmed
  -> noReceipts -> egress policy -> build -> log-one-receipt) against an
  injected `DocumentStoring` (so it composes with `InMemoryDocumentStore`
  with zero DB), with a minimal stand-in payload rather than duplicating
  the real service's format-specific builders (already covered
  elsewhere, see above). It keeps its own `exportedReceipts` log rather
  than writing into the injected store's chain, because `DocumentStoring`
  has no "append a receipt with no mutation" method by design (the real
  service goes straight to `dataLayer.appendReceiptToChain`, bypassing
  `DocumentStore.apply`, for the exact same reason) - documented inline.
- `ReceiptExportServicingContractTests.swift` (new file) is the ungated
  shadow: userConfirmed gate, noReceipts gate, egress-policy gate, and
  successful-export-logs-exactly-one-receipt / chains-correctly, all
  exercised with zero DB and zero Keychain.

Files added: `Sources/TesseraCore/Productivity/DocumentStoring.swift`,
`Sources/TesseraCore/Productivity/Receipts/ReceiptExportServicing.swift`,
`Tests/TesseraCoreTests/Productivity/DocumentStoreTestSupport.swift`,
`Tests/TesseraCoreTests/Productivity/DocumentStoringContractTests.swift`,
`Tests/TesseraCoreTests/Productivity/Receipts/
ReceiptExportServiceTestSupport.swift`,
`Tests/TesseraCoreTests/Productivity/Receipts/
ReceiptExportServicingContractTests.swift`.

## `.sortedKeys` (small, separate items in the brief)

Done: `TesseraDataStore.swift`'s `jsonEncoder` static (~line 1273) now
sets `outputFormatting = [.sortedKeys]` alongside its existing
`.iso8601` date strategy. `ThemeTests.swift`'s bare `JSONEncoder()` call
at the `testThemeEncodeDecodeIsIdentity` test (the ONE instance named in
the brief, not the other 4 `JSONEncoder()` calls later in the same file)
now builds an encoder with `.sortedKeys` explicitly before encoding.

## Item 4: Round-trip corpus harness (from-scratch rewrite)

**Status: DONE (harness + a real seed corpus), corpus SIZE explicitly
short of the studio-expansion-plan.md 6f target - see below.**

### What was built

- `Tests/TesseraCoreTests/Support/RoundTripCorpus.swift` (soffice-free,
  no XCTestCase per doctrine rule 10): the axis vocabulary
  (`RoundTripAxis`), the `RoundTripAxisScore`/`RoundTripFixtureResult`/
  `RoundTripScoreboard` Codable shapes, per-material pure scoring
  functions (`sheetAxisScores`, `slideDeckAxisScores`,
  `drawingAxisScores`, `documentASTAxisScores` - compare the model from
  the FIRST import against the model from the reimported EXPORT, so
  "expected" is always derived from what was actually captured, never a
  count I hardcoded by hand), and `RoundTripScoreboardWriter` (writes
  pretty sorted-key JSON).
- `Tests/TesseraCoreTests/RoundTripCorpusTests.swift`: the ONE
  quarantined empirical probe file (doctrine rule 10) that shells out -
  runs every fixture through Tessera's own bridges
  (`CalcBridgeFilter`/`LOBridgeDeckIO`/`ODGBridgeFilter`/
  `WriterBridgeFilter`+`TesseraFormatBridge`), builds the scoreboard, and
  writes it to `docs/.scratch/p2-0-corpus-scoreboard.json` (the
  checked-in-adjacent scratch artifact a wave gate can read). Probed
  2026-08-15 against LibreOffice 26.2.5.2
  (cd7284b4cbbfeb507e630c1aac019f4157393acb, this machine's real
  install). Skips per-fixture, cleanly, when a fixture's required tool
  is absent (soffice for everything; python-docx additionally for
  Writer, via the caught `TesseraFormatBridge.FormatBridgeError
  .missingLibrary`).
- Fixtures: kept the 6 surviving flat-ODF fixtures, added 4 new
  hand-authored flat-ODF sources exercising axes the old 6 didn't
  (`table-and-footnote.fodt`: a 2x2 table + a `text:note` footnote;
  `master-theme-slides.fodp`: 2 named master pages with distinct
  background colors + speaker notes; `layered-shapes.fodg`: 2 named
  layers + a connector between 2 shapes; `multi-column.fods`: a 3-column
  numeric sheet). Converted ALL 10 flat sources up to their real binary
  ODF/OOXML counterparts via this machine's real `soffice
  --convert-to` (not hand-fabricated zip/XML bytes, per the item's own
  instruction): `.ods` x3, `.odt` x3, `.odp` x2 + `.pptx` x2, `.odg` x2.
  Every conversion's soffice log was checked for errors (none). Corpus
  is now 20 files (10 flat-ODF sources + 10 derived binaries).

### Corpus-size gap, stated plainly

studio-expansion-plan.md 6f's target is 20+ DOCX / 10+ ODS-XLSX / 10+
PPTX-ODP / 5+ ODG-SVG. This wave's seed corpus is 3 ods, 3 odt (no docx -
see below), 2 odp + 2 pptx, 2 odg (no svg). This is a from-scratch SEED,
not the full target - closing the gap is real work for a future wave
(more source documents, ideally some derived from genuinely
richer/real-world content rather than more hand-authored minimal flat-
ODF, plus xlsx/docx once the corresponding Tessera bridges exist - see
next point).

### Real findings this probe surfaced (empirical, re-run today, not
guessed)

1. **No Writer EXPORT path in Swift at all, independent of environment.**
   `WriterBridgeFilter` is import-only (odt/rtf -> docx via soffice ->
   `TesseraFormatBridge`/python-docx -> `DocumentAST`) - its own doc
   comment says DOCX/HTML export goes through `TesseraFormatBridge`
   directly. So the ONLY available Writer round-trip shape uses
   `TesseraFormatBridge.exportFile`/`.importFile` for BOTH halves, which
   needs python-docx. **python-docx is NOT installed on this machine**
   (`python3 -c "import docx"` -> `ModuleNotFoundError`, confirmed
   today; `openpyxl` IS installed but unused, since `CalcBridgeFilter`
   only round-trips ods/xls, never xlsx). Every Writer fixture in this
   run reports `.skipped` via the caught `missingLibrary` error - not a
   Tessera code defect, an environment gap. The test itself is real and
   will score for real wherever python-docx is present (e.g. a CI image
   with it installed).
2. **CalcBridgeFilter's documented scope means the corpus honestly
   cannot exercise charts/themes/conditionalFormats/masters for Calc at
   all**, independent of fixture richness - its own doc comment states
   plainly: "no cell formatting, no named ranges/validation/conditional
   formatting" (CSV-bounded by design). The `ConditionalFormat`
   registry (1.12) and `DataValidation` (1.13) exist as Swift models
   with ZERO round-trip I/O path to any file format today. This is
   exactly the class of gap 6f's harness is supposed to surface, not
   paper over - recorded here rather than manufactured into a fake
   "passing" fixture.
3. **No `office:theme`/`a:theme`/`theme1.xml` wiring exists ANYWHERE in
   `Sources/TesseraCore`** (grepped, zero hits). `Theme`/`ThemeStore`
   (1.5) is a pure Swift model with no file-format bridge yet for any
   material. The harness's "themes" axis has no code path to test for
   ANY fixture, regardless of corpus size - a P2 prerequisite, not
   something more fixtures would fix.
4. **Hand-authored minimal ODF `style:master-page`/`presentation:notes`
   elements do not survive LibreOffice's own real ODP import/export
   cycle**, confirmed empirically today (not assumed): converted
   `master-theme-slides.fodp` (2 named masters with distinct
   `draw:fill-color`, one slide with a `presentation:notes` block) to
   `.odp` via real soffice, then back to `.fodp` to inspect - LO
   collapsed BOTH custom masters into a single regenerated "Default"
   master carrying an `loext:theme` block with LO's own default theme
   colors (not mine), and the slide's authored notes text is gone
   entirely (the `presentation:notes` element that survived is LO's own
   regenerated scaffold, empty of my text). Tried adding a minimal
   `style:page-layout`/`style:page-layout-name` link (a plausible
   missing-requirement guess) - same collapse, so the real requirement
   is deeper than that (LO's own generated master carries a full
   `loext:theme`/placeholder-frame apparatus that a hand-authored
   minimal master apparently must match to be accepted as distinct,
   which was not reverse-engineered further this wave). Titles DID
   survive correctly (verified: both "Blue Master Slide"/"Green Master
   Slide" present after the same round trip) since
   `LOBridgeDeckIO.mapToSlideDeck`'s title extraction only needs a
   plain `draw:frame`/`presentation:class="title"`, no page-layout
   apparatus. Practical effect: `master-theme-slides.fodp/.odp/.pptx`
   still meaningfully exercises `slideCount`/`slideTitles` in the
   harness; `masterBackgrounds`/`slideNotes` will show `expected: 0`
   for this fixture (the scoring code already handles this gracefully -
   see `RoundTripAxisScore.percentage`'s `nil`-when-unexercised
   contract - no false pass, no crash). A real multi-master/notes ODP
   fixture for this harness needs either a genuinely Impress-authored
   source file, or further LO schema reverse-engineering, before
   `masterBackgrounds`/`slideNotes` show non-zero `expected` counts.
   `ODGBridgeFilter`'s equivalent Draw construct (custom named layers +
   a connector, via `draw:layer-set` under `office:master-styles`) WAS
   independently re-verified to survive a real round trip today
   (matches `ODGConnectorWireFormatProbeTests.swift`'s own existing
   finding) - this is a Draw-vs-Impress LO-importer difference, not a
   general "custom ODF metadata never survives" rule.
5. **Plain literal cell values round-trip losslessly** through
   `CalcBridgeFilter`'s CSV pipeline - verified via a direct `soffice
   --convert-to csv` probe on `basic-cells.ods`/`multi-column.ods`
   (numeric text like "10"/"9.5" survives byte-for-byte, no unwanted
   ".0" suffixes or locale reformatting). This is the one axis
   `RoundTripCorpusTests` asserts a hard 100% floor on.

Files added: `Tests/TesseraCoreTests/Support/RoundTripCorpus.swift`,
`Tests/TesseraCoreTests/RoundTripCorpusTests.swift`, and the fixtures
under `Tests/TesseraCoreTests/Fixtures/RoundTrip/` (4 new flat-ODF
sources + 10 soffice-derived binaries, listed above).

## Item 5: Test-coverage completion lane

**Status: 1 of the requested 2-3 suites done this wave; explicitly
continues into P2-A per the item's own allowance.**

Added `Tests/TesseraCoreTests/Engine/DateFunctionsTests.swift`
(`FormulaEngine/Functions/DateFunctions.swift`: EDATE, EOMONTH, WORKDAY,
NETWORKDAYS, YEARFRAC) - real contract-derived tests (each function's
own published `FunctionSignature`/`FunctionParameter` description text,
same standing as the existing `LookupFunctionsTests.swift` precedent,
plus hand-computed calendar arithmetic against real 2023/2024 dates
chosen specifically to avoid month-end/leap-day ambiguity where the
description text doesn't pin the exact rule). Covers: EDATE forward/
backward + error propagation; EOMONTH same-month/leap-Feb/non-leap-Feb;
WORKDAY with and without an explicit holiday; NETWORKDAYS inclusive
count, with holiday, and the reversed-dates-negative-count case (a
well-known, spec-level Excel NETWORKDAYS behavior, not implementation-
specific); YEARFRAC basis 0 (US 30/360) for a half-year and a full year,
plus the out-of-range-basis `#NUM!` trap. Scope cut, stated in the
file's own header: YEARFRAC bases 1/2/3/4 (leap-day-aware
actual/actual, multi-year averaging) are NOT covered - hand-computing
those correctly without being able to execute the suite locally this
session was judged too risky to take on. Also disclosed inline (same
transparency the `LookupFunctionsTests.swift` author gave for the
identical situation): this file's author read `DateFunctions.swift`'s
full implementation before writing the assertions (required for other
item-4/item-1 work this session), so the prime rule's clean
before-I-touch-the-code independence cannot be claimed here, though
every expected value was still computed from the published contract +
real calendar facts, not copied from watching the code run.

**Not reached from the original "not reached" list (unchanged from
before this wave, named per the item's own requirement):**
`NumberFormatEngine`'s deep grammar; `CriteriaFunctions`,
`FinancialFunctions`, `StatisticsFunctions`, `ArrayFunctions` (the
other 4 FormulaEngine function-library files named in the brief);
`Tools/` agent-tool schema round-trip tests; `ChartRenderer`/
`DeckExportCoordinator` dedicated suites.

## Item 6: Contract stubs

**Status: (a) and (b) already complete from a PRIOR wave (discovered,
not redone); (c) stub written this wave, test not added (time).**

(a) **LookupFunctions per-function taxonomy (VLOOKUP/HLOOKUP/MATCH/
XLOOKUP/INDEX/CHOOSE)**: already done. `Tests/TesseraCoreTests/Engine/
LookupFunctionsTests.swift` exists and is exactly this contract-stub
shape (grounded in each function's own published description text, per
its own header comment), with the contract-gap note recorded in
`docs/.scratch/test-rewrite-findings-calc.md` ("Contract gaps" section).
Confirmed by reading both files today rather than assuming from the
filename. No further action taken - redoing it would be duplicate work
against an already-ratified-shape stub.

(b) **TesseraToolRegistry.default's tool roster + TesseraActionClass
.destructiveVerbs' word list**: already done. `Tests/TesseraCoreTests/
Agent/TesseraToolRegistryTests.swift` and `.../TesseraActionClassTests
.swift` both exist, referenced from `test-rewrite-findings-t1.md` /
`test-rewrite-findings-materials-data-workflow.md`. No further action
taken for the same reason as (a).

(c) **RecurrenceRule's own RRULE grammar (FREQ/INTERVAL/COUNT/UNTIL/
BYDAY) beyond `CalendarEvent.occurrences(in:)`'s end-to-end behavior**:
confirmed as a REAL, still-open gap -
`test-rewrite-findings-materials-data-workflow.md` explicitly names it
("the parser's own fixture+property coverage, per doctrine rule 9, was
not attempted"). Best-evidence contract stub, derived from
`RecurrenceRule.swift`'s own doc comment + its `Frequency`/`Weekday`/
`ParseError` types (not from reading `init(rrule:)`'s parsing body or
`occurrences(in:)`'s expansion body - only the type-level surface):

```
RecurrenceRule contract stub (derived 2026-08-15, for architect
ratification - NOT yet tested against):

Grammar (RFC 5545 subset, semicolon-delimited "KEY=VALUE" parts):
  FREQ=<DAILY|WEEKLY|MONTHLY|YEARLY>   required, exactly once
  INTERVAL=<positive integer>          optional, default 1
  COUNT=<positive integer>             optional, mutually exclusive
                                        with UNTIL (RFC 5545 3.3.10 -
                                        NOT confirmed enforced here,
                                        both fields are independently
                                        optional on the struct)
  UNTIL=<date/date-time>               optional
  BYDAY=<comma-separated MO,TU,WE,TH,FR,SA,SU>
                                        optional; RFC 5545 also allows
                                        an ordinal prefix (e.g. "2MO")
                                        for MONTHLY/YEARLY - the type's
                                        ParseError.unsupportedOrdinal
                                        case implies ordinals are
                                        REJECTED, not silently dropped
                                        (parser throws rather than
                                        half-interpreting, per the
                                        type's own doc comment)
  BYMONTHDAY=<comma-separated ints>    optional, MONTHLY only per name
  BYMONTH=<comma-separated ints 1-12>  optional, YEARLY only per name

Defaults when the relevant BY* is empty (from field doc comments):
  WEEKLY with no BYDAY   -> the anchor date's own weekday
  MONTHLY with no BYMONTHDAY -> the anchor date's own day-of-month
  YEARLY with no BYMONTH -> the anchor date's own month

Anything outside this subset -> init(rrule:) throws a ParseError
case (empty/missingFrequency/unknownFrequency/unknownPart/
invalidValue/unsupportedOrdinal), never a partial/best-effort parse.
```

No test was written against this stub this wave (time budget spent on
items 1-4 and the one item-5 suite per the item's own explicit lower
priority). Recorded here per doctrine so the next wave can pin it
(with `XCTExpectFailure` wrapping if the parser's actual behavior
disagrees with any line above) rather than the gap staying silent.
