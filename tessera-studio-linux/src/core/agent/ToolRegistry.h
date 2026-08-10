#pragma once
#include "Agent.h"
#include "tools/DesktopTool.h"
#include "tools/BrowserTool.h"
#include "../system/BackgroundPortal.h"
#include "../data/DataLayer.h"
#include <string>
namespace tessera {
class ToolRegistry {
public:
    ToolRegistry(ApprovalEngine *ae, DataLayer *dl) : approval(ae), data(dl) {}
    std::string call_desktop(const std::string &op, const std::string &args);
    std::string call_browser(const std::string &op, const std::string &args);
    std::string call_background(const std::string &reason);
    // Compliance: minimum necessary + disclosure accounting
    std::string call_data(const std::string &entity_type, const std::string &filter, const std::string &accessor="user", const std::string &purpose="need_to_know");
    bool checkMinimumNecessary(const std::string &filter);
    DesktopTool desktop;
    BrowserTool browser;
    BackgroundPortal background;
private:
    ApprovalEngine *approval=nullptr;
    DataLayer *data=nullptr;
    bool checkApproval(const std::string &tool, const std::string &args);
};
} // namespace tessera
