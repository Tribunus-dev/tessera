#include "ToolRegistry.h"
namespace tessera {
bool ToolRegistry::checkMinimumNecessary(const std::string &filter){
    if(filter.empty()) return false;
    if(filter=="*" || filter=="SELECT *" || filter.find("SELECT *")!=std::string::npos) return false;
    if(filter.size()>512) return false; // overbroad
    return true;
}
bool ToolRegistry::checkApproval(const std::string &tool, const std::string &args){
    if(!approval) return true;
    auto d = approval->decide({tool, args});
    if(d==SafetyDecision::Deny) return false;
    if(d==SafetyDecision::Ask) return false; // would show HoldYourHorsesDialog
    return true;
}
std::string ToolRegistry::call_data(const std::string &entity_type, const std::string &filter, const std::string &accessor, const std::string &purpose){
    if(!checkMinimumNecessary(filter)) return "denied: minimum necessary (filter overbroad)";
    if(!checkApproval("data."+entity_type, filter)) return "denied";
    if(data){
        // disclosure accounting per FERPA 99.32 / HIPAA 164.312(b)
        data->log_disclosure("", entity_type, accessor, purpose, filter);
        auto rows = data->list_by_type(entity_type, 50);
        std::string out;
        for(auto &r: rows) out += r.id + "|" + r.label + "\n";
        data->add_receipt("data."+entity_type, filter, out);
        return out.empty()?"ok":out;
    }
    return "ok";
}
std::string ToolRegistry::call_desktop(const std::string &op, const std::string &args){
    if(!checkApproval("desktop."+op, args)) return "denied";
    std::string out;
    if(op=="list_windows"){
        auto w=desktop.list_windows();
        for(auto &x:w) out+=x.title+"|"+x.app+"\n";
    } else if(op=="click") desktop.click("button", args);
    else if(op=="type") desktop.type_text(args);
    else if(op=="open") desktop.open_app(args);
    if(data) data->add_receipt("desktop."+op, args, out.empty()?"ok":out);
    return out.empty()?"ok":out;
}
std::string ToolRegistry::call_browser(const std::string &op, const std::string &args){
    if(!checkApproval("browser."+op, args)) return "denied";
    std::string out="ok";
    if(op=="navigate"){ browser.navigate(args); if(data) data->upsert_knowledge("web_page", args, browser.dump_dom(), "web::"+args, "browsed"); }
    else if(op=="click") browser.click(args);
    else if(op=="fill") browser.fill(args, "");
    else if(op=="screenshot") out=browser.screenshot_b64();
    else if(op=="dom") out=browser.dump_dom();
    if(data) data->add_receipt("browser."+op, args, out);
    return out;
}
std::string ToolRegistry::call_background(const std::string &reason){
    if(!checkApproval("background", reason)) return "denied";
    bool ok=background.request(reason, true, true, true);
    if(data) data->add_receipt("background", reason, ok?"granted":"denied:"+background.last_error);
    return ok?"granted":background.last_error;
}
} // namespace
