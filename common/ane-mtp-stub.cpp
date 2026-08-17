//
// ane-mtp-stub.cpp
//
// Non-Apple fallback for the ANE MTP / prefill API declared in ane-mtp.h.
// The real implementation (ane-mtp.mm) needs Core ML + the Apple Neural
// Engine and is only compiled when APPLE AND GGML_METAL. This stub keeps
// the symbols resolvable everywhere else: every entry point returns the
// header's documented "no ANE payload" value, and each caller already
// retains the ordinary backend path for exactly that case.
//

#include "ane-mtp.h"

common_ane_mtp_program_ptr common_ane_mtp_program_load(
        const std::string & /*gguf_path*/,
        uint32_t /*batch_hint*/) {
    return nullptr;
}

common_ane_prefill_program_ptr common_ane_prefill_program_load(
        const std::string & /*gguf_path*/,
        uint32_t /*sequence_hint*/) {
    return nullptr;
}

bool common_ane_prefill_manifest_load(
        const std::string & /*gguf_path*/,
        common_ane_prefill_manifest * /*manifest*/) {
    return false;
}

// 0 means the caller must retain the ordinary backend path.
uint32_t common_ane_prefill_select_bucket(
        const common_ane_prefill_manifest & /*manifest*/,
        uint32_t /*n_tokens*/) {
    return 0;
}

// false: no context mutation occurred; callers use the ordinary decode path.
bool common_ane_prefill_decode(
        const common_ane_prefill_program_ptr & /*program*/,
        const common_ane_prefill_manifest & /*manifest*/,
        struct llama_context * /*ctx*/,
        const struct llama_batch & /*batch*/,
        int32_t * /*result*/) {
    return false;
}
