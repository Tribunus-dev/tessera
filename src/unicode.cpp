#include "unicode.h"
#include "unicode-data.h"

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <map>
#include <regex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

size_t unicode_len_utf8(char src) {
    const size_t lookup[] = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 3, 4 };
    uint8_t highbits = static_cast<uint8_t>(src) >> 4;
    return lookup[highbits];
}

static std::string unicode_cpts_to_utf8(const std::vector<uint32_t> & cps) {
    std::string result;
    for (size_t i = 0; i < cps.size(); ++i) {
        result.append(unicode_cpt_to_utf8(cps[i]));
    }
    return result;
}

uint32_t unicode_cpt_from_utf8(const std::string & utf8, size_t & offset) {
    assert(offset < utf8.size());
    if (!(utf8[offset + 0] & 0x80)) {
        auto result = utf8[offset + 0];
        offset += 1;
        return result;
    }
    if (!(utf8[offset + 0] & 0x40)) {
        throw std::invalid_argument("invalid character");
    }
    if (!(utf8[offset + 0] & 0x20)) {
        if (offset + 1 >= utf8.size() || ! ((utf8[offset + 1] & 0xc0) == 0x80)) {
            throw std::invalid_argument("invalid character");
        }
        auto result = ((utf8[offset + 0] & 0x1f) << 6) | (utf8[offset + 1] & 0x3f);
        offset += 2;
        return result;
    }
    if (!(utf8[offset + 0] & 0x10)) {
        if (offset + 2 >= utf8.size() || ! ((utf8[offset + 1] & 0xc0) == 0x80) || ! ((utf8[offset + 2] & 0xc0) == 0x80)) {
            throw std::invalid_argument("invalid character");
        }
        auto result = ((utf8[offset + 0] & 0x0f) << 12) | ((utf8[offset + 1] & 0x3f) << 6) | (utf8[offset + 2] & 0x3f);
        offset += 3;
        return result;
    }
    if (!(utf8[offset + 0] & 0x08)) {
        if (offset + 3 >= utf8.size() || ! ((utf8[offset + 1] & 0xc0) == 0x80) || ! ((utf8[offset + 2] & 0xc0) == 0x80) || !((utf8[offset + 3] & 0xc0) == 0x80)) {
            throw std::invalid_argument("invalid character");
        }
        auto result = ((utf8[offset + 0] & 0x07) << 18) | ((utf8[offset + 1] & 0x3f) << 12) | ((utf8[offset + 2] & 0x3f) << 6) | (utf8[offset + 3] & 0x3f);
        offset += 4;
        return result;
    }
    throw std::invalid_argument("failed to convert utf8 to codepoint");
}

//static std::vector<uint16_t> unicode_cpt_to_utf16(uint32_t cpt) {
//    std::vector<uint16_t> result;
//    if (/* 0x0000 <= cpt && */ cpt <= 0xffff) {
//        result.emplace_back(cpt);
//        return result;
//    }
//    if (0x10000 <= cpt && cpt <= 0x10ffff) {
//        result.emplace_back(0xd800 | ((cpt - 0x10000) >> 10));
//        result.emplace_back(0xdc00 | ((cpt - 0x10000) & 0x03ff));
//        return result;
//    }
//    throw std::invalid_argument("failed to convert codepoint to utf16");
//}

//static std::vector<uint16_t> unicode_cpts_to_utf16(const std::vector<uint32_t> & cps) {
//    std::vector<uint16_t> result;
//    for (size_t i = 0; i < cps.size(); ++i) {
//        auto temp = unicode_cpt_to_utf16(cps[i]);
//        result.insert(result.end(), temp.begin(), temp.end());
//    }
//    return result;
//}

//static uint32_t unicode_cpt_from_utf16(const std::vector<uint16_t> & utf16, size_t & offset) {
//    assert(offset < utf16.size());
//    if (((utf16[0] >> 10) << 10) != 0xd800) {
//        auto result = utf16[offset + 0];
//        offset += 1;
//        return result;
//    }
//
//    if (offset + 1 >= utf16.size() || !((utf16[1] & 0xdc00) == 0xdc00)) {
//        throw std::invalid_argument("invalid character");
//    }
//
//    auto result = 0x10000 + (((utf16[0] & 0x03ff) << 10) | (utf16[1] & 0x03ff));
//    offset += 2;
//    return result;
//}

//static std::vector<uint32_t> unicode_cpts_from_utf16(const std::vector<uint16_t> & utf16) {
//    std::vector<uint32_t> result;
//    size_t offset = 0;
//    while (offset < utf16.size()) {
//        result.push_back(unicode_cpt_from_utf16(utf16, offset));
//    }
//    return result;
//}

static std::vector<unicode_cpt_flags> unicode_cpt_flags_array() {
    std::vector<unicode_cpt_flags> cpt_flags(MAX_CODEPOINTS, unicode_cpt_flags::UNDEFINED);

    assert (unicode_ranges_flags.begin()[0].first == 0);
    assert (unicode_ranges_flags.begin()[unicode_ranges_flags.size()-1].first == MAX_CODEPOINTS);
    for (size_t i = 1; i < unicode_ranges_flags.size(); ++i) {
        const auto range_ini = unicode_ranges_flags.begin()[i-1];  // codepoint_ini, flags
        const auto range_end = unicode_ranges_flags.begin()[i];    // codepoint_end, flags
        for (uint32_t cpt = range_ini.first; cpt < range_end.first; ++cpt) {
            cpt_flags[cpt] = range_ini.second;
        }
    }

    for (auto cpt : unicode_set_whitespace) {
        cpt_flags[cpt].is_whitespace = true;
    }

    for (auto p : unicode_map_lowercase) {
        cpt_flags[p.second].is_lowercase = true;
    }

    for (auto p : unicode_map_uppercase) {
        cpt_flags[p.second].is_uppercase = true;
    }

    for (auto &range : unicode_ranges_nfd) {  // start, last, nfd
        cpt_flags[range.nfd].is_nfd = true;
    }

    return cpt_flags;
}

static std::unordered_map<uint8_t, std::string> unicode_byte_to_utf8_map() {
    std::unordered_map<uint8_t, std::string> map;
    for (int ch = 0x21; ch <= 0x7E; ++ch) {  // u'!' to u'~'
        assert(0 <= ch && ch < 256);
        map[ch] = unicode_cpt_to_utf8(ch);
    }
    for (int ch = 0xA1; ch <= 0xAC; ++ch) {  // u'¡' to u'¬'
        assert(0 <= ch && ch < 256);
        map[ch] = unicode_cpt_to_utf8(ch);
    }
    for (int ch = 0xAE; ch <= 0xFF; ++ch) {  // u'®' to u'ÿ'
        assert(0 <= ch && ch < 256);
        map[ch] = unicode_cpt_to_utf8(ch);
    }
    auto n = 0;
    for (int ch = 0; ch < 256; ++ch) {
        if (map.find(ch) == map.end()) {
            map[ch] = unicode_cpt_to_utf8(256 + n);
            ++n;
        }
    }
    return map;
}

static std::unordered_map<std::string, uint8_t> unicode_utf8_to_byte_map() {
    std::unordered_map<std::string, uint8_t> map;
    for (int ch = 0x21; ch <= 0x7E; ++ch) {  // u'!' to u'~'
        assert(0 <= ch && ch < 256);
        map[unicode_cpt_to_utf8(ch)] = ch;
    }
    for (int ch = 0xA1; ch <= 0xAC; ++ch) {  // u'¡' to u'¬'
        assert(0 <= ch && ch < 256);
        map[unicode_cpt_to_utf8(ch)] = ch;
    }
    for (int ch = 0xAE; ch <= 0xFF; ++ch) {  // u'®' to u'ÿ'
        assert(0 <= ch && ch < 256);
        map[unicode_cpt_to_utf8(ch)] = ch;
    }
    auto n = 0;
    for (int ch = 0; ch < 256; ++ch) {
        if (map.find(unicode_cpt_to_utf8(ch)) == map.end()) {
            map[unicode_cpt_to_utf8(256 + n)] = ch;
            ++n;
        }
    }
    return map;
}

static std::vector<std::string> unicode_byte_encoding_process(const std::vector<std::string> & bpe_words) {
    // Precompute a fixed-layout byte->UTF-8 table: each byte maps to 1 or 2
    // UTF-8 bytes plus a length. This replaces a per-char unordered_map lookup
    // (which returned a std::string copy) with a direct table read. The table
    // content matches unicode_byte_to_utf8() exactly.
    struct byte_utf8_entry { uint8_t len; char buf[2]; };
    static const byte_utf8_entry * table = []() {
        static byte_utf8_entry t[256];
        for (int b = 0; b < 256; ++b) {
            const std::string & s = unicode_byte_to_utf8((uint8_t) b);
            t[b].len = (uint8_t) std::min((size_t)2, s.size());
            for (size_t i = 0; i < t[b].len; ++i) t[b].buf[i] = s[i];
        }
        return t;
    }();

    std::vector<std::string> bpe_encoded_words;
    bpe_encoded_words.reserve(bpe_words.size());
    for (const auto & word : bpe_words) {
        // word is already valid UTF-8; the original code round-tripped it
        // through codepoint decode/re-encode which is a no-op for valid UTF-8.
        std::string encoded_token;
        encoded_token.reserve(word.size() * 2);
        for (unsigned char c : word) {
            const byte_utf8_entry & e = table[c];
            encoded_token.append(e.buf, e.len);
        }
        bpe_encoded_words.emplace_back(std::move(encoded_token));
    }
    return bpe_encoded_words;
}

// ---------------------------------------------------------------------------
// SIMD ASCII fast-path for BPE pre-tokenization
//
// The bottleneck in unicode_regex_split is that the per-codepoint splitters
// decode the whole text up front (unicode_cpts_from_utf8) and then walk it one
// codepoint at a time. For the ASCII-heavy text that dominates calibration
// data, that is wasted work: every byte is a codepoint, and the BPE split
// patterns ('s|'t|..., letter runs, digit runs, punctuation runs, whitespace)
// are all classifiable with byte comparisons.
//
// The functions below implement the same byte-level classification that
// unicode_cpt_flags gives for ASCII codepoints, but as branchless byte
// predicates that the compiler turns into NEON / AVX2 vector instructions.
// They are used by the qwen2 / qwen35 / gpt2 / llama3 custom splitters to
// fast-path maximal ASCII runs and only fall back to per-codepoint handling
// when a byte >= 0x80 is seen.
// ---------------------------------------------------------------------------

#if defined(__ARM_NEON) || defined(__aarch64__)
#define U_REGEX_HAVE_SIMD 1
#elif defined(__AVX2__)
#define U_REGEX_HAVE_SIMD 1
#else
#define U_REGEX_HAVE_SIMD 0
#endif

// ASCII byte classes used by the BPE patterns. Values chosen so the "word char"
// test (letter | digit | underscore) is one of the bits.
enum unicode_regex_byte_class : uint8_t {
    URB_OTHER      = 0,
    URB_LETTER     = 1 << 0, // A-Z a-z
    URB_DIGIT      = 1 << 1, // 0-9
    URB_UNDERSCORE = 1 << 2, // _
    URB_APOSTROPHE = 1 << 3, // '
    URB_SPACE      = 1 << 4, // ' '
    URB_CR         = 1 << 5, // \r
    URB_LF         = 1 << 6, // \n
    URB_TAB        = 1 << 7, // \t / \v / \f (ASCII whitespace other than space/CR/LF)
};

// Map one byte to its ASCII class. Bytes >= 0x80 return URB_OTHER (handled
// by the per-codepoint fallback); for them the SIMD path bails out.
static inline uint8_t unicode_regex_classify_ascii_byte(uint8_t b) {
    if (b >= 0x80) return URB_OTHER;
    if (b == ' ')  return URB_SPACE;
    if (b == '\r') return URB_CR;
    if (b == '\n') return URB_LF;
    if (b == '\t' || b == 0x0B || b == 0x0C) return URB_TAB;
    if (b == '\'') return URB_APOSTROPHE;
    if (b == '_')  return URB_UNDERSCORE;
    if ((b >= '0' && b <= '9')) return URB_DIGIT;
    if ((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')) return URB_LETTER;
    return URB_OTHER;
}

#if U_REGEX_HAVE_SIMD
// SIMD-friendly ASCII byte classifier: classify 16 bytes at once using the same
// class enum as unicode_regex_classify_ascii_byte. Works on NEON and AVX2.
#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#define U_REGEX_SIMD_BYTES 16
using u_regex_simd_t = uint8x16_t;
static inline u_regex_simd_t u_regex_simd_load(const uint8_t * p) { return vld1q_u8(p); }
static inline u_regex_simd_t u_regex_simd_set1(uint8_t v) { return vdupq_n_u8(v); }
static inline u_regex_simd_t u_regex_simd_and(u_regex_simd_t a, u_regex_simd_t b) { return vandq_u8(a, b); }
static inline uint64_t u_regex_simd_mask16(u_regex_simd_t v) {
    // pack 16x u8 into 16 bits, little-endian lane order
    static const uint8x16_t idx = {0,2,4,6,8,10,12,14,1,3,5,7,9,11,13,15};
    uint8x16_t q = vshrq_n_u8(v, 7);          // lanes -> 0/1
    uint8x16_t p = vqtbl1q_u8(q, idx);        // gather MSBs
    uint16x8_t r = vreinterpretq_u16_u8(p);
    uint64x2_t  s = vreinterpretq_u64_u16(r);
    return vgetq_lane_u64(s, 0);
}
#define U_REGEX_SIMD_MASK_NONZERO(m) ((m) != 0)
#elif defined(__AVX2__)
#include <immintrin.h>
// 32-byte path; only load / and / move_mask are needed for ASCII detection.
#define U_REGEX_SIMD_BYTES 32
using u_regex_simd_t = __m256i;
static inline u_regex_simd_t u_regex_simd_load(const uint8_t * p) { return _mm256_loadu_si256((const __m256i*)p); }
static inline u_regex_simd_t u_regex_simd_set1(uint8_t v) { return _mm256_set1_epi8((char)v); }
static inline u_regex_simd_t u_regex_simd_and(u_regex_simd_t a, u_regex_simd_t b) { return _mm256_and_si256(a, b); }
static inline uint32_t u_regex_simd_mask32(u_regex_simd_t v) { return (uint32_t)_mm256_movemask_epi8(v); }
#define U_REGEX_SIMD_MASK_NONZERO(m) ((m) != 0u)
// alias used in the arch-generic ASCII run-length scanner below
#define u_regex_simd_mask16(v) u_regex_simd_mask32(v)
#endif  // arch

// Classify one SIMD register of bytes. Each lane gets the same class enum as
// unicode_regex_classify_ascii_byte. Implemented with SIMD compares so no lane
// ever branches. Bytes >= 0x80 are left as URB_OTHER (== 0).
// NOTE: the inner state machines use the scalar unicode_regex_classify_ascii_byte
// (the compiler auto-vectorizes those loops); the SIMD machinery below is used
// by unicode_regex_ascii_run_len for whole-segment ASCII detection.
#endif  // U_REGEX_HAVE_SIMD

// Length of the maximal ASCII-only run starting at byte_pos (in BYTES).
// Bytes with high bit set terminate the run. Used to decide whether to enter
// the SIMD fast-path; the splitters also use it to bound the lazy-codepoint
// fallback region.
static inline size_t unicode_regex_ascii_run_len(const uint8_t * data, size_t len, size_t byte_pos) {
    size_t i = byte_pos;
#if U_REGEX_HAVE_SIMD
    const size_t simd_w = U_REGEX_SIMD_BYTES;
    const u_regex_simd_t c80 = u_regex_simd_set1(0x80);
    while (i + simd_w <= len) {
        u_regex_simd_t v = u_regex_simd_load(data + i);
        u_regex_simd_t hi = u_regex_simd_and(v, c80);
        // any lane with high bit set?
        auto mask = u_regex_simd_mask16(hi);
        if (U_REGEX_SIMD_MASK_NONZERO(mask)) {
            // ctz of mask gives the first non-ASCII lane index
            unsigned first;
#if defined(__ARM_NEON) || defined(__aarch64__)
            first = (unsigned)__builtin_ctzll((unsigned long long)mask);
#else
            first = (unsigned)__builtin_ctz(mask);
#endif
            return i - byte_pos + first;
        }
        i += simd_w;
    }
#endif
    while (i < len && data[i] < 0x80) { i++; }
    return i - byte_pos;
}

// GPT2 system regex:  's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+
// GPT2 ASCII fast-path: same state machine as the per-codepoint version below,
// evaluated directly on the byte buffer for ASCII-only segments.

// forward decl: qwen2 reuses the qwen35 ASCII fast-path (they are identical for
// ASCII text), but qwen35_ascii_seg is defined further down in the file.
static void unicode_regex_split_qwen35_ascii_seg(const uint8_t * data,
                                                 size_t offset_ini, size_t offset_end,
                                                 std::vector<size_t> & bpe_offsets);

static void unicode_regex_split_gpt2_ascii_seg(const uint8_t * data,
                                               size_t offset_ini, size_t offset_end,
                                               std::vector<size_t> & bpe_offsets) {
    size_t pos = offset_ini;
    while (pos < offset_end) {
        const uint8_t b = data[pos];
        const uint8_t cls = unicode_regex_classify_ascii_byte(b);

        // regex: 's|'t|'re|'ve|'m|'ll|'d  (case-sensitive, lowercase only)
        if (b == '\'' && pos + 1 < offset_end) {
            uint8_t n1 = data[pos + 1];
            if (n1 == 's' || n1 == 't' || n1 == 'm' || n1 == 'd') {
                bpe_offsets.push_back(2);
                pos += 2;
                continue;
            }
            if (pos + 2 < offset_end) {
                uint8_t n2 = data[pos + 2];
                if ((n1 == 'r' && n2 == 'e') || (n1 == 'v' && n2 == 'e') || (n1 == 'l' && n2 == 'l')) {
                    bpe_offsets.push_back(3);
                    pos += 3;
                    continue;
                }
            }
        }

        // optional leading space (consumed by the matching run patterns below)
        const uint8_t b1 = (b == ' ' && pos + 1 < offset_end) ? data[pos + 1] : b;
        const uint8_t cls1 = unicode_regex_classify_ascii_byte(b1);
        const bool b1_defined = (b1 >= 0x20 || b1 == '\t' || b1 == '\n');

        // regex: <space>?\p{L}+
        if (cls1 & URB_LETTER) {
            const size_t tok_start = pos;
            pos += (b == ' ');
            while (pos < offset_end && (unicode_regex_classify_ascii_byte(data[pos]) & URB_LETTER)) {
                pos++;
            }
            bpe_offsets.push_back(pos - tok_start);
            continue;
        }
        // regex: <space>?\p{N}+
        if (cls1 & URB_DIGIT) {
            const size_t tok_start = pos;
            pos += (b == ' ');
            while (pos < offset_end && (unicode_regex_classify_ascii_byte(data[pos]) & URB_DIGIT)) {
                pos++;
            }
            bpe_offsets.push_back(pos - tok_start);
            continue;
        }
        // regex: <space>?[^\s\p{L}\p{N}]+
        {
            const bool punct_class = b1_defined && !((cls1) & (URB_SPACE | URB_CR | URB_LF | URB_TAB | URB_LETTER | URB_DIGIT));
            if (punct_class) {
                const size_t tok_start = pos;
                pos += (b == ' ');
                while (pos < offset_end) {
                    uint8_t c = data[pos];
                    uint8_t cc = unicode_regex_classify_ascii_byte(c);
                    bool defined = (c >= 0x20 || c == '\t' || c == '\n');
                    if (!defined) break;
                    if ((cc) & (URB_SPACE | URB_CR | URB_LF | URB_TAB | URB_LETTER | URB_DIGIT)) break;
                    pos++;
                }
                bpe_offsets.push_back(pos - tok_start);
                continue;
            }
        }

        // whitespace
        if (cls & (URB_SPACE | URB_CR | URB_LF | URB_TAB)) {
            size_t num_ws = 0;
            while (pos + num_ws < offset_end) {
                uint8_t c = data[pos + num_ws];
                uint8_t cc = unicode_regex_classify_ascii_byte(c);
                if (!((cc) & (URB_SPACE | URB_CR | URB_LF | URB_TAB))) break;
                num_ws++;
            }
            // regex: \s+(?!\S)
            const bool has_trailing_nonws = (pos + num_ws < offset_end);
            if (num_ws > 1 && has_trailing_nonws) {
                bpe_offsets.push_back(num_ws - 1);
                pos += num_ws - 1;
                continue;
            }
            // regex: \s+
            if (num_ws > 0) {
                bpe_offsets.push_back(num_ws);
                pos += num_ws;
                continue;
            }
        }

        // no matches
        bpe_offsets.push_back(1);
        pos++;
    }
}

static std::vector<size_t> unicode_regex_split_custom_gpt2(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets; // store the offset of each word
    bpe_offsets.reserve(offsets.size()); // Reserve memory for the approximate size

    const uint8_t * data = reinterpret_cast<const uint8_t *>(text.data());
    const size_t    nbytes = text.size();

    std::vector<uint32_t> cpts;
    bool cpts_done = false;

    size_t start = 0;
    size_t byte_cursor = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        start = offset_end;

        // find this segment's byte range and whether it is pure ASCII
        const size_t seg_byte_ini = byte_cursor;
        size_t bp = byte_cursor;
        size_t cpt_count = 0;
        bool seg_ascii = true;
        while (cpt_count < offset && bp < nbytes) {
            uint8_t c = data[bp];
            if (c < 0x80) {
                bp++; cpt_count++;
            } else {
                seg_ascii = false;
                size_t len = unicode_len_utf8((char)c);
                if (len == 0) len = 1;
                bp += len; cpt_count++;
            }
        }
        byte_cursor = bp;

        if (seg_ascii && cpt_count == offset) {
            unicode_regex_split_gpt2_ascii_seg(data, seg_byte_ini, byte_cursor, bpe_offsets);
            continue;
        }
        (void)seg_byte_ini;

        if (!cpts_done) {
            cpts = unicode_cpts_from_utf8(text);
            cpts_done = true;
        }
        assert(offset_end <= cpts.size());

        static const uint32_t OUT_OF_RANGE = 0xFFFFFFFF;
        auto _get_cpt = [&] (const size_t pos) -> uint32_t {
            return (offset_ini <= pos && pos < offset_end) ? cpts[pos] : OUT_OF_RANGE;
        };

        auto _get_flags = [&] (const size_t pos) -> unicode_cpt_flags {
            return (offset_ini <= pos && pos < offset_end) ? unicode_cpt_flags_from_cpt(cpts[pos]) : unicode_cpt_flags{};
        };

        size_t _prev_end = offset_ini;
        auto _add_token = [&] (const size_t end) -> size_t {
            assert(_prev_end <= end && end <= offset_end);
            size_t len = end - _prev_end;
            if (len > 0) {
                bpe_offsets.push_back(len);
            }
            _prev_end = end;
            return len;
        };

        for (size_t pos = offset_ini; pos < offset_end; /*pos++*/ ) {
            const uint32_t cpt = _get_cpt(pos);
            const auto flags = _get_flags(pos);

            // regex: 's|'t|'re|'ve|'m|'ll|'d
            if (cpt == '\'' && pos+1 < offset_end) {
                uint32_t cpt_next = _get_cpt(pos+1);
                if (cpt_next == 's' || cpt_next == 't' || cpt_next == 'm' || cpt_next == 'd') {
                    pos += _add_token(pos+2);
                    continue;
                }
                if (pos+2 < offset_end) {
                    uint32_t cpt_next_next = _get_cpt(pos+2);
                    if ((cpt_next == 'r' && cpt_next_next == 'e') ||
                        (cpt_next == 'v' && cpt_next_next == 'e') ||
                        (cpt_next == 'l' && cpt_next_next == 'l')) {
                        pos += _add_token(pos+3);
                        continue;
                    }
                }
            }

            auto flags2 = (cpt == ' ' ? _get_flags(pos+1) : flags);
            // regex: <space>?\p{L}+
            if (flags2.is_letter) {
                pos += (cpt == ' ');
                while (flags2.is_letter) {
                    flags2 = _get_flags(++pos);
                }
                _add_token(pos);
                continue;
            }
            // regex: <space>?\p{N}+
            if (flags2.is_number) {
                pos += (cpt == ' ');
                while (flags2.is_number) {
                    flags2 = _get_flags(++pos);
                }
                _add_token(pos);
                continue;
            }
            // regex: <space>?[^\s\p{L}\p{N}]+
            if (!(flags2.is_whitespace | flags2.is_letter | flags2.is_number) && flags2.as_uint()) {
                pos += (cpt == ' ');
                while (!(flags2.is_whitespace | flags2.is_letter | flags2.is_number) && flags2.as_uint()) {
                    flags2 = _get_flags(++pos);
                }
                _add_token(pos);
                continue;
            }

            size_t num_whitespaces = 0;
            while (_get_flags(pos+num_whitespaces).is_whitespace) {
                num_whitespaces++;
            }

            // regex: \s+(?!\S)
            if (num_whitespaces > 1 && _get_cpt(pos+num_whitespaces) != OUT_OF_RANGE) {
                pos += num_whitespaces - 1;
                _add_token(pos);
                continue;
            }

            // regex: \s+
            if (num_whitespaces > 0) {
                pos += num_whitespaces;
                _add_token(pos);
                continue;
            }

            // no matches
            _add_token(++pos);
        }
    }

    return bpe_offsets;
}

// LLAMA3 system regex: "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"
// LLAMA3 ASCII fast-path: byte-level state machine for ASCII-only segments.
// Identical to the per-codepoint version except \p{N}{1,3} groups digits into
// runs of at most 3 (the only structural difference from qwen35, which emits
// one digit per token).
static void unicode_regex_split_llama3_ascii_seg(const uint8_t * data,
                                                 size_t offset_ini, size_t offset_end,
                                                 std::vector<size_t> & bpe_offsets) {
    size_t pos = offset_ini;
    auto is_punct_class = [](uint8_t c) -> bool {
        uint8_t cc = unicode_regex_classify_ascii_byte(c);
        return !((cc) & (URB_SPACE | URB_CR | URB_LF | URB_TAB | URB_LETTER | URB_DIGIT));
    };
    while (pos < offset_end) {
        const uint8_t b = data[pos];
        const uint8_t cls = unicode_regex_classify_ascii_byte(b);
        const bool is_letter = (cls & URB_LETTER) != 0;
        const bool is_digit  = (cls & URB_DIGIT)  != 0;

        // regex: (?i:'s|'t|'re|'ve|'m|'ll|'d)
        if (b == '\'' && pos + 1 < offset_end) {
            uint8_t n1 = data[pos + 1];
            uint8_t l1 = (n1 >= 'A' && n1 <= 'Z') ? (uint8_t)(n1 + 32) : n1;
            if (l1 == 's' || l1 == 't' || l1 == 'm' || l1 == 'd') {
                bpe_offsets.push_back(2);
                pos += 2;
                continue;
            }
            if (pos + 2 < offset_end) {
                uint8_t n2 = data[pos + 2];
                uint8_t l2 = (n2 >= 'A' && n2 <= 'Z') ? (uint8_t)(n2 + 32) : n2;
                if ((l1 == 'r' && l2 == 'e') || (l1 == 'v' && l2 == 'e') || (l1 == 'l' && l2 == 'l')) {
                    bpe_offsets.push_back(3);
                    pos += 3;
                    continue;
                }
            }
        }

        // regex: [^\r\n\p{L}\p{N}]?\p{L}+
        if (b != '\r' && b != '\n' && !is_digit) {
            const bool next_is_letter = (pos + 1 < offset_end && (unicode_regex_classify_ascii_byte(data[pos + 1]) & URB_LETTER));
            if (is_letter || next_is_letter) {
                size_t tok_start = pos;
                pos++;
                while (pos < offset_end && (unicode_regex_classify_ascii_byte(data[pos]) & URB_LETTER)) {
                    pos++;
                }
                bpe_offsets.push_back(pos - tok_start);
                continue;
            }
        }

        // regex: \p{N}{1,3}
        if (is_digit) {
            size_t ini = pos;
            while (pos < offset_end && (unicode_regex_classify_ascii_byte(data[pos]) & URB_DIGIT)) {
                pos++;
                if (pos - ini >= 3) {
                    bpe_offsets.push_back(pos - ini);
                    ini = pos;
                }
            }
            if (pos > ini) {
                bpe_offsets.push_back(pos - ini);
            }
            continue;
        }

        // regex: <space>?[^\s\p{L}\p{N}]+[\r\n]*
        {
            const bool b0_defined = (b >= 0x20 || b == '\t' || b == '\n');
            const uint8_t b1 = (b == ' ' && pos + 1 < offset_end) ? data[pos + 1] : b;
            if (b0_defined && is_punct_class(b1)) {
                const size_t tok_start = pos;
                pos += (b == ' ');
                while (pos < offset_end && is_punct_class(data[pos])) {
                    pos++;
                }
                while (pos < offset_end && (data[pos] == '\r' || data[pos] == '\n')) {
                    pos++;
                }
                bpe_offsets.push_back(pos - tok_start);
                continue;
            }
        }

        // whitespace
        if (cls & (URB_SPACE | URB_CR | URB_LF | URB_TAB)) {
            size_t num_ws = 0;
            size_t last_rn_end = 0;
            while (pos + num_ws < offset_end) {
                uint8_t c = data[pos + num_ws];
                uint8_t cc = unicode_regex_classify_ascii_byte(c);
                if (!((cc) & (URB_SPACE | URB_CR | URB_LF | URB_TAB))) break;
                if (c == '\r' || c == '\n') {
                    last_rn_end = pos + num_ws + 1;
                }
                num_ws++;
            }
            if (last_rn_end > 0) {
                bpe_offsets.push_back(last_rn_end - pos);
                pos = last_rn_end;
                continue;
            }
            const bool has_trailing_nonws = (pos + num_ws < offset_end);
            if (num_ws > 1 && has_trailing_nonws) {
                bpe_offsets.push_back(num_ws - 1);
                pos += num_ws - 1;
                continue;
            }
            if (num_ws > 0) {
                bpe_offsets.push_back(num_ws);
                pos += num_ws;
                continue;
            }
        }

        // no matches
        bpe_offsets.push_back(1);
        pos++;
    }
}

static std::vector<size_t> unicode_regex_split_custom_llama3(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets; // store the offset of each word
    bpe_offsets.reserve(offsets.size()); // Reserve memory for the approximate size

    const uint8_t * data = reinterpret_cast<const uint8_t *>(text.data());
    const size_t    nbytes = text.size();

    std::vector<uint32_t> cpts;
    bool cpts_done = false;

    size_t start = 0;
    size_t byte_cursor = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        start = offset_end;

        const size_t seg_byte_ini = byte_cursor;
        size_t bp = byte_cursor;
        size_t cpt_count = 0;
        bool seg_ascii = true;
        while (cpt_count < offset && bp < nbytes) {
            uint8_t c = data[bp];
            if (c < 0x80) {
                bp++; cpt_count++;
            } else {
                seg_ascii = false;
                size_t len = unicode_len_utf8((char)c);
                if (len == 0) len = 1;
                bp += len; cpt_count++;
            }
        }
        byte_cursor = bp;

        if (seg_ascii && cpt_count == offset) {
            unicode_regex_split_llama3_ascii_seg(data, seg_byte_ini, byte_cursor, bpe_offsets);
            continue;
        }
        (void)seg_byte_ini;

        if (!cpts_done) {
            cpts = unicode_cpts_from_utf8(text);
            cpts_done = true;
        }
        assert(offset_end <= cpts.size());

        static const uint32_t OUT_OF_RANGE = 0xFFFFFFFF;
        auto _get_cpt = [&] (const size_t pos) -> uint32_t {
            return (offset_ini <= pos && pos < offset_end) ? cpts[pos] : OUT_OF_RANGE;
        };

        auto _get_flags = [&] (const size_t pos) -> unicode_cpt_flags {
            return (offset_ini <= pos && pos < offset_end) ? unicode_cpt_flags_from_cpt(cpts[pos]) : unicode_cpt_flags{};
        };

        size_t _prev_end = offset_ini;
        auto _add_token = [&] (const size_t end) -> size_t {
            assert(_prev_end <= end && end <= offset_end);
            size_t len = end - _prev_end;
            if (len > 0) {
                bpe_offsets.push_back(len);
            }
            _prev_end = end;
            return len;
        };

        for (size_t pos = offset_ini; pos < offset_end; /*pos++*/ ) {
            const uint32_t cpt = _get_cpt(pos);
            const auto flags = _get_flags(pos);

            // regex: (?i:'s|'t|'re|'ve|'m|'ll|'d) // case insensitive
            if (cpt == '\'' && pos+1 < offset_end) {
                uint32_t cpt_next = unicode_tolower(_get_cpt(pos+1));
                if (cpt_next == 's' || cpt_next == 't' || cpt_next == 'm' || cpt_next == 'd') {
                    pos += _add_token(pos+2);
                    continue;
                }
                if (pos+2 < offset_end) {
                    uint32_t cpt_next_next = unicode_tolower(_get_cpt(pos+2));
                    if ((cpt_next == 'r' && cpt_next_next == 'e') ||
                        (cpt_next == 'v' && cpt_next_next == 'e') ||
                        (cpt_next == 'l' && cpt_next_next == 'l')) {
                        pos += _add_token(pos+3);
                        continue;
                    }
                }
            }

            // regex: [^\r\n\p{L}\p{N}]?\p{L}+
            if (!(cpt == '\r' || cpt == '\n' || flags.is_number)) {
                if (flags.is_letter || _get_flags(pos+1).is_letter) {  // one or more letters
                    pos++;
                    while (_get_flags(pos).is_letter) {
                        pos++;
                    }
                    _add_token(pos);
                    continue;
                }
            }

            // regex: \p{N}{1,3}
            if (flags.is_number) {
                size_t ini = pos;
                while (_get_flags(pos).is_number) {
                    if (++pos - ini >= 3 ) {
                        _add_token(pos);
                        ini = pos;
                    }
                }
                _add_token(pos);
                continue;
            }

            // regex: <space>?[^\s\p{L}\p{N}]+[\r\n]*
            auto flags2 = (cpt == ' ' ? _get_flags(pos+1) : flags);
            if (!(flags2.is_whitespace | flags2.is_letter | flags2.is_number) && flags.as_uint()) {
                pos += (cpt == ' ');
                while (!(flags2.is_whitespace | flags2.is_letter | flags2.is_number) && flags2.as_uint()) {
                    flags2 = _get_flags(++pos);
                }
                uint32_t cpt2 = _get_cpt(pos);
                while (cpt2 == '\r' || cpt2 == '\n') {
                    cpt2 = _get_cpt(++pos);
                }
                _add_token(pos);
                continue;
            }

            size_t num_whitespaces = 0;
            size_t last_end_r_or_n = 0;
            while (_get_flags(pos+num_whitespaces).is_whitespace) {
                uint32_t cpt2 = _get_cpt(pos+num_whitespaces);
                if (cpt2 == '\r' || cpt2 == '\n') {
                    last_end_r_or_n = pos + num_whitespaces + 1;
                }
                num_whitespaces++;
            }

            // regex: \s*[\r\n]+
            if (last_end_r_or_n > 0) {
                pos = last_end_r_or_n;
                _add_token(pos);
                continue;
            }

            // regex: \s+(?!\S)
            if (num_whitespaces > 1 && _get_cpt(pos+num_whitespaces) != OUT_OF_RANGE) {
                pos += num_whitespaces - 1;
                _add_token(pos);
                continue;
            }

            // regex: \s+
            if (num_whitespaces > 0) {
                pos += num_whitespaces;
                _add_token(pos);
                continue;
            }

            // no matches
            _add_token(++pos);
        }
    }

    return bpe_offsets;
}

// Qwen2 system regex: "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
static std::vector<size_t> unicode_regex_split_custom_qwen2(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets; // store the offset of each word
    bpe_offsets.reserve(offsets.size()); // Reserve memory for the approximate size

    const uint8_t * data = reinterpret_cast<const uint8_t *>(text.data());
    const size_t    nbytes = text.size();

    std::vector<uint32_t> cpts;
    bool cpts_done = false;

    size_t start = 0;
    size_t byte_cursor = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        start = offset_end;

        const size_t seg_byte_ini = byte_cursor;
        size_t bp = byte_cursor;
        size_t cpt_count = 0;
        bool seg_ascii = true;
        while (cpt_count < offset && bp < nbytes) {
            uint8_t c = data[bp];
            if (c < 0x80) {
                bp++; cpt_count++;
            } else {
                seg_ascii = false;
                size_t len = unicode_len_utf8((char)c);
                if (len == 0) len = 1;
                bp += len; cpt_count++;
            }
        }
        byte_cursor = bp;

        // For ASCII, qwen2 == qwen35 (the only diff is \p{M} in letter runs,
        // and ASCII has no \p{M}), so reuse the qwen35 ASCII fast-path verbatim.
        if (seg_ascii && cpt_count == offset) {
            unicode_regex_split_qwen35_ascii_seg(data, seg_byte_ini, byte_cursor, bpe_offsets);
            continue;
        }
        (void)seg_byte_ini;

        if (!cpts_done) {
            cpts = unicode_cpts_from_utf8(text);
            cpts_done = true;
        }
        assert(offset_end <= cpts.size());

        static const uint32_t OUT_OF_RANGE = 0xFFFFFFFF;
        auto _get_cpt = [&] (const size_t pos) -> uint32_t {
            return (offset_ini <= pos && pos < offset_end) ? cpts[pos] : OUT_OF_RANGE;
        };

        auto _get_flags = [&] (const size_t pos) -> unicode_cpt_flags {
            return (offset_ini <= pos && pos < offset_end) ? unicode_cpt_flags_from_cpt(cpts[pos]) : unicode_cpt_flags{};
        };

        size_t _prev_end = offset_ini;
        auto _add_token = [&] (const size_t end) -> size_t {
            assert(_prev_end <= end && end <= offset_end);
            size_t len = end - _prev_end;
            if (len > 0) {
                bpe_offsets.push_back(len);
            }
            _prev_end = end;
            return len;
        };

        for (size_t pos = offset_ini; pos < offset_end; /*pos++*/ ) {
            const uint32_t cpt = _get_cpt(pos);
            const auto flags = _get_flags(pos);

            // regex: (?i:'s|'t|'re|'ve|'m|'ll|'d) // case insensitive
            if (cpt == '\'' && pos+1 < offset_end) {
                uint32_t cpt_next = unicode_tolower(_get_cpt(pos+1));
                if (cpt_next == 's' || cpt_next == 't' || cpt_next == 'm' || cpt_next == 'd') {
                    pos += _add_token(pos+2);
                    continue;
                }
                if (pos+2 < offset_end) {
                    uint32_t cpt_next_next = unicode_tolower(_get_cpt(pos+2));
                    if ((cpt_next == 'r' && cpt_next_next == 'e') ||
                        (cpt_next == 'v' && cpt_next_next == 'e') ||
                        (cpt_next == 'l' && cpt_next_next == 'l')) {
                        pos += _add_token(pos+3);
                        continue;
                    }
                }
            }

            // regex: [^\r\n\p{L}\p{N}]?\p{L}+
            if (!(cpt == '\r' || cpt == '\n' || flags.is_number)) {
                if (flags.is_letter || _get_flags(pos+1).is_letter) {  // one or more letters
                    pos++;
                    while (_get_flags(pos).is_letter) {
                        pos++;
                    }
                    _add_token(pos);
                    continue;
                }
            }

            // regex: \p{N}
            if (flags.is_number) {
                pos++;
                _add_token(pos);
                continue;
            }

            // regex: <space>?[^\s\p{L}\p{N}]+[\r\n]*
            auto flags2 = (cpt == ' ' ? _get_flags(pos+1) : flags);
            if (!(flags2.is_whitespace | flags2.is_letter | flags2.is_number) && flags.as_uint()) {
                pos += (cpt == ' ');
                while (!(flags2.is_whitespace | flags2.is_letter | flags2.is_number) && flags2.as_uint()) {
                    flags2 = _get_flags(++pos);
                }
                uint32_t cpt2 = _get_cpt(pos);
                while (cpt2 == '\r' || cpt2 == '\n') {
                    cpt2 = _get_cpt(++pos);
                }
                _add_token(pos);
                continue;
            }

            size_t num_whitespaces = 0;
            size_t last_end_r_or_n = 0;
            while (_get_flags(pos+num_whitespaces).is_whitespace) {
                uint32_t cpt2 = _get_cpt(pos+num_whitespaces);
                if (cpt2 == '\r' || cpt2 == '\n') {
                    last_end_r_or_n = pos + num_whitespaces + 1;
                }
                num_whitespaces++;
            }

            // regex: \s*[\r\n]+
            if (last_end_r_or_n > 0) {
                pos = last_end_r_or_n;
                _add_token(pos);
                continue;
            }

            // regex: \s+(?!\S)
            if (num_whitespaces > 1 && _get_cpt(pos+num_whitespaces) != OUT_OF_RANGE) {
                pos += num_whitespaces - 1;
                _add_token(pos);
                continue;
            }

            // regex: \s+
            if (num_whitespaces > 0) {
                pos += num_whitespaces;
                _add_token(pos);
                continue;
            }

            // no matches
            _add_token(++pos);
        }
    }

    return bpe_offsets;
}

// Qwen3.5 system regex: "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
// Compared to Qwen2, letter-runs also consume Unicode combining marks (\p{M}): [\p{L}\p{M}]+ instead of \p{L}+
//
// Byte-oriented fast-path for ASCII segments. For each input segment that is
// entirely ASCII (the calibration-data common case) the regex state machine is
// evaluated directly on the raw byte buffer with inline branchless ASCII
// classification; for codepoints this means byte length == codepoint count, so
// the emitted offsets are unchanged. Segments containing any byte >= 0x80 are
// handled by the original per-codepoint state machine over a lazily-decoded
// codepoint slice, so non-ASCII text (CJK, emoji, combining marks) is byte for
// byte identical to the previous implementation.
static void unicode_regex_split_qwen35_ascii_seg(const uint8_t * data,
                                                 size_t offset_ini, size_t offset_end,
                                                 std::vector<size_t> & bpe_offsets) {
    size_t pos = offset_ini;
    auto is_punct_class = [](uint8_t c) -> bool {
        uint8_t cc = unicode_regex_classify_ascii_byte(c);
        return !((cc) & (URB_SPACE | URB_CR | URB_LF | URB_TAB | URB_LETTER | URB_DIGIT));
    };
    while (pos < offset_end) {
        const uint8_t b = data[pos];
        const uint8_t cls = unicode_regex_classify_ascii_byte(b);
        const bool is_ws     = (cls & (URB_SPACE | URB_CR | URB_LF | URB_TAB)) != 0;
        const bool is_letter = (cls & URB_LETTER) != 0;
        const bool is_digit  = (cls & URB_DIGIT)  != 0;

        // regex: (?i:'s|'t|'re|'ve|'m|'ll|'d)
        if (b == '\'' && pos + 1 < offset_end) {
            uint8_t n1 = data[pos + 1];
            uint8_t l1 = (n1 >= 'A' && n1 <= 'Z') ? (uint8_t)(n1 + 32) : n1;
            if (l1 == 's' || l1 == 't' || l1 == 'm' || l1 == 'd') {
                bpe_offsets.push_back(2);
                pos += 2;
                continue;
            }
            if (pos + 2 < offset_end) {
                uint8_t n2 = data[pos + 2];
                uint8_t l2 = (n2 >= 'A' && n2 <= 'Z') ? (uint8_t)(n2 + 32) : n2;
                if ((l1 == 'r' && l2 == 'e') || (l1 == 'v' && l2 == 'e') || (l1 == 'l' && l2 == 'l')) {
                    bpe_offsets.push_back(3);
                    pos += 3;
                    continue;
                }
            }
            // apostrophe not part of a contraction -> handled as punctuation below
        }

        // regex: [^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+
        // ASCII has no \p{M}; this is an optional non-(\r|\n|\p{N}) prefix + letter run
        if (b != '\r' && b != '\n' && !is_digit) {
            const bool next_is_letter = (pos + 1 < offset_end && (unicode_regex_classify_ascii_byte(data[pos + 1]) & URB_LETTER));
            if (is_letter || next_is_letter) {
                size_t tok_start = pos;
                pos++;
                while (pos < offset_end && (unicode_regex_classify_ascii_byte(data[pos]) & URB_LETTER)) {
                    pos++;
                }
                bpe_offsets.push_back(pos - tok_start);
                continue;
            }
        }

        // regex: \p{N}  (single digit per token for qwen2/qwen35)
        if (is_digit) {
            bpe_offsets.push_back(1);
            pos++;
            continue;
        }

        // regex: <space>?[^\s\p{L}\p{M}\p{N}]+[\r\n]*
        // flags.as_uint() guard: ASCII controls < 0x20 (except \t \n) are UNDEFINED
        {
            const bool b0_defined = (b >= 0x20 || b == '\t' || b == '\n');
            const uint8_t b1 = (b == ' ' && pos + 1 < offset_end) ? data[pos + 1] : b;
            if (b0_defined && is_punct_class(b1)) {
                const size_t tok_start = pos;
                pos += (b == ' ');  // consume optional leading space
                while (pos < offset_end && is_punct_class(data[pos])) {
                    pos++;
                }
                while (pos < offset_end && (data[pos] == '\r' || data[pos] == '\n')) {
                    pos++;
                }
                bpe_offsets.push_back(pos - tok_start);
                continue;
            }
        }

        // whitespace handling
        if (is_ws) {
            size_t num_ws = 0;
            size_t last_rn_end = 0;
            while (pos + num_ws < offset_end) {
                uint8_t c = data[pos + num_ws];
                uint8_t cc = unicode_regex_classify_ascii_byte(c);
                if (!((cc) & (URB_SPACE | URB_CR | URB_LF | URB_TAB))) {
                    break;
                }
                if (c == '\r' || c == '\n') {
                    last_rn_end = pos + num_ws + 1;
                }
                num_ws++;
            }
            // regex: \s*[\r\n]+
            if (last_rn_end > 0) {
                bpe_offsets.push_back(last_rn_end - pos);
                pos = last_rn_end;
                continue;
            }
            // regex: \s+(?!\S)
            const bool has_trailing_nonws = (pos + num_ws < offset_end);
            if (num_ws > 1 && has_trailing_nonws) {
                bpe_offsets.push_back(num_ws - 1);
                pos += num_ws - 1;
                continue;
            }
            // regex: \s+
            if (num_ws > 0) {
                bpe_offsets.push_back(num_ws);
                pos += num_ws;
                continue;
            }
        }

        // no matches: single-char token
        bpe_offsets.push_back(1);
        pos++;
    }
}

static std::vector<size_t> unicode_regex_split_custom_qwen35(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets;
    bpe_offsets.reserve(offsets.size());

    const uint8_t * data = reinterpret_cast<const uint8_t *>(text.data());
    const size_t    nbytes = text.size();

    // lazily decoded full codepoint array; only built when a non-ASCII segment
    // is encountered (the calibration-data common case never needs it)
    std::vector<uint32_t> cpts_full;
    bool cpts_done = false;

    // segments are contiguous codepoint ranges [start, start+offset). Byte and
    // codepoint cursors diverge once a multibyte char appears, so we track the
    // byte position of each segment explicitly.
    size_t start = 0;
    size_t byte_cursor = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        start = offset_end;

        // Find this segment's byte range starting at byte_cursor, and determine
        // whether it is pure ASCII. We scan forward counting codepoints: each
        // byte < 0x80 is one codepoint; a byte >= 0x80 starts a multibyte seq.
        const size_t seg_byte_ini = byte_cursor;
        size_t bp = byte_cursor;
        size_t cpt_count = 0;
        bool seg_ascii = true;
        while (cpt_count < offset && bp < nbytes) {
            uint8_t c = data[bp];
            if (c < 0x80) {
                bp++;
                cpt_count++;
            } else {
                seg_ascii = false;
                // advance one full codepoint (1-4 bytes)
                size_t len = unicode_len_utf8((char)c);
                if (len == 0) len = 1;
                bp += len;
                cpt_count++;
            }
        }
        byte_cursor = bp;

        if (seg_ascii && cpt_count == offset) {
            // byte range [seg_byte_ini, byte_cursor) is the segment; offsets in
            // codepoint units equal byte offsets here, so we can pass the byte
            // indices directly to the ASCII fast-path.
            unicode_regex_split_qwen35_ascii_seg(data, seg_byte_ini, byte_cursor, bpe_offsets);
            continue;
        }
        (void)seg_byte_ini;

        // ---- per-codepoint fallback for any segment containing non-ASCII ----
        if (!cpts_done) {
            cpts_full = unicode_cpts_from_utf8(text);
            cpts_done = true;
        }
        assert(offset_end <= cpts_full.size());

        static const uint32_t OUT_OF_RANGE = 0xFFFFFFFF;
        auto _get_cpt = [&] (size_t pos) -> uint32_t {
            return (offset_ini <= pos && pos < offset_end) ? cpts_full[pos] : OUT_OF_RANGE;
        };
        auto _get_flags = [&] (size_t pos) -> unicode_cpt_flags {
            return (offset_ini <= pos && pos < offset_end) ? unicode_cpt_flags_from_cpt(cpts_full[pos]) : unicode_cpt_flags{};
        };
        size_t _prev_end = offset_ini;
        auto _add_token = [&] (size_t end) -> size_t {
            assert(_prev_end <= end && end <= offset_end);
            size_t len = end - _prev_end;
            if (len > 0) {
                bpe_offsets.push_back(len);
            }
            _prev_end = end;
            return len;
        };

        for (size_t pos = offset_ini; pos < offset_end; /*pos++*/ ) {
            const uint32_t cpt = _get_cpt(pos);
            const auto flags = _get_flags(pos);

            // regex: (?i:'s|'t|'re|'ve|'m|'ll|'d) // case insensitive
            if (cpt == '\'' && pos+1 < offset_end) {
                uint32_t cpt_next = unicode_tolower(_get_cpt(pos+1));
                if (cpt_next == 's' || cpt_next == 't' || cpt_next == 'm' || cpt_next == 'd') {
                    pos += _add_token(pos+2);
                    continue;
                }
                if (pos+2 < offset_end) {
                    uint32_t cpt_next_next = unicode_tolower(_get_cpt(pos+2));
                    if ((cpt_next == 'r' && cpt_next_next == 'e') ||
                        (cpt_next == 'v' && cpt_next_next == 'e') ||
                        (cpt_next == 'l' && cpt_next_next == 'l')) {
                        pos += _add_token(pos+3);
                        continue;
                    }
                }
            }

            // regex: [^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+
            if (!(cpt == '\r' || cpt == '\n' || flags.is_number)) {
                if (flags.is_letter || flags.is_accent_mark || _get_flags(pos + 1).is_accent_mark || _get_flags(pos+1).is_letter) {
                    pos++;
                    while (_get_flags(pos).is_letter || _get_flags(pos).is_accent_mark) {
                        pos++;
                    }
                    _add_token(pos);
                    continue;
                }
            }

            // regex: \p{N}
            if (flags.is_number) {
                pos++;
                _add_token(pos);
                continue;
            }

            // regex: <space>?[^\s\p{L}\p{M}\p{N}]+[\r\n]*
            auto flags2 = (cpt == ' ' ? _get_flags(pos+1) : flags);
            if (!(flags2.is_whitespace | flags2.is_letter | flags2.is_accent_mark | flags2.is_number) && flags.as_uint()) {
                pos += (cpt == ' ');
                while (!(flags2.is_whitespace | flags2.is_letter | flags2.is_accent_mark | flags2.is_number) && flags2.as_uint()) {
                    flags2 = _get_flags(++pos);
                }
                uint32_t cpt2 = _get_cpt(pos);
                while (cpt2 == '\r' || cpt2 == '\n') {
                    cpt2 = _get_cpt(++pos);
                }
                _add_token(pos);
                continue;
            }

            size_t num_whitespaces = 0;
            size_t last_end_r_or_n = 0;
            while (_get_flags(pos+num_whitespaces).is_whitespace) {
                uint32_t cpt2 = _get_cpt(pos+num_whitespaces);
                if (cpt2 == '\r' || cpt2 == '\n') {
                    last_end_r_or_n = pos + num_whitespaces + 1;
                }
                num_whitespaces++;
            }

            // regex: \s*[\r\n]+
            if (last_end_r_or_n > 0) {
                pos = last_end_r_or_n;
                _add_token(pos);
                continue;
            }

            // regex: \s+(?!\S)
            if (num_whitespaces > 1 && _get_cpt(pos+num_whitespaces) != OUT_OF_RANGE) {
                pos += num_whitespaces - 1;
                _add_token(pos);
                continue;
            }

            // regex: \s+
            if (num_whitespaces > 0) {
                pos += num_whitespaces;
                _add_token(pos);
                continue;
            }

            // no matches
            _add_token(++pos);
        }
    }

    return bpe_offsets;
}



template <typename CharT>
static std::vector<size_t> unicode_regex_split_stl(const std::basic_string<CharT> & text, const std::basic_string<CharT> & regex, const std::vector<size_t> & offsets) {
    using BidirIt = typename std::basic_string<CharT>::const_iterator;
#ifdef _MSC_VER
    // Bypass bug in MSVC: https://github.com/ggml-org/llama.cpp/issues/17830
    constexpr auto regex_flags = std::regex_constants::ECMAScript;
#else
    constexpr auto regex_flags = std::regex_constants::optimize | std::regex_constants::nosubs;
#endif
    std::basic_regex<CharT> expr(regex, regex_flags);
    std::vector<size_t> bpe_offsets; // store the offset of each word
    bpe_offsets.reserve(offsets.size()); // Reserve memory for the approximate size
    size_t start = 0;
    for (auto offset : offsets) {
        std::regex_iterator<BidirIt> it(text.begin() + start, text.begin() + start + offset, expr);
        std::regex_iterator<BidirIt> end;

        int64_t start_idx = 0;
        while (it != end) {
            std::match_results<BidirIt> match = *it;
            if (match.position() > start_idx) {
                bpe_offsets.emplace_back(match.position() - start_idx);
            }
            bpe_offsets.emplace_back(match.length());
            start_idx = match.position() + match.length();
            ++it;
        }

        if (start_idx < (int64_t) offset) {
            bpe_offsets.emplace_back(offset - start_idx);
        }
        start += offset;
    }

    return bpe_offsets;
}

// K2 system regex patterns (from tokenization_kimi.py):
// [\p{Han}]+|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+
static std::vector<size_t> unicode_regex_split_custom_kimi_k2(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets;
    bpe_offsets.reserve(offsets.size());

    const auto cpts = unicode_cpts_from_utf8(text);

    size_t start = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        assert(offset_end <= cpts.size());
        start = offset_end;

        static const uint32_t OUT_OF_RANGE = 0xFFFFFFFF;
        auto _get_cpt = [&] (const size_t pos) -> uint32_t {
            return (offset_ini <= pos && pos < offset_end) ? cpts[pos] : OUT_OF_RANGE;
        };

        auto _get_flags = [&] (const size_t pos) -> unicode_cpt_flags {
            return (offset_ini <= pos && pos < offset_end) ? unicode_cpt_flags_from_cpt(cpts[pos]) : unicode_cpt_flags{};
        };

        size_t _prev_end = offset_ini;
        auto _add_token = [&] (const size_t end) -> size_t {
            assert(_prev_end <= end && end <= offset_end);
            size_t len = end - _prev_end;
            if (len > 0) {
                bpe_offsets.push_back(len);
            }
            _prev_end = end;
            return len;
        };

        for (size_t pos = offset_ini; pos < offset_end; /*pos++*/ ) {
            const uint32_t cpt = _get_cpt(pos);
            const auto flags = _get_flags(pos);

            // Pattern 1: [\p{Han}]+ (Chinese characters)
            if (unicode_cpt_is_han(cpt)) {
                while (unicode_cpt_is_han(_get_cpt(pos))) {
                    pos++;
                }
                _add_token(pos);
                continue;
            }

            // Pattern 2 & 3: Letter words excluding Han characters with optional contractions
            // [^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+(?:'s|'t|'re|'ve|'m|'ll|'d)?
            // [^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*(?:'s|'t|'re|'ve|'m|'ll|'d)?
            // Check if current char is a letter OR if current char could be a leading char and next char is a letter
            bool is_letter_pattern = (flags.is_letter && !unicode_cpt_is_han(cpt)) ||
                                     (!(cpt == '\r' || cpt == '\n' || flags.is_letter || flags.is_number) &&
                                      _get_flags(pos + 1).is_letter && !unicode_cpt_is_han(_get_cpt(pos + 1)));

            if (is_letter_pattern) {
                // Handle optional leading non-letter/non-number character
                bool has_leading_char = false;
                if (!(cpt == '\r' || cpt == '\n' || flags.is_letter || flags.is_number)) {
                    has_leading_char = true;
                    pos++;
                }

                // Match letter sequence (excluding Han characters)
                bool has_letters = false;
                while (_get_flags(pos).is_letter && !unicode_cpt_is_han(_get_cpt(pos))) {
                    has_letters = true;
                    pos++;
                }

                // Only proceed if we found letters (after potentially skipping leading char)
                if (has_letters || (!has_leading_char && _get_flags(pos).is_letter && !unicode_cpt_is_han(_get_cpt(pos)))) {
                    if (!has_letters) pos++; // consume the first letter if we didn't already

                    // Continue consuming letters
                    while (_get_flags(pos).is_letter && !unicode_cpt_is_han(_get_cpt(pos))) {
                        pos++;
                    }

                    // Check for optional contractions (?:'s|'t|'re|'ve|'m|'ll|'d)
                    if (_get_cpt(pos) == '\'' && pos + 1 < offset_end) {
                        uint32_t cpt_next = unicode_tolower(_get_cpt(pos + 1));
                        if (cpt_next == 's' || cpt_next == 't' || cpt_next == 'm' || cpt_next == 'd') {
                            pos += 2;
                        } else if (pos + 2 < offset_end) {
                            uint32_t cpt_next_next = unicode_tolower(_get_cpt(pos + 2));
                            if ((cpt_next == 'r' && cpt_next_next == 'e') ||
                                (cpt_next == 'v' && cpt_next_next == 'e') ||
                                (cpt_next == 'l' && cpt_next_next == 'l')) {
                                pos += 3;
                            }
                        }
                    }

                    _add_token(pos);
                    continue;
                } else if (has_leading_char) {
                    // We consumed a leading char but found no letters, backtrack
                    pos--;
                }
            }

            // Pattern 4: \p{N}{1,3} (numbers 1-3 digits)
            if (flags.is_number) {
                size_t ini = pos;
                while (_get_flags(pos).is_number) {
                    if (++pos - ini >= 3) {
                        _add_token(pos);
                        ini = pos;
                    }
                }
                _add_token(pos);
                continue;
            }

            // Pattern 5:  ?[^\s\p{L}\p{N}]+[\r\n]* (optional space + non-word chars + optional newlines)
            auto flags2 = (cpt == ' ' ? _get_flags(pos + 1) : flags);
            if (!(flags2.is_whitespace || flags2.is_letter || flags2.is_number) && flags2.as_uint()) {
                pos += (cpt == ' ');
                while (!(flags2.is_whitespace || flags2.is_letter || flags2.is_number) && flags2.as_uint()) {
                    flags2 = _get_flags(++pos);
                }
                // Match optional [\r\n]*
                uint32_t cpt2 = _get_cpt(pos);
                while (cpt2 == '\r' || cpt2 == '\n') {
                    cpt2 = _get_cpt(++pos);
                }
                _add_token(pos);
                continue;
            }

            // Count whitespace characters
            size_t num_whitespaces = 0;
            size_t last_end_r_or_n = 0;
            while (_get_flags(pos + num_whitespaces).is_whitespace) {
                uint32_t cpt2 = _get_cpt(pos + num_whitespaces);
                if (cpt2 == '\r' || cpt2 == '\n') {
                    last_end_r_or_n = pos + num_whitespaces + 1;
                }
                num_whitespaces++;
            }

            // Pattern 6: \s*[\r\n]+ (whitespace with newlines)
            if (last_end_r_or_n > 0) {
                pos = last_end_r_or_n;
                _add_token(pos);
                continue;
            }

            // Pattern 7: \s+(?!\S) (trailing whitespace)
            if (num_whitespaces > 1 && _get_cpt(pos + num_whitespaces) != OUT_OF_RANGE) {
                pos += num_whitespaces - 1;
                _add_token(pos);
                continue;
            }

            // Pattern 8: \s+ (general whitespace)
            if (num_whitespaces > 0) {
                pos += num_whitespaces;
                _add_token(pos);
                continue;
            }

            // No matches - consume single character
            _add_token(++pos);
        }
    }

    return bpe_offsets;
}

// AFMOE digit handling: splits digits with leading 1-2 based on total length modulo 3
static std::vector<size_t> unicode_regex_split_custom_afmoe(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets;
    bpe_offsets.reserve(offsets.size());

    const auto cpts = unicode_cpts_from_utf8(text);

    size_t start = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        assert(offset_end <= cpts.size());
        start = offset_end;

        auto _get_flags = [&] (const size_t pos) -> unicode_cpt_flags {
            return (offset_ini <= pos && pos < offset_end) ? unicode_cpt_flags_from_cpt(cpts[pos]) : unicode_cpt_flags{};
        };

        size_t _prev_end = offset_ini;
        auto _add_token = [&] (const size_t end) -> size_t {
            assert(_prev_end <= end && end <= offset_end);
            size_t len = end - _prev_end;
            if (len > 0) {
                bpe_offsets.push_back(len);
            }
            _prev_end = end;
            return len;
        };

        for (size_t pos = offset_ini; pos < offset_end; ) {
            const auto flags = _get_flags(pos);

            // Handle digit sequences with special splitting logic
            if (flags.is_number) {
                size_t digit_start = pos;
                size_t digit_count = 0;

                // Count consecutive digits
                while (_get_flags(pos).is_number && pos < offset_end) {
                    digit_count++;
                    pos++;
                }

                // Split based on total length modulo 3
                size_t remainder = digit_count % 3;
                size_t current = digit_start;

                // Emit leading 1-2 digits if needed
                if (remainder > 0) {
                    _add_token(current + remainder);
                    current += remainder;
                }

                // Emit groups of 3
                while (current < digit_start + digit_count) {
                    _add_token(current + 3);
                    current += 3;
                }
                continue;
            }

            // For non-digits, just move forward
            pos++;
        }

        // Add any remaining content
        if (_prev_end < offset_end) {
            _add_token(offset_end);
        }
    }

    return bpe_offsets;
}

// regex: [^\n]+|[\n]+
// splits text into runs of non-newline characters and runs of newline characters
static std::vector<size_t> unicode_regex_split_custom_newlines(const std::string & text, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets;
    bpe_offsets.reserve(offsets.size());

    const auto cpts = unicode_cpts_from_utf8(text);

    size_t start = 0;
    for (auto offset : offsets) {
        const size_t offset_ini = start;
        const size_t offset_end = start + offset;
        assert(offset_end <= cpts.size());
        start = offset_end;

        size_t pos = offset_ini;
        while (pos < offset_end) {
            const bool is_newline = (cpts[pos] == '\n');
            const size_t run_start = pos;
            while (pos < offset_end && (cpts[pos] == '\n') == is_newline) {
                pos++;
            }
            bpe_offsets.push_back(pos - run_start);
        }
    }

    return bpe_offsets;
}

static std::vector<size_t> unicode_regex_split_custom(const std::string & text, const std::string & regex_expr, const std::vector<size_t> & offsets) {
    std::vector<size_t> bpe_offsets;

    if (regex_expr == "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)") {
        bpe_offsets = unicode_regex_split_custom_gpt2(text, offsets);
    } else if (
            regex_expr == "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+" ||
            regex_expr == "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+") {
        bpe_offsets = unicode_regex_split_custom_llama3(text, offsets);
    } else if (
           regex_expr == "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+") {
        bpe_offsets = unicode_regex_split_custom_qwen2(text, offsets);
    } else if (
           regex_expr == "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+") {
        bpe_offsets = unicode_regex_split_custom_qwen35(text, offsets);
    } else if (regex_expr == "\\p{Han}+") {
        // K2's first pattern - handle all K2 patterns together
        bpe_offsets = unicode_regex_split_custom_kimi_k2(text, offsets);
    } else if (regex_expr == "\\p{AFMoE_digits}") {
        // AFMOE digit pattern - use custom implementation for proper splitting
        bpe_offsets = unicode_regex_split_custom_afmoe(text, offsets);
    } else if (regex_expr == "[^\\n]+|[\\n]+") {
        bpe_offsets = unicode_regex_split_custom_newlines(text, offsets);
    } else if (regex_expr == "\\d{1,3}(?=(?:\\d{3})*\\b)") {
        // tiny_aya digit grouping pattern from tokenizer.json:
        //   {"type": "Split", "pattern": {"Regex": "\\d{1,3}(?=(?:\\d{3})*\\b)"}, "behavior": "Isolated"}
        // Splits digits into groups of 3 from the right (e.g., 1234567 -> 1, 234, 567)
        // TODO: Revisit this regex, in case there are any subtle tokenization differences with the original regex.
        bpe_offsets = unicode_regex_split_custom_afmoe(text, offsets);
    }

    return bpe_offsets;
}

//
// interface
//

std::string unicode_cpt_to_utf8(uint32_t cpt) {
    std::string result;

    if (/* 0x00 <= cpt && */ cpt <= 0x7f) {
        result.push_back(cpt);
        return result;
    }
    if (0x80 <= cpt && cpt <= 0x7ff) {
        result.push_back(0xc0 | ((cpt >> 6) & 0x1f));
        result.push_back(0x80 | (cpt & 0x3f));
        return result;
    }
    if (0x800 <= cpt && cpt <= 0xffff) {
        result.push_back(0xe0 | ((cpt >> 12) & 0x0f));
        result.push_back(0x80 | ((cpt >> 6) & 0x3f));
        result.push_back(0x80 | (cpt & 0x3f));
        return result;
    }
    if (0x10000 <= cpt && cpt <= 0x10ffff) {
        result.push_back(0xf0 | ((cpt >> 18) & 0x07));
        result.push_back(0x80 | ((cpt >> 12) & 0x3f));
        result.push_back(0x80 | ((cpt >> 6) & 0x3f));
        result.push_back(0x80 | (cpt & 0x3f));
        return result;
    }

    throw std::invalid_argument("invalid codepoint");
}

std::vector<uint32_t> unicode_cpts_normalize_nfd(const std::vector<uint32_t> & cpts) {
    auto comp = [] (const uint32_t cpt, const range_nfd & range) {
        return cpt < range.first;
    };
    std::vector<uint32_t> result(cpts.size());
    for (size_t i = 0; i < cpts.size(); ++i) {
        const uint32_t cpt = cpts[i];
        auto it = std::upper_bound(unicode_ranges_nfd.begin(), unicode_ranges_nfd.end(), cpt, comp) - 1;
        result[i] = (it->first <= cpt && cpt <= it->last) ? it->nfd : cpt;
    }
    return result;
}

std::vector<uint32_t> unicode_cpts_from_utf8(const std::string & utf8) {
    std::vector<uint32_t> result;
    result.reserve(utf8.size());
    size_t offset = 0;
    while (offset < utf8.size()) {
        try {
            result.push_back(unicode_cpt_from_utf8(utf8, offset));
        }
        catch (const std::invalid_argument & /*ex*/) {
            // Silently ignore invalid UTF-8 input to avoid leaking the exception beyond llama_tokenize
            ++offset;
            result.emplace_back(0xFFFD); // replacement character
        }
    }
    return result;
}

unicode_cpt_flags unicode_cpt_flags_from_cpt(const uint32_t cpt) {
    static const unicode_cpt_flags undef(unicode_cpt_flags::UNDEFINED);
    static const auto cpt_flags = unicode_cpt_flags_array();
    return cpt < cpt_flags.size() ? cpt_flags[cpt] : undef;
}

unicode_cpt_flags unicode_cpt_flags_from_utf8(const std::string & utf8) {
    static const unicode_cpt_flags undef(unicode_cpt_flags::UNDEFINED);
    if (utf8.empty()) {
        return undef;  // undefined
    }
    size_t offset = 0;
    return unicode_cpt_flags_from_cpt(unicode_cpt_from_utf8(utf8, offset));
}

std::string unicode_byte_to_utf8(uint8_t byte) {
    static std::unordered_map<uint8_t, std::string> map = unicode_byte_to_utf8_map();
    return map.at(byte);
}

uint8_t unicode_utf8_to_byte(const std::string & utf8) {
    static std::unordered_map<std::string, uint8_t> map = unicode_utf8_to_byte_map();
    return map.at(utf8);
}

uint32_t unicode_tolower(uint32_t cpt) {
    // binary search
    auto it = std::lower_bound(unicode_map_lowercase.begin(), unicode_map_lowercase.end(), cpt,
        [](const std::pair<uint32_t, uint32_t> & pair, uint32_t value) {
            return pair.first < value;
        });
    if (it != unicode_map_lowercase.end() && it->first == cpt) {
        return it->second;
    }
    return cpt;  // Return the original code point if no lowercase mapping is found
}

bool unicode_cpt_is_han(uint32_t cpt) {
    // Han character ranges (Chinese/CJK characters)
    // CJK Unified Ideographs (most common)
    if (cpt >= 0x4E00 && cpt <= 0x9FFF) return true;

    // CJK Extension A
    if (cpt >= 0x3400 && cpt <= 0x4DBF) return true;

    // CJK Extension B
    if (cpt >= 0x20000 && cpt <= 0x2A6DF) return true;

    // CJK Extension C
    if (cpt >= 0x2A700 && cpt <= 0x2B73F) return true;

    // CJK Extension D
    if (cpt >= 0x2B740 && cpt <= 0x2B81F) return true;

    // CJK Extension E
    if (cpt >= 0x2B820 && cpt <= 0x2CEAF) return true;

    // CJK Extension F
    if (cpt >= 0x2CEB0 && cpt <= 0x2EBEF) return true;

    // CJK Compatibility Ideographs
    if (cpt >= 0xF900 && cpt <= 0xFAFF) return true;

    // CJK Compatibility Ideographs Supplement
    if (cpt >= 0x2F800 && cpt <= 0x2FA1F) return true;

    return false;
}

std::vector<std::string> unicode_regex_split(const std::string & text, const std::vector<std::string> & regex_exprs, bool byte_encode) {
    // unicode categories
    static const std::map<std::string, int> k_ucat_enum = {
        { "\\p{N}", unicode_cpt_flags::NUMBER },
        { "\\p{L}", unicode_cpt_flags::LETTER },
        { "\\p{P}", unicode_cpt_flags::PUNCTUATION },
        { "\\p{M}", unicode_cpt_flags::ACCENT_MARK },
        { "\\p{S}", unicode_cpt_flags::SYMBOL },
        { "\\p{Lu}", unicode_cpt_flags::LETTER }, // Uppercase letter
        { "\\p{Ll}", unicode_cpt_flags::LETTER }, // Lowercase letter
        { "\\p{Lt}", unicode_cpt_flags::LETTER }, // Titlecase letter
        { "\\p{Lm}", unicode_cpt_flags::LETTER }, // Modifier letter
        { "\\p{Lo}", unicode_cpt_flags::LETTER }, // Other letter
    };

    static const std::map<int, int> k_ucat_cpt = {
        { unicode_cpt_flags::NUMBER,      0xD1 },
        { unicode_cpt_flags::LETTER,      0xD2 },
        { unicode_cpt_flags::PUNCTUATION, 0xD3 },
        { unicode_cpt_flags::ACCENT_MARK, 0xD4 },
        { unicode_cpt_flags::SYMBOL,      0xD5 },
    };

    static const std::map<int, std::string> k_ucat_map = {
        { unicode_cpt_flags::NUMBER,      "\x30-\x39" }, // 0-9
        { unicode_cpt_flags::LETTER,      "\x41-\x5A\x61-\x7A" }, // A-Za-z
        { unicode_cpt_flags::PUNCTUATION, "\x21-\x23\x25-\x2A\x2C-\x2F\x3A-\x3B\x3F-\x40\\\x5B-\\\x5D\x5F\\\x7B\\\x7D" }, // !-#%-*,-/:-;?-@\[-\]_\{\}
        { unicode_cpt_flags::ACCENT_MARK, "" }, // no sub-128 codepoints
        { unicode_cpt_flags::SYMBOL,      "\\\x24\\\x2B\x3C-\x3E\x5E\x60\\\x7C" }, // $+<=>^`|
    };

    // compute collapsed codepoints only if needed by at least one regex
    bool need_collapse = false;
    for (const auto & regex_expr : regex_exprs) {
        // search for unicode categories
        for (const auto & ucat : k_ucat_enum) {
            if (std::string::npos != regex_expr.find(ucat.first)) {
                need_collapse = true;
                break;
            }
        }
    }

    // Fast detection: if the whole text is ASCII (the calibration-data common
    // case), codepoints are bytes, so we can skip the up-front UTF-8 decode and
    // build the output words by slicing the input string directly. The custom
    // splitters (qwen35/gpt2/llama3/qwen2) all fast-path ASCII segments byte by
    // byte, so the offsets they return are byte offsets == codepoint offsets.
    const uint8_t * udata = reinterpret_cast<const uint8_t *>(text.data());
    const bool text_ascii = (text.size() == unicode_regex_ascii_run_len(udata, text.size(), 0));

    std::vector<uint32_t> cpts;
    bool cpts_done = false;
    auto ensure_cpts = [&]() {
        if (!cpts_done) {
            cpts = unicode_cpts_from_utf8(text);
            cpts_done = true;
        }
    };

    // generate a "collapsed" representation of the text, where all codepoints are replaced by a single byte
    // ref: https://github.com/ggml-org/llama.cpp/pull/6920#issuecomment-2081479935
    std::string text_collapsed;
    if (need_collapse) {
        ensure_cpts();
        // collapse all unicode categories
        text_collapsed.resize(cpts.size());

        for (size_t i = 0; i < cpts.size(); ++i) {
            // keep single-byte codepoints as is
            if (cpts[i] < 128) {
                text_collapsed[i] = cpts[i];
                continue;
            }

            const auto flags = unicode_cpt_flags_from_cpt(cpts[i]);

            if (flags.is_whitespace) {
                //NOTE: C++ std::regex \s does not mach 0x85, Rust and Python regex does.
                //text_collapsed[i] = (char) 0x85;  // <Next Line> as whitespace fallback
                text_collapsed[i] = (char) 0x0B;    // <vertical tab> as whitespace fallback
            } else if (k_ucat_cpt.find(flags.category_flag()) != k_ucat_cpt.end()) {
                text_collapsed[i] = k_ucat_cpt.at(flags.category_flag());
            } else {
                text_collapsed[i] = (char) 0xD0; // fallback
            }
        }
    }

    std::vector<size_t> bpe_offsets = { text_ascii ? text.size() : (ensure_cpts(), cpts.size()) };

    for (const auto & regex_expr : regex_exprs) {
        // first, see if we have an efficient custom regex implementation
        auto tmp = unicode_regex_split_custom(text, regex_expr, bpe_offsets);

        if (!tmp.empty()) {
            bpe_offsets = std::move(tmp);
            continue;
        }

        // fallback to general-purpose std::regex / std::wregex
        try {
            // if a unicode category is used in the regex, we use the collapsed text and replace the unicode category
            // with the corresponding collapsed representation
            bool use_collapsed = false;
            for (const auto & ucat : k_ucat_enum) {
                if (std::string::npos != regex_expr.find(ucat.first)) {
                    use_collapsed = true;
                    break;
                }
            }
            const auto cpts_regex = unicode_cpts_from_utf8(regex_expr);

            if (use_collapsed) {
                // sanity-check that the original regex does not contain any non-ASCII characters
                for (size_t i = 0; i < cpts_regex.size(); ++i) {
                    if (cpts_regex[i] >= 128) {
                        throw std::runtime_error("Regex includes both unicode categories and non-ASCII characters - not supported");
                    }
                }

                // generate a collapsed representation of the regex
                std::string regex_expr_collapsed;

                // track if we are inside [], because nested [] are not allowed
                bool inside = false;
                for (size_t i = 0; i < regex_expr.size(); ++i) {
                    if (regex_expr[i] == '[' && (i == 0 || regex_expr[i - 1] != '\\')) {
                        regex_expr_collapsed += '[';
                        inside = true;
                        continue;
                    }

                    if (inside && regex_expr[i] == ']' && regex_expr[i - 1] != '\\') {
                        regex_expr_collapsed += ']';
                        inside = false;
                        continue;
                    }

                    // Match \p{...} Unicode properties of varying lengths
                    if (regex_expr[i + 0] == '\\' && i + 3 < regex_expr.size() &&
                        regex_expr[i + 1] == 'p' &&
                        regex_expr[i + 2] == '{') {
                        // Find the closing brace
                        size_t closing_brace = regex_expr.find('}', i + 3);
                        if (closing_brace != std::string::npos && closing_brace <= i + 10) { // reasonable limit
                            const std::string pat = regex_expr.substr(i, closing_brace - i + 1);
                            if (k_ucat_enum.find(pat) != k_ucat_enum.end()) {
                                if (!inside) {
                                    regex_expr_collapsed += '[';
                                }
                                regex_expr_collapsed += k_ucat_cpt.at(k_ucat_enum.at(pat));
                                regex_expr_collapsed += k_ucat_map.at(k_ucat_enum.at(pat));
                                if (!inside) {
                                    regex_expr_collapsed += ']';
                                }
                                i = closing_brace;
                                continue;
                            }
                        }
                    }

                    regex_expr_collapsed += regex_expr[i];
                }

                //printf("text_collapsed: %s\n", text_collapsed.c_str());
                //printf("regex_expr_collapsed: %s\n", regex_expr_collapsed.c_str());
                bpe_offsets = unicode_regex_split_stl(text_collapsed, regex_expr_collapsed, bpe_offsets);
            } else {
                // no unicode category used, we can use std::wregex directly
                ensure_cpts();
                std::wstring wregex_expr(cpts_regex.begin(), cpts_regex.end());

                // std::wregex \s does not mach non-ASCII whitespaces, using 0x0B as fallback
                std::wstring wtext(cpts.begin(), cpts.end());
                for (size_t i = 0; i < wtext.size(); ++i) {
                    if (wtext[i] > 0x7F && unicode_cpt_flags_from_cpt(wtext[i]).is_whitespace) {
                        wtext[i] = 0x0B;
                    }
                }

                //printf("text: %s\n", text.c_str());
                //printf("regex_expr: %s\n", regex_expr.c_str());
                bpe_offsets = unicode_regex_split_stl(wtext, wregex_expr, bpe_offsets);
            }
        } catch (std::regex_error & e) {
            fprintf(stderr, "Failed to process regex: '%s'\n", regex_expr.c_str());
            fprintf(stderr, "Regex error: %s\n", e.what());
            throw std::runtime_error("Failed to process regex");
        }
    }

    std::vector<std::string> bpe_words;
    bpe_words.reserve(bpe_offsets.size()); // reserve memory for the approximate size

    if (text_ascii) {
        // ASCII: offsets are byte offsets, slice the input directly (no per-cpt
        // decode/re-encode, no per-char unicode_cpt_to_utf8 calls)
        size_t start = 0;
        for (size_t & offset : bpe_offsets) {
            bpe_words.emplace_back(text, start, offset);
            start += offset;
        }
    } else {
        ensure_cpts();
        size_t start = 0;
        for (size_t & offset : bpe_offsets) {
            bpe_words.emplace_back();
            for (size_t i = start; i < start + offset; ++i) {
                bpe_words.back() += unicode_cpt_to_utf8(cpts[i]);
            }
            start += offset;
        }
    }

    if (byte_encode) {
        return unicode_byte_encoding_process(bpe_words);
    }

    return bpe_words;
}
