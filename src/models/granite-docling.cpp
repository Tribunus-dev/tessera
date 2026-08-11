#include "models.h"

// Granite Docling: SigLIP vision encoder + Idefics3 QFormer + text decoder.
// The text backbone loads via llama_model_granite's load_arch_hparams / load_arch_tensors
// (inherited). The vision encoder and QFormer are loaded as mmproj tensors.
// At runtime, vision features flow through the QFormer and are injected into the decoder.
// This file provides only the build_arch_graph dispatch.

std::unique_ptr<llm_graph_context> llama_model_granite_docling::build_arch_graph(
        const llm_graph_params & params) const {
    return std::make_unique<graph>(*this, params);
}
