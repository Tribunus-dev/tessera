# Unified GGUF + qwen3-tts: audit and implementation plan

Status: design / planning (2026-08-06)
Scope: bring qwen3-tts (talker + code2wav) into the singular unified GGUF,
extend joint calibration and joint quantization to it, and build the
post-training path that lets gemma 4 hidden states cast directly into the
qwen3-tts thought space via LoRA adapters.

The goal, stated as one sentence: one file, calibrated together, quantized
together, post-trained together, until gemma 4's hidden states drive the
talker directly - no text detokenize/retokenize round trip.

---

## Part 1 - Audit findings

### 1.1 The existing unified artifact

Inspected `/Volumes/Julian T7/runs/gemma4-12b-tessera-overnight/
gemma4-12b-qat-tessera-awq-sr-unified-csr-corrected.gguf` (3.52 GB,
4595 tensors):

- `general.architecture = gemma4`, `block_count = 48`,
  `embedding_length = 3840`, T640 layout metadata present
  (`tessera.layout = T640`, page/lane geometry, calibration flags).
- Tensor prefixes: `blk.*` 4227 (48 trunk layers, T640-packed, ~7 physical
  tensors per logical tensor), `mtp.*` 289, `v.*` 54 (vision tower,
  T640-packed), `mm.*` 12 (projector), `token_embd.*` / `output_norm.*`
  (T640 clusters).
- Correction vs prior status notes: this artifact does NOT contain
  dflash/dspark tensors. The writer supports those roles; the current
  file only carries trunk + MTP + vision + projector.

### 1.2 The writer (tools/quantize/tessera/tessera-unified-writer.{h,cpp})

What is already generic:

- `write_all()` copies per-component source GGUFs tensor-by-tensor,
  preserves T640 clusters by data pointer, applies per-tensor qtype
  overrides, and publishes via tmp-file + atomic rename
  (tessera-unified-writer.cpp:985-1206).
- `ts_unified_policy_load_json` reads `model_role` per entry and an
  optional `role_budgets` sidecar (tessera-unified-writer.cpp:455-483).
- Worst-of and budget-aware cross-role reconciliation
  (`ts_unified_writer_resolve_shared`, `resolve_tensor_qtype`) are
  role-string-generic (tessera-unified-writer.cpp:313-429, 921-983).

What is hard-wired to the gemma set:

- `route_destination_name()` (tessera-unified-writer.cpp:853-864): only
  `dflash` gets a prefix; every other role copies names as-is. Talker
  source tensors are named `blk.N.attn_q.weight` etc. - IDENTICAL to
  trunk names - so a prefix for the talker role is mandatory, not
  optional.
- The stats counters are an 8-role if-chain
  (tessera-unified-writer.cpp:1149-1156).
- The CLI (tools/quantize/quantize.cpp:776-817) exposes exactly 8
  `--{component}` flags and rejects any other arch than
  `gemma4-assistant`.

### 1.3 A latent bug that qwen3-tts turns into a live bug

`resolve_tensor_qtype()` looks the policy up by tensor NAME only and
folds verdicts across roles via worst-of
(tessera-unified-writer.cpp:895-911, 921-949). That is correct for
shared tensors (`token_embd.weight` owned by trunk + shared_embd) and
harmless today because gemma-side per-block names never collide across
roles.

The talker breaks that assumption: its `blk.0.attn_q.weight` and the
trunk's `blk.0.attn_q.weight` are two unrelated tensors with the same
name and different calibration verdicts. With the name-only lookup, the
talker's verdict would worst-of-merge into the trunk tensor (and vice
versa), silently over-biting the trunk or under-biting the talker.

Fix required before the talker lands: qtype lookup must be keyed by
(component_role, name), with name-only matching kept as the fallback for
entries that carry no role (legacy policies).

### 1.4 The calibration pipeline (tools/tessera/unified_calibrate.py)

Already role-generic where it matters:

- `--component ROLE=PATH` accepts any role string; per-component policies
  are tagged with `model_role` and merged (unified_calibrate.py:125-142,
  219-257, 574-796).
- Per-role fitness defaults live in one table
  (unified_calibrate.py:116-122): trunk->awq, dflash/dspark/mtp_nextn->lrq,
  shared_embd->flrq. Unknown roles fall back to the explicit `--fitness`.

Gaps:

- No `tts_talker` / `tts_code2wav` entries in ROLE_DEFAULT_FITNESS
  (cosmetic; falls back today).
- The activation side is gemma-specific. `make-awq-layer-bundles.py`
  pairs HF safetensors weights with llama-imatrix telemetry via a
  gemma-shaped `hf_to_observer` projection map. Talker activation
  bundles do not exist and that mapper will not produce them
  (codec/cp/text_proj tensors have no `layers.N.<proj>.weight` shape).
- Components calibrate INDEPENDENTLY against a shared corpus. The only
  cross-component coupling is worst-of on shared tensor NAMES. gemma
  trunk and qwen3-tts share no tensor names, so today there is
  literally zero joint signal between them. "Calibrate together" in the
  strong sense does not exist yet anywhere in the tree.
- Doc rot: unified_calibrate.py references `tile640_quantize_v3.py` as
  the downstream quantizer; that file does not exist. The real
  quantizer is C++ `llama-quantize` with the tessera extensions
  (tools/quantize/quantize.cpp, tessera/tessera-quant.cpp). Fix the
  docstring while touching the file.

### 1.5 The talker model class (src/models/qwen3-tts-talker.cpp)

Tensor inventory (load_arch_tensors, :110-267):

- `tok_embd` (n_embd x 151936 text vocab), `output_norm`
- `codec_embd`, `codec_head` (codebook-0, n_codec_vocab=3072)
- `text_proj_1/2` + biases (n_embd x n_embd) - OPTIONAL
- 28 backbone layers: qwen3-style attn (wq/wk/wv/wo + q/k norms, mrope)
  + swiglu FFN
- cp pass: `cp_proj` (+bias), `cp_norm`, 5 cp blocks at bid 28..32,
  per-codebook `cp_codec_embd.{cid}` / `cp_head.{cid}` (16 codebooks,
  cid in the name SUFFIX)

The critical finding: **text_proj_1/2 are loaded but never referenced in
build_arch_graph.** The graph enters through `build_inp_embd(tok_embd)`
and stays on the token path (:296-374). The thinker->talker conditioning
junction that the LoRA vision targets exists only as dead weight. The
W5 CLI today bridges gemma->talker with text-level retokenization
(UTF-8 -> Qwen BPE; tessera-s2s-cli.cpp:274-286), not hidden states.

Consequence: before any adapter can be trained or served, the talker
graph needs an injected-hidden-state input path that runs the
conditioning through text_proj_1/2. This is the single graph change the
whole vision is load-bearing on.

### 1.6 The loader has the mechanism already

`llama_model_loader` carries a `component_prefix`
(src/llama-model-loader.h:101, .cpp:274-282, :556+):

- `scoped_key()` resolves KV keys as `<prefix><key>` when present.
- `expose_tensor_name` hides tensors that do not start with the prefix
  and exposes them with the prefix stripped (`mtp.` is special-cased
  when no prefix is set).

So the talker can load from the unified GGUF by constructing its model
view with `component_prefix = "tts."`: tensor names resolve
(`tts.blk.0.attn_q.weight` -> `blk.0.attn_q.weight`) and talker hparams
resolve from a `tts.*` KV namespace. No new loader machinery is needed -
just plumbing the prefix through to the talker's load site and writing
the matching KV namespace on the writer side.

The DFlash precedent covers the rest of the architecture: the talker
runs as a `ctx_other`-style companion model while borrowing nothing
from the trunk (it has its own tok_embd), exactly the pattern
gemma4-assistant uses in reverse (src/models/gemma4-assistant.cpp:150-159).

### 1.7 Blockers outside the pickle itself

1. **W5b cpufix regression - VERIFIED NOT REPRODUCIBLE (2026-08-06).**
   At HEAD (28bb8f7dd) both the W5b synthetic test and the W8
   real-weight talker forward PASS with `devices = {cpu, nullptr}`
   honored (sched splits = 1, CPU-only). The regime router wiring
   (`a130882ad`) touches only the TILE640_MATMUL dequant meta/outlier
   path selection in ggml-ane.mm and cannot route tensors between
   buffers; no other regime references exist in the backend path. The
   earlier abort observation does not reproduce. Phase 0 is closed.
2. **c2w graph convention bug** (W8 followup): the code2wav graph feeds
   time-major input to `ggml_conv_1d` which expects channel-major.
   DECISION: fixed in-campaign (Phase 2.5).
3. **c2w GGUF artifact missing from /Volumes/Julian T7** (found during
   the 2026-08-06 audit): the 456 MB F32 code2wav GGUF the W8 gate used
   is no longer on disk. It must be re-produced from the W5c converter
   (source: /Volumes/Julian T7/models/qwen3-tts-model) before any c2w
   verification, Phase 2.5 included.

---

## Part 2 - Implementation plan

Doctrine applied throughout: evolve, don't version (no toggles, no v2
coexisting paths); additive schema only; tests before commit; the
singular unified GGUF stays singular.

### Phase 0 - Unblock (CLOSED 2026-08-06, no work needed)

The W5b cpufix regression was verified not reproducible at HEAD:
test-qwen3tts-talker (synthetic) and test-qwen3tts-w8-parity (real
3.6 GB BF16 talker forward) both pass at 28bb8f7dd. See 1.7.1 for the
evidence. The campaign starts at Phase 1.

### Phase 1 - Writer + loader structure (~3-4 days)

No new math; this makes the file format speak qwen3-tts.

1.1 `route_destination_name`: `tts_talker` -> `tts.` prefix,
    `tts_code2wav` -> `tts.c2w.` prefix (evolve the function; dflash
    keeps its prefix).
1.2 CLI: add `--tts-talker` / `--tts-code2wav` to `ts_cli_unified_writer`
    (quantize.cpp:789-817). Replace the 8-role stats if-chain with a
    per-role map so role additions stop touching write_all.
1.3 Role-aware qtype lookup (the 1.3 bug fix): `resolve_tensor_qtype`
    gains the component role; entries match on (role, name) first, with
    name-only matching retained for role-less legacy entries. The
    worst-of semantics are unchanged for genuinely shared tensors.
1.4 Talker hparams sidecar: the unified file's arch is gemma4, so
    talker KV cannot live under `gemma4.*`. Write `tts.*` KV keys
    (block count, n_embd, n_codec_vocab, cp layer count, rope params -
    the set the talker's load_arch_hparams reads), sourced from the
    talker source GGUF's own KV. Additive; old readers ignore them.
1.5 Loader plumbing: pass `component_prefix = "tts."` at the talker's
    model-load site when the file is a unified GGUF (detect via the
    presence of `tts.*` KV / arch mismatch); the loader's existing
    scoped_key + expose_tensor_name do the rest.
1.6 Tests: extend test_unified_writer.cpp with a synthetic talker
    component: prefix routing, the name-collision case (trunk and talker
    both carry blk.0.attn_q.weight with DIFFERENT verdicts - pin that
    each tensor gets its own verdict), tts.* KV sidecar round-trip, and
    a synthetic unified-file talker load through the prefixed loader.

Gate: unified writer emits trunk + mtp + v + mm + tts + c2w from
synthetic sources; talker loads the tts view back; all existing writer
tests unchanged.

### Phase 2 - Per-component quantization of the talker + c2w (~2-3 days)

2.1 Quantize the real talker BF16 GGUF (3.58 GB, /Volumes/Julian T7)
    with the existing C++ quantize path. Audit the qtype classifier for
    the TTS-only tensors: codec_embd/codec_head are ordinary 2D heads;
    the 16 cp_head/cp_codec_embd pairs are small (1024 x 2048) and
    should ride the same rules as other heads; 1D norms stay unquantized.
    DECISION (architect, 2026-08-06): straight T640 for Mac and iPhone -
    no Q4_K_M interim. The ANE-native format is the target on both
    devices, so talker shapes go through the T640 packer directly and
    parity is proven at the format we will actually ship.
2.2 code2wav: DECISION (architect, 2026-08-06): fix the conv convention
    bug (1.7.2) inside this campaign and unlock PCM parity for good.
    That moves the W3-era graph rewrite (channel-major inputs to
    ggml_conv_1d) from deferred followup to Phase 2.5 below; c2w quant
    decisions wait on the fixed graph.
2.3 Rebuild the unified artifact: trunk + mtp + v + mm + tts_talker +
    tts_code2wav. This also closes the 1.1 correction (the drafters that
    the writer supports but the artifact lacks can be folded in on the
    same pass if their quantized sources are ready).

Gate: real-weight talker forward parity (the W8 test) passes against the
tts view loaded OUT OF the unified file - same logits as the standalone
talker GGUF. That is the parity contract.

### Phase 2.5 - c2w conv convention fix, PCM parity unlocked (~2-3 days)

DECISION: in scope. The W3-era code2wav graph transposes x to (L, C)
before calling ggml_conv_1d, which expects channel-major (C, L). The
fix is a channel-major rewrite of the c2w forward graph (pre_conv +
per-block convs + upsampling path), keeping the weight convention the
W3/W5c/W8 work already pinned ((K, IC, OC) in ggml ne = torch
(OC, IC, K) reversed; 1D biases {c_out, 1, 1, 1}).

Gate: real-weight c2w forward produces finite PCM and matches the
reference vocoder output within a defined band on the W7 chained
corpus - PCM parity, not just load parity.

### Phase 3 - Calibration capture for qwen3-tts (~1 week)

3.1 Talker imatrix: run llama-imatrix on the talker GGUF with a text
    corpus (the talker's tok_embd path is standard; needs Phase 0). The
    telemetry GGUF carries `blk.N.attn_q.weight.in_sum2`-shaped rows for
    every talker layer, including the cp blocks.
3.2 GGUF-native bundle builder (recommended over extending the HF
    mapper): build AWQ bundles with weights read from the talker BF16
    GGUF itself and activations from the imatrix telemetry, keyed
    directly on llama tensor names. The HF mapper exists because trunk
    calibration predates having GGUF sources; the talker GGUF IS the
    quantize source, so the HF hop is pure fragility. This evolves
    make-awq-layer-bundles.py's output contract without forking it.
3.3 ROLE_DEFAULT_FITNESS: `tts_talker -> lrq` (lossy-tolerant
    autoregressive decoder, drafter-like), `tts_code2wav -> flrq`
    (frozen vocoder, calibration-free).
3.4 Run unified_calibrate.py with the full component set (trunk,
    drafters, mmproj, tts_talker, tts_code2wav) -> one unified policy.
    Fix the tile640_quantize_v3.py doc rot while here.

Gate: unified policy JSON covers every quantized talker tensor; the
writer consumes it end-to-end; quantized-talker parity delta stays
inside the acceptance band the trunk uses.

### Phase 4 - Joint calibration signal (~1-2 weeks)

This is where "together" becomes real instead of nominal. Today the only
cross-role coupling is worst-of on shared names, and gemma/qwen share
none.

4.1 Paired capture corpus: same utterances through both pipelines.
    Capture (a) gemma 4 hidden states at utterance boundaries -
    DECISION (architect, 2026-08-06): MULTI-LAYER taps from the start,
    DFlash-style (trunk target_layer_ids set, not just the last layer;
    the adapter's input width is n_taps x n_embd_gemma), (b) the
    talker's conditioning-space inputs, (c) codec
    targets from a reference qwen3-tts run. The tap mechanism exists
    (set_embeddings_layer_inp pattern, llama-context.cpp:1168-1188;
    the DFlash offline-capture pipeline in
    docs/tessera-dflash-training-design.md is the template - Path 1,
    capture offline, train the small thing only).
4.2 Joint loss v1 (audio reconstruction): talker codec CE driven by
    captured conditioning. This validates the capture pipeline and
    produces the training pairs Phase 5 consumes. Deliberately NOT a
    new graph op - a dataset + driver, the same shape as the D-PACE
    block-dataset precedent (weights pre-applied to labels, standard CE).
4.3 Track the bridge metric in tessera.duckdb (new additive table):
    cosine / MSE between projected gemma hidden states and talker
    conditioning embeddings, per corpus batch. This is the number the
    whole campaign optimizes; it must be visible from run one.

Gate: >= 100 paired captures land in the DB with finite values; joint
loss v1 reproduces reference codec predictions within band on held-out
utterances using ORIGINAL conditioning (sanity that the pipeline is
faithful before adapters enter).

### Phase 5 - Thought LoRA adapters (~2-3 weeks)

5.1 Tensor family: `tts.thought_adapter.{A,B,gate}` - low-rank float
    delta (A: r x (n_taps x n_embd_gemma) over the multi-layer tap set,
    B: n_tts x r, plus a learned gate/scale and per-tap mixing weights),
    stored F16/F32, NOT T640 (it is the post-training output, evolves
    continuously). New writer role `tts_thought_adapter`, additive.
5.2 Wire the junction (the 1.5 finding): evolve the talker graph with an
    `inp_thought` input; when present, conditioning positions enter
    through text_proj_1/2 on the injected embeddings instead of the
    tok_embd lookup. One graph, both paths selected by input presence -
    no versioned graph, no flag.
5.3 Training driver: new tool in the tessera-train-dflash.cpp shape.
    Both base models frozen; only the adapter trains. Forward: gemma h
    -> adapter -> text_proj -> talker backbone -> CE on codebook-0 +
    per-codebook cp CE. The talker token-batch graph is fully
    differentiable (Stage-0 finding), so this reuses the existing
    training-graph machinery rather than inventing a new one.
5.4 Acceptance: codec prediction quality with (gemma h + trained
    adapter) within a defined band of (qwen thinker + text_proj),
    measured by the Phase 4 metric. Iterate on rank r and gate init
    before touching anything else.

### Phase 6 - Runtime integration (~1-2 weeks, overlappable with 5)

6.1 S2S CLI evolves: the retokenize step is replaced by the thought path
    when the unified artifact carries a trained adapter; the text path
    remains the conditioning fallback when it does not. Dispatch on
    artifact presence, consistent with the dynamic-dispatch doctrine -
    not a user-facing toggle.
6.2 iPhone residency: the budget is binding (6 GB device, ~3.5-4 GB
    working set). trunk(T640) + talker(Q4-class) + c2w(F16) sums past
    it if all resident. The GGUF->IOSurface weight streamer (Phase 2
    slices 1-3 already on main) is the enabler: keep the talker +
    c2w on disk and stream them in on voice activation, trunk stays
    resident. Slice 4 (async prefetch) moves from deferred to
    genuinely needed once this file exists.

---

## Part 3 - Dependency graph and ordering

```
Phase 1 (writer/loader) ─────> Phase 2.3 (unified artifact) ─> Phase 3.4
Phase 2 (talker T640 quant) ─┘
Phase 2.5 (c2w conv fix) ──> c2w verification (needs re-produced c2w GGUF)
Phase 3 ─> Phase 4 ─> Phase 5 ─> Phase 6
```

Phase 0 closed (not reproducible). Phase 1 starts immediately (no
real-weight dependency). The critical path is 1 -> 2 -> 3 -> 4 -> 5;
Phases 2.5 and 6 hang off it.

Honest total: ~6-8 weeks to a trained adapter serving from the unified
file, assuming the Phase 4 metric behaves. The place this estimate can
blow up: the joint loss v1 band - if captured conditioning does not
reproduce reference codec quality, the capture pipeline is wrong and
nothing downstream is trustworthy. The multi-layer tap (D3 decision)
is the capacity lever and is in the design from day one, so adapter
rank/tap-set tuning is an experiment inside Phase 5, not a rescue plan.

## Part 4 - Decisions (resolved 2026-08-06)

D1. Talker quant: STRAIGHT T640 for Mac and iPhone. No Q4_K_M interim;
    parity is proven at the shipping format.
D2. c2w conv bug: FIXED IN-CAMPAIGN (Phase 2.5). PCM parity unlocked
    for good; c2w quant decisions wait on the fixed graph.
D3. Adapter tap depth: MULTI-LAYER from the start (DFlash-style
    target_layer_ids set), not last-layer-only.
D4. Role-aware qtype lookup: APPROVED. Legacy role-less policy entries
    keep name-only fallback; existing gemma artifacts re-quantize
    byte-identically. That contract is binding on the Phase 1.3 change.
