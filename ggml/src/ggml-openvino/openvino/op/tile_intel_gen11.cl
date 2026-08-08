// Tile Intel Gen11 — native 16×32 (T512) and 32×32 (T1024) 2-bit, sub_group 16, 64KB SLM
// Gen11 Iris Plus G7: 64EU*7=448 threads, L1 32KB, L2 512KB, SLM 64KB double-buffered
// T512 canonical on-disk, T1024 coalesce is GPU tiling only (host dequant stays native)
// Compile: ocloc -file tile_intel_gen11.cl -options "-cl-std=CL2.0 -DTILE512" or -DTILE1024
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_intel_subgroups_short : enable

#ifdef TILE512
#define TILE_PAGE_SIZE 512
#define TILE_LANES 16
#define TILE_WORDS 32
#define TILE_LANE_SIZE 32
#endif
#ifdef TILE1024
#define TILE_PAGE_SIZE 1024
#define TILE_LANES 32
#define TILE_WORDS 64
#define TILE_LANE_SIZE 32
#endif
#ifndef TILE_PAGE_SIZE
#define TILE_PAGE_SIZE 512
#define TILE_LANES 16
#define TILE_WORDS 32
#define TILE_LANE_SIZE 32
#endif

__attribute__((intel_reqd_sub_group_size(16)))
__kernel void tile512_gen11_gemm(
    __global const uint* packed,       // [out_dim, pages, 32]
    __global const half* page_scales,  // [out_dim, pages]
    __global const char* lane_scales,  // [out_dim, pages, 16]
    __global const int* outlier_offsets,
    __global const int* outlier_cols,
    __global const half* outlier_vals,
    __global const half* activation,   // [in_dim, n_tokens] F16
    __global float* out,               // [out_dim, n_tokens] F32
    int in_dim, int out_dim, int pages, int n_tokens) {
    int r = get_global_id(0);
    if (r >= out_dim) return;
    int lane = get_sub_group_local_id(); // 0..15
    __local half l_sg[2][32];
    int ping = 0;
    if (lane < TILE_LANES) {
        for (int p = 0; p < pages; ++p)
            l_sg[ping][lane] = (half)(lane_scales[r*pages*TILE_LANES + p*TILE_LANES + lane] * (1.0f/127.0f));
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int j = lane; j < n_tokens; j += 16) {
        float acc = 0.0f;
        for (int p = 0; p < pages; ++p) {
            float pm = vload_half(0, &page_scales[r*pages + p]);
            int next_ping = 1 - ping;
            if (p+1 < pages && lane < TILE_LANES) l_sg[next_ping][lane] = (half)(lane_scales[r*pages*TILE_LANES + (p+1)*TILE_LANES + lane] * (1.0f/127.0f));
            for (int l = lane & 15; l < TILE_LANES; l += 16) {
                // 2 words per 32-wide lane, 16 trits per word
                for (int w = 0; w < 2; ++w) {
                    float sc = pm * (float)l_sg[ping][l];
                    uint word = packed[r*pages*TILE_WORDS + p*TILE_WORDS + l*2 + w];
                    #pragma unroll
                    for (int d = 0; d < 16; ++d) {
                        int col = p*TILE_PAGE_SIZE + l*TILE_LANE_SIZE + w*16 + d;
                        if (col >= in_dim) break;
                        uint bits = (word >> (d*2)) & 3u;
                        float wt = bits==1 ? sc : bits==2 ? -sc : 0.0f;
                        half a = activation[col * n_tokens + j];
                        acc += wt * (float)a;
                    }
                }
            }
            barrier(CLK_LOCAL_MEM_FENCE);
            ping = next_ping;
        }
        int lo = outlier_offsets[r], hi = outlier_offsets[r+1];
        for (int k = lo + lane; k < hi; k += 16) {
            int c = outlier_cols[k];
            float v = vload_half(0, &outlier_vals[k]);
            acc += v * (float)activation[c * n_tokens + j];
        }
        acc = sub_group_reduce_add(acc);
        if (lane == 0) out[r*n_tokens + j] = acc;
    }
}

__attribute__((intel_reqd_sub_group_size(16)))
__kernel void tile1024_gen11_gemm(
    __global const uint* packed,       // [out_dim, pages, 64]
    __global const half* page_scales,  // [out_dim, pages]
    __global const char* lane_scales,  // [out_dim, pages, 32]
    __global const int* outlier_offsets,
    __global const int* outlier_cols,
    __global const half* outlier_vals,
    __global const half* activation,
    __global float* out,
    int in_dim, int out_dim, int pages, int n_tokens) {
    int r = get_global_id(0);
    if (r >= out_dim) return;
    int lane = get_sub_group_local_id();
    __local half l_sg[2][32];
    int ping=0;
    if (lane < 32) for(int p=0;p<pages;++p) l_sg[ping][lane]=(half)(lane_scales[r*pages*32+p*32+lane]*(1.0f/127.0f));
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int j=lane;j<n_tokens;j+=16){
        float acc=0;
        for(int p=0;p<pages;++p){
            float pm=vload_half(0,&page_scales[r*pages+p]);
            int next_ping=1-ping;
            if(p+1<pages && lane<32) l_sg[next_ping][lane]=(half)(lane_scales[r*pages*32+(p+1)*32+lane]*(1.0f/127.0f));
            for(int l=lane & 31;l<32;l+=16){
                for(int w=0;w<2;++w){
                    float sc=pm*(float)l_sg[ping][l];
                    uint word=packed[r*pages*64 + p*64 + l*2 + w];
                    #pragma unroll
                    for(int d=0;d<16;++d){int col=p*1024+l*32+w*16+d; if(col>=in_dim)break; uint bits=(word>>(d*2))&3u; float wt=bits==1?sc:bits==2?-sc:0; acc+=wt*(float)activation[col*n_tokens+j];}
                }
            }
            barrier(CLK_LOCAL_MEM_FENCE); ping=next_ping;
        }
        int lo=outlier_offsets[r], hi=outlier_offsets[r+1];
        for(int k=lo+lane;k<hi;k+=16){int c=outlier_cols[k]; float v=vload_half(0,&outlier_vals[k]); acc+=v*(float)activation[c*n_tokens+j];}
        acc=sub_group_reduce_add(acc);
        if(lane==0) out[r*n_tokens+j]=acc;
    }
}
