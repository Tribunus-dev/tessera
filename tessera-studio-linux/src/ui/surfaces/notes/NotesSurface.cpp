#include "NotesSurface.h"
#include "core/data/DataLayer.h"
#include <adwaita.h>
#include <string>
namespace tessera {
static void on_note_select(GtkListBox*, GtkListBoxRow *row, gpointer d){
    if(!row || !d) return;
    GtkWidget *row_child = gtk_list_box_row_get_child(row);
    if(!row_child) return;
    GtkWidget *vbox = row_child;
    GtkWidget *title_w = gtk_widget_get_first_child(vbox);
    if(!title_w || !GTK_IS_LABEL(title_w)) return;
    const char *title = gtk_label_get_text(GTK_LABEL(title_w));
    if(!title) title = "";
    GtkLabel *detail = GTK_LABEL(d);
    std::string body = std::string(title) + "\n\nFirst paragraph — focus mode (Cmd-\\) fades chrome, editor fills the window, bottom shows word count · reading time. Tags below using FlowLayout stub.\n\n## Heading\n\nSecond section.";
    gtk_label_set_text(detail, body.c_str());
}

GtkWidget* notes_surface_new(tessera::DataLayer *dl){
    GtkWidget *hpaned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(sidebar, 200, -1);
    GtkWidget *lib_lbl = gtk_label_new("Library"); gtk_widget_add_css_class(lib_lbl, "title-4");
    gtk_widget_set_margin_top(lib_lbl, 8); gtk_box_append(GTK_BOX(sidebar), lib_lbl);
    const char* filters[] = {"All  4","Pinned  2","Archived  1", nullptr};
    GtkWidget *filter_list = gtk_list_box_new(); gtk_widget_add_css_class(filter_list, "notes-sidebar");
    for(int i=0;filters[i];i++){
        GtkWidget *r=gtk_list_box_row_new();
        GtkWidget *l=gtk_label_new(filters[i]); gtk_label_set_xalign(GTK_LABEL(l),0);
        gtk_widget_set_margin_start(l,12); gtk_widget_set_margin_end(l,12);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), l);
        gtk_list_box_append(GTK_LIST_BOX(filter_list), r);
    }
    gtk_box_append(GTK_BOX(sidebar), filter_list);
    GtkWidget *tags = gtk_flow_box_new(); gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(tags), 10);
    const char* tag_names[] = {"q3","review","urgent", nullptr};
    for(int i=0;tag_names[i];i++){
        GtkWidget *chip = gtk_button_new_with_label(tag_names[i]);
        gtk_widget_add_css_class(chip, "pill"); gtk_widget_set_margin_start(chip, 4);
        gtk_flow_box_append(GTK_FLOW_BOX(tags), chip);
    }
    gtk_box_append(GTK_BOX(sidebar), tags);
    GtkWidget *new_btn = gtk_button_new_with_label("+ New Note"); gtk_widget_add_css_class(new_btn, "pill");
    gtk_widget_set_margin_top(new_btn, 12); gtk_box_append(GTK_BOX(sidebar), new_btn);
    gtk_paned_set_start_child(GTK_PANED(hpaned), sidebar);

    GtkWidget *mid = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *list_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(list_box, 280, -1);
    GtkWidget *list = gtk_list_box_new();
    // Live wiring: if DataLayer is connected, pull real notes from Postgres instead of static demo
    bool have_live = false;
    if(dl && dl->is_connected()){
        auto rows = dl->list_notes(20);
        if(!rows.empty()){
            have_live = true;
            for(auto &r : rows){
                GtkWidget *row=gtk_list_box_row_new();
                GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
                GtkWidget *t=gtk_label_new(r.label.c_str()); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t, "title-4");
                GtkWidget *p=gtk_label_new(r.body.c_str()); gtk_label_set_xalign(GTK_LABEL(p),0); gtk_widget_add_css_class(p, "dim-label"); gtk_label_set_wrap(GTK_LABEL(p), TRUE); gtk_label_set_ellipsize(GTK_LABEL(p), PANGO_ELLIPSIZE_END);
                gtk_box_append(GTK_BOX(v), t); gtk_box_append(GTK_BOX(v), p);
                gtk_widget_set_margin_top(v, 8); gtk_widget_set_margin_bottom(v, 8);
                gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), v);
                gtk_list_box_append(GTK_LIST_BOX(list), row);
            }
        }
    }
    if(!have_live){
        const char* notes[] = {"📌 Q3 Review","Sprint planning","Untitled", nullptr};
        const char* previews[] = {"First paragraph… 2 hr ago · #q3 #rev","Outline for the upcoming sprint. 1 day ago","just now", nullptr};
        for(int i=0;notes[i];i++){
            GtkWidget *row=gtk_list_box_row_new();
            GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
            GtkWidget *t=gtk_label_new(notes[i]); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t, "title-4");
            GtkWidget *p=gtk_label_new(previews[i]); gtk_label_set_xalign(GTK_LABEL(p),0); gtk_widget_add_css_class(p, "dim-label"); gtk_label_set_wrap(GTK_LABEL(p), TRUE);
            gtk_box_append(GTK_BOX(v), t); gtk_box_append(GTK_BOX(v), p);
            gtk_widget_set_margin_top(v, 8); gtk_widget_set_margin_bottom(v, 8);
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), v);
            gtk_list_box_append(GTK_LIST_BOX(list), row);
        }
    }
    GtkWidget *scroll_list = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll_list), list);
    gtk_widget_set_vexpand(scroll_list, TRUE);
    gtk_box_append(GTK_BOX(list_box), scroll_list);
    gtk_paned_set_start_child(GTK_PANED(mid), list_box);

    GtkWidget *detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(toolbar, 8); gtk_widget_set_margin_bottom(toolbar, 4);
    GtkWidget *pin = gtk_toggle_button_new_with_label("Pinned");
    GtkWidget *arch = gtk_toggle_button_new_with_label("Archive");
    GtkWidget *focus = gtk_button_new_with_label("Focus");
    gtk_box_append(GTK_BOX(toolbar), pin); gtk_box_append(GTK_BOX(toolbar), arch); gtk_box_append(GTK_BOX(toolbar), focus);
    gtk_box_append(GTK_BOX(detail), toolbar);
    GtkWidget *tag_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    for(auto tag : {"#q3","#review"}){
        GtkWidget *chip = gtk_label_new(tag); gtk_widget_add_css_class(chip,"dim-label"); gtk_widget_add_css_class(chip,"caption");
        gtk_box_append(GTK_BOX(tag_bar), chip);
    }
    gtk_widget_set_margin_top(tag_bar, 2);
    gtk_box_append(GTK_BOX(detail), tag_bar);
    GtkTextBuffer *buf = gtk_text_buffer_new(nullptr);
    GtkWidget *editor = gtk_text_view_new_with_buffer(buf);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(editor), GTK_WRAP_WORD_CHAR);
    gtk_widget_set_hexpand(editor, TRUE); gtk_widget_set_vexpand(editor, TRUE);
    gtk_widget_add_css_class(editor, "card");
    GtkWidget *ed_scroll = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(ed_scroll), editor);
    gtk_widget_set_hexpand(ed_scroll, TRUE); gtk_widget_set_vexpand(ed_scroll, TRUE);
    gtk_widget_set_margin_top(ed_scroll, 12);
    gtk_box_append(GTK_BOX(detail), ed_scroll);
    GtkWidget *status = gtk_label_new("Select a note to edit"); gtk_widget_add_css_class(status, "dim-label"); gtk_widget_add_css_class(status, "caption"); gtk_label_set_xalign(GTK_LABEL(status),0);
    gtk_widget_set_margin_top(status, 6);
    gtk_box_append(GTK_BOX(detail), status);
    // live word count
    auto buf_changed = +[](GtkTextBuffer *b, gpointer d){
        GtkLabel *s = GTK_LABEL(d);
        GtkTextIter a,z; gtk_text_buffer_get_bounds(b,&a,&z); char *t=gtk_text_buffer_get_text(b,&a,&z,FALSE);
        int words=0; bool in=false; for(char *p=t;*p;p++){ bool sp = g_ascii_isspace(*p); if(!sp && !in) words++; in=!sp; }
        int mins = (words+199)/200; if(mins<1) mins=1;
        std::string txt = std::to_string(words) + " words · " + std::to_string(mins) + " min";
        gtk_label_set_text(s, txt.c_str()); g_free(t);
    };
    g_signal_connect_data(buf, "changed", G_CALLBACK(buf_changed), status, nullptr, GConnectFlags(0));
    // Debounced persist: GtkTextBuffer::changed → g_timeout 800ms → DataLayer upsert on worker thread (not GTK)
    struct PersistCtx{ tessera::DataLayer* dl; GtkTextBuffer* buf; std::string* cur_id; guint timer; };
    PersistCtx *persist = new PersistCtx{dl, buf, new std::string(""), 0};
    struct NoteSel{ GtkTextBuffer *buf; GtkLabel *status; PersistCtx *persist; GtkWidget *tag_bar; };
    NoteSel *nsel = new NoteSel{buf, GTK_LABEL(status), persist, tag_bar};
    // Capture buf_changed as static for lambdas
    auto on_note_select = +[](GtkListBox*, GtkListBoxRow *row, gpointer d){
        if(!row||!d) return; NoteSel *n=(NoteSel*)d;
        GtkWidget *rc = gtk_list_box_row_get_child(row); if(!rc) return;
        GtkWidget *v = rc; GtkWidget *tw = gtk_widget_get_first_child(v);
        const char *ti = tw && GTK_IS_LABEL(tw) ? gtk_label_get_text(GTK_LABEL(tw)) : "";
        GtkWidget *pw = tw ? gtk_widget_get_next_sibling(tw) : nullptr;
        const char *pv = pw && GTK_IS_LABEL(pw) ? gtk_label_get_text(GTK_LABEL(pw)) : "";
        std::string body = std::string(ti?ti:"") + "\n\n" + std::string(pv?pv:"");
        gtk_text_buffer_set_text(n->buf, body.c_str(), -1);
        if(n->persist && n->persist->cur_id) *n->persist->cur_id = ti ? ti : "";
        // Update word count
        GtkTextIter a,z; gtk_text_buffer_get_bounds(n->buf,&a,&z); char *t=gtk_text_buffer_get_text(n->buf,&a,&z,FALSE);
        int words=0; bool in=false; for(char *p=t;*p;p++){ bool sp=g_ascii_isspace(*p); if(!sp && !in) words++; in=!sp; }
        int mins=(words+199)/200; if(mins<1) mins=1;
        std::string txt=std::to_string(words)+" words · "+std::to_string(mins)+" min";
        gtk_label_set_text(n->status, txt.c_str()); g_free(t);
    };
    g_signal_connect(list, "row-selected", G_CALLBACK(on_note_select), nsel);
    gtk_list_box_select_row(GTK_LIST_BOX(list), gtk_list_box_get_row_at_index(GTK_LIST_BOX(list), 0));
    // Persist on timeout
    g_signal_connect_data(buf, "changed", G_CALLBACK(+[](GtkTextBuffer *b, gpointer d){
        PersistCtx *p=(PersistCtx*)d;
        if(p->timer) g_source_remove(p->timer);
        p->timer = g_timeout_add(800, +[](gpointer dd)->gboolean{
            PersistCtx *pp=(PersistCtx*)dd;
            pp->timer=0;
            if(!pp->dl || !pp->dl->is_connected()) return G_SOURCE_REMOVE;
            GtkTextIter s,e; gtk_text_buffer_get_bounds(pp->buf,&s,&e); char *txt=gtk_text_buffer_get_text(pp->buf,&s,&e,FALSE);
            std::string body = txt ? txt : ""; g_free(txt);
            std::string title = body.substr(0, body.find('\n')); if(title.size()>80) title=title.substr(0,80);
            // Off GTK thread: DataLayer is thread-safe for PGconn acquire
            std::string *idcopy = pp->cur_id ? new std::string(*pp->cur_id) : new std::string("");
            std::string bodyCopy=body;
            tessera::DataLayer *dl=pp->dl;
            g_thread_new("note-persist", [](gpointer q)->gpointer{
                auto *pr=(std::pair<tessera::DataLayer*, std::pair<std::string,std::string>>*)q;
                std::string curId=pr->second.first; std::string b=pr->second.second;
                std::string title2=b.substr(0,b.find('\n')); if(title2.size()>80) title2=title2.substr(0,80);
                // If curId is title, lookup existing note by source or create
                std::string id = pr->first->upsert_knowledge("note", title2.empty()?"Untitled":title2, b, "note://"+title2, "");
                if(!id.empty() && id!=curId) pr->first->add_receipt(id, "note_upsert", "{\"title\":\""+title2+"\"}");
                delete pr; return nullptr;
            }, new std::pair<tessera::DataLayer*, std::pair<std::string,std::string>>(dl, {*idcopy, bodyCopy}));
            delete idcopy;
            return G_SOURCE_REMOVE;
        }, p);
    }), persist, nullptr, GConnectFlags(0));
    // + New Note — live CRUD via DataLayer (hexagonal, worker thread)
    if(dl){
        struct Ctx{ tessera::DataLayer* dl; GtkWidget* list; PersistCtx* persist; };
        Ctx *ctx = new Ctx{dl, list, persist};
        g_signal_connect(new_btn, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
            Ctx *c = (Ctx*)d;
            if(!c || !c->dl || !c->dl->is_connected()) return;
            std::string id = c->dl->create_note("Untitled", "");
            if(!id.empty()){
                c->dl->add_receipt(id, "note.create", "{\"title\":\"Untitled\"}");
                if(c->persist && c->persist->cur_id) *c->persist->cur_id = id;
                GtkWidget *row=gtk_list_box_row_new();
                GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
                GtkWidget *t=gtk_label_new("Untitled"); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t,"title-4");
                GtkWidget *p2=gtk_label_new("just now"); gtk_label_set_xalign(GTK_LABEL(p2),0); gtk_widget_add_css_class(p2,"dim-label");
                gtk_box_append(GTK_BOX(v),t); gtk_box_append(GTK_BOX(v),p2);
                gtk_widget_set_margin_top(v,8); gtk_widget_set_margin_bottom(v,8);
                gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), v);
                gtk_list_box_append(GTK_LIST_BOX(c->list), row);
                gtk_list_box_select_row(GTK_LIST_BOX(c->list), GTK_LIST_BOX_ROW(row));
            }
        }), ctx);
    }

    gtk_paned_set_end_child(GTK_PANED(mid), detail);
    gtk_paned_set_resize_end_child(GTK_PANED(mid), TRUE);
    gtk_paned_set_end_child(GTK_PANED(hpaned), mid);
    gtk_paned_set_resize_end_child(GTK_PANED(hpaned), TRUE);
    gtk_paned_set_position(GTK_PANED(hpaned), 200);
    gtk_paned_set_position(GTK_PANED(mid), 500);
    return hpaned;
}
} // namespace tessera
