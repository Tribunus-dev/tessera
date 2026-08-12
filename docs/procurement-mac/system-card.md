# System Card - Tessera Studio Mac (Personal SKU)

Per OMB M-25-22, NIST AI RMF, EO 14110. For the Enterprise SKU
(collaborative, multi-user, cloud-first), see `system-card.md` in the
parent `procurement/` directory.

## 1. System Overview

Tessera Studio for macOS is a personal knowledge workspace (notes, docs,
sheets, slides, email, calendar, contacts, tasks, reminders, graph,
workflow, agent) running entirely on the user's Apple Silicon device.
Packaging: native macOS app (Xcode + Swift Package Manager).
UI: SwiftUI, AppKit where required.

**The default mode is local-only.** No data leaves the device without
explicit user action. Cloud LLM providers (OpenAI, Anthropic, Google)
are opt-in and require the user to provide their own API key; Tessera
never sees or stores the key or the queries.

Architecture stack:

- **On-device inference**: Apple Silicon Neural Engine (CoreML) + Metal
  GPU via Tessera engine (llama.cpp fork with calibrated per-tensor
  quantization T640, native spec-decoding DFlash/DSpark).
- **Local knowledge graph**: Embedded Postgres (via the Postgres.app
  runtime or system PostgreSQL) + Valkey for ephemeral cache + DuckDB
  for local analytics.
- **App state**: SwiftData (local SQLite).
- **Secrets**: Apple Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- **Encrypted volume**: APFS sparse bundle with AES-256, password stored
  in Keychain. Mounted at app launch. Destroyed on "Plead the Fifth"
  crypto-shred.
- **Import/export**: Python + Pandoc bridge, user-controlled file
  operations; no Tessera-managed cloud storage.

## 2. Intended Use

Personal knowledge management and agent-assisted writing and editing.
The agent (Tessera Agent) operates as a co-author: the user steers, the
agent drafts, the user reviews, and every mutation is recorded in a
constitutional receipt audit trail.

**NOT for automated decision-making in benefits, employment, housing,
criminal justice, or law enforcement without human review.** This
limitation is stated in the app and cannot be disabled in the personal
SKU. See NIST AI RMF MAP (GV-3, MP-1) for the policy basis.

**NOT for HIPAA-regulated environments in the personal SKU.** The
healthcare BAA (see `../procurement/BAA.md`) is scoped to the Enterprise
SKU. A user running Tessera Studio on a personal Mac in a clinical
setting is responsible for their own HIPAA risk assessment.

## 3. Data

- **Training**: OFF by default. No federation. No gradient upload. No
  cloud model training. The personal SKU has no training data pipeline.
- **Customer data portability**: `graph_entities` + `receipt_chain` export
  via `TesseraDataLayer` API; the user retains full control.
- **On termination**: user controls deletion. Deleting the app removes
  all local data. The "Plead the Fifth" crypto-shred destroys the
  encrypted volume password and all Keychain entries.
- **No third-party data custody**: Tessera Inc. never receives, stores,
  or processes user data in the personal SKU. There is no Tessera cloud
  backend for personal-SKU users.

**Cloud opt-in (user-provided API key):** When the user adds an OpenAI,
Anthropic, or Google API key, queries are sent directly to the chosen
provider under the user's account. See `dpa.md` for the data processing
terms that apply in this scenario.

## 4. Models

**On-device (default):**

- Apple Silicon Neural Engine via CoreML + Metal GPU.
- Tessera engine (llama.cpp fork, T640 quantization, DFlash / DSpark
  spec-decoding).
- Model weights stored locally in `~/Library/Application Support/TesseraStudio/`.
- No data leaves the device in on-device mode.

**Cloud opt-in (user-provided key):**

- OpenAI, Anthropic, Google: user provides key via Settings.
- Key stored in Apple Keychain, never transmitted except to the chosen
  provider's API endpoint over TLS.
- Tessera does not receive, log, or store prompts or model outputs.

**No Tessera-managed model training in the personal SKU.**

## 5. Eyes Off / Human Review

No Tessera personnel have access to user data in the personal SKU.
There is no Tessera cloud backend, no telemetry pipeline, and no
support-access mechanism for personal-SKU users.

User data stays on the device. The only egress path is:

1. The user explicitly exports a file.
2. The user opts into a cloud LLM provider (API key flow).
3. The user installs an explicitly opt-in Tessera cloud sync feature
   (future; not committed in this card).

## 6. Privacy

- **No telemetry.** Tessera does not collect usage data, error reports,
  or crash logs from personal-SKU installations.
- **No analytics.** No third-party analytics SDKs with network access.
- **No advertising.** Not applicable; there is no product monetization
  that requires user data.
- **COPPA**: the personal SKU is not marketed to or directed at children.
  Voice and biometric features (if used) require macOS system consent
  flows; Tessera does not implement its own consent for minors.
- **FERPA / HIPAA**: see section 2. The personal SKU is not the right
  tool for regulated institutional use without a separate BAA and
  institutional procurement.
- **Apple Keychain**: all secrets (API keys, volume passwords, signing
  keys) use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The
  signing key used for C2PA receipts is destroyed on crypto-shred.

## 7. Security

- **Data at rest (device level)**: macOS FileVault (device encryption,
  enabled by default on Apple Silicon Macs with Secure Boot).
- **Data at rest (app level)**: APFS sparse bundle encrypted with
  AES-256, password in Keychain. Mounted at app launch, unmounted at
  quit. "Plead the Fifth" crypto-shred destroys the password entry.
- **Data in transit**: TLS 1.2+ for all cloud API calls. API keys
  never transmitted except to the provider's endpoint.
- **Signing keys**: ed25519 receipt signing key in Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). C2PA manifests
  signed on-device. Key is destroyed on crypto-shred.
- **Access controls**: app-level. No multi-user authentication in the
  personal SKU. The device login is the access boundary.
- **No third-party SDKs with network access**: the app ships no
  network-capable third-party runtime dependencies.
- **Audit trail**: constitutional receipts (C2PA + JSON + Markdown) in
  `receipt_chain` table. Tamper-evident via prior-receipt-ID chain.
- **Incident reporting**: Tessera security contact
  `security@tessera.example`. 72-hour report per GSA 552.239-7001
  applies to Enterprise SKU only.

## 8. Incident Reporting

For personal-SKU users: Tessera has no access to personal-SKU data,
so there is no Tessera-side incident to report. User-side incidents
(e.g., device theft) are the user's responsibility.

If a future cloud sync feature is added, the incident reporting clause
from the Enterprise `system-card.md` applies.

## 9. Limitations

**In scope for personal SKU:**

- Local-only knowledge management on one Mac.
- On-device AI inference.
- Cloud AI inference with user-provided API key.
- Encrypted volume with crypto-shred.
- Constitutional receipt audit trail.

**Out of scope for personal SKU (not committed, not planned in this card):**

- **FedRAMP / SOC 2 / ISO 27001 authorization**: not in scope for
  personal SKU. Enterprise procurement should request the SSP in
  `../procurement/interim-authority.md`.
- **HIPAA BAA**: the BAA in `../procurement/BAA.md` is scoped to the
  Enterprise SKU. Personal-SKU users in healthcare settings must
  assess their own risk.
- **Multi-device sync**: not committed in this card. A future iCloud or
  Mesh sync feature would be opt-in and would require a separate
  privacy impact assessment.
- **Collaborative / multi-user**: not in scope. See Enterprise SKU.
- **Government / gov-gold procurement**: not in scope. See Tessera
  Studio Enterprise SKU for government procurement.
- **Server / on-prem deployment**: not in scope. See Tessera Studio
  Linux Enterprise SKU.
- **Third-party data integrations with egress**: not installed by
  default. The import bridge reads local files via the standard Open /
  Save dialogs; user-controlled.

## 10. Contact

Security: `security@tessera.example`
Privacy: `privacy@tessera.example`
