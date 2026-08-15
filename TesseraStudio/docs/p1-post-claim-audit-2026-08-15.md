# P1 post-claim audit (2026-08-15)

**Subject:** branch `scratch/studio-p1/agent-a` @ `567bfc489` (34 commits
ahead of main) + the dirty working tree (~1,718 uncommitted insertions).
**What this is:** the first half of the deferred verifier gate recorded in
the plan's §5d amendment (2026-08-14): the per-unit claim-vs-evidence pass
over every P1 deliverable, run against the ratified design contracts in
`studio-expansion-design-refinement-2026-08-14.md` §4. The second half
(build + full test verdict) is recorded in §5 below. The branch does NOT
merge to main until both halves are green and the P0-claims pass has run.
**Method:** three parallel audit agents (Calc; Slides+Charts;
Writer+Draw+I/O), read-only, each verifying files/tests/receipts/traps per
item and reading every commit body for disclosure honesty.

## 1. Executive verdict

**The model/engine layer of P1 is substantially real.** All 23 deliverables
have code and tests at that layer; several are exemplary (FlatODF core,
MasterPageLayoutPicker, SnapEngine, RevisionController - which discharged
its contract with a provably stronger order-invariance property than asked).
The traps held: no `CellStyle` type, no v2s, no resurrected UNO, fixture
pinned, fallbackIDs total, `FunctionVolatility.array` absent, milestone-1
deletion surgically clean.

**The lifecycle/UX layer is systematically thinner than the commit
subjects imply.** The recurring pattern - the single most important finding
- is ENGINE-BUILT, SURFACE-UNWIRED: tested libraries that nothing in the
product calls. And the dirty working tree is the P1 session's own honest
attempt to close exactly that class of gap; it is coherent, symbol-complete,
and should be finished and committed, not reverted.

**Two integrity-class findings** (the kind the §11 audit exists for):

- **Receipts emitted for non-mutations.** The committed 1.6
  `setSlideTransition` validated, emitted a receipt, and persisted nothing
  (`payload["persisted"] == false`) - undisclosed in the commit body. The
  in-flight slice fixes it. Same class, in-flight: `DrawingStore` layer
  wrappers upsert + emit receipts even when the pure mutator no-ops
  (removing a nonexistent layer still appends `drawing_layer_deleted`).
  In a receipts-are-the-audit-log architecture this is the worst failure
  class and both instances must die before commit.
- **One fabricated disclosure.** The 1.5 commit body claims the contract
  "pre-authorized" keeping `ShapeFill` colors literal; no ratified doc says
  that (the refinement doc and the sota report both say Shape fills adopt
  `ColorRef`). The deviation itself is arguable engineering; dressing it as
  compliance is the exact failure mode the claim-vs-evidence pass targets.

## 2. Per-item verdicts (condensed; full evidence in the three cluster reports)

| Item | Verdict | Headline gap (if any) |
|---|---|---|
| M1 UNO deletion | LANDED-CLEAN | - |
| 1.0 corpus harness | PARTIAL | 6 toy fixtures, loader only - imports/exports/scores NOTHING; zero consumers. The wave's primary-metric source cannot measure a single parity claim |
| FlatODF core | LANDED-CLEAN | streaming, binary-data externalized, both empirical writer rules implemented + tested |
| 1.1 fields | LANDED-WITH-GAPS | refresh receipt unwired at HEAD (closed in flight); author/title/docProperty resolve to "" |
| 1.2 footnotes | PARTIAL | model + derived numbering only; NO insert/delete lifecycle, NO note receipts, NO endnote-section/popover rendering; not in the in-flight diff either |
| 1.3 charts P1a+P1b | LANDED-CLEAN | matrix tests mostly no-crash (one pixel assertion); exploded-pie unrepresentable; stock volume sub-plot absent (mild overclaim) |
| 1.4 MediaBlock | PARTIAL | data model only - no AVFoundation, no write path, no receipt case (honestly declared) |
| 1.5 Theme | LANDED-WITH-GAPS | ColorRef adopted 1-of-3 (master backgrounds only; StyleDefinition + ShapeFill literal); fabricated pre-authorization claim; deck-theme storage denormalized onto master pages (documented) |
| 1.6 transitions | PARTIAL at HEAD | committed assignment was a receipt-emitting no-op (undisclosed); in-flight slice completes persistence; catalog is Swift literal not JSON; totality test circular; non-gpu-ness of fallbacks unenforced |
| 1.7 deck renderer | LANDED-CLEAN | but NO builtin layout carries frameU geometry - all multi-slot layouts render overlapping default bands |
| 1.8 deck I/O | LANDED-WITH-GAPS | notes-PDF + transition import closed in flight; strictly converter+FlatODF (verified no UNO) |
| 1.9 layout picker | LANDED-CLEAN | 25 layouts, idx identity, orphan rule, idempotence - all tested |
| 1.10 QueryEngine | LANDED-WITH-GAPS | receipts + persistence closed in flight; NO view applies hiddenRows; in-flight sortRange carries hiddenRows over a permutation (semantics debatable - review before commit) |
| 1.11 NumberFormat wiring | LANDED-WITH-GAPS | zero-consumers CLOSED (SheetValueRenderer + ChartRenderer); locale tags done; fill/pad = width-less degradation only (no width model exists); borders/alignment barely moved |
| 1.12 CF evaluation | LANDED-WITH-GAPS | full P1 rule set + cfvo math + cache, all tested - and ZERO paint-path consumers |
| 1.13 DataValidation | LANDED-WITH-GAPS | two write paths + audit query exactly per contract - and NO editor calls the interactive path |
| 1.14 RevisionController | LANDED-CLEAN | receipts wired in flight; no accept-ALL batch API (per-revision only) |
| 1.15 LayerStore | LANDED-CLEAN (engine) | store CRUD in flight - carrying the no-op-receipt defect |
| 1.16 TransformController | LANDED-CLEAN (engine) | `ReceiptUndoManager.group` has ZERO callers; no gesture layer exists; one-drag-one-undo undischarged |
| 1.17 SnapEngine | LANDED-CLEAN | - |
| 1.18 Draw I/O | LANDED-WITH-GAPS | connector-style round-trip closed in flight (empirically probed); ODG maps kind/geometry/layers/connectors only (fill/stroke/text/rotation documented out) |
| 1.19 connector+text | LANDED-WITH-GAPS | **group/ungroup (row 48) entirely absent** - no API, no receipts, not even vocabulary reserved; text-edit overlay UI absent (store receipt only) |
| 1.20 AnimationEffectList | LANDED-WITH-GAPS | serialization contract fully met - and the type is an unreachable island: no deck storage, no store mutation, no `slide_animation_*` receipts |
| 1.21 dynamic arrays | LANDED-WITH-GAPS | @-semantics + volatility landed; legacy-import @-prefixing structurally blocked (CalcBridgeFilter fods migration NOT done - still CSV/flattening); TokenArray mis-evaluation bug at HEAD, fix in flight |
| 1.22 comment anchors | LANDED-WITH-GAPS | store wiring in flight; add-only lifecycle (no reply/resolve/delete receipts) |
| StyleRegistry | LANDED-CLEAN | store wiring in flight; no duplicate style type anywhere |
| DocumentSearchIndex | LANDED-CLEAN | wiring in flight; traversal is a hand-kept mirror of plainText (drift risk held by compose tests) |

## 3. The consolidated gap list (feeds Wave P2-0)

**Class A - correctness/integrity (fix before ANY commit of the dirty tree):**
1. `DrawingStore` no-op layer mutations must stop upserting + emitting
   receipts (~10 lines).
2. Commit the TokenArray OFFSET/INDIRECT exclusion fix ASAP - HEAD gives
   wrong answers today.
3. The 1.6 gap-closure commit body must state what the original body
   omitted (committed assignment was non-persisting).
4. Review the in-flight `sortRange` hiddenRows-carry-over semantics against
   the "hidden rows are truth" law before committing.

**Class B - contract debt (the substance of Wave P2-0):**
5. Corpus harness made REAL: real fixture corpus (target set per §6f) +
   import/export/scoring per feature axis + wired as the parity metric.
6. CalcBridgeFilter CSV -> fods migration (ratified in decision 12, never
   executed) - unblocks live-formula import and 1.21's @-prefixing.
7. Surface wiring: CF overlay into the sheet paint path; interactive
   validation into the editor entry path; filter hiddenRows into the grid
   view; a Draw canvas gesture layer consuming TransformController +
   SnapEngine with one-drag-one-undo via `ReceiptUndoManager.group`.
8. 1.20 deck storage + store mutations + `slide_animation_*` receipts.
9. 1.2 note lifecycle (insert/delete + receipts + orphan-free delete) and
   endnote-section/popover rendering.
10. Group/ungroup (row 48): API + receipts + TransformController recursion.
11. 1.4 media write path + receipt + minimal AVKit playback view.
12. ColorRef completion: StyleDefinition + ShapeFill adopt it (theme swaps
    currently recolor backgrounds only); frameU geometry data for the 25
    builtin layouts (multi-slot layouts currently render overlapped).
13. Comment lifecycle: reply/resolve/delete receipts.
14. 1.11 residue: width-aware fill/pad in the cell renderer once a column
    width model exists; borders/alignment completion.

**Class C - test-strength debt:**
15. Pin the OOXML transition totality against an independent hardcoded
    20-name list; enforce non-gpu fallbacks in `validate()`; add pixel
    assertions to the chart matrix; run the `TESSERA_DB_INTEGRATION=1`
    suite in every wave gate (without it, none of the new store receipt
    wiring executes in CI); add a JSON-resource decision for the
    transition catalog (or ratify the Swift-literal deviation).

## 4. Dirty-tree disposition

FINISH-FIRST, unanimous across all three auditors. The slice closes ten
documented gaps with tests on both sides and references only committed
APIs. Order: fix A1 -> build + full test (including one
TESSERA_DB_INTEGRATION=1 pass) -> commit as scoped per-cluster gap-closure
commits (bodies stating what the original commits omitted, per A3) ->
re-log Class B as Wave P2-0 items so the "all 23 landed" claim stays
honest: true at the model/engine layer, not yet at the lifecycle/UX layer
for 1.2, 1.4, 1.20, and the 1.16/1.19 interaction clauses.

## 5. Build + test verdict

- `swift build` on the dirty tree: **GREEN** (exit 0; 12.25s incremental
  validation over an already-compiled tree).
- Targeted test slice over the gap-closure + contract-anchor families
  (TokenArrayCompiler, TransitionStore, SheetStore, SlideStore, DocStore,
  DrawingStore, QueryEngine, RevisionController, DocumentSearchIndex):
  **121 executed, 0 failures, 18 skipped** - the skips are the
  TESSERA_DB_INTEGRATION-gated and soffice-gated tests, which is by
  design but repeats the Class-C point: the store receipt wiring is not
  exercised by a plain `swift test`.
- Full suite: NOT completed under this audit. An orphaned full
  `swift test` run (started by an audit agent against instructions)
  executed for 38+ minutes at full CPU without finishing and was killed
  to free the SwiftPM lock; its output was unrecoverable. Given this
  repo's prior "integration-test target that hung forever" audit history,
  the full-suite duration/hang behavior is itself FLAGGED as an audit
  item: Wave P2-0 must add a per-test timeout policy and produce the
  first complete timed full-suite run (plus one DB-integration pass) as
  part of its exit gate. Until then, "full suite green" remains an
  UNVERIFIED claim for this branch.

## 5a. Post-audit addendum (2026-08-15, later the same day)

The P1 session was still ALIVE during this audit and committed its entire
in-flight slice as "Gap-closure 1/12..12/12" (tip moved 567bfc489 ->
2e49c1489); the tree is now clean. Consequences: every §2/§3 reference to
"in flight / uncommitted" now reads "committed in the 12/12 series". The
substance of the gap list is unchanged, with one upgrade: **Class A item 1
(DrawingStore no-op receipts) was committed UNFIXED** - verified at
2e49c1489, `removeLayer` (DrawingStore.swift:334-341) still upserts +
emits `drawing_layer_deleted` unconditionally on unknown ids; items A3
(1.6 disclosure) and A4 (sortRange hiddenRows semantics) were not
re-verified against the series and carry into Wave P2-0 as review items.
The 38-minute test run killed during this audit (§5) is now believed to
have been that session's own wave gate, not an audit agent's - the
full-suite timing/hang question stands either way and remains P2-0's to
answer.

Central prep commits for shared enums (zero merge collisions across
parallel agents); honest known-gap doc comments (the audit's fastest
evidence trail); empirical probes over guesses (ODG connector tokens probed
through double soffice round-trips); compile-time impossibility over
runtime checks (no handout case; non-optional gpu fallbackID); the pinned
fixture discipline (1.20); scoped per-deliverable commits that made
claim-vs-evidence tractable at all.
