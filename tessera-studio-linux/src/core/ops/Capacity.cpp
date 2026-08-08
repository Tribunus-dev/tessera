#include "Capacity.h"
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <cstdio>
#include <array>
#include <filesystem>
#include <thread>

namespace tessera {
static uint64_t parse_mem_kb(const std::string &line){
    std::istringstream iss(line);
    std::string key; uint64_t v; std::string unit;
    iss >> key >> v >> unit;
    return v;
}
LocalCapacity gather_capacity(){
    LocalCapacity c;
    {
        std::ifstream f("/proc/cpuinfo");
        std::string line;
        while(std::getline(f, line)){
            if(line.rfind("model name",0)==0){
                auto p=line.find(':'); if(p!=std::string::npos){ c.cpu_model=line.substr(p+1); while(!c.cpu_model.empty() && c.cpu_model.front()==' ') c.cpu_model.erase(c.cpu_model.begin()); break; }
            }
        }
        c.cpu_cores = (int)std::thread::hardware_concurrency();
        c.cpu_threads = c.cpu_cores;
        std::ifstream f2("/proc/cpuinfo");
        int cnt=0; std::string l;
        while(std::getline(f2,l)) if(l.rfind("processor",0)==0) cnt++;
        if(cnt) c.cpu_threads=cnt;
        std::ifstream f3("/proc/cpuinfo");
        while(std::getline(f3,l)) if(l.rfind("flags",0)==0){ if(l.find("avx512")!=std::string::npos) c.cpu_isa="AVX-512"; if(l.find("vnni")!=std::string::npos) c.cpu_isa+=" + VNNI"; break; }
        if(c.cpu_isa.empty()) c.cpu_isa="x86-64";
    }
    {
        std::ifstream f("/proc/meminfo");
        std::string l;
        while(std::getline(f,l)){
            if(l.rfind("MemTotal:",0)==0) c.ram_total_mb = parse_mem_kb(l)/1024;
            if(l.rfind("MemAvailable:",0)==0) c.ram_avail_mb = parse_mem_kb(l)/1024;
            if(l.rfind("SwapTotal:",0)==0) c.swap_total_mb = parse_mem_kb(l)/1024;
        }
    }
    {
        FILE *p=popen("lspci -nn 2>/dev/null | grep -i 'VGA\\|Display\\|3D' | head -n1", "r");
        if(p){
            char buf[512]={0};
            if(fgets(buf,sizeof(buf),p)){
                std::string s=buf;
                GpuInfo g;
                g.name=s; g.api="vulkan"; g.vram_mb=0;
                if(s.find("Intel")!=std::string::npos) g.bus="shared"; else if(!s.empty()) g.bus="pcie";
                else g.bus="shared";
                g.is_egpu=false;
                c.igpu=g;
            }
            pclose(p);
        }
        if(c.igpu.name.empty()) c.igpu.name="Integrated GPU";
        c.igpu.api="shared";
        c.bandwidth_gbs = 60.0;
    }
    {
        FILE *p=popen("nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n1", "r");
        if(p){
            char buf[256]={0};
            if(fgets(buf,sizeof(buf),p) && buf[0]){
                std::string s=buf; auto comma=s.find(',');
                if(comma!=std::string::npos){
                    std::string name=s.substr(0,comma); std::string mem=s.substr(comma+1);
                    int vram=0; try{ vram=std::stoi(mem);}catch(...){}
                    GpuInfo g; g.name=name; g.api="cuda"; g.vram_mb=(uint64_t)vram; g.bus="pcie"; g.is_egpu=false;
                    c.dgpu=g;
                }
            }
            pclose(p);
        }
    }
    if(!c.dgpu){
        FILE *p=popen("rocminfo 2>/dev/null | grep -m1 'Marketing Name' | cut -d: -f2 | xargs", "r");
        if(p){
            char buf[256]={0};
            if(fgets(buf,sizeof(buf),p) && buf[0]){
                std::string n=buf; if(!n.empty()&&n.back()=='\n') n.pop_back();
                GpuInfo g; g.name=n; g.api="rocm"; g.vram_mb=0; g.bus="pcie"; g.is_egpu=false;
                c.dgpu=g;
            }
            pclose(p);
        }
    }
    {
        FILE *p=popen("boltctl list 2>/dev/null | grep -i 'Thunderbolt' | head -n1", "r");
        if(p){
            char buf[256]={0}; bool has_tb=false; if(fgets(buf,sizeof(buf),p)) has_tb=true; pclose(p);
            if(has_tb){
                FILE *q=popen("lspci -nn 2>/dev/null | grep -i 'VGA' | grep -i 'Thunderbolt' | head -n1", "r");
                if(q){
                    char b2[512]={0};
                    if(fgets(b2,sizeof(b2),q) && b2[0]){
                        std::string s=b2;
                        GpuInfo g; g.name=s; g.api="tb4"; g.vram_mb=0; g.bus="tb4"; g.is_egpu=true;
                        c.egpu=g;
                    }
                    pclose(q);
                }
            }
        }
    }
    {
        FILE *p=popen("python3 -c \"import openvino as ov; print(','.join(ov.Core().available_devices))\" 2>/dev/null", "r");
        if(p){
            char buf[256]={0};
            if(fgets(buf,sizeof(buf),p) && buf[0]){
                std::string s=buf;
                if(s.find("NPU")!=std::string::npos){
                    NpuInfo n; n.name="Intel NPU"; n.driver="openvino-npu"; n.tops=10; n.present=true;
                    c.npu=n;
                }
            }
            pclose(p);
        }
        if(!c.npu){
            FILE *q=popen("ls /dev/accel/accel* 2>/dev/null | head -n1", "r");
            if(q){
                char b[128]={0};
                if(fgets(b,sizeof(b),q) && b[0]){
                    NpuInfo n; n.name="NPU"; n.driver="xDNA"; n.tops=16; n.present=true;
                    c.npu=n;
                }
                pclose(q);
            }
        }
    }
    return c;
}
std::string LocalCapacity::summary() const {
    std::string s = this->cpu_model + " · " + std::to_string(this->ram_total_mb/1024) + "GB RAM";
    if(this->igpu.name.size()>4) s += " · " + this->igpu.name.substr(0,28);
    if(this->dgpu) s += " · dGPU " + this->dgpu->name.substr(0,20);
    if(this->egpu) s += " · eGPU TB4";
    if(this->npu && this->npu->present) s += " · NPU " + std::to_string(this->npu->tops) + " TOPS";
    return s;
}
double estimate_tokens_per_sec(const LocalCapacity &cap, uint64_t model_bytes){
    if(model_bytes==0) return 0;
    double bw = cap.bandwidth_gbs * 1e9;
    if(cap.dgpu && cap.dgpu->vram_mb*1024*1024 >= model_bytes) bw = 300e9;
    else if(cap.egpu) bw = 32e9/8;
    return bw / (double)model_bytes;
}
std::vector<ModelFit> community_fits(const LocalCapacity &cap){
    struct Raw{ const char* id; uint64_t mb; const char* q; };
    Raw raws[] = {
        {"gemma-3-4b Q4_0", 2400, "q4_0"}, {"gemma-4-12b Q4_0", 6500, "q4_0"}, {"llama-3.1-8b Q4_K_M", 4900, "q4_k_m"},
        {"mistral-7b Q4_K_M", 4300, "q4_k_m"}, {"qwen2.5-7b Q4_K_M", 4700, "q4_k_m"}, {"qwen2.5-14b Q4_K_M", 8500, "q4_k_m"},
        {"deepseek-coder-6.7b Q4", 3800, "q4_0"}, {"phi-3-mini 3.8b Q4", 2300, "q4_k_m"}, {"gemma-3-27b Q4_0", 15000, "q4_0"},
        {"llama-3.1-70b Q4_K_M", 42000, "q4_k_m"}, {nullptr,0,nullptr}
    };
    std::vector<ModelFit> out;
    uint64_t avail = cap.ram_avail_mb ? cap.ram_avail_mb : (cap.ram_total_mb ? cap.ram_total_mb*70/100 : 8192);
    for(int i=0; raws[i].id; ++i){
        double tok = estimate_tokens_per_sec(cap, raws[i].mb*1024*1024);
        bool fits = raws[i].mb + 800 < avail;
        std::string badge = fits ? (tok>18 ? "green" : "amber") : "red";
        ModelFit mf; mf.id=raws[i].id; mf.size_mb=raws[i].mb; mf.quant=raws[i].q; mf.fits_ram=fits; mf.est_tok_s=tok; mf.badge=badge;
        out.push_back(mf);
    }
    return out;
}
}
