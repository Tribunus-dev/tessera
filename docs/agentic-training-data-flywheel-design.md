# Tessera Agentic Training Data Flywheel - Design

Status: design + Phase 1 (W1) landed. Phases 2 and 3 partially landed; the
training driver (Stage 7) and the closed-loop observe/manifest modules are
next-wave work. The plan below is the authoritative reference.

## 1. The 2026 SOTA reference shape

Three sources define what "world-class" means for agentic training data
collection in 2026.

**OpenThoughts-Agent** (Raoof, Zhuang, Nezhurina, Guha et al., arXiv:2606.24855,
June 2026) is the most systematic public study. Its 6-stage SFT pipeline
(task sourcing -> task mixing -> task description augmentation -> task
filtering -> teacher selection -> rollout filtering) and the 100+ controlled
ablations are the right reference for what an agentic data pipeline looks
like in production. The headline numbers: 100K examples, Qwen3-32B reaches
44.8% average across seven benchmarks and 54.0% on SWE-Bench Verified,
+3.9pp over the prior best open-data agent. The headline finding is that
**task-source choice swings SWE-Bench Verified by 30pp and Terminal-Bench 2.0
by 10pp**; the optimal mix is top-4 sources combining synthetic issue tasks
(SWE-Smith, Issue Tasks) with human-generated infrastructure Q&A
(StackExchange SuperUser, Tezos). The OT-Agent signal for difficulty is
teacher-token-length: tasks where GPT-5 had to consume more tokens to solve
them are the harder ones, and filtering on that signal lifted performance by
~3pp. Rollouts under five turns are dropped. A scaling plateau sits around
31,600 tasks; beyond that, synthetic augmentation is the only path through
it.

**ATIF v1.7** (Agent Trajectory Interchange Format, Harbor / Laude
Institute) is the emerging interchange standard for full-fidelity
trajectories. The schema is JSON, versioned, with Pydantic validation, and
is implemented natively in Harbor, NVIDIA NeMo Agent Toolkit, NeMo Relay,
and imported by Arize Phoenix. The root object carries `schema_version`,
`session_id`, `trajectory_id`, `agent{name, version, model_name,
tool_definitions, extra}`, ordered `steps[]` of `{step_id, timestamp, source,
message, reasoning_content, tool_calls[{tool_call_id, function_name,
arguments}], observation[{results[{source_call_id, content}]}], metrics}`,
aggregate `final_metrics`, optional `subagent_trajectories[]` and
`continued_trajectory_ref`. NVIDIA NeMo Relay documents the canonical
event-to-step mapping: LLM Start -> `user` step; LLM End -> `agent` step
(with `tool_calls` promoted from LLM End, not Tool Start); Tool End ->
observation correlated by `source_call_id`; Tool Start, Mark, and Scope
events are not steps.

**OpenTelemetry GenAI semantic conventions v1.41** (May 2026) define the
span shape every modern agent runtime should emit. Spans are
`{gen_ai.operation.name} {gen_ai.request.model}` for chat and
`execute_tool {gen_ai.tool.name}` for tools. Required attributes are
`gen_ai.operation.name` and `gen_ai.provider.name`; recommended are
`gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.conversation.id` (must
NOT be synthesized - if no real id exists, leave it off).
`gen_ai.tool.call.arguments` and `gen_ai.tool.call.result` are marked
Opt-In because they are sensitive. Agent-level attributes are
`gen_ai.agent.{id, name, description, version}` and `gen_ai.tool.definitions`.
Content capture is controlled by the
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` env var.

Two more references complete the picture but are not strictly required to
copy: **Letta Trajectory** is a more compact 6-record format
(meta, user, reasoning, assistant, tool, answer) that achieves 1.1x to
1.7x reduction versus ATIF by dropping harness bookkeeping. **ADP
(Agent-Data-Protocol)** from neulab is similar - schema-versioned JSON,
action/observation with `tool_call_id` correlation, 300+ language support.
**NeMo Curator** is the OSS reference for three-tier deduplication: exact
(MD5) -> fuzzy (MinHash+LSH, Jaccard 0.8, num_bands=20, minhashes_per_band=13)
-> semantic (embeddings + K-means + cosine), run in that order so each
tier shrinks the input for the next, with removal-ratio reporting per
tier and a halt-on-anomalous-removal safety.

The world-class shape, distilled: **versioned JSONL schema with schema-gate
at parse** + **interception capture or event-log conversion to that schema**
+ **three-tier dedup with halt-on-anomaly** + **ingest-time scrub** +
**multi-turn >=5 filter** + **task-source mix analysis with coverage
dashboard** + **token-fidelity invariant** + **replayable trajectory** +
**closed-loop observation that re-feeds the capture**.

## 2. Tessera's current surface

The drafter pipeline is genuinely first-class for what it does, and the
discipline transfers. `tessera-dataset` reads `llama.tessera.spec.v1` JSONL
and emits four output modes (text, pairs, lk, dflash). Schema enforcement
is at the parse gate; wrong-schema records become `n_skipped`, not errors.
Pure-logic separation: the data prep modules carry no llama/ggml
dependency. D-PACE weights are smoothed+normalized and baked into the
dataset record, so the loss graph is unchanged. `tessera-anonymizer` and
`tessera-scrub` are well-engineered egress privacy tools; they are
currently used for **cloud-teacher egress**, not for ingest-time scrubbing
of training data. Reusing them at ingest is a one-call change, not a
rewrite. `tessera-corpus` provides deterministic synthetic calibration
inputs (xorshift32 + Box-Muller) - the pattern is the right shape for a
deterministic replay harness. `tessera-archive` shows the schema-versioned
sidecar pattern. `tessera-capability-eval` defines a five-axis eval
substrate (mechanical, api_currency, hard_tail, personal_style,
general_competence) that maps naturally to agentic eval axes. The DFlash
design doc section 7.1 (token-fidelity invariant, renderers, dual
message/token streams) is the right principle for the agentic path too.

What world-class has and Tessera lacks: a capture layer; an
agent-trajectory schema and the validation that goes with it; quality
gates (dedup, ingest-time scrub, toxicity); coverage and diversity
analysis; replay and determinism; reward/verifier signal at the
trajectory level; the closed loop from trained model back to capture;
token-fidelity for tool calls.

## 3. The flywheel: ten stages and their Tessera modules

The closed loop is **capture -> validate -> dedup -> scrub -> filter ->
split -> train -> deploy -> observe -> capture (again)**. Each stage is a
module or pair of modules in the new `tools/quantize/tessera/traj/`
directory. Existing Tessera modules map cleanly to most stages; the new
ones are flagged.

| # | Stage | Tessera module | Status |
|---|---|---|---|
| 1 | Capture | `tessera-traj-cli` + `tessera-trajectory.{h,cpp}` | landed (W1) |
| 2 | Validate (schema) | `tessera-traj-validate` | landed (W1) |
| 3 | Dedup (3 tiers) | `tessera-traj-dedup` | landed (W2) |
| 4 | Scrub (ingest) | `tessera-traj-scrub` (wraps `tessera-anonymizer` + `tessera-scrub`) | landed (W2) |
| 5 | Filter (multi-turn, length, source, difficulty) | `tessera-traj-filter` | landed (W2) |
| 6 | Split (train/eval/held-out) | `tessera-traj-split` | landed (W2) |
| 7 | Train | `tessera-train-agent` | next-wave (W3) |
| 8 | Deploy | existing `llama-cli` / `llama-server` | reused |
| 9 | Observe (closed loop) | `tessera-traj-observe` | next-wave (W3) |
| 10 | Manifest / lineage | `tessera-traj-manifest` | landed (W3) |

The new directory sits next to `tessera-dataset` and follows the same
naming, header-comment, and pure-logic conventions: no llama/ggml dep in
the data prep modules, `n_written` / `n_skipped` return convention, `ts_*`
C API surface, `test_*` boundary test per module.

## 4. llama.tessera.agent-traj.v1 schema

The schema is a strict subset-and-superset of ATIF v1.7. Tessera adds three
Tessera-specific fields and standardizes on the versioned string
`llama.tessera.agent-traj.v1` rather than ATIF's `ATIF-v1.7`, because the
existing Tessera convention (every schema is `llama.tessera.*.vN`) is what
the rest of the codebase keys on. The wire format is JSONL; one record per
captured trajectory. The schema is **frozen at v1** in the first cut -
additional fields go into v2, not by mutating v1 records.

```json
{
  "schema": "llama.tessera.agent-traj.v1",
  "trajectory_id": "tessera-2026-08-10-0001",
  "session_id": "sess-cwd-7a1e",
  "task_id": "nebius__sdf-xarray-24",
  "task_source": "swe-rebench",
  "task_taxonomy": {
    "type": "fix",
    "language": "python",
    "difficulty": "medium"
  },
  "agent": {
    "name": "tessera-traj-cli",
    "version": "0.1.0",
    "model_name": "Qwen3-Coder-30B-A3B",
    "tool_definitions": [ /* OpenAI-format JSON schema array */ ]
  },
  "env": {
    "image": "nebius/swe-rebench:sdf-xarray-24@sha256:...",
    "git_sha": "abc123",
    "git_branch": "main",
    "seed": 42
  },
  "system_prompt": { "text": "...", "hash": "sha256:..." },
  "messages": [
    { "step_id": 1, "source": "user", "message": "...", "timestamp": "..." },
    { "step_id": 2, "source": "agent", "message": "...",
      "reasoning_content": "...",
      "tool_calls": [{ "tool_call_id": "c1", "function_name": "execute_bash",
                       "arguments": {"command": "ls -la"} }],
      "observation": { "results": [{ "source_call_id": "c1",
                                    "content": "total 12\n...",
                                    "exit_code": 0,
                                    "duration_ms": 23,
                                    "error_category": null }] },
      "metrics": { "prompt_tokens": 412, "completion_tokens": 18,
                   "cached_tokens": 200, "cost_usd": 0.00018 },
      "timestamp": "..." },
    { "step_id": 3, "source": "tool", "tool_call_id": "c1",
      "content": "...", "timestamp": "..." }
  ],
  "final_metrics": {
    "total_prompt_tokens": 1840, "total_completion_tokens": 312,
    "total_cached_tokens": 800, "total_cost_usd": 0.0019,
    "total_steps": 17, "n_user_turns": 1, "n_assistant_turns": 8,
    "n_tool_calls": 12, "n_errors": 2, "n_recoveries": 2
  },
  "reward": {
    "verifier": "swe-rebench",
    "verifier_outcome": "pass",
    "verifier_partial": 1.0,
    "verifier_tests": { "pass": 14, "fail": 0, "skip": 0 },
    "exit_status": "submitted",
    "gen_tests_correct": 3, "pred_passes_gen_test": 3
  },
  "ingest_scrub": {
    "applied": true, "aggressiveness": "balanced",
    "removed_pii": 0, "removed_secrets": 0,
    "redaction_map_id": "redmap-2026-08-10-0001"
  },
  "manifest": {
    "captured_by": "tessera-traj-cli@0.1.0",
    "captured_at": "2026-08-10T18:00:00Z",
    "harness": "openhands-0.54.0",
    "schema_version": "llama.tessera.agent-traj.v1"
  }
}
```

The three Tessera-specific fields beyond ATIF are: `task_source` (which
capture source fed this; required for source-mix analysis and the
`remove` log), `task_taxonomy` (used for the coverage dashboard and the
held-out split), and `reward` (the verifier outcome - required for the
filter stage and the eval split). `env` (container image, git sha, branch,
seed) is what makes the trajectory replayable; without it, replay is a
guess. `ingest_scrub` records what was done at ingest, separate from the
egress-side anonymizer/scrub call.

Validation at parse time enforces: schema name == `llama.tessera.agent-traj.v1`;
sequential `step_id` from 1; ISO 8601 timestamps; tool_call_id <-> observation
correlation; `source_call_id` matches a preceding tool call;
`final_metrics.total_steps == messages.size()`;
`reward.verifier_outcome in {"pass", "fail", "partial", "error", "timeout"}`.

## 5. Capture layer (Stage 1)

The capture pattern choice is the single largest architectural decision
in this expansion. Three options exist in the SOTA:

1. **Interception proxy** (Prime Intellect's pattern, already cited in
   the DFlash design doc section 7.1): the agent harness talks to a fake
   OpenAI/Anthropic-compatible endpoint; a thin layer intercepts each
   request/response, injects logprob capture + temperature, and routes to
   the trainer.
2. **Event-log converter** (Harbor/OpenHands): the agent emits an event
   log in its native format; an installed-agent adapter reads the log,
   maps events to ATIF, exports.
3. **In-process capture hook** (Tessera's `tessera-s2s-cli` shape for
   TTS): the C++ capture tool itself runs the agent loop, calls the model,
   executes tools, and writes records.

**Tessera ships option 2 (`--mode=openhands`) as the first capture mode,
with the option 1 interception proxy as the next-wave fallback.** Option 2
is the long-term standard; Harbor ships OpenHands, Terminus-2, and others
as installed-agent adapters, and the event-to-step mapping is a small
surface. Option 1 covers the case where the harness is in a different
language (Swift Tessera Studio, Python harness) and the agent does not
expose an event log.

`tools/quantize/tessera/traj/tessera-trajectory.{h,cpp}` is the C++ core.
It implements the `llama.tessera.agent-traj.v1` schema with the same
nlohmann/json + pure-logic pattern Tessera already uses. The C API
exposes:

- `ts_traj_record_open(path, schema_version, session_id, agent) -> writer`
- `ts_traj_record_step(writer, step) -> 0/-1`
- `ts_traj_record_close(writer, final_metrics, manifest) -> 0/-1`
- `ts_traj_validate_file(path) -> ts_traj_validation_result`

`tools/quantize/tessera/traj/tessera-traj-cli.cpp` is the standalone
capture CLI. It supports three sub-modes: `--mode=openhands` (event-log
converter), `--mode=proxy` (next-wave; runs the interception proxy on a
port), `--mode=replay` (next-wave; re-executes a captured trajectory for
the replay/determinism gate).

`tools/quantize/tessera/traj/tessera-traj-validate.cpp` is the validation
CLI. It reads a `*.agent-traj.v1.jsonl`, applies the schema gate, and
emits a structured error log. Exit code: 0 on all valid; 1 on any
invalid; 2 on missing file.

## 6. Quality gates (Stages 2-6)

**Stage 2 - validate.** `tessera-traj-validate` reads a
`*.agent-traj.v1.jsonl` and returns `{n_valid, n_invalid, errors[]}`.
Each error has `{line_no, trajectory_id, field, message}`. The same logic
is reachable as `ts_traj_validate_file` in the C API. The boundary test
exercises: wrong schema, missing required fields, non-sequential
step_id, mismatched tool_call_id, bad timestamps, broken reward enum,
broken `final_metrics.total_steps`. This is the same schema-gate pattern
as `tessera-dataset.cpp:170-174` extended to the trajectory level.

**Stage 3 - dedup.** Three tiers, run in this order. **Tier 1 exact
dedup** computes a SHA-256 of the normalized `(system_prompt.text,
[message.content for message in messages if source != "user"])` and
drops byte-identical duplicates. **Tier 2 fuzzy dedup** shingles messages
into 5-grams, computes MinHash with 260 permutations, LSH bands at
`num_bands=20, minhashes_per_band=13` (so 20*13 = 260 fits exactly),
drops pairs above Jaccard 0.8. LSH inflection sits at Jaccard
J where J^13 = 0.5 -> J ~= 0.949; the 0.8 threshold keeps a margin
under the inflection so we only catch true near-duplicates.
**Tier 3 semantic dedup** embeds each trajectory (using a Tessera-side
embedding model, not an API call - the no-egress preference is preserved)
and drops near-cluster-center neighbors above cosine 0.87. The output is
a `dedup_log.jsonl` with `{kept_id, removed_id, tier, similarity, reason}`.
**Halt on anomaly**: if any tier removes more than 35% of input, the tool
exits with code 4 and prints the removal distribution; the run is a
"threshold is too loose" warning, not a "dedup is done" success.

**Stage 4 - scrub at ingest.** Reuse `tessera-anonymizer` and
`tessera-scrub` via a thin `tessera-traj-scrub` wrapper that calls them
on the `messages[]` content and tool-call arguments. Light aggressiveness
for normal traffic; balanced for user-submitted; aggressive for any field
marked `sensitive` in `task_taxonomy`. Record the aggressiveness level
and removal counts in the `ingest_scrub` field of the trajectory record.
The egress-side use of these tools (to a cloud teacher) is unchanged.

**Stage 5 - filter.** Apply the OT-Agent filters: drop trajectories with
`n_assistant_turns < 5`; drop trajectories with no successful outcome
unless the user opts in to include failure-recovery trajectories
explicitly; drop trajectories whose `verifier_outcome == "timeout"`; drop
trajectories whose `total_completion_tokens < 50` (suggests degenerate).
Optional difficulty filter using `final_metrics.total_completion_tokens`
as the teacher-difficulty proxy (the OT-Agent signal): keep trajectories
in the top-K% of teacher-token consumption. All filter decisions go into
a `filter_log.jsonl`.

**Stage 6 - split.** Group by `task_id` (not by `trajectory_id` - the
same task can have multiple trajectories from different seeds, and we
want all of them on the same side of the split). Default 95/5 train/eval
split, deterministic by hashing `task_id`. The eval split is a held-out,
never-trained-on set; the test driver verifies it remains unseen by a
SHA-256 manifest. Multi-task-source splits: each source contributes to
the eval set proportionally, so the eval set is representative of the
source mix, not dominated by the largest source.

## 7. Train driver (Stage 7, next-wave)

`tools/quantize/tessera/traj/tessera-train-agent.cpp` is the agentic SFT
driver. It consumes `llama.tessera.agent-traj.v1` JSONL, applies the
standard chat template to the `messages[]` array, tokenizes, and runs
the same `ggml_opt` epoch loop as `tessera-train-lk` and
`tessera-train-dflash`. The loss is plain cross-entropy over assistant
tokens; user and tool tokens get weight 0 by the same label-fill
mechanism Tessera already uses for D-PACE.

Three driver-level non-obvious decisions:

- **Token-fidelity invariant.** The chat template is applied to
  `messages[]` once at driver load, producing a `(tokens, label_indices,
  weights)` triple per trajectory that is **the same triple that will be
  used at inference** for the same chat template. The driver must NEVER
  detokenize -> retokenize anywhere in the training path. A test
  (`test_train_agent_token_fidelity`) hashes a known trajectory's
  tokenized output and asserts the hash matches across two driver
  invocations and one inference path.
- **Multi-source batching.** Different sources have different turn
  lengths and tool-call densities. The driver mixes them by upsampling
  short, dense trajectories and downsampling long, sparse ones,
  target-token-budget-aware. This is the source-mix "top-4" lesson from
  OT-Agent applied at the batch level, not the dataset level.
- **Reward-conditioned training.** The driver accepts an optional
  `--reward-conditioned` flag. When set, trajectories are weighted by
  their `verifier_outcome` (pass=1.0, partial=0.5, fail=0.1) so the
  gradient sees better trajectories more often.

This driver is the largest single piece of remaining work. The
Tessera-internal pattern (the `examples/training/finetune.cpp` skeleton
plus `ggml_opt` plus `arg.h`) is uniform enough that this is a
multi-week task, not a multi-month one.

## 8. Closed loop (Stages 8-10)

**Stage 8 - deploy (existing paths, reused).** The trained model goes
back through the existing `llama-cli` / `llama-server` paths. The
agentic training flywheel does not modify inference; it produces GGUF
that the existing loaders consume.

**Stage 9 - observe.** The trained model is deployed; agents using it
produce trajectories; the capture layer (Stage 1) catches the new
trajectories, this time tagged with
`manifest.trained_model_id = "tessera-sft-2026-08-15-v1"`. The capture
layer must run in the user's production environment, which means it
must respect the no-egress doctrine: the capture tool writes to local
storage; only the user's explicit "send to Tessera" (or whatever
aggregator) call moves the data.

The OTel GenAI conventions are the *de facto* shape for the observe
stage. Tessera does not need to implement the full OTel SDK to use the
conventions: a thin `tessera-traj-otel.cpp` that emits the four-span
structure (LLM, tool, memory, agent) with the right attribute keys is
enough to interoperate with Honeycomb / Langfuse / Phoenix if the user
wants to. The default is **off** - Tessera does not phone home.

**Stage 10 - manifest / lineage.** `tessera-traj-manifest` emits and
validates content-addressed manifests. Every capture run, every filter
run, every train run writes a manifest sidecar. A "what's in v18 that
wasn't in v17" report is one manifest diff. The user's training data
has a verifiable history; the SFT model has a verifiable training-data
history.

## 9. Sequenced roadmap

The work splits into three phases, each independently shippable, each
adding a closed-loop capability. Naming follows the existing Tessera
wave convention (W1, W2, etc.).

**Phase 1 (W1) - capture and validate. The wedge.** `tessera-trajectory.{h,cpp}`
(the schema model), `llama.tessera.agent-traj.v1` definition,
`tessera-traj-validate`, `tessera-traj-cli` with `--mode=openhands`
(event-log converter). Tests: `test_traj_validate`,
`test_traj_cli_openhands`. Deliverable: capture-from-OpenHands and
round-trip to a valid `*.agent-traj.v1.jsonl`. **Status: landed.**

**Phase 2 (W2) - quality gates.** `tessera-traj-dedup` (3 tiers, with
the halt-on-anomaly safety), `tessera-traj-scrub` (anonymizer+scrub
wrapper), `tessera-traj-filter` (multi-turn + outcome filters),
`tessera-traj-split` (deterministic by task_id, manifest-pinned).
**Status: landed.** Pipeline test `test_traj_pipeline` runs the
end-to-end flow (validate -> dedup -> scrub -> filter -> split ->
manifest) on a 10-record synthetic corpus with 3 near-dup pairs
and asserts per-stage counts plus manifest round-trip. Dedup unit
test `test_traj_dedup` covers the tier-1 exact, tier-2 fuzzy
(near-dup cluster, Jaccard 0.8, anomaly halt at 35%), and tier-3
deferred paths. Scrub CLI wraps the existing `tessera-anonymizer` +
`tessera-scrub` egress tools in light/balanced/aggressive modes.
The CLI build wires the parent-dir `tessera-anonymizer.cpp` and
`tessera-scrub.cpp` into a separate `tessera-traj-scrub-impl`
STATIC lib so the trajectory modules stay standalone (no DuckDB,
no llama/ggml, no ggml-ane.h) - see the Lessons Learned section
for the why.

**Phase 3 (W3) - train and close the loop.** `tessera-train-agent`
(agentic SFT driver with token-fidelity invariant and reward
conditioning), `tessera-traj-observe` (capture from a running agent
harness with `trained_model_id` tagging), `tessera-traj-manifest`
(content-addressed lineage), `tessera-traj-cli --mode=replay`
(deterministic re-execution gate), `tessera-traj-otel` (OTel GenAI
conventions emitter, off by default). **Status: manifest landed;
train-agent, observe, replay, otel are next-wave work.**

Phase 1 is the wedge; it unblocks everything else. Phase 2 is what
makes the dataset trustworthy. Phase 3 is what makes it a flywheel
rather than a one-shot. The three phases ship independently - each is
a meaningful capability, each stands on its own.

## 10. Open questions and deferred decisions

**Teacher selection for SFT.** The OT-Agent lesson is "the smartest
frontier model is often the worst teacher"; the right teacher depends
on what the model will be deployed against. The default in the agentic
SFT driver should be configurable, not hard-coded. A good starting
point is whatever model the user is already running in the inference
stack (so the trajectory distribution is closer to the deploy
distribution), with a note that the OT-Agent evidence points to a
smaller, more verbose teacher outperforming a frontier silent genius.

**Embedding model for tier-3 dedup.** The no-egress preference means
the embedding model must run on-device. Apple Silicon via the
ANE/Metal stack is the obvious answer. The model choice is not
critical at the plan level; the contract is "must run locally, must
be deterministic given a model version, must produce normalized
vectors."

**Chat-template library.** The token-fidelity invariant demands a
chat template that the driver and the inference path share. The
agentic driver needs a "render the messages to tokens" function that
is the *only* path used in training, and that is also the path used at
inference. A shared header file enforced by a test is the right
enforcement.

**Held-out eval gate.** `test_holdout_invisible` is the most
important test in the whole flywheel; without it, the eval numbers
are fiction. It's small (one hash check), and it should be the very
first test written, not the last.

## 11. Lessons learned (W1 + W2 implementation)

These are the concrete findings from the W1/W2 implementation that
are not in the plan above but will save the W3 work real time.

**1. Standalone sub-library for trajectory modules.** The
`tessera-traj-impl` STATIC lib and `tessera-traj-scrub-impl` STATIC
lib are wired in `tools/quantize/CMakeLists.txt` to include ONLY
the trajectory .cpp files plus the existing `tessera-anonymizer`
and `tessera-scrub` .cpp files. They do NOT link the parent
`tessera-quantize-impl`, so the trajectory CLIs and tests don't pull
in the DuckDB amalgamation, `ggml-ane.h`, or any other quantize
heavyweight. The build is a few seconds and ~700 MB; linking the
parent lib OOMed the build host during W1. Do not fold the
trajectory modules into the existing `llama-quantize-impl` target
even if it looks tidier.

**2. Union-find parent must be identity-init, not -1.** The
`tier2_fuzzy` cluster join uses union-find. Initializing
`parent[i] = -1` to mark "i is a root" looks compact but breaks
`find()`: it follows `parent[i] = -1` then reads `parent[-1]`
(out-of-bounds UB on `std::vector`), then returns -1 as a "root"
that other indices then try to follow. Symptom: records get
incorrectly lumped into one cluster, and the leader (lowest
index) is a record that may have Jaccard 0 with the actual
duplicates - so the (leader, j) Jaccard check never sees the
real pair. Fix: `parent[i] = i` (each record is its own root
until united). Always identity-init union-find.

**3. Pairwise Jaccard within cluster, not leader-vs-rest.** LSH
banding is approximate; an unrelated record can false-positive
into a duplicate's cluster. If dedup only checks (leader, j)
pairs, the false positive (the leader itself) blocks the real
duplicate pair from being compared. Always do pairwise
Jaccard within each cluster, removing the higher-index member
of any pair above threshold. Cost is O(n^2) per cluster but
clusters are small (LSH is selective).

**4. NUM_PERM must equal NUM_BANDS * MINHASHES_PER_BAND.**
The LSH band access `sigs[i][b * minhashes_per_band + k]` is
out-of-bounds when b * minhashes_per_band + k >= num_perm.
Defaulting to 128 perms with 20 bands * 13 per band (260) is
inconsistent - we hit OOB reads that produced consistent
"garbage" values, putting unrelated records into the same LSH
bucket. Pick the LSH geometry first, then set NUM_PERM to
match. (20, 13) -> 260 perms is the NeMo Curator shape; the
LSH inflection at J=0.5^(1/13) ~= 0.949 means collisions become
likely only above ~0.85 Jaccard, which is the right shape for
"fuzzy" tier.

**5. Survivor-mask carry-forward is the bug source for "n+1
records out of n input".** When tier N's survivor mask is
initialized to all 1s (rather than copied from tier N-1's
mask), records removed by tier N-1 reappear in tier N's
output. The removal log shows the right removal; the file
emission is wrong because the writer trusts the mask. Always
write `*survivor_mask = in_mask;` at the start of each
downstream tier.

**6. Shingle SET Jaccard != body-content similarity.** A
mid-body insertion disrupts ~21% of 5-grams (the 5-grams that
contain the insertion point), pushing shingle Jaccard from
~0.97 to ~0.61 for a 40-token body. The LSH threshold
(J=0.8) is below 0.61, so the pair is not caught. Two
mitigations: (a) for synthetic test data, append the change
at the END of the body so only the last 4 5-grams are
disrupted; (b) for real data, use a body long enough that
boundary 5-grams are a small fraction of the total (200+
tokens keeps Jaccard above 0.9 even with mid-body edits).

**7. Repeated body content collapses the unique shingle set.**
An agent trajectory with N turns of agent messages that all
echo the user body creates a fingerprint with the body
content repeated N times. The 5-grams within the body are
NOT unique shingles - they're the same shingle FNV-1a hash
repeated, and MinHash's set semantics treat them as one
shingle. With a 90-token body repeated 6 times in agent
messages, the unique shingle set is ~100 even though the
raw 5-gram count is ~600, and MinHash Jaccard with a
near-dup drops to 0.65 (not 0.97). For synthetic test
fixtures, keep agent messages short and body-independent
("agent turn N response ack") so the body only appears in
the user message.

**8. scrub order: anonymize first, then scrub.** Running
scrub-then-anonymize breaks the redaction placeholder: the
anonymizer renames "secret" and "email" inside `<secret:email>`
to `tsd` and `tsb`, producing `<tsd:tsb>`. The reverse order
keeps the placeholder intact because the anonymizer doesn't
touch the email (no identifier chars). Known limitation:
API keys in plain text get renamed by the anonymizer first
(sk-abc -> ts-xyz), so the scrubber's API-key regex doesn't
match. Fixing this needs the anonymizer to skip tokens that
match a known secret shape - tracked for a follow-on wave.

**9. step_id is required by the schema-gate, not optional.**
The validator enforces sequential step_id (1, 2, 3, ...) on
every message in messages[]. A trajectory with valid content
but missing step_id fails validate with 0 valid / N invalid.
This is the right behavior (catches half-built records), but
every test fixture and the dedup-test `make_traj` helper
needs to set it explicitly. Pattern: `m["step_id"] = i + 1;`
inside the message-construction loop.

**10. Stale binaries masquerade as test failures.** A test
that was passing can start failing because the .cpp was
edited but the build dir didn't pick up the change. Pattern:
`make -j1 <test_target>` and check the binary mtime against
the source mtime before re-running. Don't trust a test
result that comes from a binary older than its source.
