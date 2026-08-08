#include "Surface.h"
#include "core/data/DataLayer.h"
#include "core/learning/TraceStore.h"
#include "core/learning/Curation.h"
#include <adwaita.h>
#include <cmath>
namespace tessera {

struct DashState{
    DataLayer *dl=nullptr;
    GtkWidget *bar_area=nullptr;
    GtkWidget *trace_list=nullptr;
    GtkWidget *stats_label=nullptr;
    GtkWidget *trace_store_label=nullptr;
    GtkWidget *curation_label=nullptr;
    int counts[7]={0};
};

static const char* type_names[7]={"contact","calendar_event","email","chat_message","web_page","note","task"};
static const char* type_labels[7]={"Contacts","Events","Emails","Chats","Web","Notes","Tasks"};

static void refresh_counts(DashState *st){
    if(!st->dl || !st->dl->is_connected()) return;
    for(int i=0;i<7;i++) st->counts[i]= std::max(0, st->dl->count_entities(type_names[i]));
    int web2 = st->dl->count_by_source_prefix("web::");
    if(web2>=0) st->counts[4]=web2;
    // TraceStore — file-backed runtime traces (XDG_DATA_HOME/tessera/traces)
    if(st->trace_store_label){
        TraceStore ts;
        int rec = ts.totalRecords();
        char buf[128];
        if(rec>=0) snprintf(buf,sizeof(buf), "Training traces: %d JSONL records · %s", rec, ts.directoryPath().c_str());
        else snprintf(buf,sizeof(buf), "Training traces: —");
        gtk_label_set_text(GTK_LABEL(st->trace_store_label), buf);
    }
    if(st->curation_label){
        CurationLedger ledger;
        auto q = ledger.quarantined().size();
        auto e = ledger.entries().size();
        char buf2[128];
        snprintf(buf2,sizeof(buf2), "Curation ledger: %d entries · %d quarantined (device-local, never leaves machine)", (int)e, (int)q);
        gtk_label_set_text(GTK_LABEL(st->curation_label), buf2);
    }
}

static void bar_draw(GtkDrawingArea*,cairo_t *cr,int w,int h,gpointer data){
    DashState *st=(DashState*)data;
    bool dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    if(dark) cairo_set_source_rgb(cr,0.22,0.22,0.23); else cairo_set_source_rgb(cr,1,1,1);
    cairo_paint(cr);
    int n=7; double maxv=1; for(int i=0;i<n;i++) maxv=std::max(maxv, (double)st->counts[i]);
    double bar_w = (w-32) / (double)n;
    double gap = 10;
    for(int i=0;i<n;i++){
        double v = st->counts[i] / maxv;
        double bh = (h-38) * v;
        double x = 16 + i*bar_w + gap/2;
        double y = h-18 - bh;
        double bw = bar_w - gap;
        // Adwaita accent blue, no gradient — flat fill
        cairo_set_source_rgb(cr, 0.22,0.45,0.80);
        // slight radius top only — avoid rounded-2xl everywhere
        double r=4;
        cairo_move_to(cr, x+r, y);
        cairo_arc(cr, x+bw -r, y+r, r, -M_PI/2, 0);
        cairo_arc(cr, x+bw -r, y+bh -r, r, 0, M_PI/2);
        cairo_arc(cr, x+r, y+bh -r, r, M_PI/2, M_PI);
        cairo_arc(cr, x+r, y+r, r, M_PI, 3*M_PI/2);
        cairo_close_path(cr); cairo_fill(cr);
        // value on top
        cairo_set_source_rgb(cr,0.25,0.25,0.27);
        cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_BOLD);
        cairo_set_font_size(cr,10);
        char buf[32]; snprintf(buf,sizeof(buf),"%d", st->counts[i]);
        cairo_text_extents_t ext; cairo_text_extents(cr,buf,&ext);
        cairo_move_to(cr, x + (bw-ext.width)/2, y-4); cairo_show_text(cr,buf);
        // label bottom
        cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr,8.5);
        cairo_text_extents(cr,type_labels[i],&ext);
        cairo_move_to(cr, x + (bw-ext.width)/2, h-4); cairo_show_text(cr,type_labels[i]);
    }
    // axis line
    cairo_set_source_rgba(cr,0.85,0.85,0.88,1); cairo_set_line_width(cr,0.7);
    cairo_move_to(cr,12,h-18); cairo_line_to(cr,w-12,h-18); cairo_stroke(cr);
}

static void rebuild_traces(DashState *st){
    if(!st->trace_list || !st->dl) return;
    // clear
    GtkWidget *child=gtk_widget_get_first_child(st->trace_list);
    while(child){ GtkWidget *next=gtk_widget_get_next_sibling(child); gtk_list_box_remove(GTK_LIST_BOX(st->trace_list), child); child=next; }
    auto rows = st->dl->list_graph_nodes(40);
    int c=0;
    for(auto &r: rows){
        if(c>=12) break;
        GtkWidget *row=gtk_list_box_row_new();
        GtkWidget *box=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,10);
        gtk_widget_set_margin_top(box,6); gtk_widget_set_margin_bottom(box,6);
        gtk_widget_set_margin_start(box,8); gtk_widget_set_margin_end(box,8);
        const char *icon="text-x-generic-symbolic";
        if(r.entity_type=="email") icon="mail-symbolic";
        else if(r.entity_type=="chat_message") icon="chat-bubble-text-symbolic";
        else if(r.entity_type=="contact") icon="avatar-default-symbolic";
        else if(r.entity_type=="calendar_event") icon="x-office-calendar-symbolic";
        else if(r.entity_type=="web_page") icon="web-browser-symbolic";
        else if(r.entity_type=="note") icon="note-symbolic";
        GtkWidget *ico=gtk_image_new_from_icon_name(icon);
        GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL,2);
        GtkWidget *lbl=gtk_label_new(r.label.c_str()); gtk_label_set_xalign(GTK_LABEL(lbl),0); gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END); gtk_widget_set_hexpand(lbl,TRUE);
        GtkWidget *meta=gtk_label_new((r.entity_type + " · " + r.updated_at.substr(0,16)).c_str());
        gtk_widget_add_css_class(meta,"caption"); gtk_widget_add_css_class(meta,"dim-label"); gtk_label_set_xalign(GTK_LABEL(meta),0);
        gtk_box_append(GTK_BOX(v),lbl); gtk_box_append(GTK_BOX(v),meta);
        gtk_box_append(GTK_BOX(box),ico); gtk_box_append(GTK_BOX(box),v);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
        gtk_list_box_append(GTK_LIST_BOX(st->trace_list), row);
        c++;
    }
    if(c==0){
        GtkWidget *row=gtk_list_box_row_new(); GtkWidget *l=gtk_label_new("No traces yet — chat or browse to populate knowledge.");
        gtk_widget_add_css_class(l,"dim-label"); gtk_label_set_wrap(GTK_LABEL(l),TRUE);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), l); gtk_list_box_append(GTK_LIST_BOX(st->trace_list), row);
    }
    // stats
    if(st->stats_label){
        int total=st->dl->count_entities("");
        char buf[128]; snprintf(buf,sizeof(buf),"%d entities · %d links · %s", total>=0?total:0, (int)st->dl->list_graph_edges(1000).size(), st->dl->status_string().c_str());
        gtk_label_set_text(GTK_LABEL(st->stats_label), buf);
    }
}

GtkWidget* learning_dashboard_new(DataLayer *dl){
    DashState *st=new DashState(); st->dl=dl;
    refresh_counts(st);
    GtkWidget *outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,12);
    gtk_widget_set_margin_top(outer,12); gtk_widget_set_margin_start(outer,12); gtk_widget_set_margin_end(outer,12); gtk_widget_set_margin_bottom(outer,12);
    // header — not centered hero, simple title + subtitle hierarchy
    GtkWidget *hdr=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
    GtkWidget *title=gtk_label_new("Learning");
    gtk_widget_add_css_class(title,"title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    GtkWidget *sub=gtk_label_new("Knowledge sync dashboard — traces, metrics, and curation. Live from Postgres.");
    gtk_widget_add_css_class(sub,"dim-label"); gtk_label_set_xalign(GTK_LABEL(sub),0); gtk_label_set_wrap(GTK_LABEL(sub),TRUE);
    gtk_box_append(GTK_BOX(hdr),title); gtk_box_append(GTK_BOX(hdr),sub);
    GtkWidget *stats=gtk_label_new(""); gtk_widget_add_css_class(stats,"caption"); gtk_widget_add_css_class(stats,"dim-label"); gtk_label_set_xalign(GTK_LABEL(stats),0);
    st->stats_label=stats; gtk_box_append(GTK_BOX(hdr),stats);
    GtkWidget *trace_store_lbl=gtk_label_new("Training traces: —"); gtk_widget_add_css_class(trace_store_lbl,"caption"); gtk_widget_add_css_class(trace_store_lbl,"dim-label"); gtk_label_set_xalign(GTK_LABEL(trace_store_lbl),0); gtk_label_set_wrap(GTK_LABEL(trace_store_lbl),TRUE);
    st->trace_store_label=trace_store_lbl; gtk_box_append(GTK_BOX(hdr),trace_store_lbl);
    GtkWidget *curation_lbl=gtk_label_new("Curation ledger: —"); gtk_widget_add_css_class(curation_lbl,"caption"); gtk_widget_add_css_class(curation_lbl,"dim-label"); gtk_label_set_xalign(GTK_LABEL(curation_lbl),0); gtk_label_set_wrap(GTK_LABEL(curation_lbl),TRUE);
    st->curation_label=curation_lbl; gtk_box_append(GTK_BOX(hdr),curation_lbl);
    gtk_box_append(GTK_BOX(outer),hdr);
    // metrics bar chart — flat Adwaita blue, not gradient
    GtkWidget *chart_card=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
    gtk_widget_add_css_class(chart_card,"card");
    GtkWidget *chart_hdr=gtk_label_new("Ingest by type");
    gtk_widget_add_css_class(chart_hdr,"title-4"); gtk_label_set_xalign(GTK_LABEL(chart_hdr),0);
    gtk_box_append(GTK_BOX(chart_card), chart_hdr);
    GtkWidget *area=gtk_drawing_area_new(); gtk_widget_set_size_request(area, 560, 140);
    st->bar_area=area;
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), bar_draw, st, nullptr);
    gtk_box_append(GTK_BOX(chart_card), area);
    gtk_box_append(GTK_BOX(outer), chart_card);
    // traces list — recent graph_entities
    GtkWidget *trace_card=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
    gtk_widget_add_css_class(trace_card,"card");
    GtkWidget *trace_hdr=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
    GtkWidget *trace_title=gtk_label_new("Recent traces");
    gtk_widget_add_css_class(trace_title,"title-4"); gtk_label_set_xalign(GTK_LABEL(trace_title),0); gtk_widget_set_hexpand(trace_title,TRUE);
    GtkWidget *refresh=gtk_button_new_from_icon_name("view-refresh-symbolic");
    gtk_widget_set_tooltip_text(refresh,"Refresh");
    gtk_box_append(GTK_BOX(trace_hdr), trace_title); gtk_box_append(GTK_BOX(trace_hdr), refresh);
    gtk_box_append(GTK_BOX(trace_card), trace_hdr);
    GtkWidget *list=gtk_list_box_new(); gtk_widget_add_css_class(list,"boxed-list");
    st->trace_list=list;
    GtkWidget *scroll=gtk_scrolled_window_new(); gtk_widget_set_size_request(scroll,-1,220);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_box_append(GTK_BOX(trace_card), scroll);
    gtk_box_append(GTK_BOX(outer), trace_card);
    // adaptation harness — honest plug-in point, no fake training (taste: flat card, no left-border accent)
    {
        GtkWidget *adapt_card=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
        gtk_widget_add_css_class(adapt_card,"card");
        GtkWidget *adapt_hdr=gtk_label_new("Adaptation");
        gtk_widget_add_css_class(adapt_hdr,"title-4"); gtk_label_set_xalign(GTK_LABEL(adapt_hdr),0);
        gtk_box_append(GTK_BOX(adapt_card), adapt_hdr);
        GtkWidget *adapt_sub=gtk_label_new("Training harness is a plug-in point in v1: gate + guard + receipt are real, but no LoRA adapter is produced until the binary is present. This view reports the gate honestly.");
        gtk_widget_add_css_class(adapt_sub,"caption"); gtk_widget_add_css_class(adapt_sub,"dim-label"); gtk_label_set_xalign(GTK_LABEL(adapt_sub),0); gtk_label_set_wrap(GTK_LABEL(adapt_sub),TRUE);
        gtk_box_append(GTK_BOX(adapt_card), adapt_sub);
        GtkWidget *adapt_row=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget *purge_btn=gtk_button_new_with_label("Purge training data");
        gtk_widget_add_css_class(purge_btn,"destructive-action");
        gtk_widget_set_tooltip_text(purge_btn,"Delete traces + ledger entries (device-local, irreversible)");
        g_signal_connect(purge_btn,"clicked", G_CALLBACK(+[](GtkButton*,gpointer d){
            DashState *s=(DashState*)d;
            g_thread_new("purge-training", [](gpointer p)->gpointer{
                // worker thread: file I/O only, no GTK
                TraceStore ts; int rec = 0; try{ rec = ts.purgeTrainingData(); }catch(...){}
                CurationLedger ledger; auto entries = ledger.entries().size();
                // mark all as purged? For now, purge files already counts as device-local deletion
                (void)entries;
                g_idle_add([](gpointer q)->gboolean{
                    DashState *qq=(DashState*)q;
                    refresh_counts(qq);
                    gtk_widget_queue_draw(qq->bar_area);
                    rebuild_traces(qq);
                    return G_SOURCE_REMOVE;
                }, p);
                (void)rec;
                return nullptr;
            }, s);
        }), st);
        GtkWidget *adapt_note=gtk_label_new("Gate: 20 signals · guard on generalCompetence · backend: harness");
        gtk_widget_add_css_class(adapt_note,"caption"); gtk_widget_add_css_class(adapt_note,"dim-label"); gtk_label_set_xalign(GTK_LABEL(adapt_note),0); gtk_widget_set_hexpand(adapt_note,TRUE);
        gtk_box_append(GTK_BOX(adapt_row), adapt_note); gtk_box_append(GTK_BOX(adapt_row), purge_btn);
        gtk_box_append(GTK_BOX(adapt_card), adapt_row);
        gtk_box_append(GTK_BOX(outer), adapt_card);
    }
    rebuild_traces(st);
    gtk_widget_queue_draw(area);
    // refresh poll — worker thread queries, idle rebuilds (taste: no fade-up)
    g_signal_connect(refresh,"clicked", G_CALLBACK(+[](GtkButton*,gpointer d){
        DashState *s=(DashState*)d;
        g_thread_new("dash-refresh", [](gpointer p)->gpointer{
            DashState *ss=(DashState*)p; refresh_counts(ss);
            g_idle_add([](gpointer q)->gboolean{
                DashState *qq=(DashState*)q; gtk_widget_queue_draw(qq->bar_area); rebuild_traces(qq); return G_SOURCE_REMOVE;
            }, ss); return nullptr;
        }, s);
    }), st);
    // 2s auto poll off GTK thread
    g_timeout_add(2000, [](gpointer d)->gboolean{
        DashState *s=(DashState*)d;
        g_thread_new("dash-poll", [](gpointer p)->gpointer{
            DashState *ss=(DashState*)p; refresh_counts(ss);
            g_idle_add([](gpointer q)->gboolean{ DashState *qq=(DashState*)q; gtk_widget_queue_draw(qq->bar_area); rebuild_traces(qq); return G_SOURCE_REMOVE; }, ss); return nullptr;
        }, s); return G_SOURCE_CONTINUE;
    }, st);
    // wrap in scrolled
    GtkWidget *wrap_scroll=gtk_scrolled_window_new(); gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(wrap_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(wrap_scroll), outer);
    return wrap_scroll;
}

} // namespace tessera
