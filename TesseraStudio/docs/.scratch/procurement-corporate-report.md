# Procurement evidence: corporate + EU (mid-market, F500/regulated, Mac deployment)

Prepared 2026-08-15 by the procurement research agent (corporate track).
Evidence input to `../procurement-readiness-2026-08-15.md`. Peer of the
other `.scratch` evidence reports. Research date 2026-08-15; uncertain
claims marked UNVERIFIED.

## 1. SOC 2 reality for a local-first desktop vendor

- Scope is vendor-defined around the supporting "system", not the desktop
  app: release/update pipeline (signing keys, appcast/CDN),
  licensing/activation, telemetry ingestion, the control plane, corporate
  IT, subprocessor management. A no-customer-data product makes SOC 2
  near-vacuous, so reviewers refocus it on supply-chain integrity - the
  binary runs on every laptop.
  https://truvocyber.com/blog/soc-2-scoping
- Tiny-vendor feasibility: Type II auditor fees $10k-35k at startup scale;
  platform (Vanta/Drata/Secureframe) $10k-25k/yr; pen test $5k-15k; first
  year total $25k-60k, 80-250 internal hours; 2-3 months to Type I, then
  3-12 month observation window; realistic 9-15 months zero-to-Type-II.
  https://drata.com/learn/soc-2/cost
  https://www.vanta.com/collection/soc-2/soc-2-audit-cost
- Gate hardness: mid-market accepts Type I or questionnaires; F500
  generally requires clean Type II. US default SOC 2; EU/UK/APAC default
  ISO 27001; multinationals want both eventually.
  https://sprinto.com/blog/soc-2-vs-iso-27001/
- The tiering escape hatch: vendor-risk programs tier by data access;
  no-data-access vendors land in the lowest tier with light-touch review.
  The core play: an egress-architecture document argues Tessera into that
  tier. Caveat: "AI app reading all my documents" triggers
  perception-based escalation regardless.
  https://www.upguard.com/blog/vendor-tiering-mapping-to-inherent-risk
- Small-scale alternatives: CAIQ (259q) / CAIQ-Lite (73q) + CSA STAR L1;
  SIG Lite; pen-test letter + whitepaper; trust center (Vanta claims up
  to 87% questionnaire deflection - vendor marketing, UNVERIFIED).
  https://blog.getagency.com/articles/caiq-vs-sig

## 2. AI-specific vendor review (the emerging layer)

- AI modules now standard in questionnaires: model provenance/lineage,
  training-data provenance, prompt logging/retention, AI subprocessors,
  fine-tuning isolation, EU AI Act role, ISO 42001 / NIST AI RMF
  alignment.
  https://www.aetos-data.com/answers-insights/enterprise-security-ai-questionnaires
  https://www.reco.ai/ciso-hub/ai-vendor-security-questionnaire
- ISO/IEC 42001: no legal requirement; de facto RFP ask growing (EU +
  regulated strongest). Claimed adoption figures ("~40% of EU AI RFPs",
  "83% of F500 by 2027") are UNVERIFIED secondary claims. Verified:
  M365 Copilot and Google Gemini/Workspace are ISO 42001 certified,
  normalizing the question. One-founder answer: NIST AI RMF-mapped
  policy statements now; certify only on repeated demand.
  https://cloud.google.com/security/compliance/iso-42001
- The Tessy answer converts the two highest-weight questions (training
  use, retention) from trust questions into VERIFICATION questions.
  Reviewers will then ask for: enumerable network-endpoint list,
  proxy-verifiable no-egress behavior, and the Sky exception documented
  as explicit, logged, user-approved. The content-hashed receipted
  egress grant is exactly the artifact current AI questionnaires ask
  about (prompt-logging consent, deployer audit access).
- Sky subprocessors: cloud model providers must be disclosed; enterprises
  increasingly expect zero-data-retention terms, which Anthropic and
  OpenAI offer via negotiated enterprise agreements, not pay-as-you-go.
  Consequence: enterprise-tier provider agreement BEFORE regulated-
  industry Sky review, or ship Sky as bring-your-own-key/tenant so the
  customer's own agreement governs.
  https://platform.claude.com/docs/en/manage-claude/api-and-data-retention
- On-device model provenance: accepted answer = model cards + licenses +
  weight hashes + acquisition chain. EU AI Act: integrating a GPAI model
  makes Tessera a downstream AI SYSTEM provider, not a GPAI MODEL
  provider, unless fine-tuning exceeds ~1/3 of 10^23 FLOPs.
  https://artificialintelligenceact.eu/gpai-guidelines-overview/

## 3. Enterprise Mac deployment mechanics

- Distribution: Developer ID direct-distribution deploys as signed +
  notarized PKG pushed by MDM (InstallEnterpriseApplication); Jamf/
  Kandji/Mosyle all support it. Ship a distribution PKG, silent-install
  capable; enterprises will not hand-drag apps.
  https://support.apple.com/en-euro/guide/deployment/content-distribution-methods-dep7cef2e0ea/1/web/1.0
- Managed app configuration (the org-policy push mechanism): iOS =
  Managed App Configuration per the AppConfig standard
  (com.apple.configuration.managed); macOS = configuration profile
  "Application & Custom Settings" writing a managed preferences domain
  read via UserDefaults/CFPreferences. Jamf exposes JSON-Schema-driven
  UI; Kandji as Library Items. Deliverable: a documented preference-key
  schema admins can import. This is the transport for "Sky disabled",
  grant tier floors, update channel, telemetry off.
  https://developer.jamf.com/jamf-pro/docs/application-custom-settings
  https://support.kandji.io/kb/appconfig
- Updates: Sparkle 2 (EdDSA-signed appcast + Apple code-sign validation,
  XPC-isolated, sandbox-compatible) is the accepted non-MAS path.
  Enterprise expectation INVERTS consumer: a managed preference to
  DISABLE self-update so IT controls rollout via MDM-pushed PKGs.
  Support both. https://sparkle-project.org/documentation/sandboxing/
- EDR coexistence: no published "local-LLM app false positive" pattern
  found (UNVERIFIED as a named phenomenon). Adjacent documented risk:
  office apps spawning child processes is a canonical behavioral
  detection; Tessera INVERTS the tree (app spawns headless soffice) -
  unusual enough to trip generic anomaly rules. Mitigations: one Team ID
  across all binaries/helpers, notarization, no executables in temp
  paths, a published process-tree document, per-EDR exclusion guides
  (CrowdStrike/SentinelOne/Defender/Jamf Protect precedent exists).
  https://www.elastic.co/guide/en/security/8.19/suspicious-macos-ms-office-child-process.html
- Licensing: seat-based volume licensing; signed OFFLINE license files
  for air-gapped fleets (tamper-evident, no per-launch phone-home,
  documented grace behavior).
  https://licenseseat.com/docs/guides-air-gapped-licensing/

## 4. Identity/audit table stakes

- Expectation set (assumed, not asked): SSO (SAML/OIDC), SCIM
  provisioning AND deprovisioning, RBAC from directory groups,
  tenant-scoped exportable audit logs, session policies. The "SSO tax"
  is resented; making SSO available at every tier is a differentiator.
  https://hashorn.com/blog/enterprise-ready-saas-sso-scim-audit-logs
- WorkOS coverage: AuthKit free to 1M MAU; SSO + Directory Sync
  $125/connection/mo tapering; Audit Logs $99/1M events; Log Streams
  $125/mo per SIEM connection delivering to Datadog HTTP, Splunk HEC,
  S3/GCS, generic HTTP; customer-IT self-configurable via Admin Portal.
  Covers the tax almost entirely; FGA covers org policy.
  https://workos.com/pricing  https://workos.com/docs/audit-logs/log-streams
- Desktop-specific residual gaps to POSITION, not build: SSO gates
  app/license access, not local data (device posture = customer's
  MDM/FileVault domain); remote revocation cannot wipe local data (MDM
  remediation); SCIM deprovision must translate to license revoke +
  local lock.
- SIEM formats: CEF legacy; OCSF rising (Datadog/AWS/Splunk); syslog
  RFC 5424 persists. Receipt log answer: documented JSON schema + OCSF
  mapping + WorkOS Log Streams; CEF only on specific demand.
  https://www.datadoghq.com/knowledge-center/ocsf/
- DPA/residency: with ~no personal data processed, an Art. 28 DPA is
  not legally required - procurement will demand one anyway. Minimal
  DPA covers licensing records, WorkOS identity data, opt-in telemetry,
  Sky egress content; subprocessor register (WorkOS, CDN, crash
  reporting, Sky providers). Content residency = customer's devices;
  only the thin control plane needs a region statement.
  https://gdpr.eu/what-is-data-processing-agreement/

## 5. EU/UK layer

- NIS2: vendor not directly covered; indirect via customers' Art.
  21(2)(d) supply-chain duties -> flowed-down clauses (secure-dev
  attestations, incident notification, patch SLAs, audit rights). Light
  but contract-shaping; have SBOM + SDLC + incident answers ready.
  https://nis2dir.eu/en/articles/nis2-supply-chain-security
- EU AI Act: Tessera = AI SYSTEM provider; GPAI MODEL obligations sit
  upstream (in force Aug 2 2025; enforcement Aug 2 2026; legacy models
  Aug 2 2027). Productivity assistant is not Annex III high-risk in
  normal use; AUP sentence forbids repurposing into Annex III uses.
  Article 50 transparency applies from Aug 2 2026: disclose AI
  interaction; machine-readable marking of synthetic content - the
  C2PA-compatible receipts are a near-direct Article 50 implementation
  (C2PA 2.1 is now ISO/IEC 22144).
  https://artificialintelligenceact.eu/article/50/
  https://contentauthenticity.org/blog/the-state-of-content-authenticity-in-2026
- UK: no AI Act equivalent; Cyber Security and Resilience Bill (draft
  Nov 2025) targets MSPs/data centres/critical suppliers - desktop
  vendor out of direct scope; NIS2-style flow-down logic applies.

## 6. Competitive benchmark

- M365 Copilot presents: ISO 27001/27018/27701, SOC 1/2/3, HIPAA, EU
  Data Boundary, ISO 42001, "prompts not used to train foundation
  models". Note: reported Apr 2026 "flex routing" default sending some
  EU inferencing outside the EU Data Boundary at peak - a live wedge
  for local-first (secondary source, UNVERIFIED).
  https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-privacy
- Gemini/Workspace: SOC 1/2/3, ISO 2700x + 42001, FedRAMP High, HIPAA
  support, residency controls.
- Local-first precedent: Ollama/LM Studio/Jan are inside enterprises
  bottom-up (allowlisting, not RFP wins). NO public case found of a
  local-first AI desktop suite passing formal F500/regulated
  procurement - absence of evidence, UNVERIFIED/none found.
- Banking third-party guidance (Interagency 2023) makes vendor
  VIABILITY (financial condition, continuity) an explicit
  due-diligence item - the hardest gate for a one-founder company,
  independent of security posture. Mitigations: source + signing-key
  escrow, continuity statement, perpetual-license terms, insurance.
  https://www.federalregister.gov/documents/2023/06/09/2023-12340/interagency-guidance-on-third-party-relationships-risk-management
- Healthcare: with no vendor access to PHI, arguably no BAA needed
  ("no PHI access" representation); hospitals default to demanding BAAs
  anyway; Sky-with-grants reopens the BAA question for whatever leaves.
  https://www.hipaajournal.com/hipaa-business-associate-agreement/

## 7. What local-first deletes vs leaves

DELETED (with egress-architecture doc as proof): cloud content
security/tenancy/backup-DR; residency; content breach exposure;
content retention/DSR handling; Tessy training-use questions
(structurally answered); most CAIQ cloud sections; subprocessor sprawl;
hosted-service SLAs.

LEFT, often HEAVIER than SaaS: software supply chain (signing, SBOM,
provenance, update integrity - scrutinized harder because the binary
runs on every endpoint); the vendor company itself (SOC 2 scope shifts
here); endpoint behavior (EDR, process tree, MDM manageability);
identity plane; AI layer (provenance, Article 50, Sky ZDR); vendor
viability (amplified by one-founder status); and the burden shifted to
the buyer: content protection now depends on customer device posture -
reviewers ask how the app SUPPORTS that (data protection classes, no
plaintext scratch files).

## 8. Gap list

Code-level: (1) managed-config surface (macOS managed prefs + iOS
AppConfig) for Sky kill-switch/grant floors/model allowlist/update
channel/telemetry, with published key schema; (2) signed+notarized
silent-install PKG; (3) Sparkle 2 hardened + MDM-disable +
manual-PKG fallback; (4) licensing wired to AuthKit/SCIM (deprovision
-> revoke -> local lock) + signed offline licenses; (5) receipt-log
export: stable JSON schema + OCSF mapping + WorkOS Log Streams,
per-org retention; (6) hard-coded enumerable endpoint list + "verify
no egress" mode for proxy testing; (7) per-grant subprocessor/model/
ZDR-flag recorded in receipts; org policy from signed offline-capable
snapshots; (8) one Team ID everywhere, no temp executables, documented
soffice invocation.

Product-pipeline: (9) SBOM (SPDX/CycloneDX) + SLSA-style provenance
per release; (10) annual third-party pen test + shareable letter;
(11) model provenance pack (cards, licenses, weight SHA-256, signed
download chain); (12) security.txt + disclosure policy + CVE process +
patch SLA; (13) EDR compatibility guide per vendor; (14) telemetry
default-off, documented.

Company-process: (15) security whitepaper + trust center + pre-filled
CAIQ-Lite/SIG Lite + AI addendum; (16) SOC 2 program (platform ->
Type I -> Type II; ISO 27001 only when EU-heavy; 42001 only on
repeated demand); (17) minimal DPA + subprocessor register + IR policy
+ HIPAA position paper; (18) viability mitigations: escrow, continuity
statement, perpetual terms, cyber/E&O insurance; (19) support SLAs +
named security contact; (20) Sky provider enterprise/ZDR agreement or
BYO-key mode.

## 9. Verdict

Mid-market kit (months 0-6, ~$15-30k + engineering): egress whitepaper
(the centerpiece), trust center + CAIQ-Lite + AI addendum, pen-test
letter, PKG + MDM guide + managed-config schema, WorkOS-backed
SSO/SCIM/audit at EVERY tier (no SSO tax - differentiator), minimal
DPA, insurance. Clears most mid-market reviews via the no-data-access
tier; SOC 2 Type I by month 6-9 removes the last common objection.

F500/regulated kit (months 9-24, additive): Type II, pen-test cadence,
SBOM + provenance, EDR docs, SIEM streaming, offline licensing, escrow
+ continuity, Sky ZDR or BYO-tenant, HIPAA paper, ISO 27001 if
EU-heavy. Binding constraint: vendor-viability screening, mitigated by
escrow/continuity/terms, not certifications.

One-founder sequencing: (1) egress whitepaper + endpoint inventory
first - free, reframes everything; (2) MDM/managed-config + PKG - no
pilot survives IT onboarding without it; (3) trust center + CAIQ-Lite +
pen test; (4) one compliance platform, Type I -> Type II, one
framework; (5) enter regulated verticals through mid-market firms in
those verticals (regional banks, clinics, boutique law firms); treat
true F500 as year-2+ contingent on Type II + viability package.
Procurement risk concentrates in: the update pipeline, the AI
questionnaire, and vendor viability - NOT data security, the section
local-first largely deletes.
