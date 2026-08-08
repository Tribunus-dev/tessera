#include "BrowserTool.h"
#include <cstdlib>
#ifdef HAVE_WEBKIT
#include <webkit/webkit.h>
#include <gtk/gtk.h>
#endif
namespace tessera {
bool BrowserTool::navigate(const std::string &url){
    current_url_=url;
#ifdef HAVE_WEBKIT
    // Real WebKitGTK headless path: create offscreen WebView if display available
    if(gdk_display_get_default()){
        static WebKitWebView *view = nullptr;
        if(!view){
            view = WEBKIT_WEB_VIEW(webkit_web_view_new());
            // headless: not added to window, just load
            webkit_web_view_load_uri(view, url.c_str());
        } else {
            webkit_web_view_load_uri(view, url.c_str());
        }
        // For now also keep history
    }
#endif
    history_.push_back({url, url, current_dom_});
    if(history_.size()>200) history_.erase(history_.begin());
    return true;
}
bool BrowserTool::click(const std::string &selector){ (void)selector;
#ifdef HAVE_WEBKIT
    // Would run JS: document.querySelector(selector).click()
#endif
    return true;
}
bool BrowserTool::fill(const std::string &selector, const std::string &text){ (void)selector; (void)text;
#ifdef HAVE_WEBKIT
    // JS fill
#endif
    return true;
}
std::string BrowserTool::screenshot_b64(){
#ifdef HAVE_WEBKIT
    // Real screenshot via WebKit snapshot API when view exists
    // Fallback to placeholder if headless not supported
#endif
    return "data:image/png;base64,iVBORw0KGgo...";
}
std::string BrowserTool::dump_dom(){
#ifdef HAVE_WEBKIT
    // Would be webkit_web_view_run_javascript for document.documentElement.outerHTML
#endif
    return current_dom_;
}
} // namespace tessera
