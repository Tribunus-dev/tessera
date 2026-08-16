# Procurement readiness: government + corporate (2026-08-15)

**Question answered:** is Tessera Studio's architecture (local-first
Tessy, grant-gated Sky, signed receipts, tiered gates, WorkOS control
plane) enough to pass procurement at government and corporate buyers -
and if not, what is the runway.
**Evidence:** `.scratch/procurement-government-report.md` +
`.scratch/procurement-corporate-report.md` (researched 2026-08-15, cited
throughout). Companion: `dual-agent-egress-design.md` (amended by §2
below).

## 1. The verdict

**The architecture is the right shape, and unusually so - but "enough"
requires three corrections and a founder-affordable runway of paper +
product work. Nothing requires the seven-figure certifications the
incumbents carry.**

The headline asymmetry, from both tracks independently: local-first
DELETES the sections of procurement that are hardest for SaaS vendors -
FedRAMP for the product (federal), StateRAMP/TX-RAMP (state), cloud
data security/tenancy/residency/breach exposure (corporate), the
training-use question (structurally answered), and the dominant
genAI-policy objection (sidestepped, not fought). What remains
concentrates in three places: the software supply chain (the binary
runs on every endpoint, so signing/SBOM/update integrity get MORE
scrutiny than a SaaS backend), the emerging AI questionnaire (which the
egress-grant receipts answer almost verbatim), and vendor viability
(the one-founder question - answered by escrow/continuity/insurance,
not certifications).

## 2. The three architecture corrections (binding on the egress design)

1. **WorkOS is the COMMERCIAL control plane only.** WorkOS holds SOC 2
   Type II and nothing government-shaped: no FedRAMP/GovRAMP, and DFARS
   7012's FedRAMP-Moderate-equivalency requirement makes it
   categorically unusable in any CUI path. Every government segment
   (federal, defense, TX-RAMP states) requires the control plane to be
   OPTIONAL AND PLUGGABLE: direct SAML/OIDC federation to the
   customer's IdP (Entra Gov/Okta Gov; PIV/CAC via IdP), optional
   direct SCIM, receipts exported to the CUSTOMER'S SIEM (documented
   JSON schema + OCSF mapping; CEF on demand), policy via MDM. This is
   an interface-design decision to make NOW, before the WorkOS
   integration hardens: one `OrgControlPlane` seam, two providers
   (WorkOS; direct-federation), never WorkOS-specific types in core.
2. **FIPS discipline in the crypto paths.** For managed mode, receipt
   signing and encrypted volumes must route through Apple's validated
   corecrypto (CryptoKit/Security.framework/Secure Enclave; macOS 15
   cert #5184 current) using FIPS-approved algorithms. Ed25519's
   in-scope status on Apple's current certificates is unverified, so
   the receipt signature suite becomes pluggable with ECDSA P-256
   (Secure Enclave) as the managed-mode default. No bundled third-party
   crypto anywhere; ChaCha20-Poly1305 is not approved.
3. **Records law inverts the privacy features in managed mode - and
   the distinction is surgical, not a rename.** Receipts and briefing
   hashes at an agency are plausibly federal/state records and
   FOIA-responsive. Plead-the-Fifth AS SHIPPED (no-confirmation hotkey,
   covert text-input trigger, user-discretionary crypto-shred, unsigned
   deletable wipe report) is an unauthorized-disposition engine and
   must be PROVABLY ABSENT in managed government postures - no
   invocable path, guard-tested. What transplants into "Certified
   Disposition" is the shred implementation and the step-report
   pattern, under an inverted control structure: triggered by the
   retention schedule, authorized by the org, frozen by legal holds,
   and reported as a SIGNED receipt in the chain (not deletable JSON).
   Inside that structure it is a genuine compliance asset - defensible
   disposal evidence supporting 36 CFR 1230 accountability and
   "no responsive records" FOIA answers. Same shredder, opposite
   governance.

## 3. Segment matrix

| Segment | Hard gates | Runway | First beachhead |
|---|---|---|---|
| Federal civilian | CISA SSDF attestation (personal False-Claims exposure - run the practices), credible ACR (VPAT 2.5; PDF/UA export is the load-bearing half), FIPS paths, SAM/889/TAA, managed retention; WorkOS-optional | ~3-6 months product+paper; zero third-party cert spend | Sub-$15k purchase-card pilots at Mac-fleet innovation offices/labs; position against $1 OneGov cloud AI as "AI that never leaves the building, with signed provenance" |
| Defense contractors (CUI) | Everything federal + control-support matrix (receipt log -> AU 3.3.x; it EXCEEDS 3.3.8/9), SIEM-in-enclave export, no WorkOS in CUI path, model-weight provenance | 6-12 months incl. one friendly contractor pilot | Small/mid contractors with Mac engineering teams inside CMMC L2 scope; Phase 2 (Nov 2026) makes their audit-evidence problem urgent - the receipt log IS audit evidence |
| State/local | Managed retention (public-records acts), accessibility (DOJ Title II deadlines 2027/28 bind the BUYERS - accessible output is a selling point), reseller/cooperative access | Smallest incremental lift | Privacy-sensitive local offices on Mac footprints: courts, public defenders, health departments |
| Corporate mid-market | Egress whitepaper + endpoint inventory (argues into the light-touch vendor tier), trust center + CAIQ-Lite + AI addendum, pen-test letter, PKG + MDM managed-config schema, SSO at every tier (no SSO tax), minimal DPA | 0-6 months, ~$15-30k + engineering; SOC 2 Type I by month 6-9 removes the last common objection | Regulated-vertical mid-market: regional banks, clinics, boutique law firms - where local-first SHORTENS review |
| F500 / regulated | SOC 2 Type II, SBOM + build provenance, EDR compatibility docs, SIEM streaming, offline licensing, Sky ZDR enterprise terms or BYO-key, escrow + continuity + insurance (viability is the binding constraint, not security) | Year 2+, months 9-24 additive | Enter through mid-market firms in the target verticals first |

## 4. Unified gap backlog (mapped to execution)

**Code-level (feeds Wave P2-D and a new P3 "enterprise readiness" wave):**
1. `OrgControlPlane` seam with WorkOS + direct-federation providers
   (correction 1) - design NOW, rides the posture work in
   `dual-agent-egress-design.md` §4.
2. Pluggable receipt-signature suite; ECDSA P-256/Secure Enclave
   managed default; corecrypto-only crypto paths (correction 2).
3. Managed retention: purge/overwrite schedule-gating, legal-hold
   freeze, Certified Disposition rename (correction 3).
4. Receipt export: stable JSON schema + OCSF mapping + customer-SIEM
   delivery (WorkOS Log Streams as the commercial transport).
5. Sky BYO-endpoint mode (agency/enterprise-supplied endpoint +
   credentials; per-grant provider/model/ZDR-flag recorded in the
   receipt - the grant design already carries provider identity).
6. Managed app configuration surface (macOS managed prefs + iOS
   AppConfig) with a published key schema; Sky kill-switch, grant tier
   floors, model allowlist, update-channel control, telemetry off.
7. Hard-coded enumerable network-endpoint inventory + a "verify no
   egress" mode security teams can proxy-test.
8. Signed+notarized silent-install PKG; Sparkle 2 hardened with
   MDM-disable; signed offline licensing with SCIM-deprovision ->
   license-revoke -> local-lock; session lock/termination; CUI banner
   marking (managed); one Team ID across all binaries, no temp
   executables, documented soffice process tree.
9. Trusted timestamps on receipts (AU 3.3.7); accessibility regression
   suite + real VoiceOver/keyboard coverage feeding the ACR.

**Product-pipeline:** SPDX + CycloneDX SBOMs per release incl. model
weights with hashes; SLSA-style build provenance; SSDF/800-218 practice
evidence (MFA on VCS/CI, separated build env, vuln scanning) so the
attestation is truthfully signable; annual pen test + shareable letter;
model provenance pack (cards, licenses, weight SHA-256, signed download
chain); EDR compatibility guides; security.txt + disclosure policy +
CVE process; ACR (508 + EN 301 549 editions); control-support matrix
mapping features to 800-53/800-171 for ISSOs and C3PAOs.

**Company-process:** SAM/UEI + 889 + TAA hygiene; sign + submit the
CISA form at first federal opportunity; egress-architecture whitepaper
FIRST (free, reframes every later question); trust center + CAIQ-Lite +
AI addendum (NIST AI RMF-mapped; EU AI Act role statement: AI system
provider, GPAI obligations upstream, Article 50 via C2PA receipts - note
C2PA 2.1 is now ISO/IEC 22144 and the receipts are a near-direct
Article 50 implementation); SOC 2 program (platform -> Type I -> Type
II, one framework); minimal DPA + subprocessor register; HIPAA "no PHI
access" position paper + Sky-BAA fallback; escrow + continuity +
perpetual terms + cyber/E&O insurance; reseller agreement
(Carahsoft-type) for MAS/SEWP/cooperatives; Sky provider enterprise/ZDR
agreement or BYO-key default.

## 5. Two ceilings the architecture does not solve

1. **The Apple-only footprint** is the real government/corporate TAM
   ceiling - bigger than any certification. (Noted, not argued here:
   the repo already carries `tessera-studio-linux` and the GTK4 port
   spec; procurement is the first commercial argument that work has
   had.)
2. **One-founder vendor viability** is the F500/banking binding
   constraint (Interagency 2023 guidance makes financial condition an
   explicit due-diligence item). Mitigations are contractual - escrow,
   continuity, perpetual licenses, insurance - and partnership optics
   (a WorkOS-adjacent go-to-market helps here more than any audit).

## 6. Sequencing (one founder, honest)

1. Now (free): egress whitepaper + endpoint inventory; the
   `OrgControlPlane` seam decision; correction 2/3 designs into the
   P2-D wave brief.
2. Months 0-6: mid-market kit (trust center, CAIQ-Lite, pen test, PKG +
   managed-config, WorkOS SSO at every tier); federal micro-purchase
   pilot prep (SAM/889/attestation evidence).
3. Months 6-12: SOC 2 Type I -> Type II window; ACR from real AT
   testing; first contractor pilot for the CMMC story.
4. Year 2: F500 motion (Type II + viability package); GSA MAS via
   reseller economics review.
