#include "Agent.h"
#include "../provider.h"
#include "../config.h"
#include "ToolRegistry.h"
#include <thread>
#include <regex>
#include <sstream>
namespace tessera {
SafetyDecision ApprovalEngine::decide(const ApprovalRequest &req) {
    // Deny list: destructive tools without explicit approval
    if (req.tool == "deny") return SafetyDecision::Deny;
    if (req.tool == "ask") return SafetyDecision::Ask;
    if (req.tool == "desktop" && (req.args.find("wipe")!=std::string::npos || req.args.find("rm -rf")!=std::string::npos)) return SafetyDecision::Ask;
    if (req.tool == "browser" && req.args.find("file://")!=std::string::npos) return SafetyDecision::Ask;
    return SafetyDecision::Allow;
}
void ApprovalEngine::approve(const std::string &id) { (void)id; }
void ApprovalEngine::deny(const std::string &id, const std::string &reason) { (void)id; (void)reason; }
void DenialCircuitBreaker::record(bool denied){ if(denied) count++; else count=0; }
void AgentLoop::run_one_turn(const std::string &user_input){
    AppConfig cfg = load_config();
    std::string pid = cfg.cloud_provider;
    LLMProvider *p = nullptr;
    if(cfg.provider==ProviderType::RemoteApi && !pid.empty()){
        p = make_provider_for_cloud(pid, cfg.cloud_model);
    } else if(cfg.provider==ProviderType::RemoteApi){
        p = make_provider_remote(cfg.remote_base_url, cfg.cloud_model);
    } else if(cfg.provider==ProviderType::OnDevice){
        p = make_provider_on_device(cfg.on_device_model_path, cfg.on_device_gpu_layers, cfg.on_device_threads);
    } else {
        p = make_provider_placeholder();
    }
    set_provider(p);
    if(!provider) return;
    // Streaming loop with tool dispatch: parse tool calls from LLM output
    // Tools are gated by ApprovalEngine and circuit breaker
    ApprovalEngine approval;
    DataLayer *dl = nullptr;
    ToolRegistry tools(&approval, dl);
    DenialCircuitBreaker breaker;
    int consecutive_denials = 0;
    std::string buffer;
    provider->send(user_input,
        [&](const std::string &delta, bool done){
            if(done){
                // End of turn: if buffer contains tool call JSON, dispatch
                if(!buffer.empty()){
                    // Simple tool call detection: look for {"tool": "...", "args": "..."}
                    std::regex tool_re(R"(\{[^}]*\"tool\"\s*:\s*\"([^\"]+)\"[^}]*\})");
                    std::smatch m;
                    std::string::const_iterator searchStart(buffer.cbegin());
                    while(std::regex_search(searchStart, buffer.cend(), m, tool_re)){
                        std::string tool = m[1];
                        std::string args = m[0];
                        ApprovalRequest req{tool, args};
                        SafetyDecision dec = approval.decide(req);
                        if(dec==SafetyDecision::Deny){
                            breaker.record(true);
                            consecutive_denials++;
                            if(breaker.should_break(consecutive_denials)){
                                buffer += "\n[circuit breaker: too many denials, stopping]\n";
                                break;
                            }
                            buffer += "\n[tool " + tool + " denied]\n";
                        } else if(dec==SafetyDecision::Ask){
                            buffer += "\n[tool " + tool + " needs approval]\n";
                            breaker.record(false);
                        } else {
                            breaker.record(false);
                            consecutive_denials = 0;
                            std::string result;
                            if(tool=="desktop" || tool=="click" || tool=="type") result = tools.call_desktop(tool, args);
                            else if(tool=="browser" || tool=="navigate") result = tools.call_browser(tool, args);
                            else result = "[unknown tool " + tool + "]";
                            buffer += "\n[tool result: " + result.substr(0,200) + "]\n";
                        }
                        searchStart = m.suffix().first;
                    }
                }
            } else {
                buffer += delta;
            }
        },
        [](const std::string &err){ (void)err; });
}
} // namespace tessera
