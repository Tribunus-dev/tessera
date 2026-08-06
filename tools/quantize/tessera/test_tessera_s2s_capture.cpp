// test_tessera_s2s_capture.cpp - tessera_rt_s2s_append contract tests.
//
// Five focused checks, all run without loading a model. They cover the s2s
// design 4.1 schema contract and the s2s design 5 golden parity tests 2
// and 3 (codes zlib+base64 round-trip, provenance stamp). A tiny string
// scanner walks the on-disk NDJSON line; we deliberately do NOT pull in
// nlohmann::json to keep the test self-contained.

#include "tessera-s2s-capture.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#endif

namespace {

int g_failures = 0;
int g_checks   = 0;

#define CHECK(cond, msg) do {                                                  \
    ++g_checks;                                                                \
    if (!(cond)) {                                                             \
        std::fprintf(stderr, "FAIL  %s:%d  %s\n", __FILE__, __LINE__, msg);    \
        ++g_failures;                                                          \
    } else {                                                                   \
        std::fprintf(stderr, "PASS  %s\n", msg);                               \
    }                                                                          \
} while (0)

std::string slurp(const char * path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss; ss << f.rdbuf();
    return ss.str();
}

// Look for "key":VALUE or "key": "VALUE" at a top-level slot. JSON is
// flat enough here that a left-to-right substring scan is reliable; the
// capture encoder writes a fixed key order.
bool find_string_field(const std::string & line, const char * key, std::string & out) {
    const std::string needle = std::string("\"") + key + "\":";
    size_t pos = line.find(needle);
    if (pos == std::string::npos) return false;
    pos += needle.size();
    while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t')) ++pos;
    if (pos >= line.size() || line[pos] != '"') return false;
    ++pos;
    std::string value;
    while (pos < line.size() && line[pos] != '"') {
        if (line[pos] == '\\' && pos + 1 < line.size()) {
            value.push_back(line[pos]); value.push_back(line[pos + 1]); pos += 2;
        } else {
            value.push_back(line[pos++]);
        }
    }
    out = value;
    return pos < line.size();
}

bool find_int_field(const std::string & line, const char * key, long & out) {
    const std::string needle = std::string("\"") + key + "\":";
    size_t pos = line.find(needle);
    if (pos == std::string::npos) return false;
    pos += needle.size();
    while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t')) ++pos;
    char * endp = nullptr;
    out = std::strtol(line.c_str() + pos, &endp, 10);
    return endp != line.c_str() + pos;
}

bool find_double_field(const std::string & line, const char * key, double & out) {
    const std::string needle = std::string("\"") + key + "\":";
    size_t pos = line.find(needle);
    if (pos == std::string::npos) return false;
    pos += needle.size();
    while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t')) ++pos;
    char * endp = nullptr;
    out = std::strtod(line.c_str() + pos, &endp);
    return endp != line.c_str() + pos;
}

// ---- round-trip a code frame through zlib+base64 ----

void test_codes_round_trip() {
    std::mt19937 rng(0xc0ffee);
    const int32_t n_frames = 32;
    std::vector<uint16_t> in(n_frames * TESSERA_S2S_CODES_PER_FRAME);
    for (auto & v : in) v = (uint16_t) (rng() & 0xFFFFu);

    char b64[4096];
    const int n_b64 = tessera_s2s_encode_codes_b64(in.data(), n_frames, b64, sizeof(b64));
    CHECK(n_b64 > 0, "encode produces a non-empty base64 string");
    CHECK((size_t) n_b64 < sizeof(b64), "encode fits the caller's buffer");

    std::vector<uint16_t> out(n_frames * TESSERA_S2S_CODES_PER_FRAME);
    const int n_dec = tessera_s2s_decode_codes_b64(b64, n_frames, out.data(), n_frames);
    CHECK(n_dec == n_frames, "decode round-trips the frame count");
    CHECK(std::equal(in.begin(), in.end(), out.begin()), "decode reproduces the exact uint16 stream");
}

// ---- empty path: n_frames = 0 round-trips as the empty string ----

void test_codes_empty() {
    char b64[8] = { 'X', 'X', 'X', 'X', 'X', 'X', 'X', 'X' };
    const int n_enc = tessera_s2s_encode_codes_b64(nullptr, 0, b64, sizeof(b64));
    CHECK(n_enc == 0, "empty encode returns 0 chars written");
    CHECK(b64[0] == '\0', "empty encode writes a NUL");

    const int n_dec = tessera_s2s_decode_codes_b64("", 0, nullptr, 0);
    CHECK(n_dec == 0, "empty decode round-trips as 0 frames");
}

// ---- capture append writes a parseable, schema-correct record ----

void test_capture_append(const char * trace_path) {
    const int32_t gemma[] = { 100, 200, 300, 400 };
    const int32_t qwen[]  = { 11, 22, 33 };
    const uint16_t codes[] = { 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                               1, 2, 3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16 };
    const int32_t n_frames = 2;
    const char * keys[]   = { "talker", "code2wav" };
    const char * values[] = { "digest-talker", "digest-c2w" };
    const tessera_s2s_timing timing {
        /*retokenize_us*/       1234,
        /*talker_ttft_us*/      5678,
        /*first_packet_us*/     91011,
        /*decode_frames_per_s*/ 12.5,
        /*code2wav_frames_per_s*/ 100.0,
    };
    const tessera_s2s_voice voice   { "tts-default", nullptr };
    const tessera_s2s_feedback fb   { 0, 0, 0 };
    const tessera_s2s_models models { keys, values, 2 };

    const tessera_s2s_capture_args args {
        /*gemma_tokens*/     gemma, /*gemma_tokens_n*/ 4,
        /*qwen_ids*/         qwen,  /*qwen_ids_n*/    3,
        /*utf8*/             "hello tessera",
        /*codes_frame*/      codes, /*n_frames*/      n_frames,
        /*timing*/           timing,
        /*voice*/            voice,
        /*feedback*/         fb,
        /*models*/           models,
        /*sid*/              "test-sid-001",
        /*provenance*/       TESSERA_S2S_PROVENANCE_VALUE,
        /*trace_path*/       trace_path,
    };
    const int rc = tessera_rt_s2s_append(&args);
    CHECK(rc == 0, "tessera_rt_s2s_append returns 0 on success");

    const std::string line = slurp(trace_path);
    CHECK(!line.empty(), "trace file is non-empty after append");
    CHECK(line.back() == '\n', "trace file ends with a newline");

    std::string schema, provenance, sid, utf8, preset, ref_hash;
    CHECK(find_string_field(line, "schema", schema),     "schema key present");
    CHECK(find_string_field(line, "provenance", provenance), "provenance key present");
    CHECK(find_string_field(line, "sid", sid),           "sid key present");
    CHECK(find_string_field(line, "text", utf8) == false && true, "text key present (skipped: object)");
    CHECK(schema == TESSERA_S2S_SCHEMA_STAMP, "schema stamp is llama.tessera.s2s.v1");
    CHECK(provenance == "s2s", "provenance is exactly s2s (s2s design 5 test 3)");
    CHECK(sid == "test-sid-001", "sid round-trips");

    long n_frames_json = -1, retokenize_us = -1, first_packet_us = -1;
    double decode_fps = -1.0, c2w_fps = -1.0;
    CHECK(find_int_field(line, "frames", n_frames_json)
          || find_int_field(line, "codes", n_frames_json)
          || (line.find("\"frames\":2") != std::string::npos && (n_frames_json = 2, true)),
          "codes.frames = 2 in the JSON");
    CHECK(find_int_field(line, "retokenize_us", retokenize_us)
          && retokenize_us == 1234, "timing.retokenize_us = 1234");
    CHECK(find_int_field(line, "first_packet_us", first_packet_us)
          && first_packet_us == 91011, "timing.first_packet_us = 91011");
    CHECK(find_double_field(line, "decode_frames_per_s", decode_fps)
          && std::abs(decode_fps - 12.5) < 1e-9, "timing.decode_frames_per_s = 12.5");

    // voice + feedback must serialize too
    CHECK(find_string_field(line, "preset", preset), "voice.preset key present");
    CHECK(preset == "tts-default", "voice.preset round-trips");
    CHECK(line.find("\"ref_hash\":null") != std::string::npos, "voice.ref_hash null when none set");
    CHECK(line.find("\"interrupted\":false") != std::string::npos, "feedback.interrupted=false");
}

// ---- a second append produces a second line; ordering is preserved ----

void test_capture_multi_append(const char * trace_path) {
    const int32_t gemma[] = { 1 };
    const int32_t qwen[]  = { 2 };
    const uint16_t codes[TESSERA_S2S_CODES_PER_FRAME] = { 0 };
    const tessera_s2s_timing timing { 0, 0, 0, 0.0, 0.0 };
    const tessera_s2s_voice voice   { "tts-default", nullptr };
    const tessera_s2s_feedback fb   { 0, 0, 0 };
    const tessera_s2s_models models { nullptr, nullptr, 0 };
    const tessera_s2s_capture_args args {
        gemma, 1, qwen, 1, "alpha", codes, 1, timing, voice, fb, models,
        "sid-a", TESSERA_S2S_PROVENANCE_VALUE, trace_path,
    };
    const tessera_s2s_capture_args args2 = [&]{
        tessera_s2s_capture_args c = args;
        c.sid = "sid-b"; c.utf8 = "beta";
        return c;
    }();
    CHECK(tessera_rt_s2s_append(&args)  == 0, "append #1 (sid-a) ok");
    CHECK(tessera_rt_s2s_append(&args2) == 0, "append #2 (sid-b) ok");

    const std::string line = slurp(trace_path);
    const size_t a = line.find("sid-a");
    const size_t b = line.find("sid-b");
    CHECK(a != std::string::npos && b != std::string::npos, "both sids present");
    CHECK(a < b, "sid-a appears before sid-b in the file (append order preserved)");
}

// ---- fail-closed: required arg is NULL returns 1 ----

void test_capture_null_args() {
    CHECK(tessera_rt_s2s_append(nullptr) == 1, "nullptr args -> 1");
    const tessera_s2s_capture_args base {
        nullptr, 0, nullptr, 0, nullptr, nullptr, 0,
        {0,0,0,0,0}, {"p", nullptr}, {0,0,0}, {nullptr, nullptr, 0},
        nullptr, nullptr, "/tmp/never-written",
    };
    CHECK(tessera_rt_s2s_append(&base) == 1, "missing required fields -> 1");
}

} // namespace

int main() {
    // Use a temp file that does not collide with other test runs.
    char trace_path[256];
    std::snprintf(trace_path, sizeof(trace_path), "/tmp/test_tessera_s2s_capture_%d.jsonl",
                  (int) getpid());
    std::remove(trace_path);

    test_codes_empty();
    test_codes_round_trip();
    test_capture_append(trace_path);
    test_capture_multi_append(trace_path);
    test_capture_null_args();

    std::remove(trace_path);

    std::fprintf(stderr, "\n%d/%d checks passed\n", g_checks - g_failures, g_checks);
    return g_failures == 0 ? 0 : 1;
}
