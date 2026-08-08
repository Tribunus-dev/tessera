-- Tessera Studio: Docs material surface (migration 0010).
--
-- Adds partial B-tree indexes for the `document` entity type's
-- `doc` subtype. The Docs surface (per
-- `docs/tessera-productivity-design.md` §12.1) stores longform
-- documents as `graph_entity` rows with `entity_type = 'document'`
-- and `subtype = 'doc'`; the other subtypes of `document` are
-- `sheet` (0011) and `slide` (0012), so every index here is
-- scoped with `WHERE entity_type = 'document' AND subtype = 'doc'`
-- to keep it narrow and write-cheap.
--
--   * idx_entities_doc_updated: (entity_type, updated_at DESC)
--     WHERE entity_type='document' AND subtype='doc'. The All
--     list orders by `updated_at DESC`; with 10k+ docs the
--     index makes the listing O(log n) instead of a scan.
--
--   * idx_entities_doc_favorite: same shape but filtered to
--     `body->>'isFavorite' = 'true'` via the JSON extractor.
--     The Favorites filter reads only starred docs; the
--     partial predicate keeps the index small.
--
--   * idx_entities_doc_archived: same shape but filtered to
--     archived docs. The Archived filter's index.
--
-- Migration follows the 0007 conventions (IF NOT EXISTS, no
-- transaction wrapper, idempotent re-apply). 0001-0009 are
-- unchanged. Docs are stored as `graph_entity` rows with
-- `entity_type='document'` and `subtype='doc'`; the body column
-- carries the serialized `Doc` JSON.

CREATE INDEX IF NOT EXISTS idx_entities_doc_updated
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'doc';

CREATE INDEX IF NOT EXISTS idx_entities_doc_favorite
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'doc' AND (body->>'isFavorite') = 'true';

CREATE INDEX IF NOT EXISTS idx_entities_doc_archived
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'doc' AND (body->>'isArchived') = 'true';
