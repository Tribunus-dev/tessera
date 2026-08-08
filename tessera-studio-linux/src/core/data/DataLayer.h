#pragma once
#include <string>
#include <vector>
#include <optional>
#ifdef HAVE_LIBPQ
#include <libpq-fe.h>
#endif
#ifdef HAVE_HIREDIS
#include <hiredis/hiredis.h>
#endif
namespace tessera {
// Postgres (source of truth) + Valkey (cache) + DuckDB (analytical) — spec §6
// Mirrors TesseraDataLayer/TesseraDataStore/TesseraCache (§6, hexagonal facade, cache invariants)
enum class StartOutcome { Ready, CacheDegraded, DataStoreDegraded, BothDown };
struct DataConfig {
    std::string postgres_url; // postgresql:// or embedded dir; default from $TESSERA_POSTGRES_URL or XDG
    std::string valkey_url;   // valkey:// or redis://; default $TESSERA_VALKEY_URL
    std::string duckdb_path;  // *.duckdb; default $XDG_DATA_HOME/tessera/tessera.duckdb
};
struct NoteRow { std::string id; std::string label; std::string body; };
class DataLayer {
public:
    explicit DataLayer(DataConfig cfg) : cfg_(cfg) {}
    // Like TesseraDataLayer/start() — never throws, returns degraded outcome
    StartOutcome connect();
    bool is_connected() const { return connected_; }
    StartOutcome last_outcome() const { return last_outcome_; }
    std::string last_error() const { return last_error_; }
    static std::string xdg_config_dir();
    static std::string xdg_data_dir();
    static std::string xdg_cache_dir();
    static DataConfig from_env(); // reads $TESSERA_* or XDG defaults
    // Live queries (hexagonal boundary — surfaces never run SQL themselves)
    int count_entities(const std::string &entity_type = "");
    std::vector<NoteRow> list_notes(int limit = 20);
    std::string status_string() const;
    // Write path — receipt chain (§6, hexagonal, mirrors TesseraDataStore + graph_receipts/receipt_chain)
    std::string insert_entity(const std::string &entity_type, const std::string &label, const std::string &body="", const std::string &subtype="", const std::string &source_url="");
    std::string create_note(const std::string &label, const std::string &body="");
    std::string add_receipt(const std::string &entity_id, const std::string &receipt_type, const std::string &payload_json);
    int receipt_chain_length(const std::string &document_id);
    bool verify_chain(const std::string &document_id); // true if chain_index dense 0..n-1 and receipts exist
    // Knowledge sync helpers — hexagonal, idempotent via source_url
    std::optional<std::string> find_by_source(const std::string &source_url);
    std::vector<NoteRow> list_by_type(const std::string &entity_type, int limit=50);
    bool ensure_link(const std::string &source_id, const std::string &target_id, const std::string &link_type, float weight=1.0f);
    std::string upsert_knowledge(const std::string &entity_type, const std::string &label, const std::string &body, const std::string &source_url, const std::string &subtype="");
    int count_by_source_prefix(const std::string &prefix);
    // Graph view — nodes + edges for force-directed viz (GKT-agnostic, worker thread safe via exec_psql)
    struct GraphNodeRow{ std::string id, label, entity_type, subtype, source_url; std::string updated_at; };
    struct GraphEdgeRow{ std::string id, source_id, target_id, link_type; float weight; };
    std::vector<GraphNodeRow> list_graph_nodes(int limit=120);
    std::vector<GraphEdgeRow> list_graph_edges(int limit=500);
    std::optional<GraphNodeRow> get_entity_row(const std::string &id);
    // P2.2 Valkey cache API (hot state)
    bool valkey_set(const std::string &key, const std::string &value, int ttl_seconds=0) const;
    std::string valkey_get(const std::string &key) const;
    // P2.3 DuckDB analytical path (in-process)
    bool duckdb_exec(const std::string &sql) const;
private:
    DataConfig cfg_;
    bool connected_=false;
    StartOutcome last_outcome_=StartOutcome::BothDown;
    std::string last_error_;
    mutable std::string last_pg_error_;
#ifdef HAVE_LIBPQ
    mutable PGconn *pg_conn_=nullptr;
    std::string exec_via_libpq(const std::string &sql) const;
#endif
#ifdef HAVE_HIREDIS
    mutable redisContext *valkey_ctx_=nullptr;
    bool valkey_connect() const;
#endif
    std::string exec_psql(const std::string &sql) const;
    std::string exec_psql_popen(const std::string &sql) const;
    friend class KnowledgeSync;
};
} // namespace tessera
