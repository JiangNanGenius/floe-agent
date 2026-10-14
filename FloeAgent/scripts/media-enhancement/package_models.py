#!/usr/bin/env python3
"""Compile converted Core ML packages and build installable model bundles.

For each converted model directory (produced by convert_rife.py /
convert_realesrgan.py) this script:

  1. compiles `model.mlpackage` to `model.mlmodelc` with the host
     `coremlcompiler` (the same artifact the app installs); with
     `--reuse-compiled` an existing compiled model is reused byte-for-byte
     instead (for notice-only bundle regeneration);
  2. renders readiness fixtures from the conversion reference tensors
     (`fixtures/*.png`, `fixtures/expected.png`);
  3. writes `manifest.json` (every bundled byte with sha256), `PROVENANCE.json`
     (weights and architecture licenses recorded separately) and copies the
     staged upstream notice file into `LICENSE.txt`;
  4. copies the bundle into the artifacts `bundles/` directory and prints a
     sha256 manifest of the whole bundle.

Required notices are fail-closed: every model must have a non-empty
`<model-dir>.LICENSE` staged by `fetch_assets.py` containing the expected
upstream license markers. With `--provenance` the license bytes are also
verified against the hash recorded by the fetch. The packager never invents a
missing license.

Nothing is published: the bundles stay under Local/Artifacts and are only
installed through `ModelArtifactStore.installLocalBundle` for qualification.

Usage:
  python3 package_models.py --models <converted-models-dir> \
      --bundles <artifacts-bundles-dir> \
      --licenses <fetch-licenses-dir> [--provenance <fetch-provenance.json>] \
      [--reuse-compiled] [--reuse-report <path>]
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import sha256_file, write_json  # noqa: E402

MODEL_SPECS = [
    {
        "directory": "floe-model-rife-v4",
        "bundle": "floe-model-rife-v4",
        "fixtures": [("frame0.npy", "frame0.png"), ("frame1.npy", "frame1.png")],
        "expected": "coreml_output.npy",
        "licenseMarkers": ["MIT License", "Practical-RIFE"],
    },
    {
        "directory": "floe-model-realesrgan-x4plus",
        "bundle": "floe-model-realesrgan-x4plus",
        "fixtures": [("input.npy", "input.png")],
        "expected": "coreml_output.npy",
        "licenseMarkers": ["BSD 3-Clause", "Apache License", "BasicSR", "Real-ESRGAN"],
    },
    {
        "directory": "floe-model-realesrgan-x2plus",
        "bundle": "floe-model-realesrgan-x2plus",
        "fixtures": [("input.npy", "input.png")],
        "expected": "coreml_output.npy",
        "licenseMarkers": ["BSD 3-Clause", "Apache License", "BasicSR", "Real-ESRGAN"],
    },
]


def compile_package(package: pathlib.Path, destination: pathlib.Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    environment = dict(os.environ)
    if "DEVELOPER_DIR" not in environment:
        for candidate in ("/Applications/Xcode.app/Contents/Developer",):
            if pathlib.Path(candidate).exists():
                environment["DEVELOPER_DIR"] = candidate
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package), str(destination.parent)],
        capture_output=True,
        text=True,
        env=environment,
    )
    if result.returncode != 0:
        raise SystemExit(f"coremlcompiler failed for {package.name}: {result.stderr.strip()[:500]}")
    if not destination.exists():
        raise SystemExit(f"coremlcompiler produced no output for {package.name}")


def render_npy(npy: pathlib.Path, png: pathlib.Path) -> None:
    array = np.load(npy)
    if array.ndim == 4:
        array = array[0]
    if array.shape[0] in (1, 3, 4) and array.ndim == 3:
        array = np.transpose(array, (1, 2, 0))
    array = np.clip(np.rint(array.astype(np.float64)), 0, 255).astype(np.uint8)
    if array.ndim == 2:
        array = np.stack([array] * 3, axis=2)
    if array.shape[2] >= 3:
        image = Image.fromarray(array[..., :3], mode="RGB")
    else:
        image = Image.fromarray(np.stack([array[..., 0]] * 3, axis=2), mode="RGB")
    png.parent.mkdir(parents=True, exist_ok=True)
    image.save(png, format="PNG", optimize=False)


def required_notice(spec: dict, licenses: pathlib.Path) -> pathlib.Path:
    """Return the staged notice file for a model, fail-closed when unusable.

    No `--licenses` directory, a missing/empty file, or missing upstream
    markers aborts the packaging instead of producing a bundle whose
    PROVENANCE.json would claim `licenseFile: null`.
    """
    candidate = licenses / f"{spec['directory']}.LICENSE"
    if not candidate.exists():
        raise SystemExit(
            f"missing required notice {candidate}; run fetch_assets.py --licenses "
            "first (the packager does not fabricate a license)"
        )
    text = candidate.read_text()
    if not text.strip():
        raise SystemExit(f"required notice {candidate} is empty")
    missing = [marker for marker in spec["licenseMarkers"] if marker not in text]
    if missing:
        raise SystemExit(f"required notice {candidate} is missing upstream markers: {missing}")
    return candidate


def verify_notice_provenance(spec: dict, notice: pathlib.Path, provenance: dict | None) -> dict:
    """With --provenance, prove the notice bytes came from the fetch staging."""
    if provenance is None:
        return {"verified": False, "reason": "no --provenance supplied"}
    entry = (provenance.get("licenseFiles") or {}).get(notice.name)
    if not entry:
        raise SystemExit(f"{notice.name} is not staged by fetch_assets.py --licenses (refusing manual file)")
    digest = sha256_file(notice)
    if digest != entry.get("sha256"):
        raise SystemExit(
            f"{notice.name} sha256 {digest} does not match the fetch-staged hash "
            f"{entry.get('sha256')}; re-run fetch_assets.py"
        )
    return {"verified": True, "fetchStagedSha256": entry.get("sha256")}


def bundle_files(bundle: pathlib.Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_dir():
            continue
        files[path.relative_to(bundle).as_posix()] = sha256_file(path)
    return files


def build_bundle(spec: dict, models: pathlib.Path, bundles: pathlib.Path, licenses: pathlib.Path,
                 provenance: dict | None, reuse_compiled: bool) -> tuple[dict, dict]:
    source = models / spec["directory"]
    contract = json.loads((source / "contract.json").read_text())
    bundle = bundles / spec["bundle"]
    old_files = bundle_files(bundle) if bundle.exists() else {}

    preserved_compiled: pathlib.Path | None = None
    if reuse_compiled:
        existing_compiled = bundle / "model.mlmodelc"
        if not existing_compiled.is_dir():
            raise SystemExit(f"--reuse-compiled: {existing_compiled} does not exist")
        preserved_compiled = pathlib.Path(tempfile.mkdtemp(prefix="floe-model-keep-")) / "model.mlmodelc"
        shutil.copytree(existing_compiled, preserved_compiled, symlinks=True)

    notice = required_notice(spec, licenses)
    notice_verification = verify_notice_provenance(spec, notice, provenance)

    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)
    if reuse_compiled and preserved_compiled is not None:
        shutil.copytree(preserved_compiled, bundle / "model.mlmodelc", symlinks=True)
        shutil.rmtree(preserved_compiled.parent, ignore_errors=True)
    else:
        compile_package(source / "model.mlpackage", bundle / "model.mlmodelc")

    contract["readinessTolerance"] = 0.03
    contract["bundleLayout"] = "model.mlmodelc + fixtures + manifest.json"
    write_json(bundle / "contract.json", contract)
    fixtures = bundle / "fixtures"
    for npy_name, png_name in spec["fixtures"]:
        render_npy(source / "reference" / npy_name, fixtures / png_name)
    render_npy(source / "reference" / spec["expected"], fixtures / "expected.png")

    shutil.copyfile(notice, bundle / "LICENSE.txt")
    notice_sha = sha256_file(bundle / "LICENSE.txt")

    provenance_payload = {
        "id": contract["id"],
        "version": contract["version"],
        "capability": contract["capability"],
        "scaleFactor": contract.get("scaleFactor"),
        "tileSize": contract.get("tileSize"),
        "source": contract.get("source"),
        "sourceCommit": contract.get("sourceCommit"),
        "weightsSha256": contract.get("weightsSha256") or contract.get("flownetSha256"),
        "license": contract.get("license"),
        "licenseEvidence": contract.get("licenseEvidence"),
        "licenseFile": "LICENSE.txt",
        "licenseSha256": notice_sha,
        "noticeProvenance": notice_verification,
        "convertedBy": contract.get("convertedBy"),
        "coremltools": contract.get("coremltools"),
        "torch": contract.get("torch"),
        "conversionReference": {
            "maxAbsDiff": json.loads((source / "reference" / "comparison.json").read_text())["maxAbsDiff"],
            "psnr": json.loads((source / "reference" / "comparison.json").read_text())["psnr"],
        },
    }
    # Code (architecture) and weights licenses are recorded separately: the
    # notice file carries both texts, but the provenance must not collapse them.
    if provenance is not None:
        basicr = provenance.get("basicr") or {}
        practical = provenance.get("practicalRife") or {}
        realesrgan = provenance.get("realesrgan") or {}
        if spec["directory"] == "floe-model-rife-v4":
            provenance_payload["weightsLicense"] = practical.get("weightsLicense")
            provenance_payload["weightsLicenseEvidence"] = practical.get("weightsLicenseEvidence")
        else:
            provenance_payload["weightsLicense"] = realesrgan.get("weightsLicense")
            provenance_payload["weightsLicenseStatus"] = realesrgan.get("weightsLicenseStatus")
            provenance_payload["weightsLicenseEvidence"] = realesrgan.get("weightsLicenseEvidence")
            provenance_payload["architecture"] = {
                "project": basicr.get("repo"),
                "tag": basicr.get("tag"),
                "commit": basicr.get("commit"),
                "license": basicr.get("license"),
                "file": "basicsr/archs/rrdbnet_arch.py",
                "fileSha256": (basicr.get("files") or {}).get("basicsr/archs/rrdbnet_arch.py", {}).get("sha256"),
                "helperFile": "basicsr/archs/arch_util.py",
                "helperFileSha256": (basicr.get("files") or {}).get("basicsr/archs/arch_util.py", {}).get("sha256"),
                "licenseFile": "LICENSE.txt",
                "licenseFileSha256": (basicr.get("files") or {}).get("LICENSE.txt", {}).get("sha256"),
            }
    write_json(bundle / "PROVENANCE.json", provenance_payload)

    files = []
    for relative, digest in bundle_files(bundle).items():
        files.append({
            "path": relative,
            "sha256": digest,
            "sizeBytes": (bundle / relative).stat().st_size,
        })
    manifest = {
        "id": contract["id"],
        "version": contract["version"],
        "capability": contract["capability"],
        "license": contract.get("license"),
        "files": files,
    }
    write_json(bundle / "manifest.json", manifest)
    total = sum(item["sizeBytes"] for item in files)
    summary = {
        "bundle": spec["bundle"],
        "files": len(files),
        "bytes": total,
        "manifestSha256": sha256_file(bundle / "manifest.json"),
        "license": contract.get("license"),
        "notice": "LICENSE.txt",
        "noticeSha256": notice_sha,
        "compiledReused": reuse_compiled,
        "noticeProvenanceVerified": notice_verification.get("verified", False),
    }

    new_files = bundle_files(bundle)
    comparison = {
        "oldManifestSha256": old_files.get("manifest.json"),
        "newManifestSha256": summary["manifestSha256"],
        "changed": [
            {"path": path, "oldSha256": old_files[path], "newSha256": new_files[path]}
            for path in sorted(set(old_files) & set(new_files))
            if old_files[path] != new_files[path]
        ],
        "unchanged": [path for path in sorted(set(old_files) & set(new_files)) if old_files[path] == new_files[path]],
        "added": [path for path in sorted(set(new_files) - set(old_files))],
        "removed": [path for path in sorted(set(old_files) - set(new_files))],
    }
    model_and_fixtures_unchanged = all(
        old_files[path] == new_files.get(path)
        for path in old_files
        if path.startswith("model.mlmodelc/") or path.startswith("fixtures/")
    ) and not any(path.startswith("model.mlmodelc/") or path.startswith("fixtures/")
                  for path in comparison["removed"])
    comparison["modelAndFixtureBytesUnchanged"] = model_and_fixtures_unchanged
    return summary, comparison


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True)
    parser.add_argument("--bundles", required=True)
    parser.add_argument("--licenses", required=True,
                        help="directory with <model-dir>.LICENSE notices staged by fetch_assets.py")
    parser.add_argument("--provenance", help="fetch provenance.json; verifies the notice file hashes")
    parser.add_argument("--reuse-compiled", action="store_true",
                        help="reuse each existing bundle's model.mlmodelc instead of recompiling")
    parser.add_argument("--reuse-report", help="write the old/new bundle file hash mapping here")
    parser.add_argument("--allow-model-bytes-change", action="store_true",
                        help="do not abort when --reuse-compiled finds changed model/fixture bytes")
    args = parser.parse_args()
    models = pathlib.Path(args.models).resolve()
    bundles = pathlib.Path(args.bundles).resolve()
    licenses = pathlib.Path(args.licenses).resolve()
    bundles.mkdir(parents=True, exist_ok=True)
    provenance = json.loads(pathlib.Path(args.provenance).read_text()) if args.provenance else None
    report = []
    comparisons: dict[str, dict] = {}
    for spec in MODEL_SPECS:
        if not (models / spec["directory"]).exists():
            raise SystemExit(f"missing converted model {spec['directory']}")
        summary, comparison = build_bundle(spec, models, bundles, licenses, provenance, args.reuse_compiled)
        report.append(summary)
        comparisons[spec["bundle"]] = comparison
        if args.reuse_compiled and not comparison["modelAndFixtureBytesUnchanged"] and not args.allow_model_bytes_change:
            raise SystemExit(
                f"{spec['bundle']}: --reuse-compiled found changed model/fixture bytes; "
                "refusing to silently ship different model bytes"
            )
    write_json(bundles / "BUNDLES.json", {"bundles": report})
    if args.reuse_report:
        write_json(pathlib.Path(args.reuse_report), {
            "reuseCompiled": args.reuse_compiled,
            "bundles": comparisons,
        })
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
