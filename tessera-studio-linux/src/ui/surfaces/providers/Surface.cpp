#include "Surface.h"
#include "core/config.h"
#include "core/provider.h"
#include "core/encryption/Secrets.h"
#include "core/engine/Engine.h"
#include "ui/surfaces/models/Surface.h"
#include <adwaita.h>
#include <gio/gio.h>

namespace tessera {

// Intentional card — Adwaita palette only, no purple/glow/glass, no emoji, no bento
static GtkWidget* provider_card_new(const CloudProvider &cp){
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(card, "card");
    gtk_widget_add_css_class(card, "provider-card");
    gtk_widget_set_size_request(card, 320, 190);

    // header: icon + name + status dot
    GtkWidget *hdr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *icon = gtk_image_new_from_icon_name(cp.icon_name.c_str());
    gtk_widget_set_size_request(icon, 28, 28);
    GtkWidget *title = gtk_label_new(cp.display_name.c_str());
    gtk_widget_add_css_class(title, "title-4"); gtk_label_set_xalign(GTK_LABEL(title), 0); gtk_widget_set_hexpand(title, TRUE);
    GtkWidget *dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_size_request(dot, 8, 8); gtk_widget_add_css_class(dot, "nav-working-dot");
    bool has_key = has_cloud_api_key(cp.id);
    gtk_widget_set_visible(dot, has_key);
    // keep dot reference for live toggle
    g_object_set_data(G_OBJECT(card), "status-dot", dot);
    g_object_set_data(G_OBJECT(card), "provider-id", (gpointer)cp.id.c_str());
    gtk_box_append(GTK_BOX(hdr), icon); gtk_box_append(GTK_BOX(hdr), title); gtk_box_append(GTK_BOX(hdr), dot);
    gtk_box_append(GTK_BOX(card), hdr);

    // base URL + model — caption, dim, selectable but not leaking raw label
    GtkWidget *url = gtk_label_new(cp.base_url.c_str());
    gtk_widget_add_css_class(url, "caption"); gtk_widget_add_css_class(url, "dim-label");
    gtk_label_set_xalign(GTK_LABEL(url), 0); gtk_label_set_ellipsize(GTK_LABEL(url), PANGO_ELLIPSIZE_MIDDLE); gtk_label_set_selectable(GTK_LABEL(url), TRUE);
    gtk_box_append(GTK_BOX(card), url);
    GtkWidget *model = gtk_label_new(cp.default_model.c_str());
    gtk_widget_add_css_class(model, "caption"); gtk_widget_add_css_class(model, "dim-label");
    gtk_label_set_xalign(GTK_LABEL(model), 0);
    gtk_box_append(GTK_BOX(card), model);

    // API key row — libsecret backed, not plaintext config
    GtkWidget *key_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *entry = gtk_password_entry_new();
    gtk_widget_set_hexpand(entry, TRUE);
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "API key — stored in libsecret");
    std::string cur = cloud_api_key(cp.id);
    if(!cur.empty()){
        gtk_editable_set_text(GTK_EDITABLE(entry), "••••••••");
        g_object_set_data_full(G_OBJECT(entry), "has-key", GINT_TO_POINTER(1), nullptr);
    }
    GtkWidget *save = gtk_button_new_with_label("Save");
    gtk_widget_add_css_class(save, "suggested-action");
    GtkWidget *clear = gtk_button_new_from_icon_name("edit-clear-symbolic");
    gtk_widget_set_tooltip_text(clear, "Clear key from keyring");
    gtk_box_append(GTK_BOX(key_row), entry); gtk_box_append(GTK_BOX(key_row), save); gtk_box_append(GTK_BOX(key_row), clear);
    gtk_box_append(GTK_BOX(card), key_row);

    // status line — provider-specific hint
    GtkWidget *status = gtk_label_new(has_key ? "Key stored · ready to drive agent" : "No key — add one to enable");
    gtk_widget_add_css_class(status, "caption"); gtk_widget_add_css_class(status, has_key ? "accent" : "dim-label");
    gtk_label_set_xalign(GTK_LABEL(status), 0);
    gtk_box_append(GTK_BOX(card), status);
    g_object_set_data(G_OBJECT(card), "status-label", status);
    g_object_set_data(G_OBJECT(card), "key-entry", entry);

    // save handler — libsecret + GSettings cloud_provider wiring
    struct SaveCtx{ GtkWidget *card; GtkWidget *entry; GtkWidget *dot; GtkWidget *status; std::string pid; };
    SaveCtx *sctx = new SaveCtx{card, entry, dot, status, cp.id};
    g_signal_connect(save, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
        SaveCtx *c=(SaveCtx*)d;
        const char *txt = gtk_editable_get_text(GTK_EDITABLE(c->entry));
        if(!txt || !*txt || g_str_has_prefix(txt, "•")) return;
        bool ok = store_cloud_api_key(c->pid, txt);
        gtk_label_set_text(GTK_LABEL(c->status), ok ? "Saved to keyring · key stored" : "Failed to store key");
        gtk_widget_set_visible(c->dot, ok);
        gtk_editable_set_text(GTK_EDITABLE(c->entry), "••••••••");
        g_object_set_data(G_OBJECT(c->entry), "has-key", GINT_TO_POINTER(1));
    }), sctx);
    g_signal_connect(clear, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
        SaveCtx *c=(SaveCtx*)d;
        store_cloud_api_key(c->pid, "");
        gtk_editable_set_text(GTK_EDITABLE(c->entry), "");
        g_object_set_data(G_OBJECT(c->entry), "has-key", nullptr);
        gtk_widget_set_visible(c->dot, FALSE);
        gtk_label_set_text(GTK_LABEL(c->status), "Key cleared — add one to enable");
    }), sctx);

    // action row — Use for Tessy (local agent, separate from personal context) + Test
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *use = gtk_button_new_with_label("Use for Tessy");
    gtk_widget_add_css_class(use, "pill"); gtk_widget_add_css_class(use, "suggested-action");
    GtkWidget *test = gtk_button_new_with_label("Test");
    gtk_widget_add_css_class(test, "pill");
    // mark active provider via GSettings
    {
        GSettings *gs = g_settings_new("org.tessera.TesseraStudio");
        char *cur = g_settings_get_string(gs, "cloud-provider");
        if(cur && cp.id==cur) gtk_widget_add_css_class(use, "accent");
        g_free(cur); g_object_unref(gs);
    }
    gtk_box_append(GTK_BOX(actions), use); gtk_box_append(GTK_BOX(actions), test);
    gtk_box_append(GTK_BOX(card), actions);

    // Use for Agent — drives AgentLoop via GSettings (provider=remote_api, cloud-provider=id)
    g_signal_connect(use, "clicked", G_CALLBACK(+[](GtkButton *b, gpointer d){
        SaveCtx *c=(SaveCtx*)d;
        if(!has_cloud_api_key(c->pid)){
            gtk_label_set_text(GTK_LABEL(c->status), "Add API key first");
            return;
        }
        GSettings *gs = g_settings_new("org.tessera.TesseraStudio");
        g_settings_set_string(gs, "provider", "remote_api");
        g_settings_set_string(gs, "cloud-provider", c->pid.c_str());
        // also set remote-base-url for compat
        std::string base = cloud_base_url_for(c->pid);
        g_settings_set_string(gs, "remote-base-url", base.c_str());
        g_object_unref(gs);
        gtk_label_set_text(GTK_LABEL(c->status), "Tessy will use this provider · your personal context stays separate");
        gtk_widget_add_css_class(GTK_WIDGET(b), "accent");
        // also notify via GNotification
        GApplication *app = g_application_get_default();
        if(app){
            GNotification *n = g_notification_new("Tessy switched provider");
            std::string body = "Tessy now drives via " + c->pid + " — your personal context stays local";
            g_notification_set_body(n, body.c_str());
            g_application_send_notification(app, "provider-switch", n);
            g_object_unref(n);
        }
    }), sctx);
    // Test — small soup GET /v1/models or echo via provider send
    g_signal_connect(test, "clicked", G_CALLBACK(+[](GtkButton *b, gpointer d){
        SaveCtx *c=(SaveCtx*)d;
        if(!has_cloud_api_key(c->pid)){
            gtk_label_set_text(GTK_LABEL(c->status), "No key — cannot test");
            return;
        }
        gtk_label_set_text(GTK_LABEL(c->status), "Testing…");
        gtk_widget_set_sensitive(GTK_WIDGET(b), FALSE);
        std::string pid = c->pid;
        GtkWidget *status_w = c->status; GtkWidget *btn = GTK_WIDGET(b);
        struct P{ std::string pid; GtkWidget *status; GtkWidget *btn; };
        g_thread_new("provider-test", [](gpointer p)->gpointer{
            P *pp=(P*)p;
            Engine eng;
            auto *prov = eng.provider_for(pp->pid); // cloud id directly
            bool ok=false; std::string err;
            prov->send("ping", [&](const std::string &delta, bool done){
                if(!delta.empty()) ok=true;
                if(done){
                    std::string *msg = new std::string(ok ? "Test ok — streaming worked" : "No data — check key/network");
                    g_idle_add([](gpointer dd)->gboolean{
                        auto *m=(std::pair<P*,std::string*>*)dd;
                        gtk_label_set_text(GTK_LABEL(m->first->status), m->second->c_str());
                        gtk_widget_set_sensitive(m->first->btn, TRUE);
                        delete m->second; delete m; return G_SOURCE_REMOVE;
                    }, new std::pair<P*,std::string*>(pp, msg));
                }
            }, [&](const std::string &e){
                err=e;
                std::string *msg = new std::string("Test failed: " + e.substr(0,120));
                g_idle_add([](gpointer dd)->gboolean{
                    auto *m=(std::pair<P*,std::string*>*)dd;
                    gtk_label_set_text(GTK_LABEL(m->first->status), m->second->c_str());
                    gtk_widget_set_sensitive(m->first->btn, TRUE);
                    delete m->second; delete m; return G_SOURCE_REMOVE;
                }, new std::pair<P*,std::string*>(pp, msg));
            });
            delete prov;
            return nullptr;
        }, new P{pid, status_w, btn});
    }), sctx);

    return card;
}

GtkWidget* providers_surface_new(){
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(outer, 12); gtk_widget_set_margin_start(outer, 12); gtk_widget_set_margin_end(outer, 12); gtk_widget_set_margin_bottom(outer, 12);

    GtkWidget *hdr = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *title = gtk_label_new("Cloud Providers");
    gtk_widget_add_css_class(title, "title-2"); gtk_label_set_xalign(GTK_LABEL(title), 0);
    GtkWidget *sub = gtk_label_new("Add an API key to drive the agent loop. Keys stay in libsecret (GNOME Keyring), never in config. Select one to make chat + agent use it.");
    gtk_widget_add_css_class(sub, "dim-label"); gtk_label_set_wrap(GTK_LABEL(sub), TRUE); gtk_label_set_xalign(GTK_LABEL(sub), 0);
    gtk_box_append(GTK_BOX(hdr), title); gtk_box_append(GTK_BOX(hdr), sub);
    gtk_box_append(GTK_BOX(outer), hdr);

    // active provider banner — Tessy vs your personal context
    {
        GSettings *gs = g_settings_new("org.tessera.TesseraStudio");
        char *prov = g_settings_get_string(gs, "provider");
        char *cloud = g_settings_get_string(gs, "cloud-provider");
        std::string txt;
        if(prov && std::string(prov)=="remote_api" && cloud && *cloud) txt = std::string("Tessy uses: ") + cloud + " · remote_api — your personal context stays local";
        else if(prov && std::string(prov)=="on_device") txt = "Tessy uses: on-device (libllama) — fully local, separate from your personal context";
        else txt = "Tessy uses: placeholder — pick a provider below. Your personal context (notes/mail) stays yours until you share it";
        GtkWidget *banner = gtk_label_new(txt.c_str());
        gtk_widget_add_css_class(banner, "caption"); gtk_widget_add_css_class(banner, "dim-label");
        gtk_label_set_xalign(GTK_LABEL(banner), 0); gtk_widget_add_css_class(banner, "card");
        gtk_widget_set_margin_top(banner, 4);
        gtk_box_append(GTK_BOX(outer), banner);
        g_free(prov); g_free(cloud); g_object_unref(gs);
    }

    GtkWidget *flow = gtk_flow_box_new();
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow), 3);
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(flow), 1);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow), 12);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow), 12);
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(flow), TRUE);

    for(auto &cp: cloud_providers()){
        if(cp.id=="generic") continue; // hide generic in card view; still usable via settings
        GtkWidget *card = provider_card_new(cp);
        gtk_flow_box_append(GTK_FLOW_BOX(flow), card);
    }

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), flow);
    gtk_box_append(GTK_BOX(outer), scroll);

    // Local models — intentional, on-demand via dialog, not main nav (calibration/quantization hidden here)
    GtkWidget *local_hdr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *local_title = gtk_label_new("Local Models");
    gtk_widget_add_css_class(local_title, "title-3"); gtk_label_set_xalign(GTK_LABEL(local_title), 0); gtk_widget_set_hexpand(local_title, TRUE);
    GtkWidget *fetch_btn = gtk_button_new_with_label("Fetch & Quantize…");
    gtk_widget_add_css_class(fetch_btn, "pill"); gtk_widget_set_tooltip_text(fetch_btn, "Download & quantize — on demand, not in main view");
    gtk_box_append(GTK_BOX(local_hdr), local_title); gtk_box_append(GTK_BOX(local_hdr), fetch_btn);
    gtk_box_append(GTK_BOX(outer), local_hdr);
    GtkWidget *local_sub = gtk_label_new("GGUF files in XDG_DATA_HOME/tessera/models — stays on disk. Calibration/quantization only runs when you fetch & quantize.");
    gtk_widget_add_css_class(local_sub, "caption"); gtk_widget_add_css_class(local_sub, "dim-label");
    gtk_label_set_wrap(GTK_LABEL(local_sub), TRUE); gtk_label_set_xalign(GTK_LABEL(local_sub), 0);
    gtk_box_append(GTK_BOX(outer), local_sub);
    // wire fetch dialog
    g_signal_connect(fetch_btn, "clicked", G_CALLBACK(+[](GtkButton*, gpointer p){
        GtkWindow *win = GTK_WINDOW(gtk_widget_get_root(GTK_WIDGET(p)));
        if(!GTK_IS_WINDOW(win)) win = nullptr;
        models_fetch_dialog_new(win);
    }), fetch_btn);

    GtkWidget *foot = gtk_label_new("Cloud via libsoup3 streaming; local via libllama dlopen. Agent respects your choice per turn — no calibration UI clutters the main view.");
    gtk_widget_add_css_class(foot, "caption"); gtk_widget_add_css_class(foot, "dim-label");
    gtk_label_set_wrap(GTK_LABEL(foot), TRUE); gtk_label_set_xalign(GTK_LABEL(foot), 0);
    gtk_box_append(GTK_BOX(outer), foot);
    return outer;
}
void providers_surface_refresh(GtkWidget*){}

} // namespace tessera
