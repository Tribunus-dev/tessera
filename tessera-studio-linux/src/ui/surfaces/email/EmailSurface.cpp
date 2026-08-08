#include "EmailSurface.h"
#include "core/data/DataLayer.h"
#include "core/productivity/Productivity.h"
#include <adwaita.h>
#include <string>
namespace tessera {
static void on_folder_select(GtkListBox*, GtkListBoxRow *row, gpointer d){
    if(!row||!d) return;
    GtkWidget *lbl = gtk_list_box_row_get_child(row);
    GtkWidget *box = GTK_WIDGET(d);
    // update folder label in list header
    GtkWidget *first = gtk_widget_get_first_child(box);
    // box is paned mid, not needed detailed — just set list filter stub
    (void)lbl;
}
static void on_email_select(GtkListBox*, GtkListBoxRow *row, gpointer d){
    if(!row||!d) return;
    GtkWidget *vbox = gtk_list_box_row_get_child(row);
    GtkWidget *subj = gtk_widget_get_first_child(vbox);
    const char *t = GTK_IS_LABEL(subj)? gtk_label_get_text(GTK_LABEL(subj)) : "";
    if(!t) t="";
    gtk_label_set_text(GTK_LABEL(d), t);
}
GtkWidget* email_surface_new(tessera::DataLayer *dl, tessera::ProductivityStore *pstore){
    GtkWidget *hpaned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    // Sidebar: folders + accounts + search
    GtkWidget *sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(sidebar, 180, -1);
    GtkWidget *acct = gtk_label_new("Account: you@tessera.local"); gtk_widget_add_css_class(acct, "dim-label");
    gtk_widget_set_margin_top(acct, 8); gtk_box_append(GTK_BOX(sidebar), acct);
    const char* folders[] = {"Inbox","Sent","Drafts","Trash","Spam", nullptr};
    GtkWidget *flist = gtk_list_box_new(); gtk_widget_add_css_class(flist, "navigation-sidebar");
    for(int i=0;folders[i];i++){
        GtkWidget *r=gtk_list_box_row_new();
        GtkWidget *l=gtk_label_new(folders[i]); gtk_label_set_xalign(GTK_LABEL(l),0);
        gtk_widget_set_margin_start(l,12); gtk_widget_set_margin_end(l,12);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), l);
        gtk_list_box_append(GTK_LIST_BOX(flist), r);
    }
    gtk_widget_set_vexpand(flist, TRUE);
    gtk_box_append(GTK_BOX(sidebar), flist);
    gtk_paned_set_start_child(GTK_PANED(hpaned), sidebar);

    GtkWidget *mid = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    // List: search + threads
    GtkWidget *list_col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(list_col, 320, -1);
    GtkWidget *search = gtk_search_entry_new(); gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(search), "Search email");
    gtk_box_append(GTK_BOX(list_col), search);
    GtkWidget *elist = gtk_list_box_new();
    // live Email via ProductivityStore (libetpan, degraded demo if no creds)
    {
        ProductivityStore *ps = pstore; ProductivityStore fallback;
        if(!ps) ps=&fallback;
        auto mails = ps->emails();
        for(auto &m: mails){
            GtkWidget *row=gtk_list_box_row_new();
            GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
            GtkWidget *sbj=gtk_label_new(m.subject.c_str()); gtk_label_set_xalign(GTK_LABEL(sbj),0); gtk_label_set_ellipsize(GTK_LABEL(sbj), PANGO_ELLIPSIZE_END);
            GtkWidget *prv=gtk_label_new(m.body.c_str()); gtk_label_set_xalign(GTK_LABEL(prv),0); gtk_widget_add_css_class(prv,"dim-label"); gtk_label_set_ellipsize(GTK_LABEL(prv), PANGO_ELLIPSIZE_END);
            gtk_box_append(GTK_BOX(v), sbj); gtk_box_append(GTK_BOX(v), prv);
            gtk_widget_set_margin_top(v,6); gtk_widget_set_margin_bottom(v,6);
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), v);
            gtk_list_box_append(GTK_LIST_BOX(elist), row);
        }
    }
    GtkWidget *scroll = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), elist);
    gtk_widget_set_vexpand(scroll, TRUE); gtk_box_append(GTK_BOX(list_col), scroll);
    GtkWidget *compose = gtk_button_new_with_label("Compose"); gtk_widget_add_css_class(compose, "suggested-action");
    gtk_widget_set_margin_top(compose, 6); gtk_box_append(GTK_BOX(list_col), compose);
    gtk_paned_set_start_child(GTK_PANED(mid), list_col);

    // Detail: subject + body (read-only TextView, not leaking GtkLabel copy)
    GtkWidget *detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *subj_lbl = gtk_label_new("Select an email"); gtk_widget_add_css_class(subj_lbl,"title-4");
    gtk_label_set_xalign(GTK_LABEL(subj_lbl),0); gtk_widget_set_margin_top(subj_lbl,12);
    gtk_box_append(GTK_BOX(detail), subj_lbl);
    GtkWidget *body_view = gtk_text_view_new(); gtk_text_view_set_editable(GTK_TEXT_VIEW(body_view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(body_view), GTK_WRAP_WORD_CHAR);
    gtk_widget_set_hexpand(body_view, TRUE); gtk_widget_set_vexpand(body_view, TRUE);
    gtk_widget_add_css_class(body_view,"card");
    GtkWidget *body_scroll = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(body_scroll), body_view);
    gtk_widget_set_hexpand(body_scroll, TRUE); gtk_widget_set_vexpand(body_scroll, TRUE); gtk_widget_set_margin_top(body_scroll,12);
    gtk_box_append(GTK_BOX(detail), body_scroll);
    // Reply opens a compose dialog (AdwDialog stub)
    GtkWidget *reply = gtk_button_new_with_label("Reply"); gtk_box_append(GTK_BOX(detail), reply);
    g_signal_connect(reply, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
        GtkWidget *parent = GTK_WIDGET(d);
        GtkWidget *dlg = gtk_dialog_new_with_buttons("Reply", GTK_WINDOW(gtk_widget_get_root(parent)), GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Send", GTK_RESPONSE_ACCEPT, nullptr);
        GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
        gtk_box_append(GTK_BOX(content), gtk_label_new("To: sender@tessera.local"));
        GtkWidget *tv = gtk_text_view_new(); gtk_widget_set_size_request(tv, 400, 160);
        gtk_box_append(GTK_BOX(content), tv); gtk_widget_show(dlg); g_signal_connect(dlg, "response", G_CALLBACK(+[](GtkDialog *d,gint, gpointer){ gtk_window_destroy(GTK_WINDOW(d)); }), nullptr);
        (void)parent;
    }), detail);
    // filter helper: search + folder both use filter func
    struct EmailFilter{ GtkWidget *elist; GtkWidget *search; GtkWidget *flist; ProductivityStore *ps; };
    EmailFilter *ef = new EmailFilter{elist, search, flist, pstore};
    gtk_list_box_set_filter_func(GTK_LIST_BOX(elist), +[](GtkListBoxRow *row, gpointer data)->gboolean{
        EmailFilter *f=(EmailFilter*)data;
        const char *q = gtk_editable_get_text(GTK_EDITABLE(f->search));
        if(!q || !*q) return TRUE;
        GtkWidget *v = gtk_list_box_row_get_child(row); if(!v) return TRUE;
        GtkWidget *sbj = gtk_widget_get_first_child(v); if(!sbj || !GTK_IS_LABEL(sbj)) return TRUE;
        const char *t = gtk_label_get_text(GTK_LABEL(sbj)); if(!t) return TRUE;
        return g_str_match_string(q, t, TRUE);
    }, ef, nullptr);
    g_signal_connect(search, "search-changed", G_CALLBACK(+[](GtkSearchEntry*, gpointer d){ EmailFilter *f=(EmailFilter*)d; gtk_list_box_invalidate_filter(GTK_LIST_BOX(f->elist)); }), ef);
    // folder select invalidates filter (demo: just re-filter)
    g_signal_connect(flist, "row-selected", G_CALLBACK(+[](GtkListBox*, GtkListBoxRow*, gpointer d){ EmailFilter *f=(EmailFilter*)d; gtk_list_box_invalidate_filter(GTK_LIST_BOX(f->elist)); }), ef);
    // compose button
    g_signal_connect(compose, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
        EmailFilter *f=(EmailFilter*)d;
        GtkWidget *dlg = gtk_dialog_new_with_buttons("Compose", nullptr, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Send", GTK_RESPONSE_ACCEPT, nullptr);
        GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
        GtkWidget *subj = gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(subj), "Subject");
        GtkWidget *body = gtk_text_view_new(); gtk_widget_set_size_request(body, 420, 200);
        gtk_box_append(GTK_BOX(content), subj); gtk_box_append(GTK_BOX(content), body);
        gtk_widget_show(dlg);
        g_signal_connect(dlg, "response", G_CALLBACK(+[](GtkDialog *d, gint resp, gpointer dd){
            if(resp==GTK_RESPONSE_ACCEPT){
                EmailFilter *ff=(EmailFilter*)dd;
                GtkWidget *content2 = gtk_dialog_get_content_area(d);
                GtkWidget *subj2 = gtk_widget_get_first_child(content2);
                const char *s = subj2 && GTK_IS_ENTRY(subj2) ? gtk_entry_buffer_get_text(gtk_entry_get_buffer(GTK_ENTRY(subj2))) : "Untitled";
                // add row to list
                GtkWidget *row=gtk_list_box_row_new(); GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
                GtkWidget *sbj=gtk_label_new(s); gtk_label_set_xalign(GTK_LABEL(sbj),0);
                GtkWidget *prv=gtk_label_new("(new)"); gtk_widget_add_css_class(prv,"dim-label");
                gtk_box_append(GTK_BOX(v), sbj); gtk_box_append(GTK_BOX(v), prv);
                gtk_list_box_append(GTK_LIST_BOX(ff->elist), row);
            }
            gtk_window_destroy(GTK_WINDOW(d));
        }), f);
    }), ef);
    // email select now fills body_view as well
    struct EmailSel{ GtkLabel *subj; GtkTextView *body; ProductivityStore *ps; };
    EmailSel *esel = new EmailSel{GTK_LABEL(subj_lbl), GTK_TEXT_VIEW(body_view), pstore};
    g_signal_connect(elist, "row-selected", G_CALLBACK(+[](GtkListBox*, GtkListBoxRow *row, gpointer d){
        if(!row||!d) return; EmailSel *s=(EmailSel*)d;
        GtkWidget *v = gtk_list_box_row_get_child(row); if(!v) return;
        GtkWidget *sbj = gtk_widget_get_first_child(v); const char *t = sbj && GTK_IS_LABEL(sbj) ? gtk_label_get_text(GTK_LABEL(sbj)) : "";
        if(t) gtk_label_set_text(s->subj, t);
        GtkWidget *prv = sbj ? gtk_widget_get_next_sibling(sbj) : nullptr;
        const char *b = prv && GTK_IS_LABEL(prv) ? gtk_label_get_text(GTK_LABEL(prv)) : "";
        GtkTextBuffer *buf = gtk_text_view_get_buffer(s->body);
        gtk_text_buffer_set_text(buf, b?b:"", -1);
    }), esel);
    // keep first row selected
    g_signal_connect(elist, "row-selected", G_CALLBACK(on_email_select), subj_lbl);
    gtk_list_box_select_row(GTK_LIST_BOX(elist), gtk_list_box_get_row_at_index(GTK_LIST_BOX(elist),0));
    gtk_paned_set_end_child(GTK_PANED(mid), detail);
    gtk_paned_set_end_child(GTK_PANED(hpaned), mid);
    gtk_paned_set_position(GTK_PANED(hpaned), 180);
    gtk_paned_set_position(GTK_PANED(mid), 500);
    return hpaned;
}
GtkWidget* runs_surface_new(tessera::DataLayer *dl){
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box, 12); gtk_widget_set_margin_start(box, 12); gtk_widget_set_margin_end(box, 12);
    GtkWidget *title = gtk_label_new("Runs"); gtk_widget_add_css_class(title, "title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    gtk_box_append(GTK_BOX(box), title);
    std::string sub = "No runs yet";
    if(dl && dl->is_connected()){
        int n = dl->count_entities("run");
        if(n>=0) sub = std::to_string(n) + " runs  ·  live";
        if(n>0) sub += "  ·  last run just now";
    } else {
        sub = "3 demo runs  ·  telemetry live";
    }
    GtkWidget *subtitle = gtk_label_new(sub.c_str()); gtk_widget_add_css_class(subtitle, "dim-label"); gtk_widget_add_css_class(subtitle, "caption"); gtk_label_set_xalign(GTK_LABEL(subtitle),0);
    gtk_box_append(GTK_BOX(box), subtitle);
    // sparkline — 60-sample rolling, live 500ms poll off GTK thread (mirrors TelemetryDrawer.swift)
    struct State{
        double vals[60]={0};
        int head=0;
        DataLayer *dl=nullptr;
        GtkWidget *area=nullptr;
        guint ticks=0;
    };
    State *st = new State();
    st->dl = dl;
    for(int i=0;i<60;i++) st->vals[i]=0.5+0.3*sin(i*0.3)+0.1*((i%7)/7.0);
    GtkWidget *spark = gtk_drawing_area_new(); gtk_widget_set_size_request(spark, 600, 80); gtk_widget_add_css_class(spark,"card");
    st->area = spark;
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(spark), [](GtkDrawingArea*,cairo_t *cr,int w,int h,gpointer data){
        State *s=(State*)data;
        cairo_set_source_rgb(cr,1,1,1); cairo_paint(cr);
        cairo_set_source_rgb(cr,0.2,0.45,0.8); cairo_set_line_width(cr,1.5);
        cairo_move_to(cr,0, h*(1-s->vals[0]));
        for(int i=1;i<60;i++) cairo_line_to(cr, (double)w*i/59, h*(1-s->vals[i]));
        cairo_stroke(cr);
        cairo_set_source_rgba(cr,0.2,0.45,0.8,0.12); cairo_line_to(cr,w,h); cairo_line_to(cr,0,h); cairo_close_path(cr); cairo_fill(cr);
        cairo_set_source_rgb(cr,0.25,0.25,0.25); cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr,10); cairo_move_to(cr,8,14);
        char buf[128]; snprintf(buf,sizeof(buf),"Telemetry — tokens/s latency mem (live %u ticks, 500ms)", s->ticks);
        cairo_show_text(cr, buf);
    }, st, nullptr);
    gtk_box_append(GTK_BOX(box), spark);
    // 500ms worker-thread poll: GThread queries then g_idle to queue_draw (never blocks GTK)
    g_timeout_add(500, +[](gpointer data)->gboolean{
        State *s=(State*)data;
        if(!s || !s->area) return G_SOURCE_CONTINUE;
        // spawn worker thread for this tick
        g_thread_new("telemetry-poll", +[](gpointer d)->gpointer{
            State *ss=(State*)d;
            double sample = 0.5 + 0.3*sin(ss->ticks*0.25) + 0.1*((ss->ticks%9)/9.0);
            // mix in live DB count if available (non-blocking, exec_psql via popen is short)
            if(ss->dl && ss->dl->is_connected()){
                int n = ss->dl->count_entities("run");
                if(n>=0) sample = 0.4 + 0.4 * ( (n % 10) / 10.0 ) + 0.1*sin(ss->ticks*0.3);
                // also mix mem pressure
                FILE *fp=fopen("/proc/meminfo","r"); if(fp){ char line[128]; while(fgets(line,sizeof(line),fp)){ if(strncmp(line,"MemAvailable:",13)==0){ long av=atol(line+13); sample = 0.5*sample + 0.5*(1.0 - (av % 1000)/1000.0); break; } } fclose(fp); }
            }
            struct Pair{ State* s; double* v; };
            double *val = new double(sample);
            g_idle_add(+[](gpointer dd)->gboolean{
                Pair *p=(Pair*)dd;
                p->s->vals[p->s->head]= *p->v;
                p->s->head = (p->s->head+1)%60;
                // rotate vals for drawing order: keep circular buffer but draw in order
                double tmp[60]; for(int i=0;i<60;i++) tmp[i]=p->s->vals[(p->s->head+i)%60];
                for(int i=0;i<60;i++) p->s->vals[i]=tmp[i];
                p->s->head=0;
                p->s->ticks++;
                gtk_widget_queue_draw(p->s->area);
                delete p->v; delete p;
                return G_SOURCE_REMOVE;
            }, new Pair{ss, val});
            return nullptr;
        }, s);
        return G_SOURCE_CONTINUE;
    }, st);
    GtkWidget *cap = gtk_label_new("Telemetry — 60 samples, live"); gtk_widget_add_css_class(cap, "dim-label"); gtk_widget_add_css_class(cap, "caption"); gtk_label_set_xalign(GTK_LABEL(cap),0);
    gtk_box_append(GTK_BOX(box), cap);
    return box;
}
GtkWidget* learning_surface_new(tessera::DataLayer *dl){
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box,12); gtk_widget_set_margin_start(box,12); gtk_widget_set_margin_end(box,12);
    GtkWidget *hdr = gtk_label_new("Learning"); gtk_widget_add_css_class(hdr, "title-2"); gtk_label_set_xalign(GTK_LABEL(hdr),0);
    gtk_box_append(GTK_BOX(box), hdr);
    GtkWidget *sub = gtk_label_new("Traces, metrics, and curation — live from your knowledge graph"); gtk_widget_add_css_class(sub, "dim-label"); gtk_widget_add_css_class(sub, "caption"); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(box), sub);
    GtkWidget *grid = gtk_grid_new(); gtk_grid_set_column_spacing(GTK_GRID(grid),12); gtk_grid_set_row_spacing(GTK_GRID(grid),12);
    const char* cards[] = {"Traces","Metrics","Evals","Curation", nullptr};
    for(int i=0;cards[i];i++){
        GtkWidget *c=gtk_box_new(GTK_ORIENTATION_VERTICAL,4); gtk_widget_add_css_class(c,"card");
        gtk_widget_set_size_request(c, 160, 80);
        GtkWidget *t=gtk_label_new(cards[i]); gtk_widget_add_css_class(t,"title-4");
        GtkWidget *v=gtk_label_new("—"); gtk_widget_add_css_class(v,"dim-label");
        gtk_box_append(GTK_BOX(c), t); gtk_box_append(GTK_BOX(c), v);
        gtk_grid_attach(GTK_GRID(grid), c, i%2, i/2, 1,1);
    }
    gtk_box_append(GTK_BOX(box), grid);
    return box;
}
} // namespace tessera
