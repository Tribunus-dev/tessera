#pragma once

#include "llama.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

inline constexpr const char * LLM_KV_IMATRIX_DATASETS    = "imatrix.datasets";
inline constexpr const char * LLM_KV_IMATRIX_CHUNK_COUNT = "imatrix.chunk_count";
inline constexpr const char * LLM_KV_IMATRIX_CHUNK_SIZE  = "imatrix.chunk_size";

struct common_imatrix_entry {
    std::vector<float>   sums;
    std::vector<float>   abs_sums;
    std::vector<float>   fourth_sums;
    std::vector<float>   max_abs;
    std::vector<int64_t> counts;
};

struct common_imatrix {
    std::map<std::string, common_imatrix_entry> entries;
    std::vector<std::string> datasets;
    int32_t chunk_count    = 0;
    int32_t chunk_size     = 0;
    bool    is_legacy      = false;
    bool    has_metadata   = false;
};

bool common_imatrix_load(const std::string & fname, common_imatrix & imatrix);

// On-disk tensor-name prefix for each observer scope. VERIFIER is the bare
// name (unchanged on-disk contract); drafter/talker scopes are tagged so the
// ledgers do not collide when multiple components collect into one imatrix
// file. Includes the trailing dot for non-verifier scopes (empty for verifier)
// so callers can concatenate directly: prefix + tensor_name.
inline std::string common_imatrix_scope_prefix(enum llama_observer_scope scope) {
    switch (scope) {
        case LLAMA_OBSERVER_SCOPE_VERIFIER: return "";
        case LLAMA_OBSERVER_SCOPE_MTP:      return "dft.mtp.";
        case LLAMA_OBSERVER_SCOPE_DFLASH:   return "dft.dflash.";
        case LLAMA_OBSERVER_SCOPE_DSPARK:   return "dft.dspark.";
        case LLAMA_OBSERVER_SCOPE_TALKER:   return "dft.talker.";
    }
    return "";
}

// Inverse of common_imatrix_scope_prefix: recover the (scope, stripped_name)
// pair from an on-disk tensor name. Recognises every per-scope tag; names
// without a tag are VERIFIER. A legacy bare "dft." tag (pre-multi-scope) maps
// to MTP with a one-time warning.
inline enum llama_observer_scope common_imatrix_scope_from_name(const std::string & full,
                                                                std::string & stripped_name) {
    static const struct { const char * tag; enum llama_observer_scope scope; } table[] = {
        { "dft.mtp.",    LLAMA_OBSERVER_SCOPE_MTP    },
        { "dft.dflash.", LLAMA_OBSERVER_SCOPE_DFLASH },
        { "dft.dspark.", LLAMA_OBSERVER_SCOPE_DSPARK },
        { "dft.talker.", LLAMA_OBSERVER_SCOPE_TALKER },
    };
    for (const auto & e : table) {
        const size_t n = strlen(e.tag);
        if (full.compare(0, n, e.tag) == 0) {
            stripped_name = full.substr(n);
            return e.scope;
        }
    }
    // Legacy bare "dft." (no subtag) -> treat as MTP, warn once.
    static const std::string k_legacy = "dft.";
    if (full.size() > k_legacy.size() && full.compare(0, k_legacy.size(), k_legacy) == 0) {
        static std::once_flag once;
        std::call_once(once, [&] {
            fprintf(stderr, "%s: legacy bare 'dft.' imatrix tag found; mapping to MTP scope\n", "common_imatrix");
        });
        stripped_name = full.substr(k_legacy.size());
        return LLAMA_OBSERVER_SCOPE_MTP;
    }
    stripped_name = full;
    return LLAMA_OBSERVER_SCOPE_VERIFIER;
}
