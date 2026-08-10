# System Card - Tessera Studio Linux Enterprise

Per OMB M-25-22, NIST AI RMF, EO 14110.

## 1. System Overview

Tessera Studio Linux is a knowledge-workbench (notes, docs, sheets,
slides, graph, workflow, agent) with a collaborative graph backed by
Postgres + Valkey + DuckDB. Packaging: Flatpak + RPM on Fedora/RHEL.
UI: GTK4 + libadwaita, Adwaita system palette only.

## 2. Intended Use

Knowledge management and collaborative document work for teams.
Not a decision tool for benefits, employment, or law enforcement
without human review (see NIST RMF MAP).

## 3. Data

- Training data: public corpora + licensed data listed in model cards.
  Customer data (notes, emails, graph entities) is NOT used for
  training. OMB M-25-22: eyes-off and no training on government data
  by default; customer must explicitly opt in per provider.
- Portability: graph_entities / receipt_chain export via DataLayer;
  customer retains data. On termination, 30-day return/destroy.

## 4. Models

- Cloud: customer-selected via RemoteStreamingProvider (OpenAI,
  Anthropic, Google, etc). Model card per provider (see model-card.md).
- On-device: LlamaProvider via llama.cpp FFI (dlsym, GGML_OPENVINO).
  No data leaves device in on-device mode.

## 5. Eyes Off / Human Review

No human review of customer content by vendor personnel unless
required by law or support ticket with consent. Support accesses are
logged in disclosure_log.

## 6. Privacy

BAA/DPA available (see BAA.md, DPA.md). COPPA voiceprint <13 requires
parental consent. FERPA disclosure log per 99.32.

## 7. Security

Encryption at rest (LUKS via udisks2) and in transit (TLS). Access
controls at data-layer (PQexecParams + ToolRegistry minimum necessary),
not prompts. Audit trails (receipt_chain + disclosure_log).

## 8. Incident Reporting

72-hour report per GSA 552.239-7001 and HIPAA Breach Notification
(see GSA-clause-matrix.md and breach-playbook.md).

## 9. Limitations

Capacity estimates heuristic (60 GB/s on T2 Intel), no formal
FedRAMP authorization yet (FedRAMP-ready SSP in interim-authority.md).

## 10. Contact

Security: security@tessera.example
Privacy: privacy@tessera.example
