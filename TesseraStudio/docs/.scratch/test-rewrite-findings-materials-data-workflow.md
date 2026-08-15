# Findings: Materials + Data + Workflow + misc cluster (test-rewrite wave)

Cluster id: `materials-data-workflow`. Doctrine: `docs/testing-doctrine.md`.

One row per XCTExpectFailure (suspected code bug), plus a section for
contracts that could not be located (doctrine: write the test you CAN
write, note the gap, never guess and silently skip).

## XCTExpectFailure rows (suspected code bugs)

(appended as found)

## Contract gaps (no doc source found; behavior tested from doc-comment
## fallback per the hierarchy, or left untested with a note)

- **Top-level `Contacts/` engine + `Graph/`**: correction to this cluster's
  earlier assumption -- `docs/tessera-productivity-contacts-graph-design.md`
  ("Phase 6: Contacts + Graph visualization") DOES cover both (its title
  reads as graph-only but section 3 is the `Contact` model and section 15
  names the exact historical test files: `ContactTests`, `ContactStoreTests`
  (receipt types + egress guard allow-list + store error equality),
  `ContactStoreIntegrationTests` (round-trip, receipt appended, egress
  policy), `GraphModelTests` (node identity, short label cap, icon
  mapping, edge style + line width, empty snapshot, adjacency,
  neighbors hop expansion). This cluster's
  `ContactTests.swift`/`ContactStoreTests.swift`/
  `ContactStoreIntegrationTests.swift`/`GraphModelTests.swift` were
  written from doc comments BEFORE this doc was located mid-pass and
  turned out to match its section-15 test strategy closely on
  cross-check (same coverage areas, independently derived) -- read as
  confirmation, not as grounds to rewrite. The four importer adapters
  named in section 15 (`VCardImporterTests`/`GoogleContactsAdapterTests`/
  `CardDAVImporterTests`) and `GraphViewModelTests` were not reached this
  pass (see areasNotReached). `GraphStore` is read-only (no mutation
  methods, no receipts) -- the doctrine's Store-mutation coverage shape
  does not apply to it as written; see the architectural note below.
- **`ChatQueueItem.swift`** (`Sources/TesseraCore/Productivity/
  ChatQueueItem.swift`) has no design doc; tested purely from its own
  public API + doc comments, exactly as the wave brief anticipated
  ("reconstruct the shape ... purely from ChatQueueItem.swift's own
  public API and doc comments").

## Areas not reached this pass (time budget; honest gap, not a rushed
## shallow pass -- listed per the instructions rather than silently
## skipped)

Priority-1 (the mandated Store quartet across Materials/{Calendar, Email,
Notes, Reminders, Tasks, Contacts, Code} + Chat/ + Graph/ + Contacts/) is
DONE for every Store this cluster found: CalendarStore, EmailStore,
NoteStore, ReminderStore, ProductivityTaskStore, CodeStore, ContactStore
(top-level), GraphStore (read-only, see note below). `ChatQueueStoring`
(the one Store-shaped seam in `Chat/`) has a doc comment naming
`DocumentStoreChatQueueStore` as its production implementation, which
wraps `DocumentStore` -- a type this cluster does not own or have context
on (belongs to the Docs material, a different cluster this wave); its
quartet was not attempted rather than guessing at `DocumentStore`'s
contract. `ChatQueueItem`/`ChatQueue` themselves (the pure value types
`Chat/`'s state machine persists) ARE fully tested (see
`Tests/TesseraCoreTests/Productivity/ChatQueueItemTests.swift`).

Not reached, by directory:

- **Materials/Calendar**: CalendarChatHandler, CalendarNLUParser,
  CalendarResolvers, CalendarViewModel, EventKitAdapter, RecurrenceRule
  (the RRULE parser/expansion engine itself -- `CalendarEventTests.swift`
  exercises `occurrences(in:)` end-to-end through a couple of RRULE
  strings, but the parser's own fixture+property coverage, per doctrine
  rule 9, was not attempted), Views/.
- **Materials/Email**: EmailChatAdapter, EmailComposer, EmailSender,
  EmailImporter, EmailContextExtractor, IMAPAdapter.
- **Materials/Notes**: NoteChatCommand, NoteListFilter, NotesViewModel.
- **Materials/Reminders**: ReminderAgentTools (explicitly an "Agent tool"
  per the doctrine's coverage-shape table -- schema round-trip + tier +
  receipt + denial path was not attempted), ReminderListViewModel,
  ReminderNotificationScheduler (its pure static helpers --
  `identifier(for:)`/`effectiveFireDate(for:now:)`/`isFireDateInPast(for:now:)`
  -- are exactly the kind of thing doctrine rule 9 wants and were not
  reached), ReminderParsing.
- **Materials/Tasks**: ProductivityTaskChatPanelBridge,
  ProductivityTaskFilter, ProductivityTaskGraphIntegration,
  ProductivityTaskNLUParser.
- **Materials/Code**: CodeFileTree, CodeFileWatcher (real fs + real
  DispatchSource per the design doc -- a real-I/O candidate, not
  attempted), CodeMutation (the mutation ENGINE's own fixture coverage
  beyond the one smoke-tested `.replaceCodeBlock` case in
  `CodeStoreTests.swift`/`CodeStoreIntegrationTests.swift` -- addTag/
  removeTag/replaceCodeRange/insertCodeAt/linkTo/unlinkFrom and their
  validation-error paths were not reached), CodeOutline, CodeSearchIndex,
  CodeSurfaceViewModel, GitReadOnly (a `Process`-shelling type --
  doctrine rule 10 empirical-probe territory).
- **Top-level Contacts/**: AppleContactsAdapter, CardDAVImporter,
  GoogleContactsAdapter, VCardImporter.
- **Chat/**: AgentContext, ChatPanelStateMachine, ChatPanelViewModel,
  ChatQueueItemStyle, ChatQueueStoring's `DocumentStoreChatQueueStore`
  (see above), CrossDocumentChatRegistry, HoldMode, MatchAndSupersedeEngine.
- **Graph/**: GraphViewModel (beyond what `ContactsGraphConnectorTests.swift`
  exercises incidentally via `openEntityHandler`/`anchorSet`/`radius`),
  GraphView (a SwiftUI view).
- **Data/** (priority 2): TesseraDataStore and TesseraCache got an
  ungated-shadow pass (closed-state error propagation, Configuration
  parsing/defaults, error-equality) PLUS TesseraDataStore got a gated
  CRUD+receipt-chain integration pass (the foundation every other
  cluster's Store-quartet gated test depends on); TesseraDataLayer got a
  light ungated pass (StartOutcome equality, cacheKey, HybridSearchWeights
  default, closed-propagation spot-checks). NOT reached:
  DuckDBAnalyticsETL, MacPostgresBootstrap, ValkeyGraphCache, and the
  gated half of TesseraCache (a CacheTTLTests-equivalent real-Valkey
  round trip) and TesseraDataLayer (a `.start()` -> `.ready` smoke test
  against real Postgres+Valkey).
- **Workflow/, StateGraph/, LLMProviders/, Tools/** (priority 2): not
  reached at all this pass. Given the cluster's enormous scope (7
  Materials directories + top-level Contacts + Chat + Graph, all with the
  non-negotiable Store quartet, plus Data/ as the shared foundation),
  the time budget was spent achieving REAL, non-shallow coverage of the
  mandated priority-1 surface plus a meaningful start on Data/ rather than
  spreading thin across every remaining directory. `Tools/`'s 39 agent
  tool files (schema round-trip + tier assertion + receipt behavior +
  denial path per the doctrine's "Agent tool" coverage shape) is the
  highest-value remaining gap if this cluster resumes.
- **Models/, Ops/, Settings/, Skills/, MoE/, Speech/** (priority 3): not
  reached at all this pass, consistent with the wave brief's own
  "best effort... list what you did not reach" instruction for this tier.

## Ungated-vs-gated mechanism note (for whoever reads this cluster's tests)

Every ungated "closed-data-layer" test in this cluster relies on ONE
verified fact, read directly from
`Sources/TesseraCore/Data/TesseraDataStore.swift` and
`Sources/TesseraCore/Data/TesseraCache.swift`: every public method on
both actors begins with `guard let client/pool else { throw
.closed }`, BEFORE any network I/O. Constructing `TesseraDataStore()` /
`TesseraCache()` / `TesseraDataLayer()` and never calling `connect()`/
`start()` therefore gives a deterministic, network-free "the backing
store is unavailable" condition -- useful for proving a mutation method
does not silently swallow a lower-layer failure and report false
success, but NOT equivalent to the store's own "not found" contract
(which requires a live, successfully-connected, empty-result query).
Tests are named accordingly (`...OnClosedDataLayerThrows...`, never
"...NotFound...") to keep this distinction honest per the prime rule.

## Architectural notes (per-store seam variance, read before assuming)

- `CalendarStore` and `ReminderStore` each have a `*Storing` protocol
  (`CalendarStoring`, `ReminderStoring`) used by their chat handlers /
  view-models. This is the stub seam used for the doctrine rule-11
  ungated shadow of those two stores' own quartets (via
  `InMemoryCalendarStore` / `InMemoryReminderStore` test doubles built
  in this wave).
- `EmailStore`, `NoteStore`, `ProductivityTaskStore` wrap
  `TesseraDataLayer` directly with NO protocol seam. `TesseraDataLayer`
  itself wraps concrete `actor TesseraDataStore` (real `PostgresClient`,
  no in-memory mode) and `actor TesseraCache` (real Valkey), so there is
  no stub seam at the data-layer boundary either. For these three
  stores the "ungated shadow of the same contract" is only achievable
  for the sub-contract that does not require a live row (validation-
  before-any-IO error paths, e.g. `EmailStore`/`NoteStore`/
  `ProductivityTaskStore`'s `loadOrFail`-style not-found paths raised
  before any `dataLayer` call, and JSON/value-type round trips). The
  receipt + persistence + no-op-with-a-live-row assertions for these
  three stores are DB-gated only (`TESSERA_DB_INTEGRATION=1`); this is
  a genuine architectural gap, not an oversight, and is called out
  per-file below rather than invented around.
- `CodeStore` is the odd one out: `init()` (no `TesseraDataLayer`) is
  the documented unit-test seam ("No Postgres in v1 unit tests" doc
  comment on the type) for the in-memory index (`upsert`/`get`/
  `listAll`/`delete`/`rename`/`apply`). Receipts silently no-op when
  `dataLayer == nil` (`appendReceipt` guards `guard let dataLayer else
  { return }`), so the ungated shadow can verify persistence-into-the-
  index + no-op-index-mutation, but NOT "exactly one receipt" (that
  needs the gated integration test against a real data layer).
- Fire-and-forget material receipts: every store's mutation path also
  kicks an unawaited `Task { try? await dataLayer.appendMaterialReceipt(...) }`
  using a DIFFERENT receipt type (e.g. `CalendarReceiptPayload.receiptType`,
  a single shared type per material) than the store's own synchronous,
  awaited `appendReceipt` call. Tests assert "exactly one receipt of the
  named type" by filtering `receipts(for:)` on the mutation's own
  receipt-type string, which is race-free against the unawaited
  fire-and-forget task (it always uses a different type string).

## Post-dispatch addendum (centralized build/test pass)

- **testFilenameFromPathFallsBackToWholeStringForEmptyLastComponent**
  (Tests/TesseraCoreTests/Productivity/Materials/Code/CodeFileTests.swift):
  SUSPECTED CODE BUG: `CodeFile.filenameFromPath("")`'s own fallback
  ternary (`url.lastPathComponent.isEmpty ? path : url.lastPathComponent`)
  is visibly written to handle a degenerate empty path by returning the
  original path - but `URL(fileURLWithPath: "")` resolves relative to
  the PROCESS'S CURRENT WORKING DIRECTORY rather than producing an
  empty URL, so `lastPathComponent` is never actually empty for this
  input; it returns the CWD's own directory name instead (observed:
  "TesseraStudio"), making the function's result depend on the working
  directory the test happens to run from. Wrapped in
  `XCTExpectFailure`; not fixed here (source change, out of this
  wave's scope).
