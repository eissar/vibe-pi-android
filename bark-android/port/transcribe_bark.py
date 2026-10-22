"""Run an original .bark model on CUDA, CPU or MPS using its official loader."""
import argparse
import importlib.util
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True, help='Folder containing model.bark and official bark_loader.py')
    parser.add_argument('--audio', required=True, help='Input audio file, e.g. recording.wav')
    parser.add_argument('--device', choices=['cuda', 'cpu', 'mps'], default='cuda')
    args = parser.parse_args()
    root = Path(args.model).expanduser().resolve()
    audio = Path(args.audio).expanduser().resolve()
    for path in [root / 'model.bark', root / 'bark_loader.py', audio]:
        if not path.is_file():
            parser.error(f'Missing file: {path}')

    import numpy as np
    import soundfile as sf
    import torch
    if args.device == 'cuda' and not torch.cuda.is_available():
        parser.error('CUDA is unavailable. Install a compatible PyTorch CUDA wheel, or explicitly choose --device cpu.')
    if args.device == 'mps' and not torch.backends.mps.is_available():
        parser.error('MPS is unavailable.')
    wave, sr = sf.read(str(audio), dtype='float32', always_2d=True)
    if not len(wave) or not np.isfinite(wave).all():
        parser.error('Audio must be nonempty and contain only finite samples.')
    spec = importlib.util.spec_from_file_location('official_bark', root / 'bark_loader.py')
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    model = loader.load_model(str(root / 'model.bark'), device=args.device, dtype=torch.float32)
    # Preserve official per-model padding defaults: Clean 0, standard/Plus 0.25s.
    print(loader.transcribe(model, wave.mean(1), sr))


if __name__ == '__main__':
    main()
