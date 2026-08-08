#!/usr/bin/env python3
"""c2w PCM parity: reference qwen_tts vocoder vs the C++ ggml forward.

Runs the HF Qwen3TTSTokenizerV2Model decoder (the qwen-tts package) on
the SAME deterministic pseudo codes the C++ test uses
(tests/test-qwen3tts-w8-parity.cpp check_code2wav_f32_forward), dumps
the reference PCM, and compares sample-by-sample against the C++ dump.

Producing the C++ dump:

    TESSERA_QWEN3TTS_C2W_PCM_OUT=/tmp/c2w-cpp-pcm.f32 \\
        ./build/bin/test-qwen3tts-w8-parity "" /path/to/c2w.gguf

Then:

    python3 tools/tessera/c2w_pcm_parity.py \\
        --hf-dir "/Volumes/Julian T7/models/qwen3-tts-model/speech_tokenizer" \\
        --cpp-pcm /tmp/c2w-cpp-pcm.f32

Without --cpp-pcm the script only writes the reference PCM
(--ref-out) + a 16-bit wav for listening.

The parity band accounts for the ggml conv path rounding im2col
patches to F16 (F32 kernel -> F16 im2col); the reference runs pure
F32 torch on CPU.

Requires: torch + qwen-tts in the environment (self-skips otherwise).
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path

N_CODEBOOKS = 16
CODEC_VOCAB = 2048
LCG_SEED    = 0x5eed1234  # matches the C++ test


def make_codes(n_frames: int) -> list[int]:
    """The exact LCG of check_code2wav_f32_forward (token order)."""
    s = LCG_SEED
    codes = []
    for _ in range(n_frames * N_CODEBOOKS):
        s = (s * 1664525 + 1013904223) & 0xFFFFFFFF
        codes.append((s >> 8) % CODEC_VOCAB)
    return codes


def read_f32(path: Path) -> list[float]:
    raw = path.read_bytes()
    n = len(raw) // 4
    return list(struct.unpack(f"<{n}f", raw[: n * 4]))


def write_wav(path: Path, samples: list[float], rate: int = 24000) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for s in samples:
            v = max(-1.0, min(1.0, s))
            frames += struct.pack("<h", int(round(v * 32767.0)))
        w.writeframes(bytes(frames))


def main() -> int:
    p = argparse.ArgumentParser(description="c2w PCM parity vs qwen_tts reference")
    p.add_argument("--hf-dir", required=True, type=Path,
                   help="speech_tokenizer HF dir (config.json + model.safetensors)")
    p.add_argument("--cpp-pcm", type=Path, default=None,
                   help="raw F32 PCM dump from the C++ test")
    p.add_argument("--frames", type=int, default=2,
                   help="number of 16-code frames (default 2, matches the C++ test)")
    p.add_argument("--ref-out", type=Path, default=Path("/tmp/c2w-ref-pcm.f32"),
                   help="where to write the reference F32 PCM")
    args = p.parse_args()

    try:
        import torch
        from qwen_tts.core.tokenizer_12hz.modeling_qwen3_tts_tokenizer_v2 import (
            Qwen3TTSTokenizerV2Model,
        )
    except Exception as e:
        print(f"c2w_pcm_parity: SKIP (torch/qwen_tts unavailable: {e})")
        return 0

    codes = make_codes(args.frames)
    print(f"c2w_pcm_parity: {args.frames} frames, first 8 codes {codes[:8]}")

    torch.set_grad_enabled(False)
    model = Qwen3TTSTokenizerV2Model.from_pretrained(
        str(args.hf_dir), torch_dtype=torch.float32)
    model.eval()

    # HF decode() takes [B, T, num_quantizers]
    audio_codes = torch.tensor(codes, dtype=torch.long).reshape(
        1, args.frames, N_CODEBOOKS)
    out = model.decode(audio_codes)
    ref = out.audio_values[0].to(torch.float32).numpy().tolist()
    print(f"c2w_pcm_parity: reference PCM n={len(ref)}")

    args.ref_out.write_bytes(struct.pack(f"<{len(ref)}f", *ref))
    write_wav(args.ref_out.with_suffix(".wav"), ref)
    print(f"c2w_pcm_parity: reference written to {args.ref_out} (+ .wav)")

    if args.cpp_pcm is None:
        print("c2w_pcm_parity: no --cpp-pcm given; reference-only mode")
        return 0

    cpp = read_f32(args.cpp_pcm)
    n = min(len(ref), len(cpp))
    if n == 0:
        print("c2w_pcm_parity: FAIL (empty PCM)")
        return 1
    print(f"c2w_pcm_parity: comparing n={n} "
          f"(ref={len(ref)}, cpp={len(cpp)})")

    max_abs = 0.0
    sum_abs = 0.0
    sum_r = sum_c = sum_rr = sum_cc = sum_rc = 0.0
    for i in range(n):
        r, c = ref[i], cpp[i]
        d = abs(r - c)
        max_abs = max(max_abs, d)
        sum_abs += d
        sum_r += r; sum_c += c
        sum_rr += r * r; sum_cc += c * c; sum_rc += r * c

    mean_abs = sum_abs / n
    cov  = sum_rc / n - (sum_r / n) * (sum_c / n)
    vr   = sum_rr / n - (sum_r / n) ** 2
    vc   = sum_cc / n - (sum_c / n) ** 2
    corr = cov / math.sqrt(vr * vc) if vr > 0 and vc > 0 else 0.0

    print(f"c2w_pcm_parity: max_abs_diff={max_abs:.6f} "
          f"mean_abs_diff={mean_abs:.6f} corr={corr:.6f}")

    # the defined band: F16 im2col rounding in the ggml conv path keeps
    # the diff well below signal scale; the waveform must stay nearly
    # perfectly correlated
    ok = True
    if not (max_abs < 0.1):
        print("c2w_pcm_parity: FAIL max_abs_diff >= 0.1"); ok = False
    if not (mean_abs < 0.01):
        print("c2w_pcm_parity: FAIL mean_abs_diff >= 0.01"); ok = False
    if not (corr > 0.999):
        print("c2w_pcm_parity: FAIL corr <= 0.999"); ok = False

    print("c2w_pcm_parity: PASS" if ok else "c2w_pcm_parity: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
