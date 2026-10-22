"""Verify ONNX pipeline == official loader. Greedy TDT decoding over onnxruntime."""
import sys
import urllib.request
from pathlib import Path

import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch

sys.path.insert(0, str(Path(__file__).parent))

WAV = "jfk.wav"
if not Path(WAV).is_file():
    urllib.request.urlretrieve("https://huggingface.co/datasets/Xenova/transformers.js-docs/resolve/main/jfk.wav", WAV)


def load_tokens(path="tokens_v3.txt"):
    toks = {}
    for line in open(path, encoding="utf-8"):
        s, i = line.rsplit(" ", 1)
        toks[int(i)] = s
    return toks


def main():
    wave, sr = sf.read(WAV, dtype="float32", always_2d=True)
    wave = wave.mean(1)
    if sr != 16000:
        import soxr
        wave = soxr.resample(wave, sr, 16000)
        sr = 16000
    print(f"audio: {len(wave)/sr:.1f}s @ {sr}Hz")

    # --- reference: official loader (torch) ---
    from bark_loader import transcribe
    ref = transcribe(__import__("bark_loader").load_model("model.bark"), wave, sr)
    print("REF :", ref)

    # --- ONNX path ---
    from transformers import AutoProcessor
    proc = AutoProcessor.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
    padded = np.concatenate([np.zeros(4000, np.float32), wave])  # 0.25s pad, official setting
    inp = proc([padded], sampling_rate=16000, return_tensors="pt", padding=True)
    feats = inp["input_features"].numpy()  # [1, T, 128]
    print("feats:", feats.shape, "mask" in inp)

    so = ort.SessionOptions()
    enc = ort.InferenceSession("onnx/encoder.onnx", so, providers=["CPUExecutionProvider"])
    pred = ort.InferenceSession("onnx/predict.onnx", so, providers=["CPUExecutionProvider"])
    joint = ort.InferenceSession("onnx/joint.onnx", so, providers=["CPUExecutionProvider"])

    hidden = enc.run(None, {enc.get_inputs()[0].name: feats})[0]  # [1, T', 640]
    T = hidden.shape[1]
    print("encoder frames:", T)

    BLANK = 8192
    toks = load_tokens()
    h = np.zeros((2, 1, 640), np.float32)
    c = np.zeros((2, 1, 640), np.float32)
    last = np.array([[0]], np.int64)  # decoder_start_token (pad id 2? check gen config)
    from transformers import GenerationConfig
    gc = GenerationConfig.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
    start_id = gc.decoder_start_token_id
    print("decoder_start_token_id:", start_id)
    last = np.array([start_id], np.int64)

    emitted = []
    t = 0
    pred_ran = False
    while t < T:
        # blanks reuse the cached prediction net output; first step always runs
        if not pred_ran or last[0] != BLANK:
            p_out, h, c = pred.run(None, {"in0": last, "in1": h, "in2": c})
            pred_ran = True
        tl, dl = joint.run(None, {"in0": p_out, "in1": hidden[:, t]})
        tok_id = int(tl[0].argmax())
        dur = int(dl[0].argmax())
        if tok_id == BLANK and dur == 0:
            dur = 1
        if tok_id != BLANK:
            emitted.append(tok_id)
        last = np.array([tok_id], np.int64)
        t += dur

    text = proc.tokenizer.decode(emitted, skip_special_tokens=True).strip()
    print("ONNX:", text)
    print("MATCH" if text == ref else "DIFF")


if __name__ == "__main__":
    main()
