# NIST AI RMF Mapping - Tessera Studio Mac (Personal SKU)

Maps Tessera Studio Mac features to NIST AI Risk Management Framework
(AI RMF) functions: GOVERN (GV), MAP (MP), MEASURE (MS), GOVERN (GS).

For the Enterprise SKU mapping (collaborative, multi-user), see
`../procurement/NIST-AI-RMF-mapping.md`.

**Key distinction for personal SKU:** The user is the sole operator,
data controller, and risk assessor. Tessera Inc. does not operate the
system; it ships the software. Many NIST AI RMF commitments that apply
to Tessera-as-operator (Enterprise SKU) map to "user responsibility"
in the personal SKU.

---

## GOVERN (GV) - Organizational AI Risk Management Policy

### GV-1: Organizational AI risk management policy established and communicated

**Personal SKU:**

- Risk management policy is LICENSE-TESSERA + PolyForm Noncommercial
  1.0.0. The license governs what Tessera Inc. is responsible for.
  Beyond the license, the user manages their own risk.
- The app's intended-use guardrail ("NOT for automated decision-making
  in benefits, employment, housing, criminal justice, or law enforcement
  without human review") is stated in `system-card.md` and cannot be
  disabled in the personal SKU.
- The constitutional receipt chain provides the audit infrastructure
  for the user's own risk management.

**Personal vs. Enterprise:** Enterprise GV-1 maps to Tessera's BAA/DPA
responsibilities. Personal SKU has no Tessera-managed policy because
Tessera does not operate the system.

### GV-2: AI roles and responsibilities established

**Personal SKU:**

- One role: the user. Tessera Studio is a single-user application.
- No multi-user roles (viewer/editor/administrator) in the personal
  SKU. The device login is the access boundary.

**Personal vs. Enterprise:** Enterprise GV-2 maps to ToolRegistry
role enforcement. Personal SKU has no role system to document.

### GV-3: AI policies and procedures for third-party AI risk established

**Personal SKU:**

- Third-party AI risk: the user chooses whether to opt into a cloud
  LLM provider. Tessera ships the conduit; the user assesses the
  provider's risk posture.
- The DPA (`dpa.md`) documents the Tessera-side terms for cloud opt-in.
- No Tessera-managed third-party AI inventory (there are no Tessera-managed
  cloud AI services in the personal SKU).
- Provider assessment is the user's responsibility. The DPA points to
  each provider's public privacy policy.

---

## MAP (MP) - AI Impact Assessment

### MP-1: AI system impacts characterized

**Personal SKU:**

- Context: personal knowledge workspace, agent-assisted writing and
  editing. Not a high-risk decision system.
- The app's stated limitation (system-card.md section 2) disclaims
  automated decision-making use cases. This is the impact characterization.
- The user assesses their own use case. Tessera does not conduct
  AI impact assessments for personal-SKU users because Tessera does not
  know how the user deploys the software.

**Personal vs. Enterprise:** Enterprise MP-1 is Tessera's responsibility
under the BAA. Personal SKU shifts MP-1 to the user.

### MP-2: AI use cases documented

**Personal SKU:**

- Use cases are documented by the user via the constitutional receipt
  chain. Each receipt records the action taken, the model used (on-device
  or cloud), and the timestamp. The receipt chain is the use-case log.
- The user can export the receipt chain via `TesseraDataLayer` for
  their own compliance purposes.
- Tessera does not maintain a use-case inventory for personal-SKU users.

**Personal vs. Enterprise:** Enterprise MP-2 is Tessera's CurationLedger
responsibility. Personal SKU provides the infrastructure (receipt chain)
but the user manages the inventory.

### MP-3: AI supply chain characterized

**Personal SKU:**

| Component | Source | License | Notes |
|---|---|---|---|
| Tessera engine (llama.cpp fork) | upstream llama.cpp + Tessera modifications | MIT (upstream) + LICENSE-TESSERA | T640 quantization, DFlash/DSpark spec-decoding |
| On-device models | user-downloaded GGUF weights | Model-provider license (varies by model) | Tessera does not provide models |
| Cloud models (opt-in) | OpenAI / Anthropic / Google | Provider terms | User provides API key; Tessera is a conduit |
| Presidio PII filter (future design basis) | Microsoft | MIT | On-device if future training is added |

- No Tessera-managed model supply chain in the personal SKU. The user
  downloads models from the source they choose.
- The upstream llama.cpp license (MIT) is the primary supply-chain
  commitment. Tessera's modifications are governed by LICENSE-TESSERA.
- Third-party cloud providers are sub-processors under the user's
  account; covered by the DPA.

---

## MEASURE (MS) - AI System Performance and Bias

### MS-1: AI system performance evaluated

**Personal SKU:**

- Performance evaluation is the user's responsibility. Tessera does not
  provide benchmarks or evaluation tooling for the personal SKU.
- The user can run their own local evaluation against the on-device
  model using `llama-bench` or similar tooling.
- Cloud model performance is governed by the provider's SLA, not
  Tessera.

**Personal vs. Enterprise:** Enterprise MS-1 maps to Tessera-provided
per-release evaluation reports. Personal SKU has no Tessera-provided
benchmark.

### MS-2: AI bias tested

**Personal SKU:**

- No Tessera-provided bias probe. Bias evaluation requires a
  statistically significant population; a single user's data does not
  provide that.
- The user may nominate their own probe. Tessera provides no default.
- The on-device inference path (CoreML + Metal) has no Tessera-managed
  bias telemetry.

**Personal vs. Enterprise:** Enterprise MS-2 maps to the tiered
probe sizes in the Enterprise training data card. Personal SKU is
explicitly out of scope for Tessera-provided bias testing.

### MS-3: AI incidents identified and addressed

**Personal SKU:**

- The constitutional receipt chain is the incident record. Each receipt
  records the action, the model, the timestamp, and the signature.
  Failed actions generate a receipt with an error payload.
- "AI incidents" (e.g., a hallucinated document edit) are recorded as
  failed receipts. The user reviews the receipt drawer to investigate.
- Tessera does not have access to personal-SKU incidents. There is no
  Tessera-managed incident database for personal SKU.

**Personal vs. Enterprise:** Enterprise MS-3 maps to Tessera's
disclosure_log and breach-playbook. Personal SKU provides the
infrastructure (receipt chain) but Tessera does not operate the
incident response.

---

## GOVERN (GS) - AI Risk Response and Monitoring

### GS-1: AI risk responses prioritized and implemented

**Personal SKU:**

- The user's receipt chain provides the audit trail for risk response.
  If a problem is identified, the user can trace the actions that
  produced it via the receipt chain.
- The C2PA manifests (signed with the Keychain-held signing key)
  provide tamper-evidence for the audit trail.
- The "Plead the Fifth" crypto-shred is the nuclear risk response:
  destroys the signing key, unmounts the encrypted volume, and makes
  all prior receipts unverifiable. This is the correct behavior when
  the data dies.

**Personal vs. Enterprise:** Enterprise GS-1 maps to Tessera's BAA
incident response (72-hour report). Personal SKU has no Tessera-managed
risk response because Tessera does not have access to the data.

### GS-2: AI monitoring ongoing

**Personal SKU:**

- Monitoring is local only. The user monitors their own system via
  the receipt drawer and the app's own logs.
- No Tessera-side monitoring. Tessera does not receive telemetry,
  usage data, or crash reports from personal-SKU installations.
- Cloud provider monitoring (token usage, API errors) is governed by
  the provider's own dashboard, accessible to the user.

**Personal vs. Enterprise:** Enterprise GS-2 maps to Tessera's fleet
monitoring. Personal SKU has no Tessera-side monitoring.

### GS-3: AI third-party risk managed

**Personal SKU:**

| Third party | Risk | Mitigation |
|---|---|---|
| OpenAI / Anthropic / Google (opt-in) | Sub-processor under user's account | DPA documents Tessera's conduit role; user reviews provider's privacy policy |
| Apple (OS, Keychain, FileVault) | Platform dependency | Apple's own privacy policy governs platform components |
| Presidio (future PII filter design basis) | Open-source MIT | No commercial sub-processor relationship |
| Python + Pandoc (import/export bridge) | Local process, no network | User-controlled file operations; no network egress |

- The user manages third-party risk by choosing which providers to
  opt into. Tessera provides the DPA documentation but does not
  manage the provider relationship.
- No Tessera-managed sub-processor list for personal SKU (Tessera has
  no data to share with sub-processors).

---

## Summary Table

| NIST AI RMF Function | Enterprise commitment | Personal SKU commitment |
|---|---|---|
| GV-1: AI risk policy | Tessera BAA/DPA + receipt chain | LICENSE-TESSERA + user-managed risk + stated use limitations |
| GV-2: AI roles | ToolRegistry viewer/editor | Device login only |
| GV-3: Third-party AI risk | Tessera-managed sub-processor list | User assesses provider; DPA documents conduit role |
| MP-1: AI impact assessment | Tessera conducts for regulated uses | User assesses their own use case |
| MP-2: AI use cases documented | Tessera CurationLedger | User's receipt chain (infrastructure provided, not managed) |
| MP-3: AI supply chain | Tessera-managed model inventory | User downloads models; upstream llama.cpp MIT + Tessera LICENSE-TESSERA |
| MS-1: AI performance | Tessera per-release evaluation | User runs own eval; no Tessera-provided benchmark |
| MS-2: AI bias | Tessera-provided tiered probe | User-nominated probe only; no Tessera default |
| MS-3: AI incidents | Tessera disclosure_log + breach-playbook | Receipt chain is incident record; Tessera has no access |
| GS-1: AI risk responses | Tessera BAA incident response | Receipt chain audit trail + Plead the Fifth crypto-shred |
| GS-2: AI monitoring | Tessera fleet monitoring | Local only; no Tessera telemetry |
| GS-3: Third-party risk | Tessera sub-processor management | User manages provider choice; DPA documents conduit role |
