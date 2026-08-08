#include "CalendarSurface.h"
#include "core/productivity/Productivity.h"
#include <gtk/gtk.h>
#include <adwaita.h>
namespace tessera {
GtkWidget* calendar_surface_new(ProductivityStore *store){
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box,12); gtk_widget_set_margin_start(box,12); gtk_widget_set_margin_end(box,12);
    GtkWidget *hdr = gtk_label_new("Calendar"); gtk_widget_add_css_class(hdr,"title-2"); gtk_label_set_xalign(GTK_LABEL(hdr),0);
    gtk_box_append(GTK_BOX(box), hdr);
    GtkWidget *sub = gtk_label_new("Events and schedules — synced"); gtk_widget_add_css_class(sub,"dim-label"); gtk_widget_add_css_class(sub,"caption"); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(box), sub);
    ProductivityStore local; if(!store) store=&local;
    auto evs = store->events();
    GtkWidget *list = gtk_list_box_new(); gtk_widget_add_css_class(list,"card");
    for(auto &e: evs){
        GtkWidget *r=gtk_list_box_row_new();
        GtkWidget *h=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
        GtkWidget *t=gtk_label_new(e.title.c_str()); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t,"title-4");
        GtkWidget *d=gtk_label_new(e.ical.c_str()); gtk_label_set_xalign(GTK_LABEL(d),0); gtk_widget_add_css_class(d,"dim-label"); gtk_label_set_wrap(GTK_LABEL(d),TRUE);
        gtk_box_append(GTK_BOX(h),t); gtk_box_append(GTK_BOX(h),d);
        gtk_widget_set_margin_top(h,6); gtk_widget_set_margin_bottom(h,6);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), h);
        gtk_list_box_append(GTK_LIST_BOX(list), r);
    }
    GtkWidget *scroll=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list); gtk_widget_set_vexpand(scroll,TRUE);
    gtk_box_append(GTK_BOX(box), scroll);
    GtkWidget *cap = gtk_label_new("Sync happens in the background — your calendar stays up to date"); gtk_widget_add_css_class(cap,"dim-label"); gtk_widget_add_css_class(cap,"caption"); gtk_label_set_xalign(GTK_LABEL(cap),0);
    gtk_box_append(GTK_BOX(box), cap);
    // NLU bar: natural-language event creation (port of CalendarNLUParser)
    GtkWidget* nluBar=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(nluBar,6);
    GtkWidget* nluEntry=gtk_entry_new(); gtk_widget_set_hexpand(nluEntry, TRUE); gtk_entry_set_placeholder_text(GTK_ENTRY(nluEntry), "Add event: 'Sprint review tomorrow 10am with Ada'");
    GtkWidget* nluBtn=gtk_button_new_with_label("Parse"); gtk_widget_add_css_class(nluBtn,"suggested-action");
    gtk_box_append(GTK_BOX(nluBar), nluEntry); gtk_box_append(GTK_BOX(nluBar), nluBtn);
    gtk_box_append(GTK_BOX(box), nluBar);
    struct NLUCtx{ GtkWidget* list; GtkWidget* entry; ProductivityStore* store; };
    NLUCtx* nctx=new NLUCtx{list, nluEntry, store};
    g_signal_connect(nluBtn, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
        NLUCtx* c=(NLUCtx*)d;
        const char* raw=gtk_editable_get_text(GTK_EDITABLE(c->entry));
        if(!raw || !*raw) return;
        std::string txt=raw;
        // tiny rule engine: detect "tomorrow" / "today" / "next" + time + "with <name>"
        std::string title=txt; std::string when="today";
        if(txt.find("tomorrow")!=std::string::npos) { when="tomorrow"; }
        else if(txt.find("next")!=std::string::npos) when="next week";
        // strip when words for title
        for(auto w: {" tomorrow"," today"," next week"," with "}){ auto p=title.find(w); if(p!=std::string::npos) title=title.substr(0,p); }
        if(title.empty()) title=txt;
        // create row immediately
        GtkWidget* row=gtk_list_box_row_new(); GtkWidget* h=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
        GtkWidget* t=gtk_label_new(title.c_str()); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t,"title-4");
        GtkWidget* dt=gtk_label_new((when + " · parsed via NLU").c_str()); gtk_label_set_xalign(GTK_LABEL(dt),0); gtk_widget_add_css_class(dt,"dim-label"); gtk_widget_add_css_class(dt,"caption");
        gtk_box_append(GTK_BOX(h), t); gtk_box_append(GTK_BOX(h), dt);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h); gtk_list_box_append(GTK_LIST_BOX(c->list), row);
        gtk_editable_set_text(GTK_EDITABLE(c->entry), "");
    }), nctx);
    g_signal_connect(nluEntry, "activate", G_CALLBACK(+[](GtkEntry*, gpointer d){ NLUCtx* c=(NLUCtx*)d; const char* raw=gtk_editable_get_text(GTK_EDITABLE(c->entry)); if(!raw||!*raw) return; std::string txt=raw; std::string title=txt, when="today"; if(txt.find("tomorrow")!=std::string::npos) when="tomorrow"; for(auto w: {" tomorrow"," today"}){ auto p=title.find(w); if(p!=std::string::npos) title=title.substr(0,p);} GtkWidget* row=gtk_list_box_row_new(); GtkWidget* h=gtk_box_new(GTK_ORIENTATION_VERTICAL,4); GtkWidget* t=gtk_label_new(title.c_str()); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t,"title-4"); GtkWidget* dt=gtk_label_new((when+" · parsed").c_str()); gtk_label_set_xalign(GTK_LABEL(dt),0); gtk_widget_add_css_class(dt,"dim-label"); gtk_box_append(GTK_BOX(h), t); gtk_box_append(GTK_BOX(h), dt); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h); gtk_list_box_append(GTK_LIST_BOX(c->list), row); gtk_editable_set_text(GTK_EDITABLE(c->entry),""); }), nctx);
    // + Event inline create (AdwDialog fallback to GtkDialog)
    {
        GtkWidget *add = gtk_button_new_with_label("+ Event"); gtk_widget_add_css_class(add, "pill"); gtk_widget_set_halign(add, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(box), add);
        struct CalCtx{ GtkWidget *list; ProductivityStore *store; };
        CalCtx *cctx = new CalCtx{list, store};
        g_signal_connect(add, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
            CalCtx *c=(CalCtx*)d;
            GtkWidget *dlg = gtk_dialog_new_with_buttons("New Event", nullptr, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Add", GTK_RESPONSE_ACCEPT, nullptr);
            GtkWidget *cnt = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
            GtkWidget *e = gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(e), "Event title");
            gtk_box_append(GTK_BOX(cnt), e); gtk_widget_show(dlg);
            g_signal_connect(dlg, "response", G_CALLBACK(+[](GtkDialog *dlg2, gint r, gpointer dd){
                if(r==GTK_RESPONSE_ACCEPT){
                    CalCtx *cc=(CalCtx*)dd;
                    GtkWidget *cnt2 = gtk_dialog_get_content_area(dlg2);
                    GtkWidget *en = gtk_widget_get_first_child(cnt2);
                    const char *t = en && GTK_IS_ENTRY(en) ? gtk_entry_buffer_get_text(gtk_entry_get_buffer(GTK_ENTRY(en))) : "Untitled";
                    GtkWidget *row=gtk_list_box_row_new(); GtkWidget *h=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
                    GtkWidget *tt=gtk_label_new(t); gtk_label_set_xalign(GTK_LABEL(tt),0); gtk_widget_add_css_class(tt,"title-4");
                    gtk_box_append(GTK_BOX(h), tt); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h); gtk_list_box_append(GTK_LIST_BOX(cc->list), row);
                }
                gtk_window_destroy(GTK_WINDOW(dlg2));
            }), c);
        }), cctx);
    }
    return box;
}
} // namespace
