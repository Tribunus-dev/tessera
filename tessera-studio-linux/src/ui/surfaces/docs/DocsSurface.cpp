#include "DocsSurface.h"
#include "core/productivity/docs/DocStore.h"
#include "core/data/DataLayer.h"
#include <adwaita.h>

namespace tessera {

static void on_docs_filter(GtkListBox*, GtkListBoxRow* row, gpointer d){
    GtkStack* stack = GTK_STACK(d);
    if(!row) return;
    const char* filter = (const char*)g_object_get_data(G_OBJECT(row), "filter");
    if(!filter) return;
    // filter applied via tag - demo just toggles subtitle
    gtk_stack_set_visible_child_name(stack, "list");
}

GtkWidget* docs_surface_new(DataLayer* dl, DocStore* store){
    GtkWidget* pane = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    // Sidebar: filters + tags
    GtkWidget* sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(sidebar, 220, -1);
    GtkWidget* lib = gtk_label_new("Library"); gtk_widget_add_css_class(lib,"title-4");
    gtk_widget_set_margin_top(lib,8); gtk_widget_set_margin_start(lib,8);
    gtk_box_append(GTK_BOX(sidebar), lib);
    GtkWidget* filters = gtk_list_box_new(); gtk_widget_add_css_class(filters,"navigation-sidebar");
    const char* names[]={"All","Favorites","Archived","Trash",nullptr};
    const char* icons[]={"folder","starred","archive","user-trash",nullptr};
    for(int i=0; names[i]; i++){
        GtkWidget* r=gtk_list_box_row_new();
        GtkWidget* h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget* ic=gtk_image_new_from_icon_name(icons[i]); GtkWidget* lb=gtk_label_new(names[i]); gtk_label_set_xalign(GTK_LABEL(lb),0); gtk_widget_set_hexpand(lb, TRUE);
        gtk_box_append(GTK_BOX(h), ic); gtk_box_append(GTK_BOX(h), lb);
        gtk_widget_set_margin_start(h,8); gtk_widget_set_margin_end(h,8); gtk_widget_set_margin_top(h,6); gtk_widget_set_margin_bottom(h,6);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), h);
        g_object_set_data(G_OBJECT(r),"filter", (gpointer)names[i]);
        gtk_list_box_append(GTK_LIST_BOX(filters), r);
    }
    gtk_box_append(GTK_BOX(sidebar), filters);
    // tag chips
    GtkWidget* tagFlow = gtk_flow_box_new(); gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(tagFlow), 6);
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(tagFlow), GTK_SELECTION_NONE);
    const char* tags[]={"q3","review","urgent",nullptr};
    for(int i=0; tags[i]; i++){ GtkWidget* chip=gtk_button_new_with_label(tags[i]); gtk_widget_add_css_class(chip,"pill"); gtk_flow_box_append(GTK_FLOW_BOX(tagFlow), chip); }
    gtk_box_append(GTK_BOX(sidebar), tagFlow);
    gtk_paned_set_start_child(GTK_PANED(pane), sidebar);

    // Middle: stack of list + detail
    GtkWidget* midStack = gtk_stack_new();
    GtkWidget* listBox = gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    GtkWidget* list = gtk_list_box_new(); gtk_widget_add_css_class(list,"boxed-list");
    auto docs = store ? store->list(50) : std::vector<Doc>{};
    bool hasLive = !docs.empty();
    if(!hasLive){
        Doc a; a.id="doc-1"; a.title="Q3 Review"; a.isFavorite=true; a.tags={"q3"};
        Doc b; b.id="doc-2"; b.title="Sprint planning"; docs={a,b};
    }
    for(auto &d: docs){
        GtkWidget* row=gtk_list_box_row_new();
        GtkWidget* v=gtk_box_new(GTK_ORIENTATION_VERTICAL,4); gtk_widget_set_hexpand(v, TRUE);
        GtkWidget* t=gtk_label_new(d.displayTitle().c_str()); gtk_label_set_xalign(GTK_LABEL(t),0); gtk_widget_add_css_class(t,"title-4");
        char sub[128]; snprintf(sub,sizeof(sub),"%s  %lu tags", d.isFavorite?" starred":"", d.tags.size());
        GtkWidget* s=gtk_label_new(sub); gtk_label_set_xalign(GTK_LABEL(s),0); gtk_widget_add_css_class(s,"dim-label"); gtk_widget_add_css_class(s,"caption");
        gtk_box_append(GTK_BOX(v), t); gtk_box_append(GTK_BOX(v), s);
        gtk_widget_set_margin_top(v,8); gtk_widget_set_margin_bottom(v,8); gtk_widget_set_margin_start(v,8);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), v);
        // store doc id for detail
        char* idcpy = g_strdup(d.id.c_str()); g_object_set_data_full(G_OBJECT(row),"doc_id", idcpy, g_free);
        gtk_list_box_append(GTK_LIST_BOX(list), row);
    }
    GtkWidget* sc = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), list); gtk_widget_set_vexpand(sc, TRUE);
    gtk_box_append(GTK_BOX(listBox), sc);
    GtkWidget* newBtn = gtk_button_new_with_label("+ New Doc"); gtk_widget_add_css_class(newBtn,"pill"); gtk_widget_set_margin_top(newBtn,8);
    gtk_box_append(GTK_BOX(listBox), newBtn);
    gtk_stack_add_named(GTK_STACK(midStack), listBox, "list");

    // Detail: editor placeholder + toolbar
    GtkWidget* detail = gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    GtkWidget* tb = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(tb,8); gtk_widget_set_margin_start(tb,8);
    GtkWidget* fav=gtk_toggle_button_new_with_label(" Favorite"); GtkWidget* arch=gtk_toggle_button_new_with_label(" Archive"); GtkWidget* trash=gtk_button_new_with_label(" Trash");
    gtk_box_append(GTK_BOX(tb), fav); gtk_box_append(GTK_BOX(tb), arch); gtk_box_append(GTK_BOX(tb), trash);
    gtk_box_append(GTK_BOX(detail), tb);
    GtkWidget* editor = gtk_text_view_new(); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(editor), GTK_WRAP_WORD); gtk_widget_set_vexpand(editor, TRUE);
    GtkWidget* edScroll = gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(edScroll), editor);
    gtk_box_append(GTK_BOX(detail), edScroll);
    // P3.6: persist editor body on change via DocStore/DataLayer
    if(store){
        GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor));
        g_signal_connect(buf, "changed", (GCallback)(+[](GtkTextBuffer *b, gpointer d){
            auto *st = (DocStore*)d;
            GtkTextIter s,e; gtk_text_buffer_get_bounds(b,&s,&e);
            char *txt = gtk_text_buffer_get_text(b,&s,&e,false);
            std::string body = txt?txt:"";
            g_free(txt);
            auto docs = st->list(1);
            if(!docs.empty()){
                Doc doc = docs[0];
                doc.body = body;
                st->upsert(doc);
            }
        }), store);
    }
    gtk_stack_add_named(GTK_STACK(midStack), detail, "detail");

    // right pane is stack of list/detail
    GtkWidget* right = midStack;
    // outer split: sidebar | midStack
    gtk_paned_set_end_child(GTK_PANED(pane), right);
    gtk_paned_set_position(GTK_PANED(pane), 240);
    // filter click -> detail
    g_signal_connect(filters, "row-activated", G_CALLBACK(on_docs_filter), midStack);
    // list click -> detail
    g_signal_connect(list, "row-activated", (GCallback)(+[](GtkListBox*, GtkListBoxRow* r, gpointer st){ if(r) gtk_stack_set_visible_child_name(GTK_STACK(st), "detail"); }), midStack);
    return pane;
}

} // namespace tessera
