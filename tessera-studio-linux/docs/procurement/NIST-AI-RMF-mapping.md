# NIST AI RMF Mapping - Tessera Studio Linux Enterprise

Maps to GOVERN / MAP / MEASURE / MANAGE.

## GOVERN

- GV-1: Risk management is led by vendor security; BAA/DPA own privacy
  risk. Audit via disclosure_log and receipt_chain.
- GV-2: Roles (viewer/editor) enforced in ToolRegistry + DataLayer.
- GV-3: Incident response 72-hour per GSA, breach playbook.

## MAP

- MP-1: Context is knowledge workbench; not high-risk decision without
  human. Documented in system-card.md.
- MP-2: Categories: generative text, retrieval (hybrid_search RRF),
  graph. No biometric ID without consent (COPPA).
- MP-3: Impacts: privacy (FERPA/HIPAA), provenance (receipt_chain),
  third-party model risk (subprocessors.md, Buy American).

Refs: DataLayer verify_chain, knowledgeSync, AgentLoop maxIterations 10,
ApprovalEngine HoldYourHorses + DenialCircuitBreaker.

## MEASURE

- ME-1: Metrics: disclosure_log count, receipt_chain verify, token_usage
  DuckDB, curation ledger quarantine rate.
- ME-2: Bias: model cards, provider evaluations; on-device option cuts
  provider bias.
- ME-3: Security: PQexecParams, libsecret, LUKS, TLS.

## MANAGE

- MG-1: Controls at data-layer not prompts; ToolRegistry minimum
  necessary circuit breaker.
- MG-2: Ongoing monitoring: 30-60 day deletion, audit exports,
  GSA 30-day portability.
- MG-3: Recovery: Valkey cache degraded ok, Postgres degraded flagged,
  BothDown with guidance.

## Artifacts

System Card, Model Card, SSP/interim-authority, GSA matrix, BAA/DPA,
subprocessors - these docs make desk-review pass without building.
