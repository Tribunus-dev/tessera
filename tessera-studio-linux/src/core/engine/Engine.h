#pragma once
#include "../provider.h"
#include <string>
namespace tessera {
// Port of TesseraLLMProviderType + EngineCall (tessera_ffi.cpp dlopen)
// ON_DEVICE via libllama shim, REMOTE_API via libsoup3, PLACEHOLDER built-in
class Engine {
public:
    explicit Engine(const std::string &cli_override = "") : cli_override_(cli_override) {}
    LLMProvider* provider_for(const std::string &type);
    std::string cli_path() const;
private:
    std::string cli_override_;
};
} // namespace tessera
