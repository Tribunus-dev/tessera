#pragma once
#include <string>
#include <vector>
#include <chrono>
#include <algorithm>
#include <cctype>

namespace tessera {

// Doc: Notion/Craft-style longform document, stored as graph_entity
// entity_type = "document", subtype = "doc". Mirrors Doc.swift.
struct Doc {
    static constexpr const char* entityType = "document";
    static constexpr const char* subtype = "doc";

    std::string id; // UUID string
    std::string title;
    std::string body; // DocumentAST JSON
    std::string coverImageURL;
    std::string iconEmoji;
    bool isArchived = false;
    bool isTrashed = false;
    bool isFavorite = false;
    std::vector<std::string> tags;
    std::vector<std::string> linkedEntityIDs;
    std::string createdAt;
    std::string updatedAt;

    std::string displayTitle() const {
        auto trim = [](std::string s){
            size_t a=0; while(a<s.size() && std::isspace((unsigned char)s[a])) a++;
            size_t b=s.size(); while(b>a && std::isspace((unsigned char)s[b-1])) b--;
            return s.substr(a,b-a);
        };
        std::string t = trim(title);
        if (!t.empty()) return t;
        return "Untitled";
    }
    int wordCount() const {
        if (body.empty()) return 0;
        int c=0; bool in=false;
        for(char ch: body){ bool sp=std::isspace((unsigned char)ch); if(!sp && !in){c++; in=true;} else if(sp) in=false; }
        return c;
    }
    static std::vector<std::string> normalizeTags(std::vector<std::string> in){
        std::vector<std::string> out;
        for(auto &t: in){
            std::string s; for(char c: t){ if(!std::isspace((unsigned char)c)) s+=std::tolower((unsigned char)c); else if(!s.empty() && s.back()!=' ') s+=' ';
            }
            size_t a=0; while(a<s.size() && s[a]==' ') a++;
            size_t b=s.size(); while(b>a && s[b-1]==' ') b--;
            s=s.substr(a,b-a);
            if(s.empty()) continue;
            if(std::find(out.begin(), out.end(), s)==out.end()) out.push_back(s);
        }
        return out;
    }
};

enum class DocReceiptType {
    upsert, body, archive, trash, favorite, tag, link
};

inline std::string docReceiptTypeString(DocReceiptType t){
    switch(t){
        case DocReceiptType::upsert: return "doc_upsert";
        case DocReceiptType::body: return "doc_body";
        case DocReceiptType::archive: return "doc_archive";
        case DocReceiptType::trash: return "doc_trash";
        case DocReceiptType::favorite: return "doc_favorite";
        case DocReceiptType::tag: return "doc_tag";
        case DocReceiptType::link: return "doc_link";
    }
    return "doc_upsert";
}

} // namespace tessera
