#pragma once
#include <string>
namespace tessera {
class SecretStore {
public:
    bool store(const std::string &service, const std::string &key, const std::string &value);
    std::string load(const std::string &service, const std::string &key);
    bool remove(const std::string &service, const std::string &key);
};
} // namespace tessera
