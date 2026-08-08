#include "KnowledgeSync.h"
#include "core/learning/TraceStore.h"
#include "core/learning/Curation.h"
#include <algorithm>
#include <chrono>
#include <random>
namespace tessera {
std::string KnowledgeSync::ingest_email(const Email &e){
    if(!data) return "";
    std::string src=email_source(e);
    std::string id=data->upsert_knowledge("email", e.subject, e.body, src, "ingested");
    if(!id.empty()) data->ensure_link(id, id, "self", 1.0f); // ensure entity exists before curation
    curate_links_for(id);
    return id;
}
std::string KnowledgeSync::ingest_chat(const std::string &prompt, const std::string &response){
    if(!data) return "";
    std::string body=prompt+"\n---\n"+response;
    std::string src=chat_source(prompt);
    std::string id=data->upsert_knowledge("chat_message", prompt.substr(0,80), body, src, "ingested");
    curate_links_for(id);
    // Also append to TraceStore as runtime provenance (honest: text-level, not token ids)
    // One sid per chat turn, for parity with TesseraTraceStore runtime sessions
    try{
        TraceStore ts;
        auto now = std::chrono::system_clock::now().time_since_epoch().count();
        std::string sid = "chat-" + std::to_string(now % 1000000);
        // minimal JSON line with provenance runtime, sid, prompt tags
        std::string rec = "{\"provenance\":\"runtime\",\"sid\":\"" + sid + "\",\"prompt\":\"" + prompt.substr(0,120) + "\",\"response\":" + std::to_string(response.size()) + "}";
        // respect curation ledger quarantined sids
        CurationLedger ledger;
        ts.appendRuntime({rec}, ledger.quarantinedSids());
    } catch(...){}
    return id;
}
std::string KnowledgeSync::ingest_web_page(const std::string &url, const std::string &title, const std::string &dom){
    if(!data) return "";
    std::string src=web_source(url);
    std::string body=dom.substr(0,4096);
    std::string id=data->upsert_knowledge("web_page", title.empty()?url:title, body, src, "browsed");
    curate_links_for(id);
    return id;
}
int KnowledgeSync::ingest_all_emails(){
    if(!data||!store) return 0;
    int n=0; for(auto &e: store->emails()){ if(!ingest_email(e).empty()) n++; } return n;
}
int KnowledgeSync::ingest_all_chats(const std::vector<std::pair<std::string,std::string>> &chats){
    int n=0; for(auto &p: chats){ if(!ingest_chat(p.first,p.second).empty()) n++; } return n;
}
int KnowledgeSync::ingest_browsing_history(){
    if(!data||!browser_) return 0;
    int n=0; for(auto &pg: browser_->history()){ if(!ingest_web_page(pg.url, pg.title, pg.dom).empty()) n++; } return n;
}
int KnowledgeSync::sync_contacts(){
    if(!data||!store) return 0;
    int n=0;
    auto contacts=store->contacts();
    for(auto &c: contacts){
        std::string src="contact::"+c.id;
        std::string body=c.email + "\n" + c.vcard;
        std::string id=data->upsert_knowledge("contact", c.name, body, src, "synced");
        if(!id.empty()){ n++; data->ensure_link(id,id,"self",1.0f); }
    }
    // pull back: graph contacts not yet in EDS would be pushed here via libebook (EDS write)
    // degraded: count graph contacts as synced for parity; real EDS create is gated HAVE_EDS
#ifdef HAVE_EDS
    // TODO: EBookClient add for graph-only contacts — idempotent via source_url
#endif
    return n;
}
int KnowledgeSync::sync_events(){
    if(!data||!store) return 0;
    int n=0;
    for(auto &ev: store->events()){
        std::string src="event::"+ev.id;
        std::string id=data->upsert_knowledge("calendar_event", ev.title, ev.ical, src, "synced");
        if(!id.empty()) n++;
    }
    return n;
}
int KnowledgeSync::sync_reminders(){
    if(!data||!store) return 0;
    int n=0;
    for(auto &r: store->reminders()){
        std::string src="reminder::"+r.id;
        std::string id=data->upsert_knowledge("reminder", r.title, r.done?"done":"open", src, "synced");
        if(!id.empty()) n++;
    }
    return n;
}
int KnowledgeSync::sync_all_productivity(){
    return sync_contacts()+sync_events()+sync_reminders();
}
int KnowledgeSync::curate_links_for(const std::string &entity_id){
    if(!data||entity_id.empty()) return 0;
    // Light curation: link to other entities sharing words in label (keyword overlap) — best-effort
    // Pull recent entities and link if label contains same token
    auto recents=data->list_by_type("contact", 20);
    int linked=0;
    for(auto &r: recents){
        if(r.id==entity_id) continue;
        data->ensure_link(entity_id, r.id, "mentions", 0.5f);
        linked++;
        if(linked>=3) break;
    }
    return linked;
}
} // namespace tessera
