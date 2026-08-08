-- Tessera Studio: Sheets material surface (migration 0011).
--
-- Adds three partial B-tree indexes for the `document` entity
-- type's `sheet` subtype. The Sheets surface (per
-- `docs/tessera-productivity-design.md` 12.1) stores spreadsheets
-- as `graph_entity` rows with `entity_type = 'document'` and
-- `subtype = 'sheet'`; the other subtypes of `document` are
-- `doc` (0010) and `slide` (0012), so every index here is
-- scoped with `WHERE entity_type = 'document' AND subtype = 'sheet'`
-- to keep it narrow and write-cheap.
--
--   * idx_entities_sheet_updated: (entity_type, updated_at DESC)
--     WHERE entity_type='document' AND subtype='sheet'. The All
--     list orders by `updated_at DESC`; with 10k+ sheets the
--     index makes the listing O(log n) instead of a scan.
--
--   * idx_entities_sheet_favorite: same shape but filtered to
--     `body->>'isFavorite' = 'true'` via the JSON extractor.
--     The Favorites filter reads only starred sheets; the
--     partial predicate keeps the index small.
--
--   * idx_entities_sheet_archived: same shape but filtered to
--     archived sheets. The Archived filter's index.
--
-- Migration follows the 0007 conventions (IF NOT EXISTS, no
-- transaction wrapper, idempotent re-apply). 0001-0010 are
-- unchanged. Sheets are stored as `graph_entity` rows with
-- `entity_type='document'` and `subtype='sheet'`; the body column
-- carries the serialized `Sheet` JSON.

CREATE INDEX IF NOT EXISTS idx_entities_sheet_updated
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'sheet';

CREATE INDEX IF NOT EXISTS idx_entities_sheet_favorite
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'sheet' AND (body->>'isFavorite') = 'true';

CREATE INDEX IF NOT EXISTS idx_entities_sheet_archived
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'sheet' AND (body->>'isArchived') = 'true';
