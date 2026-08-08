#include "Engine.h"
#include "../cli_resolver.h"
#include "../config.h"
#include "ffi/ctessera/shim.h"
#include <cstdlib>
#ifdef HAVE_GTK
#include <gio/gio.h>
#endif
namespace tessera {
LLMProvider* Engine::provider_for(const std::string &t){
    std::string type = t;
    auto cfg = load_config();
#ifdef HAVE_GTK
    // live GSettings overrides env/config (first-class Fedora persistence)
    if(GSettings *gs = g_settings_new("org.tessera.TesseraStudio")){
        char *p = g_settings_get_string(gs, "provider");
        char *cp = g_settings_get_string(gs, "cloud-provider");
        char *cm = g_settings_get_string(gs, "cloud-model");
        char *url = g_settings_get_string(gs, "remote-base-url");
        if(p && *p) { cfg.provider = provider_from_string(p); if(type.empty() || type=="placeholder") type = p; }
        if(cp) cfg.cloud_provider = cp;
        if(cm) cfg.cloud_model = cm;
        if(url) cfg.remote_base_url = url;
        g_free(p); g_free(cp); g_free(cm); g_free(url);
        g_object_unref(gs);
    }
#endif
    if(type.empty()){
        if(auto *e=getenv("TESSERA_PROVIDER")) type=e;
        else type = provider_to_string(cfg.provider);
    }
    if(type=="on_device"){
        std::string model; int gpu=0, thr=0;
        if(auto *m=getenv("TESSERA_MODEL")) model=m;
        else model = cfg.on_device_model_path;
        if(auto *g=getenv("TESSERA_GPU_LAYERS")) gpu=atoi(g);
        else gpu = cfg.on_device_gpu_layers;
        if(auto *th=getenv("TESSERA_THREADS")) thr=atoi(th);
        else thr = cfg.on_device_threads;
        tess_ffi_load(""); llama_shim_load("");
        return make_provider_on_device(model, gpu, thr);
    }
    if(type=="remote_api"){
        // cloud catalog takes precedence when cloud_provider is set (drives agent loop)
        if(!cfg.cloud_provider.empty()){
            return make_provider_for_cloud(cfg.cloud_provider, cfg.cloud_model);
        }
        std::string url="http://localhost:8080";
        if(auto *u=getenv("TESSERA_REMOTE_URL")) url=u;
        else url = cfg.remote_base_url;
        std::string m; if(auto *mm=getenv("TESSERA_MODEL")) m=mm; else m=cfg.cloud_model;
        return make_provider_remote(url, m);
    }
    // also allow direct cloud id as type (e.g. "openai")
    if(find_cloud_provider(type)){
        return make_provider_for_cloud(type, cfg.cloud_model);
    }
    return make_provider_placeholder();
}
std::string Engine::cli_path() const { auto p=resolve_cli_binary(cli_override_); return p.string(); }
} // namespace tessera
