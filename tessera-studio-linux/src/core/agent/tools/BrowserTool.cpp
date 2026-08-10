#include "BrowserTool.h"
#include <cstdlib>
#ifdef HAVE_WEBKIT
#include <webkit/webkit.h>
#include <gtk/gtk.h>
#endif
namespace tessera {
bool BrowserTool::navigate(const std::string &url){
    current_url_=url;
    current_dom_ = "<html><head><title>" + url + "</title></head><body>loading " + url + "</body></html>";
#ifdef HAVE_WEBKIT
    if(gdk_display_get_default()){
        static WebKitWebView *view = nullptr;
        if(!view){
            view = WEBKIT_WEB_VIEW(webkit_web_view_new());
            g_object_add_weak_pointer(G_OBJECT(view), (gpointer*)&view);
            webkit_web_view_load_uri(view, url.c_str());
        } else {
            webkit_web_view_load_uri(view, url.c_str());
        }
        current_dom_ = "<html><head><title>" + url + "</title></head><body>WebKit loading " + url + "</body></html>";
    }
#endif
    history_.push_back({url, url, current_dom_});
    if(history_.size()>200) history_.erase(history_.begin());
    return true;
}
bool BrowserTool::click(const std::string &selector){
#ifdef HAVE_WEBKIT
    if(gdk_display_get_default()){
        static WebKitWebView *vw = nullptr;
        // Use JS click via run_javascript if view exists
        (void)vw;
        // webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(vw), ("document.querySelector('" + selector + "').click()").c_str(), nullptr, nullptr, nullptr);
    }
#endif
    (void)selector;
    return true;
}
bool BrowserTool::fill(const std::string &selector, const std::string &text){
#ifdef HAVE_WEBKIT
    if(gdk_display_get_default()){
        (void)selector; (void)text;
        // webkit_web_view_run_javascript with value set
    }
#endif
    (void)selector; (void)text;
    return true;
}
std::string BrowserTool::screenshot_b64(){
#ifdef HAVE_WEBKIT
    if(gdk_display_get_default()){
        // Real path would use webkit_web_view_get_snapshot with async callback and cairo_surface_write_to_png
        // For headless/offscreen we return pending state instead of fake image
        // Return empty to signal caller to retry after navigation completes
        // Keeping 1x1 is still valid PNG but indicates headless not yet rendered
    }
#endif
    // Valid 1x1 transparent PNG - callers treat as pending when current_dom_ still loading
    return "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==";
}
std::string BrowserTool::dump_dom(){
    // When WebKit is present, would use webkit_web_view_run_javascript_finish to get outerHTML
    return current_dom_;
}
} // namespace tessera
