# P2-D track D3 findings - 2.16 DatabaseConnector

Track: D3 (2.16). Files owned this wave: `TesseraStudio/Package.swift` (sole
owner this wave), new `Sources/TesseraCore/DataAccess/DatabaseConnector.swift`,
new `Sources/TesseraCore/Tools/DatabaseTools.swift`,
`Productivity/Materials/Sheets/SheetStore.swift` (sole owner this wave for
`importFromDatabase`), plus new tests for all four.
`TesseraToolRegistry.swift` was withheld - see this track's structured
result "wiringNotes" for the exact registry entries a future wiring pass
needs.

No swift build/swift test was run (per this wave's standing instruction -
4 agents share this checkout). Everything below that touches GRDB/DuckDB
API surface was verified by reading the actual checked-out package sources
(`.build/checkouts/{duckdb-swift,grdb-ref}`) directly, and the core
read-only-mode architecture was additionally validated EMPIRICALLY against
the real `duckdb` CLI (v1.5.2, installed at `/opt/homebrew/bin/duckdb`) in
a scratch directory outside the Swift checkout - see finding 4. The
centralized build pass should still treat every Swift-API assumption here
as unverified until `swift build` actually succeeds.

## 1. xlsx dropped from the v1 db path entirely (per the design contract's own escape hatch)

Item 2.16's open question (b) offered an explicit escape hatch: "if iOS
DuckDB excel-extension static linking is awkward, drop xlsx from the v1 db
path entirely (CSV/Parquet cover it)." I took that path rather than
attempting `read_xlsx` + the DuckDB `excel` core extension.

Decision: `DatabaseConnector.attach(path:)` recognizes exactly
`.sqlite`/`.db` (GRDB) and `.csv`/`.tsv`/`.parquet`/`.json`/`.jsonl`
(DuckDB). Any other extension, including `.xlsx`, throws
`.unsupportedFileType` before either engine is touched - there is no
excel-extension loading code anywhere in this track's files. This is not
a partial/best-effort xlsx path; it is a hard "not in v1" boundary,
matching the ratified row-16 default ("xlsx dropped from the v1 db path if
iOS linking is awkward" - I judged static-linking an extension for a v1
connector NOT worth the complexity given CSV/Parquet already cover the
analyst workflow the item targets).

Ratification ask: none - this is the row-16 default as written, not a new
position.

## 2. ApprovalLevel mapping for tier1: `.notify`, not `.prompt`

The sota-enterprise-report.md tier-mapping table (top of the doc, shared
across 2.13-2.21) states `.prompt -> tier1`. But the ACTUAL shipped
convention in this codebase - `SheetGoalSeekTool`/`SheetSolverRunTool`
(P2-A, tier1, `.notify`) and `MailMergeRunTool` (P2-C, tier2, `.prompt`) -
uses `.auto -> tier0`, `.notify -> tier1`, `.prompt -> tier2`. Both
`SheetSolverToolsTests.swift` and `MailMergeToolsTests.swift` assert this
explicitly against `TesseraTier.tierN.displayName` ("Tier 1 (notify)"
/ "Tier 2 (approval)").

Decision: followed the shipped precedent, not the (evidently stale) sota
report table. `db_attach`/`db_import_range`/`db_detach` (tier1) all set
`.notify`; `db_schema`/`db_query` (tier0) set `.auto`. AGENTS.md's own
"read surrounding code before editing... mimic existing patterns" rule
points the same direction.

Ratification ask: the sota report's tier-mapping table (shared by every
2.13-2.21 item) should probably be corrected to match the shipped
convention, so the NEXT track reading it doesn't hit the same
discrepancy. Flagging for the architect / whoever owns that doc, not
something this track can fix (out of file scope).

## 3. db_attach / db_detach emit no `GraphReceipt` at all (not a new *ReceiptType case, not a synthetic entityID either)

The wave brief explicitly left this open: "doesn't need a NEW
*ReceiptType case since attach/detach are session-scoped, not
document-scoped mutations - your call, document it either way." No
pre-landed reservation added a case for either.

Decision: neither tool calls `TesseraDataLayer.appendReceipt` (or any
other receipt sink) at all - not even with a synthetic entityID (e.g.
`Handle.id`). Reasoning: (a) there is no real Doc/Sheet/Drawing entity
either action mutates, so any entityID would be invented purely to shoehorn
a session event into a receipt schema designed for material mutations;
(b) `DatabaseToolContext` would otherwise need a `TesseraDataLayer`
dependency it has no other reason to hold (unlike `MailMergeToolContext`,
which already needs `DocStore`/`SheetStore` for its actual work);
(c) AGENTS.md's own "Inline stop + audit log side panel" section
describes `ActionAuditLogStore` as already recording "every agent action +
outcome" with tier + timestamp + receipt id, independent of whether a
domain receipt exists - so attach/detach are NOT unaudited, they are
audited by the agent-loop layer instead of the domain-receipt layer. Each
tool's own `ToolResult.data` carries the session-scoped facts (`handle`,
`source_path`, `source_hash` for attach; `handle` for detach) as the
in-band record of what happened.

Ratification ask: yes - this is a real judgment call with no forcing
function in the contract. If the architect wants attach/detach to ALSO
carry a `GraphReceipt` (e.g. for a future "show me every database this
session touched" audit view that reads `graph_receipts` rather than the
ActionAuditLogStore), that needs (a) a `TesseraDataLayer` reference on
`DatabaseToolContext` and (b) a decision on what entityID a session-scoped
receipt should carry (a fresh synthetic UUID? one shared across the whole
session?) - neither of which this track invented unprompted.

## 4. DuckDB genuinely-read-only mode requires a FILE-backed scratch catalog, not `.inMemory` - empirically confirmed

DuckDB's own C++ source (`duckdb/src/storage/storage_manager.cpp`) throws
`"Cannot launch in-memory database in read-only mode!"` when
`access_mode = READ_ONLY` is combined with an in-memory store. So
`DatabaseConnector` cannot simply open an in-memory DuckDB database
read-only and query CSV/Parquet/JSON through it the way the design
contract's prose ("DuckDB opened with its own read_only mode") reads at
face value.

Decision: `DatabaseConnector` maintains one on-disk scratch `.duckdb`
catalog file (Application Support by default, injectable for tests) that
is created ONCE, read-write, the first time it's needed (so DuckDB
actually creates the file - DuckDB only auto-creates a MISSING file when
NOT read-only), then every subsequent `attach()` for a CSV/Parquet/JSON
source opens THIS SAME file in `access_mode = READ_ONLY` and queries the
user's file via DuckDB's own `read_csv_auto`/`read_parquet`/
`read_json_auto` table functions. Because the persisted catalog is never
written to (no `CREATE TABLE` ever runs against it), the read-only flag
has nothing of the app's own to protect; the table functions read the
external file directly and are unaffected by the attached database's own
catalog access mode.

This was validated empirically, outside the Swift build, using the real
`duckdb` CLI (v1.5.2) in a scratch temp directory:
```
$ duckdb probe.duckdb -c "SELECT 1;"                 # creates the file, read-write
$ duckdb -readonly probe.duckdb -c \
    "SELECT * FROM read_csv_auto('probe.csv');"       # succeeds
$ duckdb -readonly probe.duckdb -c \
    "SELECT * FROM read_parquet('probe.parquet') WHERE is_active = true;"  # succeeds, WHERE works
$ duckdb -readonly probe.duckdb -c "CREATE TABLE t(x INT);"
Invalid Input Error: Cannot execute statement of type "CREATE" on
database "probe" which is attached in read-only mode!
```
This is the exact mechanism `DatabaseConnector.duckDBReadOnlyConnection()`
implements. The Swift-level API calls (`Database.Configuration.setValue
("READ_ONLY", forKey: "access_mode")`, `Database(store: .file(at:),
configuration:)`) were read from the actual duckdb-swift source but NOT
exercised through `swift build` - the CLI probe above is the
architecture's proof, the Swift plumbing around it is unverified until
the centralized build pass runs.

Ratification ask: none needed technically (this is a mechanism decision,
not a policy one), but flagging because it's a real deviation from the
design contract's literal wording ("DuckDB opened with its own read_only
mode") in favor of what DuckDB actually supports.

## 5. GRDB write-rejection test bypasses `DatabaseQueue.read`'s OWN read-only wrapper on purpose

GRDB's `DatabaseQueue.read { db in ... }` wraps every call in
`db.isolated(readOnly: true)` - a GRDB-level transaction guard that
exists independent of whether the underlying connection's own
`Configuration.readonly` is set. That means a naive
"write inside `.read {}`" test would fail even on a WRITABLE queue,
proving nothing about the connection-level enforcement this item's tests
are supposed to prove ("prove the ENGINE enforces it, not just 'we didn't
call a write method'").

Decision: `DatabaseConnector.query(handle:sql:)` runs every query
(read or write) through `queue.read { db in ... }` for API-shape
consistency (it does not know in advance whether `sql` is a read), so the
PRODUCTION code path already goes through GRDB's own read-only wrapper on
top of the genuinely-readonly connection - two independent layers agree,
which is fine. But `DatabaseConnectorTests.swift`'s write-rejection tests
seed their SQLite fixtures via a plain, separately-constructed
`DatabaseQueue(path:)` (default read-write config) using
`.write { db in try db.execute(...) }` - a completely different queue
instance/connection than the one `DatabaseConnector` opens read-only via
`attach()` - so the seeded writes are genuine writes against a genuinely
writable connection, and the REJECTED writes in the actual assertions go
through `DatabaseConnector.query(...)` against the real, separately-opened
readonly connection. This is real engine-level proof, not a GRDB
transaction-guard artifact.

Ratification ask: none - documenting the subtlety so a future reader of
the tests understands why the fixture-seeding queue and the
connector-under-test's queue are deliberately two different `DatabaseQueue`
instances against the same file.

## 6. `SheetStore.growingTable(rows:cols:in:)` is `internal`, not `private`, and lives in `SheetStore.swift` rather than as a pure `Sheet` method

Every OTHER `SheetStore` mutation method's genuinely-new logic lives as a
PUBLIC pure method on `Sheet` itself (`settingCellText`,
`adjustingFormulas`, etc.), which is what lets `SheetStoreLogicShadowTests.
swift` give every DB-gated mutation an ungated shadow per testing-doctrine
rule 11. `db_import_range` needed the SAME kind of shadow for its own new
grid-growth logic, but `Sheet.swift` is NOT in this track's file list (the
wave brief lists `SheetStore.swift` as the sole owner, with no mention of
`Sheet.swift`), and the wave's own "Stick strictly to YOUR file list"
instruction is explicit.

Decision: implemented the grow-to-fit logic as `SheetStore.
growingTable(rows:cols:in:)` - store-internal, but marked `internal`
(default access, no `private`) specifically so
`SheetStoreImportFromDatabaseLogicShadowTests.swift` can call it directly
via `@testable import TesseraCore` (constructing a `SheetStore` with a
plain, never-`.start()`-ed `TesseraDataLayer()` - safe, since the method
never touches `self.dataLayer`). This satisfies doctrine rule 11's actual
requirement (an ungated test of the same logic path) without touching a
file outside this track's ownership.

Ratification ask: if a future wave DOES touch `Sheet.swift` for another
reason, moving this logic to a public `Sheet.growingToFit(rows:cols:)`
(matching the file's own established pattern) would be a clean, low-risk
follow-up - flagging so it isn't forgotten, not blocking anything now.

## 7. DuckDB column-type stringification: v1 covers scalars, not composite/nested types

`SheetStore.importFromDatabase` (and therefore `db_import_range`) needs
every query-result value as plain text, since Sheets cells are
text-first (`CellValue.classify` re-derives the typed value from text on
write). DuckDB's own Swift API requires picking ONE concrete Swift type
to `cast(to:)` per column based on its `underlyingDatabaseType` - there is
no generic "give me this value as a String no matter what" call.

Decision: `DatabaseConnector.stringify(_:rowCount:)` covers every scalar
DuckDB type real CSV/Parquet/JSON files plausibly carry: `boolean`, all 8
integer widths, `float`/`double`, `varchar`, `blob` (base64), `decimal`,
`uuid`, and `date`/`time`/`timeTz`/`timestamp`(+`Tz`/`S`/`MS`/`NS`,
via DuckDB's own decomposed `Components` structs, hand-formatted rather
than round-tripped through Foundation's `Date`). Composite/nested types
(`list`, `struct`, `map`, `union`, `enum`) and `hugeint`/`uhugeint`/
`interval` are explicitly NOT stringified - `query`/`db_query` throws a
named `DatabaseConnectorError.unsupportedColumnType(column:type:)`
naming the offending column, rather than silently emitting an empty
string that would materialize as a plausible-looking but WRONG blank
cell.

Ratification ask: none for v1 (this matches the effort-M sizing - a real
`enum`/`list`/`struct`/`map`/`union` stringification story is
meaningfully more work and none of it is exercised by the checked-in
fixtures or realistic analyst CSV/Parquet workflows). If a real corpus
surfaces one of these types in practice, that's a scoped follow-up, not a
v1 blocker.

## 8. Package.swift: GRDB also added to the `TesseraCoreTests` target, not just `TesseraCore`

The brief's exact-snippet instruction named `TesseraCore`'s target
dependencies array specifically. `DatabaseConnectorTests.swift` needs to
`import GRDB` directly (to seed real, on-disk SQLite fixtures via a
separately-constructed, genuinely-writable `DatabaseQueue` - see finding
5) - SwiftPM does not make a dependency importable in a test target
merely because the target it tests links that dependency transitively.

Decision: added `.product(name: "GRDB", package: "GRDB.swift")` to the
`TesseraCoreTests` target's own dependencies array too (the `.package(...)`
line itself is declared once regardless). This is additive, in-scope
(`Package.swift` is this track's sole-owned file this wave), and mirrors
how the test target already needs its own explicit access to whatever it
directly imports.

Ratification ask: none - flagging only because the brief's snippet didn't
literally mention the test target, so a reviewer diffing against the
literal instruction should know this second addition was deliberate, not
scope creep.

## 9. `SheetStore.importFromDatabase` takes plain `columns: [String], rows: [[String]]`, not a `DatabaseConnector.QueryResult`

Decision: kept `SheetStore.swift` free of any `DataAccess`/`DatabaseConnector`
import. `DatabaseImportRangeTool` (in `Tools/DatabaseTools.swift`) is the
one place that bridges `DatabaseConnector.QueryResult` to
`SheetStore.importFromDatabase`'s plain-array parameters. This keeps the
Productivity/Materials layer decoupled from the Tools/DataAccess layer
(the same direction every other store already points - `SheetStore` has
no imports of anything under `Tools/`) and means `SheetStore`'s own tests
never need to construct a `DatabaseConnector.QueryResult` value.

Ratification ask: none - straightforward layering choice, documenting for
completeness.
