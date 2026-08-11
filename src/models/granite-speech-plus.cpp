#include "models.h"

// Granite Speech Plus: whisper-style audio encoder + text decoder.
// The text backbone loads via llama_model_granite's load_arch_hparams / load_arch_tensors
// (inherited). The audio encoder is loaded as mmproj tensors.
// At runtime, audio features are concatenated with text embeddings before the decoder.
// This file provides only the build_arch_graph dispatch.

std::unique_ptr<llm_graph_context> llama_model_granite_speech_plus::build_arch_graph(
        const llm_graph_params & params) const {
    return std::make_unique<graph>(*this, params);
}
