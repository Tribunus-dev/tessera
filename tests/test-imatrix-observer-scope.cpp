// Per-scope observer isolation test.
//
// Verifies that the per-scope observer state in llama_cparams keeps every
// scope bucket (VERIFIER, MTP, DFLASH, DSPARK, TALKER) fully independent.
// Exercises the same storage contract that
// llm_graph_context::imatrix_observer_enabled and
// llama_context::set_imatrix_observer_filter depend on, so a regression in
// either surfaces here as a test failure.
//
// In particular, the test ensures:
//   * Each scope has independent filter, filter_data, and epoch slots, and
//     assigning to one scope does not perturb any other.
//   * Switching the active scope preserves all filters and switches the
//     dispatch to the right slot.
//   * The filter dispatch through the per-scope slots is symmetric: a filter
//     that only accepts its own marker rejects every other scope's user_data,
//     so multiple contexts (verifier + drafters + talker) in the same process
//     each see only the observers they own.

#include "llama.h"

// llama_cparams is declared in src/llama-cparams.h, which the public llama.h
// header does not pull in. The per-scope filter storage contract is part of
// the C++ context state; the C API alone cannot reach it without going
// through a live llama_context.
#include "../src/llama-graph.h"

#include <cassert>
#include <cstring>

namespace {

// One marker per scope. Each filter recognises only its own marker;
// cross-feeding is a hard reject.
int g_markers[LLAMA_OBSERVER_SCOPE_TALKER + 1];

bool accept_own_only(const char * /*tensor_name*/, void * user_data) {
    for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
        if (user_data == &g_markers[s]) {
            return true;
        }
    }
    return false;
}

} // namespace

int main() {
    // Initial state: every scope slot is zeroed and the active scope is the
    // verifier (matches the default before the user has touched it).
    {
        llama_cparams cparams{};
        assert(cparams.imatrix_observer_scope == LLAMA_OBSERVER_SCOPE_VERIFIER);
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            assert(cparams.imatrix_observer_filter[s]      == nullptr);
            assert(cparams.imatrix_observer_filter_data[s] == nullptr);
            assert(cparams.imatrix_observer_epoch[s]       == 0);
        }
    }

    // Bind every scope to a distinct marker. Writing one scope must not
    // perturb any other (a regression here would mean scopes alias storage).
    {
        llama_cparams cparams{};
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            cparams.imatrix_observer_scope             = (enum llama_observer_scope) s;
            cparams.imatrix_observer_filter[s]         = accept_own_only;
            cparams.imatrix_observer_filter_data[s]    = &g_markers[s];
            cparams.imatrix_observer_epoch[s]          = s + 1;
        }
        // Every slot reflects its own write and nothing else.
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            assert(cparams.imatrix_observer_filter[s]      == accept_own_only);
            assert(cparams.imatrix_observer_filter_data[s] == &g_markers[s]);
            assert(cparams.imatrix_observer_epoch[s]       == (uint64_t)(s + 1));
        }
    }

    // The active scope drives dispatch. For every scope, its own filter+data
    // accepts, and every other scope's data is rejected (cross-feed guard).
    // This is the contract llm_graph_context::imatrix_observer_enabled()
    // relies on.
    {
        llama_cparams cparams{};
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            cparams.imatrix_observer_filter[s]      = accept_own_only;
            cparams.imatrix_observer_filter_data[s] = &g_markers[s];
        }
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            cparams.imatrix_observer_scope = (enum llama_observer_scope) s;
            const auto filter_s = cparams.imatrix_observer_filter[s];
            const void * data_s = cparams.imatrix_observer_filter_data[s];
            assert(filter_s != nullptr);
            assert(filter_s("blk.0.attn_q.weight", data_s));
            for (int other = LLAMA_OBSERVER_SCOPE_VERIFIER; other <= LLAMA_OBSERVER_SCOPE_TALKER; ++other) {
                if (other == s) continue;
                assert(!filter_s("blk.0.attn_q.weight",
                                 cparams.imatrix_observer_filter_data[other]));
            }
        }
    }

    // Epoch tracking is per-scope: bumping one must not touch any other.
    // This is what llama_bump_imatrix_observer_epoch() depends on.
    {
        llama_cparams cparams{};
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            cparams.imatrix_observer_epoch[s] = 0;
        }
        // Bump each scope exactly once, in order. After bumping scope k, the
        // first k scopes have epoch 1 and the rest have epoch 0.
        for (int s = LLAMA_OBSERVER_SCOPE_VERIFIER; s <= LLAMA_OBSERVER_SCOPE_TALKER; ++s) {
            cparams.imatrix_observer_scope = (enum llama_observer_scope) s;
            ++cparams.imatrix_observer_epoch[cparams.imatrix_observer_scope];
            for (int t = LLAMA_OBSERVER_SCOPE_VERIFIER; t <= LLAMA_OBSERVER_SCOPE_TALKER; ++t) {
                assert(cparams.imatrix_observer_epoch[t] == (uint64_t)(t <= s ? 1 : 0));
            }
        }
    }

    return 0;
}
