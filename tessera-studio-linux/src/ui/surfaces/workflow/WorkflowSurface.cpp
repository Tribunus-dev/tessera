#include "WorkflowSurface.h"
#include "core/workflow/StateGraph.h"
#include <adwaita.h>
#include <glib.h>
#include <string>
#include <vector>

namespace tessera {

struct WFState {
    StateGraph graph;
    DataLayer *dl = nullptr;
    GtkWidget *event_list = nullptr;
    GtkWidget *state_label = nullptr;
    GtkWidget *checkpoints_label = nullptr;
    GtkWidget *interrupt_bar = nullptr;
    GtkWidget *input_entry = nullptr;
    std::string thread_id = "demo-thread";
    GraphState current_state;
    bool interrupted = false;
    std::string interrupt_node;
    std::string last_thread;
};

static void wf_append_event(WFState *s, const char *text){
    GtkWidget *row = gtk_list_box_row_new();
    GtkWidget *lbl = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(lbl), 0);
    gtk_label_set_wrap(GTK_LABEL(lbl), TRUE);
    gtk_widget_set_margin_start(lbl, 8); gtk_widget_set_margin_end(lbl, 8);
    gtk_widget_set_margin_top(lbl, 4); gtk_widget_set_margin_bottom(lbl, 4);
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), lbl);
    gtk_list_box_append(GTK_LIST_BOX(s->event_list), row);
}

static void wf_update_state_view(WFState *s){
    std::string msg = s->current_state.count("messages") ? s->current_state.at("messages") : "(none)";
    if(msg.size()>120) msg = msg.substr(0,120)+"...";
    std::string txt = "Messages: " + msg + "\nThread: " + s->thread_id;
    if(s->current_state.count("next")) txt += "\nNext: " + s->current_state.at("next");
    if(s->current_state.count("is_sensitive")) txt += "\nSensitive: " + s->current_state.at("is_sensitive");
    if(s->current_state.count("is_complex")) txt += "\nComplex: " + s->current_state.at("is_complex");
    gtk_label_set_text(GTK_LABEL(s->state_label), txt.c_str());
    // checkpoints count
    std::string cp = "Checkpoints: " + std::to_string(s->graph.nodes().size()) + " nodes";
    if(!s->last_thread.empty()) cp += " | last: " + s->last_thread;
    gtk_label_set_text(GTK_LABEL(s->checkpoints_label), cp.c_str());
}

static void wf_build_graph(WFState *s){
    s->graph = StateGraph("tessy-sky", s->dl);
    s->graph.setReducer("messages", "append");
    s->graph.addNode("tessy", "Tessy", [](const GraphState &st)->StateUpdate{
        StateUpdate upd;
        std::string last = st.count("messages") ? st.at("messages") : "";
        // take last line as input
        std::string line = last;
        auto pos = line.rfind('\n');
        if(pos!=std::string::npos) line = line.substr(pos+1);
        upd.updates["messages"] = std::string("[tessy] handling locally: ") + line;
        upd.updates["handled_by"] = "tessy";
        upd.reducers["messages"] = "append";
        return upd;
    }, "Local Tessy handles sensitive data");
    s->graph.addNode("sky", "Sky", [](const GraphState &st)->StateUpdate{
        StateUpdate upd;
        std::string last = st.count("messages") ? st.at("messages") : "";
        auto pos = last.rfind('\n');
        std::string line = (pos==std::string::npos)? last : last.substr(pos+1);
        upd.updates["messages"] = std::string("[sky] cloud synthesis: ") + line;
        upd.updates["handled_by_sky"] = "true";
        upd.reducers["messages"] = "append";
        return upd;
    }, "Cloud Sky for complex reasoning");
    s->graph.addNode("synthesis", "Synthesis", [](const GraphState &){ StateUpdate upd; upd.updates["messages"]="[synthesis] merged Tessy+Sky — ready."; upd.reducers["messages"]="append"; upd.updates["done"]="true"; return upd; }, "Merge results");
    s->graph.setEntryPoint("tessy");
    s->graph.addConditionalEdge("tessy", [](const GraphState &st)->std::string{
        auto it = st.find("is_complex");
        bool complex = (it!=st.end() && it->second=="true");
        return complex ? "sky" : "synthesis";
    }, {{"sky","sky"},{"synthesis","synthesis"}});
    s->graph.addEdge("sky", "synthesis");
    s->graph.addEdge("synthesis", "__end__");
    s->graph.interruptBefore({"sky"});
}

static void wf_on_run(GtkButton*, gpointer data){
    WFState *s = (WFState*)data;
    const char *txt = gtk_editable_get_text(GTK_EDITABLE(s->input_entry));
    if(!txt || !*txt) txt = "Hello Tessy+Sky";
    GraphState init;
    init["messages"] = txt;
    init["thread_id"] = s->thread_id;
    std::string low = txt; for(char &c: low) c = tolower(c);
    bool sensitive = low.find("password")!=std::string::npos || low.find("secret")!=std::string::npos || low.find("private")!=std::string::npos;
    bool complex = low.find("complex")!=std::string::npos || low.find("analyze")!=std::string::npos || low.size()>80;
    init["is_sensitive"] = sensitive ? "true":"false";
    init["is_complex"] = complex ? "true":"false";
    wf_append_event(s, ("→ invoke: " + std::string(txt)).c_str());
    s->current_state = init;
    wf_update_state_view(s);
    // run graph — events marshalled via g_idle_add by caller
    GraphState init_copy = init;
    WFState *sp = s;
    std::string tid = s->graph.run(init_copy,
        [sp](const WorkflowEvent &ev){
            g_idle_add([](gpointer d)->gboolean{
                auto *pair = (std::pair<WFState*,WorkflowEvent>*)d;
                WFState *s = pair->first;
                WorkflowEvent ev = pair->second;
                std::string label;
                switch(ev.type){
                    case WorkflowEventType::Started: label = "▶ started"; break;
                    case WorkflowEventType::NodeStarted: label = "  → " + ev.nodeId + " start"; break;
                    case WorkflowEventType::NodeFinished: label = "  ✓ " + ev.nodeId + " done"; break;
                    case WorkflowEventType::Interrupted: label = "⏸ interrupted before " + ev.nodeId; s->interrupted=true; s->interrupt_node=ev.nodeId; gtk_widget_set_visible(s->interrupt_bar, TRUE); break;
                    case WorkflowEventType::Finished: label = ev.success ? "✓ finished" : std::string("✗ ")+ev.message; break;
                    default: label = ev.message; break;
                }
                wf_append_event(s, label.c_str());
                if(ev.stateSnapshot.count("messages")) s->current_state = ev.stateSnapshot;
                wf_update_state_view(s);
                delete pair;
                return G_SOURCE_REMOVE;
            }, new std::pair<WFState*,WorkflowEvent>(sp, ev));
        },
        [sp](const Checkpoint &cp){
            g_idle_add([](gpointer d)->gboolean{
                auto *pair = (std::pair<WFState*,Checkpoint>*)d;
                WFState *s = pair->first;
                s->current_state = pair->second.state;
                s->last_thread = pair->second.threadId;
                wf_update_state_view(s);
                delete pair;
                return G_SOURCE_REMOVE;
            }, new std::pair<WFState*,Checkpoint>(sp, cp));
        });
    s->last_thread = tid;
}

static void wf_on_resume(GtkButton*, gpointer data){
    WFState *s = (WFState*)data;
    if(!s->interrupted) return;
    gtk_widget_set_visible(s->interrupt_bar, FALSE);
    s->interrupted = false;
    wf_append_event(s, "▶ resuming...");
    // For demo, approve and manually continue from saved state
    GraphState cur = s->current_state;
    // simulate Sky execution if was interrupted before sky
    if(s->interrupt_node=="sky"){
        // find sky node fn via graph
        for(auto &n: s->graph.nodes()) if(n.id=="sky"){
            StateUpdate upd = n.fn(cur);
            cur = reduceState(cur, upd);
            break;
        }
        for(auto &n: s->graph.nodes()) if(n.id=="synthesis"){
            StateUpdate upd = n.fn(cur);
            cur = reduceState(cur, upd);
            break;
        }
        s->current_state = cur;
        wf_append_event(s, ("✓ resumed done: " + (cur.count("messages")?cur.at("messages"):"")).c_str());
        wf_update_state_view(s);
    }
    s->interrupt_node.clear();
}

static void wf_on_reset(GtkButton*, gpointer data){
    WFState *s = (WFState*)data;
    s->interrupted = false; s->interrupt_node.clear(); s->current_state.clear();
    s->current_state["thread_id"] = s->thread_id;
    gtk_widget_set_visible(s->interrupt_bar, FALSE);
    wf_append_event(s, "↺ reset thread");
    wf_update_state_view(s);
}

static void on_palette_drag(GtkDragSource*, double, double, gpointer){ }

GtkWidget* workflow_surface_new(){
    WFState *st = new WFState();
    st->thread_id = "tessy-sky-demo";
    wf_build_graph(st);
    GtkWidget *hpaned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *palette = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(palette, 220, -1);
    GtkWidget *pal_hdr = gtk_label_new("StateGraph Palette");
    gtk_widget_add_css_class(pal_hdr, "title-4");
    gtk_widget_set_margin_top(pal_hdr, 8); gtk_widget_set_margin_bottom(pal_hdr, 4);
    gtk_box_append(GTK_BOX(palette), pal_hdr);
    gtk_box_append(GTK_BOX(palette), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    const char* nodes[] = {"Tessy Node","Sky Node","Synthesis","Conditional Edge","Interrupt (HITL)", nullptr};
    GtkWidget *pal_list = gtk_list_box_new();
    for(int i=0; nodes[i]; i++){
        GtkWidget *row = gtk_list_box_row_new();
        GtkWidget *lbl = gtk_label_new(nodes[i]); gtk_label_set_xalign(GTK_LABEL(lbl), 0);
        gtk_widget_set_margin_start(lbl, 12); gtk_widget_set_margin_end(lbl, 12);
        gtk_widget_set_margin_top(lbl, 6); gtk_widget_set_margin_bottom(lbl, 6);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), lbl);
        GtkDragSource *ds = gtk_drag_source_new();
        g_signal_connect(ds, "prepare", G_CALLBACK(on_palette_drag), nullptr);
        gtk_widget_add_controller(row, GTK_EVENT_CONTROLLER(ds));
        gtk_list_box_append(GTK_LIST_BOX(pal_list), row);
    }
    GtkWidget *pal_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(pal_scroll), pal_list);
    gtk_widget_set_vexpand(pal_scroll, TRUE);
    gtk_box_append(GTK_BOX(palette), pal_scroll);
    GtkWidget *pal_hint = gtk_label_new("Drag to canvas — solid=normal, dashed=conditional");
    gtk_label_set_wrap(GTK_LABEL(pal_hint), TRUE);
    gtk_widget_add_css_class(pal_hint, "dim-label");
    gtk_widget_set_margin_start(pal_hint, 8); gtk_widget_set_margin_end(pal_hint, 8);
    gtk_widget_set_margin_top(pal_hint, 6); gtk_widget_set_margin_bottom(pal_hint, 6);
    gtk_box_append(GTK_BOX(palette), pal_hint);
    gtk_paned_set_start_child(GTK_PANED(hpaned), palette);
    gtk_paned_set_resize_start_child(GTK_PANED(hpaned), FALSE);
    GtkWidget *mid = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *canvas_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(canvas_box, 8); gtk_widget_set_margin_end(canvas_box, 8);
    gtk_widget_set_margin_top(canvas_box, 8); gtk_widget_set_margin_bottom(canvas_box, 8);
    GtkWidget *input_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    st->input_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(st->input_entry), "Prompt — try 'complex task: analyze my calendar' to trigger Sky");
    gtk_widget_set_hexpand(st->input_entry, TRUE);
    GtkWidget *btn_run = gtk_button_new_with_label("Run");
    gtk_widget_add_css_class(btn_run, "suggested-action");
    GtkWidget *btn_reset = gtk_button_new_with_label("Reset");
    gtk_box_append(GTK_BOX(input_row), st->input_entry);
    gtk_box_append(GTK_BOX(input_row), btn_run);
    gtk_box_append(GTK_BOX(input_row), btn_reset);
    gtk_box_append(GTK_BOX(canvas_box), input_row);
    st->interrupt_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(st->interrupt_bar, "card");
    gtk_widget_set_margin_top(st->interrupt_bar, 4); gtk_widget_set_margin_bottom(st->interrupt_bar, 4);
    GtkWidget *int_lbl = gtk_label_new("Paused before Sky — human approval required");
    gtk_widget_set_hexpand(int_lbl, TRUE); gtk_label_set_xalign(GTK_LABEL(int_lbl), 0);
    GtkWidget *btn_resume = gtk_button_new_with_label("Resume");
    gtk_widget_add_css_class(btn_resume, "pill");
    gtk_box_append(GTK_BOX(st->interrupt_bar), int_lbl);
    gtk_box_append(GTK_BOX(st->interrupt_bar), btn_resume);
    gtk_widget_set_visible(st->interrupt_bar, FALSE);
    gtk_box_append(GTK_BOX(canvas_box), st->interrupt_bar);
    g_signal_connect(btn_resume, "clicked", G_CALLBACK(wf_on_resume), st);
    g_signal_connect(btn_run, "clicked", G_CALLBACK(wf_on_run), st);
    g_signal_connect(btn_reset, "clicked", G_CALLBACK(wf_on_reset), st);
    g_signal_connect(st->input_entry, "activate", G_CALLBACK(wf_on_run), st);
    GtkWidget *canvas = gtk_drawing_area_new();
    gtk_widget_set_hexpand(canvas, TRUE); gtk_widget_set_vexpand(canvas, TRUE);
    gtk_widget_add_css_class(canvas, "card");
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(canvas), [](GtkDrawingArea*, cairo_t *cr, int w, int h, gpointer){
        bool dark = adw_style_manager_get_dark(adw_style_manager_get_default());
        if(dark) cairo_set_source_rgb(cr, 0.18,0.18,0.19); else cairo_set_source_rgb(cr, 0.96,0.96,0.97);
        cairo_paint(cr);
        if(dark) cairo_set_source_rgba(cr, 0.32,0.32,0.34, 0.35); else cairo_set_source_rgba(cr, 0.82,0.82,0.85, 0.45);
        cairo_set_line_width(cr, 0.5);
        for(int x=0;x<w;x+=24){ cairo_move_to(cr,x,0); cairo_line_to(cr,x,h); } for(int y=0;y<h;y+=24){ cairo_move_to(cr,0,y); cairo_line_to(cr,w,y); } cairo_stroke(cr);
        struct N{ const char* label; double x,y,w,h; bool conditional; };
        N nodes[] = {{"START",30,60,90,36,false},{"Tessy",140,60,110,44,false},{"Router",280,60,110,44,true},{"Sky",420,20,110,44,false},{"Synthesis",420,110,110,44,false},{"END",560,60,90,36,false}};
        auto stroke_edge = [&](double x1,double y1,double x2,double y2,bool dashed){
            cairo_move_to(cr,x1,y1); cairo_line_to(cr,x2,y2);
            if(dashed){ double d[]={6,4}; cairo_set_dash(cr,d,2,0); } else cairo_set_dash(cr,nullptr,0,0);
            cairo_set_source_rgb(cr,0.22,0.45,0.80); cairo_set_line_width(cr,1.4); cairo_stroke(cr);
            cairo_set_dash(cr,nullptr,0,0);
            double ang = atan2(y2-y1,x2-x1);
            double ax=x2, ay=y2;
            cairo_move_to(cr,ax,ay); cairo_line_to(cr, ax - 8*cos(ang - 0.45), ay - 8*sin(ang - 0.45));
            cairo_line_to(cr, ax - 8*cos(ang + 0.45), ay - 8*sin(ang + 0.45)); cairo_close_path(cr);
            cairo_set_source_rgb(cr,0.22,0.45,0.80); cairo_fill(cr);
        };
        stroke_edge(120,78,140,82,false);
        stroke_edge(250,82,280,82,false);
        stroke_edge(335,60,420,42,true);
        stroke_edge(335,104,420,132,true);
        stroke_edge(530,42,560,78,false);
        stroke_edge(530,132,560,78,false);
        for(auto &n: nodes){
            if(dark) cairo_set_source_rgb(cr,0.24,0.24,0.26); else cairo_set_source_rgb(cr,1,1,1);
            double r=10;
            cairo_move_to(cr, n.x+r, n.y); cairo_line_to(cr, n.x+n.w-r, n.y); cairo_arc(cr, n.x+n.w-r, n.y+r, r, -M_PI/2, 0);
            cairo_line_to(cr, n.x+n.w, n.y+n.h-r); cairo_arc(cr, n.x+n.w-r, n.y+n.h-r, r, 0, M_PI/2);
            cairo_line_to(cr, n.x+r, n.y+n.h); cairo_arc(cr, n.x+r, n.y+n.h-r, r, M_PI/2, M_PI);
            cairo_line_to(cr, n.x, n.y+r); cairo_arc(cr, n.x+r, n.y+r, r, M_PI, 3*M_PI/2); cairo_close_path(cr);
            cairo_fill_preserve(cr);
            if(n.conditional){ cairo_set_source_rgb(cr,0.85,0.55,0.15); cairo_set_line_width(cr,1.4); }
            else { if(dark) cairo_set_source_rgb(cr,0.38,0.38,0.40); else cairo_set_source_rgb(cr,0.68,0.68,0.70); cairo_set_line_width(cr,1.0); }
            cairo_stroke(cr);
            cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_BOLD); cairo_set_font_size(cr,11);
            if(dark) cairo_set_source_rgb(cr,0.92,0.92,0.94); else cairo_set_source_rgb(cr,0.18,0.18,0.20);
            cairo_text_extents_t ext; cairo_text_extents(cr, n.label, &ext);
            cairo_move_to(cr, n.x + (n.w - ext.width)/2 - ext.x_bearing, n.y + n.h/2 + 4);
            cairo_show_text(cr, n.label);
            if(std::string(n.label)=="Sky"){
                cairo_arc(cr, n.x+n.w-8, n.y+8, 6, 0, 2*M_PI);
                cairo_set_source_rgb(cr,0.80,0.20,0.20); cairo_fill(cr);
                cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_BOLD); cairo_set_font_size(cr,7);
                cairo_set_source_rgb(cr,1,1,1); cairo_move_to(cr, n.x+n.w-11, n.y+11); cairo_show_text(cr, "!");
            }
        }
        cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL); cairo_set_font_size(cr,9);
        if(dark) cairo_set_source_rgba(cr,0.75,0.75,0.78,0.9); else cairo_set_source_rgba(cr,0.35,0.35,0.38,0.9);
        cairo_move_to(cr, 12, 14); cairo_show_text(cr, "StateGraph — messages: append reducer, sensitive/complex: replace");
        cairo_move_to(cr, 12, h-8); cairo_show_text(cr, "Checkpointer: DataLayer Postgres  •  Interrupt: before Sky  •  Dashed = conditional");
    }, nullptr, nullptr);
    gtk_box_append(GTK_BOX(canvas_box), canvas);
    GtkWidget *event_hdr = gtk_label_new("Event log (Started → NodeStarted/Finished → Interrupted → Finished)");
    gtk_widget_add_css_class(event_hdr, "dim-label");
    gtk_widget_set_margin_top(event_hdr, 6);
    gtk_box_append(GTK_BOX(canvas_box), event_hdr);
    st->event_list = gtk_list_box_new();
    GtkWidget *event_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(event_scroll), st->event_list);
    gtk_widget_set_size_request(event_scroll, -1, 140);
    gtk_box_append(GTK_BOX(canvas_box), event_scroll);
    gtk_paned_set_start_child(GTK_PANED(mid), canvas_box);
    gtk_paned_set_resize_start_child(GTK_PANED(mid), TRUE);
    GtkWidget *inspector = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_size_request(inspector, 260, -1);
    gtk_widget_set_margin_top(inspector, 12); gtk_widget_set_margin_start(inspector, 8); gtk_widget_set_margin_end(inspector, 8);
    GtkWidget *ins_hdr = gtk_label_new("State Inspector");
    gtk_widget_add_css_class(ins_hdr, "title-4");
    gtk_box_append(GTK_BOX(inspector), ins_hdr);
    gtk_box_append(GTK_BOX(inspector), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    st->state_label = gtk_label_new("Messages: (none)\nThread: tessy-sky-demo");
    gtk_label_set_xalign(GTK_LABEL(st->state_label), 0); gtk_label_set_wrap(GTK_LABEL(st->state_label), TRUE);
    gtk_label_set_selectable(GTK_LABEL(st->state_label), TRUE);
    gtk_box_append(GTK_BOX(inspector), st->state_label);
    st->checkpoints_label = gtk_label_new("Checkpoints: 0");
    gtk_label_set_xalign(GTK_LABEL(st->checkpoints_label), 0);
    gtk_box_append(GTK_BOX(inspector), st->checkpoints_label);
    GtkWidget *zoom = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.5, 2.0, 0.1);
    gtk_range_set_value(GTK_RANGE(zoom), 1.0);
    gtk_box_append(GTK_BOX(inspector), gtk_label_new("Zoom"));
    gtk_box_append(GTK_BOX(inspector), zoom);
    GtkWidget *hint = gtk_label_new("Reducers: messages→append, flags→replace. Time-travel via checkpoint thread_id.");
    gtk_label_set_wrap(GTK_LABEL(hint), TRUE); gtk_widget_add_css_class(hint, "dim-label");
    gtk_box_append(GTK_BOX(inspector), hint);
    gtk_paned_set_end_child(GTK_PANED(mid), inspector);
    gtk_paned_set_resize_end_child(GTK_PANED(mid), FALSE);
    gtk_paned_set_end_child(GTK_PANED(hpaned), mid);
    gtk_paned_set_resize_end_child(GTK_PANED(hpaned), TRUE);
    gtk_paned_set_position(GTK_PANED(hpaned), 220);
    gtk_paned_set_position(GTK_PANED(mid), 760);
    wf_append_event(st, "StateGraph ready — Tessy → Router → Sky/Synthesis → END. Enter a prompt and Run.");
    wf_update_state_view(st);
    g_object_set_data_full(G_OBJECT(hpaned), "wf-state", st, [](gpointer p){ delete (WFState*)p; });
    return hpaned;
}
} // namespace tessera
