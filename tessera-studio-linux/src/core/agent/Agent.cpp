#include "Agent.h"
#include "../provider.h"
#include "../config.h"
#include <thread>
namespace tessera {
SafetyDecision ApprovalEngine::decide(const ApprovalRequest &req) {
    if (req.tool == "deny") return SafetyDecision::Deny;
    if (req.tool == "ask") return SafetyDecision::Ask;
    return SafetyDecision::Allow;
}
void ApprovalEngine::approve(const std::string&) {}
void ApprovalEngine::deny(const std::string&, const std::string&) {}
void DenialCircuitBreaker::record(bool denied){ if(denied) count++; else count=0; }
void AgentLoop::run_one_turn(const std::string &user_input){
    // Drive the loop via the selected cloud provider (GSettings + SecretStore), off GTK thread
    LLMProvider *p = nullptr;
    AppConfig cfg = load_config();
    std::string pid = cfg.cloud_provider;
    // also check GSettings live value via env fallback is in load_config; provider must be RemoteApi to use cloud
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
    if(provider){
        // one streaming turn — tools invoked via ToolRegistry in a real loop; here we just stream the reply
        provider->send(user_input, [](const std::string&,bool){}, [](const std::string&){});
    }
    // ownership stays with caller in this stub; real loop owns provider lifecycle via Engine
}
} // namespace tessera
