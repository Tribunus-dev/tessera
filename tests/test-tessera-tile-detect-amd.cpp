// Unit test for W3 task 3.1: ts_classify_amd_arch_name() (tools/quantize/
// tessera/tile-detect.{h,cpp}).
//
// Master-plan criterion 17 asks for "a unit test that mocks the device
// properties". ts_classify_amd_arch_name() is the pure-string half of the
// detection split precisely so it can be exercised this way: it takes an
// injected gcnArchName value directly, with no HIP device access, so every
// arch bucket in docs/amd-tile-format-spec.md Section 2's table can be
// tested on any host regardless of what GPU (if any) is actually present.
//
// ts_detect_amd_arch() itself (the hipGetDeviceProperties() probe) is
// exercised separately as a build-linux-amd smoke check on real gfx1103
// hardware, not here - a ctest target must stay buildable and passable on
// hosts with no AMD GPU and no ROCm at all.

#include "tile-detect.h"

#include <cassert>
#include <cstdio>

static void test_rdna35(void) {
    printf("test-tessera-tile-detect-amd: RDNA 3.5 iGPU family\n");
    assert(ts_classify_amd_arch_name("gfx1103") == TS_ARCH_AMD_RDNA35);
    assert(ts_classify_amd_arch_name("gfx1150") == TS_ARCH_AMD_RDNA35);
    assert(ts_classify_amd_arch_name("gfx1151") == TS_ARCH_AMD_RDNA35);
    // real hipGetDeviceProperties() output carries ":feature[+-]" suffixes
    assert(ts_classify_amd_arch_name("gfx1103:sramecc-:xnack-") == TS_ARCH_AMD_RDNA35);
}

static void test_rdna3(void) {
    printf("test-tessera-tile-detect-amd: RDNA3 discrete family\n");
    assert(ts_classify_amd_arch_name("gfx1100") == TS_ARCH_AMD_RDNA3);
    assert(ts_classify_amd_arch_name("gfx1101") == TS_ARCH_AMD_RDNA3);
    assert(ts_classify_amd_arch_name("gfx1102") == TS_ARCH_AMD_RDNA3);
}

static void test_rdna4(void) {
    printf("test-tessera-tile-detect-amd: RDNA4 family\n");
    assert(ts_classify_amd_arch_name("gfx1200") == TS_ARCH_AMD_RDNA4);
    assert(ts_classify_amd_arch_name("gfx1201") == TS_ARCH_AMD_RDNA4);
}

static void test_rdna2(void) {
    printf("test-tessera-tile-detect-amd: RDNA2 family\n");
    assert(ts_classify_amd_arch_name("gfx1030") == TS_ARCH_AMD_RDNA2);
    assert(ts_classify_amd_arch_name("gfx1031") == TS_ARCH_AMD_RDNA2);
    assert(ts_classify_amd_arch_name("gfx1032") == TS_ARCH_AMD_RDNA2);
}

static void test_rdna1(void) {
    printf("test-tessera-tile-detect-amd: RDNA1 family\n");
    assert(ts_classify_amd_arch_name("gfx1010") == TS_ARCH_AMD_RDNA1);
    assert(ts_classify_amd_arch_name("gfx1011") == TS_ARCH_AMD_RDNA1);
    assert(ts_classify_amd_arch_name("gfx1012") == TS_ARCH_AMD_RDNA1);
}

static void test_cdna(void) {
    printf("test-tessera-tile-detect-amd: CDNA1-4 family\n");
    assert(ts_classify_amd_arch_name("gfx908") == TS_ARCH_AMD_CDNA1);
    assert(ts_classify_amd_arch_name("gfx90a") == TS_ARCH_AMD_CDNA2);
    assert(ts_classify_amd_arch_name("gfx90a:sramecc+:xnack-") == TS_ARCH_AMD_CDNA2);
    assert(ts_classify_amd_arch_name("gfx942") == TS_ARCH_AMD_CDNA3);
    assert(ts_classify_amd_arch_name("gfx950") == TS_ARCH_AMD_CDNA4);
}

static void test_gcn_legacy(void) {
    printf("test-tessera-tile-detect-amd: legacy GCN (gfx6xx..gfx900)\n");
    assert(ts_classify_amd_arch_name("gfx600") == TS_ARCH_AMD_GCN);
    assert(ts_classify_amd_arch_name("gfx700") == TS_ARCH_AMD_GCN);
    assert(ts_classify_amd_arch_name("gfx803") == TS_ARCH_AMD_GCN);
    assert(ts_classify_amd_arch_name("gfx900") == TS_ARCH_AMD_GCN);
}

static void test_unknown(void) {
    printf("test-tessera-tile-detect-amd: unknown / null input\n");
    assert(ts_classify_amd_arch_name(nullptr) == TS_ARCH_UNKNOWN);
    assert(ts_classify_amd_arch_name("") == TS_ARCH_UNKNOWN);
    assert(ts_classify_amd_arch_name("not-a-gfx-string") == TS_ARCH_UNKNOWN);
    // gfx9 codes that are neither CDNA1/2 nor the gfx900 GCN boundary
    // (e.g. Vega20's gfx906, an APU-only gfx9 SKU) are not in the spec's
    // table and must not silently misclassify as GCN or CDNA.
    assert(ts_classify_amd_arch_name("gfx906") == TS_ARCH_UNKNOWN);
}

int main(void) {
    test_rdna35();
    test_rdna3();
    test_rdna4();
    test_rdna2();
    test_rdna1();
    test_cdna();
    test_gcn_legacy();
    test_unknown();
    printf("test-tessera-tile-detect-amd: all tests OK\n");
    return 0;
}
