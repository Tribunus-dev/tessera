# Breach Playbook - 72-Hour Incident Response

Applies to Enterprise SKU (HIPAA + GSA 552.239-7001).

## 1. Detection

Disclosure_log anomaly, receipt_chain gap, Postgres audit, or customer
report. On-call page security@tessera.example.

## 2. Containment (0-4h)

- Revoke affected api keys via SecretStore (libsecret) + GSettings.
- Isolate host: Flatpak --share=network off or firewall.
- Snapshot disclosure_log + receipt_chain + deletion_attestations;
  do NOT purge.

## 3. Assessment (4-24h)

- Scope: who/what/when from disclosure_log + audit trails.
- HIPAA: determine unsecured PHI per 164.402, number of individuals.
- GSA: determine government data affected.

## 4. Notification

- GSA/customer: within 72 hours of discovery (GSAR 552.239-7001).
- HIPAA covered entity: without unreasonable delay, within 60 days;
  Business Associate notifies CE promptly so CE can notify individuals
  and HHS. Include: date, scope, PHI types, mitigation, contact.
- FERPA: notify institution for education-record incidents.

## 5. Eradication & Recovery

- Patch via RPM/Flatpak update, rotate secrets, re-verify
  DataLayer::verify_chain.
- Validate minimum necessary still enforced.

## 6. Post-Incident

- Root cause, POA&M entry, disclosure_log retention per policy.
- Customer may audit.

## Contacts

Security: security@tessera.example
Privacy: privacy@tessera.example

## Drill

Annual tabletop; script scripts/procurement-dry-run.sh covers static
checks, not incident drill.
