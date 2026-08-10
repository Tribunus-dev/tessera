#pragma once
#include <string>
#include <filesystem>
#include <vector>

namespace tessera {

enum class ProviderType {
    Placeholder,
    RemoteApi,
    OnDevice,
};

bool is_non_us_cloud_provider(const std::string &id);
struct CloudProvider {
    std::string id;           // gsettings/libsecret key: openai, anthropic, google, meta, minimax, alibaba, openrouter, zai, glm, deepseek, generic
    std::string display_name; // "OpenAI"
    std::string base_url;     // OpenAI-compat base, e.g. https://api.openai.com/v1
    std::string default_model;
    std::string icon_name;    // symbolic icon
    std::string doc_url;
};

struct AppConfig {
    ProviderType provider = ProviderType::Placeholder;
    std::string remote_base_url = "http://localhost:8080";
    std::string cloud_provider = ""; // when provider==RemoteApi, which catalog id drives the loop (e.g. "openai")
    std::string cloud_model;         // model override for cloud provider
    std::string on_device_model_path;
    int on_device_gpu_layers = 0;
    int on_device_threads = 0;
    std::string cli_path_override;
};

AppConfig load_config();
void save_config(const AppConfig &cfg);

ProviderType provider_from_string(const std::string &s);
std::string provider_to_string(ProviderType p);

// Cloud catalog — intentional, not a bento grid: 11 cards with real base URLs
const std::vector<CloudProvider>& cloud_providers();
const CloudProvider* find_cloud_provider(const std::string &id);
std::string cloud_base_url_for(const std::string &id);

} // namespace tessera
