#include "Surface.h"
#include "core/ops/Capacity.h"
#include "core/provider.h"
#include "core/config.h"
#include "core/encryption/Secrets.h"
#include "core/moe/MoE.h"
#include "ui/widgets/ChatBubble.h"
#include "ui/surfaces/models/Surface.h"
#include <adwaita.h>
#include <gio/gio.h>
#include <glib.h>

namespace tessera {

static GtkWidget* badge_new(const std::string &b){
    GtkWidget *w=gtk_label_new(b=="green"?"fits":b=="amber"?"tight":"needs RAM");
    gtk_widget_add_css_class(w,"caption");
    if(b=="green") gtk_widget_add_css_class(w,"accent");
    else gtk_widget_add_css_class(w,"dim-label");
    return w;
}

GtkWidget* capacity_surface_new(){
    LocalCapacity cap = gather_capacity();
    auto fits = community_fits(cap);

    GtkWidget *outer=gtk_box_new(GTK_ORIENTATION_VERTICAL,12);
    gtk_widget_set_margin_top(outer,12); gtk_widget_set_margin_start(outer,12); gtk_widget_set_margin_end(outer,12); gtk_widget_set_margin_bottom(outer,12);

    GtkWidget *hdr=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
    GtkWidget *title=gtk_label_new("Local System Capacity");
    gtk_widget_add_css_class(title,"title-2"); gtk_label_set_xalign(GTK_LABEL(title),0);
    GtkWidget *sub=gtk_label_new("What's left on this machine for GGUFs — local-first, cloud is opt-in. No benchmark clutters the daily view.");
    gtk_widget_add_css_class(sub,"dim-label"); gtk_label_set_wrap(GTK_LABEL(sub),TRUE); gtk_label_set_xalign(GTK_LABEL(sub),0);
    gtk_box_append(GTK_BOX(hdr),title); gtk_box_append(GTK_BOX(hdr),sub);
    gtk_box_append(GTK_BOX(outer),hdr);

    // Capacity cards — Adwaita, no purple/gradient/glass/bento
    GtkWidget *flow=gtk_flow_box_new();
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow),3);
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(flow),1);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow),12);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow),12);
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow),GTK_SELECTION_NONE);
    gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(flow),TRUE);

    auto card = [](const char* t, const char* v, const char* d)->GtkWidget*{
        GtkWidget *c=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
        gtk_widget_add_css_class(c,"card"); gtk_widget_add_css_class(c,"provider-card");
        GtkWidget *tt=gtk_label_new(t); gtk_widget_add_css_class(tt,"title-4"); gtk_label_set_xalign(GTK_LABEL(tt),0);
        GtkWidget *vv=gtk_label_new(v); gtk_label_set_xalign(GTK_LABEL(vv),0); gtk_label_set_wrap(GTK_LABEL(vv),TRUE);
        GtkWidget *dd=gtk_label_new(d); gtk_widget_add_css_class(dd,"caption"); gtk_widget_add_css_class(dd,"dim-label"); gtk_label_set_xalign(GTK_LABEL(dd),0); gtk_label_set_wrap(GTK_LABEL(dd),TRUE);
        gtk_box_append(GTK_BOX(c),tt); gtk_box_append(GTK_BOX(c),vv); gtk_box_append(GTK_BOX(c),dd);
        return c;
    };
    char mem_buf[128]; snprintf(mem_buf,sizeof(mem_buf),"%lu GB total · %lu GB avail", cap.ram_total_mb/1024, cap.ram_avail_mb/1024);
    GtkWidget *mem_card=card("Memory", mem_buf, cap.swap_total_mb? "Swap available" : "No swap");
    GtkWidget *lvl=gtk_level_bar_new();
    double frac = cap.ram_total_mb? (double)cap.ram_avail_mb/cap.ram_total_mb : 0.7;
    gtk_level_bar_set_value(GTK_LEVEL_BAR(lvl), frac);
    gtk_level_bar_set_min_value(GTK_LEVEL_BAR(lvl),0); gtk_level_bar_set_max_value(GTK_LEVEL_BAR(lvl),1);
    gtk_box_append(GTK_BOX(mem_card), lvl);
    gtk_flow_box_append(GTK_FLOW_BOX(flow), mem_card);

    char cpu_buf[256]; snprintf(cpu_buf,sizeof(cpu_buf),"%s\n%dC/%dT · %s", cap.cpu_model.c_str(), cap.cpu_cores, cap.cpu_threads, cap.cpu_isa.c_str());
    GtkWidget *cpu_card=card("Compute", cpu_buf, cap.bandwidth_gbs>0? (std::to_string((int)cap.bandwidth_gbs)+" GB/s shared").c_str() : "Bandwidth est.");
    gtk_flow_box_append(GTK_FLOW_BOX(flow), cpu_card);

    std::string gpu_txt = cap.igpu.name;
    if(cap.dgpu) gpu_txt += "\n" + cap.dgpu->name + " " + std::to_string(cap.dgpu->vram_mb) + "MB";
    if(cap.egpu) gpu_txt += "\n" + cap.egpu->name + " (eGPU TB4)";
    if(cap.npu && cap.npu->present) gpu_txt += "\nNPU " + std::to_string(cap.npu->tops) + " TOPS";
    GtkWidget *gpu_card=card("Graphics & NPU", gpu_txt.c_str(), cap.egpu? "eGPU via Thunderbolt" : cap.dgpu? "dGPU present" : cap.npu&&cap.npu->present? "NPU present" : "No dGPU/eGPU — iGPU only");
    gtk_flow_box_append(GTK_FLOW_BOX(flow), gpu_card);

    gtk_box_append(GTK_BOX(outer), flow);

    // Fit bar — which GGUFs fit in avail RAM
    GtkWidget *fit_hdr=gtk_label_new("Community GGUFs — fit on this machine");
    gtk_widget_add_css_class(fit_hdr,"title-3"); gtk_label_set_xalign(GTK_LABEL(fit_hdr),0); gtk_widget_set_margin_top(fit_hdr,8);
    gtk_box_append(GTK_BOX(outer), fit_hdr);
    GtkWidget *fit_sub=gtk_label_new("Estimated tokens/s from bandwidth / model_bytes. Green = fits + fast, amber = fits tight, red = needs more RAM/offload.");
    gtk_widget_add_css_class(fit_sub,"caption"); gtk_widget_add_css_class(fit_sub,"dim-label"); gtk_label_set_wrap(GTK_LABEL(fit_sub),TRUE); gtk_label_set_xalign(GTK_LABEL(fit_sub),0);
    gtk_box_append(GTK_BOX(outer), fit_sub);

    GtkWidget *list=gtk_list_box_new(); gtk_widget_add_css_class(list,"boxed-list");
    for(auto &m: fits){
        GtkWidget *row=gtk_list_box_row_new();
        GtkWidget *h=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,10);
        gtk_widget_set_margin_top(h,6); gtk_widget_set_margin_bottom(h,6); gtk_widget_set_margin_start(h,8); gtk_widget_set_margin_end(h,8);
        GtkWidget *v=gtk_box_new(GTK_ORIENTATION_VERTICAL,2); gtk_widget_set_hexpand(v,TRUE);
        char t2[128]; snprintf(t2,sizeof(t2),"%s · %.1fGB · %s", m.id.c_str(), m.size_mb/1024.0, m.quant.c_str());
        GtkWidget *lbl=gtk_label_new(t2); gtk_label_set_xalign(GTK_LABEL(lbl),0);
        char e2[128]; snprintf(e2,sizeof(e2),"est. %.1f tok/s on this box", m.est_tok_s);
        GtkWidget *est=gtk_label_new(e2); gtk_widget_add_css_class(est,"caption"); gtk_widget_add_css_class(est,"dim-label"); gtk_label_set_xalign(GTK_LABEL(est),0);
        gtk_box_append(GTK_BOX(v),lbl); gtk_box_append(GTK_BOX(v),est);
        GtkWidget *bd=badge_new(m.badge);
        gtk_box_append(GTK_BOX(h),v); gtk_box_append(GTK_BOX(h),bd);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row),h);
        gtk_list_box_append(GTK_LIST_BOX(list),row);
    }
    GtkWidget *scroll=gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll),list);
    gtk_widget_set_vexpand(scroll,TRUE); gtk_widget_set_size_request(scroll,-1,280);
    gtk_box_append(GTK_BOX(outer),scroll);

    // Bootstrap Tessy with Sky's help — Sky benches, picks a model, fetches for Tessy
    GtkWidget *boot_hdr=gtk_label_new("Bootstrap Tessy — Sky helps");
    gtk_widget_add_css_class(boot_hdr,"title-3"); gtk_label_set_xalign(GTK_LABEL(boot_hdr),0); gtk_widget_set_margin_top(boot_hdr,12);
    gtk_box_append(GTK_BOX(outer),boot_hdr);
    GtkWidget *boot_sub=gtk_label_new("Tessy is local and handles your sensitive personal data. Sky is cloud-only — she can bench this machine, recommend a model that fits, fetch it, and set Tessy up. Your notes/mail never leave the device.");
    gtk_widget_add_css_class(boot_sub,"caption"); gtk_widget_add_css_class(boot_sub,"dim-label"); gtk_label_set_wrap(GTK_LABEL(boot_sub),TRUE); gtk_label_set_xalign(GTK_LABEL(boot_sub),0);
    gtk_box_append(GTK_BOX(outer),boot_sub);
    GtkWidget *boot_card=gtk_box_new(GTK_ORIENTATION_VERTICAL,8);
    gtk_widget_add_css_class(boot_card,"card"); gtk_widget_add_css_class(boot_card,"provider-card");
    // Current Tessy model
    {
        GSettings *gs=g_settings_new("org.tessera.TesseraStudio");
        char *mp=g_settings_get_string(gs,"on-device-model-path");
        std::string cur = (mp && *mp) ? mp : "(none — Tessy has no model yet)";
        g_free(mp); g_object_unref(gs);
        GtkWidget *cur_row=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget *cur_lbl=gtk_label_new(("Tessy model: " + cur).c_str()); gtk_label_set_xalign(GTK_LABEL(cur_lbl),0); gtk_widget_set_hexpand(cur_lbl,TRUE); gtk_label_set_ellipsize(GTK_LABEL(cur_lbl),PANGO_ELLIPSIZE_MIDDLE);
        gtk_box_append(GTK_BOX(cur_row),cur_lbl);
        gtk_box_append(GTK_BOX(boot_card),cur_row);
    }
    // Sky recommendation area
    GtkWidget *sky_box=gtk_box_new(GTK_ORIENTATION_VERTICAL,6);
    GtkWidget *sky_scroll=gtk_scrolled_window_new(); gtk_widget_set_size_request(sky_scroll,-1,120);
    GtkWidget *sky_hist=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sky_scroll),sky_hist);
    gtk_box_append(GTK_BOX(sky_box),sky_scroll);
    // Seed Sky's persona
    gtk_box_append(GTK_BOX(sky_hist), chat_bubble_new(ChatRole::Sky, "Sky: I can bench your system and pick a model for Tessy. Tell me to bench, recommend, or bootstrap — I'll keep your personal data local.", false));
    gtk_box_append(GTK_BOX(boot_card),sky_box);
    GtkWidget *btn_row=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
    GtkWidget *bench_btn=gtk_button_new_with_label("Bench with Sky");
    gtk_widget_add_css_class(bench_btn,"pill");
    GtkWidget *rec_btn=gtk_button_new_with_label("Ask Sky to recommend");
    gtk_widget_add_css_class(rec_btn,"pill"); gtk_widget_add_css_class(rec_btn,"suggested-action");
    GtkWidget *fetch_btn2=gtk_button_new_with_label("Fetch for Tessy…");
    gtk_widget_add_css_class(fetch_btn2,"pill");
    gtk_box_append(GTK_BOX(btn_row),bench_btn); gtk_box_append(GTK_BOX(btn_row),rec_btn); gtk_box_append(GTK_BOX(btn_row),fetch_btn2);
    gtk_box_append(GTK_BOX(boot_card),btn_row);
    // Bench: re-gather capacity and show Sky's bench summary
    g_signal_connect(bench_btn,"clicked", G_CALLBACK((+[](GtkButton*, gpointer d){
        auto *hist=(GtkWidget*)d;
        LocalCapacity c=gather_capacity();
        char buf[256]; snprintf(buf,sizeof(buf),"Bench: %s · %luGB avail · %.0f GB/s", c.cpu_model.c_str(), c.ram_avail_mb/1024, c.bandwidth_gbs);
        GtkWidget *b=chat_bubble_new(ChatRole::Sky, std::string("Sky: ") + buf + " — i can now recommend a model that fits this budget.", false);
        g_idle_add([](gpointer p)->gboolean{ auto *pr=(std::pair<GtkWidget*,GtkWidget*>*)p; gtk_box_append(GTK_BOX(pr->first), pr->second); delete pr; return G_SOURCE_REMOVE; }, new std::pair<GtkWidget*,GtkWidget*>(hist,b));
    })), sky_hist);
    // Recommend: ask Sky (cloud) to pick a model that fits
    g_signal_connect(rec_btn,"clicked", G_CALLBACK((+[](GtkButton *b, gpointer d){
        auto *hist=(GtkWidget*)d;
        gtk_widget_set_sensitive(GTK_WIDGET(b),FALSE);
        GtkWidget *stream=chat_bubble_new(ChatRole::Sky, "", true);
        gtk_box_append(GTK_BOX(hist),stream);
        LocalCapacity c=gather_capacity();
        auto fits=community_fits(c);
        std::string best; for(auto &m: fits) if(m.fits_ram){ best=m.id; break; }
        if(best.empty()) best="phi-3-mini 3.8b Q4";
        std::string prompt = "System: " + c.summary() + " RAM avail " + std::to_string(c.ram_avail_mb) + "MB. Recommend the best community GGUF from [" + best + "] that fits, for Tessy local. Keep personal data local.";
        // find Sky provider
        std::string cpid="openai";
        {
            GSettings *gs=g_settings_new("org.tessera.TesseraStudio");
            char *cp=g_settings_get_string(gs,"cloud-provider"); if(cp && *cp) cpid=cp; g_free(cp); g_object_unref(gs);
        }
        bool has_key = has_cloud_api_key(cpid);
        if(!has_key){
            gtk_widget_set_visible(stream,FALSE);
            GtkWidget *msg=chat_bubble_new(ChatRole::Sky, "Sky: I need a cloud API key to help. Add one in Providers → Sky, then I can bench and recommend. For now, heuristic pick: " + best + " fits this machine.", false);
            gtk_box_append(GTK_BOX(hist),msg);
            gtk_widget_set_sensitive(GTK_WIDGET(b),TRUE);
            return;
        }
        auto *prov=make_provider_for_cloud(cpid,"");
        struct S{ GtkWidget *hist; GtkWidget *stream; GtkWidget *btn; LLMProvider *prov; std::string acc; };
        S *s=new S{hist,stream,GTK_WIDGET(b),prov,""};
        g_thread_new("sky-recommend",[](gpointer p)->gpointer{
            S *ss=(S*)p;
            ss->prov->send("Recommend a GGUF for Tessy local on " + std::to_string(ss->hist?1:0) + " system", [ss](const std::string &delta,bool done){
                std::string *d=new std::string(delta); bool *dd=new bool(done);
                g_idle_add([](gpointer q)->gboolean{
                    auto *pr=(std::pair<S*,std::pair<std::string*,bool*>>*)q;
                    S *sss=pr->first;
                    if(*pr->second.second){
                        gtk_widget_set_visible(sss->stream,FALSE);
                        if(!sss->acc.empty()){
                            GtkWidget *bub=chat_bubble_new(ChatRole::Sky, sss->acc, false);
                            gtk_box_append(GTK_BOX(sss->hist),bub);
                        }
                        gtk_widget_set_sensitive(sss->btn,TRUE);
                        delete sss->prov; delete sss;
                    } else sss->acc+=*pr->second.first;
                    delete pr->second.first; delete pr->second.second; delete pr;
                    return G_SOURCE_REMOVE;
                }, new std::pair<S*,std::pair<std::string*,bool*>>(ss, {d,dd}));
            }, [ss](const std::string &err){
                std::string *e=new std::string(err);
                g_idle_add([](gpointer q)->gboolean{
                    auto *pr=(std::pair<S*,std::string*>*)q;
                    gtk_widget_set_visible(pr->first->stream,FALSE);
                    GtkWidget *bub=chat_bubble_new(ChatRole::System, "Sky error: "+*pr->second, false);
                    gtk_box_append(GTK_BOX(pr->first->hist),bub);
                    gtk_widget_set_sensitive(pr->first->btn,TRUE);
                    delete pr->first->prov; delete pr->first; delete pr->second; delete pr;
                    return G_SOURCE_REMOVE;
                }, new std::pair<S*,std::string*>(ss,e));
            });
            return nullptr;
        }, s);
    })), sky_hist);
    g_signal_connect(fetch_btn2,"clicked", G_CALLBACK((+[](GtkButton*, gpointer p){
        GtkWindow *win=GTK_WINDOW(gtk_widget_get_root(GTK_WIDGET(p)));
        if(!GTK_IS_WINDOW(win)) win=nullptr;
        models_fetch_dialog_new(win);
    })), bench_btn);
    gtk_box_append(GTK_BOX(outer),boot_card);

    // MoE A/B bench — APEX + prefetchers + CasMoE
    {
        GtkWidget *moe_hdr=gtk_label_new("MoE A/B — APEX vs Prefetchers vs CasMoE");
        gtk_widget_add_css_class(moe_hdr,"title-3"); gtk_label_set_xalign(GTK_LABEL(moe_hdr),0); gtk_widget_set_margin_top(moe_hdr,12);
        gtk_box_append(GTK_BOX(outer),moe_hdr);
        GtkWidget *moe_desc=gtk_label_new("Orthogonal stack: APEX quant (size) → CORM neuron cache → SpecPrefetch/SP-MoE (stall) → CasMoE (quality cascade). Run the same traces through each prefetcher and compare hit-rate / TTFT.");
        gtk_widget_add_css_class(moe_desc,"dim-label"); gtk_label_set_wrap(GTK_LABEL(moe_desc),TRUE); gtk_label_set_xalign(GTK_LABEL(moe_desc),0);
        gtk_box_append(GTK_BOX(outer),moe_desc);
        GtkWidget *moe_card=gtk_box_new(GTK_ORIENTATION_VERTICAL,8);
        gtk_widget_add_css_class(moe_card,"card");
        gtk_widget_set_margin_top(moe_card,6);

        GtkWidget *row1=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget *apex_dd=gtk_drop_down_new_from_strings((const char*[]){"Quality 21.3GB","Balanced 18.7GB","Compact 16.1GB","Lean 14.0GB","Mini 12.2GB",nullptr});
        gtk_drop_down_set_selected(GTK_DROP_DOWN(apex_dd),1);
        GtkWidget *pref_dd=gtk_drop_down_new_from_strings((const char*[]){"none","SpecPrefetch","SP-MoE","CORM-predictor",nullptr});
        // restore from GSettings
        {
            GSettings *gs=g_settings_new("org.tessera.TesseraStudio");
            char *pf=g_settings_get_string(gs,"moe-prefetcher");
            char *at=g_settings_get_string(gs,"moe-apex-tier");
            if(pf){ int idx=0; if(std::string(pf)=="SpecPrefetch") idx=1; else if(std::string(pf)=="SP-MoE") idx=2; else if(std::string(pf)=="CORM-predictor") idx=3; gtk_drop_down_set_selected(GTK_DROP_DOWN(pref_dd),(guint)idx); g_free(pf); }
            if(at){ int idx=1; if(std::string(at)=="Quality") idx=0; else if(std::string(at)=="Compact") idx=2; else if(std::string(at)=="Lean") idx=3; else if(std::string(at)=="Mini") idx=4; gtk_drop_down_set_selected(GTK_DROP_DOWN(apex_dd),(guint)idx); g_free(at); }
            g_object_unref(gs);
        }
        GtkWidget *cas_chk=gtk_check_button_new_with_label("CasMoE cascade (2 vs 8 experts)");
        gtk_check_button_set_active(GTK_CHECK_BUTTON(cas_chk), TRUE);
        gtk_box_append(GTK_BOX(row1), gtk_label_new("APEX:")); gtk_box_append(GTK_BOX(row1), apex_dd);
        gtk_box_append(GTK_BOX(row1), gtk_label_new("Prefetcher:")); gtk_box_append(GTK_BOX(row1), pref_dd);
        gtk_box_append(GTK_BOX(row1), cas_chk);
        gtk_box_append(GTK_BOX(moe_card), row1);

        GtkWidget *btn_row2=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
        GtkWidget *run_ab_btn=gtk_button_new_with_label("Run A/B (all prefetchers)");
        gtk_widget_add_css_class(run_ab_btn,"suggested-action");
        GtkWidget *run_one_btn=gtk_button_new_with_label("Run active only");
        gtk_widget_add_css_class(run_one_btn,"pill");
        gtk_box_append(GTK_BOX(btn_row2), run_ab_btn); gtk_box_append(GTK_BOX(btn_row2), run_one_btn);
        gtk_box_append(GTK_BOX(moe_card), btn_row2);

        GtkWidget *result_scroll=gtk_scrolled_window_new();
        gtk_widget_set_size_request(result_scroll,-1,140);
        GtkWidget *result_box=gtk_box_new(GTK_ORIENTATION_VERTICAL,4);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(result_scroll), result_box);
        gtk_box_append(GTK_BOX(moe_card), result_scroll);
        GtkWidget *hint=gtk_label_new("Results JSONL: XDG_DATA_HOME/tessera/bench/<ts>.jsonl — scenarios: 24GB 3090Ti / 16GB 4060 / NVMe offload");
        gtk_widget_add_css_class(hint,"caption"); gtk_widget_add_css_class(hint,"dim-label");
        gtk_box_append(GTK_BOX(moe_card), hint);

        struct AbCtx{ GtkWidget *apex_dd; GtkWidget *pref_dd; GtkWidget *cas_chk; GtkWidget *box; bool all; };
        AbCtx *ctxAll=new AbCtx{apex_dd,pref_dd,cas_chk,result_box,true};
        AbCtx *ctxOne=new AbCtx{apex_dd,pref_dd,cas_chk,result_box,false};
        auto run_fn = +[](GtkButton*, gpointer d){
            AbCtx *c=(AbCtx*)d;
            guint apex_idx=gtk_drop_down_get_selected(GTK_DROP_DOWN(c->apex_dd));
            guint pref_idx=gtk_drop_down_get_selected(GTK_DROP_DOWN(c->pref_dd));
            bool cas=gtk_check_button_get_active(GTK_CHECK_BUTTON(c->cas_chk));
            // persist
            {
                GSettings *gs=g_settings_new("org.tessera.TesseraStudio");
                const char *pf="none"; if(pref_idx==1) pf="SpecPrefetch"; else if(pref_idx==2) pf="SP-MoE"; else if(pref_idx==3) pf="CORM-predictor";
                const char *at="Balanced"; if(apex_idx==0) at="Quality"; else if(apex_idx==2) at="Compact"; else if(apex_idx==3) at="Lean"; else if(apex_idx==4) at="Mini";
                g_settings_set_string(gs,"moe-prefetcher",pf);
                g_settings_set_string(gs,"moe-apex-tier",at);
                g_settings_set_boolean(gs,"moe-casmoe",cas);
                g_object_unref(gs);
            }
            // clear
            GtkWidget *child=gtk_widget_get_first_child(c->box);
            while(child){ GtkWidget *n=gtk_widget_get_next_sibling(child); gtk_box_remove(GTK_BOX(c->box),child); child=n; }
            GtkWidget *prog=gtk_label_new("Running bench off GTK thread…"); gtk_box_append(GTK_BOX(c->box), prog);
            // GTask
            struct Td{ AbCtx *c; guint apex_idx; guint pref_idx; bool cas; bool all; };
            Td *td=new Td{c,apex_idx,pref_idx,cas,c->all};
            GTask *task=g_task_new(nullptr,nullptr,nullptr,nullptr);
            g_task_set_task_data(task, td, [](gpointer p){ delete (Td*)p; });
            g_task_run_in_thread(task, [](GTask *task, gpointer, gpointer, GCancellable*){
                Td *t=(Td*)g_task_get_task_data(task);
                using namespace tessera::moe;
                ApexTier tier=ApexTier::Balanced;
                if(t->apex_idx==0) tier=ApexTier::Quality; else if(t->apex_idx==2) tier=ApexTier::Compact; else if(t->apex_idx==3) tier=ApexTier::Lean; else if(t->apex_idx==4) tier=ApexTier::Mini;
                CasPolicy cas{ t->cas, 8, 2, 0.6f};
                TopKRouter router;
                // also build StableRouter variant for comparison when cas off
                ExpertCache base(32);
                CORMCache corm(32, 0.175f);
                SpecPrefetchAdapter spec(4);
                SPMoEPrefetcher spmoe;
                CORMPrefetcher cormpf(&corm);
                NoPrefetcher none;
                std::vector<Prefetcher*> all = { &none, &spec, &spmoe, &cormpf };
                std::vector<Prefetcher*> sel;
                if(t->all) sel=all; else {
                    if(t->pref_idx==0) sel={&none};
                    else if(t->pref_idx==1) sel={&spec};
                    else if(t->pref_idx==2) sel={&spmoe};
                    else sel={&cormpf};
                }
                std::vector<BenchScenario> scs = { {"24GB 3090Ti",24576,"cuda"}, {"16GB 4060",16384,"cuda"}, {"NVMe offload",8192,"nvme"}};
                std::vector<BenchSample> samples;
                for(int i=0;i<32;i++){
                    TokenState tok; tok.pos=i; tok.hidden={ (float)i*0.1f, (float)(i%4)};
                    samples.push_back({tok, (i%3==0?0.8f:0.3f)});
                }
                ExpertCache *cache = (t->pref_idx==3? (ExpertCache*)&corm : &base);
                auto res = Bench::run_ab(router, sel, *cache, cas, scs, samples, tier);
                std::string path = Bench::results_path();
                Bench::write_jsonl(res, path);
                // ship to UI
                struct Rd{ AbCtx *c; std::vector<BenchResult> res; std::string path; };
                Rd *rd=new Rd{t->c, res, path};
                g_idle_add([](gpointer p)->gboolean{
                    Rd *r=(Rd*)p;
                    GtkWidget *child=gtk_widget_get_first_child(r->c->box);
                    while(child){ GtkWidget *n=gtk_widget_get_next_sibling(child); gtk_box_remove(GTK_BOX(r->c->box),child); child=n; }
                    for(auto &br: r->res){
                        char buf[256];
                        snprintf(buf,sizeof(buf), "%s | %s | %s — hit %.0f%% stall %.1fms TTFT %.0fms %.1f tok/s", br.prefetcher.c_str(), br.scenario.c_str(), br.apex_tier.c_str(), br.hit_rate*100, br.stall_ms, br.ttft_ms, br.decode_tps);
                        GtkWidget *row=gtk_label_new(buf); gtk_label_set_xalign(GTK_LABEL(row),0); gtk_widget_add_css_class(row, br.prefetcher=="none"?"dim-label":"");
                        gtk_box_append(GTK_BOX(r->c->box), row);
                    }
                    GtkWidget *path_lbl=gtk_label_new(("→ " + r->path).c_str());
                    gtk_widget_add_css_class(path_lbl,"caption"); gtk_widget_add_css_class(path_lbl,"dim-label"); gtk_label_set_xalign(GTK_LABEL(path_lbl),0);
                    gtk_box_append(GTK_BOX(r->c->box), path_lbl);
                    delete r; return G_SOURCE_REMOVE;
                }, rd);
            });
            g_object_unref(task);
        };
        g_signal_connect(run_ab_btn,"clicked", G_CALLBACK(run_fn), ctxAll);
        g_signal_connect(run_one_btn,"clicked", G_CALLBACK(run_fn), ctxOne);

        gtk_box_append(GTK_BOX(outer), moe_card);
    }

    GtkWidget *foot=gtk_label_new("Cloud runs elsewhere · Local runs here — this page is the local capacity vibe, benchmark-free until you tap Run. Sky helps, Tessy keeps personal data local.");
    gtk_widget_add_css_class(foot,"caption"); gtk_widget_add_css_class(foot,"dim-label"); gtk_label_set_wrap(GTK_LABEL(foot),TRUE); gtk_label_set_xalign(GTK_LABEL(foot),0);
    gtk_box_append(GTK_BOX(outer),foot);

    GtkWidget *wrap=gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(wrap),GTK_POLICY_NEVER,GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(wrap),outer);
    return wrap;
}
}
