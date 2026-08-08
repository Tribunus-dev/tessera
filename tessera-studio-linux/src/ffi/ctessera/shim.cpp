#include "shim.h"
#include <dlfcn.h>

namespace tessera {

static void *g_llama = nullptr;
static void *g_ffi = nullptr;

bool llama_shim_load(const std::string &lib_path) {
    std::string p = lib_path.empty() ? "libllama.so" : lib_path;
    g_llama = dlopen(p.c_str(), RTLD_NOW | RTLD_LOCAL);
    return g_llama != nullptr;
}
void llama_shim_unload() { if (g_llama) { dlclose(g_llama); g_llama = nullptr; } }

bool tess_ffi_load(const std::string &lib_path) {
    std::string p = lib_path.empty() ? "libtessera-ffi.so" : lib_path;
    g_ffi = dlopen(p.c_str(), RTLD_NOW | RTLD_LOCAL);
    return g_ffi != nullptr;
}
void tess_ffi_unload() { if (g_ffi) { dlclose(g_ffi); g_ffi = nullptr; } }

} // namespace tessera
