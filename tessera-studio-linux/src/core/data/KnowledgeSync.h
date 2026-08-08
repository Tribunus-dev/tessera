#pragma once
#include "data/DataLayer.h"
#include "productivity/Productivity.h"
#include "agent/tools/BrowserTool.h"
#include <string>
#include <vector>
namespace tessera {
// Bidirectional knowledge sync — agent populates graph_entities from emails/chats/web,
// and curates contacts/events/reminders both ways with system apps (EDS/libebook/libecal)
// Worker thread only, idempotent via source_url, receipt-chained
class KnowledgeSync{
public:
    KnowledgeSync(DataLayer *dl, ProductivityStore *ps, BrowserTool *browser=nullptr)
        : data(dl), store(ps), browser_(browser) {}
    // Ingest — each returns entity id (upserted)
    std::string ingest_email(const Email &email);
    std::string ingest_chat(const std::string &prompt, const std::string &response);
    std::string ingest_web_page(const std::string &url, const std::string &title, const std::string &dom);
    int ingest_all_emails();
    int ingest_all_chats(const std::vector<std::pair<std::string,std::string>> &chats);
    int ingest_browsing_history();
    // Productivity — bidirectional, EDS <-> graph_entities (contact/event/reminder)
    // Returns counts of newly synced entities
    int sync_contacts();
    int sync_events();
    int sync_reminders();
    int sync_all_productivity();
    // Curation — link related entities (person<->email, event<->contact)
    int curate_links_for(const std::string &entity_id);
private:
    DataLayer *data=nullptr;
    ProductivityStore *store=nullptr;
    BrowserTool *browser_=nullptr;
    std::string web_source(const std::string &url) const { return "web::"+url; }
    std::string email_source(const Email &e) const { return "email::"+e.id; }
    std::string chat_source(const std::string &prompt) const { return "chat::"+prompt.substr(0,64); }
};
} // namespace tessera
