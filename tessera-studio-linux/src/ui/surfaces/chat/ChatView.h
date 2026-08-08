#pragma once
#include <string>
#include <vector>
#include <functional>

namespace tessera {

// Chat history types (port of ChatPanelStateMachine / ChatQueueItem)
struct Msg {
    std::string role; // user / assistant / system
    std::string content;
};

class ChatSession {
public:
    void add_user(const std::string &text) { history.push_back({"user", text}); }
    void add_assistant(const std::string &text) { history.push_back({"assistant", text}); }
    const std::vector<Msg> &get_history() const { return history; }
    void clear() { history.clear(); }
private:
    std::vector<Msg> history;
};

// Minimal state machine for ChatPanelViewModel
enum class ChatState { Idle, Streaming, Error };

} // namespace tessera
