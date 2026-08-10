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
void AgentLoop::run_one_turn(const std::string &user_input){ run(user_input, 1); }

void AgentLoop::run(const std::string &user_input, int max_iters){
    int iters = max_iters < 0 ? maxIterations_ : max_iters;
    if(iters < 1) iters = 1;
    if(iters > 20) iters = 20;
    if(!provider){
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
    }
    if(!provider) return;
    ApprovalEngine approval;
    ToolRegistry tools(&approval, dataLayer_);
    DenialCircuitBreaker breaker;
    int consecutive_denials = 0;
    std::string conversation = user_input;
    std::string buffer;
    for(int iter=0; iter<iters; ++iter){
        std::string turnBuf;
        bool doneFlag=false;
        std::string errBuf;
        provider->send(conversation,
            [&](const std::string &delta, bool done){
                if(done) doneFlag=true;
                else turnBuf += delta;
            },
            [&](const std::string &err){ errBuf = err; doneFlag=true; });
        if(!errBuf.empty()){ buffer += "\n[error: " + errBuf + "]\n"; break; }
        buffer += turnBuf;
        // Parse tool calls as JSON {"tool": "...", "args": {...}} or {"tool":"...","args":"..."}
        if(turnBuf.empty() || turnBuf.find("\"tool\"")==std::string::npos){
            // No tool call, end of agent iteration
            break;
        }
        std::regex tool_re(R"(\{[^{}]*\"tool\"\s*:\s*\"([^\"]+)\"[^{}]*\})");
        std::smatch m;
        std::string::const_iterator searchStart(turnBuf.cbegin());
        bool dispatched=false;
        bool should_break=false;
        std::string toolResults;
        while(std::regex_search(searchStart, turnBuf.cend(), m, tool_re)){
            std::string tool = m[1];
            std::string args = m[0].str();
            ApprovalRequest req{tool, args};
            SafetyDecision dec = approval.decide(req);
            if(dec==SafetyDecision::Deny){
                breaker.record(true);
                consecutive_denials++;
                if(breaker.should_break(consecutive_denials)){
                    buffer += "\n[circuit breaker: too many denials, stopping]\n";
                    should_break=true; break;
                }
                toolResults += "\n[tool " + tool + " denied]\n";
            } else if(dec==SafetyDecision::Ask){
                toolResults += "\n[tool " + tool + " needs approval - HoldYourHorses]\n";
                breaker.record(false);
            } else {
                breaker.record(false);
                consecutive_denials = 0;
                dispatched=true;
                std::string result;
                if(tool=="desktop" || tool=="click" || tool=="type") result = tools.call_desktop(tool, args);
                else if(tool=="browser" || tool=="navigate" || tool=="web") result = tools.call_browser(tool, args);
                else if(tool=="background") result = tools.call_background(args);
                else result = "[unknown tool " + tool + "]";
                toolResults += "\n[tool " + tool + " result: " + result.substr(0,400) + "]\n";
            }
            searchStart = m.suffix().first;
        }
        if(should_break) break;
        if(!dispatched){
            // No Allowed tool dispatched, stop iteration
            if(!toolResults.empty()) buffer += toolResults;
            break;
        }
        buffer += toolResults;
        // Feed tool results back as next conversation context for multi-turn
        conversation = "Tool results:" + toolResults + "\nContinue.";
        if(iter+1 >= iters) buffer += "\n[maxIterations " + std::to_string(iters) + " reached]\n";
    }
    lastBuffer_ = buffer;
}
} // namespace tessera
