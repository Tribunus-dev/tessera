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
- **ASCII, not unicode.** Use `-`, `->`, `x`, `...`. No `—`, `→`, `×`, `…`.
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
