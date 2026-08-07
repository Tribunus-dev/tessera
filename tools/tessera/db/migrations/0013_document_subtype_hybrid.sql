-- Tessera Studio: document subtype in hybrid_search (migration 0013).
--
-- The three document materials (doc / sheet / slide) share
-- entity_type='document' with distinct subtype values. The graph
-- view's subtype chips ("doc", "sheet", "slide") and the
-- subtype-filtered hybrid search both need the subtype in the
-- hybrid_search output so callers can filter without a second
-- lookup. This migration extends hybrid_search to return the
-- subtype alongside the existing columns.
--
-- Idempotent: CREATE OR REPLACE. Re-applying is safe.
-- No new tables or indexes; the existing idx_entities_subtype
-- (0001) already covers subtype.

CREATE OR REPLACE FUNCTION hybrid_search(
    p_anchor         uuid,
    p_query_text     text,
    p_query_embedding vector(1536),
    p_max_depth      int DEFAULT 3
) RETURNS TABLE (
    entity_id        uuid,
    entity_type      text,
    subtype          text,
    label            text,
    body             text,
    graph_score      real,
    vector_score     real,
    keyword_score    real,
    rrf_score        real
) AS $$
WITH RECURSIVE walk AS (
    SELECT target_id AS id, 1 AS depth, link_type
      FROM entity_links WHERE source_id = p_anchor
    UNION ALL
    SELECT el.target_id, w.depth + 1, el.link_type
      FROM walk w JOIN entity_links el ON el.source_id = w.id
     WHERE w.depth < p_max_depth
),
vector_ranked AS (
    SELECT e.id, ROW_NUMBER() OVER (ORDER BY e.embedding <=> p_query_embedding) AS rn
      FROM graph_entities e
     WHERE p_query_embedding IS NOT NULL
),
keyword_ranked AS (
    SELECT e.id, ROW_NUMBER() OVER (
        ORDER BY ts_rank_cd(e.search_tsv, plainto_tsquery('english', p_query_text)) DESC
    ) AS rn
      FROM graph_entities e
     WHERE p_query_text IS NOT NULL
       AND e.search_tsv @@ plainto_tsquery('english', p_query_text)
)
SELECT
    e.id, e.entity_type, e.subtype, e.label, e.body,
    (1.0 / (1 + 1.5 * w.depth))::real                                         AS graph_score,
    COALESCE(1 - (e.embedding <=> p_query_embedding), 0.0)::real               AS vector_score,
    COALESCE(ts_rank_cd(e.search_tsv, plainto_tsquery('english', p_query_text)), 0.0)::real
                                                                               AS keyword_score,
    (
        0.2 * COALESCE(1.0 / (60 + vr.rn), 0) +
        0.5 * COALESCE(1.0 / (60 + kr.rn), 0) +
        0.3 * COALESCE(1.0 / (1 + 1.5 * w.depth), 0)
    )::real                                                                    AS rrf_score
FROM walk w
JOIN graph_entities e ON e.id = w.id
LEFT JOIN vector_ranked  vr ON vr.id = e.id
LEFT JOIN keyword_ranked kr ON kr.id = e.id
ORDER BY rrf_score DESC
LIMIT 25;
$$ LANGUAGE sql STABLE;
