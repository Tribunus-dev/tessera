# Instructions for tessera

Tessera is a fork of llama.cpp with calibrated per-tensor quantization (T640),
native spec-decoding (DFlash / DSpark), and Apple-ANE prefill. Author: Julian
Alejandro Torres Nieto / Tribunus.dev. Multi-licensed: `LICENSE-TESSERA`
noncommercial; upstream llama.cpp MIT.

> [!IMPORTANT]
>
> AI-generated code is allowed. What is **not** allowed is shipping code you
> do not understand. The human owns every line, however it was produced.

## AI policy distilled

- **You (or the human) own every line.** Use AI to learn, draft mechanical
  patterns, or pressure-test a design the human already owns. Don't ship
  code the human cannot explain to a reviewer without AI help.
- **No outward-facing action without explicit human approval.** No
  auto-merge, no auto-push, no `gh pr create`, no PR description, no
  commit message, no reviewer response. The architect approves each one.
- **Read surrounding code before editing.** Mimic existing patterns. The
  diff must blend in. If the change introduces a new pattern, PAUSE and
  ask first.
- **ASCII, not unicode.** Use `-`, `->`, `x`, `...`. No em-dash, no right
  arrow, no multiplication sign, no horizontal ellipsis.
- **Comments are concise.** Carry the invariant, not the lesson. The next
  reader knows the codebase.
- **Don't split lines mid-sentence.** Don't force a fixed column width.
- **Reuse existing infrastructure.** Avoid invasive changes that add new
  subsystems. Simpler is better than 100%.
- **Code comments - carry the invariant, not the lesson:**

  ```cpp
  // GOOD (explains a non-obvious invariant)
  accept();
  bool has_client = listen(idle_interval);
  if (has_client) {
    task_queue->on_idle(); // also signal child disconnection
  }

  // BAD (restates what the code already says)
  // Reset n_tokens to 0 before releasing the slot. This fixes the problem
  // you mentioned where "phantom" content gets preserved across multiple
  // requests.
  n_tokens = 0;
  ```

## Project map

| Surface | Where |
|---|---|
| Python quantizer + T640 calibration | `tools/tile640/`, `tools/tessera/` |
| C++ quant side, Metal kernel, L1-L6 layers, tests | `tools/quantize/tessera/` |
| ANE Core ML prefill toolkit (gemma 4 / qwen 3 MTP) | `tools/ane-mtp/` |
| ANE / speculative shared headers | `common/ane-mtp.{h,mm}`, `common/speculative-calibration.*`, `common/tessera-args.h`, `common/tessera-debug/` |
| llama core + KV-cache variants (`*-dsa`, `*-dsv4`, `*-iswa`) | `src/` |
| Tessera uberkernel backend | `ggml/src/ggml-et/` |
| Tile640 dequant kernel | `ggml/src/ggml-metal/ggml-metal-tile640-interleaved.metal` |
| Native Swift macOS / iOS app | `TesseraStudio/` |
| Build variants | `build/` (default), `build-ane/` (ANE), `build-g0/` (g1 Metal) |
| Subsystem status (Production / WIP / Legacy) | `docs/PROJECT-STATUS.md` |

## Workflow

- **Branch namespaces.** `scratch/<feature>/agent-X` (in-flight),
  `evolve-review/<feature>/agent-X` (review), `champions/<id>`,
  `evolve-baseline/wN`, `tessera/*`. `agent@tessera.local` is a first-class
  author.
- **Evolve loop.** A wave's gene worktree freezes -> peer review -> promote
  to `champions/` -> `evolve-baseline/w(N+1)` rebases on top. The
  `.zcode/alphaevolve/<run>/` directory IS the coordination protocol
  (see the alphaevolve meta-skill for the full spec).
- **Skills live in two places.** Workspace skills in `.zcode/skills/`
  (e.g. `tessera-analyst`). User skills in `~/.zcode/skills/` (xlsx,
  skill-refiner, etc.). Check `.zcode/skills/` before starting work.

## Tessera Studio agent surface (agent-ux-fatigue)

The Tessera Studio agent product is the SwiftUI macOS + iOS surface
in `TesseraStudio/`. The agent-ux-fatigue audit (2026-08-12, see
`docs/AGENT-UX-FATIGUE-REVIEW.md`) added the named types and
surfaces below. The audit's intent is to surface data the agent
infrastructure already holds, not to add new inference.

### Tier policy (Wave 1, item 1B)

- `TesseraTier` (`TesseraCore/Agent/TesseraTier.swift`): a `Comparable`
  enum with `tier0 | tier1 | tier2 | tier3`. The dimension is
  reversibility + blast radius, NOT action type. Pure: same inputs
  always produce the same tier. `tier(for: TesseraActionClass, risk:)`,
  `tier(forRisk:)`, and `revoke()` are the public surface. The only
  path that lowers a tier is `TesseraTier.revoke()`; direct
  reassignment without `revoke()` is tier-boundary drift and fails
  review.
- `TesseraSafetyDecision.tier(forActionClass:)` and `riskOnlyTier`
  (`TesseraCore/Agent/TesseraSafetyDecision.swift:113-122`) delegate
  to `TesseraTier` so the tier policy has one auditable surface.
- `ConfirmationPanel` (`TesseraStudioMac/Encryption/ConfirmationPanel.swift`)
  surfaces the tier label as a `TierChip`; the existing confirm /
  reject flow is preserved.

### Notification budget (Wave 1, item 1D)

- `TesseraNotificationBudget` (`TesseraCore/Encryption/TesseraNotificationBudget.swift`):
  a `Swift actor` enforcing a per-UTC-day hard cap (default 3) on
  user-facing push notifications. The cap has NO `force:` override;
  there is no soft-target knob the planner can talk itself into.
  Every `tryPost(...)` records a `TesseraNotificationEvent` to a
  JSONL log at `tessera.notifications.log` (modeled on
  `TesseraAdaptationScheduler.swift:22`). The budget respects
  `TesseraSettings.telemetryEnabled`.
- `TesseraNotificationCategory` enum (`workflow | training |
  adaptation | assessment | covert | wipeReport | reminder`).
- `TesseraAdaptationScheduler` and `TesseraAssessmentScheduler` each
  gain an `onFinished: (@Sendable (TesseraLearningReceipt) -> Void)?`
  hook so silent scheduler collapses surface through the budget.
- `.dryRun` notifications are dropped from the postable set and
  gated behind a separate `devMode` flag.

### Citation + uncertainty on chat + tool results (Waves 2-3, items 2D and 3A)

- `Citation` (`TesseraCore/Models/ChatMessage.swift:82-132`): a
  grounded source backing an agent claim. Fields: `id`, `label`,
  `snippet`, `url?`, optional `RangeOffset` (UTF-16 `(start, end)`,
  not `Range<String.Index>` so it is `Codable`).
- `ChatMessage.sources: [Citation]` (item 3A) and
  `ToolResultPayload.sources: [Citation]` (item 3A): the per-message
  and per-tool-result citation set; the chat row renders the first 3
  as inline chips and expands on tap. The chip vocabulary is shared
  with the audit-log HEAD chip.
- `ConfidenceBand` enum (`ChatMessage.swift:157-161`): categorical
  `low | medium | high`. Per the skill's anti-pattern, never use
  numeric confidence percentages (LLMs are themselves miscalibrated);
  the categorical band is the Tian Pan 2026-04-12 split between
  "the agent was uncertain and said so" and "the agent was confident
  and was wrong". `ToolResultPayload.confidenceBand: ConfidenceBand?`
  is the wire field; `nil` is the documented "no uncertainty
  available" path.

### Inline stop + audit log side panel (Waves 3, items 3C and 3D)

- `StopReason` (`TesseraCore/Agent/TesseraAgentLoop.swift:34`):
  `userRequest` (paradox 5 / Microsoft HAX G11) and friends. The
  loop's `stop(reason:)` records the reason and the loop does NOT
  auto-resume; a new `run()` is rejected until `clearStop()` is
  called. `lastStopReason` is `public private(set)` so the audit
  log and the chat progress feed can read the state without
  depending on a new `AgentEvent` case.
- `AgentInlineStopButton` (`TesseraStudioMac/Views/Editor/AgentCursorOverlay.swift`):
  the inline stop affordance at the agent cursor. The host wires
  `onStop: () -> Void` to `TesseraAgentLoop.stop(reason: .userRequest)`.
- `ActionAuditLogPanel` (`TesseraCore/Agent/ActionAuditLogPanel.swift`):
  a side-panel SwiftUI view rendering a chronological list of every
  agent action + outcome with the tier label, time, and receipt id.
  Pull, not push: the host toggles `isPresented` from the existing
  `ConfirmationPanel`. The panel is backed by `ActionAuditLogStore`
  (`@Observable`, `@MainActor`, default capacity 500, FIFO trim) and
  uses the same chip vocabulary as the audit-log HEAD chip.
- `ActionAuditOutcome` enum (`success | failure | reverted | blocked`)
  and `ActionAuditEntry` struct: pure value types so the capture path
  is append-only and the read path is single-sourced.

### Other named surfaces from the audit

- `DestinationStarterPrompts` + `DestinationStarterPromptsList`
  (`TesseraCore/Agent/DestinationStarterPrompts.swift`): per-context
  3-5 starter prompts for the empty chat (macOS dock, iOS
  `ContentUnavailableView`, `LibraryView` empty state).
- `ChatProgressFeed` (`TesseraCore/Agent/ChatProgressFeed.swift`):
  pull-to-open progress feed in the chat dock; never auto-pushes.
- `AuditLogHeadChip` (`TesseraStudioMac/Views/Editor/TesseraDiffOverlayView.swift`):
  the one-line chip between the diff and the Accept/Reject
  controls; rendered only on `state == .diffComplete` or
  `.editable`, suppressed on `.streaming` and when
  `Receipt.mutations` is empty. The chip is the load-bearing
  surface for the verification paradox (paradox 1).
- `TimeLimitedUndoPolicy` + `TimeLimitedUndoBudget` +
  `TimeLimitedUndoChip` (`TesseraStudioMac/Views/Editor/EditorUndoCoordinator.swift`):
  time-based undo cap (default 90s) replacing the depth cap.
- `ReceiptsCoordinator.receiptStream()` -> `AsyncStream<Receipt>`
  (`TesseraCore/Productivity/Receipts/ReceiptsCoordinator.swift`):
  broadcast receipt source replacing the 200ms polling.

## Measurement architecture (agent-ux-fatigue)

Every move that ships from the agent-ux-fatigue audit carries a
one-primary + one-trust + one-anti measurement architecture (per
the skill's `references/measurement-architecture.md`). The rule is
fixed; only the role each metric plays changes between move types.

- **Primary** (the metric the move is supposed to move). Without a
  number on the primary, the move has not shipped.
- **Trust** (the metric that catches the failure mode). Same move's
  failure mode register, not a generic dashboard.
- **Anti-metric** (the metric that catches the opposite failure).
  The most often missing role. If the primary is on target and the
  anti-metric is off, the move is over-corrected and will need to
  be relaxed.

Format: `primary: <metric> <direction> <N% | N pp | N absolute> by
week <W>`. The deadline is a real number. Vague targets get argued
about; specific targets get shipped against.

The per-item targets for the 12 shipped units are in
`docs/PROJECT-STATUS.md` under "Tessera Studio agent-UX-fatigue
audit (2026-08-12)". The skill's worked examples
(`references/measurement-architecture.md` lines 76-132) cover the
three common move shapes: gating (Risk-Tiered Approval Gates),
surfacing (Action Audit Log, Progress Feed), off-ramp (Inline Stop).

The architectural rules from the skill that bind every shipped
unit:

- The cap on a budget is a HARD cap. There is no `force:` override.
  The architect approves a new enum case at the call site if a
  future use case genuinely warrants a high-priority bypass.
- The audit log is PULL, not push. Surfacing it as a notification
  re-introduces the proactive-agent paradox (paradox 7) onto the
  audit surface.
- The off-ramp is a hard stop. The agent does not auto-resume. The
  thermostat-on-a-schedule metaphor: a manual nudge holds until the
  next user-initiated `clearStop()`.
- The diff overlay's chip is the headline, not the article. Field
  cap of 5; the user opens the row (or the receipts drawer) for
  the full record.

## Program Routing - the conductor

The model is the dynamic-routing runtime across these capabilities. State
which capability you are about to dispatch and why, BEFORE the dispatch,
in the same turn.

| Capability | What it does | How to invoke |
|---|---|---|
| `alphaevolve` | Multi-agent evolutionary coding loop (init / join / finalize modes) | `Agent(subagent_type="alphaevolve")` |
| `tessera-analyst` | Deep research / architecture study on Tessera-specific topics | Load the `tessera-analyst` workspace skill (`skill({name:"tessera-analyst"})`) |
| `findings-curator` | Pick up entries from `.zcode/alphaevolve/findings.jsonl`, ship fixes | `Agent(subagent_type="findings-curator")` |
| `verifier` (code review) | Mandatory review gate before promoting a champion to main | `Agent(subagent_type="verifier")` |

### Routing rules (priority order)

1. **Explicit user request for a capability** -> route directly. Don't
   ask which one.
2. **A wave just froze** (`stack-state.json` changed under
   `.zcode/alphaevolve/<run>/integration/`) -> offer `tessera-analyst` +
   `findings-curator` to capture the result.
3. **Open high / medium findings in `findings.jsonl`** -> offer
   `findings-curator fix N`.
4. **About to promote a champion to main** -> MANDATORY `verifier` review
   gate + explicit human approval. Never auto-promote.
5. **Ambiguous** -> ask the user. Never guess.

### Run-book protocol

Before dispatching program-level work, read the run-book:

```
python3 scripts/run-book.py show
python3 scripts/run-book.py next
```

After each step that completes a phase, update it:

```
python3 scripts/run-book.py update <id> --status done
python3 scripts/run-book.py decide "promoted g1 -0.48% RSS, stacked on main"
```

The run-book (`.zcode/program/run-book.json`) IS the protocol. Atomic
writes from the helper script so a partial update never corrupts state.

### Hard rules

- **Never auto-promote** without `verifier` review + human approval.
- **Never fabricate run-book state.** If a phase didn't happen, it
  doesn't go in.
- **State the route out loud.** "Routing to findings-curator because
  findings.jsonl has 3 high-severity open items" -> THEN dispatch.

## Useful resources

### Project docs (tessera)

- `docs/PROJECT-STATUS.md` - Production / WIP / Legacy status per pillar
- `docs/AGENT-UX-FATIGUE-REVIEW.md` - the 2026-08-12 agent-ux-fatigue
  audit of Tessera Studio (the SwiftUI macOS + iOS agent product);
  full report with per-move measurement architectures, paradox
  analysis, and the wave-by-wave implementation plan
- `docs/architecture.md` - top-level architecture
- `docs/runtime-aware-pipeline.md` - Layers 1-6 (L1 imatrix -> L6 acceptance)
- `docs/c++-port-design.md` - the C++ port design (locked decisions 1-14)
- `docs/findings-*.md` - ledger rollups
- `docs/audit-*.md` - audit reports
- `docs/build.md` - build flags
- `tools/server/README.md` - server usage

### Design studies (tessera)

- `docs/inference-engines-comparison-study.md`
- `docs/ane-backend-deep-study.md`
- `docs/vllm-concurrency` (or whichever path holds the vLLM study)
- `docs/moe-disk-offload`
- `docs/interleaved-kernel-design-study.md`

### Inherited from upstream llama.cpp (clearly upstream)

- `docs/development/HOWTO-add-model.md` - upstream how-to
- `docs/development/parsing.md` - PEG parser
- `docs/autoparser.md` - auto parser
- `common/jinja/README.md` - Jinja engine

> No new agent types. The four capabilities above are the complete set.
> No background scheduler. Routing is reactive on user turns. Restart the
> runtime after editing this file so the new routing section loads.
