#include "SheetStore.h"
#include <chrono>
#include <ctime>
namespace tessera {
static std::string nowS(){ auto t=std::chrono::system_clock::now(); std::time_t tt=std::chrono::system_clock::to_time_t(t); char b[32]; std::strftime(b,sizeof(b),"%Y-%m-%dT%H:%M:%SZ", std::gmtime(&tt)); return b; }
Sheet SheetStore::upsert(const Sheet& s){ Sheet d=s; if(d.id.empty()) d.id="sheet-"+std::to_string(rand()); d.updatedAt=nowS(); if(d.createdAt.empty()) d.createdAt=d.updatedAt; if(dl_ && dl_->is_connected()) dl_->insert_entity("document", d.displayTitle(), d.body, "sheet", d.id); for(auto &c: cache_) if(c.id==d.id){c=d; appendReceipt(d.id, SheetReceiptType::upsert, "{}"); return d;} cache_.push_back(d); appendReceipt(d.id, SheetReceiptType::upsert, "{}"); return d; }
bool SheetStore::setCell(const std::string& id,int r,int c,const std::string& v){ for(auto &s: cache_) if(s.id==id){ appendReceipt(id, SheetReceiptType::cell, "{\"r\":"+std::to_string(r)+",\"c\":"+std::to_string(c)+"}"); return true; } return false; }
std::vector<Sheet> SheetStore::list(int lim){ if(cache_.empty()){ Sheet a; a.id="sheet-1"; a.title="Budget 2026"; a.body="{\"table\":[]}"; cache_.push_back(a);} std::vector<Sheet> out; for(size_t i=0;i<cache_.size() && (int)i<lim;i++) out.push_back(cache_[i]); return out; }
Sheet* SheetStore::get(const std::string& id){ for(auto &c: cache_) if(c.id==id) return &c; return nullptr; }
void SheetStore::appendReceipt(const std::string& id, SheetReceiptType t, const std::string& p){ if(dl_ && dl_->is_connected()) dl_->add_receipt(id, sheetReceiptTypeString(t), p); }
} // namespace tessera
