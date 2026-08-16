# Procurement evidence: US government (federal civilian, defense/CUI, state-local)

Prepared 2026-08-15 by the procurement research agent (government track).
Evidence input to `../procurement-readiness-2026-08-15.md`. Research date
2026-08-15; uncertain claims marked UNVERIFIED.

## 1. FedRAMP applicability boundary

- FedRAMP covers cloud services holding federal information. Desktop/
  on-prem software is explicitly OUT of scope; it is admitted as a
  component inside the buying agency's own FISMA/RMF authorization
  boundary (workstation/GSS SSP), with the app expected to SUPPORT
  NIST 800-53 controls, not hold its own authorization.
  https://www.fedramp.gov/2026/scope/
- "Tessy-only mode for federal" = ordinary COTS on-prem software, bought
  every day via MAS/SEWP without FedRAMP. Caveat from FedRAMP's own
  guidance: only the agency determines whether a cloud-touching
  component (updates, licensing, WorkOS) falls in scope.
- Sky for federal = BYO endpoint ONLY: the agency supplies a FedRAMP
  High endpoint inside its own boundary. The authorized menu is rich:
  Azure OpenAI in Azure Government (FedRAMP High + DoD IL4/IL5);
  AWS GovCloud Bedrock (Claude at High + IL4/5 since May 2025; GPT/
  GPT-OSS + Nemotron added June 2026); Google Gemini at FedRAMP High +
  GDC air-gapped IL6.
  https://aws.amazon.com/about-aws/whats-new/2025/05/amazon-bedrock-models-fedramp-high-dod-il-4-5-govcloud/
  https://devblogs.microsoft.com/azuregov/azure-openai-fedramp-high-for-government/
- Competitive backdrop: GSA OneGov gave agencies Claude and ChatGPT for
  $1/yr and Gemini for $0.47 (Aug 2025) - reselling cloud AI is
  worthless to federal buyers; "AI that never leaves the machine" is
  the differentiator.
  https://fedscoop.com/anthropic-government-agencies-onegov-general-services-administration-artificial-intelligence/
- **WorkOS drags cloud scope back in.** WorkOS's stated posture: SOC 2
  Type II, GDPR/CCPA, HIPAA BAA on enterprise plans - and nothing more.
  No FedRAMP or StateRAMP/GovRAMP authorization claimed. (A third-party
  aggregator claims otherwise - contradicted by WorkOS's own materials;
  treat as false.) If federal identities/receipt exports flow through
  WorkOS, agencies will treat it as an unauthorized cloud service.
  Conclusion: WorkOS must be an OPTIONAL, commercial-market control
  plane. Government SKU: direct SAML/OIDC federation to agency IdPs
  (Entra Gov / Okta Gov, PIV/CAC via IdP), optional direct SCIM,
  receipts to the agency's own SIEM, policy via MDM.
  https://workos.com/security

## 2. CISA Secure Software Development Attestation (M-22-18 / M-23-16)

- APPLIES to COTS desktop software. In scope: software developed after
  Sept 14 2022 (Tessera squarely in scope). Deadlines already passed;
  any first federal sale requires the signed common form (OMB 1670-0052)
  submitted to CISA's repository up front.
  https://www.cisa.gov/secure-software-attestation-form
- The form attests to a subset of SSDF/NIST 800-218: secure build
  environments (separated build env, MFA on dev infra, logging,
  encryption, defensive monitoring); trusted source-code supply chains;
  provenance for internal + third-party components; automated vuln
  detection/remediation. Signed by someone with authority to bind the
  company; a knowingly false form is False Claims Act exposure -
  PERSONAL risk for a solo founder; run the practices, don't
  paper-attest.
- SBOM: no universal federal mandate yet (FAR Case 2021-017 proposed,
  not final); the Army already requires SBOMs contractually incl.
  commercial software. SPDX and CycloneDX both acceptable. Generate
  both in CI, including model weights with hashes.
  https://www.federalregister.gov/documents/2023/10/03/2023-21328/federal-acquisition-regulation-cyber-threat-and-incident-reporting-and-information-sharing

## 3. CMMC 2.0 / NIST 800-171 (defense contractors, CUI)

- Timeline real: 32 CFR effective Dec 16 2024; DFARS 252.204-7021 in
  new solicitations since Nov 10 2025; Phase 2 (C3PAO third-party
  assessments standard for L2) begins Nov 10 2026. L2 = the 110
  controls of 800-171 (assessed against Rev 2 currently).
  https://summit7.us/blog/final-rule-update-48-cfr-and-the-cmmc
- The CONTRACTOR'S enclave is certified, not the app; COTS-only
  suppliers are exempt from CMMC flow-down. The app must SUPPORT:
  - **SC 3.13.11 FIPS-validated crypto** - the classic tripwire.
    Apple corecrypto FIPS 140-3 is current and citable: macOS 15
    Sequoia Apple-silicon User cert #5184 (validated 2026-03-11),
    Secure Key Store #5305; macOS 14 fully validated. Consequence:
    receipt-signing and encrypted-volume paths must route through
    Apple's validated modules (CryptoKit/Security.framework/Secure
    Enclave) with FIPS-approved algorithms (AES-GCM/XTS, SHA-2, ECDSA
    P-256). Bundled third-party crypto = finding. ChaCha20-Poly1305
    not approved. Ed25519 approved by FIPS 186-5, but whether EdDSA is
    inside the approved scope of Apple's CURRENT certificates is
    UNVERIFIED -> make the receipt signature suite pluggable, ECDSA
    P-256 (Secure Enclave) as the managed-mode default.
    https://support.apple.com/guide/certifications/macos-security-certifications-apc35eb3dc4fa/web
  - **AU 3.3.x audit** - the signed append-only receipt log maps
    directly to 3.3.1/3.3.2 and EXCEEDS 3.3.8/3.3.9 (cryptographic
    append-only beats what assessors usually see). Complete with
    trusted timestamps (3.3.7) and export to the CONTRACTOR'S SIEM.
    WorkOS cannot carry CUI-derived receipts: DFARS 252.204-7012
    requires external CSPs handling covered defense information to
    meet FedRAMP Moderate baseline or DoD-assessed equivalency
    (Dec 2023 memo: 100% of controls, 3PAO-verified) - WorkOS meets
    neither. Categorically unusable in the CUI path.
    https://www.acquisition.gov/dfars/252.204-7012-safeguarding-covered-defense-information-and-cyber-incident-reporting.
  - **AC/IA**: session lock w/ pattern-hiding (3.1.10), termination
    (3.1.11), org-managed identity + MFA via SSO federation (PIV/CAC
    arrives via the IdP); tier gates align with least privilege.
  - **MP**: encrypted local volumes (3.8.1/3.8.2); secure overwrite
    genuinely useful for 3.8.3 sanitization; add CUI banner-marking
    as a managed-mode feature.
- On-device AI for CUI: NO dedicated DoD policy blesses local LLMs by
  name (UNVERIFIED as a recognized pattern). Existing genAI guidance
  (DON, Army) prohibits CUI in commercial genAI tools and pushes
  controlled environments; inference that never leaves an authorized
  endpoint is the cleanest reading, but expect case-by-case assessor
  scrutiny and model-weight provenance questions. Macs in CMMC
  enclaves are a real minority pattern with mature tooling (macOS
  Security Compliance Project, Jamf baselines mapped to 800-171).
  https://dodcio.defense.gov/Portals/0/Documents/Library/AI-CybersecurityRMTailoringGuide.pdf

## 4. Section 508 / accessibility

- Revised 508 applies WCAG 2.0 A/AA to native desktop software;
  agencies increasingly demand 2.1 (CMS explicitly). VPAT 2.5 editions:
  508, EU (EN 301 549), WCAG, INT. A credible ACR = per-criterion
  verdicts with specific remarks grounded in real VoiceOver/keyboard
  testing; "Partially Supports" with honest remarks is acceptable; thin
  or dishonest ACRs disqualify late.
  https://www.section508.gov/sell/acr-vpat-faq/
- The authoring-tool dimension: documents the app PRODUCES must be
  accessible - tagged-PDF (PDF/UA) export is arguably the most
  load-bearing piece (agency outputs must be 508-conformant).
- DOJ ADA Title II web rule deadlines extended (Apr 2026 interim final
  rule) to Apr 26 2027 (pop >= 50k) / Apr 26 2028 (smaller) - binds
  BUYERS, making accessible-output tooling a selling point.

## 5. Records retention vs privacy features

- Receipts/AI edit histories are plausibly federal records (44 USC
  3301 is medium-agnostic; NARA Bulletin 2023-02 treats messaging as
  records; the Army's 2025 LLM-workspace policy captures prompts +
  generated content as managed records; FOIA requesters already target
  AI interaction logs). Assume receipts + briefing hashes at an agency
  are records and FOIA-responsive.
  https://www.archives.gov/records-mgmt/bulletins/2023/2023-02
- **Managed mode MUST disable/schedule-gate purge.** Destruction
  outside a NARA-approved schedule or under a FOIA/litigation hold is
  unlawful disposition (36 CFR 1230). Session purge, secure overwrite,
  and Plead-the-Fifth must be org-policy-controllable with legal-hold
  flags freezing receipts + content. State public-records acts mirror.
- Deletion attestations are a genuine compliance ASSET inside the
  schedule ("defensible disposal": signed evidence of authorized,
  schedule-based destruction - better than most agencies produce
  today). But RENAME for the government SKU - "Plead the Fifth" reads
  as spoliation tooling to a records officer. Suggested: "Certified
  Disposition".

## 6. Procurement mechanics

- Fastest first dollar: micro-purchases - threshold $15,000 since
  Oct 1 2025; card buys below it need no competition/posting/protest.
  Prerequisites: SAM.gov/UEI, Section 889 reps; CISA attestation in
  principle (card-level enforcement inconsistent - UNVERIFIED).
  https://smartpay.gsa.gov/guidance-and-audits/smart-bulletins/002/
- Channel: government resellers (Carahsoft/DLT/immixGroup type) holding
  MAS/SEWP/state cooperatives handle TAA/889/paperwork for margin; own
  GSA MAS listing ~3-6 months + normally two years of financials.
- State/local: cooperatives (NASPO ValuePoint, Sourcewell, OMNIA,
  TIPS), state vehicles (TX DIR). StateRAMP/GovRAMP and TX-RAMP gate
  CLOUD services only - desktop exempt; WorkOS would be caught for
  Texas state-agency deals.
- Hard gates: SAM/UEI, 889, CISA attestation, TAA for MAS, ACR when
  asked. Semi-negotiable: company SOC 2 (pen-test letter + roadmap
  sometimes suffices early). N/A: FedRAMP for the product; CMMC for a
  COTS vendor not handling CUI.

## 7. What local-first buys / leaves / creates

BUYS (deleted): FedRAMP for the product (the seven-figure, multi-year
gate); StateRAMP/TX-RAMP for the product; DFARS 7012 CSP analysis for
the Tessy inference path; residency/breach/cloud-incident concerns for
content; the dominant genAI-policy objection (sidestepped, not fought).

LEAVES (endpoint software still owes): CISA attestation; ACR +
accessible outputs; FIPS-validated crypto paths; records/FOIA behavior
(local-first RAISES this bar - the app itself must enforce retention);
supply-chain hygiene (SBOM/provenance/889/TAA/signed updates, extended
to model weights); company trust artifacts.

CREATES: managed update distribution for CDN-blocked environments;
model weights as supply-chain artifacts; the Apple-only hardware floor
in a Windows-dominated fleet (the real TAM ceiling, bigger than any
certification); and the WorkOS re-entry problem (must be optional/
pluggable for every government segment).

## 8. Verdicts

- **Federal civilian**: architecture fundamentally suited; WorkOS as
  designed is not. Runway ~3-6 months of product+paper (FIPS paths,
  attestation evidence, ACR, managed retention, WorkOS-optional), zero
  third-party certification spend. Beachhead: sub-$15k card pilots at
  Mac-fleet innovation offices/labs, positioned against $1 OneGov
  cloud AI as "the AI that never leaves the building, with signed
  provenance".
- **Defense/CUI**: sold to CONTRACTORS, not DoD; viable after FIPS +
  no-cloud work; the receipt log is audit evidence for their CMMC L2
  assessments (Phase 2 Nov 2026 is a tailwind). No WorkOS anywhere in
  the CUI path. Runway 6-12 months incl. one friendly contractor
  pilot. Beachhead: small/mid contractors with Mac engineering teams
  whose current options are "no AI" or "GCC High only".
- **State/local**: formally easiest, most fragmented; managed
  retention + accessibility are the binding requirements; reseller/
  cooperative access is the lift. Beachhead: privacy-sensitive local
  offices on Mac footprints (courts, public defenders, health
  departments).

Bottom line: local-first deletes the seven-figure gate and the loudest
AI objection; the remaining obligations are founder-affordable. The two
things the architecture does not solve: WorkOS must become optional/
pluggable for government, and the Apple-only footprint - not any
certification - is the real ceiling on government TAM.
