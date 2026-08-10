# BAA - Business Associate Agreement (HHS Template Reference)

Tessera Studio Linux - Enterprise SKU

## 1. Parties

Business Associate: Tessera Studio Linux (Enterprise) operator
Covered Entity: Customer (healthcare provider / plan / clearinghouse)

## 2. Regulatory Basis

45 CFR 164.502(e), 164.504(e), HHS BAA template Jan 2025.
2025 HIPAA Final Rule: encryption at rest and in transit is MANDATORY
(not addressable). Implementation: libsecret + udisks2 LUKS outer,
TLS 1.2+ for RemoteStreamingProvider (libsoup), Postgres sslmode=require.

## 3. Permitted Uses

Business Associate may use PHI only as necessary to provide the
collaborative knowledge-studio service (notes, graph, workflow surfaces)
and as required by law. No other use.

## 4. Safeguards

- Administrative: role-based access (viewer/editor), minimum necessary
  enforced in ToolRegistry (filter must be specific, no SELECT *).
- Technical: AES-256 LUKS volume (EncryptedVolume), TLS, column-level
  access via DataLayer PQexecParams, disclosure_log per 164.312(b).
- Physical: customer-hosted Postgres/Valkey; no PHI leaves boundary
  without explicit BAA with subprocessor.

## 5. Subcontractors

See subprocessors.md. Each subprocessor with PHI access signs a BAA
before data flows. Non-US subprocessors blocked by default
(TESSERA_ENTERPRISE).

## 6. Reporting

Breach of unsecured PHI reported without unreasonable delay and within
60 days of discovery (164.402/410). Enterprise also triggers the
72-hour GSA incident clause (see GSA-clause-matrix.md).

## 7. Termination

Within 30 days of termination, BA returns or destroys PHI per
NIST 800-88 Purge and attests via deletion_attestations table
(+ receipt_chain tombstone). If destruction infeasible, protections
extend.

## 8. No Training on PHI

Model training on customer PHI prohibited. See system-card.md
(OMB M-25-22). On-device lane (LlamaProvider) never sends PHI to
remote; RemoteApi requires customer opt-in per provider.

## 9. Audit

Customer may audit disclosure_log (FERPA 99.32 style, see DataLayer)
and receipt_chain. BA makes NIST AI RMF mapping available.

Signature blocks and effective date to be completed per customer.
