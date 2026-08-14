#include "ggml.h"

#include <cassert>
#include <cstddef>

int main() {
    // -- ggml observer tensor classification --
    // The stats view is the half of an imatrix observer cast whose offset and
    // element count identify it as the importance accumulator; the storage
    // and activation halves are the activation path. This is the contract
    // ggml_imatrix_observer_is_stats depends on.
    ggml_init_params params = {
        /*.mem_size   =*/16 * 1024 * 1024,
        /*.mem_buffer =*/nullptr,
        /*.no_alloc   =*/true,
    };
    ggml_context * ctx = ggml_init(params);
    assert(ctx != nullptr);

    ggml_tensor * activations     = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, 2048, 128, 2, 1);
    ggml_tensor * weight_anchor   = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, 2048, 2048);
    ggml_tensor * stats           = nullptr;
    ggml_tensor * activation_view = ggml_imatrix_observer_cast(ctx, activations, weight_anchor, &stats);
    ggml_tensor * storage         = activation_view->view_src;

    assert(storage != nullptr);
    assert(storage == stats->view_src);
    assert(storage->op == GGML_OP_IMATRIX_OBSERVER);
    assert(storage->type == GGML_TYPE_F16);
    assert(activation_view->op == GGML_OP_VIEW);
    assert(activation_view->type == GGML_TYPE_F16);
    assert(stats->op == GGML_OP_VIEW);
    assert(stats->type == GGML_TYPE_F32);

    assert(!ggml_imatrix_observer_is_stats(storage));
    assert(!ggml_imatrix_observer_is_stats(activation_view));
    assert(ggml_imatrix_observer_is_stats(stats));

    const size_t original_offset = stats->view_offs;
    stats->view_offs             = 0;
    assert(!ggml_imatrix_observer_is_stats(stats));
    stats->view_offs = original_offset;

    const int64_t original_elements = stats->ne[0];
    stats->ne[0]                    = original_elements - 1;
    assert(!ggml_imatrix_observer_is_stats(stats));
    stats->ne[0] = original_elements;
    assert(ggml_imatrix_observer_is_stats(stats));

    // -- ggml_imatrix_observer_is_activation_view: the mirror-image check
    // (pipeline refactor stage 5, real per-tensor activation capture). It
    // must identify exactly the F16 activation view and reject the other
    // two views into the same shared storage tensor.
    assert(!ggml_imatrix_observer_is_activation_view(storage));
    assert(!ggml_imatrix_observer_is_activation_view(stats));
    assert(ggml_imatrix_observer_is_activation_view(activation_view));

    // A tensor with view_offs != 0 is never the activation view (that
    // offset belongs to the stats tail).
    const size_t original_act_offset = activation_view->view_offs;
    activation_view->view_offs       = 1;
    assert(!ggml_imatrix_observer_is_activation_view(activation_view));
    activation_view->view_offs = original_act_offset;
    assert(ggml_imatrix_observer_is_activation_view(activation_view));

    // A plain F16 view into an unrelated (non-GGML_OP_IMATRIX_OBSERVER)
    // storage tensor must not be misclassified as an activation view.
    ggml_tensor * unrelated_storage = ggml_new_tensor_1d(ctx, GGML_TYPE_F16, 4096);
    ggml_tensor * unrelated_view    = ggml_view_4d(ctx, unrelated_storage,
                                                   2048, 2, 1, 1,
                                                   2048 * sizeof(ggml_fp16_t),
                                                   2048 * sizeof(ggml_fp16_t) * 2,
                                                   2048 * sizeof(ggml_fp16_t) * 2, 0);
    assert(!ggml_imatrix_observer_is_activation_view(unrelated_view));

    ggml_free(ctx);

    // Per-scope filter storage is covered by test-imatrix-observer-scope.cpp.

    return 0;
}
