#include "RemindersSurface.h"
#include "core/productivity/Productivity.h"
#include <gtk/gtk.h>
#include <adwaita.h>
namespace tessera {
GtkWidget* reminders_surface_new(ProductivityStore *store){
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box,12); gtk_widget_set_margin_start(box,12); gtk_widget_set_margin_end(box,12);
    GtkWidget *hdr = gtk_label_new("Reminders"); gtk_widget_add_css_class(hdr,"title-2"); gtk_label_set_xalign(GTK_LABEL(hdr),0);
    gtk_box_append(GTK_BOX(box), hdr);
    GtkWidget *sub3 = gtk_label_new("Tasks that notify — stay on track"); gtk_widget_add_css_class(sub3,"dim-label"); gtk_widget_add_css_class(sub3,"caption"); gtk_label_set_xalign(GTK_LABEL(sub3),0);
    gtk_box_append(GTK_BOX(box), sub3);
    ProductivityStore local; if(!store) store=&local;
    auto rems = store->reminders();
    GtkWidget *list = gtk_list_box_new(); gtk_widget_add_css_class(list,"card");
    for(auto &r: rems){
        GtkWidget *row=gtk_list_box_row_new();
        GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget *cb=gtk_check_button_new(); gtk_check_button_set_active(GTK_CHECK_BUTTON(cb), r.done);
        GtkWidget *l=gtk_label_new(r.title.c_str()); gtk_label_set_xalign(GTK_LABEL(l),0);
        if(r.done) gtk_widget_add_css_class(l,"dim-label");
        gtk_box_append(GTK_BOX(h),cb); gtk_box_append(GTK_BOX(h),l);
        gtk_widget_set_margin_top(h,6); gtk_widget_set_margin_bottom(h,6);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h);
        gtk_list_box_append(GTK_LIST_BOX(list), row);
    }
    GtkWidget *scroll=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list); gtk_widget_set_vexpand(scroll,TRUE);
    gtk_box_append(GTK_BOX(box), scroll);
    GtkWidget *cap2 = gtk_label_new("Reminders sync — notifications via portal"); gtk_widget_add_css_class(cap2,"dim-label"); gtk_widget_add_css_class(cap2,"caption"); gtk_label_set_xalign(GTK_LABEL(cap2),0);
    gtk_box_append(GTK_BOX(box), cap2);
    {
        GtkWidget *add = gtk_button_new_with_label("+ Reminder"); gtk_widget_add_css_class(add, "pill"); gtk_widget_set_halign(add, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(box), add);
        struct RCtx{ GtkWidget *list; };
        RCtx *rc = new RCtx{list};
        g_signal_connect(add, "clicked", G_CALLBACK(+[](GtkButton*, gpointer d){
            RCtx *c=(RCtx*)d;
            GtkWidget *dlg = gtk_dialog_new_with_buttons("New Reminder", nullptr, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Add", GTK_RESPONSE_ACCEPT, nullptr);
            GtkWidget *cnt = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
            GtkWidget *e = gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(e), "Reminder");
            gtk_box_append(GTK_BOX(cnt), e); gtk_widget_show(dlg);
            g_signal_connect(dlg, "response", G_CALLBACK(+[](GtkDialog *d, gint r, gpointer dd){
                if(r==GTK_RESPONSE_ACCEPT){
                    RCtx *cc=(RCtx*)dd;
                    GtkWidget *cnt2 = gtk_dialog_get_content_area(d);
                    GtkWidget *en = gtk_widget_get_first_child(cnt2);
                    const char *t = en && GTK_IS_ENTRY(en) ? gtk_entry_buffer_get_text(gtk_entry_get_buffer(GTK_ENTRY(en))) : "Untitled";
                    GtkWidget *row=gtk_list_box_row_new(); GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
                    GtkWidget *cb=gtk_check_button_new(); GtkWidget *l=gtk_label_new(t); gtk_label_set_xalign(GTK_LABEL(l),0);
                    gtk_box_append(GTK_BOX(h), cb); gtk_box_append(GTK_BOX(h), l);
                    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), h); gtk_list_box_append(GTK_LIST_BOX(cc->list), row);
                }
                gtk_window_destroy(GTK_WINDOW(d));
            }), c);
        }), rc);
    }
    return box;
}
} // namespace
