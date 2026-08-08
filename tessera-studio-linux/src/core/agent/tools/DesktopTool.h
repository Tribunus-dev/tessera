#pragma once
#include <string>
#include <vector>
namespace tessera {
// Full desktop control via AT-SPI2 (Wayland/X11) + portal RemoteDesktop
// Worker thread only, approval-gated, receipt-written
struct DesktopWindow{ std::string id, title, app; };
struct DesktopElement{ std::string role, name; int x,y,w,h; };
class DesktopTool{
public:
    std::vector<DesktopWindow> list_windows(); // via atspi if HAVE_ATSPI else fallback
    std::vector<DesktopElement> find(const std::string &role, const std::string &name_substr);
    bool click(const std::string &role, const std::string &name);
    bool type_text(const std::string &text);
    bool open_app(const std::string &app_id); // GAppInfo
};
} // namespace tessera
