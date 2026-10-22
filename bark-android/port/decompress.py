"""Decompress a .bark file into a stock HF ParakeetTDT checkpoint (exact weights, no requant)."""
import json
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).parent))
from bark_loader import load_state_dict, load_model

out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "bark-hf")
out_dir.mkdir(exist_ok=True)

sd, cfg = load_state_dict("model.bark")
print("config:", json.dumps(cfg)[:400])
model = load_model("model.bark")  # builds ParakeetForTDT, validates strict load
model.save_pretrained(out_dir)
print("saved to", out_dir)
print("params:", sum(p.numel() for p in model.parameters()) / 1e6, "M")
