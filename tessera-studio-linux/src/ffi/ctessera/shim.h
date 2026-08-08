#pragma once
#include <string>

// Thin dlopen wrapper for libllama / libtessera-ffi
// Mirrors Sources/CLlama/cllama_shim.c + ffi/tessera_ffi.cpp

namespace tessera {

bool llama_shim_load(const std::string &lib_path = "");
void llama_shim_unload();
bool tess_ffi_load(const std::string &lib_path = "");
void tess_ffi_unload();

} // namespace tessera
