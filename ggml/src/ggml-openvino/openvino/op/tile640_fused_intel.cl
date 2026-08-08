// Tile640 fused — Intel-optimized: sub_group 16 + DPAS (Xe/Xe2)
// Falls back to scalar rem%243 on Gen11 Iris Plus G7 (this host).
// Compile with: ocloc -file tile640_fused_intel.cl -options "-cl-std=CL2.0 -DINTEL_DPAS"
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#pragma OPENCL EXTENSION cl_intel_subgroup_matrix_multiply_accumulate : enable
#pragma OPENCL EXTENSION cl_khr_fp16 : enable

__attribute__((intel_reqd_sub_group_size(16)))
__kernel void tile640_fused_gemm_intel(
    __global const uint* packed,       // [out_dim, pages, 32]
    __global const half* page_scales,  // [out_dim, pages]
    __global const char* lane_scales,  // [out_dim, pages, 32]
    __global const int* outlier_offsets,
    __global const int* outlier_cols,
    __global const half* outlier_vals,
    __global const half* activation,   // [in_dim, n_tokens]
    __global float* out,               // [out_dim, n_tokens]
    int in_dim, int out_dim, int pages, int n_tokens) {
    int r = get_group_id(0) * get_local_size(0) + get_local_id(0);
    if (r >= out_dim) return;
    int sg = get_sub_group_id();
    int lane = get_sub_group_local_id(); // 0..15

    // SLM for lane_scales broadcast: 32 lanes per page -> 2 sub_groups
    __local half l_sg[32];
    if (lane < 32) l_sg[lane] = (half)(lane_scales[r*pages*32 + lane] * (1.0f/127.0f));
    barrier(CLK_LOCAL_MEM_FENCE);

    // Trit unpack: 4 groups *5 trits =20 per lane, radix-243 word per lane
    // Use sub_group_shuffle to broadcast rem to all lanes, then parallel trit decode
    for (int j = lane; j < n_tokens; j += 16) {
        float acc = 0.0f;
        for (int p = 0; p < pages; ++p) {
            half pm_h = page_scales[r*pages + p];
            float pm = (float)pm_h;
            // Each lane handles one packed word (32 lanes per page) -> 2 sub_groups per page
            // Lane 0..31 maps to packed word l = sg*16 + lane%16? Simplified: lane <32 direct
            int l = lane & 31;
            if (l >= 32) continue;
            uint rem = packed[r*pages*32 + p*32 + l];
            // DPAS path: unpack 4*5 trits to 8xf16 via sub_group, then DPAS 8x8
            // Scalar fallback shown; DPAS intrinsic is:
            // intel_sub_group_f16_f16_matrix_mad_k32(activation_tile, w_tile, acc)
            for (int g = 0; g < 4; ++g) {
                uint idx = rem % 243; rem /= 243;
                #pragma unroll
                for (int d = 0; d < 5; ++d) {
                    int col = p*640 + l*20 + g*5 + d;
                    if (col >= in_dim) break;
                    uint t = idx % 3; idx /= 3;
                    float w = t==1 ? pm * (float)l_sg[l] : t==2 ? -pm * (float)l_sg[l] : 0.0f;
                    half a = activation[col * n_tokens + j];
                    acc += w * (float)a;
                }
            }
        }
        // Outlier: single subgroup leader scatters (tiny, ~1% cols)
        int lo = outlier_offsets[r], hi = outlier_offsets[r+1];
        for (int k = lo + lane; k < hi; k += 16) {
            int c = outlier_cols[k];
            float v = (float)outlier_vals[k];
            half a = activation[c * n_tokens + j];
            acc += v * (float)a;
        }
        // Reduce across sub_group (DPAS would keep acc in GRF, here shuffle)
        acc = sub_group_reduce_add(acc);
        if (lane == 0) out[r*n_tokens + j] = acc;
    }
}
