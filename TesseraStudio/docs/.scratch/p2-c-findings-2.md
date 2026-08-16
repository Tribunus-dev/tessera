# P2-C track C2 findings - 2.4 MailMergeCoordinator + 2.21 wizard

Track: C2 (2.4 MailMergeCoordinator restatement + 2.21 merge wizard).
Files: `FieldController.swift` (sole owner this wave, `.mergeField` case),
new `Productivity/MailMergeCoordinator.swift`, new
`Tools/MailMergeTools.swift`, new
`TesseraStudioMac/Views/Docs/MailMergeWizardView.swift`, new test files.
Findings file per the wave brief's per-track convention (not shared with
other tracks' files this wave).

No `XCTExpectFailure` findings in this file - every test written this
session is contract-true against the design contract AND passes against
the code written alongside it (verified by careful manual trace of every
assertion against the implementation, since this session may not run
`swift build`/`swift test` on the shared checkout - see item 6 below for
the one place I DID use an isolated, off-checkout `swiftc` sanity check).
The entries below are DESIGN-JUDGMENT-CALL records per the brief's own
instruction ("make the call, implement it, and record it... for architect
ratification"), not suspected-bug reports.

## 1. `.mergeField` resolution context: an optional trailing `mergeRecord`
   parameter on `FieldController.refresh`, defaulting to `nil`

**The situation.** Item 1's own instruction: "your call on exactly how
the resolution context threads the current record in without breaking
FieldController's existing pure-function signature for every OTHER
FieldKind case."

**The call.** `refresh(_:in:clock:mergeRecord:)` gained ONE new trailing
parameter, `mergeRecord: [String: String]? = nil`. Every existing call
site (including `DocStore.refreshFields`, which has no concept of "the
current record") keeps compiling and behaving identically - this is the
literal "no migration" the file's own pre-existing header note (lines
76-81 before this change) already promised for adding the case itself;
extending it to the RESOLUTION signature needed the same guarantee.

**The harder half of the call: what `mergeRecord == nil` means for an
ALREADY-merged field.** A merged output `Doc` keeps its `.mergeField`
kind forever (same as every other `FieldSpec.kind` - kind is never
rewritten to something else after resolution). That means an
already-merged output Doc calling the ORDINARY `DocStore.refreshFields`
later (e.g. because it also has a `.date` field someone wants refreshed)
would hit `.mergeField` blocks too, with `mergeRecord == nil` (that call
site has no record to pass). Two options:
  - (a) resolve to `mergeRecord?[name] ?? ""` unconditionally -> an
    already-merged field's resolved text ("Ada") would be BLANKED to ""
    on the next ordinary refresh, silently destroying merged content.
  - (b) treat `mergeRecord == nil` as "no merge context available yet",
    exactly like the existing layout-sensitive treatment of
    `.page`/`.numPages`/`.ref` - leave `content`/`dirty` untouched.

Chose (b). This is the doctrine's own "canonize a bug via a code-derived
test" trap, caught at design time rather than in a later bug-fix wave: a
test built FROM the code (option (a)'s actual behavior) would have
pinned "refreshing a merged doc blanks its merge fields" as correct.
Tested directly:
`FieldControllerTests.testRefreshMergeFieldWithNoMergeRecordLeavesAlreadyResolvedContentUntouched`.

## 2. Merge-operation receipt (`doc_mail_merge_run`) NOT emitted this wave
   - blocked on withheld `DocStore.swift`

The design contract: "receipts carry source hash + record count" for
the merge OPERATION (distinct from each output Doc's own `doc_upsert`).
`DocReceiptType.runMailMerge` is already pre-landed (this wave's opener
commit) with payload keys documented as `sourceHash`/`recordCount`, but
appending a receipt requires either (a) a `DocStore` method (this file's
withheld this wave - see the wave brief's structural constraint), or
(b) `MailMergeCoordinator` reaching directly into `TesseraDataLayer.
appendReceipt` itself, bypassing `DocStore` entirely.

**The call: neither reach around DocStore NOR skip the receipt silently
- surface it as an explicit, documented gap with everything the
centralized pass needs.** Reaching around `DocStore` (option (b)) would
break this codebase's own "one material = one Store = one receipt-
emitting seam" pattern (verified: EVERY material Store - DocStore,
SheetStore, SlideStore, DrawingStore, EmailStore, NoteStore,
CalendarStore, CodeStore, ContactStore, ReminderStore - is the ONLY
caller of its own private `appendReceipt` wrapper; introducing a second,
cross-material caller of the raw `TesseraDataLayer` receipt API is
exactly the kind of new subsystem/pattern AGENTS.md's "reuse existing
infrastructure... if the change introduces a new pattern, PAUSE and ask
first" rule is about). So `MailMergeCoordinator.run(...)` computes
`sourceHash`/`recordCount` and returns them on `MailMergeRunResult`, and
marks the exact call site with a `// TODO(wiring)` comment naming the
method the centralized pass should add. See wiringNotes for the precise
signature. Every OUTPUT document's own `doc_upsert` receipt already
fires normally through the pre-existing `DocStore.upsert(_:)` - this gap
is ONLY the one summary receipt, not a hole in per-document
auditability, matching the brief's own framing of this constraint.

## 3. v1 record-source scope: `Sheet` only, and which `Sheet`

Two candidate materials named `Sheet` matter here: the plain
Notion/Airtable-style row/column material (`Materials/Sheets/Sheet.swift`,
`entity subtype "sheet"`, `SheetColumn.label` + `Sheet.cellText(row:
col:)`) and `SheetWorkbook` (the full Calc spreadsheet engine - formulas,
typed cells, pivot tables). The design contract says only "Sheet is the
obvious first one" without naming which.

**The call.** The plain `Sheet` material. Reasons: (a) it already has a
stable, minimal, PUBLIC row/column read path
(`SheetColumn.label`/`cellText(row:col:)`) that reads exactly like a mail
merge data source should - named columns, plain-text values, no formula
evaluation needed; (b) `SheetWorkbook` is explicitly staged as "keeps its
name as it grows to multi-sheet" (AGENTS.md) and is a much heavier
surface (formula engine, typed `CellValue`, pivot definitions) than
"walk labeled columns, read text" needs - pulling it in would mean
either evaluating formulas for merge purposes (undefined behavior per any
contract) or ignoring that whole engine anyway, at which point `Sheet`'s
simpler path is doing the identical job with less surface touched. A
`Doc`-as-source or a `SheetWorkbook`-as-source are both explicitly framed
in `MailMergeCoordinator.swift`'s own header as additive follow-ups (a
new `records(from:)` overload), not blocked by this choice.

## 4. Duplicate/blank Sheet column labels: last-column-wins, blank-skipped

Not specified either way by the design contract. `records(from:)`:
- A column label that trims to "" is SKIPPED (can't match any
  `.mergeField(name:)`, which always names a non-empty field) rather
  than keyed by `""`.
- Two columns with the same trimmed label: the LATER (higher physical
  column index) one wins, matching plain `[key: value]` dictionary-
  literal build semantics (no special dedup logic added). Recorded here
  rather than silently chosen; both directions are pinned as explicit
  tests (`testRecordsFromSheetSkipsBlankColumnLabels`,
  `testRecordsFromSheetDuplicateColumnLabelLaterColumnWins`) so a future
  change to this behavior is a visible test diff, not a silent drift.

## 5. `merge_run` tool + `MailMergeCoordinator` wiring: a shared-context
   singleton (`MailMergeToolContext`), same shape as `SheetToolContext`

`TesseraToolRegistry.default` is a hardcoded array of mostly zero-argument
tool initializers (`SheetWriteTool()`, `EvolveTool()`, ...); the one
store-backed precedent in that array (`SheetReadTool`/`SheetWriteTool`)
resolves its live dependency through `SheetToolContext.shared`, a
lazily-installed singleton, rather than taking a constructor argument -
because the registry itself has no way to hand a tool a live
`DocStore`/`SheetStore` pair at `static let` init time. `Reminder*Tool`
IS constructor-injected (`init(store: any ReminderStoring)`), but that
family is NOT wired into `TesseraToolRegistry.default` anywhere in this
codebase either (checked: zero call sites construct a `Reminder*Tool` for
the registry) - so it is not actually a working precedent for "how a
store-backed tool gets into the static default array," only for "how a
store-backed tool CAN be written."

**The call.** `MailMergeToolContext.shared`, same shape as
`SheetToolContext`: a `final class ... @unchecked Sendable` with a
lock-guarded optional `coordinator: MailMergeCoordinator?`, `install(_:)`
to set/clear it. `MailMergeRunTool()` stays a plain zero-argument
initializer, so the withheld `TesseraToolRegistry.default` array needs
only `MailMergeRunTool()` added to it (no constructor-argument threading
needed there) - see wiringNotes item (b).

## 6. Picker selection type: `ExportFormat.rawValue` (`String`), not the
   enum itself - `DocumentExporter.swift` not touched

`DocumentExporter.ExportFormat` declares `CaseIterable, Identifiable` but
NOT `Equatable`/`Hashable`. SwiftUI's `Picker(selection:)` binding type
must be `Hashable`. `DocumentExporter.swift` is not on this track's file
list this wave (not withheld, but not owned either - the wave brief says
"stick strictly to YOUR file list"), so rather than adding `Hashable` to
that type, `MailMergeWizardView` binds the picker to
`@State private var outputFormatRaw: String` (the raw value) and converts
back to the real enum at the one call site that needs it
(`coordinator.run(outputFormat:)`). Documented inline at the property
declaration. Flagging for the centralized pass / a future wave: adding
`Hashable` to `DocumentExporter.ExportFormat` directly (it has no stored
properties beyond the case itself, so synthesis would be immediate) would
let a future caller bind it directly; not done here to stay inside this
track's file list.

Separately verified (via an isolated single-file `swiftc` snippet,
off the shared checkout, NOT `swift build`/`swift test` on the package -
see the brief's constraint on those two specific commands) that this
toolchain (Apple Swift 6.3.3) auto-synthesizes `Equatable` for a plain
`enum Foo: String, Codable, CaseIterable { case a, b, c }` with no
explicit `Equatable` declaration - which is WHY
`XCTAssertEqual(tool.defaultApprovalLevel, .prompt)` (this track's tests)
and the existing `SheetSolverToolsTests.
testGoalSeekToolDefaultApprovalLevelIsNotify` both compile against
`ApprovalLevel`/`TesseraTier` without those enums declaring `Equatable`
either. `ExportFormat`'s MISSING conformance is real (verified by reading
its declaration directly), so the `Picker` issue itself is real and the
fix above stands - this note is only recording that the adjacent
"maybe `ApprovalLevel` has the same problem" concern was checked and is
NOT an issue.

## 7. Merge wizard: no multi-step-sheet component found, built a plain
   `@State`-driven single `View`

Checked `TesseraStudioMac/Views` for an existing "wizard"/paged-sheet
component before writing `MailMergeWizardView` (grep for "wizard"/
"Wizard"/"@State private var step"/"enum ... Step" across
`TesseraStudioMac`): none exists. `VersionHistorySheet.swift` (the
closest existing Docs sheet) is itself a single flat `View`. Built
`MailMergeWizardView` the same way: one `View`, `@State` gating which
section renders (source picker always visible; field chips/preview/run
appear once both a template and a source are selected) - per the item's
own instruction ("a plain single SwiftUI View with @State driving which
section shows is fine if nothing else in this codebase does multi-step
sheets").

## 8. No test target exists for `TesseraStudioMac` - the wizard view has
   no XCTest coverage, by construction of this repo, not by omission

`TesseraStudio/Package.swift` declares exactly one `.testTarget`
(`TesseraCoreTests`, depending on `TesseraCore` only); `TesseraStudioMac`
is an `.executableTarget` with no corresponding test target anywhere in
the manifest, and grep confirms no OTHER `TesseraStudioMac/Views/*.swift`
file has ever had a paired XCTest file either. `MailMergeWizardView.swift`
is therefore UI-only, verified by careful manual review against the
design contract's own "source picker -> field chips -> preview record k
-> run" flow (this findings file's item 7) rather than by an automated
test - consistent with the rest of this codebase's `TesseraStudioMac`
surface, not a gap specific to this track's item.
