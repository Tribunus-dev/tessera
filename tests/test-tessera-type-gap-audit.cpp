// W3 task 3.3 gap audit (docs/amd-tile-format-spec.md 9(v)/9(vii)):
// GGML_TYPE_COUNT grew 47 -> 64 to land GGML_TYPE_TESSERA_T_RDNA3 = 63 at
// its spec-pinned value, leaving 47-62 as reserved gap slots (11 unused
// AMD-family archs this wave does not implement, plus room for W4's
// KCACHE/VCACHE). This test links the real `ggml` library (not a stub) and
// verifies every public per-type accessor returns a safe value - never a
// null pointer, never a value that would let a gap type slip past
// gguf.cpp's loader gate - for the entire reserved range plus the not-yet-
// wired RDNA3 slot (its real dequant kernel lands in task 3.7; until then
// it must behave exactly like a gap slot, not a half-working type).

#include "ggml.h"

#include <cstdio>
#include <cstring>

// This project's default CMake build is Release (-DNDEBUG), which compiles
// a plain assert() to nothing - the checks below would silently never run.
// Force live assertions the same way tests/test-tessera-config.cpp does:
// undef NDEBUG and re-include <cassert> so its macro re-expands to the
// checking form regardless of the command-line -DNDEBUG.
#undef NDEBUG
#include <cassert>

static void test_gap_range_47_to_62(void) {
    printf("test-tessera-type-gap-audit: reserved gap range 47-62\n");
    for (int t = 47; t <= 62; ++t) {
        const enum ggml_type type = (enum ggml_type) t;

        const char * name = ggml_type_name(type);
        assert(name != nullptr);
        assert(std::strlen(name) > 0);

        // blck_size == 0 is what makes gguf.cpp's loader gate
        // ("blck_size == 0" -> reject) refuse any tensor claiming one of
        // these types, instead of falling through to a modulo-by-zero on
        // the tensor's row size.
        assert(ggml_blck_size(type) == 0);
        assert(ggml_type_size(type) == 0);
        assert(ggml_is_quantized(type) == false);
    }
}

static void test_rdna3_gap_safe_until_task_3_7(void) {
    printf("test-tessera-type-gap-audit: GGML_TYPE_TESSERA_T_RDNA3 (63) is "
           "gap-safe pending task 3.7's CPU reference dequant\n");

    const char * name = ggml_type_name(GGML_TYPE_TESSERA_T_RDNA3);
    assert(name != nullptr);
    assert(std::strcmp(name, "tessera_t_rdna3") == 0);

    // Deliberately still gap-safe (blck_size 0) as of task 3.3: wiring a
    // nonzero blck_size before to_float exists would let a crafted GGUF
    // pass the loader's gate and then null-deref on first dequant.
    assert(ggml_blck_size(GGML_TYPE_TESSERA_T_RDNA3) == 0);
    assert(ggml_type_size(GGML_TYPE_TESSERA_T_RDNA3) == 0);
    assert(ggml_is_quantized(GGML_TYPE_TESSERA_T_RDNA3) == false);
}

static void test_enum_shape(void) {
    printf("test-tessera-type-gap-audit: enum shape matches the spec\n");
    assert(GGML_TYPE_COUNT == 64);
    assert((int) GGML_TYPE_TESSERA_T_RDNA3 == 63);
    assert((int) GGML_TYPE_TESSERA_T1024 == 46);
}

static void test_existing_tessera_types_unaffected(void) {
    printf("test-tessera-type-gap-audit: T640/T640_3D/T512/T1024 unchanged\n");
    // Carry-over regression check: growing GGML_TYPE_COUNT must not have
    // disturbed the already-shipped Tessera tile types' traits.
    assert(std::strcmp(ggml_type_name(GGML_TYPE_TESSERA_T640), "tessera_t640") == 0);
    assert(ggml_is_quantized(GGML_TYPE_TESSERA_T640) == true);
    assert(std::strcmp(ggml_type_name(GGML_TYPE_TESSERA_T640_3D), "tessera_t640_3d") == 0);
    assert(ggml_is_quantized(GGML_TYPE_TESSERA_T640_3D) == true);
    assert(std::strcmp(ggml_type_name(GGML_TYPE_TESSERA_T512), "tessera_t512") == 0);
    assert(ggml_is_quantized(GGML_TYPE_TESSERA_T512) == true);
    assert(std::strcmp(ggml_type_name(GGML_TYPE_TESSERA_T1024), "tessera_t1024") == 0);
    assert(ggml_is_quantized(GGML_TYPE_TESSERA_T1024) == true);
}

static void test_no_type_name_is_null_across_full_range(void) {
    printf("test-tessera-type-gap-audit: ggml_type_name() never returns "
           "null for any defined enum value in [0, GGML_TYPE_COUNT)\n");
    // Sweeps every index, not just the known gap range: catches any future
    // enum insertion that forgets a designated-init entry, since a C
    // aggregate leaves un-designated slots implicitly zeroed (null name).
    for (int t = 0; t < GGML_TYPE_COUNT; ++t) {
        const char * name = ggml_type_name((enum ggml_type) t);
        if (name == nullptr) {
            fprintf(stderr, "test-tessera-type-gap-audit: type %d has a "
                            "null type_name (missing designated-init entry)\n", t);
            assert(false);
        }
    }
}

int main(void) {
    test_gap_range_47_to_62();
    test_rdna3_gap_safe_until_task_3_7();
    test_enum_shape();
    test_existing_tessera_types_unaffected();
    test_no_type_name_is_null_across_full_range();
    printf("test-tessera-type-gap-audit: all tests OK\n");
    return 0;
}
