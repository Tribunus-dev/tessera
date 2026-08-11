//
// ggml-metal-event.mm
//
// (empty)
//
// The MTLSharedEvent implementation has moved to
// ggml-mtl-shared-events.mm, which is compiled into the SHARED
// library `ggml-mtl-shared-events`. That shared lib is the canonical
// home for the ggml_mtl_shared_event_* symbols so that BOTH
// ggml-metal (a MODULE_LIBRARY loaded at runtime) and llama-common
// (linked directly) can call them without duplicating the
// definitions.
//
// This file is kept as an empty stub so any historical references
// (in docs, commit messages, or older CMake) remain resolvable; it
// is not compiled into any target.
//
