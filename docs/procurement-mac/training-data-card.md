# Training Data Card - Tessera Studio Mac (Personal SKU)

This card describes the training data posture of the Tessera Studio Mac
personal SKU. It is fundamentally different from the Enterprise SKU card
(`../procurement/tessera-data-card.md`).

The key difference: **there is no training data pipeline in the personal SKU.**

The commitments in this card apply to any future training opt-in that may
be added to the personal SKU. Today (commit 232aa4596), the personal SKU
does not train on user data. This card documents the design so that
future opt-in features are auditable from first principles.

## 1. Scope

**In scope today:**

- No user data is collected, transmitted, or used for model training.
- No federation, no gradient upload, no DP-SGD.
- On-device inference only by default; cloud opt-in with user-provided
  key (see `dpa.md`).

**In scope for future opt-in training (not committed):**

- Any on-device training that may be added to personalize the local
  drafter (DFlash / DSpark) to the user's writing style.
- The design principle: all training happens on-device; no intermediate
  artifact leaves the device unless the user explicitly opts into a
  future sync feature.

**Out of scope for personal SKU:**

- Federated gradient aggregation (enterprise feature, see
  `../procurement/tessera-data-card.md`).
- Granite Guardian cloud safety filter (not used in personal SKU;
  inference is on-device with Tessera engine).
- Third-party training data (no third-party corpora).
- Multi-user / organization training (personal SKU only).
- Healthcare / HIPAA BAA (enterprise feature, see `../procurement/BAA.md`).

## 2. Source

**Today's source: none.**

No user data enters a training pipeline.

**Future on-device personalization source (design basis):**

If a future release adds on-device drafter personalization, the source
would be the user's own consented interactions, processed on-device:

- Chat transcripts from Tessera Studio notes + chat panel.
- Document edits from Tessera Studio docs + sheets.
- Workflow node traces.
- Speech transcripts (if the user uses the speech node).

No third-party corpora. No web scrape. No licensed dataset resale.

The user is the sole data controller in the personal SKU. Tessera Inc.
does not receive any training data.

## 3. PII Filtering (Design Basis for Future On-Device Training)

If on-device training is added, PII filtering would run on-device:

**Base layer: Presidio (MIT licensed, ~180 entity types).**

Open-source, runs locally, no network access. Detects:
names, emails, phone numbers, SSN, MRN, addresses, credit card numbers,
IP addresses, biometric identifiers, and customer-configured entity types.

Action: redact in place, hash the redacted span for chain-of-custody
provenance, discard the original.

**Custom layer: user-defined regex patterns.**

The app exposes a settings panel for user-defined PII patterns. This
allows the user to add domain-specific patterns (e.g., employee IDs,
internal ticket numbers) without requiring a Tessera cloud update.

**Healthcare note:** Presidio alone is not procurement-grade for HIPAA
environments (see the 79.3% recall / 37.1% precision baseline in the
Enterprise card). Users in regulated healthcare environments should use
the Enterprise SKU with the BAA and the full PII pipeline, not the
personal SKU.

## 4. Safety Filtering

**Not applicable in today's personal SKU.** No training occurs.

**Design basis for future on-device training:**

On-device safety filtering would use the same Tessera engine inference
stack, not a cloud model. The Tessera engine runs locally on Apple
Silicon; there is no Granite Guardian or other cloud safety model in
the personal SKU.

If a future on-device safety filter is added, the design principle is:
one model for inference safety and training data safety (same tool,
same vendor review, same personal-SKU privacy story).

No third-party cloud safety model is used in the personal SKU because
that would require transmitting user data to a third party.

## 5. Quality Filters (Design Basis)

**Not applicable in today's personal SKU.**

If future on-device training is added, quality filters would run
on-device:

| Filter | Tool | Rationale |
|---|---|---|
| Dedup (text) | MinHash + LSH, Jaccard >= 0.85 | On-device, same as enterprise |
| Dedup (feature cache) | cosine sim on activation deltas >= 0.95 | Catches near-duplicate prompts |
| Length | token count 16 <= n <= 4096 | Rejects one-liners and runaways |
| Language ID | fastText lid.176, en accepted | On-device |
| Encoding | UTF-8 NFC | Rejects mojibake |

No cloud service calls. All processing on Apple Silicon ANE / GPU.

## 6. Bias Evaluation

**Not applicable in today's personal SKU.** No training occurs.

**Design basis for future on-device training:**

The personal SKU does not include Tessera-provided bias probes (contrast
with the Enterprise card, which provides per-customer tiered probe
sizes). The user may nominate their own probe; Tessera provides no
default.

Rationale: bias evaluation in a personal context is fundamentally
different from an enterprise context. A single user's interactions do
not constitute a statistically significant population for demographic
bias evaluation. The user can run their own bias probe against the
on-device model; Tessera does not prescribe the probe content.

## 7. Right to Be Forgotten

**Today's posture: immediate and complete.**

The user controls all their data. Deleting the app:
1. Removes all graph entities, receipt chains, and app state.
2. Unmounts and (optionally) deletes the encrypted APFS volume.
3. Destroys all Keychain entries for Tessera (volume password, API
   keys, signing key).

The "Plead the Fifth" crypto-shred is a faster path:
1. User triggers crypto-shred from Settings > Advanced.
2. Tessera destroys the encrypted volume password in Keychain.
3. Tessera destroys the signing key in Keychain.
4. Tessera unmounts the volume.
5. All C2PA receipts become unverifiable (correct: the data is gone).

This is the constitutional property: when the data dies, the receipts
die with it. The audit trail cannot outlive the data.

**Future on-device training right to be forgotten:**

If future on-device training adds a local trace store, deletion removes
all local training traces. No federation means no upstream gradient to
delete; data is gone when the device data is gone.

## 8. Known Limitations

**Today (no training):**

- **No personalization in today's SKU.** The on-device drafter
  (DFlash / DSpark) is the same for all users. Personalization requires
  a future on-device training opt-in.
- **Single-device only.** No multi-device sync. Data is bound to one
  Mac.
- **No bias evaluation available.** No Tessera-provided probe.
- **No cloud training.** Cloud AI is inference-only with user-provided
  key. No Tessera-managed model training.

**If future on-device training is added:**

- **PII filter is on-device only.** A user who needs HIPAA-grade PII
  filtering should use the Enterprise SKU with the BAA and the full
  enterprise PII pipeline.
- **No third-party auditor path.** Personal-SKU users cannot delegate
  an audit to a third party; there is no Tessera-managed audit
  infrastructure for personal SKU. The audit trail (receipt chain)
  is user-inspectable on-device.
- **User is the sole data controller.** Tessera Inc. has no
  responsibility for the user's on-device training decisions.
