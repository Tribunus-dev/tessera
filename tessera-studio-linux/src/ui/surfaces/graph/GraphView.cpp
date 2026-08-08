#include "GraphView.h"
#include "core/data/DataLayer.h"
#include <adwaita.h>
#include <cmath>
#include <unordered_map>
#include <vector>
#include <string>
#include <algorithm>
#include <mutex>
namespace tessera {

struct GNode{ std::string id,label,etype; double x,y,vx,vy, r; bool pinned=false; };
struct GEdge{ std::string src,dst,type; float w; };
struct GraphState{
    DataLayer *dl=nullptr;
    GtkWidget *area=nullptr;
    GtkWidget *inspector_label=nullptr;
    std::vector<GNode> nodes;
    std::vector<GEdge> edges;
    std::string selected;
    guint timer=0;
    std::unordered_map<std::string,int> idx;
    std::mutex mu;
};

static void color_for(const std::string &t, double &r,double &g,double &b){
    if(t=="contact"||t=="person") { r=0.22; g=0.45; b=0.80; }
    else if(t=="calendar_event") { r=0.80; g=0.30; b=0.15; }
    else if(t=="email") { r=0.35; g=0.55; b=0.35; }
    else if(t=="chat_message") { r=0.60; g=0.40; b=0.70; }
    else if(t=="web_page") { r=0.75; g=0.55; b=0.15; }
    else if(t=="note"||t=="document") { r=0.15; g=0.55; b=0.75; }
    else if(t=="task"||t=="reminder") { r=0.30; g=0.65; b=0.35; }
    else { r=0.45; g=0.45; b=0.48; }
}
static std::string short_label(const std::string &s){ return s.size()>22? s.substr(0,22)+"…": s; }

static void load_graph(GraphState *st){
    if(!st->dl){
        std::lock_guard<std::mutex> lk(st->mu);
        st->nodes.clear(); st->edges.clear(); st->idx.clear();
        return;
    }
    // fetch off-lock (blocks on podman exec, don't hold mu)
    auto rows = st->dl->list_graph_nodes(80);
    auto erows = st->dl->list_graph_edges(300);
    std::lock_guard<std::mutex> lk(st->mu);
    st->nodes.clear(); st->edges.clear(); st->idx.clear();
    int i=0;
    for(auto &r: rows){
        double ang = (i* 2*M_PI)/std::max(1,(int)rows.size());
        double rad = 110 + (i%3)*45;
        GNode n{r.id, r.label.empty()? r.entity_type : r.label, r.entity_type, 300+rad*cos(ang), 220+rad*sin(ang), (double)(rand()%100)/300.0 -0.15, (double)(rand()%100)/300.0 -0.15, 10.0 + std::min(10.0, (double)r.label.size()/3.0), false};
        st->idx[n.id]=st->nodes.size();
        st->nodes.push_back(std::move(n)); i++;
    }
    for(auto &e: erows) st->edges.push_back({e.source_id,e.target_id,e.link_type,e.weight});
    // degree-based radius + pinned if high degree
    std::unordered_map<std::string,int> deg;
    for(auto &e: st->edges){ deg[e.src]++; deg[e.dst]++; }
    for(auto &n: st->nodes){
        int d=deg[n.id];
        n.r = 8 + std::min(14.0, 4.0 + d*1.8);
        n.pinned = d>=4;
    }
}

static void sim_step(GraphState *st){
    std::lock_guard<std::mutex> lk(st->mu);
    int n=st->nodes.size(); if(n==0) return;
    double cx=360, cy=240;
    // repulsion
    for(int i=0;i<n;i++) for(int j=i+1;j<n;j++){
        double dx=st->nodes[j].x - st->nodes[i].x;
        double dy=st->nodes[j].y - st->nodes[i].y;
        double d2=dx*dx+dy*dy+0.01; double d=sqrt(d2);
        double rep = 4200.0 / d2;
        double fx = rep * dx / d * 0.08;
        double fy = rep * dy / d * 0.08;
        if(!st->nodes[i].pinned){ st->nodes[i].vx -= fx; st->nodes[i].vy -= fy; }
        if(!st->nodes[j].pinned){ st->nodes[j].vx += fx; st->nodes[j].vy += fy; }
    }
    // attraction
    for(auto &e: st->edges){
        auto it1=st->idx.find(e.src), it2=st->idx.find(e.dst);
        if(it1==st->idx.end()||it2==st->idx.end()) continue;
        GNode &a=st->nodes[it1->second], &b=st->nodes[it2->second];
        double dx=b.x-a.x, dy=b.y-a.y, d=sqrt(dx*dx+dy*dy)+0.01;
        double attr = 0.015 * d * std::max(0.3f, e.w);
        double fx=attr*dx/d, fy=attr*dy/d;
        if(!a.pinned){ a.vx+=fx; a.vy+=fy; }
        if(!b.pinned){ b.vx-=fx; b.vy-=fy; }
    }
    // center + damp + clamp
    for(auto &nd: st->nodes){
        if(nd.pinned) continue;
        nd.vx += (cx-nd.x)*0.002;
        nd.vy += (cy-nd.y)*0.002;
        nd.vx *= 0.82; nd.vy *= 0.82;
        nd.x += nd.vx; nd.y += nd.vy;
        nd.x = std::clamp(nd.x, 18.0, 702.0); nd.y = std::clamp(nd.y, 18.0, 462.0);
    }
}

static void on_draw(GtkDrawingArea*,cairo_t *cr,int w,int h,gpointer data){
    GraphState *st=(GraphState*)data;
    // snapshot under lock, then draw without holding mu
    std::vector<GNode> nodes; std::vector<GEdge> edges; std::string selected;
    { std::lock_guard<std::mutex> lk(st->mu); nodes=st->nodes; edges=st->edges; selected=st->selected; }
    bool dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    if(dark) cairo_set_source_rgb(cr, 0.20,0.20,0.21); else cairo_set_source_rgb(cr, 1,1,1);
    cairo_paint(cr);
    // faint grid — Adwaita subtle, not aurora
    if(dark) cairo_set_source_rgba(cr, 0.30,0.30,0.32,1); else cairo_set_source_rgba(cr, 0.92,0.92,0.94,1);
    cairo_set_line_width(cr,0.5);
    for(int x=0;x<w;x+=42){ cairo_move_to(cr,x,0); cairo_line_to(cr,x,h);} for(int y=0;y<h;y+=42){ cairo_move_to(cr,0,y); cairo_line_to(cr,w,y);} cairo_stroke(cr);
    // edges — solid/dashed/dotted per link_type, alpha weight (use snapshot)
    // build index from snapshot nodes
    std::unordered_map<std::string,int> snap_idx;
    for(size_t i=0;i<nodes.size();++i) snap_idx[nodes[i].id]=(int)i;
    for(auto &e: edges){
        auto it1=snap_idx.find(e.src), it2=snap_idx.find(e.dst);
        if(it1==snap_idx.end()||it2==snap_idx.end()) continue;
        auto &a=nodes[it1->second], &b=nodes[it2->second];
        double alpha = 0.45 + 0.35*std::min(1.0f, e.w);
        cairo_set_source_rgba(cr, 0.55,0.55,0.60, alpha);
        cairo_set_line_width(cr, 1.0 + 1.2*std::min(1.0f,e.w));
        double dashSolid[]={};
        double dashDashed[]={6,4};
        double dashDotted[]={1.5,4};
        if(e.type=="superseded") { cairo_set_dash(cr,dashDashed,2,0); }
        else if(e.type=="voided") { cairo_set_dash(cr,dashDotted,2,0); }
        else cairo_set_dash(cr,dashSolid,0,0);
        cairo_move_to(cr,a.x,a.y); cairo_line_to(cr,b.x,b.y); cairo_stroke(cr);
        cairo_set_dash(cr,dashSolid,0,0);
    }
    // nodes (from snapshot)
    for(auto &n: nodes){
        double r,g,b; color_for(n.etype,r,g,b);
        bool sel = (n.id==selected);
        // halo for selected/pinned
        if(sel || n.pinned){
            cairo_set_source_rgba(cr,r,g,b,0.18);
            cairo_arc(cr,n.x,n.y,n.r+7,0,2*M_PI); cairo_fill(cr);
        }
        cairo_set_source_rgb(cr,r,g,b);
        cairo_arc(cr,n.x,n.y,n.r,0,2*M_PI); cairo_fill(cr);
        cairo_set_source_rgba(cr,0,0,0,0.10); cairo_arc(cr,n.x,n.y,n.r,0,2*M_PI); cairo_stroke(cr);
        // label — short, clipped, caption scale
        cairo_set_source_rgb(cr, 0.18,0.18,0.20);
        cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 8.5);
        std::string lbl=short_label(n.label);
        cairo_text_extents_t ext; cairo_text_extents(cr,lbl.c_str(),&ext);
        double lx=n.x - ext.width/2, ly=n.y + n.r + 10;
        // label bg pill
        cairo_set_source_rgba(cr,1,1,1,0.85);
        cairo_rectangle(cr,lx-4, ly-9, ext.width+8, 11); cairo_fill(cr);
        cairo_set_source_rgb(cr,0.18,0.18,0.20);
        cairo_move_to(cr,lx,ly); cairo_show_text(cr,lbl.c_str());
    }
    // legend footer
    cairo_set_source_rgba(cr,0.45,0.45,0.50,1);
    cairo_select_font_face(cr,"Sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr,9);
    cairo_move_to(cr,8,h-8); cairo_show_text(cr,"Graph — drag off; pin=high-degree. Click node for inspector.");
}

static gboolean on_click(GtkGestureClick*,int,int,double x,double y,gpointer data){
    GraphState *st=(GraphState*)data;
    // snapshot search under lock
    std::string bestId;
    {
        std::lock_guard<std::mutex> lk(st->mu);
        double best=1e9;
        for(auto &n: st->nodes){
            double dx=n.x-x, dy=n.y-y, d=sqrt(dx*dx+dy*dy);
            if(d < n.r+6 && d < best){ best=d; bestId=n.id; }
        }
        if(!bestId.empty()) st->selected=bestId;
    }
    if(!bestId.empty()){
        // immediate visual feedback + degree (non-blocking, from snapshot)
        {
            int deg=0;
            { std::lock_guard<std::mutex> lk(st->mu); for(auto &e: st->edges) if(e.src==bestId||e.dst==bestId) deg++; }
            std::string fallback;
            { std::lock_guard<std::mutex> lk(st->mu); auto it=st->idx.find(bestId); if(it!=st->idx.end()) fallback = st->nodes[it->second].etype + " · " + st->nodes[it->second].label; }
            std::string t = fallback + "\ndegree " + std::to_string(deg) + " · loading…";
            // sanitize to valid UTF-8 for GtkLabel
            char *valid = g_utf8_make_valid(t.c_str(), -1);
            gtk_label_set_text(GTK_LABEL(st->inspector_label), valid);
            g_free(valid);
        }
        gtk_widget_queue_draw(st->area);
        // fetch full row + receipts off GTK thread
        struct InspectJob{ GraphState *st; std::string id; };
        InspectJob *job = new InspectJob{st, bestId};
        g_thread_new("graph-inspect", [](gpointer p)->gpointer{
            InspectJob *j=(InspectJob*)p;
            GraphState *ss=j->st; std::string bid=j->id;
            auto row = ss->dl ? ss->dl->get_entity_row(bid) : std::nullopt;
            int rc = ss->dl ? ss->dl->receipt_chain_length(bid) : -1;
            int deg=0;
            { std::lock_guard<std::mutex> lk(ss->mu); for(auto &e: ss->edges) if(e.src==bid||e.dst==bid) deg++; }
            std::string fallback;
            { std::lock_guard<std::mutex> lk(ss->mu); auto it=ss->idx.find(bid); if(it!=ss->idx.end()) fallback = ss->nodes[it->second].etype + " · " + ss->nodes[it->second].label; }
            std::string txt;
            if(row) txt = row->entity_type + " · " + row->label + "\n" + row->source_url + "\n" + row->updated_at;
            else txt = fallback;
            txt += "\ndegree " + std::to_string(deg) + (rc>=0? " · receipts " + std::to_string(rc): "");
            char *valid = g_utf8_make_valid(txt.c_str(), -1);
            std::string *out = new std::string(valid); g_free(valid);
            struct Idle{ GraphState *st; std::string *txt; std::string id; };
            Idle *idle = new Idle{ss, out, bid};
            g_idle_add([](gpointer d)->gboolean{
                Idle *id=(Idle*)d;
                // only update if selection hasn't moved (avoid overwriting newer click)
                std::string cur; { std::lock_guard<std::mutex> lk(id->st->mu); cur=id->st->selected; }
                if(cur==id->id && id->st->inspector_label)
                    gtk_label_set_text(GTK_LABEL(id->st->inspector_label), id->txt->c_str());
                delete id->txt; delete id; return G_SOURCE_REMOVE;
            }, idle);
            delete j;
            return nullptr;
        }, job);
    }
    return TRUE;
}

GtkWidget* graph_view_new(DataLayer *dl){
    GraphState *st=new GraphState(); st->dl=dl;
    GtkWidget *box=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,12);
    GtkWidget *left=gtk_box_new(GTK_ORIENTATION_VERTICAL,8);
    gtk_widget_set_hexpand(left,TRUE);
    GtkWidget *area=gtk_drawing_area_new();
    gtk_widget_set_size_request(area,720,480);
    gtk_widget_add_css_class(area,"graph-canvas");
    gtk_widget_set_hexpand(area,TRUE); gtk_widget_set_vexpand(area,TRUE);
    st->area=area;
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), on_draw, st, nullptr);
    GtkGesture *click=gtk_gesture_click_new(); g_signal_connect(click,"pressed",G_CALLBACK(on_click), st);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(click));
    gtk_box_append(GTK_BOX(left), area);
    load_graph(st);
    // bottom inspector
    GtkWidget *insp=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
    gtk_widget_add_css_class(insp,"card"); gtk_widget_set_margin_top(insp,6);
    GtkWidget *insp_hdr=gtk_label_new("Inspector — click a node");
    gtk_widget_add_css_class(insp_hdr,"title-4"); gtk_label_set_xalign(GTK_LABEL(insp_hdr),0);
    GtkWidget *insp_lbl=gtk_label_new("No selection. Pinned nodes are always in view.");
    gtk_label_set_wrap(GTK_LABEL(insp_lbl),TRUE); gtk_label_set_xalign(GTK_LABEL(insp_lbl),0); gtk_widget_add_css_class(insp_lbl,"dim-label");
    st->inspector_label=insp_lbl;
    gtk_box_append(GTK_BOX(insp), insp_hdr); gtk_box_append(GTK_BOX(insp), insp_lbl);
    gtk_box_append(GTK_BOX(left), insp);
    gtk_box_append(GTK_BOX(box), left);
    // legend sidebar — Adwaita, not bento
    GtkWidget *side=gtk_box_new(GTK_ORIENTATION_VERTICAL,8);
    gtk_widget_set_size_request(side,160,-1);
    gtk_widget_add_css_class(side,"card");
    GtkWidget *side_hdr=gtk_label_new("Legend");
    gtk_widget_add_css_class(side_hdr,"title-4"); gtk_label_set_xalign(GTK_LABEL(side_hdr),0);
    gtk_box_append(GTK_BOX(side), side_hdr);
    const char* types[]={"contact","calendar_event","email","chat_message","web_page","note","task",nullptr};
    for(int i=0;types[i];i++){
        GtkWidget *row=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        double r,g,b; color_for(types[i],r,g,b);
        GtkWidget *dot=gtk_drawing_area_new(); gtk_widget_set_size_request(dot,10,10);
        double *col=new double[3]{r,g,b};
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(dot), [](GtkDrawingArea*,cairo_t* cr,int w,int h,gpointer d){ double *c=(double*)d; cairo_set_source_rgb(cr,c[0],c[1],c[2]); cairo_arc(cr,w/2,h/2,5,0,2*M_PI); cairo_fill(cr); }, col, [](gpointer d){ delete[] (double*)d; });
        GtkWidget *lbl=gtk_label_new(types[i]); gtk_widget_add_css_class(lbl,"caption");
        gtk_box_append(GTK_BOX(row), dot); gtk_box_append(GTK_BOX(row), lbl);
        gtk_box_append(GTK_BOX(side), row);
    }
    GtkWidget *refresh=gtk_button_new_with_label("Reload");
    gtk_widget_set_tooltip_text(refresh,"Reload from Postgres");
    g_signal_connect(refresh,"clicked", G_CALLBACK(+[](GtkButton*,gpointer d){ GraphState *s=(GraphState*)d; g_thread_new("graph-load", [](gpointer p)->gpointer{ GraphState *ss=(GraphState*)p; load_graph(ss); g_idle_add([](gpointer q)->gboolean{ GraphState *qq=(GraphState*)q; gtk_widget_queue_draw(qq->area); return G_SOURCE_REMOVE; }, ss); return nullptr; }, s); }), st);
    gtk_box_append(GTK_BOX(side), refresh);
    gtk_box_append(GTK_BOX(box), side);
    // 60fps sim — main-thread tick (no thread explosion), respects data lock
    st->timer = g_timeout_add(16, [](gpointer d)->gboolean{
        GraphState *ss=(GraphState*)d;
        sim_step(ss);
        gtk_widget_queue_draw(ss->area);
        return G_SOURCE_CONTINUE;
    }, st);
    return box;
}
void graph_view_refresh(GtkWidget *view){ (void)view; }

} // namespace tessera
