# DPA - Data Processing Addendum (FERPA / COPPA / State Privacy)

Applies to Tessera Studio Linux Enterprise.

## 1. Scope

Processor processes Education Records (FERPA 34 CFR 99), personal
information of children under 13 (COPPA 16 CFR 312, 2025 voiceprint
rule), and personal data under SOPIPA / HB 4 / HB 2-d where applicable.

## 2. FERPA - 34 CFR 99.32 Disclosure Log

Every disclosure of education records is logged with:
(1) recipient, (2) interest, (3) date, (4) purpose/minimum necessary
filter. Implemented as disclosure_log table (see DataLayer::log_disclosure
and ToolRegistry::call_data). Institution can export via
DataLayer::list_disclosures.

No disclosure without written consent except directory information or
99.31 exceptions; each exception still logged.

## 3. COPPA - Voiceprint / Biometric <13

Voice, face, or other biometric identifiers of children under 13 are
COPPA personal information (2025 rule). Processor will:
- Obtain verifiable parental consent before collecting voiceprint.
- Not condition participation on disclosure of more than reasonably
  necessary.
- Voice models: on-device only unless parental consent specifies cloud
  provider; non-US voice processors blocked (see subprocessors.md).

## 4. No Selling / No Targeted Advertising

Processor does not sell personal information, does not use it for
targeted advertising, and does not use it to train models that serve
other customers (system-card.md, OMB M-25-22).

## 5. State Law

Complies with California SOPIPA (Ed Code 49073.6), Texas HB 4 (Data
Privacy and Security Act), and similar student-privacy statutes that
require deletion on request.

## 6. Deletion SLA 30-60 days

Upon verified FERPA/COPPA deletion request:
- Purge from graph_entities WHERE source_url LIKE 'student:%'
- Tombstone in receipt_chain + CurationLedger + deletion_attestations
- TraceStore::purgeTrainingData trims within 30 days, attestation
  within 60 days. See DataLayer::purge_by_source_prefix.

## 7. Subprocessors

Listed in subprocessors.md. New subprocessor with education-record
access requires 30-day notice; customer may object.

## 8. Security

Same safeguards as BAA.md (NIST 800-88, PQexecParams, etc).
Incident notification within 72 hours per GSA 552.239-7001.
