#include "ChatBubble.h"
#include <adwaita.h>
#include <glib.h>

namespace tessera {

static const char* role_label(ChatRole r){
    switch(r){
        case ChatRole::User: return "You";
        case ChatRole::Assistant: return "Tessy";
        case ChatRole::Sky: return "Sky";
        case ChatRole::System: return "System";
    }
    return "";
}

static std::string now_time(){
    GDateTime *dt = g_date_time_new_now_local();
    char *s = g_date_time_format(dt, "%-I:%M %p");
    std::string out = s ? s : "";
    g_free(s); g_date_time_unref(dt);
    return out;
}

GtkWidget* chat_timestamp_new(const std::string &text){
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_halign(outer, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(outer, 12); gtk_widget_set_margin_bottom(outer, 4);
    GtkWidget *pill = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(pill, "chat-timestamp");
    GtkWidget *lbl = gtk_label_new(text.c_str());
    gtk_widget_add_css_class(lbl, "caption"); gtk_widget_add_css_class(lbl, "dim-label");
    gtk_widget_set_margin_top(lbl, 3); gtk_widget_set_margin_bottom(lbl, 3);
    gtk_widget_set_margin_start(lbl, 10); gtk_widget_set_margin_end(lbl, 10);
    gtk_box_append(GTK_BOX(pill), lbl);
    gtk_box_append(GTK_BOX(outer), pill);
    gtk_accessible_update_property(GTK_ACCESSIBLE(outer), GTK_ACCESSIBLE_PROPERTY_LABEL, text.c_str(), -1);
    return outer;
}

GtkWidget* chat_bubble_new(ChatRole role, const std::string &content, bool is_streaming, const std::string &stream_text) {
    bool is_user = (role == ChatRole::User);
    bool is_system = (role == ChatRole::System);

    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(outer, 2); gtk_widget_set_margin_bottom(outer, 2);
    gtk_widget_set_margin_start(outer, 8); gtk_widget_set_margin_end(outer, 8);

    // Avatar — Tessy (local) vs Sky (cloud), both distinct from your personal context
    bool is_sky = (role == ChatRole::Sky);
    bool is_tessy = (role == ChatRole::Assistant);
    GtkWidget *avatar = nullptr;
    if(!is_system){
        if(is_user){
            avatar = gtk_image_new_from_icon_name("avatar-default-symbolic");
            gtk_widget_set_tooltip_text(avatar, "You — personal context");
        } else if(is_sky){
            avatar = gtk_image_new_from_icon_name("cloud-symbolic");
            if(!gtk_image_get_icon_name(GTK_IMAGE(avatar))) {
                g_object_unref(avatar);
                avatar = gtk_image_new_from_icon_name("network-server-symbolic");
            }
            gtk_widget_set_tooltip_text(avatar, "Sky — cloud agent, powered only by cloud APIs");
        } else {
            avatar = gtk_image_new_from_icon_name("org.tessera.TesseraStudio");
            if(!gtk_image_get_icon_name(GTK_IMAGE(avatar))) {
                g_object_unref(avatar);
                avatar = gtk_image_new_from_icon_name("avatar-default-symbolic");
            }
            gtk_widget_set_tooltip_text(avatar, "Tessy — local agent, on this device");
        }
        gtk_widget_set_size_request(avatar, 26, 26);
        gtk_widget_set_valign(avatar, GTK_ALIGN_END);
        gtk_widget_add_css_class(avatar, "chat-avatar");
        if(is_tessy) gtk_widget_add_css_class(avatar, "tessy-avatar");
        if(is_sky) gtk_widget_add_css_class(avatar, "sky-avatar");
        gtk_widget_set_margin_bottom(avatar, 16);
    }

    GtkWidget *spacer_l = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0);
    GtkWidget *spacer_r = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0);
    gtk_widget_set_size_request(spacer_l, 36, -1); gtk_widget_set_size_request(spacer_r, 36, -1);
    gtk_widget_set_hexpand(spacer_l, TRUE); gtk_widget_set_hexpand(spacer_r, TRUE);

    GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_hexpand(col, FALSE);
    gtk_widget_set_halign(col, is_user ? GTK_ALIGN_END : GTK_ALIGN_START);
    // cap bubble width to ~68% of window — use size request hint
    gtk_widget_set_size_request(col, 280, -1);

    if (!content.empty()) {
        GtkWidget *bubble = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_add_css_class(bubble, "chat-bubble");
        if (is_user) gtk_widget_add_css_class(bubble, "user");
        else if (is_system) gtk_widget_add_css_class(bubble, "system");
        else if (is_sky) { gtk_widget_add_css_class(bubble, "assistant"); gtk_widget_add_css_class(bubble, "sky"); }
        else gtk_widget_add_css_class(bubble, "assistant");
        GtkWidget *text;
        if (role == ChatRole::Assistant || role == ChatRole::System) {
            std::string md = content;
            std::string pango; pango.reserve(md.size()*2);
            bool in_code=false, in_bold=false;
            for(size_t i=0;i<md.size();){
                if(i+2<md.size() && md.substr(i,3)=="```"){ in_code=!in_code; pango+= in_code ? "<i><tt>" : "</tt></i>"; i+=3; continue; }
                if(i+1<md.size() && md.substr(i,2)=="**"){ in_bold=!in_bold; pango+= in_bold ? "<b>" : "</b>"; i+=2; continue; }
                if(md[i]=='`' && !in_code){ pango+="<tt>"; size_t j=md.find('`',i+1); if(j!=std::string::npos){ std::string inner=md.substr(i+1,j-i-1); for(char c:inner){ if(c=='&') pango+="&amp;"; else if(c=='<') pango+="&lt;"; else if(c=='>') pango+="&gt;"; else pango+=c; } pango+="</tt>"; i=j+1; continue; } else { pango+="`"; i++; continue; } }
                if(md[i]=='&') { pango+="&amp;"; i++; }
                else if(md[i]=='<') { pango+="&lt;"; i++; }
                else if(md[i]=='>') { pango+="&gt;"; i++; }
                else if(md[i]=='\n') { pango+="\n"; i++; }
                else pango+=md[i++];
            }
            text = gtk_label_new(nullptr);
            gtk_label_set_markup(GTK_LABEL(text), pango.c_str());
            gtk_label_set_wrap(GTK_LABEL(text), TRUE); gtk_label_set_xalign(GTK_LABEL(text), 0);
            gtk_label_set_selectable(GTK_LABEL(text), TRUE); gtk_label_set_wrap_mode(GTK_LABEL(text), PANGO_WRAP_WORD_CHAR);
        } else {
            text = gtk_label_new(content.c_str());
            gtk_label_set_wrap(GTK_LABEL(text), TRUE); gtk_label_set_xalign(GTK_LABEL(text), 0);
            gtk_label_set_selectable(GTK_LABEL(text), TRUE);
            // user bubble uses accent_fg_color for contrast — handled in css via color inheritance
        }
        gtk_widget_set_margin_top(text, 8); gtk_widget_set_margin_bottom(text, 8);
        gtk_widget_set_margin_start(text, 12); gtk_widget_set_margin_end(text, 12);
        gtk_box_append(GTK_BOX(bubble), text);
        gtk_box_append(GTK_BOX(col), bubble);

        // Metadata row — timestamp + delivered/read (iMessage: small caption below bubble)
        GtkWidget *meta = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_set_halign(meta, is_user ? GTK_ALIGN_END : GTK_ALIGN_START);
        GtkWidget *time_lbl = gtk_label_new(now_time().c_str());
        gtk_widget_add_css_class(time_lbl, "caption"); gtk_widget_add_css_class(time_lbl, "dim-label");
        gtk_widget_add_css_class(time_lbl, "chat-meta");
        gtk_box_append(GTK_BOX(meta), time_lbl);
        if(is_user){
            GtkWidget *dot = gtk_label_new("·"); gtk_widget_add_css_class(dot, "caption"); gtk_widget_add_css_class(dot, "dim-label");
            GtkWidget *status = gtk_label_new("Delivered"); gtk_widget_add_css_class(status, "caption"); gtk_widget_add_css_class(status, "dim-label");
            gtk_box_append(GTK_BOX(meta), dot); gtk_box_append(GTK_BOX(meta), status);
        }
        gtk_box_append(GTK_BOX(col), meta);
    }

    if (is_streaming) {
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_set_halign(row, GTK_ALIGN_START);
        gtk_widget_set_margin_start(row, 4);
        bool is_group_sky = is_sky;
        GtkWidget *spinner = gtk_spinner_new(); gtk_spinner_start(GTK_SPINNER(spinner));
        gtk_widget_set_size_request(spinner, 12, 12);
        GtkWidget *lbl = gtk_label_new(stream_text.c_str());
        gtk_widget_add_css_class(lbl, "caption"); gtk_widget_add_css_class(lbl, "dim-label");
        // three animated dots — pure CSS bounce, no JS, respects reduced-motion
        GtkWidget *dots = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
        for(int i=0;i<3;i++){ GtkWidget *d=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0); gtk_widget_set_size_request(d,6,6); gtk_widget_add_css_class(d,"typing-dot"); gtk_box_append(GTK_BOX(dots), d); }
        gtk_box_append(GTK_BOX(row), spinner); gtk_box_append(GTK_BOX(row), lbl); gtk_box_append(GTK_BOX(row), dots);
        gtk_box_append(GTK_BOX(col), row);
        if(is_group_sky) gtk_widget_add_css_class(row, "typing-sky");
    }

    gtk_accessible_update_property(GTK_ACCESSIBLE(outer), GTK_ACCESSIBLE_PROPERTY_LABEL, (std::string(role_label(role))+": "+content).c_str(), -1);

    if (is_system) {
        gtk_widget_set_halign(col, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(outer), col);
    } else if (is_user) {
        gtk_box_append(GTK_BOX(outer), spacer_l); gtk_box_append(GTK_BOX(outer), col); gtk_box_append(GTK_BOX(outer), avatar);
    } else {
        gtk_box_append(GTK_BOX(outer), avatar); gtk_box_append(GTK_BOX(outer), col); gtk_box_append(GTK_BOX(outer), spacer_r);
    }
    return outer;
}

void chat_bubble_set_streaming(GtkWidget*, bool){}

std::string funny_tool_line(ChatRole role, const std::string &tool, const std::string &hint){
    // Keep it playful, short, Adwaita — no emoji spam, one word play per call
    std::string h=hint; for(char &c: h) c=tolower(c);
    bool is_sky = (role==ChatRole::Sky);
    if(tool=="notes" || h.find("note")!=std::string::npos){
        return is_sky ? "Sky is peeking at the index (not your notes) — doing cloud math" : "Tessy is tiptoeing through your notes — stays on this device, promise";
    }
    if(tool=="email" || h.find("email")!=std::string::npos || h.find("inbox")!=std::string::npos){
        return is_sky ? "Sky is drafting email-fu in the cloud — Tessy keeps the inbox local" : "Tessy is politely knocking on your inbox — no mail leaves the machine";
    }
    if(tool=="calendar" || h.find("calendar")!=std::string::npos){
        return is_sky ? "Sky is juggling time zones for you" : "Tessy flips your calendar — local only, no spoilers to the cloud";
    }
    if(tool=="search" || tool=="browser" || h.find("search")!=std::string::npos || h.find("browse")!=std::string::npos){
        return is_sky ? "Sky is sprinting the web — tabs open, coffee not needed" : "Tessy is spelunking the web with Sky as scout";
    }
    if(tool=="code" || h.find("code")!=std::string::npos){
        return is_sky ? "Sky is pairing with the internet — typing at lightspeed" : "Tessy is rubber-ducking your code, locally";
    }
    if(tool=="desktop"){
        return is_sky ? "Sky is squinting at windows — via Tessy's eyes only" : "Tessy is peeking at your windows — careful steps only";
    }
    if(tool=="synthesis"){
        return "Tessy + Sky huddle — Tessy kept the secrets, Sky brought the big brain";
    }
    if(is_sky) return "Sky is warming up the cloud brains — one sec";
    return "Tessy is rummaging locally — fast, private, no suitcase to the cloud";
}

GtkWidget* chat_tool_call_new(ChatRole role, const std::string &tool, const std::string &funny_detail, bool running){
    bool is_sky = (role==ChatRole::Sky);
    bool is_user = (role==ChatRole::User);
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(outer, 4); gtk_widget_set_margin_bottom(outer, 4);
    gtk_widget_set_margin_start(outer, 8); gtk_widget_set_margin_end(outer, 8);
    GtkWidget *avatar = nullptr;
    if(!is_user){
        if(is_sky) avatar = gtk_image_new_from_icon_name("cloud-symbolic");
        else avatar = gtk_image_new_from_icon_name("org.tessera.TesseraStudio");
        if(!gtk_image_get_icon_name(GTK_IMAGE(avatar))){ g_object_unref(avatar); avatar = gtk_image_new_from_icon_name("avatar-default-symbolic"); }
        gtk_widget_set_size_request(avatar, 22, 22);
        gtk_widget_set_valign(avatar, GTK_ALIGN_START);
        gtk_widget_add_css_class(avatar, "chat-avatar");
        if(role==ChatRole::Assistant) gtk_widget_add_css_class(avatar, "tessy-avatar");
        if(is_sky) gtk_widget_add_css_class(avatar, "sky-avatar");
    }
    GtkWidget *spacer_l = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0);
    GtkWidget *spacer_r = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0);
    gtk_widget_set_size_request(spacer_l, 36, -1); gtk_widget_set_size_request(spacer_r, 36, -1);
    gtk_widget_set_hexpand(spacer_l, TRUE); gtk_widget_set_hexpand(spacer_r, TRUE);
    GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_halign(col, GTK_ALIGN_START);
    gtk_widget_set_size_request(col, 300, -1);
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(card, "tool-call");
    if(is_sky) gtk_widget_add_css_class(card, "sky");
    if(running) gtk_widget_add_css_class(card, "running");
    GtkWidget *icon = running ? gtk_spinner_new() : gtk_image_new_from_icon_name(is_sky ? "cloud-symbolic" : "emblem-ok-symbolic");
    if(running){ gtk_spinner_start(GTK_SPINNER(icon)); gtk_widget_set_size_request(icon, 16, 16); }
    else { gtk_widget_set_size_request(icon, 16, 16); }
    GtkWidget *v = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2); gtk_widget_set_hexpand(v, TRUE);
    GtkWidget *title = gtk_label_new((tool.empty() ? (is_sky ? "Sky" : "Tessy") : (is_sky ? "Sky — " + tool : "Tessy — " + tool)).c_str());
    gtk_widget_add_css_class(title, "tool-call-label"); gtk_label_set_xalign(GTK_LABEL(title), 0);
    GtkWidget *detail = gtk_label_new(funny_detail.c_str());
    gtk_widget_add_css_class(detail, "tool-call-detail"); gtk_label_set_xalign(GTK_LABEL(detail), 0); gtk_label_set_wrap(GTK_LABEL(detail), TRUE);
    gtk_box_append(GTK_BOX(v), title); gtk_box_append(GTK_BOX(v), detail);
    gtk_box_append(GTK_BOX(card), icon); gtk_box_append(GTK_BOX(card), v);
    gtk_box_append(GTK_BOX(col), card);
    if(!is_user && !is_sky){
        gtk_box_append(GTK_BOX(outer), avatar); gtk_box_append(GTK_BOX(outer), col); gtk_box_append(GTK_BOX(outer), spacer_r);
    } else if(is_sky){
        gtk_box_append(GTK_BOX(outer), avatar); gtk_box_append(GTK_BOX(outer), col); gtk_box_append(GTK_BOX(outer), spacer_r);
    } else {
        gtk_box_append(GTK_BOX(outer), spacer_l); gtk_box_append(GTK_BOX(outer), col); gtk_box_append(GTK_BOX(outer), avatar);
    }
    return outer;
}

} // namespace tessera
