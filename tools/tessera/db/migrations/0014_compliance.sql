-- 0014_compliance: disclosure log + deletion attestation (FERPA 99.32 / HIPAA 164.312)
-- First-class procurement: enterprise SKU logs every data access for BAA/HIPAA audit.

CREATE TABLE IF NOT EXISTS disclosure_log (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id             uuid REFERENCES graph_entities(id) ON DELETE SET NULL,
    entity_type           text,
    accessor              text NOT NULL,
    purpose               text NOT NULL,
    min_necessary_filter  text,
    accessed_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_disclosure_entity ON disclosure_log(entity_id);
CREATE INDEX IF NOT EXISTS idx_disclosure_accessor ON disclosure_log(accessor);
CREATE INDEX IF NOT EXISTS idx_disclosure_at ON disclosure_log(accessed_at);

-- Deletion attestation: tombstone for 30-60 day SLA (TraceStore + receipt_chain)
CREATE TABLE IF NOT EXISTS deletion_attestations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_prefix   text NOT NULL,
    deleted_count   int NOT NULL,
    attested_by     text NOT NULL,
    attested_at     timestamptz NOT NULL DEFAULT now(),
    receipt_id      uuid REFERENCES graph_receipts(id)
);
