# Test-rewrite wave report (2026-08-15)

**Scope:** rewrite the Tessera Studio test suite from scratch under
`docs/testing-doctrine.md`, after the pre-doctrine suite (247 files) was
deleted at `54d9b54cb`. Five clusters (T1-T5), dispatched via the
Workflow tool per the architect's explicit multi-agent opt-in; T1 ran
solo first (shared timeout support), T2-T5 ran in parallel after.

## 1. Suites written per area

139 new test files (up from the 1-file placeholder), organized as 28
per-suite-cluster commits (`git log --oneline` on this branch,
`tests(<area>): ...` subjects):

| Cluster | Area | Files | Commits |
|---|---|---|---|
| T1 | Support (shared doctrine timeout watchdog) | 1 | 1 |
| T1 | Agent/ (agent-ux-fatigue: tier, budget, citations, stop, audit log) | 19 | 1 |
| T1 | Encryption/ (notification budget, Plead-the-Fifth, data root) | 13 | 1 |
| T1 | Learning/ (self-improving-loop safety spine, partial: 7 of 38 files) | 7 | 1 |
| T1 | Editor/ (TimeLimitedUndo, AuditLogHead - exact-file exception) | 2 | 1 |
| T2 | Engine/ (FormulaEngine: dynamic arrays, volatility, precedence) | 7 | 1 |
| T2 | Sheets/ (QueryEngine, ConditionalFormat, DataValidation, comments) | 5 | 1 |
| T2 | Sheets/ (SheetStore mutation quartet) | 3 | 1 |
| T3 | Draw/ (pure engine + value types) | 9 | 1 |
| T3 | Draw/ (DrawingStore receipts law) | 2 | 1 |
| T3 | Slides/ (Theme, TransitionSpec, layout picker, value types) | 6 | 1 |
| T3 | Views/Renderers/ (SlideDeckRenderer) | 1 | 1 |
| T3 | ImportExport/ (ODG connector probe, FlatODF writer rules) | 3 | 1 |
| T4 | Writer engines (StyleRegistry/FieldController/RevisionController/DocumentSearchIndex) | 5 | 1 |
| T4 | Slides/ (1.20 AnimationEffectList fixture exception) | 1 | 1 |
| T4 | Docs/ (Doc/DocReceiptType/DocStore) | 3 | 1 |
| T4 | Productivity/ (Block/Mutation/Receipt/ReceiptSigner/ReceiptUndoManager/DocumentStore) | 7 | 1 |
| T4 | Productivity/ (Comments/TableLayout/TextCursor/DocumentExporter) | 4 | 1 |
| T4 | Receipts/ (ReceiptsCoordinator/MaterialReceiptPayload/ReceiptExportService/C2PA) | 4 | 1 |
| T4 | Editor/ (DiffProvider, EditorCursorState, EditorMode, IntTextLocation, TextEditReducer, EditorCoalescer) | 6 | 1 |
| T5 | Materials/Calendar | 5 | 1 |
| T5 | Materials/Email | 3 | 1 |
| T5 | Materials/Notes | 3 | 1 |
| T5 | Materials/Reminders | 5 | 1 |
| T5 | Materials/Tasks | 3 | 1 |
| T5 | Materials/Code | 3 | 1 |
| T5 | Contacts/ + Materials/Contacts/ | 4 | 1 |
| T5 | Graph/ | 2 | 1 |
| T5 | ChatQueueItem | 1 | 1 |
| T5 | Data/ (TesseraDataStore/Cache/DataLayer foundation) | 4 | 1 |

**Not reached this wave** (honest gaps, not silently dropped - see each
cluster's findings file for the full itemized list):
- Learning/: ~20 of 38 files (TesseraApproverNetwork, TesseraS2SRecord,
  TesseraSessionScorecard, TesseraAutonomyService's real ratchet, the
  Adaptation/AssessmentScheduler `onFinished` hooks named in AGENTS.md
  item 1D, and others).
- Editor/ (top-level): 8 of 15 files (BlockRenderer,
  TesseraTextContentManager, TesseraWritingToolsCoordinator,
  TesseraGhostTextManager, CodeBlockHighlighter, TesseraTextElement,
  AnimationPrimitives, ImageLoader) - large, AppKit/TextKit-coupled
  files needing careful seam identification.
- Slides/Draw: SlideDeck's own round-trip test, most of SlideStore's
  mutation methods, MasterPageStore, SlideReceiptType/
  DrawingReceiptType vocabulary guards, ThemeStore/TransitionStore's
  own DB-gated mutation tests, LOBridgeDeckIO, SVGBridgeFilter,
  PDFExportBridge, WriterBridgeFilter, CalcBridgeFilter,
  ChartRenderer, ShapeRenderer, DeckExportCoordinator (dedicated
  files - exercised only transitively via other tests).
- Calc: SheetsViewModel, SheetsGraphConnector, SpreadsheetDigester,
  NumberFormatEngine's deep grammar, Lexer/Parser dedicated suite,
  FormulaReferenceAdjuster, CriteriaFunctions/FinancialFunctions/
  StatisticsFunctions/DateFunctions/ArrayFunctions.
- T5: Workflow/, StateGraph/, LLMProviders/, Tools/ (39 agent-tool
  files), Models/, Ops/, Settings/, Skills/, MoE/, Speech/, plus the
  Materials engine/controller/adapter files beyond each material's
  Store+model (NLU parsers, chat adapters, view-models, import
  adapters, notification scheduler, git/file-watcher).

## 2. Test counts and timings

- **Default suite** (no gates): 1635 tests, 132 skipped (DB/soffice-
  gated), **0 unexpected failures**, 18.167s wall (well under the
  5-minute doctrine target). 3 raw "failures" reported are the
  doctrine-sanctioned `XCTExpectFailure` findings that happen to run
  ungated - these are green by design.
- **`TESSERA_DB_INTEGRATION=1` pass**: see section 4 - this branch's
  first-ever real DB-integration run (previously "UNVERIFIED" per
  `p1-post-claim-audit-2026-08-15.md` §5).
- **soffice pass**: satisfied by the default suite run itself -
  soffice is genuinely installed (LibreOffice 26.2.5.2), so soffice-
  gated tests are never skipped on this machine; `ODGConnectorWireFormatProbeTests`
  took 11.1s of real `soffice --convert-to` subprocess time and
  passed cleanly. No separate soffice-only invocation was needed.

## 3. XCTExpectFailure findings (contract-true, fails against current code)

Per-cluster findings files: `docs/.scratch/test-rewrite-findings-{t1,calc,t2-slides-draw,writer,materials-data-workflow}.md`.

| Test | File | Suspected bug |
|---|---|---|
| testToolResultPayloadDecodesFromLegacyJSONWithNoSourcesField | Agent/ChatMessageCitationTests.swift | `ToolResultPayload.sources` is non-Optional `[Citation]` with no custom decoder; synthesized `Decodable` requires the key and throws `keyNotFound` on pre-3A JSON instead of defaulting to `[]`. |
| testRandomPassesUnderDirectoryFinalPassWritesZeroBytes | Encryption/SecureOverwriteTests.swift | `SecureOverwrite`'s documented final zero-pass never writes zeros - `writeRandomPass()` unconditionally re-invokes `randomFill()` first, discarding the pre-zeroed buffer. |
| 6 tests in TesseraDataRootTests.swift | Encryption/TesseraDataRootTests.swift | `insideVolume(subdirectory:fallbackFile:)` applies its two parameters asymmetrically between branches - mounted appends `subdirectory` but ignores `fallbackFile`; sandbox-override ignores `subdirectory` but applies `fallbackFile`. Breaks `appSupport()`/`caches()`/`preferences()` under a sandbox override and `duckdbFile()` while mounted. |
| 8 tests (archive/unarchive/trash/restore/favorite/unfavorite/addTag/removeTag no-ops) | Productivity/Materials/Sheets/SheetStoreTests.swift | Same failure class as the already-known DrawingStore defect: each method appends its receipt unconditionally even on its own documented no-op branch. |
| 5 tests (removeLayer/renameLayer/reorderLayers/setLayerVisibility/setLayerLock, unknown id) | Productivity/Materials/Draw/DrawingStoreTests.swift | The originally-audited defect (`p1-post-claim-audit-2026-08-15.md` Class A item 1), confirmed still present at HEAD: layer mutations upsert + emit a receipt on a no-op. |
| testStylePropertiesTextColorAcceptsThemeReferencePerColorRefContract | Productivity/Materials/Slides/ThemeTests.swift | `StyleProperties.textColorHex` still a literal `String?`, not `ColorRef` (1.5, ColorRef adopted 1-of-3). |
| testShapeFillColorAcceptsThemeReferencePerColorRefContract | Productivity/Materials/Draw/ShapeTests.swift | `ShapeFill.colorHex` still a literal `String`, not `ColorRef` (same 1.5 gap). |
| testAllBuiltinSlideLayoutPlaceholdersHaveFrameU | Productivity/Materials/Slides/SlideLayoutSpecTests.swift | No builtin `SlideLayoutSpec` placeholder carries `frameU` (1.7). |
| testTitleContentSlideRendersNonOverlappingPlaceholderBands | Views/Renderers/SlideDeckRendererTests.swift | Renderer-level demonstration of the same frameU gap: two distinct content slots resolve to the identical default frame. |
| testThreadsFromDocumentBuildsRootMessagePlusReplies | Productivity/CommentsTests.swift | `CommentStore.threads(from:)`'s build-threads pass has no guard excluding reply blocks, so a reply is double-counted as its own separate thread as well as folded into its parent's messages. |
| testFilenameFromPathFallsBackToWholeStringForEmptyLastComponent | Productivity/Materials/Code/CodeFileTests.swift | `URL(fileURLWithPath: "")` resolves relative to the process's CWD rather than producing an empty URL, so `filenameFromPath("")`'s own fallback never triggers - returns the CWD's directory name instead of `""`. |

Group/ungroup (1.19 row 48) and the `ReceiptUndoManager.group(_:)`
Draw-canvas wiring are **not** XCTExpectFailure findings - no callable
symbol exists yet to test against (doctrine's "contract not testable"
path, distinct from "contract-true test fails"). See
`GroupUngroupContractStubTests.swift` and
`test-rewrite-findings-t2-slides-draw.md`.

## 4. `TESSERA_DB_INTEGRATION=1` pass - infrastructure notes

No local Postgres/Valkey was running at the start of this gate. Set up
and run log:

- Valkey: already running (`valkey-cli ping` → `PONG`).
- Postgres: Homebrew `postgresql@17` had a stale `postmaster.pid` lock
  (the recorded PID had been reused by an unrelated process after an
  unclean prior shutdown) blocking `brew services start`; removed the
  stale lock (standard, non-destructive Postgres recovery - the data
  directory itself was untouched) and started the server directly via
  `pg_ctl`. Created the `tessera` role/database matching
  `TesseraDataStore.Configuration`'s default (`localhost:5432`,
  `tessera`/`tessera`).
- **Two real, pre-existing bugs found in `tools/tessera/db/migrations/*.sql`**
  while applying the schema (not fixed in the repo - worked around
  locally only, to unblock this gate; out of scope for a test-writing
  wave):
  1. `graph_entities.body` is declared `text` (migration 0001), but
     migrations 0004-0006/0008-0012 use the `->>'` jsonb operator on
     it directly, which fails against a plain `text` column
     (`operator does not exist: text ->> unknown`). The intended dev
     environment uses a `pgvector/pgvector:pg16` Docker image per
     `tools/tessera/db/Makefile`'s own comments - this class of error
     may be masked there by some difference this investigation didn't
     fully characterize, or may be a genuine latent bug regardless of
     environment. Worked around locally with `body::jsonb->>` casts
     applied to a scratch copy of each affected migration (the actual
     `.sql` files in the repo are untouched).
  2. Migration 0013 redefines `hybrid_search(uuid,text,vector,integer)`
     with a different return-row shape than migration 0001's version,
     without a `DROP FUNCTION` first - Postgres rejects this
     (`cannot change return type of existing function`). Worked around
     locally with an explicit `DROP FUNCTION` before re-applying 0013.
- After both workarounds, all 14 migrations applied cleanly (8 tables
  created: `graph_entities`, `entity_links`, `graph_receipts`,
  `receipt_chain`, `chat_queues`, `disclosure_log`,
  `deletion_attestations`, `graph_checkpoints`).

**Result: this branch's first-ever real `TESSERA_DB_INTEGRATION=1`
run.** 1634 tests, 4 skipped, **18 unexpected failures** (down from
128 before the schema existed at all). Categorized, not individually
diagnosed further within this wave's scope (fixing source is Wave
P2-0's job; distinguishing "real bug" from "artifact of this ad-hoc
local Postgres setup vs. the intended Docker environment" needs more
investigation than this gate's time budget allowed):

- **~7 tests, redacted `PSQLError` on delete/link operations**
  (CalendarStoreIntegrationTests, CodeStoreIntegrationTests,
  ContactStoreIntegrationTests, DocStoreTests, DocumentStoreTests,
  EmailStoreIntegrationTests, NoteStoreIntegrationTests,
  ProductivityTaskStoreIntegrationTests, ReminderStoreIntegrationTests).
  PostgresNIO's `PSQLError` description is deliberately redacted
  ("Generic description to prevent accidental leakage of sensitive
  data"); the equivalent raw SQL (`DELETE FROM graph_entities WHERE
  id = ...`, the `entity_links` upsert) runs cleanly via plain `psql`,
  so the failure is specific to the PostgresNIO wire-protocol path,
  not the SQL itself. Root cause not identified.
- **~5 tests, `Optional(X)` "not equal to" an identical-looking
  `Optional(X)`** (CalendarStoreIntegrationTests, ContactStoreIntegrationTests,
  EmailStoreIntegrationTests, NoteStoreIntegrationTests,
  ReminderStoreIntegrationTests, each `testUpsertPersists...`). Very
  likely the same Date()-precision-vs-`.iso8601`-truncation pattern
  fixed throughout this wave's ungated tests (section 5), in DB-gated
  call sites that could not be reached during the earlier remediation
  pass since the DB gate was closed then. Not confirmed or fixed.
- **2 tests, receipt-count mismatches** (SheetStoreTests
  testDeleteRowOfTheLastRemainingRowThrowsWithoutPersistingOrReceipting,
  testUndefineNamedRangeOfAnUndefinedNameIsANoOpEmittingNoReceiptAndNotPersisting).
  Possibly a further instance of the receipts-law violation pattern
  already documented in section 3, or state carried over between test
  runs on a persistent (non-reset-per-run) local database. Not
  distinguished.
- **1 test, `FieldControllerTests.testSequenceFieldNumbersFromDocumentOrderAmongSameName`**
  (three assertion failures) - notable because this is a *pure,
  ungated* test with no DB dependency, yet it passed cleanly in the
  default-suite run and only fails here, when more tests execute
  before it. Suspected non-deterministic behavior (possibly
  `FieldController`'s sequence-numbering relying on `Dictionary`
  iteration order rather than a stable document-order traversal) -
  flagged as a genuine finding worth its own investigation, not
  wrapped in `XCTExpectFailure` here since it was not reproduced
  standalone within this gate's time budget.
- **1 test, `GraphStoreIntegrationTests.testSearchFindsAnUpsertedNoteByLabelPrefix`** -
  not investigated.

## 5. Contract-true test fixes applied during the centralized build/test pass

None of the following are XCTExpectFailure findings - they are test-
authoring corrections (the contract was right, the test's own
construction was wrong), applied directly. Full detail in each
cluster's commit body; summarized here for completeness:

- **Systemic Date()-fixture pattern** (doctrine rule 4: no bare
  `Date()` in fixtures): CalendarEvent, ChatQueueItem, CodeFile,
  Contact, EmailMessage, Note, ProductivityTask, Reminder, Doc,
  Drawing, and Receipt/ReceiptExportService test fixtures all left
  `createdAt`/`updatedAt`/`timestamp`/`receivedAt`/`modifiedAt`
  defaulted to `Date()`; round-tripping through each type's
  `.iso8601` JSON strategy truncates fractional seconds, so the
  original never equaled the decoded value even though both would
  print identically at whole-second resolution. Fixed by passing
  explicit whole-second `Date(timeIntervalSince1970:...)` fixtures
  throughout (11 files).
- **Swift labeled-argument ordering**: two calls (`StyleProperties(...)`,
  `Block(...)`) passed keyword arguments out of declaration order,
  which Swift rejects even when skipping defaulted parameters -
  reordered.
- **`await` inside `XCTAssert*` autoclosures**: several files called
  an actor-isolated method directly inside an assertion argument
  (`XCTAssertFalse(await x.isArmed)`), which doesn't typecheck; hoisted
  into a local `let` first (`TesseraNotificationBudgetTests`,
  `CovertTriggerMonitorTests`, plus a handful of single-line instances
  elsewhere).
- **`try` inside `XCTExpectFailure` closures wrapping `XCTAssertNoThrow`**:
  the closure's throwing effect leaked out, requiring `try
  XCTExpectFailure(...)` - restructured to hoist the `try?` decode
  attempt outside the closure and assert on the captured `Optional`
  result instead (`ThemeTests`, `ShapeTests`, `ChatMessageCitationTests`).
  Also caught the same pattern one file used with a genuinely-
  throwing helper it didn't need (`try XCTUnwrap` needing the
  enclosing test marked `throws`) - `TesseraMiscalibrationDetectorTests`.
- **Off-by-one path resolution**: `AnimationEffectListP1FixtureTests`'s
  fixture-path computation stripped 3 path components when it needed
  4 (the first `deletingLastPathComponent()` strips the file's own
  filename, not "Slides" as the inline comment assumed).
- **Test-isolation bug in a property test**: `testTighteningIsPerClassNotGlobalByDefault`
  exercised only one action class, making its own per-class window and
  the global window (a single chronological stream of every class's
  outcomes) mathematically identical - both tightened together,
  defeating the point of the test. Fixed by interleaving a second,
  always-approved class to keep the global rate diluted.
- **Wrong assumption about uniform no-op behavior**: two `TesseraNoop*Service`
  tests assumed every no-op service silently succeeds; `ingest`/
  `record` (recording actions, unlike their read-only siblings)
  deliberately throw `.notConfigured` per source - rewritten to assert
  the throw.
- **Byte-identical comparison across two separately-constructed
  fixtures**: `Sheet.makeBlank(...)` mints fresh random UUIDs per call,
  so comparing JSON bytes between two independent calls can never
  match regardless of correctness - fixed to snapshot the original
  sheet before mutating it.
- **Reused fixture identities across independently-constructed values**:
  `RevisionControllerTests`'s order-invariance tests called a
  fixture-builder helper twice (fresh random block ids each call) but
  kept using the first call's ids against the second call's AST -
  fixed by threading explicit shared ids through both calls.
- **Dead test-helper parameter**: `signedReceipt(summary:...)`'s
  `summary:` argument was never threaded into `ReceiptSigner.sign`
  (which has no such override - it always derives the summary from
  the mutation list); fixed the one test that depended on the literal
  string to assert against the receipt's own actual computed summary
  instead.
- **`.gitignore` false-positive**: the repo-root personal `Notes/`
  ignore rule incidentally matches the deeper
  `Tests/.../Materials/Notes/` path; force-added per this repo's own
  documented precedent (the `.gitignore` comment already explains the
  workaround, used previously for `Sources/.../Notes/`).

## 6. Contracts not located (per doctrine: listed, not guessed)

- `LookupFunctions`' per-function numeric/error-taxonomy spec table
  (VLOOKUP/HLOOKUP/MATCH/XLOOKUP/INDEX/CHOOSE) beyond each function's
  own `FunctionParameter` description text.
- `TesseraToolRegistry.default`'s exact ~29-tool roster and
  `TesseraActionClass.destructiveVerbs`' exact word list - no design
  doc names either exhaustively.
- `ReceiptUndoManager.group(_:)`'s one-drag-one-undo Draw-canvas
  wiring and group/ungroup (1.19 row 48) - no callable symbol exists.
- `Materials/Calendar/RecurrenceRule.swift`'s own RRULE-parser grammar
  (FREQ/INTERVAL/COUNT/UNTIL/BYDAY) beyond `CalendarEvent.occurrences(in:)`'s
  end-to-end behavior.
- No in-memory/stub `TesseraDataLayer` exists anywhere in this
  codebase, so doctrine rule 11's required ungated shadow could not be
  built for `DocStore`/`DocumentStore`/`ReceiptExportService.export`
  from a Tests/-only change - documented as a real, unclosed
  architectural gap (not every *Store has this problem: `ReminderStore`/
  `CalendarStore` ship a `*Storing` protocol seam with an in-memory
  fake specifically to close it; most others do not).

## 7. Commits

28 commits on `scratch/studio-p1/agent-a`, one per suite-cluster,
subject format `tests(<area>): <what the suite enforces>` (see `git
log --oneline` for the full list). `DoctrinePlaceholderTests.swift`
deleted in the first commit once real coverage existed.
