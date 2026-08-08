#pragma once
#include <functional>
#include <string>

namespace tessera {

enum class ChatRole { User, Assistant, System, Sky };

struct ChatMessage {
    ChatRole role;
    std::string content;
};

using ChatChunkCallback = std::function<void(const std::string &delta, bool done)>;
using ChatErrorCallback = std::function<void(const std::string &error)>;

class LLMProvider {
public:
    virtual ~LLMProvider() = default;
    virtual void send(const std::string &prompt, ChatChunkCallback on_chunk, ChatErrorCallback on_error) = 0;
};

LLMProvider *make_provider_placeholder();
LLMProvider *make_provider_remote(const std::string &base_url, const std::string &model = "");
LLMProvider *make_provider_on_device(const std::string &model_path, int gpu_layers, int threads);
// Cloud catalog aware — resolves base_url + api key via SecretStore
LLMProvider *make_provider_for_cloud(const std::string &provider_id, const std::string &model_override = "");
std::string cloud_api_key(const std::string &provider_id);
bool store_cloud_api_key(const std::string &provider_id, const std::string &api_key);
bool has_cloud_api_key(const std::string &provider_id);

} // namespace tessera
