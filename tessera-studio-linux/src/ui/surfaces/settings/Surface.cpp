#include "Surface.h"
#include <adwaita.h>
#include <gio/gio.h>
#include <string>

namespace tessera {

static void on_provider_selected(GObject *obj, GParamSpec*, gpointer){
    guint sel = adw_combo_row_get_selected(ADW_COMBO_ROW(obj));
    const char *vals[]={"placeholder","remote_api","on_device"};
    GSettings *s=(GSettings*)g_object_get_data(G_OBJECT(obj),"gsettings");
    if(s && sel<3) g_settings_set_string(s,"provider",vals[sel]);
}
static void on_entry_apply(AdwEntryRow *row, gpointer key){
    GSettings *s=(GSettings*)g_object_get_data(G_OBJECT(row),"gsettings");
    const char *k=(const char*)key;
    if(s && k){
        const char *t = gtk_editable_get_text(GTK_EDITABLE(row));
        g_settings_set_string(s,k,t?t:"");
    }
}
static void on_spin_gpu_changed(GObject *obj, GParamSpec*, gpointer){
    GSettings *s=(GSettings*)g_object_get_data(G_OBJECT(obj),"gsettings");
    if(s) g_settings_set_int(s,"on-device-gpu-layers", (int)adw_spin_row_get_value(ADW_SPIN_ROW(obj)));
}
static void on_spin_thr_changed(GObject *obj, GParamSpec*, gpointer){
    GSettings *s=(GSettings*)g_object_get_data(G_OBJECT(obj),"gsettings");
    if(s) g_settings_set_int(s,"on-device-threads", (int)adw_spin_row_get_value(ADW_SPIN_ROW(obj)));
}
static void on_switch_onb(GObject *obj, GParamSpec*, gpointer){
    GSettings *s=(GSettings*)g_object_get_data(G_OBJECT(obj),"gsettings");
    if(s) g_settings_set_boolean(s,"onboarding-complete", adw_switch_row_get_active(ADW_SWITCH_ROW(obj)));
}

GtkWidget* settings_window_new(GtkWindow *parent){
    GSettings *s = g_settings_new("org.tessera.TesseraStudio");
    GtkWidget *win = adw_preferences_window_new();
    gtk_window_set_transient_for(GTK_WINDOW(win), parent);
    gtk_window_set_title(GTK_WINDOW(win), "Settings");
    gtk_window_set_icon_name(GTK_WINDOW(win), "org.tessera.TesseraStudio");
    adw_preferences_window_set_search_enabled(ADW_PREFERENCES_WINDOW(win), TRUE);

    // General — provider + CLI
    AdwPreferencesPage *page_general = ADW_PREFERENCES_PAGE(adw_preferences_page_new());
    adw_preferences_page_set_title(page_general, "General");
    adw_preferences_page_set_icon_name(page_general, "applications-system-symbolic");
    adw_preferences_window_add(ADW_PREFERENCES_WINDOW(win), page_general);
    AdwPreferencesGroup *grp_provider = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_provider, "Provider");
    adw_preferences_group_set_description(grp_provider, "LLM provider · GSettings org.tessera.TesseraStudio");
    adw_preferences_page_add(page_general, grp_provider);
    GtkWidget *combo = adw_combo_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(combo), "Provider");
    adw_combo_row_set_model(ADW_COMBO_ROW(combo), G_LIST_MODEL(gtk_string_list_new((const char*[]){"placeholder","remote_api","on_device",nullptr})));
    char *cur_prov = g_settings_get_string(s, "provider");
    int idx=0;
    if(cur_prov){
        if(g_strcmp0(cur_prov,"remote_api")==0) idx=1;
        else if(g_strcmp0(cur_prov,"on_device")==0) idx=2;
        g_free(cur_prov);
    }
    adw_combo_row_set_selected(ADW_COMBO_ROW(combo), idx);
    g_object_set_data_full(G_OBJECT(combo), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(combo, "notify::selected", G_CALLBACK(on_provider_selected), nullptr);
    adw_preferences_group_add(grp_provider, GTK_WIDGET(combo));
    GtkWidget *cli_row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cli_row), "CLI path override");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(cli_row), TRUE);
    g_object_set_data_full(G_OBJECT(cli_row), "gsettings", g_object_ref(s), g_object_unref);
    {
        char *cur = g_settings_get_string(s, "cli-path");
        if(cur){ gtk_editable_set_text(GTK_EDITABLE(cli_row), cur); g_free(cur); }
    }
    g_signal_connect(cli_row, "apply", G_CALLBACK(on_entry_apply), (gpointer)"cli-path");
    adw_preferences_group_add(grp_provider, cli_row);

    // Remote
    AdwPreferencesPage *page_remote = ADW_PREFERENCES_PAGE(adw_preferences_page_new());
    adw_preferences_page_set_title(page_remote, "Remote");
    adw_preferences_page_set_icon_name(page_remote, "network-server-symbolic");
    adw_preferences_window_add(ADW_PREFERENCES_WINDOW(win), page_remote);
    AdwPreferencesGroup *grp_remote = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_remote, "OpenAI-compatible endpoint");
    adw_preferences_page_add(page_remote, grp_remote);
    GtkWidget *url_row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(url_row), "Base URL");
    g_object_set_data_full(G_OBJECT(url_row), "gsettings", g_object_ref(s), g_object_unref);
    {
        char *cur = g_settings_get_string(s, "remote-base-url");
        if(cur){ gtk_editable_set_text(GTK_EDITABLE(url_row), cur); g_free(cur); }
    }
    g_signal_connect(url_row, "apply", G_CALLBACK(on_entry_apply), (gpointer)"remote-base-url");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(url_row), TRUE);
    adw_preferences_group_add(grp_remote, url_row);

    // On-device
    AdwPreferencesPage *page_device = ADW_PREFERENCES_PAGE(adw_preferences_page_new());
    adw_preferences_page_set_title(page_device, "On-device");
    adw_preferences_page_set_icon_name(page_device, "computer-symbolic");
    adw_preferences_window_add(ADW_PREFERENCES_WINDOW(win), page_device);
    AdwPreferencesGroup *grp_device = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_device, "GGUF / llama.cpp");
    adw_preferences_group_set_description(grp_device, "GPU layers (OpenVINO) · threads (0=auto)");
    adw_preferences_page_add(page_device, grp_device);
    GtkWidget *model_row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(model_row), "Model path");
    g_object_set_data_full(G_OBJECT(model_row), "gsettings", g_object_ref(s), g_object_unref);
    {
        char *cur = g_settings_get_string(s, "on-device-model-path");
        if(cur){ gtk_editable_set_text(GTK_EDITABLE(model_row), cur); g_free(cur); }
    }
    g_signal_connect(model_row, "apply", G_CALLBACK(on_entry_apply), (gpointer)"on-device-model-path");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(model_row), TRUE);
    adw_preferences_group_add(grp_device, model_row);
    GtkWidget *gpu_row = adw_spin_row_new_with_range(0, 128, 1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(gpu_row), "GPU layers");
    adw_spin_row_set_value(ADW_SPIN_ROW(gpu_row), g_settings_get_int(s,"on-device-gpu-layers"));
    g_object_set_data_full(G_OBJECT(gpu_row), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(gpu_row, "notify::value", G_CALLBACK(on_spin_gpu_changed), nullptr);
    adw_preferences_group_add(grp_device, gpu_row);
    GtkWidget *thr_row = adw_spin_row_new_with_range(0, 64, 1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(thr_row), "Threads");
    adw_spin_row_set_value(ADW_SPIN_ROW(thr_row), g_settings_get_int(s,"on-device-threads"));
    g_object_set_data_full(G_OBJECT(thr_row), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(thr_row, "notify::value", G_CALLBACK(on_spin_thr_changed), nullptr);
    adw_preferences_group_add(grp_device, thr_row);

    // Advanced
    AdwPreferencesPage *page_adv = ADW_PREFERENCES_PAGE(adw_preferences_page_new());
    adw_preferences_page_set_title(page_adv, "Advanced");
    adw_preferences_page_set_icon_name(page_adv, "emblem-system-symbolic");
    adw_preferences_window_add(ADW_PREFERENCES_WINDOW(win), page_adv);
    AdwPreferencesGroup *grp_adv = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_adv, "State");
    adw_preferences_page_add(page_adv, grp_adv);
    GtkWidget *onb = adw_switch_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(onb), "Onboarding complete");
    adw_switch_row_set_active(ADW_SWITCH_ROW(onb), g_settings_get_boolean(s,"onboarding-complete"));
    g_object_set_data_full(G_OBJECT(onb), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(onb, "notify::active", G_CALLBACK(on_switch_onb), nullptr);
    adw_preferences_group_add(grp_adv, onb);

    g_object_unref(s);
    return win;
}

GtkWidget* settings_surface_new(){
    GSettings *s = g_settings_new("org.tessera.TesseraStudio");
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(outer, 12); gtk_widget_set_margin_start(outer, 12); gtk_widget_set_margin_end(outer, 12); gtk_widget_set_margin_bottom(outer, 12);
    GtkWidget *hdr = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *title = gtk_label_new("Settings");
    gtk_widget_add_css_class(title, "title-2"); gtk_label_set_xalign(GTK_LABEL(title), 0);
    GtkWidget *sub = gtk_label_new("Provider, remote endpoint, on-device model — GSettings live, no restart needed.");
    gtk_widget_add_css_class(sub, "dim-label"); gtk_label_set_wrap(GTK_LABEL(sub), TRUE); gtk_label_set_xalign(GTK_LABEL(sub), 0);
    gtk_box_append(GTK_BOX(hdr), title); gtk_box_append(GTK_BOX(hdr), sub);
    gtk_box_append(GTK_BOX(outer), hdr);

    // General — provider + CLI
    AdwPreferencesGroup *grp_provider = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_provider, "Provider");
    adw_preferences_group_set_description(grp_provider, "LLM provider · GSettings org.tessera.TesseraStudio");
    GtkWidget *combo = adw_combo_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(combo), "Provider");
    adw_combo_row_set_model(ADW_COMBO_ROW(combo), G_LIST_MODEL(gtk_string_list_new((const char*[]){"placeholder","remote_api","on_device",nullptr})));
    char *cur_prov = g_settings_get_string(s, "provider");
    int idx=0;
    if(cur_prov){
        if(g_strcmp0(cur_prov,"remote_api")==0) idx=1;
        else if(g_strcmp0(cur_prov,"on_device")==0) idx=2;
        g_free(cur_prov);
    }
    adw_combo_row_set_selected(ADW_COMBO_ROW(combo), idx);
    g_object_set_data_full(G_OBJECT(combo), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(combo, "notify::selected", G_CALLBACK(on_provider_selected), nullptr);
    adw_preferences_group_add(grp_provider, GTK_WIDGET(combo));
    GtkWidget *cli_row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cli_row), "CLI path override");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(cli_row), TRUE);
    g_object_set_data_full(G_OBJECT(cli_row), "gsettings", g_object_ref(s), g_object_unref);
    {
        char *cur = g_settings_get_string(s, "cli-path");
        if(cur){ gtk_editable_set_text(GTK_EDITABLE(cli_row), cur); g_free(cur); }
    }
    g_signal_connect(cli_row, "apply", G_CALLBACK(on_entry_apply), (gpointer)"cli-path");
    adw_preferences_group_add(grp_provider, cli_row);
    gtk_box_append(GTK_BOX(outer), GTK_WIDGET(grp_provider));

    // Remote
    AdwPreferencesGroup *grp_remote = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_remote, "OpenAI-compatible endpoint");
    GtkWidget *url_row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(url_row), "Base URL");
    g_object_set_data_full(G_OBJECT(url_row), "gsettings", g_object_ref(s), g_object_unref);
    {
        char *cur = g_settings_get_string(s, "remote-base-url");
        if(cur){ gtk_editable_set_text(GTK_EDITABLE(url_row), cur); g_free(cur); }
    }
    g_signal_connect(url_row, "apply", G_CALLBACK(on_entry_apply), (gpointer)"remote-base-url");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(url_row), TRUE);
    adw_preferences_group_add(grp_remote, url_row);
    gtk_box_append(GTK_BOX(outer), GTK_WIDGET(grp_remote));

    // On-device
    AdwPreferencesGroup *grp_device = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_device, "GGUF / llama.cpp");
    adw_preferences_group_set_description(grp_device, "GPU layers (OpenVINO) · threads (0=auto)");
    GtkWidget *model_row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(model_row), "Model path");
    g_object_set_data_full(G_OBJECT(model_row), "gsettings", g_object_ref(s), g_object_unref);
    {
        char *cur = g_settings_get_string(s, "on-device-model-path");
        if(cur){ gtk_editable_set_text(GTK_EDITABLE(model_row), cur); g_free(cur); }
    }
    g_signal_connect(model_row, "apply", G_CALLBACK(on_entry_apply), (gpointer)"on-device-model-path");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(model_row), TRUE);
    adw_preferences_group_add(grp_device, model_row);
    GtkWidget *gpu_row = adw_spin_row_new_with_range(0, 128, 1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(gpu_row), "GPU layers");
    adw_spin_row_set_value(ADW_SPIN_ROW(gpu_row), g_settings_get_int(s,"on-device-gpu-layers"));
    g_object_set_data_full(G_OBJECT(gpu_row), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(gpu_row, "notify::value", G_CALLBACK(on_spin_gpu_changed), nullptr);
    adw_preferences_group_add(grp_device, gpu_row);
    GtkWidget *thr_row = adw_spin_row_new_with_range(0, 64, 1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(thr_row), "Threads");
    adw_spin_row_set_value(ADW_SPIN_ROW(thr_row), g_settings_get_int(s,"on-device-threads"));
    g_object_set_data_full(G_OBJECT(thr_row), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(thr_row, "notify::value", G_CALLBACK(on_spin_thr_changed), nullptr);
    adw_preferences_group_add(grp_device, thr_row);
    gtk_box_append(GTK_BOX(outer), GTK_WIDGET(grp_device));

    // Advanced
    AdwPreferencesGroup *grp_adv = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(grp_adv, "State");
    GtkWidget *onb = adw_switch_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(onb), "Onboarding complete");
    adw_switch_row_set_active(ADW_SWITCH_ROW(onb), g_settings_get_boolean(s,"onboarding-complete"));
    g_object_set_data_full(G_OBJECT(onb), "gsettings", g_object_ref(s), g_object_unref);
    g_signal_connect(onb, "notify::active", G_CALLBACK(on_switch_onb), nullptr);
    adw_preferences_group_add(grp_adv, onb);
    gtk_box_append(GTK_BOX(outer), GTK_WIDGET(grp_adv));

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), outer);
    g_object_unref(s);
    return scroll;
}

void show_settings(GtkWindow *parent){
    GtkWidget *w = settings_window_new(parent);
    gtk_window_present(GTK_WINDOW(w));
}
void show_shortcuts(GtkWindow *parent){
    GtkBuilder *b = gtk_builder_new_from_string(
        "<interface>"
        " <object class='GtkShortcutsWindow' id='win'>"
        "  <property name='title'>Keyboard Shortcuts</property>"
        "  <child><object class='GtkShortcutsSection'>"
        "   <property name='section-name'>general</property>"
        "   <property name='title'>General</property>"
        "   <child><object class='GtkShortcutsGroup'>"
        "    <property name='title'>Navigation</property>"
        "    <child><object class='GtkShortcutsShortcut'><property name='title'>Toggle sidebar</property><property name='accelerator'>&lt;Control&gt;b</property></object></child>"
        "    <child><object class='GtkShortcutsShortcut'><property name='title'>Preferences</property><property name='accelerator'>&lt;Control&gt;comma</property></object></child>"
        "    <child><object class='GtkShortcutsShortcut'><property name='title'>Close window</property><property name='accelerator'>&lt;Control&gt;w</property></object></child>"
        "   </object></child>"
        "  </object></child>"
        " </object>"
        "</interface>", -1);
    GtkWidget *win = GTK_WIDGET(gtk_builder_get_object(b, "win"));
    gtk_window_set_transient_for(GTK_WINDOW(win), parent);
    gtk_window_present(GTK_WINDOW(win));
    g_object_unref(b);
}
void show_about(GtkWindow *parent){
    GtkWidget *w = adw_about_window_new();
    gtk_window_set_transient_for(GTK_WINDOW(w), parent);
    adw_about_window_set_application_name(ADW_ABOUT_WINDOW(w), "Tessera Studio");
    adw_about_window_set_application_icon(ADW_ABOUT_WINDOW(w), "org.tessera.TesseraStudio");
    adw_about_window_set_version(ADW_ABOUT_WINDOW(w), "1.0");
    adw_about_window_set_developer_name(ADW_ABOUT_WINDOW(w), "The Tessera contributors");
    static const char *developers[] = {"Tessera contributors — calibrated quantization, spec decoding & studio", "Fedora GTK4 port — Adwaita, EDS/CalDAV, libetpan, Postgres+Valkey+DuckDB", nullptr};
    adw_about_window_set_developers(ADW_ABOUT_WINDOW(w), developers);
    static const char *designers[] = {"Adwaita / GNOME HIG — system palette only", nullptr};
    adw_about_window_set_designers(ADW_ABOUT_WINDOW(w), designers);
    adw_about_window_set_copyright(ADW_ABOUT_WINDOW(w), "© 2024–2026 Tessera contributors");
    adw_about_window_set_comments(ADW_ABOUT_WINDOW(w), "Local-first studio for chat, calibration and knowledge — Fedora-native, Adwaita, on your machine.");
    adw_about_window_set_website(ADW_ABOUT_WINDOW(w), "https://tessera.tribunus.dev");
    adw_about_window_set_issue_url(ADW_ABOUT_WINDOW(w), "https://github.com/ggml-org/llama.cpp/issues");
    adw_about_window_set_support_url(ADW_ABOUT_WINDOW(w), "https://github.com/tribunus-dev/tessera/discussions");
    adw_about_window_set_translator_credits(ADW_ABOUT_WINDOW(w), "Translator credits — add yours via po/");
    // intentional: release notes as plain list, no gradient/hero/bento — just Adwaita
    adw_about_window_set_release_notes(ADW_ABOUT_WINDOW(w),
        "<p>1.0 — Fedora GTK4 parity:</p>"
        "<ul>"
        "<li>11 destinations (Chat, Code, Workflows, Notes, Tasks, Learning, Graph, Email, Calendar, Contacts, Reminders) + persistent chat dock</li>"
        "<li>Adwaita system palette, light/dark via AdwStyleManager, no custom purple or glass</li>"
        "<li>Data stays local — Postgres (truth) + Valkey (cache) + DuckDB (analytics), libsecret for secrets</li>"
        "<li>On-device via libllama dlopen + Remote OpenAI-compatible via libsoup3</li>"
        "</ul>");
    adw_about_window_set_license_type(ADW_ABOUT_WINDOW(w), GTK_LICENSE_CUSTOM);
    // debug info — build + runtime, not a hero
    {
        std::string dbg = std::string("GTK ") + std::to_string(gtk_get_major_version()) + "." + std::to_string(gtk_get_minor_version())
            + " · Adwaita " + std::to_string(adw_get_major_version()) + "." + std::to_string(adw_get_minor_version())
            + " · " + (adw_style_manager_get_dark(adw_style_manager_get_default()) ? "dark" : "light")
            + " · org.tessera.TesseraStudio";
        adw_about_window_set_debug_info(ADW_ABOUT_WINDOW(w), dbg.c_str());
        adw_about_window_set_debug_info_filename(ADW_ABOUT_WINDOW(w), "tessera-studio-debug.nfo");
    }
    adw_about_window_add_legal_section(ADW_ABOUT_WINDOW(w), "Tessera", "PolyForm Noncommercial 1.0.0 — see LICENSE-TESSERA", GTK_LICENSE_CUSTOM, nullptr);
    adw_about_window_add_legal_section(ADW_ABOUT_WINDOW(w), "llama.cpp / ggml", "MIT — see LICENSE", GTK_LICENSE_MIT_X11, nullptr);
    gtk_window_present(GTK_WINDOW(w));
}

} // namespace tessera
