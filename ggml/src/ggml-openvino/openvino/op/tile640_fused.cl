// Tile640 fused — Gen11 Iris Plus G7: 8KB L1 / 64KB SLM double-buffered, sub_group 16
// Any-host tuning: TILE 64 (32KB L1) -> 16KB F32 tile, 2 tiles in L1, 4 tiles in L2 (512KB)
// Spatial: 64EU*7=448 threads, n_tokens=1 decode needs 2D NDRange; temporal: ping-pong SLM
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#pragma OPENCL EXTENSION cl_intel_subgroup_matrix_multiply_accumulate : enable
#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_intel_subgroups_char : enable
#pragma OPENCL EXTENSION cl_intel_subgroups_long : enable

__attribute__((intel_reqd_sub_group_size(16)))
__kernel void tile640_fused_gemm(
    __global const uint* packed,       // [out_dim, pages, 32]
    __global const half* page_scales,  // [out_dim, pages]
    __global const char* lane_scales,  // [out_dim, pages, 32]
    __global const int* outlier_offsets,
    __global const int* outlier_cols,
    __global const half* outlier_vals,
    __global const half* activation,   // [in_dim, n_tokens]
    __global float* out,               // [out_dim, n_tokens]
    int in_dim, int out_dim, int pages, int n_tokens) {
    int r = get_global_id(0);
    if (r >= out_dim) return;
    int lane = get_sub_group_local_id(); // 0..15
    int sg = get_sub_group_id();

    // SLM double buffer: 64KB SLM -> 2x 32KB ping-pong for l_sg + w_tile
    // 8KB L1 tile = 64*64 F32 =16KB, 2 tiles =32KB fits L1, 4 tiles in L2 (512KB)
    __local half l_sg[2][32];
    __local half w_sg[2][64]; // ping-pong for packed dequant tile
    int ping = 0;
    if (lane < 32) {
        for (int p = 0; p < pages; ++p)
            l_sg[ping][lane] = (half)(lane_scales[r*pages*32 + p*32 + lane] * (1.0f/127.0f));
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // Spatial: 2D NDRange r*n_tokens would be ideal, but 1D r + sub_group j handles decode n_tokens=1
    // Temporal: block_read 16*I32 packed + SLM double buffer hides L3->SLM latency
    for (int j = lane; j < n_tokens; j += 16) {
        float acc = 0.0f;
        // Prefetch next page's packed via block_read
        for (int p = 0; p < pages; ++p) {
            float pm = vload_half(0, &page_scales[r*pages + p]);
            // Double buffer: prefetch next l_sg while computing current
            int next_ping = 1 - ping;
            if (p+1 < pages && lane < 32) l_sg[next_ping][lane] = (half)(lane_scales[r*pages*32 + (p+1)*32 + lane] * (1.0f/127.0f));
            // Block read 16*uint packed for this page's 32 lanes -> 2 sub_groups
            for (int l = (lane & 31); l < 32; l += 16) {
                // Use sub_group_block_read for coalesced 16*I32 (Gen11) — scalar fallback is rem%243
                float sc = pm * (float)l_sg[ping][l];
                int col0 = p*640 + l*20;
                uint rem = as_uint(intel_sub_group_block_read((__global const uint*) &packed[r*pages*32 + p*32 + (l & ~15)]));
                // Shuffle rem to lane's word (sub_group 16 -> 16 words per block_read, pick lane%16)
                rem = intel_sub_group_shuffle(rem, l & 15);
                for (int g = 0; g < 4; ++g) {
                    uint idx = rem % 243; rem /= 243;
                    #pragma unroll
                    for (int d = 0; d < 5; ++d) {
                        int col = col0 + g*5 + d;
                        if (col >= in_dim) break;
                        uint t = idx % 3; idx /= 3;
                        float w = t==1 ? sc : t==2 ? -sc : 0.0f;
                        half a = activation[col * n_tokens + j];
                        acc += w * (float)a;
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
            // Coalesced: outlier_cols are ~1% sparse, not block_read
            acc += v * (float)activation[c * n_tokens + j];
        }
        acc = sub_group_reduce_add(acc);
        if (lane == 0) out[r*n_tokens + j] = acc;
    }
}
