#include "llama.h"

#include "arg.h"
#include "build-info.h"
#include "common.h"
#include "imatrix-loader.h"
#include "tessera-args.h"

#include "tessera/tessera-dispatch.h"
#include "tessera/tessera-capability-eval.h"
#include "tessera/tessera-adapt.h"
#include "tessera/tessera-anonymizer.h"
#include "tessera/tessera-throughput.h"
#include "tessera/tessera-dataset.h"
#include "tessera/tessera-dpace.h"
#include "tessera/tessera-unified-writer.h"
#include "tessera/tessera-quantize-db.h"
#include "tessera/tessera-ternary.h"
#include "tessera/tessera-quant.h"
#include "tessera/tessera-imatrix.h"
#include "tessera/tessera-regime.h"
#include "tessera/ttt-writer.h"
#include "tessera/ttt-reader.h"
#include "tessera/tessera-gguf-writer.h"
#include "tessera/tile-detect.h"

#include "gguf.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <clocale>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <vector>
#include <string>
#include <unordered_map>
#include <fstream>
#include <filesystem>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#  include <sys/sysctl.h>
#endif

// result of parsing --tensor-type option
// changes to this struct must also be reflected in src/llama-quant.cpp
struct tensor_type_option {
    std::string name;
    ggml_type type = GGML_TYPE_COUNT;
};

struct quant_option {
    std::string name;
    llama_ftype ftype;
    std::string desc;
};

static const std::vector<quant_option> QUANT_OPTIONS = {
    { "Q1_0",     LLAMA_FTYPE_MOSTLY_Q1_0,     " 1.125 bpw quantization",           },
    { "Q2_0",     LLAMA_FTYPE_MOSTLY_Q2_0,     " 2.25 bpw quantization (group 64)",  },
    { "Q4_0",     LLAMA_FTYPE_MOSTLY_Q4_0,     " 4.34G, +0.4685 ppl @ Llama-3-8B",  },
    { "Q4_1",     LLAMA_FTYPE_MOSTLY_Q4_1,     " 4.78G, +0.4511 ppl @ Llama-3-8B",  },
    { "MXFP4_MOE",LLAMA_FTYPE_MOSTLY_MXFP4_MOE," MXFP4 MoE",  },
    { "Q5_0",     LLAMA_FTYPE_MOSTLY_Q5_0,     " 5.21G, +0.1316 ppl @ Llama-3-8B",  },
    { "Q5_1",     LLAMA_FTYPE_MOSTLY_Q5_1,     " 5.65G, +0.1062 ppl @ Llama-3-8B",  },
    { "IQ2_XXS",  LLAMA_FTYPE_MOSTLY_IQ2_XXS,  " 2.06 bpw quantization",            },
    { "IQ2_XS",   LLAMA_FTYPE_MOSTLY_IQ2_XS,   " 2.31 bpw quantization",            },
    { "IQ2_S",    LLAMA_FTYPE_MOSTLY_IQ2_S,    " 2.5  bpw quantization",            },
    { "IQ2_M",    LLAMA_FTYPE_MOSTLY_IQ2_M,    " 2.7  bpw quantization",            },
    { "IQ1_S",    LLAMA_FTYPE_MOSTLY_IQ1_S,    " 1.56 bpw quantization",            },
    { "IQ1_M",    LLAMA_FTYPE_MOSTLY_IQ1_M,    " 1.75 bpw quantization",            },
    { "TQ1_0",    LLAMA_FTYPE_MOSTLY_TQ1_0,    " 1.69 bpw ternarization",           },
    { "TQ2_0",    LLAMA_FTYPE_MOSTLY_TQ2_0,    " 2.06 bpw ternarization",           },
    { "Q2_K",     LLAMA_FTYPE_MOSTLY_Q2_K,     " 2.96G, +3.5199 ppl @ Llama-3-8B",  },
    { "Q2_K_S",   LLAMA_FTYPE_MOSTLY_Q2_K_S,   " 2.96G, +3.1836 ppl @ Llama-3-8B",  },
    { "IQ3_XXS",  LLAMA_FTYPE_MOSTLY_IQ3_XXS,  " 3.06 bpw quantization",            },
    { "IQ3_S",    LLAMA_FTYPE_MOSTLY_IQ3_S,    " 3.44 bpw quantization",            },
    { "IQ3_M",    LLAMA_FTYPE_MOSTLY_IQ3_M,    " 3.66 bpw quantization mix",        },
    { "Q3_K",     LLAMA_FTYPE_MOSTLY_Q3_K_M,   "alias for Q3_K_M"                   },
    { "IQ3_XS",   LLAMA_FTYPE_MOSTLY_IQ3_XS,   " 3.3 bpw quantization",             },
    { "Q3_K_S",   LLAMA_FTYPE_MOSTLY_Q3_K_S,   " 3.41G, +1.6321 ppl @ Llama-3-8B",  },
    { "Q3_K_M",   LLAMA_FTYPE_MOSTLY_Q3_K_M,   " 3.74G, +0.6569 ppl @ Llama-3-8B",  },
    { "Q3_K_L",   LLAMA_FTYPE_MOSTLY_Q3_K_L,   " 4.03G, +0.5562 ppl @ Llama-3-8B",  },
    { "IQ4_NL",   LLAMA_FTYPE_MOSTLY_IQ4_NL,   " 4.50 bpw non-linear quantization", },
    { "IQ4_XS",   LLAMA_FTYPE_MOSTLY_IQ4_XS,   " 4.25 bpw non-linear quantization", },
    { "Q4_K",     LLAMA_FTYPE_MOSTLY_Q4_K_M,   "alias for Q4_K_M",                  },
    { "Q4_K_S",   LLAMA_FTYPE_MOSTLY_Q4_K_S,   " 4.37G, +0.2689 ppl @ Llama-3-8B",  },
    { "Q4_K_M",   LLAMA_FTYPE_MOSTLY_Q4_K_M,   " 4.58G, +0.1754 ppl @ Llama-3-8B",  },
    { "Q5_K",     LLAMA_FTYPE_MOSTLY_Q5_K_M,   "alias for Q5_K_M",                  },
    { "Q5_K_S",   LLAMA_FTYPE_MOSTLY_Q5_K_S,   " 5.21G, +0.1049 ppl @ Llama-3-8B",  },
    { "Q5_K_M",   LLAMA_FTYPE_MOSTLY_Q5_K_M,   " 5.33G, +0.0569 ppl @ Llama-3-8B",  },
    { "Q6_K",     LLAMA_FTYPE_MOSTLY_Q6_K,     " 6.14G, +0.0217 ppl @ Llama-3-8B",  },
    { "Q8_0",     LLAMA_FTYPE_MOSTLY_Q8_0,     " 7.96G, +0.0026 ppl @ Llama-3-8B",  },
    { "F16",      LLAMA_FTYPE_MOSTLY_F16,      "14.00G, +0.0020 ppl @ Mistral-7B",  },
    { "BF16",     LLAMA_FTYPE_MOSTLY_BF16,     "14.00G, -0.0050 ppl @ Mistral-7B",  },
    { "F32",      LLAMA_FTYPE_ALL_F32,         "26.00G              @ 7B",          },
    // Note: Ensure COPY comes after F32 to avoid ftype 0 from matching.
    { "COPY",     LLAMA_FTYPE_ALL_F32,         "only copy tensors, no quantizing",  },
};

static const char * const LLM_KV_QUANTIZE_IMATRIX_FILE       = "quantize.imatrix.file";
static const char * const LLM_KV_QUANTIZE_IMATRIX_DATASET    = "quantize.imatrix.dataset";
static const char * const LLM_KV_QUANTIZE_IMATRIX_N_ENTRIES  = "quantize.imatrix.entries_count";
static const char * const LLM_KV_QUANTIZE_IMATRIX_N_CHUNKS   = "quantize.imatrix.chunks_count";
static const char * const LLM_KV_QUANTIZE_IMATRIX_PRIOR_W    = "quantize.imatrix.prior_weight";

static bool striequals(const char * a, const char * b) {
    while (*a && *b) {
        if (std::tolower(*a) != std::tolower(*b)) {
            return false;
        }
        a++; b++;
    }
    return *a == *b;
}

static bool try_parse_ftype(const std::string & ftype_str_in, llama_ftype & ftype, std::string & ftype_str_out) {
    std::string ftype_str;

    for (auto ch : ftype_str_in) {
        ftype_str.push_back(std::toupper(ch));
    }
    for (const auto & it : QUANT_OPTIONS) {
        if (striequals(it.name.c_str(), ftype_str.c_str())) {
            ftype = it.ftype;
            ftype_str_out = it.name;
            return true;
        }
    }
    try {
        int ftype_int = std::stoi(ftype_str);
        for (const auto & it : QUANT_OPTIONS) {
            if (it.ftype == ftype_int) {
                ftype = it.ftype;
                ftype_str_out = it.name;
                return true;
            }
        }
    }
    catch (...) {
        // stoi failed
    }
    return false;
}

[[noreturn]]
static void usage(const char * executable) {
    printf("usage: %s [--help] [--allow-requantize] [--leave-output-tensor] [--pure] [--imatrix] [--include-weights]\n", executable);
    printf("       [--exclude-weights] [--output-tensor-type] [--token-embedding-type] [--tensor-type] [--tensor-type-file]\n");
    printf("       [--prune-layers] [--keep-split] [--override-kv] [--dry-run]\n");
    printf("       model-f32.gguf [model-quant.gguf] type [nthreads]\n\n");
    printf("  --allow-requantize\n");
    printf("                                      allow requantizing tensors that have already been quantized\n");
    printf("                                      WARNING: this can severely reduce quality compared to quantizing\n");
    printf("                                               from 16bit or 32bit!\n");
    printf("  --leave-output-tensor\n");
    printf("                                      leave output.weight un(re)quantized\n");
    printf("                                      increases model size but may also increase quality, especially when requantizing\n");
    printf("  --pure\n");
    printf("                                      disable k-quant mixtures and quantize all tensors to the same type\n");
    printf("  --imatrix file_name\n");
    printf("                                      use data in file_name as importance matrix for quant optimizations\n");
    printf("  --imatrix-scope {verifier|mtp|dflash|dspark|talker}\n");
    printf("                                      scope tag to look up in the imatrix (default verifier)\n");
    printf("                                      use when quantizing a drafter/talker component against a combined imatrix file\n");
    printf("  --include-weights tensor_name\n");
    printf("                                      use importance matrix for this/these tensor(s)\n");
    printf("  --exclude-weights tensor_name\n");
    printf("                                      do not use importance matrix for this/these tensor(s)\n");
    printf("  --output-tensor-type ggml_type\n");
    printf("                                      use this ggml_type for the output.weight tensor\n");
    printf("  --token-embedding-type ggml_type\n");
    printf("                                      use this ggml_type for the token embeddings tensor\n");
    printf("  --tensor-type tensor_name=ggml_type\n");
    printf("                                      quantize this tensor to this ggml_type\n");
    printf("                                      this is an advanced option to selectively quantize tensors. may be specified multiple times.\n");
    printf("                                      example: --tensor-type attn_q=q8_0\n");
    printf("  --tensor-type-file tensor_types.txt\n");
    printf("                                      list of tensors to quantize to a specific ggml_type\n");
    printf("                                      this is an advanced option to selectively quantize a long list of tensors.\n");
    printf("                                      the file should use the same format as above, separated by spaces or newlines.\n");
    printf("  --prune-layers L0,L1,L2...\n");
    printf("                                      comma-separated list of layer numbers to prune from the model\n");
    printf("                                      WARNING: this is an advanced option, use with care.\n");
    printf("  --keep-split\n");
    printf("                                      generate quantized model in the same shards as input\n");
    printf("  --prior-weight N\n");
    printf("                                      how many tokens the neutral prior is worth (when using imatrix)\n");
    printf("  --override-kv KEY=TYPE:VALUE\n");
    printf("                                      override model metadata by key in the quantized model. may be specified multiple times.\n");
    printf("                                      WARNING: this is an advanced option, use with care.\n");
    printf("  --dry-run\n");
    printf("                                      calculate and show the final quantization size without performing quantization\n");
    printf("                                      example: llama-quantize --dry-run model-f32.gguf Q4_K\n\n");
    printf("note: --include-weights and --exclude-weights cannot be used together\n\n");
    printf("-----------------------------------------------------------------------------\n");
    printf(" allowed quantization types\n");
    printf("-----------------------------------------------------------------------------\n\n");
    for (const auto & it : QUANT_OPTIONS) {
        if (it.name != "COPY") {
            printf("  %2d  or  ", it.ftype);
        } else {
            printf("          ");
        }
        printf("%-7s : %s\n", it.name.c_str(), it.desc.c_str());
    }
    exit(1);
}

static int load_imatrix(const std::string & imatrix_file, std::vector<std::string> & imatrix_datasets, std::unordered_map<std::string, std::vector<float>> & imatrix_data, float & prior_weight) {
    common_imatrix loaded;
    if (!common_imatrix_load(imatrix_file, loaded)) {
        fprintf(stderr, "%s: failed to load imatrix from '%s'\n", __func__, imatrix_file.c_str());
        exit(1);
    }

    if (!loaded.is_legacy && !loaded.has_metadata) {
        fprintf(stderr, "%s: missing imatrix metadata in file %s\n", __func__, imatrix_file.c_str());
        exit(1);
    }

    for (const auto & [name, entry] : loaded.entries) {
        auto & e = imatrix_data[name];
        e.resize(entry.sums.size());

        if (!loaded.is_legacy) {
            // GGUF format: normalize by per-expert counts
            const int64_t ncounts = entry.counts.size();
            const int64_t ne0     = (int64_t) entry.sums.size() / ncounts;

            for (int64_t j = 0; j < ncounts; ++j) {
                const float count = (float) entry.counts[j];
                if (count > 0.0f) {
                    for (int64_t i = 0; i < ne0; ++i) {
                        e[j*ne0 + i] = (entry.sums[j*ne0 + i] + prior_weight) / (count + prior_weight);
                    }
                } else {
                    for (int64_t i = 0; i < ne0; ++i) {
                        e[j*ne0 + i] = 1;
                    }
                }
            }

            if (getenv("LLAMA_TRACE")) {
                float max_count = 0.0f;
                for (int64_t j = 0; j < ncounts; ++j) {
                    const float count = (float) entry.counts[j];
                    if (count > max_count) {
                        max_count = count;
                    }
                }
                printf("%s: loaded data (size = %6d, n_tokens = %6d, n_chunks = %6d) for '%s'\n",
                       __func__, int(e.size()), int(max_count), int(max_count / loaded.chunk_size), name.c_str());
            }
        } else {
            // Legacy format: sums contain (raw/count)*ncall, divide by ncall
            prior_weight = 0.0f; // can't use a prior weight without having proper activation counts
            const int64_t ncall = entry.counts.empty() ? 0 : entry.counts[0];
            if (ncall > 0) {
                for (size_t i = 0; i < entry.sums.size(); ++i) {
                    e[i] = entry.sums[i] / ncall;
                }
            } else {
                for (size_t i = 0; i < entry.sums.size(); ++i) {
                    e[i] = entry.sums[i];
                }
            }

            if (getenv("LLAMA_TRACE")) {
                printf("%s: loaded data (size = %6d, ncall = %6d) for '%s'\n",
                       __func__, int(e.size()), int(ncall), name.c_str());
            }
        }
    }

    imatrix_datasets = std::move(loaded.datasets);

    if (!imatrix_datasets.empty()) {
        printf("%s: imatrix datasets=['%s'", __func__, imatrix_datasets[0].c_str());
        for (size_t i = 1; i < imatrix_datasets.size(); ++i) {
            printf(", '%s'", imatrix_datasets[i].c_str());
        }
        printf("]\n");
    }

    printf("%s: loaded %d importance matrix entries from %s computed on %d chunks\n", __func__, int(imatrix_data.size()), imatrix_file.c_str(), loaded.chunk_count);

    return loaded.chunk_count;
}

static int prepare_imatrix(const std::string & imatrix_file,
        std::vector<std::string> & imatrix_dataset,
        const std::vector<std::string> & included_weights,
        const std::vector<std::string> & excluded_weights,
        std::unordered_map<std::string, std::vector<float>> & imatrix_data,
        float & prior_weight) {
    int m_last_call = -1;
    if (!imatrix_file.empty()) {
        m_last_call = load_imatrix(imatrix_file, imatrix_dataset, imatrix_data, prior_weight);
    }
    if (imatrix_data.empty()) {
        return m_last_call;
    }
    if (!excluded_weights.empty()) {
        for (const auto & name : excluded_weights) {
            for (auto it = imatrix_data.begin(); it != imatrix_data.end();) {
                auto pos = it->first.find(name);
                if (pos != std::string::npos) {
                    it = imatrix_data.erase(it);
                } else {
                    ++it;
                }
            }
        }
    }
    if (!included_weights.empty()) {
        std::unordered_map<std::string, std::vector<float>> tmp;
        for (const auto & name : included_weights) {
            for (auto & e : imatrix_data) {
                auto pos = e.first.find(name);
                if (pos != std::string::npos) {
                    tmp.emplace(std::move(e));
                }
            }
        }
        imatrix_data = std::move(tmp);
    }
    if (!imatrix_data.empty()) {
        printf("%s: have %d importance matrix entries\n", __func__, int(imatrix_data.size()));
    }
    return m_last_call;
}

static ggml_type parse_ggml_type(const char * arg) {
    for (int i = 0; i < GGML_TYPE_COUNT; ++i) {
        auto type = (ggml_type)i;
        const auto * name = ggml_type_name(type);
        if (name && striequals(name, arg)) {
            return type;
        }
    }
    fprintf(stderr, "\n%s: invalid ggml_type '%s'\n\n", __func__, arg);
    return GGML_TYPE_COUNT;
}

static bool parse_tensor_type(const char * data, std::vector<tensor_type_option> & tensor_type) {
    const char * sep = strchr(data, '=');
    if (sep == nullptr) {
        printf("\n%s: malformed tensor type '%s'\n\n", __func__, data);
        return false;
    }

    const size_t tn_len = sep - data;
    if (tn_len == 0) {
        printf("\n%s: missing tensor name\n\n", __func__);
        return false;
    }
    if (const size_t qt_len = strlen(sep); qt_len == 1) {
        printf("\n%s: missing quantization type\n\n", __func__);
        return false;
    }

    std::string tn(data, tn_len);
    std::transform(tn.begin(), tn.end(), tn.begin(), tolower);
    sep++;
    tensor_type_option tensor_type_opt;
    tensor_type_opt.name = tn;
    tensor_type_opt.type = parse_ggml_type(sep);
    tensor_type.emplace_back(std::move(tensor_type_opt));
    if (tensor_type_opt.type == GGML_TYPE_COUNT) {
        printf("\n%s: invalid quantization type '%s'\n\n", __func__, sep);
        return false;
    }

    return true;
}

static bool parse_tensor_type_file(const char * filename, std::vector<tensor_type_option> & tensor_type) {
    std::ifstream file(filename);
    if (!file) {
        printf("\n%s: failed to open file '%s': %s\n\n", __func__, filename, std::strerror(errno));
        return false;
    }

    std::string arg;
    while (file >> arg) {
        if (!parse_tensor_type(arg.c_str(), tensor_type)) {
            return false;
        }
    }

    return true;
}

static bool parse_layer_prune(const char * data, std::vector<int> & prune_layers) {
    if (!data) {
        printf("\n%s: no layer pruning ids provided\n\n", __func__);
        return false;
    }

    const auto block_ids = string_split<std::string>(data, ',');
    for (const auto & block_id : block_ids) {
        int id;
        try {
            id = std::stoi(block_id);
        } catch (...) {
            id = -1;
        }
        if (id < 0) {
            printf("\n%s: invalid layer id '%s'\n\n", __func__, block_id.c_str());
            return false;
        }
        prune_layers.emplace_back(id);
    }

    sort(prune_layers.begin(), prune_layers.end());
    prune_layers.erase(std::unique(prune_layers.begin(), prune_layers.end()), prune_layers.end());
    return true;
}

// satisfies -Wmissing-declarations
int llama_tessera_main(int argc, char ** argv);

// llama_quantize() is the main-quantize-path subroutine: it parses the
// positional <input> <ftype> [nthreads] args plus the legacy
// llama-quantize-specific flags (--leave-output-tensor,
// --output-tensor-type, --tensor-type, ...) and runs the dispatch.
// Called from llama_tessera_main when the user invokes llama-tessera
// without a subcommand (or with a tuning subcommand like awq, l5, w4a4).
int llama_quantize(int argc, char ** argv);

// Serialize a capability score vector. Field order matches the adapt
// receipt's "score" object (tessera-adapt.cpp) so the two stay in sync.
static nlohmann::json ts_cli_capability_score_json(const ts_capability_score * s) {
    nlohmann::json j;
    j["mechanical"]         = s->mechanical;
    j["api_currency"]       = s->api_currency;
    j["hard_tail"]          = s->hard_tail;
    j["personal_style"]     = s->personal_style;
    j["general_competence"] = s->general_competence;
    return j;
}

// --tessera-capability-eval: reduce per-axis instances to a score, print it
// as JSON (five axes + uniform-weight sum), optionally write it, then exit.
// No quantization runs. Returns a process exit code.
static int ts_cli_capability_eval(const common_tessera_params & tp) {
    ts_capability_score score;
    ts_capability_score baseline;
    bool has_baseline = false;
    std::string err;
    if (ts_capability_score_load(tp.capability_eval.c_str(), &score, &baseline, &has_baseline, &err) != 0) {
        fprintf(stderr, "error: capability-eval: %s\n", err.c_str());
        return 1;
    }

    // uniform weights over the four optimization axes; weights[4] is the
    // guard axis and is deliberately not summed (ts_capability_score_weighted_sum).
    const double weights[5] = { 0.25, 0.25, 0.25, 0.25, 0.0 };

    nlohmann::json j;
    j["schema"]       = "llama.tessera.capability.v1";
    j["score"]        = ts_cli_capability_score_json(&score);
    j["weights"]      = { weights[0], weights[1], weights[2], weights[3], weights[4] };
    j["weighted_sum"] = ts_capability_score_weighted_sum(&score, weights);
    j["has_baseline"] = has_baseline;
    j["baseline"]     = has_baseline ? ts_cli_capability_score_json(&baseline) : nlohmann::json(nullptr);

    const std::string out = j.dump(2);
    printf("%s\n", out.c_str());

    if (!tp.capability_out.empty()) {
        std::ofstream f(tp.capability_out, std::ios::binary);
        if (!f) {
            fprintf(stderr, "error: capability-eval: cannot write: %s\n", tp.capability_out.c_str());
            return 1;
        }
        f << out << "\n";
        if (!f.good()) {
            fprintf(stderr, "error: capability-eval: write failed: %s\n", tp.capability_out.c_str());
            return 1;
        }
    }
    return 0;
}

// --tessera-adapt: run one guarded adaptation step and exit with the adapter's
// return code mapped to a process exit code: 0 -> 0 (guard passed),
// 1 -> 1 (guard failed / blocked), -1 -> 2 (error).
static int ts_cli_adapt(const common_tessera_params & tp) {
    ts_adapt_params params;
    ts_adapt_default_params(&params);
    snprintf(params.input_eval_path, sizeof(params.input_eval_path), "%s", tp.adapt_eval.c_str());
    const std::string out_path = tp.adapt_out.empty() ? std::string("tessera-adapt-receipt.json") : tp.adapt_out;
    snprintf(params.output_receipt_path, sizeof(params.output_receipt_path), "%s", out_path.c_str());
    params.dry_run       = tp.adapt_dry_run;
    params.guard_epsilon = tp.adapt_epsilon;

    const int rc = ts_adapt_run(&params);
    if (rc == 0) return 0;
    if (rc == 1) return 1;
    return 2;
}

// --tessera-anonymize: scrub a text payload (tier-2 escalation) and exit.
// Prints the anonymized text to stdout, optionally writes it to
// --tessera-anonymize-out and the local de-anonymization map to
// --tessera-anonymize-map. No quantization runs. Returns a process exit code.
static int ts_cli_anonymize(const common_tessera_params & tp) {
    std::ifstream f(tp.anonymize_in, std::ios::binary);
    if (!f) {
        fprintf(stderr, "error: anonymize: cannot read: %s\n", tp.anonymize_in.c_str());
        return 1;
    }
    const std::string input((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    ts_anon_params params;
    ts_anon_default_params(&params);
    if (ts_anon_level_from_string(tp.anonymize_level.c_str(), &params.level) != 0) {
        fprintf(stderr, "error: anonymize: unknown level: %s\n", tp.anonymize_level.c_str());
        return 1;
    }
    params.emit_map = !tp.anonymize_map.empty();

    char * output_text = NULL;
    char * map_json    = NULL;
    if (ts_anonymize_run(&params, input.c_str(), &output_text, &map_json) != 0) {
        fprintf(stderr, "error: anonymize: anonymize run failed\n");
        return 1;
    }

    printf("%s", output_text);

    int rc = 0;
    if (!tp.anonymize_out.empty()) {
        std::ofstream of(tp.anonymize_out, std::ios::binary);
        if (!of) {
            fprintf(stderr, "error: anonymize: cannot write: %s\n", tp.anonymize_out.c_str());
            rc = 1;
        } else {
            of << output_text;
            if (!of.good()) {
                fprintf(stderr, "error: anonymize: write failed: %s\n", tp.anonymize_out.c_str());
                rc = 1;
            }
        }
    }
    if (rc == 0 && map_json != NULL) {
        std::ofstream mf(tp.anonymize_map, std::ios::binary);
        if (!mf) {
            fprintf(stderr, "error: anonymize: cannot write map: %s\n", tp.anonymize_map.c_str());
            rc = 1;
        } else {
            mf << map_json << "\n";
            if (!mf.good()) {
                fprintf(stderr, "error: anonymize: map write failed: %s\n", tp.anonymize_map.c_str());
                rc = 1;
            }
        }
    }

    free(output_text);
    free(map_json);
    return rc;
}

// --tessera-throughput: run the north-star batched-throughput workload harness
// and exit. No model is loaded in v1; the stub timing path exercises the full
// measurement and receipt pipeline. Returns a process exit code.
static int ts_cli_throughput(const common_tessera_params & tp) {
    ts_throughput_workload workloads[TS_THROUGHPUT_MAX_WORKLOADS];
    int n_workloads = 0;
    std::string err;

    if (ts_throughput_workload_load(tp.throughput_workload.c_str(), workloads,
                                    TS_THROUGHPUT_MAX_WORKLOADS, &n_workloads, &err) != 0) {
        fprintf(stderr, "error: throughput: %s\n", err.c_str());
        return 1;
    }

    std::vector<ts_throughput_result> results(n_workloads);
    // v1: no inference backend wired -> stub timing (stub=true in receipt)
    if (ts_throughput_run(workloads, n_workloads, nullptr, nullptr, results.data(), &err) != 0) {
        fprintf(stderr, "error: throughput: %s\n", err.c_str());
        return 1;
    }

    const std::string out_path = tp.throughput_out.empty()
        ? std::string("tessera-throughput-receipt.json")
        : tp.throughput_out;
    if (ts_throughput_receipt_write(out_path.c_str(), results.data(), n_workloads, &err) != 0) {
        fprintf(stderr, "error: throughput: %s\n", err.c_str());
        return 1;
    }

    // also print to stdout for immediate inspection
    for (const auto & r : results) {
        printf("%-24s regime=%-8s batch=%d seq=%d  %.1f tok/s  mean=%.2fms  p95=%.2fms%s\n",
               r.name, r.regime, r.batch_size, r.seq_len,
               r.tokens_per_sec, r.mean_latency_ms, r.p95_latency_ms,
               r.stub ? "  [stub]" : "");
    }
    printf("receipt: %s\n", out_path.c_str());
    return 0;
}

// --tessera-dataset: prepare drafter training data from spec_calib.v2 JSONL
// and exit. No model needed. Returns a process exit code.
static int ts_cli_dataset(const common_tessera_params & tp) {
    ts_dataset_params dp;
    ts_dataset_default_params(&dp);
    snprintf(dp.input_path,  sizeof(dp.input_path),  "%s", tp.dataset_in.c_str());
    const std::string out = tp.dataset_out.empty()
        ? std::string("tessera-dataset-out.txt")
        : tp.dataset_out;
    snprintf(dp.output_path, sizeof(dp.output_path), "%s", out.c_str());
    if (ts_dataset_mode_from_string(tp.dataset_mode.c_str(), &dp.mode) != 0) {
        fprintf(stderr, "error: dataset: unknown mode '%s' (use text|pairs|lk|dflash)\n",
                tp.dataset_mode.c_str());
        return 1;
    }
    // dflash mode bakes D-PACE weights into each block; reuse the shared
    // --tessera-dpace-alpha / --tessera-dpace-gamma knobs.
    dp.dpace_alpha  = tp.dpace_alpha;
    dp.dflash_gamma = tp.dpace_gamma;
    int n_records = 0;
    int n_skipped = 0;
    std::string err;
    if (ts_dataset_run(&dp, &n_records, &n_skipped, &err) != 0) {
        fprintf(stderr, "error: dataset: %s\n", err.c_str());
        return 1;
    }
    printf("dataset: %d records -> %s (mode=%s, skipped=%d)\n",
           n_records, out.c_str(), tp.dataset_mode.c_str(), n_skipped);
    return 0;
}

// --tessera-dpace: compute D-PACE adaptive position weights from DFlash
// acceptance telemetry and exit. No model needed. Returns a process exit code.
static int ts_cli_dpace(const common_tessera_params & tp) {
    std::ifstream f(tp.dpace_in);
    if (!f) {
        fprintf(stderr, "error: dpace: cannot read: %s\n", tp.dpace_in.c_str());
        return 1;
    }

    const float alpha = tp.dpace_alpha;
    const float gamma = tp.dpace_gamma;

    // Accumulate per-position weight statistics across all telemetry events
    int n_events = 0;
    int max_block = 0;
    std::vector<double> dpace_sum;   // sum of D-PACE weights per position
    std::vector<double> decay_sum;   // sum of decay weights per position
    std::vector<int>    pos_count;   // number of events reaching each position
    double surrogate_sum = 0.0;

    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) {
            continue;
        }
        // Parse llama.tessera.spec.v1 JSONL
        // Expected: {"schema":"llama.tessera.spec.v1", ... , "confidence":[...]}
        auto j = nlohmann::json::parse(line, nullptr, false);
        if (j.is_discarded()) {
            continue;
        }
        if (j.value("schema", "") != "llama.tessera.spec.v1") {
            continue;
        }
        if (!j.contains("confidence") || !j["confidence"].is_array()) {
            continue;
        }

        const auto & conf = j["confidence"];
        const int block_size = (int)conf.size();
        if (block_size <= 0) {
            continue;
        }

        // Grow accumulators if needed
        if (block_size > max_block) {
            dpace_sum.resize(block_size, 0.0);
            decay_sum.resize(block_size, 0.0);
            pos_count.resize(block_size, 0);
            max_block = block_size;
        }

        // Extract per-position acceptance probabilities
        std::vector<float> acc(block_size);
        for (int i = 0; i < block_size; ++i) {
            acc[i] = (float)conf[i].get<double>();
        }

        // Compute D-PACE weights (smoothed, normalized)
        std::vector<double> dw(block_size);
        ts_dpace_weights_smoothed(acc.data(), block_size, alpha, dw.data());
        ts_dpace_normalize_weights(dw.data(), block_size);

        // Compute DFlash decay weights (normalized)
        std::vector<double> fw(block_size);
        ts_dflash_decay_weights(block_size, gamma, fw.data());
        ts_dpace_normalize_weights(fw.data(), block_size);

        for (int i = 0; i < block_size; ++i) {
            dpace_sum[i] += dw[i];
            decay_sum[i] += fw[i];
            pos_count[i]++;
        }
        surrogate_sum += ts_dpace_accepted_length_surrogate(acc.data(), block_size);
        n_events++;
    }

    if (n_events == 0) {
        fprintf(stderr, "error: dpace: no valid llama.tessera.spec.v1 events in %s\n",
                tp.dpace_in.c_str());
        return 1;
    }

    // Build output JSON
    nlohmann::json out;
    out["schema"] = "llama.tessera.dpace.v1";
    out["n_events"] = n_events;
    out["max_block_size"] = max_block;
    out["alpha"] = alpha;
    out["gamma"] = gamma;
    out["mean_surrogate"] = surrogate_sum / n_events;

    nlohmann::json positions = nlohmann::json::array();
    for (int i = 0; i < max_block; ++i) {
        nlohmann::json p;
        p["position"] = i;
        p["count"] = pos_count[i];
        p["dpace_weight"] = pos_count[i] > 0 ? dpace_sum[i] / pos_count[i] : 0.0;
        p["decay_weight"] = pos_count[i] > 0 ? decay_sum[i] / pos_count[i] : 0.0;
        positions.push_back(p);
    }
    out["positions"] = positions;

    // Print summary
    printf("dpace: %d events, max_block=%d, alpha=%.3f, gamma=%.3f\n",
           n_events, max_block, alpha, gamma);
    printf("dpace: mean accepted-length surrogate = %.4f\n", surrogate_sum / n_events);
    printf("dpace: per-position weights (dpace vs decay):\n");
    for (int i = 0; i < max_block && i < 16; ++i) {
        double dw = pos_count[i] > 0 ? dpace_sum[i] / pos_count[i] : 0.0;
        double fw = pos_count[i] > 0 ? decay_sum[i] / pos_count[i] : 0.0;
        printf("  pos %2d: dpace=%.4f  decay=%.4f  ratio=%.3f\n", i, dw, fw,
               fw > 0.0 ? dw / fw : 0.0);
    }

    // Write output file if requested
    if (!tp.dpace_out.empty()) {
        std::ofstream of(tp.dpace_out);
        if (!of) {
            fprintf(stderr, "error: dpace: cannot write: %s\n", tp.dpace_out.c_str());
            return 1;
        }
        of << out.dump(2) << "\n";
        printf("dpace: receipt -> %s\n", tp.dpace_out.c_str());
    }

    return 0;
}

// ---- export-ternary / pack helpers --------------------------------------
//
// The two tile-neutral safetensors subcommands share a small set of GGUF
// reading/writing helpers that mirror the dispatch's patterns but stay
// local to keep the handlers self-contained.

// Best-effort physical-memory estimate in bytes. Used only to print a
// warning when the input GGUF is larger than RAM (the export path streams
// per-tensor via lazy mmap, so it does not need the whole file resident).
// Returns 0 when the host's physmem cannot be determined.
static size_t ts_export_physmem_bytes() {
#if defined(__APPLE__)
    int64_t mem = 0;
    size_t len = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &len, nullptr, 0) == 0 && mem > 0) {
        return (size_t) mem;
    }
#elif defined(_SC_PHYS_PAGES) && defined(_SC_PAGE_SIZE)
    long pages = sysconf(_SC_PHYS_PAGES);
    long psz   = sysconf(_SC_PAGE_SIZE);
    if (pages > 0 && psz > 0) {
        return (size_t) pages * (size_t) psz;
    }
#endif
    return 0;
}

// A 2D/3D weight matrix is exportable when it has a known tensor family
// (attn/ffn/...) and a registered dequant path. Matches ts_is_quantizable
// in tessera-dispatch.cpp; duplicated here so the export path does not
// pull the dispatch's full header surface into quantize.cpp.
static bool ts_export_is_weight(const char * name, enum ggml_type type, int n_dims) {
    if (type == GGML_TYPE_TESSERA_T640) {
        return false;
    }
    if (type != GGML_TYPE_F32 && type != GGML_TYPE_F16) {
        const struct ggml_type_traits * traits = ggml_get_type_traits(type);
        if (!traits || !traits->to_float) {
            return false;
        }
    }
    if (n_dims != 2 && n_dims != 3) {
        return false;
    }
    std::string family = ts_regime_infer_family(name);
    if (family.empty() || family == "other") {
        return false;
    }
    return true;
}

// Convert a ggml tensor's data to a flat F32 buffer via the registered
// dequant path. Returns an empty vector on failure.
static std::vector<float> ts_export_tensor_to_f32(const struct ggml_tensor * t) {
    const int64_t n = ggml_nelements(t);
    std::vector<float> out((size_t) n);
    if (t->data == nullptr) {
        out.clear();
        return out;
    }
    if (t->type == GGML_TYPE_F32) {
        std::memcpy(out.data(), t->data, (size_t) n * sizeof(float));
    } else {
        const struct ggml_type_traits * traits = ggml_get_type_traits(t->type);
        if (traits && traits->to_float) {
            traits->to_float(t->data, out.data(), n);
        } else {
            out.clear();
        }
    }
    return out;
}

// Open a GGUF for reading, mmap it, and patch each tensor's data pointer
// into the mmap'd region (the no_alloc=true path leaves them null). Mirrors
// the dispatch's input-GGUF open so the export handler does not load the
// whole model into RAM. Returns the gguf_context; on failure returns
// nullptr and sets *err. The caller owns *ggml_ctx and must munmap via
// ts_export_munmap.
//
// The mmap is deliberately lazy: MAP_PRIVATE is page-faulted on access, so
// opening a 65 GB GGUF on a 17 GB host does not prefetch anything. We also
// issue POSIX_MADV_RANDOM to tell the kernel we touch pages per-tensor (not
// sequentially), so the pager does not speculatively read ahead. The
// per-tensor fault+evict cycle in ts_cli_export_ternary keeps the resident
// set at roughly one tensor.
struct ts_export_mmap {
    void *  mapped = nullptr;
    size_t  size   = 0;
    size_t  data_off = 0;   // byte offset of the tensor-data section in the file
};

static struct gguf_context * ts_export_open_gguf(const std::string & path,
                                                 struct ggml_context * & ggml_ctx,
                                                 ts_export_mmap & mm,
                                                 std::string & err) {
    ggml_ctx = nullptr;
    struct gguf_init_params gparams = {
        /*no_alloc =*/ true,
        /*ctx      =*/ &ggml_ctx,
    };
    struct gguf_context * ctx = gguf_init_from_file(path.c_str(), gparams);
    if (ctx == nullptr) {
        err = "failed to open input GGUF: " + path;
        return nullptr;
    }

    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        err = "open failed for mmap: " + path;
        gguf_free(ctx);
        ggml_free(ggml_ctx);
        ggml_ctx = nullptr;
        return nullptr;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        err = "fstat failed for mmap";
        close(fd);
        gguf_free(ctx);
        ggml_free(ggml_ctx);
        ggml_ctx = nullptr;
        return nullptr;
    }
    mm.size   = (size_t) st.st_size;
    mm.mapped = mmap(nullptr, mm.size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mm.mapped == MAP_FAILED) {
        mm.mapped = nullptr;
        err = "mmap failed for input GGUF";
        gguf_free(ctx);
        ggml_free(ggml_ctx);
        ggml_ctx = nullptr;
        return nullptr;
    }
    // No prefetch: do NOT call posix_madvise(WILLNEED) and do NOT pass
    // MAP_POPULATE. POSIX_MADV_RANDOM tells the kernel the access pattern is
    // per-tensor (random), disabling readahead that would page in the whole
    // file. Ignore EINVAL on filesystems that do not support the hint.
    (void) posix_madvise(mm.mapped, mm.size, POSIX_MADV_RANDOM);

    mm.data_off = gguf_get_data_offset(ctx);
    const int64_t n_t = gguf_get_n_tensors(ctx);
    for (int64_t i = 0; i < n_t; i++) {
        const char * tname = gguf_get_tensor_name(ctx, i);
        size_t toff = gguf_get_tensor_offset(ctx, i);
        struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, tname);
        if (t) {
            t->data = (char *) mm.mapped + mm.data_off + toff;
        }
    }
    return ctx;
}

// Collect the GGUF KV metadata as string-valued hparams (the safetensors
// config stores them as strings; the pack path re-emits them with the
// matching gguf_set_val_* type). String KVs keep their value; numerics
// are stringified via the json dump. Also writes "general.architecture"
// to *arch when present.
static void ts_export_collect_hparams(struct gguf_context * ctx,
                                      std::string & arch,
                                      std::map<std::string, std::string> & hparams) {
    const int64_t n_kv = gguf_get_n_kv(ctx);
    for (int64_t i = 0; i < n_kv; i++) {
        const char * key = gguf_get_key(ctx, i);
        if (key == nullptr) continue;
        const gguf_type t = gguf_get_kv_type(ctx, i);
        std::string val;
        switch (t) {
            case GGUF_TYPE_STRING:
                val = gguf_get_val_str(ctx, i) ? gguf_get_val_str(ctx, i) : "";
                break;
            case GGUF_TYPE_UINT8:   val = std::to_string((uint32_t) gguf_get_val_u8(ctx, i));  break;
            case GGUF_TYPE_INT8:    val = std::to_string((int32_t)  gguf_get_val_i8(ctx, i));   break;
            case GGUF_TYPE_UINT16:  val = std::to_string((uint32_t) gguf_get_val_u16(ctx, i)); break;
            case GGUF_TYPE_INT16:   val = std::to_string((int32_t)  gguf_get_val_i16(ctx, i));  break;
            case GGUF_TYPE_UINT32:  val = std::to_string(gguf_get_val_u32(ctx, i)); break;
            case GGUF_TYPE_INT32:   val = std::to_string(gguf_get_val_i32(ctx, i)); break;
            case GGUF_TYPE_UINT64:  val = std::to_string(gguf_get_val_u64(ctx, i)); break;
            case GGUF_TYPE_INT64:   val = std::to_string(gguf_get_val_i64(ctx, i)); break;
            case GGUF_TYPE_FLOAT32: val = std::to_string(gguf_get_val_f32(ctx, i)); break;
            case GGUF_TYPE_FLOAT64: val = std::to_string(gguf_get_val_f64(ctx, i)); break;
            case GGUF_TYPE_BOOL:    val = gguf_get_val_bool(ctx, i) ? "true" : "false"; break;
            default: continue;  // arrays are not hparams
        }
        hparams[key] = std::move(val);
        if (std::string(key) == "general.architecture") {
            arch = hparams[key];
        }
    }
}

// Write a string-valued hparam back into a gguf_context using the type
// hint recovered by the value's shape: numeric strings go back as the
// narrowest matching integer/float type; "true"/"false" as bool; anything
// else as a string. This preserves the round-trip for the pack path.
static void ts_pack_set_hparam(struct gguf_context * ctx,
                               const std::string & key,
                               const std::string & val) {
    if (val == "true" || val == "false") {
        gguf_set_val_bool(ctx, key.c_str(), val == "true");
        return;
    }
    // integer?
    {
        char * end = nullptr;
        errno = 0;
        long long iv = std::strtoll(val.c_str(), &end, 10);
        if (end != val.c_str() && *end == '\0' && errno == 0) {
            if (iv >= INT32_MIN && iv <= INT32_MAX) {
                gguf_set_val_i32(ctx, key.c_str(), (int32_t) iv);
            } else {
                gguf_set_val_i64(ctx, key.c_str(), (int64_t) iv);
            }
            return;
        }
    }
    // float?
    {
        char * end = nullptr;
        std::strtod(val.c_str(), &end);
        if (end != val.c_str() && *end == '\0') {
            gguf_set_val_f32(ctx, key.c_str(), (float) std::strtod(val.c_str(), nullptr));
            return;
        }
    }
    gguf_set_val_str(ctx, key.c_str(), val.c_str());
}

// export-ternary: read a BF16 GGUF, quantize each 2D weight to tile-agnostic
// ternary via ts_quantize_2d_ternary, write a tile-neutral safetensors
// directory via ts_write_ttt_stream. The export runs the AWQ alpha search
// per tensor (using the imatrix when supplied) and emits the trits + CSR
// outliers + AWQ scales + clipped core that the client-side packer
// consumes. Tokenizer + chat template travel in the safetensors directory;
// the GGUF KV metadata travels in config.json::hparams.
//
// Memory model: the source GGUF is mmap'd lazily (no prefetch) and processed
// one tensor at a time. Before dequantizing a tensor we hint
// POSIX_MADV_WILLNEED on its byte range so the kernel pages it in; after the
// tensor's last expert is quantized we hint POSIX_MADV_DONTNEED so the
// kernel can evict those pages, keeping the resident set at roughly one
// tensor. The ternary writer streams each tensor's arrays to a sibling spool
// file before the next tensor is read, so RSS is bounded by one tensor's
// worth of trits + core + the source GGUF's pages for that one tensor.
static int ts_cli_export_ternary(const common_tessera_params & tp) {
    if (tp.export_in.empty()) {
        fprintf(stderr, "error: `export-ternary` subcommand requires --in PATH\n");
        return 1;
    }
    if (tp.export_out.empty()) {
        fprintf(stderr, "error: `export-ternary` subcommand requires --out PATH\n");
        return 1;
    }

    // optional imatrix for the AWQ alpha search
    ts_imatrix imatrix;
    bool have_imatrix = false;
    if (!tp.imatrix.empty()) {
        std::string ierr;
        const std::string & p = tp.imatrix;
        bool ok = false;
        if (p.size() >= 5 && p.substr(p.size() - 5) == ".gguf") {
            ok = ts_imatrix_load_gguf(p.c_str(), &imatrix, &ierr) == 0;
        } else {
            ok = ts_imatrix_load_npz(p.c_str(), &imatrix, &ierr) == 0;
        }
        if (!ok) {
            fprintf(stderr, "error: export-ternary: --imatrix: %s\n", ierr.c_str());
            return 1;
        }
        have_imatrix = !imatrix.data.empty();
    }

    // open + mmap the source GGUF. ts_export_open_gguf uses a lazy MAP_PRIVATE
    // mmap (no prefetch, POSIX_MADV_RANDOM) so opening a 65 GB file on a 17 GB
    // host does not page anything in until a tensor is touched.
    struct ggml_context * ggml_ctx = nullptr;
    ts_export_mmap mm;
    std::string err;
    struct gguf_context * in_ctx = ts_export_open_gguf(tp.export_in, ggml_ctx, mm, err);
    if (in_ctx == nullptr) {
        fprintf(stderr, "error: export-ternary: %s\n", err.c_str());
        return 1;
    }

    // Memory precheck: warn (but continue) when the input file is larger than
    // physmem. The export path streams per-tensor via the lazy mmap, so this
    // is recoverable as long as the host is not also tight on disk for the
    // spool. Refusing to start would block the only path that can actually
    // process such a model on a memory-constrained host.
    {
        const size_t phys = ts_export_physmem_bytes();
        if (phys > 0 && mm.size > phys) {
            fprintf(stderr,
                    "export-ternary: warning: input %.2f GiB > physmem %.2f GiB; "
                    "streaming per-tensor (lazy mmap + page eviction)\n",
                    (double) mm.size / (1024.0 * 1024.0 * 1024.0),
                    (double) phys    / (1024.0 * 1024.0 * 1024.0));
        }
    }

    std::string arch;
    std::map<std::string, std::string> hparams;
    ts_export_collect_hparams(in_ctx, arch, hparams);
    if (arch.empty()) {
        arch = "llama";
    }

    const int64_t n_tensors = gguf_get_n_tensors(in_ctx);
    printf("export-ternary: %s (%lld tensors) -> %s\n",
           tp.export_in.c_str(), (long long) n_tensors, tp.export_out.c_str());

    // tokenizer.json + chat_template.jinja: the source GGUF embeds the
    // tokenizer as KV pairs (not a standalone file). We carry the chat
    // template out to chat_template.jinja when present so the pack path
    // and downstream tooling can read it directly; the full tokenizer KV
    // travels in config.json::hparams and is re-embedded on pack. The
    // template is staged to a sibling temp file (outside the output dir)
    // so the writer copies it into the destination without colliding with
    // its own output path. Resolved before the streaming pass so the writer
    // gets the paths up front.
    std::string tokenizer_path;
    std::string chat_template_path;
    {
        int64_t kchat = gguf_find_key(in_ctx, "tokenizer.chat_template");
        if (kchat >= 0 && gguf_get_kv_type(in_ctx, kchat) == GGUF_TYPE_STRING) {
            const char * tmpl = gguf_get_val_str(in_ctx, kchat);
            if (tmpl && tmpl[0] != '\0') {
                const std::string tmp_chat =
                    std::filesystem::temp_directory_path().string() + "/ts_export_chat.tmpl";
                std::ofstream of(tmp_chat, std::ios::binary | std::ios::trunc);
                if (of) {
                    of << tmpl;
                    of.close();
                    chat_template_path = tmp_chat;
                }
            }
        }
    }

    // quantize each 2D weight via ts_quantize_2d_ternary. 3D MoE experts
    // are exported as one ternary tensor per expert (flattened name suffix
    // .E<j>), matching the dispatch's per-expert quantize convention.
    ts_quant_params_2d qp{};
    qp.alpha          = 0.0f;   // auto-search
    qp.clip           = 1.0f;
    qp.max_outliers   = 0;
    qp.outlier_thresh = tp.outlier_frac;
    qp.use_imatrix    = false;
    qp.use_septq      = false;
    qp.awq_grid       = 20;

    // Streaming source state: the source lambda is called once per exported
    // (sub)tensor and advances through the GGUF. `cur_*` cache the current
    // source tensor so a 3D MoE weight yields one call per expert without
    // re-dequantizing. `full` holds the dequantized F32 buffer for the
    // current tensor and is cleared (and its mmap pages evicted) once all
    // experts are emitted.
    int64_t n_exported = 0;
    int64_t n_skipped  = 0;
    int64_t gguf_idx   = 0;
    int64_t expert_idx = 0;
    int64_t n_experts  = 0;
    int64_t in_dim     = 0;
    int64_t out_dim    = 0;
    int     n_dims     = 0;
    const float * act_scales = nullptr;
    std::string cur_name;
    std::vector<float> full;
    struct ggml_tensor * cur_t = nullptr;

    // Drop residence for the current source tensor's mmap range. Called once
    // the last expert has been quantized so the next tensor's pages can
    // reuse the memory. madvise DONTNEED is a hint; on macOS it instructs
    // the pager to drop the (clean, read-only) pages.
    auto evict_current = [&]() {
        if (cur_t && cur_t->data && mm.mapped) {
            const size_t nbytes = ggml_nbytes(cur_t);
            (void) posix_madvise(cur_t->data, nbytes, POSIX_MADV_DONTNEED);
        }
    };

    // Advance to the next exportable GGUF tensor and dequantize it into
    // `full`. Returns true if a tensor was loaded, false at end-of-stream
    // (or on a fatal dequant error). Skips non-weight tensors with a
    // warning count. Issues WILLNEED before the dequant so the kernel pages
    // the tensor in proactively rather than on the first byte read.
    auto load_next_tensor = [&]() -> bool {
        full.clear();
        full.shrink_to_fit();
        cur_t = nullptr;
        cur_name.clear();
        act_scales = nullptr;
        n_experts  = 0;
        expert_idx = 0;
        while (gguf_idx < n_tensors) {
            const int64_t i = gguf_idx++;
            const char * name = gguf_get_tensor_name(in_ctx, i);
            const enum ggml_type type = gguf_get_tensor_type(in_ctx, i);
            const int64_t * ne = gguf_get_tensor_ne(in_ctx, i);
            int nd = GGML_MAX_DIMS;
            while (nd > 1 && ne[nd - 1] == 1) {
                nd--;
            }
            if (!ts_export_is_weight(name, type, nd)) {
                n_skipped++;
                continue;
            }
            struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, name);
            if (t == nullptr) {
                fprintf(stderr, "export-ternary: warning: '%s' not in ggml ctx, skipping\n", name);
                n_skipped++;
                continue;
            }

            // Hint the pager that we are about to read this tensor's pages.
            // The mmap was created without WILLNEED/MAP_POPULATE, so without
            // this hint the first dequant byte read would fault each page in
            // on demand; WILLNEED lets the kernel start the readahead for
            // just this tensor's byte range in parallel.
            if (t->data) {
                (void) posix_madvise(t->data, ggml_nbytes(t), POSIX_MADV_WILLNEED);
            }

            std::vector<float> dequant = ts_export_tensor_to_f32(t);
            if (dequant.empty()) {
                fprintf(stderr, "export-ternary: warning: unsupported type for '%s', skipping\n", name);
                n_skipped++;
                // Evict the pages we just hinted in for this unusable tensor.
                if (t->data) {
                    (void) posix_madvise(t->data, ggml_nbytes(t), POSIX_MADV_DONTNEED);
                }
                continue;
            }

            cur_t     = t;
            cur_name  = name;
            n_dims    = nd;
            in_dim    = ne[0];
            out_dim   = ne[1];
            n_experts = (n_dims == 3) ? ne[2] : 1;
            expert_idx = 0;
            full = std::move(dequant);

            if (have_imatrix) {
                int64_t act_n = 0;
                act_scales = ts_imatrix_lookup(&imatrix, name, &act_n);
                if (act_scales != nullptr && act_n != in_dim) {
                    act_scales = nullptr;
                }
            }
            return true;
        }
        return false;
    };

    ts_ttt_tensor_source source = [&](ts_ternary_tensor & tensor) -> std::string {
        for (;;) {
            if (expert_idx < n_experts) {
                const int64_t per = out_dim * in_dim;
                const float * wptr = full.data() + (int64_t)(expert_idx * per);
                std::vector<float> expert_weights;
                if (n_dims == 3) {
                    // per-expert slice needs contiguous storage independent of `full`
                    expert_weights.assign(wptr, wptr + per);
                    wptr = expert_weights.data();
                }

                std::string tname = cur_name;
                if (n_dims == 3) {
                    tname += ".E" + std::to_string(expert_idx);
                }

                expert_idx++;

                ts_ternary_tensor tn;
                int rc = ts_quantize_2d_ternary(wptr, act_scales,
                                                nullptr, nullptr, nullptr,
                                                out_dim, in_dim, 0,
                                                &qp, &tn);
                if (rc != 0) {
                    fprintf(stderr, "export-ternary: warning: quantize failed for '%s', skipping\n",
                            tname.c_str());
                    n_skipped++;
                    continue;
                }
                n_exported++;
                tensor = std::move(tn);
                return tname;
            }
            // Done with the current source tensor's experts: drop its pages
            // so the next tensor can reuse the memory, then advance.
            evict_current();
            if (!load_next_tensor()) {
                return std::string();
            }
        }
    };

    int rc = ts_write_ttt_stream(source, arch, hparams,
                                 tp.export_out, tokenizer_path, chat_template_path);
    // Drain the source so the export/skip tallies are accurate even when the
    // writer returns early on error (the source may not have been fully
    // consumed). The writer's spool is already removed by ts_write_ttt_stream
    // on both success and failure; draining only advances the GGUF iteration
    // and does not allocate (each yielded tensor is overwritten on the next
    // call and dropped at scope exit).
    if (rc != 0) {
        ts_ternary_tensor drain;
        while (!source(drain).empty()) { /* discard */ }
    }

    printf("export-ternary: %lld tensors exported, %lld skipped\n",
           (long long) n_exported, (long long) n_skipped);

    if (rc != 0) {
        fprintf(stderr, "error: export-ternary: ts_write_ttt_stream failed (rc=%d)\n", rc);
    } else {
        printf("export-ternary: wrote %s\n", tp.export_out.c_str());
    }

    if (!chat_template_path.empty()) {
        std::remove(chat_template_path.c_str());
    }
    if (mm.mapped) munmap(mm.mapped, mm.size);
    gguf_free(in_ctx);
    ggml_free(ggml_ctx);
    return rc;
}

// pack: read a tile-neutral safetensors directory, pack each tensor to the
// target tile geometry via ts_pack_ternary_to_tile, write a GGUF. Streams
// one tensor at a time (ts_ttt_tensor_stream) so RSS is bounded by one
// tensor regardless of model size. The GGUF header is rebuilt from the
// safetensors config.json hparams; the 5 sub-tensors per weight come from
// ts_gguf_write_tensor_cluster.
static int ts_cli_pack(const common_tessera_params & tp) {
    if (tp.pack_in.empty()) {
        fprintf(stderr, "error: `pack` subcommand requires --in PATH\n");
        return 1;
    }
    if (tp.pack_out.empty()) {
        fprintf(stderr, "error: `pack` subcommand requires --out PATH\n");
        return 1;
    }

    // resolve the target tile geometry
    std::string tile = tp.pack_tile;
    if (tile.empty()) {
        tile = "auto";
    }
    struct ts_tile_config config;
    bool auto_detect = false;
    if (tile == "t640") {
        config = ts_tile_config_t640();
    } else if (tile == "t512") {
        config = ts_tile_config_t512();
    } else if (tile == "t1024") {
        config = ts_tile_config_t1024();
    } else if (tile == "auto") {
        config = ts_detect_tile_config();
        auto_detect = true;
    } else {
        fprintf(stderr, "error: pack: --tile must be one of t640|t512|t1024|auto, got '%s'\n",
                tile.c_str());
        return 1;
    }
    printf("pack: tile geometry = %s (%dx%d, %s)\n",
           auto_detect ? "auto" : tile.c_str(),
           config.page_size, config.lane_size,
           config.packing == TS_PACK_RADIX243 ? "radix-243" : "2-bit");

    // open the safetensors directory for streaming
    ts_ttt_tensor_stream stream;
    if (stream.open(tp.pack_in) != 0) {
        fprintf(stderr, "error: pack: cannot open safetensors directory: %s\n", tp.pack_in.c_str());
        return 1;
    }

    // output GGUF: build the header from the safetensors hparams, then
    // stream each tensor through the packer and append its 5 sub-tensors.
    struct gguf_context * out_ctx = gguf_init_empty();
    for (const auto & kv : stream.hparams()) {
        ts_pack_set_hparam(out_ctx, kv.first, kv.second);
    }

    // tessera provenance + tile-geometry stamp so the loader knows which
    // packer produced this GGUF.
    gguf_set_val_u32(out_ctx, "tessera.version", 1);
    gguf_set_val_str(out_ctx, "tessera.tile.geometry",
                     tile == "auto" ? "auto" : tile.c_str());
    {
        ts_gguf_writer_params wparams{};
        wparams.alpha = 0.0f;   // already-searched; the ternary carries best_alpha
        wparams.clip  = 1.0f;
        wparams.outlier_frac = tp.outlier_frac;
        const char * commit = llama_commit();
        wparams.build_info = std::string("tessera-pack @ ") + (commit ? commit : "unknown");
        ts_gguf_write_metadata(out_ctx, &wparams);
    }

    // ggml context for the transient cluster descriptors. Size generously:
    // each tensor emits up to 7 descriptors; we free them per-tensor below.
    struct ggml_init_params out_init = {
        /*mem_size =*/ (size_t) 7 * 512 + 64 * 1024,
        /*mem_buffer =*/ nullptr,
        /*no_alloc =*/ true,
    };
    struct ggml_context * out_ggml_ctx = ggml_init(out_init);
    if (out_ggml_ctx == nullptr) {
        fprintf(stderr, "error: pack: ggml_init failed for output tensor context\n");
        gguf_free(out_ctx);
        return 1;
    }

    // The pack results back the GGUF tensor descriptors by data pointer and
    // must outlive gguf_write_to_file. Keep them in a function-scope deque
    // (stable element addresses) until the write completes.
    std::deque<ts_quant_result_2d> packed_results;

    int64_t n_packed = 0;
    ts_ternary_tensor tn;
    std::string name;
    while (!(name = stream.next(tn)).empty()) {
        packed_results.emplace_back();
        ts_quant_result_2d & qr = packed_results.back();
        int rc = ts_pack_ternary_to_tile(tn, config, &qr);
        if (rc != 0) {
            fprintf(stderr, "error: pack: ts_pack_ternary_to_tile failed for '%s' (rc=%d)\n",
                    name.c_str(), rc);
            packed_results.pop_back();
            gguf_free(out_ctx);
            ggml_free(out_ggml_ctx);
            return 1;
        }
        ts_gguf_write_tensor_cluster(out_ctx, out_ggml_ctx, name.c_str(), &qr,
                                     tn.out_dim, tn.in_dim);
        // The cluster descriptors are copied by value into out_ctx; the
        // ggml context pool is reset for the next tensor. The result
        // buffer stays alive in the deque for the eventual write.
        ggml_free(out_ggml_ctx);
        out_ggml_ctx = ggml_init(out_init);
        if (out_ggml_ctx == nullptr) {
            fprintf(stderr, "error: pack: ggml_init re-init failed\n");
            gguf_free(out_ctx);
            return 1;
        }
        n_packed++;
    }
    stream.close();

    printf("pack: %lld tensors packed -> %s\n",
           (long long) n_packed, tp.pack_out.c_str());

    bool ok = gguf_write_to_file(out_ctx, tp.pack_out.c_str(), false);
    if (!ok) {
        fprintf(stderr, "error: pack: gguf_write_to_file failed for %s\n",
                tp.pack_out.c_str());
        ggml_free(out_ggml_ctx);
        gguf_free(out_ctx);
        return 1;
    }

    ggml_free(out_ggml_ctx);
    gguf_free(out_ctx);
    return 0;
}

// --tessera-unified-writer: write a gemma4-assistant GGUF from 4+ per-component
// GGUFs + a per-tensor calibration policy. Phase 16. No model loading runs;
// the writer opens each source GGUF, copies the tensors (with optional
// qtype overrides from the policy), and emits a single gemma4-assistant
// GGUF. Returns a process exit code.
//
// CLI:
//   llama-tessera unified-writer \
//       --out <dest.gguf> \
//       --arch gemma4-assistant \
//       --policy <policy.json> \
//       --hparams <hparams.json> \
//       --trunk <trunk.gguf> \
//       --dflash <dflash.gguf> \
//       --dspark <dspark.gguf> \
//       --mtp <mtp.gguf> \
//       --shared-embd <embd.gguf>
//
// At least one --{component} flag is required. The hparams JSON is the
// gemma4-assistant block_count / embedding_length / etc. that the loader
// reads in src/models/gemma4-assistant.cpp:41-60. The policy JSON mirrors
// unified_calibrate.py's tensor_families output.
static int ts_cli_unified_writer(const common_tessera_params & tp) {
    if (tp.unified_out.empty()) {
        fprintf(stderr, "error: `unified-writer` subcommand requires --out PATH\n");
        return 1;
    }
    if (tp.unified_arch != "gemma4-assistant") {
        fprintf(stderr, "error: `unified-writer` only supports --arch gemma4-assistant; got '%s'\n",
                tp.unified_arch.c_str());
        return 1;
    }

    // Build the components list from the supplied --{component} flags.
    // At least one must be set; the writer does not require all five.
    std::vector<ts_unified_component> components;
    auto add_component = [&](const std::string & path, const std::string & role) {
        if (path.empty()) return;
        if (!std::ifstream(path)) {
            fprintf(stderr, "error: --%s: file not found: %s\n", role.c_str(), path.c_str());
            // Non-fatal: continue with the other components. The
            // writer's open_source will catch missing files.
        }
        ts_unified_component c;
        c.path = path;
        c.model_role = role;
        components.push_back(std::move(c));
    };
    add_component(tp.unified_trunk,        "trunk");
    add_component(tp.unified_dflash,       "dflash");
    add_component(tp.unified_dspark,       "dspark");
    add_component(tp.unified_mtp,          "mtp_nextn");
    add_component(tp.unified_shared_embd,  "shared_embd");
    // Phase M0a: multimodal-projector components. The order is
    // significant for shared mm.* names (first writer wins; the
    // convention is vision_tower before mm_projector so the
    // mm_projector's authored data is the canonical one).
    add_component(tp.unified_vision_tower, "vision_tower");
    add_component(tp.unified_audio_tower,  "audio_tower");
    add_component(tp.unified_mm_projector, "mm_projector");
    // unified-tts: the qwen3-tts talker + code2wav vocoder. The writer
    // prefix-routes their tensors (tts.* / tts.c2w.*) and sidecar-copies
    // each source's KV namespace under the same prefix.
    add_component(tp.unified_tts_talker,   "tts_talker");
    add_component(tp.unified_tts_code2wav, "tts_code2wav");
    if (components.empty()) {
        fprintf(stderr, "error: `unified-writer` requires at least one --{trunk,dflash,dspark,mtp,shared-embd,vision-tower,audio-tower,mm-projector,tts-talker,tts-code2wav} flag\n");
        return 1;
    }

    // Load the per-tensor calibration policy from --policy (sidecar
    // JSON) and, when --tessera-db is also set, merge in the DB's
    // per-(model_hash, model_role, name) tensor_stats rows. The DB
    // overrides the sidecar on collision (the DB is the production
    // data source; the sidecar is a debugging affordance).
    ts_unified_policy policy;
    if (!tp.unified_policy.empty()) {
        std::string err;
        if (ts_unified_policy_load_json(tp.unified_policy, &policy, &err) != 0) {
            fprintf(stderr, "error: --policy: %s\n", err.c_str());
            return 1;
        }
    }
    if (!tp.tessera_db.empty()) {
        // The dispatch's tessera_db is the production data source.
        // We need a model_hash to read the per-(model_hash,
        // model_role, name) rows. The convention is the SHA256 of
        // the trunk GGUF (the same hash the dispatch uses for the
        // ga-prep walk's warm-start). When the trunk is not
        // supplied, fall back to "dispatch-default".
        std::string model_hash = "dispatch-default";
        if (!tp.unified_trunk.empty()) {
            model_hash = ts_tessera_db_hash_gguf(tp.unified_trunk);
            if (model_hash.empty()) {
                fprintf(stderr, "error: --tessera-db: failed to hash trunk GGUF for model_hash lookup\n");
                return 1;
            }
        }
        std::string err;
        ts_tessera_db * db = ts_tessera_db_open(tp.tessera_db, &err);
        if (db == nullptr) {
            fprintf(stderr, "error: --tessera-db: %s\n", err.c_str());
            return 1;
        }
        ts_tessera_db_unified_policy db_policy;
        if (ts_tessera_db_read_unified_policy(db, model_hash, "", &db_policy, &err) != 0) {
            fprintf(stderr, "error: --tessera-db: %s\n", err.c_str());
            delete db;
            return 1;
        }
        // DB overrides sidecar on collision: walk the DB rows and
        // replace the sidecar's matching (model_role, name) entry.
        for (const auto & db_e : db_policy.entries) {
            bool replaced = false;
            for (auto & s_e : policy.entries) {
                if (s_e.model_role == db_e.model_role && s_e.name == db_e.name) {
                    s_e.dtype = db_e.dtype;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                ts_unified_policy_entry e;
                e.model_role = db_e.model_role;
                e.name       = db_e.name;
                e.dtype      = db_e.dtype;
                policy.entries.push_back(std::move(e));
            }
        }
        delete db;
    }

    // Load the hparams. When --hparams is empty, fall back to a
    // minimal "n_layer = 0" default; the writer rejects that with a
    // clear error.
    ts_unified_hparams hparams;
    if (!tp.unified_hparams.empty()) {
        std::ifstream f(tp.unified_hparams);
        if (!f) {
            fprintf(stderr, "error: --hparams: cannot read: %s\n", tp.unified_hparams.c_str());
            return 1;
        }
        nlohmann::json j;
        try {
            f >> j;
        } catch (const std::exception & e) {
            fprintf(stderr, "error: --hparams: parse error: %s\n", e.what());
            return 1;
        }
        // JSON key names match the writer's struct field names.
        // The writer uses snake_case internally but the hparams
        // file uses the gemma4 arch's canonical names (camelCase)
        // so the same JSON can be authored from the legacy
        // meta-sidecar tools.
        auto get_u = [&](const char * k) -> uint32_t {
            return j.contains(k) ? j[k].get<uint32_t>() : 0;
        };
        hparams.n_layer               = get_u("n_layer");
        hparams.n_embd                = get_u("n_embd");
        hparams.n_head                = get_u("n_head");
        hparams.n_head_kv             = get_u("n_head_kv");
        hparams.n_embd_head_k         = get_u("n_embd_head_k");
        hparams.n_embd_head_v         = get_u("n_embd_head_v");
        hparams.n_embd_head_k_swa     = get_u("n_embd_head_k_swa");
        hparams.n_embd_head_v_swa     = get_u("n_embd_head_v_swa");
        hparams.n_ff                  = get_u("n_ff");
        hparams.n_vocab               = get_u("n_vocab");
        hparams.n_embd_out            = get_u("n_embd_out");
        hparams.n_swa                 = get_u("n_swa");
        hparams.n_kv_shared_layers    = get_u("n_kv_shared_layers");
        if (j.contains("rope_freq_base_train_swa")) {
            hparams.rope_freq_base_train_swa = j["rope_freq_base_train_swa"].get<float>();
        }
        if (j.contains("f_norm_rms_eps")) {
            hparams.f_norm_rms_eps = j["f_norm_rms_eps"].get<float>();
        }
        if (j.contains("is_swa_impl") && j["is_swa_impl"].is_array()) {
            for (const auto & v : j["is_swa_impl"]) {
                hparams.is_swa_impl.push_back(v.get<uint8_t>());
            }
        }
    }
    if (hparams.n_layer == 0) {
        fprintf(stderr, "error: --hparams: n_layer must be > 0 (use a --hparams JSON with at least n_layer set)\n");
        return 1;
    }

    // DFlash / DSpark hparams (optional). The writer does not
    // strictly need them; they are emitted as auxiliary KV pairs
    // when non-zero. The CLI uses zero defaults for now.
    ts_unified_dflash_hparams dflash_hp{};
    ts_unified_dspark_hparams dspark_hp{};

    // Phase M0a: mmproj hparams (optional). When --mmproj-hparams is
    // empty, the writer uses zero defaults and the destination's
    // loader treats the absence of gemma4-assistant.vision.* /
    // .audio.* / .mm.* KV keys as "no mmproj in this GGUF" (the
    // pre-M0a contract). The JSON shape mirrors the C++ struct
    // field names; vision_arch / audio_arch are plain strings.
    ts_unified_mmproj_hparams mmproj_hp{};
    if (!tp.unified_mmproj_hparams.empty()) {
        std::ifstream f(tp.unified_mmproj_hparams);
        if (!f) {
            fprintf(stderr, "error: --mmproj-hparams: cannot read: %s\n", tp.unified_mmproj_hparams.c_str());
            return 1;
        }
        nlohmann::json j;
        try {
            f >> j;
        } catch (const std::exception & e) {
            fprintf(stderr, "error: --mmproj-hparams: parse error: %s\n", e.what());
            return 1;
        }
        auto get_i = [&](const char * k) -> int32_t {
            return j.contains(k) ? j[k].get<int32_t>() : 0;
        };
        mmproj_hp.vision_n_embd = get_i("vision_n_embd");
        mmproj_hp.audio_n_embd  = get_i("audio_n_embd");
        mmproj_hp.projector_dim = get_i("projector_dim");
        if (j.contains("vision_arch")) mmproj_hp.vision_arch = j["vision_arch"].get<std::string>();
        if (j.contains("audio_arch"))  mmproj_hp.audio_arch  = j["audio_arch"].get<std::string>();
    }

    // Tessera provenance: best-effort. The build info is the
    // llama-tessera commit + build-info; the main_tip is a TODO
    // (we'd need to read the .git/HEAD on the user's filesystem).
    ts_unified_meta meta;
    const char * commit = llama_commit();
    meta.build_info = std::string("tessera-unified-writer @ ") + (commit ? commit : "unknown");
    meta.main_tip   = "";   // TODO: read from .git/HEAD when available

    // Construct the writer and emit the unified GGUF.
    std::string err;
    ts_unified_writer w(tp.unified_out, components, policy,
                         hparams, dflash_hp, dspark_hp, mmproj_hp, meta, &err);
    if (!err.empty()) {
        fprintf(stderr, "error: unified-writer: %s\n", err.c_str());
        return 1;
    }
    int rc = w.write_all(&err);
    if (rc != 0) {
        fprintf(stderr, "error: unified-writer: write_all: %s\n", err.c_str());
        return rc;
    }
    const auto & s = w.get_stats();
    printf("unified-writer: %s -> %s\n", tp.unified_out.c_str(),
           "ok");
    // Per-role tensor counts (plan 1.2: the stats struct carries a
    // role -> count map, so role additions do not touch this summary).
    // std::map iterates in sorted role order; the output is stable.
    printf("  tensors by role:\n");
    for (const auto & kv : s.n_tensors_by_role) {
        printf("    %-14s %d\n", kv.first.c_str(), kv.second);
    }
    if (s.n_kv_copied > 0) {
        printf("  tts KV sidecar keys: %d\n", s.n_kv_copied);
    }
    printf("  qtype overrides: %d (per-tensor calibration policy)\n",
           s.n_qtype_overrides);
    if (s.n_budget_relaxed > 0 || s.n_budget_enforced > 0) {
        printf("  budget cross-role: %d relaxed, %d enforced "
               "(see tessera.unified.budget_events)\n",
               s.n_budget_relaxed, s.n_budget_enforced);
    }
    printf("  total bytes: %lld\n", (long long)s.total_bytes);
    return 0;
}

int llama_quantize(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");
    if (argc < 3) {
        usage(argv[0]);
    }

    llama_model_quantize_params params = llama_model_quantize_default_params();

    int arg_idx = 1;
    std::string imatrix_file;
    std::vector<std::string> included_weights, excluded_weights;
    std::vector<llama_model_kv_override> kv_overrides;
    std::vector<tensor_type_option> tensor_type_opts;
    std::vector<int> prune_layers;
    // Neutral-prior blending is opt-in only: prior_weight defaults to 0.0f so the
    // (sum + prior_weight) / (count + prior_weight) formula is an exact no-op
    // unless --prior-weight is explicitly provided. (The upstream branch defaults
    // to 1.0f and applies it unconditionally, which silently changes default
    // quantization; that was reverted there and we keep it opt-in here.)
    float prior_weight     = 0.0f;
    bool  prior_weight_set = false;
    bool use_tessera = false;
    std::string model_input;  // --model/-m value (kept for the flag-based CLI)

    for (; arg_idx < argc && strncmp(argv[arg_idx], "--", 2) == 0; arg_idx++) {
        if (strcmp(argv[arg_idx], "--model") == 0 || strcmp(argv[arg_idx], "-m") == 0) {
            if (arg_idx < argc-1) {
                model_input = argv[++arg_idx];
            }
        } else if (strcmp(argv[arg_idx], "--leave-output-tensor") == 0) {
            params.quantize_output_tensor = false;
        } else if (strcmp(argv[arg_idx], "--output-tensor-type") == 0) {
            if (arg_idx < argc-1) {
                params.output_tensor_type = parse_ggml_type(argv[++arg_idx]);
                if (params.output_tensor_type == GGML_TYPE_COUNT) {
                    usage(argv[0]);
                }
            } else {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--token-embedding-type") == 0) {
            if (arg_idx < argc-1) {
                params.token_embedding_type = parse_ggml_type(argv[++arg_idx]);
                if (params.token_embedding_type == GGML_TYPE_COUNT) {
                    usage(argv[0]);
                }
            } else {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--tensor-type") == 0) {
            if (arg_idx == argc-1 || !parse_tensor_type(argv[++arg_idx], tensor_type_opts)) {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--tensor-type-file") == 0) {
            if (arg_idx == argc-1 || !parse_tensor_type_file(argv[++arg_idx], tensor_type_opts)) {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--prune-layers") == 0) {
            if (arg_idx == argc-1 || !parse_layer_prune(argv[++arg_idx], prune_layers)) {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--override-kv") == 0) {
            if (arg_idx == argc-1 || !string_parse_kv_override(argv[++arg_idx], kv_overrides)) {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--dry-run") == 0) {
            params.dry_run = true;
        } else if (strcmp(argv[arg_idx], "--allow-requantize") == 0) {
            params.allow_requantize = true;
        } else if (strcmp(argv[arg_idx], "--pure") == 0) {
            params.pure = true;
        } else if (strcmp(argv[arg_idx], "--imatrix") == 0) {
            if (arg_idx < argc-1) {
                imatrix_file = argv[++arg_idx];
            } else {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--imatrix-scope") == 0) {
            if (arg_idx < argc-1) {
                const std::string s = argv[++arg_idx];
                if (s == "verifier") {
                    params.imatrix_scope = LLAMA_OBSERVER_SCOPE_VERIFIER;
                } else if (s == "mtp") {
                    params.imatrix_scope = LLAMA_OBSERVER_SCOPE_MTP;
                } else if (s == "dflash") {
                    params.imatrix_scope = LLAMA_OBSERVER_SCOPE_DFLASH;
                } else if (s == "dspark") {
                    params.imatrix_scope = LLAMA_OBSERVER_SCOPE_DSPARK;
                } else if (s == "talker") {
                    params.imatrix_scope = LLAMA_OBSERVER_SCOPE_TALKER;
                } else {
                    fprintf(stderr, "error: unknown --imatrix-scope '%s' (use verifier|mtp|dflash|dspark|talker)\n", s.c_str());
                    usage(argv[0]);
                }
            } else {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--include-weights") == 0) {
            if (arg_idx < argc-1) {
                included_weights.emplace_back(argv[++arg_idx]);
            } else {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--exclude-weights") == 0) {
            if (arg_idx < argc-1) {
                excluded_weights.emplace_back(argv[++arg_idx]);
            } else {
                usage(argv[0]);
            }
        } else if (strcmp(argv[arg_idx], "--keep-split") == 0) {
            params.keep_split = true;
        } else if (strcmp(argv[arg_idx], "--prior-weight") == 0) {
            if (arg_idx < argc-1) {
                try {
                    prior_weight = std::stof(argv[++arg_idx]);
                    prior_weight_set = true;
                } catch (...) {
                    usage(argv[0]);
                }
            } else {
                usage(argv[0]);
            }
        } else if (const int tessera_kind = common_tessera_flag_kind(argv[arg_idx]); tessera_kind > 0) {
            // Tessera-owned top-level flag (--progress-file, --tessera-db,
            // ...): already consumed into tessera_params by
            // common_tessera_params_parse. Skip it here, including its
            // value when the flag takes one.
            if (tessera_kind == 2 && arg_idx + 1 < argc) {
                arg_idx++;
            }
        } else {
            // Tessera fork (Tier 2 HARD BREAK): unknown --flag here means
            // the user passed a legacy --tessera-* or --calib-* flag. Those
            // are removed; the new subcommand syntax must be used. Print
            // a clear error pointing to the migration map and exit.
            fprintf(stderr, "%s: unrecognized argument: %s\n", argv[0], argv[arg_idx]);
            fprintf(stderr, "    The flat --tessera-* / --calib-* flag surface has been replaced by 19 named subcommands.\n");
            fprintf(stderr, "    Run `%s --help` for the subcommand list, or see docs/tier2-subcommand-design.md.\n", argv[0]);
            usage(argv[0]);
        }
    }

    // Self-improving loop harnesses: output-targeting ops that run and exit
    // without the normal model+output positional args, following the
    // --tessera-evolve-only / --tessera-calibrate-only precedent.
    {
        const common_tessera_params & tp = common_get_tessera_params();
        if (!tp.capability_eval.empty()) {
            return ts_cli_capability_eval(tp);
        }
        if (!tp.adapt_eval.empty()) {
            return ts_cli_adapt(tp);
        }
        if (!tp.anonymize_in.empty()) {
            return ts_cli_anonymize(tp);
        }
        if (!tp.throughput_workload.empty()) {
            return ts_cli_throughput(tp);
        }
        if (!tp.dataset_in.empty()) {
            return ts_cli_dataset(tp);
        }
        if (!tp.dpace_in.empty()) {
            return ts_cli_dpace(tp);
        }
    }

    if (argc - arg_idx < 2) {
        printf("%s: bad arguments\n", argv[0]);
        usage(argv[0]);
    }
    if (!included_weights.empty() && !excluded_weights.empty()) {
        usage(argv[0]);
    }

    std::vector<std::string> imatrix_datasets;
    std::unordered_map<std::string, std::vector<float>> imatrix_data;
    int m_last_call = prepare_imatrix(imatrix_file, imatrix_datasets, included_weights, excluded_weights, imatrix_data, prior_weight);

    std::vector<llama_model_imatrix_data> i_data;
    std::vector<llama_model_tensor_override> t_override;
    if (!imatrix_data.empty()) {
        i_data.reserve(imatrix_data.size() + 1);
        for (const auto & kv : imatrix_data) {
            i_data.push_back({kv.first.c_str(), kv.second.data(), kv.second.size()});
        }
        i_data.push_back({nullptr, nullptr, 0});  // array terminator
        params.imatrix = i_data.data();
        {
            llama_model_kv_override kvo;
            std::strcpy(kvo.key, LLM_KV_QUANTIZE_IMATRIX_FILE);
            kvo.tag = LLAMA_KV_OVERRIDE_TYPE_STR;
            strncpy(kvo.val_str, imatrix_file.c_str(), 127);
            kvo.val_str[127] = '\0';
            kv_overrides.emplace_back(std::move(kvo));
        }
        if (!imatrix_datasets.empty()) {
            llama_model_kv_override kvo;
            // TODO: list multiple datasets when there are more than one
            std::strcpy(kvo.key, LLM_KV_QUANTIZE_IMATRIX_DATASET);
            kvo.tag = LLAMA_KV_OVERRIDE_TYPE_STR;
            strncpy(kvo.val_str, imatrix_datasets[0].c_str(), 127);
            kvo.val_str[127] = '\0';
            kv_overrides.emplace_back(std::move(kvo));
        }
        {
            llama_model_kv_override kvo;
            std::strcpy(kvo.key, LLM_KV_QUANTIZE_IMATRIX_N_ENTRIES);
            kvo.tag = LLAMA_KV_OVERRIDE_TYPE_INT;
            kvo.val_i64 = imatrix_data.size();
            kv_overrides.emplace_back(std::move(kvo));
        }
        if (m_last_call > 0) {
            llama_model_kv_override kvo;
            std::strcpy(kvo.key, LLM_KV_QUANTIZE_IMATRIX_N_CHUNKS);
            kvo.tag = LLAMA_KV_OVERRIDE_TYPE_INT;
            kvo.val_i64 = m_last_call;
            kv_overrides.emplace_back(std::move(kvo));
        }
        // Only record the prior-weight metadata (and only apply the prior at
        // all, see load_imatrix) when --prior-weight was explicitly passed.
        if (prior_weight_set) {
            llama_model_kv_override kvo;
            std::strcpy(kvo.key, LLM_KV_QUANTIZE_IMATRIX_PRIOR_W);
            kvo.tag = LLAMA_KV_OVERRIDE_TYPE_FLOAT;
            kvo.val_f64 = prior_weight;
            kv_overrides.emplace_back(std::move(kvo));
        }
    }
    if (!kv_overrides.empty()) {
        kv_overrides.emplace_back();
        kv_overrides.back().key[0] = 0;
        params.kv_overrides = kv_overrides.data();
    }
    if (!tensor_type_opts.empty()) {
        t_override.reserve(tensor_type_opts.size() + 1);
        for (const auto & tt : tensor_type_opts) {
            t_override.push_back({tt.name.c_str(), tt.type});
        }
        t_override.push_back({nullptr, GGML_TYPE_COUNT});  // array terminator
        params.tt_overrides = t_override.data();
    }
    if (!prune_layers.empty()) {
        prune_layers.push_back(-1);  // array terminator
        params.prune_layers = prune_layers.data();
    }

    llama_backend_init();

    // parse command line arguments
    const std::string fname_inp = !model_input.empty() ? model_input : argv[arg_idx];
    arg_idx++;
    std::string fname_out;

    std::string ftype_str;
    std::string suffix = ".gguf";
    if (try_parse_ftype(argv[arg_idx], params.ftype, ftype_str) ||
            striequals(argv[arg_idx], "TESSERA_T640") || striequals(argv[arg_idx], "TESSERA_T640_3D")) {
        if (striequals(argv[arg_idx], "TESSERA_T640") || striequals(argv[arg_idx], "TESSERA_T640_3D")) {
            use_tessera = true;
            ftype_str = argv[arg_idx];
            for (auto & ch : ftype_str) {
                ch = std::toupper(ch);
            }
        }
        // argv[arg_idx] is the ftype directly: <input> <ftype>
        if (!params.dry_run) {
            std::string fpath;
            const size_t pos = fname_inp.find_last_of("/\\");
            if (pos != std::string::npos) {
                fpath = fname_inp.substr(0, pos + 1);
            }

            // export as [inp path]/ggml-model-[ftype]. Only add extension if there is no splitting
            fname_out = fpath + "ggml-model-" + ftype_str;
            if (!params.keep_split) {
                fname_out += suffix;
            }
        }
        arg_idx++;
        if (ftype_str == "COPY") {
            params.only_copy = true;
        }
    } else {
        // argv[arg_idx] is not a valid ftype, so treat it as output path: <input> <output> <ftype>
        fname_out = argv[arg_idx];
        if (params.keep_split && fname_out.find(suffix) != std::string::npos) {
            fname_out = fname_out.substr(0, fname_out.length() - suffix.length());
        }
        arg_idx++;

        if (argc <= arg_idx) {
            fprintf(stderr, "%s: missing ftype\n", __func__);
            return 1;
        }
        if (!try_parse_ftype(argv[arg_idx], params.ftype, ftype_str) &&
                !striequals(argv[arg_idx], "TESSERA_T640") && !striequals(argv[arg_idx], "TESSERA_T640_3D")) {
            fprintf(stderr, "%s: invalid ftype '%s'\n", __func__, argv[arg_idx]);
            return 1;
        }
        if (striequals(argv[arg_idx], "TESSERA_T640") || striequals(argv[arg_idx], "TESSERA_T640_3D")) {
            use_tessera = true;
            ftype_str = argv[arg_idx];
            for (auto & ch : ftype_str) {
                ch = std::toupper(ch);
            }
        }
        if (ftype_str == "COPY") {
           params.only_copy = true;
        }
        arg_idx++;
    }

    // parse nthreads; a trailing --flag is tessera-owned and was already
    // consumed by common_tessera_params_parse, so leave it alone
    if (argc > arg_idx && strncmp(argv[arg_idx], "--", 2) != 0) {
        try {
            params.nthread = std::stoi(argv[arg_idx]);
        }
        catch (const std::exception & e) {
            fprintf(stderr, "%s: invalid nthread '%s' (%s)\n", __func__, argv[arg_idx], e.what());
            return 1;
        }
    }

    if (!params.dry_run) {
        if (std::error_code ec; std::filesystem::equivalent(fname_inp, fname_out, ec)) {
            fprintf(stderr, "%s: error: input and output files are the same: '%s'\n", __func__, fname_inp.c_str());
            return 1;
        }
    }

    llama_print_build_info();

    if (params.dry_run) {
        fprintf(stderr, "%s: calculating quantization size for '%s' as %s", __func__, fname_inp.c_str(), ftype_str.c_str());
    } else {
        fprintf(stderr, "%s: quantizing '%s' to '%s' as %s", __func__, fname_inp.c_str(), fname_out.c_str(), ftype_str.c_str());
    }

    if (params.nthread > 0) {
        fprintf(stderr, " using %d threads", params.nthread);
    }
    fprintf(stderr, "\n");

    const int64_t t_main_start_us = llama_time_us();

    int64_t t_quantize_us = 0;

    if (use_tessera) {
        const common_tessera_params & tp = common_get_tessera_params();
        ts_dispatch_params tparams = {};
        tparams.input_path        = fname_inp;
        tparams.output_path       = fname_out;
        tparams.imatrix_path      = tp.imatrix;
        tparams.policy_path       = tp.policy;
        tparams.policy_out_path   = tp.policy_out;
        tparams.calib_corpus      = tp.calib_corpus;
        tparams.higgs_alpha_mode  = "uniform";
        tparams.evolve_seed       = tp.evolve_seed;
        tparams.evolve_iters      = tp.evolve_iters;
        tparams.evolve_islands    = tp.evolve_islands;
        tparams.evolve_population = tp.evolve_population;
        tparams.evolve_only       = tp.evolve_only;
        tparams.calibrate_only    = tp.calibrate_only;
        tparams.outlier_frac      = tp.outlier_frac;
        tparams.awq_alpha         = tp.awq_alpha;
        tparams.awq_clip          = tp.awq_clip;
        tparams.nthreads          = tp.nthreads;
        tparams.progress_file     = tp.progress_file;
        tparams.kernel_fitness       = tp.kernel_fitness;
        tparams.kernel_fitness_dir   = tp.kernel_fitness_dir;
        tparams.kernel_fitness_blend = tp.kernel_fitness_blend;
        tparams.w4a4                 = tp.w4a4;
        tparams.w4a4_outlier_thresh  = tp.w4a4_outlier_thresh;
        tparams.run_acceptance       = tp.acceptance;
        if (tp.acceptance) {
            ts_acceptance_default_config(&tparams.acceptance_config);
            tparams.acceptance_config.verbose = true;
            if (!tp.acceptance_out.empty()) {
                snprintf(tparams.acceptance_config.output_path,
                         sizeof(tparams.acceptance_config.output_path),
                         "%s", tp.acceptance_out.c_str());
            }
        }
        tparams.adaptive_requantize          = tp.adaptive_requantize;
        tparams.l5_max_generations           = tp.l5_max_generations;
        tparams.l5_flag_multiplier           = tp.l5_flag_multiplier;
        tparams.l5_alpha_min                 = tp.l5_alpha_min;
        tparams.l5_clip_min                  = tp.l5_clip_min;
        tparams.l5_outlier_overshoot_scale   = tp.l5_outlier_overshoot_scale;
        tparams.l5_outlier_frac_cap          = tp.l5_outlier_frac_cap;
        tparams.l5_out_path                  = tp.l5_out;
        tparams.tessera_db_path              = tp.tessera_db;
        tparams.force_requantize             = tp.force_requantize;
        tparams.runtime_probe                = tp.runtime_probe;
        tparams.runtime_probe_bf16           = tp.runtime_probe_bf16;
        tparams.runtime_probe_l2_out         = tp.runtime_probe_l2_out;
        ts_dispatch_result tresult;
        std::string terr;
        if (ts_dispatch_run(&tparams, &tresult, &terr) != 0) {
            fprintf(stderr, "error: tessera pipeline failed: %s\n", terr.c_str());
            return 1;
        }
        printf("tessera: quantized %lld tensors, total mse = %.6f\n",
               (long long)tresult.n_tensors_quantized, tresult.total_mse);
        if (tresult.acceptance_ran) {
            printf("tessera: acceptance: %s\n", tresult.acceptance.verdict);
            return tresult.acceptance.acceptance_passed ? 0 : 1;
        }
        if (tresult.l5_ran) {
            printf("tessera: l5 adaptive requantize: ran\n");
        }
        return 0;
    }

    // load the model
    {
        const int64_t t_start_us = llama_time_us();

        if (llama_model_quantize(fname_inp.c_str(), fname_out.c_str(), &params)) {
            fprintf(stderr, "%s: failed to quantize model from '%s'\n", __func__, fname_inp.c_str());
            return 1;
        }

        t_quantize_us = llama_time_us() - t_start_us;
    }

    // report timing
    {
        const int64_t t_main_end_us = llama_time_us();

        printf("\n");
        printf("%s: quantize time = %8.2f ms\n", __func__, t_quantize_us/1000.0);
        printf("%s:    total time = %8.2f ms\n", __func__, (t_main_end_us - t_main_start_us)/1000.0);
    }

    llama_backend_free();

    return 0;
}

// Tessera fork: top-level subcommand-aware entry point (Tier 2). Called
// by the llama-tessera binary. Parses with common_tessera_params_parse
// (which handles the subcommand dispatch and the subcommand-scoped Tessera
// flag set), then routes to the right handler.
//
// Subcommand modes that exit without quantizing (capability, adapt,
// anonymize, throughput, dataset, dpace, l2) call the matching ts_cli_*
// helper and return its exit code. Tuning subcommands (awq, l5, w4a4,
// champq, evolve, calibrate, policy, ga, kernel-fitness, runtime-probe,
// accept, l15) fall through to the main quantize path; their flags have
// already been recorded in tessera_params. No-subcommand mode is also
// the main quantize path.
//
// HARD BREAK: the old --tessera-* flag surface is gone. Any old flag
// that slipped through to llama_quantize's hand-rolled loop will hit
// the "unrecognized argument" path because common_tessera_parse_one is
// removed. Old flags must be migrated to subcommand syntax.
[[noreturn]]
static void llama_tessera_usage_wrapper(int /*argc*/, char ** argv) {
    usage(argv[0]);
}

int llama_tessera_main(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");

    common_params params;
    if (!common_tessera_params_parse(argc, argv, params, llama_tessera_usage_wrapper)) {
        fprintf(stderr, "error: failed to parse arguments\n");
        return 1;
    }

    const enum tessera_subcommand sc = common_tessera_active_subcommand();
    const common_tessera_params & tp = common_get_tessera_params();

    // Exit-without-quantize subcommands: they run a self-contained CLI
    // helper against tessera_params and return its exit code. Each
    // helper checks that its required input was supplied.
    switch (sc) {
        case TESSERA_SC_CAPABILITY:
            if (tp.capability_eval.empty()) {
                fprintf(stderr, "error: `capability` subcommand requires --eval PATH\n");
                return 1;
            }
            return ts_cli_capability_eval(tp);
        case TESSERA_SC_ADAPT:
            if (tp.adapt_eval.empty()) {
                fprintf(stderr, "error: `adapt` subcommand requires --eval PATH\n");
                return 1;
            }
            return ts_cli_adapt(tp);
        case TESSERA_SC_ANONYMIZE:
            if (tp.anonymize_in.empty()) {
                fprintf(stderr, "error: `anonymize` subcommand requires --in PATH\n");
                return 1;
            }
            return ts_cli_anonymize(tp);
        case TESSERA_SC_THROUGHPUT:
            if (tp.throughput_workload.empty()) {
                fprintf(stderr, "error: `throughput` subcommand requires --workload PATH\n");
                return 1;
            }
            return ts_cli_throughput(tp);
        case TESSERA_SC_DATASET:
            if (tp.dataset_in.empty()) {
                fprintf(stderr, "error: `dataset` subcommand requires --in PATH\n");
                return 1;
            }
            return ts_cli_dataset(tp);
        case TESSERA_SC_DPACE:
            if (tp.dpace_in.empty()) {
                fprintf(stderr, "error: `dpace` subcommand requires --in PATH\n");
                return 1;
            }
            return ts_cli_dpace(tp);
        case TESSERA_SC_UNIFIED_WRITER:
            return ts_cli_unified_writer(tp);
        case TESSERA_SC_EXPORT_TERNARY: {
            // Positional fallback: `export-ternary <in.gguf> <out_dir/>`
            // (argv[1] is the subcommand token; argv[2..] are positionals).
            common_tessera_params & mtp = const_cast<common_tessera_params &>(tp);
            for (int i = 2; i < argc; i++) {
                if (argv[i] == nullptr || argv[i][0] == '-') break;
                if (mtp.export_in.empty()) {
                    mtp.export_in = argv[i];
                } else if (mtp.export_out.empty()) {
                    mtp.export_out = argv[i];
                }
            }
            return ts_cli_export_ternary(tp);
        }
        case TESSERA_SC_PACK: {
            // Positional fallback: `pack <in_dir/> <out.gguf>`
            common_tessera_params & mtp = const_cast<common_tessera_params &>(tp);
            for (int i = 2; i < argc; i++) {
                if (argv[i] == nullptr || argv[i][0] == '-') break;
                if (mtp.pack_in.empty()) {
                    mtp.pack_in = argv[i];
                } else if (mtp.pack_out.empty()) {
                    mtp.pack_out = argv[i];
                }
            }
            return ts_cli_pack(tp);
        }
        default:
            break;
    }

    // Tuning subcommands that just set flags on tessera_params and fall
    // through to the main quantize path. The subcommand-as-toggle cases
    // (champq, w4a4) are handled here: the subcommand's presence enables
    // the toggle, no flag needed.
    if (sc == TESSERA_SC_CHAMPQ) {
        const_cast<common_tessera_params &>(tp).champq = true;
    }
    if (sc == TESSERA_SC_W4A4) {
        const_cast<common_tessera_params &>(tp).w4a4 = true;
    }

    // Subcommand-less path or tuning subcommand: hand the argv to the
    // legacy llama_quantize subroutine, which parses the positional
    // <input> <output> <ftype> [nthreads] syntax. A tuning subcommand
    // sits as a bare token in argv[1] (common_tessera_params_parse
    // shifted its own local copy only), so shift it out here too.
    if (sc != TESSERA_SC_NONE) {
        return llama_quantize(argc - 1, argv + 1);
    }
    return llama_quantize(argc, argv);
}
