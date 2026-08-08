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
    // Real probe: if url set, try TCP; if empty, try localhost defaults
    std::string pg_url = cfg_.postgres_url;
    std::string vk_url = cfg_.valkey_url;
    if(pg_url.empty() && can_connect("127.0.0.1",5432)) pg_url = "postgres://tessera:tessera@127.0.0.1:5432/tessera";
    if(vk_url.empty() && can_connect("127.0.0.1",6379)) vk_url = "valkey://127.0.0.1:6379";
    // update cfg_ so from_env probing is sticky
    cfg_.postgres_url = pg_url; cfg_.valkey_url = vk_url;
    bool pg_ok=false, cache_ok=false;
    if(!pg_url.empty()){
        std::string h; int p; if(probe_url(pg_url,h,p)) pg_ok = can_connect(h,p);
        else pg_ok = true;
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
std::string DataLayer::exec_psql(const std::string &sql) const {
    // Hexagonal: surfaces call DataLayer, which shells to podman exec psql (host has no psql binary, daemons run in podman)
    // Escape double quotes and backslashes for the outer -c "..." shell arg; sql_escape already handled single quotes for SQL
    std::string esc_sql; esc_sql.reserve(sql.size()*2);
    for(char c: sql){ if(c=='\\') esc_sql+="\\\\"; else if(c=='"') esc_sql+="\\\""; else if(c=='$') esc_sql+="\\$"; else if(c=='`') esc_sql+="\\`"; else esc_sql+=c; }
    std::string cmd = "podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -c \"" + esc_sql + "\" 2>/dev/null";
    // escape quotes in sql (simple: replace \" with \\\")
    std::array<char,256> buf; std::string out;
    FILE *p = popen(cmd.c_str(), "r");
    if(!p) return "";
    while(fgets(buf.data(), buf.size(), p)) out += buf.data();
    pclose(p);
    // psql -t -A prints command tag "INSERT 0 1" on second line for INSERT ... RETURNING; take first non-empty line only
    size_t nl = out.find('\n');
    if(nl != std::string::npos) out = out.substr(0, nl);
    // trim
    while(!out.empty() && (out.back()=='\n' || out.back()=='\r' || out.back()==' ')) out.pop_back();
    while(!out.empty() && out.front()==' ') out.erase(out.begin());
    return out;
}
int DataLayer::count_entities(const std::string &entity_type){
    std::string sql = entity_type.empty() ? "SELECT count(*) FROM graph_entities" : "SELECT count(*) FROM graph_entities WHERE entity_type='" + entity_type + "'";
    std::string r = exec_psql(sql);
    try{ return std::stoi(r); } catch(...){ return -1; }
}
std::vector<NoteRow> DataLayer::list_notes(int limit){
    std::string sql = "SELECT id::text, label, coalesce(body,'') FROM graph_entities WHERE entity_type='note' ORDER BY created_at DESC LIMIT " + std::to_string(limit);
    std::string raw = exec_psql(sql + " | tr '\\n' '\\r'"); // keep simple, use psql -A with |
    // Use a more structured query with delimiter
    std::string cmd = "podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -F '|' -c \"" + sql + "\" 2>/dev/null";
    std::array<char,1024> buf; std::string out;
    FILE *p = popen(cmd.c_str(), "r");
    if(!p) return {};
    while(fgets(buf.data(), buf.size(), p)) out += buf.data();
    pclose(p);
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
    std::string sql = "INSERT INTO graph_entities (entity_type,label,body,subtype,source_url) VALUES ('" + sql_escape(entity_type) + "','" + sql_escape(label) + "','" + sql_escape(body) + "'," + (subtype.empty()?"NULL":"'"+sql_escape(subtype)+"'") + "," + (source_url.empty()?"NULL":"'"+sql_escape(source_url)+"'") + ") RETURNING id::text";
    return exec_psql(sql);
}
std::string DataLayer::create_note(const std::string &label, const std::string &body){ return insert_entity("note", label, body); }
std::string DataLayer::add_receipt(const std::string &entity_id, const std::string &receipt_type, const std::string &payload_json){
    std::string esc_payload = sql_escape(payload_json.empty()?"{}":payload_json);
    std::string sql = "INSERT INTO graph_receipts (entity_id, receipt_type, payload) VALUES ('" + sql_escape(entity_id) + "','" + sql_escape(receipt_type) + "','" + esc_payload + "'::jsonb) RETURNING id::text";
    std::string receipt_id = exec_psql(sql);
    if(receipt_id.empty()) return "";
    std::string idx_sql = "SELECT coalesce(max(chain_index),-1)+1 FROM receipt_chain WHERE document_id='" + sql_escape(entity_id) + "'";
    std::string next_idx = exec_psql(idx_sql);
    if(next_idx.empty()) next_idx="0";
    std::string chain_sql = "INSERT INTO receipt_chain (document_id, chain_index, receipt_id) VALUES ('" + sql_escape(entity_id) + "'," + next_idx + ",'" + sql_escape(receipt_id) + "') RETURNING chain_index";
    exec_psql(chain_sql);
    return receipt_id;
}
int DataLayer::receipt_chain_length(const std::string &document_id){
    std::string r = exec_psql("SELECT count(*) FROM receipt_chain WHERE document_id='" + sql_escape(document_id) + "'");
    try{ return std::stoi(r);} catch(...){ return -1; }
}
bool DataLayer::verify_chain(const std::string &document_id){
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
    std::string r=exec_psql("SELECT id::text FROM graph_entities WHERE source_url='" + sql_escape(source_url) + "' LIMIT 1");
    if(r.empty() || r.find('-')==std::string::npos) return std::nullopt;
    return r;
}
std::vector<NoteRow> DataLayer::list_by_type(const std::string &entity_type, int limit){
    std::string sql="SELECT id::text, label, coalesce(body,'') FROM graph_entities WHERE entity_type='"+sql_escape(entity_type)+"' ORDER BY created_at DESC LIMIT "+std::to_string(limit);
    std::string cmd="podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -F '|' -c \""+sql+"\" 2>/dev/null";
    std::array<char,1024> buf; std::string out; FILE *p=popen(cmd.c_str(),"r"); if(!p) return {};
    while(fgets(buf.data(), buf.size(), p)) out+=buf.data(); pclose(p);
    std::vector<NoteRow> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; size_t p1=line.find('|'); size_t p2=line.find('|',p1+1); if(p1==std::string::npos||p2==std::string::npos) continue; rows.push_back({line.substr(0,p1), line.substr(p1+1,p2-p1-1), line.substr(p2+1)}); }
    return rows;
}
bool DataLayer::ensure_link(const std::string &source_id, const std::string &target_id, const std::string &link_type, float weight){
    if(source_id.empty()||target_id.empty()||link_type.empty()) return false;
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
    std::string sql="SELECT id::text, label, entity_type, coalesce(subtype,''), coalesce(source_url,''), updated_at::text FROM graph_entities ORDER BY updated_at DESC LIMIT "+std::to_string(limit);
    std::string cmd="podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -F '|' -c \""+sql+"\" 2>/dev/null";
    std::array<char,1024> buf; std::string out; FILE *p=popen(cmd.c_str(),"r"); if(!p) return {};
    while(fgets(buf.data(), buf.size(), p)) out+=buf.data(); pclose(p);
    std::vector<GraphNodeRow> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<6) continue; rows.push_back({f[0],f[1],f[2],f[3],f[4],f[5]}); }
    return rows;
}
std::vector<DataLayer::GraphEdgeRow> DataLayer::list_graph_edges(int limit){
    std::string sql="SELECT id::text, source_id::text, target_id::text, link_type, weight FROM entity_links LIMIT "+std::to_string(limit);
    std::string cmd="podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -F '|' -c \""+sql+"\" 2>/dev/null";
    std::array<char,1024> buf; std::string out; FILE *p=popen(cmd.c_str(),"r"); if(!p) return {};
    while(fgets(buf.data(), buf.size(), p)) out+=buf.data(); pclose(p);
    std::vector<GraphEdgeRow> rows; size_t pos=0;
    while(pos<out.size()){ size_t nl=out.find('\n',pos); std::string line=out.substr(pos,nl==std::string::npos?std::string::npos:nl-pos); pos=nl==std::string::npos?out.size():nl+1; if(line.empty()) continue; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<5) continue; rows.push_back({f[0],f[1],f[2],f[3], (float)std::atof(f[4].c_str())}); }
    return rows;
}
std::optional<DataLayer::GraphNodeRow> DataLayer::get_entity_row(const std::string &id){
    std::string sql="SELECT id::text, label, entity_type, coalesce(subtype,''), coalesce(source_url,''), updated_at::text FROM graph_entities WHERE id='"+sql_escape(id)+"' LIMIT 1";
    std::string cmd="podman exec tessera-postgres psql -h 127.0.0.1 -U tessera -d tessera -t -A -F '|' -c \""+sql+"\" 2>/dev/null";
    std::array<char,1024> buf; std::string out; FILE *p=popen(cmd.c_str(),"r"); if(!p) return std::nullopt;
    while(fgets(buf.data(), buf.size(), p)) out+=buf.data(); pclose(p);
    if(out.empty()) return std::nullopt; size_t nl=out.find('\n'); std::string line=out.substr(0,nl==std::string::npos? out.size():nl); if(line.empty()) return std::nullopt; std::vector<std::string> f; size_t s=0; while(true){ size_t d=line.find('|',s); if(d==std::string::npos){ f.push_back(line.substr(s)); break;} f.push_back(line.substr(s,d-s)); s=d+1; } if(f.size()<6) return std::nullopt; return GraphNodeRow{f[0],f[1],f[2],f[3],f[4],f[5]};
}
} // namespace tessera
