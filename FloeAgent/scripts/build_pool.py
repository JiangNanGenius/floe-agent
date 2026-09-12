#!/usr/bin/env python3
"""Stages Floe repository packages from `pool/manifest.json`.

Ready entries (status=ready) are downloaded, SHA-256 verified and laid out as
`pool/<component>/<package>/{control,payload/...}` so `build_floe_repo.py` can
package them into real .deb files. Pending entries are skipped with a warning
(CI fills in the artifact URL and digest when the build completes).

Kinds:
  npm            → tarball extracted into the Node global module root
  cross-compiled → artifact already laid out as the final file tree
  wasm           → .wasm plus a /usr/bin shim script
  python-wheel   → wheel extracted into usr/lib/floe-python/site-packages
  file           → artifact copied under usr/share/<package>/

Usage: python3 FloeAgent/scripts/build_pool.py [--check]
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import sys
import tarfile
import urllib.request
import zipfile

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
POOL = REPO_ROOT / "pool"
MANIFEST = POOL / "manifest.json"


def sha256_file(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def download(url: str, destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=300) as response:
        destination.write_bytes(response.read())


def stage_payload(package_dir: pathlib.Path, kind: str, artifact: pathlib.Path, module_name: str) -> None:
    payload = package_dir / "payload"
    if payload.exists():
        shutil.rmtree(payload)
    payload.mkdir(parents=True)
    if kind == "npm":
        target = payload / "usr/lib/node_modules"
        target.mkdir(parents=True)
        with tarfile.open(artifact) as archive:
            archive.extractall(target, filter="data")
        # npm tarballs wrap everything in a single `package/` directory.
        wrapped = target / "package"
        if wrapped.is_dir():
            wrapped.rename(target / module_name)
    elif kind == "python-wheel":
        target = payload / "usr/lib/floe-python/site-packages"
        target.mkdir(parents=True)
        with zipfile.ZipFile(artifact) as archive:
            archive.extractall(target)
    elif kind == "wasm":
        target = payload / "usr/lib/floe-wasm"
        target.mkdir(parents=True)
        shutil.copy2(artifact, target / f"{module_name}.wasm")
        bin_dir = payload / "usr/bin"
        bin_dir.mkdir(parents=True)
        shim = bin_dir / module_name
        shim.write_text(f"#!/bin/sh\nexec wasm /usr/lib/floe-wasm/{module_name}.wasm \"$@\"\n")
        shim.chmod(0o755)
    elif kind == "cross-compiled":
        with tarfile.open(artifact) as archive:
            archive.extractall(payload, filter="data")
    else:  # file
        target = payload / "usr/share" / module_name
        target.mkdir(parents=True)
        shutil.copy2(artifact, target / artifact.name)


def main() -> int:
    check = "--check" in sys.argv
    manifest = json.loads(MANIFEST.read_text())
    cache = POOL / ".cache"
    cache.mkdir(exist_ok=True)
    staged = 0
    pending = 0
    for package in manifest.get("packages", []):
        name = package["name"]
        if package.get("status") != "ready":
            print(f"pending: {name} ({package.get('kind')})")
            pending += 1
            continue
        url = package.get("url")
        expected = package.get("sha256")
        if not url or not expected:
            raise SystemExit(f"{name}: ready entry needs url and sha256")
        artifact = cache / pathlib.Path(url).name
        if not artifact.exists():
            if check:
                raise SystemExit(f"{name}: artifact not cached; run without --check to download")
            download(url, artifact)
        actual = sha256_file(artifact)
        if actual != expected:
            raise SystemExit(f"{name}: sha256 mismatch {actual} != {expected}")
        if check:
            print(f"ok: {name}")
            continue
        component_dir = POOL / package["component"] / name
        component_dir.mkdir(parents=True, exist_ok=True)
        control = package["control"]
        control_text = "\n".join(f"{key}: {value}" for key, value in control.items()) + "\n"
        (component_dir / "control").write_text(control_text)
        stage_payload(component_dir, package["kind"], artifact, package.get("module") or name)
        print(f"staged: {name} -> {component_dir.relative_to(REPO_ROOT)}")
        staged += 1
    print(f"{staged} staged, {pending} pending")
    return 0


if __name__ == "__main__":
    sys.exit(main())
