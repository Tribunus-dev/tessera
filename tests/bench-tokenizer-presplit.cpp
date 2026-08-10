// Benchmark for the BPE pre-tokenization fast-path.
//
// Generates a large ASCII-heavy buffer (mimicking calibration data) plus a
// smaller mixed ASCII/non-ASCII buffer, then times unicode_regex_split on a
// given regex pattern set. Run twice: once against the baseline binary, once
// against the SIMD-fast-path binary, and compare wall time.
//
// Usage: bench-tokenizer-presplit <pattern-set> <mib>
//   pattern-set in {qwen35, gpt2, llama3}; mib = mebibytes of ASCII text

#include "../src/unicode.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const char * k_words[] = {
    "the", "of", "and", "to", "in", "a", "is", "that", "for", "it",
    "as", "was", "with", "be", "by", "on", "not", "he", "this", "are",
    "or", "his", "from", "at", "which", "but", "have", "an", "had",
    "they", "you", "were", "their", "one", "all", "we", "can", "her",
    "has", "there", "been", "if", "more", "when", "will", "would", "who",
    "so", "no", "she", "other", "its", "may", "these", "what", "them",
    "than", "some", "into", "only", "your", "any", "new", "him", "before",
    "two", "however", "made", "after", "also", "did", "many", "being",
    "those", "must", "through", "back", "where", "much", "life", "child",
};
static const size_t k_nwords = sizeof(k_words) / sizeof(k_words[0]);

static const char * k_punct[] = {
    ",", ".", ":", ";", "!", "?", "-", "(", ")", "\"", "'s", "'t", "'re",
};
static const size_t k_npunct = sizeof(k_punct) / sizeof(k_punct[0]);

static std::string make_ascii_corpus(size_t mib) {
    // deterministic PRNG so both runs generate identical text
    unsigned long st = 0x12345678u;
    auto rnd = [&st]() {
        st = st * 6364136223846793005u + 1442695040888963407u;
        return (unsigned)(st >> 33);
    };
    std::string s;
    s.reserve(mib * 1024 * 1024);
    size_t target = mib * 1024 * 1024;
    size_t sentence_len = 0;
    while (s.size() < target) {
        // a word
        const char * w = k_words[rnd() % k_nwords];
        size_t wl = std::strlen(w);
        // occasionally capitalize
        if ((rnd() % 7) == 0 && wl > 0) {
            s.push_back((char)(w[0] - 32));
            s.append(w + 1, wl - 1);
        } else {
            s.append(w, wl);
        }
        sentence_len++;
        // sometimes a number
        if ((rnd() % 5) == 0) {
            char buf[16];
            int n = 1 + (int)(rnd() % 7);
            std::snprintf(buf, sizeof(buf), "%d", n);
            s.push_back(' ');
            s.append(buf);
        }
        // punctuation or space
        if ((rnd() % 3) == 0) {
            const char * p = k_punct[rnd() % k_npunct];
            s.append(p);
        }
        s.push_back(' ');
        // sentence boundary
        if (sentence_len >= 12 + (rnd() % 18)) {
            s.push_back('\n');
            sentence_len = 0;
        }
    }
    return s;
}

int main(int argc, char ** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <qwen35|gpt2|llama3> <mib>\n", argv[0]);
        return 1;
    }
    const std::string which = argv[1];
    const size_t mib = (size_t) std::strtoul(argv[2], nullptr, 10);

    std::vector<std::string> regex_exprs;
    if (which == "qwen35") {
        regex_exprs = {
            "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
        };
    } else if (which == "gpt2") {
        regex_exprs = {
            "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)",
        };
    } else if (which == "llama3") {
        regex_exprs = {
            "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
        };
    } else {
        fprintf(stderr, "unknown pattern set: %s\n", which.c_str());
        return 1;
    }

    std::string text = make_ascii_corpus(mib);
    fprintf(stderr, "%s: corpus = %zu MiB (%zu bytes), pattern = %s\n",
            argv[0], text.size() / (1024*1024), text.size(), which.c_str());

    // warmup + time both byte-encode modes
    auto t0 = std::chrono::steady_clock::now();
    auto words = unicode_regex_split(text, regex_exprs, /*byte_encode=*/false);
    auto t1 = std::chrono::steady_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();

    auto t2 = std::chrono::steady_clock::now();
    auto words_enc = unicode_regex_split(text, regex_exprs, /*byte_encode=*/true);
    auto t3 = std::chrono::steady_clock::now();
    double sec_enc = std::chrono::duration<double>(t3 - t2).count();

    size_t total_words = 0;
    for (auto & w : words) total_words += w.size();
    fprintf(stderr, "%s: byte_encode=false: %.3fs (%.1f MiB/s)  byte_encode=true: %.3fs (%.1f MiB/s)  chunks=%zu\n",
            argv[0], sec, (text.size() / (1024.0*1024.0)) / sec,
            sec_enc, (text.size() / (1024.0*1024.0)) / sec_enc, words.size());
    (void)total_words;

    printf("%.3f %.3f\n", sec, sec_enc);
    return 0;
}
