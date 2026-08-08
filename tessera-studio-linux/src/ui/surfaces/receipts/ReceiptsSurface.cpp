#include "Surface.h"
#include "core/data/DataLayer.h"
#include <adwaita.h>
namespace tessera {
GtkWidget* receipts_surface_new(DataLayer* dl){
    GtkWidget* outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    GtkWidget* hdr=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(hdr,8); gtk_widget_set_margin_start(hdr,8);
    GtkWidget* title=gtk_label_new("Receipts"); gtk_widget_add_css_class(title,"title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    GtkWidget* sub=gtk_label_new("Constitutional receipt chain — every mutation signed"); gtk_widget_add_css_class(sub,"dim-label"); gtk_widget_set_hexpand(sub,TRUE); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(hdr), title); gtk_box_append(GTK_BOX(hdr), sub);
    gtk_box_append(GTK_BOX(outer), hdr);
    GtkWidget* list=gtk_list_box_new(); gtk_widget_add_css_class(list,"boxed-list");
    // pull recent receipts via chain length (if DB available)
    int demo = dl ? dl->receipt_chain_length("doc-1") : -1;
    if(demo<0){
        const char* descs[]={"doc_upsert · Q3 Review — 2 tags","sheet_upsert · Budget 2026 — 3 cols","slide_upsert · Roadmap — 1 slide",nullptr};
        for(int i=0;descs[i];i++){
            GtkWidget* row=gtk_list_box_row_new();
            GtkWidget* h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8); gtk_widget_set_margin_top(h,6); gtk_widget_set_margin_bottom(h,6); gtk_widget_set_margin_start(h,8);
            GtkWidget* ic=gtk_image_new_from_icon_name("emblem-ok-symbolic");
            GtkWidget* lb=gtk_label_new(descs[i]); gtk_label_set_xalign(GTK_LABEL(lb),0); gtk_widget_set_hexpand(lb,TRUE);
            gtk_box_append(GTK_BOX(h), ic); gtk_box_append(GTK_BOX(h), lb);
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h);
            gtk_list_box_append(GTK_LIST_BOX(list), row);
        }
    } else {
        char buf[64]; snprintf(buf,sizeof(buf),"Receipt chain length for doc-1: %d", demo);
        GtkWidget* row=gtk_list_box_row_new(); GtkWidget* lb=gtk_label_new(buf); gtk_label_set_xalign(GTK_LABEL(lb),0); gtk_widget_set_margin_start(lb,8);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), lb); gtk_list_box_append(GTK_LIST_BOX(list), row);
    }
    GtkWidget* sc=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), list); gtk_widget_set_vexpand(sc, TRUE);
    gtk_box_append(GTK_BOX(outer), sc);
    // export bar
    GtkWidget* bar=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(bar,6); gtk_widget_set_margin_start(bar,8);
    GtkWidget* exp=gtk_button_new_with_label("Export Receipts"); gtk_widget_add_css_class(exp,"pill");
    GtkWidget* ver=gtk_button_new_with_label("Verify Chain"); gtk_widget_add_css_class(ver,"pill");
    gtk_box_append(GTK_BOX(bar), exp); gtk_box_append(GTK_BOX(bar), ver);
    gtk_box_append(GTK_BOX(outer), bar);
    return outer;
}
} // namespace tessera
