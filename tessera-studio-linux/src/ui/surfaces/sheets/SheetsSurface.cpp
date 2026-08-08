#include "SheetsSurface.h"
#include "core/productivity/sheets/SheetStore.h"
#include <adwaita.h>
namespace tessera {
GtkWidget* sheets_surface_new(DataLayer* dl, SheetStore* store){
    GtkWidget* outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    GtkWidget* hdr=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(hdr,8); gtk_widget_set_margin_start(hdr,8);
    GtkWidget* title=gtk_label_new("Sheets"); gtk_widget_add_css_class(title,"title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    GtkWidget* sub=gtk_label_new("Excel/openpyxl-style grids backed by DocumentAST tables"); gtk_widget_add_css_class(sub,"dim-label"); gtk_widget_set_hexpand(sub,TRUE); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(hdr), title); gtk_box_append(GTK_BOX(hdr), sub);
    gtk_box_append(GTK_BOX(outer), hdr);
    // FlowBox grid cards
    GtkWidget* flow=gtk_flow_box_new(); gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow),3); gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(flow),1);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow),12); gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow),12);
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow),GTK_SELECTION_NONE); gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(flow),TRUE);
    auto sheets = store ? store->list(12) : std::vector<Sheet>{};
    if(sheets.empty()){ Sheet a; a.id="sheet-1"; a.title="Budget 2026"; a.columns={{ "Q1",120, SheetColumnType::number},{"Q2",120, SheetColumnType::number},{ "Total",140, SheetColumnType::number}}; sheets.push_back(a); }
    for(auto &s: sheets){
        GtkWidget* card=gtk_box_new(GTK_ORIENTATION_VERTICAL,6); gtk_widget_add_css_class(card,"card");
        GtkWidget* lbl=gtk_label_new(s.displayTitle().c_str()); gtk_widget_add_css_class(lbl,"title-4"); gtk_label_set_xalign(GTK_LABEL(lbl),0);
        char cols[128]; snprintf(cols,sizeof(cols),"%lu columns", s.columns.size());
        GtkWidget* c2=gtk_label_new(cols); gtk_widget_add_css_class(c2,"dim-label"); gtk_widget_add_css_class(c2,"caption"); gtk_label_set_xalign(GTK_LABEL(c2),0);
        // grid preview: GtkGrid with header row
        GtkWidget* grid=gtk_grid_new(); gtk_grid_set_column_spacing(GTK_GRID(grid),6); gtk_grid_set_row_spacing(GTK_GRID(grid),4);
        for(size_t ci=0; ci<s.columns.size() && ci<4; ci++){
            GtkWidget* hdr2=gtk_label_new(s.columns[ci].label.c_str()); gtk_widget_add_css_class(hdr2,"heading"); gtk_grid_attach(GTK_GRID(grid), hdr2, (int)ci, 0,1,1);
            for(int r=1;r<4;r++){ char v[16]; snprintf(v,sizeof(v),"—"); GtkWidget* cell=gtk_label_new(v); gtk_widget_add_css_class(cell,"dim-label"); gtk_grid_attach(GTK_GRID(grid), cell, (int)ci, r,1,1); }
        }
        gtk_box_append(GTK_BOX(card), lbl); gtk_box_append(GTK_BOX(card), c2); gtk_box_append(GTK_BOX(card), grid);
        gtk_flow_box_append(GTK_FLOW_BOX(flow), card);
    }
    GtkWidget* sc=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), flow); gtk_widget_set_vexpand(sc, TRUE);
    gtk_box_append(GTK_BOX(outer), sc);
    GtkWidget* newBtn=gtk_button_new_with_label("+ New Sheet"); gtk_widget_add_css_class(newBtn,"pill"); gtk_widget_set_margin_top(newBtn,8); gtk_widget_set_halign(newBtn, GTK_ALIGN_START); gtk_widget_set_margin_start(newBtn,8);
    gtk_box_append(GTK_BOX(outer), newBtn);
    return outer;
}
GtkWidget* slides_surface_new(DataLayer* dl, SlideStore* store){
    GtkWidget* outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    GtkWidget* hdr=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(hdr,8); gtk_widget_set_margin_start(hdr,8);
    GtkWidget* title=gtk_label_new("Slides"); gtk_widget_add_css_class(title,"title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    GtkWidget* sub=gtk_label_new("Keynote/pptx decks, one AST per deck"); gtk_widget_add_css_class(sub,"dim-label"); gtk_widget_set_hexpand(sub,TRUE); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(hdr), title); gtk_box_append(GTK_BOX(hdr), sub);
    gtk_box_append(GTK_BOX(outer), hdr);
    // Deck list + slide strip preview
    GtkWidget* pane=gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget* list=gtk_list_box_new(); gtk_widget_add_css_class(list,"boxed-list"); gtk_widget_set_size_request(list, 260, -1);
    auto decks = store ? store->list(12) : std::vector<SlideDeck>{};
    if(decks.empty()){ SlideDeck a; a.id="deck-1"; a.title="Roadmap 2026"; decks.push_back(a); }
    for(auto &d: decks){
        GtkWidget* row=gtk_list_box_row_new();
        GtkWidget* v=gtk_box_new(GTK_ORIENTATION_VERTICAL,4); gtk_widget_set_margin_top(v,8); gtk_widget_set_margin_bottom(v,8); gtk_widget_set_margin_start(v,8);
        GtkWidget* t=gtk_label_new(d.displayTitle().c_str()); gtk_widget_add_css_class(t,"title-4"); gtk_label_set_xalign(GTK_LABEL(t),0);
        char cnt[64]; snprintf(cnt,sizeof(cnt),"%lu slides", d.slides().size());
        GtkWidget* c2=gtk_label_new(cnt); gtk_widget_add_css_class(c2,"dim-label"); gtk_widget_add_css_class(c2,"caption"); gtk_label_set_xalign(GTK_LABEL(c2),0);
        gtk_box_append(GTK_BOX(v), t); gtk_box_append(GTK_BOX(v), c2);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), v);
        gtk_list_box_append(GTK_LIST_BOX(list), row);
    }
    gtk_paned_set_start_child(GTK_PANED(pane), list);
    // Canvas placeholder: DrawingArea with title layout preview
    GtkWidget* canvas=gtk_box_new(GTK_ORIENTATION_VERTICAL,0); gtk_widget_set_hexpand(canvas, TRUE);
    GtkWidget* area=gtk_drawing_area_new(); gtk_widget_set_size_request(area, 640, 360); gtk_widget_set_hexpand(area, TRUE); gtk_widget_set_vexpand(area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), +[](GtkDrawingArea*, cairo_t* cr, int w, int h, gpointer){ cairo_set_source_rgb(cr,0.96,0.96,0.96); cairo_paint(cr); cairo_set_source_rgb(cr,0.2,0.2,0.2); cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_BOLD); cairo_set_font_size(cr,28); cairo_move_to(cr, w*0.08, h*0.35); cairo_show_text(cr,"Title"); cairo_set_font_size(cr,16); cairo_move_to(cr,w*0.08,h*0.5); cairo_show_text(cr,"Title and Content layout"); }, NULL, NULL);
    gtk_widget_add_css_class(area,"card");
    gtk_box_append(GTK_BOX(canvas), area);
    // notes strip
    GtkWidget* notes=gtk_text_view_new(); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(notes), GTK_WRAP_WORD); gtk_widget_set_size_request(notes,-1,80);
    GtkWidget* sc2=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc2), notes);
    gtk_box_append(GTK_BOX(canvas), sc2);
    gtk_paned_set_end_child(GTK_PANED(pane), canvas);
    gtk_paned_set_position(GTK_PANED(pane), 280);
    gtk_box_append(GTK_BOX(outer), pane);
    gtk_widget_set_vexpand(pane, TRUE);
    return outer;
}
} // namespace tessera
