// tessera-train-dflash.cpp - native DFlash / D-PACE block-drafter training driver.
//
// Trains a DFlash / DSpark block drafter with the D-PACE adaptive cross-entropy
// objective (Wu et al., arXiv:2605.18810), using the existing cross-entropy
// path with per-position weights written at the llama-layer label fill (the
// additive change to src/llama-context.cpp). Reads llama.tessera.dflash-block.v1
// records (from `tessera-dataset --tessera-dataset-mode dflash`) and produces
// the (tokens, sparse labels, D-PACE weights) triples the weighted-CE label
// fill consumes. Runs the same ggml_opt epoch loop as tessera-train-lk, just
// with per-position weights and a different loss driver.
//
// Layout contract (per docs/tessera-dflash-training-design.md 0b):
//   one datapoint = n_ctx = n_dft + 1 tokens
//   pos 0         = anchor (committed last token; weight 0 -> no gradient)
//   pos 1 + j     = drafted position j (target = dataset.target_tokens[j],
//                   weight  = dataset.dpace_weights[j])
// The dflash model's block_drafts (dflash.block_size in GGUF metadata) INCLUDES
// the anchor, so we set n_ctx = block_drafts = n_dft + 1. The drafter borrows
// tok_embd + output (lm_head) from the trunk via ctx_other (frozen at train),
// so the only trainable params are the drafter's own (encoder FC, drafter
// layers, norms, dspark heads). Stage 1 of the design doc is the gate this
// driver satisfies.
//
// Mimics examples/training/finetune.cpp; the only structural differences from
// tessera-train-lk are the per-position weight buffer (parallel to
// labels_sparse), the optional --weight-scheme flag, and the
// use_weighted_ce + opt_label_weights opt_init path. The cross-entropy loss
// graph itself is unchanged: a D-PACE weight at the label fill produces
// sum_j w_j * (-log q(y_j)) with gradient scaled per position.

#include "arg.h"
#include "common.h"
#include "log.h"
#include "llama.h"
#include "tessera-dflash-train-data.h"

#include "ggml-opt.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static void print_usage(const char * prog) {
    printf("usage: %s -m drafter.gguf --trunk-model trunk.gguf --dflash-data blocks.jsonl -o trained.gguf [options]\n", prog);
    printf("\n");
    printf("DFlash / D-PACE block-drafter training: minimize the per-position weighted\n");
    printf("cross-entropy of the drafter against the verifier's argmax, with weights\n");
    printf("baked into the dataset. Default weight scheme = D-PACE (adaptive from the\n");
    printf("accepted-length surrogate); --weight-scheme decay uses the DFlash fixed\n");
    printf("exponential baseline (A/B via data swap, no graph change).\n");
    printf("\n");
    printf("Tessera options:\n");
    printf("  --trunk-model PATH    trunk GGUF (provides tok_embd + output via ctx_other)\n");
    printf("  --dflash-data PATH    llama.tessera.dflash-block.v1 JSONL (from tessera-dataset --tessera-dataset-mode dflash)\n");
    printf("  --block-size B        drafted tokens per step; n_ctx = B+1 (default: auto-detect modal)\n");
    printf("  --max-examples N      dataset cap, bounds sparse-label memory (default 512)\n");
    printf("  --weight-scheme S     dpace (default) | decay\n");
    printf("  --dry-run             build the dataset and print stats; do not train or save\n");
    printf("\n");
    printf("Standard training options (shared with llama-finetune):\n");
    printf("  -m, --model PATH      drafter model to train (weights are modified in place)\n");
    printf("  -o, --out-file PATH   where to save the trained model\n");
    printf("  -epochs, --epochs N         number of epochs\n");
    printf("  -lr, --learning-rate F      adamw | sgd optimizer alpha\n");
    printf("  -opt, --optimizer NAME      adamw | sgd (default adamw)\n");
    printf("  -val-split, --val-split F   validation fraction\n");
    printf("  -ngl, --n-gpu-layers N      layers on the GPU\n");
    printf("\n");
    printf("The context size is forced to block_size+1 (one block per datapoint: anchor + B drafted).\n");
    printf("The DFlash graph borrows tok_embd + output (lm_head) from the trunk via ctx_other;\n");
    printf("those tensors are resident but frozen at train time, so the drafter's own params\n");
    printf("(encoder FC, drafter layers, norms, dspark heads) are the trainable set.\n");
}

int main(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");

    // ---- pull tessera-specific flags out of argv; pass the rest to common ----
    std::string trunk_model_path;
    std::string dflash_data_path;
    int  block_size   = 0;     // 0 -> auto-detect modal n_dft
    int  max_examples = 512;
    int  weight_scheme = 0;    // 0 = dpace (default), 1 = decay
    bool dry_run      = false;

    std::vector<std::string> pass;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "-h" || a == "--help") { print_usage(argv[0]); return 0; }
        else if (a == "--trunk-model"   && i + 1 < argc) { trunk_model_path = argv[++i]; }
        else if (a == "--dflash-data"   && i + 1 < argc) { dflash_data_path = argv[++i]; }
        else if (a == "--block-size"    && i + 1 < argc) { block_size       = std::atoi(argv[++i]); }
        else if (a == "--max-examples"  && i + 1 < argc) { max_examples     = std::atoi(argv[++i]); }
        else if (a == "--weight-scheme" && i + 1 < argc) {
            const std::string s = argv[++i];
            if      (s == "dpace") { weight_scheme = 0; }
            else if (s == "decay") { weight_scheme = 1; }
            else {
                LOG_ERR("--weight-scheme must be 'dpace' or 'decay', got '%s'\n", s.c_str());
                return 1;
            }
        }
        else if (a == "--dry-run")                       { dry_run          = true; }
        else { pass.push_back(a); }
    }

    if (trunk_model_path.empty()) {
        print_usage(argv[0]);
        LOG_ERR("--trunk-model is required (path to the trunk GGUF)\n");
        return 1;
    }
    if (dflash_data_path.empty()) {
        print_usage(argv[0]);
        LOG_ERR("--dflash-data is required\n");
        return 1;
    }
    if (max_examples <= 0) {
        LOG_ERR("--max-examples must be > 0\n");
        return 1;
    }

    std::vector<char *> cargv;
    cargv.push_back(argv[0]);
    for (auto & s : pass) {
        cargv.push_back(const_cast<char *>(s.c_str()));
    }
    const int cargc = (int) cargv.size();

    common_params params;
    params.escape = false;

    common_init();

    if (!common_params_parse(cargc, cargv.data(), params, LLAMA_EXAMPLE_FINETUNE)) {
        return 1;
    }

    // ---- resolve block size (auto-detect the modal n_dft) ----
    if (block_size <= 0) {
        block_size = ts_dflash_train_detect_block_size(dflash_data_path.c_str());
        if (block_size <= 0) {
            LOG_ERR("could not auto-detect block size from %s (no dflash-block.v1 records?); pass --block-size\n",
                    dflash_data_path.c_str());
            return 1;
        }
        LOG_INF("auto-detected block_size = %d (modal n_dft)\n", block_size);
    }
    const int n_ctx_dp = block_size + 1;  // anchor + n_dft drafted

    // ---- force the training context to one block per datapoint ----
    // Mirrors finetune / tessera-train-lk: writable weights + f32 KV cache
    // (OUT_PROD has no f16) and flash attention disabled (FLASH_ATTN_EXT has
    // no backward pass, so the training graph must use the differentiable
    // non-flash attention path).
    params.load_mode        = LLAMA_LOAD_MODE_NONE;
    params.cache_type_k     = GGML_TYPE_F32;
    params.cache_type_v     = GGML_TYPE_F32;
    params.flash_attn_type  = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    params.n_ctx            = n_ctx_dp;
    params.n_batch          = n_ctx_dp;
    params.n_ubatch         = n_ctx_dp;

    llama_backend_init();
    llama_numa_init(params.numa);

    // all variables declared before any goto so C++ is happy about jumps
    llama_model   * model_trunk = nullptr;
    llama_context * ctx_trunk   = nullptr;
    llama_model   * model_dft   = nullptr;
    llama_context * ctx_dft     = nullptr;
    ggml_opt_dataset_t dataset = nullptr;
    struct llama_model_params mparams_trunk;
    struct llama_context_params cparams_trunk;
    struct llama_model_params mparams_dft;
    struct llama_context_params cparams_dft;
    std::vector<std::string> usable;
    int ndata = 0;
    llama_token * data_ptr   = nullptr;
    llama_token * labels_ptr = nullptr;
    std::vector<float> weights_buffer;
    struct llama_opt_params lopt_params;
    struct lr_opt & lr = params.lr;
    int64_t idata_split = 0;
    ggml_opt_result_t result_train = nullptr;
    ggml_opt_result_t result_eval  = nullptr;
    int n_vocab = 0;

    // ---- Step 1: load trunk model (provides frozen tok_embd + output via ctx_other) ----
    // The trunk context needs only enough n_ctx to hold the KV working set;
    // token embeddings are resolved at the model level before the context is created.
    mparams_trunk = common_model_params_to_llama(params);
    model_trunk = llama_model_load_from_file(trunk_model_path.c_str(), mparams_trunk);
    if (model_trunk == NULL) {
        LOG_ERR("failed to load trunk model: %s\n", trunk_model_path.c_str());
        goto cleanup;
    }

    cparams_trunk = llama_context_default_params();
    cparams_trunk.n_ctx    = 128;  // minimal; trunk KV working set is unused at train
    cparams_trunk.n_batch  = 128;
    cparams_trunk.n_ubatch = 128;
    ctx_trunk = llama_init_from_model(model_trunk, cparams_trunk);
    if (ctx_trunk == NULL) {
        LOG_ERR("failed to create trunk context\n");
        goto cleanup;
    }

    // ---- Step 2: load drafter model and bind ctx_other to the trunk ----
    // The drafter GGUF may have its own tok_embd/output tensors allocated
    // (Gemma4-style, n_embd x n_vocab), but the forward pass checks
    //   if (model.tok_embd == nullptr) { tok_embd = ctx_other->model->tok_embd; }
    // so we always borrow from the trunk. This is the correct behavior for
    // training: the drafter's trunk-borrowed tok_embd + output are frozen,
    // and only the drafter's own params (encoder FC, drafter layers, norms,
    // dspark heads) carry gradients.
    mparams_dft = common_model_params_to_llama(params);
    model_dft = llama_model_load_from_file(params.model.path.c_str(), mparams_dft);
    if (model_dft == NULL) {
        LOG_ERR("failed to load drafter model: %s\n", params.model.path.c_str());
        goto cleanup;
    }

    cparams_dft = common_context_params_to_llama(params);
    cparams_dft.ctx_other = ctx_trunk;  // key: drafter borrows trunk tok_embd + output
    ctx_dft = llama_init_from_model(model_dft, cparams_dft);
    if (ctx_dft == NULL) {
        LOG_ERR("failed to create drafter context\n");
        goto cleanup;
    }

    LOG_INF("\n%s\n", common_params_get_system_info(params).c_str());

    // vocab: the drafter's logits dimension must match the trunk's. The vocab
    // should be identical (same tokenizer as the trunk); n_vocab from the trunk
    // is the authoritative value since that's what the shared lm_head uses.
    n_vocab = llama_vocab_n_tokens(llama_model_get_vocab(model_trunk));
    LOG_INF("trunk:  n_vocab = %d  (tok_embd + output borrowed by drafter via ctx_other)\n", n_vocab);
    LOG_INF("drafter: n_ctx = %d (block_size = %d, weight_scheme = %s)\n",
            n_ctx_dp, block_size, weight_scheme == 0 ? "dpace" : "decay");

    // ---- Step 3: load and build the dataset ----
    {
        std::ifstream fin(dflash_data_path);
        if (!fin) {
            LOG_ERR("cannot open dflash data: %s\n", dflash_data_path.c_str());
            goto cleanup;
        }
        std::string line;
        while (std::getline(fin, line) && (int) usable.size() < max_examples) {
            if (!line.empty() && ts_dflash_train_line_usable(line.c_str(), block_size) == 1) {
                usable.push_back(line);
            }
        }
    }

    ndata = (int) usable.size();
    if (ndata == 0) {
        LOG_ERR("no usable dflash-block.v1 records with n_dft == %d in %s\n",
                block_size, dflash_data_path.c_str());
        goto cleanup;
    }

    dataset = ggml_opt_dataset_init(
            GGML_TYPE_I32, GGML_TYPE_I32, n_ctx_dp, /*ne_label =*/ n_ctx_dp, ndata, /*ndata_shard =*/ 1);

    data_ptr   = (llama_token *) ggml_opt_dataset_data(dataset)->data;
    labels_ptr = (llama_token *) ggml_opt_dataset_labels(dataset)->data;

    weights_buffer.assign((size_t) ndata * n_ctx_dp, 0.0f);

    for (int idata = 0; idata < ndata; ++idata) {
        float * w = weights_buffer.data() + (size_t) idata * n_ctx_dp;
        const int rc = ts_dflash_train_example_from_line(
                usable[idata].c_str(), block_size, weight_scheme,
                data_ptr   + (size_t) idata * n_ctx_dp,
                labels_ptr + (size_t) idata * n_ctx_dp,
                w);
        if (rc != 1) {
            LOG_ERR("failed to build training example %d (rc = %d)\n", idata, rc);
            goto cleanup;
        }
        if (w[0] != 0.0f) {
            LOG_WRN("example %d: anchor weight = %f (expected 0); resetting to 0\n", idata, w[0]);
            w[0] = 0.0f;
        }
    }
    LOG_INF("built %d training examples; weight scheme = %s\n",
            ndata, weight_scheme == 0 ? "dpace" : "decay");
    usable.clear();
    usable.shrink_to_fit();

    llama_set_opt_label_weights(ctx_dft, weights_buffer.data(), (size_t) n_ctx_dp);

    if (dry_run) {
        LOG_INF("dry-run: dataset built OK; skipping training and save\n");
        goto cleanup;
    }

    LOG_INF("-optimizer %s -lr0 %.2g -wd %.2g -epochs %d -period %.2g -val %.2g\n",
            ggml_opt_optimizer_name(params.optimizer), (double) lr.lr0, (double) lr.wd,
            (unsigned) lr.epochs, (double) params.n_batch / params.n_ubatch, (double) params.val_split);

    lopt_params.n_ctx_train     = (uint32_t) n_ctx_dp;
    lopt_params.param_filter     = llama_opt_param_filter_all;
    lopt_params.param_filter_ud  = nullptr;
    lopt_params.get_opt_pars     = common_opt_lr_pars;
    lopt_params.get_opt_pars_ud  = &params.lr;
    lopt_params.optimizer_type   = params.optimizer;
    lopt_params.loss_type        = GGML_OPT_LOSS_TYPE_CROSS_ENTROPY;
    lopt_params.use_weighted_ce  = true;
    llama_opt_init(ctx_dft, model_dft, lopt_params);

    idata_split = ggml_opt_dataset_ndata(dataset) * (1.0f - params.val_split);

    result_train = ggml_opt_result_init();
    result_eval  = ggml_opt_result_init();

    for (lr.epoch = 0; lr.epoch < lr.epochs; ++lr.epoch) {
        llama_opt_epoch(ctx_dft, dataset, result_train, result_eval, idata_split,
                        ggml_opt_epoch_callback_progress_bar, ggml_opt_epoch_callback_progress_bar);
        fprintf(stderr, "\n");

        double loss_train = 0.0, acc_train = 0.0;
        ggml_opt_result_loss(result_train, &loss_train, nullptr);
        ggml_opt_result_accuracy(result_train, &acc_train, nullptr);
        LOG_INF("epoch %u: train weighted-CE loss %.6f, top-1 agreement %.4f\n",
                lr.epoch, loss_train, acc_train);

        ggml_opt_result_reset(result_train);
        ggml_opt_result_reset(result_eval);
    }

    ggml_opt_result_free(result_train);
    ggml_opt_result_free(result_eval);
    ggml_opt_dataset_free(dataset);

    if (params.out_file.empty()) {
        LOG_ERR("no --out-file specified; trained model not saved\n");
    } else {
        llama_model_save_to_file(model_dft, params.out_file.c_str());
        LOG_INF("saved trained drafter to %s\n", params.out_file.c_str());
    }

cleanup:
    if (ctx_dft)     { llama_free(ctx_dft); }
    if (model_dft)   { llama_model_free(model_dft); }
    if (ctx_trunk)   { llama_free(ctx_trunk); }
    if (model_trunk) { llama_model_free(model_trunk); }
    llama_backend_free();
    return 0;
}
