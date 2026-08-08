#include "config.h"
#include <cstdlib>

namespace tessera {

ProviderType provider_from_string(const std::string &s) {
    if (s == "remote_api") return ProviderType::RemoteApi;
    if (s == "on_device") return ProviderType::OnDevice;
    return ProviderType::Placeholder;
}

std::string provider_to_string(ProviderType p) {
    switch (p) {
        case ProviderType::RemoteApi: return "remote_api";
        case ProviderType::OnDevice: return "on_device";
        default: return "placeholder";
    }
}

const std::vector<CloudProvider>& cloud_providers(){
    static const std::vector<CloudProvider> cats = {
        {"openai",      "OpenAI",        "https://api.openai.com/v1",                          "gpt-4o-mini",            "network-server-symbolic", "https://platform.openai.com/docs"},
        {"anthropic",   "Anthropic",     "https://api.anthropic.com/v1",                       "claude-3-5-sonnet-20241022","chat-bubble-text-symbolic","https://docs.anthropic.com"},
        {"google",      "Google",        "https://generativelanguage.googleapis.com/v1beta",   "gemini-2.0-flash",       "globe-symbolic",          "https://ai.google.dev"},
        {"meta",        "Meta",          "https://api.llama.com/v1",                           "Llama-4-Maverick-17B",   "avatar-default-symbolic","https://www.llama.com/docs"},
        {"minimax",     "MiniMax",       "https://api.minimax.chat/v1",                        "MiniMax-Text-01",        "chat-bubble-text-symbolic","https://platform.minimaxi.com/document"},
        {"alibaba",     "Alibaba Cloud", "https://dashscope.aliyuncs.com/compatible-mode/v1",  "qwen-max",               "cloud-symbolic",          "https://www.alibabacloud.com/help/en/model-studio"},
        {"openrouter",  "OpenRouter",    "https://openrouter.ai/api/v1",                       "openrouter/auto",        "network-transmit-receive-symbolic","https://openrouter.ai/docs"},
        {"zai",         "Z.ai",          "https://api.z.ai/api/paas/v4",                       "glm-4-plus",             "starred-symbolic",        "https://docs.z.ai"},
        {"glm",         "GLM (Zhipu)",   "https://open.bigmodel.cn/api/paas/v4",               "glm-4-plus",             "starred-symbolic",        "https://open.bigmodel.cn/dev/api"},
        {"deepseek",    "DeepSeek",      "https://api.deepseek.com/v1",                        "deepseek-chat",          "cpu-symbolic",            "https://api-docs.deepseek.com"},
        {"generic",     "Generic",       "http://localhost:8080",                              "",                       "network-wired-symbolic",  ""},
    };
    return cats;
}
const CloudProvider* find_cloud_provider(const std::string &id){
    for(auto &c: cloud_providers()) if(c.id==id) return &c;
    return nullptr;
}
std::string cloud_base_url_for(const std::string &id){
    if(auto *c=find_cloud_provider(id)) return c->base_url;
    return "http://localhost:8080";
}

AppConfig load_config() {
    AppConfig cfg;
    if (const char *v = std::getenv("TESSERA_PROVIDER")) {
        cfg.provider = provider_from_string(v);
    }
    if (const char *v = std::getenv("TESSERA_REMOTE_URL")) {
        cfg.remote_base_url = v;
    }
    if (const char *v = std::getenv("TESSERA_CLOUD_PROVIDER")) {
        cfg.cloud_provider = v;
    }
    if (const char *v = std::getenv("TESSERA_CLOUD_MODEL")) {
        cfg.cloud_model = v;
    }
    if (const char *v = std::getenv("TESSERA_MODEL")) {
        cfg.on_device_model_path = v;
        if(cfg.cloud_model.empty()) cfg.cloud_model = v;
    }
    return cfg;
}

void save_config(const AppConfig &) {
    // Persist via GSettings when GTK available; stub for core-only build.
}

} // namespace tessera
