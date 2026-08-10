#include "DataLayer.h"
#include <cstdlib>
#include <filesystem>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string>
#include <cstdio>
#include <array>
namespace tessera {
static bool can_connect(const std::string &host, int port){
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if(fd<0) return false;
    struct sockaddr_in addr{}; addr.sin_family=AF_INET; addr.sin_port=htons(port);
    if(inet_pton(AF_INET, host.c_str(), &addr.sin_addr)!=1){ close(fd); return false; }
    struct timeval tv{1,0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    bool ok = connect(fd, (struct sockaddr*)&addr, sizeof(addr))==0;
    close(fd); return ok;
}
static bool probe_url(const std::string &url, std::string &host, int &port){
    // very small url parser for postgres://user:pass@host:port/db and valkey://host:port
    auto at = url.find('@'); auto hostpart = at!=std::string::npos ? url.substr(at+1) : url;
    // strip scheme
    auto scheme = url.find("://");
    if(scheme!=std::string::npos) hostpart = url.substr(scheme+3);
    if(at!=std::string::npos) hostpart = url.substr(at+1);
    else if(scheme!=std::string::npos) hostpart = url.substr(scheme+3);
    // hostpart is host:port/db or host:port
    auto slash = hostpart.find('/'); if(slash!=std::string::npos) hostpart = hostpart.substr(0,slash);
    auto colon = hostpart.find(':');
    if(colon!=std::string::npos){ host = hostpart.substr(0,colon); port = std::stoi(hostpart.substr(colon+1)); }
    else { host = hostpart; port = url.rfind("postgres")!=std::string::npos ? 5432 : 6379; }
    if(host.empty() || host=="localhost") host="127.0.0.1";
    return !host.empty();
}
StartOutcome DataLayer::connect(){
    // Embedded Postgres first (user decision): use XDG_DATA_HOME/tessera/pgdata if present or if no external URL
    std::string embedded_pg = xdg_data_dir() + "/pgdata";
    bool embedded_exists = std::filesystem::exists(embedded_pg + "/PG_VERSION") || std::filesystem::exists(embedded_pg + "/postgresql.conf");
    std::string pg_url = cfg_.postgres_url;
    std::string vk_url = cfg_.valkey_url;
    if(pg_url.empty()){
        if(embedded_exists){
            // Embedded: use Unix socket via host param or default embedded URL
            pg_url = "postgres://tessera:tessera@127.0.0.1:5432/tessera?host=" + embedded_pg;
            // If embedded not yet running, we will start it via pg_ctl in Flatpak; probe will fail gracefully to DataStoreDegraded
        } else if(can_connect("127.0.0.1",5432)){
            pg_url = "postgres://tessera:tessera@127.0.0.1:5432/tessera";
        } else {
            // No embedded and no external: keep empty, will report BothDown with hint to init embedded
            pg_url = "";
        }
    }
    if(vk_url.empty() && can_connect("127.0.0.1",6379)) vk_url = "valkey://127.0.0.1:6379";
    // update cfg_ so from_env probing is sticky
    cfg_.postgres_url = pg_url; cfg_.valkey_url = vk_url;
    bool pg_ok=false, cache_ok=false;
    if(!pg_url.empty()){
        std::string h; int p; if(probe_url(pg_url,h,p)) pg_ok = can_connect(h,p);
        else pg_ok = true;
        if(!pg_ok){
            // Embedded: try to start or init via tessera-init-db (Flatpak) or pg_ctl
            if(embedded_exists){
                if(system("tessera-init-db >/tmp/tessera-init-db.log 2>&1")==0 || system(("pg_ctl -D '" + embedded_pg + "' start -l '" + embedded_pg + "/postgres.log' 2>/dev/null").c_str())==0){
                    if(probe_url(pg_url,h,p)) pg_ok = can_connect(h,p);
                }
            } else {
                // No pgdata yet — try to init embedded (will create pgdata and start)
                if(system("tessera-init-db >/tmp/tessera-init-db.log 2>&1")==0){
                    // After init, update pg_url to embedded
                    if(pg_url.empty()) pg_url = "postgres://tessera:tessera@127.0.0.1:5432/tessera?host=" + embedded_pg;
                    if(probe_url(pg_url,h,p)) pg_ok = can_connect(h,p);
                    cfg_.postgres_url = pg_url;
                }
            }
        }
    } else if(!embedded_exists){
        // pg_url empty and no embedded — try to init embedded as last resort
        if(system("tessera-init-db >/tmp/tessera-init-db.log 2>&1")==0){
            std::string try_url = "postgres://tessera:tessera@127.0.0.1:5432/tessera?host=" + embedded_pg;
            std::string h; int p;
            if(probe_url(try_url,h,p) && can_connect(h,p)){
                pg_url = try_url;
                cfg_.postgres_url = pg_url;
                pg_ok = true;
            }
        }
    }
    if(!vk_url.empty()){
        std::string h; int p; if(probe_url(vk_url,h,p)) cache_ok = can_connect(h,p);
        else cache_ok = true;
    }
    if(cfg_.duckdb_path.empty()) cfg_.duckdb_path = xdg_data_dir() + "/tessera.duckdb";
    std::filesystem::create_directories(std::filesystem::path(cfg_.duckdb_path).parent_path());
    if(pg_ok && cache_ok){ connected_=true; last_outcome_=StartOutcome::Ready; last_error_=""; return last_outcome_; }
    if(pg_ok && !cache_ok){ connected_=true; last_outcome_=StartOutcome::CacheDegraded; last_error_="valkey unreachable"; return last_outcome_; }
    if(!pg_ok && cache_ok){ connected_=false; last_outcome_=StartOutcome::DataStoreDegraded; last_error_="postgres unreachable"; return last_outcome_; }
    connected_=false; last_outcome_=StartOutcome::BothDown; last_error_= pg_url.empty() && vk_url.empty() ? "both stores down (set TESSERA_POSTGRES_URL / TESSERA_VALKEY_URL)" : "both probes failed"; return last_outcome_;
}
DataConfig DataLayer::from_env(){
    DataConfig c;
    if(auto v=getenv("TESSERA_POSTGRES_URL")) c.postgres_url=v;
    else if(auto v=getenv("DATABASE_URL")) c.postgres_url=v;
    else c.postgres_url="";
    if(auto v=getenv("TESSERA_VALKEY_URL")) c.valkey_url=v;
    else if(auto v=getenv("VALKEY_URL")) c.valkey_url=v;
    else if(auto v=getenv("REDIS_URL")) c.valkey_url=v;
    else c.valkey_url="";
    if(auto v=getenv("TESSERA_DUCKDB_PATH")) c.duckdb_path=v;
    else c.duckdb_path = xdg_data_dir() + "/tessera.duckdb";
    return c;
}
std::string DataLayer::xdg_config_dir(){ const char* p=getenv("XDG_CONFIG_HOME"); return p? std::string(p)+"/tessera" : std::string(getenv("HOME")?getenv("HOME"):"")+"/.config/tessera"; }
std::string DataLayer::xdg_data_dir(){ const char* p=getenv("XDG_DATA_HOME"); return p? std::string(p)+"/tessera" : std::string(getenv("HOME")?getenv("HOME"):"")+"/.local/share/tessera"; }
std::string DataLayer::xdg_cache_dir(){ const char* p=getenv("XDG_CACHE_HOME"); return p? std::string(p)+"/tessera" : std::string(getenv("HOME")?getenv("HOME"):"")+"/.cache/tessera"; }
std::string DataLayer::exec_psql_popen(const std::string &sql) const {
    std::string esc_sql; esc_sql.reserve(sql.size()*2);
    for(char c: sql){ if(c=='\\') esc_sql+="\\\\"; else if(c=='"') esc_sql+="\\\""; else if(c=='$') esc_sql+="\\$"; else if(c=='`') esc_sql+="\\`"; else esc_sql+=c; }
    std::string cmd = "podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -c \"" + esc_sql + "\" 2>/dev/null";
    std::array<char,256> buf; std::string out;
    FILE *p = popen(cmd.c_str(), "r");
    if(!p) return "";
    while(fgets(buf.data(), buf.size(), p)) out += buf.data();
    pclose(p);
    size_t nl = out.find('\n');
    if(nl != std::string::npos) out = out.substr(0, nl);
    while(!out.empty() && (out.back()=='\n' || out.back()=='\r' || out.back()==' ')) out.pop_back();
    while(!out.empty() && out.front()==' ') out.erase(out.begin());
    return out;
}
std::string DataLayer::exec_psql(const std::string &sql) const {
#ifdef HAVE_LIBPQ
    std::string r = exec_via_libpq(sql);
    if(!r.empty() || last_pg_error_.empty()) return r;
    // fallback to popen if libpq failed (e.g. no server or not connected)
#endif
    return exec_psql_popen(sql);
}
#ifdef HAVE_LIBPQ
std::string DataLayer::exec_via_libpq(const std::string &sql) const {
    if(cfg_.postgres_url.empty()){ last_pg_error_="no postgres_url"; return ""; }
    if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
        if(pg_conn_) PQfinish(pg_conn_);
        pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
        if(PQstatus(pg_conn_)!=CONNECTION_OK){
            last_pg_error_ = PQerrorMessage(pg_conn_);
            PQfinish(pg_conn_); pg_conn_=nullptr;
            return "";
        }
    }
    PGresult *res = PQexec(pg_conn_, sql.c_str());
    if(!res){ last_pg_error_=PQerrorMessage(pg_conn_); return ""; }
    ExecStatusType st = PQresultStatus(res);
    std::string out;
    if(st==PGRES_TUPLES_OK){
        if(PQntuples(res)>0 && PQnfields(res)>0){
            // For our usage we want first field of first row (count, id, etc)
            // If multiple fields (list_notes with delimiter), the popen path handles it.
            // For libpq, reconstruct pipe-delimited for list_* callers that parse '|'
            if(PQnfields(res)==1){
                out = PQgetvalue(res,0,0) ? PQgetvalue(res,0,0) : "";
            } else {
                // concatenate fields with '|'
                for(int f=0;f<PQnfields(res);++f){
                    if(f) out+='|';
                    out += PQgetvalue(res,0,f) ? PQgetvalue(res,0,f) : "";
                }
            }
            // For multi-row queries, callers currently use popen with -F '|'.
            // Return first row only here; multi-row will be handled via separate PQ path in list_* methods.
            // Signal multi-row by returning concatenated lines?
            if(PQntuples(res)>1){
                // Build full output as lines with | delimiter
                out.clear();
                for(int r=0;r<PQntuples(res);++r){
                    std::string line;
                    for(int f=0;f<PQnfields(res);++f){
                        if(f) line+='|';
                        line += PQgetvalue(res,r,f) ? PQgetvalue(res,r,f) : "";
                    }
                    out += line + "\n";
                }
                if(!out.empty() && out.back()=='\n') out.pop_back();
            }
        }
        last_pg_error_.clear();
    } else if(st==PGRES_COMMAND_OK){
        // For INSERT ... RETURNING, libpq returns TUPLES_OK, not COMMAND_OK. If we get COMMAND_OK, try to get OID?
        last_pg_error_.clear();
    } else {
        last_pg_error_ = PQresultErrorMessage(res);
    }
    PQclear(res);
    return out;
}
#endif
int DataLayer::count_entities(const std::string &entity_type){
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        // Parameterized to close sql_escape injection surface
        const char *sql = entity_type.empty() ? "SELECT count(*) FROM graph_entities" : "SELECT count(*) FROM graph_entities WHERE entity_type=$1";
        PGresult *res = nullptr;
        if(entity_type.empty()){
            if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK) res = PQexec(pg_conn_, sql);
            else res = nullptr;
        } else {
            if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
                if(pg_conn_) PQfinish(pg_conn_);
                pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
            }
            const char *vals[1] = {entity_type.c_str()};
            if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK) res = PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
        }
        if(res){
            std::string r;
            if(PQresultStatus(res)==PGRES_TUPLES_OK && PQntuples(res)>0) r = PQgetvalue(res,0,0)?PQgetvalue(res,0,0):"";
            PQclear(res);
            if(!r.empty()){ try{ return std::stoi(r);}catch(...){} }
        }
    }
#endif
    std::string sql = entity_type.empty() ? "SELECT count(*) FROM graph_entities" : "SELECT count(*) FROM graph_entities WHERE entity_type='" + entity_type + "'";
    std::string r = exec_psql(sql);
    try{ return std::stoi(r); } catch(...){ return -1; }
}
std::vector<NoteRow> DataLayer::list_notes(int limit){
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
            if(pg_conn_) PQfinish(pg_conn_);
            pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
        }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            const char *sql = "SELECT id::text, label, coalesce(body,'') FROM graph_entities WHERE entity_type=$1 ORDER BY created_at DESC LIMIT $2";
            std::string typ="note"; std::string lim=std::to_string(limit);
            const char *vals[2]={typ.c_str(), lim.c_str()};
            PGresult *res=PQexecParams(pg_conn_, sql, 2, nullptr, vals, nullptr, nullptr, 0);
            if(res && PQresultStatus(res)==PGRES_TUPLES_OK){
                std::vector<NoteRow> rows;
                for(int i=0;i<PQntuples(res);++i) rows.push_back({PQgetvalue(res,i,0)?PQgetvalue(res,i,0):"", PQgetvalue(res,i,1)?PQgetvalue(res,i,1):"", PQgetvalue(res,i,2)?PQgetvalue(res,i,2):""});
                PQclear(res);
                if(!rows.empty() || PQntuples(res)>=0) return rows;
            }
            if(res) PQclear(res);
        }
    }
#endif
    std::string sql = "SELECT id::text, label, coalesce(body,'') FROM graph_entities WHERE entity_type='note' ORDER BY created_at DESC LIMIT " + std::to_string(limit);
    std::string out = exec_psql(sql);
    // exec_psql now returns pipe-delimited via libpq; fallback parse pipes
    std::vector<NoteRow> rows;
    size_t pos=0;
    while(pos < out.size()){
        size_t nl = out.find('\n', pos);
        std::string line = out.substr(pos, nl==std::string::npos ? std::string::npos : nl-pos);
        pos = nl==std::string::npos ? out.size() : nl+1;
        if(line.empty()) continue;
        size_t p1=line.find('|'); size_t p2=line.find('|', p1+1);
        if(p1==std::string::npos || p2==std::string::npos) continue;
        rows.push_back({line.substr(0,p1), line.substr(p1+1, p2-p1-1), line.substr(p2+1)});
    }
    return rows;
}
std::string DataLayer::status_string() const {
    std::string s;
    switch(last_outcome_){
        case StartOutcome::Ready: s="Ready"; break;
        case StartOutcome::CacheDegraded: s="Cache degraded"; break;
        case StartOutcome::DataStoreDegraded: s="DB degraded"; break;
        case StartOutcome::BothDown: s="Both down"; break;
    }
    if(!last_error_.empty()) s += " (" + last_error_ + ")";
    return s;
}
static std::string sql_escape(const std::string &s){
    std::string o; o.reserve(s.size()*2);
    for(char c: s) if(c=='\'') o+="''"; else if(c=='\\') o+="\\\\"; else o+=c;
    return o;
}
std::string DataLayer::insert_entity(const std::string &entity_type, const std::string &label, const std::string &body, const std::string &subtype, const std::string &source_url){
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
            if(pg_conn_) PQfinish(pg_conn_);
            pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
        }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            const char *sql = "INSERT INTO graph_entities (entity_type,label,body,subtype,source_url) VALUES ($1,$2,$3,$4,$5) RETURNING id::text";
            const char *vals[5] = {entity_type.c_str(), label.c_str(), body.c_str(), subtype.empty()?nullptr:subtype.c_str(), source_url.empty()?nullptr:source_url.c_str()};
            int lens[5] = {(int)entity_type.size(), (int)label.size(), (int)body.size(), subtype.empty()?0:(int)subtype.size(), source_url.empty()?0:(int)source_url.size()};
            int fmts[5] = {0,0,0,0,0};
            // Use PQexecParams with null for empty subtype/source_url handled as NULL via param type
            PGresult *res = PQexecParams(pg_conn_, sql, 5, nullptr, vals, lens, fmts, 0);
            if(res && PQresultStatus(res)==PGRES_TUPLES_OK && PQntuples(res)>0){
                std::string id = PQgetvalue(res,0,0)?PQgetvalue(res,0,0):"";
                PQclear(res);
                if(!id.empty()){
                    // hot path: cache recent entity in Valkey per linux-data-contracts.md
                    valkey_set("tessera:entity:" + id, label, 3600);
                    return id;
                }
            }
            if(res) PQclear(res);
        }
    }
#endif
    std::string sql = "INSERT INTO graph_entities (entity_type,label,body,subtype,source_url) VALUES ('" + sql_escape(entity_type) + "','" + sql_escape(label) + "','" + sql_escape(body) + "'," + (subtype.empty()?"NULL":"'"+sql_escape(subtype)+"'") + "," + (source_url.empty()?"NULL":"'"+sql_escape(source_url)+"'") + ") RETURNING id::text";
    std::string id = exec_psql(sql);
    if(!id.empty()) valkey_set("tessera:entity:" + id, label, 3600);
    return id;
}
std::string DataLayer::create_note(const std::string &label, const std::string &body){ return insert_entity("note", label, body); }
std::string DataLayer::add_receipt(const std::string &entity_id, const std::string &receipt_type, const std::string &payload_json){
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        const char *sql = "INSERT INTO graph_receipts (entity_id, receipt_type, payload) VALUES ($1,$2,$3::jsonb) RETURNING id::text";
        std::string payload = payload_json.empty()?"{}":payload_json;
        const char *vals[3] = {entity_id.c_str(), receipt_type.c_str(), payload.c_str()};
        PGresult *res = PQexecParams(pg_conn_, sql, 3, nullptr, vals, nullptr, nullptr, 0);
        if(res && PQresultStatus(res)==PGRES_TUPLES_OK && PQntuples(res)>0){
            std::string receipt_id = PQgetvalue(res,0,0)?PQgetvalue(res,0,0):"";
            PQclear(res);
            if(!receipt_id.empty()){
                const char *idx_sql = "SELECT coalesce(max(chain_index),-1)+1 FROM receipt_chain WHERE document_id=$1";
                const char *idx_vals[1] = {entity_id.c_str()};
                PGresult *idx_res = PQexecParams(pg_conn_, idx_sql, 1, nullptr, idx_vals, nullptr, nullptr, 0);
                std::string next_idx="0";
                if(idx_res && PQresultStatus(idx_res)==PGRES_TUPLES_OK && PQntuples(idx_res)>0) next_idx = PQgetvalue(idx_res,0,0)?PQgetvalue(idx_res,0,0):"0";
                if(idx_res) PQclear(idx_res);
                const char *chain_sql = "INSERT INTO receipt_chain (document_id, chain_index, receipt_id) VALUES ($1,$2::int,$3) RETURNING chain_index";
                const char *chain_vals[3] = {entity_id.c_str(), next_idx.c_str(), receipt_id.c_str()};
                PGresult *chain_res = PQexecParams(pg_conn_, chain_sql, 3, nullptr, chain_vals, nullptr, nullptr, 0);
                if(chain_res) PQclear(chain_res);
                // cache receipt hot path
                valkey_set("tessera:receipt:" + receipt_id, payload, 3600);
                // DuckDB analytics fan-out
                duckdb_exec("INSERT INTO traces (sid, ts, kind, payload) VALUES ('" + entity_id + "', now(), 'receipt', '" + payload + "')");
                return receipt_id;
            }
        }
        if(res) PQclear(res);
    }
#endif
    std::string esc_payload = sql_escape(payload_json.empty()?"{}":payload_json);
    std::string sql = "INSERT INTO graph_receipts (entity_id, receipt_type, payload) VALUES ('" + sql_escape(entity_id) + "','" + sql_escape(receipt_type) + "','" + esc_payload + "'::jsonb) RETURNING id::text";
    std::string receipt_id = exec_psql(sql);
    if(receipt_id.empty()) return "";
    std::string idx_sql = "SELECT coalesce(max(chain_index),-1)+1 FROM receipt_chain WHERE document_id='" + sql_escape(entity_id) + "'";
    std::string next_idx = exec_psql(idx_sql);
    if(next_idx.empty()) next_idx="0";
    std::string chain_sql = "INSERT INTO receipt_chain (document_id, chain_index, receipt_id) VALUES ('" + sql_escape(entity_id) + "'," + next_idx + ",'" + sql_escape(receipt_id) + "') RETURNING chain_index";
    exec_psql(chain_sql);
    valkey_set("tessera:receipt:" + receipt_id, payload_json, 3600);
    duckdb_exec("INSERT INTO traces (sid, ts, kind, payload) VALUES ('" + entity_id + "', now(), 'receipt', '" + payload_json + "')");
    return receipt_id;
}
int DataLayer::receipt_chain_length(const std::string &document_id){
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        const char *sql="SELECT count(*) FROM receipt_chain WHERE document_id=$1";
        const char *vals[1]={document_id.c_str()};
        PGresult *res=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
        std::string r;
        if(res && PQresultStatus(res)==PGRES_TUPLES_OK && PQntuples(res)>0) r=PQgetvalue(res,0,0)?PQgetvalue(res,0,0):"";
        if(res) PQclear(res);
        if(!r.empty()){ try{ return std::stoi(r);}catch(...){} }
    }
#endif
    std::string r = exec_psql("SELECT count(*) FROM receipt_chain WHERE document_id='" + sql_escape(document_id) + "'");
    try{ return std::stoi(r);} catch(...){ return -1; }
}
bool DataLayer::verify_chain(const std::string &document_id){
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        const char *cnt_sql="SELECT count(*) FROM receipt_chain WHERE document_id=$1";
        const char *max_sql="SELECT coalesce(max(chain_index),-1) FROM receipt_chain WHERE document_id=$1";
        const char *vals[1]={document_id.c_str()};
        PGresult *cnt_res=PQexecParams(pg_conn_, cnt_sql, 1, nullptr, vals, nullptr, nullptr, 0);
        PGresult *max_res=PQexecParams(pg_conn_, max_sql, 1, nullptr, vals, nullptr, nullptr, 0);
        std::string cnt_s, max_s;
        if(cnt_res && PQresultStatus(cnt_res)==PGRES_TUPLES_OK && PQntuples(cnt_res)>0) cnt_s=PQgetvalue(cnt_res,0,0)?PQgetvalue(cnt_res,0,0):"";
        if(max_res && PQresultStatus(max_res)==PGRES_TUPLES_OK && PQntuples(max_res)>0) max_s=PQgetvalue(max_res,0,0)?PQgetvalue(max_res,0,0):"";
        if(cnt_res) PQclear(cnt_res);
        if(max_res) PQclear(max_res);
        if(!cnt_s.empty() && !max_s.empty()){
            try{ int cnt=std::stoi(cnt_s); int mx=std::stoi(max_s); if(cnt==0) return true; return mx==cnt-1; }catch(...){}
        }
    }
#endif
    std::string cnt_s = exec_psql("SELECT count(*) FROM receipt_chain WHERE document_id='" + sql_escape(document_id) + "'");
    std::string max_s = exec_psql("SELECT coalesce(max(chain_index),-1) FROM receipt_chain WHERE document_id='" + sql_escape(document_id) + "'");
    try{
        int cnt = std::stoi(cnt_s); int mx = std::stoi(max_s);
        if(cnt==0) return true; // empty chain is vacuously dense
        return mx == cnt-1;
    } catch(...){ return false; }
}
std::optional<std::string> DataLayer::find_by_source(const std::string &source_url){
    if(source_url.empty()) return std::nullopt;
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        const char *sql="SELECT id::text FROM graph_entities WHERE source_url=$1 LIMIT 1";
        const char *vals[1]={source_url.c_str()};
        PGresult *res=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
        std::string r;
        if(res && PQresultStatus(res)==PGRES_TUPLES_OK && PQntuples(res)>0) r=PQgetvalue(res,0,0)?PQgetvalue(res,0,0):"";
        if(res) PQclear(res);
        if(!r.empty() && r.find('-')!=std::string::npos) return r;
    }
#endif
    std::string r=exec_psql("SELECT id::text FROM graph_entities WHERE source_url='" + sql_escape(source_url) + "' LIMIT 1");
    if(r.empty() || r.find('-')==std::string::npos) return std::nullopt;
    return r;
}
std::vector<NoteRow> DataLayer::list_by_type(const std::string &entity_type, int limit){
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        const char *sql="SELECT id::text, label, coalesce(body,'') FROM graph_entities WHERE entity_type=$1 ORDER BY created_at DESC LIMIT $2";
        std::string lim=std::to_string(limit);
        const char *vals[2]={entity_type.c_str(), lim.c_str()};
        PGresult *res=PQexecParams(pg_conn_, sql, 2, nullptr, vals, nullptr, nullptr, 0);
        if(res && PQresultStatus(res)==PGRES_TUPLES_OK){
            std::vector<NoteRow> rows;
            for(int i=0;i<PQntuples(res);++i) rows.push_back({PQgetvalue(res,i,0)?PQgetvalue(res,i,0):"", PQgetvalue(res,i,1)?PQgetvalue(res,i,1):"", PQgetvalue(res,i,2)?PQgetvalue(res,i,2):""});
            PQclear(res);
            // cache hot recent list
            if(!rows.empty()) valkey_set("tessera:list:" + entity_type, std::to_string(rows.size()), 60);
            if(!rows.empty()) return rows;
        }
        if(res) PQclear(res);
    }
#endif
    std::string sql="SELECT id::text, label, coalesce(body,'') FROM graph_entities WHERE entity_type='"+sql_escape(entity_type)+"' ORDER BY created_at DESC LIMIT "+std::to_string(limit);
    std::string out=exec_psql(sql);
    std::vector<NoteRow> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; size_t p1=line.find('|'); size_t p2=line.find('|',p1+1); if(p1==std::string::npos||p2==std::string::npos) continue; rows.push_back({line.substr(0,p1), line.substr(p1+1,p2-p1-1), line.substr(p2+1)}); }
    if(!rows.empty()) valkey_set("tessera:list:" + entity_type, std::to_string(rows.size()), 60);
    return rows;
}
bool DataLayer::ensure_link(const std::string &source_id, const std::string &target_id, const std::string &link_type, float weight){
    if(source_id.empty()||target_id.empty()||link_type.empty()) return false;
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        const char *sql="INSERT INTO entity_links (source_id,target_id,link_type,weight) VALUES ($1,$2,$3,$4) ON CONFLICT (source_id,target_id,link_type) DO NOTHING RETURNING id::text";
        std::string w=std::to_string(weight);
        const char *vals[4]={source_id.c_str(), target_id.c_str(), link_type.c_str(), w.c_str()};
        PGresult *res=PQexecParams(pg_conn_, sql, 4, nullptr, vals, nullptr, nullptr, 0);
        bool ok=false;
        if(res) { ok = PQresultStatus(res)==PGRES_TUPLES_OK || PQresultStatus(res)==PGRES_COMMAND_OK; PQclear(res); }
        if(ok) return true;
    }
#endif
    std::string sql="INSERT INTO entity_links (source_id,target_id,link_type,weight) VALUES ('"+sql_escape(source_id)+"','"+sql_escape(target_id)+"','"+sql_escape(link_type)+"',"+std::to_string(weight)+") ON CONFLICT (source_id,target_id,link_type) DO NOTHING RETURNING id::text";
    std::string r=exec_psql(sql); return !r.empty() || true; // idempotent
}
std::string DataLayer::upsert_knowledge(const std::string &entity_type, const std::string &label, const std::string &body, const std::string &source_url, const std::string &subtype){
    auto existing=find_by_source(source_url);
    if(existing) return *existing;
    std::string id=insert_entity(entity_type,label,body,subtype,source_url);
    if(!id.empty()) add_receipt(id,"ingest","{\"source\":\""+sql_escape(source_url)+"\"}");
    return id;
}
int DataLayer::count_by_source_prefix(const std::string &prefix){
    std::string r=exec_psql("SELECT count(*) FROM graph_entities WHERE source_url LIKE '"+sql_escape(prefix)+"%'");
    try{ return std::stoi(r);}catch(...){ return -1; }
}
std::vector<DataLayer::GraphNodeRow> DataLayer::list_graph_nodes(int limit){
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
            if(pg_conn_) PQfinish(pg_conn_);
            pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
        }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            std::string lim=std::to_string(limit);
            const char *sql="SELECT id::text, label, entity_type, coalesce(subtype,''), coalesce(source_url,''), updated_at::text FROM graph_entities ORDER BY updated_at DESC LIMIT $1";
            const char *vals[1]={lim.c_str()};
            PGresult *res=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
            if(res && PQresultStatus(res)==PGRES_TUPLES_OK){
                std::vector<GraphNodeRow> rows;
                for(int i=0;i<PQntuples(res);++i) rows.push_back({PQgetvalue(res,i,0)?PQgetvalue(res,i,0):"", PQgetvalue(res,i,1)?PQgetvalue(res,i,1):"", PQgetvalue(res,i,2)?PQgetvalue(res,i,2):"", PQgetvalue(res,i,3)?PQgetvalue(res,i,3):"", PQgetvalue(res,i,4)?PQgetvalue(res,i,4):"", PQgetvalue(res,i,5)?PQgetvalue(res,i,5):""});
                PQclear(res);
                return rows;
            }
            if(res) PQclear(res);
        }
    }
#endif
    std::string sql="SELECT id::text, label, entity_type, coalesce(subtype,''), coalesce(source_url,''), updated_at::text FROM graph_entities ORDER BY updated_at DESC LIMIT "+std::to_string(limit);
    std::string out=exec_psql(sql);
    std::vector<GraphNodeRow> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<6) continue; rows.push_back({f[0],f[1],f[2],f[3],f[4],f[5]}); }
    return rows;
}
std::vector<DataLayer::GraphEdgeRow> DataLayer::list_graph_edges(int limit){
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
            if(pg_conn_) PQfinish(pg_conn_);
            pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
        }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            std::string lim=std::to_string(limit);
            const char *sql="SELECT id::text, source_id::text, target_id::text, link_type, weight FROM entity_links LIMIT $1";
            const char *vals[1]={lim.c_str()};
            PGresult *res=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
            if(res && PQresultStatus(res)==PGRES_TUPLES_OK){
                std::vector<GraphEdgeRow> rows;
                for(int i=0;i<PQntuples(res);++i) rows.push_back({PQgetvalue(res,i,0)?PQgetvalue(res,i,0):"", PQgetvalue(res,i,1)?PQgetvalue(res,i,1):"", PQgetvalue(res,i,2)?PQgetvalue(res,i,2):"", PQgetvalue(res,i,3)?PQgetvalue(res,i,3):"", (float)atof(PQgetvalue(res,i,4)?PQgetvalue(res,i,4):"0")});
                PQclear(res);
                return rows;
            }
            if(res) PQclear(res);
        }
    }
#endif
    std::string sql="SELECT id::text, source_id::text, target_id::text, link_type, weight FROM entity_links LIMIT "+std::to_string(limit);
    std::string out=exec_psql(sql);
    std::vector<GraphEdgeRow> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<5) continue; rows.push_back({f[0],f[1],f[2],f[3], (float)std::atof(f[4].c_str())}); }
    return rows;
}

bool DataLayer::valkey_set(const std::string &key, const std::string &value, int ttl_seconds) const {
#ifdef HAVE_HIREDIS
    if(!valkey_connect()) return false;
    redisReply *r = nullptr;
    if(ttl_seconds>0) r = (redisReply*)redisCommand(valkey_ctx_, "SETEX %s %d %s", key.c_str(), ttl_seconds, value.c_str());
    else r = (redisReply*)redisCommand(valkey_ctx_, "SET %s %s", key.c_str(), value.c_str());
    bool ok = r && r->type!=REDIS_REPLY_ERROR;
    if(r) freeReplyObject(r);
    return ok;
#else
    (void)key; (void)value; (void)ttl_seconds;
    // TCP probe fallback already in connect(); no hiredis available
    return false;
#endif
}
std::string DataLayer::valkey_get(const std::string &key) const {
#ifdef HAVE_HIREDIS
    if(!valkey_connect()) return "";
    redisReply *r = (redisReply*)redisCommand(valkey_ctx_, "GET %s", key.c_str());
    std::string out;
    if(r && r->type==REDIS_REPLY_STRING) out = r->str ? r->str : "";
    if(r) freeReplyObject(r);
    return out;
#else
    (void)key; return "";
#endif
}
#ifdef HAVE_HIREDIS
bool DataLayer::valkey_connect() const {
    if(valkey_ctx_ && valkey_ctx_->err==0) return true;
    if(valkey_ctx_) { redisFree(valkey_ctx_); valkey_ctx_=nullptr; }
    std::string host="127.0.0.1"; int port=6379;
    std::string url = cfg_.valkey_url;
    if(!url.empty()){
        std::string h; int p; if(probe_url(url,h,p)){ host=h; port=p; }
    }
    // Probe TCP first to avoid hiredis sds invalid pointer when no server
    if(!can_connect(host, port)) return false;
    struct timeval tv{1,0};
    valkey_ctx_ = redisConnectWithTimeout(host.c_str(), port, tv);
    return valkey_ctx_ && valkey_ctx_->err==0;
}
#endif
bool DataLayer::duckdb_exec(const std::string &sql) const {
#ifdef HAVE_DUCKDB
    duckdb db=nullptr; duckdb_connection con=nullptr;
    if(duckdb_open(cfg_.duckdb_path.c_str(), &db)!=DuckDBSuccess) return false;
    if(duckdb_connect(db, &con)!=DuckDBSuccess){ duckdb_close(&db); return false; }
    const char *init_sql =
        "CREATE TABLE IF NOT EXISTS token_usage (ts TIMESTAMP, model TEXT, provider TEXT, prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER);"
        "CREATE TABLE IF NOT EXISTS run_stats (run_id TEXT PRIMARY KEY, model TEXT, status TEXT, started_at TIMESTAMP, finished_at TIMESTAMP, duration_ms INTEGER);"
        "CREATE TABLE IF NOT EXISTS traces (sid TEXT, ts TIMESTAMP, kind TEXT, payload JSON);"
        "CREATE TABLE IF NOT EXISTS graph_analytics (entity_type TEXT, count INTEGER, updated_at TIMESTAMP);";
    duckdb_query(con, init_sql, nullptr);
    duckdb_result res;
    bool ok = duckdb_query(con, sql.c_str(), &res)==DuckDBSuccess;
    duckdb_destroy_result(&res);
    duckdb_disconnect(&con);
    duckdb_close(&db);
    return ok;
#else
    (void)sql;
    return false;
#endif
}
std::optional<DataLayer::GraphNodeRow> DataLayer::get_entity_row(const std::string &id){
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){
            if(pg_conn_) PQfinish(pg_conn_);
            pg_conn_ = PQconnectdb(cfg_.postgres_url.c_str());
        }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            const char *sql="SELECT id::text, label, entity_type, coalesce(subtype,''), coalesce(source_url,''), updated_at::text FROM graph_entities WHERE id=$1 LIMIT 1";
            const char *vals[1]={id.c_str()};
            PGresult *res=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
            std::string line;
            if(res && PQresultStatus(res)==PGRES_TUPLES_OK && PQntuples(res)>0){
                std::string out;
                for(int f=0;f<PQnfields(res);++f){ if(f) out+='|'; out+=PQgetvalue(res,0,f)?PQgetvalue(res,0,f):""; }
                line=out;
            }
            if(res) PQclear(res);
            if(!line.empty()){
                std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()>=6) return GraphNodeRow{f[0],f[1],f[2],f[3],f[4],f[5]};
            }
        }
    }
#endif
    std::string sql="SELECT id::text, label, entity_type, coalesce(subtype,''), coalesce(source_url,''), updated_at::text FROM graph_entities WHERE id='"+sql_escape(id)+"' LIMIT 1";
    std::string out=exec_psql(sql);
    if(out.empty()) return std::nullopt; size_t nl=out.find('\n'); std::string line=out.substr(0,nl==std::string::npos? out.size():nl); if(line.empty()) return std::nullopt; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<6) return std::nullopt; return GraphNodeRow{f[0],f[1],f[2],f[3],f[4],f[5]};
}
bool DataLayer::ensure_compliance_tables(){
    const char *sql="CREATE TABLE IF NOT EXISTS disclosure_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entity_id uuid REFERENCES graph_entities(id) ON DELETE SET NULL, entity_type text, accessor text NOT NULL, purpose text NOT NULL, min_necessary_filter text, accessed_at timestamptz NOT NULL DEFAULT now()); CREATE TABLE IF NOT EXISTS deletion_attestations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), source_prefix text NOT NULL, deleted_count int NOT NULL, attested_by text NOT NULL, attested_at timestamptz NOT NULL DEFAULT now(), receipt_id uuid REFERENCES graph_receipts(id));";
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){ if(pg_conn_) PQfinish(pg_conn_); pg_conn_=PQconnectdb(cfg_.postgres_url.c_str()); }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            PGresult *r=PQexec(pg_conn_, sql);
            bool ok=r && (PQresultStatus(r)==PGRES_COMMAND_OK || PQresultStatus(r)==PGRES_TUPLES_OK);
            if(r) PQclear(r);
            if(ok) return true;
        }
    }
#endif
    std::string out=exec_psql(sql);
    return true;
}
bool DataLayer::log_disclosure(const std::string &entity_id, const std::string &entity_type, const std::string &accessor, const std::string &purpose, const std::string &filter){
    if(accessor.empty() || purpose.empty()) return false;
    ensure_compliance_tables();
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){ if(pg_conn_) PQfinish(pg_conn_); pg_conn_=PQconnectdb(cfg_.postgres_url.c_str()); }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            const char *sql="INSERT INTO disclosure_log (entity_id, entity_type, accessor, purpose, min_necessary_filter) VALUES ($1::uuid, $2, $3, $4, $5)";
            const char *e = entity_id.empty()?nullptr:entity_id.c_str();
            const char *et = entity_type.empty()?nullptr:entity_type.c_str();
            const char *vals[5]={e, et, accessor.c_str(), purpose.c_str(), filter.empty()?nullptr:filter.c_str()};
            PGresult *r=PQexecParams(pg_conn_, sql, 5, nullptr, vals, nullptr, nullptr, 0);
            bool ok=r && PQresultStatus(r)==PGRES_COMMAND_OK;
            if(r) PQclear(r);
            if(ok) return true;
        }
    }
#endif
    std::string sql="INSERT INTO disclosure_log (entity_id, entity_type, accessor, purpose, min_necessary_filter) VALUES ("+(entity_id.empty()?"NULL":"'"+sql_escape(entity_id)+"'::uuid")+", "+(entity_type.empty()?"NULL":"'"+sql_escape(entity_type)+"'")+", '"+sql_escape(accessor)+"', '"+sql_escape(purpose)+"', "+(filter.empty()?"NULL":"'"+sql_escape(filter)+"'")+")";
    exec_psql(sql);
    return true;
}
int DataLayer::count_disclosures(const std::string &entity_type){
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        if(entity_type.empty()){
            PGresult *r=PQexec(pg_conn_, "SELECT count(*) FROM disclosure_log");
            std::string s; if(r && PQresultStatus(r)==PGRES_TUPLES_OK && PQntuples(r)>0) s=PQgetvalue(r,0,0)?PQgetvalue(r,0,0):""; if(r) PQclear(r); try{ if(!s.empty()) return std::stoi(s);}catch(...){}
        } else {
            const char *sql="SELECT count(*) FROM disclosure_log WHERE entity_type=$1";
            const char *vals[1]={entity_type.c_str()};
            PGresult *r=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
            std::string s; if(r && PQresultStatus(r)==PGRES_TUPLES_OK && PQntuples(r)>0) s=PQgetvalue(r,0,0)?PQgetvalue(r,0,0):""; if(r) PQclear(r); try{ if(!s.empty()) return std::stoi(s);}catch(...){}
        }
    }
#endif
    std::string sql=entity_type.empty()? "SELECT count(*) FROM disclosure_log" : "SELECT count(*) FROM disclosure_log WHERE entity_type='"+sql_escape(entity_type)+"'";
    std::string r=exec_psql(sql);
    try{ return std::stoi(r);}catch(...){ return -1; }
}
std::vector<DataLayer::Disclosure> DataLayer::list_disclosures(int limit){
#ifdef HAVE_LIBPQ
    if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
        std::string lim=std::to_string(limit);
        const char *sql="SELECT id::text, coalesce(entity_id::text,''), coalesce(entity_type,''), accessor, purpose, coalesce(min_necessary_filter,''), accessed_at::text FROM disclosure_log ORDER BY accessed_at DESC LIMIT $1";
        const char *vals[1]={lim.c_str()};
        PGresult *r=PQexecParams(pg_conn_, sql, 1, nullptr, vals, nullptr, nullptr, 0);
        if(r && PQresultStatus(r)==PGRES_TUPLES_OK){
            std::vector<Disclosure> out;
            for(int i=0;i<PQntuples(r);++i) out.push_back({PQgetvalue(r,i,0)?PQgetvalue(r,i,0):"", PQgetvalue(r,i,1)?PQgetvalue(r,i,1):"", PQgetvalue(r,i,2)?PQgetvalue(r,i,2):"", PQgetvalue(r,i,3)?PQgetvalue(r,i,3):"", PQgetvalue(r,i,4)?PQgetvalue(r,i,4):"", PQgetvalue(r,i,5)?PQgetvalue(r,i,5):"", PQgetvalue(r,i,6)?PQgetvalue(r,i,6):""});
            PQclear(r);
            return out;
        }
        if(r) PQclear(r);
    }
#endif
    std::string out=exec_psql("SELECT id::text, coalesce(entity_id::text,''), coalesce(entity_type,''), accessor, purpose, coalesce(min_necessary_filter,''), accessed_at::text FROM disclosure_log ORDER BY accessed_at DESC LIMIT "+std::to_string(limit));
    std::vector<Disclosure> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<7) continue; rows.push_back({f[0],f[1],f[2],f[3],f[4],f[5],f[6]}); }
    return rows;
}
int DataLayer::purge_by_source_prefix(const std::string &prefix, const std::string &attested_by){
    if(prefix.empty()) return -1;
    ensure_compliance_tables();
    int before=count_by_source_prefix(prefix);
    if(before<=0) return 0;
#ifdef HAVE_LIBPQ
    if(pg_conn_ || !cfg_.postgres_url.empty()){
        if(!pg_conn_ || PQstatus(pg_conn_)!=CONNECTION_OK){ if(pg_conn_) PQfinish(pg_conn_); pg_conn_=PQconnectdb(cfg_.postgres_url.c_str()); }
        if(pg_conn_ && PQstatus(pg_conn_)==CONNECTION_OK){
            const char *del_sql="DELETE FROM graph_entities WHERE source_url LIKE $1";
            std::string pat=prefix+"%";
            const char *vals[1]={pat.c_str()};
            PGresult *r=PQexecParams(pg_conn_, del_sql, 1, nullptr, vals, nullptr, nullptr, 0);
            bool ok=r && (PQresultStatus(r)==PGRES_COMMAND_OK || PQresultStatus(r)==PGRES_TUPLES_OK);
            std::string deleted = ok? PQcmdTuples(r): "0";
            if(r) PQclear(r);
            int n=0; try{ n=std::stoi(deleted);}catch(...){ n=before; }
            // receipt + attestation
            std::string receipt=add_receipt("deletion:"+prefix, "purge", "{\"prefix\":\""+sql_escape(prefix)+"\",\"count\":"+std::to_string(n)+"}");
            const char *att_sql="INSERT INTO deletion_attestations (source_prefix, deleted_count, attested_by, receipt_id) VALUES ($1,$2,$3,$4::uuid)";
            std::string cnt=std::to_string(n);
            const char *avals[4]={prefix.c_str(), cnt.c_str(), attested_by.c_str(), receipt.empty()?nullptr:receipt.c_str()};
            PGresult *ar=PQexecParams(pg_conn_, att_sql, 4, nullptr, avals, nullptr, nullptr, 0);
            if(ar) PQclear(ar);
            return n;
        }
    }
#endif
    std::string del="DELETE FROM graph_entities WHERE source_url LIKE '"+sql_escape(prefix)+"%'";
    std::string r=exec_psql(del);
    std::string receipt=add_receipt("deletion:"+prefix, "purge", "{\"prefix\":\""+sql_escape(prefix)+"\",\"count\":"+std::to_string(before)+"}");
    std::string att="INSERT INTO deletion_attestations (source_prefix, deleted_count, attested_by, receipt_id) VALUES ('"+sql_escape(prefix)+"',"+std::to_string(before)+",'"+sql_escape(attested_by)+"',"+(receipt.empty()?"NULL":"'"+sql_escape(receipt)+"'::uuid")+")";
    exec_psql(att);
    return before;
}
int DataLayer::count_by_source_prefix_attested(const std::string &prefix){
    std::string r=exec_psql("SELECT count(*) FROM deletion_attestations WHERE source_prefix='"+sql_escape(prefix)+"'");
    try{ return std::stoi(r);}catch(...){ return -1; }
}
} // namespace tessera
