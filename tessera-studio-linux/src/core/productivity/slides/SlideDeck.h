#pragma once
#include <string>
#include <vector>
namespace tessera {
enum class SlideLayout { title, titleAndContent, image, blank };
struct Slide { std::string id, title, body; int index=0; SlideLayout layout=SlideLayout::titleAndContent; std::string notes; };
struct SlideDeck {
    static constexpr const char* entityType = "document";
    static constexpr const char* subtype = "slide";
    std::string id, title, body; // body is canonical DocumentAST
    std::vector<Slide> slidesCache;
    bool isArchived=false, isTrashed=false, isFavorite=false;
    std::vector<std::string> tags, linkedEntityIDs;
    std::string createdAt, updatedAt;
    std::string displayTitle() const { return title.empty()?"Untitled Deck":title; }
    std::vector<Slide> slides() const {
        if(!slidesCache.empty()) return slidesCache;
        // derive one slide per deck if empty
        Slide s; s.id=id+"-s0"; s.title=title; s.body=body; s.index=0; return {s};
    }
};
enum class SlideReceiptType { upsert, slide, layout, archive, trash, favorite, tag, link };
inline std::string slideReceiptTypeString(SlideReceiptType t){
    switch(t){ case SlideReceiptType::upsert: return "slide_upsert"; case SlideReceiptType::slide: return "slide_edit"; case SlideReceiptType::layout: return "slide_layout"; case SlideReceiptType::archive: return "slide_archive"; case SlideReceiptType::trash: return "slide_trash"; case SlideReceiptType::favorite: return "slide_favorite"; case SlideReceiptType::tag: return "slide_tag"; case SlideReceiptType::link: return "slide_link"; } return "slide_upsert";
}
} // namespace tessera
