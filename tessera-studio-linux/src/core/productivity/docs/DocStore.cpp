#include "DocStore.h"
#include <chrono>
#include <ctime>
#include <sstream>

namespace tessera {

static std::string now_iso(){
    auto t = std::chrono::system_clock::now();
    std::time_t tt = std::chrono::system_clock::to_time_t(t);
    char buf[32]; std::strftime(buf,sizeof(buf),"%Y-%m-%dT%H:%M:%SZ", std::gmtime(&tt));
    return buf;
}

Doc DocStore::upsert(const Doc& doc){
    Doc d = doc;
    if(d.id.empty()){
        char uid[37]; snprintf(uid,sizeof(uid),"%08x-%04x-%04x-%04x-%012x",
            rand(), rand()&0xffff, rand()&0xffff, rand()&0xffff, rand());
        d.id = uid;
    }
    d.updatedAt = now_iso();
    if(d.createdAt.empty()) d.createdAt = d.updatedAt;
    d.tags = Doc::normalizeTags(d.tags);
    // persist via DataLayer hexagonal API
    if(dl_ && dl_->is_connected()){
        std::string bodyJson = "{\"title\":\"" + d.title + "\",\"body\":" + (d.body.empty()?"\"\"":d.body) + "}";
        // graph_entities pattern: label is displayTitle, body is Doc JSON
        dl_->insert_entity("document", d.displayTitle(), bodyJson, "doc", d.id);
    }
    // upsert cache
    for(auto &c: cache_) if(c.id==d.id){ c=d; appendReceipt(d.id, DocReceiptType::upsert, "{\"title\":\""+d.title+"\"}"); return d; }
    cache_.push_back(d);
    appendReceipt(d.id, DocReceiptType::upsert, "{\"title\":\""+d.title+"\",\"tagCount\":"+std::to_string(d.tags.size())+"}");
    return d;
}

bool DocStore::trash(const std::string& id, bool trashed){ for(auto &c: cache_) if(c.id==id){ c.isTrashed=trashed; c.updatedAt=now_iso(); appendReceipt(id, DocReceiptType::trash, trashed?"true":"false"); return true; } return false; }
bool DocStore::archive(const std::string& id, bool a){ for(auto &c: cache_) if(c.id==id){ c.isArchived=a; c.updatedAt=now_iso(); appendReceipt(id, DocReceiptType::archive, a?"true":"false"); return true; } return false; }
bool DocStore::favorite(const std::string& id, bool f){ for(auto &c: cache_) if(c.id==id){ c.isFavorite=f; c.updatedAt=now_iso(); appendReceipt(id, DocReceiptType::favorite, f?"true":"false"); return true; } return false; }
bool DocStore::setTags(const std::string& id, const std::vector<std::string>& tags){ for(auto &c: cache_) if(c.id==id){ c.tags=Doc::normalizeTags(tags); c.updatedAt=now_iso(); appendReceipt(id, DocReceiptType::tag, "{\"tags\":"+std::to_string(c.tags.size())+"}"); return true; } return false; }
bool DocStore::link(const std::string& id, const std::string& targetId){ for(auto &c: cache_) if(c.id==id){ c.linkedEntityIDs.push_back(targetId); c.updatedAt=now_iso(); appendReceipt(id, DocReceiptType::link, targetId); return true; } return false; }

std::vector<Doc> DocStore::list(int limit){
    if(cache_.empty()){
        // seed demo if no live DB
        if(!dl_ || !dl_->is_connected()){
            Doc a; a.id="doc-1"; a.title="Q3 Review"; a.body="{\"blocks\":[]}"; a.tags={"q3","review"}; a.isFavorite=true;
            Doc b; b.id="doc-2"; b.title="Sprint planning"; b.body="{\"blocks\":[]}";
            cache_={a,b};
        }
    }
    std::vector<Doc> out; for(size_t i=0;i<cache_.size() && (int)i<limit;i++) out.push_back(cache_[i]);
    return out;
}
Doc* DocStore::get(const std::string& id){ for(auto &c: cache_) if(c.id==id) return &c; return nullptr; }

void DocStore::appendReceipt(const std::string& entityId, DocReceiptType type, const std::string& payloadJson){
    // constitutional receipt backbone: graph_receipts append
    if(dl_ && dl_->is_connected()){
        std::string rt = docReceiptTypeString(type);
        dl_->exec_psql("INSERT INTO graph_receipts (entity_id, receipt_type, payload) VALUES ('"+dl_->sql_escape(entityId)+"','"+rt+"','"+dl_->sql_escape(payloadJson)+"')");
    }
}

} // namespace tessera
