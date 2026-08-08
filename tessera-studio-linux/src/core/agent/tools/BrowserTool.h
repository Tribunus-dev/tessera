#pragma once
#include <string>
#include <vector>
namespace tessera {
struct BrowsedPage{ std::string url, title, dom; };
// Headless browser via WebKit/playwright — background portal friendly
class BrowserTool{
public:
    bool navigate(const std::string &url);
    bool click(const std::string &selector);
    bool fill(const std::string &selector, const std::string &text);
    std::string screenshot_b64(); // headless
    std::string dump_dom();
    std::string current_url() const { return current_url_; }
    std::vector<BrowsedPage> history() const { return history_; }
private:
    std::string current_url_;
    std::string current_dom_ = "<html><body>headless</body></html>";
    std::vector<BrowsedPage> history_;
};
} // namespace tessera
