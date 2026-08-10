-- 0014_graph_checkpoints.sql
-- Durable store for StateGraph run checkpoints. The Swift StateGraph port
-- (Sources/TesseraCore/StateGraph/) checkpoints every step of a graph run so
-- conversations and workflows are resumable/branchable. This is the backing
-- store for StateGraphCheckpointer; the chat-as-graph dock reconstructs its
-- transcript from these rows on reopen.
--
-- Mirrors the LangGraph (thread_id, checkpoint_id, step, node, state) tuple.
-- State is JSONB so GraphState ([String: JSONValue]) round-trips cleanly.

CREATE TABLE IF NOT EXISTS graph_checkpoints (
    id          uuid PRIMARY KEY,
    thread_id   text NOT NULL,
    step        integer NOT NULL,
    node_id     text NOT NULL,
    state       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_thread
    ON graph_checkpoints (thread_id, step);
