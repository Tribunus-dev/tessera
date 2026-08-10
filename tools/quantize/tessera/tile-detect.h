#pragma once

//
// tile-detect.h
//
// Runtime GPU tile-geometry detection for the Tessera pack subcommand.
// ts_detect_tile_config() probes the host GPU (Apple Metal device family
// on macOS, Intel/integrated otherwise) and returns the ts_tile_config
// that matches its optimal page/lane geometry:
//   Apple Silicon (M1/M2/M3/M4+) -> T640 (radix-243)
//   Intel / non-Apple            -> T512 (2-bit)
//   unknown                      -> T640 (safe default)
//
// The detection is best-effort: if the probe fails (no Metal device, the
// backend symbols are unavailable, or the host is not Apple), the safe T640
// default is returned. Callers that want a specific geometry regardless of
// the host GPU pass it explicitly via --tile {t640|t512|t1024}.

// ggml-common.h only emits its C++ definitions when GGML_COMMON_DECL_CPP is
// defined before the include; without it the header is a no-op and ts_tile_config
// would be left undefined (it is returned by value below). Match the pattern
// used by tessera-ternary.h.
#ifndef GGML_COMMON_DECL_CPP
#  define GGML_COMMON_DECL_CPP
#  include "ggml-common.h"
#else
#  include "ggml-common.h"
#endif

// Probe the host GPU and return the recommended tile config. The returned
// struct is a value copy (no ownership). Always returns a usable config.
struct ts_tile_config ts_detect_tile_config();
