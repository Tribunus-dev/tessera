# Training flywheel, Granite-first: idle post-training, consented data, certifiable derivatives

**Status:** proposal for architect ratification (decision 19 candidate).
**Evidence:** `.scratch/granite-redhat-ecosystem-report.md`,
`.scratch/training-certifiability-report.md` (both 2026-08-16), plus a
code review of `Sources/TesseraCore/Learning/` (42 files, 7,097 lines)
and `docs/agentic-training-data-flywheel-design.md` (repo root).
**Relationship to existing designs:** extends the flywheel design (which
governs the drafter loop) and the egress-grant design
(`dual-agent-egress-design.md`) - the contribution pipeline is a new
GRANT CLASS, not a new egress mechanism.

## 1. What exists today (verified)

- **Idle drafter training, complete and honest:** TesseraTrainingScheduler
  (idle cadence, auto-train setting, AC-power gate degrading open,
  notification-budget integration, persisted skips) ->
  TesseraTrainingOrchestrator (trace-count gate, default dryRun,
  512-example cap) -> native `tessera-train-lk` (LK loss, drafter GGUF).
  Scope: SPEED self-improvement of the speculative drafter. The
  capability-eval guard cases exist but are UNWIRED (honest plug-in
  point).
- **Data pipeline, 80% of the collection system:** capture -> session
  curation (promote/quarantine/drop, honest sweep reports, replay
  promotion) -> fail-closed TesseraEgressGuard (runtime + s2s LOCAL-ONLY
  by construction; only replay-stamped records dataset-eligible) ->
  TesseraAnonymizerService (symbol-level, local de-anonymization map,
  honest fallback labeling) + versioned TesseraScrubRules (quarantine by
  rule id, never content).
- **Missing:** main-model post-training; any uploader; eval-gate wiring;
  user-grant-based consent (today's guard is provenance-based);
  doctrine test coverage (Learning had 7/38 files rewritten - thinnest
  in the codebase).

## 2. Decision 19 (one yes/no/amend, seven parts)

**19a - Base model: granite-4.1-3b (dense), with granite-4.0-350m as the
speculative draft and aLoRA as the adapter mechanism.** Dense = the
existing T640 calibration, ANE prefill, and fork paths work unchanged
(hybrids need ssm_conv1d exemptions, state-aware calibration, Metal SSM
conformance - R&D only). ~2GB at Q4 on the 16GB floor; official IBM
GGUFs; 4.0/4.1 share the 100352-token vocab so the 350m Nano drafts for
the 3B (verify tokenizer identity at integration). granite-4.1-8b as an
optional quality tier. IBM's own granitelib ships signed aLoRA adapters
targeting a 3B dense - our per-feature intrinsics land structurally
inside IBM's "AI as software libraries" direction, and upstream
llama.cpp already runs aLoRA (PR #15327; port to the fork).

**19b - Contribution format: plain hashed JSONL chat datasets.** NOT the
InstructLab taxonomy - the community pipeline is wound down (evidence:
eulogy commit, v0.26.1 final CLI, successor stack sdg_hub/training_hub
consumes ordinary chat format). Optional thin skill-metadata wrapper.
This keeps exports consumable by MLX-LM, training_hub, Unsloth, and
anything future.

**19c - The uploader is an egress-grant consumer.** New grant class
`trainingContribution`: batch grants over curated+scrubbed samples that
already passed the egress guard; the grant preview shows the exact
post-scrub samples; per-sample content hashes in the signed receipt;
tier 2. The grant receipt carries ISO/IEC TS 27560 consent fields
(purpose "model post-training", processor list naming Hugging Face +
jurisdiction, withdrawal method) - making every consent a
standards-conformant consent record. Raw pre-scrub content NEVER
uploads; client-side scrubbing is the privacy boundary, not the HF
"private" flag.

**19d - HF private dataset, PRO tier now.** Layout per the research
(parquet shards partitioned by contrib-month + user bucket so one
user's revocation rewrites only their shards under Xet dedup;
meta/consent_index + tombstones + scrub_manifest; Croissant 1.1 + RAI
fields). CommitScheduler daily batching; `train-YYYYMMDD` tags;
training pins commit SHAs. Revocation = tombstone -> physical shard
rewrite -> exclusion from all future runs -> affected adapters retrain
within a published SLA (30 days) -> ledger entry. NEVER promise
"removed from the model" - promise exclusion-plus-retrain. Upgrade to
Enterprise (EU storage region + DPA) before any EU marketing.
Consent language for "heavier runs elsewhere" (server-side training) is
a SEPARATE grant class written up front - consent cannot broaden
retroactively.

**19e - Adapter training: native C++ in the fork, multi-platform, by
porting not pioneering.** (REVISED 2026-08-16 after the landscape
research, superseding the earlier MLX-sidecar plan - MLX has no
AMD/Intel Linux path, so it cannot serve the Fedora build; evidence:
`.scratch/ggml-training-landscape-report.md`.) The fork already owns
the substrate (LK loss in ggml-opt, llama_opt epoch path, the
`build_lora_mm` seam instrumented for activation capture, and
`llama_opt_init`'s `param_filter` as the base-freezing hook). The
plan: port QVAC Fabric's MIT-licensed `llama-finetune-lora` training
core (LoRA graph, masked loss, cosine LR, their Metal/Vulkan backward
kernels - the only proven multi-backend GGUF-native LoRA trainer,
active through 2026-08) onto the fork (M); add Granite-4.1 dense
coverage (S-M; llama-like graph + scalar multipliers, no mamba); add
aLoRA training gating - position-mask the lora branch at >= the
invocation offset, loss on post-invocation tokens, emit
`adapter.alora.invocation_tokens` (S; FIRST-OF-ITS-KIND in C++); add
bf16/Q8_0 OUT_PROD dtype coverage for the frozen-base backward (S-M);
carry the #21037 finetune bug patches until upstream merges. Backend
reality: Vulkan backward is ON MASTER (the Linux AMD/Intel leg exists
today); CUDA complete; Metal needs the QVAC kernel port - v1 fallback
is Mac-trains-on-CPU (historical 3B LoRA ~3h class; QVAC's M3 Pro
Metal reference: 5.3h for an 8-epoch run). Memory: bf16 base + r=8-16
adapters + materialized-softmax attention at ctx <= 1024 fits ~11-12GB
- inside the 16GB floor with the suite quiesced; longer ctx waits for
the checkpointing port. Artifact boundary (the IBM-interop answer):
emit BOTH a GGUF adapter (hot-load --lora, aLoRA metadata included)
AND a PEFT-convention directory (safetensors + adapter_config.json
with HF module names + alora fields) via a small GGUF->PEFT exporter
(no such tool exists anywhere - ours to write); datasets in JSONL
"messages" (sdg_hub/training_hub/QVAC all speak it). NON-NEGOTIABLE
gate: parity validation of one adapter against an Unsloth/PEFT
reference run (loss curves + adapter equivalence) before any trained
artifact ships (M). Upstream strategy rides the IBM playbook: the
Metal kernels (#14909), the bug patches, dtype OUT_PROD, and a
plain-LoRA example (#13485) are all upstreamable where IBM's Granite
lead reviews - and nobody owns llama.cpp training today, which makes
it a more visible contribution than inference work. iOS still never
trains (adapters sync). MLX demoted to an optional Mac-side dev
harness, not shipped.

**19f - The certifiability chain ships with the first adapter.** Per
training run, the 12 artifacts from the certifiability report: 27560
consent bundle; per-sample provenance manifests (receipt-anchored);
dataset snapshot SHA + Croissant/RAI; data BOM (CycloneDX or SPDX 3.0);
training-run record incl. IBM model.sig verification transcript + FLOPs
arithmetic showing orders below the 1/3 x 10^23 GPAI threshold; eval
gate report (pinned harness + Granite Guardian 4.1 as safety judge,
thresholds declared BEFORE the run - benign fine-tuning measurably
degrades refusals, so NO adapter ships without this gate); adapter
ML-BOM; OMS-signed adapter (Sigstore keyless, stable Tessera identity,
Rekor - mirroring IBM's granitelib practice exactly); adapter model
card (base_model relation); receipt-log anchor over all artifacts;
release register + revocation ledger. THIS wires the orchestrator's
reserved guardPassed/guardFailed cases - the eval gate is no longer a
plug-in point, it is the certification mechanism.

**19g - Certification posture and the honest claim.** ISO/IEC 42001
attaches to organizations, not models; nothing inherits from IBM's
certificate (Schellman-audited, org-scoped). Sequence: publish a NIST
AI RMF + GenAI Profile self-assessment NOW (free); pursue Tessera's own
42001 AIMS (scoped to collection/curation/post-training/eval/release)
as a later ~$15-40k capstone - the chain then reads "a 42001-certified
org fine-tuning a model from a 42001-certified org", which no
inheritance could ever say. THE ONLY PERMITTED MARKETING CLAIM until
then: "built on ISO 42001-certified IBM Granite, post-trained under our
documented management system, with signed artifacts and published
evals." Anything implying inherited certification is false and is the
top legal risk on this track. Also on record: IBM's IP indemnity is
watsonx-only - HF-downloaded weights carry Apache 2.0 and no indemnity;
never imply otherwise.

## 3. Import-side trust wiring (engine + app)

- Verify IBM's `model.sig` at model download (OMS model_signing against
  sigstore.verify.ibm.com), record the verification transcript as a
  receipt; cache the result - verify at download, not per-launch (the
  IBM Sigstore endpoint is a network dependency and the feature is
  labeled experimental).
- Model weights enter the SBOM pipeline (procurement doc item): SPDX +
  CycloneDX entries with weight hashes + acquisition chain.
- Engine work items (tessera repo, not TesseraStudio): granite-4.1-3b
  through T640 calibration + ANE prefill (dense - expected unchanged;
  verify); 350m draft wiring into the spec-decode path; port upstream
  aLoRA support (b6396) into the fork; per-model engine profiles so the
  next Granite architecture swing (hybrid -> dense -> swash previews
  inside 10 months) is a profile, not a rewrite; budget one
  re-quantize/re-train/re-sign cycle per Granite generation.

## 4. Collaboration playbook (evidence-ranked)

IBM - contribution before contracts:
1. NOW: upstream the fork's Granite findings (quantization behavior,
   Metal fixes, aLoRA improvements) to ggml-org/llama.cpp - IBM's
   Granite lead reviews there directly; cookbook PRs to
   ibm-granite-community (an AI Alliance project).
2. 1-2 months: ship "Granite inside Tessera" - verified-signature
   import surfaced in receipts, Nano draft, signed local adapters -
   and present it. IBM has Dell/Docker/LM Studio distribution partners
   but NO signed-verification-on-device consumer showcase, and no
   Apple-Silicon program; the gap is visible and ours to fill.
3. 3-6 months: Partner Plus Build application; ask about indemnity for
   locally-run Granite (expect "watsonx only"; the ask opens the
   account). 6-12 months: IBM Research contact on consent-gated
   on-device aLoRA intrinsics (generative-computing org). AI Alliance
   startup membership meanwhile.

Red Hat - Fedora-native credibility before programs:
1. NOW: Flathub listing for the GTK4 app; do not wait for any
   partnership to ship on Fedora.
2. 1-3 months: align with Podman AI Lab / RamaLama local-model
   conventions; Fedora Magazine / Red Hat Developer writeup ("local
   Granite AI on Fedora, receipts and all").
3. Align the grant-export JSONL with sdg_hub/training_hub conventions
   so granted data can feed Red Hat AI's customization pipeline; skip
   the dead taxonomy format. Partner Connect = marketing checkbox
   later; RHEL AI/llm-d irrelevant until a server tier exists.

## 5. Sequencing (wave-able units)

- **T-F1 (engine):** Granite 4.1-3b + 350m through the engine
  (calibration, ANE, drafts) + model.sig verification receipts. Gate:
  parity metrics vs current default model on the corpus harness.
- **T-F2 (app):** trainingContribution grant class + 27560 fields +
  HF uploader (CommitScheduler) + revocation flow + doctrine tests
  (this wave also pays down the Learning cluster's 7/38 coverage debt
  for the files it touches).
- **T-F3 (training):** MLX sidecar + eval gate wiring (Guardian judge +
  pinned harness) + OMS adapter signing + the 12-artifact emission +
  aLoRA fork port. Gate: one signed adapter, full artifact chain, on a
  synthetic consented dataset.
- **T-F4 (paper):** NIST AI RMF self-assessment publication; safe-claim
  marketing language locked; 42001 decision deferred to revenue.
- Ordering with the P2 campaign: T-F1 can start immediately (engine
  repo, no TesseraStudio contention); T-F2/F3 follow Wave P2-D (they
  consume the egress-grant mechanism P2-D builds).

## 6. Risks (carried from evidence, binding)

Marketing overreach (the top legal risk - safe claim only); benign
fine-tuning degrades refusals ~30% (Guardian gate mandatory, never
optional); free-text anonymization is never watertight (treat the HF
dataset as personal data: consent records, DPA, retention, erasure
propagation; DP-SGD over LoRA is the only formal-anonymity path, at
utility cost - defer, document); HF runs NO PII scanning (a scrub bug
uploads PII silently - scrub-manifest review + sampled human review in
T-F2); 16GB contention (training only with suite quiesced, AC, thermal
gate); ecosystem half-life (depend on formats - GGUF/PEFT/JSONL - not
programs); architecture churn (engine profiles); IBM Sigstore endpoint
availability (cache verifications). Never train on non-consented data
"because it's local" - purpose limitation dies the moment it feeds a
shipped model.
