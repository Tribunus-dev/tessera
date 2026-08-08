#include "BrowserTool.h"
#include <cstdlib>
namespace tessera {
bool BrowserTool::navigate(const std::string &url){ current_url_=url; history_.push_back({url, url, current_dom_}); if(history_.size()>200) history_.erase(history_.begin()); return true; }
bool BrowserTool::click(const std::string &selector){ (void)selector; return true; }
bool BrowserTool::fill(const std::string &selector, const std::string &text){ (void)selector; (void)text; return true; }
std::string BrowserTool::screenshot_b64(){ return "data:image/png;base64,iVBORw0KGgo..."; }
std::string BrowserTool::dump_dom(){ return current_dom_; }
} // namespace
