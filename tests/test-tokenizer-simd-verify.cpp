// Standalone verification harness for the SIMD pre-tokenization fast-path.
//
// Loads a BPE vocab, then tokenizes a battery of strings that exercise the
// qwen35 / gpt2 / llama3 pre-tokenizer patterns (contractions, runs of letters,
// digits, whitespace, punctuation, CJK, emoji, mixing ASCII and non-ASCII).
//
// Used as an A/B oracle: build against the current code, save the token ids
// per string; rebuild with the SIMD fast-path and confirm the ids match.
//
// Usage: test-tokenizer-simd-verify <vocab.gguf> [output-file]

#include "llama.h"
#include "common.h"

#include "../src/unicode.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static const std::vector<std::string> & k_corpus() {
    static const std::vector<std::string> v = {
        // ASCII basics
        "",
        " ",
        "  ",
        "   ",
        "\t",
        "\n",
        "\n\n",
        "\n\n\n",
        "\t\n",
        "Hello world",
        " Hello world",
        "Hello World",
        " Hello World",
        " Hello World!",
        "Hello, world!",
        " Hello, world!",
        "Hello, y'all! How are you doing today?",
        "w048 7tuijk dsdfhu",
        "The quick brown fox jumps over the lazy dog.",
        "   leading spaces then word",
        "trailing spaces then    ",
        "multiple    spaces    between    words",
        "a b c d e f g h i j k l m n o p",
        // contractions
        "'s 't 're 've 'm 'll 'd",
        "It's a test, we're here, I'd say, you'll see, they've gone",
        "don't can't won't shouldn't I'm we're it's",
        "Case Insensitive: 'S 'T 'RE 'VE 'M 'LL 'D",
        // digits / numbers
        "3",
        "33",
        "333",
        "3333",
        "33333",
        "333333",
        "1234567890",
        "phone: 555-1234, zip: 90210",
        "mixed1word2and3nums",
        "v2.0 release 3.1.4-beta",
        // punctuation runs
        "!!!???...---===",
        "...",
        "a...b...c",
        "http://example.com/path?query=value&foo=bar#frag",
        "array[0] = func(x, y) * (a + b);",
        "100% done, $5.00 each, < 10 > 5, ^ & |",
        // newlines / whitespace patterns (the \s+(?!\S) vs \s+ distinction)
        "end of line   \n  next line",
        "trailing ws   ",
        "line1\nline2\nline3\n",
        "\r\n\r\n",
        "tab\tseparated\tvalues\there",
        // CJK / non-ASCII letters
        "Hello 世界",
        "你好世界",
        "日本語のテキスト",
        "한국어 텍스트",
        "Привет мир",
        "Ελληνικά",
        "مرحبا بالعالم",
        "mix English and 中文 and 한국어 and 日本語",
        // emoji (4-byte UTF-8, exercises the non-ASCII fallback)
        "emoji: 🦙 test",
        "🚀 (normal) 😶‍🌫️ (multiple emojis concatenated)",
        "multiple 🎉🎊🎈 emoji",
        // combining marks (qwen35 includes \p{M} in letter runs)
        "café résumé naïve",
        "Zürich Über",
        // mixed word/punct boundaries adjacent to multibyte
        "Hello,世界!你好?World.",
        "123你好456",
        "abc中def文gh",
        // code-like
        "def foo(x, y):\n    return x + y\n",
        "#include <stdio.h>\nint main() { return 0; }\n",
        "const char *s = \"hello\\nworld\";",
        "def factorial(n):\n    if n <= 1:\n        return 1\n    return n * factorial(n-1)",
        // long ASCII run (exercises SIMD chunks)
        "The Analytical Engine weaves algebraic patterns just as the Jacquard loom weaves flowers and leaves.",
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "                    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa                    ",
        // tab + space mixes
        "indent\n    indented\n        more indented",
        // apostrophe at boundaries
        "owners' rights",
        "'twas brillig",
        "rock 'n' roll",
    };
    return v;
}

int main(int argc, char ** argv) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s <vocab-file> [output-file]\n", argv[0]);
        return 1;
    }
    const std::string fname = argv[1];
    const std::string out   = argc == 3 ? argv[2] : "-";

    llama_backend_init();

    llama_model * model = nullptr;
    llama_context * ctx  = nullptr;
    {
        auto mparams = llama_model_default_params();
        mparams.vocab_only = true;
        model = llama_model_load_from_file(fname.c_str(), mparams);
        if (!model) {
            fprintf(stderr, "%s: failed to load vocab '%s'\n", __func__, fname.c_str());
            return 1;
        }
        auto cparams = llama_context_default_params();
        ctx = llama_init_from_model(model, cparams);
        if (!ctx) {
            fprintf(stderr, "%s: failed to init context for '%s'\n", __func__, fname.c_str());
            llama_model_free(model);
            return 1;
        }
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);

    FILE * fp = out == "-" ? stdout : std::fopen(out.c_str(), "wb");
    if (!fp) {
        fprintf(stderr, "%s: cannot open '%s'\n", __func__, out.c_str());
        return 1;
    }

    fprintf(fp, "corpus_size=%zu\n", k_corpus().size());

    bool ok = true;
    size_t idx = 0;
    for (const auto & s : k_corpus()) {
        auto tokens = common_tokenize(ctx, s, false, true);
        fprintf(fp, "[%05zu] n=%zu bytes=%zu ::", idx, tokens.size(), s.size());
        for (auto t : tokens) {
            fprintf(fp, " %d", t);
        }
        fprintf(fp, "\n");
        idx++;
        (void)ok;
    }

    if (fp != stdout) {
        std::fclose(fp);
    }

    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();

    fprintf(stderr, "%s: wrote %zu entries to %s\n",
            __func__, k_corpus().size(), out.c_str());
    return 0;
}
