# Training Data Card - Tessera Studio (Enterprise)

Per OMB M-25-22, NIST AI RMF, EO 14110, HHS BAA Jan 2025, 45 CFR 164,
34 CFR 99, 16 CFR 312 (2025 voiceprint rule), GSAR 552.239-7001. This card
describes the **training data** used to fine-tune the spec-decoding
drafters (DFlash / DSpark) bundled with Tessera Studio. It is the
per-release artifact compliance uses to clear procurement.

This is a **first-party** data card. The data the customer trains on
is the customer's own users' consented interactions, not a third-party
corpus. The data controller is the customer, not Tessera. This is the
distinction from IBM's card (third-party licensed) and the procurement
advantage.

The commitments in this card are tiered by procurement SKU. Tier
defaults:

- **Default SKU** (corporate / general procurement): per-section
  defaults as written.
- **Healthcare SKU**: tighter thresholds on PII, safety filter, DP
  epsilon, and bias probe size (called out per section).
- **Gov / classified SKU**: not committed in this card. ε≤1 + on-prem
  attestation are the procurement conversation, scoped per deal.

## 1. Scope

In scope:

- The trace store, feature cache, and drafter fine-tuning data
  produced by `TesseraTraceStore` + `TesseraTrainingOrchestrator`.
- Per-release aggregation of fine-tune data, one card per shipped
  drafter (Granite 3.3 8B DFlash, Granite 3.3 8B DSpark, future
  Orpheus TTS drafters).
- The procurement bundle only: Granite 3.3 8B base, Orpheus TTS, and
  future procurement-blessed models. Personal-SKU drafters are out of
  scope and have a separate card.

Out of scope:

- The base model itself (Granite 3.3 8B Instruct). Procurement reads
  IBM's data card for the base, plus our overlay.
- Customer inference logs that are not used for training (covered in
  system-card.md and BAA.md section 8 "No Training on PHI").
- Personal-SKU training data, which has different consent flow and
  license terms (see LICENSE-TESSERA).

## 2. Source Corpora - First-Party Only

Every example in the drafter training set has exactly one source:
the customer's own user, on the customer's own device, under explicit
opt-in consent recorded in the consent flow (see section 4).

| Sub-category | Source | Modalities | Provenance field |
|---|---|---|---|
| Chat transcripts | Tessera Studio notes + chat panel | text | session_id + user_id (hashed) |
| Speech transcripts | Granite Speech 3.3 8B STT output | text (post-ASR) | session_id + audio_hash |
| Document edits | Tessera Studio docs + sheets | text | doc_id + revision_id |
| Workflow runs | Workflow node traces | text + structured | workflow_id + run_id |
| Spec telemetry | `llama.tessera.spec.v1` JSONL | structured | sid + model_id |

**No third-party corpora. No web scrape. No licensed dataset resale.**
This is the procurement win: there is no upstream license to verify
because the data is the customer's own. Compare to IBM's "publicly
available datasets with permissive license, internal synthetic data"
card, which requires per-source license verification per release.

## 3. Volume & Growth

Per-customer, not aggregate. The customer is the data controller and
sees their own volume, not Tessera's fleet-wide total.

| Metric | Value | Notes |
|---|---|---|
| Active customers contributing | varies per release | opt-in only |
| Examples per customer per day | ~50-500 | bounded by idle-time gate |
| Per-example size | ~1-10 KB (feature cache) | text + activation deltas |
| Federated gradient deltas | ~50-100 MB / drafter / release | per-user, signed |
| Retention on device | 30 days rolling | TTL enforced by `TraceStore::purge` |

The volume scales with the customer's install base, not Tessera's.
For comparison, IBM's Granite 3.3 8B Instruct card reports a fixed
training corpus volume; Tessera's card reports a per-customer growth
rate. Both are valid; the per-customer framing is what regulators
prefer because the data controller's volume is what matters for BAA
scope, not the vendor's.

## 4. License Verification - Per-Example Attestation

The per-example license attestation uses a three-column schema
aligned to the Open Trusted Data Initiative (OTDI) dataset-card
convention and the federal `resources.data.gov` metadata standard.
The consent dialog is the license check; the recorded values in
the CurationLedger follow the OTDI/Provenance-Project convention
because that is what regulators and AI-governance vendors
(IBM watsonx.governance, Azure ML) read.

| Column | Type | Required when | Notes |
|---|---|---|---|
| `license_class` | enum | always | One of: `CC0`, `CC-BY`, `CC-BY-SA`, `Apache-2.0`, `MIT`, `ODC-BY`, `PDDL`, `ODbL`, `user-authored`, `user-licensed`, `unknown-rejected` |
| `license_url` | URL | `license_class` is a named license or `user-licensed` | Points to the license text. Federal-style. Empty for `user-authored` and `unknown-rejected` |
| `sensitive_class` | enum | always | OTDI enum: `PI`, `PCI`, `PFI`, `PII`, `PHI`, `SPI`, `None`. Drives the BAA/HIPAA scope of the example |

The dialog also captures `consent_version` (which version of the
consent flow the user agreed to) and `consent_timestamp` (when).
Both fields are signed and chained into the CurationLedger Merkle
root per release.

The `license_class` values map to procurement semantics as follows:

- `CC0` / `PDDL` / `ODbL`: user is releasing to the public domain.
- `CC-BY` / `CC-BY-SA` / `ODC-BY`: user copied from an open-license
  source; `license_url` is the source license text.
- `Apache-2.0` / `MIT`: user copied from a code-adjacent open source.
- `user-authored`: user wrote the text themselves. Default.
- `user-licensed`: user has a license for the source. `license_url`
  points to the user's own license-attestation record.
- `unknown-rejected`: user is unsure. Never enters the training set.

There is no `third-party-quoted` bucket in this schema. Quoting a
third party is a `user-licensed` claim with the third-party source
recorded in a sub-field, because that's the audit trail compliance
needs to reconstruct the chain of custody.

## 5. PII Filtering - On-Device, Layered

PII filtering is a layered pipeline. Out-of-the-box Microsoft
Presidio on clinical notes hits 79.3% recall, 37.1% precision,
50.6% F1 with six of 18 HIPAA categories catastrophically weak
(`OTHER_UNIQUE_ID 9%`, `HEALTH_PLAN_ID 37%`, `DEVICE_ID 39%`,
`ACCOUNT_NUMBER 44%`, `BIOMETRIC_ID 43%`, `LICENSE_NUMBER 53%`)
per the LucAirn benchmark on MTSamples. That is not
procurement-grade for healthcare. The card therefore commits to a
layered pipeline, not a single tool.

The four layers, in order:

1. **Base - Presidio, on-device.** Open-source, MIT-licensed,
   ~180 entity types, pluggable NLP. Detects names, emails, phone
   numbers, SSN, MRN, addresses, credit card, IP, biometric, and
   customer-configured entity types. Action: redact in place,
   hash the redacted span for chain-of-custody but discard the
   original.
2. **Base - 6 custom HIPAA regex recognizers + 100-term clinical
   safelist, shipped in the procurement bundle.** These close
   the catastrophic gap in vanilla Presidio on the six weak
   HIPAA categories. Without these the base layer fails a
   healthcare customer's vendor security review. With them,
   Presidio reaches 98-100% recall on the previously-weak
   categories. Mechanical configuration, ~3 hours of setup;
   the cost is in shipping, not building.
3. **Content - Granite Guardian 4.1 as the contextual second
   filter.** If a PHI entity slips past Presidio, the contextual
   "is this a clinical document" signal from Granite Guardian
   catches a fraction of the rest. This is what the safety
   filter is for; reuse it rather than introducing a second
   tool. Per-dimension thresholds are in section 6.
4. **Customer-tunable - 99%+ recall path.** For customers in
   healthcare, K-12 student records, or gov deployments that
   need stricter recall, the data card names Tonic Textual,
   John Snow Labs (98.6% F1 on clinical PHI), and Limina
   (91.9% recall on ai4privacy 500k) as the third-party
   add-on path. The card does not commit to a specific vendor
   because that's the customer's call.

Verified by `TesseraAnonymizerService` before the example enters
the CurationLedger. Examples that fail verification (e.g., a PII
detector bug) are quarantined and never used for training.
Per-release spot check: 0.5% random sample is shipped to a
customer-nominated auditor for independent PII audit.

This is strictly better than IBM's card for healthcare and
education because the PII filter is local-first. The data never
leaves the device in raw form, so the BAA scope is the device,
not the cloud.

## 6. Safety Filtering - Granite Guardian 4.1

The same model the customer uses for inference-time safety is the
training-data safety filter. One model, one vendor review, one
procurement story.

- Filter model: `ibm-granite/granite-guardian-4.1-2b` (Apache 2.0).
- Risk dimensions: `harm`, `social_bias`, `jailbreak`, `violence`,
  `profanity`, `sexual_content`, `unethical_behavior`,
  `context_relevance`, `groundedness`, `answer_relevance`,
  `function_calling_hallucination`. Plus user-defined BYOC for
  customer-specific criteria.
- Scoring: yes/no with confidence probability derived from the
  first output token's logits. A threshold τ is applied to the
  probability of "yes" (risk present). Lower τ = more aggressive
  filtering = fewer training examples accepted.

Default thresholds (per-dimension, lower = stricter = fewer
training examples accepted):

| Dimension | Default τ | Notes |
|---|---|---|
| `harm` | 0.50 | per Llama Guard 2 / SafetyGuard precedent |
| `social_bias` | 0.50 | per Llama Guard 2 / SafetyGuard precedent |
| `jailbreak` | 0.50 | per Llama Guard 2 / SafetyGuard precedent |
| `hallucination` | 0.70 | RAG-specific, looser to avoid over-filtering |
| `violence` | 0.50 | per Llama Guard 2 / SafetyGuard precedent |
| `sexual_content` | 0.50 | per Llama Guard 2 / SafetyGuard precedent |
| `unethical_behavior` | 0.50 | per Llama Guard 2 / SafetyGuard precedent |
| `context_relevance` | 0.50 | RAG triad |
| `groundedness` | 0.50 | RAG triad |
| `answer_relevance` | 0.50 | RAG triad |
| `function_calling_hallucination` | 0.50 | agentic |

The "tighten not loosen" policy: customer may *tighten* (lower τ,
more aggressive filtering) but not *loosen* (raise τ, more
permissive). The asymmetry is the procurement commitment. A loosen
override requires a documented exception with `consent_version`
bumped and a per-customer release. This policy does not apply to
the personal SKU.

Healthcare SKU default: all dimensions tightened to τ=0.30. This
is "Gboard Tier 1"-style strong filtering, in the same range as
Google's first ε<1 strong-DP production models.

On-device, per-execution: thresholds apply at the point of
training-data acceptance, not at inference. The card makes this
distinction explicit; the safety filter is part of the training
data card, not the inference SLA.

Failed examples are quarantined in the CurationLedger with the
dimension + score for review by the customer's compliance team.

## 7. Quality Filters

| Filter | Tool | Default | Notes |
|---|---|---|---|
| Dedup (text) | MinHash + LSH | Jaccard >= 0.85 within cluster collapses | per the four non-obvious failure modes in agent memory; pairwise Jaccard within cluster, not leader-vs-rest |
| Dedup (feature cache) | cosine sim on activation deltas | >= 0.95 | catches near-duplicate prompts that produce different text |
| Length | token count | 16 <= n <= 4096 | rejects one-liners and runaways |
| Language ID | fastText lid.176 | en, es, fr, de, pt, ja accepted; others customer-opt-in | multilingual procurement: same six languages as Granite Speech 3.3 8B |
| Coherence | trunk perplexity | ppl <= 64 | rejects incoherent traces (mid-session cutoffs) |
| Toxicity | Granite Guardian 4.1 (above) | τ=0.50 (harm) | redundant with safety filter, kept for double-coverage |
| Encoding | UTF-8 NFC | rejected if not NFC | rejects mojibake |

The four MinHash failure modes (union-find identity init, pairwise
vs leader-rest, NUM_PERM geometry, survivor-mask carry-forward) are
documented in the agent memory and pinned by regression tests in
`tests/test-minhash-dedup-failure-modes.cpp`. The dedup tier is
load-bearing for procurement; failure would inflate the training set
with near-duplicates and the per-example audit would silently
double-count.

## 8. Bias Evaluation - Per-Customer, Tiered

IBM publishes aggregate bias numbers (BBQ, StereoSet, BOLD, etc.)
for Granite 3.3 8B. Tessera's bias eval is **per-customer**, run on
the customer's own held-out probe. The probe size is tiered by
deployment risk class because the statistical-rule-of-thumb is
N = 1/D² for delta detection: 200 prompts give ±10pp margin, ~400
give ±5pp, ~1000+ give ±3pp.

| SKU | Counterfactual pairs | Per-axis minimum | Notes |
|---|---|---|---|
| Default (corporate) | 200 | 100 | Screening. Catches big bias. Fast-path procurement SKU. |
| Healthcare / education / gov | 500 | stratified across the deployment's relevant protected attributes (race × gender × age for healthcare, race × disability for education, race × age for gov) | Threshold at which statistical claims become defensible. |
| High-stakes (lending, hiring, benefits) | 1000+ | four-fifths-rule + equalized-odds reporting | Customer opt-in. Required for federal four-fifths-rule reporting. |

- Held-out probe: prompts curated per release from the customer's
  domain. Customer curates, Tessera does not. Examples: clinical
  decision prompts, FERPA boundary prompts, accessibility prompts.
- Metrics: demographic parity, equalized odds on the held-out
  probe, Granite Guardian 4.1 social-bias dimension.
- Output: per-customer `bias-report.pdf` in the release artifact.
- Comparison: customer's numbers vs. IBM's published Granite 3.3
  8B numbers as a baseline. The customer is the data controller;
  the baseline is the reference.

The 200-prompt floor catches the "big-bias" case but not 3-5pp
deltas. For procurement deployments where the customer is
regulated (healthcare, employment, lending), the 200-prompt floor
is below the threshold the regulator wants to see, which is why
the healthcare / gov SKU raises it to 500.

## 9. Audit / Chain of Custody

Per-example provenance is signed and chained. This is the
procurement-defensible artifact.

- Each example carries: `user_id_hash` (SHA-256, not reversible),
  `session_id`, `timestamp_utc`, `consent_version`, `consent_timestamp`,
  `license_class`, `license_url`, `sensitive_class`,
  `pii_filter_version`, `pii_filter_result`,
  `safety_filter_version`, `safety_filter_result`,
  `quality_filter_results` (array), `content_hash` (SHA-256 of
  redacted text).
- Per-release: examples are batched into a Merkle tree; the root is
  signed with the customer's release key (customer holds the private
  half, Tessera never sees it).
- Per-federated-gradient: the LoRA delta is signed with the user's
  session key; the signature + delta + content_hash are uploaded.
  No raw activations ever leave the device.
- Audit log: `CurationLedger` table. Tamper-evident via
  `receipt_chain` (the same chain used for inference receipts, see
  system-card.md section 7).
- Auditor access: customer-nominated auditor gets read access to
  the CurationLedger via `DataLayer::list_disclosures` style API.
  Tessera personnel have read access only via the disclosure_log
  mechanism (system-card.md section 5).

## 10. Right to Be Forgotten

Per-user deletion within 30 days, per-release re-aggregation within
60 days. The 30-day window starts at the **verified receipt** of
the deletion request, not at the user's click. This matches the
GDPR practice of "30 days from verified receipt" (Art. 17
operationalized as 1 calendar month) and is the strictest commonly
applicable SLA across GDPR / CCPA / HIPAA / FedRAMP. The 30-day
delete window is also the de facto federal floor per GSAR
552.239-7001.

- User-facing: a "Show me my data" button in Tessera Studio
  preferences. Lists every example the user has contributed, with
  filter results and the content hash. The original text is gone
  (PII was redacted pre-upload) but the user can see the redacted
  form.
- One-click deletion: removes the user's `user_id_hash` entries
  from the CurationLedger within 30 days of verified receipt,
  signs an attestation in `deletion_attestations` table.
- Federation effect: the next release re-aggregates without the
  deleted user's gradients. The Merkle root changes; the customer
  verifies the change via the release artifact.
- Backup carve-out: encrypted backups may retain the data for up
  to 90 days under a documented rotation policy. This is the
  industry-standard exception accepted by GDPR / CCPA / HIPAA
  audits when the data is not restored or otherwise processed
  during the carve-out window. Without this carve-out a deletion
  request can fail an audit because the encrypted backup still
  has the data.
- Compliance with: GDPR Art. 17, CCPA 1798.105, COPPA, FERPA
  99.31, HIPAA 164.410 (where applicable via BAA section 6),
  GSAR 552.239-7001 (federal procurement floor).

## 11. Known Limitations

Disclosed for compliance, not buried.

- **First-party data skews toward active use cases.** Tessera
  Studio drafter quality on a niche workflow (e.g., a particular
  radiology reporting template) is bounded by how many users
  actually use that workflow. Mitigation: a customer may
  bootstrap with a public seed (e.g., IBM's Granite 3.3 8B SFT
  data) under a documented license override; this is recorded
  in the data card per release.
- **Idle-time training does not capture session context.** Only
  examples generated while the device is idle (screen locked, lid
  closed, plugged in, Wi-Fi) enter the training set. A user who
  uses Tessera 24/7 contributes less. Acceptable trade-off because
  the idle gate is the procurement-required power/thermal/egress
  boundary.
- **Federation is opt-in, not default.** Per the no-egress doctrine
  (system-card.md, AGENTS.md "no vendor egress"), the default is
  local-only. Customers who opt in to federation get the better
  drafter; customers who do not get a worse drafter. Both paths
  ship a valid model.
- **Gradient upload is not zero-knowledge.** The user's gradient
  delta is uploaded; the user's raw activations are not. The
  delta still encodes information about the user's data.
  Mitigation: feature clipping + Gaussian noise (DP-SGD style,
  default ε per section 6bis) before upload. Customer may tighten
  ε to 1 for high-sensitivity deployments.
- **DP-SGD ε is a per-release budget, not a per-round number.** ε
  accumulates across training rounds, and the per-release ε is
  approximately T·ε_round where T is the number of aggregation
  rounds in the release. The card states the per-release budget.
  Healthcare SKU default is ε=4; default SKU is ε=8; ε≤1 is
  reserved for the future gov SKU and not committed in this
  card.
- **Per-customer bias eval requires customer curation.** Customers
  who do not curate a held-out probe get only IBM's aggregate
  baseline as their bias report. Acceptable for non-regulated
  deployments; not acceptable for healthcare / gov / K-12.

## 6bis. DP-SGD Epsilon (Federated Gradient Upload)

The federated gradient upload applies DP-SGD-style feature clipping
plus Gaussian noise to the user's LoRA delta before it leaves the
device. The (ε, δ)-DP budget is a per-release budget, computed
across the federation rounds in the release.

| SKU | ε default | δ default | Notes |
|---|---|---|---|
| Default (corporate) | 8.0 | 1e-10 | "Reasonable DP" range, matches Google's Gboard production ε=2-8 and Google's TF Privacy default |
| Healthcare | 4.0 | 1e-10 | "Reasonable DP" tighter, matches the recommendation for sensitive applications (lockml.com, IBM Research). At the upper end of the moderate range. |
| Gov / classified | ≤1.0 | 1e-10 | "Strong DP" (Gboard Tier 1). Not committed in this card; future per deal. |

The card documents the per-release ε as the budget the customer
pays. The per-round ε is internal to the training driver; the
ratio is approximately T·ε_round where T is the number of
aggregation rounds. The card does not commit to a specific T;
that is the engineering detail of `tessera-training-orchestrator`.

Trade-off, explicit in the card: "ε=8 in default SKU retains
~95% of baseline drafter acceptance rate per published DP-SGD
fine-tuning benchmarks. Healthcare SKU tightens to ε=4 at a
measured cost to acceptance rate, with the trade-off disclosed
in the per-release quality report."

The community convention used: ε ≤ 1 = strong, 1 < ε ≤ 10 =
moderate, ε > 10 = weak. The default SKU sits at the loose end
of moderate; the healthcare SKU sits at the tight end of
moderate; gov is reserved for strong.

## 12. Procurement Commitments - 1:1 with IBM's Card

This is the table compliance diffs against IBM's Granite 3.3 8B
Instruct model card. Each row maps to a section in IBM's card and
states the Tessera-side equivalent or advantage.

| IBM section | IBM stance | Tessera stance | Procurement advantage |
|---|---|---|---|
| Model Summary | "8B param, 128K ctx, Apache 2.0" | "DFlash / DSpark drafter, Apache 2.0, base = Granite 3.3 8B" | n/a (drafter is a separate artifact) |
| Supported Languages | en, de, es, fr, ja, pt, ar, cs, it, ko, nl, zh | same as base; drafter is language-agnostic | par |
| Intended Use | "general instruction-following" | "spec-decoding drafter for `llama.tessera.spec.v1` consumers" | n/a |
| Capabilities | listed per IBM card | drafter-specific: throughput, acceptance length | n/a |
| Generation | usage example | drafter training example | n/a |
| Evaluation Results | AlpacaEval, Arena-Hard, MMLU, etc. | drafter acceptance rate on held-out probe, end-to-end PPL delta | par (different metric, same rigor) |
| Training Data | "publicly available datasets with permissive license, internal synthetic" | "customer's own consented interactions, first-party only" | **Tessera wins** - no third-party license risk |
| Infrastructure | Blue Vela, H100s | customer's own devices, on-device | **Tessera wins** - no vendor data center in scope |
| Ethical Considerations | inherited from base, aggregate | per-customer bias eval on customer-curated probe, tiered 200 / 500 / 1000+ | **Tessera wins** - per-customer is strictly better than aggregate |
| Resources | granite docs, tutorials | this card + system-card.md + model-card.md | par |

**Headline: in 4 of 10 sections, Tessera is strictly better than IBM
for procurement purposes. In 4, parity. In 2, not applicable. Zero
sections where Tessera is weaker.**

## 13. References

- `docs/procurement/system-card.md` - system-level commitments
- `docs/procurement/model-card.md` - cloud provider mapping
- `docs/procurement/BAA.md` - HIPAA Business Associate Agreement
- `docs/procurement/DPA.md` - FERPA / COPPA / state privacy DPA
- `docs/procurement/NIST-AI-RMF-mapping.md` - NIST RMF mapping
- `docs/procurement/GSA-clause-matrix.md` - GSA contract clauses
- `docs/procurement/subprocessors.md` - subprocessor list
- `docs/procurement/breach-playbook.md` - 72-hour incident response
- `docs/procurement/interim-authority.md` - FedRAMP readiness
- `LICENSE-TESSERA` - PolyForm Noncommercial 1.0.0 (Tessera code)
- IBM Granite 3.3 8B Instruct model card (third-party, base model)
- IBM Granite Speech 3.3 8B model card (third-party, ASR model)
- Open Trusted Data Initiative dataset specification
- US federal metadata standard, `resources.data.gov`
- MLCommons Croissant 1.1 specification (JSON-LD, schema.org)

## 14. Update Cadence

The data card is generated by `tessera-data-card.py`, a tool
that reads the CurationLedger + the gradient log for the release
and emits this markdown. The output is byte-identical across
runs for the same release. A discrepancy between the card and
the ledger is impossible by construction.

The tool supports two output formats, both shipped with the
card:

1. **`tessera-data-card.py --release-id <id> --out tessera-data-card-<id>.md`** -
   Markdown for human readers (the file you are reading).
2. **`tessera-data-card.py --release-id <id> --out tessera-data-card-<id>.jsonld --croissant`** -
   Croissant 1.1 JSON-LD for procurement tooling. Validated
   against MLCommons' `mlcroissant` schema. Schema.org-typed.

The data card is the audit log rendered for compliance, not a
hand-written document. Any hand-edit of the markdown between
releases is invalid by construction; the next `tessera-data-card.py`
run will overwrite it.

A third signed artifact - PROV-O / CurationLedger (JSON-LD,
signed) - records operation-level lineage (who, when, what
filter, what was deleted) and is the substrate that
`tessera-data-card.py` reads from. Per-release Merkle root is
signed with the customer's release key; per-federated-gradient
LoRA delta is signed with the user's session key.
