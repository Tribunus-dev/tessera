#include "Surface.h"
#include "ui/widgets/ChatBubble.h"
#include <adwaita.h>
#include <vector>
#include <string>

namespace tessera {
static GtkWidget *g_collab_history=nullptr;
static GtkWidget *g_collab_scroll=nullptr;

GtkWidget* collab_surface_new(){
    GtkWidget *outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,12);
    gtk_widget_set_margin_top(outer,12); gtk_widget_set_margin_start(outer,12); gtk_widget_set_margin_end(outer,12); gtk_widget_set_margin_bottom(outer,12);
    GtkWidget *hdr=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
    GtkWidget *title=gtk_label_new("Tessy & Sky — How Sky helps Tessy");
    gtk_widget_add_css_class(title,"title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    GtkWidget *sub=gtk_label_new("Inspectable reasoning: Tessy keeps your personal context local; when a task is complex she asks Sky (cloud-only) for help. This log shows that handoff — not the main group chat.");
    gtk_widget_add_css_class(sub,"dim-label"); gtk_label_set_wrap(GTK_LABEL(sub),TRUE); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(hdr),title); gtk_box_append(GTK_BOX(hdr),sub);
    gtk_box_append(GTK_BOX(outer),hdr);
    GtkWidget *exp=gtk_expander_new("How it works");
    GtkWidget *exp_lbl=gtk_label_new("• Group Chat (right dock): Tessy + Sky answer you together.\n• This view: Tessy → Sky request, Sky reasoning, Tessy synthesis — inspectable.\n• Sensitive data (notes/mail/calendar) never leaves device; Sky only sees the abstracted task.");
    gtk_label_set_wrap(GTK_LABEL(exp_lbl),TRUE); gtk_label_set_xalign(GTK_LABEL(exp_lbl),0); gtk_widget_add_css_class(exp_lbl,"dim-label");
    gtk_expander_set_child(GTK_EXPANDER(exp),exp_lbl);
    gtk_box_append(GTK_BOX(outer),exp);
    GtkWidget *scroll=gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll,TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),GTK_POLICY_NEVER,GTK_POLICY_AUTOMATIC);
    gtk_widget_add_css_class(scroll,"chat-scroll");
    GtkWidget *history=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
    gtk_widget_set_margin_top(history,6); gtk_widget_set_margin_bottom(history,6);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll),history);
    g_collab_history=history; g_collab_scroll=scroll;
    // seed example trace
    gtk_box_append(GTK_BOX(history), chat_timestamp_new("Inspectable trace — example"));
    gtk_box_append(GTK_BOX(history), chat_bubble_new(ChatRole::Assistant, "Tessy: User asked to summarize Q3 notes and explain the trends — that's personal (notes) + complex (analysis). I'll keep the notes local and ask Sky to help reason about the trends.", false));
    gtk_box_append(GTK_BOX(history), chat_bubble_new(ChatRole::Sky, "Sky: Got the abstracted trends (no raw notes). Here's the reasoning: revenue up 12%, churn down — likely due to onboarding fix. Suggest framing for user.", false));
    gtk_box_append(GTK_BOX(history), chat_bubble_new(ChatRole::Assistant, "Tessy: Thanks Sky. Synthesized for user — sharing summary without exposing raw notes.", false));
    gtk_box_append(GTK_BOX(outer),scroll);
    GtkWidget *foot=gtk_label_new("Tip: Complex prompts automatically populate this view. Clear with right-click → Clear.");
    gtk_widget_add_css_class(foot,"caption"); gtk_widget_add_css_class(foot,"dim-label"); gtk_label_set_xalign(GTK_LABEL(foot),0);
    gtk_box_append(GTK_BOX(outer),foot);
    // clear on right-click
    GtkGesture *click=gtk_gesture_click_new(); gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click),3);
    g_signal_connect(click,"pressed",G_CALLBACK(+[](GtkGesture*,int,int,double,double,gpointer){
        if(!g_collab_history) return;
        GtkWidget *ch=gtk_widget_get_first_child(g_collab_history);
        while(ch){ GtkWidget *n=gtk_widget_get_next_sibling(ch); gtk_box_remove(GTK_BOX(g_collab_history),ch); ch=n; }
    }),nullptr);
    gtk_widget_add_controller(scroll,GTK_EVENT_CONTROLLER(click));
    GtkWidget *wrap=gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(wrap),GTK_POLICY_NEVER,GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(wrap),outer);
    return wrap;
}
void collab_log_append(const char* from, const char* text){
    if(!g_collab_history) return;
    ChatRole r = (from && std::string(from)=="Sky") ? ChatRole::Sky : ChatRole::Assistant;
    std::string t = std::string(from?from:"Tessy") + ": " + (text?text:"");
    GtkWidget *b = chat_bubble_new(r, t, false);
    // must be on GTK thread
    if(g_main_context_is_owner(nullptr)){
        gtk_box_append(GTK_BOX(g_collab_history), b);
        if(g_collab_scroll){
            auto *adj=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(g_collab_scroll));
            gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj));
        }
    } else {
        struct P{ GtkWidget *hist; GtkWidget *bub; GtkWidget *scroll; };
        P *p=new P{g_collab_history,b,g_collab_scroll};
        g_idle_add([](gpointer d)->gboolean{
            P *pp=(P*)d;
            gtk_box_append(GTK_BOX(pp->hist), pp->bub);
            if(pp->scroll){
                auto *adj=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(pp->scroll));
                gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj));
            }
            delete pp; return G_SOURCE_REMOVE;
        },p);
    }
}
}
