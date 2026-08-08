#include "SlideStore.h"
#include <chrono>
#include <ctime>
namespace tessera {
static std::string nowS2(){ auto t=std::chrono::system_clock::now(); std::time_t tt=std::chrono::system_clock::to_time_t(t); char b[32]; std::strftime(b,sizeof(b),"%Y-%m-%dT%H:%M:%SZ", std::gmtime(&tt)); return b; }
SlideDeck SlideStore::upsert(const SlideDeck& d){ SlideDeck n=d; if(n.id.empty()) n.id="slide-"+std::to_string(rand()); n.updatedAt=nowS2(); if(n.createdAt.empty()) n.createdAt=n.updatedAt; if(dl_ && dl_->is_connected()) dl_->insert_entity("document", n.displayTitle(), n.body, "slide", n.id); for(auto &c: cache_) if(c.id==n.id){c=n; appendReceipt(n.id, SlideReceiptType::upsert, "{}"); return n;} cache_.push_back(n); appendReceipt(n.id, SlideReceiptType::upsert, "{}"); return n; }
std::vector<SlideDeck> SlideStore::list(int lim){ if(cache_.empty()){ SlideDeck a; a.id="deck-1"; a.title="Roadmap 2026"; a.body="{\"deck\":[]}"; cache_.push_back(a);} std::vector<SlideDeck> out; for(size_t i=0;i<cache_.size() && (int)i<lim;i++) out.push_back(cache_[i]); return out; }
SlideDeck* SlideStore::get(const std::string& id){ for(auto &c: cache_) if(c.id==id) return &c; return nullptr; }
void SlideStore::appendReceipt(const std::string& id, SlideReceiptType t, const std::string& p){ if(dl_ && dl_->is_connected()) dl_->add_receipt(id, slideReceiptTypeString(t), p); }
} // namespace tessera
