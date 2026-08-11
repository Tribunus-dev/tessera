#include "models.h"

// Granite 4.1 Vision text decoder.
// The text backbone (blk.*, token_embd, output_norm) loads via llama_model_granite's
// load_arch_hparams / load_arch_tensors (inherited).
// The SigLIP vision encoder and 4-projector deepstack are handled by the mmproj tensor
// loaded via llama_model::load_tensors_from_mmproj.
// At runtime, deepstack injection at target layers is handled by llama_model_granite::graph
// via the deepstack_mapping_arr read from GGUF metadata (set_arch_hparams).
// This file provides only the build_arch_graph dispatch.

std::unique_ptr<llm_graph_context> llama_model_granite4vision::build_arch_graph(
        const llm_graph_params & params) const {
    return std::make_unique<graph>(*this, params);
}
