# P2-A findings - Track A4 (2.8 statistics wizards + 2.9 revision reviewer)

Cluster ownership: `Sources/TesseraCore/Tools/SheetStatisticsTools.swift`,
`Sources/TesseraCore/Editor/RevisionReviewPanel.swift`, and their test files
under `Tests/TesseraCoreTests/Tools/` and `Tests/TesseraCoreTests/Editor/`.

Contract source: `studio-expansion-plan.md`'s P2 core table row ("Statistics
wizards (18 agent-tool wrappers)") for 2.8 - no further design doc names the
exact 18, so a contract stub is derived here per testing-doctrine.md's "derive
a contract stub from the best available evidence, record it for architect
ratification" rule. `sota-p2-core-report.md`'s "2.9 Track-changes reviewer UI"
design contract for 2.9 - fully specified there, no derivation needed.

No `XCTExpectFailure` rows in this file: no test written against either
item's contract failed against current (pre-existing) code. Both items are
new files this wave; there is no legacy behavior to find a bug in.

---

## 2.8 - derived 18-item contract stub (FOR ARCHITECT RATIFICATION)

`StatisticsFunctions.swift` at HEAD registers exactly 8 functions (VAR, VARP,
STDEV, STDEVP, MEDIAN, PERCENTILE, LARGE, SMALL) plus CORREL - no MODE. The
plan names a count (18) and a category ("statistics wizards") but not the
list. Derived list, mirrored verbatim in `SheetStatisticsTools.swift`'s own
file-header comment:

mean, median, mode, stdev (sample), stdev_population, variance (sample),
variance_population, range, quartiles (Q1/Q2/Q3), iqr, correlation,
linear_regression (slope+intercept), rank, percentile, zscore, large, small,
count.

**Rationale.** This is the descriptive + order-statistic + two-variable set a
spreadsheet "Statistics" wizard typically offers (Excel's Analysis ToolPak /
LO Calc's Statistics function category), scoped to what the LANDED
FormulaEngine can answer without a new distribution/hypothesis-testing
engine. Explicitly OUT of scope: t-test, ANOVA, chi-square, F-test, and any
other inferential test requiring a probability-distribution library - nothing
in the plan's "18" names them, and building one is a new subsystem this
track's file-ownership scope (SheetStatisticsTools.swift only, no
StatisticsFunctions.swift/FunctionRegistry.swift edits) does not license.
**Open question for the architect:** should any of the excluded inferential
tests replace one of the 18 above, or is the descriptive/order-statistic
scope correct for "wizards"? Ratify-or-amend before P2-B/P2-C touch Calc
again.

**Reuse discipline (per the track brief, not a judgment call, but worth
recording for the reviewer):** every tool whose function is already
registered anywhere in the FormulaEngine (AVERAGE, MEDIAN, STDEV, STDEVP,
VAR, VARP, PERCENTILE, LARGE, SMALL, CORREL, COUNT, MAX, MIN) invokes the
landed `Evaluator` against a formula string
(`SheetStatisticsSupport.evaluateFormula`) rather than recomputing the math.
Five tools with no registered function of their own (range, quartiles, iqr,
linear_regression, zscore) are still built by COMPOSING landed functions
(MAX-MIN; PERCENTILE at .25/.5/.75; slope = CORREL * stdev(y)/stdev(x),
intercept = mean(y) - slope*mean(x); zscore = (value-mean)/stdev) - zero new
numerical code, only arithmetic glue between evaluator results. Only MODE and
RANK have neither a registered function nor a landed composition available
(no MODE, no RANK/RANK.EQ anywhere in FunctionRegistry.swift); those two read
raw range values themselves and implement the missing math directly, exactly
as the track brief instructs for functions StatisticsFunctions.swift does not
register.

**Evaluation mechanism (worth flagging - a real technique, not just a
convention).** `SheetReadTool`/`SheetDescribeTool` only ever READ raw cell
values; neither shows how to invoke the FormulaEngine's registered math
without writing a cell. This file's `SheetStatisticsSupport.evaluateFormula`
parses a formula string with the landed `FormulaParser` and calls
`SheetEngine.evaluator.evaluate(ast, at:, sheet:, engine: engine)` directly -
bypassing `SheetEngine.setFormula` entirely, so nothing is written to
`document.blocks`, no undo-stack entry is pushed, and no dependency-graph
node is created. This works because `SheetEngine` itself (not just its
private `EvaluatorBridge`) conforms to `SheetEngineCore`, and its own
conformance methods (`getCellValue`/`getRangeValues`/`resolveNamedRange`)
each take the engine's lock independently per call - see
`SheetEngine.evaluatorBridge`'s own doc comment for why that PRIVATE bridge
exists only for calls already holding the lock (calling it from outside
would need the lock exposed, which the engine deliberately does not do).
Calling `evaluate(..., engine: engine)` from OUTSIDE any lock, as this file
does, is safe and does not deadlock. Recording this because it is a pattern
future non-mutating "compute over a formula" tools can reuse instead of
writing a scratch cell and reading it back.

---

## 2.9 - judgment calls recorded for ratification

The design contract in `sota-p2-core-report.md` is fully specified; nothing
here contradicts it. Two implementation decisions were judgment calls where
the contract's own words left room, recorded per doctrine ("this is a real
judgment call... not something to bury") even though 2.9's own contract
stub was already complete (only 2.8 formally required one):

1. **Receipt-id chip data source.** `DocStore.acceptRevision`/
   `rejectRevision` persist through `dataLayer.appendReceipt` internally but
   do NOT return the receipt id to the caller - there is no way to know a
   just-created receipt's id from the store's own public surface today. A
   pending row therefore has NO receipt id (nothing has happened yet - this
   is correct, not a gap). For a row the panel itself just resolved,
   `RevisionReviewStore.recordResolvedLog` looks the id up after the fact via
   the already-public `TesseraDataLayer.receiptChain(documentID:limit:)`,
   matching on receipt type + the `revisionID` payload key
   `RevisionResolution.payload` already writes. This is a real, non-
   fabricated id when found; a lookup miss (or the call throwing) leaves the
   chip absent rather than showing a guessed value. **wiringNotes records the
   alternative** (a `DocStore` signature change returning the receipt id
   directly) for the centralized pass to consider, since it would let the
   lookup be removed entirely - see this track's wiringNotes.
2. **`.removed` outcome's local-undo granularity.** `RevisionController
   .removeSubtree` purges a block's WHOLE descendant subtree, but
   `MutationEngine.deleteBlock` only unlinks the one named block (it has no
   subtree-delete primitive). `RevisionReviewUndoBuilder` therefore builds
   one `Mutation.deleteBlock` per `RevisionBlockOutcome` - the group's own
   top-level entries - not one per purged descendant. This is NOT a
   narrower guarantee than the real, persisted receipt already gives:
   `RevisionResolution.payload` (what `DocStore.acceptRevision`/
   `rejectRevision` actually persists) ALSO only lists the group's top-level
   `blocks`, never the full purged subtree - so the local Cmd-Z chain's scope
   matches the real receipt's own documented scope, not a new gap introduced
   here. Flagging because it means undoing a `.removed` accept/reject via the
   LOCAL Receipt chain (not yet wired to a real Cmd-Z handler this wave - see
   wiringNotes) would not resurrect deeply-nested descendants of a removed
   subtree; the persisted document state is unaffected either way since
   `DocStore` is the sole persister and never goes through this local chain.
3. **`ReceiptUndoManager.group(_:)` = "one undo unit" clarified, not
   redefined.** Initially misread as "one `undo()` call pops the whole
   group atomically" - it does not; `undo()` pops exactly one `Receipt` per
   call regardless of how it was pushed. The RATIFIED contract (this
   codebase's own `ReceiptUndoManagerTests.testGroupAppendsEveryReceiptToTheUndoStackInOrder`)
   is "every receipt from the batch lands on the stack via ONE `group(_:)`
   call, in order" - matching `DrawCanvasView`'s own "one drag is one undo
   unit" framing. `RevisionReviewStore.resolve` calls `registerUndo` exactly
   once per accept/reject/accept-all/per-author call, and `registerUndo`
   calls `.group(receipts)` at most once - so "accept-all produces exactly
   one undo unit" holds under the RATIFIED meaning of that phrase.
   `RevisionReviewUndoBuilderTests.swift`'s header comment records this
   clarification so a future reader does not re-trip on the same
   misreading. Not a code-bug finding - the confusion was mine, resolved by
   reading the already-ratified test before writing a new one.
