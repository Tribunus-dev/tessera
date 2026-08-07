-- Tessera Studio: Slides material surface (migration 0012).
--
-- Adds three partial B-tree indexes for the `document` entity
-- type's `slide` subtype. The Slides surface (per
-- `docs/tessera-productivity-design.md` 12.1) stores slide decks
-- as `graph_entity` rows with `entity_type = 'document'` and
-- `subtype = 'slide'`; the other subtypes of `document` are
-- `doc` (0010) and `sheet` (0011), so every index here is
-- scoped with `WHERE entity_type = 'document' AND subtype = 'slide'`
-- to keep it narrow and write-cheap.
--
--   * idx_entities_slide_updated: (entity_type, updated_at DESC)
--     WHERE entity_type='document' AND subtype='slide'. The All
--     list orders by `updated_at DESC`; with 10k+ decks the
--     index makes the listing O(log n) instead of a scan.
--
--   * idx_entities_slide_favorite: same shape but filtered to
--     `body->>'isFavorite' = 'true'` via the JSON extractor.
--     The Favorites filter reads only starred decks; the
--     partial predicate keeps the index small.
--
--   * idx_entities_slide_archived: same shape but filtered to
--     archived decks. The Archived filter's index.
--
-- Migration follows the 0007 conventions (IF NOT EXISTS, no
-- transaction wrapper, idempotent re-apply). 0001-0011 are
-- unchanged. Slide decks are stored as `graph_entity` rows with
-- `entity_type='document'` and `subtype='slide'`; the body column
-- carries the serialized `SlideDeck` JSON.

CREATE INDEX IF NOT EXISTS idx_entities_slide_updated
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'slide';

CREATE INDEX IF NOT EXISTS idx_entities_slide_favorite
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'slide' AND (body->>'isFavorite') = 'true';

CREATE INDEX IF NOT EXISTS idx_entities_slide_archived
    ON graph_entities (entity_type, updated_at DESC)
    WHERE entity_type = 'document' AND subtype = 'slide' AND (body->>'isArchived') = 'true';
