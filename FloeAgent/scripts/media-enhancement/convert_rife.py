#!/usr/bin/env python3
"""Convert the pinned RIFE 4.25 Lite checkpoint to Core ML.

Derived directly from the pinned 4.25.lite archive (IFNet_HDv3.py + flownet.pkl)
and the pinned Practical-RIFE commit's model/warplayer.py warp implementation.
No third-party pre-converted Core ML model is used.

Contract produced (fixed tile, image inputs, scalar timestep):
  input  "frame0", "frame1": ImageType RGB [1, 3, tile, tile], scale 1/255
  input  "timestep": TensorType [1, 1], phase in [0, 1] (0.5 = midpoint)
  output "frame": ImageType RGB, merged frame clamped to [0, 1] and scaled to 255

The network needs frequency-domain flow math; FLOAT16 compute precision was
measured to be unusable (see scratch evidence) and the conversion therefore
uses FLOAT32 compute precision.

Usage:
  python3 convert_rife.py --work <work-dir> --tile 256 --output <dir> \
      --fixture0 <i0.png> --fixture1 <i1.png>
"""
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import shutil
import sys

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import REFERENCE_SEED, max_mean_abs_diff, normalize_to_unit, sha256_file, write_json  # noqa: E402

import coremltools as ct  # noqa: E402
from PIL import Image  # noqa: E402

TRAINING_ONLY_PREFIXES = ("teacher.", "caltime.")


class RIFEExport(nn.Module):
    """Exact upstream Model.inference scale list [32, 16, 8, 4, 1] at scale 1.0."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.scale_list = [32.0, 16.0, 8.0, 4.0, 1.0]

    def forward(self, frame0, frame1, timestep):
        images = torch.cat((frame0, frame1), 1)
        _flow, _mask, merged = self.net(images, timestep, self.scale_list)
        return torch.clamp(merged[-1], 0.0, 1.0) * 255.0


def load_network(work: pathlib.Path):
    upstream = work / "upstream-practical-rife"
    rife_dir = work / "rife425lite"
    sys.path.insert(0, str(upstream))
    sys.path.insert(0, str(rife_dir))
    spec = importlib.util.spec_from_file_location("IFNet_HDv3", rife_dir / "IFNet_HDv3.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["IFNet_HDv3"] = module
    spec.loader.exec_module(module)
    net = module.IFNet().eval()
    state = torch.load(rife_dir / "flownet.pkl", map_location="cpu", weights_only=True)
    converted = {key.replace("module.", ""): value for key, value in state.items() if "module." in key}
    missing, unexpected = net.load_state_dict(converted, strict=False)
    inference_unexpected = [k for k in unexpected if not k.startswith(TRAINING_ONLY_PREFIXES)]
    if missing or inference_unexpected:
        raise SystemExit(f"state dict mismatch missing={missing[:4]} unexpected={inference_unexpected[:4]}")
    print(f"loaded {len(converted)} tensors ({len(unexpected)} training-only keys ignored)")
    return RIFEExport(net).eval()


def fixture_tile(path: pathlib.Path | None, tile: int, seed_offset: int) -> np.ndarray:
    if path is not None and path.exists():
        image = Image.open(path).convert("RGB")
        width, height = image.size
        left = max(0, (width - tile) // 2)
        top = max(0, (height - tile) // 2)
        image = image.crop((left, top, left + min(tile, width), top + min(tile, height)))
        if image.size != (tile, tile):
            image = image.resize((tile, tile), Image.BICUBIC)
        return np.asarray(image, dtype=np.uint8)
    generator = np.random.default_rng(REFERENCE_SEED + seed_offset)
    return generator.integers(0, 256, size=(tile, tile, 3), dtype=np.uint8)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", required=True)
    parser.add_argument("--tile", type=int, default=256)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fixture0")
    parser.add_argument("--fixture1")
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--phase", type=float, default=0.5)
    parser.add_argument("--source", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--license", default="MIT")
    parser.add_argument("--license-evidence", required=True)
    args = parser.parse_args()

    work = pathlib.Path(args.work).resolve()
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    tile = args.tile

    torch.manual_seed(REFERENCE_SEED)
    export = load_network(work)

    frame0_image = fixture_tile(pathlib.Path(args.fixture0) if args.fixture0 else None, tile, 0)
    frame1_image = fixture_tile(pathlib.Path(args.fixture1) if args.fixture1 else None, tile, 1)
    frame0 = torch.from_numpy(frame0_image.astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
    frame1 = torch.from_numpy(frame1_image.astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
    timestep = torch.tensor([[args.phase]], dtype=torch.float32)
    with torch.no_grad():
        torch_output = export(frame0, frame1, timestep)[0].permute(1, 2, 0).numpy()

    traced = torch.jit.trace(export, (frame0, frame1, timestep), strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="frame0", shape=(1, 3, tile, tile), scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
            ct.ImageType(name="frame1", shape=(1, 3, tile, tile), scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
            ct.TensorType(name="timestep", shape=(1, 1)),
        ],
        outputs=[ct.ImageType(name="frame", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
    )
    package = output / "model.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))

    prediction = mlmodel.predict(
        {
            "frame0": Image.fromarray(frame0_image),
            "frame1": Image.fromarray(frame1_image),
            "timestep": np.array([[args.phase]], dtype=np.float32),
        }
    )
    coreml_output = np.asarray(prediction["frame"], dtype=np.float32)[..., :3]
    comparison = max_mean_abs_diff(normalize_to_unit(torch_output), normalize_to_unit(coreml_output))

    reference_dir = output / "reference"
    reference_dir.mkdir(parents=True, exist_ok=True)
    np.save(reference_dir / "frame0.npy", frame0_image)
    np.save(reference_dir / "frame1.npy", frame1_image)
    np.save(reference_dir / "torch_output.npy", torch_output.astype(np.float32))
    np.save(reference_dir / "coreml_output.npy", coreml_output.astype(np.float32))
    contract = {
        "id": args.id,
        "version": args.version,
        "kind": "coreml",
        "capability": "video.interpolate",
        "tileSize": tile,
        "phase": args.phase,
        "scaleList": [32, 16, 8, 4, 1],
        "inputs": [
            {"name": "frame0", "type": "image", "shape": [1, 3, tile, tile], "colorLayout": "RGB", "scale": 1 / 255.0},
            {"name": "frame1", "type": "image", "shape": [1, 3, tile, tile], "colorLayout": "RGB", "scale": 1 / 255.0},
            {"name": "timestep", "type": "tensor", "shape": [1, 1], "range": [0, 1]},
        ],
        "outputs": [{"name": "frame", "type": "image", "colorLayout": "RGB", "scale": 1.0}],
        "normalization": "input RGB 8-bit pixel buffers, scale 1/255; output merged RGB frame at 0..255",
        "computePrecision": "FLOAT32",
        "flownetSha256": sha256_file(work / "rife425lite" / "flownet.pkl"),
        "license": args.license,
        "licenseEvidence": args.license_evidence,
        "source": args.source,
        "sourceCommit": args.source_commit,
        "convertedBy": "FloeAgent/scripts/media-enhancement/convert_rife.py",
        "coremltools": ct.__version__,
        "torch": torch.__version__,
    }
    write_json(output / "contract.json", contract)
    write_json(reference_dir / "comparison.json", comparison)
    print(f"{args.id}: maxAbsDiff={comparison['maxAbsDiff']:.6f} meanAbsDiff={comparison['meanAbsDiff']:.6f} psnr={comparison['psnr']:.2f}")
    print(f"saved {package}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
