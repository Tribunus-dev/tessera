# Bug-fix wave report

Follow-up to `test-rewrite-report.md`: fixes the source bugs behind the 11
`XCTExpectFailure`-wrapped findings from that wave, plus everything the
`TESSERA_DB_INTEGRATION=1` gate surfaced once it was actually run to green.
Branch `scratch/studio-p1/agent-a`, 10 commits, starting tip `7619c5277`.

## Part 1 — the 11 confirmed findings (dispatched as a 6-agent Workflow)

All 11 fixed at the source; each corresponding test unwrapped from
`XCTExpectFailure` back to a plain, passing assertion. Verified: default
suite 1634 tests / 0 failures / 14.5s.

| # | Bug | Fix | Commit |
|---|-----|-----|--------|
| 1 | `SecureOverwrite.writeRandomPass` re-randomized the buffer on every chunk, including the caller's pre-zeroed "final pass" | `refillPerChunk: Bool` flag, `false` on the final pass | `741eb4baa` |
| 2 | `TesseraDataRoot.insideVolume` asymmetric: mounted branch dropped `fallbackFile`, sandbox branch dropped `subdirectory` | Symmetric root-then-file construction in both branches; `appSupport()`'s call site fixed to pass `fallbackFile: nil` | `741eb4baa` |
| 3 | `ToolResultPayload.sources` non-optional with no custom `Decodable`, broke legacy JSON with no `sources` key | Custom `Codable` conformance, `decodeIfPresent(...) ?? []` | `741eb4baa` |
| 4 | 8 `SheetStore` methods (archive/unarchive/trash/restore/favorite/unfavorite/addTag/removeTag) receipted no-ops | Early-return guard before upsert+receipt | `96239f2c9` |
| 5 | 5 `DrawingStore` layer-mutation methods receipted no-ops (audited Class A item 1) | Snapshot `layers` before/after, skip persist+receipt when unchanged | `d4aa8cf0f` |
| 6 | `CommentStore.threads(from:)` double-counted reply blocks as separate threads | Exclude child-of-another-comment-block ids from the top-level pass | `c436ca2b1` |
| 7 | `CodeFile.filenameFromPath("")` returned the CWD's name (Foundation resolves `URL(fileURLWithPath: "")` against CWD) | Explicit empty-path guard before URL construction | `c436ca2b1` |
| 8 | `StyleProperties.textColorHex` / `ShapeFill.colorHex` still raw `String`, not `ColorRef` (item 1.5, "1 of 3" adopted) | Type swap to `ColorRef`; fixed 3 downstream consumers (`StyleRegistry.runOverlay`, `DocumentExporter`, `ShapeRenderer`) | `045dcba2c` |
| 9 | `SlideLayoutSpec` builtins never set `frameU`, so multi-slot layouts rendered overlapping | Added normalized `frameU` rects to all ~29 leaf placeholders across 25 builtins | `c0572102e` |

## Part 2 — found during centralized verification, fixed the same wave

Not part of the original 11 (no `XCTExpectFailure` findings-file entry), but
either broke the default suite outright or made `TESSERA_DB_INTEGRATION=1`
unusable. All confirmed via direct diagnosis (reading the failing assertion,
or unmasking `PSQLError`'s redacted description with a temporary
`String(reflecting: error)` probe, removed before committing).

### FieldControllerTests id/dict-key mismatch (test bug) — `af19c05ed`
`fieldBlock(kind:)` called `Block(type: .field)` (auto-generated `.id`) but
was stored under an unrelated dictionary key (`ast.blocks[firstID] = ...`).
`FieldController.sequenceNumber` finds itself by comparing `block.id`
against the walked ids, so it never matched and silently fell through to
the "detached block" fallback every time — deterministic, not flaky. Fixed
the test helper to accept and use an explicit `id`.

### `graph_receipts` cascade-deletes itself, the real audit-trail bug — `e17f8bb09`
The single highest-impact finding. `graph_receipts.entity_id REFERENCES
graph_entities(id) ON DELETE CASCADE` meant deleting *any* entity
cascade-wiped its entire receipt history, and then the store's own
`delete(id:)` method's subsequent "entity deleted" receipt insert failed
with a foreign-key violation (the parent row it referenced no longer
existed). This explains why every store's delete-path integration test
failed identically with a redacted `PSQLError` — it wasn't 7+ separate
bugs, it was one schema defect. Dropped the FK entirely (this table is the
"constitutional receipt log" per its own doc comment — a permanent
append-only audit trail has no business being cascade-deleted). Verified
via `ALTER TABLE ... DROP CONSTRAINT` on the local dev Postgres, then
carried into `0001_init.sql` for every future apply. `entity_links` and
`receipt_chain`/`chat_queues` keep their existing cascades — correctly
different scope (relational edges / per-document operational state, not
permanent history).

### `entity_links`-requires-a-real-target (test bug, 5 files) — `1f4c8bbaf`
Every store's "link" integration test (Calendar/Contact/Task/Code/Note)
linked to `let targetID = UUID()` without ever inserting that entity.
`entity_links.target_id` is a real FK. The codebase's own canonical pattern
(`TesseraDataStoreIntegrationTests.testLinkEntitiesThenOutLinksReturnsTheLink`)
already upserts both sides before linking; these five tests just never
followed it. Fixed by inserting a real target entity first.

### Date()-fixture gap in 5 more DB-integration files (test bug) — `1f4c8bbaf`
Same systemic pattern as the 11 files fixed in the prior wave, just not yet
reached in the DB-gated ones: `CalendarEvent`/`Contact`/`EmailMessage`/
`Note`/`Reminder`'s `make*()` helpers relied on each model's bare `Date()`
default for `createdAt`/`updatedAt` (`EmailMessage` also `receivedAt`),
which round-trips through `.iso8601` encoding with sub-second precision
truncated. Fixed with explicit `Date(timeIntervalSince1970:...)` values.

### `GraphStore.search` never returns anything (source bug) — `7e08fe7a6`
`GraphStore.search(query:limit:)` passes the sentinel string `"any"` as
`entityType` into `searchByLabelPrefix`, which applied a plain
`WHERE entity_type = 'any'` filter with no special case — since no row is
ever stored with that literal type, the graph-wide search feature could
never return a result, for any query, ever. Added an `entityType == "any"`
branch that drops the type filter.

### `receiptChain`'s LIMIT clause was never valid SQL (source bug) — `7e08fe7a6`
`TesseraDataStore.receiptChain(documentID:limit:)` built the optional LIMIT
clause as a plain Swift `String` and interpolated that fragment into the
`PostgresQuery` literal. `PostgresQuery`'s interpolation binds every
`\(...)` as a parameter, not spliced SQL — so instead of becoming
`LIMIT 20`, the whole fragment was sent as a bound value sitting right
after the literal `ASC`, producing `syntax error at or near "ASC$2"` on
every call, `LIMIT` set or not. Rewrote as two full query literals instead
of interpolating a raw-SQL-fragment string.

### `SheetStoreTests`' fire-and-forget-receipt race (test bug) — `96239f2c9`
`SheetStore.upsert(_:)` schedules a "material receipt" on an unawaited
`Task` (documented as intentional). Several tests capture a receipt-count
snapshot immediately after creating a sheet, with no intervening real
mutation to let that task settle — a genuine, non-deterministic race
against the test's own before/after comparison (confirmed by re-running
individual tests repeatedly: some failed 4/4 in isolation — those were the
real no-op-receipt bug, now fixed — while the *set* of SheetStore failures
under the full suite varied run to run once that bug was fixed, isolating
the race). Added a `sheetReceipts(_:forSheet:)` helper filtering out the
`SheetReceiptPayload.receiptType` ("sheet_operation") material receipt,
used for every before/after snapshot in the file.

## Part 2b — DocStore double-receipt, resolved after review — `de73f6a80`

`DocStoreTests`' 4 raw-delta-count tests (`testAcceptRevisionOfRealTrackInsertionEmitsExactlyOneAcceptedReceipt`,
`testDefineStyleEmitsExactlyOneDefineStyleReceipt`,
`testFindAndReplaceWithAMatchEmitsExactlyOneFindReplaceReceipt`,
`testRefreshFieldsWithADirtyDateFieldEmitsExactlyOneFieldsRefreshedReceipt`)
were flagged in this report as genuinely ambiguous — reviewed with Julian,
confirmed as a real source bug, not a test bug. `DocStore.upsert(_:)`
unconditionally appended its own generic `doc_upsert` receipt on every
call, including when invoked *internally* by all 16 of `DocStore`'s other
mutation methods as their persistence step — every one of them produced a
redundant generic receipt alongside its own specific one (only 4 had a test
that asserted a raw count and caught it). Split persistence from
receipting: `upsert(_:)` now delegates to a new private `persist(_:)` that
does only the data-layer write; all 16 other mutation methods now call
`persist(_:)` directly, so only their own specific receipt fires. Verified:
all 4 previously-failing tests pass; default suite unaffected.

**Related, also fixed** (`27c0f6ebc`, after review): reading `DocStore.swift`
for the above fix surfaced a second, distinct pattern in the same file —
`archive`/`unarchive`/`trash`/`restore`/`favorite`/`unfavorite` all appended
their receipt *unconditionally, outside the `if` that guarded the actual
mutation* (the exact shape already fixed in `SheetStore`/`DrawingStore`
earlier this wave). Unlike those two, `DocStoreTests` had an existing,
currently-passing test asserting this as the *intended* contract, written
that way in the prior test-rewrite wave — reviewed with Julian and
confirmed it's the same bug, not an intentional difference. All 6 methods
now guard on current state and return unchanged with zero receipts on a
no-op, matching `SheetStore` exactly. `DocStoreTests` had no positive-case
coverage at all for this method family (only the one, now-corrected,
no-op test existed) - replaced it with the full quartet coverage shape
(positive + no-op per method, 12 tests) rather than a 1:1 swap.

## Part 3 — known, not fixed this wave

### `DocumentStoreTests` — 2 tests (`testApplyInsertBlockPersistsAndEmitsExactlyOneReceipt`, `testHistoryReturnsReceiptsOldestFirst`)
Both fail with `ReceiptSignerError.signingKeyUnavailable` —
`TesseraKeychainVolume.receiptSigningKey()` returns `nil` because this
headless CLI test run has no macOS Keychain access / no key provisioned.
Environment limitation of the local ad-hoc test setup, not a code bug;
`DocumentStore`'s tests don't inject a test signing key the way some other
suites do. Would need either a `.injected` test key wired into
`DocumentStoreTests.makeStore()`, or real Keychain access in CI.

### `ThemeTests.testSwappingActiveThemeChangesResolvedMasterBackgroundColorWithoutRewritingTheMasterPagesStoredJSON` — rare, pre-existing
Passed 4/4 in isolation; failed once in two separate full-suite
`TESSERA_DB_INTEGRATION=1` runs (never in the ungated default suite).
Failure shape (`"37 bytes" is not equal to "37 bytes"` — same length,
different content) is consistent with `Theme.colors: [ThemeColorSlot:
String]` (a `Dictionary`) encoding in non-deterministic key order absent
`.sortedKeys` output formatting, combined with Swift's per-process-random
hash seed. Pre-existing (this wave touched neither `Theme.swift` nor
`SlideMasterPage.swift`'s encode path); not chased further given its low,
seed-dependent frequency — the real fix would be auditing `Theme`/
`SlideMasterPage`'s JSON encoding for `.sortedKeys`.

## Gate

- Default suite: 1634 tests / 0 failures / 0 unexpected / ~15s.
- `TESSERA_DB_INTEGRATION=1`: 1634 tests / 2 failures / 2 unexpected, both
  the `DocumentStoreTests` Keychain-environment gap above (down from 128
  unexpected at the start of the prior wave's first-ever run, 18 unexpected
  at that wave's end, 7 after the main bug-fix pass, now 2 after the
  DocStore review) — the one remaining category is environmental, not a
  code or test bug. The `ThemeTests` flake did not reproduce on this run
  (consistent with "rare").
- soffice: satisfied by the default suite itself (installed, genuinely
  exercised, not skipped) — unchanged from the prior wave's gate.
