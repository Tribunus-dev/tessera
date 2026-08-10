# GSA Clause Matrix - GSAR 552.239-7001 + Related

FedRAMP / GovRAMP ready posture for Enterprise SKU.

## GSAR 552.239-7001 - Information and Communication Technology

| clause | requirement | tessera enterprise implementation |
|---|---|---|
| 30-day termination | return/destroy within 30 days, attestation | DataLayer::purge_by_source_prefix + deletion_attestations + receipt_chain tombstone; RPM %post no-op |
| Eyes off | no vendor viewing of government data without consent | system-card.md eyes off; disclosure_log for any support access; on-device default |
| 72-hour incident | report incidents within 72h of discovery | breach-playbook.md + NIST RMF GV-3; disclosure_log + receipt_chain preserved |
| FedRAMP | FedRAMP authorization or readiness | interim-authority.md (SSP + POA&M), NIST RMF mapping, System/Model Cards |
| No training on gov data | do not train on government data | OMB M-25-22 per system-card.md; provider ZDR; on-device lane |
| Portability | data export in standard format | Postgres dump + DataLayer graph export + Flatpak data dir |
| Audit | government may audit | disclosure_log + receipt_chain + GSettings audit trail |

## OMB M-25-22

AI use not to train on gov data, maintain IP and privacy safeguards.
Implemented via BAA/DPA, subprocessors allowlist, Buy American.

## Buy American (FAR 52.225-1 / 41 U.S.C. 8301)

Enterprise blocks non-US LLM subprocessors (alibaba/zai/deepseek/glm/
minimax) compile-time; provider.cpp is_non_us_provider returns
PlaceholderProvider. Personal SKU retains them (not for procurement).

## SOC 2 / ISO 42001 Note

Authorization is audit outcome, not code. Enterprise delivers
readiness artifacts listed above; actual authorization requires
independent auditor. See interim-authority.md.
