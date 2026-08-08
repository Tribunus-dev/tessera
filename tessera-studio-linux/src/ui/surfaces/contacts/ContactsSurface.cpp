#include "ContactsSurface.h"
#include "core/productivity/Productivity.h"
#include <gtk/gtk.h>
#include <adwaita.h>
namespace tessera {
GtkWidget* contacts_surface_new(ProductivityStore *store){
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box,12); gtk_widget_set_margin_start(box,12); gtk_widget_set_margin_end(box,12);
    GtkWidget *hdr = gtk_label_new("Contacts"); gtk_widget_add_css_class(hdr,"title-2"); gtk_label_set_xalign(GTK_LABEL(hdr),0);
    gtk_box_append(GTK_BOX(box), hdr);
    GtkWidget *sub2 = gtk_label_new("People and groups — always in sync"); gtk_widget_add_css_class(sub2,"dim-label"); gtk_widget_add_css_class(sub2,"caption"); gtk_label_set_xalign(GTK_LABEL(sub2),0);
    gtk_box_append(GTK_BOX(box), sub2);
    ProductivityStore local; if(!store) store=&local;
    auto cs = store->contacts();
    GtkWidget *list = gtk_list_box_new(); gtk_widget_add_css_class(list,"card");
    for(auto &c: cs){
        GtkWidget *r=gtk_list_box_row_new();
        GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget *avatar=gtk_image_new_from_icon_name("avatar-default-symbolic");
        GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL,2);
        GtkWidget *n=gtk_label_new(c.name.c_str()); gtk_label_set_xalign(GTK_LABEL(n),0); gtk_widget_add_css_class(n,"title-4");
        GtkWidget *e=gtk_label_new(c.email.c_str()); gtk_label_set_xalign(GTK_LABEL(e),0); gtk_widget_add_css_class(e,"dim-label");
        gtk_box_append(GTK_BOX(v),n); gtk_box_append(GTK_BOX(v),e);
        gtk_box_append(GTK_BOX(h),avatar); gtk_box_append(GTK_BOX(h),v);
        gtk_widget_set_margin_top(h,6); gtk_widget_set_margin_bottom(h,6);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), h);
        gtk_list_box_append(GTK_LIST_BOX(list), r);
    }
    GtkWidget *scroll=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list); gtk_widget_set_vexpand(scroll,TRUE);
    gtk_box_append(GTK_BOX(box), scroll);
    GtkWidget *cap = gtk_label_new("Contacts sync in the background"); gtk_widget_add_css_class(cap,"dim-label"); gtk_widget_add_css_class(cap,"caption"); gtk_label_set_xalign(GTK_LABEL(cap),0);
    gtk_box_append(GTK_BOX(box), cap);
    {
        GtkWidget *add = gtk_button_new_with_label("+ Contact"); gtk_widget_add_css_class(add, "pill"); gtk_widget_set_halign(add, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(box), add);
        struct CCtx{ GtkWidget *list; };
        CCtx *cc = new CCtx{list};
        g_signal_connect(add, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
            CCtx *c=(CCtx*)d;
            GtkWidget *dlg = gtk_dialog_new_with_buttons("New Contact", nullptr, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Add", GTK_RESPONSE_ACCEPT, nullptr);
            GtkWidget *cnt = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
            GtkWidget *e = gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(e), "Name");
            GtkWidget *e2 = gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(e2), "Email");
            gtk_box_append(GTK_BOX(cnt), e); gtk_box_append(GTK_BOX(cnt), e2); gtk_widget_show(dlg);
            g_signal_connect(dlg, "response", G_CALLBACK(+[](GtkDialog *d, gint r, gpointer dd){
                if(r==GTK_RESPONSE_ACCEPT){
                    CCtx *cc2=(CCtx*)dd;
                    GtkWidget *cnt2 = gtk_dialog_get_content_area(d);
                    GtkWidget *en = gtk_widget_get_first_child(cnt2);
                    const char *n = en && GTK_IS_ENTRY(en) ? gtk_entry_buffer_get_text(gtk_entry_get_buffer(GTK_ENTRY(en))) : "Untitled";
                    GtkWidget *row=gtk_list_box_row_new(); GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
                    GtkWidget *av=gtk_image_new_from_icon_name("avatar-default-symbolic");
                    GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL,2);
                    GtkWidget *nl=gtk_label_new(n); gtk_label_set_xalign(GTK_LABEL(nl),0);
                    gtk_box_append(GTK_BOX(v), nl); gtk_box_append(GTK_BOX(h), av); gtk_box_append(GTK_BOX(h), v);
                    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h); gtk_list_box_append(GTK_LIST_BOX(cc2->list), row);
                }
                gtk_window_destroy(GTK_WINDOW(d));
            }), c);
        }), cc);
    }
    return box;
}
} // namespace
