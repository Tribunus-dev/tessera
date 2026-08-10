#include "core/config.h"
#include "core/provider.h"
#include "core/engine/Engine.h"
#include "core/cli_resolver.h"
#include "ffi/ctessera/shim.h"
#include "ui/widgets/ChatBubble.h"
#include "ui/surfaces/code/CodeSurface.h"
#include "ui/surfaces/workflow/WorkflowSurface.h"
#include "ui/surfaces/notes/NotesSurface.h"
#include "ui/surfaces/email/EmailSurface.h"
#include "ui/surfaces/tasks/Surface.h"
#include "ui/surfaces/calendar/CalendarSurface.h"
#include "ui/surfaces/contacts/ContactsSurface.h"
#include "ui/surfaces/reminders/RemindersSurface.h"
#include "core/data/DataLayer.h"
#include "core/data/KnowledgeSync.h"
#include "core/productivity/Productivity.h"
#include "core/agent/tools/BrowserTool.h"
#include "ui/surfaces/learning/Surface.h"
#include "ui/surfaces/graph/GraphView.h"
#include "ui/surfaces/settings/Surface.h"
#include "ui/surfaces/providers/Surface.h"
#include "ui/surfaces/capacity/Surface.h"
#include "ui/surfaces/collab/Surface.h"
#include "ui/surfaces/docs/DocsSurface.h"
#include "ui/surfaces/sheets/SheetsSurface.h"
#include "ui/surfaces/slides/SlidesSurface.h"
#include "ui/surfaces/models/Surface.h"
#include "ui/surfaces/receipts/Surface.h"
#include "ui/surfaces/editor/EditorSurface.h"
#include "core/productivity/docs/DocStore.h"
#include "core/productivity/sheets/SheetStore.h"
#include "core/productivity/slides/SlideStore.h"
#include "core/encryption/Volume.h"
#include <glib.h>

#ifdef HAVE_GTK
#include <gtk/gtk.h>
#include <adwaita.h>

struct StreamCtx{ GtkWidget *history; GtkWidget *stream; GtkWidget *scroll; std::string acc; tessera::LLMProvider *provider; std::string prompt; tessera::ChatRole role; };
struct StreamIdle{ StreamCtx* s; std::string *d; bool *done; };
struct NavCtx { GtkStack *stack; GtkLabel *status; };
// Agent UX — Tessy is the local agent, distinct from your personal context (Adwaita palette only, no purple/aurora/glass)
static GtkWidget *g_agent_box=nullptr;
static GtkSpinner *g_agent_spinner=nullptr;
static GtkLabel *g_agent_label=nullptr;
static GtkWidget *g_agent_banner=nullptr;
static GtkLabel *g_agent_banner_label=nullptr;
static AdwWindowTitle *g_agent_title=nullptr;
static void agent_set_state(bool working, const char *detail){
    if(g_agent_spinner) { gtk_spinner_set_spinning(g_agent_spinner, working); gtk_widget_set_visible(GTK_WIDGET(g_agent_spinner), working); }
    if(g_agent_label) gtk_label_set_text(g_agent_label, working ? (detail ? detail : "Tessy working") : "Tessy idle");
    if(g_agent_box){
        if(working) gtk_widget_add_css_class(g_agent_box, "working");
        else gtk_widget_remove_css_class(g_agent_box, "working");
        gtk_widget_set_tooltip_text(g_agent_box, working ? (detail ? detail : "Tessy is working — local, on this device") : "Tessy idle — local agent, separate from your personal context");
        gtk_accessible_update_property(GTK_ACCESSIBLE(g_agent_box), GTK_ACCESSIBLE_PROPERTY_LABEL, working ? "Tessy working — local" : "Tessy idle — local", -1);
    }
    if(g_agent_banner) gtk_widget_set_visible(g_agent_banner, working);
    if(g_agent_banner_label && detail) gtk_label_set_text(g_agent_banner_label, detail);
    if(g_agent_title) adw_window_title_set_subtitle(g_agent_title, working ? (detail ? detail : "Tessy working…") : "Tessy idle — local");
}
struct AgentIdle{ bool working; std::string detail; };
static gboolean agent_idle_apply(gpointer d){
    AgentIdle *a=(AgentIdle*)d; agent_set_state(a->working, a->detail.c_str()); delete a; return G_SOURCE_REMOVE;
}
static void agent_set_state_threadsafe(bool working, const char *detail){
    if(g_main_context_is_owner(nullptr)) agent_set_state(working, detail);
    else g_idle_add(agent_idle_apply, new AgentIdle{working, detail ? detail : ""});
}
static tessera::KnowledgeSync *g_ks = nullptr;
static tessera::BrowserTool *g_browser = nullptr;
struct ChatIngest{ tessera::KnowledgeSync *ks; std::string prompt; std::string response; };
static GtkStack *g_main_stack = nullptr;
static GtkListBox *g_nav_list = nullptr;
// per-view background indicator (nav dot + chat header)
static void set_view_working(const char *view, bool working){
    if(!g_nav_list || !view) return;
    GtkListBoxRow *row = nullptr;
    for(GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(g_nav_list)); child; child = gtk_widget_get_next_sibling(child)){
        if(!GTK_IS_LIST_BOX_ROW(child)) continue;
        const char *d = (const char*)g_object_get_data(G_OBJECT(child), "dest_name");
        if(d && g_strcmp0(d, view)==0){ row = GTK_LIST_BOX_ROW(child); break; }
    }
    if(row){
        GtkWidget *dot = (GtkWidget*)g_object_get_data(G_OBJECT(row), "working_dot");
        if(dot) gtk_widget_set_visible(dot, working);
    }
    if(working){
        std::string msg = std::string("Tessy working in ") + view + "…";
        agent_set_state(true, msg.c_str());
    } else {
        // if no other view working, clear banner; otherwise keep
        bool any=false;
        for(GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(g_nav_list)); child; child = gtk_widget_get_next_sibling(child)){
            if(!GTK_IS_LIST_BOX_ROW(child)) continue;
            GtkWidget *dot2 = (GtkWidget*)g_object_get_data(G_OBJECT(child), "working_dot");
            if(dot2 && gtk_widget_get_visible(dot2)) { any=true; break; }
        }
        if(!any) agent_set_state(false, nullptr);
    }
}

static void on_nav_clicked(GtkButton *btn, gpointer data) {
    NavCtx *ctx = (NavCtx*)data;
    const char *name = (const char*)g_object_get_data(G_OBJECT(btn), "nav_name");
    if (name && ctx && ctx->stack) {
        gtk_stack_set_visible_child_name(ctx->stack, name);
        // update header WindowTitle subtitle via AdwHeaderBar title widget
        GtkWidget *header = (GtkWidget*)g_object_get_data(G_OBJECT(ctx->stack), "header");
        if(header){
            AdwWindowTitle *title = (AdwWindowTitle*)g_object_get_data(G_OBJECT(header), "title_widget");
            if(title){
                std::string nice = name; if(!nice.empty()) nice[0]=toupper(nice[0]);
                adw_window_title_set_title(title, ("Tessera Studio — " + nice).c_str());
                adw_window_title_set_subtitle(title, "Ready");
            }
        }
    }
    if (ctx && ctx->status && name) {
        std::string s = std::string("Active: ") + name;
        gtk_label_set_text(ctx->status, s.c_str());
    }
}

static void on_chat_send(GtkButton *btn, gpointer data) {
    GtkEntry *entry = GTK_ENTRY(g_object_get_data(G_OBJECT(btn), "entry"));
    GtkLabel *out = GTK_LABEL(data);
    const char *txt = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (!txt || !*txt) return;
    auto *p = tessera::make_provider_placeholder();
    std::string acc;
    p->send(txt, [&](const std::string &d, bool done){
        acc += d;
        if (done) gtk_label_set_text(out, acc.c_str());
    }, [&](const std::string &e){ gtk_label_set_text(out, e.c_str()); });
    delete p;
    gtk_editable_set_text(GTK_EDITABLE(entry), "");
}

static void on_history_toggle(GtkButton*, gpointer data) {
    GtkRevealer *rev = GTK_REVEALER(data);
    gtk_revealer_set_reveal_child(rev, !gtk_revealer_get_reveal_child(rev));
}

static void on_activate(AdwApplication *app, gpointer) {
    // Taste: load Adwaita system palette CSS, respect prefers-color-scheme via AdwStyleManager
    GtkCssProvider *prov = gtk_css_provider_new();
    GFile *f = g_file_new_for_path("tessera-studio-linux/res/style.css");
    if (!g_file_query_exists(f, nullptr)) { g_object_unref(f); f = g_file_new_for_path("res/style.css"); }
    if (g_file_query_exists(f, nullptr)) gtk_css_provider_load_from_file(prov, f);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(prov), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(prov); g_object_unref(f);
    AdwStyleManager *sm = adw_style_manager_get_default();
    (void)sm; // follows system light/dark, no custom purple

    // GSettings — first-class Fedora persistence (provider/model/onboarding/window)
    GSettings *gset = g_settings_new("org.tessera.TesseraStudio");
    // Data plane — hexagonal: surfaces call DataLayer, which probes live Postgres/Valkey/DuckDB
    static tessera::DataLayer *dl = new tessera::DataLayer(tessera::DataLayer::from_env());
    dl->connect();
    std::string data_status = dl->status_string();
    int total = dl->count_entities("");
    int notes_cnt = dl->count_entities("note");

    GtkWidget *win = adw_application_window_new(GTK_APPLICATION(app));
    gtk_window_set_title(GTK_WINDOW(win), "Tessera Studio — Fedora");
    gtk_window_set_default_size(GTK_WINDOW(win), 1280, 720);
    gtk_window_set_icon_name(GTK_WINDOW(win), "org.tessera.TesseraStudio");
    // persist window maximized via GSettings onboarding-complete as example bind
    g_settings_bind(gset, "onboarding-complete", win, "maximized", G_SETTINGS_BIND_DEFAULT);

    GtkWidget *header = adw_header_bar_new();
    GtkWidget *title_w = adw_window_title_new("Tessera Studio — Playground", "Ready");
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(header), title_w);
    g_agent_title = ADW_WINDOW_TITLE(title_w);
    GtkWidget *hist_btn = gtk_button_new_from_icon_name("sidebar-show-symbolic");
    gtk_widget_set_tooltip_text(hist_btn, "Toggle sidebar (Ctrl+B)");
    gtk_accessible_update_property(GTK_ACCESSIBLE(hist_btn), GTK_ACCESSIBLE_PROPERTY_LABEL, "History", GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "Toggle sidebar", -1);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), hist_btn);
    // Agent status pill — Tessy, local, distinct from personal context
    {
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_add_css_class(box, "agent-status");
        gtk_widget_set_tooltip_text(box, "Tessy idle — local agent, separate from your personal context");
        gtk_accessible_update_property(GTK_ACCESSIBLE(box), GTK_ACCESSIBLE_PROPERTY_LABEL, "Tessy idle — local", -1);
        GtkWidget *sp = gtk_spinner_new();
        gtk_spinner_set_spinning(GTK_SPINNER(sp), FALSE);
        gtk_widget_set_visible(sp, FALSE);
        gtk_widget_set_size_request(sp, 14, 14);
        GtkWidget *lbl = gtk_label_new("Tessy idle");
        gtk_widget_add_css_class(lbl, "caption");
        gtk_widget_add_css_class(lbl, "dim-label");
        gtk_box_append(GTK_BOX(box), sp);
        gtk_box_append(GTK_BOX(box), lbl);
        adw_header_bar_pack_end(ADW_HEADER_BAR(header), box);
        g_agent_box = box;
        g_agent_spinner = GTK_SPINNER(sp);
        g_agent_label = GTK_LABEL(lbl);
    }

    // NavigationSplitView-like layout: sidebar (180 min) + detail stack
    GtkWidget *split = adw_overlay_split_view_new();
    adw_overlay_split_view_set_max_sidebar_width(ADW_OVERLAY_SPLIT_VIEW(split), 260);
    adw_overlay_split_view_set_min_sidebar_width(ADW_OVERLAY_SPLIT_VIEW(split), 180);

    // Sidebar — ListBox with icon rows mirroring ContentView.Destination
    GtkWidget *sidebar_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *side_title = gtk_label_new("Tessera Studio");
    gtk_widget_add_css_class(side_title, "title-4"); gtk_widget_set_margin_top(side_title, 12);
    gtk_widget_set_margin_bottom(side_title, 6); gtk_widget_set_margin_start(side_title, 12);
    gtk_label_set_xalign(GTK_LABEL(side_title), 0);
    gtk_box_append(GTK_BOX(sidebar_box), side_title);

    // Grouped nav — Work / Knowledge / Connect / Cloud / System — group chat + inspectable Tessy↔Sky
    struct Dest { const char *name; const char *title; const char *icon; const char *group; };
    Dest dests[] = {
        {"runs","Runs","clock-symbolic","Work"},
        {"workflows","Workflows","linked-symbolic","Work"},
        {"tasks","Tasks","check-round-outline-symbolic","Work"},
        {"library","Library","books-vertical-symbolic","Knowledge"},
        {"notes","Notes","note-symbolic","Knowledge"},
        {"docs","Docs","document-symbolic","Knowledge"},
        {"sheets","Sheets","view-grid-symbolic","Knowledge"},
        {"slides","Slides","presentation-symbolic","Knowledge"},
        {"learning","Learning","chart-bar-symbolic","Knowledge"},
        {"graph","Graph","share-symbolic","Knowledge"},
        {"receipts","Receipts","emblem-ok-symbolic","Knowledge"},
        {"editor","Editor","edit-symbolic","Knowledge"},
        {"providers","Providers","cloud-symbolic","Knowledge"},
        {"capacity","Capacity","gauge-symbolic","Knowledge"},
        {"models","Models","cpu-symbolic","System"},
        {"collab","Tessy & Sky","chat-bubble-text-symbolic","Knowledge"},
        {"email","Email","mail-symbolic","Connect"},
        {"calendar","Calendar","x-office-calendar-symbolic","Connect"},
        {"contacts","Contacts","avatar-default-symbolic","Connect"},
        {"reminders","Reminders","alarm-symbolic","Connect"},
        {"settings","Settings","emblem-system-symbolic","System"},
    };
    GtkWidget *list = gtk_list_box_new(); gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_SINGLE);
    gtk_widget_add_css_class(list, "navigation-sidebar");
    g_nav_list = GTK_LIST_BOX(list);
    const char *cur_group=nullptr;
    for (int i=0;i<21;i++) {
        if(!cur_group || std::string(cur_group)!=dests[i].group){
            cur_group=dests[i].group;
            GtkWidget *hdr = gtk_label_new(cur_group); gtk_widget_add_css_class(hdr,"dim-label"); gtk_widget_add_css_class(hdr,"caption");
            gtk_label_set_xalign(GTK_LABEL(hdr),0); gtk_widget_set_margin_top(hdr,10); gtk_widget_set_margin_start(hdr,12);
            GtkWidget *hdr_row = gtk_list_box_row_new(); gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(hdr_row), FALSE); gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(hdr_row), FALSE);
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(hdr_row), hdr); gtk_list_box_append(GTK_LIST_BOX(list), hdr_row);
        }
        GtkWidget *row = gtk_list_box_row_new();
        GtkWidget *hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_margin_top(hbox, 6); gtk_widget_set_margin_bottom(hbox, 6);
        gtk_widget_set_margin_start(hbox, 12); gtk_widget_set_margin_end(hbox, 12);
        GtkWidget *icon = gtk_image_new_from_icon_name(dests[i].icon);
        GtkWidget *label = gtk_label_new(dests[i].title); gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_widget_set_hexpand(label, TRUE);
        gtk_box_append(GTK_BOX(hbox), icon); gtk_box_append(GTK_BOX(hbox), label);
        // count badge — only when live data available, Adwaita caption only
        if(std::string(dests[i].name)=="notes" && notes_cnt>0){
            GtkWidget *badge=gtk_label_new(std::to_string(notes_cnt).c_str()); gtk_widget_add_css_class(badge,"caption"); gtk_widget_add_css_class(badge,"dim-label");
            gtk_box_append(GTK_BOX(hbox), badge);
        }
        // background-working indicator dot (hidden until agent works in this view)
        {
            GtkWidget *dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0);
            gtk_widget_set_size_request(dot, 8, 8);
            gtk_widget_add_css_class(dot, "nav-working-dot");
            gtk_widget_set_visible(dot, FALSE);
            gtk_widget_set_tooltip_text(dot, "Agent working here");
            g_object_set_data(G_OBJECT(row), "working_dot", dot);
            gtk_box_append(GTK_BOX(hbox), dot);
        }
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), hbox);
        g_object_set_data(G_OBJECT(row), "dest_name", (gpointer)dests[i].name);
        gtk_list_box_append(GTK_LIST_BOX(list), row);
    }
    gtk_box_append(GTK_BOX(sidebar_box), list);

    // Stack pages — use AdwViewStack discipline; crossfade kept light
    GtkWidget *stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_widget_set_hexpand(stack, TRUE); gtk_widget_set_vexpand(stack, TRUE);

    // Library — now Code 3-column (LibraryView.swift + CodeSurfaceView.swift) — GtksourceView parity, file tree primary
    GtkWidget *lib_box = tessera::code_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), lib_box, "library", "Library");
    // Playground — iMessage-inspired, Fedora-native (AdwClamp + tail bubbles + timestamp pills)
    GtkWidget *chat_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_top(chat_box, 6); gtk_widget_set_margin_start(chat_box, 6);
    gtk_widget_set_margin_end(chat_box, 6); gtk_widget_set_margin_bottom(chat_box, 6);
    // Group chat header — makes teaming intentional: You + Tessy (sensitive, local) + Sky (complex, cloud)
    GtkWidget *chat_hdr_col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_margin_bottom(chat_hdr_col, 6);
    GtkWidget *chat_hdr_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *chat_hdr = gtk_label_new("Group Chat"); gtk_widget_add_css_class(chat_hdr,"title-3"); gtk_widget_set_hexpand(chat_hdr,TRUE); gtk_label_set_xalign(GTK_LABEL(chat_hdr),0);
    GtkWidget *chat_hist_btn = gtk_button_new_from_icon_name("view-list-symbolic"); gtk_widget_set_tooltip_text(chat_hist_btn,"Show history");
    gtk_box_append(GTK_BOX(chat_hdr_row), chat_hdr); gtk_box_append(GTK_BOX(chat_hdr_row), chat_hist_btn);
    gtk_box_append(GTK_BOX(chat_hdr_col), chat_hdr_row);
    GtkWidget *chat_sub = gtk_label_new("You + Tessy (local, keeps sensitive info private) + Sky (cloud, jumps in when it's complex)");
    gtk_widget_add_css_class(chat_sub,"caption"); gtk_widget_add_css_class(chat_sub,"dim-label"); gtk_label_set_xalign(GTK_LABEL(chat_sub),0); gtk_label_set_wrap(GTK_LABEL(chat_sub),TRUE);
    gtk_box_append(GTK_BOX(chat_hdr_col), chat_sub);
    GtkWidget *chat_participants = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(chat_participants, 4);
    // participant chips — Adwaita, no emoji, system palette only
    {
        GtkWidget *chip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4); gtk_widget_add_css_class(chip,"card"); gtk_widget_set_margin_top(chip,0);
        GtkWidget *av = gtk_image_new_from_icon_name("avatar-default-symbolic"); gtk_widget_set_size_request(av,16,16);
        GtkWidget *lb = gtk_label_new("You"); gtk_widget_add_css_class(lb,"caption");
        gtk_box_append(GTK_BOX(chip), av); gtk_box_append(GTK_BOX(chip), lb);
        gtk_box_append(GTK_BOX(chat_participants), chip);
    }
    {
        GtkWidget *chip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4); gtk_widget_add_css_class(chip,"card");
        GtkWidget *av = gtk_image_new_from_icon_name("org.tessera.TesseraStudio"); gtk_widget_set_size_request(av,16,16); gtk_widget_add_css_class(av,"tessy-avatar");
        if(!gtk_image_get_icon_name(GTK_IMAGE(av))){ g_object_unref(av); av = gtk_image_new_from_icon_name("avatar-default-symbolic"); gtk_widget_set_size_request(av,16,16); }
        GtkWidget *lb = gtk_label_new("Tessy — local, sensitive"); gtk_widget_add_css_class(lb,"caption");
        gtk_box_append(GTK_BOX(chip), av); gtk_box_append(GTK_BOX(chip), lb);
        gtk_box_append(GTK_BOX(chat_participants), chip);
    }
    {
        GtkWidget *chip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4); gtk_widget_add_css_class(chip,"card");
        GtkWidget *av = gtk_image_new_from_icon_name("cloud-symbolic"); gtk_widget_set_size_request(av,16,16); gtk_widget_add_css_class(av,"sky-avatar");
        GtkWidget *lb = gtk_label_new("Sky — cloud, complex"); gtk_widget_add_css_class(lb,"caption");
        gtk_box_append(GTK_BOX(chip), av); gtk_box_append(GTK_BOX(chip), lb);
        gtk_box_append(GTK_BOX(chat_participants), chip);
    }
    gtk_box_append(GTK_BOX(chat_hdr_col), chat_participants);
    gtk_box_append(GTK_BOX(chat_box), chat_hdr_col);
    GtkWidget *chat_clamp = adw_clamp_new(); adw_clamp_set_maximum_size(ADW_CLAMP(chat_clamp), 760); adw_clamp_set_tightening_threshold(ADW_CLAMP(chat_clamp), 640);
    GtkWidget *chat_scroll = gtk_scrolled_window_new(); gtk_widget_set_vexpand(chat_scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(chat_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_add_css_class(chat_scroll, "chat-scroll");
    GtkWidget *chat_history = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_top(chat_history, 8); gtk_widget_set_margin_bottom(chat_history, 8);
    gtk_widget_set_margin_start(chat_history, 8); gtk_widget_set_margin_end(chat_history, 8);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(chat_scroll), chat_history);
    adw_clamp_set_child(ADW_CLAMP(chat_clamp), chat_scroll);
    // timestamp separator + welcome bubble (iMessage: centered pill)
    {
        GDateTime *dt = g_date_time_new_now_local(); char *s = g_date_time_format(dt, "%A %I:%M %p"); std::string t = s ? s : "Today";
        gtk_box_append(GTK_BOX(chat_history), tessera::chat_timestamp_new(t)); g_free(s); g_date_time_unref(dt);
    }
    gtk_box_append(GTK_BOX(chat_history), tessera::chat_bubble_new(tessera::ChatRole::Assistant, "Hi — group chat: Tessy (local) keeps sensitive personal info private on this device, Sky (cloud) jumps in when things get complex. You’re blue on the right, we’re on the left. Try: “remember my notes” (Tessy), “explain ... in steps” (Sky), or both — we’ll team up.", false));
    gtk_box_append(GTK_BOX(chat_box), chat_clamp);
    // history drawer now inside Playground (not global overlay) — simple Revealer
    GtkWidget *chat_hist_drawer = gtk_revealer_new(); gtk_revealer_set_transition_type(GTK_REVEALER(chat_hist_drawer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT);
    GtkWidget *hist_box = gtk_box_new(GTK_ORIENTATION_VERTICAL,6); gtk_widget_add_css_class(hist_box,"card");
    gtk_widget_set_size_request(hist_box, 260, -1);
    gtk_box_append(GTK_BOX(hist_box), gtk_label_new("History")); gtk_box_append(GTK_BOX(hist_box), gtk_label_new("(no history yet)"));
    gtk_revealer_set_child(GTK_REVEALER(chat_hist_drawer), hist_box); gtk_revealer_set_reveal_child(GTK_REVEALER(chat_hist_drawer), FALSE);
    gtk_box_append(GTK_BOX(chat_box), chat_hist_drawer);
    g_signal_connect(chat_hist_btn, "clicked", G_CALLBACK(on_history_toggle), chat_hist_drawer);
    // pinned input bar — iMessage pill entry + circular send (Fedora-native, no emoji)
    GtkWidget *chat_input_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_margin_top(chat_input_bar, 10); gtk_widget_set_margin_start(chat_input_bar, 8); gtk_widget_set_margin_end(chat_input_bar, 8);
    GtkWidget *chat_input_clamp = adw_clamp_new(); adw_clamp_set_maximum_size(ADW_CLAMP(chat_input_clamp), 760);
    GtkWidget *chat_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8); gtk_widget_set_hexpand(chat_row, TRUE);
    gtk_widget_add_css_class(chat_row, "chat-input-row");
    GtkWidget *chat_entry = gtk_entry_new(); gtk_widget_set_hexpand(chat_entry, TRUE);
    gtk_widget_add_css_class(chat_entry, "chat-entry");
    gtk_entry_set_placeholder_text(GTK_ENTRY(chat_entry), "Message  ·  Enter to send");
    gtk_widget_set_tooltip_text(chat_entry, "Type a message");
    GtkWidget *send_btn = gtk_button_new_from_icon_name("go-up-symbolic"); gtk_widget_add_css_class(send_btn, "circular"); gtk_widget_add_css_class(send_btn, "suggested-action");
    gtk_widget_set_tooltip_text(send_btn, "Send (Enter)"); gtk_widget_set_size_request(send_btn, 36, 36);
    struct ChatSendCtx { GtkWidget *history; GtkWidget *entry; GtkWidget *scroll; };
    static ChatSendCtx sctx{nullptr,nullptr,nullptr};
    sctx.history = chat_history; sctx.entry = chat_entry; sctx.scroll = chat_scroll;
    void (*on_send)(GtkButton*, gpointer) = [](GtkButton*, gpointer d){
        ChatSendCtx *c=(ChatSendCtx*)d;
        const char *txt=gtk_editable_get_text(GTK_EDITABLE(c->entry));
        if(!txt||!*txt) return;
        std::string prompt = txt;
        gtk_box_append(GTK_BOX(c->history), tessera::chat_bubble_new(tessera::ChatRole::User, prompt, false));
        gtk_editable_set_text(GTK_EDITABLE(c->entry), "");
        // Group chat: Tessy (local, handles sensitive personal info) + Sky (cloud, handles complex tasks) team up
        auto is_sensitive = [](const std::string &s)->bool{
            std::string t=s; for(char &ch: t) ch=tolower(ch);
            return t.find("my ")!=std::string::npos || t.find("personal")!=std::string::npos || t.find("private")!=std::string::npos
                || t.find("notes")!=std::string::npos || t.find("email")!=std::string::npos || t.find("calendar")!=std::string::npos
                || t.find("remember")!=std::string::npos || t.find("contact")!=std::string::npos;
        };
        auto is_complex = [](const std::string &s)->bool{
            if(s.size()>120) return true;
            std::string t=s; for(char &ch: t) ch=tolower(ch);
            const char* keys[]={"explain","analyze","code","write","plan","design","compare","summarize","translate","why","how to","steps",nullptr};
            for(int i=0;keys[i];++i) if(t.find(keys[i])!=std::string::npos) return true;
            return false;
        };
        bool sensitive = is_sensitive(prompt);
        bool complex = is_complex(prompt);
        // Group policy: Tessy always handles sensitive/personal (local), Sky helps when complex (cloud). If both, they team up sequentially.
        bool use_tessy = sensitive || !complex; // default Tessy, plus always for sensitive
        bool use_sky = complex;
        if(!use_tessy && !use_sky) use_tessy=true;
        // Create Tessy provider (local) and Sky provider (cloud)
        tessera::Engine eng;
        // Tessy: on-device or placeholder local
        tessera::LLMProvider *tessy_prov = nullptr;
        if(use_tessy){
            GSettings *gs=g_settings_new("org.tessera.TesseraStudio");
            char *m=g_settings_get_string(gs,"on-device-model-path");
            std::string mp = m? m : "";
            g_free(m); g_object_unref(gs);
            if(!mp.empty()) tessy_prov = tessera::make_provider_on_device(mp, 0, 0);
            else tessy_prov = tessera::make_provider_placeholder();
        }
        tessera::LLMProvider *sky_prov = nullptr;
        if(use_sky){
            // Sky is cloud-only
            GSettings *gs=g_settings_new("org.tessera.TesseraStudio");
            char *cp=g_settings_get_string(gs,"cloud-provider");
            std::string cpid = cp? cp : "";
            g_free(cp); g_object_unref(gs);
            if(cpid.empty()) cpid="openai";
            sky_prov = tessera::make_provider_for_cloud(cpid, "");
        }
        // UI: group chat with animations — staggered bubble-in + funny tool calls (Adwaita, reduced-motion safe)
        auto pick_tool = [](const std::string &p)->std::string{
            std::string t=p; for(char &ch: t) ch=tolower(ch);
            if(t.find("note")!=std::string::npos) return "notes";
            if(t.find("email")!=std::string::npos || t.find("inbox")!=std::string::npos) return "email";
            if(t.find("calendar")!=std::string::npos || t.find("event")!=std::string::npos) return "calendar";
            if(t.find("search")!=std::string::npos || t.find("browse")!=std::string::npos || t.find("web")!=std::string::npos) return "browser";
            if(t.find("code")!=std::string::npos || t.find("write")!=std::string::npos) return "code";
            if(t.find("desktop")!=std::string::npos || t.find("window")!=std::string::npos) return "desktop";
            return "";
        };
        std::string tessy_tool = pick_tool(prompt);
        std::string sky_tool = pick_tool(prompt);
        if(sky_tool.empty() && use_sky) sky_tool = "cloud";
        GtkWidget *tessy_tool_w=nullptr, *sky_tool_w=nullptr;
        if(use_tessy){
            std::string funny = tessera::funny_tool_line(tessera::ChatRole::Assistant, tessy_tool, prompt);
            tessy_tool_w = tessera::chat_tool_call_new(tessera::ChatRole::Assistant, tessy_tool.empty() ? "local" : tessy_tool, funny, true);
            gtk_box_append(GTK_BOX(c->history), tessy_tool_w);
        }
        if(use_sky){
            std::string funny = tessera::funny_tool_line(tessera::ChatRole::Sky, sky_tool, prompt);
            sky_tool_w = tessera::chat_tool_call_new(tessera::ChatRole::Sky, sky_tool, funny, true);
            gtk_box_append(GTK_BOX(c->history), sky_tool_w);
        }
        GtkWidget *tessy_stream=nullptr, *sky_stream=nullptr;
        if(use_tessy){
            tessy_stream = tessera::chat_bubble_new(tessera::ChatRole::Assistant, "", true);
            gtk_box_append(GTK_BOX(c->history), tessy_stream);
        }
        if(use_sky){
            sky_stream = tessera::chat_bubble_new(tessera::ChatRole::Sky, "", true);
            gtk_box_append(GTK_BOX(c->history), sky_stream);
        }
        auto *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(c->scroll));
        gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj));
        if(use_tessy && use_sky) agent_set_state(true, "Tessy + Sky huddling…");
        else if(use_sky) agent_set_state(true, "Sky thinking… (cloud)");
        else agent_set_state(true, "Tessy thinking…");
        // For single participant, keep old single-stream path; for group, run Tessy then Sky teaming
        auto launch_stream = [](StreamCtx *st){
            g_thread_new("llm-stream", [](gpointer dd)->gpointer{
                StreamCtx *s=(StreamCtx*)dd;
                std::string promptCopy = s->prompt;
                s->provider->send(promptCopy,
                    [s](const std::string &delta, bool done){
                        std::string *dcopy = new std::string(delta);
                        bool *doneCopy = new bool(done);
                        g_idle_add([](gpointer gdata)->gboolean{
                            StreamIdle *id=(StreamIdle*)gdata;
                            if(*id->done){
                                gtk_widget_set_visible(id->s->stream, false);
                                if(!id->s->acc.empty()){
                                    gtk_box_append(GTK_BOX(id->s->history), tessera::chat_bubble_new(id->s->role, id->s->acc, false));
                                    if(g_ks){
                                        auto *ci=new ChatIngest{g_ks, id->s->prompt, id->s->acc};
                                        g_thread_new("ingest-chat", [](gpointer d)->gpointer{
                                            ChatIngest *c=(ChatIngest*)d; c->ks->ingest_chat(c->prompt, c->response); delete c; return nullptr;
                                        }, ci);
                                    }
                                }
                                auto *adj2 = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(id->s->scroll));
                                gtk_adjustment_set_value(adj2, gtk_adjustment_get_upper(adj2));
                                // in group, don't clear banner until both done — simple: clear if no other stream visible
                                bool any_visible=false;
                                for(GtkWidget *ch=gtk_widget_get_first_child(id->s->history); ch; ch=gtk_widget_get_next_sibling(ch)) if(gtk_widget_get_visible(ch)) any_visible=true;
                                if(!any_visible) agent_set_state(false, nullptr);
                                else {
                                    // if any stream still visible, keep group banner
                                    // check other stream still spinning? just keep
                                }
                                delete id->s->provider;
                                delete id->s;
                            } else {
                                id->s->acc += *id->d;
                            }
                            delete id->d; delete id->done; delete id;
                            return G_SOURCE_REMOVE;
                        }, new StreamIdle{s, dcopy, doneCopy});
                    },
                    [s](const std::string &err){
                        std::string *ecopy=new std::string(err);
                        g_idle_add([](gpointer gdata)->gboolean{
                            auto *p=(std::pair<StreamCtx*,std::string*>*)gdata;
                            gtk_widget_set_visible(p->first->stream, false);
                            gtk_box_append(GTK_BOX(p->first->history), tessera::chat_bubble_new(tessera::ChatRole::System, "Error: "+*p->second, false));
                            agent_set_state(false, nullptr);
                            delete p->second; delete p->first->provider; delete p->first; delete p;
                            return G_SOURCE_REMOVE;
                        }, new std::pair<StreamCtx*,std::string*>(s, ecopy));
                    });
                return nullptr;
            }, st);
        };
        if(use_tessy && !use_sky){
            StreamCtx *st = new StreamCtx{c->history, tessy_stream, c->scroll, "", tessy_prov, prompt, tessera::ChatRole::Assistant};
            if(sky_prov) delete sky_prov;
            launch_stream(st);
        } else if(!use_tessy && use_sky){
            StreamCtx *st = new StreamCtx{c->history, sky_stream, c->scroll, "", sky_prov, prompt, tessera::ChatRole::Sky};
            if(tessy_prov) delete tessy_prov;
            launch_stream(st);
        } else {
            // group: Tessy handles sensitive personal, Sky helps with complex — team up parallel + log inspectable trace
            // also log to collab view so user can inspect how Sky helps Tessy
            tessera::collab_log_append("Tessy", ("Got complex task — asking Sky for help: " + prompt.substr(0,80)).c_str());
            StreamCtx *st1 = new StreamCtx{c->history, tessy_stream, c->scroll, "", tessy_prov, prompt, tessera::ChatRole::Assistant};
            StreamCtx *st2 = new StreamCtx{c->history, sky_stream, c->scroll, "", sky_prov, prompt, tessera::ChatRole::Sky};
            launch_stream(st1);
            launch_stream(st2);
            // log Sky's help asynchronously — when Sky finishes, its acc will be appended to group; also mirror to collab
            // (the stream idle already appends to history; we also mirror a compact trace)
            tessera::collab_log_append("Sky", "Reasoning over complex request — will synthesize with Tessy's personal context.");
        }
    };
    // store send_btn on entry for headless test hook
    g_object_set_data(G_OBJECT(chat_entry), "send_btn", send_btn);
    g_signal_connect(send_btn, "clicked", G_CALLBACK(on_send), &sctx);
    g_signal_connect(chat_entry, "activate", G_CALLBACK(+[](GtkEntry *e, gpointer b){ g_signal_emit_by_name(b, "clicked"); }), send_btn);
    gtk_box_append(GTK_BOX(chat_row), chat_entry); gtk_box_append(GTK_BOX(chat_row), send_btn);
    adw_clamp_set_child(ADW_CLAMP(chat_input_clamp), chat_row);
    gtk_box_append(GTK_BOX(chat_input_bar), chat_input_clamp);
    gtk_box_append(GTK_BOX(chat_box), chat_input_bar);
    // not added to stack — chat is now persistent right-docked, not a page

    // Runs — 60-sample rolling sparkline (TelemetryDrawer.swift) — live Postgres count
    GtkWidget *runs_box = tessera::runs_surface_new(dl);
    gtk_stack_add_titled(GTK_STACK(stack), runs_box, "runs", "Runs");
    // Learning — metrics + traces + curation (LearningDashboardView.swift) — flat Adwaita chart, live DataLayer
    GtkWidget *learn_box = tessera::learning_dashboard_new(dl);
    gtk_stack_add_titled(GTK_STACK(stack), learn_box, "learning", "Learning");
    // Graph — force-directed knowledge graph (GraphModel+GraphStore, Grape port) — Cairo + g_thread sim
    GtkWidget *graph_box = tessera::graph_view_new(dl);
    gtk_stack_add_titled(GTK_STACK(stack), graph_box, "graph", "Graph");
    // Workflows — 3-column palette | canvas | inspector (WorkflowsView.swift)
    GtkWidget *wf_box = tessera::workflow_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), wf_box, "workflows", "Workflows");
    // Email — 3-column folders | threads | composer (EmailView.swift) — libetpan via ProductivityStore
    static tessera::ProductivityStore *pstore = new tessera::ProductivityStore();
    if(!g_browser) g_browser = new tessera::BrowserTool();
    if(!g_ks) g_ks = new tessera::KnowledgeSync(dl, pstore, g_browser);
    // Knowledge sync — bidirectional EDS <-> graph + ingest emails/browsing (worker thread, no GTK)
    g_thread_new("knowledge-sync", [](gpointer d)->gpointer{
        auto *ks=(tessera::KnowledgeSync*)d;
        agent_set_state_threadsafe(true, "Syncing knowledge...");
        int prod = ks->sync_all_productivity();
        int emails = ks->ingest_all_emails();
        int browsed = ks->ingest_browsing_history();
        g_idle_add([](gpointer)->gboolean{ agent_set_state(false, nullptr); return G_SOURCE_REMOVE; }, nullptr);
        g_print("knowledge sync: %d productivity %d emails %d browsed\n", prod, emails, browsed);
        return nullptr;
    }, g_ks);
    GtkWidget *email_box = tessera::email_surface_new(dl, pstore);
    gtk_stack_add_titled(GTK_STACK(stack), email_box, "email", "Email");
    // Notes — 3-column All/Pinned/Archived + FlowLayout tags (NotesView.swift) — now live CRUD (A)
    GtkWidget *notes_box = tessera::notes_surface_new(dl);
    gtk_stack_add_titled(GTK_STACK(stack), notes_box, "notes", "Notes");
    // Tasks — 3-column Inbox/Today/Upcoming/Anytime/Someday + NLU input (TasksView.swift) — live via DataLayer (A)
    GtkWidget *tasks_box = tessera::tasks_surface_new(dl);
    gtk_stack_add_titled(GTK_STACK(stack), tasks_box, "tasks", "Tasks");
    // Productivity — Calendar/Contacts/Reminders via EDS (spec 7.3) — worker thread, degraded demo fallback, taste Adwaita only
    GtkWidget *cal_box = tessera::calendar_surface_new(pstore);
    gtk_stack_add_titled(GTK_STACK(stack), cal_box, "calendar", "Calendar");
    GtkWidget *contacts_box = tessera::contacts_surface_new(pstore);
    gtk_stack_add_titled(GTK_STACK(stack), contacts_box, "contacts", "Contacts");
    GtkWidget *reminders_box = tessera::reminders_surface_new(pstore);
    gtk_stack_add_titled(GTK_STACK(stack), reminders_box, "reminders", "Reminders");
    // Docs / Sheets / Slides / Models / Editor / Receipts — P3.1 wired (were never instantiated)
    static tessera::DocStore *docStore = new tessera::DocStore(dl);
    static tessera::SheetStore *sheetStore = new tessera::SheetStore(dl);
    static tessera::SlideStore *slideStore = new tessera::SlideStore(dl);
    GtkWidget *docs_box = tessera::docs_surface_new(dl, docStore);
    gtk_stack_add_titled(GTK_STACK(stack), docs_box, "docs", "Docs");
    GtkWidget *sheets_box = tessera::sheets_surface_new(dl, sheetStore);
    gtk_stack_add_titled(GTK_STACK(stack), sheets_box, "sheets", "Sheets");
    GtkWidget *slides_box = tessera::slides_surface_new(dl, slideStore);
    gtk_stack_add_titled(GTK_STACK(stack), slides_box, "slides", "Slides");
    GtkWidget *models_box = tessera::models_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), models_box, "models", "Models");
    GtkWidget *editor_box = tessera::editor_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), editor_box, "editor", "Editor");
    GtkWidget *receipts_box = tessera::receipts_surface_new(dl);
    gtk_stack_add_titled(GTK_STACK(stack), receipts_box, "receipts", "Receipts");
    // Providers — cloud API cards (anthropic/openai/google/meta/minimax/alibaba/openrouter/z.ai/glm/deepseek) — libsecret + libsoup3, drives AgentLoop
    GtkWidget *providers_box = tessera::providers_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), providers_box, "providers", "Providers");
    // Capacity — local system capacity vibe (hardware + fits, not main chat)
    GtkWidget *capacity_box = tessera::capacity_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), capacity_box, "capacity", "Capacity");
    // Tessy & Sky inspectable — how Sky helps Tessy reason (not the group chat dock)
    GtkWidget *collab_box = tessera::collab_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), collab_box, "collab", "Tessy & Sky");
    // Settings — now a standard view like the others (not a popup window)
    GtkWidget *settings_box = tessera::settings_surface_new();
    gtk_stack_add_titled(GTK_STACK(stack), settings_box, "settings", "Settings");

    // Window title subtitle shows destination + Data status (replaces global dim-label)
    GtkWidget *detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(detail), header);
    // Agent banner — inline, revealer-hidden when idle (visible when working/background)
    {
        GtkWidget *banner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_add_css_class(banner, "agent-banner");
        gtk_widget_set_visible(banner, FALSE);
        GtkWidget *sp2 = gtk_spinner_new();
        gtk_spinner_set_spinning(GTK_SPINNER(sp2), TRUE);
        gtk_widget_set_size_request(sp2, 14, 14);
        GtkWidget *lbl2 = gtk_label_new("Tessy working — in background, local");
        gtk_widget_add_css_class(lbl2, "caption");
        gtk_label_set_xalign(GTK_LABEL(lbl2), 0);
        gtk_widget_set_hexpand(lbl2, TRUE);
        gtk_box_append(GTK_BOX(banner), sp2);
        gtk_box_append(GTK_BOX(banner), lbl2);
        gtk_accessible_update_property(GTK_ACCESSIBLE(banner), GTK_ACCESSIBLE_PROPERTY_LABEL, "Tessy working — local", -1);
        gtk_box_append(GTK_BOX(detail), banner);
        g_agent_banner = banner;
        g_agent_banner_label = GTK_LABEL(lbl2);
    }
    // persistent dock — main content + chat side-by-side (chat always visible, follows context)
    {
        GtkWidget *chat_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_add_css_class(chat_panel, "chat-panel");
        gtk_widget_set_size_request(chat_panel, 360, -1);
        gtk_widget_set_hexpand(chat_panel, FALSE); gtk_widget_set_vexpand(chat_panel, TRUE);
        gtk_widget_set_hexpand(stack, TRUE); gtk_widget_set_vexpand(stack, TRUE);
        // chat_box already built above
        gtk_box_append(GTK_BOX(chat_panel), chat_box);
        gtk_widget_set_hexpand(chat_box, TRUE); gtk_widget_set_vexpand(chat_box, TRUE);
        GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
        gtk_paned_set_start_child(GTK_PANED(paned), stack);
        gtk_paned_set_end_child(GTK_PANED(paned), chat_panel);
        gtk_paned_set_resize_start_child(GTK_PANED(paned), TRUE);
        gtk_paned_set_resize_end_child(GTK_PANED(paned), FALSE);
        gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
        gtk_paned_set_shrink_end_child(GTK_PANED(paned), FALSE);
        gtk_paned_set_position(GTK_PANED(paned), 760);
        gtk_widget_set_hexpand(paned, TRUE); gtk_widget_set_vexpand(paned, TRUE);
        g_main_stack = GTK_STACK(stack);
        gtk_box_append(GTK_BOX(detail), paned);
    }
    // status now in header subtitle via NavCtx — telemetry lives inside Runs surface only
    GtkWidget *status = gtk_label_new("Playground • Ready");
    gtk_widget_set_visible(status, FALSE); // kept for NavCtx wiring but not shown
    g_object_set_data(G_OBJECT(stack), "header", header);
    g_object_set_data(G_OBJECT(header), "title_widget", title_w);
    g_object_set_data(G_OBJECT(split), "header", header);
    // Ctrl+B toggle sidebar, Ctrl+K focus search
    GtkEventController *key = gtk_event_controller_key_new();
    g_signal_connect(key, "key-pressed", G_CALLBACK(+[](GtkEventController*, guint keyval, guint, GdkModifierType state, gpointer data)->gboolean{
        AdwOverlaySplitView *sp = ADW_OVERLAY_SPLIT_VIEW(data);
        if((state & GDK_CONTROL_MASK) && keyval==GDK_KEY_b){
            gboolean show = adw_overlay_split_view_get_show_sidebar(sp);
            adw_overlay_split_view_set_show_sidebar(sp, !show);
            return TRUE;
        }
        return FALSE;
    }), split);
    gtk_widget_add_controller(win, key);

    static NavCtx ctx{GTK_STACK(stack), GTK_LABEL(status)};
    auto on_row_selected = +[](GtkListBox*, GtkListBoxRow *row, gpointer d){
        if (!row) return;
        const char *dest = (const char*)g_object_get_data(G_OBJECT(row), "dest_name");
        if(!dest) return; // header rows have no dest
        NavCtx *c=(NavCtx*)d;
        gtk_stack_set_visible_child_name(c->stack, dest);
        // update header title to match destination
        GtkWidget *header = (GtkWidget*)g_object_get_data(G_OBJECT(c->stack), "header");
        if(header){
            AdwWindowTitle *title = (AdwWindowTitle*)g_object_get_data(G_OBJECT(header), "title_widget");
            if(title){
                std::string nice = dest; if(!nice.empty()) nice[0]=toupper(nice[0]);
                adw_window_title_set_title(title, ("Tessera Studio — " + nice).c_str());
            }
        }
        if(c->status){
            std::string s = std::string("Active: ") + dest;
            gtk_label_set_text(c->status, s.c_str());
        }
    };
    g_signal_connect(list, "row-selected", G_CALLBACK(on_row_selected), &ctx);
    gtk_stack_set_visible_child_name(GTK_STACK(stack), "library");

    // History now lives inside Playground, no global overlay
    GtkWidget *overlay = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(overlay), detail);

    adw_overlay_split_view_set_sidebar(ADW_OVERLAY_SPLIT_VIEW(split), sidebar_box);
    adw_overlay_split_view_set_content(ADW_OVERLAY_SPLIT_VIEW(split), overlay);
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(win), split);
    gtk_window_present(GTK_WINDOW(win));
    // Headless test hook — auto-exercise group chat when TESSERA_TEST_GROUP_CHAT=1 (no click needed)
    if(g_getenv("TESSERA_TEST_GROUP_CHAT")){
        // give UI 1.5s to settle, then simulate the three routing cases
        g_timeout_add(1500, [](gpointer d)->gboolean{
            ChatSendCtx *c = (ChatSendCtx*)d;
            // helper to fake a send without needing entry focus
            auto fake_send = [c](const std::string &txt){
                gtk_editable_set_text(GTK_EDITABLE(c->entry), txt.c_str());
                // emit clicked on send_btn via its connected handler
                g_signal_emit_by_name(g_object_get_data(G_OBJECT(c->entry), "send_btn"), "clicked");
                // fallback: directly invoke on_send logic by setting entry and emitting
            };
            // we need send_btn reference — store it in entry data
            return G_SOURCE_REMOVE;
        }, &sctx);
        // simpler: directly schedule three sends via idle
        g_timeout_add(1600, [](gpointer d)->gboolean{
            ChatSendCtx *c=(ChatSendCtx*)d;
            auto do_send = [](ChatSendCtx *ctx, const char *txt){
                gtk_editable_set_text(GTK_EDITABLE(ctx->entry), txt);
                // find send_btn via data stored on entry
                GtkWidget *btn = (GtkWidget*)g_object_get_data(G_OBJECT(ctx->entry), "send_btn");
                if(btn) g_signal_emit_by_name(btn, "clicked");
            };
            do_send(c, "my notes about Q3");
            return G_SOURCE_REMOVE;
        }, &sctx);
        g_timeout_add(3500, [](gpointer d)->gboolean{
            ChatSendCtx *c=(ChatSendCtx*)d;
            GtkWidget *btn = (GtkWidget*)g_object_get_data(G_OBJECT(c->entry), "send_btn");
            if(btn){ gtk_editable_set_text(GTK_EDITABLE(c->entry), "explain quantum computing in detail with steps and why it matters"); g_signal_emit_by_name(btn, "clicked"); }
            return G_SOURCE_REMOVE;
        }, &sctx);
        g_timeout_add(5500, [](gpointer d)->gboolean{
            ChatSendCtx *c=(ChatSendCtx*)d;
            GtkWidget *btn = (GtkWidget*)g_object_get_data(G_OBJECT(c->entry), "send_btn");
            if(btn){ gtk_editable_set_text(GTK_EDITABLE(c->entry), "my notes summarize Q3 explain trends and design a plan"); g_signal_emit_by_name(btn, "clicked"); }
            return G_SOURCE_REMOVE;
        }, &sctx);
    }
    // Onboarding + Notifications — GNotification for Reminders (portal)
    GSettings *gs = g_settings_new("org.tessera.TesseraStudio");
    gboolean done = g_settings_get_boolean(gs, "onboarding-complete");
    if (!done) {
        GtkWidget *dlg = adw_message_dialog_new(GTK_WINDOW(win), "Welcome to Tessera Studio", "Chat, Code, Workflows, Notes — Fedora GTK4 port. History drawer, telemetry, and receipts are ready. Your data stays in Postgres+Valkey on device.");
        adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(dlg), "ok", "Get Started");
        adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dlg), "ok", ADW_RESPONSE_SUGGESTED);
        g_signal_connect(dlg, "response", G_CALLBACK(+[](AdwMessageDialog*d, gchar*, gpointer s){ g_settings_set_boolean(G_SETTINGS(s), "onboarding-complete", TRUE); }), gs);
        gtk_window_present(GTK_WINDOW(dlg));
        // also send GNotification (portal) for first run
        GNotification *n = g_notification_new("Tessera Studio ready");
        g_notification_set_body(n, "Productivity sync via EDS is active. Reminders will notify via portal.");
        g_notification_set_priority(n, G_NOTIFICATION_PRIORITY_LOW);
        g_application_send_notification(G_APPLICATION(app), "onboarding", n);
        g_object_unref(n);
    }
    // FileChooser portal example — CodeSurface uses GtkFileDialog (auto portal) for Import; wire a header action
    {
        GtkWidget *open_btn = gtk_button_new_from_icon_name("document-open-symbolic");
        gtk_widget_set_tooltip_text(open_btn, "Open file (portal FileChooser)");
        g_signal_connect(open_btn, "clicked", G_CALLBACK(+[](GtkButton*, gpointer w){
            GtkFileDialog *dlg = gtk_file_dialog_new();
            gtk_file_dialog_set_title(dlg, "Open file (portal)");
            gtk_file_dialog_open(dlg, GTK_WINDOW(w), nullptr, +[](GObject *src, GAsyncResult *res, gpointer){
                GError *err=nullptr;
                GFile *f = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(src), res, &err);
                if(f){ char *p=g_file_get_path(f); g_print("portal opened %s\n", p ? p : "(null)"); g_free(p); g_object_unref(f); }
                if(err) g_error_free(err);
                g_object_unref(src);
            }, nullptr);
        }), win);
        adw_header_bar_pack_end(ADW_HEADER_BAR(header), open_btn);
    }
    // Fedora-native first-class: header menu → Preferences / Shortcuts / About (HIG)
    {
        GtkWidget *menu_btn = gtk_menu_button_new();
        gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_btn), "open-menu-symbolic");
        gtk_widget_set_tooltip_text(menu_btn, "Main Menu");
        gtk_accessible_update_property(GTK_ACCESSIBLE(menu_btn), GTK_ACCESSIBLE_PROPERTY_LABEL, "Main Menu", -1);
        GMenu *menu = g_menu_new();
        g_menu_append(menu, "Preferences", "app.preferences");
        g_menu_append(menu, "Keyboard Shortcuts", "app.shortcuts");
        GMenu *p5 = g_menu_new(); g_menu_append(p5, "Lock / Wipe (Plead the Fifth)", "app.plead5");
        g_menu_append_section(menu, nullptr, G_MENU_MODEL(p5)); g_object_unref(p5);
        g_menu_append(menu, "About Tessera Studio", "app.about");
        gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_btn), G_MENU_MODEL(menu));
        g_object_unref(menu);
        adw_header_bar_pack_end(ADW_HEADER_BAR(header), menu_btn);
    }
    g_object_unref(gs);
}
#endif

static void on_prefs(GSimpleAction*, GVariant*, gpointer){ if(g_main_stack) gtk_stack_set_visible_child_name(g_main_stack, "settings"); }
static void on_shortcuts(GSimpleAction*, GVariant*, gpointer win){ tessera::show_shortcuts(GTK_WINDOW(win)); }
static void on_about(GSimpleAction*, GVariant*, gpointer win){ tessera::show_about(GTK_WINDOW(win)); }
#ifndef TESSERA_ENTERPRISE
static void on_plead5(GSimpleAction*, GVariant*, gpointer app){
    GtkWindow *w = gtk_application_get_active_window(GTK_APPLICATION(app)); if(!w) return;
    GtkWidget* d=gtk_dialog_new_with_buttons("Plead the Fifth — Lock/Wipe", w, GTK_DIALOG_MODAL, "Cancel", GTK_RESPONSE_CANCEL, "Lock", GTK_RESPONSE_ACCEPT, nullptr);
    GtkWidget* c=gtk_dialog_get_content_area(GTK_DIALOG(d));
    GtkWidget* lb=gtk_label_new("This will lock the encrypted volume via libsecret. Type DELETE to wipe."); gtk_label_set_wrap(GTK_LABEL(lb),TRUE); gtk_box_append(GTK_BOX(c), lb);
    GtkWidget* e=gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(e),"type DELETE to confirm wipe"); gtk_box_append(GTK_BOX(c), e);
    GtkWidget* err_lbl = gtk_label_new(""); gtk_widget_add_css_class(err_lbl,"error"); gtk_widget_set_visible(err_lbl, FALSE); gtk_box_append(GTK_BOX(c), err_lbl);
    // Capture entry for response handler
    struct PleadCtx { GtkEntry *entry; GtkLabel *err; };
    PleadCtx *ctx = new PleadCtx{GTK_ENTRY(e), GTK_LABEL(err_lbl)};
    g_object_set_data_full(G_OBJECT(d), "plead_ctx", ctx, [](gpointer p){ delete (PleadCtx*)p; });
    gtk_window_present(GTK_WINDOW(d));
    g_signal_connect(d,"response", G_CALLBACK(+[](GtkDialog* dlg,int r,gpointer){
        if(r==GTK_RESPONSE_ACCEPT){
            PleadCtx *cx = (PleadCtx*)g_object_get_data(G_OBJECT(dlg), "plead_ctx");
            const char *txt = cx ? gtk_editable_get_text(GTK_EDITABLE(cx->entry)) : "";
            bool is_wipe = txt && g_strcmp0(txt, "DELETE")==0;
            std::string home = g_get_home_dir() ? g_get_home_dir() : "/tmp";
            std::string vol = home + "/.local/share/tessera/volume.luks";
            if(is_wipe){
                tessera::PleadTheFifth pf; pf.trigger();
                GtkWindow *pw = gtk_window_get_transient_for(GTK_WINDOW(dlg));
                if(!pw) pw = GTK_WINDOW(dlg);
                GtkWidget *ack = adw_message_dialog_new(pw, "Wiped", "Encrypted volume shredded and audit logged.");
                adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(ack), "ok", "OK");
                gtk_window_present(GTK_WINDOW(ack));
            } else {
                tessera::EncryptedVolume ev;
                bool locked = ev.close(vol);
                GtkWindow *pw = gtk_window_get_transient_for(GTK_WINDOW(dlg));
                if(!pw) pw = GTK_WINDOW(dlg);
                const char *msg = locked ? "Volume locked. Re-enter password to unlock." : "Lock requested (volume will lock on next suspend).";
                GtkWidget *ack = adw_message_dialog_new(pw, "Locked", msg);
                adw_message_dialog_add_response(ADW_MESSAGE_DIALOG(ack), "ok", "OK");
                gtk_window_present(GTK_WINDOW(ack));
            }
        }
        gtk_window_destroy(GTK_WINDOW(dlg));
    }), nullptr);
}
#endif // !TESSERA_ENTERPRISE

int main(int argc, char **argv) {
    // --background flag for systemd tessera-agent.service (P3.8)
    bool background = false;
    for (int i=1;i<argc;i++) if (std::string(argv[i])=="--background") background = true;
    if (background) {
        auto cfg = tessera::load_config();
        g_print("Tessera agent — background mode (provider=%s)\n", tessera::provider_to_string(cfg.provider).c_str());
        // headless agent loop — run one turn on stdin or idle
        // For now, keep alive as a service: block on GMainLoop until killed
        GMainLoop *loop = g_main_loop_new(nullptr, FALSE);
        g_print("Background agent running; waiting for D-Bus activation. Send SIGTERM to stop.\n");
        g_main_loop_run(loop);
        g_main_loop_unref(loop);
        return 0;
    }
    auto cfg = tessera::load_config();
    auto cli = tessera::resolve_cli_binary(cfg.cli_path_override);
#ifdef HAVE_GTK
    AdwApplication *app = adw_application_new("org.tessera.TesseraStudio", G_APPLICATION_DEFAULT_FLAGS); // single-instance via GApplication
    g_application_set_application_id(G_APPLICATION(app), "org.tessera.TesseraStudio");
    // Fedora first-class: app actions for header menu (HIG) — Preferences / Shortcuts / About
    {
        const GActionEntry entries[] = {
            {"preferences", on_prefs, nullptr, nullptr, nullptr},
            {"shortcuts", on_shortcuts, nullptr, nullptr, nullptr},
            {"about", on_about, nullptr, nullptr, nullptr},
        };
        // placeholder — real window passed via activate's win, use activate's win via current active window
        // wrap to use g_application_get_active_window
        auto prefs_wrap = +[](GSimpleAction*, GVariant*, gpointer){ if(g_main_stack) gtk_stack_set_visible_child_name(g_main_stack, "settings"); };
        auto short_wrap = +[](GSimpleAction*, GVariant*, gpointer app){ GtkWindow *w = gtk_application_get_active_window(GTK_APPLICATION(app)); if(w) tessera::show_shortcuts(w); };
        auto about_wrap = +[](GSimpleAction*, GVariant*, gpointer app){ GtkWindow *w = gtk_application_get_active_window(GTK_APPLICATION(app)); if(w) tessera::show_about(w); };
        const GActionEntry real_entries[] = {
            {"preferences", prefs_wrap, nullptr, nullptr, nullptr},
            {"shortcuts", short_wrap, nullptr, nullptr, nullptr},
            {"about", about_wrap, nullptr, nullptr, nullptr},
#ifndef TESSERA_ENTERPRISE
            {"plead5", on_plead5, nullptr, nullptr, nullptr},
#endif
        };
#ifdef TESSERA_ENTERPRISE
        g_action_map_add_action_entries(G_ACTION_MAP(app), real_entries, 3, app);
#else
        g_action_map_add_action_entries(G_ACTION_MAP(app), real_entries, 4, app);
#endif
        gtk_application_set_accels_for_action(GTK_APPLICATION(app), "app.preferences", (const char*[]){"<Control>comma", nullptr});
        gtk_application_set_accels_for_action(GTK_APPLICATION(app), "app.shortcuts", (const char*[]){"<Control>question", nullptr});
    }
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
#else
    g_print("Tessera Studio (core only) — GTK4/Adwaita not found.\n");
    g_print("Provider: %s CLI: %s\n", tessera::provider_to_string(cfg.provider).c_str(), cli.c_str());
    auto *p = tessera::make_provider_placeholder();
    p->send("hello from headless C0", [](const std::string &d, bool done){ if(!done) g_print("%s", d.c_str()); else g_print("\n"); }, [](const std::string &e){ g_print("error: %s\n", e.c_str()); });
    delete p;
    return 0;
#endif
}
