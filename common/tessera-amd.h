#pragma once

//
// tessera-amd.h
//
// Bridge between the tessera CLI (common_tessera_params AMD fields) and
// the ggml-amd backend's GGML_AMD_* environment variables. Called once
// before ggml_backend_load_all() so the CLI flags take precedence over
// any ambient env state.
//
// The env vars are set unconditionally for fields that have a non-empty
// value; empty strings are skipped so the backend's own defaults apply.
// Boolean fields (amd_xdna, amd_vulkan_fallback) are always set because
// they have a meaningful default (off/on).
//

struct common_tessera_params;

// Read the AMD fields from `params` and set the corresponding GGML_AMD_*
// environment variables. Safe to call multiple times; last write wins.
// No-op when the ggml-amd backend is not compiled in (the header is
// still includable; the function body is empty).
void tessera_amd_apply_config(const common_tessera_params & params);
