#!/usr/bin/env python3
"""Convert the pinned Real-ESRGAN x2plus/x4plus checkpoints to Core ML.

The conversion is derived directly from the pinned upstream checkpoint and the
pinned BasicSR v1.4.2 RRDBNet architecture (see fetch_assets.py); no third-party
pre-converted Core ML model is used.

Contract produced (fixed tile, image input/output):
  input  "image":  ImageType RGB, shape [1, 3, tile, tile], scale 1/255
  output "image":  ImageType RGB, values clamped to [0, 1] and scaled by 255

Usage:
  python3 convert_realesrgan.py --weights <x4plus.pth> --scale 4 \
      --tile 256 --output <dir>
"""
from __future__ import annotations

import argparse
import pathlib
import sys

import numpy as np
import torch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import REFERENCE_SEED, max_mean_abs_diff, normalize_to_unit, sha256_bytes, sha256_file, write_json  # noqa: E402
from rrdbnet_arch import RRDBNet  # noqa: E402

import coremltools as ct  # noqa: E402
import torch.nn as nn  # noqa: E402
from PIL import Image  # noqa: E402


class ESRGANExport(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x), 0.0, 1.0) * 255.0


def load_network(weights: pathlib.Path, scale: int) -> RRDBNet:
    net = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=scale)
    checkpoint = torch.load(weights, map_location="cpu", weights_only=True)
    if not isinstance(checkpoint, dict):
        raise SystemExit("unexpected checkpoint payload")
    for key in ("params_ema", "params"):
        if key in checkpoint and isinstance(checkpoint[key], dict):
            state = checkpoint[key]
            break
    else:
        state = checkpoint
    if not any(k.startswith("conv_first") for k in state):
        raise SystemExit("checkpoint does not look like an RRDBNet state dict")
    missing, unexpected = net.load_state_dict(state, strict=False)
    if missing or unexpected:
        raise SystemExit(f"state dict mismatch missing={missing[:4]} unexpected={unexpected[:4]}")
    return net.eval()


def reference_image(fixture: pathlib.Path | None, tile: int) -> np.ndarray:
    if fixture is not None and fixture.exists():
        image = Image.open(fixture).convert("RGB")
        width, height = image.size
        left = max(0, (width - tile) // 2)
        top = max(0, (height - tile) // 2)
        image = image.crop((left, top, left + min(tile, width), top + min(tile, height)))
        if image.size != (tile, tile):
            image = image.resize((tile, tile), Image.BICUBIC)
        return np.asarray(image, dtype=np.uint8)
    generator = np.random.default_rng(REFERENCE_SEED)
    return generator.integers(0, 256, size=(tile, tile, 3), dtype=np.uint8)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True)
    parser.add_argument("--scale", required=True, type=int, choices=(2, 4))
    parser.add_argument("--tile", type=int, default=256)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fixture", help="optional PNG used for the reference comparison")
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--license", default="BSD-3-Clause")
    parser.add_argument("--license-evidence", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()

    weights = pathlib.Path(args.weights).resolve()
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    tile = args.tile

    torch.manual_seed(REFERENCE_SEED)
    net = load_network(weights, args.scale)
    export = ESRGANExport(net).eval()

    sample = reference_image(pathlib.Path(args.fixture) if args.fixture else None, tile)
    tensor = torch.from_numpy(sample.astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        torch_output = export(tensor)[0].permute(1, 2, 0).numpy()

    traced = torch.jit.trace(export, tensor, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, tile, tile), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="image_out", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
    )
    package = output / "model.mlpackage"
    if package.exists():
        import shutil

        shutil.rmtree(package)
    mlmodel.save(str(package))

    prediction = mlmodel.predict({"image": Image.fromarray(sample)})
    coreml_output = np.asarray(prediction["image_out"], dtype=np.float32)[..., :3]
    comparison = max_mean_abs_diff(normalize_to_unit(torch_output), normalize_to_unit(coreml_output))

    reference_dir = output / "reference"
    reference_dir.mkdir(parents=True, exist_ok=True)
    np.save(reference_dir / "input.npy", sample)
    np.save(reference_dir / "torch_output.npy", torch_output.astype(np.float32))
    np.save(reference_dir / "coreml_output.npy", coreml_output.astype(np.float32))
    contract = {
        "id": args.id,
        "version": args.version,
        "kind": "coreml",
        "capability": "video.superResolution",
        "scaleFactor": args.scale,
        "tileSize": tile,
        "inputs": [{"name": "image", "type": "image", "shape": [1, 3, tile, tile], "colorLayout": "RGB", "scale": 1 / 255.0}],
        "outputs": [{"name": "image_out", "type": "image", "colorLayout": "RGB", "scale": 1.0}],
        "normalization": "input RGB 8-bit pixel buffer, scale 1/255; output 8-bit RGB pixel buffer",
        "license": args.license,
        "licenseEvidence": args.license_evidence,
        "source": args.source,
        "sourceCommit": args.source_commit,
        "weightsSha256": sha256_file(weights),
        "weightsBytes": weights.stat().st_size,
        "convertedBy": "FloeAgent/scripts/media-enhancement/convert_realesrgan.py",
        "coremltools": ct.__version__,
        "torch": torch.__version__,
    }
    write_json(output / "contract.json", contract)
    write_json(reference_dir / "comparison.json", comparison)
    write_json(reference_dir / "input.sha256", {"sha256": sha256_bytes(sample.tobytes()), "shape": list(sample.shape), "dtype": str(sample.dtype)})
    print(f"{args.id}: maxAbsDiff={comparison['maxAbsDiff']:.6f} meanAbsDiff={comparison['meanAbsDiff']:.6f} psnr={comparison['psnr']:.2f}")
    print(f"saved {package}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
