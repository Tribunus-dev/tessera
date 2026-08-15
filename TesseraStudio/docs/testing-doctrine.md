# Tessera Studio testing doctrine

**Status:** binding for every test written after 2026-08-15 (architect
directive; the pre-doctrine suite - 247 files - was deleted the same day
in favor of a doctrine-compliant rewrite; fixtures survived as data
contracts). Every rule below is traceable to a failure the 2026-08-13
post-claim audit or the 2026-08-15 P1 audit actually caught; none is
theoretical.

## The prime rule: tests are written FROM contracts, never from code

A test's source of truth is a design contract: the refinement doc's named
test-contract lines, the plan's deliverable rows, AGENTS.md's unit
descriptions (tier policy, notification budget, receipts law), a spec
table in a sota report, or a ratified decision. A test writer who cannot
find the contract for a behavior does NOT reverse-engineer the
implementation and pin what it happens to do - that canonizes bugs. They
write the test from the best contract statement available and, where the
code disagrees, the TEST is presumed right until the architect rules.

Corollary - suspected-bug protocol: a contract-true test that fails
against current code is a FINDING, not a broken test. Wrap it in
`XCTExpectFailure("SUSPECTED CODE BUG: <one line> - see findings")`, add a
row to the wave's findings file, and keep the suite green. Never weaken
the assertion to match the code. (Lesson: the DrawingStore no-op-receipt
defect would have been pinned as correct by any code-derived test.)

## Behavioral laws every suite enforces

1. **Receipts law.** Every mutation test asserts exactly one receipt of
   the named type with the named payload keys. Every no-op test asserts
   ZERO receipts and ZERO persistence. "No receipt without a mutation" is
   a standing rule (plan decision 17); its tests are mandatory per store
   method, both directions. (Lesson: 1.6 shipped a receipt-emitting no-op.)
2. **Round-trip identity.** Every Codable value type gets: encode-decode
   identity, legacy-JSON decode (pin a fixture the moment the type first
   ships), and - where the type has a canonical serialization -
   byte-identical re-encode. (Lesson: the 1.20 fixture discipline worked;
   generalize it.)
3. **Derived-never-stored.** Anything documented as derived (note
   numbers, animation grouping, toc entries, pivot grids, effective
   orders) gets a test that mutates the source and asserts re-derivation,
   plus a test that no stored copy exists to drift.
4. **Determinism.** Injected clocks only (the FieldController pattern);
   no Date()/random in assertions; no test depends on execution order or
   on another test's side effects; renderer tests assert two independent
   passes produce byte-identical output before asserting anything else.
5. **Traps stay pinned.** Ratified thou-shalt-nots get guard tests: no
   `CellStyle` type, no `FunctionVolatility.array`, no `macro_run` tool,
   gpu transition presets all carry non-gpu fallbacks (asserted against
   an INDEPENDENT hardcoded list - see rule 7), pinned fixtures
   byte-stable.

## Structural rules

6. **One behavior per test; the name is the contract sentence.**
   `testRemoveLayerOfUnknownIDEmitsNoReceiptAndDoesNotPersist` - a
   reviewer reads the name and knows the contract without the body.
   Arrange-act-assert; no shared mutable state; helpers build values,
   never hide assertions.
7. **Independent oracles.** A totality/coverage test never iterates the
   system's own catalog to validate the catalog - it pins against a list
   hardcoded in the test from the spec (the 20 OOXML transition names,
   the 12 theme slots, the 9 SMIL node types). (Lesson: the circular
   transition-totality test would have passed after deleting `wipe`.)
8. **Renderers assert content, not survival.** Offscreen render tests
   check pixels/bytes at known coordinates or against tiny golden
   buffers - never only "did not crash". Determinism first (rule 4), then
   content. (Lesson: the chart matrix was no-crash-only.)
9. **Math gets fixtures AND properties.** Engine math (cfvo
   interpolation, ticks, simplex, snap, transforms) gets hand-computed
   fixture cases from the spec formulas plus at least one cheap property
   test (round-trip, invariant, idempotence) where the property is
   statable.
10. **Empirical probes are quarantined and labeled.** Tests that encode
    external-tool behavior (soffice round-trips, wire formats) live in
    clearly-marked files, state the probe date + tool version in a
    comment, skip cleanly when the tool is absent, and are the ONLY tests
    allowed to shell out. Re-verification happens by re-running them, not
    by trusting the comment.

## Environment and gating

11. **Every gated test has an ungated shadow.** DB-gated
    (`TESSERA_DB_INTEGRATION=1`) and soffice-gated tests verify the full
    integration; each MUST be paired with an ungated test of the same
    contract against the in-memory/stub seam, so a plain `swift test`
    exercises the wiring logic. A contract whose only test skips in CI is
    an unverified contract. (Lesson: 18 silent skips meant the receipt
    wiring never ran in a default suite.)
12. **Timeouts are policy.** Every test target sets a per-test timeout
    (executionTimeAllowance or an XCTestObservation watchdog; default 30s,
    soffice probes 120s). A test that would hang fails with a name
    attached. (Lesson: a full-suite run exceeded 38 minutes with no
    verdict; this repo has hang history.)
13. **The full suite has a time budget.** Target: default suite < 5
    minutes on the 16GB M1. Anything slower moves behind a gate (with its
    ungated shadow, rule 11) or gets faster. The wave gate runs: default
    suite + DB pass + soffice pass + corpus scoreboard, all timed, times
    recorded in the wave report.

## Coverage shape (what "done" means per kind of code)

- Store mutation: receipt + persistence + no-op zero-receipt + error path
  (not-found throws without writing).
- Value type: rule 2's triple.
- Engine/controller: contract fixtures + property + trap guards.
- Renderer: determinism + content + degenerate inputs (empty, zero rect,
  single value).
- Agent tool: schema round-trip + tier assertion + receipt behavior +
  denial path.
- Safety surfaces (tier policy, notification budget, undo caps): every
  ratified invariant in AGENTS.md gets a named test - hard cap has no
  override, tier lowering only via revoke(), budget respects the day
  boundary, dryRun excluded. These are the highest-priority rewrites.

## Bookkeeping

- Fixtures are data contracts: never edited after pinning; a needed
  change means a NEW fixture beside the old plus an architect note.
- Deleting or weakening any test requires a doc note in the commit body
  naming the contract it stopped enforcing and why.
- Findings files (`docs/.scratch/test-rewrite-findings-<wave>.md`) carry
  every XCTExpectFailure with its suspected-bug line; the next code wave
  consumes them.
