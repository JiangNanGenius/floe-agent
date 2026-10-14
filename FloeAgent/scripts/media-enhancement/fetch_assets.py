#!/usr/bin/env python3
"""T2 media enhancement — pinned asset fetch, verification and license staging.

Downloads the exact upstream sources and weights that the Floe RIFE 4.25 Lite
and Real-ESRGAN x2plus/x4plus Core ML conversions are derived from, verifies
their SHA-256 hashes, writes a provenance manifest and composes the upstream
license/notice files the bundle packager copies into the installable bundles.

Nothing is published; the files stay under Local/Scratch and Local/Artifacts.

Usage:
    # full fresh run: weights + sources + licenses + provenance
    python3 fetch_assets.py --destination <downloads> --work <work> --licenses <licenses>

    # small-source-only run (no 157 MB weights; used to verify the pinned
    # source/license pins from a clean machine or in CI)
    python3 fetch_assets.py --destination <downloads> --work <work> \
        --licenses <licenses> --sources-only

    # read-only verification of an existing fetch (no writes, fail closed)
    python3 fetch_assets.py --destination <downloads> --work <work> \
        --licenses <licenses> --check

Provenance (fixed, do not substitute; see also verify_rrdbnet_source.py):
  * BasicSR RRDBNet architecture, Apache-2.0, tag v1.4.2 at immutable commit
    651835a1b9d38dbbdaf45750f56906be2364f01a. The `LICENSE` path in that repo
    is a directory; the actual license text file is `LICENSE.txt`.
  * Practical-RIFE reference code/weights, MIT. The pinned README states the
    trained-model links are under the same MIT license as the project.
  * Real-ESRGAN weights/checkpoints, BSD-3-Clause repository license. Upstream
    publishes no separate weights-specific grant; that limitation is recorded
    in the provenance and the bundle stays local/internal.

Every reviewed input has a pinned SHA-256; a missing or mismatching hash is a
hard failure (never an "expected hash None" first-fetch path).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import urllib.request
import zipfile

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

BASICSR_REPO = "XPixelGroup/BasicSR"
BASICSR_TAG = "v1.4.2"
BASICSR_COMMIT = "651835a1b9d38dbbdaf45750f56906be2364f01a"
BASICSR_FILES = {
    "basicsr/archs/rrdbnet_arch.py": "6aa8eb3f77e918b90eeff4ebfaf8745abe0c40eb8fcc03abbc1928693d70ab58",
    "basicsr/archs/arch_util.py": "45b322b874057c4bff382cc8f1b64554857b9aa4e0c47e73fe67e4afc0b28ac1",
    "LICENSE.txt": "5447872f21ddc29dc0dc060d5c885513c01c904e9da9931bba69898a6fb4d415",
    "VERSION": "b99b4c7cdf236f59bc9f65d963deaecae3b16a7dad87939cacb9057f7664daee",
}
BASICSR_LICENSE = "Apache-2.0"

PRACTICAL_RIFE_COMMIT = "bbfd2ea90910789a860ea3e2b32a240cd577b75e"
PRACTICAL_RIFE_FILES = {
    "LICENSE": "7932fb49341512b959b1744a6d9cbb39e5a1ec89da438a34d0454d5d8df9fecd",
    "README.md": "b695ac5d4a69c2f551512678883f8234d784c286d805ca546f4873cb465959b4",
    "model/warplayer.py": "feb3af9475b724749b023d1913c3b135431eff13d0045b8efb472a699058385f",
    "demo/i0.png": "a01f79bf3c485c6d59284f36c9ec7933598313ae847b0394acbc0c4573491687",
    "demo/i1.png": "7ba4a0f8eae5a62ce567ef2611349e56907e29b968b9da5d2e57a8f4525d51ea",
}
# "The content of these links is under the same MIT license as this project."
# (Practical-RIFE README, pinned commit, "Trained Model" section.)
PRACTICAL_RIFE_WEIGHTS_STATEMENT = (
    "The content of these links is under the same MIT license as this project."
)
RIFE_WEIGHTS_URL = (
    "https://drive.usercontent.google.com/download"
    "?id=1zlKblGuKNatulJNFf5jdB-emp9AqGK05&export=download&confirm=t"
)
RIFE_WEIGHTS_SHA256 = "e84366c23e0eb1a637a55aad2e4f3442ec2bf4c388043b4aabbf590be289e6e8"
RIFE_FLOWNET_SHA256 = "81cdba223fe72a120130cc8552e5d2ecac824259d406f0c15323b3decf96b8b1"
RIFE_VERSION = "4.25.lite"
RIFE_RELEASE_NOTE = "Practical-RIFE README: 4.25.lite - 2024.10.20"

REALESRGAN_COMMIT = "a4abfb2979a7bbff3f69f58f58ae324608821e27"
REALESRGAN_FILES = {
    "LICENSE": "4a699ec4863d96a91fc265948a0c90033f7e8735d515524dcf3444736406e0c2",
    "README.md": "d0a13607913ea94e65a91ac864b969683a41a45b0aec16e0ae64271649d0364d",
    "requirements.txt": "5944cac4c2c4d8ae27ccaa88435e870898d9859394f3a3fd80b88393dba30e9d",
}
REALESRGAN_WEIGHTS = {
    "RealESRGAN_x4plus.pth": {
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        "sha256": "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
        "scale": 4,
    },
    "RealESRGAN_x2plus.pth": {
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        "sha256": "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb",
        "scale": 2,
    },
}
# Upstream publishes only the repository BSD-3-Clause license; no separate
# model-weights grant. Recorded honestly instead of assuming the repo license
# settles the weights.
REALESRGAN_WEIGHTS_LICENSE_STATUS = (
    "BSD-3-Clause (repository license). Upstream publishes no separate "
    "weights-specific license grant; retained as an unresolved limitation "
    "(internal bundles only) until the rights are clarified."
)

RAW_URL = "https://raw.githubusercontent.com/{repo}/{commit}/{path}"


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: pathlib.Path) -> None:
    """Transport seam (tests monkeypatch this). Google Drive needs curl."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if "drive.usercontent.google.com" in url or "drive.google.com" in url:
        result = subprocess.run(
            ["curl", "--fail", "--location", "--retry", "3", "--max-time", "600", "-o", str(destination), url],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise SystemExit(f"download failed ({result.returncode}): {result.stderr.strip()[:400]}")
        return
    request = urllib.request.Request(url, headers={"User-Agent": "floe-media-repro/1.0"})
    with urllib.request.urlopen(request, timeout=600) as response:
        destination.write_bytes(response.read())


def fetch_verified(url: str, destination: pathlib.Path, expected: str | None, *, label: str | None = None) -> str:
    """Fetch or reuse a file and verify it against a mandatory pinned hash.

    Fail-closed rules:
      * `expected` must be a 64-hex SHA-256; reviewed inputs are never accepted
        with an unknown ("None") hash.
      * an existing file with the wrong hash is refused without being deleted.
      * a freshly downloaded file with the wrong hash is removed and refused.
    """
    what = label or str(destination)
    if not isinstance(expected, str) or not SHA256_RE.match(expected):
        raise SystemExit(f"refusing unpinned input {url}: no reviewed sha256 for {what}")
    if destination.exists():
        digest = sha256(destination)
        if digest != expected:
            raise SystemExit(
                f"existing {destination} sha256 mismatch ({digest} != {expected}) for {what}; "
                "refusing to continue (remove the file to re-download)"
            )
        return digest
    download(url, destination)
    digest = sha256(destination)
    if digest != expected:
        destination.unlink(missing_ok=True)
        raise SystemExit(f"downloaded {destination} sha256 mismatch ({digest} != {expected}) for {what}")
    return digest


def file_entry(path: pathlib.Path, url: str) -> dict:
    return {"url": url, "sha256": sha256(path), "bytes": path.stat().st_size}


def fetch_source_files(destination: pathlib.Path, work: pathlib.Path) -> dict:
    """Fetch the small pinned sources; returns their manifest entries."""
    sources: dict = {
        "basicr": {"repo": BASICSR_REPO, "tag": BASICSR_TAG, "commit": BASICSR_COMMIT,
                   "license": BASICSR_LICENSE, "files": {}},
        "practicalRife": {"repo": "hzwer/Practical-RIFE", "commit": PRACTICAL_RIFE_COMMIT,
                          "license": "MIT", "files": {}},
        "realesrgan": {"repo": "xinntao/Real-ESRGAN", "commit": REALESRGAN_COMMIT,
                       "license": "BSD-3-Clause", "files": {}},
    }
    for relative, expected in BASICSR_FILES.items():
        url = RAW_URL.format(repo=BASICSR_REPO, commit=BASICSR_COMMIT, path=relative)
        target = work / "basicsr" / relative
        fetch_verified(url, target, expected, label=f"BasicSR {relative}")
        sources["basicr"]["files"][relative] = file_entry(target, url)
    for relative, expected in PRACTICAL_RIFE_FILES.items():
        url = RAW_URL.format(repo="hzwer/Practical-RIFE", commit=PRACTICAL_RIFE_COMMIT, path=relative)
        target = work / "upstream-practical-rife" / relative
        fetch_verified(url, target, expected, label=f"Practical-RIFE {relative}")
        sources["practicalRife"]["files"][relative] = file_entry(target, url)
    for relative, expected in REALESRGAN_FILES.items():
        url = RAW_URL.format(repo="xinntao/Real-ESRGAN", commit=REALESRGAN_COMMIT, path=relative)
        target = work / "realesrgan" / relative
        fetch_verified(url, target, expected, label=f"Real-ESRGAN {relative}")
        sources["realesrgan"]["files"][relative] = file_entry(target, url)

    # Import-time helper used by convert_rife.py.
    (work / "upstream-practical-rife" / "model" / "__init__.py").write_text("")
    return sources


def fetch_weights(destination: pathlib.Path, work: pathlib.Path) -> dict:
    weights: dict = {}
    archive = destination / "rife425lite.zip"
    archive_sha = fetch_verified(RIFE_WEIGHTS_URL, archive, RIFE_WEIGHTS_SHA256, label="RIFE 4.25 Lite archive")
    rife_dir = work / "rife425lite"
    rife_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zip_file:
        for member in zip_file.namelist():
            if member.startswith("__MACOSX/") or member.endswith("/.DS_Store") or "__pycache__" in member:
                continue
            name = pathlib.Path(member).name
            if not name:
                continue
            target = rife_dir / name
            with zip_file.open(member) as source, target.open("wb") as output:
                output.write(source.read())
    flownet = rife_dir / "flownet.pkl"
    flownet_sha = sha256(flownet)
    if flownet_sha != RIFE_FLOWNET_SHA256:
        flownet.unlink(missing_ok=True)
        raise SystemExit(f"flownet.pkl sha256 mismatch: {flownet_sha} != {RIFE_FLOWNET_SHA256}")
    weights["rife"] = {
        "archiveUrl": "https://drive.google.com/file/d/1zlKblGuKNatulJNFf5jdB-emp9AqGK05/view?usp=share_link",
        "archiveSha256": archive_sha,
        "archiveBytes": archive.stat().st_size,
        "flownetSha256": flownet_sha,
        "version": RIFE_VERSION,
        "releaseNote": RIFE_RELEASE_NOTE,
    }
    for name, spec in REALESRGAN_WEIGHTS.items():
        target = destination / name
        digest = fetch_verified(spec["url"], target, spec["sha256"], label=f"Real-ESRGAN {name}")
        weights.setdefault("realesrgan", {})[name] = {
            "url": spec["url"], "sha256": digest, "bytes": target.stat().st_size, "scale": spec["scale"],
        }
    return weights


# --------------------------------------------------------------------------
# License and notice staging
# --------------------------------------------------------------------------

def _notice_header(title: str, lines: list[str]) -> str:
    rule = "=" * len(title)
    return f"{title}\n{rule}\n\n" + "\n".join(lines) + "\n\n"


def compose_licenses(destination: pathlib.Path, work: pathlib.Path, sources: dict) -> dict:
    """Compose the per-bundle notice files from the pinned upstream texts.

    The packager copies `<model-dir>.LICENSE` into each bundle; the exact bytes
    are hash-recorded in the provenance so `package_models.py --provenance`
    can prove they came from this fetch, not from a manual edit.
    """
    rife_license = (work / "upstream-practical-rife" / "LICENSE").read_text()
    rife_readme_sha = sources["practicalRife"]["files"]["README.md"]["sha256"]
    rife_license_sha = sources["practicalRife"]["files"]["LICENSE"]["sha256"]
    basicr_license = (work / "basicsr" / "LICENSE.txt").read_text()
    realesrgan_license = (work / "realesrgan" / "LICENSE").read_text()

    rife_notice = _notice_header(
        "Third-party notices — floe-model-rife-v4 (RIFE 4.25 Lite, Core ML conversion)",
        [
            "Upstream project: Practical-RIFE — https://github.com/hzwer/Practical-RIFE",
            f"Pinned source commit: {PRACTICAL_RIFE_COMMIT}",
            f"Weights: official README {RIFE_VERSION} link (Google Drive file id "
            "1zlKblGuKNatulJNFf5jdB-emp9AqGK05), archive sha256",
            f"  {RIFE_WEIGHTS_SHA256}",
            f"Converted checkpoint: flownet.pkl sha256 {RIFE_FLOWNET_SHA256}",
            "",
            "License: MIT. Upstream README (pinned commit) states:",
            f'  "{PRACTICAL_RIFE_WEIGHTS_STATEMENT}"',
            f"  README sha256: {rife_readme_sha}",
            f"  LICENSE sha256: {rife_license_sha}",
            "",
            "The full upstream license text follows.",
        ],
    ) + rife_license

    realesrgan_weights = {
        "floe-model-realesrgan-x4plus": ("x4plus", "RealESRGAN_x4plus.pth",
                                         REALESRGAN_WEIGHTS["RealESRGAN_x4plus.pth"]),
        "floe-model-realesrgan-x2plus": ("x2plus", "RealESRGAN_x2plus.pth",
                                         REALESRGAN_WEIGHTS["RealESRGAN_x2plus.pth"]),
    }
    notices = {
        "floe-model-rife-v4.LICENSE": rife_notice,
    }
    for model_dir, (label, weight_name, spec) in realesrgan_weights.items():
        notice = _notice_header(
            f"Third-party notices — {model_dir} (Real-ESRGAN {label}, Core ML conversion)",
            [
                "This bundle contains a Core ML conversion of an upstream trained checkpoint and",
                "of the upstream network architecture source. Both notices are retained below.",
                "The two licenses cover different artifacts and are deliberately not merged.",
                "",
                "1) Model weights and reference pipeline — Real-ESRGAN, BSD-3-Clause",
                f"   Pinned commit: {REALESRGAN_COMMIT}",
                f"   Checkpoint: {weight_name} ({spec['url']})",
                f"   Checkpoint sha256: {spec['sha256']}",
                f"   Weights license status: {REALESRGAN_WEIGHTS_LICENSE_STATUS}",
                "",
                "2) Network architecture source — BasicSR RRDBNet, Apache-2.0",
                f"   Pinned commit: {BASICSR_COMMIT} (tag {BASICSR_TAG})",
                "   Vendored source: FloeAgent/scripts/media-enhancement/rrdbnet_arch.py",
                "   Upstream basicsr/archs/rrdbnet_arch.py sha256:",
                f"     {BASICSR_FILES['basicsr/archs/rrdbnet_arch.py']}",
                "   Upstream basicsr/archs/arch_util.py sha256:",
                f"     {BASICSR_FILES['basicsr/archs/arch_util.py']}",
                "   License: Apache-2.0 (upstream LICENSE.txt sha256 "
                f"{BASICSR_FILES['LICENSE.txt']})",
                "",
                "Both license texts follow.",
            ],
        ) + (
            "--- Real-ESRGAN license (BSD-3-Clause) -------------------------------------\n\n"
            + realesrgan_license
            + "\n\n--- BasicSR license (Apache-2.0) -------------------------------------------\n\n"
            + basicr_license
        )
        notices[f"{model_dir}.LICENSE"] = notice

    licenses_dir = pathlib.Path(destination)
    licenses_dir.mkdir(parents=True, exist_ok=True)
    staged = {}
    for name, text in notices.items():
        target = licenses_dir / name
        target.write_text(text)
        staged[name] = {"path": str(target), "sha256": sha256(target), "bytes": target.stat().st_size}
    return staged


# --------------------------------------------------------------------------
# Check mode (read-only)
# --------------------------------------------------------------------------

def expected_paths(destination: pathlib.Path, work: pathlib.Path) -> list[tuple[str, pathlib.Path, str | None, bool]]:
    """(label, path, pinned sha256, required_in_sources_only)."""
    entries: list[tuple[str, pathlib.Path, str | None, bool]] = []
    for relative, expected in BASICSR_FILES.items():
        entries.append((f"BasicSR {relative}", work / "basicsr" / relative, expected, True))
    for relative, expected in PRACTICAL_RIFE_FILES.items():
        entries.append((f"Practical-RIFE {relative}", work / "upstream-practical-rife" / relative, expected, True))
    for relative, expected in REALESRGAN_FILES.items():
        entries.append((f"Real-ESRGAN {relative}", work / "realesrgan" / relative, expected, True))
    entries.append(("RIFE archive", destination / "rife425lite.zip", RIFE_WEIGHTS_SHA256, False))
    entries.append(("RIFE flownet.pkl", work / "rife425lite" / "flownet.pkl", RIFE_FLOWNET_SHA256, False))
    for name, spec in REALESRGAN_WEIGHTS.items():
        entries.append((f"weights {name}", destination / name, spec["sha256"], False))
    return entries


def run_check(destination: pathlib.Path, work: pathlib.Path, licenses: pathlib.Path,
              sources_only: bool, require_licenses: bool) -> int:
    problems: list[str] = []
    checked = 0
    for label, path, expected, small in expected_paths(destination, work):
        if sources_only and not small:
            continue
        if not path.exists():
            problems.append(f"missing: {label} ({path})")
            continue
        digest = sha256(path)
        if digest != expected:
            problems.append(f"sha256 mismatch: {label} ({digest} != {expected})")
        checked += 1
    if licenses.exists():
        for name in ("floe-model-rife-v4.LICENSE", "floe-model-realesrgan-x4plus.LICENSE",
                     "floe-model-realesrgan-x2plus.LICENSE"):
            target = licenses / name
            if not target.exists():
                problems.append(f"missing license notice: {target}")
            else:
                checked += 1
    elif require_licenses:
        problems.append(f"missing license directory: {licenses}")
    print(json.dumps({"mode": "check", "sourcesOnly": sources_only, "checked": checked,
                      "problems": problems, "ok": not problems}, indent=2, sort_keys=True))
    if problems:
        print(f"CHECK FAILED: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    print(f"CHECK OK: {checked} pinned file(s) verified", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", required=True, help="download directory (weights + provenance.json)")
    parser.add_argument("--work", required=True, help="extraction/source directory")
    parser.add_argument("--licenses", help="directory to write the composed notice files (default: <work>/licenses)")
    parser.add_argument("--sources-only", action="store_true",
                        help="fetch only the small pinned sources/licenses; skip weights and flownet extraction")
    parser.add_argument("--check", action="store_true",
                        help="read-only verification of an existing fetch; writes nothing")
    args = parser.parse_args()
    destination = pathlib.Path(args.destination).resolve()
    work = pathlib.Path(args.work).resolve()
    licenses = pathlib.Path(args.licenses).resolve() if args.licenses else work / "licenses"

    if args.check:
        return run_check(destination, work, licenses, args.sources_only, require_licenses=args.licenses is not None)

    destination.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)

    sources = fetch_source_files(destination, work)
    manifest: dict = {
        "schema": 2,
        "note": "Pinned conversion inputs for Floe T2 media enhancement. Local evidence only; no publication.",
        "mode": "sources-only" if args.sources_only else "full",
        "conversionArchitecture": {
            "vendored": "FloeAgent/scripts/media-enhancement/rrdbnet_arch.py",
            "verifiedBy": "FloeAgent/scripts/media-enhancement/verify_rrdbnet_source.py",
            "upstreamFile": "basicsr/archs/rrdbnet_arch.py",
            "upstreamSha256": BASICSR_FILES["basicsr/archs/rrdbnet_arch.py"],
            "commit": BASICSR_COMMIT,
        },
    }
    manifest.update({key: sources[key] for key in ("basicr", "practicalRife", "realesrgan")})

    if not args.sources_only:
        weights = fetch_weights(destination, work)
        manifest["practicalRife"]["weights"] = weights["rife"]
        manifest["realesrgan"]["weights"] = weights["realesrgan"]
        manifest["realesrgan"]["weightsLicense"] = "BSD-3-Clause (repository license only)"
        manifest["realesrgan"]["weightsLicenseStatus"] = REALESRGAN_WEIGHTS_LICENSE_STATUS
        manifest["realesrgan"]["weightsLicenseEvidence"] = {
            "path": "LICENSE",
            "sha256": sources["realesrgan"]["files"]["LICENSE"]["sha256"],
            "note": "repository license file; no separate weights grant found upstream",
        }
    manifest["practicalRife"]["weightsLicense"] = "MIT"
    manifest["practicalRife"]["weightsLicenseEvidence"] = {
        "statement": PRACTICAL_RIFE_WEIGHTS_STATEMENT,
        "readmePath": "README.md",
        "readmeSha256": sources["practicalRife"]["files"]["README.md"]["sha256"],
        "licensePath": "LICENSE",
        "licenseSha256": sources["practicalRife"]["files"]["LICENSE"]["sha256"],
    }

    manifest["licenseFiles"] = compose_licenses(licenses, work, sources)

    manifest_path = destination / "provenance.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
