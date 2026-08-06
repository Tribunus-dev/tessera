// tessera-s2s-capture.h - per-utterance s2s record append hook (s2s design 4.1).
//
// Schema: llama.tessera.s2s.v1 (NDJSON, one record per utterance, written
// by tessera_rt_s2s_append into a TesseraTraceStore traces-s2s-*.jsonl
// family file). The Swift side TesseraS2SRecord reads the same schema; the
// zlib+base64 codes codec is bit-compatible so either side can decode a
// record the other wrote.
//
// C-side entry point for the runtime capture path: after every complete
// 16-codebook frame the s2s CLI (or the future Studio audio node) calls
// tessera_rt_s2s_append to flush the captured per-utterance data. Failures
// return a non-zero code; the caller treats that as exit 5 (capture-write
// failure) per the s2s CLI exit code contract.
//
// The header is C-callable and dependency-light: <stdint.h> plus a forward
// struct of plain-old-data fields, so the Swift side can later call it
// through a C bridge without a C++ ABI.

#ifndef TESSERA_S2S_CAPTURE_H
#define TESSERA_S2S_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One frame = codebook 0 (semantic) plus acoustic layers 1..15.
#define TESSERA_S2S_CODES_PER_FRAME 16

// Schema + provenance stamps. These are the byte-exact strings the Swift
// TesseraS2SRecord reads; they MUST match llama.tessera.s2s.v1 and "s2s".
#define TESSERA_S2S_SCHEMA_STAMP     "llama.tessera.s2s.v1"
#define TESSERA_S2S_PROVENANCE_VALUE "s2s"

// Timing block, microseconds + frames/second rates (s2s design 4.1).
typedef struct tessera_s2s_timing {
    int64_t retokenize_us;        // UTF-8 -> Qwen BPE retokenize latency
    int64_t talker_ttft_us;       // time to first codebook-0 token from prefill end
    int64_t first_packet_us;     // first PCM packet written from code2wav
    double  decode_frames_per_s; // talker throughput (frames / s)
    double  code2wav_frames_per_s;// code2wav throughput (frames / s)
} tessera_s2s_timing;

// Voice configuration: preset id (always set), reference-audio content hash
// (NULL when no reference; cloning is on indefinite hold so this is normally
// NULL).
typedef struct tessera_s2s_voice {
    const char * preset;     // never NULL
    const char * ref_hash;   // NULL when no reference audio
} tessera_s2s_voice;

// Implicit feedback. All three flags default to 0 (false) at record write.
typedef struct tessera_s2s_feedback {
    int interrupted;
    int regenerated;
    int replayed;
} tessera_s2s_feedback;

// Source-manifest lineage. Values are digest hex of the producing assets,
// keyed by role (e.g. "talker", "code2wav"). Both arrays are non-NULL and
// have matching length; the function joins them into a JSON object.
typedef struct tessera_s2s_models {
    const char * const * keys;   // n_keys entries
    const char * const * values; // n_keys entries
    int32_t n_keys;
} tessera_s2s_models;

// Per-call arguments. All pointer fields are read-only; the function
// copies what it needs into the on-disk record.
typedef struct tessera_s2s_capture_args {
    // Text: Gemma token ids, post-retokenize Qwen ids, exact UTF-8 string.
    const int32_t * gemma_tokens;
    int32_t        gemma_tokens_n;
    const int32_t * qwen_ids;
    int32_t        qwen_ids_n;
    const char    * utf8;          // the exact UTF-8 answer Gemma produced

    // Codes: frame-major, n_frames * 16 uint16 values (codebook 0 first,
    // then acoustic layers 1..15 per frame).
    const uint16_t * codes_frame;
    int32_t         n_frames;

    // Sidecar data.
    tessera_s2s_timing  timing;
    tessera_s2s_voice   voice;
    tessera_s2s_feedback feedback;
    tessera_s2s_models  models;

    // Stamp + identity.
    const char * sid;         // device-local UUID; never NULL
    const char * provenance;  // typically TESSERA_S2S_PROVENANCE_VALUE; never NULL
    const char * trace_path;  // output JSONL path; appended-to (one line per call)
} tessera_s2s_capture_args;

// Append one NDJSON record. Returns 0 on success, non-zero (1..5) on
// failure: 1 = null/empty required arg, 2 = zlib failure, 3 = I/O open
// failure, 4 = I/O write failure, 5 = encode failure.
int tessera_rt_s2s_append(const tessera_s2s_capture_args * args);

// Standalone zlib+base64 encoder used by the capture path; also exported
// for the CLI self-test (s2s design 5 golden parity Test 2). Writes a
// "zlib_b64" string into out_b64 (caller-owned, must hold at least
// 4 * (n_bytes + 64) / 3 + 8 bytes). Returns the number of base64 chars
// written (excluding the NUL), or 0 on failure.
int tessera_s2s_encode_codes_b64(const uint16_t * codes_frame,
                                 int32_t         n_frames,
                                 char          * out_b64,
                                 int32_t         out_b64_cap);

// Standalone decoder. Parses a zlib_b64 string back into the frame-major
// 16-codes-per-frame layout. Returns the number of frames decoded, or -1
// on failure (bad base64, bad zlib, payload not a multiple of
// TESSERA_S2S_CODES_PER_FRAME * 2 bytes, or output cap too small).
int tessera_s2s_decode_codes_b64(const char * zlib_b64,
                                 int32_t     expected_frames,
                                 uint16_t  * out_codes,
                                 int32_t     out_codes_cap_frames);

#ifdef __cplusplus
}
#endif

#endif // TESSERA_S2S_CAPTURE_H
