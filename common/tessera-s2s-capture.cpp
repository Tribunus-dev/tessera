// tessera-s2s-capture.cpp - per-utterance s2s record append hook (s2s design 4.1).
//
// Implements tessera_rt_s2s_append: appends one llama.tessera.s2s.v1 NDJSON
// record to the trace file at args->trace_path. The codes payload is
// zlib-compressed (RFC 1950) and base64-encoded, bit-compatible with the
// Swift-side TesseraS2SCodes.encode/decode (NSData .zlib). All other fields
// are written with stable key order (sorted) so the on-disk record can be
// diffed and round-tripped through the Swift decoder.
//
// Threading: this is a single-threaded append path (one utterance at a
// time). Concurrent appends from the CLI and the future Studio audio node
// must be serialized upstream; the file open uses O_APPEND so concurrent
// writers at the OS level stay consistent, but record boundaries are not
// line-locked.

#include "tessera-s2s-capture.h"

#include "base64.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include <zlib.h>

namespace {

// Worst-case zlib output bound (from zlib.h: source + 12 bytes for the
// header/trailer + ceil(source * 0.1%)).
inline uint64_t zlib_compress_bound(uint64_t n) {
    return compressBound((uLong) n) + 16u;
}

std::string json_escape(const char * s) {
    if (s == nullptr) return std::string("null");
    std::string out;
    out.reserve(std::strlen(s) + 8);
    out.push_back('"');
    for (const unsigned char * p = (const unsigned char *) s; *p; ++p) {
        const unsigned char c = *p;
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b";  break;
            case '\f': out += "\\f";  break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char esc[8];
                    std::snprintf(esc, sizeof(esc), "\\u%04x", c);
                    out += esc;
                } else {
                    out.push_back((char) c);
                }
        }
    }
    out.push_back('"');
    return out;
}

std::string json_escape_nullable(const char * s) {
    if (s == nullptr) return std::string("null");
    return json_escape(s);
}

// Write int32_t array as a JSON int array. token_id is the underlying
// physical type but we serialize as signed ints to match the Swift
// TesseraS2SRecord.Text schema.
std::string json_int_array(const int32_t * v, int32_t n) {
    std::string out = "[";
    for (int32_t i = 0; i < n; ++i) {
        if (i) out.push_back(',');
        char buf[24];
        std::snprintf(buf, sizeof(buf), "%d", (int) v[i]);
        out += buf;
    }
    out.push_back(']');
    return out;
}

std::string json_string_map(const char * const * keys, const char * const * values, int32_t n) {
    std::string out = "{";
    for (int32_t i = 0; i < n; ++i) {
        if (i) out.push_back(',');
        out += json_escape(keys[i]);
        out.push_back(':');
        out += json_escape(values[i]);
    }
    out.push_back('}');
    return out;
}

} // namespace

// ---- standalone encoder/decoder (exported for the CLI self-test) ----

int tessera_s2s_encode_codes_b64(const uint16_t * codes_frame,
                                 int32_t         n_frames,
                                 char          * out_b64,
                                 int32_t         out_b64_cap) {
    if (out_b64 == nullptr) return 0;
    if (n_frames < 0) return 0;

    // Empty payload -> empty string (bit-compatible with the Swift empty
    // path which round-trips [] with frames = 0). codes_frame is allowed
    // to be NULL when n_frames is 0.
    if (n_frames == 0) {
        if (out_b64_cap < 1) return 0;
        out_b64[0] = '\0';
        return 0;
    }

    if (codes_frame == nullptr) return 0;

    const int32_t n_codes = n_frames * TESSERA_S2S_CODES_PER_FRAME;
    const uint64_t n_raw  = (uint64_t) n_codes * 2u;

    std::vector<unsigned char> raw(n_raw);
    for (int32_t i = 0; i < n_codes; ++i) {
        const uint16_t v = codes_frame[i];
        raw[(size_t) i * 2u + 0u] = (unsigned char) (v & 0xFFu);
        raw[(size_t) i * 2u + 1u] = (unsigned char) ((v >> 8) & 0xFFu);
    }

    const uint64_t bound = zlib_compress_bound(n_raw);
    std::vector<unsigned char> comp((size_t) bound);

    uLongf comp_len = (uLongf) comp.size();
    const int rc = compress2(comp.data(), &comp_len, raw.data(), (uLong) raw.size(), Z_DEFAULT_COMPRESSION);
    if (rc != Z_OK) return 0;
    comp.resize((size_t) comp_len);

    // base64-encode the compressed payload
    std::string b64;
    b64.reserve(((size_t) comp_len + 2u) / 3u * 4u + 1u);
    base64::encode(comp.begin(), comp.end(), std::back_inserter(b64), base64::alphabet::standard);

    if ((int32_t) b64.size() + 1 > out_b64_cap) return 0;
    std::memcpy(out_b64, b64.data(), b64.size());
    out_b64[b64.size()] = '\0';
    return (int) b64.size();
}

int tessera_s2s_decode_codes_b64(const char * zlib_b64,
                                 int32_t     expected_frames,
                                 uint16_t  * out_codes,
                                 int32_t     out_codes_cap_frames) {
    if (zlib_b64 == nullptr) return -1;
    if (expected_frames < 0) return -1;

    // Empty payload -> empty round-trip. out_codes is allowed to be NULL
    // when expected_frames is 0 (matches the encode side: b64 writes a
    // NUL with no codes to decode).
    if (zlib_b64[0] == '\0' && expected_frames == 0) return 0;
    if (expected_frames == 0) return -1;
    if (out_codes == nullptr) return -1;
    if (expected_frames > out_codes_cap_frames) return -1;

    std::vector<unsigned char> comp;
    comp.reserve((std::strlen(zlib_b64) / 4u) * 3u + 4u);
    try {
        base64::decode(zlib_b64, zlib_b64 + std::strlen(zlib_b64), std::back_inserter(comp),
                       base64::alphabet::standard, base64::decoding_behavior::loose);
    } catch (...) {
        return -1;
    }
    if (comp.empty()) return -1;

    const uint64_t expected_raw = (uint64_t) expected_frames * TESSERA_S2S_CODES_PER_FRAME * 2u;
    std::vector<unsigned char> raw;
    raw.resize((size_t) expected_raw + 64u);
    uLongf raw_len = (uLongf) raw.size();
    const int rc = uncompress(raw.data(), &raw_len, comp.data(), (uLong) comp.size());
    if (rc != Z_OK) return -1;
    if (raw_len != expected_raw) return -1;

    for (int32_t i = 0; i < expected_frames * TESSERA_S2S_CODES_PER_FRAME; ++i) {
        out_codes[i] = (uint16_t) raw[(size_t) i * 2u + 0u] | ((uint16_t) raw[(size_t) i * 2u + 1u] << 8);
    }
    return expected_frames;
}

// ---- append hook ----

int tessera_rt_s2s_append(const tessera_s2s_capture_args * args) {
    if (args == nullptr) return 1;
    if (args->utf8 == nullptr || args->sid == nullptr || args->provenance == nullptr
        || args->trace_path == nullptr || args->voice.preset == nullptr) {
        return 1;
    }
    if (args->n_frames < 0) return 1;
    if (args->gemma_tokens_n < 0 || args->gemma_tokens == nullptr) return 1;
    if (args->qwen_ids_n    < 0 || args->qwen_ids    == nullptr) return 1;
    if (args->n_frames > 0 && args->codes_frame == nullptr) return 1;
    if (args->models.n_keys != 0
        && (args->models.keys == nullptr || args->models.values == nullptr)) {
        return 1;
    }

    // zlib+base64 the codes. out_b64 holds the compressed payload.
    std::string codes_b64;
    {
        const int32_t b64_cap = ((args->n_frames * TESSERA_S2S_CODES_PER_FRAME * 2u) + 64u) * 2u + 32u;
        codes_b64.resize((size_t) b64_cap);
        const int n = tessera_s2s_encode_codes_b64(
                args->codes_frame, args->n_frames,
                codes_b64.data(), b64_cap);
        if (n < 0) return 2;
        codes_b64.resize((size_t) n);
    }

    // Compose the JSON body. Key order is fixed so the on-disk line is
    // diff-friendly: the Swift decoder is order-insensitive but the C
    // encoder must agree on order to round-trip.
    std::ostringstream js;
    js << "{";
    js << "\"codes\":{\"frames\":" << args->n_frames << ",\"zlib_b64\":" << json_escape(codes_b64.c_str()) << "},";
    js << "\"feedback\":{\"interrupted\":" << (args->feedback.interrupted ? "true" : "false")
       <<            ",\"regenerated\":" << (args->feedback.regenerated ? "true" : "false")
       <<            ",\"replayed\":"    << (args->feedback.replayed     ? "true" : "false") << "},";
    js << "\"models\":" << json_string_map(args->models.keys, args->models.values, args->models.n_keys) << ",";
    js << "\"provenance\":" << json_escape_nullable(args->provenance) << ",";
    js << "\"schema\":"    << json_escape(TESSERA_S2S_SCHEMA_STAMP) << ",";
    js << "\"sid\":"       << json_escape_nullable(args->sid) << ",";
    js << "\"text\":{\"gemma_tokens\":" << json_int_array(args->gemma_tokens, args->gemma_tokens_n)
       <<            ",\"qwen_ids\":"    << json_int_array(args->qwen_ids,    args->qwen_ids_n)
       <<            ",\"utf8\":"        << json_escape_nullable(args->utf8) << "},";
    js << "\"timing\":{\"code2wav_frames_per_s\":" << args->timing.code2wav_frames_per_s
       <<          ",\"decode_frames_per_s\":"    << args->timing.decode_frames_per_s
       <<          ",\"first_packet_us\":"         << args->timing.first_packet_us
       <<          ",\"retokenize_us\":"           << args->timing.retokenize_us
       <<          ",\"talker_ttft_us\":"          << args->timing.talker_ttft_us << "},";
    js << "\"voice\":{\"preset\":" << json_escape_nullable(args->voice.preset)
       <<           ",\"ref_hash\":" << json_escape_nullable(args->voice.ref_hash) << "}";
    js << "}\n";

    const std::string line = js.str();

    // O_APPEND keeps concurrent writers at the OS level consistent; the
    // caller is expected to serialize at the utterance level.
    std::ofstream f(args->trace_path, std::ios::binary | std::ios::app);
    if (!f.is_open()) return 3;
    f.write(line.data(), (std::streamsize) line.size());
    if (!f.good()) return 4;
    f.close();
    return 0;
}
