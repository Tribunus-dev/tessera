#pragma once
#include <string>
namespace tessera {
class BackgroundPortal{
public:
    bool request(const std::string &reason, bool autostart, bool background, bool dbus_activatable);
    bool is_supported() const;
    std::string last_error;
};
} // namespace tessera
