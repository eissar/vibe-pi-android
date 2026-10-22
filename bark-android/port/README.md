# Underdog Bark 3.0 → Android ONNX port

Exact-weight port of `ConwayResearch/Underdog-Bark-3.0` (a finetune of
`nvidia/parakeet-tdt-0.6b-v3`, HF `ParakeetForTDT`) to ONNX for on-device
inference with `onnxruntime-android`. **No model or quantization changes**:
the `.bark` container's ANS-coded weights decompress bit-exactly to fp32
("the weights you get are the weights that were evaluated"), and those fp32
tensors are what land in the ONNX initializers.

## Status

- [x] `model.bark` → HF checkpoint (exact fp32), loads into stock
      `transformers.ParakeetForTDT` (627M params)
- [x] ONNX export: `encoder.onnx` (+ external data), `predict.onnx`,
      `joint.onnx`, `tokens.txt` (8193 tokens incl. `<blk>` 8192)
- [x] Verified: greedy-TDT decode over onnxruntime reproduces the official
      `bark_loader.transcribe` output **exactly** on the JFK sample
      (`verify.py` → `MATCH`)
- [ ] Kotlin: fbank frontend (spec below), greedy-TDT decoder (semantics below),
      mic capture, app integration in vibe-pi-android, model download

## Runtime artifacts (`onnx/`)

| file | shape contract |
|---|---|
| `encoder.onnx` | `in0` f32 `[N,T,128]` → `[N,T/8,640]` |
| `predict.onnx` | `in0` i64 `[N]` last token, `in1`/`in2` f32 `[2,N,640]` LSTM state → out f32 `[N,640]`, new h, c |
| `joint.onnx` | `in0` pred f32 `[N,640]`, `in1` enc frame f32 `[N,640]` → token logits `[N,8193]`, duration logits `[N,5]` |
| `tokens.txt` | token<space>id lines, `8192` = `<blk>` |

## Decoder semantics (verified; do not deviate)

Replicates `transformers` `ParakeetTDTGenerationMixin` + `ParakeetRNNTDecoderCache`:

1. LSTM state starts zero; feed `decoder_start_token_id` = **8192** (`<blk>`).
2. Per encoder frame `t`: run predict (see 3) → joint → token = argmax(token
   logits), duration = argmax(duration logits).
3. **Blank-skip rule**: the prediction network only runs when the previous
   sampled token was non-blank (or on the very first step). Blank tokens reuse
   the cached prediction output and do *not* touch the LSTM state.
4. If token == blank and duration == 0, force duration = 1.
5. `t += duration` (non-blank tokens may have duration 0 → they stay on the
   same frame and predict again). Stop when `t >= T`. Emit non-blank ids,
   detokenize with `tokens.txt`.

## Feature frontend (for the Kotlin fbank)

Matches HF `ParakeetFeatureExtractor` (Parakeet v3 / Bark): 16 kHz mono,
128 mel bins, `n_fft` 512, `win_length` 400 (Hann), `hop_length` 160,
preemphasis 0.97, log (ln) mel, **per-feature-bin mean/var normalization over
time**, left-padded with 0.25 s of silence (the officially evaluated setting).
Subsampling factor 8. Sanity targets for the JFK sample after frontend:
`min ≈ -4.25, max ≈ 16.63, mean ≈ 0.0`.

## Reproduce

```bash
uv venv .venv && uv pip install --python .venv "transformers>=5.19" torch \
  constriction numpy soundfile soxr onnx onnxruntime librosa onnxscript
.venv/bin/python export_onnx.py   # ~2.4 GB fp32 artifacts in onnx/
.venv/bin/python verify.py        # prints MATCH when identical to reference
```

`model.bark`, `bark_loader.py` are from the HF repo; `jfk.wav` is fetched
by `verify.py`.

## Sizing note

fp32 = 2.4 GB on device (per the no-requant constraint). If that's ever
relaxed, fp16 (1.2 GB) or the official int8 dynamic quant path are drop-in
follow-ups; expect a small WER delta.
