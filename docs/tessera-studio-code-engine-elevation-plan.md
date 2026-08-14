# Tessera Studio coding-agent engine - elevation plan

Status: proposal, not started. Owner: architect. Scope: the coding-agent
engine (inference -> loop -> tools -> code material -> receipts -> learning),
not the quantizer / C++ runtime.

## 0. Thesis

Tessera's coding engine is already differentiated in kind, not degree. The
copycats (Claude Code, ChatGPT, Antigravity) are all the same product in
different skin: a remote frontier model + a tool loop + a diff/terminal
surface. Tessera owns the stack below the API boundary, which makes three
moats structurally unavailable to them:

1. Self-measuring, self-optimizing inference (spec-acceptance traces ->
   drafter training -> faster on-device decode).
2. Evidence-native edits (every mutation is a signed, schema-versioned,
   byte-exact-reversible receipt with a C2PA manifest).
3. Constitutional trust (structural action classes, RULES-not-ML
   irreversibility, tier policy, ratchet, miscalibration detection).

The product is not "a better Claude Code". It is the coding agent that is
yours: your silicon, your proof, your improvement loop.

The elevation problem is that this value is buried in the infrastructure and
the surface defaults to chat prose. The plan below turns the moat into the
headline and closes the one real capability gap (tool calling) and the one
real correctness gap (no verify-before-accept).

## 1. Current state

| Layer | Where | State |
| --- | --- | --- |
| Inference | `TesseraStudio/Sources/TesseraCore/Engine/LlamaLLMProvider.swift`, `CLlamaSpecEngine.swift`, `TesseraRuntimeDrafterResolver.swift` | Local GGUF via libllama; spec decoding with drafter; per-step `llama.tessera.spec.v1` trace capture. |
| Loop | `TesseraStudio/Sources/TesseraCore/Agent/TesseraAgentLoop.swift` | Streaming ReAct, maxIterations 10, hard stop, pending-mutation chip. |
| Constitutional trust | `Agent/TesseraActionClass.swift`, `TesseraSafetyDecision.swift`, `TesseraTier.swift`, `TesseraApprovalEngine.swift`, `Learning/TesseraAutonomyService.swift`, `TesseraMiscalibrationDetector.swift` | Structural classification, tier0-3, ratchet, circuit breaker, regime-shift tightening. |
| Evidence | `Productivity/Receipt.swift`, `ReceiptSigner.swift`, `Receipts/ReceiptsCoordinator.swift`, `Materials/Code/CodeMutation.swift`, `CodeStore.swift` | Signed receipt per mutation; byte-exact inverse; C2PA manifest. |
| Self-improvement | `Learning/TesseraTrainingOrchestrator.swift`, `TesseraTraceStore.swift`, `TesseraCapabilityEvalService.swift`, `Tools/Learning/RecordOutcomeTool.swift` | Trace -> train -> eval loop; world outcomes (build/test/commit/revert). |

The trust and evidence layers are the strongest pieces (the agent-ux-fatigue
audit reached the same conclusion: "the agent infrastructure is more mature
than the agent surface").

## 2. Honest gap vs the copycats

1. Tool calling is a text-fence hack. `LlamaLLMProvider.buildPrompt` +
   `toolsInstruction` inject tools as prose; `parse()` scans ```tool fences.
   No native function calling, no grammar. This is the capability ceiling.
2. The loop is a plain for-loop, no verify-before-accept. The constitutional
   pieces exist (`TesseraActionVerifier`, `RecordOutcomeTool`) but the loop
   never requires build/test to pass before an edit is "done".
3. The surface hides the moat. Receipts, tier, confidence, telemetry all
   exist and all default to chat prose / drawers.

## 3. Phase 0 - reconcile the two checkouts

There are two trees: this workspace (`tessera-l1-l6`, HEAD 6d25d8d7c) and a
parallel checkout (`/Users/user/Developer/GitHub/tessera`, HEAD 8fe7659c6).
Their `TesseraStudio/Sources` trees differ by a handful of files:

- In `tessera` but not here: `Agent/ApprovalSafetyFacts.swift` (agent-ux-
  fatigue wave 4B) + 4 `FormulaEngine/Functions/*` files.
- Here but not in `tessera`: `Productivity/Receipts/C2PAToolCompatibility.swift`,
  `MaterialReceiptPayload.swift`, `ImportExport/TesseraFormatBridge.swift`.

Action: port `ApprovalSafetyFacts.swift` into this workspace (it feeds the
ApprovalSheet tier/risk display, which Phase 1 builds on), decide the
FormulaEngine files, then treat this workspace as the single source of truth.

Acceptance: the delta between the two `TesseraStudio/Sources` trees is either
empty or a documented, intentional difference.

## 4. Phase 1 - receipt as the headline (trust surface)

Goal: every agent edit renders as a receipt card (tier + confidence + checksum
+ undo), not "Rewrite complete" prose.

Files and changes:

- `TesseraStudio/Sources/TesseraCore/Productivity/Receipt.swift`
  Add optional `tier: TesseraTier?` and `confidenceBand: ConfidenceBand?`
  fields (additive, Codable-default nil so existing receipts decode). The
  receipt becomes the durable carrier of the gate decision, not just the
  mutation.
- `TesseraStudio/Sources/TesseraCore/Productivity/Materials/Code/CodeStore.swift`
  Thread `tier` and `confidenceBand` from the mutation into the
  `appendReceipt` payload (currently only path/summary/checksums).
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraAgentLoop.swift`
  Carry the gate's `TesseraTier` and the tool result's `confidenceBand`
  into the receipt. Today `pendingMutation` is cleared after `toolResult`
  and the tier is lost; fix that by keeping the tier on the mutation result.
- `TesseraStudio/Sources/TesseraCore/Editor/AuditLogHead.swift`
  Add `tier` + `confidence` fields and render them in the chip (still capped
  at `fieldCap == 5`). Refactor in place; no second chip type.
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/TesseraDiffOverlayView.swift`
  Replace the "Rewrite complete" status label with the receipt headline
  (tier + confidence + receipt id), so the chip IS the status.

Acceptance: every accepted or rejected diff shows tier + confidence band +
receipt id inline; zero agent mutations produce a nil-tier receipt.

Measurement:
- primary: % of agent edits whose receipt card renders tier + confidence
  (target 100% by end of phase).
- trust: rep-reported "I could explain this change to a reviewer" score
  (up >=20%).
- anti: % of edits where the receipt card is suppressed or empty (target 0).

## 5. Phase 2 - structured tool calls (capability ceiling)

Goal: replace ```tool fence parsing with GBNF-grammar-constrained decoding.

The fork already ships the grammar machinery (`include/llama.h:1463`
`llama_sampler_init_grammar`, `common/sampling.cpp:254-258` builds a grammar
sampler). The shim just does not expose it.

Files and changes:

- `TesseraStudio/Sources/CLlama/include/cllama_shim.h` + `cllama_shim.c`
  Add `cllama_engine_generate_grammar(eng, prompt, grammar, max_tokens,
  on_token, user_data)` and a spec-engine variant. Resolve
  `llama_sampler_init_grammar` at load time; degrade to the existing path when
  the symbol is missing (same degrade-open pattern as the batch surface).
- `TesseraStudio/Sources/TesseraCore/Engine/LlamaLLMProvider.swift`
  Add a grammar path: build a GBNF grammar from the registry, route
  tool-intent turns through grammar-constrained generation, keep `parse()` as
  the fallback for engines without grammar.
- New `TesseraStudio/Sources/TesseraCore/Engine/TesseraToolGrammar.swift`
  Derive a GBNF grammar from `TesseraTool` + `JSONSchema`: a tool-call object
  `{"name":"<enumerated>","arguments":{...}}` over the known tools. One
  generator, no `_v2` sibling.

Acceptance: tool-call parse failure rate drops sharply; no behavior change on
engines without grammar (fallback still works).

Measurement:
- primary: tool-call fence-parse failure rate (down >=90%).
- trust: tokens consumed per successful tool call (down; less prose waste).
- anti: % of valid tool turns the grammar incorrectly rejects (near 0; the
  fallback catches any residual).

## 6. Phase 3 - receipt-driven verification (correctness loop)

Goal: the agent cannot mark an edit "accepted" until build/test verify;
otherwise it auto-reverts via the byte-exact inverse.

Files and changes:

- `TesseraStudio/Sources/TesseraCore/Agent/TesseraAgentLoop.swift`
  Add a verify gate after code-mutating tool calls. The gate runs the repo's
  build/test via `ProcessRunner` and records a world outcome, instead of
  relying on the model to emit `record_outcome`.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraWorldOutcomeContracts.swift`
  + `Tools/Learning/RecordOutcomeTool.swift`
  Already present; wire a built-in verifier alongside the tool so the loop is
  not dependent on model cooperation.
- `TesseraStudio/Sources/TesseraCore/Productivity/Materials/Code/CodeMutation.swift`
  `inverse` already exists; use it for auto-revert on a failed verify.

Acceptance: a mutation whose build fails is reverted and its receipt records
`verification: revert`; a passing one records `verification: pass`.

Measurement:
- primary: % of code edits with a recorded verification outcome (target 100%
  of code edits).
- trust: % of "accepted" edits later manually reverted (down).
- anti: verification latency per edit (bounded; the gate must not become a
  full CI per edit - scope it to the affected target).

## 7. Phase 4 - self-improving drafter (compounding moat)

Goal: close the trace -> train -> hot-swap -> measure loop and surface the
speedup as a receipt.

Files and changes:

- `TesseraStudio/Sources/TesseraCore/Engine/LlamaLLMProvider.swift`
  Hot-swap the drafter after a successful training cycle. Today the drafter is
  resolved at init only ("hot-swapping ... is a follow-up").
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraTrainingOrchestrator.swift`
  + `TesseraAdaptationScheduler.swift`
  Auto-trigger training on the trace threshold; wire the reserved
  `guardPassed`/`guardFailed` outcomes to the capability eval.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraCapabilityEvalService.swift`
  Gate the trained drafter on acceptance + throughput vs baseline; discard on
  regression.

Acceptance: after >= threshold traces and one training cycle, the provider
reloads the trained drafter; a regressing drafter is discarded, never shipped.

Measurement:
- primary: decode tokens/sec after the drafter swap (up >=2x on a held-out
  prompt set).
- trust: spec acceptance rate (up).
- anti: % of trained drafters discarded by the eval gate (bounded, target
  <50% - the gate exists to stop bad drafters, not to rubber-stamp).

## 8. Phase 5 - portable provenance (explain/export)

Goal: one-click "explain this change" / PR body from the receipt chain.

Most of the machinery is already built (`ReceiptExportService` supports
signedJSON / markdown / c2paDocument / es256JUMBF / file;
`C2PAToolCompatibility` produces c2patool-compatible manifests). This phase is
surfacing + one new renderer.

Files and changes:

- `TesseraStudio/Sources/TesseraCore/Productivity/Receipts/ReceiptExportService.swift`
  Add a `changeManifest` renderer: a markdown change description (what changed,
  why, tier, confidence, verification, checksums) suitable for a PR body.
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/TesseraDiffOverlayView.swift`
  Add an "Explain" affordance next to Accept/Reject that exports the receipt
  chain.
- Optional: `TesseraStudio/Sources/TesseraCore/Productivity/Materials/Code/GitReadOnly.swift`
  Diff the receipt against the working tree as a trust check.

Acceptance: a reviewer can reconstruct "what changed, why, at what tier, with
what verification" from the exported manifest without opening the app.

Measurement:
- primary: time-to-answer "what did this agent change and why" (down).
- trust: reviewer completeness score (up).
- anti: export size / time (bounded).

## 9. Sequencing and ownership

- Phase 0 first (small, unblocks Phase 1's ApprovalSheet work).
- Phase 1 and Phase 2 are disjoint (Phase 1 touches Receipt/CodeStore/
  AuditLogHead/DiffOverlay; Phase 2 touches the C shim + LlamaLLMProvider +
  a new grammar file) - they can run as parallel writers.
- Phase 3 touches `TesseraAgentLoop.swift`, which Phase 1 also touches, so
  serialize Phase 3 after Phase 1's loop change lands (or a single writer
  owns both loop edits).
- Phase 4 is the longest horizon; start after Phase 2 (structured tool calls
  produce cleaner traces) but it is not blocked by Phase 3.
- Phase 5 is mostly-surface and can ship any time after Phase 1.

Recommended ship order: 0 -> 1 -> 2 -> 3 -> 5 -> 4. Trust first (fastest,
most legible), capability second, correctness third, provenance as a quick
win, compounding moat last because it needs the most runway.

## 10. Risk register

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Grammar path breaks a model that produced valid fences | Medium | Keep `parse()` as fallback; grammar only constrains, never removes the fence path. |
| C shim ABI change breaks the batch/spec surface | Medium | Additive symbol + degrade-open runtime check, mirroring the batch surface. |
| Verify gate adds latency and turns every edit into a CI run | Medium | Scope verify to the affected target only; cap latency with an explicit budget. |
| Trained drafter regresses on real prompts | Medium | The capability-eval gate (Phase 4) is the sole ship authority; discard on regression. |
| Receipt schema change breaks old receipts | Low | Additive optional fields with nil default; no field renames. |

## 11. Out of scope / explicitly not doing

- No new agent types, no background scheduler (per AGENTS.md "Program
  Routing" - the four capabilities are the complete set).
- No plan-mode / sub-agent fanfare in the loop before Phase 2 and Phase 3; a
  fancier loop over a text-fence tool layer is still a text-fence tool layer.
- No chasing "best frontier model" or "most polished editor" - that is a
  commodity race Tessera loses on someone else's terms.
- No versioned parallel implementations: every change refactors in place.
