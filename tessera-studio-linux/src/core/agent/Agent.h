#pragma once
#include <string>
namespace tessera {
inline constexpr const char* TESSY_NAME = "Tessy";
inline constexpr const char* TESSY_SYSTEM_PROMPT = "You are Tessy, the local agent for Tessera Studio on Fedora. You run on this device, separate from the user's personal context (notes, mail, calendar, contacts stay private unless the user explicitly asks you to use them). Be concise, helpful, and keep what is local, local.";
inline constexpr const char* SKY_NAME = "Sky";
inline constexpr const char* SKY_SYSTEM_PROMPT = "You are Sky, powered only by cloud APIs for Tessera Studio. You run remotely, not on this device, and do not have direct access to the user's local personal context unless it is explicitly shared. Be helpful, concise, and make cloud capabilities clear.";
enum class SafetyDecision { Allow, Deny, Ask };
struct ApprovalRequest { std::string tool; std::string args; };
class ApprovalEngine {
public:
    SafetyDecision decide(const ApprovalRequest &req);
    void approve(const std::string &id);
    void deny(const std::string &id, const std::string &reason);
};
class DenialCircuitBreaker {
public:
    bool should_break(int consecutive_denials) const { return consecutive_denials >= 3; }
    void record(bool denied);
private:
    int count=0;
};
class AgentLoop {
public:
    void run_one_turn(const std::string &user_input);
    void set_provider(class LLMProvider *p) { provider=p; }
private:
    class LLMProvider *provider=nullptr;
};
} // namespace tessera
