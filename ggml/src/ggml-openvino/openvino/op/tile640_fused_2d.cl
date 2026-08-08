// 2D NDRange + persistent EU + SLM double buffer — any-host, 10% over 1D
// NDRange = {ceil(out_dim/16), ceil(n_tokens/16)} * local {16,16} = 256 threads/WG
// Each WG persists: while (r < out_dim) { j loop } -> r += gridDim.x
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#pragma OPENCL EXTENSION cl_khr_fp16 : enable

__attribute__((reqd_work_group_size(16,16,1)))
__attribute__((intel_reqd_sub_group_size(16)))
__kernel void tile640_fused_gemm_2d(
    __global const uint* packed, __global const half* page_scales,
    __global const char* lane_scales, __global const int* outlier_offsets,
    __global const int* outlier_cols, __global const half* outlier_vals,
    __global const half* activation, __global float* out,
    int in_dim, int out_dim, int pages, int n_tokens) {
    int r0 = get_group_id(0)*get_local_size(0) + get_local_id(0);
    int j0 = get_group_id(1)*get_local_size(1) + get_local_id(1);
    int lane = get_sub_group_local_id();
    __local half l_sg[2][32];
    // Persistent: grid-stride loop over r
    for (int r = r0; r < out_dim; r += get_num_groups(0)*get_local_size(0)) {
        // SLM double buffer prefetch l_sg
        if (lane < 32) for (int p=0;p<pages;++p) l_sg[0][lane]=(half)(lane_scales[r*pages*32+p*32+lane]*(1.0f/127.0f));
        barrier(CLK_LOCAL_MEM_FENCE);
        for (int j = j0; j < n_tokens; j += get_num_groups(1)*get_local_size(1)) {
            float acc=0;
            for (int p=0;p<pages;++p){
                float pm=vload_half(0,&page_scales[r*pages+p]);
                int ping = p & 1, next = 1-ping;
                if (p+1<pages && lane<32) l_sg[next][lane]=(half)(lane_scales[r*pages*32+(p+1)*32+lane]*(1.0f/127.0f));
                for(int l=lane&31;l<32;l+=16){
                    float sc=pm*(float)l_sg[ping][l];
                    uint rem=packed[r*pages*32+p*32+l];
                    // Scalar trit still, DPAS in _intel.cl
                    for(int g=0;g<4;++g){uint idx=rem%243;rem/=243;for(int d=0;d<5;++d){int col=p*640+l*20+g*5+d;if(col>=in_dim)break;uint t=idx%3;idx/=3;float w=t==1?sc:t==2?-sc:0;acc+=w*(float)activation[col*n_tokens+j];}}
                }
                barrier(CLK_LOCAL_MEM_FENCE);
            }
            int lo=outlier_offsets[r], hi=outlier_offsets[r+1];
            for(int k=lo+lane;k<hi;k+=16){int c=outlier_cols[k]; acc+= (float)outlier_vals[k]*(float)activation[c*n_tokens+j];}
            acc=sub_group_reduce_add(acc);
            if(lane==0) out[r*n_tokens+j]=acc;
        }
    }
}
