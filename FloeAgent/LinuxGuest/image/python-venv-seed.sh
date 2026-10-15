#!/bin/sh
# python-venv-seed.sh — build the immutable Python venv seed inside a Floe
# guest rootfs (image recipe, reproducible).
#
# Copyright (c) 2026 Floe contributors
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Why a seed: the first Python use in a fresh environment otherwise pays
# `python3 -m venv --system-site-packages` (ensurepip) inside the TinyEMU
# interpreter — measured 143.6 s on an Apple M5 Pro host and 255-259 s in the
# on-device run. The environment-level fast path
# (LinuxGuestPythonEnvironment.swift: `--without-pip` + distro-pip wrapper +
# atomic rename, 0.6 s measured) is the production route on the pinned image;
# this seed is the fallback for images without a usable distro pip and the
# reproducibility record for that fallback.
#
# Contract:
#   * the seed lives at /usr/lib/floe/python/venv-seed — inside the immutable
#     image layers. It is NEVER under /floe: /floe/env is the per-environment
#     writable layer mounted over the image, so a seed baked there would be
#     shadowed (and a seed written into it would leak shared state).
#   * materialization is per environment and the service owns it: copy the
#     seed to a private staging path under /floe/env/python, rewrite the
#     absolute seed paths in the copied venv (bin/activate*, bin/pip* and the
#     pyvenv.cfg command line), validate the interpreter/version, then
#     promote with one atomic rename. The rewrite is what prevents a copied
#     seed from sending `pip`/`python3` back into the read-only image copy.
#   * the seed is created with --system-site-packages so Debian's apt Python
#     packages stay visible read-only, and WITH ensurepip because the seed's
#     whole purpose is to pay that one-time cost at image build time instead
#     of at first use.
#
# Usage (inside the target rootfs context: the image build runs a qemu-user
# riscv64 chroot, the guest runs it natively):
#   sh python-venv-seed.sh [/] [seed-path]
# then record/verify with:
#   python3 python-venv-seed-verify.py --root <rootfs-dir>
set -eu

ROOT="${1:-/}"
SEED_PATH="${2:-/usr/lib/floe/python/venv-seed}"
SEED_DIR="$ROOT$SEED_PATH"
MANIFEST="$ROOT/usr/lib/floe/python/venv-seed.manifest.json"
SCRIPT_SHA="$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$0" | cut -d' ' -f1)"

case "$SEED_PATH" in
  /floe|/floe/*) echo "refusing: the seed must not live under /floe (per-env layer)" >&2; exit 2;;
esac

rm -rf "$SEED_DIR"
mkdir -p "$(dirname "$SEED_DIR")"
python3 -m venv --system-site-packages "$SEED_DIR"

# The seed interpreter must run and import its own pip.
VERSION="$("$SEED_DIR/bin/python3" -c 'import sys; print(sys.version.split()[0])')"
"$SEED_DIR/bin/python3" -c 'import sys, sysconfig, pip; print(sys.version.split()[0]); print(sysconfig.get_paths()["purelib"])' >/dev/null
PLATFORM="$("$SEED_DIR/bin/python3" -c 'import sysconfig; print(sysconfig.get_platform())')"
BASE_EXE="$("$SEED_DIR/bin/python3" -c 'import sys; print(sys._base_executable)')"
FILES="$(cd "$SEED_DIR" && find . -type f -o -type l | sed 's|^\./||' | sort)"

python3 - "$SEED_DIR" "$MANIFEST" "$SEED_PATH" "$VERSION" "$PLATFORM" "$BASE_EXE" "$SCRIPT_SHA" <<'PY'
import hashlib, json, os, sys

seed_dir, manifest_path, seed_path, version, platform, base_exe, script_sha = sys.argv[1:8]
files = {}
total = 0
for root, _dirs, names in os.walk(seed_dir):
    for name in names:
        full = os.path.join(root, name)
        rel = os.path.relpath(full, seed_dir)
        digest = hashlib.sha256()
        if os.path.islink(full):
            target = os.readlink(full)
            files[rel] = {"link": target}
            continue
        with open(full, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        size = os.path.getsize(full)
        total += size
        files[rel] = {"sha256": digest.hexdigest(), "bytes": size}

manifest = {
    "schema": "floe-python-venv-seed/v1",
    "seed_path": seed_path,
    "materialize_target": "/floe/env/python/venv",
    "created_by": "FloeAgent/LinuxGuest/image/python-venv-seed.sh",
    "recipe_sha256": script_sha,
    "command": "python3 -m venv --system-site-packages " + seed_path,
    "python": {"version": version, "platform": platform, "base_executable": base_exe,
               "include_system_site_packages": True},
    "file_count": len(files),
    "total_bytes": total,
    "files": files,
}
os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("seed: %s files=%d bytes=%d python=%s" % (seed_path, len(files), total, version))
print("manifest: %s" % manifest_path)
PY

python3 "$(dirname "$0")/python-venv-seed-verify.py" --root "$ROOT" --manifest "$MANIFEST"
