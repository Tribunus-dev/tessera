#include "ChatView.h"
#include "core/provider.h"
#include "core/data/DataLayer.h"
#include "ui/widgets/ChatBubble.h"
#include <adwaita.h>
#include <vector>

namespace tessera {

struct ChatViewState{ DataLayer* dl; LLMProvider* provider; GtkWidget* list; GtkWidget* entry; GtkWidget* sendBtn; std::vector<ChatMessage> history; };

static void bubble_append(ChatViewState* st, ChatRole role, const std::string& text){
    GtkWidget* w = chat_bubble_new(role, text, "");
    gtk_list_box_append(GTK_LIST_BOX(st->list), w);
    // auto-scroll handled by parent ScrolledWindow
}

static void on_send_clicked(GtkButton*, gpointer d){
    ChatViewState* st=(ChatViewState*)d;
    const char* txt = gtk_editable_get_text(GTK_EDITABLE(st->entry));
    if(!txt || !*txt) return;
    std::string prompt=txt;
    gtk_editable_set_text(GTK_EDITABLE(st->entry), "");
    bubble_append(st, ChatRole::User, prompt);
    st->history.push_back({ChatRole::User, prompt});
    // typing indicator
    GtkWidget* typing = chat_bubble_new(ChatRole::Assistant, "…", "");
    gtk_list_box_append(GTK_LIST_BOX(st->list), typing);
    // dispatch to LLMProvider off GTK thread
    LLMProvider* prov = st->provider;
    if(!prov) { gtk_list_box_remove(GTK_LIST_BOX(st->list), typing); bubble_append(st, ChatRole::Assistant, "No provider configured. Select a model in Settings."); return; }
    struct Job{ ChatViewState* st; std::string prompt; GtkWidget* typing; LLMProvider* prov; std::string acc; };
    Job* job=new Job{st, prompt, typing, prov, ""};
    g_thread_new("chat-send", [](gpointer p)->gpointer{
        Job* j=(Job*)p;
        j->prov->send(j->prompt, [j](const std::string& delta, bool done){
            j->acc+=delta;
            std::string* tmp=new std::string(j->acc);
            GtkWidget* typing=j->typing; ChatViewState* st=j->st;
            g_idle_add([](gpointer q)->gboolean{
                auto *a=(std::pair<ChatViewState*, std::string*>*)q;
                ChatViewState* s=a->first; std::string* txt=a->second;
                // replace typing bubble text via remove+append (simple)
                // find typing row is last
                GtkWidget* list=s->list;
                GtkWidget* last=gtk_widget_get_last_child(list);
                if(last) gtk_list_box_remove(GTK_LIST_BOX(list), last);
                bubble_append(s, ChatRole::Assistant, *txt);
                delete txt; delete a; return G_SOURCE_REMOVE;
            }, new std::pair<ChatViewState*, std::string*>(st, tmp));
            if(done){
                g_idle_add([](gpointer q)->gboolean{ Job* jj=(Job*)q; jj->st->history.push_back({ChatRole::Assistant, jj->acc}); delete jj; return G_SOURCE_REMOVE; }, j);
            }
        }, [j](const std::string& err){
            g_idle_add([](gpointer q)->gboolean{
                auto *pr=(std::pair<ChatViewState*, std::string>*)q;
                GtkWidget* last=gtk_widget_get_last_child(pr->first->list);
                if(last) gtk_list_box_remove(GTK_LIST_BOX(pr->first->list), last);
                bubble_append(pr->first, ChatRole::Assistant, "Error: "+pr->second);
                delete pr; return G_SOURCE_REMOVE;
            }, new std::pair<ChatViewState*, std::string>(j->st, err));
            delete j;
        });
        return nullptr;
    }, job);
}

GtkWidget* chat_view_new(DataLayer* dl, LLMProvider* provider){
    ChatViewState* st=new ChatViewState{dl, provider, nullptr, nullptr, nullptr, {}};
    GtkWidget* outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    // message list
    GtkWidget* list=gtk_list_box_new(); gtk_widget_add_css_class(list,"chat-list"); gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_NONE);
    // placeholder history
    GtkWidget* sc=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), list); gtk_widget_set_vexpand(sc, TRUE); gtk_widget_set_hexpand(sc, TRUE);
    gtk_box_append(GTK_BOX(outer), sc);
    st->list=list;
    // input bar
    GtkWidget* bar=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,6); gtk_widget_set_margin_top(bar,6); gtk_widget_set_margin_bottom(bar,6); gtk_widget_set_margin_start(bar,6); gtk_widget_set_margin_end(bar,6);
    GtkWidget* entry=gtk_entry_new(); gtk_widget_set_hexpand(entry, TRUE); gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "Ask Tessy… (Enter to send)");
    GtkWidget* send=gtk_button_new_with_label("Send"); gtk_widget_add_css_class(send,"suggested-action");
    gtk_box_append(GTK_BOX(bar), entry); gtk_box_append(GTK_BOX(bar), send);
    st->entry=entry; st->sendBtn=send;
    g_signal_connect(send,"clicked",G_CALLBACK(on_send_clicked), st);
    g_signal_connect(entry,"activate",G_CALLBACK(+[](GtkEntry*, gpointer d){ on_send_clicked(nullptr,d); }), st);
    gtk_box_append(GTK_BOX(outer), bar);
    // welcome bubble
    bubble_append(st, ChatRole::Assistant, "Hello — Tessy here, running locally on this device. Ask anything.");
    return outer;
}

} // namespace tessera
