# Interim Authority - SSP Outline + POA&M Template

Enterprise only. No claim of FedRAMP authorization.

## SSP Outline (NIST 800-53 Rev 5, low baseline)

- System: Tessera Studio Linux Enterprise (Flatpak + RPM)
- Boundary: client app + Postgres/Valkey/DuckDB (customer-hosted or
  FedRAMP-authorized PaaS); no vendor SaaS boundary.
- Controls: AC-3 (ToolRegistry/DataLayer), AU-2/AU-3 (disclosure_log,
  receipt_chain), SC-12/SC-13 (LUKS/TLS/libsecret), SC-7 (Buy American
  network gating), SI-10 (minimum necessary), IR-4 (breach playbook).

## Implemented

Encryption at rest/in transit, disclosure accounting, audit trails,
minimum necessary, 72-hour incident, 30-day portability, no training.

## POA&M Template

| id | control | finding | milestone | date |
|---|---|---|---|---|
| POAM-001 | AU-2 | disclosure_log needs SIEM export | add syslog forwarder | 2026-11-01 |
| POAM-002 | CA-7 | continuous monitoring dashboard | implement | 2026-12-01 |
| POAM-003 | 3PAO | FedRAMP package with 3PAO | engage 3PAO | 2027-01-15 |

Customer may copy this file into their package. Auditor will validate
against actual deployment.

## Desk Review Gate

Reviewer opens docs/procurement/*.md without building: BAA, DPA,
subprocessors, System/Model Cards, NIST RMF map, GSA matrix, this SSP,
breach playbook must be present and read as procurement-first.
