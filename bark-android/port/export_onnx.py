"""Export Underdog Bark 3.0 (HF ParakeetForTDT, exact decompressed weights) to ONNX.

Produces a self-contained contract for an on-device greedy-TDT decoder:
  encoder.onnx:  fbank [N,T,128] -> hidden [N,T',640]   (encoder + projector)
  predict.onnx:  (last_token i64[N], h f32[2,N,640], c f32[2,N,640]) -> (out f32[N,640], h, c)
  joint.onnx:    (pred f32[N,640], enc f32[N,640]) -> (token_logits f32[N,8193], dur_logits f32[N,5])

No quantization, no weight changes: safetensors -> ONNX initializers verbatim (fp32).
"""
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).parent))
from bark_loader import load_model

OUT = Path("onnx")
OUT.mkdir(exist_ok=True)


class EncoderWrapper(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.encoder, self.projector = m.encoder, m.encoder_projector

    def forward(self, features):  # [N, T, 128]
        return self.projector(self.encoder(features, attention_mask=None).last_hidden_state)


class PredictWrapper(torch.nn.Module):
    """Stateful streaming prediction network: one token step at a time."""

    def __init__(self, m):
        super().__init__()
        self.embedding = m.decoder.embedding
        self.lstm = m.decoder.lstm
        self.projector = m.decoder.decoder_projector

    def forward(self, last_token, h, c):  # last_token: i64[N]
        x = self.embedding(last_token).unsqueeze(1)  # [N,1,640]
        out, (h, c) = self.lstm(x, (h, c))
        return self.projector(out.squeeze(1)), h, c


class JointWrapper(torch.nn.Module):
    """Per-frame joint: bypasses the [N,T,D] broadcast, computes a single frame."""

    def __init__(self, m):
        super().__init__()
        self.activation = m.joint.activation
        self.head = m.joint.head

    def forward(self, pred, enc):  # both [N, 640]
        x = self.activation(pred + enc)
        logits = self.head(x)  # [N, vocab + 5]
        return logits[:, :-5], logits[:, -5:]


def export(name, model, args, dynamic=None):
    p = OUT / f"{name}.onnx"
    torch.onnx.export(
        model, args, str(p), opset_version=17, dynamo=False,
        dynamic_axes=dynamic or {},
        input_names=[a[0] if isinstance(a, tuple) else f"in{i}" for i, a in enumerate(args)],
    )
    print("wrote", p)


def main():
    m = load_model("model.bark", device="cpu", dtype=torch.float32)

    with torch.inference_mode():
        enc = EncoderWrapper(m)
        x = torch.randn(2, 256, 128)
        enc_out = enc(x)
        print("encoder out:", tuple(enc_out.shape))

        pred = PredictWrapper(m)
        tok = torch.tensor([5], dtype=torch.int64)
        h = torch.zeros(2, 1, 640)
        c = torch.zeros(2, 1, 640)
        p_out, h2, c2 = pred(tok, h, c)
        print("predict out:", tuple(p_out.shape), tuple(h2.shape))

        joint = JointWrapper(m)
        j_pred = torch.randn(1, 640)
        j_enc = torch.randn(1, 640)
        tl, dl = joint(j_pred, j_enc)
        print("joint out:", tuple(tl.shape), tuple(dl.shape))

        export("encoder", enc, (x,), dynamic={"in0": {0: "N", 1: "T"}})
        export("predict", pred, (tok, h, c),
               dynamic={"in0": {0: "N"}, "in1": {0: "N"}, "in2": {0: "N"}})
        export("joint", joint, (j_pred, j_enc), dynamic={"in0": {0: "N"}, "in1": {0: "N"}})


if __name__ == "__main__":
    main()
