#include "../src/llama-graph.h"

// This project's default CMake build is Release (-DNDEBUG), which compiles
// a plain assert() to nothing - the checks below would silently never run.
// Force live assertions the same way tests/test-tessera-config.cpp does:
// undef NDEBUG and re-include <cassert> so its macro re-expands to the
// checking form regardless of the command-line -DNDEBUG.
#undef NDEBUG
#include <cassert>

int main() {
    // Graph reuse is safe while the observer selection is unchanged.  A
    // progressive freeze/probe transition changes graph topology, however,
    // and must force the context to rebuild it.  Each scope owns an
    // independent epoch so a transition in any bucket (verifier, MTP, DFlash,
    // DSpark, or TALKER) invalidates the cached topology.
    llm_graph_params previous{};
    llm_graph_params current{};

    assert(previous.allow_reuse(current));

    // A transition in any non-verifier scope invalidates reuse even when the
    // other scopes are unchanged. Walk all scopes and verify each one
    // independently breaks reuse, then restores it when previous catches up.
    const int scopes[] = {
        LLAMA_OBSERVER_SCOPE_VERIFIER,
        LLAMA_OBSERVER_SCOPE_MTP,
        LLAMA_OBSERVER_SCOPE_DFLASH,
        LLAMA_OBSERVER_SCOPE_DSPARK,
        LLAMA_OBSERVER_SCOPE_TALKER,
    };
    for (int s : scopes) {
        current.cparams.imatrix_observer_epoch[s] += 1;
        assert(!previous.allow_reuse(current));
        previous.cparams.imatrix_observer_epoch[s] = current.cparams.imatrix_observer_epoch[s];
        assert(previous.allow_reuse(current));
    }

    return 0;
}
