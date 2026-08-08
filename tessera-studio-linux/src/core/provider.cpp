#include "provider.h"
#include "config.h"
#include "agent/Agent.h"
#include "encryption/Secrets.h"
#include <thread>
#include <chrono>
#include <sstream>
#include <cstdlib>

#ifdef HAVE_LIBSOUP
#include <libsoup/soup.h>
#endif

namespace tessera {

class PlaceholderProvider : public LLMProvider {
public:
    void send(const std::string &prompt, ChatChunkCallback on_chunk, ChatErrorCallback) override {
        std::string reply = "[placeholder] echo: " + prompt;
        for (size_t i = 0; i < reply.size(); i += 16) {
            on_chunk(reply.substr(i, 16), false);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        on_chunk("", true);
    }
};

LLMProvider *make_provider_placeholder() {
    return new PlaceholderProvider();
}

std::string cloud_api_key(const std::string &provider_id){
    if(provider_id.empty()) return "";
    SecretStore ss; return ss.load("tessera", "apikey-" + provider_id);
}
bool store_cloud_api_key(const std::string &provider_id, const std::string &api_key){
    if(provider_id.empty()) return false;
    SecretStore ss;
    if(api_key.empty()) return ss.remove("tessera", "apikey-" + provider_id);
    return ss.store("tessera", "apikey-" + provider_id, api_key);
}
bool has_cloud_api_key(const std::string &provider_id){
    return !cloud_api_key(provider_id).empty();
}

#ifdef HAVE_LIBSOUP
class RemoteStreamingProvider : public LLMProvider {
public:
    RemoteStreamingProvider(std::string base_url, std::string model, std::string api_key, std::string provider_id)
        : base_url_(std::move(base_url)), model_(std::move(model)), api_key_(std::move(api_key)), provider_id_(std::move(provider_id)) {}
    void send(const std::string &prompt, ChatChunkCallback on_chunk, ChatErrorCallback on_error) override {
        if(api_key_.empty()){
            // no key — fall back to placeholder with hint
            std::string hint = "[no API key for " + provider_id_ + "] prompt: " + prompt;
            on_chunk(hint, false); on_chunk("", true); return;
        }
        // Build OpenAI-compat payload
        std::string url = base_url_;
        if(url.back()=='/') url.pop_back();
        // Anthropic uses /v1/messages not /v1/chat/completions — translate to compat via openai shape for now
        // OpenRouter/Alibaba/Z.ai/DeepSeek all speak OpenAI compat at /v1/chat/completions
        if(provider_id_!="anthropic" && provider_id_!="google"){
            if(url.find("/chat/completions")==std::string::npos) url += "/chat/completions";
        } else if(provider_id_=="anthropic"){
            // Anthropic native: https://api.anthropic.com/v1/messages — keep openai compat via openrouter fallback? use messages endpoint
            url = "https://api.anthropic.com/v1/messages";
        } else if(provider_id_=="google"){
            url += "/models/" + (model_.empty()?"gemini-2.0-flash":model_) + ":streamGenerateContent?key=" + api_key_;
        }
        SoupSession *session = soup_session_new();
        soup_session_set_timeout(session, 30);
        std::string body;
        // Sky is cloud-only, Tessy is local — distinct system prompts
        bool is_sky = (provider_id_!="generic" && find_cloud_provider(provider_id_) != nullptr);
        const std::string sys = is_sky ? std::string(SKY_SYSTEM_PROMPT) : std::string(TESSY_SYSTEM_PROMPT);
        if(provider_id_=="google"){
            body = "{\"contents\":[{\"parts\":[{\"text\":\"" + json_escape(sys + "\\n\\n" + prompt) + "\"}]}]}";
        } else if(provider_id_=="anthropic"){
            body = "{\"model\":\"" + json_escape(model_.empty()?"claude-3-5-sonnet-20241022":model_) + "\",\"max_tokens\":1024,\"system\":\"" + json_escape(sys) + "\",\"messages\":[{\"role\":\"user\",\"content\":\"" + json_escape(prompt) + "\"}],\"stream\":true}";
        } else {
            std::string mdl = model_;
            if(mdl.empty()){
                if(auto *c=find_cloud_provider(provider_id_)) mdl=c->default_model;
                if(mdl.empty()) mdl="gpt-4o-mini";
            }
            body = "{\"model\":\"" + json_escape(mdl) + "\",\"messages\":[{\"role\":\"system\",\"content\":\"" + json_escape(sys) + "\"},{\"role\":\"user\",\"content\":\"" + json_escape(prompt) + "\"}],\"stream\":true}";
        }
        SoupMessage *msg = soup_message_new("POST", url.c_str());
        soup_message_set_request_body_from_bytes(msg, "application/json", g_bytes_new(body.c_str(), body.size()));
        // auth header per provider
        if(provider_id_=="anthropic"){
            soup_message_headers_append(soup_message_get_request_headers(msg), "x-api-key", api_key_.c_str());
            soup_message_headers_append(soup_message_get_request_headers(msg), "anthropic-version", "2023-06-01");
        } else if(provider_id_!="google"){
            std::string auth = "Bearer " + api_key_;
            soup_message_headers_append(soup_message_get_request_headers(msg), "Authorization", auth.c_str());
        }
        if(provider_id_=="openrouter"){
            soup_message_headers_append(soup_message_get_request_headers(msg), "HTTP-Referer", "https://tessera.tribunus.dev");
            soup_message_headers_append(soup_message_get_request_headers(msg), "X-Title", "Tessera Studio");
        }
        soup_message_headers_append(soup_message_get_request_headers(msg), "Content-Type", "application/json");
        // synchronous streaming via soup_session_send_and_read with chunk callback is simplest for core-only thread
        GError *err=nullptr;
        GBytes *resp = soup_session_send_and_read(session, msg, nullptr, &err);
        if(err){
            std::string e = err->message ? err->message : "soup error";
            g_error_free(err); g_object_unref(msg); g_object_unref(session);
            on_error(e); return;
        }
        guint status = soup_message_get_status(msg);
        if(status < 200 || status >= 300){
            size_t sz; const char* data = (const char*)g_bytes_get_data(resp, &sz);
            std::string e = "HTTP " + std::to_string(status) + (data ? std::string(": ")+std::string(data, std::min(sz,(size_t)300)) : "");
            g_bytes_unref(resp); g_object_unref(msg); g_object_unref(session);
            on_error(e); return;
        }
        size_t sz; const char* data = (const char*)g_bytes_get_data(resp, &sz);
        std::string raw(data? data : "", sz);
        // Parse SSE: data: {...}\n — extract delta content
        parse_sse(raw, on_chunk);
        on_chunk("", true);
        g_bytes_unref(resp); g_object_unref(msg); g_object_unref(session);
    }
private:
    std::string base_url_, model_, api_key_, provider_id_;
    static std::string json_escape(const std::string &s){
        std::string o; o.reserve(s.size()+8);
        for(char c: s){ if(c=='\\') o+="\\\\"; else if(c=='"') o+="\\\""; else if(c=='\n') o+="\\n"; else if(c=='\r') o+="\\r"; else if(c=='\t') o+="\\t"; else o+=c; }
        return o;
    }
    static void parse_sse(const std::string &raw, ChatChunkCallback &on_chunk){
        size_t pos=0;
        while(pos<raw.size()){
            size_t nl=raw.find('\n',pos);
            std::string line = raw.substr(pos, nl==std::string::npos? std::string::npos : nl-pos);
            pos = nl==std::string::npos? raw.size() : nl+1;
            if(line.rfind("data: ",0)==0){
                std::string j=line.substr(6);
                if(j=="[DONE]") break;
                // quick extract "delta":{"content":"..."} or "content":"..."
                size_t p=j.find("\"content\"");
                if(p!=std::string::npos){
                    size_t colon=j.find(':',p);
                    size_t q1=j.find('"',colon+1);
                    size_t q2=j.find('"',q1+1);
                    // handle escaped quotes simply: find unescaped
                    if(q1!=std::string::npos && q2!=std::string::npos){
                        std::string delta=j.substr(q1+1,q2-q1-1);
                        // unescape \n
                        std::string u; for(size_t i=0;i<delta.size();++i){ if(delta[i]=='\\'&&i+1<delta.size()&&delta[i+1]=='n'){ u+='\n'; ++i; } else if(delta[i]=='\\'&&i+1<delta.size()&&delta[i+1]=='"'){ u+='"'; ++i; } else u+=delta[i]; }
                        if(!u.empty()) on_chunk(u,false);
                    }
                }
            }
        }
        if(raw.find("\"content\"")==std::string::npos && !raw.empty() && raw.size()<2000){
            // non-stream JSON fallback (Google etc) — emit raw truncated
            on_chunk(raw.substr(0,800), false);
        }
    }
};
#endif

LLMProvider *make_provider_remote(const std::string &base_url, const std::string &model) {
#ifdef HAVE_LIBSOUP
    std::string key;
    // try to resolve key from env or generic secret for generic provider
    if(const char* k=getenv("OPENAI_API_KEY")) key=k;
    else if(const char* k=getenv("ANTHROPIC_API_KEY")) key=k;
    else key = cloud_api_key("generic");
    if(!key.empty() || base_url.find("localhost")!=std::string::npos){
        return new RemoteStreamingProvider(base_url, model, key, "generic");
    }
    return new PlaceholderProvider();
#else
    (void)base_url; (void)model;
    return new PlaceholderProvider();
#endif
}

LLMProvider *make_provider_for_cloud(const std::string &provider_id, const std::string &model_override){
    std::string pid = provider_id;
    if(pid.empty()) pid = "generic";
    const CloudProvider *cp = find_cloud_provider(pid);
    std::string base = cp ? cp->base_url : "http://localhost:8080";
    std::string model = model_override;
    if(model.empty() && cp) model = cp->default_model;
    // allow env override per provider: e.g. OPENAI_API_KEY etc handled in RemoteStreamingProvider, but also check SecretStore
    std::string key = cloud_api_key(pid);
    if(key.empty()){
        // fallback to env vars for common providers
        if(pid=="openai" && getenv("OPENAI_API_KEY")) key=getenv("OPENAI_API_KEY");
        else if(pid=="anthropic" && getenv("ANTHROPIC_API_KEY")) key=getenv("ANTHROPIC_API_KEY");
        else if(pid=="google" && getenv("GOOGLE_API_KEY")) key=getenv("GOOGLE_API_KEY");
        else if(pid=="deepseek" && getenv("DEEPSEEK_API_KEY")) key=getenv("DEEPSEEK_API_KEY");
        else if(pid=="openrouter" && getenv("OPENROUTER_API_KEY")) key=getenv("OPENROUTER_API_KEY");
    }
#ifdef HAVE_LIBSOUP
    return new RemoteStreamingProvider(base, model, key, pid);
#else
    (void)base; (void)model; (void)key;
    return new PlaceholderProvider();
#endif
}

LLMProvider *make_provider_on_device(const std::string &model_path, int gpu_layers, int threads) {
    (void)model_path; (void)gpu_layers; (void)threads;
    return new PlaceholderProvider();
}

} // namespace tessera
