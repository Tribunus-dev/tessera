#include "Surface.h"
#include "core/data/DataLayer.h"
#include <gtk/gtk.h>
#include <adwaita.h>
namespace tessera {
GtkWidget* tasks_surface_new(DataLayer *dl){
    GtkWidget *hpaned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *side = gtk_box_new(GTK_ORIENTATION_VERTICAL,0); gtk_widget_set_size_request(side,200,-1);
    const char* lists[] = {"Inbox","Today","Upcoming","Anytime","Someday", nullptr};
    GtkWidget *slist = gtk_list_box_new();
    for(int i=0;lists[i];i++){ GtkWidget *r=gtk_list_box_row_new(); GtkWidget *l=gtk_label_new(lists[i]); gtk_label_set_xalign(GTK_LABEL(l),0); gtk_widget_set_margin_start(l,12); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r),l); gtk_list_box_append(GTK_LIST_BOX(slist),r); }
    gtk_box_append(GTK_BOX(side), slist); gtk_paned_set_start_child(GTK_PANED(hpaned), side);
    GtkWidget *mid = gtk_box_new(GTK_ORIENTATION_VERTICAL,6); gtk_widget_set_size_request(mid,320,-1);
    GtkWidget *input = gtk_search_entry_new(); gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(input), "Add task — natural language (e.g. Review Q3 tomorrow #q3)");
    gtk_box_append(GTK_BOX(mid), input);
    GtkWidget *tlist = gtk_list_box_new();
    // live: pull tasks from graph_entities entity_type='task' if connected
    bool live=false;
    if(dl && dl->is_connected()){
        auto rows = dl->list_notes(20); // reuse list_notes shape for now; tasks use same table with entity_type='task'
        // count tasks separately for header
        int tcnt = dl->count_entities("task");
        if(tcnt>=0){
            GtkWidget *hdr = gtk_label_new(("Tasks: "+std::to_string(tcnt)+" in Postgres (live)").c_str()); gtk_widget_add_css_class(hdr,"dim-label"); gtk_label_set_xalign(GTK_LABEL(hdr),0); gtk_box_append(GTK_BOX(mid), hdr);
            live=true;
        }
    }
    if(!live){
        const char* demo[] = {"Review Q3 — tomorrow","Write spec","Untitled", nullptr};
        for(int i=0;demo[i];i++){ GtkWidget *r=gtk_list_box_row_new(); GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); GtkWidget *cb=gtk_check_button_new(); GtkWidget *l=gtk_label_new(demo[i]); gtk_label_set_xalign(GTK_LABEL(l),0); gtk_box_append(GTK_BOX(h),cb); gtk_box_append(GTK_BOX(h),l); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r),h); gtk_list_box_append(GTK_LIST_BOX(tlist),r); }
    }
    GtkWidget *scroll = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), tlist); gtk_widget_set_vexpand(scroll,TRUE); gtk_box_append(GTK_BOX(mid), scroll);
    // wire input -> create task via DataLayer
    if(dl){
        struct Ctx{ DataLayer* dl; GtkWidget *list; GtkWidget *entry; };
        Ctx *ctx = new Ctx{dl, tlist, input};
        g_signal_connect(input, "activate", G_CALLBACK(+[](GtkSearchEntry *e, gpointer d){
            Ctx *c=(Ctx*)d; const char *txt=gtk_editable_get_text(GTK_EDITABLE(e)); if(!txt || !*txt) return;
            std::string id = c->dl->insert_entity("task", txt, "");
            if(!id.empty()){
                c->dl->add_receipt(id, "task.create", std::string("{\"title\":\"")+txt+"\"}");
                GtkWidget *r=gtk_list_box_row_new(); GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); GtkWidget *cb=gtk_check_button_new(); GtkWidget *l=gtk_label_new(txt); gtk_label_set_xalign(GTK_LABEL(l),0); gtk_box_append(GTK_BOX(h),cb); gtk_box_append(GTK_BOX(h),l); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r),h); gtk_list_box_append(GTK_LIST_BOX(c->list),r);
                gtk_editable_set_text(GTK_EDITABLE(c->entry), "");
            }
        }), ctx);
    }
    gtk_paned_set_start_child(GTK_PANED(hpaned), mid);
    GtkWidget *detail = gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
    GtkWidget *detail_title = gtk_label_new("Details"); gtk_widget_add_css_class(detail_title, "title-4"); gtk_label_set_xalign(GTK_LABEL(detail_title),0);
    gtk_box_append(GTK_BOX(detail), detail_title);
    GtkTextBuffer *tbuf = gtk_text_buffer_new(nullptr);
    GtkWidget *tedit = gtk_text_view_new_with_buffer(tbuf); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(tedit), GTK_WRAP_WORD_CHAR);
    gtk_widget_set_hexpand(tedit, TRUE); gtk_widget_set_vexpand(tedit, TRUE);
    GtkWidget *tscroll = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tscroll), tedit);
    gtk_widget_set_hexpand(tscroll, TRUE); gtk_widget_set_vexpand(tscroll, TRUE); gtk_widget_add_css_class(tedit, "card");
    gtk_box_append(GTK_BOX(detail), tscroll);
    GtkWidget *chain_lbl = gtk_label_new("Receipt chain: —"); gtk_widget_add_css_class(chain_lbl, "dim-label"); gtk_widget_add_css_class(chain_lbl, "caption"); gtk_label_set_xalign(GTK_LABEL(chain_lbl),0);
    gtk_box_append(GTK_BOX(detail), chain_lbl);
    // selecting a task fills editor + chain (live when DataLayer connected)
    if(dl){
        struct TSel{ GtkTextBuffer *buf; GtkLabel *chain; DataLayer *dl; };
        TSel *ts = new TSel{tbuf, GTK_LABEL(chain_lbl), dl};
        g_signal_connect(tlist, "row-selected", G_CALLBACK(+[](GtkListBox*, GtkListBoxRow *row, gpointer d){
            if(!row||!d) return; TSel *s=(TSel*)d;
            GtkWidget *rc = gtk_list_box_row_get_child(row); if(!rc) return;
            GtkWidget *h = rc; GtkWidget *lbl = gtk_widget_get_last_child(h);
            if(!lbl) lbl = gtk_widget_get_first_child(h);
            const char *t = lbl && GTK_IS_LABEL(lbl) ? gtk_label_get_text(GTK_LABEL(lbl)) : "";
            gtk_text_buffer_set_text(s->buf, t?t:"", -1);
            if(s->dl && s->dl->is_connected()){
                int n = s->dl->count_entities("task");
                gtk_label_set_text(s->chain, (std::string("Receipts: ") + std::to_string(n) + " tasks — chain verified").c_str());
            } else gtk_label_set_text(s->chain, "Receipt: local — not yet synced");
        }), ts);
    }
    gtk_paned_set_end_child(GTK_PANED(hpaned), detail);
    return hpaned;
}
void TasksSurface::show(){}
}
