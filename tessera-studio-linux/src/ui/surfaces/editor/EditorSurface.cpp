#include "Editor.h"
#include <adwaita.h>
#ifdef HAVE_GTKSOURCEVIEW
#include <gtksourceview/gtksource.h>
#endif
namespace tessera {
GtkWidget* editor_surface_new(){
    GtkWidget* pane=gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget* sidebar=gtk_box_new(GTK_ORIENTATION_VERTICAL,0); gtk_widget_set_size_request(sidebar,220,-1);
    GtkWidget* outline=gtk_list_box_new(); gtk_widget_add_css_class(outline,"navigation-sidebar");
    const char* items[]={"Heading 1","Paragraph","Code block",nullptr};
    for(int i=0;items[i];i++){ GtkWidget* r=gtk_list_box_row_new(); GtkWidget* lb=gtk_label_new(items[i]); gtk_label_set_xalign(GTK_LABEL(lb),0); gtk_widget_set_margin_start(lb,8); gtk_widget_set_margin_top(lb,4); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), lb); gtk_list_box_append(GTK_LIST_BOX(outline), r); }
    gtk_box_append(GTK_BOX(sidebar), outline);
    gtk_paned_set_start_child(GTK_PANED(pane), sidebar);
#ifdef HAVE_GTKSOURCEVIEW
    GtkSourceBuffer* buf=gtk_source_buffer_new(NULL);
    GtkWidget* view=gtk_source_view_new_with_buffer(buf);
    gtk_source_view_set_show_line_numbers(GTK_SOURCE_VIEW(view), TRUE);
    gtk_source_view_set_highlight_current_line(GTK_SOURCE_VIEW(view), TRUE);
    GtkSourceLanguageManager* lm=gtk_source_language_manager_get_default();
    GtkSourceLanguage* lang=gtk_source_language_manager_get_language(lm, "markdown");
    if(lang) gtk_source_buffer_set_language(buf, lang);
    gtk_text_buffer_set_text(GTK_TEXT_BUFFER(buf), "# Untitled\n\nStart typing…", -1);
    g_object_unref(buf);
#else
    GtkWidget* view=gtk_text_view_new(); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD);
    GtkTextBuffer* buf=gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)); gtk_text_buffer_set_text(buf, "# Untitled\n\nStart typing… (install gtksourceview-5 for syntax + gutter)", -1);
#endif
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(view), false);
    GtkWidget* sc=gtk_scrolled_window_new(); gtk_widget_set_hexpand(view, TRUE); gtk_widget_set_vexpand(view, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), view);
    gtk_paned_set_end_child(GTK_PANED(pane), sc);
    gtk_paned_set_position(GTK_PANED(pane), 240);
    return pane;
}

} // namespace tessera
